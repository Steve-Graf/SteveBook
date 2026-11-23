-- Dice, roll under (SPEC §11b): the rules and engine (Dice.lua), then a round at a house table through
-- CasinoNet and the window on the stubbed game. Run from repo root: luajit tests/test_dice.lua
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
local CN, Casino, Client, House, Dice, P = ns.CasinoNet, ns.Casino, ns.CasinoClient, ns.House, ns.Dice, ns.Protocol
local UI = ns.UI.Casino
local AceSer = LibStub("AceSerializer-3.0")

------------------------------------------------------------------------------------------
-- 1. The rules
------------------------------------------------------------------------------------------
eq(Dice.SIDES, 100, "a hundred sides, like /roll"); eq(Dice.EDGE, 2, "the house keeps 2%")
check(Dice.ValidTarget(2) and Dice.ValidTarget(95) and Dice.ValidTarget(49), "targets 2 to 95")
check(not Dice.ValidTarget(1) and not Dice.ValidTarget(96) and not Dice.ValidTarget(49.5) and not Dice.ValidTarget("50") and not Dice.ValidTarget(nil), "nothing else")
eq(Dice.Payout(100, 49), 200, "target 49 pays double"); eq(Dice.Payout(100, 50), 196, "target 50 pays 1.96x")
eq(Dice.Payout(100, 2), 4900, "target 2 pays 49x"); eq(Dice.Payout(100, 95), 103, "target 95 barely pays")
eq(Dice.Payout(1000, 10), 9800, "a 10% chance pays 9.8x"); eq(Dice.Multiplier(49), 2, "multiplier")
eq(Dice.Chance(25), 0.25, "chance")
for target = Dice.MIN_TARGET, Dice.MAX_TARGET do
    check(Dice.Payout(10000, target) > 10000, "a win always pays more than the stake (target " .. target .. ")")
    local ev = Dice.Chance(target) * Dice.Payout(10000, target) / 10000
    check(math.abs(ev - 0.98) < 0.001, ("the house edge is 2%% at target %d (got %.4f)"):format(target, ev))
end

local NOW = 5000
local seed = 0
local function rand(n) seed = seed + 7; return (seed % n) + 1 end
check(not Casino.Create({}, { game = "dice" }, "Host", NOW, rand), "dice cannot be hosted as an ordinary table")
eq(select(2, Casino.Create({}, { game = "dice" }, "Host", NOW, rand)), "Dice is only played against a house.", "and says why")
local t = assert(Casino.Create({}, { game = "dice", house = true, name = "D", minBet = 100, maxBet = 10000 }, "Host", NOW, rand))
check(t.code:find("^DCE%-"), "code prefix DCE"); eq(t.maxSeats, 1, "one seat")
assert(Casino.RequestJoin(t, "Ann", NOW)); assert(Casino.Admit(t, "Ann", 50000, NOW))

local function bet(amount, pick, ref, round) return Casino.PlaceBet(t, "Ann", round or t.round, { kind = "roll", amount = amount, pick = pick }, ref) end
eq(select(2, bet(100, 1)), "bad_bet", "target 1"); eq(select(2, bet(100, 96)), "bad_bet", "target 96")
eq(select(2, bet(100, 50.5)), "bad_bet", "a fractional target"); eq(select(2, bet(150, 50)), "bad_bet", "a stake in whole silver")
eq(select(2, Casino.PlaceBet(t, "Ann", t.round, { kind = "straight", amount = 100, pick = 50 })), "bad_bet", "another kind of bet")
eq(select(2, bet(50, 50)), "bad_bet", "half a silver"); eq(select(2, bet(0, 50)), "bad_bet", "nothing")
eq(select(2, bet(100, 50, "x", 99)), "round_closed", "a stale round")
eq(select(2, Casino.PlaceBet(t, "Nobody", t.round, { kind = "roll", amount = 100, pick = 50 })), "not_seated", "not seated")
do local _, why, lim = bet(10100, 50); eq(why, "max_bet", "over the maximum"); eq(lim, 10000, "with the limit") end
t.members.Ann.balance = 400
do local _, why, have = bet(500, 50); eq(why, "no_balance", "more than the chips"); eq(have, 400, "with what they have") end
t.members.Ann.balance = 50000
local b1 = assert(bet(1000, 49, "r1"))
eq(b1.kind, "roll", "stored"); eq(b1.pick, 49, "with its target"); eq(t.members.Ann.balance, 49000, "the stake left the chips")
check(select(3, bet(1000, 49, "r1")), "the same ref is the same bet"); eq(#t.members.Ann.bets, 1, "and was not taken twice")
eq(select(2, bet(500, 30, "r2")), "bad_bet", "one bet per roll")
eq(Casino.ClearBets(t, "Ann", t.round), 1000, "taking it back returns the stake"); eq(t.members.Ann.balance, 50000, "balance")
eq(select(2, Dice.Roll(t, NOW)), "no_bets", "no roll without a bet")

-- a roll
local function fixed(n) return function() return n end end
local autoT = t
autoT.auto, autoT.autoSeconds = true, 0
eq(Casino.AutoTick(autoT, NOW), nil, "no bets, nothing to start")
assert(bet(1000, 49, "r3"))
eq(Casino.AutoTick(autoT, NOW), "start", "a bet starts the roll at once (no countdown)")
check(Dice.Roll(t, NOW), "rolling"); eq(t.status, "rolling", "the dice are tumbling")
eq(select(2, bet(100, 50, "late")), "round_closed", "no bets while rolling"); eq(Dice.Roll(t, NOW), nil, "not twice")
local r = assert(Dice.Finish(t, fixed(30), NOW + 2))
eq(r.number, 30, "the roll"); eq(t.status, "betting", "betting reopens"); eq(t.round, 2, "round 2")
eq(r.results[1].net, 1000, "30 is under 49: a win of one stake"); eq(t.members.Ann.balance, 49000 + 2000, "stake back plus winnings")
eq(r.results[1].bets[1].win, 2000, "the win is listed"); eq(r.results[1].bets[1].pick, 49, "with its target")
eq(t.history[1], 30, "history"); eq(#t.members.Ann.bets, 0, "the bet is settled")
-- the target itself wins, one above loses
assert(bet(1000, 49)); Dice.Roll(t, NOW); r = Dice.Finish(t, fixed(49), NOW)
eq(r.results[1].net, 1000, "rolling exactly the target wins")
assert(bet(1000, 49)); Dice.Roll(t, NOW); r = Dice.Finish(t, fixed(50), NOW)
eq(r.results[1].net, -1000, "one over loses the stake"); eq(t.members.Ann.balance, 51000 + 1000 - 1000, "chips")
assert(bet(1000, 95)); Dice.Roll(t, NOW); r = Dice.Finish(t, fixed(100), NOW); eq(r.results[1].net, -1000, "100 loses everything")
check(Dice.Finish(t, fixed(1), NOW) == nil, "no finish without a roll")
for i = 1, 20 do assert(bet(100, 50)); Dice.Roll(t, NOW); Dice.Finish(t, fixed(i), NOW) end
eq(#t.history, Casino.HISTORY_KEEP, "history is trimmed")
-- reload mid-roll
assert(bet(2000, 50, "z")); Dice.Roll(t, NOW)
local before = t.members.Ann.balance
Casino.Recover({ casino = { tables = { [t.code] = t } } })
eq(t.status, "betting", "a roll that never finished is cancelled"); eq(t.members.Ann.balance, before + 2000, "the stake comes back")
-- messages
assert(bet(1000, 25, "m1"))
check(P.Validate("TBL_STATE", Casino.StateMessage(t)), "the state is a valid message")
local pm = Casino.PlayerMessage(t, "Ann"); eq(pm.bets[1].pick, 25, "the player is told the target of their bet")
Dice.Roll(t, NOW); Dice.Finish(t, fixed(7), NOW)
check(P.Validate("TBL_RESULT", Casino.ResultMessage(t)), "the result is a valid message"); eq(Casino.ResultMessage(t).number, 7, "carrying the roll")

------------------------------------------------------------------------------------------
-- 2. At a house table
------------------------------------------------------------------------------------------
local function settle() for _ = 1, 14 do stub.advance(1); stub.runAfters() end end
local function fromWire(sender, msgType, code, payload)
    local env = assert(P.Wrap(msgType, code, payload))
    stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", sender)
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

-- the die is rigged by replacing math.random for one-argument calls (the ref nonce uses two)
local realRandom, FIXED = math.random, nil
math.random = function(...) if select("#", ...) == 1 and FIXED then return FIXED end return realRandom(...) end

fromWire("Steve lol", "LOBBY_HOUSE", P.LOBBY_CODE, { on = true, minBet = 100, maxBet = 10000 })
local dt = assert(CN.PlayHouse("Steve", "dice")); settle()
local tc = Client.Table(db.casinoCache, dt.code)
eq(dt.game, "dice", "a dice table"); eq(dt.house, "Steve", "at Steve's house"); eq(dt.auto, true, "rolls by itself"); eq(dt.autoSeconds, 0, "at once")
eq(tc.status, "seated", "seated"); eq(tc.balance, 50000, "five maximum bets"); check(tc.state ~= nil, "the table is here")
check(#CN.Houses() == 1, "(Steve's house)")

check(not CN.DiceBet(dt.code, 1000, 1), "target 1 refused by the client"); eq(select(2, CN.DiceBet(dt.code, 1000, 1)), "Roll under a whole number from 2 to 95.", "with a reason")
eq(select(2, CN.DiceBet(dt.code, 1050, 50)), "Bets are whole silver.", "whole silver")
eq(select(2, CN.DiceBet(dt.code, 20000, 50)), "The maximum bet is " .. ns.Odds.FormatMoney(10000) .. ".", "limits")
lines()

FIXED = 30
assert(CN.DiceBet(dt.code, 1000, 49))
eq(select(2, CN.DiceBet(dt.code, 1000, 49)), "Your roll is already on its way.", "one bet at a time")
settle()
eq(dt.round, 2, "the die rolled as soon as the bet was in, and the next round is open")
eq(tc.lastResult.number, 30, "the player has the roll"); eq(tc.balance, 51000, "chips: the stake back and one stake won (no refill: still above five maximum bets)")
local said = lines()
check(said:find("Rolled 30") ~= nil and said:find("You won") ~= nil, "chat says what was rolled and that you won")
local rec = db.houses.Steve
eq(rec.games.dice.rounds, 1, "counted"); eq(rec.games.dice.wagered, 1000, "wagered"); eq(rec.games.dice.net, 1000, "net: won one stake")
eq(House.TableNet(dt), 1000, "the chips agree"); eq(#tc.rolls, 1, "my roll list"); eq(tc.rolls[1].target, 49, "with the target")

FIXED = 77
assert(CN.DiceBet(dt.code, 2000, 49)); settle()
eq(rec.games.dice.rounds, 2, "two rounds"); eq(rec.games.dice.net, -1000, "after a 20s loss"); eq(tc.rolls[1].net, -2000, "newest first")
check(lines():find("You lost") ~= nil, "chat says you lost")
eq(House.Balance(rec), -1000, "the balance with the house")

-- the window
UI.OpenTable(dt.code); settle()
local roll = allByText("Roll")[1]
check(roll ~= nil, "the dice window has a Roll button")
eq(roll:IsEnabled(), true, "live"); check(UI.IsGlowing(roll), "and glowing")
check(textOf("Wins on") ~= nil and textOf("2.00x") ~= nil and textOf("49%") ~= nil, "the odds of the target in the box (49: 2.00x)")
check(textOf("owes you") or textOf("You owe") or textOf("all square"), "where you stand with the bookie")
check(textOf("You needed 49 or less.") ~= nil, "the last roll's target")
local box
for _, f in ipairs(stub.frames) do if rawget(f, "_text") == "49" and f._scripts and f._scripts.OnTextChanged then box = f end end
check(box ~= nil, "the target box")
UI.SetTarget(10); check(textOf("9.80x") ~= nil, "a lower target pays more"); check(textOf("10%") ~= nil, "10% to win")
UI.SetTarget(500); eq(box:GetText(), "95", "the target is held to 95")
UI.SetTarget(-3); eq(box:GetText(), "2", "and to 2")
box:SetText("1"); UI.Refresh()
eq(roll:IsEnabled(), false, "a bad target disables Roll"); check(textOf("Roll under a whole number from 2 to 95.") ~= nil, "and says why")
UI.SetTarget(10); UI.SetDiceStake(500); check(textOf("9.80x") ~= nil, "back to a good target")
FIXED = 5
click(allByText("Roll")[1]); settle()
eq(dt.round, 4, "the button rolled once"); eq(tc.lastResult.number, 5, "5 is under 10")
check(textOf("WIN +") ~= nil, "the window shows the win"); eq(rec.games.dice.rounds, 3, "counted")
check(textOf("Your last rolls") ~= nil and textOf("under 10") ~= nil, "the roll is in the list of my last rolls")
UI.Show(); settle()
local dtext = textOf("Roll under a number you pick")
check(dtext ~= nil, "the casino window explains dice")
local hostBtns = allByText("Host a table"); check(not hostBtns[3]:IsEnabled(), "dice has no Host button")
check(allByText("Join a table")[3] ~= nil and not allByText("Join a table")[3]:IsEnabled(), "nor a Join button")
check(#allByText("Play vs Steve") == 3, "but a house button")

math.random = realRandom
eq(#stub.errors, 0, "no errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_dice: all passed") else out_("test_dice: " .. fails .. " FAILED") os.exit(1) end
