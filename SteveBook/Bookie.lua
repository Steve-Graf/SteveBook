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
local PAYMENTS_KEEP = 20             -- snapshots include this many recent payments
local BET_HISTORY_KEEP = 14 * 24 * 3600   -- snapshots include settled/void bets settled within this window

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

-- closesAt is the game's start. A game that has started takes no bets, so from then on only
-- Settle and Void remain: no edits, no extending the close time, no reopening.
-- "open" can lag behind the clock until Sweep runs, so the time is checked as well as the status.
function Bookie.HasStarted(market, now) return now >= market.closesAt end

-- True while the market takes bets: status "open" and the game has not started.
function Bookie.IsBettable(market, now)
    return market.status == "open" and now < market.closesAt
end

-- "open" | "locked" | "settled" | "void". A market still marked "open" past closesAt reads as "locked".
function Bookie.EffectiveStatus(market, now)
    if market.status == "open" and now >= market.closesAt then return "locked" end
    return market.status
end

-- changes = { odds = { [selectionId] = americanOdds }, line = n, closesAt = epoch }
-- Validated as a whole before anything changes. Only affects bets placed afterwards.
-- `now` is required. Refused with "market_closed" once the game has started (any change, including
-- a later closesAt); a new closesAt must still be in the future ("bad_close_time").
function Bookie.EditMarket(book, marketId, changes, now)
    if type(now) ~= "number" then return nil, "bad_time" end
    local m, err = editable(book, marketId)
    if not m then return nil, err end
    if Bookie.HasStarted(m, now) then return nil, "market_closed" end
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
    if changes.closesAt ~= nil and (type(changes.closesAt) ~= "number" or changes.closesAt <= now) then
        return nil, "bad_close_time"
    end

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

-- locked -> open, only while the close time is still in the future. Once the game has started
-- this is always refused, even for a market whose stored status still says "open".
function Bookie.Unlock(book, marketId, now)
    local m, err = editable(book, marketId)
    if not m then return nil, err end
    if Bookie.HasStarted(m, now) then return nil, "market_closed" end
    if m.status == "open" then return m end
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
--   "bad_stake"       fails Odds.StakeCheck (whole silver, at most Odds.MAX_STAKE)
--   "odds_changed"    extra = current odds (UI should re-confirm)
--   "credit_limit"    extra = copper still available under the member's limit
-- A repeated `ref` from the same bettor returns the original bet plus a third value `true`
-- (idempotent re-ack: the caller re-sends BET_ACK but must not treat it as a new bet), so a
-- retried BET_PLACE never double-books.
function Bookie.PlaceBet(book, bettor, req, now)
    local member = book.members[bettor]
    if not member or member.status ~= "active" then return nil, "not_member" end
    if type(req) ~= "table" then return nil, "bad_request" end

    if req.ref ~= nil then
        for _, b in pairs(book.bets) do
            if b.bettor == bettor and b.ref == req.ref then return b, nil, true end
        end
    end

    local m = book.markets[req.marketId]
    if not m then return nil, "no_market" end
    if m.status ~= "open" or now >= m.closesAt then return nil, "market_closed" end
    local sel = m.selections[req.selectionId]
    if not sel then return nil, "bad_selection" end
    if not Odds.StakeCheck(req.stake) then return nil, "bad_stake" end   -- shared rule: whole silver, max 1g
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
        -- A bet the bookie voided on its own (bet.voided) stays void when its market is settled
        -- or voided later; only a market-level void is undone by re-settling.
        if b.marketId == marketId and b.status ~= "rejected" and not b.voided then list[#list + 1] = b end
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
    b.voided = true      -- sticky: later Settle/VoidMarket on its market leave it alone
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
-- Bets: this player's open bets, always, plus settled/void bets from the last BET_HISTORY_KEEP
-- (a bet settled exactly that long ago is kept). The balance is absolute, so dropping old history
-- never changes it. Markets: those that still take bets (open and before closesAt), plus every
-- market one of the INCLUDED bets refers to, whatever its status (so My Bets can name the event).
-- Games that have started or finished are never presented to bettors who did not bet on them.
-- Why the cap: a SYNC grows ~260 bytes per bet and ChatThrottleLib moves ~800 bytes/s.
function Bookie.Snapshot(book, player, now)
    local bets, bettedOn = {}, {}
    for _, b in pairs(book.bets) do
        if b.bettor == player and (b.status == "accepted" or (b.settledAt or now) >= now - BET_HISTORY_KEEP) then
            bets[#bets + 1] = b
            bettedOn[b.marketId] = true
        end
    end
    table.sort(bets, function(a, c) return a.id < c.id end)

    local markets = {}
    for id, m in pairs(book.markets) do
        if bettedOn[id] or Bookie.IsBettable(m, now) then markets[#markets + 1] = m end
    end
    table.sort(markets, function(a, c) return a.id < c.id end)

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


------------------------------------------------------------------------------------------
-- Messages (SPEC §5, shapes in Protocol.lua). Still pure: nothing here sends anything.
-- Handlers and builders return outbound messages for the Comm glue (UI/Bookie.lua) to send:
--     { type = "BET_ACK", payload = { ... }, to = "Name" }
-- `to = nil` means broadcast on the book channel. Glue does:
--     Comm.Send(m.type, m.payload, book.code, m.to)
-- Handle also returns a list of UI events: { kind = "join_request" | "bet" | "bet_rejected", ... }.
------------------------------------------------------------------------------------------

local function syncPayload(book, player, now)
    local s = Bookie.Snapshot(book, player, now)
    s.bookName = book.name
    return s
end

-- Handle a message from a bettor. `sender` is the name Comm delivered it from (members are
-- keyed by exactly that string); `payload` has already passed Protocol.Validate.
-- Returns out, events.
function Bookie.Handle(book, sender, msgType, payload, now)
    local out, events = {}, {}
    local function reply(t, p) out[#out + 1] = { type = t, payload = p, to = sender } end
    local member = book.members[sender]
    payload = payload or {}

    if msgType == "JOIN_REQ" then
        local known = member ~= nil
        local status, err = Bookie.RequestJoin(book, sender, now)
        if status == "active" then
            reply("JOIN_OK", { bookName = book.name, ownerName = book.ownerName or "", rev = book.rev })
        elseif status == "pending" then
            -- no reply: the bettor waits until the bookie approves or denies
            if not known then events[#events + 1] = { kind = "join_request", name = sender } end
        else
            reply("JOIN_DENY", { reason = err, ownerName = book.ownerName or "" })
        end

    elseif msgType == "SYNC_REQ" then
        if member and member.status == "active" then
            reply("SYNC", syncPayload(book, sender, now))
        elseif member and member.status == "pending" then
            -- ignored; the bettor stays "requested"
        else
            reply("JOIN_DENY", { reason = "not_member", ownerName = book.ownerName or "" })
        end

    elseif msgType == "BET_PLACE" then
        local bet, reason, extra = Bookie.PlaceBet(book, sender, {
            marketId = payload.marketId, selectionId = payload.selectionId,
            stake = payload.stake, odds = payload.odds, ref = payload.ref,
        }, now)
        if bet then
            reply("BET_ACK", { ref = payload.ref, bet = bet, balance = Bookie.Balance(book, sender) })
            if not extra then events[#events + 1] = { kind = "bet", bet = bet } end   -- extra = repeat of an earlier ref
        else
            local r = { ref = payload.ref, reason = reason }
            if reason == "odds_changed" then r.currentOdds = extra end
            if reason == "credit_limit" then r.available = extra end
            reply("BET_REJECT", r)
            events[#events + 1] = { kind = "bet_rejected", name = sender, reason = reason }
        end

    elseif msgType == "PING" then
        reply("PONG", { rev = book.rev })
    end
    return out, events
end

-- MARKET broadcast after AddMarket / EditMarket / Lock / Unlock / Settle / Void, and for each
-- market SweepMarkets returns. The market is sent whole (status + result included).
function Bookie.MarketMessage(book, market)
    return { type = "MARKET", payload = { rev = book.rev, market = market } }
end

-- Names of the bettors touched by a Settle/VoidMarket result list (sorted, distinct).
function Bookie.AffectedBettors(results)
    local seen, names = {}, {}
    for _, r in ipairs(results) do
        if not seen[r.bet.bettor] then
            seen[r.bet.bettor] = true
            names[#names + 1] = r.bet.bettor
        end
    end
    table.sort(names)
    return names
end

-- A fresh full SYNC for each named bettor (active members only). Send these after a settle,
-- void or bet correction: bet statuses and balances changed, and MARKET alone doesn't carry bets.
function Bookie.SyncMessages(book, names, now)
    local out = {}
    for _, name in ipairs(names) do
        local m = book.members[name]
        if m and m.status == "active" then
            out[#out + 1] = { type = "SYNC", payload = syncPayload(book, name, now), to = name }
        end
    end
    return out
end

-- Small balance notice for one bettor, e.g. after RecordPayment. `note` is shown in chat.
function Bookie.BalanceMessage(book, player, note)
    return { type = "BALANCE", to = player,
             payload = { rev = book.rev, balance = Bookie.Balance(book, player), note = note } }
end


------------------------------------------------------------------------------------------
-- Form parsing for the window (pure, so it is testable). Errors are readable sentences.
------------------------------------------------------------------------------------------

local function trim(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end

local function parseLine(s)
    s = trim(s)
    if not (s:match("^[+-]?%d+%.?%d*$") or s:match("^[+-]?%.%d+$")) then return nil end
    return tonumber(s)
end

local ODDS_HELP = "Odds look like -110 or +150 (nothing between -99 and +99)."
local LINE_HELP = "Line must be a number, e.g. -3.5 or 47.5."
local CLOSE_HELP = "Closes in: use 30m, 2h, 1d or 1h30m."

-- "30m", "2h", "1d", "1h30m" -> seconds. A bare number means minutes. nil if invalid or zero.
function Bookie.ParseDuration(str)
    if type(str) ~= "string" then return nil end
    local s = str:lower():gsub("%s+", "")
    if s == "" then return nil end
    if s:match("^%d+$") then s = s .. "m" end
    local mult = { d = 86400, h = 3600, m = 60 }
    local total, pos, seen = 0, 1, {}
    while pos <= #s do
        local num, unit, nextPos = s:match("^(%d+)([dhm])()", pos)
        if not num or seen[unit] then return nil end
        seen[unit] = true
        total = total + tonumber(num) * mult[unit]
        pos = nextPos
    end
    if total <= 0 then return nil end
    return total
end

-- f = { sport, event, type, line, label1, odds1, label2, odds2, closes } (all strings, from
-- edit boxes; type is "moneyline"|"spread"|"total"; `closes` is a duration from now).
-- Returns a spec for AddMarket, or nil, message.
function Bookie.ParseMarketForm(f, now)
    local event = trim(f.event)
    if event == "" then return nil, "Event is required, e.g. PHI @ DAL." end
    if not MARKET_TYPES[f.type] then return nil, "Pick a market type." end
    local label1, label2 = trim(f.label1), trim(f.label2)
    if label1 == "" or label2 == "" then return nil, "Both sides need a name." end
    -- "|" starts an escape code in WoW text, and these names are shown in every bettor's window
    if (trim(f.sport) .. event .. label1 .. label2):find("|", 1, true) then
        return nil, "Names can't contain the | character."
    end
    if label1 == label2 then return nil, "The two sides need different names." end
    local odds1, odds2 = Odds.Parse(f.odds1), Odds.Parse(f.odds2)
    if not odds1 or not odds2 then return nil, ODDS_HELP end
    local line
    if f.type ~= "moneyline" then
        line = parseLine(f.line)
        if not line then return nil, LINE_HELP end
    end
    local secs = Bookie.ParseDuration(f.closes)
    if not secs then return nil, CLOSE_HELP end
    return {
        sport = trim(f.sport), event = event, type = f.type, line = line, closesAt = now + secs,
        selections = { { label = label1, odds = odds1 }, { label = label2, odds = odds2 } },
    }
end

-- f = { odds1, odds2, line, closes }. Blank or unchanged fields are left alone.
-- Returns a `changes` table for EditMarket, or nil, message.
function Bookie.ParseEditForm(market, f, now)
    local changes, odds = {}, {}
    for i = 1, 2 do
        local s = trim(f["odds" .. i])
        if s ~= "" then
            local v = Odds.Parse(s)
            if not v then return nil, ODDS_HELP end
            if v ~= market.selections[i].odds then odds[i] = v end
        end
    end
    if next(odds) then changes.odds = odds end
    if market.type ~= "moneyline" and trim(f.line) ~= "" then
        local line = parseLine(f.line)
        if not line then return nil, LINE_HELP end
        if line ~= market.line then changes.line = line end
    end
    if trim(f.closes) ~= "" then
        local secs = Bookie.ParseDuration(f.closes)
        if not secs then return nil, CLOSE_HELP end
        changes.closesAt = now + secs
    end
    if next(changes) == nil then return nil, "Nothing to change." end
    return changes
end

-- Credit-limit input: blank = remove the limit. Returns copper, or nil (cleared), or false, message.
function Bookie.ParseLimit(text, parseMoney)
    if trim(text) == "" then return nil end
    local c = parseMoney(text)
    if not c or c <= 0 then return false, "Enter an amount like 50g, or leave blank for no limit." end
    return c
end


------------------------------------------------------------------------------------------
-- View helpers for the Ledger and Bets tabs (pure, so they are testable)
------------------------------------------------------------------------------------------

-- Payment input: copper, or false, message. (Unlike ParseLimit, blank is an error.)
function Bookie.ParseAmount(text, parseMoney)
    local c = parseMoney(text)
    if not c or c <= 0 then return false, "Enter an amount like 250g or 12g 50s." end
    return c
end

-- One row per player who matters to the ledger: active members, plus anyone with a balance,
-- open bets or payment history. Biggest balances (either direction) first.
-- Row: { name, status = member status or "unknown", balance, openRisk, payments = count }.
-- balance < 0 means the player owes the book; > 0 means the book owes the player.
function Bookie.LedgerRows(book)
    local seen, rows = {}, {}
    local function add(name)
        if seen[name] then return end
        seen[name] = true
        local l, m = book.ledger[name], book.members[name]
        local balance = l and l.balance or 0
        local _, openRisk = Bookie.Credit(book, name)
        local payments = l and #l.payments or 0
        if (m and m.status == "active") or balance ~= 0 or openRisk > 0 or payments > 0 then
            rows[#rows + 1] = { name = name, status = m and m.status or "unknown",
                                balance = balance, openRisk = openRisk, payments = payments }
        end
    end
    for name in pairs(book.members) do add(name) end
    for name in pairs(book.ledger) do add(name) end
    table.sort(rows, function(a, b)
        local x, y = math.abs(a.balance), math.abs(b.balance)
        if x ~= y then return x > y end
        return a.name < b.name
    end)
    return rows
end

-- { owedToBook = what players owe you, owedByBook = what you owe players, net = owedToBook - owedByBook }
function Bookie.LedgerTotals(book)
    local toBook, byBook = 0, 0
    for _, l in pairs(book.ledger) do
        if l.balance < 0 then toBook = toBook - l.balance else byBook = byBook + l.balance end
    end
    return { owedToBook = toBook, owedByBook = byBook, net = toBook - byBook }
end

Bookie.BET_STATUSES = { "accepted", "won", "lost", "push", "void" }

-- Bets matching filter = { status, bettor, marketId } (each optional), newest first.
function Bookie.ListBets(book, filter)
    filter = filter or {}
    local list = {}
    for _, b in pairs(book.bets) do
        if (not filter.status or b.status == filter.status)
           and (not filter.bettor or b.bettor == filter.bettor)
           and (not filter.marketId or b.marketId == filter.marketId) then
            list[#list + 1] = b
        end
    end
    table.sort(list, function(a, b) return a.id > b.id end)
    return list
end

-- Values the Bets tab can filter on: { bettors = sorted names, markets = ascending ids }.
function Bookie.BetFilterChoices(book)
    local bettors, markets, seenB, seenM = {}, {}, {}, {}
    for _, b in pairs(book.bets) do
        if not seenB[b.bettor] then seenB[b.bettor] = true; bettors[#bettors + 1] = b.bettor end
        if not seenM[b.marketId] then seenM[b.marketId] = true; markets[#markets + 1] = b.marketId end
    end
    table.sort(bettors)
    table.sort(markets)
    return { bettors = bettors, markets = markets }
end

-- Next value in a cycle: nil -> list[1] -> list[2] ... -> nil. A value no longer in the list
-- (e.g. the filtered bettor was removed) starts over at nil.
function Bookie.CycleFilter(list, current)
    if current == nil then return list[1] end
    for i, v in ipairs(list) do
        if v == current then return list[i + 1] end
    end
    return nil
end

return Bookie
