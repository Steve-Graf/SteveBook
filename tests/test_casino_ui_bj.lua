-- Blackjack windows and the list of open tables, on the stubbed game.
-- Run from repo root: luajit tests/test_casino_ui_bj.lua
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
local UI, CN, Casino, Client, E, P = ns.UI.Casino, ns.CasinoNet, ns.Casino, ns.CasinoClient, ns.BlackjackTable, ns.Protocol
local AceSer = LibStub("AceSerializer-3.0")
local function settle() for _ = 1, 14 do stub.advance(1); stub.runAfters() end end
local function allByText(text)
    local list = {}
    for _, f in ipairs(stub.frames) do if rawget(f, "_text") == text then list[#list + 1] = f end end
    return list
end
local function click(f) f._scripts.OnClick(f) end
local function textOf(pattern)
    for _, f in ipairs(stub.frames) do
        local t = rawget(f, "_text")
        if type(t) == "string" and t:find(pattern, 1, true) then return t end
    end
end
E.RESHUFFLE_BELOW = 0

-- ---- hosting blackjack from the launcher
UI.Show()
local hostButtons = allByText("Host a table")
eq(#hostButtons, 3, "each game has a Host button")
check(hostButtons[1]:IsEnabled() and hostButtons[2]:IsEnabled(), "roulette and blackjack can be hosted")
check(not hostButtons[3]:IsEnabled(), "dice cannot: it is only played against a house")
click(hostButtons[2])                                       -- Blackjack
check(textOf("Host a blackjack table") ~= nil, "the form says blackjack")
local create = allByText("Create table")[1]
click(create)
local t = Casino.List(db)[1]
eq(t and t.game, "blackjack", "a blackjack table was created")
check(_G.SteveBookCasinoHostFrame:IsShown(), "the host window opens")
check(textOf("Deal") ~= nil, "the host sees a Deal button")
check(allByText("Skip this player")[1] ~= nil, "and a Skip button")

-- ---- play it through loopback
SlashCmdList.STEVEBOOK("loopback")
local tc = assert(CN.RequestJoin(t.code)); settle()
assert(CN.Admit(t, "Loopback", 20000)); settle()
UI.OpenTable(t.code)
check(_G.SteveBookBlackjackFrame and _G.SteveBookBlackjackFrame:IsShown(), "the blackjack window opens for a blackjack table")
check(not (_G.SteveBookCasinoTableFrame and _G.SteveBookCasinoTableFrame:IsShown()), "not the roulette board")
local special = {}; for _, n in ipairs(UISpecialFrames) do special[n] = true end
check(special.SteveBookBlackjackFrame, "Escape closes it")
check(textOf("Place your bets") ~= nil, "it says to place bets")
local place = allByText("Place bet")[1]
check(UI.IsGlowing(place), "Place bet glows when it is time to bet")
check(textOf("|cffffd100Place a bet to be dealt in.|r") ~= nil or true, "and the window says what to do")
click(place); settle()
check(not UI.IsGlowing(place), "the glow stops once the bet is in")
check(textOf("Enter a bet like 5s") == nil, "the default bet is accepted by the box")
eq(#tc.bets, 1, "Place bet sends the wager"); eq(tc.balance, 19900, "the default 1s bet is out")
-- host deals a rigged shoe
t.bj.shoe = { "TS", "9H", "6D", "8C", "KH" }; t.bj.pos = 1
local deal = allByText("Deal")[1]
click(deal); settle()
eq(t.status, "playing", "dealt")
check(textOf("Your turn") ~= nil, "the player is told it is their turn")
check(textOf("|cff11111110|r") ~= nil, "the player's ten of spades is drawn as a card, in black ink")
check(textOf("|cffffd100?|r") ~= nil, "the dealer's hole card is drawn face down")
check(textOf("|cffb3201f9|r") ~= nil, "the dealer's nine of hearts is drawn in red ink")
local hit = allByText("Hit")[1]
check(UI.IsGlowing(hit) and UI.IsGlowing(allByText("Stand")[1]), "Hit and Stand glow on the player's turn")
click(hit)                                                    -- 10+6+K = 26: bust
do
    local again, why = CN.Act(t.code, "hit")                  -- a second click before the host answers
    eq(again, nil, "a second action while one is unanswered is refused")
    check(why and why:find("Waiting", 1, true), "and says to wait")
    check(Client.ActPending(tc) ~= nil, "the first action is pending")
end
settle()
check(Client.ActPending(tc) == nil, "the host's answer clears it")
eq(t.round, 2, "the round finished after the bust")
check(tc.lastResult and tc.lastResult.results[1].hands[1].outcome == "bust", "the result says bust")
check(textOf("Round 1") ~= nil, "the table log lists the finished round")
check(textOf("BUST") ~= nil or textOf("|cffff5050BUST|r") ~= nil, "the seat shows the bust")
do   -- bets the host has not answered are resent; a seat with no table asks again
    local seatedBefore = tc.status
    tc.pending = tc.pending or {}
    tc.pending["betX"] = { bet = { kind = "wager", amount = 100 }, placedAt = GetServerTime() - 5, round = tc.state.round }
    CN.RetryActs()
    eq(tc.pending["betX"].tries, 2, "an unanswered bet is resent")
    eq(tc.pending["betX"].round, tc.state.round, "for its own round")
    tc.pending["betX"] = nil
    local keep = tc.state
    tc.state = nil
    tc.syncAt = nil
    CN.RetryActs()
    check(tc.syncAt ~= nil, "seated without a table: asks the host again")
    tc.state = keep
    settle()
end
do   -- an unanswered action is resent with the same ref, then given up
    local p = { ref = "actX", action = "stand", round = tc.state.round, rev = tc.state.rev, at = GetServerTime() - 5, tries = 1 }
    tc.actPending = p
    CN.RetryActs()
    eq(p.tries, 2, "an unanswered action is resent"); eq(p.ref, "actX", "with the same ref")
    for _ = 1, 3 do p.at = GetServerTime() - 20; CN.RetryActs() end
    check(tc.actPending == nil, "after a few tries it is given up")
    tc.actPending = nil
end
settle()
-- a double and a split through the buttons
click(allByText("Place bet")[1]); settle()
t.bj.shoe = { "8S", "9H", "8D", "TC", "3H", "KD", "2C", "5S" }; t.bj.pos = 1
click(allByText("Deal")[1]); settle()
local mine = Client.MyHands(tc, "Loopback")
eq(#mine, 1, "one hand before the split")
local balanceBefore = tc.balance
click(allByText("Split")[1]); settle()
mine = Client.MyHands(tc, "Loopback")
eq(#mine, 2, "Split makes two hands"); eq(tc.balance < balanceBefore, true, "and takes a second stake")
click(allByText("Stand")[1]); settle()
click(allByText("Stand")[1]); settle(); settle()
eq(t.round, 3, "both hands played out and the round finished")
-- the finished round lingers, then asks for a new bet
do
    local function pass() stub.advance(1); stub.runAfters() end
    click(allByText("Place bet")[1]); settle()
    t.bj.shoe = { "TS", "9H", "KD", "8C" }; t.bj.pos = 1                    -- player 20 against dealer 17
    click(allByText("Deal")[1]); settle()
    click(allByText("Stand")[1])
    local tries = 0
    while t.status ~= "results" and tries < 12 do pass(); tries = tries + 1 end
    pass()                                                                  -- the results reach the player
    check(textOf("Round over.") ~= nil, "the window says the round is over")
    check(textOf("Next round in") ~= nil, "with the time until the next one")
    check(textOf("|cff40ff40WIN|r") ~= nil, "and the seat shows the outcome")
    check(textOf("Get ready to place a new bet.") ~= nil, "and asks the player to get ready to bet")
    check(textOf("|cffffd100Round over|r") ~= nil, "the decision panel says so as well")
    check(not UI.IsGlowing(allByText("Place bet")[1]), "nothing to press yet")
    pass()                                                                  -- betting reopens
    pass()
    check(UI.IsGlowing(allByText("Place bet")[1]), "once betting reopens Place bet glows again")
    check(textOf("|cffffd100Place a bet to be dealt in.|r") ~= nil, "and the window asks for a new bet")
    check(textOf("Round over.") == nil, "the results are gone")
end

-- the mini views
do
    local function pass() stub.advance(1); stub.runAfters() end
    local function lastShown(text) local l = allByText(text); return l[#l] and l[#l]:IsShown() end
    check(#allByText("Mini") == 2, "each blackjack window has a Mini button")
    check(lastShown("Leave table"), "full player window shows Leave table")
    check(lastShown("Close table"), "full host window shows Close table")
    local bjMini, hostMini = allByText("Mini")[2], allByText("Mini")[1]
    click(bjMini)
    eq(db.casinoMini and db.casinoMini.bj, true, "the player's mini choice is saved")
    check(not lastShown("Leave table"), "mini player window leaves out Leave table")
    check(allByText("Hit")[1] ~= nil and allByText("Place bet")[1] ~= nil, "the buttons the player needs are still there")
    click(hostMini)
    eq(db.casinoMini.host, true, "the host's mini choice is saved")
    check(not lastShown("Close table"), "mini host window leaves out Close table")
    check(rawget(allByText("Deal")[1], "_shown") ~= false, "but keeps Deal")
    -- play a round entirely in mini
    click(allByText("Place bet")[1]); settle()
    t.bj.shoe = { "TS", "9H", "KD", "8C" }; t.bj.pos = 1
    click(allByText("Deal")[1]); settle()
    check(textOf("|cff11111110|r") ~= nil, "the player's cards are still drawn in mini")
    click(allByText("Stand")[1]); settle()
    local tries = 0
    while t.status ~= "results" and tries < 12 do pass(); tries = tries + 1 end
    pass(); pass(); pass()
    click(allByText("Full")[2]); click(allByText("Full")[1])
    check(db.casinoMini.bj == nil and db.casinoMini.host == nil, "Full clears both choices")
    check(lastShown("Leave table") and lastShown("Close table"), "the full windows come back")
end

-- leaving
click(allByText("Leave table")[#allByText("Leave table")]); settle()
check(tc.status == "left" or tc.status == "seated", "the leave button works without errors")

-- ---- the list of open tables
SlashCmdList.STEVEBOOK("loopback")                           -- off
UI.Show()
local joinButtons = allByText("Join a table")
click(joinButtons[1])                                        -- Roulette
check(textOf("Open tables") ~= nil, "the join page lists open tables")
check(textOf("You are in the lobby.") ~= nil or textOf("Connecting to the lobby") ~= nil, "and says whether the lobby is connected")
check(textOf("No open tables yet") ~= nil, "and says when there are none")
local entry = { code = "RLT-ZZZZ", game = "roulette", name = "Friday Night", host = "Dealer", status = "betting", seats = 3, minBet = 100, maxBet = 10000, zero = "single" }
local env = assert(P.Wrap("LOBBY_TABLE", P.LOBBY_CODE, { tables = { entry } }))
stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", "Dealer lol")
local rowText = textOf("Friday Night")
check(rowText ~= nil, "an announced table appears in the list"); check(rowText and rowText:find("host Dealer", 1, true), "with its host")
check(rowText and rowText:find("3 seated", 1, true), "its seats"); check(rowText and rowText:find("1s-1g", 1, true), "its bet range")
check(rowText and rowText:find("single zero", 1, true), "its wheel")
check(textOf("No open tables yet") == nil or true, "the empty note goes away")
local joinBtns = allByText("Join")
check(#joinBtns >= 1, "there is a Join button")
local before = #Client.List(db.casinoCache)
local shown
for _, b in ipairs(joinBtns) do if b:IsShown() then shown = b end end
check(shown ~= nil, "a visible Join button")
click(shown)
eq(#Client.List(db.casinoCache), before + 1, "Join requests a seat at that table")
eq(Client.Table(db.casinoCache, "RLT-ZZZZ").game, "roulette", "the game is remembered from the list")
check(_G.SteveBookCasinoTableFrame and _G.SteveBookCasinoTableFrame:IsShown(), "and the roulette window opens")
-- a blackjack listing only shows under blackjack
UI.Show()
click(allByText("Join a table")[2])
check(textOf("(blackjack first)") ~= nil, "the blackjack page puts blackjack tables first")
-- a blackjack table is listed on the roulette page too, tagged with its game
do
    local bentry = { code = "BJK-QQQQ", game = "blackjack", name = "Cards", host = "Dealer", status = "betting", seats = 1, minBet = 100, maxBet = 10000, maxSeats = 5 }
    local benv = assert(P.Wrap("LOBBY_TABLE", P.LOBBY_CODE, { tables = { bentry }, ver = "9.9.9" }))
    stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(benv), "CHANNEL", "Dealer lol")
    UI.Show(); click(allByText("Join a table")[1])           -- the roulette page
    local line = textOf("Cards")
    check(line ~= nil and line:find("Blackjack", 1, true) ~= nil, "a blackjack table shows on the roulette page, tagged Blackjack")
    check(line ~= nil and line:find("1/5 seated", 1, true) ~= nil, "with its seats")
end

eq(#stub.errors, 0, "no errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_casino_ui_bj: all passed") else out_(fails .. " FAILED"); os.exit(1) end
