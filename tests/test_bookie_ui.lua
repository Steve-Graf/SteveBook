-- Smoke test for SteveBook/UI/Bookie.lua with a stubbed WoW API. It drives the real widgets
-- (via UI.widgets / UI.rows) through the whole bookie flow, checks what the window shows and what
-- goes out over Comm. It cannot check that real frame templates exist: do that in game (README).
-- Run from repo root: lua5.1 tests/test_bookie_ui.lua
local realprint = print
local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; realprint("FAIL: " .. label) end
end
local function eq(got, want, label)
    check(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

-- stub frames -----------------------------------------------------------------------------
local Frame = {}
Frame.__index = function(self, k)
    local v = rawget(Frame, k)
    if v ~= nil then return v end
    return function() return self end   -- any other method: no-op returning the frame
end
local function script(self, name) local s = rawget(self, "_scripts"); return s and s[name] end
function Frame.SetText(self, t) rawset(self, "_text", t) end
function Frame.GetText(self) return rawget(self, "_text") or "" end
function Frame.SetScript(self, name, fn) local s = rawget(self, "_scripts"); if not s then s = {}; rawset(self, "_scripts", s) end; s[name] = fn end
function Frame.GetWidth() return 600 end
function Frame.GetHeight() return 400 end
function Frame.GetVerticalScroll() return 0 end
function Frame.Show(self) rawset(self, "_shown", true) end
function Frame.Hide(self) rawset(self, "_shown", false) end
function Frame.SetShown(self, v) rawset(self, "_shown", v and true or false) end
function Frame.IsShown(self) return rawget(self, "_shown") == true end
function Frame.SetEnabled(self, v) rawset(self, "_enabled", v and true or false) end
function Frame.IsEnabled(self) return rawget(self, "_enabled") ~= false end
function Frame.Click(self) local f = script(self, "OnClick"); assert(f, "button has no OnClick: " .. tostring(rawget(self, "_text"))); f(self) end
function Frame.CreateFontString() return setmetatable({ _text = "" }, Frame) end
local function newFrame() return setmetatable({}, Frame) end

function CreateFrame() return newFrame() end
UIParent = newFrame()
local T = 1000000
function GetServerTime() return T end
function UnitName() return "Steve" end
date = os.date
local chat = {}
print = function(s) chat[#chat + 1] = s end
local function chatText() local c = table.concat(chat, "\n"); chat = {}; return c end
C_Timer = { NewTicker = function() end }

-- addon + stubbed Comm ----------------------------------------------------------------------
local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Import.lua"))("SteveBook", ns)   -- before the window: it captures ns.Import at load
assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)
local Model = assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)
local Bookie = assert(loadfile("SteveBook/Bookie.lua"))("SteveBook", ns)
local handlers, sent, joined = {}, {}, {}
ns.Comm = {
    Register = function(t, fn) handlers[t] = fn end,
    Send = function(t, payload, code, to)
        local env, err = ns.Protocol.Wrap(t, code, payload)
        check(env ~= nil, "UI sent invalid " .. t .. ": " .. tostring(err))
        sent[#sent + 1] = { type = t, payload = payload, code = code, to = to }
        return true
    end,
    JoinBook = function(c) joined[#joined + 1] = c end,
    Me = function() return "Steve" end,
}
SteveBookDB = Model.NewDB()
assert(loadfile("SteveBook/BookieNet.lua"))("SteveBook", ns)
local UI = assert(loadfile("SteveBook/UI/Bookie.lua"))("SteveBook", ns)
check(UI == ns.UI.Bookie and UI.Show and UI.Hide and UI.Toggle, "ns.UI.Bookie exposes Show/Hide/Toggle")
local W = UI.widgets

local function drain() local s = sent; sent = {}; return s end
local function find(frames, text)
    for _, f in ipairs(frames) do
        if f:GetText() == text and f:IsShown() then return f end
    end
end
local function rowBtn(i, text)
    local r = UI.rows[i]
    local b = r and find(r.btn, text)
    check(b, ("row %d has a visible [%s] button"):format(i, text))
    return b
end
local function rowText(i) return UI.rows[i] and UI.rows[i]:IsShown() and UI.rows[i].text:GetText() or "" end
local function rowSub(i) return UI.rows[i] and UI.rows[i].sub:GetText() or "" end

-- open the window: no book yet -> create-book prompt ------------------------------------------
UI.Show()
check(W.prompt:IsShown() and not W.scroll:IsShown(), "no book: prompt shown")
W.prompt.input:SetText("   ")
find(W.prompt.btn, "Create"):Click()
check(W.prompt:IsShown() and W.prompt.msg:GetText():find("book name required"), "empty name keeps the prompt open with a message")
W.prompt.input:SetText("NFL Week 12")
find(W.prompt.btn, "Create"):Click()
local book = Model.ActiveBook(SteveBookDB)
check(book and book.name == "NFL Week 12", "book created")
eq(joined[1], book and book.code, "new book's channel joined")
check(W.scroll:IsShown() and not W.prompt:IsShown(), "back to the list")
eq(W.codeBox:GetText(), book.code, "join code shown")
check(W.book:GetText():find(book.code, 1, true), "book button shows name and code")
check(chatText():find("Share the join code"), "chat tells the bookie to share the code")
check(rowText(1):find("No markets yet"), "empty markets message")

-- a join request arrives while the window is open ------------------------------------------
W.tabs.members:Click()
check(rowText(1):find("Nobody yet"), "members tab empty")
handlers.JOIN_REQ("Bob", {}, book.code)
check(rowText(1):find("Bob") and rowText(1):find("wants to join"), "pending request listed live")
eq(W.tabs.members:GetText(), "Members (1)", "pending count on the tab")
drain(); chatText()
rowBtn(1, "Approve"):Click()
local s = drain()
check(#s == 1 and s[1].type == "JOIN_OK" and s[1].to == "Bob", "Approve sends JOIN_OK")
check(rowText(1):find("Bob") and rowText(1):find("limit none"), "Bob is now active")
eq(W.tabs.members:GetText(), "Members", "pending count cleared")

rowBtn(1, "Limit"):Click()
check(W.prompt:IsShown() and W.prompt.input:IsShown(), "limit prompt open")
W.prompt.input:SetText("zero")
find(W.prompt.btn, "Set"):Click()
check(W.prompt:IsShown() and W.prompt.msg:GetText():find("Enter an amount"), "bad limit keeps the prompt open")
W.prompt.input:SetText("50g")
find(W.prompt.btn, "Set"):Click()
eq(book.members.Bob.creditLimit, 500000, "limit saved")
check(rowText(1):find("limit 50g"), "limit shown")
s = drain()
check(#s == 1 and s[1].type == "SYNC" and s[1].payload.creditLimit == 500000, "limit pushed to Bob in a SYNC")

handlers.JOIN_REQ("Eve", {}, book.code)
check(rowText(1):find("Eve") and rowText(1):find("wants to join"), "pending members sort first")
check(rowText(2):find("Bob"), "active members follow")
drain()
rowBtn(1, "Deny"):Click()
s = drain()
check(#s == 1 and s[1].type == "JOIN_DENY" and s[1].to == "Eve" and s[1].payload.reason == "denied" and s[1].payload.ownerName == "Steve", "Deny sends JOIN_DENY denied, naming the owner")
eq(book.members.Eve, nil, "denied request is deleted")
check(rowText(1):find("Bob"), "Bob back on top")

-- market form -----------------------------------------------------------------------------
W.tabs.markets:Click()
W.newMarket:Click()
check(W.form:IsShown() and not W.scroll:IsShown(), "form shown")
W.form.ok:Click()
check(W.form.msg:GetText():find("Event is required"), "empty form: " .. W.form.msg:GetText())
eq(next(book.markets), nil, "nothing created from an empty form")

local F = W.form.f
F.event:SetText("PHI @ DAL"); F.label1:SetText("PHI"); F.label2:SetText("DAL")
F.odds1:SetText("-150"); F.odds2:SetText("+130"); F.closes:SetText("2h")
W.form.typeBtn:Click()   -- spread
eq(W.form.typeBtn:GetText(), "Spread", "type cycles to spread")
W.form.ok:Click()
check(W.form.msg:GetText():find("Line must be"), "spread needs a line")
F.line:SetText("-3.5")
W.form.ok:Click()
local m = book.markets[1]
check(m and m.type == "spread" and m.line == -3.5 and m.closesAt == T + 7200, "market created from the form")
check(W.scroll:IsShown() and not W.form:IsShown(), "back to the list")
s = drain()
check(#s == 1 and s[1].type == "MARKET" and s[1].to == nil, "new market broadcast")
check(rowText(1):find("OPEN") and rowText(1):find("PHI @ DAL") and rowText(1):find("PHI %-3.5"), "row text: " .. rowText(1))
check(rowSub(1):find("PHI %-150 / DAL %+130") and rowSub(1):find("closes"), "row sub: " .. rowSub(1))

-- total auto-fills Over/Under
W.newMarket:Click()
W.form.typeBtn:Click(); W.form.typeBtn:Click()
eq(W.form.typeBtn:GetText(), "Total", "type cycles to total")
eq(F.label1:GetText(), "Over", "total fills Over")
eq(F.label2:GetText(), "Under", "total fills Under")
W.form.cancel:Click()
check(W.scroll:IsShown(), "cancel returns to the list")

-- refresh must not clobber a form in progress
W.newMarket:Click()
F.event:SetText("half typed")
handlers.JOIN_REQ("Mallory", {}, book.code)
check(W.form:IsShown() and F.event:GetText() == "half typed", "live refresh leaves the open form alone")
W.form.cancel:Click()

-- a bet arrives; exposure shows; lock/unlock ----------------------------------------------
handlers.BET_PLACE("Bob", { ref = "r1", marketId = 1, selectionId = 1, stake = 10000, odds = -150 }, book.code)
check(rowSub(1):find("staked") and rowSub(1):find("book if PHI wins"), "exposure in the row: " .. rowSub(1))
drain()
rowBtn(1, "Lock"):Click()
s = drain()
check(#s == 1 and s[1].payload.market.status == "locked", "Lock broadcasts")
check(rowText(1):find("LOCKED"), "row shows LOCKED")
rowBtn(1, "Unlock"):Click()
check(rowText(1):find("OPEN"), "Unlock reopens")
drain()

-- edit odds -------------------------------------------------------------------------------
rowBtn(1, "Odds"):Click()
check(W.form:IsShown() and F.odds1:GetText() == "-150" and F.line:GetText() == "-3.5", "edit form prefilled")
W.form.ok:Click()
check(W.form.msg:GetText():find("Nothing to change"), "unchanged edit refused")
F.odds1:SetText("-165")
W.form.ok:Click()
eq(m.selections[1].odds, -165, "odds edited")
eq(book.bets[1].odds, -150, "existing bet keeps its odds")
s = drain()
check(#s == 1 and s[1].payload.market.selections[1].odds == -165, "edit broadcast")

-- settle ----------------------------------------------------------------------------------
rowBtn(1, "Settle"):Click()
check(W.prompt:IsShown() and find(W.prompt.btn, "PHI won") and find(W.prompt.btn, "DAL won") and find(W.prompt.btn, "Push") and find(W.prompt.btn, "Cancel"), "settle chooser has both sides, push, cancel")
find(W.prompt.btn, "Cancel"):Click()
eq(m.status, "open", "cancel settles nothing")
rowBtn(1, "Settle"):Click()
find(W.prompt.btn, "PHI won"):Click()
eq(m.status, "settled", "market settled")
eq(Bookie.Balance(book, "Bob"), 6666, "Bob won floor(10000*100/150)")
check(rowText(1):find("SETTLED") and rowText(1):find("PHI won"), "row: " .. rowText(1))
s = drain()
local types = {}; for _, x in ipairs(s) do types[#types + 1] = x.type .. ">" .. tostring(x.to) end
eq(table.concat(types, ","), "MARKET>nil,SYNC>Bob", "settle: MARKET broadcast then Bob's SYNC")

-- correct a wrong result, then void ---------------------------------------------------------
rowBtn(1, "Re-settle"):Click()
find(W.prompt.btn, "DAL won"):Click()
eq(Bookie.Balance(book, "Bob"), -10000, "re-settle reverses and reapplies")
drain()
rowBtn(1, "Void"):Click()
check(W.prompt:IsShown() and W.prompt.text:GetText():find("refunded"), "void asks first")
find(W.prompt.btn, "Cancel"):Click()
eq(m.status, "settled", "cancelled void changes nothing")
rowBtn(1, "Void"):Click()
find(W.prompt.btn, "Void market"):Click()
eq(m.status, "void", "market void")
eq(Bookie.Balance(book, "Bob"), 0, "void refunds")
check(rowText(1):find("VOID"), "row shows VOID")

-- Bets tab ----------------------------------------------------------------------------------
W.tabs.bets:Click()
check(rowText(1):find("Filters") and find(UI.rows[1].btn, "Status: all") and find(UI.rows[1].btn, "Bettor: all") and find(UI.rows[1].btn, "Market: all"), "filter bar")
check(rowText(2):find("#1") and rowText(2):find("Bob") and rowText(2):find("1g on PHI %-150") and rowText(2):find("VOID"), "voided bet listed: " .. rowText(2))
check(not find(UI.rows[2].btn, "Void"), "a void bet has no Void button")

local mk2 = assert(ns.BookieNet.AddMarket(book, { sport = "NFL", event = "NYG @ WAS", type = "moneyline",
    closesAt = T + 3600, selections = { { label = "NYG", odds = -150 }, { label = "WAS", odds = 130 } } }))
handlers.BET_PLACE("Bob", { ref = "r9", marketId = mk2.id, selectionId = 2, stake = 5000, odds = 130 }, book.code)
check(rowText(2):find("#2") and rowText(2):find("OPEN") and rowText(3):find("#1"), "new bet appears live, newest first: " .. rowText(2))

local function filterBtn(prefix)
    for _, b in ipairs(UI.rows[1].btn) do if b:IsShown() and b:GetText():find("^" .. prefix) then return b end end
end
filterBtn("Status:"):Click()
check(filterBtn("Status:"):GetText() == "Status: open", "status filter cycles to open")
check(rowText(2):find("#2") and rowText(3) == "", "only the open bet is shown")
for _ = 1, 4 do filterBtn("Status:"):Click() end      -- won, lost, push, void
check(filterBtn("Status:"):GetText() == "Status: void" and rowText(2):find("#1") and rowText(3) == "", "void filter shows only #1")
filterBtn("Status:"):Click()
eq(filterBtn("Status:"):GetText(), "Status: all", "status filter wraps to all")
filterBtn("Bettor:"):Click()
eq(filterBtn("Bettor:"):GetText(), "Bettor: Bob", "bettor filter")
filterBtn("Bettor:"):Click()
eq(filterBtn("Bettor:"):GetText(), "Bettor: all", "bettor filter wraps")
filterBtn("Market:"):Click(); filterBtn("Market:"):Click()
check(filterBtn("Market:"):GetText():find("NYG @ WAS") or filterBtn("Market:"):GetText():find("NYG"), "market filter names the market: " .. filterBtn("Market:"):GetText())
check(rowText(2):find("#2") and rowText(3) == "", "market filter narrows the list")
filterBtn("Market:"):Click()
eq(filterBtn("Market:"):GetText(), "Market: all", "market filter wraps")

drain()
rowBtn(2, "Void"):Click()
check(W.prompt:IsShown() and W.prompt.text:GetText():find("Void bet #2"), "void bet asks first")
find(W.prompt.btn, "Cancel"):Click()
eq(book.bets[2].status, "accepted", "cancel keeps the bet")
rowBtn(2, "Void"):Click()
find(W.prompt.btn, "Void bet"):Click()
eq(book.bets[2].status, "void", "bet voided")
s = drain()
check(#s == 1 and s[1].type == "SYNC" and s[1].to == "Bob", "voiding a bet re-syncs the bettor")
check(rowText(2):find("VOID"), "row shows VOID")

-- Ledger tab --------------------------------------------------------------------------------
handlers.BET_PLACE("Bob", { ref = "r10", marketId = mk2.id, selectionId = 2, stake = 5000, odds = 130 }, book.code)
ns.BookieNet.Settle(book, mk2.id, 1)                   -- WAS loses: Bob owes 50s
eq(Bookie.Balance(book, "Bob"), -5000, "Bob owes 50s")
drain()
W.tabs.ledger:Click()
check(rowText(1):find("Players owe you") and rowText(1):find("50s"), "ledger totals: " .. rowText(1))
check(rowText(2):find("Bob") and rowText(2):find("owes you 50s"), "Bob owes you: " .. rowText(2))

rowBtn(2, "Paid me"):Click()
check(W.prompt:IsShown() and W.prompt.text:GetText():find("Bob paid you"), "payment prompt")
eq(W.prompt.input:GetText(), "50s", "amount prefilled with what Bob owes")
check(W.prompt.input2:IsShown(), "note box shown")
W.prompt.input:SetText("x")
find(W.prompt.btn, "Record"):Click()
check(W.prompt:IsShown() and W.prompt.msg:GetText():find("Enter an amount"), "bad amount keeps the prompt open")
eq(Bookie.Balance(book, "Bob"), -5000, "bad amount records nothing")
W.prompt.input:SetText("20s"); W.prompt.input2:SetText("  gold trade ")
find(W.prompt.btn, "Record"):Click()
eq(Bookie.Balance(book, "Bob"), -3000, "20s recorded")
s = drain()
check(#s == 1 and s[1].type == "BALANCE" and s[1].to == "Bob" and s[1].payload.balance == -3000
      and s[1].payload.note == "Payment received: 20s (gold trade)", "BALANCE with note: " .. tostring(s[1] and s[1].payload.note))
check(rowText(2):find("owes you 30s"), "row updated: " .. rowText(2))
check(chatText():find("Recorded: Bob paid you 20s"), "chat confirms the payment")

rowBtn(2, "I paid"):Click()
check(W.prompt.text:GetText():find("You paid Bob") and W.prompt.input:GetText() == "", "I paid: no prefill when Bob owes you")
W.prompt.input:SetText("10s")
find(W.prompt.btn, "Record"):Click()
eq(Bookie.Balance(book, "Bob"), -4000, "you paid Bob 10s: balance moves toward owing you")
s = drain()
check(s[1] and s[1].payload.note == "Book paid you: 10s", "outgoing note")

rowBtn(2, "History"):Click()
check(rowText(1):find("Payments with Bob") and find(UI.rows[1].btn, "Back"), "history header")
check(rowText(2):find("you paid 10s"), "newest payment first: " .. rowText(2))
check(rowText(3):find("paid you 20s") and rowText(3):find("gold trade"), "older payment with note: " .. rowText(3))
find(UI.rows[1].btn, "Back"):Click()
check(rowText(1):find("Players owe you"), "Back returns to the ledger")
rowBtn(2, "History"):Click()
W.tabs.members:Click(); W.tabs.ledger:Click()
check(rowText(1):find("Players owe you"), "switching tabs leaves the history view")

-- Import tab --------------------------------------------------------------------------------
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
W.tabs.import:Click()
check(W.import:IsShown() and not W.scroll:IsShown(), "import editor shown")
W.import.preview:Click()
check(W.import.msg:GetText():find("Nothing to import"), "empty paste is refused")

local paste = table.concat({
    "# NFL week 12",
    "ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130",
    "SPREAD|NFL|PHI @ DAL|2026-11-26T16:30-05:00|-3.5|PHI:-110|DAL:-110",
    "bad|line|here",
    "ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130",
    "ML|NFL|OLD @ GAME|1970-01-05T00:00Z|OLD:-150|GAME:+130",
}, "\n")
W.import.box:SetText(paste)
W.import.preview:Click()
check(W.scroll:IsShown() and not W.import:IsShown(), "preview replaces the editor")
check(rowText(1):find("2 to import") and rowText(1):find("1 duplicate") and rowText(1):find("2 with errors"), "preview summary: " .. rowText(1))
check(rowText(2):find("OK") and rowText(2):find("PHI @ DAL") and rowText(2):find("PHI %-150 / DAL %+130"), "ML preview row: " .. rowText(2))
check(rowText(3):find("OK") and rowText(3):find("Spread") and rowText(3):find("PHI %-3.5"), "spread preview row: " .. rowText(3))
check(rowText(4):find("ERROR") and rowText(4):find("line 4"), "error row names the line: " .. rowText(4))
check(UI.rows[4].sub:GetText():find("bad||line||here", 1, true), "pipes in an echoed line are doubled for display: " .. UI.rows[4].sub:GetText())
check(rowText(5):find("SKIP") and rowText(5):find("already posted"), "duplicate row: " .. rowText(5))
check(rowText(6):find("ERROR") and rowText(6):find("already passed"), "closed market row: " .. rowText(6))
check(find(UI.rows[1].btn, "Import 2") and find(UI.rows[1].btn, "Back"), "Import and Back buttons")

find(UI.rows[1].btn, "Back"):Click()
check(W.import:IsShown() and W.import.box:GetText() == paste, "Back returns to the editor with the text intact")
W.import.preview:Click()
local before = count(book.markets)
drain(); chatText()
find(UI.rows[1].btn, "Import 2"):Click()
eq(count(book.markets), before + 2, "two markets imported")
s = drain()
local broadcasts = 0
for _, x in ipairs(s) do if x.type == "MARKET" and x.to == nil then broadcasts = broadcasts + 1 end end
eq(broadcasts, 2, "each imported market is broadcast")
check(chatText():find("Imported 2 markets"), "chat reports the import")
eq(W.import.box:GetText(), "", "box cleared after a clean import")
check(W.scroll:IsShown() and rowText(1):find("OPEN"), "lands on the Markets tab: " .. rowText(1))
local newest
for _, mk in pairs(book.markets) do if mk.type == "spread" and mk.event == "PHI @ DAL" then newest = mk end end
check(newest and newest.line == -3.5 and newest.closesAt == 1795728600 and newest.selections[1].label == "PHI", "imported spread market is right")

-- pasting the same text again: everything is a duplicate, nothing left to import
W.tabs.import:Click()
W.import.box:SetText(paste)
W.import.preview:Click()
check(rowText(1):find("0 to import") and rowText(1):find("3 duplicate"), "second paste: " .. rowText(1))
check(not find(UI.rows[1].btn, "Import 0") and find(UI.rows[1].btn, "Back"), "nothing to import: only Back")
find(UI.rows[1].btn, "Back"):Click()

-- a stale preview must not post duplicates: the plan is re-made at confirm time
W.import.box:SetText("ML|NBA|LAL @ BOS|2026-12-01T20:00-05:00|LAL:+110|BOS:-130")
W.import.preview:Click()
check(rowText(1):find("1 to import"), "fresh line previews as importable")
local spec = ns.Import.Parse("ML|NBA|LAL @ BOS|2026-12-01T20:00-05:00|LAL:+110|BOS:-130", T)[1].spec
assert(ns.BookieNet.AddMarket(book, spec))              -- posted by hand while the preview is open
before = count(book.markets); drain(); chatText()
find(UI.rows[1].btn, "Import 1"):Click()
eq(count(book.markets), before, "confirm re-plans: no duplicate posted")
check(chatText():find("Imported 0 markets"), "chat says nothing was imported")

-- a started game reads STARTED with only Settle and Void, even before the sweep catches up ---------------
W.tabs.markets:Click()
local sm = assert(ns.BookieNet.AddMarket(book, { sport = "NFL", event = "Kickoff @ Now", type = "moneyline",
    closesAt = T + 30, selections = { { label = "K", odds = -110 }, { label = "N", odds = -110 } } }))
local function rowFor(event)
    for i = 1, #UI.rows do
        if UI.rows[i]:IsShown() and UI.rows[i].text:GetText():find(event, 1, true) then return i end
    end
end
local ri = rowFor("Kickoff @ Now")
check(ri and rowText(ri):find("OPEN") and not rowText(ri):find("STARTED"), "before the start: OPEN")
check(ri and find(UI.rows[ri].btn, "Odds") and find(UI.rows[ri].btn, "Lock"), "...with Odds and Lock")
check(ri and rowSub(ri):find("closes"), "...and a closing time")
T = T + 30                                   -- exactly the game's start; the sweep has not run
UI.Refresh()
ri = rowFor("Kickoff @ Now")
eq(sm.status, "open", "the stored status has not caught up")
check(ri and rowText(ri):find("STARTED") and not rowText(ri):find("OPEN"), "at closesAt: STARTED, not OPEN: " .. tostring(ri and rowText(ri)))
check(ri and rowSub(ri):find("started"), "the sub line says started")
check(ri and find(UI.rows[ri].btn, "Settle") and find(UI.rows[ri].btn, "Void"), "Settle and Void remain")
check(ri and not find(UI.rows[ri].btn, "Odds") and not find(UI.rows[ri].btn, "Lock") and not find(UI.rows[ri].btn, "Unlock"),
      "no Odds, Lock or Unlock once the game has started")
check(select(2, ns.BookieNet.EditMarket(book, sm.id, { closesAt = T + 9999 })) == "market_closed", "extending a started game is refused")
check(select(2, ns.BookieNet.UnlockMarket(book, sm.id)) == "market_closed", "reopening a started game is refused")

-- a book owned by another character is never shown or listed ---------------------------------------
local theirs = assert(Model.CreateBook(SteveBookDB, "Theirs", "Other", T))   -- also becomes db.activeBook
UI.Refresh()
check(W.book:GetText():find(book.code, 1, true) and not W.book:GetText():find("Theirs"),
      "header shows my book, not another character's: " .. W.book:GetText())
W.book:Click()
check(not W.book:GetText():find("Theirs"), "cycling skips another character's book: " .. W.book:GetText())
eq(Model.ActiveBook(SteveBookDB), book, "cycling never activates another character's book")
Model.PickBook(SteveBookDB, book.code)
UI.Refresh()

-- book picker, remove, hide/toggle -----------------------------------------------------------
W.new:Click()
W.prompt.input:SetText("NBA")
find(W.prompt.btn, "Create"):Click()
local book2 = Model.ActiveBook(SteveBookDB)
check(book2 and book2.name == "NBA" and book2 ~= book, "second book created and active")
check(W.book:GetText():find("NBA"), "header follows the active book")
W.book:Click()
eq(Model.ActiveBook(SteveBookDB), book, "book button cycles back")
W.tabs.members:Click()
local name
for i = 1, 5 do if rowText(i):find("Bob") then name = i end end
check(name, "Bob listed")
rowBtn(name, "Remove"):Click()
eq(book.members.Bob.status, "removed", "member removed")
s = drain()
local denied = false
for _, x in ipairs(s) do if x.type == "JOIN_DENY" and x.to == "Bob" and x.payload.reason == "removed" and x.payload.ownerName == "Steve" then denied = true end end
check(denied, "removal notified")

check(W.tabs.members:IsEnabled() == false and W.tabs.markets:IsEnabled() == true, "current tab's button is disabled")
check(W.frame:IsShown(), "window is open")
UI.Hide()
check(not W.frame:IsShown(), "Hide closes the window")
UI.Toggle()
check(W.frame:IsShown(), "Toggle opens it")
UI.Toggle()
check(not W.frame:IsShown(), "Toggle closes it")

if fails == 0 then realprint("bookie_ui: all tests passed") else os.exit(1) end
