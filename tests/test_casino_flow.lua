-- The whole casino flow as a player lives it: joining, leaving and coming back, closing windows,
-- losing the host, chat alerts. One character plays both sides with /book loopback.
-- Run from repo root: luajit tests/test_casino_flow.lua
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
local ADDON, DIR = "SteveBook/", "SteveBook/"
ADDON = "SteveBook"
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
local UI, CN, Casino, Client, E = ns.UI.Casino, ns.CasinoNet, ns.Casino, ns.CasinoClient, ns.BlackjackTable
local function settle() for _ = 1, 14 do stub.advance(1); stub.runAfters() end end
local function pass() stub.advance(1); stub.runAfters() end
local function allByText(text)
    local list = {}
    for _, f in ipairs(stub.frames) do if rawget(f, "_text") == text then list[#list + 1] = f end end
    return list
end
local function textOf(pattern)
    for _, f in ipairs(stub.frames) do
        local t = rawget(f, "_text")
        if type(t) == "string" and t:find(pattern, 1, true) then return t end
    end
end
local function click(f) f._scripts.OnClick(f) end
local printedFrom = 0
local function chat() local t = {}; for i = printedFrom + 1, #stub.printed do t[#t + 1] = stub.printed[i] end; printedFrom = #stub.printed; return table.concat(t, "\n") end
E.RESHUFFLE_BELOW = 0
local realRandom = math.random
SlashCmdList.STEVEBOOK("loopback")

------------------------------------------------------------------------------------------
-- joining from the list, starting a game
------------------------------------------------------------------------------------------
local t = assert(CN.Create({ game = "roulette", name = "Flow Table" })); settle()
UI.Show()
click(allByText("Join a table")[1]); settle()                   -- Roulette join page
local rows = CN.Rooms("roulette")
eq(#rows, 1, "with loopback the table is on the list"); eq(rows[1].maxSeats, 12, "with its seat count")
check(textOf("0/12 seated") ~= nil, "and the page shows the seats as 0/12")
local joinBtn
for _, b in ipairs(allByText("Join")) do if b:IsShown() then joinBtn = b end end
click(joinBtn); settle()
local tc = Client.Table(db.casinoCache, t.code)
eq(tc.status, "requested", "Join from the list sends the request"); eq(tc.game, "roulette", "and remembers the game")
check(_G.SteveBookCasinoTableFrame:IsShown(), "the table window opens, waiting")
check(textOf("Waiting for the host to let you in") ~= nil, "and says it is waiting")
-- the host admits
assert(CN.Admit(t, "Loopback", 5000)); settle()
eq(tc.status, "seated", "seated"); eq(tc.balance, 5000, "with chips")

------------------------------------------------------------------------------------------
-- closing windows does not leave the table or stop the game
------------------------------------------------------------------------------------------
UI.SetAmount(500); UI.PickOutside("red"); UI.PlaceSlip(); settle()
eq(#tc.bets, 1, "a bet is on the table")
_G.SteveBookCasinoTableFrame:Hide(); _G.SteveBookCasinoFrame:Hide()
if _G.SteveBookCasinoHostFrame then _G.SteveBookCasinoHostFrame:Hide() end
eq(tc.status, "seated", "closing the windows does not leave the table"); eq(t.members.Loopback.status, "seated", "the host still has the player seated")
eq(#tc.bets, 1, "the bet stays on the table")
math.random = function(a, b) return (a == 1 and b == 37) and 20 or 1 end        -- pocket 19 (red)
eq(CN.Spin(t), true, "the host can spin with every window closed"); settle()
math.random = realRandom
eq(t.round, 2, "the round finished"); eq(tc.lastResult.number, 19, "the closed window still received the result")
eq(tc.balance, 5000 - 500 + 1000, "and the player was paid (500 back with 500 won)")
check(chat():find("19 red", 1, true) ~= nil, "chat reported the result")
UI.OpenTable(t.code)
check(_G.SteveBookCasinoTableFrame:IsShown(), "reopening shows the table"); check(textOf("Taking bets") ~= nil, "in the current round")
eq(tc.status, "seated", "still seated after reopening")

------------------------------------------------------------------------------------------
-- leaving and asking to rejoin
------------------------------------------------------------------------------------------
local leave = allByText("Leave table")[#allByText("Leave table")]
click(leave); settle()
eq(tc.status, "left", "left"); eq(t.members.Loopback.status, "left", "the host knows")
local rejoin = allByText("Ask to rejoin")[1]
check(rejoin ~= nil, "the window offers Ask to rejoin"); check(UI.IsGlowing(rejoin), "and it glows")
check(textOf("You left the table. Your chips are safe") ~= nil, "and says the chips are safe")
local chipsBefore = t.members.Loopback.balance
click(rejoin); settle()
eq(tc.status, "requested", "asking to rejoin sends a request"); eq(t.members.Loopback.status, "pending", "the host sees it as pending")
check(chat():find("wants a seat", 1, true) ~= nil, "the host is told in chat")
UI.OpenHost(t.code)
check(textOf("Let back in") ~= nil, "the host's window says Let back in, not Let in with chips")
check(textOf("|cffffd100Next: Loopback is back. Let them back in (their chips are kept).|r") ~= nil, "and the hint explains")
click(allByText("Let back in")[1]); settle()
eq(tc.status, "seated", "back at the table"); eq(t.members.Loopback.balance, chipsBefore, "with exactly the chips they had")
-- a removed player cannot ask again
assert(CN.Kick(t, "Loopback")); settle()
eq(tc.status, "removed", "removed by the host")
UI.OpenTable(t.code)
check(allByText("Ask to rejoin")[1] == nil or not allByText("Ask to rejoin")[1]:IsShown(), "a removed player is not offered Ask to rejoin")
CN.RequestJoin(t.code); settle()
eq(tc.status, "removed", "and asking anyway is refused again")
-- a player who was turned down may try again
assert(CN.Admit(t, "Loopback", 0)); settle()
eq(tc.status, "seated", "the host can take a removed player back")

------------------------------------------------------------------------------------------
-- the host goes quiet
------------------------------------------------------------------------------------------
UI.OpenTable(t.code)
CN.Heartbeat(); settle()
check(textOf("No word from the host") == nil, "no warning while the host is heard")
stub.advance(60); UI.Refresh()
check(textOf("No word from the host for") ~= nil, "after a minute of silence the window warns the player")
check(textOf("your seat and chips are safe") ~= nil, "and reassures them")
CN.Heartbeat(); settle()
check(textOf("No word from the host") == nil, "the warning clears when the host is heard again")
-- a bet the host never answers
chat()
Client.NewPending(db.casinoCache, t.code, "lost1", { kind = "red", amount = 100 }, stub.time - 30)
CN.tick()
check(chat():find("did not answer a bet", 1, true) ~= nil, "a bet that is never answered is reported, and the chips were not taken")

------------------------------------------------------------------------------------------
-- blackjack: chat alerts when the window is closed
------------------------------------------------------------------------------------------
local bt = assert(CN.Create({ game = "blackjack", name = "Alert Table" })); settle()
local btc = assert(CN.RequestJoin(bt.code)); settle()
assert(CN.Admit(bt, "Loopback", 20000)); settle()
UI.OpenTable(bt.code)
click(allByText("Place bet")[1]); settle()
_G.SteveBookBlackjackFrame:Hide()
chat()
bt.bj.shoe = { "5S", "9H", "6D", "8C", "TH" }; bt.bj.pos = 1
assert(CN.Deal(bt)); settle()
local said = chat()
check(said:find("It's your turn in blackjack at Alert Table", 1, true) ~= nil, "a closed window gets 'It's your turn in blackjack' in chat")
local _, times = said:gsub("your turn in blackjack", "")
eq(times, 1, "once")
CN.Heartbeat(); settle()
check(select(2, chat():gsub("your turn in blackjack", "")) == 0, "the heartbeat does not repeat it")
UI.OpenTable(bt.code)
click(allByText("Stand")[1])
_G.SteveBookBlackjackFrame:Hide()                       -- the player closes the window while the round plays out
chat()
for _ = 1, 8 do pass() end
eq(bt.round, 2, "the round went on without the window")
check(chat():find("Betting is open in blackjack at Alert Table", 1, true) ~= nil, "when betting reopens a closed window gets a chat reminder")
-- an open window means no chat alert
UI.OpenTable(bt.code)
chat()
bt.bj.shoe = { "5S", "9H", "6D", "8C", "TH" }; bt.bj.pos = 1
assert(CN.Wager(bt.code, 100)); settle()
assert(CN.Deal(bt)); settle()
check(chat():find("your turn in blackjack", 1, true) == nil, "no chat alert while the window is open")

------------------------------------------------------------------------------------------
-- seat limits
------------------------------------------------------------------------------------------
local ft = assert(CN.Create({ game = "blackjack", name = "Full" })); settle()
for i = 1, 5 do Casino.RequestJoin(ft, "P" .. i, 1); assert(CN.Admit(ft, "P" .. i, 0)) end
Casino.RequestJoin(ft, "Extra", 1)
local ok, err = CN.Admit(ft, "Extra", 0)
eq(ok, nil, "the sixth player cannot be admitted"); check(err and err:find("table is full", 1, true) ~= nil, "with a clear message: " .. tostring(err))
UI.OpenHost(ft.code)
check(textOf("Asking for a seat") ~= nil, "the sixth player waits on the list")

eq(#stub.errors, 0, "no errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_casino_flow: all passed") else out_(fails .. " FAILED"); os.exit(1) end
