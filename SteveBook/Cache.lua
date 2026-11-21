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

-- "nflk7q2", "nfl k7q2" and "NFL-K7Q2" are all the same book (Protocol.CanonicalCode).
local function normalize(code) return ns.Protocol.CanonicalCode(code) end
Cache.NormalizeCode = normalize

-- True if `code` (after normalizing) looks like a join code: 3 letters/digits, hyphen, 4.
function Cache.IsValidCode(code) return normalize(code):match("^[A-Z0-9][A-Z0-9][A-Z0-9]%-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$") ~= nil end

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
-- A game that has started (past closesAt, the game's start) or is finished (locked, settled
-- or void) takes no bets and is not shown in Lines. `now` may be nil to judge by status only.
function Cache.IsClosed(market, now)
    return market.status ~= "open" or (now ~= nil and now >= market.closesAt)
end

-- Does this bet (single, or any leg of a parlay) refer to the market?
local function betOnMarket(bet, marketId)
    if bet.marketId == marketId then return true end
    for _, leg in ipairs(bet.legs or {}) do
        if leg.marketId == marketId then return true end
    end
    return false
end

Cache.BetOnMarket = betOnMarket

local function holdsBet(b, marketId)
    for _, bet in pairs(b.bets) do if betOnMarket(bet, marketId) then return true end end
    for _, bet in pairs(b.pending) do if betOnMarket(bet, marketId) then return true end end
    return false
end

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
    -- Closed games nobody here bet on are not worth keeping (My Bets needs the ones I bet on).
    for id, m in pairs(b.markets) do
        if Cache.IsClosed(m, now) and not holdsBet(b, id) then b.markets[id] = nil end
    end
    b.balance = snap.balance or 0
    b.payments = snap.payments or {}
    b.creditLimit = snap.creditLimit
    b.syncedAt = now
    return b
end

-- MARKET: one full Market table (new, edited, locked, settled or void). It carries no bets:
-- the bookie follows a settle/void/correction with a full SYNC, which is how my bet outcomes
-- arrive. Returns the BookCache and the previous market (or nil) to spot transitions.
-- A closed game (see IsClosed) is ignored unless I already hold the market or have a bet on
-- it, so closed games never enter the cache; held ones still update (a settled result must
-- reach My Bets). `now` is optional.
function Cache.ApplyMarket(store, code, market, now)
    local b = Cache.Book(store, code, true)
    local old = b.markets[market.id]
    if not old and Cache.IsClosed(market, now) and not holdsBet(b, market.id) then return b, nil end
    b.markets[market.id] = market
    return b, old
end

-- Remember a bet request I'm about to send. `ref` is a client nonce, unique per bettor; the
-- bookie echoes it back so a retried BET_PLACE can't double-book. Returns the pending bet.
function Cache.NewPending(store, code, req, now)
    local b = Cache.Book(store, code, true)
    local bet = { ref = req.ref, stake = req.stake, status = "pending", placedAt = now }
    if req.legs then
        -- A parlay: legs = { {marketId, selectionId, odds}, ... }; odds is the combined price.
        bet.legs, bet.odds = {}, nil
        local list = {}
        for i, leg in ipairs(req.legs) do
            bet.legs[i] = { marketId = leg.marketId, selectionId = leg.selectionId, odds = leg.odds, line = leg.line, status = "pending" }
            list[i] = leg.odds
        end
        bet.odds = ns.Odds.ParlayOdds(list)
    else
        bet.marketId, bet.selectionId, bet.odds, bet.line = req.marketId, req.selectionId, req.odds, req.line
    end
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
-- "odds_changed"), `available` (copper, set for "credit_limit") and `legIndex` (parlays: the leg
-- the reason is about) and `currentLine` (odds_changed because a spread/total line moved).
-- Returns the rejected bet,
-- or nil if we weren't waiting for that ref.
function Cache.ApplyBetReject(store, code, ref, reason, currentOdds, now, available, legIndex, currentLine)
    local b = Cache.Book(store, code, true)
    local bet = b.pending[ref]
    if not bet then return nil end
    b.pending[ref] = nil
    bet.status, bet.rejectReason, bet.currentOdds, bet.available, bet.settledAt = "rejected", reason, currentOdds, available, now
    bet.legIndex, bet.currentLine = legIndex, currentLine
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

-- Any message from the bookie (not only the answer to our ping) is a sign they are online. Kept apart
-- from lastPong, which alone decides when to ask for a fresh sync after a silence.
function Cache.MarkHeard(store, code, now, sender)
    local b = Cache.Book(store, code, false)
    if not b or (b.owner and sender and sender ~= b.owner) then return nil end
    b.lastHeard = now
    return b
end

function Cache.IsPongRecent(store, code, now)
    local b = Cache.Book(store, code, false)
    return b ~= nil and b.lastPong ~= nil and now - b.lastPong <= PONG_TTL
end

function Cache.IsOnline(store, code, now)
    local b = Cache.Book(store, code, false)
    if not b then return false end
    return (b.lastPong ~= nil and now - b.lastPong <= PONG_TTL) or (b.lastHeard ~= nil and now - b.lastHeard <= PONG_TTL)
end

-- Can I place a bet on this market right now? Returns ok, reason.
function Cache.CanBet(store, code, marketId, now)
    local b = Cache.Book(store, code, false)
    if not b or b.status ~= "active" then return false, "not_member" end
    if not Cache.IsOnline(store, code, now) then return false, "offline" end
    local m = b.markets[marketId]
    if not m then return false, "no_market" end
    if Cache.IsClosed(m, now) then return false, "market_closed" end
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

-- The selection with this id (ids are not array positions), or nil.
function Cache.Selection(market, selectionId)
    for _, sel in ipairs(market and market.selections or {}) do
        if sel.id == selectionId then return sel end
    end
end

-- Selection label for a bet, falling back when the market isn't cached.
function Cache.SelectionLabel(market, selectionId)
    local s = Cache.Selection(market, selectionId)
    return s and s.label or ("#" .. tostring(selectionId))
end

-- Event name for a bet row. The bookie sends a settled bet's market only while it sends the
-- bet, so a market can be missing.
function Cache.EventName(market)
    return market and market.event or "Game no longer listed"
end

------------------------------------------------------------------------------------------
-- Group bets ("All Bets", SPEC §3b): what every member has bet, rendered by the bookie.
------------------------------------------------------------------------------------------

Cache.GROUP_BETS_MAX = 100     -- sanity cap; the bookie sends at most 60
local GROUP_TEXT_MAX, GROUP_WHO_MAX = 240, 40

local function isOpenStatus(st) return st == "accepted" or st == "pending" or st == "open" end

-- BETS: replace the group list. Entries are { id, who, text, stake, status, at, win? }.
-- Malformed entries are skipped, long strings cut, and the list capped. Returns how many kept.
function Cache.ApplyGroupBets(store, code, entries, now)
    local b = Cache.Book(store, code, false)
    if not b then return 0 end
    local list = {}
    for _, e in ipairs(entries or {}) do
        if #list >= Cache.GROUP_BETS_MAX then break end
        if type(e) == "table" and type(e.who) == "string" and type(e.text) == "string"
            and type(e.stake) == "number" and type(e.status) == "string" then
            list[#list + 1] = {
                id = e.id, who = e.who:sub(1, GROUP_WHO_MAX), text = e.text:sub(1, GROUP_TEXT_MAX),
                stake = e.stake, status = e.status, at = type(e.at) == "number" and e.at or 0,
                win = type(e.win) == "number" and e.win or nil,
            }
        end
    end
    b.groupBets, b.groupAt = list, now
    return #list
end

-- Seconds since the last BETS, or nil if none has arrived yet.
function Cache.GroupAge(store, code, now)
    local b = Cache.Book(store, code, false)
    return b and b.groupAt and math.max(0, now - b.groupAt) or nil
end

-- The group list split for display: open bets first (newest first), then settled (newest
-- first), with the numbers for the header. nil if no BETS has arrived.
function Cache.GroupBets(store, code)
    local b = Cache.Book(store, code, false)
    if not b or not b.groupBets then return nil end
    local out = { open = {}, settled = {}, atStake = 0 }
    for _, e in ipairs(b.groupBets) do
        if isOpenStatus(e.status) then out.open[#out.open + 1] = e; out.atStake = out.atStake + e.stake
        else out.settled[#out.settled + 1] = e end
    end
    local function newest(a, c)
        if a.at ~= c.at then return a.at > c.at end
        return (a.id or 0) > (c.id or 0)
    end
    table.sort(out.open, newest)
    table.sort(out.settled, newest)
    return out
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
function Cache.SelectionText(market, selectionId, line)
    local label = Cache.SelectionLabel(market, selectionId)
    if not market then return label end
    -- A bet remembers the line it was accepted on; lines move in place afterwards.
    if line == nil then line = market.line end
    if line == nil then return label end
    if market.type == "spread" then
        return label .. " " .. signed(selectionId == 1 and line or -line)
    elseif market.type == "total" then
        return label .. " " .. num(line)
    end
    return label
end

local REASONS = {
    not_member = "You are not an approved member of this book.",
    market_closed = "This game has started.",
    parlay_conflict = "Those legs can't be combined in one parlay.",
    market_unknown = "That market no longer exists.",
    no_market = "That market no longer exists.",
    selection_unknown = "That selection no longer exists.",
    bad_selection = "That selection no longer exists.",
    bad_stake = "Invalid stake. Stakes are whole silver, from 1s up to the book maximum.",
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
        if bet.legs then
            -- A parlay can be lost (or voided by hand) while legs still read "pending", so the
            -- bet's own status decides; only a win needs the legs, to price it.
            if st == "lost" then return -bet.stake end
            if st ~= "won" then return 0 end
            local _, delta = ns.Odds.GradeParlay(bet.stake, bet.legs)
            return delta
        end
        return (ns.Odds.Delta(bet.stake, bet.odds, st))
    end
    return nil
end

-- One short description of a bet's selection(s) for lists and chat. `getMarket(id)` -> Market|nil.
function Cache.BetTitle(b, bet)
    if bet.legs then return ("Parlay (%d legs)"):format(#bet.legs) end
    return Cache.SelectionText(b.markets[bet.marketId], bet.selectionId, bet.line)
end

------------------------------------------------------------------------------------------
-- The odds board (Lines tab): one entry per game, with its spread / total / moneyline markets
-- laid out in two rows (away, home / over, under).
------------------------------------------------------------------------------------------

-- Returns { sports = { "NBA", "NFL" }, games = { Game... } } for games still open at `now`.
-- `filter` is a sport name or nil/"All". Game = { sport, event, closesAt,
--   spread = Market|nil, total = Market|nil, moneyline = Market|nil,
--   rows = { spread = {id1, id2}, total = {id1, id2}, moneyline = {id1, id2} } }
-- where row 1 / row 2 give the selection id shown on the first / second line of the game block.
-- Only the first market of each type is shown (lowest id). A moneyline is lined up with the
-- spread by team label, so the same team is on the same line.
function Cache.Board(store, code, now, filter)
    local out = { sports = {}, games = {} }
    for _, s in ipairs(Cache.Lines(store, code, now)) do
        out.sports[#out.sports + 1] = s.sport
        if not filter or filter == "All" or filter == s.sport then
            for _, ev in ipairs(s.events) do
                local g = { sport = s.sport, event = ev.event, closesAt = ev.closesAt, rows = {} }
                for _, m in ipairs(ev.markets) do
                    if not g[m.type] then g[m.type] = m end
                end
                for _, t in ipairs({ "spread", "total", "moneyline" }) do
                    local m = g[t]
                    if m and m.selections[1] and m.selections[2] then
                        g.rows[t] = { m.selections[1].id, m.selections[2].id }
                    end
                end
                local sp, ml = g.spread, g.moneyline
                if sp and ml and g.rows.spread and g.rows.moneyline then
                    local first = sp.selections[1].label
                    if ml.selections[2].label == first then
                        g.rows.moneyline = { ml.selections[2].id, ml.selections[1].id }
                    end
                end
                if g.spread or g.total or g.moneyline then out.games[#out.games + 1] = g end
            end
        end
    end
    return out
end

return Cache
