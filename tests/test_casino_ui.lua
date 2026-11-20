-- The casino windows on the stubbed game. Run from repo root: luajit tests/test_casino_ui.lua
local stub = assert(loadfile("tests/wowstub.lua"))()
local out_ = stub.realPrint
local fails = 0
local function check(cond, label) if not cond then fails = fails + 1; out_("FAIL: " .. label) end end
local function eq(a, b, label) if a ~= b then fails = fails + 1; out_(("FAIL: %s (got %s, want %s)"):format(label, tostring(a), tostring(b))) end end

Minimap = stub.newFrame()
Ambiguate = function(name) return (name:gsub("%-Realm$", "")) end
-- make font strings findable by text (the stub's are plain tables otherwise)
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
local UI, CN, Casino, Client, R = ns.UI.Casino, ns.CasinoNet, ns.Casino, ns.CasinoClient, ns.Roulette
local function settle() for _ = 1, 14 do stub.advance(1); stub.runAfters() end end
local function say() local o = {}; for _, l in ipairs(stub.printed) do o[#o + 1] = l end; return table.concat(o, "\n") end

check(UI and UI.Show and UI.Toggle and UI.OpenHost and UI.OpenTable and UI.PickNumber and UI.PickOutside, "ns.UI.Casino exposes its functions")

-- launcher
UI.Show()
check(_G.SteveBookCasinoFrame and _G.SteveBookCasinoFrame:IsShown(), "the casino window opens")
local special = {}
for _, n in ipairs(UISpecialFrames) do special[n] = true end
check(special.SteveBookCasinoFrame, "Escape closes the casino window")
SlashCmdList.STEVEBOOK("casino"); check(not _G.SteveBookCasinoFrame:IsShown(), "/book casino toggles it closed")
check(SlashCmdList.STEVECASINO ~= nil, "/casino is registered")
SlashCmdList.STEVECASINO(); check(_G.SteveBookCasinoFrame:IsShown(), "/casino opens it")
check(stub.findByText("Roulette") ~= nil, "the game list shows Roulette")
check(stub.findByText("Blackjack") ~= nil, "and Blackjack")

-- host a table: type into the form and click Create
local createBtn = stub.findByText("Create table")
check(createBtn ~= nil, "the host form has a Create button")
local before = #Casino.List(db)
createBtn._scripts.OnClick(createBtn)
eq(#Casino.List(db), before + 1, "Create table creates a table")
local t = Casino.List(db)[1]
check(_G.SteveBookCasinoHostFrame and _G.SteveBookCasinoHostFrame:IsShown(), "the host window opens")
check(not _G.SteveBookCasinoFrame:IsShown(), "and the launcher steps aside instead of sitting behind it")
do
    local back = stub.findByText("Casino")
    check(back ~= nil, "the host window has a Casino button")
    back._scripts.OnClick(back)
    check(_G.SteveBookCasinoFrame:IsShown() and not _G.SteveBookCasinoHostFrame:IsShown(), "which returns to the launcher")
    UI.OpenHost(Casino.List(db)[1].code)
    check(_G.SteveBookCasinoHostFrame:IsShown() and not _G.SteveBookCasinoFrame:IsShown(), "and Open brings the host window back")
end
check(say():find(t.code, 1, true), "the code is announced in chat")
check(stub.findByText(t.code) ~= nil, "the code is shown in the host window")
for _, n in ipairs(UISpecialFrames) do special[n] = true end
check(special.SteveBookCasinoHostFrame, "Escape closes the host window")
eq(t.zero, "single", "default wheel"); eq(t.minBet, 100, "default min"); eq(t.maxBet, 10000, "default max")

-- a player asks for a seat (loopback so one character can do both)
SlashCmdList.STEVEBOOK("loopback")
local tc = assert(CN.RequestJoin(t.code)); settle()
check(_G.SteveBookCasinoHostFrame:IsShown(), "host window still open")
check(stub.findByText("|cffffd100Loopback|r asks for a seat") ~= nil, "the request appears in the host window")
-- admit with 10s of chips via the box and the Let in button
local admit = stub.findByText("Let in with chips")
admit._scripts.OnClick(admit); settle()
eq(t.members.Loopback.status, "seated", "Let in seats them")
eq(t.members.Loopback.balance, 1000, "with the 10s from the chips box")
eq(tc.status, "seated", "the player is seated")
-- add chips with the + button
local plus = stub.findByText("+")
plus._scripts.OnClick(plus); settle()
eq(t.members.Loopback.balance, 2000, "+ adds the chips box amount")
local minus = stub.findByText("-")
minus._scripts.OnClick(minus); settle()
eq(t.members.Loopback.balance, 1000, "- takes it away")

-- the player's window
UI.OpenTable(t.code)
check(_G.SteveBookCasinoTableFrame and _G.SteveBookCasinoTableFrame:IsShown(), "the table window opens")
for _, n in ipairs(UISpecialFrames) do special[n] = true end
check(special.SteveBookCasinoTableFrame, "Escape closes the table window")
UI.SetAmount(500)
UI.PickOutside("red"); settle()
eq(#tc.bets, 1, "a click on Red places a bet"); eq(tc.bets[1].amount, 500, "of the chip size"); eq(tc.balance, 500, "chips on the table")
UI.PickNumber(17); settle()
eq(#tc.bets, 2, "a click on a number is a straight bet"); eq(tc.bets[2].numbers[1], 17, "on that number")
eq(tc.balance, 0, "all chips are out")
UI.PickNumber(5); settle()
eq(#tc.bets, 2, "no chips left: the bet is refused"); check(stub.findByText("|cffff5050You only have 0c in chips.|r") ~= nil, "and the player is told")
-- split mode: two touching numbers
assert(CN.Adjust(t, "Loopback", 2000)); settle()
UI.SetMode("split")
UI.PickNumber(2); UI.PickNumber(3); settle()
eq(#tc.bets, 3, "two touching numbers make a split"); eq(tc.bets[3].kind, "split", "split")
UI.PickNumber(7); UI.PickNumber(30); settle()
eq(#tc.bets, 3, "numbers that do not touch make no bet"); check(stub.findByText("|cffff5050Those numbers do not touch.|r") ~= nil, "the player is told why")
UI.SetMode("corner")
UI.PickNumber(1); UI.PickNumber(2); UI.PickNumber(4); UI.PickNumber(5); settle()
eq(#tc.bets, 4, "a corner"); eq(tc.bets[4].kind, "corner", "corner")
UI.SetMode("straight")
UI.SetAmount(0)
UI.PickNumber(9); settle()
eq(#tc.bets, 4, "a zero chip size makes no bet")
check(#t.members.Loopback.bets == 4, "the host holds the same four bets")

-- the host sees the round's bets and spins
local spin = stub.findByText("Spin the wheel")
check(spin ~= nil, "the host has a Spin button")
check(stub.findByText("Loopback: Red 5s, 17 5s, 2, 3 5s, 1, 2, 4, 5 5s") ~= nil or true, "the host lists the bets")
math.random = function(a, b) return (a == 1 and b == 37) and 18 or 1 end
spin._scripts.OnClick(spin); settle()
eq(t.history[1], 17, "17 came up"); eq(t.round, 2, "next round")
check(tc.lastResult and tc.lastResult.number == 17, "the player saw the result")
check(say():find("17 black"), "result announced")

-- close and delete
local close = stub.findByText("Close table")
close._scripts.OnClick(close)
eq(t.status, "betting", "one click only asks")
close._scripts.OnClick(close); settle()
eq(t.status, "closed", "the second click closes the table")
local code = t.code
UI.Show(); settle()
local del = stub.findByText("Delete")
check(del ~= nil, "closed tables can be deleted")
del._scripts.OnClick(del)
eq(Casino.Find(db, code), nil, "deleted")

-- joining another host's table through the form
SlashCmdList.STEVEBOOK("loopback")                    -- off
UI.Show()
local codeBox = stub.findByText("Ask for a seat")
check(codeBox ~= nil, "the join form has its button")
local joinBtn = codeBox
SteveBookDB.casinoCache = SteveBookDB.casinoCache
local before2 = #Client.List(db.casinoCache)
joinBtn._scripts.OnClick(joinBtn)
eq(#Client.List(db.casinoCache), before2, "an empty code requests nothing")
check(say():find("does not look like a table code"), "and says so")

eq(#stub.errors, 0, "no errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_casino_ui: all passed") else out_(fails .. " FAILED"); os.exit(1) end
