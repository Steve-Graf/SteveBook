-- UI/Casino.lua: the casino windows (SPEC §11).
--   Launcher  (/casino): the list of games, Host / Join, and your tables.
--   Host window:   the table's code, players and their chips, Admit / chips / Kick, limits, Spin.
--   Table window:  the roulette board for a player: chips, bets, the last result.
-- Only draws and wires: the rules live in ns.Roulette / ns.Casino / ns.CasinoClient and the
-- messages in ns.CasinoNet.
-- Exposes ns.UI.Casino = { Show, Hide, Toggle, OpenHost, OpenTable, Refresh,
--                          SetMode, SetAmount, PickNumber, PickOutside }.
local ADDON, ns = ...
ns.UI = ns.UI or {}

local Casino, Client, CN, Roulette, Odds = ns.Casino, ns.CasinoClient, ns.CasinoNet, ns.Roulette, ns.Odds
local UI = {}
ns.UI.Casino = UI

local GOLD, GREEN, RED, GREY = "|cffffd100", "|cff40ff40", "|cffff5050", "|cff999999"
local CELL_W, CELL_H = 38, 34
local HOST_ROWS, PENDING_ROWS, TABLE_ROWS = 9, 5, 8

local function say(msg) print(GOLD .. "SteveBook Casino:|r " .. msg) end
local function money(c) return Odds.FormatMoney(c) end
local function db() return SteveBookDB end

------------------------------------------------------------------------------------------
-- Widgets (same look as the other windows)
------------------------------------------------------------------------------------------

local function button(parent, text, w, onClick, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function label(parent, template, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

local function editBox(parent, w, text, maxLetters)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 22)
    e:SetAutoFocus(false)
    if maxLetters then e:SetMaxLetters(maxLetters) end
    e:SetScript("OnEscapePressed", e.ClearFocus)
    if text then e:SetText(text) end
    return e
end

local function paint(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a or 1)
    else tex:SetTexture("Interface\\Buttons\\WHITE8X8"); tex:SetVertexColor(r, g, b, a or 1) end
end

local function at(region, parent, x, y, point)
    region:SetPoint(point or "TOPLEFT", parent, point or "TOPLEFT", x, -y)
    return region
end

local function newWindow(name, w, h, title)
    local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
    if UISpecialFrames then table.insert(UISpecialFrames, name) end     -- Escape closes it
    f:SetSize(w, h)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:Hide()
    f.title = label(f, "GameFontNormal", "CENTER")
    f.title:SetPoint("TOP", 0, -5)
    f.title:SetText(title)
    return f
end

local function colored(n)
    local c = Roulette.Color(n)
    local code = c == "red" and RED or (c == "green" and GREEN or "|cffdddddd")
    return code .. Roulette.Label(n) .. "|r"
end

local function historyText(list)
    local parts = {}
    for i, n in ipairs(list or {}) do parts[i] = colored(n) end
    if #parts == 0 then return GREY .. "no spins yet|r" end
    return table.concat(parts, "  ")
end

-- The player's own name as the table knows it.
local function myName(tc) return tc and tc.me or UnitName("player") end

------------------------------------------------------------------------------------------
-- Launcher
------------------------------------------------------------------------------------------

local launcher = {}          -- frame, sections
local mode = "home"          -- "home" | "host" | "join"
local wheel = "single"
local WHEEL_TEXT = {
    single = "Single zero (0). The house keeps 2.7%.",
    double = "Double zero (0 and 00). The house keeps 5.3%.",
    none = "No zero. Fair odds, the house keeps nothing.",
}
local confirmClose

local function setMode(m)
    mode = m
    local L = launcher
    if not L.frame then return end
    L.home:SetShown(m == "home")
    L.hostForm:SetShown(m == "host")
    L.joinForm:SetShown(m == "join")
end

local function tableRows()
    local rows = {}
    local d = db()
    if not d then return rows end
    for _, t in ipairs(Casino.List(d)) do
        if t.hostName == UnitName("player") then
            local seated = #Casino.Seated(t)
            rows[#rows + 1] = { host = true, code = t.code,
                text = ("%sHosting|r %s  %s  %s  %d seated"):format(GOLD, t.name, GREY .. t.code .. "|r",
                    t.status == "closed" and (RED .. "closed|r") or (GREEN .. t.status .. "|r"), seated),
                closed = t.status == "closed" }
        end
    end
    for _, tc in ipairs(d.casinoCache and Client.List(d.casinoCache) or {}) do
        local status = ({ requested = GOLD .. "waiting for the host|r", seated = GREEN .. "seated|r",
            denied = RED .. "turned down|r", left = GREY .. "left|r", removed = RED .. "removed|r",
            closed = GREY .. "closed|r" })[tc.status] or tc.status
        rows[#rows + 1] = { host = false, code = tc.code,
            text = ("%s  %s  %s"):format(tc.name or "Roulette", GREY .. tc.code .. "|r", status) }
    end
    return rows
end

local function buildLauncher()
    local L = launcher
    local f = newWindow("SteveBookCasinoFrame", 520, 470, "SteveBook Casino")
    L.frame = f

    -- home: games and tables
    L.home = CreateFrame("Frame", nil, f)
    L.home:SetPoint("TOPLEFT", 14, -34); L.home:SetPoint("BOTTOMRIGHT", -14, 14)
    local head = label(L.home, "GameFontNormal")
    at(head, L.home, 0, 0); head:SetText("Pick a game")
    L.games = {}
    local y = 24
    for _, id in ipairs(Casino.GAME_ORDER) do
        local g = Casino.GAMES[id]
        local row = { id = id }
        row.name = label(L.home, "GameFontHighlightLarge"); at(row.name, L.home, 0, y); row.name:SetText(g.title)
        row.note = label(L.home, "GameFontHighlightSmall"); at(row.note, L.home, 0, y + 20)
        row.note:SetText(g.ready and (GREY .. "Everyone bets on the same wheel. The host spins.|r") or (GREY .. "Coming soon.|r"))
        row.host = button(L.home, "Host a table", 110, function() setMode("host") end)
        at(row.host, L.home, 270, y - 2)
        row.join = button(L.home, "Join a table", 110, function() setMode("join") end)
        at(row.join, L.home, 388, y - 2)
        if not g.ready then row.host:Disable(); row.join:Disable() end
        L.games[#L.games + 1] = row
        y = y + 46
    end
    local tl = label(L.home, "GameFontNormal"); at(tl, L.home, 0, y + 6); tl:SetText("Your tables")
    L.rows = {}
    for i = 1, 8 do
        local r = {}
        r.text = label(L.home, "GameFontHighlightSmall"); at(r.text, L.home, 0, y + 28 + (i - 1) * 26 + 4)
        r.text:SetWidth(330); r.text:SetWordWrap(false)
        r.open = button(L.home, "Open", 60, function() end, 20); at(r.open, L.home, 340, y + 28 + (i - 1) * 26)
        r.drop = button(L.home, "Remove", 70, function() end, 20); at(r.drop, L.home, 404, y + 28 + (i - 1) * 26)
        L.rows[i] = r
    end
    L.empty = label(L.home, "GameFontHighlightSmall"); at(L.empty, L.home, 0, y + 32)
    L.empty:SetText(GREY .. "No tables yet. Host one, or join a friend's with their code.|r")
    L.sport = button(L.home, "Back to the sportsbook", 170, function()
        f:Hide()
        if ns.UI.Bettor and ns.UI.Bettor.Show then ns.UI.Bettor.Show() end
    end)
    L.sport:SetPoint("BOTTOMLEFT", L.home, "BOTTOMLEFT", 0, 0)

    -- host form
    L.hostForm = CreateFrame("Frame", nil, f)
    L.hostForm:SetPoint("TOPLEFT", 14, -34); L.hostForm:SetPoint("BOTTOMRIGHT", -14, 14)
    local hf = L.hostForm
    local t1 = label(hf, "GameFontNormal"); at(t1, hf, 0, 0); t1:SetText("Host a roulette table")
    local n1 = label(hf, "GameFontHighlight"); at(n1, hf, 0, 34); n1:SetText("Table name")
    L.nameBox = editBox(hf, 240, "", 40); at(L.nameBox, hf, 130, 30)
    local n2 = label(hf, "GameFontHighlight"); at(n2, hf, 0, 70); n2:SetText("Wheel")
    L.wheelBtn = button(hf, "Single zero", 140, function()
        wheel = wheel == "single" and "double" or (wheel == "double" and "none" or "single")
        L.wheelBtn:SetText(({ single = "Single zero", double = "Double zero", none = "No zero" })[wheel])
        L.wheelNote:SetText(GREY .. WHEEL_TEXT[wheel] .. "|r")
    end)
    at(L.wheelBtn, hf, 130, 66)
    L.wheelNote = label(hf, "GameFontHighlightSmall"); at(L.wheelNote, hf, 280, 72); L.wheelNote:SetText(GREY .. WHEEL_TEXT.single .. "|r")
    L.wheelNote:SetWidth(210); L.wheelNote:SetWordWrap(true)
    local n3 = label(hf, "GameFontHighlight"); at(n3, hf, 0, 110); n3:SetText("Smallest bet")
    L.minBox = editBox(hf, 80, money(Casino.DEFAULT_MIN_BET), 12); at(L.minBox, hf, 130, 106)
    local n4 = label(hf, "GameFontHighlight"); at(n4, hf, 240, 110); n4:SetText("Largest bet")
    L.maxBox = editBox(hf, 80, money(Casino.DEFAULT_MAX_BET), 12); at(L.maxBox, hf, 330, 106)
    local note = label(hf, "GameFontHighlightSmall"); at(note, hf, 0, 150)
    note:SetWidth(470); note:SetWordWrap(true)
    note:SetText(GREY .. "Players get no chips until you give them some. Let someone in, then add chips for what they pay you. Chips are only a record: gold changes hands by trade, outside the addon.|r")
    L.create = button(hf, "Create table", 120, function()
        local lo, hi = Odds.ParseMoney(L.minBox:GetText()), Odds.ParseMoney(L.maxBox:GetText())
        if not (lo and hi) then return say("Enter the bet sizes like 1s or 1g.") end
        local t, err = CN.Create({ game = "roulette", name = L.nameBox:GetText(), zero = wheel, minBet = lo, maxBet = hi })
        if not t then return say(err) end
        say(("Table %s created. Share the code %s%s|r so players can ask for a seat."):format(t.name, GOLD, t.code))
        setMode("home")
        UI.OpenHost(t.code)
        UI.Refresh()
    end)
    at(L.create, hf, 0, 210)
    L.hostBack = button(hf, "Back", 80, function() setMode("home") end); at(L.hostBack, hf, 130, 210)

    -- join form
    L.joinForm = CreateFrame("Frame", nil, f)
    L.joinForm:SetPoint("TOPLEFT", 14, -34); L.joinForm:SetPoint("BOTTOMRIGHT", -14, 14)
    local jf = L.joinForm
    local j1 = label(jf, "GameFontNormal"); at(j1, jf, 0, 0); j1:SetText("Join a table")
    local j2 = label(jf, "GameFontHighlight"); at(j2, jf, 0, 34); j2:SetText("Table code from the host (like RLT-K7Q2)")
    L.codeBox = editBox(jf, 140, "", 12); at(L.codeBox, jf, 0, 58)
    L.request = button(jf, "Ask for a seat", 130, function()
        local tc, err = CN.RequestJoin(L.codeBox:GetText())
        if not tc then return say(err) end
        say("Asked for a seat at " .. tc.code .. ". Waiting for the host to let you in.")
        L.codeBox:SetText("")
        setMode("home")
        UI.OpenTable(tc.code)
        UI.Refresh()
    end)
    at(L.request, jf, 150, 56)
    L.joinBack = button(jf, "Back", 80, function() setMode("home") end); at(L.joinBack, jf, 290, 56)
    local jn = label(jf, "GameFontHighlightSmall"); at(jn, jf, 0, 100); jn:SetWidth(470); jn:SetWordWrap(true)
    jn:SetText(GREY .. "The host decides when to let you in and how many chips you get. You can place bets once you have chips.|r")

    f:SetScript("OnShow", function() UI.Refresh() end)
    setMode("home")
end

local function refreshLauncher()
    local L = launcher
    if not (L.frame and L.frame:IsShown()) then return end
    local rows = tableRows()
    L.empty:SetShown(#rows == 0)
    for i, r in ipairs(L.rows) do
        local row = rows[i]
        r.text:SetShown(row ~= nil); r.open:SetShown(row ~= nil); r.drop:SetShown(row ~= nil)
        if row then
            r.text:SetText(row.text)
            r.open:SetScript("OnClick", function()
                if row.host then UI.OpenHost(row.code) else UI.OpenTable(row.code) end
            end)
            if row.host then
                r.drop:SetText("Delete")
                if row.closed then r.drop:Enable() else r.drop:Disable() end
                r.drop:SetScript("OnClick", function()
                    local t = Casino.Find(db(), row.code)
                    if t then
                        local ok, err = CN.Delete(t)
                        if not ok then say(err) end
                    end
                    UI.Refresh()
                end)
            else
                r.drop:SetText("Remove"); r.drop:Enable()
                r.drop:SetScript("OnClick", function() CN.Forget(row.code); UI.Refresh() end)
            end
        end
    end
end

------------------------------------------------------------------------------------------
-- Host window
------------------------------------------------------------------------------------------

local host = {}
local hostCode

local function hostTable()
    return hostCode and db() and Casino.Find(db(), hostCode)
end

local function chipsAmount()
    local c = Odds.ParseMoney(host.chips:GetText())
    if not c or c <= 0 then say("Enter chips like 10s or 5g."); return nil end
    return c
end

local function buildHost()
    local H = host
    local f = newWindow("SteveBookCasinoHostFrame", 720, 560, "SteveBook Casino: Host")
    H.frame = f
    H.head = label(f, "GameFontNormalLarge"); at(H.head, f, 16, 34)
    H.status = label(f, "GameFontHighlight"); at(H.status, f, 16, 58)
    local cl = label(f, "GameFontHighlightSmall"); at(cl, f, 16, 84); cl:SetText("Table code (share it):")
    H.codeBox = editBox(f, 110, "", 12); at(H.codeBox, f, 140, 80)
    H.codeBox:SetScript("OnChar", function(self) self:SetText(hostCode or "") end)   -- read only: you can still copy it

    local pl = label(f, "GameFontNormal"); at(pl, f, 16, 114); pl:SetText("Players")
    local cb = label(f, "GameFontHighlightSmall"); at(cb, f, 250, 116); cb:SetText("Chips to add or take:")
    H.chips = editBox(f, 80, "10s", 12); at(H.chips, f, 380, 110)

    H.pending = {}
    for i = 1, PENDING_ROWS do
        local r = {}
        r.name = label(f, "GameFontHighlight"); at(r.name, f, 16, 144 + (i - 1) * 26)
        r.admit = button(f, "Let in with chips", 130, function() end, 20); at(r.admit, f, 160, 140 + (i - 1) * 26)
        r.deny = button(f, "Turn down", 80, function() end, 20); at(r.deny, f, 296, 140 + (i - 1) * 26)
        H.pending[i] = r
    end
    local py = 144 + PENDING_ROWS * 26 + 8
    H.rows = {}
    for i = 1, HOST_ROWS do
        local r = {}
        local y = py + (i - 1) * 26
        r.name = label(f, "GameFontHighlight"); at(r.name, f, 16, y + 4); r.name:SetWidth(110); r.name:SetWordWrap(false)
        r.chips = label(f, "GameFontHighlight", "RIGHT"); at(r.chips, f, 126, y + 4); r.chips:SetWidth(80)
        r.net = label(f, "GameFontHighlightSmall", "RIGHT"); at(r.net, f, 210, y + 5); r.net:SetWidth(70)
        r.add = button(f, "+", 26, function() end, 20); at(r.add, f, 288, y)
        r.take = button(f, "-", 26, function() end, 20); at(r.take, f, 318, y)
        r.kick = button(f, "Remove", 64, function() end, 20); at(r.kick, f, 350, y)
        H.rows[i] = r
    end
    H.more = label(f, "GameFontHighlightSmall"); at(H.more, f, 16, py + HOST_ROWS * 26 + 2)
    local hdrs = { { 126, 80, "Chips", "RIGHT" }, { 210, 70, "Result", "RIGHT" } }
    for _, h in ipairs(hdrs) do
        local fs = label(f, "GameFontNormalSmall", h[4]); at(fs, f, h[1], py - 14); fs:SetWidth(h[2]); fs:SetText(h[3])
    end

    -- right column
    local rx = 440
    local lr = label(f, "GameFontNormal"); at(lr, f, rx, 114); lr:SetText("Wheel")
    H.number = label(f, "GameFontNormalHuge", "CENTER"); at(H.number, f, rx, 138); H.number:SetWidth(264)
    H.history = label(f, "GameFontHighlightSmall"); at(H.history, f, rx, 188); H.history:SetWidth(264); H.history:SetWordWrap(true)
    local br = label(f, "GameFontNormal"); at(br, f, rx, 224); br:SetText("Bets this round")
    H.bets = label(f, "GameFontHighlightSmall"); at(H.bets, f, rx, 246); H.bets:SetWidth(264); H.bets:SetWordWrap(true)
    H.bets:SetJustifyV("TOP"); H.bets:SetHeight(150)
    local ll = label(f, "GameFontNormal"); at(ll, f, rx, 404); ll:SetText("Bet limits")
    H.minBox = editBox(f, 70, "", 12); at(H.minBox, f, rx, 426)
    local dash = label(f, "GameFontHighlight"); at(dash, f, rx + 78, 430); dash:SetText("to")
    H.maxBox = editBox(f, 70, "", 12); at(H.maxBox, f, rx + 100, 426)
    H.setLimits = button(f, "Set", 50, function()
        local t = hostTable(); if not t then return end
        local lo, hi = Odds.ParseMoney(H.minBox:GetText()), Odds.ParseMoney(H.maxBox:GetText())
        if not (lo and hi) then return say("Enter bet sizes like 1s or 1g.") end
        local ok, err = CN.SetLimits(t, lo, hi)
        if not ok then say(err) end
        UI.Refresh()
    end, 22)
    at(H.setLimits, f, rx + 178, 426)

    H.spin = button(f, "Spin the wheel", 180, function()
        local t = hostTable(); if not t then return end
        local ok, err = CN.Spin(t)
        if not ok then say(err) end
    end, 32)
    at(H.spin, f, 16, 500)
    H.close = button(f, "Close table", 120, function()
        local t = hostTable(); if not t then return end
        if not confirmClose then
            confirmClose = true
            H.close:SetText("Click again")
            if C_Timer and C_Timer.After then C_Timer.After(5, function() confirmClose = false; H.close:SetText("Close table") end) end
            return
        end
        confirmClose = false
        H.close:SetText("Close table")
        CN.CloseTable(t)
        say("Table closed. Settle up with your players in gold, then delete it from /casino.")
    end, 22)
    at(H.close, f, 580, 504)
    f:SetScript("OnShow", function() UI.Refresh() end)
end

local function refreshHost()
    local H = host
    if not (H.frame and H.frame:IsShown()) then return end
    local t = hostTable()
    if not t then H.frame:Hide(); return end
    H.head:SetText(t.name)
    local statusText = ({ betting = GREEN .. "Taking bets|r", spinning = GOLD .. "Spinning...|r", closed = RED .. "Closed|r" })[t.status]
    H.status:SetText(("%s   Round %d   Bets %s to %s   %s"):format(statusText or t.status, t.round, money(t.minBet), money(t.maxBet),
        GREY .. ({ single = "single zero", double = "double zero", none = "no zero" })[t.zero] .. "|r"))
    H.codeBox:SetText(t.code)
    if not H.minBox:HasFocus() then H.minBox:SetText(money(t.minBet)) end
    if not H.maxBox:HasFocus() then H.maxBox:SetText(money(t.maxBet)) end

    local pending = Casino.Pending(t)
    for i, r in ipairs(H.pending) do
        local name = pending[i]
        r.name:SetShown(name ~= nil); r.admit:SetShown(name ~= nil); r.deny:SetShown(name ~= nil)
        if name then
            r.name:SetText(GOLD .. name .. "|r asks for a seat")
            r.name:SetWidth(150)
            r.admit:SetScript("OnClick", function()
                local chips = Odds.ParseMoney(H.chips:GetText()) or 0
                local ok, err = CN.Admit(t, name, chips)
                if not ok then say(err) end
                UI.Refresh()
            end)
            r.deny:SetScript("OnClick", function() CN.Deny(t, name); UI.Refresh() end)
        end
    end

    local ledger = {}
    for _, e in ipairs(Casino.Ledger(t)) do if e.status == "seated" then ledger[#ledger + 1] = e end end
    for i, r in ipairs(H.rows) do
        local e = ledger[i]
        for _, w in ipairs({ r.name, r.chips, r.net, r.add, r.take, r.kick }) do w:SetShown(e ~= nil) end
        if e then
            local m = t.members[e.name]
            r.name:SetText(e.name)
            r.chips:SetText(money(m.balance + Casino.Staked(m)))
            r.net:SetText((e.result >= 0 and GREEN or RED) .. (e.result >= 0 and "+" or "") .. money(e.result) .. "|r")
            r.add:SetScript("OnClick", function()
                local c = chipsAmount(); if not c then return end
                local ok, err = CN.Adjust(t, e.name, c)
                if not ok then say(err == "bad_amount" and "Chips are whole silver." or err) end
                UI.Refresh()
            end)
            r.take:SetScript("OnClick", function()
                local c = chipsAmount(); if not c then return end
                local ok, err = CN.Adjust(t, e.name, -c)
                if not ok then say(err == "no_balance" and (e.name .. " does not have that many chips.") or "Chips are whole silver.") end
                UI.Refresh()
            end)
            r.kick:SetScript("OnClick", function() CN.Kick(t, e.name); UI.Refresh() end)
        end
    end
    H.more:SetText(#ledger > HOST_ROWS and (GREY .. ("+%d more seated"):format(#ledger - HOST_ROWS) .. "|r")
        or (#ledger == 0 and (GREY .. "Nobody is seated yet.|r") or ""))

    local last = t.lastResult
    H.number:SetText(last and colored(last.number) or GREY .. "-|r")
    H.history:SetText(historyText(t.history))
    local lines = {}
    for _, name in ipairs(Casino.Seated(t)) do
        local m = t.members[name]
        if #m.bets > 0 then
            local parts = {}
            for _, b in ipairs(m.bets) do parts[#parts + 1] = Roulette.Describe(b) .. " " .. money(b.amount) end
            lines[#lines + 1] = name .. ": " .. table.concat(parts, ", ")
        end
    end
    H.bets:SetText(#lines > 0 and table.concat(lines, "\n") or (GREY .. "No bets yet.|r"))
    if t.status == "betting" then H.spin:Enable() else H.spin:Disable() end
end

------------------------------------------------------------------------------------------
-- Player window: the roulette board
------------------------------------------------------------------------------------------

local play = {}
local playCode
local betMode = "straight"            -- straight | split | street | corner | sixline
local MODE_SIZE = { straight = 1, split = 2, street = 3, corner = 4, sixline = 6 }
local MODE_TITLE = { straight = "Straight", split = "Split", street = "Street", corner = "Corner", sixline = "Six line" }
local picks = {}                      -- numbers selected for a multi-number bet
local amount = Odds.STAKE_STEP * 1    -- chip size in copper
local message = ""

local function playTable()
    return playCode and db() and db().casinoCache and Client.Table(db().casinoCache, playCode)
end

local function setMessage(text)
    message = text or ""
    if play.msg then play.msg:SetText(message) end
end

local function placeBet(bet)
    local ok, err = CN.PlaceBet(playCode, bet)
    if not ok then setMessage(RED .. err .. "|r"); return false end
    setMessage("")
    return true
end

local function clearPicks()
    picks = {}
end

function UI.SetMode(m)
    if not MODE_SIZE[m] then return end
    betMode = m
    clearPicks()
    UI.Refresh()
end

function UI.SetAmount(copper)
    amount = copper
    if play.amountBox then play.amountBox:SetText(money(copper)) end
end

local function currentAmount()
    local c = play.amountBox and Odds.ParseMoney(play.amountBox:GetText())
    if not c or c <= 0 then setMessage(RED .. "Enter a chip size like 5s.|r"); return nil end
    amount = c
    return c
end

-- A click on a pocket: a straight bet, or one more number toward a split / street / corner / six line.
function UI.PickNumber(n)
    local a = currentAmount(); if not a then return end
    if betMode == "straight" then
        placeBet({ kind = "straight", numbers = { n }, amount = a })
        return
    end
    for i, x in ipairs(picks) do
        if x == n then table.remove(picks, i); UI.Refresh(); return end        -- click again to un-pick
    end
    picks[#picks + 1] = n
    if #picks == MODE_SIZE[betMode] then
        local bet = { kind = betMode, numbers = picks, amount = a }
        local tc = playTable()
        local ok, _, msg = Roulette.ValidateBet(bet, tc and tc.state and tc.state.zero or "single")
        if ok then placeBet(bet) else setMessage(RED .. (msg or "Those numbers do not make that bet.") .. "|r") end
        clearPicks()
    end
    UI.Refresh()
end

function UI.PickOutside(kind, pick)
    local a = currentAmount(); if not a then return end
    placeBet({ kind = kind, pick = pick, amount = a })
end

local OUTSIDE = {
    { "dozen", 1, "1st 12" }, { "dozen", 2, "2nd 12" }, { "dozen", 3, "3rd 12" },
    { "low", nil, "1-18" }, { "even", nil, "Even" }, { "red", nil, "Red" },
    { "black", nil, "Black" }, { "odd", nil, "Odd" }, { "high", nil, "19-36" },
}

local function numberCell(parent, n, w, h)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(w or CELL_W, h or CELL_H)
    c.bg = c:CreateTexture(nil, "BACKGROUND"); c.bg:SetAllPoints()
    local col = Roulette.Color(n)
    c.base = col == "red" and { 0.62, 0.1, 0.1 } or (col == "green" and { 0.08, 0.42, 0.14 } or { 0.07, 0.07, 0.07 })
    paint(c.bg, c.base[1], c.base[2], c.base[3], 1)
    c.mark = c:CreateTexture(nil, "BORDER"); c.mark:SetAllPoints(); paint(c.mark, 1, 0.82, 0, 0.0)
    c.text = label(c, "GameFontNormalSmall", "CENTER"); c.text:SetPoint("CENTER", 0, 5); c.text:SetText(Roulette.Label(n))
    c.stake = label(c, "GameFontHighlightSmall", "CENTER"); c.stake:SetPoint("BOTTOM", 0, 2)
    c.n = n
    c:SetScript("OnClick", function() UI.PickNumber(n) end)
    c:SetScript("OnEnter", function(self) paint(self.bg, self.base[1] + 0.15, self.base[2] + 0.15, self.base[3] + 0.15, 1) end)
    c:SetScript("OnLeave", function(self) paint(self.bg, self.base[1], self.base[2], self.base[3], 1) end)
    return c
end

local function flatButton(parent, text, w, h, onClick)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(w, h)
    c.bg = c:CreateTexture(nil, "BACKGROUND"); c.bg:SetAllPoints(); paint(c.bg, 0.16, 0.13, 0.085, 1)
    c.text = label(c, "GameFontHighlightSmall", "CENTER"); c.text:SetPoint("CENTER"); c.text:SetText(text)
    c.stake = label(c, "GameFontNormalSmall", "RIGHT"); c.stake:SetPoint("BOTTOMRIGHT", -3, 2)
    c:SetScript("OnClick", onClick)
    c:SetScript("OnEnter", function(self) paint(self.bg, 0.26, 0.2, 0.11, 1) end)
    c:SetScript("OnLeave", function(self) paint(self.bg, 0.16, 0.13, 0.085, 1) end)
    return c
end

local function buildTable()
    local P = play
    local f = newWindow("SteveBookCasinoTableFrame", 860, 610, "SteveBook Casino")
    P.frame = f

    P.head = label(f, "GameFontNormalLarge"); at(P.head, f, 16, 34)
    P.status = label(f, "GameFontHighlight"); at(P.status, f, 16, 58)
    P.balance = label(f, "GameFontHighlight", "RIGHT"); at(P.balance, f, 460, 36); P.balance:SetWidth(260)
    P.leave = button(f, "Leave table", 110, function()
        if playCode then CN.Leave(playCode) end
    end, 22)
    at(P.leave, f, 730, 30)

    -- the board: zeros on the left, 12 columns of 3 rows, then the 2:1 column bets
    local bx, by = 16, 96
    P.board = CreateFrame("Frame", nil, f)
    P.board:SetPoint("TOPLEFT", f, "TOPLEFT", bx, -by)
    P.board:SetSize(CELL_W * 14 + 6, CELL_H * 3 + 6)
    P.cells = {}
    P.zero = numberCell(P.board, 0, CELL_W, CELL_H * 3)
    at(P.zero, P.board, 0, 0); P.cells[0] = P.zero
    P.dzero = numberCell(P.board, Roulette.DOUBLE_ZERO, CELL_W, CELL_H * 3 / 2)
    at(P.dzero, P.board, 0, 0); P.cells[Roulette.DOUBLE_ZERO] = P.dzero
    for n = 1, 36 do
        local c = numberCell(P.board, n)
        local colIdx = math.ceil(n / 3)               -- 1..12
        local rowIdx = 2 - (n - 1) % 3                -- 0 = top row
        at(c, P.board, CELL_W * colIdx, CELL_H * rowIdx)
        P.cells[n] = c
    end
    P.columns = {}
    for pick = 1, 3 do                                -- column 1 is the bottom row (1, 4, 7 ...)
        local c = flatButton(P.board, "2:1", CELL_W, CELL_H, function() UI.PickOutside("column", pick) end)
        at(c, P.board, CELL_W * 13, CELL_H * (3 - pick))
        P.columns[pick] = c
    end

    -- outside bets under the board
    P.outside = {}
    local oy = by + CELL_H * 3 + 12
    local ox = bx + CELL_W
    local idx = 0
    -- dozens: 4 cells wide each
    for i = 1, 3 do
        local o = OUTSIDE[i]
        local c = flatButton(f, o[3], CELL_W * 4 - 2, 30, function() UI.PickOutside(o[1], o[2]) end)
        at(c, f, ox + (i - 1) * CELL_W * 4, oy)
        P.outside[#P.outside + 1] = { cell = c, kind = o[1], pick = o[2] }
    end
    -- even-money bets: 2 cells wide each
    for i = 4, 9 do
        local o = OUTSIDE[i]
        local c = flatButton(f, o[3], CELL_W * 2 - 2, 30, function() UI.PickOutside(o[1], o[2]) end)
        at(c, f, ox + (i - 4) * CELL_W * 2, oy + 34)
        if o[1] == "red" then paint(c.bg, 0.5, 0.08, 0.08, 1) elseif o[1] == "black" then paint(c.bg, 0.05, 0.05, 0.05, 1) end
        P.outside[#P.outside + 1] = { cell = c, kind = o[1], pick = o[2] }
    end

    -- bet type and chip size
    local ty = oy + 78
    local tl = label(f, "GameFontNormal"); at(tl, f, 16, ty); tl:SetText("Bet type")
    P.modes = {}
    local mx = 90
    for _, m in ipairs({ "straight", "split", "street", "corner", "sixline" }) do
        local b = button(f, MODE_TITLE[m], 82, function() UI.SetMode(m) end, 22)
        at(b, f, mx, ty - 4); mx = mx + 86
        P.modes[m] = b
    end
    P.modeHint = label(f, "GameFontHighlightSmall"); at(P.modeHint, f, 16, ty + 26); P.modeHint:SetWidth(520)
    local cl = label(f, "GameFontNormal"); at(cl, f, 16, ty + 54); cl:SetText("Chip size")
    P.amountBox = editBox(f, 70, money(amount), 12); at(P.amountBox, f, 90, ty + 50)
    local qx = 170
    for _, v in ipairs({ 100, 500, 1000, 5000, 10000 }) do
        local b = button(f, money(v), 46, function() UI.SetAmount(v) end, 22)
        at(b, f, qx, ty + 50); qx = qx + 50
    end
    P.msg = label(f, "GameFontHighlight"); at(P.msg, f, 16, ty + 82); P.msg:SetWidth(560); P.msg:SetWordWrap(true)

    -- right column: result, history, my bets, players
    local rx = 600
    local rl = label(f, "GameFontNormal"); at(rl, f, rx, 96 + CELL_H * 3 + 12); rl:SetText("Last spin")
    P.number = label(f, "GameFontNormalHuge", "LEFT"); at(P.number, f, rx + 90, 96 + CELL_H * 3 + 2)
    P.history = label(f, "GameFontHighlightSmall"); at(P.history, f, rx, 96 + CELL_H * 3 + 44); P.history:SetWidth(244); P.history:SetWordWrap(true)
    local ml = label(f, "GameFontNormal"); at(ml, f, rx, 96 + CELL_H * 3 + 80); ml:SetText("My bets")
    P.clear = button(f, "Take all back", 100, function()
        local ok, err = CN.ClearBets(playCode)
        if not ok then setMessage(RED .. err .. "|r") end
    end, 20)
    at(P.clear, f, rx + 144, 96 + CELL_H * 3 + 76)
    P.bets = label(f, "GameFontHighlightSmall"); at(P.bets, f, rx, 96 + CELL_H * 3 + 104); P.bets:SetWidth(244)
    P.bets:SetWordWrap(true); P.bets:SetJustifyV("TOP"); P.bets:SetHeight(92)
    local sl = label(f, "GameFontNormal"); at(sl, f, rx, 96 + CELL_H * 3 + 200); sl:SetText("At the table")
    P.seats = label(f, "GameFontHighlightSmall"); at(P.seats, f, rx, 96 + CELL_H * 3 + 222); P.seats:SetWidth(244)
    P.seats:SetWordWrap(true); P.seats:SetJustifyV("TOP"); P.seats:SetHeight(110)

    f:SetScript("OnShow", function()
        if playCode then CN.Sync(playCode) end
        UI.Refresh()
    end)
end

local function stakedOn(tc)
    local straight, outside = {}, {}
    for _, b in ipairs(tc.bets) do
        if b.kind == "straight" then straight[b.numbers[1]] = (straight[b.numbers[1]] or 0) + b.amount
        elseif b.kind == "dozen" or b.kind == "column" then outside[b.kind .. b.pick] = (outside[b.kind .. b.pick] or 0) + b.amount
        elseif not b.numbers then outside[b.kind] = (outside[b.kind] or 0) + b.amount end
    end
    return straight, outside
end

local function shortMoney(c)
    if c >= Odds.MAX_STAKE and c % Odds.MAX_STAKE == 0 then return (c / Odds.MAX_STAKE) .. "g" end
    if c % 100 == 0 then return (c / 100) .. "s" end
    return money(c)
end

local function refreshTable()
    local P = play
    if not (P.frame and P.frame:IsShown()) then return end
    local tc = playTable()
    if not tc then P.frame:Hide(); return end
    local st = tc.state
    P.head:SetText(tc.name or "Roulette")
    local seated = tc.status == "seated"
    local zero = st and st.zero or "single"
    local statusText
    if tc.status == "requested" then statusText = GOLD .. "Waiting for the host to let you in...|r"
    elseif tc.status == "denied" then statusText = RED .. "The host turned down your request.|r"
    elseif tc.status == "removed" then statusText = RED .. "The host removed you from the table.|r"
    elseif tc.status == "left" then statusText = GREY .. "You left the table.|r"
    elseif tc.status == "closed" then statusText = RED .. "This table is closed.|r"
    elseif not st then statusText = GOLD .. "Waiting for the table...|r"
    elseif st.status == "spinning" then statusText = GOLD .. "No more bets: the wheel is spinning...|r"
    else statusText = GREEN .. "Place your bets|r" .. GREY .. ("   Round %d   %s to %s"):format(st.round, money(st.minBet), money(st.maxBet)) .. "|r" end
    P.status:SetText(statusText)
    local staked = Client.Staked(tc)
    P.balance:SetText(("Chips: %s%s|r   on the table: %s"):format(GOLD, money(tc.balance or 0), money(staked)))

    -- zero cells follow the wheel
    P.zero:SetShown(zero ~= "none")
    if zero == "double" then
        P.zero:SetSize(CELL_W, CELL_H * 3 / 2)
        P.dzero:Show(); P.dzero:ClearAllPoints()
        P.dzero:SetPoint("TOPLEFT", P.board, "TOPLEFT", 0, -CELL_H * 3 / 2)
    else
        P.zero:SetSize(CELL_W, CELL_H * 3)
        P.dzero:Hide()
    end

    local straight, outside = stakedOn(tc)
    local selected = {}
    for _, n in ipairs(picks) do selected[n] = true end
    for n, c in pairs(P.cells) do
        local s = straight[n]
        c.stake:SetText(s and (GOLD .. shortMoney(s) .. "|r") or "")
        paint(c.mark, 1, 0.82, 0, selected[n] and 0.55 or (s and 0.22 or 0.0))
    end
    for pick = 1, 3 do P.columns[pick].stake:SetText(outside["column" .. pick] and shortMoney(outside["column" .. pick]) or "") end
    for _, o in ipairs(P.outside) do
        local key = o.pick and (o.kind .. o.pick) or o.kind
        o.cell.stake:SetText(outside[key] and shortMoney(outside[key]) or "")
    end

    for m, b in pairs(P.modes) do
        if m == betMode then b:Disable() else b:Enable() end
    end
    if betMode == "straight" then
        P.modeHint:SetText(GREY .. "Click a number or a box under the board to bet the chip size.|r")
    else
        P.modeHint:SetText(GREY .. ("Pick %d numbers that touch (%d chosen). Click a chosen number again to drop it."):format(MODE_SIZE[betMode], #picks) .. "|r")
    end

    local last = tc.lastResult
    P.number:SetText(last and colored(last.number) or GREY .. "-|r")
    P.history:SetText(historyText(st and st.history))
    local lines = {}
    for _, b in ipairs(tc.bets) do lines[#lines + 1] = Roulette.Describe(b) .. "  " .. money(b.amount) end
    for _, p in pairs(tc.pending) do lines[#lines + 1] = GREY .. Roulette.Describe(p.bet) .. "  " .. money(p.bet.amount) .. " (waiting)|r" end
    P.bets:SetText(#lines > 0 and table.concat(lines, "\n") or (GREY .. "none yet|r"))
    local seats = {}
    for _, s in ipairs(st and st.seats or {}) do
        seats[#seats + 1] = (s.name == myName(tc) and (GOLD .. s.name .. "|r") or s.name) .. "  " .. money(s.balance)
    end
    P.seats:SetText(#seats > 0 and table.concat(seats, "\n") or (GREY .. "nobody yet|r"))
    local mine = Client.MyResult(tc, myName(tc))
    if mine and not (message ~= "") then
        P.msg:SetText(("Last spin: %s%s|r"):format(mine.net >= 0 and GREEN or RED, (mine.net >= 0 and "+" or "") .. money(mine.net)))
    else
        P.msg:SetText(message)
    end
    if seated and Client.CanBet(tc) then P.clear:Enable() else P.clear:Disable() end
    if tc.status == "seated" then P.leave:Enable() else P.leave:Disable() end
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

function UI.Refresh()
    refreshLauncher()
    refreshHost()
    refreshTable()
end

function UI.OpenHost(code)
    if not host.frame then buildHost() end
    hostCode = ns.Protocol.CanonicalCode(code)
    host.frame:Show()
    UI.Refresh()
end

function UI.OpenTable(code)
    if not play.frame then buildTable() end
    playCode = ns.Protocol.CanonicalCode(code)
    picks = {}
    setMessage("")
    play.frame:Show()
    UI.Refresh()
end

function UI.Show()
    if not launcher.frame then buildLauncher() end
    setMode("home")
    launcher.frame:Show()
    UI.Refresh()
end

function UI.Hide()
    if launcher.frame then launcher.frame:Hide() end
end

function UI.Toggle()
    if launcher.frame and launcher.frame:IsShown() then UI.Hide() else UI.Show() end
end

CN.Subscribe(function() UI.Refresh() end)
