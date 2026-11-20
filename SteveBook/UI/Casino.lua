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

local Casino, Client, CN, Roulette, Odds, Blackjack = ns.Casino, ns.CasinoClient, ns.CasinoNet, ns.Roulette, ns.Odds, ns.Blackjack
local UI = {}
ns.UI.Casino = UI

local GOLD, GREEN, RED, GREY = "|cffffd100", "|cff40ff40", "|cffff5050", "|cff999999"
local CELL_W, CELL_H = 38, 34
local HOST_ROWS, PENDING_ROWS, TABLE_ROWS = 7, 4, 8

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

-- `anchor` = { point, x, y } for where the window first opens (it can be dragged afterwards). The
-- launcher sits in the middle; the host window opens at the left and a table the player sits at on
-- the right, so a host who also plays (/book loopback) sees both.
local function newWindow(name, w, h, title, anchor)
    local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
    if UISpecialFrames then table.insert(UISpecialFrames, name) end     -- Escape closes it
    f:SetSize(w, h)
    if anchor then f:SetPoint(anchor[1], UIParent, anchor[1], anchor[2], anchor[3]) else f:SetPoint("CENTER") end
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

-- A small "Casino" button in the corner of a table window: back to the list of games.
local function casinoButton(f)
    local b = button(f, "Casino", 64, function() f:Hide(); UI.Show() end, 20)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -3)
    return b
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

-- "1s-1g" for a table's bet limits.
local function shortRange(r) return money(r.minBet or 0) .. "-" .. money(r.maxBet or 0) end

-- The player's own name as the table knows it.
local function myName(tc) return tc and tc.me or UnitName("player") end

------------------------------------------------------------------------------------------
-- Launcher
------------------------------------------------------------------------------------------

local launcher = {}          -- frame, sections
local mode = "home"          -- "home" | "host" | "join"
local hostGame, joinGame = "roulette", "roulette"
local wheel = "single"
local WHEEL_TEXT = {
    single = "Single zero (0). The house keeps 2.7%.",
    double = "Double zero (0 and 00). The house keeps 5.3%.",
    none = "No zero. Fair odds, the house keeps nothing.",
}
local ROOM_ROWS = 7
local confirmClose

local function gameTitle(id) return Casino.GAMES[id] and Casino.GAMES[id].title or id end

-- Which game a table code belongs to: what we were told, else its prefix (RLT / BJK).
local function gameOfCode(code)
    local d = db()
    local tc = d and d.casinoCache and Client.Table(d.casinoCache, code)
    if tc and tc.game then return tc.game end
    local t = d and Casino.Find(d, code)
    if t then return t.game end
    local prefix = ns.Protocol.CanonicalCode(code):sub(1, 3)
    for id, g in pairs(Casino.GAMES) do if g.prefix == prefix then return id end end
    return "roulette"
end

local function setMode(m, game)
    mode = m
    local L = launcher
    if not L.frame then return end
    if m == "host" and game then hostGame = game end
    if m == "join" and game then joinGame = game end
    L.home:SetShown(m == "home")
    L.hostForm:SetShown(m == "host")
    L.joinForm:SetShown(m == "join")
    if m == "host" then
        L.hostTitle:SetText("Host a " .. gameTitle(hostGame):lower() .. " table")
        local roulette = hostGame == "roulette"
        L.wheelLabel:SetShown(roulette); L.wheelBtn:SetShown(roulette); L.wheelNote:SetShown(roulette)
    elseif m == "join" then
        L.joinTitle:SetText("Open " .. gameTitle(joinGame):lower() .. " tables")
        CN.AskLobby()
    end
    UI.Refresh()
end

local function tableRows()
    local rows = {}
    local d = db()
    if not d then return rows end
    for _, t in ipairs(Casino.List(d)) do
        if t.hostName == UnitName("player") then
            local seated = #Casino.Seated(t)
            rows[#rows + 1] = { host = true, code = t.code,
                text = ("%sHosting|r %s  %s  %s  %d seated"):format(GOLD, t.name, GREY .. gameTitle(t.game) .. "|r",
                    t.status == "closed" and (RED .. "closed|r") or (GREEN .. "open|r"), seated),
                closed = t.status == "closed" }
        end
    end
    for _, tc in ipairs(d.casinoCache and Client.List(d.casinoCache) or {}) do
        local status = ({ requested = GOLD .. "waiting for the host|r", seated = GREEN .. "seated|r",
            denied = RED .. "turned down|r", left = GREY .. "left|r", removed = RED .. "removed|r",
            closed = GREY .. "closed|r" })[tc.status] or tc.status
        rows[#rows + 1] = { host = false, code = tc.code,
            text = ("%s  %s  %s"):format(tc.name or gameTitle(gameOfCode(tc.code)), GREY .. gameTitle(gameOfCode(tc.code)) .. "|r", status) }
    end
    return rows
end

local function roomText(r)
    local bits = { r.name, GREY .. "host " .. r.host .. "|r", ("%d seated"):format(r.seats or 0),
        GREY .. "bets " .. shortRange(r) .. "|r" }
    if r.zero then bits[#bits + 1] = GREY .. ({ single = "single zero", double = "double zero", none = "no zero" })[r.zero] .. "|r" end
    return table.concat(bits, "   ")
end

local function buildLauncher()
    local L = launcher
    local f = newWindow("SteveBookCasinoFrame", 560, 500, "SteveBook Casino")
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
        row.note:SetText(GREY .. (id == "roulette" and "Everyone bets on the same wheel. The host spins."
            or "Everyone plays the dealer at the same table. Blackjack pays 3:2.") .. "|r")
        row.host = button(L.home, "Host a table", 110, function() setMode("host", id) end)
        at(row.host, L.home, 300, y - 2)
        row.join = button(L.home, "Join a table", 110, function() setMode("join", id) end)
        at(row.join, L.home, 418, y - 2)
        if not g.ready then row.host:Disable(); row.join:Disable() end
        L.games[#L.games + 1] = row
        y = y + 46
    end
    local tl = label(L.home, "GameFontNormal"); at(tl, L.home, 0, y + 6); tl:SetText("Your tables")
    L.rows = {}
    for i = 1, 8 do
        local r = {}
        r.text = label(L.home, "GameFontHighlightSmall"); at(r.text, L.home, 0, y + 28 + (i - 1) * 26 + 4)
        r.text:SetWidth(370); r.text:SetWordWrap(false)
        r.open = button(L.home, "Open", 60, function() end, 20); at(r.open, L.home, 380, y + 28 + (i - 1) * 26)
        r.drop = button(L.home, "Remove", 70, function() end, 20); at(r.drop, L.home, 444, y + 28 + (i - 1) * 26)
        L.rows[i] = r
    end
    L.empty = label(L.home, "GameFontHighlightSmall"); at(L.empty, L.home, 0, y + 32)
    L.empty:SetText(GREY .. "No tables yet. Host one, or join a friend's.|r")
    L.sport = button(L.home, "Back to the sportsbook", 170, function()
        f:Hide()
        if ns.UI.Bettor and ns.UI.Bettor.Show then ns.UI.Bettor.Show() end
    end)
    L.sport:SetPoint("BOTTOMLEFT", L.home, "BOTTOMLEFT", 0, 0)

    -- host form
    L.hostForm = CreateFrame("Frame", nil, f)
    L.hostForm:SetPoint("TOPLEFT", 14, -34); L.hostForm:SetPoint("BOTTOMRIGHT", -14, 14)
    local hf = L.hostForm
    L.hostTitle = label(hf, "GameFontNormal"); at(L.hostTitle, hf, 0, 0); L.hostTitle:SetText("Host a roulette table")
    local n1 = label(hf, "GameFontHighlight"); at(n1, hf, 0, 34); n1:SetText("Table name")
    L.nameBox = editBox(hf, 240, "", 40); at(L.nameBox, hf, 130, 30)
    L.wheelLabel = label(hf, "GameFontHighlight"); at(L.wheelLabel, hf, 0, 70); L.wheelLabel:SetText("Wheel")
    L.wheelBtn = button(hf, "Single zero", 140, function()
        wheel = wheel == "single" and "double" or (wheel == "double" and "none" or "single")
        L.wheelBtn:SetText(({ single = "Single zero", double = "Double zero", none = "No zero" })[wheel])
        L.wheelNote:SetText(GREY .. WHEEL_TEXT[wheel] .. "|r")
    end)
    at(L.wheelBtn, hf, 130, 66)
    L.wheelNote = label(hf, "GameFontHighlightSmall"); at(L.wheelNote, hf, 280, 72); L.wheelNote:SetText(GREY .. WHEEL_TEXT.single .. "|r")
    L.wheelNote:SetWidth(240); L.wheelNote:SetWordWrap(true)
    local n3 = label(hf, "GameFontHighlight"); at(n3, hf, 0, 110); n3:SetText("Smallest bet")
    L.minBox = editBox(hf, 80, money(Casino.DEFAULT_MIN_BET), 12); at(L.minBox, hf, 130, 106)
    local n4 = label(hf, "GameFontHighlight"); at(n4, hf, 240, 110); n4:SetText("Largest bet")
    L.maxBox = editBox(hf, 80, money(Casino.DEFAULT_MAX_BET), 12); at(L.maxBox, hf, 330, 106)
    local note = label(hf, "GameFontHighlightSmall"); at(note, hf, 0, 150)
    note:SetWidth(500); note:SetWordWrap(true)
    note:SetText(GREY .. "Players get no chips until you give them some. Let someone in, then add chips for what they pay you. Chips are only a record: gold changes hands by trade, outside the addon. Your table shows up in the list of open tables for everyone.|r")
    L.create = button(hf, "Create table", 120, function()
        local lo, hi = Odds.ParseMoney(L.minBox:GetText()), Odds.ParseMoney(L.maxBox:GetText())
        if not (lo and hi) then return say("Enter the bet sizes like 1s or 1g.") end
        local t, err = CN.Create({ game = hostGame, name = L.nameBox:GetText(), zero = hostGame == "roulette" and wheel or nil, minBet = lo, maxBet = hi })
        if not t then return say(err) end
        say(("Table %s created. It is on the list of open tables; the code is %s%s|r if someone wants it."):format(t.name, GOLD, t.code))
        setMode("home")
        UI.OpenHost(t.code)
        UI.Refresh()
    end)
    at(L.create, hf, 0, 220)
    L.hostBack = button(hf, "Back", 80, function() setMode("home") end); at(L.hostBack, hf, 130, 220)

    -- join form: the list of open tables, and a code box for a table that is not listed
    L.joinForm = CreateFrame("Frame", nil, f)
    L.joinForm:SetPoint("TOPLEFT", 14, -34); L.joinForm:SetPoint("BOTTOMRIGHT", -14, 14)
    local jf = L.joinForm
    L.joinTitle = label(jf, "GameFontNormal"); at(L.joinTitle, jf, 0, 0); L.joinTitle:SetText("Open roulette tables")
    L.refresh = button(jf, "Refresh", 80, function() CN.AskLobby(); UI.Refresh() end, 22)
    at(L.refresh, jf, 440, -4 + 4)
    L.room = {}
    for i = 1, ROOM_ROWS do
        local r = {}
        local ry = 30 + (i - 1) * 32
        r.text = label(jf, "GameFontHighlightSmall"); at(r.text, jf, 0, ry + 6); r.text:SetWidth(420); r.text:SetWordWrap(false)
        r.join = button(jf, "Join", 70, function() end, 22); at(r.join, jf, 440, ry)
        L.room[i] = r
    end
    L.noRooms = label(jf, "GameFontHighlightSmall"); at(L.noRooms, jf, 0, 36); L.noRooms:SetWidth(500); L.noRooms:SetWordWrap(true)
    L.noRooms:SetText(GREY .. "No open tables yet. Tables show up here when a host opens one. Press Refresh to ask again.|r")
    local cy = 30 + ROOM_ROWS * 32 + 12
    local j2 = label(jf, "GameFontHighlightSmall"); at(j2, jf, 0, cy); j2:SetText("Have a table code? Type it here:")
    L.codeBox = editBox(jf, 120, "", 12); at(L.codeBox, jf, 190, cy - 6)
    L.request = button(jf, "Ask for a seat", 110, function()
        local tc, err = CN.RequestJoin(L.codeBox:GetText())
        if not tc then return say(err) end
        say("Asked for a seat at " .. tc.code .. ". Waiting for the host to let you in.")
        L.codeBox:SetText("")
        setMode("home")
        UI.OpenTable(tc.code)
        UI.Refresh()
    end)
    at(L.request, jf, 320, cy - 6)
    L.joinBack = button(jf, "Back", 80, function() setMode("home") end); at(L.joinBack, jf, 0, cy + 30)

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
    if mode == "join" then
        local rooms = CN.Rooms(joinGame)
        L.noRooms:SetShown(#rooms == 0)
        for i, r in ipairs(L.room) do
            local room = rooms[i]
            r.text:SetShown(room ~= nil); r.join:SetShown(room ~= nil)
            if room then
                r.text:SetText(roomText(room))
                r.join:SetScript("OnClick", function()
                    local tc, err = CN.RequestJoin(room.code, room.game)
                    if not tc then return say(err) end
                    say("Asked for a seat at " .. room.name .. ". Waiting for " .. room.host .. " to let you in.")
                    setMode("home")
                    UI.OpenTable(tc.code)
                    UI.Refresh()
                end)
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
    local f = newWindow("SteveBookCasinoHostFrame", 720, 560, "SteveBook Casino: Host", { "TOPLEFT", 40, -70 })
    H.frame = f
    casinoButton(f)
    H.head = label(f, "GameFontNormalLarge"); at(H.head, f, 16, 34)
    H.status = label(f, "GameFontHighlight"); at(H.status, f, 16, 58)
    local cl = label(f, "GameFontHighlightSmall"); at(cl, f, 16, 84); cl:SetText("Table code (share it):")
    H.codeBox = editBox(f, 110, "", 12); at(H.codeBox, f, 140, 80)
    H.codeBox:SetScript("OnChar", function(self) self:SetText(hostCode or "") end)   -- read only: you can still copy it

    local pl = label(f, "GameFontNormal"); at(pl, f, 16, 114); pl:SetText("Players")
    local cb = label(f, "GameFontHighlightSmall", "RIGHT"); at(cb, f, 130, 118); cb:SetWidth(180); cb:SetText("Chips to add or take:")
    H.chips = editBox(f, 80, "10s", 12); at(H.chips, f, 318, 110)

    -- the players: column headings, then one row each
    local hdrs = { { 126, 80, "Chips", "RIGHT" }, { 210, 70, "Result", "RIGHT" } }
    for _, h in ipairs(hdrs) do
        local fs = label(f, "GameFontNormalSmall", h[4]); at(fs, f, h[1], 142); fs:SetWidth(h[2]); fs:SetText(h[3])
    end
    local py = 160
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
    H.empty = label(f, "GameFontHighlightSmall"); at(H.empty, f, 16, py + 4)
    H.more = label(f, "GameFontHighlightSmall"); at(H.more, f, 16, py + HOST_ROWS * 26 + 2)

    -- players waiting for a seat
    local qy = py + HOST_ROWS * 26 + 22
    H.pendTitle = label(f, "GameFontNormal"); at(H.pendTitle, f, 16, qy)
    H.pending = {}
    for i = 1, PENDING_ROWS do
        local r = {}
        local y = qy + 24 + (i - 1) * 26
        r.name = label(f, "GameFontHighlight"); at(r.name, f, 16, y + 4)
        r.admit = button(f, "Let in with chips", 130, function() end, 20); at(r.admit, f, 160, y)
        r.deny = button(f, "Turn down", 80, function() end, 20); at(r.deny, f, 296, y)
        H.pending[i] = r
    end

    -- right column
    local rx = 440
    H.rightTitle = label(f, "GameFontNormal"); at(H.rightTitle, f, rx, 114); H.rightTitle:SetText("Wheel")
    H.number = label(f, "GameFontNormalHuge", "CENTER"); at(H.number, f, rx, 138); H.number:SetWidth(264)
    H.history = label(f, "GameFontHighlightSmall"); at(H.history, f, rx, 188); H.history:SetWidth(264); H.history:SetWordWrap(true)
    H.betsTitle = label(f, "GameFontNormal"); at(H.betsTitle, f, rx, 224); H.betsTitle:SetText("Bets this round")
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
        local ok, err
        if t.game == "blackjack" then ok, err = CN.Deal(t) else ok, err = CN.Spin(t) end
        if not ok then say(err) end
    end, 32)
    at(H.spin, f, 16, 500)
    H.skip = button(f, "Skip this player", 140, function()
        local t = hostTable(); if not t then return end
        local ok, err = CN.Skip(t)
        if not ok then say(err) end
    end, 22)
    at(H.skip, f, 210, 505)
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
    local bjGame = t.game == "blackjack"
    local statusText = ({ betting = GREEN .. "Taking bets|r", spinning = GOLD .. "Spinning...|r", closed = RED .. "Closed|r",
        playing = GOLD .. "Players are deciding|r", dealer = GOLD .. "Dealer's turn|r" })[t.status]
    H.status:SetText(("%s   Round %d   Bets %s to %s   %s"):format(statusText or t.status, t.round, money(t.minBet), money(t.maxBet),
        GREY .. (bjGame and "blackjack pays 3:2" or ({ single = "single zero", double = "double zero", none = "no zero" })[t.zero]) .. "|r"))
    H.rightTitle:SetText(bjGame and "Dealer" or "Wheel")
    H.betsTitle:SetText(bjGame and "Hands" or "Bets this round")
    H.skip:SetShown(bjGame)
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
    H.more:SetText(#ledger > HOST_ROWS and (GREY .. ("+%d more seated"):format(#ledger - HOST_ROWS) .. "|r") or "")
    H.empty:SetText(#ledger == 0 and (GREY .. "Nobody is seated yet.|r") or "")
    H.pendTitle:SetText(#pending > 0 and "Asking for a seat" or (GREY .. "Nobody is waiting for a seat.|r"))

    local last = t.lastResult
    local lines = {}
    if bjGame then
        local pub = ns.BlackjackTable.Public(t)
        local dealerText = #pub.dealer.cards == 0 and (GREY .. "no cards yet|r") or UI.CardsText(pub.dealer.cards) .. (pub.dealer.hidden and " ??" or "")
        H.number:SetText(dealerText)
        H.history:SetText(last and last.dealer and (GREY .. ("Last round: dealer %d%s"):format(last.dealer.total, last.dealer.bust and " (bust)" or "") .. "|r") or "")
        for _, h in ipairs(pub.hands) do
            lines[#lines + 1] = h.name .. ": " .. UI.HandsText(h.hands)
        end
        H.bets:SetText(#lines > 0 and table.concat(lines, "\n") or (GREY .. "No bets yet.|r"))
        local anyWager = false
        for _, name in ipairs(Casino.Seated(t)) do
            for _, b in ipairs(t.members[name].bets) do if b.kind == "wager" then anyWager = true end end
        end
        H.spin:SetText("Deal")
        if t.status == "betting" and anyWager then H.spin:Enable() else H.spin:Disable() end
        if t.status == "playing" then H.skip:Enable() else H.skip:Disable() end
    else
        H.number:SetText(last and colored(last.number) or GREY .. "-|r")
        H.history:SetText(historyText(t.history))
        for _, name in ipairs(Casino.Seated(t)) do
            local m = t.members[name]
            if #m.bets > 0 then
                local parts = {}
                for _, b in ipairs(m.bets) do parts[#parts + 1] = Roulette.Describe(b) .. " " .. money(b.amount) end
                lines[#lines + 1] = name .. ": " .. table.concat(parts, ", ")
            end
        end
        H.bets:SetText(#lines > 0 and table.concat(lines, "\n") or (GREY .. "No bets yet.|r"))
        H.spin:SetText("Spin the wheel")
        if t.status == "betting" then H.spin:Enable() else H.spin:Disable() end
    end
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
    local f = newWindow("SteveBookCasinoTableFrame", 860, 610, "SteveBook Casino", { "TOPRIGHT", -40, -70 })
    P.frame = f
    casinoButton(f)

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
-- Player window: blackjack
------------------------------------------------------------------------------------------

local SUIT_COLOR = { S = "|cffdddddd", H = "|cffff5050", D = "|cff55aaff", C = "|cff55dd77" }

-- "10h", "As": the rank, then the suit in its own colour (four-colour deck; plain letters, so no
-- special glyphs are needed from the font).
function UI.CardText(card)
    local suit = card:sub(2, 2)
    return Blackjack.RankLabel(card) .. (SUIT_COLOR[suit] or "") .. suit:lower() .. "|r"
end

function UI.CardsText(cards)
    local parts = {}
    for i, c in ipairs(cards) do parts[i] = UI.CardText(c) end
    return table.concat(parts, " ")
end

local HAND_STATE = { stand = "stands", bust = RED .. "BUST|r", blackjack = GREEN .. "BLACKJACK|r", bet = GREY .. "bet placed|r" }

-- One player's hands as a line of text: cards, total, bet, state (two hands after a split).
function UI.HandsText(hands)
    local parts = {}
    for i, h in ipairs(hands) do
        local bits = {}
        if #h.cards > 0 then
            bits[#bits + 1] = UI.CardsText(h.cards)
            if h.value then bits[#bits + 1] = "= " .. (h.soft and h.value <= 21 and "soft " or "") .. h.value end
        end
        bits[#bits + 1] = GREY .. "bet " .. money(h.bet or 0) .. "|r"
        if HAND_STATE[h.state] then bits[#bits + 1] = HAND_STATE[h.state] end
        parts[i] = table.concat(bits, "  ")
    end
    return table.concat(parts, "   |   ")
end

local bj = {}
local bjCode
local BJ_ROWS = 7

local function bjTable() return bjCode and db() and db().casinoCache and Client.Table(db().casinoCache, bjCode) end

local function bjMessage(text) bj.message = text or ""; if bj.msg then bj.msg:SetText(bj.message) end end

local function bjAct(action)
    local ok, err = CN.Act(bjCode, action)
    if not ok then bjMessage(RED .. err .. "|r") else bjMessage("") end
end

local function buildBlackjack()
    local B = bj
    local f = newWindow("SteveBookBlackjackFrame", 860, 590, "SteveBook Casino", { "TOPRIGHT", -40, -70 })
    B.frame = f
    casinoButton(f)
    B.head = label(f, "GameFontNormalLarge"); at(B.head, f, 16, 34)
    B.status = label(f, "GameFontHighlight"); at(B.status, f, 16, 58); B.status:SetWidth(500)
    B.balance = label(f, "GameFontHighlight", "RIGHT"); at(B.balance, f, 460, 36); B.balance:SetWidth(260)
    B.leave = button(f, "Leave table", 110, function() if bjCode then CN.Leave(bjCode) end end, 22)
    at(B.leave, f, 730, 30)

    local dl = label(f, "GameFontNormal"); at(dl, f, 16, 92); dl:SetText("Dealer")
    B.dealer = label(f, "GameFontNormalLarge"); at(B.dealer, f, 16, 114); B.dealer:SetWidth(600)
    B.dealerNote = label(f, "GameFontHighlightSmall"); at(B.dealerNote, f, 16, 142); B.dealerNote:SetWidth(600)

    local pl = label(f, "GameFontNormal"); at(pl, f, 16, 168); pl:SetText("Players")
    B.rows = {}
    for i = 1, BJ_ROWS do
        local y = 192 + (i - 1) * 38
        local r = {}
        r.name = label(f, "GameFontHighlight"); at(r.name, f, 16, y); r.name:SetWidth(130); r.name:SetWordWrap(false)
        r.hands = label(f, "GameFontHighlight"); at(r.hands, f, 150, y); r.hands:SetWidth(690); r.hands:SetWordWrap(true)
        r.hands:SetJustifyV("TOP"); r.hands:SetHeight(34)
        B.rows[i] = r
    end
    B.more = label(f, "GameFontHighlightSmall"); at(B.more, f, 16, 192 + BJ_ROWS * 38)

    -- betting controls
    B.betPanel = CreateFrame("Frame", nil, f)
    B.betPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -486); B.betPanel:SetSize(820, 56)
    local cl = label(B.betPanel, "GameFontNormal"); at(cl, B.betPanel, 0, 4); cl:SetText("Your bet")
    B.amountBox = editBox(B.betPanel, 70, money(amount), 12); at(B.amountBox, B.betPanel, 80, 0)
    local qx = 160
    for _, v in ipairs({ 100, 500, 1000, 5000, 10000 }) do
        local b = button(B.betPanel, money(v), 46, function() amount = v; B.amountBox:SetText(money(v)) end, 22)
        at(b, B.betPanel, qx, 0); qx = qx + 50
    end
    B.place = button(B.betPanel, "Place bet", 100, function()
        local c = Odds.ParseMoney(B.amountBox:GetText())
        if not c or c <= 0 then return bjMessage(RED .. "Enter a bet like 5s.|r") end
        local ok, err = CN.Wager(bjCode, c)
        if not ok then bjMessage(RED .. err .. "|r") else bjMessage("") end
    end, 22)
    at(B.place, B.betPanel, 420, 0)
    B.back = button(B.betPanel, "Take it back", 100, function()
        local ok, err = CN.ClearBets(bjCode)
        if not ok then bjMessage(RED .. err .. "|r") end
    end, 22)
    at(B.back, B.betPanel, 526, 0)

    -- decisions
    B.actPanel = CreateFrame("Frame", nil, f)
    B.actPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -486); B.actPanel:SetSize(820, 56)
    B.hit = button(B.actPanel, "Hit", 90, function() bjAct("hit") end, 28); at(B.hit, B.actPanel, 0, 0)
    B.stand = button(B.actPanel, "Stand", 90, function() bjAct("stand") end, 28); at(B.stand, B.actPanel, 98, 0)
    B.double = button(B.actPanel, "Double", 90, function() bjAct("double") end, 28); at(B.double, B.actPanel, 196, 0)
    B.split = button(B.actPanel, "Split", 90, function() bjAct("split") end, 28); at(B.split, B.actPanel, 294, 0)
    B.timer = label(B.actPanel, "GameFontNormal"); at(B.timer, B.actPanel, 400, 6); B.timer:SetWidth(300)

    B.msg = label(f, "GameFontHighlight"); at(B.msg, f, 16, 552); B.msg:SetWidth(820)

    local ticker
    f:SetScript("OnShow", function()
        if bjCode then CN.Sync(bjCode) end
        if not ticker and C_Timer and C_Timer.NewTicker then ticker = C_Timer.NewTicker(1, function() UI.Refresh() end) end
        UI.Refresh()
    end)
    f:SetScript("OnHide", function() if ticker then ticker:Cancel(); ticker = nil end end)
end

local function refreshBlackjack()
    local B = bj
    if not (B.frame and B.frame:IsShown()) then return end
    local tc = bjTable()
    if not tc then B.frame:Hide(); return end
    local st = tc.state
    local pub = st and st.bj
    local me = myName(tc)
    B.head:SetText(tc.name or "Blackjack")

    local statusText
    if tc.status == "requested" then statusText = GOLD .. "Waiting for the host to let you in...|r"
    elseif tc.status == "denied" then statusText = RED .. "The host turned down your request.|r"
    elseif tc.status == "removed" then statusText = RED .. "The host removed you from the table.|r"
    elseif tc.status == "left" then statusText = GREY .. "You left the table.|r"
    elseif tc.status == "closed" then statusText = RED .. "This table is closed.|r"
    elseif not st then statusText = GOLD .. "Waiting for the table...|r"
    elseif st.status == "betting" then statusText = GREEN .. "Place your bets|r" .. GREY .. ("   Round %d   %s to %s"):format(st.round, money(st.minBet), money(st.maxBet)) .. "|r"
    elseif st.status == "dealer" then statusText = GOLD .. "The dealer plays...|r"
    elseif pub and pub.turn == me then statusText = GREEN .. "Your turn|r"
    elseif pub and pub.turn then statusText = GOLD .. "Waiting for " .. pub.turn .. "|r"
    else statusText = GOLD .. "Playing...|r" end
    B.status:SetText(statusText)
    B.balance:SetText(("Chips: %s%s|r   on the table: %s"):format(GOLD, money(tc.balance or 0), money(Client.Staked(tc))))

    -- dealer
    if pub and #pub.dealer.cards > 0 then
        B.dealer:SetText(UI.CardsText(pub.dealer.cards) .. (pub.dealer.hidden and "  ??" or ""))
        B.dealerNote:SetText(pub.dealer.value and ("Dealer has " .. pub.dealer.value) or (GREY .. "One card is face down.|r"))
    else
        local last = tc.lastResult and tc.lastResult.dealer
        B.dealer:SetText(last and UI.CardsText(last.cards) or (GREY .. "-|r"))
        B.dealerNote:SetText(last and (GREY .. ("Last round: dealer %d%s"):format(last.total or 0, last.bust and " (bust)" or "") .. "|r") or "")
    end

    -- players
    local hands = pub and pub.hands or {}
    for i, r in ipairs(B.rows) do
        local h = hands[i]
        r.name:SetShown(h ~= nil); r.hands:SetShown(h ~= nil)
        if h then
            local mark = (pub.turn == h.name) and (GOLD .. "> |r") or ""
            r.name:SetText(mark .. (h.name == me and (GOLD .. h.name .. "|r") or h.name))
            r.hands:SetText(UI.HandsText(h.hands))
        end
    end
    B.more:SetText(#hands > BJ_ROWS and (GREY .. ("+%d more"):format(#hands - BJ_ROWS) .. "|r") or
        ((#hands == 0 and st) and (GREY .. "Nobody has bet yet.|r") or ""))

    -- controls
    local canBet = Client.CanBet(tc)
    local myHand = Client.MyTurn(tc, me)
    B.betPanel:SetShown(canBet)
    B.actPanel:SetShown(myHand ~= nil)
    if myHand then
        local mine = Client.MyHands(tc, me) or {}
        local h = mine[myHand]
        local free = tc.balance or 0
        if h then
            if h.aces and h.split then B.hit:Disable() else B.hit:Enable() end
            B.stand:Enable()
            if #h.cards == 2 and not (h.aces and h.split) and free >= (h.bet or 0) then B.double:Enable() else B.double:Disable() end
            if #mine == 1 and Blackjack.CanSplit(h.cards) and free >= (h.bet or 0) then B.split:Enable() else B.split:Disable() end
        end
        local left = pub.deadline and (pub.deadline - GetServerTime()) or nil
        B.timer:SetText(left and (GOLD .. ("%d s left"):format(math.max(0, left)) .. "|r") or "")
    end
    if canBet then
        if Client.Staked(tc) > 0 then B.place:Disable(); B.back:Enable() else B.place:Enable(); B.back:Disable() end
    end
    local mine = Client.MyResult(tc, me)
    if (B.message or "") ~= "" then B.msg:SetText(B.message)
    elseif mine and canBet then
        B.msg:SetText(("Last round: %s%s|r"):format(mine.net >= 0 and GREEN or RED, (mine.net >= 0 and "+" or "") .. money(mine.net)))
    else B.msg:SetText("") end
    if tc.status == "seated" then B.leave:Enable() else B.leave:Disable() end
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

function UI.Refresh()
    refreshLauncher()
    refreshHost()
    refreshTable()
    refreshBlackjack()
end

function UI.OpenHost(code)
    if not host.frame then buildHost() end
    hostCode = ns.Protocol.CanonicalCode(code)
    UI.Hide()                                  -- the launcher steps aside
    host.frame:Show()
    UI.Refresh()
end

function UI.OpenTable(code)
    code = ns.Protocol.CanonicalCode(code)
    UI.Hide()                                  -- the launcher steps aside
    if gameOfCode(code) == "blackjack" then
        if not bj.frame then buildBlackjack() end
        bjCode = code
        bjMessage("")
        bj.frame:Show()
    else
        if not play.frame then buildTable() end
        playCode = code
        picks = {}
        setMessage("")
        play.frame:Show()
    end
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
