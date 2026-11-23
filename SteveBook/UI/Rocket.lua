-- UI/Rocket.lua: the rocket window (SPEC §11c). Only draws and wires: the rocket is Rocket.lua, the bets and
-- messages are RocketNet.lua. Opened from the casino window (the house button next to Rocket).
-- Exposes ns.UI.Rocket = { Show, Refresh }.
local ADDON, ns = ...
ns.UI = ns.UI or {}

local K = ns.UI.Casino.Kit
local Rocket, RocketNet, Odds = ns.Rocket, ns.RocketNet, ns.Odds
local button, label, editBox, paint, at, panel, glow = K.button, K.label, K.editBox, K.paint, K.at, K.panel, K.glow
local COL, MUTED, GOLD, GREEN, RED, GREY, money = K.COL, K.MUTED, K.GOLD, K.GREEN, K.RED, K.GREY, K.money

local UI = {}
ns.UI.Rocket = UI

local W = {}
local SKY_W, SKY_H = 420, 280
local PAD, TOP = 12, 56                       -- room under the rocket's base and above its nose
local EXPLOSION_SHOW = 4                      -- seconds the explosion stays on show

local function fmt(m100) return Rocket.Format(m100) end
local function signed(c) return (c >= 0 and GREEN .. "+" or RED .. "-") .. money(math.abs(c)) .. "|r" end

-- Height of the rocket's base above the floor of the sky for a multiplier (in hundredths): 1x at the bottom, 50x at the top.
local function height(m100)
    local progress = math.log(math.max(100, m100) / 100) / math.log(Rocket.MAX100 / 100)
    return PAD + math.max(0, math.min(1, progress)) * (SKY_H - PAD - TOP)
end

local function message(text)
    W.message = text or ""
    if W.msg then W.msg:SetText(W.message) end
end

-- Lines for a list of players: who is on the rocket, who bailed where, who crashed.
local function playerLines(list)
    local lines = {}
    for i, r in ipairs(list or {}) do
        if i > 9 then lines[#lines + 1] = MUTED .. ("+%d more"):format(#list - 9) .. "|r"; break end
        local amount = r.amount and money(r.amount) or "?"
        if r.status == "bailed" then
            lines[#lines + 1] = ("%s  %s  %sbailed %s|r%s"):format(r.name, amount, GREEN, fmt(r.bail100), r.net and ("  " .. signed(r.net)) or "")
        elseif r.status == "crashed" then
            lines[#lines + 1] = ("%s  %s  %sCRASHED|r%s"):format(r.name, amount, RED, r.net and ("  " .. signed(r.net)) or "")
        else
            lines[#lines + 1] = ("%s  %s  %son board|r"):format(r.name, amount, MUTED)
        end
    end
    return lines
end

local function parseAuto()
    local text = W.autoBox:GetText() or ""
    if text:match("^%s*$") then return nil end
    return tonumber(text) or false               -- false: something that is not a number
end

function UI.Bet()
    local stake = Odds.ParseMoney(W.amountBox:GetText() or "")
    if not stake or stake <= 0 then return message(RED .. "Enter a stake like 5s.|r") end
    local auto = parseAuto()
    if auto == false then return message(RED .. "Auto bail is a number like 2.5.|r") end
    local ok, err = RocketNet.PlaceBet(stake, auto)
    message(ok and "" or (RED .. err .. "|r"))
end

function UI.Bail()
    local ok, err = RocketNet.Bail()
    message(ok and "" or (RED .. err .. "|r"))
end

------------------------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------------------------

local function build()
    local f, body = K.playerWindow("SteveBookRocketFrame", 712, 480, "SteveBook Casino")
    W.frame, W.body = f, body
    W.head = label(body, "GameFontNormalLarge"); at(W.head, body, 14, 8); W.head:SetWidth(300)
    W.note = label(body, "GameFontHighlight", "RIGHT"); at(W.note, body, 300, 10); W.note:SetWidth(384)
    W.status = label(body, "GameFontHighlight"); at(W.status, body, 14, 34); W.status:SetWidth(660)

    -- the sky
    local sky = panel(body, 14, 62, SKY_W, SKY_H, COL.panel, COL.edge)
    W.sky = sky
    for _, x in ipairs({ 2, 5, 10, 25 }) do                      -- height markers
        local y = height(x * 100)
        local line = sky:CreateTexture(nil, "ARTWORK")
        line:SetSize(SKY_W - 2, 1); line:SetPoint("BOTTOMLEFT", sky, "BOTTOMLEFT", 1, y); paint(line, 0.3, 0.25, 0.15, 0.7)
        local lab = label(sky, "GameFontHighlightSmall")
        lab:SetPoint("BOTTOMLEFT", sky, "BOTTOMLEFT", 6, y + 2); lab:SetText(MUTED .. x .. "x|r")
    end
    W.mult = label(sky, "GameFontNormalHuge", "CENTER"); W.mult:SetPoint("TOP", sky, "TOP", 0, -14); W.mult:SetWidth(SKY_W - 20)
    W.skyNote = label(sky, "GameFontHighlight", "CENTER"); W.skyNote:SetPoint("TOP", sky, "TOP", 0, -50); W.skyNote:SetWidth(SKY_W - 20)

    local rk = CreateFrame("Frame", nil, sky)                    -- the rocket: a few coloured boxes
    rk:SetSize(24, 46)
    W.rocket = rk
    local function part(w, h, point, rel, relPoint, x, y, r, g, b)
        local t = rk:CreateTexture(nil, "ARTWORK")
        t:SetSize(w, h); t:SetPoint(point, rel, relPoint, x, y); paint(t, r, g, b, 1)
        return t
    end
    W.flame = part(8, 12, "BOTTOM", rk, "BOTTOM", 0, 0, 1, 0.55, 0.1)
    local bodyTex = part(14, 24, "BOTTOM", rk, "BOTTOM", 0, 10, 0.92, 0.92, 0.95)
    part(8, 9, "BOTTOM", rk, "BOTTOM", 0, 34, 0.85, 0.2, 0.2)
    part(5, 10, "BOTTOMRIGHT", bodyTex, "BOTTOMLEFT", 0, 0, 0.6, 0.6, 0.65)
    part(5, 10, "BOTTOMLEFT", bodyTex, "BOTTOMRIGHT", 0, 0, 0.6, 0.6, 0.65)
    rk:Hide()

    local boom = CreateFrame("Frame", nil, sky)                  -- the explosion
    boom:SetSize(76, 76)
    W.boom = boom
    local b1 = boom:CreateTexture(nil, "ARTWORK"); b1:SetAllPoints(); paint(b1, 1, 0.35, 0.1, 0.9)
    local b2 = boom:CreateTexture(nil, "OVERLAY"); b2:SetSize(44, 44); b2:SetPoint("CENTER"); paint(b2, 1, 0.85, 0.2, 1)
    local bl = label(boom, "GameFontNormal", "CENTER"); bl:SetPoint("CENTER"); bl:SetText("BOOM")
    boom:Hide()

    W.hist = label(body, "GameFontHighlightSmall"); at(W.hist, body, 14, 350); W.hist:SetWidth(SKY_W); W.hist:SetWordWrap(true)

    -- who is on the rocket
    local tp = panel(body, 446, 62, 240, 136, COL.panel, COL.line)
    local tl = label(tp, "GameFontNormal"); at(tl, tp, 10, 8); tl:SetText("This round")
    W.thisText = label(tp, "GameFontHighlightSmall"); at(W.thisText, tp, 10, 28); W.thisText:SetWidth(222)
    W.thisText:SetWordWrap(true); W.thisText:SetJustifyV("TOP"); W.thisText:SetHeight(104)
    local lp = panel(body, 446, 206, 240, 136, COL.panel, COL.line)
    W.lastTitle = label(lp, "GameFontNormal"); at(W.lastTitle, lp, 10, 8); W.lastTitle:SetWidth(222); W.lastTitle:SetText("Last round")
    W.lastText = label(lp, "GameFontHighlightSmall"); at(W.lastText, lp, 10, 28); W.lastText:SetWidth(222)
    W.lastText:SetWordWrap(true); W.lastText:SetJustifyV("TOP"); W.lastText:SetHeight(104)

    -- the bet
    local sl = label(body, "GameFontNormal"); at(sl, body, 14, 380); sl:SetText("Stake")
    W.amountBox = editBox(body, 64, money(Odds.STAKE_STEP), 12); at(W.amountBox, body, 60, 376)
    local qx = 130
    for _, v in ipairs(K.STAKE_BUTTONS) do
        local b = button(body, money(v), 44, function() W.amountBox:SetText(money(v)) end, 22)
        at(b, body, qx, 376); qx = qx + 48
    end
    local al = label(body, "GameFontNormal"); at(al, body, 386, 380); al:SetText("Auto bail at")
    W.autoBox = editBox(body, 50, "", 6); at(W.autoBox, body, 474, 376)
    local ax = label(body, "GameFontNormal"); at(ax, body, 530, 380); ax:SetText("x")
    W.bet = button(body, "Bet", 200, function() UI.Bet() end, 34); at(W.bet, body, 14, 406)
    W.bail = button(body, "Bail", 300, function() UI.Bail() end, 34); at(W.bail, body, 224, 406)
    W.msg = label(body, "GameFontHighlight"); at(W.msg, body, 536, 408); W.msg:SetWidth(150); W.msg:SetWordWrap(true)

    local acc = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc >= 0.05 then acc = 0; UI.Refresh() end
    end)
    f:SetScript("OnShow", function() UI.Refresh() end)
end

function UI.Refresh()
    if not (W.frame and W.frame:IsShown()) then return end
    RocketNet.Tick()
    local v = RocketNet.View()
    if not v then
        W.head:SetText("Rocket")
        W.status:SetText(GOLD .. "Open the rocket from the casino window (the button next to Rocket).|r")
        W.note:SetText(""); W.mult:SetText(""); W.skyNote:SetText(""); W.hist:SetText("")
        W.thisText:SetText(""); W.lastText:SetText("")
        W.rocket:Hide(); W.boom:Hide(); W.bet:Disable(); W.bail:Disable(); glow(W.bet, false); glow(W.bail, false)
        return
    end
    local st, bet = v.state, v.bet
    W.head:SetText(v.host .. "'s rocket")
    W.note:SetText(K.houseNote(v.host) .. MUTED .. ("   Bets %s to %s"):format(money(v.minBet), money(v.maxBet)) .. "|r")

    -- the sky
    local exploded = st.last and st.phase == "waiting" and v.now - st.last.explodeAt < EXPLOSION_SHOW and not st.idle
    local x = SKY_W / 2
    if st.phase == "flying" then
        local m = st.m100
        W.rocket:ClearAllPoints(); W.rocket:SetPoint("BOTTOM", W.sky, "BOTTOMLEFT", x, height(m)); W.rocket:Show()
        W.flame:SetAlpha(math.floor(v.now * 12) % 2 == 0 and 1 or 0.55)
        W.boom:Hide()
        W.mult:SetText((m >= 1000 and GREEN or (m >= 200 and GOLD or "|cffffffff")) .. fmt(m) .. "|r")
        W.skyNote:SetText(GREY .. "climbing..." .. "|r")
    elseif exploded then
        W.rocket:Hide()
        W.boom:ClearAllPoints(); W.boom:SetPoint("CENTER", W.sky, "BOTTOMLEFT", x, height(st.last.crash100) + 20); W.boom:Show()
        W.mult:SetText(RED .. fmt(st.last.crash100) .. "|r")
        W.skyNote:SetText(RED .. "EXPLODED|r")
    else
        W.boom:Hide()
        W.rocket:ClearAllPoints(); W.rocket:SetPoint("BOTTOM", W.sky, "BOTTOMLEFT", x, height(100)); W.rocket:Show()
        W.flame:SetAlpha(0)
        W.mult:SetText(GOLD .. ("%d"):format(math.ceil(st.toLaunch)) .. "|r")
        W.skyNote:SetText(st.idle and (GREY .. "the rocket is resting for a while" .. "|r") or (GOLD .. "launch in seconds: place your bets" .. "|r"))
    end

    -- status line and what I did
    local line
    if not v.open then line = RED .. "This house is closed.|r"
    elseif st.phase == "waiting" then line = GOLD .. ("Betting is open: launch in %d s"):format(math.ceil(st.toLaunch)) .. "|r"
    else line = GREEN .. "The rocket is climbing" .. "|r" end
    if bet then
        line = line .. MUTED .. "   Your bet: " .. money(bet.amount) .. (bet.auto and (" (auto bail at " .. fmt(bet.auto) .. ")") or "")
            .. (bet.bail and (", bailed at " .. fmt(bet.bail)) or "") .. "|r"
    elseif v.result and v.result.host == v.host then
        local r = v.result
        line = line .. MUTED .. "   Last bet: " .. (r.bail100 and ("bailed at " .. fmt(r.bail100)) or "crashed") .. " " .. "|r" .. signed(r.net)
    end
    W.status:SetText(line)

    -- history of explosions, and who is on the rocket
    local hist = {}
    for i, c in ipairs(st.recent or {}) do hist[i] = (c >= 200 and GREEN or RED) .. fmt(c) .. "|r" end
    W.hist:SetText(MUTED .. "Explosions: |r" .. (#hist > 0 and table.concat(hist, "  ") or (GREY .. "none yet|r")))
    W.thisText:SetText(#v.thisRows > 0 and table.concat(playerLines(v.thisRows), "\n") or (GREY .. "nobody has bet yet|r"))
    if st.last and v.lastRows then
        W.lastTitle:SetText("Last round  " .. RED .. "exploded at " .. fmt(st.last.crash100) .. "|r")
        W.lastText:SetText(#v.lastRows > 0 and table.concat(playerLines(v.lastRows), "\n") or (GREY .. "nobody was on it|r"))
    else
        W.lastTitle:SetText("Last round"); W.lastText:SetText("")
    end

    -- the buttons
    local stake = Odds.ParseMoney(W.amountBox:GetText() or "")
    local canBet = v.open and st.phase == "waiting" and st.toLaunch > 0.3 and not bet and stake ~= nil and stake > 0
    W.bet:SetText(stake and stake > 0 and ("Bet " .. money(stake)) or "Bet")
    if canBet then W.bet:Enable() else W.bet:Disable() end
    glow(W.bet, canBet)
    local canBail = bet ~= nil and st.phase == "flying" and not bet.bail
    if canBail then
        W.bail:SetText(("BAIL  %s  (%s)"):format(fmt(st.m100), signed(math.floor(bet.amount * st.m100 / 100) - bet.amount)))
        W.bail:Enable()
    else
        W.bail:SetText(bet and bet.bail and ("Bailed at " .. fmt(bet.bail)) or "Bail")
        W.bail:Disable()
    end
    glow(W.bail, canBail)
    local hint = ""
    if (W.message or "") ~= "" then hint = W.message
    elseif not bet and st.phase == "waiting" and v.open then hint = MUTED .. "Set a stake and press Bet before the launch.|r" end
    W.msg:SetText(hint)
end

function UI.Show()
    if not W.frame then build() end
    W.frame:Show()
    UI.Refresh()
end

RocketNet.Subscribe(function() UI.Refresh() end)
