-- Casino.lua: the HOST side of a casino table (SPEC §11). Pure logic: no WoW API calls, so it is
-- testable with plain lua5.1. The host's client is the authority: players only ask.
--
-- A table (kept in SteveBookDB.casino.tables[code]; the host's own saved data):
--   { code, game, name, hostName, createdAt, zero, minBet, maxBet,
--     status = "betting" | "spinning" | "closed", round, rev, nextBetId,
--     auto = true when automatic rounds are on, autoAt = server time the bets lock (see Casino.AutoTick),
--     autoSeconds = delay after the first bet (default AUTO_SECONDS; 0 = at once), house = a one-seat house table (House.lua),
--     members = { [name] = { status = "pending"|"seated"|"left"|"kicked"|"denied", requestedAt,
--                            joinedAt, balance, bought, bets = { {id, ref, kind, numbers?, pick?, amount} } } },
--     history = { newest-first pocket numbers }, lastResult = { round, number, results, at } }
-- Chips are copper and are the TABLE's own credit: the host allots them (Admit / Adjust) and a bet
-- takes its amount out of the balance at once (it sits on the table); a result pays winners back.
-- `bought` is the net chips the host has given the player, so balance - bought is their result.
-- Handle() returns outbound messages like Bookie.Handle: { type, payload, to = name }.
local ADDON, ns = ...
ns = ns or {}

local Casino = {}
ns.Casino = Casino

local Odds, Roulette = ns.Odds, ns.Roulette

Casino.GAMES = {
    roulette  = { title = "Roulette",  prefix = "RLT", ready = true },
    blackjack = { title = "Blackjack", prefix = "BJK", ready = true },
}
-- Per-game round logic (everything except roulette, which lives in this file): a game registers
-- Casino.Engines[game] = { Init, PlaceBet, ClearBets, OnRemoved, OnClosed, Recover, Public, ... }.
Casino.Engines = {}
local function engine(t) return Casino.Engines[t.game] end
Casino.GAME_ORDER = { "roulette", "blackjack" }
Casino.MAX_SEATS = { roulette = 12, blackjack = 5 }       -- seats per table (blackjack shows five rows)
Casino.HISTORY_KEEP = 12
Casino.SPIN_SECONDS = 3
Casino.DEFAULT_MIN_BET = 100                 -- 1s
Casino.DEFAULT_MAX_BET = 10000               -- 1g
Casino.MAX_BET_CAP = 100000                  -- 10g: the most a host may set as a table maximum
Casino.AUTO_SECONDS = 20                     -- automatic rounds: bets lock this long after the round's first bet

local function touch(t) t.rev = (t.rev or 0) + 1 end
local function wholeSilver(n) return type(n) == "number" and n == math.floor(n) and n % Odds.STAKE_STEP == 0 end

------------------------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------------------------

function Casino.Ensure(db)
    db.casino = db.casino or {}
    db.casino.tables = db.casino.tables or {}
    return db.casino
end

function Casino.Find(db, code)
    local c = db.casino
    if not (c and c.tables) then return nil end
    return c.tables[ns.Protocol.CanonicalCode(code)]
end

-- Hosted tables, oldest first.
function Casino.List(db)
    local list = {}
    local c = db.casino
    for _, t in pairs(c and c.tables or {}) do list[#list + 1] = t end
    table.sort(list, function(a, b)
        if (a.createdAt or 0) ~= (b.createdAt or 0) then return (a.createdAt or 0) < (b.createdAt or 0) end
        return a.code < b.code
    end)
    return list
end

-- Check table settings. Returns true, or false, message.
function Casino.CheckLimits(minBet, maxBet)
    if not wholeSilver(minBet) or minBet < Odds.STAKE_STEP then return false, "The minimum bet is a whole number of silver." end
    if not wholeSilver(maxBet) then return false, "The maximum bet is a whole number of silver." end
    if maxBet < minBet then return false, "The maximum bet is below the minimum." end
    if maxBet > Casino.MAX_BET_CAP then
        return false, "The maximum bet cannot be more than " .. Odds.FormatMoney(Casino.MAX_BET_CAP) .. "."
    end
    return true
end

-- spec = { game, name, zero, minBet, maxBet }. Returns the table, or nil, message.
function Casino.Create(db, spec, hostName, now, rand)
    spec = spec or {}
    local game = Casino.GAMES[spec.game]
    if not game then return nil, "Unknown game." end
    if not game.ready then return nil, game.title .. " is not available yet." end
    local zero
    if spec.game == "roulette" then
        zero = spec.zero or "single"
        if zero ~= "single" and zero ~= "double" and zero ~= "none" then return nil, "Pick a wheel: single, double or none." end
    end
    local minBet = spec.minBet or Casino.DEFAULT_MIN_BET
    local maxBet = spec.maxBet or Casino.DEFAULT_MAX_BET
    local ok, msg = Casino.CheckLimits(minBet, maxBet)
    if not ok then return nil, msg end
    if not hostName or hostName == "" then return nil, "No host name." end
    local c = Casino.Ensure(db)
    local code = ns.Model.GenerateCode(game.prefix, function(x) return c.tables[x] ~= nil end, rand)
    local name = (spec.name or ""):match("^%s*(.-)%s*$")
    if name == "" then name = game.title end
    local t = {
        code = code, game = spec.game, name = name:sub(1, 40), hostName = hostName, createdAt = now,
        zero = zero, minBet = minBet, maxBet = maxBet,
        status = "betting", round = 1, rev = 1, nextBetId = 1, maxSeats = Casino.MAX_SEATS[spec.game],
        members = {}, history = {},
    }
    c.tables[code] = t
    local e = engine(t)
    if e and e.Init then e.Init(t) end
    return t
end

function Casino.Delete(db, code)
    local c = db.casino
    if c and c.tables then c.tables[ns.Protocol.CanonicalCode(code)] = nil end
end

function Casino.SetLimits(t, minBet, maxBet)
    local ok, msg = Casino.CheckLimits(minBet, maxBet)
    if not ok then return nil, msg end
    t.minBet, t.maxBet = minBet, maxBet
    touch(t)
    return true
end

------------------------------------------------------------------------------------------
-- Members and chips
------------------------------------------------------------------------------------------

local function refund(m)
    for _, b in ipairs(m.bets) do m.balance = m.balance + b.amount end
    m.bets = {}
end
Casino.Refund = refund

-- Names of seated members, sorted.
function Casino.Seated(t)
    local list = {}
    for name, m in pairs(t.members) do if m.status == "seated" then list[#list + 1] = name end end
    table.sort(list)
    return list
end

-- Names of pending requests, oldest first.
function Casino.Pending(t)
    local list = {}
    for name, m in pairs(t.members) do if m.status == "pending" then list[#list + 1] = name end end
    table.sort(list, function(a, b)
        local ra, rb = t.members[a].requestedAt or 0, t.members[b].requestedAt or 0
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    return list
end

-- A player asks for a seat. Returns the member's status, or nil, reason ("closed" | "removed").
function Casino.RequestJoin(t, name, now)
    if not name or name == "" then return nil, "bad_name" end
    if t.status == "closed" then return nil, "closed" end
    local m = t.members[name]
    if m then
        if m.status == "kicked" then return nil, "removed" end
        if m.status == "left" or m.status == "denied" then
            m.status = "pending"; m.requestedAt = now; touch(t)
        end
        return m.status
    end
    t.members[name] = { status = "pending", requestedAt = now, balance = 0, bought = 0, bets = {} }
    touch(t)
    return "pending"
end

-- Let a player sit, optionally with starting chips (whole silver). Returns the member, or nil, reason.
function Casino.Admit(t, name, chips, now)
    local m = t.members[name]
    if not m then return nil, "no_member" end
    if m.status ~= "seated" and #Casino.Seated(t) >= (t.maxSeats or Casino.MAX_SEATS[t.game] or 12) then return nil, "full" end
    if m.status == "kicked" and not chips then chips = 0 end   -- the host may take a kicked player back
    chips = chips or 0
    if not (type(chips) == "number" and chips >= 0 and chips == math.floor(chips)) then return nil, "bad_amount" end
    if chips > 0 and not wholeSilver(chips) then return nil, "bad_amount" end
    if m.status ~= "seated" then m.status = "seated"; m.joinedAt = now end
    m.balance = m.balance + chips
    m.bought = m.bought + chips
    touch(t)
    return m
end

-- Refuse a pending request (they may ask again).
function Casino.Deny(t, name)
    local m = t.members[name]
    if not m or m.status ~= "pending" then return nil, "not_pending" end
    m.status = "denied"
    touch(t)
    return true
end

-- Remove a seated player: their open bets are returned to their balance first. Returns true.
function Casino.Kick(t, name)
    local m = t.members[name]
    if not m then return nil, "no_member" end
    refund(m)
    m.status = "kicked"
    local e = engine(t)
    if e and e.OnRemoved then e.OnRemoved(t, name) end
    touch(t)
    return true
end

-- A player stands up on their own. Their chips stay on the books for the host to pay out.
function Casino.Leave(t, name)
    local m = t.members[name]
    if not m or m.status ~= "seated" then return nil, "not_seated" end
    refund(m)
    m.status = "left"
    local e = engine(t)
    if e and e.OnRemoved then e.OnRemoved(t, name) end
    touch(t)
    return true
end

-- Add (delta > 0) or take away (delta < 0) chips from a seated player. Whole silver. Returns the
-- new balance, or nil, reason.
function Casino.Adjust(t, name, delta)
    local m = t.members[name]
    if not m or m.status ~= "seated" then return nil, "not_seated" end
    if not (wholeSilver(delta) and delta ~= 0) then return nil, "bad_amount" end
    if m.balance + delta < 0 then return nil, "no_balance", m.balance end
    m.balance = m.balance + delta
    m.bought = m.bought + delta
    touch(t)
    return m.balance
end

------------------------------------------------------------------------------------------
-- Betting
------------------------------------------------------------------------------------------

local function copyBet(b)
    local c = { kind = b.kind, amount = b.amount, pick = b.pick, id = b.id }
    if b.numbers then
        c.numbers = {}
        for i, n in ipairs(b.numbers) do c.numbers[i] = n end
        table.sort(c.numbers)
    end
    return c
end

-- A bet for the current round. Returns the stored bet, or nil, reason, extra:
--   "not_seated", "round_closed", "bad_bet", "min_bet"/"max_bet" (extra = the limit),
--   "no_balance" (extra = chips on hand). A repeated `ref` returns the original bet and true.
function Casino.PlaceBet(t, name, round, bet, ref)
    local e = engine(t)
    if e and e.PlaceBet then return e.PlaceBet(t, name, round, bet, ref) end
    local m = t.members[name]
    if not m or m.status ~= "seated" then return nil, "not_seated" end
    if ref ~= nil then
        for _, b in ipairs(m.bets) do if b.ref == ref then return b, nil, true end end
    end
    if t.status ~= "betting" or round ~= t.round then return nil, "round_closed" end
    local ok = Roulette.ValidateBet(bet, t.zero)
    if not ok then return nil, "bad_bet" end
    if not wholeSilver(bet.amount) then return nil, "bad_bet" end
    if bet.amount < t.minBet then return nil, "min_bet", t.minBet end
    if bet.amount > t.maxBet then return nil, "max_bet", t.maxBet end
    if m.balance < bet.amount then return nil, "no_balance", m.balance end

    local stored = copyBet(bet)
    stored.id = t.nextBetId
    stored.ref = ref
    t.nextBetId = t.nextBetId + 1
    m.balance = m.balance - bet.amount
    m.bets[#m.bets + 1] = stored
    touch(t)
    return stored
end

-- Take back every bet this round. Returns how many chips went back, or nil, "round_closed".
function Casino.ClearBets(t, name, round)
    local e = engine(t)
    if e and e.ClearBets then return e.ClearBets(t, name, round) end
    local m = t.members[name]
    if not m or m.status ~= "seated" then return nil, "not_seated" end
    if t.status ~= "betting" or round ~= t.round then return nil, "round_closed" end
    local back = 0
    for _, b in ipairs(m.bets) do back = back + b.amount end
    refund(m)
    if back > 0 then touch(t) end
    return back
end

-- Total chips a member has on the table this round.
function Casino.Staked(m)
    local n = 0
    for _, b in ipairs(m.bets) do n = n + b.amount end
    return n
end

------------------------------------------------------------------------------------------
-- Rounds
------------------------------------------------------------------------------------------

-- Betting stops; the glue waits Casino.SPIN_SECONDS, then calls Finish.
function Casino.BeginSpin(t, now)
    if t.status ~= "betting" then return nil, "not_betting" end
    t.status = "spinning"
    t.spinAt = now
    t.autoAt = nil                                   -- a manual spin cancels the automatic countdown
    touch(t)
    return true
end

-- Automatic rounds (the host's setting, t.auto): Casino.AUTO_SECONDS after the first bet of a round the
-- bets lock and the hand or spin starts by itself. Later bets do not move the deadline. If every bet is
-- taken back the countdown is dropped, and it starts again with the next bet. The countdown (t.autoAt,
-- server time) is part of the public state so players can show it; a reload forgets it (see Recover).
function Casino.SetAuto(t, on)
    on = on and true or false
    if (t.auto == true) == on then return on end
    t.auto = on or nil
    t.autoAt = nil
    touch(t)
    return on
end

local function anyBets(t)
    for _, name in ipairs(Casino.Seated(t)) do
        if #t.members[name].bets > 0 then return true end
    end
    return false
end

-- Called about once a second and after every player message. Returns what changed:
--   "armed"   the first bet is in: the countdown just started (broadcast the state)
--   "cleared" the countdown was dropped (everyone took their bets back, or the setting went off)
--   "start"   the countdown is over: the caller starts the round (Spin or Deal), which clears it
--   nil       nothing to do
function Casino.AutoTick(t, now)
    if not (t.auto and t.status == "betting" and anyBets(t)) then
        if t.autoAt then t.autoAt = nil; touch(t); return "cleared" end
        return nil
    end
    if not t.autoAt then
        local secs = t.autoSeconds or Casino.AUTO_SECONDS      -- a house table (SPEC §11a) goes at once: 0
        if secs <= 0 then return "start" end
        t.autoAt = now + secs
        touch(t)
        return "armed"
    end
    if now >= t.autoAt then return "start" end
    return nil
end

function Casino.PickNumber(t, rng) return Roulette.Spin(t.zero, rng) end

-- Pay out `number`, record it and open the next round. Returns the result record.
function Casino.Finish(t, number, now)
    if t.status ~= "spinning" then return nil, "not_spinning" end
    local results = {}
    for _, name in ipairs(Casino.Seated(t)) do
        local m = t.members[name]
        if #m.bets > 0 then
            local s = Roulette.Settle(m.bets, number)
            local bets = {}
            for i, b in ipairs(m.bets) do
                local c = copyBet(b)
                c.win = s.wins[i]
                bets[i] = c
            end
            m.balance = m.balance + s.returned
            m.bets = {}
            results[#results + 1] = { name = name, net = s.net, balance = m.balance, bets = bets }
        end
    end
    table.insert(t.history, 1, number)
    while #t.history > Casino.HISTORY_KEEP do table.remove(t.history) end
    t.lastResult = { round = t.round, number = number, results = results, at = now }
    t.round = t.round + 1
    t.status = "betting"
    t.spinAt = nil
    touch(t)
    return t.lastResult
end

-- Close the table: every open bet goes back to its owner. Balances stay for the host to pay out.
function Casino.Close(t)
    for _, m in pairs(t.members) do refund(m) end
    local e = engine(t)
    if e and e.OnClosed then e.OnClosed(t) end
    t.autoAt = nil
    t.status = "closed"
    touch(t)
    return true
end

-- After a /reload or login: a spin that never finished is cancelled and the bets returned.
function Casino.Recover(db)
    for _, t in pairs(db.casino and db.casino.tables or {}) do
        local e = engine(t)
        t.autoAt = nil                                   -- the automatic countdown starts afresh once bets are seen again
        if e and e.Recover then
            e.Recover(t)
        elseif t.status == "spinning" then
            for _, m in pairs(t.members) do refund(m) end
            t.status = "betting"
            t.spinAt = nil
            touch(t)
        end
    end
end

-- What the host owes / is owed: per seated or departed member { name, balance, bought, result }.
function Casino.Ledger(t)
    local list = {}
    for name, m in pairs(t.members) do
        if m.status == "seated" or m.status == "left" or m.status == "kicked" then
            local chips = m.balance + Casino.Staked(m)
            list[#list + 1] = { name = name, status = m.status, chips = chips, bought = m.bought, result = chips - m.bought }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Roulette: what the house stands to win or lose on this round's bets, for the host's window.
-- Returns { staked, bettors, worst = { number, net }, best = { number, net } } where net is the house's
-- result if that pocket comes up (negative = the house pays out more than it takes in).
function Casino.Exposure(t)
    if t.game ~= "roulette" then return nil end
    local bets, staked, bettors = {}, 0, 0
    for _, name in ipairs(Casino.Seated(t)) do
        local m = t.members[name]
        if #m.bets > 0 then bettors = bettors + 1 end
        for _, b in ipairs(m.bets) do bets[#bets + 1] = b; staked = staked + b.amount end
    end
    local out = { staked = staked, bettors = bettors }
    if #bets == 0 then return out end
    for _, pocket in ipairs(Roulette.Pockets(t.zero)) do
        local net = -Roulette.Settle(bets, pocket).net                -- the house's side of the table
        if not out.worst or net < out.worst.net then out.worst = { number = pocket, net = net } end
        if not out.best or net > out.best.net then out.best = { number = pocket, net = net } end
    end
    return out
end

------------------------------------------------------------------------------------------
-- Messages (shapes in Protocol.lua)
------------------------------------------------------------------------------------------

function Casino.StateMessage(t)
    local seats = {}
    for _, name in ipairs(Casino.Seated(t)) do
        seats[#seats + 1] = { name = name, balance = t.members[name].balance }
    end
    local history = {}
    for i, n in ipairs(t.history) do history[i] = n end
    local msg = {
        rev = t.rev, game = t.game, name = t.name, status = t.status, round = t.round,
        minBet = t.minBet, maxBet = t.maxBet, zero = t.zero, seats = seats, history = history,
        auto = t.auto and true or nil, autoAt = t.autoAt,        -- automatic rounds: on, and when the bets lock
    }
    local e = engine(t)
    if e and e.Public then msg.bj = e.Public(t) end       -- the game's own public table state
    return msg
end

function Casino.PlayerMessage(t, name)
    local m = t.members[name]
    local bets = {}
    for i, b in ipairs(m and m.bets or {}) do bets[i] = copyBet(b) end
    return { rev = t.rev, balance = m and m.balance or 0, bets = bets }
end

function Casino.ResultMessage(t)
    local r = t.lastResult
    if not r then return nil end
    return { rev = t.rev, round = r.round, number = r.number, dealer = r.dealer, results = r.results }
end

-- Handle a message from a player. `sender` is the name Comm delivered it from. Returns out, events;
-- out = list of { type, payload, to }, events = list of { kind = "join_request" | "bet" | "left", ... }.
function Casino.Handle(t, sender, msgType, payload, now)
    local out, events = {}, {}
    local function reply(ty, p) out[#out + 1] = { type = ty, payload = p, to = sender } end
    payload = payload or {}
    local m = t.members[sender]
    local function deny(reason) reply("TBL_JOIN_DENY", { ownerName = t.hostName, reason = reason }) end
    local function seatedWelcome()
        -- The welcome is three messages. A player who asks again while the first set is still waiting in the
        -- (rate-limited) queue would only add three more behind it, so answer a repeat only after a while.
        if m and m.welcomeAt and now - m.welcomeAt < 8 then return end
        if m then m.welcomeAt = now end
        reply("TBL_JOIN_OK", { game = t.game, name = t.name, ownerName = t.hostName, rev = t.rev })
        reply("TBL_STATE", Casino.StateMessage(t))
        reply("TBL_PLAYER", Casino.PlayerMessage(t, sender))
    end

    if msgType == "TBL_JOIN" then
        local known = m ~= nil and m.status ~= "left" and m.status ~= "denied"
        local status, err = Casino.RequestJoin(t, sender, now)
        if status == "seated" then
            seatedWelcome()
        elseif status == "pending" then
            if not known then events[#events + 1] = { kind = "join_request", name = sender } end
        else
            deny(err)
        end

    elseif msgType == "TBL_SYNC_REQ" then
        if m and m.status == "seated" then
            seatedWelcome()
        elseif m and m.status == "pending" then
            -- ignored: still waiting for the host
        else
            deny("not_seated")
        end

    elseif msgType == "TBL_BET" then
        local bet, reason, extra = Casino.PlaceBet(t, sender, payload.round, payload.bet, payload.ref)
        if bet then
            reply("TBL_BET_OK", { ref = payload.ref, betId = bet.id, balance = t.members[sender].balance })
            if not extra then events[#events + 1] = { kind = "bet", name = sender, bet = bet } end
        else
            local r = { ref = payload.ref, reason = reason }
            if reason == "min_bet" then r.min = extra elseif reason == "max_bet" then r.max = extra
            elseif reason == "no_balance" then r.balance = extra end
            reply("TBL_BET_REJECT", r)
        end

    elseif msgType == "TBL_ACT" then
        local e = engine(t)
        if m and m.status == "seated" and e and e.Act and payload.ref ~= nil and m.lastAct == payload.ref then
            -- the same click sent again (the answer was slow or lost): never act twice, just restate the table
            reply("TBL_PLAYER", Casino.PlayerMessage(t, sender))
            reply("TBL_STATE", Casino.StateMessage(t))
        elseif m and m.status == "seated" and e and e.Act then
            local ok, reason = e.Act(t, sender, payload.round, payload.action, now)
            if ok then
                m.lastAct = payload.ref
                reply("TBL_PLAYER", Casino.PlayerMessage(t, sender))
                events[#events + 1] = { kind = "act", name = sender, action = payload.action }
            else
                reply("TBL_BET_REJECT", { ref = payload.ref or "act", reason = reason, balance = m.balance })
            end
        end

    elseif msgType == "TBL_BET_CLEAR" then
        if m and m.status == "seated" then
            Casino.ClearBets(t, sender, payload.round)
            reply("TBL_PLAYER", Casino.PlayerMessage(t, sender))     -- the truth, whether or not it worked
        end

    elseif msgType == "TBL_LEAVE" then
        if Casino.Leave(t, sender) then
            deny("left")
            events[#events + 1] = { kind = "left", name = sender }
        end
    end
    return out, events
end

return Casino
