-- Automatic rounds at roulette and blackjack tables (SPEC §11): with the host's switch on, Casino.AUTO_SECONDS
-- after a round's first bet the bets lock and the spin or hand starts by itself.
-- Part 1 is the pure rules; part 2 runs them through CasinoNet and the windows on the stubbed game.
-- Run from repo root: luajit tests/test_casino_auto.lua
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
local UI, CN, Casino, E, P = ns.UI.Casino, ns.CasinoNet, ns.Casino, ns.BlackjackTable, ns.Protocol
E.RESHUFFLE_BELOW = 0

------------------------------------------------------------------------------------------
-- 1. The rules
------------------------------------------------------------------------------------------
local NOW = 5000
local AUTO = Casino.AUTO_SECONDS
eq(AUTO, 20, "automatic rounds lock the bets 20 s after the first bet")
local seed = 0
local function rand(n) seed = seed + 7; return (seed % n) + 1 end

local function seated(game)
    local t = assert(Casino.Create({}, { game = game, name = "T", zero = game == "roulette" and "single" or nil }, "Host", NOW, rand))
    for _, n in ipairs({ "Ann", "Bob" }) do Casino.RequestJoin(t, n, NOW); Casino.Admit(t, n, 10000, NOW) end
    return t
end
local function bet(t, name, ref)
    if t.game == "blackjack" then return assert(Casino.PlaceBet(t, name, t.round, { kind = "wager", amount = 100 }, ref)) end
    return assert(Casino.PlaceBet(t, name, t.round, { kind = "red", amount = 100 }, ref))
end

for _, game in ipairs({ "roulette", "blackjack" }) do
    local g = game .. ": "
    local t = seated(game)
    eq(t.auto, nil, g .. "off by default")
    bet(t, "Ann", "a1")
    eq(Casino.AutoTick(t, NOW), nil, g .. "off: a bet starts nothing")
    eq(t.autoAt, nil, g .. "off: no countdown")

    -- turning it on
    local rev = t.rev
    eq(Casino.SetAuto(t, true), true, g .. "SetAuto reports the new state"); eq(t.auto, true, g .. "on")
    check(t.rev > rev, g .. "the change reaches players (rev moves)")
    rev = t.rev
    Casino.SetAuto(t, true); eq(t.rev, rev, g .. "switching on twice changes nothing")
    eq(t.autoAt, nil, g .. "switching on does not start a countdown by itself")

    -- the first bet (already on the table) starts the countdown, later bets do not move it
    eq(Casino.AutoTick(t, NOW), "armed", g .. "bets on the table: the countdown starts")
    eq(t.autoAt, NOW + AUTO, g .. "it ends AUTO_SECONDS from now")
    eq(Casino.AutoTick(t, NOW + 1), nil, g .. "nothing to do while it runs")
    bet(t, "Bob", "b1")
    eq(Casino.AutoTick(t, NOW + 5), nil, g .. "a second bettor does not restart it")
    eq(t.autoAt, NOW + AUTO, g .. "the deadline did not move")
    eq(Casino.AutoTick(t, NOW + AUTO - 1), nil, g .. "one second early: still waiting")
    eq(Casino.AutoTick(t, NOW + AUTO), "start", g .. "at the deadline: start the round")
    eq(Casino.AutoTick(t, NOW + AUTO + 3), "start", g .. "and it keeps saying so until the round actually starts")

    -- the state players see
    local msg = Casino.StateMessage(t)
    eq(msg.auto, true, g .. "players are told it is on"); eq(msg.autoAt, NOW + AUTO, g .. "and when the bets lock")
    check(P.Validate("TBL_STATE", msg), g .. "the state with the countdown is a valid message")
    check(not P.Validate("TBL_STATE", { rev = 1, game = game, name = "x", status = "betting", round = 1, minBet = 100, maxBet = 100,
        seats = {}, history = {}, autoAt = "soon" }), g .. "autoAt must be a number")

    -- starting the round by hand drops the countdown
    if game == "roulette" then assert(Casino.BeginSpin(t, NOW + 10)) else assert(E.Deal(t, nil, NOW + 10)) end
    eq(t.autoAt, nil, g .. "a manual start clears the countdown")
    eq(Casino.AutoTick(t, NOW + 99), nil, g .. "no countdown while the round is on")
    eq(Casino.StateMessage(t).autoAt, nil, g .. "and it is not in the state")
end

-- taking every bet back drops the countdown; the next bet starts a fresh one
do
    local t = seated("roulette")
    Casino.SetAuto(t, true)
    bet(t, "Ann", "a1"); bet(t, "Bob", "b1")
    eq(Casino.AutoTick(t, NOW), "armed", "armed")
    Casino.ClearBets(t, "Ann", t.round)
    eq(Casino.AutoTick(t, NOW + 3), nil, "one player took theirs back, the other has not: it keeps running")
    eq(t.autoAt, NOW + AUTO, "unchanged")
    Casino.ClearBets(t, "Bob", t.round)
    eq(Casino.AutoTick(t, NOW + 4), "cleared", "nobody is betting any more: the countdown is dropped")
    eq(t.autoAt, nil, "no deadline")
    eq(Casino.AutoTick(t, NOW + 60), nil, "and it never starts a round with no bets")
    bet(t, "Ann", "a2")
    eq(Casino.AutoTick(t, NOW + 61), "armed", "a new bet starts a new countdown")
    eq(t.autoAt, NOW + 61 + AUTO, "from that bet, not the old one")
    -- a player who leaves (bets refunded) counts the same way
    Casino.Leave(t, "Ann")
    eq(Casino.AutoTick(t, NOW + 62), "cleared", "the only bettor leaving drops it")
end

-- switching off mid-countdown, closing, reloading
do
    local t = seated("blackjack")
    Casino.SetAuto(t, true)
    bet(t, "Ann", "a1")
    eq(Casino.AutoTick(t, NOW), "armed", "armed")
    Casino.SetAuto(t, false)
    eq(t.auto, nil, "off again"); eq(t.autoAt, nil, "switching off drops the countdown")
    eq(Casino.AutoTick(t, NOW + 99), nil, "and nothing starts")
    Casino.SetAuto(t, true)
    eq(Casino.AutoTick(t, NOW + 100), "armed", "on with a wager waiting: it starts counting now")
    eq(t.autoAt, NOW + 100 + AUTO, "from the moment it was seen")
    -- a reload forgets the countdown (the timers are gone too); the table keeps the setting
    local rdb = { casino = { tables = { [t.code] = t } } }
    Casino.Recover(rdb)
    eq(t.autoAt, nil, "a reload clears the countdown"); eq(t.auto, true, "but keeps the setting")
    eq(Casino.AutoTick(t, NOW + 200), "armed", "it starts afresh when the wager is seen again")
    Casino.Close(t)
    eq(t.autoAt, nil, "closing clears it")
    eq(Casino.AutoTick(t, NOW + 300), nil, "a closed table never starts a round")
end

-- bets are only taken while betting: no countdown mid-hand
do
    local t = seated("blackjack")
    Casino.SetAuto(t, true)
    bet(t, "Ann", "a1")
    assert(E.Deal(t, nil, NOW))
    eq(Casino.AutoTick(t, NOW + 1), nil, "no countdown while players are deciding")
end

------------------------------------------------------------------------------------------
-- 2. Through the net glue and the windows (one character as host and player, via loopback)
------------------------------------------------------------------------------------------
local function settle() for _ = 1, 14 do stub.advance(1); stub.runAfters() end end
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
local function jumpTo(time) stub.time = time; stub.mono = stub.mono + 1; stub.runTickers() end

SlashCmdList.STEVEBOOK("loopback")

-- ---- roulette
local rt = assert(CN.Create({ game = "roulette", name = "Auto Wheel", zero = "single" }))
local rtc = assert(CN.RequestJoin(rt.code)); settle()
assert(CN.Admit(rt, "Loopback", 50000)); settle()
UI.OpenHost(rt.code)
UI.OpenTable(rt.code)
local autoBtn = allByText("Auto: off")[1]
check(autoBtn ~= nil, "the host window has an Auto switch, off to begin with")

-- off: a bet does not start anything, however long we wait
assert(CN.PlaceBet(rt.code, { kind = "red", amount = 1000 })); settle()
eq(rt.autoAt, nil, "off: no countdown")
jumpTo(stub.time + 120)
eq(rt.status, "betting", "off: the wheel waits for the host")
eq(#rt.history, 0, "off: nobody spun")

-- switching on with a bet already down starts the clock at once, and the player is told
local t0 = stub.time
click(autoBtn)
eq(rt.auto, true, "the switch turns it on")
eq(rt.autoAt, t0 + AUTO, "a bet is already down: the clock starts now")
check(textOf("Auto: ON") ~= nil, "the button says so")
settle()
eq(rtc.state.auto, true, "the player's copy of the table knows it is automatic")
eq(rtc.state.autoAt, t0 + AUTO, "and when the bets lock")
check(textOf("Bets lock in") ~= nil, "the roulette window shows the countdown")
check(textOf("Spinning in") ~= nil, "so does the host's hint")
check(textOf("auto-spin") ~= nil, "and the player's status marks the table as automatic")
check(UI.IsGlowing(allByText("Spin the wheel")[1]), "the host's Spin button still glows: they can go sooner")

-- the clock runs out
jumpTo(rt.autoAt - 1)
eq(rt.status, "betting", "one second early the wheel has not started")
jumpTo(rt.autoAt)
eq(rt.status, "spinning", "at the deadline the bets lock and the wheel turns")
eq(rt.autoAt, nil, "the countdown is spent")
settle()
eq(rt.status, "betting", "the spin finishes and the next round opens"); eq(rt.round, 2, "round 2")
eq(#rt.history, 1, "one pocket drawn")
eq(rtc.state.autoAt, nil, "the player's countdown is gone")
check(#rtc.bets == 0, "the bet was settled")

-- round 2: the first bet starts the clock from the host's side, taking it back drops it
assert(CN.PlaceBet(rt.code, { kind = "black", amount = 1000 })); settle()
check(rt.autoAt ~= nil, "a player's bet starts the countdown")
eq(rtc.state.autoAt, rt.autoAt, "and the players hear about it")
assert(CN.ClearBets(rt.code)); settle()
eq(rt.autoAt, nil, "taking the bet back drops it")
eq(rtc.state.autoAt, nil, "and the players hear that too")
jumpTo(stub.time + 120)
eq(rt.status, "betting", "no bets, no spin")
eq(rt.round, 2, "still round 2")

-- a manual spin while counting down
assert(CN.PlaceBet(rt.code, { kind = "black", amount = 1000 })); settle()
check(rt.autoAt ~= nil, "counting")
assert(CN.Spin(rt)); eq(rt.autoAt, nil, "pressing Spin clears the countdown")
settle()
eq(rt.round, 3, "that spin ran once")
jumpTo(stub.time + 120)
eq(rt.round, 3, "and the countdown did not spin it a second time")

-- switching off
assert(CN.PlaceBet(rt.code, { kind = "black", amount = 1000 })); settle()
check(rt.autoAt ~= nil, "counting again")
click(autoBtn)                                   -- the same button, now reading "Auto: ON"
eq(rt.auto, nil, "the switch turns it off"); eq(rt.autoAt, nil, "and drops the countdown")
check(textOf("Auto: off") ~= nil, "the button says off again")
jumpTo(stub.time + 120)
eq(rt.status, "betting", "off: the wheel waits again")
eq(CN.SetAuto(rt, true), true, "the glue's switch"); eq(rt.auto, true, "on")
CN.CloseTable(rt)
eq(select(2, CN.SetAuto(rt, true)), "This table is closed.", "a closed table has no automatic rounds")

-- ---- blackjack
local bt = assert(CN.Create({ game = "blackjack", name = "Auto Cards" }))
local btc = assert(CN.RequestJoin(bt.code)); settle()
assert(CN.Admit(bt, "Loopback", 50000)); settle()
eq(CN.SetAuto(bt, true), true, "switch on")
assert(CN.Wager(bt.code, 1000)); settle()
check(bt.autoAt ~= nil, "blackjack: the first wager starts the countdown")
eq(btc.state.autoAt, bt.autoAt, "blackjack: the player hears when the bets lock")
UI.OpenHost(bt.code)
UI.OpenTable(bt.code)
check(textOf("Bets lock in") ~= nil, "the blackjack window shows the countdown")
check(textOf("Dealing in") ~= nil, "and so does the host's hint")
check(textOf("Your bet is in. Dealing in") ~= nil, "and the bet panel says when the hand is dealt")
local deadline = bt.autoAt
jumpTo(deadline - 1)
eq(bt.status, "betting", "blackjack: not yet")
jumpTo(deadline)
check(bt.status == "playing" or bt.status == "dealer" or bt.status == "results", "blackjack: the wager locks and the hand is dealt (" .. tostring(bt.status) .. ")")
check(bt.bj.hands.Loopback ~= nil, "the player was dealt in")
eq(bt.autoAt, nil, "blackjack: the countdown is spent")

-- the next round's countdown: dealer stands, results, then betting opens and a new wager starts a new one
for _ = 1, 40 do
    if bt.status == "betting" then break end
    if bt.status == "playing" then CN.Skip(bt) end
    settle()
    if bt.status == "results" then jumpTo(stub.time + 6); settle() end
end
eq(bt.status, "betting", "blackjack: the table came back to betting")
local round = bt.round
assert(CN.Wager(bt.code, 1000)); settle()
check(bt.autoAt ~= nil, "blackjack: the next round's first wager starts a new countdown")
assert(CN.Deal(bt)); eq(bt.autoAt, nil, "blackjack: pressing Deal clears the countdown")
eq(bt.round, round, "blackjack: and that deal is this round")

eq(#stub.errors, 0, "no handler errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_casino_auto: all passed") else out_(fails .. " FAILED"); os.exit(1) end
