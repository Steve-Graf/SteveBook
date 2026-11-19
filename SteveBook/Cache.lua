-- Cache.lua: the bettor's per-book cache (SPEC §4, last paragraph). Pure logic: no WoW API
-- calls, testable with plain Lua. The cache is just data (it can live in SavedVariables); the
-- bookie is the source of truth and a SYNC replaces everything the bookie knows about.
--
-- Store layout (one per character, e.g. SteveBookDB.cache):
--   store = { books = { [code] = BookCache } }
--   BookCache = {
--     code, name?, owner? (bookie character), status = "requested" | "active" | "denied" | "removed",
--     rev = n,                          -- last bookie revision seen (send in SYNC_REQ)
--     markets = { [id] = Market },      -- SPEC §4 Market tables, as the bookie sent them
--     bets = { [id] = Bet },            -- my bets the bookie knows about
--     pending = { [ref] = Bet },      -- bets I sent that have no BET_ACK/BET_REJECT yet
--     rejected = { Bet... },            -- recent rejections, newest last (for the UI)
--     balance = copper, payments = { {amount, at, note} }, creditLimit = copper|nil,
--     lastPong = epoch|nil, syncedAt = epoch|nil,
--   }
-- `now` is always passed in (GetServerTime() in game). Money is integer copper.
local ADDON, ns = ...
ns = ns or {}

local Cache = {}
ns.Cache = Cache

local PONG_TTL = 60          -- seconds a PONG keeps the book "online"
local REJECTED_KEEP = 20
local PENDING_EXPIRE = 120   -- seconds before an unanswered request is dropped as "no_reply"

Cache.PONG_TTL = PONG_TTL

local function normalize(code) return ((code or ""):upper():gsub("%s", "")) end
Cache.NormalizeCode = normalize

function Cache.NewStore()
    return { books = {} }
end

-- Returns the BookCache for `code`, creating it (status "requested") when `create` is true.
function Cache.Book(store, code, create)
    code = normalize(code)
    local b = store.books[code]
    if not b and create then
        b = {
            code = code, status = "requested", rev = 0,
            markets = {}, bets = {}, pending = {}, rejected = {},
            balance = 0, payments = {},
        }
        store.books[code] = b
    end
    return b
end

-- Books sorted by code, for a stable book picker.
function Cache.ListBooks(store)
    local list = {}
    for _, b in pairs(store.books) do list[#list + 1] = b end
    table.sort(list, function(a, c) return a.code < c.code end)
    return list
end

function Cache.Forget(store, code) store.books[normalize(code)] = nil end

------------------------------------------------------------------------------------------
-- Membership
------------------------------------------------------------------------------------------

-- I sent a JOIN_REQ.
function Cache.RequestJoin(store, code, name)
    local b = Cache.Book(store, code, true)
    if b.status ~= "active" then b.status = "requested" end
    if name then b.name = name end
    return b
end

-- JOIN_OK / JOIN_DENY arrived. `owner` is the bookie's character name (only PONGs from them
-- count as the book being online).
function Cache.SetMembership(store, code, approved, name, owner)
    local b = Cache.Book(store, code, true)
    b.status = approved and "active" or "denied"
    if name then b.name = name end
    if owner then b.owner = owner end
    return b
end

------------------------------------------------------------------------------------------
-- Applying bookie messages
------------------------------------------------------------------------------------------

-- SYNC: replace markets, bets, balance, payments and limit wholesale. Local pending bets
-- survive unless the snapshot already contains a bet with the same ref (it was accepted).
-- snap = { rev, markets = {Market...}, bets = {Bet...}, balance, payments, creditLimit }
function Cache.ApplySync(store, code, snap, now)
    local b = Cache.Book(store, code, true)
    b.status = "active"
    b.rev = snap.rev or b.rev
    b.markets, b.bets = {}, {}
    for _, m in ipairs(snap.markets or {}) do b.markets[m.id] = m end
    for _, bet in ipairs(snap.bets or {}) do
        b.bets[bet.id] = bet
        local id = bet.ref
        if id ~= nil then b.pending[id] = nil end
    end
    b.balance = snap.balance or 0
    b.payments = snap.payments or {}
    b.creditLimit = snap.creditLimit
    b.syncedAt = now
    return b
end

-- Status my bet should have given its market. The result is public (market.result is the
-- winning selection id or "push"), so the bettor can grade without waiting for a SYNC.
-- Individually voided bets (status "void") are left alone unless the whole market is void.
function Cache.GradeBet(market, bet)
    local st = bet.status
    if st ~= "accepted" and st ~= "won" and st ~= "lost" and st ~= "push" and st ~= "void" then return st end
    if market.status == "void" then return "void" end
    if st == "void" then return st end
    if market.status == "settled" then
        if market.result == "push" then return "push" end
        return market.result == bet.selectionId and "won" or "lost"
    end
    return "accepted"
end

-- MARKET: one full Market table (new, edited, locked, settled or void). Re-grades my bets on
-- it. Returns the BookCache and the previous market (or nil) so callers can spot transitions.
function Cache.ApplyMarket(store, code, market)
    local b = Cache.Book(store, code, true)
    local old = b.markets[market.id]
    b.markets[market.id] = market
    for _, bet in pairs(b.bets) do
        if bet.marketId == market.id then
            local st = Cache.GradeBet(market, bet)
            if st ~= bet.status then bet.status, bet.delta, bet.settledAt = st, nil, nil end
        end
    end
    return b, old
end

-- Remember a bet request I'm about to send. `ref` is a client nonce, unique per bettor; the
-- bookie echoes it back so a retried BET_PLACE can't double-book. Returns the pending bet.
function Cache.NewPending(store, code, req, now)
    local b = Cache.Book(store, code, true)
    local bet = {
        ref = req.ref, marketId = req.marketId, selectionId = req.selectionId,
        stake = req.stake, odds = req.odds, status = "pending", placedAt = now,
    }
    b.pending[req.ref] = bet
    return bet
end

-- BET_ACK: my request id, the accepted Bet (final odds, id), and the new balance if sent.
function Cache.ApplyBetAck(store, code, ref, bet, balance)
    local b = Cache.Book(store, code, true)
    if ref ~= nil then b.pending[ref] = nil end
    b.bets[bet.id] = bet
    if balance then b.balance = balance end
    return b
end

-- BET_REJECT: `ref` of my request, a short reason code, `currentOdds` (set for
-- "odds_changed") and `available` (copper, set for "credit_limit"). Returns the rejected bet,
-- or nil if we weren't waiting for that ref.
function Cache.ApplyBetReject(store, code, ref, reason, currentOdds, now, available)
    local b = Cache.Book(store, code, true)
    local bet = b.pending[ref]
    if not bet then return nil end
    b.pending[ref] = nil
    bet.status, bet.rejectReason, bet.currentOdds, bet.available, bet.settledAt = "rejected", reason, currentOdds, available, now
    b.rejected[#b.rejected + 1] = bet
    while #b.rejected > REJECTED_KEEP do table.remove(b.rejected, 1) end
    return bet
end

-- BALANCE: absolute new balance, optional note. Appends to the payments list only when the
-- bookie sent a payment entry; settlements are visible through bet results instead.
function Cache.ApplyBalance(store, code, balance, payment)
    local b = Cache.Book(store, code, true)
    b.balance = balance
    if payment then b.payments[#b.payments + 1] = payment end
    return b
end

-- PONG from `sender`. Ignored (returns nil) if we know the bookie and it isn't them.
function Cache.MarkPong(store, code, now, sender)
    local b = Cache.Book(store, code, true)
    if sender and b.owner and sender ~= b.owner then return nil end
    b.lastPong = now
    return b
end

-- Drop requests the bookie never answered. Returns the dropped bets.
function Cache.ExpirePending(store, code, now)
    local b = Cache.Book(store, code, false)
    local dropped = {}
    if not b then return dropped end
    for ref, bet in pairs(b.pending) do
        if now - bet.placedAt >= PENDING_EXPIRE then
            b.pending[ref] = nil
            bet.status, bet.rejectReason, bet.settledAt = "rejected", "no_reply", now
            b.rejected[#b.rejected + 1] = bet
            dropped[#dropped + 1] = bet
        end
    end
    return dropped
end

------------------------------------------------------------------------------------------
-- Queries (everything the UI shows comes through here)
------------------------------------------------------------------------------------------

function Cache.IsOnline(store, code, now)
    local b = Cache.Book(store, code, false)
    return b ~= nil and b.lastPong ~= nil and now - b.lastPong <= PONG_TTL
end

-- Can I place a bet on this market right now? Returns ok, reason.
function Cache.CanBet(store, code, marketId, now)
    local b = Cache.Book(store, code, false)
    if not b or b.status ~= "active" then return false, "not_member" end
    if not Cache.IsOnline(store, code, now) then return false, "offline" end
    local m = b.markets[marketId]
    if not m then return false, "no_market" end
    if m.status ~= "open" or now >= m.closesAt then return false, "market_closed" end
    return true
end

-- Open markets grouped by sport then event, soonest close first:
-- { { sport = "NFL", events = { { event = "PHI @ DAL", closesAt = t, markets = {Market...} } } } }
function Cache.Lines(store, code, now)
    local b = Cache.Book(store, code, false)
    if not b then return {} end
    local bySport, sports = {}, {}
    for _, m in pairs(b.markets) do
        if m.status == "open" and now < m.closesAt then
            local sport = (m.sport and m.sport ~= "") and m.sport or "Other"
            local s = bySport[sport]
            if not s then s = { sport = sport, byEvent = {}, events = {} }; bySport[sport] = s; sports[#sports + 1] = s end
            local e = s.byEvent[m.event]
            if not e then
                e = { event = m.event, closesAt = m.closesAt, markets = {} }
                s.byEvent[m.event] = e
                s.events[#s.events + 1] = e
            end
            e.markets[#e.markets + 1] = m
            if m.closesAt < e.closesAt then e.closesAt = m.closesAt end
        end
    end
    local order = { moneyline = 1, spread = 2, total = 3 }
    table.sort(sports, function(a, c) return a.sport < c.sport end)
    for _, s in ipairs(sports) do
        s.byEvent = nil
        table.sort(s.events, function(a, c)
            if a.closesAt ~= c.closesAt then return a.closesAt < c.closesAt end
            return a.event < c.event
        end)
        for _, e in ipairs(s.events) do
            table.sort(e.markets, function(a, c)
                if a.type ~= c.type then return (order[a.type] or 9) < (order[c.type] or 9) end
                return a.id < c.id
            end)
        end
    end
    return sports
end

local OPEN_BET = { pending = true, accepted = true }

local function betList(b)
    local list = {}
    for _, bet in pairs(b.bets) do list[#list + 1] = bet end
    for _, bet in pairs(b.pending) do list[#list + 1] = bet end
    return list
end

-- My bets: { open = {...}, settled = {...} }. Open = pending or accepted; settled = won, lost,
-- push, void (and rejected). Newest first. Each entry is the Bet plus `market` (may be nil if
-- the market aged out of the cache).
function Cache.MyBets(store, code)
    local out = { open = {}, settled = {} }
    local b = Cache.Book(store, code, false)
    if not b then return out end
    local list = betList(b)
    for _, bet in ipairs(b.rejected) do list[#list + 1] = bet end
    table.sort(list, function(a, c)
        if (a.placedAt or 0) ~= (c.placedAt or 0) then return (a.placedAt or 0) > (c.placedAt or 0) end
        return (a.id or 0) > (c.id or 0)
    end)
    for _, bet in ipairs(list) do
        local row = setmetatable({ market = b.markets[bet.marketId] }, { __index = bet })
        local dest = OPEN_BET[bet.status] and out.open or out.settled
        dest[#dest + 1] = row
    end
    return out
end

-- Selection label for a bet, falling back when the market isn't cached.
function Cache.SelectionLabel(market, selectionId)
    local s = market and market.selections and market.selections[selectionId]
    return s and s.label or ("#" .. tostring(selectionId))
end

-- Total copper at risk in accepted + pending bets.
function Cache.OpenRisk(store, code)
    local b = Cache.Book(store, code, false)
    local risk = 0
    if not b then return 0 end
    for _, bet in ipairs(betList(b)) do
        if OPEN_BET[bet.status] then risk = risk + bet.stake end
    end
    return risk
end

-- Copper still bettable under the credit limit, or nil if there is none. Advisory only: the
-- bookie enforces the limit.
function Cache.CreditAvailable(store, code)
    local b = Cache.Book(store, code, false)
    if not b or not b.creditLimit then return nil end
    local owed = b.balance < 0 and -b.balance or 0
    return math.max(0, b.creditLimit - owed - Cache.OpenRisk(store, code))
end

------------------------------------------------------------------------------------------
-- Display helpers (text only; the UI decides colors and layout)
------------------------------------------------------------------------------------------

local function num(n) return (("%g"):format(n)) end
local function signed(n) return (("%+g"):format(n)) end

-- "PHI -3.5" for a spread, "Over 47.5" for a total, plain label for a moneyline. For spreads
-- the market line belongs to selection 1 and the other side gets the opposite sign.
function Cache.SelectionText(market, selectionId)
    local label = Cache.SelectionLabel(market, selectionId)
    if not market or market.line == nil then return label end
    if market.type == "spread" then
        local line = selectionId == 1 and market.line or -market.line
        return label .. " " .. signed(line)
    elseif market.type == "total" then
        return label .. " " .. num(market.line)
    end
    return label
end

local REASONS = {
    not_member = "You are not an approved member of this book.",
    market_closed = "That market is closed.",
    market_unknown = "That market no longer exists.",
    no_market = "That market no longer exists.",
    selection_unknown = "That selection no longer exists.",
    bad_selection = "That selection no longer exists.",
    bad_stake = "Invalid stake.",
    bad_request = "The bookie could not read that request.",
    odds_changed = "The odds changed.",
    credit_limit = "That bet is over your credit limit.",
    book_error = "The book had an error; try again.",
    no_reply = "The bookie did not answer.",
    offline = "The bookie is offline.",
}

function Cache.ReasonText(reason)
    return REASONS[reason] or ("Rejected (" .. tostring(reason) .. ").")
end

-- Effect of a bet on my balance: copper for a finished bet, nil while it is still open or if it
-- was rejected. Prefers the bookie's own `delta` when it sent one.
function Cache.BetDelta(bet)
    if bet.delta then return bet.delta end
    local st = bet.status
    if st == "won" or st == "lost" or st == "push" or st == "void" then
        return (ns.Odds.Delta(bet.stake, bet.odds, st))
    end
    return nil
end

return Cache
