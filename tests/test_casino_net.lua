-- A casino table through the real Comm (AceComm/ChatThrottleLib on the stub), one character acting
-- as host and player via /book loopback. Run from repo root: luajit tests/test_casino_net.lua
local stub = assert(loadfile("tests/wowstub.lua"))()
local out_ = stub.realPrint
local fails = 0
local function check(cond, label) if not cond then fails = fails + 1; out_("FAIL: " .. label) end end
local function eq(a, b, label) if a ~= b then fails = fails + 1; out_(("FAIL: %s (got %s, want %s)"):format(label, tostring(a), tostring(b))) end end

Minimap = stub.newFrame()
Ambiguate = function(name) return (name:gsub("%-Realm$", "")) end        -- AceComm binds this when it loads
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
local CN, Casino, Client = ns.CasinoNet, ns.Casino, ns.CasinoClient
local function settle() for _ = 1, 14 do stub.advance(1); stub.runAfters() end end
local printedFrom = 0
local function lines() local t = {}; for i = printedFrom + 1, #stub.printed do t[#t + 1] = stub.printed[i] end; printedFrom = #stub.printed; return table.concat(t, "\n") end

-- host: create a table
local t = assert(CN.Create({ game = "roulette", name = "Test Table", zero = "single" }))
eq(db.casino.tables[t.code], t, "the table is saved"); check(ns.Comm.IsJoined(t.code) or stub.channels[ns.Protocol.ChannelName(t.code)] ~= nil, "the host joined the table's channel")
local events = 0
CN.Subscribe(function() events = events + 1 end)

-- not the same character: a request to my own table is refused unless loopback is on
eq(CN.RequestJoin(t.code), nil, "cannot join my own table without loopback")
SlashCmdList.STEVEBOOK("loopback")
local tc = assert(CN.RequestJoin(t.code))
eq(tc.me, "Loopback", "loopback seats me as 'Loopback'")
settle()
eq(t.members.Loopback and t.members.Loopback.status, "pending", "the host sees the request")
check(lines():find("wants a seat"), "the host is told in chat")
eq(CN.RequestJoin("nonsense"), nil, "bad codes are refused")

-- admit with chips
assert(CN.Admit(t, "Loopback", 5000)); settle()
eq(tc.status, "seated", "the player is seated"); eq(tc.owner, stub.player, "host pinned")
eq(tc.balance, 5000, "chips arrived"); check(tc.state and tc.state.status == "betting", "state arrived")
eq(tc.state.seats[1].name, "Loopback", "seat list"); eq(tc.state.round, 1, "round 1")
check(events > 0, "windows are told")

-- bets
eq(CN.PlaceBet(t.code, { kind = "red", amount = 1000 }), true, "place a bet"); settle()
eq(#tc.bets, 1, "the bet is confirmed"); eq(tc.balance, 4000, "balance dropped"); eq(next(tc.pending), nil, "nothing pending")
eq(select(2, CN.PlaceBet(t.code, { kind = "red", amount = 150 })), "Bets are whole silver.", "client-side whole silver check")
eq(select(2, CN.PlaceBet(t.code, { kind = "bogus", amount = 100 })), "Unknown bet type.", "client-side bet check")
eq(select(2, CN.PlaceBet(t.code, { kind = "red", amount = 50000 })), "The maximum bet is " .. ns.Odds.FormatMoney(10000) .. ".", "client-side max")
eq(select(2, CN.PlaceBet(t.code, { kind = "red", amount = 9000 })), "You only have 40s in chips.", "client-side chips check")
assert(CN.PlaceBet(t.code, { kind = "straight", numbers = { 17 }, amount = 500 })); settle()
eq(#tc.bets, 2, "two bets"); eq(tc.balance, 3500, "balance")
-- a host-side rejection reaches the player's chat
lines()
t.maxBet = 1000                                      -- the host lowered the limit; the player's copy is stale
assert(CN.PlaceBet(t.code, { kind = "red", amount = 2000 })); settle()
check(lines():find("maximum bet here is"), "the host's rejection is explained")
eq(next(tc.pending), nil, "rejected bet is no longer pending")
eq(#tc.bets, 2, "and it was not booked"); t.maxBet = 10000

-- take everything back, then bet again
assert(CN.ClearBets(t.code)); settle()
eq(#tc.bets, 0, "bets cleared"); eq(tc.balance, 5000, "chips back")
assert(CN.PlaceBet(t.code, { kind = "straight", numbers = { 17 }, amount = 1000 }))
assert(CN.PlaceBet(t.code, { kind = "black", amount = 500 })); settle()
eq(tc.balance, 3500, "5000 - 1500")

-- spin: 17 (black) pays both
math.random = function(a, b) return (a == 1 and b == 37) and 18 or 1 end        -- the 18th pocket of 0..36 is 17
local before = #stub.printed
eq(CN.Spin(t), true, "spin"); eq(t.status, "spinning", "spinning")
eq(select(2, CN.Spin(t)), "The wheel is already turning.", "cannot spin while it turns")
settle()
eq(t.status, "betting", "betting again"); eq(t.round, 2, "round 2")
eq(t.history[1], 17, "17 came up")
eq(tc.balance, 3500 + 36000 + 1000, "the player was paid: 36x on 10s straight, 2x on 5s black")
eq(tc.lastResult.number, 17, "result delivered"); eq(#tc.bets, 0, "bets cleared")
check(lines():find("17 black") ~= nil, "chat shows the result")
eq(tc.state.round, 2, "state shows round 2"); eq(tc.state.history[1], 17, "history shown")

-- stale round: a request for an old round is refused and a sync follows
tc.state.round = 1
assert(CN.PlaceBet(t.code, { kind = "red", amount = 100 })); settle()
check(lines():find("Betting is closed for that round"), "stale round is explained")
eq(tc.state.round, t.round, "and the player re-synced to the host's round")

-- leave, rejoin
eq(CN.Leave(t.code), true); settle()
eq(tc.status, "left", "left")
eq(t.members.Loopback.status, "left", "host agrees")
eq(select(2, CN.PlaceBet(t.code, { kind = "red", amount = 100 })), "Betting is closed right now.", "cannot bet after leaving")
CN.RequestJoin(t.code); settle()
eq(t.members.Loopback.status, "pending", "asking again is a new request")
assert(CN.Admit(t, "Loopback", 0)); settle()
eq(tc.status, "seated", "back at the table"); eq(tc.balance, 3500 + 36000 + 1000 - 100 + 100, "chips were kept")

-- kick
assert(CN.Kick(t, "Loopback")); settle()
eq(tc.status, "removed", "removed by the host")

-- close table + delete
eq(CN.Delete(t), nil, "cannot delete an open table")
assert(CN.CloseTable(t)); settle()
eq(t.status, "closed", "closed")
eq(CN.Delete(t), true, "deleted"); eq(db.casino.tables[t.code], nil, "gone")

-- forged host message: someone else claiming to be the host is ignored
do
    local tc2 = Client.RequestJoin(db.casinoCache, "RLT-FAKE", 1)
    eq(tc2.status, "requested", "pending request")
    local Comm = ns.Comm
    local AceSer = LibStub("AceSerializer-3.0")
    local env = assert(ns.Protocol.Wrap("TBL_JOIN_OK", "RLT-FAKE", { game = "roulette", name = "Evil", ownerName = "Steve", rev = 1 }))
    stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", "Mallory lol")
    eq(tc2.status, "requested", "a JOIN_OK from someone who is not the named host is ignored")
    env = assert(ns.Protocol.Wrap("TBL_JOIN_OK", "RLT-FAKE", { game = "roulette", name = "Real", ownerName = "Steve", rev = 1 }))
    stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", "Steve Spinebreaker")
    eq(tc2.status, "seated", "a JOIN_OK from the named host (spaced Forever name) seats us")
    env = assert(ns.Protocol.Wrap("TBL_STATE", "RLT-FAKE", { rev = 9, game = "roulette", name = "Fake", status = "betting", round = 1, minBet = 100, maxBet = 100, seats = {}, history = {} }))
    stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", "Mallory lol")
    eq(tc2.state, nil, "state from an impostor is ignored")
end

eq(#stub.errors, 0, "no handler errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_casino_net: all passed") else out_(fails .. " FAILED"); os.exit(1) end
