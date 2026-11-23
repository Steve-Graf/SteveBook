-- Play against the house (SPEC §11a): a one-seat table on the player's own client, results reported to the bookie.
-- Part 1 is the pure rules (House.lua); part 2 runs a player and a bookie through CasinoNet on the stubbed game.
-- Run from repo root: luajit tests/test_house.lua
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
local CN, Casino, Client, House, E, P = ns.CasinoNet, ns.Casino, ns.CasinoClient, ns.House, ns.BlackjackTable, ns.Protocol
local AceSer = LibStub("AceSerializer-3.0")
E.RESHUFFLE_BELOW = 0

------------------------------------------------------------------------------------------
-- 1. The rules
------------------------------------------------------------------------------------------
do
    local book = House.EnsureBook({})
    eq(book.enabled, false, "a house is closed until the bookie opens it")
    eq(book.minBet, Casino.DEFAULT_MIN_BET, "default minimum"); eq(book.maxBet, Casino.DEFAULT_MAX_BET, "default maximum")
    check(House.SetLimits(book, 100, 50000), "limits can be set")
    check(not House.SetLimits(book, 100, Casino.MAX_BET_CAP + 100), "but not above the cap")
    check(not House.SetLimits(book, 5000, 100), "nor a maximum under the minimum")

    -- reports are totals: the latest wins, an old or repeated one changes nothing
    local st, e = House.Apply(book, "Ann-Realm", { rounds = 3, wagered = 3000, net = 1500, games = { roulette = { rounds = 3, wagered = 3000, net = 1500 } } }, 100)
    eq(st, "new", "first report"); eq(e.net, 1500, "net kept"); eq(e.paid, 0, "nothing settled yet")
    check(book.players.Ann ~= nil, "the realm is dropped from the name")
    eq(House.Owed(e), 1500, "the bookie owes a winning player")
    eq((House.Apply(book, "Ann", { rounds = 3, wagered = 3000, net = 1500 }, 101)), "stale", "a repeat is stale")
    eq((House.Apply(book, "Ann", { rounds = 2, wagered = 2000, net = 0 }, 102)), "stale", "an older one too")
    eq(book.players.Ann.net, 1500, "and neither changed anything")
    eq((House.Apply(book, "Ann", { rounds = 5, wagered = 5000, net = -500 }, 103)), "updated", "newer totals replace the old")
    eq(book.players.Ann.net, -500, "the player went the other way"); eq(House.Owed(book.players.Ann), -500, "so they owe the bookie")

    -- reports that cannot be true
    eq((House.Apply(book, "Mal", { rounds = 1, wagered = 100, net = 100 * 50 }, 1)), "rejected", "more than 49:1")
eq((House.Apply(book, "Lucky", { rounds = 1, wagered = 100, net = 100 * 49 }, 1)), "new", "49:1 is a 2% dice win: allowed")
House.Forget(book, "Lucky")
    eq((House.Apply(book, "Mal", { rounds = 1, wagered = 100, net = -101 }, 1)), "rejected", "lost more than was staked")
    eq((House.Apply(book, "Mal", { rounds = 1, wagered = 100.5, net = 0 }, 1)), "rejected", "fractions")
    eq((House.Apply(book, "Mal", { rounds = -1, wagered = 0, net = 0 }, 1)), "rejected", "negative rounds")
    eq((House.Apply(book, "Mal", { rounds = 0, wagered = 0, net = 500 }, 1)), "rejected", "money without rounds")
    eq((House.Apply(book, "Mal", { rounds = 1 / 0, wagered = 0, net = 0 }, 1)), "rejected", "infinity")
    eq(book.players.Mal, nil, "a rejected report leaves no trace")

    -- settling
    House.Apply(book, "Bo", { rounds = 4, wagered = 4000, net = 3000 }, 104)
    local rows = House.Rows(book)
    eq(#rows, 2, "two players"); eq(rows[1].name, "Bo", "the biggest balance first")
    local tot = House.Totals(book)
    eq(tot.players, 2, "totals: players"); eq(tot.rounds, 9, "rounds"); eq(tot.net, 2500, "net"); eq(tot.owed, 2500, "owed")
    eq(House.Settle(book, "Bo"), 3000, "settling returns what was owed"); eq(House.Owed(book.players.Bo), 0, "nothing owed after")
    House.Apply(book, "Bo", { rounds = 5, wagered = 5000, net = 3200 }, 105)
    eq(House.Owed(book.players.Bo), 200, "later results add to a settled balance")
    eq(House.Settle(book, "Nobody"), nil, "unknown player")
    check(House.Forget(book, "Ann"), "forgotten"); eq(book.players.Ann, nil, "gone")

    -- the player's own record
    local d = {}
    local rec = House.Record(d, "Steve-Realm")
    eq(rec.host, "Steve", "keyed by the base name")
    eq(House.Known(d)[1], nil, "unheard houses are not offered")
    local r2, changed = House.Heard(d, "Steve", { on = true, minBet = 100, maxBet = 10000 }, 50)
    check(r2 == rec and changed, "hearing limits fills the record"); eq(House.Known(d)[1].host, "Steve", "and offers the house")
    eq(select(2, House.Heard(d, "Steve", { on = true, minBet = 100, maxBet = 10000 }, 60)), false, "the same limits again are no change")
    check(not House.Heard(d, "Steve", { on = true, minBet = 100, maxBet = 1e9 }, 70), "absurd limits are ignored")
    eq(rec.maxBet, 10000, "and keep the old ones")
    check(House.Heard(d, "Zed", { on = true, minBet = 100, maxBet = 100 }, 90) ~= nil, "a second house")
    eq(House.Known(d)[1].host, "Zed", "the most recently heard comes first")

    House.RecordRound(rec, "roulette", { bets = { { amount = 1000 }, { amount = 500 } } }, 1500)
    House.RecordRound(rec, "blackjack", { hands = { { bet = 2000 }, { bet = 2000 } } }, -4000)
    local rounds, wagered, net = House.PlayerTotals(rec)
    eq(rounds, 2, "two rounds"); eq(wagered, 5500, "wagered counts bets and hands"); eq(net, -2500, "net adds the games")
    eq(House.Balance(rec), -2500, "I owe the house")
    check(House.Unsynced(rec), "the bookie has not seen them")
    local rep = House.Report(rec)
    eq(rep.rounds, 2, "report: rounds"); eq(rep.net, -2500, "report: net"); eq(rep.games.blackjack.net, -4000, "report: per game")
    check(P.Validate("HOUSE_REPORT", rep), "the report is a valid message")
    House.ApplyAck(rec, { rounds = 2, paid = -1000 })
    check(not House.Unsynced(rec), "acknowledged"); eq(House.Balance(rec), -1500, "and 10s of it is settled")
    House.ApplyAck(rec, { rounds = 1, paid = -1000 })
    eq(rec.acked, 2, "an old ack never goes backwards")
    check(P.Validate("LOBBY_HOUSE", { on = true, minBet = 100, maxBet = 10000 }), "LOBBY_HOUSE is valid")
    check(not P.Validate("LOBBY_HOUSE", { minBet = 100, maxBet = 10000 }), "which needs on")
    check(P.Validate("HOUSE_ACK", { rounds = 1, paid = 0 }), "HOUSE_ACK is valid")

    -- the one-seat table
    local db2 = {}
    House.Record(db2, "Steve")
    check(not House.NewTable(db2, "Steve", "roulette", "Tester", 100), "no table before the limits are known")
    House.Heard(db2, "Steve", { on = true, minBet = 100, maxBet = 10000 }, 50)
    local rt = assert(House.NewTable(db2, "Steve", "roulette", "Tester", 100))
    eq(rt.house, "Steve", "tagged with the bookie"); eq(rt.maxSeats, 1, "one seat"); eq(rt.auto, nil, "roulette waits for the player's spin")
    eq(House.NewTable(db2, "Steve", "roulette", "Tester", 200), rt, "the same table the second time")
    local bt = assert(House.NewTable(db2, "Steve", "blackjack", "Tester", 100))
    eq(bt.auto, true, "blackjack deals by itself"); eq(bt.autoSeconds, 0, "at once")
    Casino.RequestJoin(bt, "Loopback", 100); Casino.Admit(bt, "Loopback", 0, 100)
    eq(House.Refill(bt, "Loopback"), 5 * 10000, "chips are topped up to five maximum bets")
    eq(bt.members.Loopback.balance, 50000, "balance"); eq(House.TableNet(bt), 0, "credit is not a result")
    eq(House.Refill(bt, "Loopback"), 0, "no top-up when full")
    assert(Casino.PlaceBet(bt, "Loopback", bt.round, { kind = "wager", amount = 10000 }, "a"))
    eq(Casino.AutoTick(bt, 100), "start", "a wager starts the deal at once")
    bt.members.Loopback.balance = 12345                          -- lost most of it, and a payout left odd copper
    eq(House.Refill(bt, "Loopback"), 0, "nothing is added while a bet is on the table")
    bt.members.Loopback.bets = {}
    eq(House.Refill(bt, "Loopback"), 37600, "whole silver only"); eq(bt.members.Loopback.balance, 49945, "topped up")
    eq(House.TableNet(bt), 49945 - 87600, "the result is chips less all the credit given (the 100 lost with the cleared bet shows)")
end

------------------------------------------------------------------------------------------
-- 2. Through CasinoNet: the player
------------------------------------------------------------------------------------------
local function settle() for _ = 1, 14 do stub.advance(1); stub.runAfters() end end
local function sent(msgType)
    local list = {}
    for _, m in ipairs(stub.addonMessages) do
        local ok, env = AceSer:Deserialize(m.text)
        if ok and type(env) == "table" and env.t == msgType then list[#list + 1] = env end
    end
    return list
end
local function fromWire(sender, msgType, code, payload)
    local env = assert(P.Wrap(msgType, code, payload))
    stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", sender)
end
local LOBBY = P.LOBBY_CODE
local printedFrom = 0
local function lines() local l = {}; for i = printedFrom + 1, #stub.printed do l[#l + 1] = stub.printed[i] end; printedFrom = #stub.printed; return table.concat(l, "\n") end
local function playRoulette(t, tc, bet)
    assert(CN.PlaceBet(t.code, bet)); settle()
    return assert(CN.HouseSpin(t.code))
end

check(select(1, CN.PlayHouse("Steve", "roulette")) == nil, "a house nobody has heard cannot be played")
eq(#CN.Houses(), 0, "none are offered")

fromWire("Steve lol", "LOBBY_HOUSE", LOBBY, { on = true, minBet = 100, maxBet = 10000 })
eq(#CN.Houses(), 1, "the announcement makes it playable"); eq(CN.Houses()[1].host, "Steve", "Steve's house")
stub.addonMessages = {}

local t = assert(CN.PlayHouse("Steve", "roulette")); settle()
local tc = Client.Table(db.casinoCache, t.code)
eq(t.house, "Steve", "a house table"); eq(tc.status, "seated", "seated at once"); eq(tc.house, "Steve", "the cache knows it is the house")
eq(tc.balance, 50000, "five maximum bets of credit"); check(tc.state ~= nil, "the table arrived (it is local)")
eq(#sent("TBL_STATE") + #sent("TBL_PLAYER") + #sent("TBL_JOIN") + #sent("TBL_JOIN_OK"), 0, "nothing about a house table goes on the wire")
check(stub.channels[P.ChannelName(t.code)] == nil, "and no channel was joined for it")
eq(#Casino.List(db), 1, "(one table)")
for _, e in ipairs(CN.Rooms()) do check(e.code ~= t.code, "a house table is not in the lobby list") end
CN.Announce(); eq(#sent("LOBBY_TABLE"), 0, "and is never announced")
eq(select(2, CN.HouseSpin(t.code)), "Place a bet first.", "no spin without a bet")
eq(CN.PlayHouse("Steve", "roulette"), t, "playing again reuses the table")

-- a round: the player bets, then spins
assert(CN.PlaceBet(t.code, { kind = "red", amount = 1000 })); settle()
eq(#tc.bets, 1, "the bet is on the table"); eq(t.status, "betting", "roulette waits for the player")
check(t.autoAt == nil, "no countdown")
assert(CN.HouseSpin(t.code)); eq(t.status, "spinning", "the player's Spin turns the wheel")
settle()
eq(t.status, "betting", "the next round opens"); eq(t.round, 2, "round 2")
local rec = db.houses.Steve
local rounds, wagered, net = House.PlayerTotals(rec)
eq(rounds, 1, "one round counted"); eq(wagered, 1000, "wagered"); check(net == 1000 or net == -1000, "a red bet wins or loses 10s")
eq(House.TableNet(t), net, "the record follows the chips")
eq(tc.balance, 50000, "chips are back at five bets")
local said = lines()
check(said:find("You won") or said:find("You lost"), "the player is told in chat")
check(#sent("HOUSE_REPORT") >= 1, "the bookie was announced a moment ago, so the result was sent")
local rep = sent("HOUSE_REPORT")[#sent("HOUSE_REPORT")]
eq(rep.p.rounds, 1, "the report has the totals"); eq(rep.p.net, net, "and the result"); eq(rep.to, "Steve", "addressed to the bookie")
eq(rep.c, LOBBY, "in the lobby channel")
fromWire("Steve lol", "HOUSE_ACK", LOBBY, { rounds = 1, paid = 0 })
check(not House.Unsynced(rec), "the ack is recorded")

-- the bookie goes offline: more rounds, nothing sent
stub.advance(400)
stub.addonMessages = {}
for _ = 1, 2 do assert(CN.PlaceBet(t.code, { kind = "black", amount = 500 })); settle(); assert(CN.HouseSpin(t.code)); settle() end
eq(House.PlayerTotals(rec), 3, "three rounds now")
eq(#sent("HOUSE_REPORT"), 0, "the bookie has not been heard for a while, so nothing is sent")
check(House.Unsynced(rec), "the results wait")
-- and they come back: their announcement brings the report
fromWire("Steve lol", "LOBBY_HOUSE", LOBBY, { on = true, minBet = 100, maxBet = 10000 }); settle()
eq(#sent("HOUSE_REPORT"), 1, "the bookie's announcement triggers one report")
eq(sent("HOUSE_REPORT")[1].p.rounds, 3, "with everything so far")
stub.advance(5)
fromWire("Steve lol", "LOBBY_HOUSE", LOBBY, { on = true, minBet = 100, maxBet = 10000 }); settle()
eq(#sent("HOUSE_REPORT"), 1, "and not another within seconds")
fromWire("Steve lol", "HOUSE_ACK", LOBBY, { rounds = 3, paid = 2000 })
eq(rec.paid, 2000, "the bookie's settlement is shown"); eq(House.Balance(rec), select(3, House.PlayerTotals(rec)) - 2000, "as a balance")

-- limits follow the bookie
fromWire("Steve lol", "LOBBY_HOUSE", LOBBY, { on = true, minBet = 100, maxBet = 20000 }); settle()
eq(t.maxBet, 20000, "my table has the bookie's new limit"); eq(tc.state.maxBet, 20000, "and the window sees it")
eq(select(2, CN.PlaceBet(t.code, { kind = "red", amount = 30000 })), "The maximum bet is " .. ns.Odds.FormatMoney(20000) .. ".", "limits are enforced")
-- a closed house cannot be started, a table in play carries on
fromWire("Steve lol", "LOBBY_HOUSE", LOBBY, { on = false, minBet = 100, maxBet = 20000 })
eq(select(2, CN.PlayHouse("Steve", "blackjack")), "Steve's house is closed right now.", "a closed house takes no new games")

-- a reload in the middle of a spin returns the bet
fromWire("Steve lol", "LOBBY_HOUSE", LOBBY, { on = true, minBet = 100, maxBet = 20000 })
assert(CN.PlaceBet(t.code, { kind = "red", amount = 1000 })); settle()
assert(CN.HouseSpin(t.code))
Casino.Recover(db)
eq(t.status, "betting", "a spin that never finished is cancelled"); eq(t.members.Loopback.balance + Casino.Staked(t.members.Loopback), t.members.Loopback.balance, "with the bet returned")
settle()
eq(t.round, 4, "(the timer of the cancelled spin finds nothing to do)")

-- blackjack: a wager deals the hand at once
fromWire("Steve lol", "LOBBY_HOUSE", LOBBY, { on = true, minBet = 100, maxBet = 10000 }); settle()
local bt = assert(CN.PlayHouse("Steve", "blackjack")); settle()
local btc = Client.Table(db.casinoCache, bt.code)
eq(bt.auto, true, "blackjack is automatic"); eq(btc.balance, 50000, "chips")
bt.bj.shoe = { "TS", "9H", "6D", "8C", "KH", "2C", "3C" }; bt.bj.pos = 1
assert(CN.Wager(bt.code, 1000)); settle()
eq(bt.status, "playing", "the hand was dealt as soon as the wager was in")
eq(btc.state.status, "playing", "the player sees it")
check(Client.MyTurn(btc, btc.me) ~= nil, "and it is their turn")
local before = House.PlayerTotals(rec)
assert(CN.Act(bt.code, "stand")); settle()
for _ = 1, 3 do stub.advance(1); stub.runAfters() end
eq(bt.status, "betting", "the table reopens by itself"); eq(bt.round, 2, "round 2")
eq(House.PlayerTotals(rec) - before, 1, "the hand counted as a round")
eq(db.houses.Steve.games.blackjack.net, -1000, "16 against 17: the player lost 10s")
eq(btc.balance, 50000, "and the chips are topped up")
eq(btc.state.status, "betting", "the player may bet again")
eq(#Casino.List(db), 2, "(two house tables)")

------------------------------------------------------------------------------------------
-- 3. The bookie
------------------------------------------------------------------------------------------
stub.advance(1000)
stub.addonMessages = {}
check(CN.HouseForget("Nobody") == nil, "forgetting an unknown player")
eq(CN.SetHouse(true), true, "the bookie opens the house")
eq(db.lobbyJoined, true, "and stays in the lobby from now on")
local ann = sent("LOBBY_HOUSE")
eq(#ann, 1, "an announcement goes out"); eq(ann[1].p.on, true, "open"); eq(ann[1].p.maxBet, Casino.DEFAULT_MAX_BET, "with the default limits")
check(CN.SetHouseLimits(200, 5000), "limits changed")
eq(sent("LOBBY_HOUSE")[2].p.maxBet, 5000, "and announced at once")
check(not CN.SetHouseLimits(5000, 200), "bad limits refused")
stub.advance(31); stub.runTickers()
check(#sent("LOBBY_HOUSE") >= 3, "the open house keeps announcing")

stub.addonMessages = {}
lines()
fromWire("Ann lol", "HOUSE_REPORT", LOBBY, { rounds = 4, wagered = 4000, net = 2500 })
local ann1 = db.houseBook.players.Ann
check(ann1 ~= nil, "a report is recorded"); eq(ann1.net, 2500, "net")
eq(#sent("HOUSE_ACK"), 1, "and answered"); eq(sent("HOUSE_ACK")[1].p.rounds, 4, "with what the bookie now holds"); eq(sent("HOUSE_ACK")[1].to, "Ann", "to that player")
check(lines():find("Ann played the house") ~= nil, "the bookie is told in chat")
fromWire("Ann lol", "HOUSE_REPORT", LOBBY, { rounds = 4, wagered = 4000, net = 2500 })
eq(#sent("HOUSE_ACK"), 2, "a repeat is acknowledged too (the first ack may have been lost)")
fromWire("Mal lol", "HOUSE_REPORT", LOBBY, { rounds = 1, wagered = 100, net = 100000 })
eq(db.houseBook.players.Mal, nil, "a report that cannot be true is dropped"); check(lines():find("do not add up") ~= nil, "and says so")
eq(CN.HouseSettle("Ann"), 2500, "settling returns the amount"); eq(ann1.paid, 2500, "recorded")
local acks = sent("HOUSE_ACK"); eq(acks[#acks].p.paid, 2500, "the player is told"); eq(acks[#acks].to, "Ann", "by name")
eq(House.Owed(ann1), 0, "nothing owed")
eq(CN.SetHouse(false), false, "the house closes")
eq(sent("LOBBY_HOUSE")[#sent("LOBBY_HOUSE")].p.on, false, "and says so once")
local n = #sent("LOBBY_HOUSE"); stub.advance(31); stub.runTickers()
eq(#sent("LOBBY_HOUSE"), n, "a closed house stays quiet")
fromWire("Zed lol", "LOBBY_ASK", LOBBY, {}); settle()
eq(sent("LOBBY_HOUSE")[#sent("LOBBY_HOUSE")].p.on, false, "except to answer a question")
check(CN.HouseForget("Ann"), "a player can be dropped from the books")
eq(db.houseBook.players.Ann, nil, "gone")

------------------------------------------------------------------------------------------
-- 4. The windows
------------------------------------------------------------------------------------------
local UI = ns.UI.Casino
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

-- the player: the launcher offers the house, the roulette window has its own Spin
db.houseBook.players = {}
fromWire("Steve lol", "LOBBY_HOUSE", LOBBY, { on = true, minBet = 100, maxBet = 10000 })
UI.Show(); settle()
local plays = allByText("Play vs Steve")
eq(#plays, 4, "each game offers Steve's house")
eq(plays[1]:IsEnabled(), true, "the button is live")
fromWire("Steve lol", "LOBBY_HOUSE", LOBBY, { on = false, minBet = 100, maxBet = 10000 }); UI.Refresh()
check(#allByText("House closed") == 4 and not allByText("House closed")[1]:IsEnabled(), "a closed house cannot be started")
fromWire("Steve lol", "LOBBY_HOUSE", LOBBY, { on = true, minBet = 100, maxBet = 10000 }); UI.Refresh()
click(allByText("Play vs Steve")[1]); settle()
local spin = allByText("Spin")[1]
check(spin ~= nil and spin:IsShown(), "the roulette window has a Spin button at a house table")
eq(spin:IsEnabled(), false, "disabled until there is a bet")
check(not UI.IsGlowing(spin), "and not glowing")
for _, f in ipairs(allByText("Leave table")) do f:Show() end           -- (the stub starts frames hidden: show them, then see what a refresh does)
UI.Refresh()
check(#allByText("Leave table") > 0, "the window has a Leave button")
for _, f in ipairs(allByText("Leave table")) do check(not f:IsShown(), "but a house table hides it: it is your own table") end
check(textOf("owes you") or textOf("You owe") or textOf("all square"), "the window says where you stand with the bookie")
local hostT = House.FindTable(db, "Steve", "roulette")
check(not textOf("Hosting"), "the table is not in the list of hosted tables")
UI.PickOutside("red"); UI.PlaceSlip(); settle()
eq(spin:IsEnabled(), true, "a bet is on the table: Spin is live"); check(UI.IsGlowing(spin), "and glows")
local r0 = hostT.round
click(spin); settle()
eq(hostT.round, r0 + 1, "pressing Spin turned the wheel once")

-- the blackjack window at a house table
local bjT = House.FindTable(db, "Steve", "blackjack")
UI.OpenTable(bjT.code); settle(); UI.Refresh()
check(textOf("as soon as it is in") ~= nil, "blackjack tells the player the hand is dealt at once")
check(textOf("Dealing in") == nil and textOf("The host deals") == nil, "and mentions no host or countdown")
for _, f in ipairs(allByText("Leave table")) do f:Show() end
UI.Refresh()
for _, f in ipairs(allByText("Leave table")) do check(not f:IsShown(), "blackjack hides Leave too") end

-- the bookie's books
UI.OpenHouse()
check(textOf("Nobody has played yet") ~= nil, "an empty house says so")
fromWire("Ann lol", "HOUSE_REPORT", LOBBY, { rounds = 6, wagered = 6000, net = 3000 })
fromWire("Bo lol", "HOUSE_REPORT", LOBBY, { rounds = 2, wagered = 2000, net = -1000 })
UI.Refresh()
check(textOf("you owe") ~= nil, "a winning player is owed")
check(textOf("owes you") ~= nil, "a losing player owes the bookie")
check(textOf("2 players, 8 rounds") ~= nil, "the totals line")
local settleBtn = allByText("Settle")[1]
click(settleBtn)
eq(db.houseBook.players.Ann.paid, 0, "one click only asks")
check(#allByText("Sure?") == 1, "the button asks again")
click(allByText("Sure?")[1]); UI.Refresh()
eq(db.houseBook.players.Ann.paid, 3000, "the second click settles")
check(textOf("settled") ~= nil, "and the row says settled")
check(textOf("In all you are owed") ~= nil, "the totals follow")

eq(#stub.errors, 0, "no errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_house: all passed") else out_("test_house: " .. fails .. " FAILED") os.exit(1) end
