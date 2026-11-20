-- Smoke test for SteveBook/UI/Bookie.lua with a stubbed WoW API. It drives the real widgets
-- (via UI.widgets / UI.rows / UI.mrows) through the whole bookie flow, checks what the window shows
-- and what goes out over Comm. It cannot check that real frame templates exist: do that in game (README).
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
-- like the game, SetText also fires OnTextChanged (userInput = false)
function Frame.SetText(self, t)
    rawset(self, "_text", t)
    local f = script(self, "OnTextChanged"); if f then f(self, false) end
end
function Frame.GetText(self) return rawget(self, "_text") or "" end
function Frame.SetScript(self, name, fn) local s = rawget(self, "_scripts"); if not s then s = {}; rawset(self, "_scripts", s) end; s[name] = fn end
function Frame.GetWidth(self) return rawget(self, "_w") or 600 end
function Frame.SetWidth(self, w) rawset(self, "_w", w) end
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
-- edit box focus: ClearFocus fires OnEditFocusLost only if the box had focus, like the game
function Frame.SetFocus(self)
    if rawget(self, "_focus") then return end
    rawset(self, "_focus", true)
    local f = script(self, "OnEditFocusGained"); if f then f(self) end
end
function Frame.HasFocus(self) return rawget(self, "_focus") == true end
function Frame.ClearFocus(self)
    if rawget(self, "_focus") then
        rawset(self, "_focus", false)
        local f = script(self, "OnEditFocusLost"); if f then f(self) end
    end
end
function Frame.Enter(self) local f = script(self, "OnEnterPressed"); assert(f, "no OnEnterPressed"); f(self) end
function Frame.Escape(self) local f = script(self, "OnEscapePressed"); assert(f, "no OnEscapePressed"); f(self) end
local function newFrame() return setmetatable({}, Frame) end

-- like the game, a named frame becomes a global (UISpecialFrames only takes global names)
function CreateFrame(_, name)
    local f = newFrame()
    if name then _G[name] = f end
    return f
end
UISpecialFrames = {}
tinsert = table.insert
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
-- generic list rows (Bets, Members, Ledger, import preview, empty-state messages)
local function rowBtn(i, text)
    local r = UI.rows[i]
    local b = r and find(r.btn, text)
    check(b, ("row %d has a visible [%s] button"):format(i, text))
    return b
end
local function rowText(i) return UI.rows[i] and UI.rows[i]:IsShown() and UI.rows[i].text:GetText() or "" end
local function rowSub(i) return UI.rows[i] and UI.rows[i].sub:GetText() or "" end
-- Markets table rows
local function mrowFor(event, market)
    for _, r in ipairs(UI.mrows) do
        if r:IsShown() and r.game:GetText() == event and (not market or r.mkt:GetText():find(market, 1, true)) then return r end
    end
end
local function mbtn(r, text)
    local b = r and find(r.btn, text)
    check(b, ("market row %s has a visible [%s] button"):format(r and r.game:GetText() or "?", text))
    return b
end
local function mlabels(r)
    local t = {}
    for _, b in ipairs(r.btn) do if b:IsShown() then t[#t + 1] = b:GetText() end end
    return table.concat(t, ",")
end
local function shownMRows() local n = 0; for _, r in ipairs(UI.mrows) do if r:IsShown() then n = n + 1 end end; return n end

-- open the window: no book yet -> create-book prompt ------------------------------------------
UI.Show()
do
    local special = {}
    for _, n in ipairs(UISpecialFrames) do special[n] = true end
    check(special.SteveBookBookieFrame and _G.SteveBookBookieFrame == W.frame, "the window is a named global registered for Escape (UISpecialFrames)")
end
check(W.prompt:IsShown() and not W.scroll:IsShown(), "no book: prompt shown")
check(not W.panel:IsShown() and not W.head:IsShown(), "no book: no import panel or table heading")
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
check(W.title:GetText():find("NFL Week 12", 1, true), "window title names the book: " .. W.title:GetText())
check(chatText():find("Share the join code"), "chat tells the bookie to share the code")
check(rowText(1):find("No markets yet"), "empty markets message")
check(W.panel:IsShown() and W.head:IsShown() and W.newMarket:IsShown() and W.lockAll:IsShown(), "Markets tab: import panel, column headings and toolbar")
eq(W.tabs.markets:GetText(), "Markets", "no live markets: plain tab label")

-- a join request arrives while the window is open ------------------------------------------
W.tabs.members:Click()
check(not W.panel:IsShown() and not W.head:IsShown() and not W.newMarket:IsShown(), "Members tab: no panel, headings or toolbar")
check(rowText(1):find("Nobody yet"), "members tab empty")
handlers.JOIN_REQ("Bob", {}, book.code)
check(rowText(1):find("Bob") and rowText(1):find("wants to join"), "pending request listed live")
eq(W.tabs.members:GetText(), "Members (1 pending)", "pending count on the tab")
drain(); chatText()
rowBtn(1, "Approve"):Click()
local s = drain()
check(#s == 1 and s[1].type == "JOIN_OK" and s[1].to == "Bob", "Approve sends JOIN_OK")
check(rowText(1):find("Bob") and rowText(1):find("limit none"), "Bob is now active")
eq(W.tabs.members:GetText(), "Members", "pending count cleared")

rowBtn(1, "Limit"):Click()
check(W.prompt:IsShown() and W.prompt.input:IsShown(), "limit prompt open")
check(not W.panel:IsShown(), "a prompt replaces the whole content area")
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
check(W.form:IsShown() and not W.scroll:IsShown() and not W.panel:IsShown(), "form shown, replacing the table and the panel")
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
check(W.scroll:IsShown() and not W.form:IsShown() and W.panel:IsShown(), "back to the table with the import panel")
s = drain()
check(#s == 1 and s[1].type == "MARKET" and s[1].to == nil, "new market broadcast")
eq(W.tabs.markets:GetText(), "Markets (1)", "live market count on the tab")

-- the table row ----------------------------------------------------------------------------
local r1 = mrowFor("PHI @ DAL")
check(r1, "a table row for the new market")
eq(r1 and r1.mkt:GetText(), "Spread PHI -3.5", "Market column")
eq(r1 and r1.o1:GetText(), "-150", "first odds box")
eq(r1 and r1.o2:GetText(), "+130", "second odds box")
check(r1 and r1.o1:IsShown() and r1.o2:IsShown() and not r1.result:IsShown(), "an open market has editable odds boxes")
check(r1 and r1.status:GetText():find("Open"), "Status column: " .. tostring(r1 and r1.status:GetText()))
check(r1 and r1.closes:GetText():find("%d+:%d%d [AP]M"), "Closes column is a clock time: " .. tostring(r1 and r1.closes:GetText()))
check(r1 and r1.risk:GetText():find("0c"), "At risk starts at 0c: " .. tostring(r1 and r1.risk:GetText()))
eq(r1 and mlabels(r1), "Lock,Settle,Edit", "an open market's actions")
check(W.openStakes:GetText():find("Open stakes: |cffffd1000c"), "open stakes total: " .. W.openStakes:GetText())

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

-- a bet arrives: At risk shows the stake; lock/unlock ----------------------------------------
handlers.BET_PLACE("Bob", { ref = "r1", marketId = 1, selectionId = 1, stake = 10000, odds = -150 }, book.code)
r1 = mrowFor("PHI @ DAL")
eq(r1.risk:GetText(), "1g", "At risk shows the stake live")
check(W.openStakes:GetText():find("Open stakes: |cffffd1001g"), "open stakes total follows: " .. W.openStakes:GetText())
drain()
mbtn(r1, "Lock"):Click()
s = drain()
check(#s == 1 and s[1].payload.market.status == "locked", "Lock broadcasts")
r1 = mrowFor("PHI @ DAL")
check(r1.status:GetText():find("Locked"), "row shows Locked")
eq(mlabels(r1), "Unlock,Settle,Edit", "a locked market's actions")
mbtn(r1, "Unlock"):Click()
check(mrowFor("PHI @ DAL").status:GetText():find("Open"), "Unlock reopens")
drain()

-- inline odds editing ------------------------------------------------------------------------
r1 = mrowFor("PHI @ DAL")
r1.o1:SetFocus(); r1.o1:SetText("-165"); r1.o1:Enter()
eq(m.selections[1].odds, -165, "Enter in an odds box saves the new odds")
eq(m.selections[2].odds, 130, "the other side is untouched")
eq(book.bets[1].odds, -150, "an existing bet keeps its odds")
s = drain()
check(#s == 1 and s[1].type == "MARKET" and s[1].payload.market.selections[1].odds == -165, "the edit is broadcast")
eq(r1.o1:GetText(), "-165", "the box shows the saved odds")

r1.o2:SetFocus(); r1.o2:SetText("125"); r1.o2:ClearFocus()                 -- clicking away also saves; "125" means +125
eq(m.selections[2].odds, 125, "losing focus saves too")
eq(r1.o2:GetText(), "+125", "the box is re-shown in canonical form")
drain()

r1.o1:SetFocus(); r1.o1:SetText("-165"); r1.o1:Enter()
eq(#drain(), 0, "re-entering the same odds broadcasts nothing")

r1.o1:SetFocus(); r1.o1:SetText("abc"); r1.o1:Enter()
eq(m.selections[1].odds, -165, "garbage odds change nothing")
check(chatText():find("Odds look like"), "garbage odds are explained in chat")
eq(r1.o1:GetText(), "-165", "the box goes back to the real odds")
r1.o1:SetFocus(); r1.o1:SetText("50"); r1.o1:Enter()
eq(m.selections[1].odds, -165, "odds between -99 and +99 are refused")
chatText()
eq(#drain(), 0, "refused odds broadcast nothing")

r1.o1:SetFocus(); r1.o1:SetText("-999"); r1.o1:Escape()
eq(m.selections[1].odds, -165, "Escape abandons the edit")
eq(r1.o1:GetText(), "-165", "...and restores the box")

-- a box being typed in is not overwritten by a refresh
r1.o1:SetFocus(); r1.o1:SetText("-17")
handlers.JOIN_REQ("Zed", {}, book.code)                 -- any change redraws the table
eq(r1.o1:GetText(), "-17", "a live refresh leaves a box with focus alone")
r1.o1:SetText("-165"); r1.o1:ClearFocus()
eq(#drain(), 0, "(nothing sent for the abandoned typing)")
Bookie.Deny(book, "Zed")
UI.Refresh()

-- ...and a refresh that re-sorts the table cannot send a half-typed edit to a different market
do
    local early = assert(ns.BookieNet.AddMarket(book, { sport = "NFL", event = "Early @ Bird", type = "moneyline",
        closesAt = T + 600, selections = { { label = "E", odds = -120 }, { label = "B", odds = 100 } } }))
    drain()
    local rEarly = mrowFor("Early @ Bird")
    local idx
    for i, r in ipairs(UI.mrows) do if r == rEarly then idx = i end end
    eq(idx, 1, "setup: the earliest-closing market is the first row")
    local phiBefore = m.selections[1].odds
    rEarly.o1:SetFocus(); rEarly.o1:SetText("-777")          -- typing in Early @ Bird's first box...
    ns.BookieNet.Settle(book, early.id, 1)                   -- ...when it settles and drops to the finished section
    check(mrowFor("Early @ Bird").status:GetText():find("Settled"), "setup: the settled market moved down")
    check(UI.mrows[1].game:GetText() ~= "Early @ Bird", "setup: row 1 now shows a different market (" .. UI.mrows[1].game:GetText() .. ")")
    local other = UI.mrows[1]
    check(not other.o1:HasFocus(), "the focus was dropped when the row was rebound")
    check(other.o1:GetText():find("^[+-]%d+$") and other.o1:GetText() ~= "-777", "the box shows that market's real odds, not the typed text: " .. other.o1:GetText())
    pcall(function() other.o1:Enter() end)                   -- a stray Enter changes nothing
    eq(early.selections[1].odds, -120, "the abandoned edit was not applied to the old market")
    eq(m.selections[1].odds, phiBefore, "...nor to the market now in that row")
    for _, mk in pairs(book.markets) do
        if mk.event ~= "Early @ Bird" then check(mk.selections[1].odds ~= -777, "no market got the half-typed odds: " .. mk.event) end
    end
    drain(); chatText()

    -- belt and braces: even if the client only reports the focus loss after the row was rebound,
    -- the commit still goes nowhere (the edit started in a different market)
    local bystander = assert(ns.BookieNet.AddMarket(book, { sport = "NFL", event = "By @ Stander", type = "moneyline",
        closesAt = T + 900, selections = { { label = "Y", odds = -105 }, { label = "Z", odds = -115 } } }))
    local row2 = mrowFor("PHI @ DAL")
    row2.o1:SetFocus()
    local was = row2.mid
    row2.mid = bystander.id                                  -- the row now "belongs" to another live market
    row2.o1:SetText("-777"); row2.o1:Enter()
    for _, mk in pairs(book.markets) do check(mk.selections[1].odds ~= -777, "a late focus loss edited the wrong market: " .. mk.event) end
    row2.mid = was
    UI.Refresh()
    drain(); chatText()
end

-- the edit form still handles line and close time -----------------------------------------------
mbtn(mrowFor("PHI @ DAL"), "Edit"):Click()
check(W.form:IsShown() and F.odds1:GetText() == "-165" and F.line:GetText() == "-3.5", "edit form prefilled")
W.form.ok:Click()
check(W.form.msg:GetText():find("Nothing to change"), "unchanged edit refused")
F.line:SetText("-4")
W.form.ok:Click()
eq(m.line, -4, "line edited through the form")
eq(mrowFor("PHI @ DAL").mkt:GetText(), "Spread PHI -4", "the Market column follows")
drain()
mbtn(mrowFor("PHI @ DAL"), "Edit"):Click()
F.line:SetText("-3.5")
W.form.ok:Click()
drain()

-- hovering: tooltips are optional (no GameTooltip here), but the scripts must not error --------------
do
    local r = mrowFor("PHI @ DAL")
    local ok = pcall(function()
        for _, w in ipairs({ r.o1, r.o2, r.riskHit }) do local f = w._scripts and w._scripts.OnEnter; if f then f(w) end end
    end)
    check(ok, "hover scripts run without a tooltip")
    GameTooltip = setmetatable({ lines = {} }, { __index = function(t, k)
        return function(self, ...) if k == "SetText" or k == "AddLine" then t.lines[#t.lines + 1] = (...) end; return self end
    end })
    for _, w in ipairs({ r.o1, r.riskHit }) do w._scripts.OnEnter(w); w._scripts.OnLeave(w) end
    local joinedLines = table.concat(GameTooltip.lines, "|")
    check(joinedLines:find("PHI odds", 1, true), "odds box tooltip names the side: " .. joinedLines)
    check(joinedLines:find("Book result if", 1, true) and joinedLines:find("PHI wins", 1, true), "At risk tooltip shows the book's result per outcome: " .. joinedLines)
    GameTooltip = nil
end

-- settle ----------------------------------------------------------------------------------
mbtn(mrowFor("PHI @ DAL"), "Settle"):Click()
check(W.prompt:IsShown() and find(W.prompt.btn, "PHI won") and find(W.prompt.btn, "DAL won") and find(W.prompt.btn, "Push")
      and find(W.prompt.btn, "Void") and find(W.prompt.btn, "Cancel"), "settle chooser has both sides, push, void, cancel")
find(W.prompt.btn, "Cancel"):Click()
eq(m.status, "open", "cancel settles nothing")
mbtn(mrowFor("PHI @ DAL"), "Settle"):Click()
find(W.prompt.btn, "PHI won"):Click()
eq(m.status, "settled", "market settled")
eq(Bookie.Balance(book, "Bob"), 6666, "Bob won floor(10000*100/150)")
r1 = mrowFor("PHI @ DAL")
check(r1.status:GetText():find("Settled") and r1.result:IsShown() and r1.result:GetText():find("PHI won") and not r1.o1:IsShown(), "row: Settled, PHI won, no odds boxes")
eq(r1.risk:GetText(), "", "a settled market has nothing at risk")
eq(mlabels(r1), "Re-settle", "a settled market's action")
s = drain()
local types = {}; for _, x in ipairs(s) do types[#types + 1] = x.type .. ">" .. tostring(x.to) end
eq(table.concat(types, ","), "MARKET>nil,SYNC>Bob", "settle: MARKET broadcast then Bob's SYNC")

-- correct a wrong result, then void ---------------------------------------------------------
mbtn(mrowFor("PHI @ DAL"), "Re-settle"):Click()
find(W.prompt.btn, "DAL won"):Click()
eq(Bookie.Balance(book, "Bob"), -10000, "re-settle reverses and reapplies")
drain()
mbtn(mrowFor("PHI @ DAL"), "Re-settle"):Click()
find(W.prompt.btn, "Void"):Click()
check(W.prompt:IsShown() and W.prompt.text:GetText():find("refunded"), "void asks first")
find(W.prompt.btn, "Cancel"):Click()
eq(m.status, "settled", "cancelled void changes nothing")
mbtn(mrowFor("PHI @ DAL"), "Re-settle"):Click()
find(W.prompt.btn, "Void"):Click()
find(W.prompt.btn, "Void market"):Click()
eq(m.status, "void", "market void")
eq(Bookie.Balance(book, "Bob"), 0, "void refunds")
r1 = mrowFor("PHI @ DAL")
check(r1.status:GetText():find("Void") and r1.result:GetText():find("refunded"), "row shows Void")
eq(mlabels(r1), "Settle", "a void market can still be settled")

-- Bets tab ----------------------------------------------------------------------------------
W.tabs.bets:Click()
check(rowText(1):find("Filters") and find(UI.rows[1].btn, "Status: all") and find(UI.rows[1].btn, "Bettor: all") and find(UI.rows[1].btn, "Market: all"), "filter bar")
check(rowText(2):find("#1") and rowText(2):find("Bob") and rowText(2):find("1g on PHI %-3.5 %-150") and rowText(2):find("VOID"), "voided bet listed with its pick and line: " .. rowText(2))
check(not find(UI.rows[2].btn, "Void"), "a void bet has no Void button")
eq(W.tabs.bets:GetText(), "Bets", "no open bets: plain tab label")

local mk2 = assert(ns.BookieNet.AddMarket(book, { sport = "NFL", event = "NYG @ WAS", type = "moneyline",
    closesAt = T + 3600, selections = { { label = "NYG", odds = -150 }, { label = "WAS", odds = 130 } } }))
handlers.BET_PLACE("Bob", { ref = "r9", marketId = mk2.id, selectionId = 2, stake = 5000, odds = 130 }, book.code)
check(rowText(2):find("#2") and rowText(2):find("OPEN") and rowText(3):find("#1"), "new bet appears live, newest first: " .. rowText(2))
check(rowText(2):find("50s on WAS ML %+130"), "a moneyline pick reads 'WAS ML': " .. rowText(2))
eq(W.tabs.bets:GetText(), "Bets (1)", "open bet count on the tab")

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

-- parlays in the Bets tab ---------------------------------------------------------------------
do
    local function addMl(event, o1, o2, l1, l2)
        return assert(ns.BookieNet.AddMarket(book, { sport = "NBA", event = event, type = "moneyline", closesAt = T + 7200,
            selections = { { label = l1 or "HOM", odds = o1 }, { label = l2 or "AWY", odds = o2 } } }))
    end
    local pa, pb = addMl("LAL @ BOS", 150, -170, "LAL", "BOS"), addMl("DEN @ PHX", -200, 170, "DEN", "PHX")
    local ptot = assert(ns.BookieNet.AddMarket(book, { sport = "NBA", event = "LAL @ BOS", type = "total", line = 231.5,
        closesAt = pa.closesAt, selections = { { label = "Over", odds = -110 }, { label = "Under", odds = -110 } } }))
    local function leg(mk, sel) return { marketId = mk.id, selectionId = sel, odds = mk.selections[sel].odds } end
    drain(); chatText()
    handlers.BET_PLACE("Bob", { ref = "pp1", stake = 2000, legs = { leg(pa, 1), leg(pb, 1), leg(ptot, 1) } }, book.code)
    s = drain()
    check(#s == 1 and s[1].type == "BET_ACK" and s[1].payload.bet.legs, "the parlay was accepted")
    check(chatText():find("Bob bet 20s on a 3%-leg parlay"), "chat announces it")
    local pbet = s[1].payload.bet

    W.tabs.bets:Click()
    local row
    for i = 1, 6 do if rowText(i):find("parlay") then row = i end end
    check(row, "the parlay is listed")
    check(rowText(row):find("#" .. pbet.id) and rowText(row):find("Bob") and rowText(row):find("20s on a 3%-leg parlay") and rowText(row):find("OPEN"),
          "parlay headline: " .. rowText(row))
    local sub = rowSub(row)
    check(sub:find("1%. LAL @ BOS: LAL ML %(%+150%)") and sub:find("pending"), "leg 1 with its pick, odds and status: " .. sub)
    check(sub:find("2%. DEN @ PHX: DEN ML %(%-200%)"), "leg 2")
    check(sub:find("3%. LAL @ BOS: Over 231.5 %(%-110%)"), "leg 3 (a total)")
    eq(select(2, sub:gsub("\n", "")), 2, "one line per leg")
    check(UI.rows[row].btn[1]:IsShown() and UI.rows[row].btn[1]:GetText() == "Void", "a Void button")
    eq(W.tabs.bets:GetText(), "Bets (1)", "the tab counts the parlay as one open bet (bet #2 was voided)")
    W.tabs.markets:Click()
    check(W.openStakes:GetText():find("Open stakes: |cffffd10020s|r") and W.openStakes:GetText():find("20s in parlays"),
          "open stakes include the parlay and say so: " .. W.openStakes:GetText())
    W.tabs.bets:Click()

    -- one leg wins: the Bets tab shows the leg result, the parlay stays open
    ns.BookieNet.Settle(book, pa.id, 1)
    for i = 1, 6 do if rowText(i):find("parlay") then row = i end end
    check(rowText(row):find("OPEN") and rowSub(row):find("1%. LAL @ BOS: LAL ML %(%+150%)  won"), "leg 1 won, parlay still open: " .. rowSub(row))
    -- a leg loses: the parlay is lost at once
    ns.BookieNet.Settle(book, pb.id, 2)
    for i = 1, 6 do if rowText(i):find("parlay") then row = i end end
    check(rowText(row):find("LOST 20s"), "a lost leg loses the parlay: " .. rowText(row))
    check(rowSub(row):find("lost") and rowSub(row):find("pending"), "legs show won / lost / pending: " .. rowSub(row))

    -- the Market filter reaches parlays through their legs
    local filterB = filterBtn("Market:")
    for _ = 1, 10 do
        if filterB:GetText():find("DEN @ PHX", 1, true) then break end
        filterB:Click(); filterB = filterBtn("Market:")
    end
    check(filterB:GetText():find("DEN @ PHX", 1, true), "market filter can pick a parlay's leg market: " .. filterB:GetText())
    local seen = false
    for i = 2, 6 do if rowText(i):find("parlay") then seen = true end end
    check(seen, "...and lists the parlay")
    for _ = 1, 10 do
        if filterBtn("Market:"):GetText() == "Market: all" then break end
        filterBtn("Market:"):Click()
    end

    -- voiding a parlay asks about the whole parlay
    for i = 1, 6 do if rowText(i):find("parlay") then row = i end end
    drain()
    rowBtn(row, "Void"):Click()
    check(W.prompt:IsShown() and W.prompt.text:GetText():find("20s parlay"), "void asks about the parlay: " .. W.prompt.text:GetText())
    find(W.prompt.btn, "Void bet"):Click()
    eq(book.bets[pbet.id].status, "void", "parlay voided")
    check(book.bets[pbet.id].voided, "...stickily")
    eq(Bookie.Balance(book, "Bob"), 0, "the parlay's loss was reversed with the void")
    drain()
end

-- Ledger tab --------------------------------------------------------------------------------
handlers.BET_PLACE("Bob", { ref = "r10", marketId = mk2.id, selectionId = 2, stake = 5000, odds = 130 }, book.code)
ns.BookieNet.Settle(book, mk2.id, 1)                   -- WAS loses: Bob owes 50s (everything else is void)
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

-- Import panel ------------------------------------------------------------------------------
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local P = W.panel
local function sumText() local t = {}; for i = 1, 5 do t[i] = P.sum[i]:GetText() end; return table.concat(t, "\n") end

W.tabs.markets:Click()
check(P:IsShown(), "the panel sits beside the Markets table")
check(P.sum[1]:GetText():find("Nothing pasted yet"), "empty box: " .. P.sum[1]:GetText())
check(not P.go:IsEnabled() and P.go:GetText() == "Import", "nothing to import: the button is disabled")

local paste = table.concat({
    "# NFL week 12",
    "ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130",
    "SPREAD|NFL|PHI @ DAL|2026-11-26T16:30-05:00|-3.5|PHI:-110|DAL:-110",
    "bad|line|here",
    "ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130",
    "ML|NFL|OLD @ GAME|1970-01-05T00:00Z|OLD:-150|GAME:+130",
}, "\n")
local marketsBefore = count(book.markets)
P.box:SetText(paste)                                      -- the summary is live: no Preview button
local sum = sumText()
check(sum:find("2 new") and sum:find("0 updated") and sum:find("1 skipped|r: already started") and sum:find("1 skipped|r: duplicate") and sum:find("1 error"),
      "live summary counts new / updated / started / duplicate / errors: " .. sum:gsub("\n", " / "))
check(P.go:IsEnabled() and P.go:GetText() == "Import 2", "Import 2 is enabled")
eq(count(book.markets), marketsBefore, "typing in the box imports nothing")

-- the Import tab lists what would happen to each line
W.tabs.import:Click()
check(P:IsShown() and not W.head:IsShown(), "Import tab: the panel stays, the table heading goes")
check(rowText(1):find("NEW") and rowText(1):find("PHI @ DAL") and rowText(1):find("PHI %-150 / DAL %+130"), "ML preview row: " .. rowText(1))
check(rowText(2):find("NEW") and rowText(2):find("Spread") and rowText(2):find("PHI %-3.5"), "spread preview row: " .. rowText(2))
check(rowText(3):find("ERROR") and rowText(3):find("line 4"), "error row names the line: " .. rowText(3))
check(UI.rows[3].sub:GetText():find("bad||line||here", 1, true), "pipes in an echoed line are doubled for display: " .. UI.rows[3].sub:GetText())
check(rowText(4):find("SKIP") and rowText(4):find("already posted"), "duplicate row: " .. rowText(4))
check(rowText(5):find("SKIP") and rowText(5):find("already started"), "started row is a skip, not an error: " .. rowText(5))
eq(rowText(6), "", "five lines, five rows")

-- clearing, and an empty import tab says how to start
P.clear:Click()
eq(P.box:GetText(), "", "Clear empties the box")
check(P.sum[1]:GetText():find("Nothing pasted yet") and not P.go:IsEnabled(), "...and the summary")
check(rowText(1):find("Paste lines into the Import box"), "the Import tab explains itself: " .. rowText(1))
P.box:SetText(paste)

drain(); chatText()
local before = count(book.markets)
P.go:Click()
eq(count(book.markets), before + 2, "two markets imported")
s = drain()
local broadcasts = 0
for _, x in ipairs(s) do if x.type == "MARKET" and x.to == nil then broadcasts = broadcasts + 1 end end
eq(broadcasts, 2, "each imported market is broadcast")
check(chatText():find("Imported 2 new markets"), "chat reports the import")
eq(P.box:GetText(), paste, "a paste with an error line keeps its text, to fix and retry")
check(W.head:IsShown() and W.newMarket:IsShown(), "after an import the window lands on the Markets tab (table heading is back)")
local newest
for _, mk in pairs(book.markets) do if mk.type == "spread" and mk.event == "PHI @ DAL" and mk.line == -3.5 and mk.id > 2 then newest = mk end end
check(newest and newest.closesAt == 1795728600 and newest.selections[1].label == "PHI", "imported spread market is right")
check(mrowFor("PHI @ DAL", "Spread PHI -3.5"), "...and it is in the table")

-- the same text again: everything is a duplicate now, nothing left to import
check(sumText():find("0 new") and sumText():find("3 skipped|r: duplicate") and sumText():find("1 skipped|r: already started") and sumText():find("1 error"),
      "second look: three duplicates now, still one started and one error: " .. sumText():gsub("\n", " / "))
check(not P.go:IsEnabled() and P.go:GetText() == "Import 0", "nothing left to import: the button is disabled")
P.clear:Click()

-- UPDATE: the same market with new odds changes the existing market's odds (and counts as "updated")
local ML = function(event, a, b) return ("ML|NBA|%s|2026-12-01T20:00-05:00|%s|%s"):format(event, a, b) end
P.box:SetText(ML("LAL @ BOS", "LAL:+110", "BOS:-130"))
check(sumText():find("1 new"), "fresh line previews as new: " .. sumText():gsub("\n", " / "))
P.go:Click()
local lal
for _, mk in pairs(book.markets) do if mk.event == "LAL @ BOS" and mk.type == "moneyline" and mk.closesAt > T + 100000 then lal = mk end end
check(lal and lal.selections[1].odds == 110, "market posted from the first import")
drain(); chatText()
handlers.BET_PLACE("Bob", { ref = "u1", marketId = lal.id, selectionId = 1, stake = 1000, odds = 110 }, book.code)
drain(); chatText()

P.box:SetText(ML("LAL @ BOS", "LAL:+125", "BOS:-145") .. "\n" .. ML("MIA @ NYK", "MIA:+130", "NYK:-150"))
sum = sumText()
check(sum:find("1 new") and sum:find("1 updated"), "the moved line is an update, the new game new: " .. sum:gsub("\n", " / "))
check(P.go:GetText() == "Import 2", "Import counts updates too")
W.tabs.import:Click()
check(rowText(1):find("UPDATE") and rowText(1):find("LAL %+110 %-> .-%+125") and rowText(1):find("BOS %-130 %-> .-%-145"), "update row shows old -> new: " .. rowText(1))
check(rowText(2):find("NEW") and rowText(2):find("MIA @ NYK"), "new row: " .. rowText(2))
P.go:Click()
eq(lal.selections[1].odds, 125, "the open market's odds were updated")
eq(lal.selections[2].odds, -145, "...both sides")
local luBet
for _, b in pairs(book.bets) do if b.ref == "u1" then luBet = b end end
eq(luBet and luBet.odds, 110, "an existing bet keeps the odds it was accepted at")
s = drain()
local upd, adds = 0, 0
for _, x in ipairs(s) do
    if x.type == "MARKET" and x.payload.market.id == lal.id then upd = upd + 1 end
    if x.type == "MARKET" and x.payload.market.event == "MIA @ NYK" then adds = adds + 1 end
end
check(upd == 1 and adds == 1, "the update and the new market are both broadcast")
check(chatText():find("Imported 1 new market and updated the odds of 1 market"), "chat reports new and updated")
eq(P.box:GetText(), "", "a clean import clears the box")
check(W.head:IsShown(), "back on the Markets tab")
eq(mrowFor("LAL @ BOS", "Moneyline").o1:GetText(), "+125", "the table shows the new odds")

-- a locked market is never touched by an import
Bookie.Lock(book, lal.id)
P.box:SetText(ML("LAL @ BOS", "LAL:+200", "BOS:-250"))
check(sumText():find("1 skipped|r: already started or closed") and sumText():find("0 updated"), "a locked market is skipped: " .. sumText():gsub("\n", " / "))
check(not P.go:IsEnabled(), "nothing to import")
Bookie.Unlock(book, lal.id, T)
P.clear:Click()

-- a moved spread line: the preview shows the line change, the table follows, an existing bet keeps its line
do
    local spread
    for _, mk in pairs(book.markets) do
        if mk.type == "spread" and mk.event == "PHI @ DAL" and mk.closesAt == 1795728600 then spread = mk end
    end
    check(spread and spread.line == -3.5 and spread.status == "open", "setup: the imported PHI @ DAL spread is open at -3.5")
    handlers.BET_PLACE("Bob", { ref = "ln1", marketId = spread.id, selectionId = 1, stake = 1000, odds = -110 }, book.code)
    drain(); chatText()
    P.box:SetText("SPREAD|NFL|PHI @ DAL|2026-11-26T16:30-05:00|-4.5|PHI:-105|DAL:-115")
    local sm2 = sumText()
    check(sm2:find("0 new") and sm2:find("1 updated") and P.go:GetText() == "Import 1", "a moved line counts as an update: " .. sm2:gsub("\n", " / "))
    W.tabs.import:Click()
    check(rowText(1):find("UPDATE") and rowText(1):find("line %-3.5 %-> .-%-4.5") and rowText(1):find("PHI %-110 %-> .-%-105"),
          "the preview shows the line and the odds changing: " .. rowText(1))
    P.go:Click()
    eq(spread.line, -4.5, "the market's line moved")
    eq(spread.selections[1].odds, -105, "...and its odds")
    check(chatText():find("Imported 0 new markets and updated the odds of 1 market"), "chat reports the update")
    s = drain()
    check(#s == 1 and s[1].type == "MARKET" and s[1].payload.market.line == -4.5, "broadcast with the new line")
    eq(mrowFor("PHI @ DAL", "Spread PHI -4.5") ~= nil, true, "the table's Market column shows the new line")
    local bobBet
    for _, b in pairs(book.bets) do if b.ref == "ln1" then bobBet = b end end
    check(bobBet and bobBet.line == -3.5 and bobBet.odds == -110, "the existing bet keeps its line and odds")
    W.tabs.bets:Click()
    local seenLine
    for i = 1, 8 do if rowText(i):find("#" .. bobBet.id, 1, true) then seenLine = rowText(i) end end
    check(seenLine and seenLine:find("PHI %-3.5 %-110"), "the Bets tab shows the line the bet was taken at, not the market's new one: " .. tostring(seenLine))
    W.tabs.markets:Click()
    drain()
end

-- a stale preview must not post duplicates: the plan is re-made at confirm time
P.box:SetText("ML|NBA|GSW @ SAC|2026-12-01T20:00-05:00|GSW:+110|SAC:-130")
check(sumText():find("1 new"), "fresh line previews as importable")
local spec = ns.Import.Parse("ML|NBA|GSW @ SAC|2026-12-01T20:00-05:00|GSW:+110|SAC:-130", T)[1].spec
assert(ns.BookieNet.AddMarket(book, spec))              -- posted by hand while the preview is open
before = count(book.markets); drain(); chatText()
P.go:Click()
eq(count(book.markets), before, "confirm re-plans: no duplicate posted")
check(chatText():find("Imported 0 new markets"), "chat says nothing was imported")
P.clear:Click()

-- Lock all -----------------------------------------------------------------------------------
do
    local open = 0
    for _, mk in pairs(book.markets) do if Bookie.IsBettable(mk, T) then open = open + 1 end end
    check(open >= 3, "setup: several open markets (" .. open .. ")")
    drain(); chatText()
    W.lockAll:Click()
    check(W.prompt:IsShown() and W.prompt.text:GetText():find("Lock all " .. open .. " open markets"), "Lock all asks first: " .. W.prompt.text:GetText())
    find(W.prompt.btn, "Cancel"):Click()
    eq(#drain(), 0, "cancel locks nothing")
    W.lockAll:Click()
    find(W.prompt.btn, "Lock all"):Click()
    local left = 0
    for _, mk in pairs(book.markets) do if Bookie.IsBettable(mk, T) then left = left + 1 end end
    eq(left, 0, "every open market is locked")
    s = drain()
    eq(#s, open, "one MARKET broadcast per locked market")
    check(chatText():find("Locked " .. open .. " markets"), "chat reports the count")
    W.lockAll:Click()
    eq(W.prompt:IsShown(), false, "nothing open: no prompt")
    check(chatText():find("No open markets to lock"), "...just a note in chat")
    for _, mk in pairs(book.markets) do
        if mk.status == "locked" and mk.closesAt > T then ns.BookieNet.UnlockMarket(book, mk.id) end
    end
    drain()
end

-- a started game reads Started with only Settle, even before the sweep catches up ---------------------
W.tabs.markets:Click()
local sm = assert(ns.BookieNet.AddMarket(book, { sport = "NFL", event = "Kickoff @ Now", type = "moneyline",
    closesAt = T + 30, selections = { { label = "K", odds = -110 }, { label = "N", odds = -110 } } }))
local rk = mrowFor("Kickoff @ Now")
check(rk and rk.status:GetText():find("Open") and not rk.status:GetText():find("Started"), "before the start: Open")
check(rk and rk.o1:IsShown() and mlabels(rk) == "Lock,Settle,Edit", "...with odds boxes, Lock and Edit")
check(rk and rk.closes:GetText():find("[AP]M"), "...and a closing time")
T = T + 30                                   -- exactly the game's start; the sweep has not run
UI.Refresh()
rk = mrowFor("Kickoff @ Now")
eq(sm.status, "open", "the stored status has not caught up")
check(rk and rk.status:GetText():find("Started") and not rk.status:GetText():find("Open"), "at closesAt: Started, not Open: " .. tostring(rk and rk.status:GetText()))
check(rk and not rk.o1:IsShown() and not rk.o2:IsShown() and rk.result:IsShown() and rk.result:GetText():find("K %-110 / N %-110"), "no odds boxes once the game is on; the prices are shown as text")
check(rk and rk.closes:GetText():find("began"), "the Closes column says when it began: " .. tostring(rk and rk.closes:GetText()))
eq(rk and mlabels(rk), "Settle", "only Settle remains (no Lock, Unlock, Edit)")
check(select(2, ns.BookieNet.EditMarket(book, sm.id, { closesAt = T + 9999 })) == "market_closed", "extending a started game is refused")
check(select(2, ns.BookieNet.EditMarket(book, sm.id, { odds = { [1] = -120 } })) == "market_closed", "editing a started game's odds is refused")
check(select(2, ns.BookieNet.UnlockMarket(book, sm.id)) == "market_closed", "reopening a started game is refused")
-- live markets (open, locked, started) come first, finished ones after: once a Settled/Void row
-- appears no live row follows it
do
    local seenFinal, liveAfterFinal, finals, lives = false, false, 0, 0
    for _, r in ipairs(UI.mrows) do
        if r:IsShown() then
            local st = r.status:GetText()
            if st:find("Settled") or st:find("Void") then seenFinal = true; finals = finals + 1
            else lives = lives + 1; if seenFinal then liveAfterFinal = true end end
        end
    end
    check(lives >= 3 and finals >= 1, "setup: live and finished markets are both listed (" .. lives .. "/" .. finals .. ")")
    check(not liveAfterFinal, "live markets are listed before finished ones")
end

-- the odds view (/book ratio) never changes the bookie window: typed and shown odds stay American ----------
do
    local O = ns.Odds
    O.SetView("ratio")
    check(O.Format(-110) == "0.91x" and O.FormatAmerican(-110) == "-110", "setup: the ratio view is on (Odds.Format shows 0.91x)")
    local function ratioish(text) return tostring(text):find("%dx") end
    local function scanTable()
        local bad
        for _, r in ipairs(UI.mrows) do
            if r:IsShown() then
                for _, f in ipairs({ "game", "mkt", "o1", "o2", "result", "closes", "status", "risk" }) do
                    if ratioish(r[f]:GetText()) then bad = bad or (f .. ": " .. r[f]:GetText()) end
                end
            end
        end
        return bad
    end
    W.tabs.markets:Click()
    UI.Refresh()
    eq(scanTable(), nil, "the Markets table shows no ratio text")
    local live = 0
    for _, r in ipairs(UI.mrows) do
        if r:IsShown() and r.o1:IsShown() then
            live = live + 1
            check(r.o1:GetText():find("^[+-]%d+$") and r.o2:GetText():find("^[+-]%d+$"), "odds boxes hold American text: " .. r.o1:GetText() .. " / " .. r.o2:GetText())
        end
    end
    check(live >= 2, "setup: several rows with odds boxes (" .. live .. ")")

    -- an unchanged box saved on click-away changes nothing and sends nothing
    local row
    for _, r in ipairs(UI.mrows) do if r:IsShown() and r.o1:IsShown() then row = r; break end end
    local mkt = book.markets[row.mid]
    local o1, o2, rev = mkt.selections[1].odds, mkt.selections[2].odds, book.rev
    local was = row.o1:GetText()
    drain(); chatText()
    row.o1:SetFocus(); row.o1:ClearFocus()
    row.o2:SetFocus(); row.o2:ClearFocus()
    check(mkt.selections[1].odds == o1 and mkt.selections[2].odds == o2, "unchanged boxes saved on click-away leave the market alone")
    eq(book.rev, rev, "...and the book is not touched")
    eq(#drain(), 0, "...and nothing is broadcast")
    eq(chatText(), "", "...and no 'odds look like' complaint (the box text still parses)")
    eq(row.o1:GetText(), was, "the box still reads as before")
    -- a real edit still works in the ratio view
    row.o1:SetFocus(); row.o1:SetText(o1 < 0 and tostring(o1 - 5) or ("+" .. (o1 + 5))); row.o1:Enter()
    eq(mkt.selections[1].odds, o1 < 0 and o1 - 5 or o1 + 5, "typing American odds still saves in the ratio view")
    eq(row.o1:GetText(), O.FormatAmerican(mkt.selections[1].odds), "...and the box shows the new odds in American")
    drain()
    -- Escape abandons a half-typed edit and shows the market's odds in American again
    chatText()
    row.o2:SetFocus(); row.o2:SetText("junk"); row.o2:Escape()
    eq(row.o2:GetText(), O.FormatAmerican(mkt.selections[2].odds), "Escape restores the box in American")
    eq(chatText(), "", "...without an 'odds look like' complaint (the restored text parses)")
    eq(#drain(), 0, "...and nothing sent")

    -- a started game's prices (plain text), the edit form, the Bets tab and the import preview
    local sg = mrowFor("Kickoff @ Now")
    check(sg and sg.result:GetText():find("K %-110 / N %-110"), "a started row shows American prices: " .. tostring(sg and sg.result:GetText()))
    mbtn(row, "Edit"):Click()
    check(W.form.f.odds1:GetText():find("^[+-]%d+$") and W.form.f.odds2:GetText():find("^[+-]%d+$"), "the edit form is prefilled in American: " .. W.form.f.odds1:GetText())
    W.form.cancel:Click()
    W.tabs.bets:Click()
    local sawBet, sawLeg = false, false
    for i = 1, 20 do
        local t, sub = rowText(i), rowSub(i)
        check(not ratioish(t) and not ratioish(sub), "Bets tab row " .. i .. " shows no ratio text: " .. t .. " " .. sub)
        if t:find("on a %d%-leg parlay [+-]%d+") then sawLeg = true end
        if t:find("on .- [+-]%d+  %(") then sawBet = true end
    end
    check(sawBet and sawLeg, "the Bets tab lists a single and a parlay with American odds (" .. tostring(sawBet) .. "/" .. tostring(sawLeg) .. ")")
    W.tabs.markets:Click()
    local lalMarket
    for _, mk in pairs(book.markets) do if mk.event == "LAL @ BOS" and mk.type == "moneyline" and mk.closesAt > T + 100000 then lalMarket = mk end end
    check(lalMarket and lalMarket.status == "open", "setup: the imported LAL @ BOS moneyline is open")
    local newOdds1 = lalMarket.selections[1].odds + 10
    P.box:SetText(ML("LAL @ BOS", "LAL:" .. newOdds1, "BOS:" .. lalMarket.selections[2].odds)
        .. "\nML|NBA|RAT @ IO|2026-12-05T20:00-05:00|RAT:-120|IO:+100")
    W.tabs.import:Click()
    check(rowText(1):find("UPDATE") and rowText(1):find("%->") and not ratioish(rowText(1)), "the import preview's old -> new odds are American: " .. rowText(1))
    check(rowText(1):find(O.FormatAmerican(lalMarket.selections[1].odds), 1, true) and rowText(1):find(O.FormatAmerican(newOdds1), 1, true)
          and rowText(1):find(O.FormatAmerican(lalMarket.selections[2].odds), 1, true), "...old, new and the unchanged side all in American: " .. rowText(1))
    check(rowText(2):find("NEW") and rowText(2):find("RAT %-120") and rowText(2):find("IO %+100") and not ratioish(rowText(2)), "a NEW preview row shows American odds: " .. rowText(2))
    for i = 1, 5 do check(not ratioish(P.sum[i]:GetText()), "import summary line " .. i .. " has no ratio text") end
    P.clear:Click()
    W.tabs.markets:Click()
    O.SetView("american")
end

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
P.box:SetText("ML|NBA|STALE @ TEXT|2026-12-01T20:00-05:00|A:+110|B:-130")
W.new:Click()
W.prompt.input:SetText("NBA")
find(W.prompt.btn, "Create"):Click()
local book2 = Model.ActiveBook(SteveBookDB)
check(book2 and book2.name == "NBA" and book2 ~= book, "second book created and active")
check(W.book:GetText():find("NBA"), "header follows the active book")
check(W.title:GetText():find("NBA", 1, true), "title follows the active book")
check(shownMRows() == 0 and rowText(1):find("No markets yet"), "the new book's table starts empty")
check(sumText():find("1 new"), "(text pasted for the other book still previews until the book is switched)")
W.book:Click()
eq(Model.ActiveBook(SteveBookDB), book, "book button cycles back")
eq(P.box:GetText(), "", "switching books clears pasted lines (they were meant for the other book)")
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
