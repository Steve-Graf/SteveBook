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
-- The look of the two player windows: dark brown panels with gold edges (the sportsbook's colours)
------------------------------------------------------------------------------------------

local COL = {
    ground = { 0.09, 0.07, 0.05 }, panel = { 0.106, 0.082, 0.055 }, raised = { 0.165, 0.13, 0.085 },
    edge = { 0.48, 0.39, 0.19 }, line = { 0.23, 0.18, 0.11 }, sel = { 0.29, 0.23, 0.11 }, gold = { 1, 0.82, 0 },
}
local MUTED = "|cffb9ab8c"

local function fill(tex, c, a) paint(tex, c[1], c[2], c[3], a or 1) end

-- A flat box with a one-pixel edge; its children draw above it.
local function panel(parent, x, y, w, h, fillColor, edgeColor)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    f.edge = f:CreateTexture(nil, "BACKGROUND"); f.edge:SetAllPoints(); fill(f.edge, edgeColor or COL.line)
    f.fill = f:CreateTexture(nil, "BORDER")
    f.fill:SetPoint("TOPLEFT", 1, -1); f.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    fill(f.fill, fillColor or COL.panel)
    return f
end

-- A flat button: text in the middle, an optional tag (like "2:1") at the right. State: "normal",
-- "selected" (gold edge) or "off".
local function flat(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.edge = b:CreateTexture(nil, "BACKGROUND"); b.edge:SetAllPoints()
    b.fill = b:CreateTexture(nil, "BORDER"); b.fill:SetPoint("TOPLEFT", 1, -1); b.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    b.text = label(b, "GameFontHighlightSmall", "CENTER"); b.text:SetPoint("CENTER"); b.text:SetText(text)
    b.tag = label(b, "GameFontNormalSmall", "RIGHT"); b.tag:SetPoint("RIGHT", -6, 0)
    b.state = "normal"
    function b:Paint(state)
        self.state = state or self.state
        local f, e = COL.raised, COL.edge
        if self.state == "selected" then f, e = COL.sel, COL.gold
        elseif self.state == "off" then f, e = COL.panel, COL.line end
        if self.hover then f = { f[1] + 0.07, f[2] + 0.06, f[3] + 0.04 } end
        fill(self.edge, e); fill(self.fill, f)
    end
    b:SetScript("OnEnter", function(self) self.hover = true; self:Paint() end)
    b:SetScript("OnLeave", function(self) self.hover = false; self:Paint() end)
    b:SetScript("OnClick", onClick)
    b:Paint("normal")
    return b
end

-- A window with the dark body panel already in it. Returns the frame and the body.
local function playerWindow(name, w, h, title, anchor)
    local f = newWindow(name, w, h, title, anchor)
    casinoButton(f)
    local body = panel(f, 6, 28, w - 12, h - 34, COL.ground, COL.edge)
    return f, body
end

local STAKE_BUTTONS = { 100, 500, 1000, 5000, 10000 }
local amount = Odds.STAKE_STEP                 -- the stake a new pick or bet starts with

-- Parse a stake box. Returns copper, or nil (after saying why through `complain`).
local function parseStake(text, complain)
    local c = Odds.ParseMoney(text or "")
    if not c or c <= 0 then complain("Enter a stake like 5s."); return nil end
    return c
end

------------------------------------------------------------------------------------------
-- Player window: roulette (bet slip)
------------------------------------------------------------------------------------------

local play = {}
local playCode
local betMode = "straight"            -- straight | split | street | corner | sixline
local MODE_SIZE = { straight = 1, split = 2, street = 3, corner = 4, sixline = 6 }
local MODE_TITLE = { straight = "Straight", split = "Split", street = "Street", corner = "Corner", sixline = "Six line" }
local KIND_NAME = { straight = "Straight", split = "Split", street = "Street", corner = "Corner", sixline = "Six line" }
local ORDINAL = { "1st", "2nd", "3rd" }
local picks = {}                      -- numbers chosen so far for a multi-number bet
local slip = {}                       -- the bet slip: { kind, numbers?, pick?, amount }
local MAX_SLIP = 7
local message = ""

local function playTable()
    return playCode and db() and db().casinoCache and Client.Table(db().casinoCache, playCode)
end

local function setMessage(text)
    message = text or ""
    if play.msg then play.msg:SetText(message) end
end

local function pickName(b)
    if b.numbers then
        local parts = {}
        for i, n in ipairs(b.numbers) do parts[i] = Roulette.Label(n) end
        table.sort(parts, function(x, y) return tonumber(x) < tonumber(y) end)
        return KIND_NAME[b.kind] .. " " .. table.concat(parts, ", ")
    end
    if b.kind == "dozen" then return ORDINAL[b.pick] .. " dozen" end
    if b.kind == "column" then return ORDINAL[b.pick] .. " column" end
    if b.kind == "low" then return "1-18" end
    if b.kind == "high" then return "19-36" end
    return b.kind:sub(1, 1):upper() .. b.kind:sub(2)
end

local function betKey(b)
    return b.kind .. ":" .. (b.numbers and table.concat(b.numbers, ",") or "") .. ":" .. tostring(b.pick or "")
end

local function slipTotal()
    local n = 0
    for _, b in ipairs(slip) do n = n + b.amount end
    return n
end

function UI.SetMode(m)
    if not MODE_SIZE[m] then return end
    betMode = m
    picks = {}
    UI.Refresh()
end

function UI.SetAmount(copper)
    amount = copper
    if play.amountBox then play.amountBox:SetText(money(copper)) end
end

local function currentAmount()
    if not play.amountBox then return amount end
    local c = parseStake(play.amountBox:GetText(), function(m) setMessage(RED .. m .. "|r") end)
    if c then amount = c end
    return c
end

-- Put a bet on the slip, or take it off again if it is already there.
local function togglePick(bet)
    local a = currentAmount(); if not a then return end
    bet.amount = a
    local key = betKey(bet)
    for i, b in ipairs(slip) do
        if betKey(b) == key then table.remove(slip, i); setMessage(""); UI.Refresh(); return end
    end
    if #slip >= MAX_SLIP then
        setMessage(RED .. ("The slip holds %d picks. Place or clear some first."):format(MAX_SLIP) .. "|r")
        return
    end
    slip[#slip + 1] = bet
    setMessage("")
    UI.Refresh()
end

-- A click on a pocket: a straight bet, or one more number toward a split / street / corner / six line.
function UI.PickNumber(n)
    if betMode == "straight" then return togglePick({ kind = "straight", numbers = { n } }) end
    for i, x in ipairs(picks) do
        if x == n then table.remove(picks, i); UI.Refresh(); return end        -- click again to drop it
    end
    picks[#picks + 1] = n
    if #picks == MODE_SIZE[betMode] then
        local bet = { kind = betMode, numbers = picks }
        picks = {}
        local tc = playTable()
        local ok, _, msg = Roulette.ValidateBet({ kind = bet.kind, numbers = bet.numbers, amount = 1 }, tc and tc.state and tc.state.zero or "single")
        if ok then togglePick(bet) else setMessage(RED .. (msg or "Those numbers do not make that bet.") .. "|r"); UI.Refresh() end
        return
    end
    UI.Refresh()
end

function UI.PickOutside(kind, pick) togglePick({ kind = kind, pick = pick }) end

function UI.Slip() return slip end

function UI.ClearSlip() slip = {}; picks = {}; setMessage(""); UI.Refresh() end

-- Change the stake of one pick (the stake boxes call this as you type).
function UI.SetStake(i, copper)
    if slip[i] and copper and copper > 0 then slip[i].amount = copper end
    UI.Refresh()
end

function UI.SetAllStakes(copper)
    for _, b in ipairs(slip) do b.amount = copper end
    UI.Refresh()
end

-- Load last round's bets onto the slip.
function UI.SameAsLast()
    local tc = playTable()
    if not (tc and tc.prevBets and #tc.prevBets > 0) then return setMessage(RED .. "There are no bets from last round to repeat.|r") end
    slip = {}
    for _, b in ipairs(tc.prevBets) do
        if #slip < MAX_SLIP then
            local c = { kind = b.kind, pick = b.pick, amount = b.amount }
            if b.numbers then c.numbers = {}; for i, n in ipairs(b.numbers) do c.numbers[i] = n end end
            slip[#slip + 1] = c
        end
    end
    setMessage("")
    UI.Refresh()
end

-- Place every pick on the slip. All of them are checked first, so a slip that cannot be covered
-- places nothing.
function UI.PlaceSlip()
    local tc = playTable()
    if not Client.CanBet(tc) then return setMessage(RED .. "Betting is closed right now.|r") end
    if #slip == 0 then return setMessage(RED .. "Pick something to bet on first.|r") end
    local st = tc.state
    for _, b in ipairs(slip) do
        if b.amount < st.minBet then return setMessage(RED .. ("%s: the minimum bet is %s."):format(pickName(b), money(st.minBet)) .. "|r") end
        if b.amount > st.maxBet then return setMessage(RED .. ("%s: the maximum bet is %s."):format(pickName(b), money(st.maxBet)) .. "|r") end
        if b.amount % Odds.STAKE_STEP ~= 0 then return setMessage(RED .. pickName(b) .. ": stakes are whole silver.|r") end
    end
    local waiting = 0
    for _, p in pairs(tc.pending) do waiting = waiting + p.bet.amount end
    if slipTotal() > (tc.balance or 0) - waiting then
        return setMessage(RED .. ("The slip is %s but you only have %s in chips."):format(money(slipTotal()), money(math.max(0, (tc.balance or 0) - waiting))) .. "|r")
    end
    while #slip > 0 do
        local ok, err = CN.PlaceBet(playCode, slip[1])
        if not ok then return setMessage(RED .. err .. "|r") end
        table.remove(slip, 1)
    end
    setMessage("")
    UI.Refresh()
end

local OUTSIDE_ROWS = {
    { { "dozen", 1, "1st dozen", "2:1" }, { "dozen", 2, "2nd dozen", "2:1" }, { "dozen", 3, "3rd dozen", "2:1" } },
    { { "column", 1, "1st column", "2:1" }, { "column", 2, "2nd column", "2:1" }, { "column", 3, "3rd column", "2:1" } },
}
local EVEN_MONEY = { { "low", nil, "1-18" }, { "even", nil, "Even" }, { "red", nil, "Red" }, { "black", nil, "Black" }, { "odd", nil, "Odd" }, { "high", nil, "19-36" } }

local function numberCell(parent, n, x, y, w, h)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(w, h)
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    c.edge = c:CreateTexture(nil, "BACKGROUND"); c.edge:SetAllPoints(); fill(c.edge, COL.edge)
    c.bg = c:CreateTexture(nil, "BORDER"); c.bg:SetPoint("TOPLEFT", 1, -1); c.bg:SetPoint("BOTTOMRIGHT", -1, 1)
    local col = Roulette.Color(n)
    c.base = col == "red" and { 0.56, 0.11, 0.11 } or (col == "green" and { 0.04, 0.35, 0.16 } or { 0.05, 0.04, 0.03 })
    fill(c.bg, c.base)
    c.mark = c:CreateTexture(nil, "ARTWORK"); c.mark:SetPoint("TOPLEFT", 1, -1); c.mark:SetPoint("BOTTOMRIGHT", -1, 1); paint(c.mark, 1, 0.82, 0, 0)
    c.text = label(c, "GameFontNormal", "CENTER"); c.text:SetPoint("CENTER", 0, 4); c.text:SetText("|cffffffff" .. Roulette.Label(n) .. "|r")
    c.stake = label(c, "GameFontHighlightSmall", "CENTER"); c.stake:SetPoint("BOTTOM", 0, 2)
    c.n = n
    c:SetScript("OnClick", function() UI.PickNumber(n) end)
    c:SetScript("OnEnter", function(self) fill(self.bg, { self.base[1] + 0.12, self.base[2] + 0.12, self.base[3] + 0.12 }) end)
    c:SetScript("OnLeave", function(self) fill(self.bg, self.base) end)
    return c
end

local function buildTable()
    local P = play
    local f, body = playerWindow("SteveBookCasinoTableFrame", 900, 640, "SteveBook Casino", { "TOPRIGHT", -40, -70 })
    P.frame, P.body = f, body

    P.head = label(body, "GameFontNormalLarge"); at(P.head, body, 14, 8); P.head:SetWidth(340)
    P.status = label(body, "GameFontHighlight"); at(P.status, body, 14, 32); P.status:SetWidth(560)
    P.balance = label(body, "GameFontHighlight", "RIGHT"); at(P.balance, body, 330, 10); P.balance:SetWidth(430)
    P.leave = button(body, "Leave table", 100, function() if playCode then CN.Leave(playCode) end end, 22)
    at(P.leave, body, 772, 6)

    -- numbers
    local nl = label(body, "GameFontNormal"); at(nl, body, 14, 62); nl:SetText("Numbers")
    P.modes = {}
    local mx = 216
    for _, m in ipairs({ "straight", "split", "street", "corner", "sixline" }) do
        local b = flat(body, MODE_TITLE[m], 64, 22, function() UI.SetMode(m) end)
        at(b, body, mx, 58); mx = mx + 68
        P.modes[m] = b
    end
    local bx, by = 14, 88
    P.cells = {}
    P.zero = numberCell(body, 0, bx, by, 40, 122); P.cells[0] = P.zero
    P.dzero = numberCell(body, Roulette.DOUBLE_ZERO, bx, by + 61, 40, 61); P.cells[Roulette.DOUBLE_ZERO] = P.dzero
    for n = 1, 36 do
        local colIdx = math.ceil(n / 3)               -- 1..12
        local rowIdx = 2 - (n - 1) % 3                -- 0 = top row
        P.cells[n] = numberCell(body, n, bx + 42 * colIdx, by + 42 * rowIdx, 40, 40)
    end

    -- outside bets
    local ol = label(body, "GameFontNormal"); at(ol, body, 14, 222); ol:SetText("Outside bets")
    P.outside = {}
    for r, row in ipairs(OUTSIDE_ROWS) do
        for i, o in ipairs(row) do
            local b = flat(body, o[3], 172, 30, function() UI.PickOutside(o[1], o[2]) end)
            b.text:ClearAllPoints(); b.text:SetPoint("LEFT", 10, 0); b.text:SetJustifyH("LEFT")
            b.tag:SetText(o[4])
            at(b, body, 14 + (i - 1) * 176, 244 + (r - 1) * 34)
            P.outside[#P.outside + 1] = { cell = b, kind = o[1], pick = o[2] }
        end
    end
    for i, o in ipairs(EVEN_MONEY) do
        local b = flat(body, o[3], 85, 30, function() UI.PickOutside(o[1], o[2]) end)
        at(b, body, 14 + (i - 1) * 88, 312)
        P.outside[#P.outside + 1] = { cell = b, kind = o[1], pick = o[2] }
    end
    P.hint = label(body, "GameFontHighlightSmall"); at(P.hint, body, 14, 350); P.hint:SetWidth(540); P.hint:SetWordWrap(true)

    -- stake for new picks
    local sl = label(body, "GameFontNormal"); at(sl, body, 14, 384); sl:SetText("Stake for a new pick")
    P.amountBox = editBox(body, 70, money(amount), 12); at(P.amountBox, body, 160, 380)
    local qx = 238
    for _, v in ipairs(STAKE_BUTTONS) do
        local b = button(body, money(v), 46, function() UI.SetAmount(v) end, 22)
        at(b, body, qx, 380); qx = qx + 50
    end
    P.msg = label(body, "GameFontHighlight"); at(P.msg, body, 14, 410); P.msg:SetWidth(560); P.msg:SetWordWrap(true)

    -- last spin and the table
    local lp = panel(body, 14, 440, 270, 150, COL.panel, COL.line)
    local ll = label(lp, "GameFontNormal"); at(ll, lp, 10, 8); ll:SetText("Last spin")
    P.number = label(lp, "GameFontNormalHuge", "LEFT"); at(P.number, lp, 10, 30)
    P.numberNote = label(lp, "GameFontHighlightSmall"); at(P.numberNote, lp, 80, 40); P.numberNote:SetWidth(180)
    P.history = label(lp, "GameFontHighlightSmall"); at(P.history, lp, 10, 84); P.history:SetWidth(250); P.history:SetWordWrap(true)
    local tp = panel(body, 294, 440, 270, 150, COL.panel, COL.line)
    local tl = label(tp, "GameFontNormal"); at(tl, tp, 10, 8); tl:SetText("At the table")
    P.seats = label(tp, "GameFontHighlightSmall"); at(P.seats, tp, 10, 30); P.seats:SetWidth(250)
    P.seats:SetWordWrap(true); P.seats:SetJustifyV("TOP"); P.seats:SetHeight(112)

    -- the slip
    local sp = panel(body, 580, 40, 296, 556, COL.panel, COL.edge)
    P.slipPanel = sp
    local st = label(sp, "GameFontNormalLarge"); at(st, sp, 12, 10); st:SetText("Bet slip")
    P.slipCount = label(sp, "GameFontHighlightSmall", "RIGHT"); at(P.slipCount, sp, 150, 14); P.slipCount:SetWidth(134)
    P.rows = {}
    for i = 1, MAX_SLIP do
        local y = 38 + (i - 1) * 44
        local r = {}
        r.frame = panel(sp, 10, y, 276, 40, COL.raised, COL.line)
        r.name = label(r.frame, "GameFontHighlight"); at(r.name, r.frame, 8, 5); r.name:SetWidth(150); r.name:SetWordWrap(false)
        r.pays = label(r.frame, "GameFontHighlightSmall"); at(r.pays, r.frame, 8, 22); r.pays:SetWidth(170); r.pays:SetWordWrap(false)
        r.box = editBox(r.frame, 52, "", 10); at(r.box, r.frame, 182, 9)
        r.box:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then return end                          -- only what the player types
            local c = Odds.ParseMoney(self:GetText())
            if c and c > 0 and slip[i] then slip[i].amount = c; UI.Refresh() end
        end)
        r.remove = button(r.frame, "x", 22, function() table.remove(slip, i); UI.Refresh() end, 22)
        at(r.remove, r.frame, 244, 9)
        P.rows[i] = r
    end
    P.slipEmpty = label(sp, "GameFontHighlightSmall"); at(P.slipEmpty, sp, 14, 46); P.slipEmpty:SetWidth(266); P.slipEmpty:SetWordWrap(true)
    P.slipEmpty:SetText(MUTED .. "Click what you want to bet on. Each pick goes onto the slip; set the stakes here, then place everything with one click. A zero loses every outside bet.|r")
    local al = label(sp, "GameFontHighlightSmall"); at(al, sp, 12, 354); al:SetText(MUTED .. "Set all to|r")
    local ax = 80
    for _, v in ipairs({ 100, 500, 1000 }) do
        local b = flat(sp, money(v), 44, 22, function() UI.SetAllStakes(v) end)
        at(b, sp, ax, 350); ax = ax + 48
    end
    P.totalStake = label(sp, "GameFontHighlight"); at(P.totalStake, sp, 12, 388); P.totalStake:SetWidth(272)
    P.after = label(sp, "GameFontHighlightSmall"); at(P.after, sp, 12, 408); P.after:SetWidth(272)
    P.place = button(sp, "Place bets", 272, function() UI.PlaceSlip() end, 32)
    at(P.place, sp, 12, 432)
    P.same = button(sp, "Same as last round", 134, function() UI.SameAsLast() end, 22); at(P.same, sp, 12, 472)
    P.clearSlip = button(sp, "Clear slip", 134, function() UI.ClearSlip() end, 22); at(P.clearSlip, sp, 150, 472)
    local on = label(sp, "GameFontNormal"); at(on, sp, 12, 508); on:SetText("On the table")
    P.onTable = label(sp, "GameFontHighlightSmall"); at(P.onTable, sp, 12, 528); P.onTable:SetWidth(150)
    P.clear = button(sp, "Take all back", 110, function()
        local ok, err = CN.ClearBets(playCode)
        if not ok then setMessage(RED .. err .. "|r") end
    end, 22)
    at(P.clear, sp, 174, 524)

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
    local zero = st and st.zero or "single"
    local statusText
    if tc.status == "requested" then statusText = GOLD .. "Waiting for the host to let you in...|r"
    elseif tc.status == "denied" then statusText = RED .. "The host turned down your request.|r"
    elseif tc.status == "removed" then statusText = RED .. "The host removed you from the table.|r"
    elseif tc.status == "left" then statusText = GREY .. "You left the table.|r"
    elseif tc.status == "closed" then statusText = RED .. "This table is closed.|r"
    elseif not st then statusText = GOLD .. "Waiting for the table...|r"
    elseif st.status == "spinning" then statusText = GOLD .. "No more bets: the wheel is spinning...|r"
    else statusText = GREEN .. "Taking bets|r" .. MUTED .. ("   Round %d   %s to %s   %s"):format(st.round, money(st.minBet), money(st.maxBet),
        ({ single = "single zero", double = "double zero", none = "no zero" })[zero]) .. "|r" end
    P.status:SetText(statusText)
    P.balance:SetText(("Chips %s%s|r   %son the table %s|r"):format(GOLD, money(tc.balance or 0), MUTED, money(Client.Staked(tc))))

    -- zero cells follow the wheel
    P.zero:SetShown(zero ~= "none")
    if zero == "double" then
        P.zero:SetSize(40, 61)
        P.dzero:Show()
    else
        P.zero:SetSize(40, 122)
        P.dzero:Hide()
    end

    -- what is on the table (confirmed) and what is on the slip
    local straight, outside = stakedOn(tc)
    local inSlip, inProgress = {}, {}
    for _, b in ipairs(slip) do inSlip[betKey(b)] = true end
    for _, n in ipairs(picks) do inProgress[n] = true end
    for n, c in pairs(P.cells) do
        local s = straight[n]
        c.stake:SetText(s and (GOLD .. shortMoney(s) .. "|r") or "")
        local mark = inProgress[n] and 0.55 or (inSlip[betKey({ kind = "straight", numbers = { n } })] and 0.45 or (s and 0.2 or 0))
        paint(c.mark, 1, 0.82, 0, mark)
    end
    for _, o in ipairs(P.outside) do
        local b = { kind = o.kind, pick = o.pick }
        local key = o.pick and (o.kind .. o.pick) or o.kind
        o.cell.tag:SetText(outside[key] and (GOLD .. shortMoney(outside[key]) .. "|r") or (o.pick and MUTED .. "2:1|r" or ""))
        o.cell:Paint(inSlip[betKey(b)] and "selected" or "normal")
    end
    for m, b in pairs(P.modes) do b:Paint(m == betMode and "selected" or "normal") end
    if betMode == "straight" then
        P.hint:SetText(MUTED .. "Click a number or a bet to put it on the slip; click again to take it off.|r")
    else
        P.hint:SetText(MUTED .. ("Pick %d numbers that touch (%d chosen). Click a chosen number again to drop it."):format(MODE_SIZE[betMode], #picks) .. "|r")
    end

    -- last spin, table
    local last = tc.lastResult
    if last and last.number then
        P.number:SetText(colored(last.number))
        local mine = Client.MyResult(tc, myName(tc))
        P.numberNote:SetText(Roulette.Color(last.number) .. (mine and ("\n" .. (mine.net >= 0 and GREEN or RED) .. (mine.net >= 0 and "You won +" or "You lost ") .. money(math.abs(mine.net)) .. "|r") or ""))
    else
        P.number:SetText(GREY .. "-|r"); P.numberNote:SetText("")
    end
    P.history:SetText(historyText(st and st.history))
    local seats = {}
    for _, s in ipairs(st and st.seats or {}) do
        seats[#seats + 1] = (s.name == myName(tc) and (GOLD .. s.name .. "|r") or s.name) .. "   " .. money(s.balance)
    end
    P.seats:SetText(#seats > 0 and table.concat(seats, "\n") or (GREY .. "nobody yet|r"))

    -- the slip
    for i, r in ipairs(P.rows) do
        local b = slip[i]
        r.frame:SetShown(b ~= nil)
        if b then
            r.name:SetText(pickName(b))
            local pay = Roulette.PAYOUT[b.kind]
            r.pays:SetText(MUTED .. ("pays %d:1   to win %s"):format(pay, money(b.amount * pay)) .. "|r")
            if not r.box:HasFocus() and r.box:GetText() ~= money(b.amount) then r.box:SetText(money(b.amount)) end
        end
    end
    P.slipEmpty:SetShown(#slip == 0)
    P.slipCount:SetText(MUTED .. (#slip == 1 and "1 pick" or (#slip .. " picks")) .. "|r")
    local total = slipTotal()
    P.totalStake:SetText(("Total stake   %s%s|r"):format(GOLD, money(total)))
    P.after:SetText(MUTED .. "Chips left after   " .. money((tc.balance or 0) - total) .. "|r")
    P.place:SetText(#slip == 0 and "Place bets" or (#slip == 1 and "Place 1 bet" or ("Place " .. #slip .. " bets")))
    local can = Client.CanBet(tc)
    if can and #slip > 0 then P.place:Enable() else P.place:Disable() end
    if can then P.clear:Enable() else P.clear:Disable() end
    if can and tc.prevBets and #tc.prevBets > 0 then P.same:Enable() else P.same:Disable() end
    if #slip > 0 then P.clearSlip:Enable() else P.clearSlip:Disable() end
    local nb = #tc.bets
    P.onTable:SetText(nb > 0 and (money(Client.Staked(tc)) .. " in " .. nb .. (nb == 1 and " bet" or " bets")) or (GREY .. "nothing yet|r"))
    P.msg:SetText(message)
    if tc.status == "seated" then P.leave:Enable() else P.leave:Disable() end
end

------------------------------------------------------------------------------------------
-- Cards (the host window uses these helpers too)
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

-- A playing card: a white rectangle with the rank on top and the suit letter below (red for hearts
-- and diamonds), or a dark back with a gold edge when it is face down.
local function newCard(parent, w, h)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(w, h)
    c.edge = c:CreateTexture(nil, "BACKGROUND"); c.edge:SetAllPoints(); fill(c.edge, { 0.55, 0.52, 0.46 })
    c.face = c:CreateTexture(nil, "BORDER"); c.face:SetPoint("TOPLEFT", 1, -1); c.face:SetPoint("BOTTOMRIGHT", -1, 1)
    c.rank = label(c, "GameFontNormalLarge", "CENTER"); c.rank:SetPoint("CENTER", 0, 7)
    c.suit = label(c, "GameFontNormalSmall", "CENTER"); c.suit:SetPoint("BOTTOM", 0, 4)
    return c
end

local function showCard(c, card, down, x, y, parent)
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    if down then
        fill(c.edge, COL.gold); fill(c.face, { 0.27, 0.18, 0.08 })
        c.rank:SetText(GOLD .. "?|r"); c.suit:SetText("")
    elseif card then
        fill(c.edge, { 0.55, 0.52, 0.46 }); fill(c.face, { 0.96, 0.95, 0.92 })
        local suit = card:sub(2, 2)
        local ink = (suit == "H" or suit == "D") and "|cffb3201f" or "|cff111111"
        c.rank:SetText(ink .. Blackjack.RankLabel(card) .. "|r"); c.suit:SetText(ink .. suit .. "|r")
    end
    c:Show()
end

------------------------------------------------------------------------------------------
-- Player window: blackjack (seat rows)
------------------------------------------------------------------------------------------

local bj = {}
local bjCode
local BJ_ROWS, BJ_CARDS = 5, 8

local function bjTable() return bjCode and db() and db().casinoCache and Client.Table(db().casinoCache, bjCode) end

local function bjMessage(text) bj.message = text or ""; if bj.msg then bj.msg:SetText(bj.message) end end

local function bjAct(action)
    local ok, err = CN.Act(bjCode, action)
    if not ok then bjMessage(RED .. err .. "|r") else bjMessage("") end
end

local function chipFrame(parent, w)
    local c = panel(parent, 0, 0, w, 26, COL.raised, COL.edge)
    c.text = label(c, "GameFontNormalSmall", "CENTER"); c.text:SetPoint("CENTER")
    return c
end

local function buildBlackjack()
    local B = bj
    local f, body = playerWindow("SteveBookBlackjackFrame", 900, 640, "SteveBook Casino", { "TOPRIGHT", -40, -70 })
    B.frame, B.body = f, body

    B.head = label(body, "GameFontNormalLarge"); at(B.head, body, 14, 8); B.head:SetWidth(340)
    B.status = label(body, "GameFontHighlight"); at(B.status, body, 14, 32); B.status:SetWidth(580)
    B.balance = label(body, "GameFontHighlight", "RIGHT"); at(B.balance, body, 330, 10); B.balance:SetWidth(430)
    B.leave = button(body, "Leave table", 100, function() if bjCode then CN.Leave(bjCode) end end, 22)
    at(B.leave, body, 772, 6)

    -- dealer
    B.dealerBox = panel(body, 14, 56, 600, 92, COL.panel, COL.line)
    local d = B.dealerBox
    local dl = label(d, "GameFontNormal"); at(dl, d, 12, 12); dl:SetText("Dealer")
    local dn = label(d, "GameFontHighlightSmall"); at(dn, d, 12, 32); dn:SetText(MUTED .. "stands on 17|r")
    B.dealerCards = {}
    for i = 1, 6 do B.dealerCards[i] = newCard(d, 44, 62) end
    B.dealerNote = label(d, "GameFontHighlightSmall", "RIGHT"); at(B.dealerNote, d, 410, 36); B.dealerNote:SetWidth(180)
    B.round = label(d, "GameFontHighlightSmall", "RIGHT"); at(B.round, d, 410, 12); B.round:SetWidth(180)

    -- seats
    B.rows = {}
    for i = 1, BJ_ROWS do
        local y = 158 + (i - 1) * 68
        local r = {}
        r.frame = panel(body, 14, y, 600, 62, COL.panel, COL.line)
        r.name = label(r.frame, "GameFontHighlight"); at(r.name, r.frame, 12, 10); r.name:SetWidth(84); r.name:SetWordWrap(false)
        r.chips = label(r.frame, "GameFontHighlightSmall"); at(r.chips, r.frame, 12, 32); r.chips:SetWidth(84); r.chips:SetWordWrap(false)
        r.bet = chipFrame(r.frame, 52); r.bet:ClearAllPoints(); r.bet:SetPoint("TOPLEFT", r.frame, "TOPLEFT", 100, -18)
        r.cards = {}
        for k = 1, BJ_CARDS do r.cards[k] = newCard(r.frame, 34, 48) end
        r.badge = label(r.frame, "GameFontNormal", "CENTER"); at(r.badge, r.frame, 496, 12); r.badge:SetWidth(96)
        r.note = label(r.frame, "GameFontHighlightSmall", "CENTER"); at(r.note, r.frame, 496, 36); r.note:SetWidth(96)
        B.rows[i] = r
    end
    B.more = label(body, "GameFontHighlightSmall"); at(B.more, body, 14, 158 + BJ_ROWS * 68 - 2)

    -- my decision
    B.act = panel(body, 14, 508, 600, 88, COL.panel, COL.edge)
    local a = B.act
    B.actTitle = label(a, "GameFontNormal"); at(B.actTitle, a, 12, 10)
    B.timer = label(a, "GameFontNormal", "RIGHT"); at(B.timer, a, 400, 10); B.timer:SetWidth(188)
    B.barTrack = a:CreateTexture(nil, "BORDER"); B.barTrack:SetPoint("TOPLEFT", a, "TOPLEFT", 12, -32); B.barTrack:SetSize(576, 6); fill(B.barTrack, COL.raised)
    B.barFill = a:CreateTexture(nil, "ARTWORK"); B.barFill:SetPoint("TOPLEFT", a, "TOPLEFT", 12, -32); B.barFill:SetSize(576, 6); fill(B.barFill, COL.gold)
    B.hit = button(a, "Hit", 138, function() bjAct("hit") end, 30); at(B.hit, a, 12, 48)
    B.stand = button(a, "Stand", 138, function() bjAct("stand") end, 30); at(B.stand, a, 156, 48)
    B.double = button(a, "Double", 138, function() bjAct("double") end, 30); at(B.double, a, 300, 48)
    B.split = button(a, "Split", 138, function() bjAct("split") end, 30); at(B.split, a, 444, 48)
    B.waiting = label(a, "GameFontHighlight"); at(B.waiting, a, 12, 52); B.waiting:SetWidth(570)

    -- next round and the log
    B.next = panel(body, 626, 56, 250, 196, COL.panel, COL.line)
    local n = B.next
    local nt = label(n, "GameFontNormal"); at(nt, n, 12, 10); nt:SetText("Your bet")
    B.betNote = label(n, "GameFontHighlightSmall"); at(B.betNote, n, 12, 30); B.betNote:SetWidth(226); B.betNote:SetWordWrap(true)
    local qx = 12
    for _, v in ipairs({ 100, 500, 1000, 10000 }) do
        local b = flat(n, money(v), 50, 24, function() amount = v; B.amountBox:SetText(money(v)) end)
        at(b, n, qx, 66); qx = qx + 54
    end
    B.amountBox = editBox(n, 80, money(amount), 12); at(B.amountBox, n, 12, 100)
    B.place = button(n, "Place bet", 134, function()
        local c = parseStake(B.amountBox:GetText(), function(m) bjMessage(RED .. m .. "|r") end)
        if not c then return end
        local ok, err = CN.Wager(bjCode, c)
        if not ok then bjMessage(RED .. err .. "|r") else bjMessage("") end
    end, 24)
    at(B.place, n, 104, 99)
    B.back = button(n, "Take it back", 226, function()
        local ok, err = CN.ClearBets(bjCode)
        if not ok then bjMessage(RED .. err .. "|r") end
    end, 24)
    at(B.back, n, 12, 134)
    B.msg = label(n, "GameFontHighlightSmall"); at(B.msg, n, 12, 164); B.msg:SetWidth(226); B.msg:SetWordWrap(true)

    B.logBox = panel(body, 626, 262, 250, 334, COL.panel, COL.line)
    local lt = label(B.logBox, "GameFontNormal"); at(lt, B.logBox, 12, 10); lt:SetText("Table log")
    B.log = label(B.logBox, "GameFontHighlightSmall"); at(B.log, B.logBox, 12, 32); B.log:SetWidth(226)
    B.log:SetWordWrap(true); B.log:SetJustifyV("TOP"); B.log:SetHeight(292)

    local ticker
    f:SetScript("OnShow", function()
        if bjCode then CN.Sync(bjCode) end
        if not ticker and C_Timer and C_Timer.NewTicker then ticker = C_Timer.NewTicker(1, function() UI.Refresh() end) end
        UI.Refresh()
    end)
    f:SetScript("OnHide", function() if ticker then ticker:Cancel(); ticker = nil end end)
end

local function signed(c) return (c >= 0 and GREEN .. "+" or RED .. "-") .. money(math.abs(c)) .. "|r" end

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
    elseif st.status == "betting" then statusText = GREEN .. "Place your bets|r" .. MUTED .. ("   Round %d   %s to %s"):format(st.round, money(st.minBet), money(st.maxBet)) .. "|r"
    elseif st.status == "dealer" then statusText = GOLD .. "The dealer plays...|r"
    elseif pub and pub.turn == me then statusText = GREEN .. "Your turn|r"
    elseif pub and pub.turn then statusText = GOLD .. "Waiting for " .. pub.turn .. "|r"
    else statusText = GOLD .. "Playing...|r" end
    B.status:SetText(statusText)
    B.balance:SetText(("Chips %s%s|r   %son the table %s|r"):format(GOLD, money(tc.balance or 0), MUTED, money(Client.Staked(tc))))

    -- dealer
    local dcards, hidden = {}, false
    if pub and #pub.dealer.cards > 0 then dcards, hidden = pub.dealer.cards, pub.dealer.hidden
    elseif tc.lastResult and tc.lastResult.dealer then dcards = tc.lastResult.dealer.cards end
    for i, c in ipairs(B.dealerCards) do
        if dcards[i] then showCard(c, dcards[i], false, 110 + (i - 1) * 50, 14, B.dealerBox)
        elseif hidden and i == #dcards + 1 then showCard(c, nil, true, 110 + (i - 1) * 50, 14, B.dealerBox)
        else c:Hide() end
    end
    if pub and #pub.dealer.cards > 0 then
        B.dealerNote:SetText(pub.dealer.value and ("Dealer has " .. pub.dealer.value) or (MUTED .. "showing " .. Blackjack.Points(Blackjack.Rank(pub.dealer.cards[1])) .. "|r"))
    else
        local last = tc.lastResult and tc.lastResult.dealer
        B.dealerNote:SetText(last and (MUTED .. ("Last round: dealer %d%s"):format(last.total or 0, last.bust and " (bust)" or "") .. "|r") or "")
    end
    B.round:SetText(st and (MUTED .. ("Round %d   shoe %d"):format(st.round, pub and pub.shoe or 0) .. "|r") or "")

    -- seats
    local hands = pub and pub.hands or {}
    local seatChips = {}
    for _, s in ipairs(st and st.seats or {}) do seatChips[s.name] = s.balance end
    for i, r in ipairs(B.rows) do
        local h = hands[i]
        r.frame:SetShown(h ~= nil)
        if h then
            local mine = h.name == me
            fill(r.frame.fill, mine and { 0.14, 0.11, 0.06 } or COL.panel)
            fill(r.frame.edge, mine and COL.gold or COL.line)
            r.name:SetText((pub.turn == h.name and (GOLD .. "> |r") or "") .. (mine and (GOLD .. "You|r") or h.name))
            r.chips:SetText(MUTED .. (seatChips[h.name] and money(seatChips[h.name]) or "") .. "|r")
            local bet, x = 0, 160
            local values, state = {}, nil
            local k = 0
            for hi, hand in ipairs(h.hands) do
                bet = bet + (hand.bet or 0)
                if hand.value then values[#values + 1] = (hand.soft and hand.value <= 21 and "soft " or "") .. hand.value end
                state = state or hand.state
                for _, card in ipairs(hand.cards) do
                    k = k + 1
                    if r.cards[k] then showCard(r.cards[k], card, false, x, 7, r.frame); x = x + 38 end
                end
                x = x + 10
            end
            for j = k + 1, BJ_CARDS do r.cards[j]:Hide() end
            r.bet.text:SetText(GOLD .. shortMoney(bet) .. "|r")
            local one = #h.hands == 1 and h.hands[1] or nil
            if one and (one.state == "bust" or one.state == "blackjack") then
                r.badge:SetText(one.state == "bust" and (RED .. "BUST|r") or (GREEN .. "BLACKJACK|r"))
            else
                r.badge:SetText(#values > 0 and table.concat(values, " | ") or (MUTED .. "bet|r"))
            end
            local note = ""
            if pub.turn == h.name then note = GOLD .. (mine and "your turn" or "thinking...") .. "|r"
            elseif one and one.state == "stand" then note = MUTED .. "stands|r"
            elseif one and one.state == "bet" then note = MUTED .. "bet placed|r" end
            r.note:SetText(note)
        end
    end
    B.more:SetText(#hands > BJ_ROWS and (GREY .. ("+%d more players"):format(#hands - BJ_ROWS) .. "|r") or
        ((#hands == 0 and st) and (GREY .. "Nobody has bet yet.|r") or ""))

    -- my decision
    local canBet = Client.CanBet(tc)
    local myHand = Client.MyTurn(tc, me)
    if myHand then
        local mine = Client.MyHands(tc, me) or {}
        local h = mine[myHand]
        local free = tc.balance or 0
        B.actTitle:SetText(GREEN .. "Your turn|r" .. (#mine > 1 and (MUTED .. ("   hand %d of %d"):format(myHand, #mine) .. "|r") or ""))
        B.hit:Show(); B.stand:Show(); B.double:Show(); B.split:Show(); B.waiting:SetText("")
        if h then
            if h.aces and h.split then B.hit:Disable() else B.hit:Enable() end
            B.stand:Enable()
            if #h.cards == 2 and not (h.aces and h.split) and free >= (h.bet or 0) then B.double:Enable() else B.double:Disable() end
            if #mine == 1 and Blackjack.CanSplit(h.cards) and free >= (h.bet or 0) then B.split:Enable() else B.split:Disable() end
        end
        local left = pub.deadline and (pub.deadline - GetServerTime()) or nil
        B.timer:SetText(left and (GOLD .. ("%d s left"):format(math.max(0, left)) .. "|r") or "")
        local frac = left and math.max(0, math.min(1, left / ns.BlackjackTable.TURN_SECONDS)) or 1
        B.barFill:SetSize(math.max(1, 576 * frac), 6)
        B.barTrack:Show(); B.barFill:Show()
    else
        B.actTitle:SetText(MUTED .. "Your decision|r")
        B.hit:Hide(); B.stand:Hide(); B.double:Hide(); B.split:Hide()
        B.timer:SetText(""); B.barTrack:Hide(); B.barFill:Hide()
        local mineBetting = Client.Staked(tc) > 0
        B.waiting:SetText(canBet and (mineBetting and (MUTED .. "Your bet is in. The host deals when everyone is ready.|r") or (MUTED .. "Place a bet to be dealt in.|r"))
            or (pub and pub.turn and (MUTED .. "Waiting for " .. pub.turn .. " to play...|r") or ""))
    end

    -- bet panel
    B.betNote:SetText(st and (MUTED .. ("Bets %s to %s. Blackjack pays 3:2."):format(money(st.minBet), money(st.maxBet)) .. "|r") or "")
    if canBet then
        if Client.Staked(tc) > 0 then B.place:Disable(); B.back:Enable() else B.place:Enable(); B.back:Disable() end
    else
        B.place:Disable(); B.back:Disable()
    end
    local mine = Client.MyResult(tc, me)
    if (B.message or "") ~= "" then B.msg:SetText(B.message)
    elseif mine and canBet then B.msg:SetText("Last round: " .. signed(mine.net))
    else B.msg:SetText("") end

    -- the log
    local lines = {}
    for _, e in ipairs(tc.log or {}) do
        lines[#lines + 1] = "|cffffffffRound " .. e.round .. "|r"
        lines[#lines + 1] = e.blackjack and "Dealer blackjack" or (e.bust and ("Dealer bust (" .. e.total .. ")") or ("Dealer " .. e.total))
        local parts = {}
        for _, x in ipairs(e.nets) do
            parts[#parts + 1] = ((x.name == me) and "You" or x.name) .. " " .. (x.net == 0 and (MUTED .. "push|r") or signed(x.net))
        end
        lines[#lines + 1] = #parts > 0 and table.concat(parts, "  ") or (MUTED .. "nobody played|r")
        lines[#lines + 1] = ""
    end
    B.log:SetText(#lines > 0 and table.concat(lines, "\n") or (GREY .. "No rounds yet.|r"))
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
