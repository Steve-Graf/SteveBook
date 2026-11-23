-- RocketNet.lua: the rocket in the game (SPEC §11c). WoW-dependent glue around Rocket.lua: the clock, the
-- player's one bet (saved in SteveBookDB.rocket), settling it into the house report, and the two messages that
-- let everybody see who is on the rocket.
--   SteveBookDB.rocket = { host = the house I am watching, bet = my live bet, lastResult }
-- Player actions: Open, PlaceBet, Bail. The window reads View() and listens through Subscribe.
local ADDON, ns = ...
ns = ns or {}

local Rocket, House, Odds = ns.Rocket, ns.House, ns.Odds
local RocketNet = {}
ns.RocketNet = RocketNet

local GOLD, GREEN, RED = "|cffffd100", "|cff40ff40", "|cffff5050"
local BOARD_KEEP = 180               -- seconds a round stays on the board

local function say(msg) print(GOLD .. "SteveBook Rocket:|r " .. msg) end
local function db() return SteveBookDB end
local function me() return UnitName("player") end
local function money(c) return Odds.FormatMoney(c) end
local function baseName(name) return type(name) == "string" and name:match("^([^%-%s]+)") or nil end

local listeners = {}
function RocketNet.Subscribe(fn) listeners[#listeners + 1] = fn end
local function changed()
    for _, fn in ipairs(listeners) do pcall(fn) end
end

local board = Rocket.NewBoard()

------------------------------------------------------------------------------------------
-- The clock: server time to a fraction of a second. GetServerTime() only counts whole seconds, so the offset
-- from the local clock is the largest value seen: the sample taken right after the server's tick is the true one.
------------------------------------------------------------------------------------------

local offset, lastLocal
function RocketNet.Now()
    local l = GetTime()
    local o = GetServerTime() - l
    local dt = lastLocal and math.max(0, l - lastLocal) or 0
    lastLocal = l
    if offset then offset = math.max(offset - 0.0005 * dt, o) else offset = o end     -- (a hair of decay follows clock drift)
    return l + offset
end

------------------------------------------------------------------------------------------
-- State
------------------------------------------------------------------------------------------

local function store()
    local d = db()
    d.rocket = d.rocket or {}
    return d.rocket
end

local function houseRec(host)
    local d = db()
    return host and d and d.houses and d.houses[host]
end

-- Everything the window needs, or nil if no house is picked yet or its rocket is unknown.
function RocketNet.View()
    if not db() then return nil end
    local s = store()
    local rec = houseRec(s.host)
    if not (rec and rec.seed and rec.minBet) then return nil end
    local now = RocketNet.Now()
    local st = Rocket.State(rec.seed, now)
    local bet = s.bet and s.bet.host == s.host and s.bet or nil
    local v = { host = s.host, rec = rec, now = now, state = st, bet = bet, minBet = rec.minBet, maxBet = rec.maxBet,
                open = rec.on ~= false, result = s.lastResult }
    v.thisRows = Rocket.BoardRows(board, s.host, st.id)
    if st.last then v.lastRows = Rocket.BoardRows(board, s.host, st.last.id, st.last.crash100) end
    return v
end

-- Pick the house whose rocket I watch. Returns true, or nil, message.
function RocketNet.Open(host)
    host = baseName(host)
    local rec = houseRec(host)
    if not (rec and rec.minBet) then return nil, ("%s's house has not been heard yet. They need to be online once."):format(tostring(host)) end
    if not rec.seed then return nil, host .. "'s house needs the newest SteveBook before its rocket can fly." end
    if rec.on == false then return nil, host .. "'s house is closed right now." end
    local d = db()
    d.lobbyJoined = true                                  -- hear the bookie's announcements and the other players
    ns.Comm.JoinBook(ns.Protocol.LOBBY_CODE)
    store().host = host
    changed()
    return true
end

------------------------------------------------------------------------------------------
-- My bet
------------------------------------------------------------------------------------------

local function send(msgType, payload)
    ns.Comm.JoinBook(ns.Protocol.LOBBY_CODE)
    ns.Comm.Send(msgType, payload, ns.Protocol.LOBBY_CODE)
end

-- Bet `amount` copper on the next launch; `autoX` (like 2.5) is an optional multiplier to bail at by itself.
function RocketNet.PlaceBet(amount, autoX)
    local s = store()
    local host = s.host
    local rec = houseRec(host)
    if not (rec and rec.seed) then return nil, "Open the rocket from the casino window first." end
    if rec.on == false then return nil, host .. "'s house is closed right now." end
    RocketNet.Tick()                                      -- settle a bet from an earlier round first
    local now = RocketNet.Now()
    local st = Rocket.State(rec.seed, now)
    if st.phase ~= "waiting" or st.toLaunch < 0.3 then return nil, "The rocket is flying. Bet in the pause before the next launch." end
    if s.bet then return nil, s.bet.id == st.id and "You already bet on this launch." or "Your last bet is still on the rocket." end
    local ok, why, limit = Rocket.CheckStake(amount, rec.minBet, rec.maxBet)
    if not ok then
        if why == "minimum" then return nil, "The minimum bet is " .. money(limit) .. "." end
        if why == "maximum" then return nil, "The maximum bet is " .. money(limit) .. "." end
        return nil, why
    end
    local auto
    if autoX ~= nil then
        local err
        auto, err = Rocket.ParseAuto(autoX)
        if not auto then return nil, err end
    end
    s.bet = { host = host, id = st.id, amount = amount, auto = auto }
    Rocket.BoardBet(board, host, st.id, me(), amount, now)
    send("ROCKET_BET", { house = host, id = st.id, amount = amount })
    changed()
    return true
end

-- Bail now. Returns true, m100, or nil, message.
local BAIL_TEXT = {
    crashed = "Too late: it exploded.",
    already = "You already bailed.",
    not_launched = "It has not launched yet.",
    no_round = "There is no rocket right now.",
}
function RocketNet.Bail()
    local bet = store().bet
    if not bet then return nil, "You have no bet on the rocket." end
    local rec = houseRec(bet.host)
    if not (rec and rec.seed) then return nil, BAIL_TEXT.no_round end
    local now = RocketNet.Now()
    local ok, m = Rocket.Bail(rec.seed, bet, now)
    if not ok then return nil, BAIL_TEXT[m] or m end
    Rocket.BoardBail(board, bet.host, bet.id, me(), m, Rocket.Round(rec.seed, bet.id).crash100, now)
    send("ROCKET_BAIL", { house = bet.host, id = bet.id, m100 = m })
    changed()
    return true, m
end

-- The round is over: count it in the house report and say how it went.
local function settle(bet, res)
    local d = db()
    House.RecordPlain(House.Record(d, bet.host), "rocket", bet.amount, res.net)
    local s = store()
    s.bet = nil
    s.lastResult = { id = bet.id, host = bet.host, crash100 = res.crash100, bail100 = res.bail100, amount = bet.amount, net = res.net }
    if res.bail100 then
        say(("The rocket exploded at %s. You bailed at %s and %s %s%s|r."):format(Rocket.Format(res.crash100),
            Rocket.Format(res.bail100), res.net >= 0 and "won" or "lost", res.net >= 0 and GREEN or RED, money(math.abs(res.net))))
    else
        say(("The rocket exploded at %s. You did not bail and lost %s%s|r."):format(Rocket.Format(res.crash100), RED, money(bet.amount)))
    end
    if ns.CasinoNet and ns.CasinoNet.ReportSoon then ns.CasinoNet.ReportSoon(bet.host) end
    changed()
end

-- About four times a second: carry out a standing auto-bail and settle a bet whose round is over. (It also runs
-- from the window and after a reload, so a bet is never forgotten.)
function RocketNet.Tick()
    if not db() then return end
    local bet = store().bet
    if not bet then return end
    local rec = houseRec(bet.host)
    if not (rec and rec.seed) then return end
    local now = RocketNet.Now()
    local round = Rocket.Round(rec.seed, bet.id)
    if not round then store().bet = nil; return end
    local m = Rocket.AutoBail(rec.seed, bet, now)
    if m and now < round.explodeAt then                   -- tell the others while it still matters
        Rocket.BoardBail(board, bet.host, bet.id, me(), m, round.crash100, now)
        send("ROCKET_BAIL", { house = bet.host, id = bet.id, m100 = m })
        changed()
    end
    local res = Rocket.Settle(rec.seed, bet, now)
    if res then settle(bet, res) end
end

------------------------------------------------------------------------------------------
-- Other players (their messages only decorate the board; the rocket itself is worked out here)
------------------------------------------------------------------------------------------

-- The round a message is about, if it is recent enough to matter.
local function recentRound(rec, id, now)
    local r = Rocket.Round(rec.seed, id)
    if r and r.explodeAt > now - 60 and r.startAt < now + 30 then return r end
end

local function onBet(sender, p)
    local host = baseName(p.house)
    local rec = houseRec(host)
    if not (rec and rec.seed and rec.minBet) then return end
    local now = RocketNet.Now()
    if not recentRound(rec, p.id, now) then return end
    if not Rocket.CheckStake(p.amount, rec.minBet, rec.maxBet) then return end
    if Rocket.BoardBet(board, host, p.id, sender, p.amount, now) then changed() end
end

local function onBail(sender, p)
    local host = baseName(p.house)
    local rec = houseRec(host)
    if not (rec and rec.seed) then return end
    local now = RocketNet.Now()
    local r = recentRound(rec, p.id, now)
    if not r then return end
    if Rocket.BoardBail(board, host, p.id, sender, p.m100, r.crash100, now) then changed() end
end

------------------------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------------------------

local registered
function RocketNet.Init()
    if registered or not (ns.Comm and ns.Comm.Register) then return end
    registered = true
    ns.Comm.Register("ROCKET_BET", onBet)
    ns.Comm.Register("ROCKET_BAIL", onBail)
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(0.25, RocketNet.Tick)
        C_Timer.NewTicker(30, function() Rocket.BoardPrune(board, RocketNet.Now(), BOARD_KEEP) end)
    end
    if C_Timer and C_Timer.After then C_Timer.After(3, RocketNet.Tick) end         -- a bet from before a reload
end

RocketNet.board = board
return RocketNet
