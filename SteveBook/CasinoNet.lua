-- CasinoNet.lua: casino tables over the wire (SPEC §11). The glue between Comm and the two pure
-- modules: Casino (the host's authority) and CasinoClient (the player's saved view). WoW-dependent.
--   Host actions:   Create, Admit, Deny, Adjust, Kick, SetLimits, Spin, CloseTable, Delete
--   Player actions: RequestJoin, PlaceBet, ClearBets, Leave, Forget, Sync
--   Subscribe(fn) tells a window that something changed.
local ADDON, ns = ...
ns = ns or {}

local Casino, Client, Roulette, Odds, Blackjack = ns.Casino, ns.CasinoClient, ns.Roulette, ns.Odds, ns.Blackjack
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
        local rev = t.rev
        local out, events = Casino.Handle(t, sender, msgType, payload, now())
        send(code, out)
        for _, e in ipairs(events) do
            if e.kind == "left" then send(code, { stateMsg(t) }); CasinoNet.Announce() end
        end
        -- blackjack is played in the open: every wager and decision changes what everyone sees
        if t.game == "blackjack" and t.rev ~= rev and msgType ~= "TBL_JOIN" and msgType ~= "TBL_SYNC_REQ" then
            CasinoNet.AfterBlackjack(t)
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
    CasinoNet.Announce()
    changed(t.code)
    return t
end

function CasinoNet.Admit(t, name, chips)
    local m, err = Casino.Admit(t, name, chips, now())
    if not m then
        if err == "full" then return nil, ("The table is full (%d seats). Remove someone first."):format(t.maxSeats or 0) end
        return nil, err
    end
    send(t.code, {
        { type = "TBL_JOIN_OK", to = name, payload = { game = t.game, name = t.name, ownerName = t.hostName, rev = t.rev } },
        stateMsg(t),
        { type = "TBL_PLAYER", to = name, payload = Casino.PlayerMessage(t, name) },
    })
    CasinoNet.Announce()
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
    if t.game == "blackjack" then CasinoNet.AfterBlackjack(t) end
    CasinoNet.Announce()
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
    CasinoNet.Announce({ [t.code] = true })
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
-- Host: blackjack
------------------------------------------------------------------------------------------

local dealerPending = {}                 -- table code -> true while the dealer's reveal is waiting to finish

local function finishBlackjack(code)
    dealerPending[code] = nil
    local t = hosted(code)
    if not (t and t.status == "dealer") then return end
    local r = ns.BlackjackTable.FinishDealer(t, now())
    if not r then return end
    local house = 0
    for _, e in ipairs(r.results) do house = house - e.net end
    say(("%s: the dealer has %d%s. Round %d, %d player(s). House %s%s|r."):format(
        t.name, r.dealer.total, r.dealer.bust and " (bust)" or "", r.round, #r.results,
        house >= 0 and GREEN or RED, (house >= 0 and "+" or "") .. money(house)))
    send(code, { { type = "TBL_RESULT", payload = Casino.ResultMessage(t) }, stateMsg(t) })
    changed(code)
    -- the round stays on the table for a few seconds, then betting reopens
    if C_Timer and C_Timer.After then C_Timer.After(ns.BlackjackTable.RESULTS_SECONDS, function() CasinoNet.NextBlackjackRound(code) end)
    else CasinoNet.NextBlackjackRound(code) end
end

function CasinoNet.NextBlackjackRound(code)
    local t = hosted(code)
    if not (t and t.status == "results") then return end
    ns.BlackjackTable.NextRound(t, now())
    send(code, { stateMsg(t) })
    CasinoNet.Announce()
    changed(code)
end

-- Tell everyone what the table looks like now, and if the players are done start the dealer.
function CasinoNet.AfterBlackjack(t)
    send(t.code, { stateMsg(t) })
    if t.status == "dealer" and not dealerPending[t.code] then
        dealerPending[t.code] = true
        local code = t.code
        if C_Timer and C_Timer.After then C_Timer.After(ns.BlackjackTable.DEALER_SECONDS, function() finishBlackjack(code) end)
        else finishBlackjack(code) end
    end
    changed(t.code)
end

local DEAL_ERRORS = { no_bets = "Nobody has placed a bet yet.", not_betting = "A round is already being played." }

function CasinoNet.Deal(t)
    if t.game ~= "blackjack" then return nil, "Only blackjack tables deal." end
    local ok, info = ns.BlackjackTable.Deal(t, nil, now())
    if not ok then return nil, DEAL_ERRORS[info] or info end
    if info.shuffled then say("A fresh shoe was shuffled.") end
    CasinoNet.AfterBlackjack(t)
    return true
end

-- Stand the player whose turn it is (the host's button).
function CasinoNet.Skip(t)
    local name = t.game == "blackjack" and ns.BlackjackTable.Skip(t, now())
    if not name then return nil, "There is nobody to skip." end
    say(name .. " was stood.")
    CasinoNet.AfterBlackjack(t)
    return true
end

local function blackjackTick()
    local d = db()
    if not d then return end
    for _, t in ipairs(Casino.List(d)) do
        if t.hostName == me() and t.game == "blackjack" and t.status == "playing" then
            local name = ns.BlackjackTable.Tick(t, now())
            if name then
                say(name .. " ran out of time and stands.")
                CasinoNet.AfterBlackjack(t)
            end
        end
    end
end

------------------------------------------------------------------------------------------
-- The lobby: open tables are announced in one shared channel so players can pick from a list
------------------------------------------------------------------------------------------

local ROOM_TTL = 100                     -- a listing disappears this long after the host's last announcement
local ANNOUNCE_EVERY = 15                -- hosts repeat their listing this often (a missed message costs only 15 s)
local rooms = {}                         -- code -> { entry, seen }
local lastAnnounce = 0
local lastHeard = nil                    -- when any host's listing (table or book) last reached me

local function entryFor(t)
    return { code = t.code, game = t.game, name = t.name, host = t.hostName, seats = #Casino.Seated(t),
             status = t.status, minBet = t.minBet, maxBet = t.maxBet, zero = t.zero, maxSeats = t.maxSeats }
end

-- My open tables (and `extra`: codes of tables to list once more as closed), told to the lobby.
function CasinoNet.Announce(closed)
    local d = db()
    if not d then return end
    local list = {}
    for _, t in ipairs(Casino.List(d)) do
        if t.hostName == me() then
            if t.status ~= "closed" then list[#list + 1] = entryFor(t)
            elseif closed and closed[t.code] then list[#list + 1] = entryFor(t) end
        end
    end
    if #list == 0 then return end
    lastAnnounce = now()
    ns.Comm.JoinBook(ns.Protocol.LOBBY_CODE)
    ns.Comm.Send("LOBBY_TABLE", { tables = list, ver = ns.Comm.Version() }, ns.Protocol.LOBBY_CODE)
end

-- Tell the players at my open tables that the table is alive (and repair any state they missed). The
-- player's window warns when it has not heard from the host for a while.
function CasinoNet.Heartbeat()
    local d = db()
    if not d then return end
    for _, t in ipairs(Casino.List(d)) do
        if t.hostName == me() and t.status ~= "closed" and #Casino.Seated(t) > 0 then
            send(t.code, { stateMsg(t) })
        end
    end
end

-- Join the lobby and ask who is hosting. Called when the player opens the list of tables.
function CasinoNet.AskLobby()
    if db() then db().lobbyJoined = true end            -- from now on stay in the lobby, so the list is already warm next time
    ns.Comm.JoinBook(ns.Protocol.LOBBY_CODE)
    ns.Comm.Send("LOBBY_ASK", { ver = ns.Comm.Version() }, ns.Protocol.LOBBY_CODE)
end

-- For the window: am I in the lobby channel, and when did a host last come through?
function CasinoNet.LobbyStatus()
    return { joined = ns.Comm.IsJoined(ns.Protocol.LOBBY_CODE), heard = lastHeard and (now() - lastHeard) or nil }
end

-- Seconds since my own tables were last announced, or nil if never.
function CasinoNet.LastAnnounce() return lastAnnounce > 0 and (now() - lastAnnounce) or nil end

-- Open tables of one game (or all) that I could join, newest announcement first, as entries
-- { code, game, name, host, seats, status, minBet, maxBet, zero, age }. Tables I already sit at or
-- host are left out (with /book loopback my own tables are listed so one character can test).
function CasinoNet.Rooms(game)
    local t0 = now()
    local list = {}
    local d = db()
    local mine = {}
    for _, tc in ipairs(d and d.casinoCache and Client.List(d.casinoCache) or {}) do
        if tc.status == "requested" or tc.status == "seated" then mine[tc.code] = true end
    end
    for code, r in pairs(rooms) do
        if t0 - r.seen > ROOM_TTL then rooms[code] = nil
        elseif not mine[code] and (not game or r.entry.game == game) and r.entry.status ~= "closed" and not hosted(code) then
            local e = {}
            for k, v in pairs(r.entry) do e[k] = v end
            e.age = t0 - r.seen
            list[#list + 1] = e
        end
    end
    if d and d.loopback == true then
        for _, t in ipairs(Casino.List(d)) do
            if t.hostName == me() and t.status ~= "closed" and not mine[t.code] and (not game or t.game == game) then
                local e = entryFor(t); e.age = 0; list[#list + 1] = e
            end
        end
    end
    table.sort(list, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.code < b.code
    end)
    return list
end

local lobbyHandlers = {}
local peers = {}                         -- who has said anything in the lobby: name -> when

-- /book lobby: is this client in the lobby channel, and who has been heard there? (Channel numbers
-- are only a player's own slot: two players in the same channel usually have different numbers.)
function CasinoNet.LobbyReport()
    local name = ns.Protocol.ChannelName(ns.Protocol.LOBBY_CODE)
    local id, disabled = ns.Comm.ChannelState(ns.Protocol.LOBBY_CODE)
    local lines = {}
    if id and id > 0 and disabled then
        lines[1] = ("The lobby channel %s has slot /%d but the game lists it as DISABLED, so nothing is sent or heard. SteveBook retries joining it every few seconds; run /book net to watch."):format(name, id)
    elseif id and id > 0 then
        lines[1] = ("In the lobby channel %s as /%d. The number is just your own slot: everyone is reached by the channel name, so a friend on another number is fine."):format(name, id)
    else
        lines[1] = "Not in the lobby channel (" .. name .. ") yet. Open /casino to join it."
    end
    local list = {}
    for who, p in pairs(peers) do list[#list + 1] = { who = who, ago = now() - p.at, ver = p.ver } end
    table.sort(list, function(a, b) return a.ago < b.ago end)
    if #list == 0 then
        lines[2] = "Nobody else has been heard in the lobby yet. When a friend opens the casino's join page, or hosts a table, they should appear here."
    else
        local parts = {}
        for i, e in ipairs(list) do
            if i <= 8 then parts[#parts + 1] = ("%s (%s%d s ago)"):format(e.who, e.ver and ("v" .. e.ver .. ", ") or "", e.ago) end
        end
        lines[2] = "Heard in the lobby: " .. table.concat(parts, ", ") .. "."
    end
    return lines
end

local function hear(sender, p)
    if sender then peers[sender] = { at = now(), ver = p and p.ver } end
end

local function dbg(msg)
    if db() and db().debug then say("|cff9d9d9d[debug]|r " .. msg) end
end

function lobbyHandlers.LOBBY_ASK(sender, p)
    hear(sender, p)
    dbg(("lobby: %s is asking who is hosting%s"):format(tostring(sender), p and p.ver and (" (v" .. p.ver .. ")") or ""))
    if now() - lastAnnounce >= 2 then CasinoNet.Announce() end
end

function lobbyHandlers.LOBBY_BOOKS(sender, p)                    -- only to know the lobby is alive
    lastHeard = now()
    hear(sender, p)
end

function lobbyHandlers.LOBBY_TABLE(sender, p)
    lastHeard = now()
    hear(sender, p)
    for _, e in ipairs(p.tables) do
        -- a listing counts only when the host announces their own table
        if baseName(sender) == baseName(e.host) then
            if e.status == "closed" then rooms[e.code] = nil
            else rooms[e.code] = { entry = e, seen = now() } end
            dbg(("lobby: listing %s (%s) from %s"):format(e.code, e.game, tostring(sender)))
        else
            dbg(("lobby: ignored the listing %s from %s because it names %s as the host"):format(e.code, tostring(sender), tostring(e.host)))
        end
    end
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
    tc.lastHeard = now()                                 -- the host is alive (the window warns when this gets old)
    return tc
end

-- The window tells us whether it is open for a table, so we can speak up in chat when something needs
-- the player and the window is closed (closing the window never leaves the table).
local windowOpen = function() return false end
function CasinoNet.SetWindowCheck(fn) windowOpen = fn or function() return false end end

local function alertIfNeeded(tc, code, before, p)
    if windowOpen(code) or tc.status ~= "seated" then return end
    local me_ = tc.me or me()
    local bj = p.bj
    if bj and p.status == "playing" and bj.turn == me_ then
        local key = tostring(p.round) .. ":" .. tostring(bj.turnHand or 1)
        if tc.alertedTurn ~= key then
            tc.alertedTurn = key
            say(("It's your turn in blackjack at %s. /casino to open the table (you are stood after %d s)."):format(p.name, ns.BlackjackTable and ns.BlackjackTable.TURN_SECONDS or 30))
        end
    elseif p.status == "betting" and before and before ~= "betting" and (tc.balance or 0) > 0 and Client.Staked(tc) == 0 and tc.alertedBet ~= p.round then
        tc.alertedBet = p.round
        say(("Betting is open in %s at %s. /casino to place your bet."):format((Casino.GAMES[p.game] and Casino.GAMES[p.game].title or "the casino"):lower(), p.name))
    end
end

local REJECT_TEXT = {
    not_seated = "You do not have a seat at this table.",
    round_closed = "Betting is closed for that round.",
    not_your_turn = "It is not your turn.",
    bad_action = "You cannot do that with this hand.",
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
    tc.lastHeard = now()
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
    if not (tc and tc.status == "seated") then return end
    local before = tc.state and tc.state.status
    if Client.ApplyState(db().casinoCache, code, p) then alertIfNeeded(tc, code, before, p) end
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
    if bet or (p.ref and p.ref:sub(1, 3) == "act") then say(rejectText(p)) end
    if p.reason == "round_closed" then CasinoNet.Sync(code) end     -- our round number was stale
end

function handlers.TBL_RESULT(sender, p, code)
    local tc = tableFor(code, sender)
    if not (tc and tc.status == "seated") then return end
    Client.ApplyResult(db().casinoCache, code, p)
    local label
    if p.number then
        label = Roulette.Label(p.number) .. " " .. Roulette.Color(p.number)
    elseif p.dealer then
        label = ("Dealer %d%s"):format(p.dealer.total or 0, p.dealer.bust and " (bust)" or (p.dealer.blackjack and " (blackjack)" or ""))
    else
        label = "Round over"
    end
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

function CasinoNet.RequestJoin(code, game)
    code = ns.Protocol.CanonicalCode(code)
    if not ns.Protocol.CanonicalCode(code):match("^%u%u%u%-%w%w%w%w$") then
        return nil, "That does not look like a table code (like RLT-K7Q2)."
    end
    if hosted(code) and not (db().loopback == true) then return nil, "That is your own table. Turn on /book loopback to test it alone." end
    local tc = Client.RequestJoin(db().casinoCache, code, now())
    if game and not tc.game then tc.game = game end              -- from the list; the host confirms it later
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

-- Blackjack: the wager for the next round.
function CasinoNet.Wager(code, amount)
    local tc = cache(code)
    if not Client.CanBet(tc) then return nil, "Betting is closed right now." end
    local st = tc.state
    if amount % Odds.STAKE_STEP ~= 0 or amount <= 0 then return nil, "Bets are whole silver." end
    if amount < st.minBet then return nil, "The minimum bet is " .. money(st.minBet) .. "." end
    if amount > st.maxBet then return nil, "The maximum bet is " .. money(st.maxBet) .. "." end
    if amount > (tc.balance or 0) then return nil, "You only have " .. money(tc.balance or 0) .. " in chips." end
    if Client.Staked(tc) > 0 then return nil, "You already bet this round. Take it back first to change it." end
    seq = seq + 1
    local ref = ("%d-%04d-%d"):format(now(), math.random(0, 9999), seq)
    local bet = { kind = "wager", amount = amount }
    Client.NewPending(db().casinoCache, code, ref, bet, now())
    ns.Comm.Send("TBL_BET", { ref = ref, round = st.round, bet = bet }, code)
    changed(code)
    return true
end

-- Blackjack: hit, stand, double or split on my turn.
function CasinoNet.Act(code, action)
    local tc = cache(code)
    if not Client.MyTurn(tc, tc and tc.me or me()) then return nil, "It is not your turn." end
    seq = seq + 1
    ns.Comm.Send("TBL_ACT", { ref = "act" .. seq, round = tc.state.round, action = action }, code)
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
            local dropped = Client.ExpirePending(d.casinoCache, tc.code, t0)
            if dropped > 0 then
                say(("The host of %s did not answer %s; your chips were not taken. Check that they are online."):format(
                    tc.name or tc.code, dropped == 1 and "a bet" or (dropped .. " bets")))
                changed(tc.code)
            end
        end
    end
end

local registered
local function register()
    if registered or not (ns.Comm and ns.Comm.Register) then return end
    registered = true
    for _, t in ipairs({ "TBL_JOIN", "TBL_LEAVE", "TBL_SYNC_REQ", "TBL_BET", "TBL_BET_CLEAR", "TBL_ACT" }) do
        ns.Comm.Register(t, onPlayerMessage(t))
    end
    for msgType, fn in pairs(handlers) do
        ns.Comm.Register(msgType, function(sender, payload, code)
            fn(sender, payload, code)
            changed(code)
        end)
    end
    for msgType, fn in pairs(lobbyHandlers) do
        ns.Comm.Register(msgType, function(sender, payload, code)
            fn(sender, payload, code)
            changed(code)
        end)
    end
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(TICK_SECONDS, tick)
        C_Timer.NewTicker(1, blackjackTick)
        C_Timer.NewTicker(ANNOUNCE_EVERY, function() CasinoNet.Announce(); CasinoNet.Heartbeat() end)   -- list + heartbeat
    end
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
