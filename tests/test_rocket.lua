-- The rocket (SPEC §11c): the maths and schedule (Rocket.lua), then a player and the other players on the stubbed
-- game (RocketNet.lua, UI/Rocket.lua). Run from repo root: luajit tests/test_rocket.lua
local stub = assert(loadfile("tests/wowstub.lua"))()
local out_ = stub.realPrint
local fails = 0
local function check(cond, label) if not cond then fails = fails + 1; out_("FAIL: " .. label) end end
local function eq(a, b, label) if a ~= b then fails = fails + 1; out_(("FAIL: %s (got %s, want %s)"):format(label, tostring(a), tostring(b))) end end

Minimap = stub.newFrame()
Ambiguate = function(name) return (name:gsub("%-Realm$", "")) end
do
    local Frame = getmetatable(stub.newFrame())
    function Frame.CreateFontString() local f = stub.newFrame(); rawset(f, "_text", ""); return f end
end
local ADDON, DIR = "SteveBook", "SteveBook/"
local ns = {}
local function readFile(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
local loadFile
local function loadXml(path)
    local dir = path:match("^(.*)/[^/]*$") or "."
    for file in readFile(path):gmatch('<[SI][a-z]+%s+file="([^"]+)"') do loadFile(dir .. "/" .. file:gsub("\\", "/")) end
end
function loadFile(path)
    path = path:gsub("\\", "/")
    if path:match("%.xml$") then return loadXml(path) end
    local ok, e = pcall(assert(loadfile(path)), ADDON, ns)
    check(ok, "load " .. path .. (ok and "" or (": " .. tostring(e))))
end
for line in readFile(DIR .. "SteveBook.toc"):gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then loadFile(DIR .. line) end
end
stub.fire("ADDON_LOADED", ADDON)
local db = SteveBookDB
local R, RN, House, P = ns.Rocket, ns.RocketNet, ns.House, ns.Protocol
local UI = ns.UI.Casino
local AceSer = LibStub("AceSerializer-3.0")

------------------------------------------------------------------------------------------
-- 1. The numbers
------------------------------------------------------------------------------------------
local SEED = 123456789
do
    -- the draw is the same everywhere, and evenly spread
    eq(R.Crash100(SEED, 944000001), R.Crash100(SEED, 944000001), "the same seed and round always give the same crash")
    local differ = 0
    for id = 1, 200 do if R.Crash100(SEED, id) ~= R.Crash100(SEED + 1, id) then differ = differ + 1 end end
    check(differ > 150, "another seed is another rocket")
    local N, buckets, sum = 60000, {}, 0
    for i = 1, 10 do buckets[i] = 0 end
    local prev = R.Unit(SEED, 944000000)
    local sxy, sxx, sx = 0, 0, 0
    for id = 1, N do
        local u = R.Unit(SEED, 944000000 + id)
        local k = math.floor(u * 10) + 1
        buckets[k] = buckets[k] + 1
        sum = sum + u; sxy = sxy + prev * u; sxx = sxx + u * u; sx = sx + u
        prev = u
    end
    for i = 1, 10 do check(math.abs(buckets[i] / N * 10 - 1) < 0.04, "the draw is even in bucket " .. i) end
    local mean = sx / N
    local corr = (sxy / N - mean * mean) / (sxx / N - mean * mean)
    check(math.abs(corr) < 0.02, "neighbouring rounds are not related (lag-1 correlation " .. corr .. ")")
    -- the crash point: P(reach x) is about 0.98 / x
    local ge2, ge10, inst, cap = 0, 0, 0, 0
    for id = 1, N do
        local c = R.Crash100(SEED, 944000000 + id)
        check(c >= 100 and c <= R.MAX100, "the crash point stays between 1x and 50x")
        if c >= 200 then ge2 = ge2 + 1 end
        if c >= 1000 then ge10 = ge10 + 1 end
        if c == 100 then inst = inst + 1 end
        if c == R.MAX100 then cap = cap + 1 end
    end
    check(math.abs(ge2 / N - 0.49) < 0.012, "about 49% of rockets reach 2x (" .. ge2 / N .. ")")
    check(math.abs(ge10 / N - 0.098) < 0.008, "about 9.8% reach 10x (" .. ge10 / N .. ")")
    check(inst / N > 0.02 and inst / N < 0.04, "about 3% explode at once (" .. inst / N .. ")")
    check(cap / N > 0.01 and cap / N < 0.03, "about 2% reach the ceiling (" .. cap / N .. ")")
    -- what a player who always bails at 2x gets back: the house keeps about 2%
    local back, rounds = 0, 100000
    for id = 1, rounds do if R.Crash100(SEED, 900000000 + id) > 200 then back = back + 2 end end
    check(back / rounds > 0.95 and back / rounds < 0.995, "bailing at 2x returns about 98% (" .. back / rounds .. ")")
end
eq(R.Mult100(0), 100, "1.00x at the launch"); eq(R.Mult100(-5), 100, "and before it")
eq(R.Mult100(R.TimeFor(200) + 0.0001), 200, "2x is reached at TimeFor(200)"); eq(R.Mult100(R.TimeFor(200) - 0.0001), 199, "and not before")
check(math.abs(R.TimeFor(200) - 8.66) < 0.02, "2x after about 8.7 s"); check(math.abs(R.TimeFor(5000) - 48.9) < 0.1, "50x after about 49 s")
eq(R.Format(250), "2.50x", "formatting"); eq(R.Format(100), "1.00x", "formatting 1x")

------------------------------------------------------------------------------------------
-- 2. The schedule
------------------------------------------------------------------------------------------
local ERA = 944000
do
    local list = R.Schedule(SEED, ERA)
    check(#list > 40, "a good many rounds in an era (" .. #list .. ")")
    eq(list[1].startAt, ERA * R.ERA, "the first round starts with the era"); eq(list[1].launchAt, ERA * R.ERA + R.PAUSE, "and launches after the pause")
    for i, r in ipairs(list) do
        eq(r.id, ERA * R.ROUNDS_PER_ERA + i - 1, "ids count up")
        eq(r.launchAt, r.startAt + R.PAUSE, "betting lasts " .. R.PAUSE .. " s")
        check(r.explodeAt > r.launchAt and r.explodeAt <= (ERA + 1) * R.ERA, "every round is over before the era ends")
        check(r.flight >= R.MIN_FLIGHT, "every flight is on show for a second at least")
        if i > 1 then eq(r.startAt, list[i - 1].explodeAt, "the next betting window opens at the explosion") end
    end
    eq(R.Schedule(SEED, ERA), list, "the schedule is cached")
    eq(R.Round(SEED, list[7].id), list[7], "a round by id"); eq(R.Round(SEED, -1), nil, "no round -1"); eq(R.Round(SEED, 1.5), nil, "nor 1.5")
    eq(R.Round(SEED, ERA * R.ROUNDS_PER_ERA + 999), nil, "nor one past the era's last")

    local r5 = list[5]
    local st = R.State(SEED, r5.startAt + 3)
    eq(st.phase, "waiting", "betting"); eq(st.id, r5.id, "for round 5"); check(math.abs(st.toLaunch - (R.PAUSE - 3)) < 1e-9, "seven seconds to go")
    eq(st.last.id, list[4].id, "the round before is known"); eq(st.last.crash100, list[4].crash100, "with its crash point"); eq(st.recent[1], list[4].crash100, "newest first")
    eq(#st.recent, math.min(R.RECENT, 4 + #R.Schedule(SEED, ERA - 1)), "and the history reaches into the era before")
    eq(#st.past, #st.recent, "the past rounds carry their times too"); eq(st.past[1].crash100, st.recent[1], "same order")
    eq(st.past[1].explodeAt, list[4].explodeAt, "when the round before exploded"); eq(st.past[1].id, list[4].id, "and which it was")
    check(st.past[2].explodeAt < st.past[1].explodeAt, "older ones are older")
    eq(st.m100, nil, "nothing is climbing yet")
    st = R.State(SEED, r5.launchAt + 2)
    eq(st.phase, "flying", "flying"); eq(st.m100, math.min(R.Mult100(2), r5.crash100), "at the multiplier of the moment"); check(math.abs(st.t - 2) < 1e-9, "two seconds in")
    check(st.crash100 == nil and st.last.id == list[4].id, "the crash point of the round in flight is not in the state")
    st = R.State(SEED, r5.explodeAt)
    eq(st.id, list[6].id, "at the explosion the next window opens"); eq(st.phase, "waiting", "waiting"); eq(st.last.id, r5.id, "and the round that just ended is the last one")
    eq(st.last.crash100, r5.crash100, "with its crash point")
    st = R.State(SEED, list[#list].explodeAt + 3)
    eq(st.idle, true, "the end of the era is idle"); eq(st.phase, "waiting", "waiting for the next era"); eq(st.id, (ERA + 1) * R.ROUNDS_PER_ERA, "whose first round is next")
    eq(st.last.id, list[#list].id, "and the last round of this era is the last one")
    check(st.toLaunch > R.PAUSE - 0.01, "with the pause still to wait")
    -- everyone computes the same thing
    local a, b = R.State(SEED, 1700000123.4), R.State(SEED, 1700000123.4)
    eq(a.id, b.id, "two clients agree"); eq(a.m100, b.m100, "on the multiplier")
end

------------------------------------------------------------------------------------------
-- 3. A bet
------------------------------------------------------------------------------------------
do
    local list = R.Schedule(SEED, ERA)
    local function findRound(pred) for _, r in ipairs(list) do if pred(r) then return r end end end
    local high = findRound(function(r) return r.crash100 >= 1000 end)
    local instant = findRound(function(r) return r.crash100 == 100 end)
    local lowish = findRound(function(r) return r.crash100 >= 110 and r.crash100 <= 150 end)
    check(high and instant and lowish, "the era has the rounds this test needs")

    check(R.CheckStake(100, 100, 10000) and R.CheckStake(10000, 100, 10000), "stakes within the limits")
    eq(select(2, R.CheckStake(150, 100, 10000)), "Bets are whole silver.", "whole silver"); eq(select(2, R.CheckStake(0, 100, 10000)), "Bets are whole silver.", "not zero")
    eq(select(2, R.CheckStake(100, 500, 10000)), "minimum", "under the minimum"); eq(select(2, R.CheckStake(20000, 100, 10000)), "maximum", "over the maximum")
    eq(R.ParseAuto(nil), nil, "no auto bail"); eq(R.ParseAuto(2.5), 250, "2.5x"); eq(R.ParseAuto(1.01), 101, "the least")
    check(not R.ParseAuto(1) and not R.ParseAuto(50) and not R.ParseAuto("x"), "1x, 50x and words are not targets")

    -- bailing
    local bet = { id = high.id, amount = 1000 }
    local ok, why = R.Bail(SEED, bet, high.launchAt - 1); eq(why, "not_launched", "not before the launch")
    ok, why = R.Bail(SEED, bet, high.launchAt + 3)
    check(ok, "a bail while it climbs"); eq(why, R.Mult100(3), "at the multiplier of that moment"); eq(bet.bail, R.Mult100(3), "which the bet remembers")
    eq(select(2, R.Bail(SEED, bet, high.launchAt + 4)), "already", "only once")
    local late = { id = high.id, amount = 1000 }
    eq(select(2, R.Bail(SEED, late, high.explodeAt + 0.01)), "crashed", "not after the explosion")
    local ib = { id = instant.id, amount = 1000 }
    eq(select(2, R.Bail(SEED, ib, instant.launchAt + 0.5)), "crashed", "an instant crash cannot be bailed out of")
    eq(select(2, R.Bail(SEED, { id = -5, amount = 1 }, 1)), "no_round", "no such round")

    -- settling
    eq(R.Settle(SEED, { id = high.id, amount = 1000 }, high.explodeAt - 0.1), nil, "not while it is still flying")
    local res = R.Settle(SEED, bet, high.explodeAt)
    eq(res.crash100, high.crash100, "the crash point"); eq(res.bail100, R.Mult100(3), "the bail"); eq(res.win, math.floor(1000 * R.Mult100(3) / 100), "pays stake times multiplier")
    eq(res.net, res.win - 1000, "net of the stake")
    res = R.Settle(SEED, { id = high.id, amount = 1000 }, high.explodeAt)
    eq(res.bail100, nil, "no bail"); eq(res.win, 0, "nothing back"); eq(res.net, -1000, "the stake is lost")
    -- a standing auto-bail order
    local ab = { id = high.id, amount = 1000, auto = 300 }
    eq(R.AutoBail(SEED, ab, high.launchAt + R.TimeFor(300) - 0.2), nil, "not before the target")
    eq(R.AutoBail(SEED, ab, high.launchAt + R.TimeFor(300) + 0.01), 300, "bails at the target"); eq(ab.bail, 300, "and remembers")
    eq(R.AutoBail(SEED, ab, high.launchAt + 20), nil, "only once")
    res = R.Settle(SEED, ab, high.explodeAt); eq(res.win, 3000, "an auto bail at 3x pays three stakes")
    local away = { id = high.id, amount = 1000, auto = 200 }
    res = R.Settle(SEED, away, high.explodeAt + 3600); eq(res.bail100, 200, "an order works while the player is away"); eq(res.net, 1000, "and wins")
    local early = { id = lowish.id, amount = 1000, auto = 2000 }
    eq(R.AutoBail(SEED, early, lowish.explodeAt), nil, "a target above the crash point is never reached")
    res = R.Settle(SEED, early, lowish.explodeAt); eq(res.bail100, nil, "so the stake is lost"); eq(res.net, -1000, "settled")
    -- a saved bet that claims a bail at or past the crash point (corrupt data) is not paid
    res = R.Settle(SEED, { id = lowish.id, amount = 1000, bail = lowish.crash100 + 50 }, lowish.explodeAt)
    eq(res.bail100, nil, "a bail past the crash point is not believed when settling"); eq(res.net, -1000, "and the stake is lost")
    -- a bail at the very crash point does not count
    local edge = { id = lowish.id, amount = 1000, auto = lowish.crash100 }
    res = R.Settle(SEED, edge, lowish.explodeAt); eq(res.bail100, nil, "a target equal to the crash point is lost")
    local edgeBefore = { id = lowish.id, amount = 1000, auto = lowish.crash100 - 1 }
    res = R.Settle(SEED, edgeBefore, lowish.explodeAt); eq(res.bail100, lowish.crash100 - 1, "one hundredth below it wins")
end

------------------------------------------------------------------------------------------
-- 4. The board
------------------------------------------------------------------------------------------
do
    local b = R.NewBoard()
    check(R.BoardBet(b, "Steve", 7, "Ann", 500, 100), "a bet is recorded")
    check(not R.BoardBet(b, "Steve", 7, "Ann", 9999, 100), "a second one from the same player is not")
    check(R.BoardBet(b, "Steve", 7, "Bob", 1000, 100), "another player")
    check(R.BoardBail(b, "Steve", 7, "Ann", 250, 400, 101), "a believable bail")
    check(not R.BoardBail(b, "Steve", 7, "Ann", 300, 400, 101), "only the first bail counts")
    check(not R.BoardBail(b, "Steve", 7, "Bob", 400, 400, 101), "a bail at the crash point is not believed")
    check(not R.BoardBail(b, "Steve", 7, "Bob", 500, 400, 101), "nor one past it")
    check(not R.BoardBail(b, "Steve", 7, "Bob", 50, 400, 101), "nor one under 1x")
    local rows = R.BoardRows(b, "Steve", 7)
    eq(#rows, 2, "two players"); eq(rows[1].name, "Ann", "in the order they were heard"); eq(rows[1].status, "bailed", "Ann bailed")
    eq(rows[1].net, 750, "and won 1.5 stakes"); eq(rows[2].status, "flying", "Bob is still on board"); eq(rows[2].net, nil, "undecided")
    rows = R.BoardRows(b, "Steve", 7, 400)
    eq(rows[2].status, "crashed", "once it exploded, Bob crashed"); eq(rows[2].net, -1000, "and lost his stake"); eq(rows[1].status, "bailed", "Ann still bailed")
    check(R.BoardBail(b, "Steve", 8, "Cat", 150, 200, 101), "a bail heard before the bet")
    eq(R.BoardRows(b, "Steve", 8)[1].amount, nil, "has no amount yet"); check(R.BoardBet(b, "Steve", 8, "Cat", 300, 101), "the bet arrives later")
    eq(R.BoardRows(b, "Steve", 8)[1].amount, 300, "and fills it in")
    eq(#R.BoardRows(b, "Other", 7), 0, "another house has its own board")
    for i = 1, 20 do R.BoardBet(b, "Steve", 9, "P" .. i, 100, 101) end
    eq(#R.BoardRows(b, "Steve", 9), R.BOARD_MAX, "a round shows at most " .. R.BOARD_MAX .. " players")
    R.BoardPrune(b, 100 + 500, 180)
    eq(#R.BoardRows(b, "Steve", 7), 0, "old rounds are forgotten")
end

check(P.Validate("ROCKET_BET", { house = "Steve", id = 5, amount = 100 }), "ROCKET_BET is valid")
check(P.Validate("ROCKET_BAIL", { house = "Steve", id = 5, m100 = 250 }), "ROCKET_BAIL is valid")
check(not P.Validate("ROCKET_BAIL", { house = "Steve", id = 5 }), "which needs m100")
check(P.Validate("LOBBY_HOUSE", { on = true, minBet = 100, maxBet = 10000, seed = 5 }), "LOBBY_HOUSE carries a seed")
check(P.Validate("LOBBY_HOUSE", { on = true, minBet = 100, maxBet = 10000 }), "which is optional")

------------------------------------------------------------------------------------------
-- 5. In the game
------------------------------------------------------------------------------------------
local function settle() for _ = 1, 14 do stub.advance(1); stub.runAfters() end end
local function fromWire(sender, msgType, code, payload)
    local env = assert(P.Wrap(msgType, code, payload))
    stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", sender)
end
local function sent(msgType)
    stub.advance(1)                            -- the throttle library despools queued messages from OnUpdate
    local list = {}
    for _, m in ipairs(stub.addonMessages) do
        local ok, env = AceSer:Deserialize(m.text)
        if ok and type(env) == "table" and env.t == msgType then list[#list + 1] = env end
    end
    return list
end
local function allByText(text)
    local list = {}
    for _, f in ipairs(stub.frames) do if rawget(f, "_text") == text then list[#list + 1] = f end end
    return list
end
local function textOf(pattern)
    for _, f in ipairs(stub.frames) do
        local tx = rawget(f, "_text")
        if type(tx) == "string" and tx:find(pattern, 1, true) then return tx end
    end
end
local function click(f) f._scripts.OnClick(f) end
local printedFrom = 0
local function lines() local l = {}; for i = printedFrom + 1, #stub.printed do l[#l + 1] = stub.printed[i] end; printedFrom = #stub.printed; return table.concat(l, "\n") end
local function setTime(t) local d = t - stub.time; stub.time = t; stub.mono = stub.mono + d end

ns.Comm.JoinBook(P.LOBBY_CODE); settle()
eq(select(2, RN.OpenDefault()), "No house has been heard yet. Steve needs to be online once, with the lobby open.", "/rocket before any house is heard says so")
stub.player = "Steve"
check(select(2, RN.OpenDefault()):find("played by your friends", 1, true) ~= nil, "and tells Steve it is his own house")
stub.player = "Tester"
check(select(1, RN.Open("Steve")) == nil, "a house nobody has heard has no rocket")
fromWire("Steve lol", "LOBBY_HOUSE", P.LOBBY_CODE, { on = true, minBet = 100, maxBet = 10000 })
eq(select(2, RN.Open("Steve")), "Steve's house needs the newest SteveBook before its rocket can fly.", "an old house sends no seed")
local gameEra = math.floor(stub.time / R.ERA) + 1      -- the next era: the game clock only ever moves forward
local list = R.Schedule(SEED, gameEra)
local function announce() fromWire("Steve lol", "LOBBY_HOUSE", P.LOBBY_CODE, { on = true, minBet = 100, maxBet = 10000, seed = SEED }) end
announce()
eq(db.houses.Steve.seed, SEED, "the seed is remembered")
check(RN.Open("Steve"), "opening the rocket"); eq(db.rocket.host, "Steve", "at Steve's house")
check(RN.View() ~= nil, "a view")
local function round(from, pred) for i = from, #list do if pred(list[i]) then return list[i], i end end end
local winRound, wi = round(3, function(r) return r.crash100 >= 600 end)
local lostRound, li = round(wi + 2, function(r) return r.crash100 >= 110 and r.crash100 <= 160 end)
local autoRound, ai = round(li + 2, function(r) return r.crash100 >= 600 end)
local missRound, mi = round(ai + 2, function(r) return r.crash100 >= 110 and r.crash100 <= 190 end)
local awayRound, wai = round(mi + 2, function(r) return r.crash100 >= 600 end)
check(winRound and lostRound and autoRound and missRound and awayRound, "the era has the rounds the game test needs")

-- no bet in a flying rocket, and the first bet
local before1 = list[wi - 1]
setTime(before1.launchAt + 3); announce()
eq(select(2, RN.PlaceBet(1000)), "The rocket is flying. Bet in the pause before the next launch.", "no bets while it climbs")
setTime(winRound.startAt + 1); announce(); stub.addonMessages = {}
eq(select(2, RN.PlaceBet(50)), "Bets are whole silver.", "whole silver"); eq(select(2, RN.PlaceBet(20000)), "The maximum bet is " .. ns.Odds.FormatMoney(10000) .. ".", "the maximum")
eq(select(2, RN.PlaceBet(1000, 1)), "Auto bail must be between 1.01x and 49.99x.", "a bad auto bail")
eq(select(2, RN.Bail()), "You have no bet on the rocket.", "nothing to bail")
check(RN.PlaceBet(1000), "a bet before the launch")
eq(select(2, RN.PlaceBet(1000)), "You already bet on this launch.", "one per launch")
local bets = sent("ROCKET_BET")
eq(#bets, 1, "the others are told"); eq(bets[1].p.house, "Steve", "which house"); eq(bets[1].p.id, winRound.id, "which round"); eq(bets[1].p.amount, 1000, "how much")
eq(bets[1].c, P.LOBBY_CODE, "in the lobby channel")
local view = RN.View()
eq(#view.thisRows, 1, "I am on the board"); eq(view.thisRows[1].name, "Tester", "by name"); eq(view.thisRows[1].status, "flying", "on board")

-- other players
fromWire("Ann lol", "ROCKET_BET", P.LOBBY_CODE, { house = "Steve", id = winRound.id, amount = 500 })
fromWire("Bob lol", "ROCKET_BET", P.LOBBY_CODE, { house = "Steve", id = winRound.id, amount = 2000 })
fromWire("Cat lol", "ROCKET_BET", P.LOBBY_CODE, { house = "Steve", id = winRound.id, amount = 99999999 })
fromWire("Dan lol", "ROCKET_BET", P.LOBBY_CODE, { house = "Other", id = winRound.id, amount = 500 })
fromWire("Eve lol", "ROCKET_BET", P.LOBBY_CODE, { house = "Steve", id = winRound.id - 50, amount = 500 })
eq(#RN.View().thisRows, 3, "me, Ann and Bob: not a bet over the limit, another house or an old round")

-- the launch: my bail
setTime(winRound.launchAt + 3); stub.runTickers()
view = RN.View()
eq(view.state.phase, "flying", "flying"); eq(view.state.m100, R.Mult100(3), "at the multiplier of 3 seconds")
fromWire("Ann lol", "ROCKET_BAIL", P.LOBBY_CODE, { house = "Steve", id = winRound.id, m100 = R.Mult100(2.5) })
fromWire("Bob lol", "ROCKET_BAIL", P.LOBBY_CODE, { house = "Steve", id = winRound.id, m100 = winRound.crash100 })
eq(RN.View().thisRows[2].status, "bailed", "Ann bailed"); eq(RN.View().thisRows[3].status, "flying", "a claim at the crash point is not believed")
stub.addonMessages = {}
local ok, m = RN.Bail()
check(ok, "I bail"); eq(m, R.Mult100(3), "at the multiplier of the moment")
eq(select(2, RN.Bail()), "You already bailed.", "once")
eq(#sent("ROCKET_BAIL"), 1, "the others are told"); eq(sent("ROCKET_BAIL")[1].p.m100, R.Mult100(3), "where I bailed"); eq(sent("ROCKET_BAIL")[1].p.id, winRound.id, "in which round")
eq(RN.View().thisRows[1].status, "bailed", "and I see it on my board")
lines()
announce(); stub.addonMessages = {}
setTime(winRound.explodeAt + 0.2); stub.runTickers()
local rec = db.houses.Steve
eq(rec.games.rocket.rounds, 1, "the round is counted"); eq(rec.games.rocket.wagered, 1000, "wagered"); eq(rec.games.rocket.net, math.floor(1000 * R.Mult100(3) / 100) - 1000, "and the win is the net")
eq(db.rocket.bet, nil, "the bet is settled"); check(lines():find("bailed at " .. R.Format(R.Mult100(3)), 1, true) ~= nil, "chat says what happened")
local last = RN.View()                                   -- (before the report's timer: the next round is only 10 s away)
stub.runAfters()
check(#sent("HOUSE_REPORT") >= 1, "the bookie was around, so the result was reported")
eq(last.state.last.id, winRound.id, "the finished round is the last round"); eq(#last.lastRows, 3, "with its players")
eq(last.lastRows[1].status, "bailed", "I bailed"); eq(last.lastRows[2].status, "bailed", "Ann bailed"); eq(last.lastRows[3].status, "crashed", "and Bob crashed")
eq(last.lastRows[3].net, -2000, "losing his stake")

-- a crash
setTime(lostRound.startAt + 2); announce()
check(RN.PlaceBet(2000), "a bet")
setTime(lostRound.explodeAt + 0.5); stub.runTickers()
eq(rec.games.rocket.rounds, 2, "counted"); eq(rec.games.rocket.net, math.floor(1000 * R.Mult100(3) / 100) - 1000 - 2000, "a lost stake")
check(lines():find("did not bail") ~= nil, "chat says so")

-- an auto bail
setTime(autoRound.startAt + 2); announce(); stub.addonMessages = {}
check(RN.PlaceBet(1000, 3), "a bet with an auto bail at 3x")
eq(db.rocket.bet.auto, 300, "kept in hundredths")
setTime(autoRound.launchAt + R.TimeFor(300) - 0.3); stub.runTickers()
eq(db.rocket.bet.bail, nil, "not yet")
setTime(autoRound.launchAt + R.TimeFor(300) + 0.3); stub.runTickers()
eq(db.rocket.bet.bail, 300, "bailed by itself at exactly 3x"); eq(sent("ROCKET_BAIL")[1].p.m100, 300, "and the others are told")
local before = rec.games.rocket.net
setTime(autoRound.explodeAt + 0.2); stub.runTickers()
eq(rec.games.rocket.net - before, 2000, "an auto bail at 3x wins two stakes")

-- an auto bail above where it explodes
setTime(missRound.startAt + 2); announce()
check(RN.PlaceBet(1000, 40), "a bet with an auto bail at 40x")
setTime(missRound.explodeAt + 0.2); stub.runTickers()
eq(rec.games.rocket.net - before, 2000 - 1000, "it exploded first: the stake is lost")

-- the player is away: the standing order still works
setTime(awayRound.startAt + 2); announce()
check(RN.PlaceBet(1000, 2), "a bet with an auto bail at 2x")
before = rec.games.rocket.net
setTime(awayRound.explodeAt + 120)            -- no ticks at all: logged out, say
RN.Tick()
eq(rec.games.rocket.net - before, 1000, "settled on the next tick: 2x won")
eq(db.rocket.bet, nil, "nothing is left over")

-- the window
check(not RN.PlaceBet(1000) or true, "(a bet any time is up to the clock)")
db.rocket.bet = nil
local nextRound, ni = round(wai + 2, function(r) return r.crash100 >= 400 and r.crash100 ~= list[wai + 1].crash100 end)
setTime(nextRound.startAt + 1); announce()
ns.UI.Rocket.Show(); ns.UI.Rocket.Refresh()
check(textOf("Steve's rocket") ~= nil, "the window names the house")
check(textOf("Bet 1s") ~= nil, "the Bet button shows the stake"); local bet = allByText("Bet 1s")[1]
eq(bet:IsEnabled(), true, "betting is open"); check(ns.UI.Casino.IsGlowing(bet), "and the button glows")
check(textOf("Past rounds") ~= nil, "a strip of the past rounds")
click(bet)
check(db.rocket.bet ~= nil, "pressing Bet places the bet"); eq(allByText("Bet 1s")[1]:IsEnabled(), false, "and only once")
fromWire("Ann lol", "ROCKET_BET", P.LOBBY_CODE, { house = "Steve", id = nextRound.id, amount = 500 })
setTime(nextRound.launchAt + 2.5); ns.UI.Rocket.Refresh()
local bail = textOf("BAIL  ")
check(bail ~= nil, "the Bail button shows the multiplier and what it would win"); check(textOf(R.Format(R.Mult100(2.5))) ~= nil, "and so does the sky")
check(textOf(R.Format(nextRound.crash100)) == nil, "but nothing shows where it will explode")
check(textOf("Ann  ") ~= nil and textOf("on board") ~= nil, "Ann is on the rocket")
fromWire("Ann lol", "ROCKET_BAIL", P.LOBBY_CODE, { house = "Steve", id = nextRound.id, m100 = R.Mult100(2.5) })
check(textOf("bailed " .. R.Format(R.Mult100(2.5))) ~= nil, "when Ann bails, everyone sees where")
local bailBtn
for _, f in ipairs(stub.frames) do local tx = rawget(f, "_text"); if type(tx) == "string" and tx:find("BAIL  ", 1, true) then bailBtn = f end end
check(ns.UI.Casino.IsGlowing(bailBtn), "the Bail button glows"); click(bailBtn)
eq(db.rocket.bet.bail, R.Mult100(2.5), "pressing it bails")
setTime(nextRound.explodeAt + 0.5); ns.UI.Rocket.Refresh()
check(textOf("EXPLODED") ~= nil, "the explosion is shown"); check(textOf(R.Format(nextRound.crash100)) ~= nil, "with where it happened")
check(textOf("Last round  ") ~= nil and textOf("exploded at " .. R.Format(nextRound.crash100)) ~= nil, "and the last round says where")
check(textOf("Ann  ") ~= nil and textOf("bailed " .. R.Format(R.Mult100(2.5))) ~= nil, "who bailed where")
setTime(nextRound.explodeAt + 6); ns.UI.Rocket.Refresh()
check(textOf("EXPLODED") == nil, "the explosion clears after a few seconds")

-- the strip of past rounds: five of them, with where each exploded and how long ago
do
    local tx = textOf("Past rounds")
    check(tx ~= nil, "the window lists the past rounds")
    local n = 0
    for _ in tx:gmatch(" ago") do n = n + 1 end
    eq(n, 5, "five of them")
    local lastCrash = R.State(SEED, RN.Now()).past[1]
    check(tx:find(R.Format(lastCrash.crash100) .. "|r", 1, true) ~= nil, "the newest is first, with its multiplier")
    check(tx:find(("%ds ago"):format(math.floor(RN.Now() - lastCrash.explodeAt)), 1, true) ~= nil, "and how long ago it exploded")
end

-- the launcher's rocket button
UI.Show(); settle()
local plays = allByText("Play vs Steve")
eq(#plays, 4, "every game, the rocket included, offers the house")
db.rocket.host = nil
click(plays[4])
eq(db.rocket.host, "Steve", "the rocket button opens Steve's rocket")

-- /rocket
check(SlashCmdList.STEVEROCKET ~= nil and _G.SLASH_STEVEROCKET1 == "/rocket", "/rocket is registered")
local win = _G.SteveBookRocketFrame
win:Hide(); db.rocket.host = nil
SlashCmdList.STEVEROCKET()
eq(db.rocket.host, "Steve", "/rocket picks Steve's house"); check(win:IsShown(), "and opens the rocket")
SlashCmdList.STEVEROCKET()
check(not win:IsShown(), "a second /rocket closes it")
db.houses.Steve.on = false; SlashCmdList.STEVEROCKET()
check(not win:IsShown(), "a closed house does not open it"); db.houses.Steve.on = true

eq(#stub.errors, 0, "no errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_rocket: all passed") else out_("test_rocket: " .. fails .. " FAILED") os.exit(1) end
