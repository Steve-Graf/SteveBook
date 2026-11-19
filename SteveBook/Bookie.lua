-- Bookie.lua: the bookie's authority logic. Pure: no WoW API calls, testable with plain lua5.1.
-- Operates on a Book table (see SPEC §4). The bookie's client is the only writer; bettor
-- clients only send requests that end up in PlaceBet / RequestJoin.
--
-- Conventions
--   * `now` is always passed in (GetServerTime() in game) so time is injectable in tests.
--   * Every mutating call bumps book.rev. Failures return nil, reasonCode and change nothing.
--   * Reason codes are short strings safe to put on the wire (BET_REJECT.reason).
local ADDON, ns = ...
ns = ns or {}
local Odds = ns.Odds

local Bookie = {}
ns.Bookie = Bookie

local MARKET_TYPES = { moneyline = true, spread = true, total = true }
local SETTLED_KEEP = 7 * 24 * 3600   -- snapshots include markets settled within this window
local PAYMENTS_KEEP = 20             -- snapshots include this many recent payments

local function touch(book) book.rev = (book.rev or 0) + 1 end

local function nextId(book, key)
    local id = book[key] or 1
    book[key] = id + 1
    return id
end

local function isCopper(n)
    return type(n) == "number" and n == math.floor(n) and n > 0
end

local function ledgerOf(book, player)
    local l = book.ledger[player]
    if not l then
        l = { balance = 0, payments = {} }
        book.ledger[player] = l
    end
    return l
end

------------------------------------------------------------------------------------------
-- Members
------------------------------------------------------------------------------------------

-- A JOIN_REQ arrived. Returns the member's resulting status ("pending" | "active"), or
-- nil, "removed" if the bookie previously removed them (they stay out until Approve'd).
function Bookie.RequestJoin(book, name, now)
    if not name or name == "" then return nil, "bad_name" end
    local m = book.members[name]
    if m then
        if m.status == "removed" then return nil, "removed" end
        return m.status
    end
    book.members[name] = { status = "pending", requestedAt = now }
    touch(book)
    return "pending"
end

-- pending (or previously removed) -> active.
function Bookie.Approve(book, name, now)
    local m = book.members[name]
    if not m then return nil, "no_member" end
    if m.status == "active" then return m end
    m.status = "active"
    m.joinedAt = now
    touch(book)
    return m
end

-- Deny deletes the pending request, so the player may ask again.
function Bookie.Deny(book, name)
    local m = book.members[name]
    if not m or m.status ~= "pending" then return nil, "not_pending" end
    book.members[name] = nil
    touch(book)
    return true
end

-- Remove marks an active member "removed". Their bets and balance stay on the books.
function Bookie.Remove(book, name)
    local m = book.members[name]
    if not m or m.status ~= "active" then return nil, "not_active" end
    m.status = "removed"
    touch(book)
    return true
end

-- limit in copper, or nil to clear.
function Bookie.SetCreditLimit(book, name, limit)
    local m = book.members[name]
    if not m then return nil, "no_member" end
    if limit ~= nil and not isCopper(limit) then return nil, "bad_limit" end
    m.creditLimit = limit
    touch(book)
    return true
end

------------------------------------------------------------------------------------------
-- Markets
------------------------------------------------------------------------------------------

local function validLine(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

-- spec = { sport, event, type, line, closesAt, selections = { {label=, odds=}, {label=, odds=} } }
-- Selection ids are 1 and 2. For spreads, `line` applies to selection 1.
function Bookie.AddMarket(book, spec, now)
    if type(spec) ~= "table" then return nil, "bad_spec" end
    if not MARKET_TYPES[spec.type] then return nil, "bad_type" end
    if type(spec.event) ~= "string" or spec.event == "" then return nil, "bad_event" end
    if type(spec.closesAt) ~= "number" or spec.closesAt <= now then return nil, "bad_close_time" end
    if spec.type ~= "moneyline" and not validLine(spec.line) then return nil, "bad_line" end
    local sel = spec.selections
    if type(sel) ~= "table" or #sel ~= 2 then return nil, "need_two_selections" end
    local selections = {}
    for i = 1, 2 do
        local s = sel[i]
        if type(s) ~= "table" or type(s.label) ~= "string" or s.label == "" then return nil, "bad_label" end
        if not Odds.IsValid(s.odds) then return nil, "bad_odds" end
        selections[i] = { id = i, label = s.label, odds = s.odds }
    end
    if selections[1].label == selections[2].label then return nil, "duplicate_label" end

    local market = {
        id = nextId(book, "nextMarketId"),
        sport = spec.sport or "",
        event = spec.event,
        type = spec.type,
        line = spec.type ~= "moneyline" and spec.line or nil,
        selections = selections,
        closesAt = spec.closesAt,
        status = "open",
        createdAt = now,
    }
    book.markets[market.id] = market
    touch(book)
    return market
end

local function editable(book, marketId)
    local m = book.markets[marketId]
    if not m then return nil, "no_market" end
    if m.status ~= "open" and m.status ~= "locked" then return nil, "market_final" end
    return m
end

-- changes = { odds = { [selectionId] = americanOdds }, line = n, closesAt = epoch }
-- Validated as a whole before anything changes. Only affects bets placed afterwards.
function Bookie.EditMarket(book, marketId, changes)
    local m, err = editable(book, marketId)
    if not m then return nil, err end
    changes = changes or {}
    if changes.odds then
        for id, odds in pairs(changes.odds) do
            if not m.selections[id] then return nil, "bad_selection" end
            if not Odds.IsValid(odds) then return nil, "bad_odds" end
        end
    end
    if changes.line ~= nil then
        if m.type == "moneyline" or not validLine(changes.line) then return nil, "bad_line" end
    end
    if changes.closesAt ~= nil and type(changes.closesAt) ~= "number" then return nil, "bad_close_time" end

    if changes.odds then
        for id, odds in pairs(changes.odds) do m.selections[id].odds = odds end
    end
    if changes.line ~= nil then m.line = changes.line end
    if changes.closesAt ~= nil then m.closesAt = changes.closesAt end
    touch(book)
    return m
end

function Bookie.Lock(book, marketId)
    local m, err = editable(book, marketId)
    if not m then return nil, err end
    if m.status == "locked" then return m end
    m.status = "locked"
    touch(book)
    return m
end

-- locked -> open, only while the close time is still in the future.
function Bookie.Unlock(book, marketId, now)
    local m, err = editable(book, marketId)
    if not m then return nil, err end
    if m.status == "open" then return m end
    if now >= m.closesAt then return nil, "market_closed" end
    m.status = "open"
    touch(book)
    return m
end

-- Lock every open market whose close time has passed. Returns the list of markets locked, so
-- the caller can broadcast MARKET for each. Cheap; call from a ticker.
function Bookie.Sweep(book, now)
    local locked
    for _, m in pairs(book.markets) do
        if m.status == "open" and now >= m.closesAt then
            m.status = "locked"
            locked = locked or {}
            locked[#locked + 1] = m
        end
    end
    if locked then touch(book) end
    return locked or {}
end

------------------------------------------------------------------------------------------
-- Betting
------------------------------------------------------------------------------------------

-- Copper the bettor currently owes the book (0 if the book owes them) and their open stakes.
function Bookie.Credit(book, player)
    local l = book.ledger[player]
    local owed = (l and l.balance < 0) and -l.balance or 0
    local openRisk = 0
    for _, b in pairs(book.bets) do
        if b.bettor == player and b.status == "accepted" then openRisk = openRisk + b.stake end
    end
    return owed, openRisk
end

-- req = { marketId, selectionId, stake, odds (as the bettor saw them), ref (client nonce) }
-- Returns bet on success. On failure returns nil, reason, extra where:
--   "not_member"      not an active member
--   "no_market"       unknown market id
--   "market_closed"   not open, or past closesAt
--   "bad_selection"   unknown selection id
--   "bad_stake"       not a positive integer of copper
--   "odds_changed"    extra = current odds (UI should re-confirm)
--   "credit_limit"    extra = copper still available under the member's limit
-- A repeated `ref` from the same bettor returns the original bet (idempotent re-ack), so a
-- retried BET_PLACE never double-books.
function Bookie.PlaceBet(book, bettor, req, now)
    local member = book.members[bettor]
    if not member or member.status ~= "active" then return nil, "not_member" end
    if type(req) ~= "table" then return nil, "bad_request" end

    if req.ref ~= nil then
        for _, b in pairs(book.bets) do
            if b.bettor == bettor and b.ref == req.ref then return b end
        end
    end

    local m = book.markets[req.marketId]
    if not m then return nil, "no_market" end
    if m.status ~= "open" or now >= m.closesAt then return nil, "market_closed" end
    local sel = m.selections[req.selectionId]
    if not sel then return nil, "bad_selection" end
    if not isCopper(req.stake) then return nil, "bad_stake" end
    if req.odds ~= sel.odds then return nil, "odds_changed", sel.odds end

    if member.creditLimit then
        local owed, openRisk = Bookie.Credit(book, bettor)
        local available = member.creditLimit - owed - openRisk
        if req.stake > available then return nil, "credit_limit", math.max(0, available) end
    end

    local bet = {
        id = nextId(book, "nextBetId"),
        bettor = bettor,
        marketId = m.id,
        selectionId = sel.id,
        stake = req.stake,
        odds = sel.odds,
        status = "accepted",
        placedAt = now,
        ref = req.ref,
    }
    book.bets[bet.id] = bet
    touch(book)
    return bet
end

------------------------------------------------------------------------------------------
-- Settlement
------------------------------------------------------------------------------------------

-- Undo the ledger effect of an already-settled/voided bet, returning it to "accepted".
local function reverse(book, bet)
    if bet.delta and bet.delta ~= 0 then
        ledgerOf(book, bet.bettor).balance = ledgerOf(book, bet.bettor).balance - bet.delta
    end
    bet.status = "accepted"
    bet.delta = nil
    bet.settledAt = nil
end

local function resolve(book, bet, outcome, now)
    local delta = Odds.Delta(bet.stake, bet.odds, outcome)
    bet.status = outcome
    bet.delta = delta
    bet.settledAt = now
    if delta ~= 0 then
        ledgerOf(book, bet.bettor).balance = ledgerOf(book, bet.bettor).balance + delta
    end
    return delta
end

local function marketBets(book, marketId)
    local list = {}
    for _, b in pairs(book.bets) do
        if b.marketId == marketId and b.status ~= "rejected" then list[#list + 1] = b end
    end
    table.sort(list, function(a, c) return a.id < c.id end)
    return list
end

local FINAL = { won = true, lost = true, push = true, void = true }

-- result = winning selection id, or "push". Works on open, locked, or already-settled/void
-- markets: a wrong result can be corrected by settling again (old effects are reversed first).
-- Returns a list of { bet = bet, delta = copper } so the caller can send BALANCE/chat.
function Bookie.Settle(book, marketId, result, now)
    local m = book.markets[marketId]
    if not m then return nil, "no_market" end
    if result ~= "push" and not m.selections[result] then return nil, "bad_result" end

    local bets = marketBets(book, marketId)
    for _, b in ipairs(bets) do
        if FINAL[b.status] then reverse(book, b) end
    end
    local out = {}
    for _, b in ipairs(bets) do
        local outcome = (result == "push") and "push" or (b.selectionId == result and "won" or "lost")
        out[#out + 1] = { bet = b, delta = resolve(book, b, outcome, now) }
    end
    m.status = "settled"
    m.result = result
    m.settledAt = now
    touch(book)
    return out
end

-- Void a whole market: every bet on it is refunded (delta 0). Also reverses a prior settlement.
function Bookie.VoidMarket(book, marketId, now)
    local m = book.markets[marketId]
    if not m then return nil, "no_market" end
    local bets = marketBets(book, marketId)
    for _, b in ipairs(bets) do
        if FINAL[b.status] then reverse(book, b) end
    end
    local out = {}
    for _, b in ipairs(bets) do
        out[#out + 1] = { bet = b, delta = resolve(book, b, "void", now) }
    end
    m.status = "void"
    m.result = nil
    m.settledAt = now
    touch(book)
    return out
end

-- Void a single bet (reverses its settlement if it had one).
function Bookie.VoidBet(book, betId, now)
    local b = book.bets[betId]
    if not b then return nil, "no_bet" end
    if FINAL[b.status] then reverse(book, b) end
    if b.status ~= "accepted" then return nil, "bad_status" end
    resolve(book, b, "void", now)
    touch(book)
    return b
end

------------------------------------------------------------------------------------------
-- Ledger
------------------------------------------------------------------------------------------

function Bookie.Balance(book, player)
    local l = book.ledger[player]
    return l and l.balance or 0
end

-- direction "in":  the player paid the book `amount` (balance goes up toward zero/positive).
-- direction "out": the book paid the player `amount` (balance goes down).
-- payments[] stores the signed change to the player's balance. Returns the new balance.
function Bookie.RecordPayment(book, player, direction, amount, note, now)
    if not book.members[player] and not book.ledger[player] then return nil, "no_member" end
    if not isCopper(amount) then return nil, "bad_amount" end
    if direction ~= "in" and direction ~= "out" then return nil, "bad_direction" end
    local delta = direction == "in" and amount or -amount
    local l = ledgerOf(book, player)
    l.balance = l.balance + delta
    l.payments[#l.payments + 1] = { amount = delta, at = now, note = note }
    touch(book)
    return l.balance
end

------------------------------------------------------------------------------------------
-- Reporting and sync
------------------------------------------------------------------------------------------

-- The bookie's net result per outcome of a market, over accepted bets:
-- { staked = total copper, net = { [selectionId] = copper, push = 0 } }
-- net[i] > 0 means the book wins that much if selection i wins; < 0 means it pays out.
function Bookie.MarketExposure(book, marketId)
    local m = book.markets[marketId]
    if not m then return nil, "no_market" end
    local staked, net = 0, { push = 0 }
    for i in ipairs(m.selections) do net[i] = 0 end
    for _, b in ipairs(marketBets(book, marketId)) do
        if b.status == "accepted" then
            staked = staked + b.stake
            local profit = Odds.Profit(b.stake, b.odds)
            for i in ipairs(m.selections) do
                net[i] = net[i] + (b.selectionId == i and -profit or b.stake)
            end
        end
    end
    return { staked = staked, net = net }
end

-- State for one bettor (the SYNC payload, minus protocol envelope). Contains references into
-- the book: serialize it, don't mutate it.
function Bookie.Snapshot(book, player, now)
    local markets, included = {}, {}
    for id, m in pairs(book.markets) do
        local live = m.status == "open" or m.status == "locked"
        if live or (m.settledAt and m.settledAt >= now - SETTLED_KEEP) then
            markets[#markets + 1] = m
            included[id] = true
        end
    end
    table.sort(markets, function(a, c) return a.id < c.id end)

    local bets = {}
    for _, b in pairs(book.bets) do
        if b.bettor == player and included[b.marketId] then bets[#bets + 1] = b end
    end
    table.sort(bets, function(a, c) return a.id < c.id end)

    local l = book.ledger[player]
    local payments = {}
    if l then
        for i = math.max(1, #l.payments - PAYMENTS_KEEP + 1), #l.payments do
            payments[#payments + 1] = l.payments[i]
        end
    end
    local member = book.members[player]
    return {
        rev = book.rev,
        markets = markets,
        bets = bets,
        balance = l and l.balance or 0,
        payments = payments,
        creditLimit = member and member.creditLimit or nil,
    }
end

return Bookie
