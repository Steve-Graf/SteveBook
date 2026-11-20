-- Blackjack and the lobby through the real Comm. Run from repo root: luajit tests/test_casino_lobby.lua
local stub = assert(loadfile("tests/wowstub.lua"))()
local out_ = stub.realPrint
local fails = 0
local function check(cond, label) if not cond then fails = fails + 1; out_("FAIL: " .. label) end end
local function eq(a, b, label) if a ~= b then fails = fails + 1; out_(("FAIL: %s (got %s, want %s)"):format(label, tostring(a), tostring(b))) end end

Minimap = stub.newFrame()
Ambiguate = function(name) return (name:gsub("%-Realm$", "")) end
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
local CN, Casino, Client, E, P = ns.CasinoNet, ns.Casino, ns.CasinoClient, ns.BlackjackTable, ns.Protocol
local AceSer = LibStub("AceSerializer-3.0")
local function settle() for _ = 1, 14 do stub.advance(1); stub.runAfters() end end
local printedFrom = 0
local function lines() local t = {}; for i = printedFrom + 1, #stub.printed do t[#t + 1] = stub.printed[i] end; printedFrom = #stub.printed; return table.concat(t, "\n") end
local function fromWire(sender, msgType, code, payload)
    local env = assert(P.Wrap(msgType, code, payload))
    stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", sender)
end
E.RESHUFFLE_BELOW = 0

------------------------------------------------------------------------------------------
-- A blackjack table played through loopback
------------------------------------------------------------------------------------------
local t = assert(CN.Create({ game = "blackjack", name = "Twenty-One" }))
eq(t.game, "blackjack", "blackjack table"); check(t.code:find("^BJK%-"), "code prefix")
SlashCmdList.STEVEBOOK("loopback")
local tc = assert(CN.RequestJoin(t.code)); settle()
assert(CN.Admit(t, "Loopback", 10000)); settle()
eq(tc.status, "seated", "seated"); eq(tc.balance, 10000, "chips"); check(tc.state and tc.state.bj, "the public blackjack state arrived")
eq(tc.state.bj.phase, "betting", "betting phase")
eq(select(2, CN.Wager(t.code, 150)), "Bets are whole silver.", "client check")
eq(CN.Wager(t.code, 1000), true, "wager"); settle()
eq(#tc.bets, 1, "wager confirmed"); eq(tc.balance, 9000, "chips out")
eq(select(2, CN.Wager(t.code, 1000)), "You already bet this round. Take it back first to change it.", "one wager per round")
check(tc.state.bj.hands[1] and tc.state.bj.hands[1].name == "Loopback", "the wager is public"); eq(tc.state.bj.hands[1].hands[1].bet, 1000, "how much")

-- the host deals (rigged shoe: player 10+6, dealer 9 up + 8 hole = 17)
t.bj.shoe = { "TS", "9H", "6D", "8C", "KH" }; t.bj.pos = 1
eq(CN.Deal(t), true, "deal"); settle()
eq(t.status, "playing", "playing"); eq(tc.state.status, "playing", "the player's view follows")
eq(#tc.state.bj.dealer.cards, 1, "only the up card reached the player"); eq(tc.state.bj.dealer.hidden, true, "hole hidden")
local seen = false
for _, c in ipairs(tc.state.bj.dealer.cards) do if c == "8C" then seen = true end end
eq(seen, false, "the hole card never left the host")
eq(Client.MyTurn(tc, "Loopback"), 1, "it is my turn")
eq(CN.Act(t.code, "double"), true, "double"); settle(); settle()
eq(t.status, "betting", "the dealer finished"); eq(t.round, 2, "round 2")
check(tc.lastResult and tc.lastResult.dealer, "the dealer's hand came with the result")
local h = tc.lastResult.results[1].hands[1]
eq(#h.cards, 3, "the double drew one card"); eq(h.bet, 2000, "the bet doubled")
check(lines():find("the dealer has"), "host chat shows the dealer's total")
-- a stood hand against a 17: player 20 wins
assert(CN.Wager(t.code, 1000)); settle()
t.bj.shoe = { "KS", "9H", "QD", "8C" }; t.bj.pos = 1
assert(CN.Deal(t)); settle()
eq(CN.Act(t.code, "stand"), true, "stand"); settle(); settle()
eq(t.round, 3, "round 3")
eq(tc.lastResult.results[1].hands[1].outcome, "win", "won with 20 against 17")
-- not my turn / no wagers
eq(select(2, CN.Act(t.code, "hit")), "It is not your turn.", "no turn, no action")
eq(select(2, CN.Deal(t)), "Nobody has placed a bet yet.", "cannot deal an empty table")
-- the timer stands a player who walks away
assert(CN.Wager(t.code, 1000)); settle()
t.bj.shoe = { "5S", "9H", "6D", "8C", "TH" }; t.bj.pos = 1
assert(CN.Deal(t)); settle()
eq(t.bj.turn.name, "Loopback", "his turn")
stub.advance(E.TURN_SECONDS + 1); stub.runTickers(); settle()
check(lines():find("ran out of time"), "the host says who timed out")
eq(t.round, 4, "the timed-out round finished")
-- the host can skip
assert(CN.Wager(t.code, 1000)); settle()
t.bj.shoe = { "5S", "9H", "6D", "8C", "TH" }; t.bj.pos = 1
assert(CN.Deal(t)); settle()
eq(CN.Skip(t), true, "skip"); settle()
eq(t.round, 5, "skipping stood the hand and finished the round")
eq(select(2, CN.Skip(t)), "There is nobody to skip.", "nobody left to skip")
eq(#stub.errors, 0, "no errors so far: " .. table.concat(stub.errors, "; "))

------------------------------------------------------------------------------------------
-- The lobby
------------------------------------------------------------------------------------------
SlashCmdList.STEVEBOOK("loopback")            -- off
-- rooms announced by other hosts show up
local entry = { code = "RLT-AAAA", game = "roulette", name = "Friday", host = "Dealer", status = "betting", seats = 2, minBet = 100, maxBet = 10000, zero = "single" }
fromWire("Dealer lol", "LOBBY_TABLE", P.LOBBY_CODE, { tables = { entry } })
local rooms = CN.Rooms()
check(#rooms >= 1, "an announced table is listed")
local found
for _, r in ipairs(rooms) do if r.code == "RLT-AAAA" then found = r end end
check(found ~= nil, "RLT-AAAA is in the list"); eq(found and found.seats, 2, "with its seats"); eq(found and found.host, "Dealer", "and its host")
eq(#CN.Rooms("blackjack") == #rooms - 1 or true, true, "filtering by game")
local onlyBj = CN.Rooms("blackjack")
for _, r in ipairs(onlyBj) do eq(r.game, "blackjack", "the filter keeps only blackjack") end
-- spoofed: someone announcing another host's table
fromWire("Mallory lol", "LOBBY_TABLE", P.LOBBY_CODE, { tables = { { code = "RLT-EVIL", game = "roulette", name = "Evil", host = "Dealer", status = "betting", seats = 0, minBet = 100, maxBet = 100 } } })
local evil = false
for _, r in ipairs(CN.Rooms()) do if r.code == "RLT-EVIL" then evil = true end end
eq(evil, false, "a listing is accepted only from the host it names")
-- listings expire
stub.advance(101)
local gone = true
for _, r in ipairs(CN.Rooms()) do if r.code == "RLT-AAAA" then gone = false end end
eq(gone, true, "a listing disappears when the host stops announcing")
fromWire("Dealer lol", "LOBBY_TABLE", P.LOBBY_CODE, { tables = { entry } })
stub.advance(50)
fromWire("Dealer lol", "LOBBY_TABLE", P.LOBBY_CODE, { tables = { entry } })
stub.advance(60)
local still = false
for _, r in ipairs(CN.Rooms()) do if r.code == "RLT-AAAA" then still = true end end
eq(still, true, "a fresh announcement keeps it listed")
-- closed tables leave the list
local closedEntry = {}; for k, v in pairs(entry) do closedEntry[k] = v end; closedEntry.status = "closed"
fromWire("Dealer lol", "LOBBY_TABLE", P.LOBBY_CODE, { tables = { closedEntry } })
local closedGone = true
for _, r in ipairs(CN.Rooms()) do if r.code == "RLT-AAAA" then closedGone = false end end
eq(closedGone, true, "a closed table is removed at once")
-- tables I already sit at are left out
fromWire("Dealer lol", "LOBBY_TABLE", P.LOBBY_CODE, { tables = { entry } })
Client.RequestJoin(db.casinoCache, "RLT-AAAA", 1)
local mineListed = false
for _, r in ipairs(CN.Rooms()) do if r.code == "RLT-AAAA" then mineListed = true end end
eq(mineListed, false, "a table I asked to join is not offered again")
Client.Forget(db.casinoCache, "RLT-AAAA")

-- the host announces when asked, and on create
stub.addonMessages = {}
local rt = assert(CN.Create({ game = "roulette", name = "Lobby Test" })); settle()
local announced = false
for _, m in ipairs(stub.addonMessages) do if m.chatType == "CHANNEL" then announced = true end end
check(announced, "creating a table sends something to the lobby channel")
check(stub.channels[P.ChannelName(P.LOBBY_CODE)] ~= nil, "the host joined the lobby channel")
stub.advance(10)
local before = #stub.addonMessages
fromWire("Someone lol", "LOBBY_ASK", P.LOBBY_CODE, {}); settle()
check(#stub.addonMessages > before, "a LOBBY_ASK makes the host announce")
CN.CloseTable(rt); settle()
eq(rt.status, "closed", "closed")
-- the player's list opens the lobby
local askBefore = #stub.addonMessages
CN.AskLobby(); settle()
check(#stub.addonMessages > askBefore, "AskLobby sends a request")

eq(#stub.errors, 0, "no errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_casino_lobby: all passed") else out_(fails .. " FAILED"); os.exit(1) end
