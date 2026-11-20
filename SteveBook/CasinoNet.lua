-- CasinoNet.lua: casino tables over the wire (SPEC §11). The glue between Comm and the two pure
-- modules: Casino (the host's authority) and CasinoClient (the player's saved view). WoW-dependent.
--   Host actions:   Create, Admit, Deny, Adjust, Kick, SetLimits, Spin, CloseTable, Delete
--   Player actions: RequestJoin, PlaceBet, ClearBets, Leave, Forget, Sync
--   Subscribe(fn) tells a window that something changed.
local ADDON, ns = ...
ns = ns or {}

local Casino, Client, Roulette, Odds = ns.Casino, ns.CasinoClient, ns.Roulette, ns.Odds
local CasinoNet = {}
ns.CasinoNet = CasinoNet

local TICK_SECONDS = 30
local GOLD, GREEN, RED = "|cffffd100", "|cff40ff40", "|cffff5050"

local function say(msg) print(GOLD .. "SteveBook Casino:|r " .. msg) end
local function me() return UnitName("player") end
local function now() return GetServerTime() end
local function money(c) return Odds.FormatMoney(c) end
local function baseName(name) return type(name) == "string" and name:match("^([^%-]+)") or nil end

local listeners = {}
function CasinoNet.Subscribe(fn) listeners[#listeners + 1] = fn end
local function changed(code)
    for _, fn in ipairs(listeners) do pcall(fn, code) end
end

local function db() return SteveBookDB end
local function hosted(code)
    local t = db() and Casino.Find(db(), code)
    if t and t.hostName == me() then return t end
end
local function cache(code)
    local d = db()
    return d and d.casinoCache and Client.Table(d.casinoCache, code)
end

-- Send a list of { type, payload, to } for one table.
local function send(code, msgs)
    for _, m in ipairs(msgs) do
        local ok, err = ns.Comm.Send(m.type, m.payload, code, m.to)
        if ok == false then say(("could not send %s: %s"):format(m.type, tostring(err))) end
    end
end

local function stateMsg(t) return { type = "TBL_STATE", payload = Casino.StateMessage(t) } end

------------------------------------------------------------------------------------------
-- Host: incoming
------------------------------------------------------------------------------------------

local function announce(t, events)
    for _, e in ipairs(events) do
        if e.kind == "join_request" then
            say(("%s wants a seat at %s (%s). /casino to let them in."):format(e.name, t.name, t.code))
        elseif e.kind == "left" then
            say(("%s left %s."):format(e.name, t.name))
        end
    end
end

local function onPlayerMessage(msgType)
    return function(sender, payload, code)
        local t = hosted(code)
        if not t or sender == t.hostName then return end
        local out, events = Casino.Handle(t, sender, msgType, payload, now())
        send(code, out)
        for _, e in ipairs(events) do
            if e.kind == "left" then send(code, { stateMsg(t) }) end
        end
        announce(t, events)
        changed(code)
    end
end

------------------------------------------------------------------------------------------
-- Host: actions (each returns the result, or nil, message)
------------------------------------------------------------------------------------------

function CasinoNet.Create(spec)
    local t, err = Casino.Create(db(), spec, me(), now())
    if not t then return nil, err end
    ns.Comm.JoinBook(t.code)
    changed(t.code)
    return t
end

function CasinoNet.Admit(t, name, chips)
    local m, err = Casino.Admit(t, name, chips, now())
    if not m then return nil, err end
    send(t.code, {
        { type = "TBL_JOIN_OK", to = name, payload = { game = t.game, name = t.name, ownerName = t.hostName, rev = t.rev } },
        stateMsg(t),
        { type = "TBL_PLAYER", to = name, payload = Casino.PlayerMessage(t, name) },
    })
    changed(t.code)
    return m
end

function CasinoNet.Deny(t, name)
    local ok, err = Casino.Deny(t, name)
    if not ok then return nil, err end
    send(t.code, { { type = "TBL_JOIN_DENY", to = name, payload = { ownerName = t.hostName, reason = "denied" } } })
    changed(t.code)
    return true
end

function CasinoNet.Adjust(t, name, delta)
    local balance, err = Casino.Adjust(t, name, delta)
    if not balance then return nil, err end
    send(t.code, { stateMsg(t), { type = "TBL_PLAYER", to = name, payload = Casino.PlayerMessage(t, name) } })
    changed(t.code)
    return balance
end

function CasinoNet.Kick(t, name)
    local ok, err = Casino.Kick(t, name)
    if not ok then return nil, err end
    send(t.code, {
        { type = "TBL_JOIN_DENY", to = name, payload = { ownerName = t.hostName, reason = "removed" } },
        stateMsg(t),
    })
    changed(t.code)
    return true
end

function CasinoNet.SetLimits(t, minBet, maxBet)
    local ok, err = Casino.SetLimits(t, minBet, maxBet)
    if not ok then return nil, err end
    send(t.code, { stateMsg(t) })
    changed(t.code)
    return true
end

-- The spin: betting stops, the wheel "turns" for Casino.SPIN_SECONDS, then the number is drawn and
-- paid. The delay is only for show; the number is picked when it ends.
local function finishSpin(code)
    local t = hosted(code)
    if not (t and t.status == "spinning") then return end
    local number = Casino.PickNumber(t)
    local r = Casino.Finish(t, number, now())
    if not r then return end
    local house = 0
    for _, e in ipairs(r.results) do house = house - e.net end
    say(("%s: %s %s. Round %d, %d player(s) bet. House %s%s|r."):format(
        t.name, Roulette.Label(number), Roulette.Color(number), r.round, #r.results,
        house >= 0 and GREEN or RED, (house >= 0 and "+" or "") .. money(house)))
    send(code, { { type = "TBL_RESULT", payload = Casino.ResultMessage(t) }, stateMsg(t) })
    changed(code)
end

function CasinoNet.Spin(t)
    local ok, err = Casino.BeginSpin(t, now())
    if not ok then return nil, err == "not_betting" and "The wheel is already turning." or err end
    send(t.code, { stateMsg(t) })
    changed(t.code)
    local code = t.code
    if C_Timer and C_Timer.After then C_Timer.After(Casino.SPIN_SECONDS, function() finishSpin(code) end)
    else finishSpin(code) end
    return true
end

function CasinoNet.CloseTable(t)
    Casino.Close(t)
    send(t.code, { stateMsg(t) })
    changed(t.code)
    local code = t.code
    if C_Timer and C_Timer.After then
        C_Timer.After(10, function()               -- let the last state go out, then leave the channel
            local tt = hosted(code)
            if tt and tt.status == "closed" then ns.Comm.LeaveBook(code) end
        end)
    end
    return true
end

-- Remove a closed table from the list for good.
function CasinoNet.Delete(t)
    if t.status ~= "closed" then return nil, "Close the table first." end
    Casino.Delete(db(), t.code)
    changed(t.code)
    return true
end

------------------------------------------------------------------------------------------
-- Player: incoming
------------------------------------------------------------------------------------------

-- The table a host message is about, or nil: we must know the table and, once we know the host,
-- only that host's messages count.
local function tableFor(code, sender)
    local tc = cache(code)
    if not tc then return nil end
    if tc.owner and baseName(sender) ~= baseName(tc.owner) then return nil end
    return tc
end

local REJECT_TEXT = {
    not_seated = "You do not have a seat at this table.",
    round_closed = "Betting is closed for that round.",
    bad_bet = "That is not a valid bet.",
    table_error = "The table could not take that bet.",
}

local function rejectText(p)
    if p.reason == "min_bet" then return "The minimum bet here is " .. money(p.min or 0) .. "." end
    if p.reason == "max_bet" then return "The maximum bet here is " .. money(p.max or 0) .. "." end
    if p.reason == "no_balance" then return "You only have " .. money(p.balance or 0) .. " in chips." end
    return REJECT_TEXT[p.reason] or ("Bet refused (" .. tostring(p.reason) .. ").")
end

local handlers = {}

function handlers.TBL_JOIN_OK(sender, p, code)
    local tc = cache(code)
    if not tc or tc.status == "seated" then return end
    -- only the character the payload names as the host may seat us, and only if they sent it
    if not baseName(sender) or baseName(sender) ~= baseName(p.ownerName) then return end
    Client.ApplyJoinOk(db().casinoCache, code, sender, p)
    say(("You have a seat at %s."):format(p.name))
end

function handlers.TBL_JOIN_DENY(sender, p, code)
    local tc = cache(code)
    if not tc then return end
    local who = baseName(sender)
    if not who or who ~= baseName(p.ownerName) then return end
    if tc.owner and who ~= baseName(tc.owner) then return end
    Client.ApplyJoinDeny(db().casinoCache, code, p.reason)
    local why = ({ left = "You left the table.", removed = "The host removed you from the table.",
        closed = "That table is closed.", denied = "The host turned down your request." })[p.reason]
    say(why or ("The host refused your request (" .. tostring(p.reason) .. ")."))
end

function handlers.TBL_STATE(sender, p, code)
    local tc = tableFor(code, sender)
    if tc and tc.status == "seated" then Client.ApplyState(db().casinoCache, code, p) end
end

function handlers.TBL_PLAYER(sender, p, code)
    local tc = tableFor(code, sender)
    if tc and tc.status == "seated" then Client.ApplyPlayer(db().casinoCache, code, p) end
end

function handlers.TBL_BET_OK(sender, p, code)
    local tc = tableFor(code, sender)
    if tc and tc.status == "seated" then Client.ApplyBetOk(db().casinoCache, code, p.ref, p.betId, p.balance) end
end

function handlers.TBL_BET_REJECT(sender, p, code)
    local tc = tableFor(code, sender)
    if not (tc and tc.status == "seated") then return end
    local bet = Client.ApplyBetReject(db().casinoCache, code, p.ref, p.balance)
    if bet then say(rejectText(p)) end
    if p.reason == "round_closed" then CasinoNet.Sync(code) end     -- our round number was stale
end

function handlers.TBL_RESULT(sender, p, code)
    local tc = tableFor(code, sender)
    if not (tc and tc.status == "seated") then return end
    Client.ApplyResult(db().casinoCache, code, p)
    local label = Roulette.Label(p.number) .. " " .. Roulette.Color(p.number)
    local mine = Client.MyResult(tc, tc.me or me())
    if mine then
        if mine.net > 0 then say(("%s! You won %s%s|r."):format(label, GREEN, money(mine.net)))
        elseif mine.net < 0 then say(("%s. You lost %s%s|r."):format(label, RED, money(-mine.net)))
        else say(label .. ". You broke even.") end
    else
        say(label .. ".")
    end
end

------------------------------------------------------------------------------------------
-- Player: actions (each returns true, or nil, message)
------------------------------------------------------------------------------------------

local seq = 0

function CasinoNet.RequestJoin(code)
    code = ns.Protocol.CanonicalCode(code)
    if not ns.Protocol.CanonicalCode(code):match("^%u%u%u%-%w%w%w%w$") then
        return nil, "That does not look like a table code (like RLT-K7Q2)."
    end
    if hosted(code) and not (db().loopback == true) then return nil, "That is your own table. Turn on /book loopback to test it alone." end
    local tc = Client.RequestJoin(db().casinoCache, code, now())
    tc.me = (ns.Comm.LoopbackActive and ns.Comm.LoopbackActive(code)) and ns.Comm.LOOPBACK_NAME or ns.Comm.Me()
    ns.Comm.JoinBook(code)
    ns.Comm.Send("TBL_JOIN", {}, code)
    changed(code)
    return tc
end

function CasinoNet.Sync(code)
    local tc = cache(code)
    if tc and tc.status == "seated" then ns.Comm.Send("TBL_SYNC_REQ", { rev = tc.rev or 0 }, code) end
end

-- A bet from the board. `bet` = { kind, numbers?, pick?, amount }.
function CasinoNet.PlaceBet(code, bet)
    local tc = cache(code)
    if not Client.CanBet(tc) then return nil, "Betting is closed right now." end
    local st = tc.state
    local ok, _, msg = Roulette.ValidateBet(bet, st.zero)
    if not ok then return nil, msg or "That is not a valid bet." end
    if bet.amount % Odds.STAKE_STEP ~= 0 then return nil, "Bets are whole silver." end
    if bet.amount < st.minBet then return nil, "The minimum bet is " .. money(st.minBet) .. "." end
    if bet.amount > st.maxBet then return nil, "The maximum bet is " .. money(st.maxBet) .. "." end
    -- confirmed bets are already out of the balance; only unanswered ones are not
    local waiting = 0
    for _, p in pairs(tc.pending) do waiting = waiting + p.bet.amount end
    local free = (tc.balance or 0) - waiting
    if bet.amount > free then return nil, "You only have " .. money(math.max(0, free)) .. " in chips." end
    seq = seq + 1
    local ref = ("%d-%04d-%d"):format(now(), math.random(0, 9999), seq)
    local copy = { kind = bet.kind, amount = bet.amount, pick = bet.pick }
    if bet.numbers then
        copy.numbers = {}
        for i, n in ipairs(bet.numbers) do copy.numbers[i] = n end
    end
    Client.NewPending(db().casinoCache, code, ref, copy, now())
    ns.Comm.Send("TBL_BET", { ref = ref, round = st.round, bet = copy }, code)
    changed(code)
    return true
end

function CasinoNet.ClearBets(code)
    local tc = cache(code)
    if not Client.CanBet(tc) then return nil, "Betting is closed right now." end
    ns.Comm.Send("TBL_BET_CLEAR", { round = tc.state.round }, code)
    return true
end

function CasinoNet.Leave(code)
    local tc = cache(code)
    if not tc then return nil end
    if tc.status == "seated" then ns.Comm.Send("TBL_LEAVE", {}, code) end
    return true
end

-- Drop a table from my list (leaves it first if I am seated).
function CasinoNet.Forget(code)
    local tc = cache(code)
    if not tc then return end
    if tc.status == "seated" then ns.Comm.Send("TBL_LEAVE", {}, code) end
    Client.Forget(db().casinoCache, code)
    ns.Comm.LeaveBook(code)
    changed(code)
end

------------------------------------------------------------------------------------------
-- Setup and periodic work
------------------------------------------------------------------------------------------

local function tick()
    local d = db()
    if not (d and d.casinoCache) then return end
    local t0 = now()
    for _, tc in ipairs(Client.List(d.casinoCache)) do
        if tc.status == "requested" then
            ns.Comm.Send("TBL_JOIN", {}, tc.code)                  -- idempotent; covers a host who was offline
        elseif tc.status == "seated" then
            if Client.ExpirePending(d.casinoCache, tc.code, t0) > 0 then changed(tc.code) end
        end
    end
end

local registered
local function register()
    if registered or not (ns.Comm and ns.Comm.Register) then return end
    registered = true
    for _, t in ipairs({ "TBL_JOIN", "TBL_LEAVE", "TBL_SYNC_REQ", "TBL_BET", "TBL_BET_CLEAR" }) do
        ns.Comm.Register(t, onPlayerMessage(t))
    end
    for msgType, fn in pairs(handlers) do
        ns.Comm.Register(msgType, function(sender, payload, code)
            fn(sender, payload, code)
            changed(code)
        end)
    end
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(TICK_SECONDS, tick) end
end

-- Called once SteveBookDB exists (ADDON_LOADED).
function CasinoNet.Init()
    local d = db()
    if not d then return end
    Casino.Ensure(d)
    Client.Ensure(d)
    Casino.Recover(d)
    register()
    -- ask each table I sit at for its state once the channels are up
    if C_Timer and C_Timer.After then
        C_Timer.After(25, function()
            for _, tc in ipairs(Client.List(d.casinoCache)) do
                if tc.status == "seated" then CasinoNet.Sync(tc.code) end
            end
        end)
    end
end

CasinoNet.tick = tick
return CasinoNet
