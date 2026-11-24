-- Rocket.lua: the rocket game (SPEC §11c). Pure Lua: no WoW API calls; every function takes the time it needs.
--
-- A rocket launches, climbs and explodes, over and over, for everyone at a house (see House.lua), whether or
-- not the bookie is online. There is no host: the rocket is a pure function of a seed (the bookie's, announced
-- in LOBBY_HOUSE) and the SERVER clock, so every client that knows the seed sees the same rocket at the same
-- moment, with no messages during the round. Players bet before the launch and bail while it climbs; a player
-- who has not bailed when it explodes loses the stake.
--
-- Time is cut into eras of Rocket.ERA seconds. In an era the rounds follow one another: the betting window
-- (Rocket.PAUSE seconds, which is also the pause after an explosion), the flight, the explosion, the next window.
-- A round that would not be over before the era ends is not flown; the era's last seconds are idle.
-- The multiplier at t seconds after the launch is e^(RATE * t). The crash point is drawn from the seed and the
-- round: it reaches x with probability about (100 - EDGE)% / x, so the house keeps about EDGE percent whenever
-- a player bails (and the rocket never climbs past MAX100 / 100).
-- Multipliers are integers in hundredths ("m100": 250 = 2.50x). A bail at m100 wins floor(stake * m100 / 100),
-- stake included, and counts only if m100 is below the crash point.
local ADDON, ns = ...
ns = ns or {}

local Rocket = {}
ns.Rocket = Rocket

Rocket.RATE = 0.08            -- per second: 2x after 8.7 s, 10x after 29 s
Rocket.EDGE = 2               -- percent
Rocket.MAX100 = 5000          -- the rocket explodes by 50.00x at the latest
Rocket.PAUSE = 10             -- seconds of betting before each launch (and after each explosion)
Rocket.MIN_FLIGHT = 1         -- even an instant crash is on show this long
Rocket.ERA = 1800
Rocket.ROUNDS_PER_ERA = 1000  -- round ids are era * 1000 + k
Rocket.RECENT = 12            -- crash points kept for the history strip
Rocket.STEP = 100             -- stakes are whole silver (Odds.STAKE_STEP)

local P = 67108859            -- 2^26 - 5, a prime: squares stay below 2^53, so the arithmetic is exact in doubles

------------------------------------------------------------------------------------------
-- The numbers
------------------------------------------------------------------------------------------

-- A number in [0, 1) that depends only on the seed and the round id. (Squaring modulo a prime gives the
-- non-linearity: a plain linear generator would make neighbouring rounds follow a pattern.)
local function unit(seed, id)
    local x = ((seed or 0) % P + (id % P) * 1237 + 17) % P
    for i = 1, 5 do x = (x * x + 40503 + i * 977) % P end
    local y = (x * x + 31337) % P
    return (x + y / P) / P
end
Rocket.Unit = unit

-- The crash point of a round in hundredths: 100 (1.00x, an instant crash) to MAX100.
function Rocket.Crash100(seed, id)
    local c = math.floor((100 - Rocket.EDGE) / (1 - unit(seed, id)))
    if c < 100 then c = 100 end
    if c > Rocket.MAX100 then c = Rocket.MAX100 end
    return c
end

-- The multiplier (hundredths) t seconds after the launch.
function Rocket.Mult100(t)
    if t < 0 then return 100 end
    return math.floor(100 * math.exp(Rocket.RATE * t))
end

-- Seconds after the launch at which the multiplier reaches m100.
function Rocket.TimeFor(m100) return math.log(m100 / 100) / Rocket.RATE end

function Rocket.Format(m100) return ("%.2fx"):format(m100 / 100) end

------------------------------------------------------------------------------------------
-- The schedule
------------------------------------------------------------------------------------------

local cache, cacheN = {}, 0

-- The rounds of one era: list of { id, startAt, launchAt, crash100, flight, explodeAt } (server time).
function Rocket.Schedule(seed, era)
    local key = tostring(seed) .. ":" .. era
    local list = cache[key]
    if list then return list end
    list = {}
    local base, S, k = era * Rocket.ERA, era * Rocket.ERA, 0
    while k < Rocket.ROUNDS_PER_ERA do
        local id = era * Rocket.ROUNDS_PER_ERA + k
        local c = Rocket.Crash100(seed, id)
        local flight = math.max(Rocket.MIN_FLIGHT, Rocket.TimeFor(c))
        local L = S + Rocket.PAUSE
        local E = L + flight
        if E > base + Rocket.ERA then break end
        list[#list + 1] = { id = id, startAt = S, launchAt = L, crash100 = c, flight = flight, explodeAt = E }
        S, k = E, k + 1
    end
    if cacheN >= 6 then cache, cacheN = {}, 0 end
    cache[key] = list
    cacheN = cacheN + 1
    return list
end

-- One round by id, or nil.
function Rocket.Round(seed, id)
    if type(id) ~= "number" or id < 0 or id ~= math.floor(id) then return nil end
    local era, k = math.floor(id / Rocket.ROUNDS_PER_ERA), id % Rocket.ROUNDS_PER_ERA
    return Rocket.Schedule(seed, era)[k + 1]
end

-- The rounds that ended before `r`, newest first (up to `n`), reaching into the era before if need be.
local function before(seed, era, index, n)
    local out = {}
    local e, i = era, index - 1
    while #out < n do
        local list = Rocket.Schedule(seed, e)
        if i < 1 then
            if e <= era - 1 then break end                       -- one era back is enough
            e, i = e - 1, #Rocket.Schedule(seed, e - 1)
        else
            out[#out + 1] = list[i]; i = i - 1
        end
    end
    return out
end

-- What the rocket is doing at server time `now`:
--   { id, phase = "waiting" | "flying", startAt, launchAt, explodeAt,
--     toLaunch (waiting), t (seconds since the launch), m100 (flying: the multiplier on show),
--     last = { id, crash100, explodeAt } (the round before), recent = { crash100, ... } newest first,
--     past = { { id, crash100, explodeAt }, ... } the same rounds with their times, idle = true }
-- The crash point of the round in progress is NOT part of the state (it is only known once it is over).
function Rocket.State(seed, now)
    local era = math.floor(now / Rocket.ERA)
    local list = Rocket.Schedule(seed, era)
    local cur, index
    for i, r in ipairs(list) do
        if now < r.explodeAt then cur, index = r, i; break end
    end
    local idle = false
    if not cur then                                              -- the end of the era: wait for the next one
        local nextList = Rocket.Schedule(seed, era + 1)
        cur, index, era, idle = nextList[1], 1, era + 1, true
    end
    local st = { id = cur.id, startAt = cur.startAt, launchAt = cur.launchAt, explodeAt = cur.explodeAt, idle = idle or nil }
    st.t = now - cur.launchAt
    if now < cur.launchAt then
        st.phase, st.toLaunch = "waiting", cur.launchAt - now
    else
        st.phase = "flying"
        st.m100 = math.min(Rocket.Mult100(st.t), cur.crash100)
    end
    local prev = before(seed, era, index, Rocket.RECENT)
    st.recent, st.past = {}, {}
    for i, r in ipairs(prev) do
        st.recent[i] = r.crash100
        st.past[i] = { id = r.id, crash100 = r.crash100, explodeAt = r.explodeAt }
    end
    if prev[1] then st.last = { id = prev[1].id, crash100 = prev[1].crash100, explodeAt = prev[1].explodeAt } end
    return st
end

------------------------------------------------------------------------------------------
-- A bet
-- bet = { host, id, amount, auto = m100 to bail at by itself | nil, bail = m100 bailed at | nil }
------------------------------------------------------------------------------------------

-- Is this stake allowed? Returns true, or false, message.
function Rocket.CheckStake(amount, minBet, maxBet)
    if type(amount) ~= "number" or amount <= 0 or amount ~= math.floor(amount) or amount % Rocket.STEP ~= 0 then
        return false, "Bets are whole silver."
    end
    if minBet and amount < minBet then return false, "minimum", minBet end
    if maxBet and amount > maxBet then return false, "maximum", maxBet end
    return true
end

-- An auto-bail target such as 2.5 (x): returns hundredths, or nil, message.
function Rocket.ParseAuto(x)
    if x == nil then return nil end
    if type(x) ~= "number" then return nil, "Auto bail is a number like 2.5." end
    local m = math.floor(x * 100 + 0.5)
    if m < 101 or m >= Rocket.MAX100 then
        return nil, ("Auto bail must be between %s and %s."):format(Rocket.Format(101), Rocket.Format(Rocket.MAX100 - 1))
    end
    return m
end

-- Bail now. Returns true, m100, or nil, reason ("not_launched" | "already" | "crashed" | "no_round").
-- "crashed" means the rocket has already exploded (the bet is lost); a bail is never accepted at or past the crash point.
function Rocket.Bail(seed, bet, now)
    local r = Rocket.Round(seed, bet.id)
    if not r then return nil, "no_round" end
    if bet.bail then return nil, "already" end
    if now < r.launchAt then return nil, "not_launched" end
    local m = Rocket.Mult100(now - r.launchAt)
    if m >= r.crash100 then return nil, "crashed" end
    bet.bail = m
    return true, m
end

-- A standing auto-bail order: once the multiplier has reached the target, bail at exactly the target (if the
-- rocket is still climbing). Returns the m100 bailed at, or nil.
function Rocket.AutoBail(seed, bet, now)
    if not bet.auto or bet.bail then return nil end
    local r = Rocket.Round(seed, bet.id)
    if not r or now < r.launchAt then return nil end
    if Rocket.Mult100(now - r.launchAt) < bet.auto then return nil end       -- not there yet
    if bet.auto >= r.crash100 then return nil end                            -- it exploded first
    bet.bail = bet.auto
    return bet.auto
end

-- The bet's outcome once the round is over, else nil:
--   { crash100, bail100 | nil, win (copper returned, stake included), net }
function Rocket.Settle(seed, bet, now)
    local r = Rocket.Round(seed, bet.id)
    if not r or now < r.explodeAt then return nil end
    local bail = bet.bail
    if not bail and bet.auto and bet.auto < r.crash100 then bail = bet.auto end      -- a standing order works while you are away
    if bail and bail >= r.crash100 then bail = nil end
    local win = bail and math.floor(bet.amount * bail / 100) or 0
    return { crash100 = r.crash100, bail100 = bail, win = win, net = win - bet.amount }
end

------------------------------------------------------------------------------------------
-- The board: what other players are doing (from their messages)
-- board.rounds[house .. ":" .. id] = { at, order = { names }, by = { [name] = { amount, bail } } }
------------------------------------------------------------------------------------------

Rocket.BOARD_MAX = 12            -- names shown per round

function Rocket.NewBoard() return { rounds = {} } end

local function entry(board, house, id, now, create)
    local key = house .. ":" .. id
    local e = board.rounds[key]
    if not e and create then e = { at = now, order = {}, by = {} }; board.rounds[key] = e end
    return e
end

local function slot(e, name, create)
    local s = e.by[name]
    if not s and create then
        if #e.order >= Rocket.BOARD_MAX then return nil end
        s = {}; e.by[name] = s; e.order[#e.order + 1] = name
    end
    return s
end

-- A bet was placed. The first message of a player counts. Returns true if it was recorded.
function Rocket.BoardBet(board, house, id, name, amount, now)
    local e = entry(board, house, id, now, true)
    local s = slot(e, name, true)
    if not s or s.amount then return false end
    s.amount = amount
    return true
end

-- A bail was claimed at m100; `crash100` is the round's crash point, which every client can compute, so a claim at
-- or past it (or before the rocket moved) is not believed. Returns true if recorded.
function Rocket.BoardBail(board, house, id, name, m100, crash100, now)
    if type(m100) ~= "number" or m100 < 100 or m100 >= crash100 then return false end
    local e = entry(board, house, id, now, true)
    local s = slot(e, name, true)
    if not s or s.bail then return false end
    s.bail = m100
    return true
end

-- The players of a round, in the order they were heard. Pass `crash100` once the round is over: a player who
-- did not bail has crashed. Rows: { name, amount, bail100, status = "flying" | "bailed" | "crashed", net }.
function Rocket.BoardRows(board, house, id, crash100)
    local e = entry(board, house, id, 0, false)
    local rows = {}
    if not e then return rows end
    for _, name in ipairs(e.order) do
        local s = e.by[name]
        local row = { name = name, amount = s.amount, bail100 = s.bail }
        if s.bail then
            row.status = "bailed"
            if s.amount then row.net = math.floor(s.amount * s.bail / 100) - s.amount end
        elseif crash100 then
            row.status = "crashed"
            if s.amount then row.net = -s.amount end
        else
            row.status = "flying"
        end
        rows[#rows + 1] = row
    end
    return rows
end

-- Forget rounds not touched for `maxAge` seconds.
function Rocket.BoardPrune(board, now, maxAge)
    for key, e in pairs(board.rounds) do
        if now - e.at > maxAge then board.rounds[key] = nil end
    end
end

return Rocket
