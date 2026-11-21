-- UI/Bookie.lua: the bookie window (SPEC §6). Tabs: Markets (a table with inline odds boxes and the
-- Import panel beside it), Bets (singles and parlays with their legs), Members, Ledger, Import
-- (the same panel, with a line-by-line preview). Header: book picker and join code.
-- All state changes go through ns.BookieNet (which also does the broadcasting); form parsing is
-- Bookie.ParseMarketForm / ParseEditForm and the import plan is Import.Plan (pure, tested).
-- Exposes ns.UI.Bookie = { Show, Hide, Toggle, Refresh }.
-- Frame templates: BasicFrameTemplateWithInset, UIPanelButtonTemplate, InputBoxTemplate (as in
-- UI/Bettor.lua; checked in game with the /run line in README.md). Also used here and worth a
-- /dump check if something looks wrong in game: EditBox:HasFocus, EditBox:SetMultiLine,
-- Frame:CreateTexture + Texture:SetColorTexture, GameTooltip:SetOwner/SetText/AddLine/Show.
local ADDON, ns = ...
ns.UI = ns.UI or {}

local Model, Bookie, Odds, Net, Import = ns.Model, ns.Bookie, ns.Odds, ns.BookieNet, ns.Import
local UI = {}
ns.UI.Bookie = UI

local WIN_W, WIN_H = 960, 600
local MARGIN = 14                -- window edge to content
local PANEL_W, GAP = 262, 8      -- the Import panel and the space between it and the list
local CONTENT_Y = 90             -- top of the content area
local HEAD_Y = 122               -- the Markets table's column headings
local TABLE_Y = 140              -- first table row
local ROW_H = 28
local GREEN, RED, GOLD, GREY = "|cff40ff40", "|cffff5050", "|cffffd100", "|cff999999"
local MAX_BTN = 4                -- buttons per generic list row
local PROMPT_BTN = 5             -- buttons in the prompt view
local FINALS_SHOWN = 15          -- settled/void markets listed below the live ones

-- Column positions inside a market row (x from the row's left edge, widths in pixels). A row is
-- PANEL_W + GAP narrower than the window's content, so these add up to a little under 662.
local COL = {
    game = { x = 4, w = 108 }, market = { x = 116, w = 94 },
    odds1 = { x = 214, w = 46 }, odds2 = { x = 264, w = 46 },
    closes = { x = 316, w = 58 }, status = { x = 378, w = 52 }, risk = { x = 434, w = 52 },
    buttons = { x = 492 },
}

local frame, content, scroll
local ui = {}                    -- widgets, also handy for the smoke test
local rows = {}                  -- generic list rows (Bets, Members, Ledger, import preview)
local mrows = {}                 -- Markets table rows
local tab, view = "markets", "list"          -- tab: markets|bets|members|ledger|import; view: list|form|prompt
local curPlan                    -- Import.Plan for the text in the import box (nil when it is empty)
local formState = { mode = "new", type = "moneyline" }
local promptSeq = 0
local ledgerPlayer               -- set while the Ledger tab shows one player's payments
local betFilter = {}             -- Bets tab filters: { status, bettor, marketId }

local function say(msg) print(GOLD .. "SteveBook:|r " .. msg) end
local function now() return GetServerTime() end
local function money(c) return Odds.FormatMoney(c) end
local function when(t) return date("%a %b %d %H:%M", t) end
local function clock(t) return (date("%I:%M %p", t):gsub("^0", "")) end
-- "7:30 PM" today, "Thu 7:30 PM" on another day.
local function closesText(t)
    if date("%Y%m%d", t) == date("%Y%m%d", now()) then return clock(t) end
    return date("%a", t) .. " " .. clock(t)
end
local function shown() return frame and frame:IsShown() end
-- The book the window shows: the active one if this character runs it, else its first own book.
-- Books owned by other characters are never listed or edited from here.
local function currentBook()
    if not SteveBookDB then return nil end
    local active = Model.ActiveBook(SteveBookDB)
    if active and active.ownerName == Net.Me() then return active end
    return Net.MyBooks()[1]
end

local function colorMoney(c)
    if c > 0 then return GREEN .. "+" .. money(c) .. "|r" end
    if c < 0 then return RED .. money(c) .. "|r" end
    return money(c)
end

local ERRORS = {
    bad_close_time = "The close time must be in the future.",
    market_final = "That market is already settled or void.",
    market_closed = "That market has already closed.",
    bad_result = "Pick one of the two sides, or Push.",
    no_market = "That market no longer exists.",
    no_member = "That player is not in the book.",
    bad_limit = "Enter an amount like 50g.",
    bad_amount = "Enter an amount like 50g.",
    bad_odds = "Odds look like -110 or +150 (nothing between -99 and +99).",
}
local function describe(code) return ERRORS[code] or tostring(code) end

local TYPE_NAME = { moneyline = "ML", spread = "Spread", total = "Total" }
local function signed(n) return (n > 0 and "+" or "") .. ("%g"):format(n) end
local function plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end

-- Ledger balances are stored from the player's side (positive = the book owes them). The bookie
-- reads it the other way round, so say who owes whom.
local function owesText(balance)
    if balance < 0 then return GREEN .. "owes you " .. money(-balance) .. "|r" end
    if balance > 0 then return RED .. "you owe " .. money(balance) .. "|r" end
    return GREY .. "settled|r"
end

local function short(s, n)
    s = tostring(s)
    return #s > n and (s:sub(1, n - 2) .. "..") or s
end

-- Free text shown in a FontString: a lone "|" starts an escape code, so double it.
local function esc(s) return (tostring(s):gsub("|", "||")) end

-- "Moneyline", "Spread PHI -3.5", "Total 47.5": the Market column.
local function marketLabel(m)
    if m.type == "spread" then return ("Spread %s %s"):format(esc(m.selections[1].label), signed(m.line)) end
    if m.type == "total" then return ("Total %g"):format(m.line) end
    return "Moneyline"
end

------------------------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------------------------

local function button(parent, text, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function label(parent, template, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

local function editBox(parent, w, maxLetters)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 22)
    e:SetAutoFocus(false)
    if maxLetters then e:SetMaxLetters(maxLetters) end
    e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

local function labelAt(parent, text, x, y, template)
    local fs = label(parent, template or "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

-- Hover text, when the client has a tooltip to show it in.
local function tip(frameWithTip, lines)
    frameWithTip:EnableMouse(true)
    frameWithTip:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        local l = lines
        if type(lines) == "function" then l = lines(self) end      -- not "and ... or": a nil result must stay nil
        if not l or #l == 0 then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(l[1])
        for i = 2, #l do GameTooltip:AddLine(l[i], 1, 1, 1) end
        GameTooltip:Show()
    end)
    frameWithTip:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

------------------------------------------------------------------------------------------
-- Generic list: pooled rows in a scroll frame. entry = { text, sub, h, buttons = { {label, fn} } }
-- (Bets, Members, Ledger and the import preview. The Markets tab has its own table below.)
------------------------------------------------------------------------------------------

local function getRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, content)
    r.text = label(r, "GameFontHighlight")
    r.text:SetPoint("TOPLEFT", 0, -2)
    r.text:SetWordWrap(false)
    r.sub = label(r, "GameFontHighlight")
    r.sub:SetWordWrap(false)
    r.btn = {}
    for k = 1, MAX_BTN do r.btn[k] = button(r, "", 58, nil) end
    rows[i] = r
    return r
end

local function render(entries)
    for i = 1, #mrows do mrows[i]:Hide() end
    local y, width = 0, content:GetWidth()
    for i, e in ipairs(entries) do
        local r = getRow(i)
        local h = e.h or 20
        r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        r:SetSize(width, h)
        r:Show()
        local nb = e.buttons and #e.buttons or 0
        local bw = e.bw or 58
        local textW = width - nb * (bw + 4) - 6
        r.text:SetWidth(textW)
        r.text:SetText(e.text or "")
        if e.sub then
            r.sub:SetPoint("TOPLEFT", 0, -20)
            r.sub:SetWidth(textW)
            r.sub:SetText(e.rawSub and e.sub or (GREY .. e.sub .. "|r"))
            r.sub:Show()
        else
            r.sub:Hide()
        end
        for k = 1, MAX_BTN do
            local b, d = r.btn[k], e.buttons and e.buttons[k]
            if d then
                b:SetText(d[1])
                b:SetScript("OnClick", d[2])
                b:SetWidth(bw)
                b:ClearAllPoints()
                b:SetPoint("RIGHT", r, "RIGHT", -((nb - k) * (bw + 4)), 0)
                b:Show()
            else
                b:Hide()
            end
        end
        y = y + h + 2
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(y, 1))
end

------------------------------------------------------------------------------------------
-- Views and layout. view "list" shows the scroll list (and, on Markets/Import, the import panel
-- beside it); "form" and "prompt" replace the whole content area.
------------------------------------------------------------------------------------------

local function applyLayout()
    local book = currentBook()
    local list = view == "list"
    local withPanel = list and book ~= nil and (tab == "markets" or tab == "import")
    local withTable = list and book ~= nil and tab == "markets"
    ui.scroll:SetShown(list)
    ui.form:SetShown(view == "form")
    ui.prompt:SetShown(view == "prompt")
    ui.panel:SetShown(withPanel)
    ui.newMarket:SetShown(withTable)
    ui.lockAll:SetShown(withTable)
    ui.openStakes:SetShown(withTable)
    ui.head:SetShown(withTable)

    local right = withPanel and (MARGIN + PANEL_W + GAP) or MARGIN
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", MARGIN, -(withTable and TABLE_Y or CONTENT_Y))
    scroll:SetPoint("BOTTOMRIGHT", -right, MARGIN)
    content:SetWidth(WIN_W - MARGIN - right)
end

local function setView(v)
    view = v
    applyLayout()
end

------------------------------------------------------------------------------------------
-- Prompt view: a message, up to two text boxes, up to PROMPT_BTN buttons.
-- spec = { text, input = defaultText | nil, input2 = defaultText | nil,
--          buttons = { {label, fn(inputText, input2Text) -> errorString|nil} } }
-- A button whose fn returns a string keeps the prompt open and shows it.
------------------------------------------------------------------------------------------

local function ask(spec)
    local p = ui.prompt
    promptSeq = promptSeq + 1
    local id = promptSeq
    p.text:SetText(spec.text)
    if spec.input ~= nil then
        p.input:Show()
        p.input:SetText(spec.input)
        p.input:SetFocus()
    else
        p.input:Hide()
    end
    p.input2:SetShown(spec.input2 ~= nil)
    p.hint2:SetShown(spec.input2 ~= nil)
    if spec.input2 ~= nil then p.input2:SetText(spec.input2) end
    p.msg:SetText("")
    for i = 1, PROMPT_BTN do
        local b, d = p.btn[i], spec.buttons[i]
        if d then
            b:SetText(d[1])
            b:SetScript("OnClick", function()
                local err = d[2] and d[2](spec.input ~= nil and p.input:GetText() or nil,
                                          spec.input2 ~= nil and p.input2:GetText() or nil)
                if err then return p.msg:SetText(err) end
                if promptSeq == id then setView("list") end    -- fn may have opened another view
                UI.Refresh()
            end)
            b:Show()
        else
            b:Hide()
        end
    end
    setView("prompt")
end

local function act(fn, ...)
    local ok, err = fn(...)
    if not ok then say(describe(err)) end
    UI.Refresh()
    return ok
end

local function askNewBook()
    ask({ text = "Name for the new book (e.g. NFL Week 12):", input = "", buttons = {
        { "Create", function(text)
            local book, err = Net.CreateBook(text)
            if not book then return describe(err) end
            tab = "markets"
            say(("Created %s. Share the join code %s with friends."):format(book.name, book.code))
        end },
        { "Cancel" },
    } })
end

------------------------------------------------------------------------------------------
-- Market form (new market, or edit odds/line/close time)
------------------------------------------------------------------------------------------

local FORM_FIELDS = { "sport", "event", "line", "label1", "odds1", "label2", "odds2", "closes" }
local NEXT_TYPE = { moneyline = "spread", spread = "total", total = "moneyline" }

local function syncTypeWidgets()
    local f = ui.form
    local t = formState.type
    f.typeBtn:SetText(TYPE_NAME[t])
    f.f.line:SetShown(t ~= "moneyline")
    f.lineLabel:SetShown(t ~= "moneyline")
end

local function enableNameFields(on)
    for _, k in ipairs({ "sport", "event", "label1", "label2" }) do
        local e = ui.form.f[k]
        if e.SetEnabled then e:SetEnabled(on) end
    end
    ui.form.typeBtn:SetEnabled(on)
end

local function openForm(mode, market)
    local f = ui.form
    formState = { mode = mode, market = market, type = market and market.type or "moneyline" }
    for _, k in ipairs(FORM_FIELDS) do f.f[k]:SetText("") end
    f.msg:SetText("")
    if mode == "edit" then
        f.title:SetText(("Edit %s: leave a box alone to keep it. Changes only affect new bets."):format(esc(market.event)))
        f.f.sport:SetText(market.sport or "")
        f.f.event:SetText(market.event)
        f.f.label1:SetText(market.selections[1].label)
        f.f.label2:SetText(market.selections[2].label)
        f.f.odds1:SetText(Odds.FormatAmerican(market.selections[1].odds))
        f.f.odds2:SetText(Odds.FormatAmerican(market.selections[2].odds))
        if market.line then f.f.line:SetText(("%g"):format(market.line)) end
        f.ok:SetText("Save")
        enableNameFields(false)
    else
        f.title:SetText("New market")
        f.ok:SetText("Create")
        enableNameFields(true)
    end
    syncTypeWidgets()
    setView("form")
end

local function readForm()
    local f, out = ui.form.f, { type = formState.type }
    for _, k in ipairs(FORM_FIELDS) do out[k] = f[k]:GetText() end
    return out
end

local function submitForm()
    local book = currentBook()
    if not book then return end
    local f = ui.form
    local fields = readForm()
    if formState.mode == "new" then
        local spec, err = Bookie.ParseMarketForm(fields, now())
        if not spec then return f.msg:SetText(err) end
        local m, e2 = Net.AddMarket(book, spec)
        if not m then return f.msg:SetText(describe(e2)) end
    else
        local changes, err = Bookie.ParseEditForm(formState.market, fields, now())
        if not changes then return f.msg:SetText(err) end
        local m, e2 = Net.EditMarket(book, formState.market.id, changes)
        if not m then return f.msg:SetText(describe(e2)) end
    end
    setView("list")
    UI.Refresh()
end

------------------------------------------------------------------------------------------
-- Markets tab: a table (Game, Market, two odds boxes, Closes, Status, At risk, actions)
------------------------------------------------------------------------------------------

-- Settle (or correct) a market. Void is here too, behind its own confirmation.
local askVoid
local function askSettle(book, m)
    local s1, s2 = m.selections[1], m.selections[2]
    ask({ text = ("Settle %s: who won? (Void refunds every bet on it.)"):format(esc(m.event)), buttons = {
        { esc(s1.label) .. " won", function() if not Net.Settle(book, m.id, s1.id) then return "Could not settle." end end },
        { esc(s2.label) .. " won", function() if not Net.Settle(book, m.id, s2.id) then return "Could not settle." end end },
        { "Push", function() if not Net.Settle(book, m.id, "push") then return "Could not settle." end end },
        { "Void", function() askVoid(book, m) end },
        { "Cancel" },
    } })
end

function askVoid(book, m)
    ask({ text = ("Void %s? Every bet on it is refunded."):format(esc(m.event)), buttons = {
        { "Void market", function() local ok, err = Net.VoidMarket(book, m.id); if not ok then return describe(err) end end },
        { "Cancel" },
    } })
end

local function askLockAll(book)
    local n = 0
    for _, m in pairs(book.markets) do if Bookie.IsBettable(m, now()) then n = n + 1 end end
    if n == 0 then return say("No open markets to lock.") end
    ask({ text = ("Lock all %s? Nobody can bet on them until you unlock each one."):format(plural(n, "open market")), buttons = {
        { "Lock all", function()
            local done = 0
            for _, m in pairs(book.markets) do
                if Bookie.IsBettable(m, now()) and Net.LockMarket(book, m.id) then done = done + 1 end
            end
            say(("Locked %s."):format(plural(done, "market")))
        end },
        { "Cancel" },
    } })
end

-- An odds box lost focus or Enter was pressed: apply the edit if it changed. Odds changes only
-- affect new bets (the bookie logic keeps every accepted bet's own odds).
local function commitOdds(box)
    if box.discard then return end                       -- the row was rebound to another market mid-edit
    local book = currentBook()
    local m = book and book.markets[box.row.mid]
    -- The edit belongs to the market the bookie started typing in. If a refresh moved this row to a
    -- different market since (a market settled and the table re-sorted), drop the edit instead of
    -- changing the wrong market's odds.
    if not m or box.editMid ~= box.row.mid then return UI.Refresh() end
    local i = box.side
    local v = Odds.Parse(box:GetText())
    if not v then
        say(describe("bad_odds"))
    elseif v ~= m.selections[i].odds then
        local ok, err = Net.EditMarket(book, m.id, { odds = { [i] = v } })
        if not ok then say(describe(err)) end
    end
    UI.Refresh()
end

-- A box that has focus keeps what the bookie is typing when a refresh arrives.
local function setBoxText(box, text)
    if not box:HasFocus() then box:SetText(text) end
end

local function fontString(parent, col, justify)
    local fs = label(parent, "GameFontHighlight", justify)
    fs:SetPoint("LEFT", parent, "LEFT", col.x, 0)
    fs:SetWidth(col.w)
    fs:SetWordWrap(false)
    return fs
end

local function oddsBox(r, col, side)
    local e = editBox(r, col.w, 6)
    e:SetPoint("LEFT", r, "LEFT", col.x, 0)
    e:SetJustifyH("CENTER")
    e.row, e.side, e.discard, e.editMid = r, side, false, false
    e:SetScript("OnEditFocusGained", function(self) self.editMid = self.row.mid end)
    e:SetScript("OnEnterPressed", e.ClearFocus)           -- losing focus commits
    e:SetScript("OnEditFocusLost", commitOdds)
    e:SetScript("OnEscapePressed", function(self)
        local book = currentBook()
        local m = book and book.markets[self.row.mid]
        if m then self:SetText(Odds.FormatAmerican(m.selections[self.side].odds)) end
        self:ClearFocus()
    end)
    tip(e, function(self)
        local book = currentBook()
        local m = book and book.markets[self.row.mid]
        return m and { esc(m.selections[self.side].label) .. " odds", "Enter to save. Only affects new bets." } or nil
    end)
    return e
end

local function getMRow(i)
    local r = mrows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, content)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(1, 1, 1, 0.05)
    r.game = fontString(r, COL.game)
    r.mkt = fontString(r, COL.market)
    r.o1 = oddsBox(r, COL.odds1, 1)
    r.o2 = oddsBox(r, COL.odds2, 2)
    r.result = fontString(r, { x = COL.odds1.x, w = COL.odds2.x + COL.odds2.w - COL.odds1.x })   -- replaces the boxes
    r.closes = fontString(r, COL.closes)
    r.status = fontString(r, COL.status)
    r.risk = fontString(r, COL.risk, "RIGHT")
    r.riskHit = CreateFrame("Frame", nil, r)
    r.riskHit:SetPoint("LEFT", r, "LEFT", COL.risk.x, 0)
    r.riskHit:SetSize(COL.risk.w, ROW_H)
    tip(r.riskHit, function()
        local row = r.row
        local ex = row and row.exposure
        if not ex or ex.staked == 0 then return nil end
        local m = row.market
        return { "Book result if...",
                 ("%s wins: %s"):format(esc(m.selections[1].label), colorMoney(ex.net[1])),
                 ("%s wins: %s"):format(esc(m.selections[2].label), colorMoney(ex.net[2])),
                 "Push: 0", GREY .. "Single bets only; parlays are counted in the total above.|r" }
    end)
    r.btn = {}
    for k = 1, 3 do r.btn[k] = button(r, "", 50, nil) end
    mrows[i] = r
    return r
end

-- Buttons for a row state: { label, width, fn }.
local function rowButtons(book, row)
    local m, s = row.market, row.state
    local settle = { "Settle", 52, function() askSettle(book, m) end }
    local edit = { "Edit", 40, function() openForm("edit", m) end }
    if s == "open" then
        return { { "Lock", 46, function() act(Net.LockMarket, book, m.id) end }, settle, edit }
    elseif s == "locked" then
        return { { "Unlock", 56, function() act(Net.UnlockMarket, book, m.id) end }, settle, edit }
    elseif s == "started" then
        return { settle }                      -- no edits, no extending, no reopening once the game is on
    elseif s == "settled" then
        return { { "Re-settle", 72, function() askSettle(book, m) end } }
    end
    return { settle }                          -- void: settle it after all
end

local STATE_TEXT = { open = GREEN .. "Open|r", locked = GOLD .. "Locked|r", started = GOLD .. "Started|r",
                     settled = GREY .. "Settled|r", void = GREY .. "Void|r" }

local function fillMRow(r, row, book, t)
    local m, s = row.market, row.state
    local live = s == "open" or s == "locked"
    local s1, s2 = m.selections[1], m.selections[2]
    if r.mid ~= m.id then
        -- this row now shows a different market: an edit in progress in its boxes is abandoned
        for _, box in ipairs({ r.o1, r.o2 }) do
            if box:HasFocus() then box.discard = true; box:ClearFocus(); box.discard = false end
        end
    end
    r.mid, r.row = m.id, row
    r.game:SetText(esc(m.event))
    r.mkt:SetText(marketLabel(m))
    r.status:SetText(STATE_TEXT[s])
    r.o1:SetShown(live)
    r.o2:SetShown(live)
    r.result:SetShown(not live)
    if live then
        setBoxText(r.o1, Odds.FormatAmerican(s1.odds))
        setBoxText(r.o2, Odds.FormatAmerican(s2.odds))
        r.closes:SetText(GREY .. closesText(m.closesAt) .. "|r")
    else
        local text
        if s == "started" then
            text = GREY .. esc(s1.label) .. " " .. Odds.FormatAmerican(s1.odds) .. " / " .. esc(s2.label) .. " " .. Odds.FormatAmerican(s2.odds) .. "|r"
        elseif s == "settled" then
            text = GOLD .. (m.result == "push" and "Push" or (m.selections[m.result] and esc(m.selections[m.result].label) .. " won") or "?") .. "|r"
        else
            text = GREY .. "refunded|r"
        end
        r.result:SetText(text)
        r.closes:SetText(GREY .. (s == "started" and ("began " .. clock(m.closesAt)) or closesText(m.closesAt)) .. "|r")
    end
    r.risk:SetText((live or s == "started") and (row.staked > 0 and money(row.staked) or GREY .. "0c|r") or "")
    r.bg:SetAlpha((s == "settled" or s == "void") and 0.02 or 0.05)

    local x = COL.buttons.x
    local defs = rowButtons(book, row)
    for k = 1, 3 do
        local b, d = r.btn[k], defs[k]
        if d then
            b:SetText(d[1])
            b:SetWidth(d[2])
            b:SetScript("OnClick", d[3])
            b:ClearAllPoints()
            b:SetPoint("LEFT", r, "LEFT", x, 0)
            x = x + d[2] + 3
            b:Show()
        else
            b:Hide()
        end
    end
end

local function renderMarkets(book)
    local model, live = Bookie.MarketRows(book, now(), FINALS_SHOWN)
    ui.openStakes:SetText(UI.stakesText(book))
    if #model == 0 then
        return render({ { text = GREY .. "No markets yet. Click + New market, or paste lines into the Import box on the right.|r" } })
    end
    for i = 1, #rows do rows[i]:Hide() end
    local t, width, y = now(), content:GetWidth(), 0
    for i, row in ipairs(model) do
        local r = getMRow(i)
        r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        r:SetSize(width, ROW_H)
        fillMRow(r, row, book, t)
        r:Show()
        y = y + ROW_H + 2
    end
    for i = #model + 1, #mrows do mrows[i]:Hide() end
    content:SetHeight(math.max(y, 1))
    return live
end

-- "Open stakes: 3g 40s (20s in parlays)" for the toolbar.
function UI.stakesText(book)
    local o = Bookie.OpenStakes(book)
    local text = ("Open stakes: %s%s|r"):format(GOLD, money(o.total))
    if o.parlays > 0 then text = text .. GREY .. (" (%s in parlays)"):format(money(o.parlays)) .. "|r" end
    return text
end

------------------------------------------------------------------------------------------
-- Members tab
------------------------------------------------------------------------------------------

local STATUS_ORDER = { pending = 1, active = 2, removed = 3 }

local function askLimit(book, name, m)
    ask({ text = ("Credit limit for %s (e.g. 50g). Leave blank for no limit."):format(esc(name)),
          input = m.creditLimit and money(m.creditLimit) or "", buttons = {
        { "Set", function(text)
            local c, err = Bookie.ParseLimit(text, Odds.ParseMoney)
            if c == false then return err end
            local ok, e = Net.SetCreditLimit(book, name, c)
            if not ok then return describe(e) end
        end },
        { "Cancel" },
    } })
end

local function memberEntries(book)
    local names = {}
    for name in pairs(book.members) do names[#names + 1] = name end
    table.sort(names, function(a, b)
        local sa, sb = STATUS_ORDER[book.members[a].status] or 9, STATUS_ORDER[book.members[b].status] or 9
        if sa ~= sb then return sa < sb end
        return a < b
    end)
    local entries = {}
    if #names == 0 then
        entries[1] = { text = GREY .. "Nobody yet. Share the join code (top right) with your friends.|r" }
        return entries
    end
    for _, name in ipairs(names) do
        local m = book.members[name]
        local text, buttons
        if m.status == "pending" then
            text = ("%s  %swants to join|r"):format(name, GOLD)
            buttons = { { "Approve", function() act(Net.Approve, book, name) end },
                        { "Deny", function() act(Net.Deny, book, name) end } }
        elseif m.status == "active" then
            local _, risk = Bookie.Credit(book, name)
            text = ("%s  %s   open bets %s   limit %s"):format(name,
                owesText(Bookie.Balance(book, name)), money(risk), m.creditLimit and money(m.creditLimit) or "none")
            buttons = { { "Limit", function() askLimit(book, name, m) end },
                        { "Remove", function() act(Net.Remove, book, name) end } }
        else
            text = ("%s  %sremoved|r   %s"):format(name, GREY, owesText(Bookie.Balance(book, name)))
            buttons = { { "Approve", function() act(Net.Approve, book, name) end } }
        end
        entries[#entries + 1] = { text = text, h = 24, buttons = buttons }
    end
    return entries
end

------------------------------------------------------------------------------------------
-- Ledger tab: who owes whom, record payments, payment history
------------------------------------------------------------------------------------------

-- direction "in": the player paid you; "out": you paid the player.
local function askPayment(book, name, direction)
    local balance = Bookie.Balance(book, name)
    local suggest = ""
    if direction == "in" and balance < 0 then suggest = money(-balance)
    elseif direction == "out" and balance > 0 then suggest = money(balance) end
    local who = direction == "in" and (name .. " paid you.") or ("You paid " .. name .. ".")
    ask({ text = who .. " Amount (e.g. 250g):", input = suggest, input2 = "", buttons = {
        { "Record", function(amount, note)
            local c, err = Bookie.ParseAmount(amount, Odds.ParseMoney)
            if c == false then return err end
            note = (note or ""):match("^%s*(.-)%s*$")
            local ok, e = Net.RecordPayment(book, name, direction, c, note ~= "" and note or nil)
            if not ok then return describe(e) end
            say(("Recorded: %s %s."):format(direction == "in" and (name .. " paid you") or ("you paid " .. name), money(c)))
        end },
        { "Cancel" },
    } })
end

local function ledgerEntries(book)
    local entries = {}
    if ledgerPlayer then
        entries[1] = { text = ("Payments with %s   %s"):format(ledgerPlayer, owesText(Bookie.Balance(book, ledgerPlayer))),
                       h = 24, buttons = { { "Back", function() ledgerPlayer = nil; UI.Refresh() end } } }
        local l = book.ledger[ledgerPlayer]
        local pays = l and l.payments or {}
        if #pays == 0 then
            entries[2] = { text = GREY .. "No payments recorded yet.|r" }
            return entries
        end
        for i = #pays, 1, -1 do
            local p = pays[i]
            local text = ("%s   %s %s"):format(when(p.at), p.amount > 0 and "paid you" or "you paid", money(math.abs(p.amount)))
            if p.note and p.note ~= "" then text = text .. "   (" .. esc(p.note) .. ")" end
            entries[#entries + 1] = { text = text }
        end
        return entries
    end

    local t = Bookie.LedgerTotals(book)
    entries[1] = { h = 24, text = ("Players owe you %s%s|r     You owe players %s%s|r"):format(
        GREEN, money(t.owedToBook), RED, money(t.owedByBook)) }
    local lrows = Bookie.LedgerRows(book)
    if #lrows == 0 then
        entries[2] = { text = GREY .. "Nothing to settle yet.|r" }
        return entries
    end
    for _, r in ipairs(lrows) do
        local name = r.name
        local text = ("%s%s   %s"):format(name, r.status == "removed" and (GREY .. " (removed)|r") or "", owesText(r.balance))
        if r.openRisk > 0 then text = text .. ("   open bets %s"):format(money(r.openRisk)) end
        entries[#entries + 1] = { text = text, h = 24, bw = 64, buttons = {
            { "Paid me", function() askPayment(book, name, "in") end },
            { "I paid", function() askPayment(book, name, "out") end },
            { "History", function() ledgerPlayer = name; UI.Refresh() end },
        } }
    end
    return entries
end

------------------------------------------------------------------------------------------
-- Bets tab: every bet (singles and parlays), filterable by status / bettor / market
------------------------------------------------------------------------------------------

local BETS_SHOWN = 100
local LEG_LINE_H = 14
local STATUS_LABEL = { accepted = "open", won = "won", lost = "lost", push = "push", void = "void" }
local LEG_COLOR = { pending = GREY, won = GREEN, lost = RED, push = GREY, void = GREY }
local LEG_WORD = { pending = "pending", won = "won", lost = "lost", push = "push", void = "void" }

local function askVoidBet(book, b)
    local what = b.legs and ("%s parlay"):format(money(b.stake)) or money(b.stake)
    ask({ text = ("Void bet #%d (%s, %s)? It is refunded and any result is reversed."):format(b.id, b.bettor, what),
          buttons = {
        { "Void bet", function() local ok, err = Net.VoidBet(book, b.id); if not ok then return describe(err) end end },
        { "Cancel" },
    } })
end

local function betResult(b)
    if b.status == "accepted" then return GOLD .. "OPEN|r"
    elseif b.status == "won" then return GREEN .. "WON " .. money(b.delta or 0) .. "|r"
    elseif b.status == "lost" then return RED .. "LOST " .. money(-(b.delta or 0)) .. "|r"
    elseif b.status == "push" then return GREY .. "PUSH|r" end
    return GREY .. "VOID|r"
end

local function betEntries(book)
    local f = betFilter
    local choices = Bookie.BetFilterChoices(book)
    local mkt = f.marketId and book.markets[f.marketId]
    local entries = { { text = "Filters", h = 26, bw = 140, buttons = {
        { "Status: " .. (f.status and STATUS_LABEL[f.status] or "all"),
          function() f.status = Bookie.CycleFilter(Bookie.BET_STATUSES, f.status); UI.Refresh() end },
        { "Bettor: " .. short(f.bettor or "all", 12),
          function() f.bettor = Bookie.CycleFilter(choices.bettors, f.bettor); UI.Refresh() end },
        { "Market: " .. (mkt and short(mkt.event, 12) or (f.marketId and ("#" .. f.marketId)) or "all"),
          function() f.marketId = Bookie.CycleFilter(choices.markets, f.marketId); UI.Refresh() end },
    } } }

    local bets = Bookie.ListBets(book, f)
    if #bets == 0 then
        entries[2] = { text = GREY .. (next(book.bets) and "No bets match these filters." or "No bets yet.") .. "|r" }
        return entries
    end
    for i = 1, math.min(#bets, BETS_SHOWN) do
        local b = bets[i]
        local entry
        if b.legs then
            -- a parlay: one line for the bet, then one per leg with its own result
            local lines = {}
            for _, leg in ipairs(Bookie.LegRows(book, b)) do
                lines[#lines + 1] = ("%s%d. %s: %s (%s)  %s|r"):format(LEG_COLOR[leg.status], leg.index, esc(leg.event),
                    esc(leg.pick), Odds.FormatAmerican(leg.odds), LEG_WORD[leg.status])
            end
            entry = {
                text = ("#%d  %s  %s on a %d-leg parlay %s  %s"):format(b.id, b.bettor, money(b.stake), #b.legs,
                    Odds.FormatAmerican(b.odds), betResult(b)),
                sub = table.concat(lines, "\n"), rawSub = true, h = 22 + LEG_LINE_H * #lines + 4,
            }
        else
            local m = book.markets[b.marketId]
            entry = {
                text = ("#%d  %s  %s on %s %s  (%s)  %s"):format(b.id, b.bettor, money(b.stake),
                    esc(Bookie.SelectionText(m, b.selectionId, b.line)), Odds.FormatAmerican(b.odds), m and esc(m.event) or "?", betResult(b)),
                h = 24,
            }
        end
        if b.status ~= "void" then entry.buttons = { { "Void", function() askVoidBet(book, b) end } } end
        entries[#entries + 1] = entry
    end
    if #bets > BETS_SHOWN then
        entries[#entries + 1] = { text = GREY .. ("... and %d more. Use the filters to narrow it down."):format(#bets - BETS_SHOWN) .. "|r" }
    end
    return entries
end

------------------------------------------------------------------------------------------
-- Import panel (beside Markets, and the whole Import tab's right side): paste, live summary, confirm.
-- Format: SPEC §7, parser and plan: Import.lua. Matching lines UPDATE open markets' odds.
------------------------------------------------------------------------------------------

local function planFor(book)
    local text = ui.panel.box:GetText()
    if not book or text:match("^%s*$") then return nil end
    return Import.Plan(book, text, now())
end

local function refreshPanel(book)
    local p = ui.panel
    local plan = planFor(book)
    curPlan = plan
    if not plan then
        p.sum[1]:SetText(GREY .. "Nothing pasted yet.|r")
        for i = 2, 6 do p.sum[i]:SetText("") end
        p.go:SetText("Import")
        p.go:SetEnabled(false)
        return
    end
    local n = plan.ok + plan.updated + plan.markets
    p.sum[1]:SetText(("%s%d new|r %s ready"):format(plan.ok > 0 and GREEN or GREY, plan.ok, plan.ok == 1 and "market" or "markets"))
    p.sum[2]:SetText(("%s%d updated|r (new odds on open markets)"):format(plan.updated > 0 and GOLD or GREY, plan.updated))
    p.sum[3]:SetText(("%s%d to settle|r%s"):format(plan.markets > 0 and GREEN or GREY, plan.markets,
        plan.settle > 0 and (" (from " .. plural(plan.settle, "final score") .. ")") or " (FINAL lines)"))
    p.sum[4]:SetText(("%s%d skipped|r: already started or closed"):format(plan.started > 0 and GOLD or GREY, plan.started))
    p.sum[5]:SetText(("%s%d skipped|r: duplicate, or nothing to settle"):format(GREY, plan.duplicate + plan.none))
    p.sum[6]:SetText(("%s%d %s|r"):format(plan.errors > 0 and RED or GREY, plan.errors, plan.errors == 1 and "error" or "errors"))
    if plan.markets > 0 and plan.ok + plan.updated == 0 then
        p.go:SetText(("Settle %s"):format(plural(plan.markets, "market")))
    else
        p.go:SetText(("Import %d"):format(n))
    end
    p.go:SetEnabled(n > 0)
end

-- Re-plans from the text box at confirm time (Net.ApplyImport), so a stale preview can't import
-- markets that have closed since, post duplicates after a double click, or touch a locked market.
local function confirmImport()
    local book = currentBook()
    if not book then return end
    local r = Net.ApplyImport(book, ui.panel.box:GetText())
    local text
    if r.settled > 0 and r.added == 0 and r.updated == 0 then
        text = ("Settled %s"):format(plural(r.settled, "market"))
    else
        text = ("Imported %s"):format(plural(r.added, "new market"))
        if r.updated > 0 then text = text .. (" and updated the odds of %s"):format(plural(r.updated, "market")) end
        if r.settled > 0 then text = text .. (" and settled %s"):format(plural(r.settled, "market")) end
    end
    say(text .. ".")
    for _, f in ipairs(r.failed) do say("Skipped " .. f) end
    if #r.failed == 0 and r.plan.errors == 0 then
        ui.panel.box:SetText("")               -- keep the text if something was wrong, to fix and retry
    end
    if tab == "import" then tab = "markets" end
    setView("list")
    UI.Refresh()
end

-- The Import tab's list: one line per pasted line, saying what would happen to it.
local function importEntries(book)
    local plan = curPlan
    if not plan then
        return { { text = GREY .. "Paste lines into the Import box on the right. Each line is checked here as you paste.|r" },
                 { text = GREY .. "Format: ML||NFL||PHI @ DAL||2026-11-26T16:30-05:00||PHI:-150||DAL:+130   (also SPREAD and TOTAL)|r" },
                 { text = GREY .. "To settle: FINAL||NFL||PHI @ DAL||PHI:24||DAL:20   (the final score: settles that game's moneyline, spreads and totals)|r" } }
    end
    local entries = {}
    for _, it in ipairs(plan.items) do
        local s = it.spec
        if it.status == "settle" then
            local f = it.final
            local picks = {}
            for _, st in ipairs(it.settles) do picks[#picks + 1] = esc(st.pick) end
            local skipped = it.skipped > 0 and (" (" .. it.skipped .. " already settled or not started: left alone)") or ""
            entries[#entries + 1] = { h = 40, text = ("%sSETTLE|r  %s   %s %d - %s %d"):format(GREEN, esc(f.event),
                esc(f.scores[1].label), f.scores[1].score, esc(f.scores[2].label), f.scores[2].score),
                sub = short(table.concat(picks, ", ") .. skipped, 110) }
        elseif it.status == "none" then
            entries[#entries + 1] = { h = 22, text = ("%sSKIP|r  %s%s: %s|r"):format(GREY, GREY, esc(it.final.event), it.why) }
        elseif it.status == "ok" then
            local lineText = s.type == "spread" and ("  " .. esc(s.selections[1].label) .. " " .. signed(s.line))
                          or s.type == "total" and ("  " .. ("%g"):format(s.line)) or ""
            entries[#entries + 1] = { h = 22, text = ("%sNEW|r  %s  %s%s   %s %s / %s %s   closes %s"):format(GREEN,
                TYPE_NAME[s.type], esc(s.event), lineText, esc(s.selections[1].label), Odds.FormatAmerican(s.selections[1].odds),
                esc(s.selections[2].label), Odds.FormatAmerican(s.selections[2].odds), when(s.closesAt)) }
        elseif it.status == "update" then
            local m = book.markets[it.marketId]
            local parts = {}
            for i = 1, 2 do
                local label1 = esc(m.selections[i].label)
                if it.changes[i] then
                    parts[#parts + 1] = ("%s %s -> %s%s|r"):format(label1, Odds.FormatAmerican(it.before[i]), GOLD, Odds.FormatAmerican(it.changes[i]))
                else
                    parts[#parts + 1] = ("%s %s"):format(label1, Odds.FormatAmerican(m.selections[i].odds))
                end
            end
            local lineText = ""
            if it.newLine then
                local a, b = it.beforeLine, it.newLine
                lineText = (s.type == "spread" and ("line %s -> %s%s|r   "):format(signed(a), GOLD, signed(b))
                                               or ("line %g -> %s%g|r   "):format(a, GOLD, b))
            end
            entries[#entries + 1] = { h = 22, text = ("%sUPDATE|r  %s  %s   %s%s"):format(GOLD, TYPE_NAME[s.type], esc(s.event),
                lineText, table.concat(parts, " / ")) }
        elseif it.status == "duplicate" then
            entries[#entries + 1] = { h = 22, text = ("%sSKIP|r  %s%s: already posted with these odds (same type, game, time and line)|r"):format(
                GREY, GREY, esc(s.event)) }
        elseif it.status == "started" then
            entries[#entries + 1] = { h = 22, text = ("%sSKIP|r  %s%s: %s|r"):format(GOLD, GREY, esc(s.event), it.why) }
        else
            entries[#entries + 1] = { h = 40, text = ("%sERROR|r  line %d: %s"):format(RED, it.line, it.err),
                                      sub = esc(short(it.text, 110)) }
        end
    end
    return entries
end

local ENTRIES = { bets = betEntries, members = memberEntries, ledger = ledgerEntries, import = importEntries }

------------------------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------------------------

local function counts(book)
    local live, pending = 0, 0
    for _, m in pairs(book.markets) do if m.status == "open" or m.status == "locked" then live = live + 1 end end
    for _, m in pairs(book.members) do if m.status == "pending" then pending = pending + 1 end end
    return live, pending, Bookie.OpenStakes(book).count
end

function UI.Refresh()
    if not frame then return end
    local book = currentBook()

    ui.title:SetText(book and ("SteveBook: Bookie - " .. esc(book.name)) or "SteveBook: Bookie")
    ui.book:SetText(book and (esc(book.name) .. "  [" .. book.code .. "]") or "No book yet")
    ui.codeBox.code = book and book.code or ""
    ui.codeBox:SetText(book and book.code or "")
    for name, b in pairs(ui.tabs) do b:SetEnabled(tab ~= name) end
    local live, pending, openBets = 0, 0, 0
    if book then live, pending, openBets = counts(book) end
    ui.tabs.markets:SetText(live > 0 and ("Markets (%d)"):format(live) or "Markets")
    ui.tabs.bets:SetText(openBets > 0 and ("Bets (%d)"):format(openBets) or "Bets")
    ui.tabs.members:SetText(pending > 0 and ("Members (%d pending)"):format(pending) or "Members")

    if view ~= "list" then return end      -- don't disturb a form or prompt in progress
    applyLayout()
    if tab == "markets" or tab == "import" then refreshPanel(book) end
    if not book then
        render({ { text = GREY .. "No books yet. Click + New to create one.|r" } })
    elseif tab == "markets" then
        renderMarkets(book)
    else
        render(ENTRIES[tab](book))
    end
end

local function setTab(name)
    tab = name
    ledgerPlayer = nil
    if view ~= "list" then view = "list" end
    scroll:SetVerticalScroll(0)
    UI.Refresh()
end

local function cycleBook()
    local list = Net.MyBooks()
    if #list == 0 then return askNewBook() end
    local cur, idx = currentBook(), 1
    for i, b in ipairs(list) do if cur and b.id == cur.id then idx = i end end
    Model.PickBook(SteveBookDB, list[idx % #list + 1].code)
    ledgerPlayer, betFilter = nil, {}
    ui.panel.box:SetText("")               -- pasted lines belong to the book they were pasted for
    if view ~= "list" then setView("list") end
    UI.Refresh()
end

-- The import box changed (typing, pasting, or SetText): update the summary, and the preview list
-- when the Import tab is showing it.
local function onImportChanged()
    if not frame then return end
    local book = currentBook()
    refreshPanel(book)
    if book and view == "list" and tab == "import" then render(importEntries(book)) end
end

local function buildImportPanel()
    local p = CreateFrame("Frame", nil, frame)
    p:SetPoint("TOPRIGHT", -MARGIN, -CONTENT_Y)
    p:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
    p:SetWidth(PANEL_W)
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    p.bg:SetColorTexture(0, 0, 0, 0.25)
    p.title = label(p, "GameFontNormal")
    p.title:SetPoint("TOPLEFT", 10, -8)
    p.title:SetText("Import lines")
    p.help = label(p, "GameFontHighlight")
    p.help:SetPoint("TOPLEFT", 10, -28)
    p.help:SetWidth(PANEL_W - 20)
    p.help:SetText(GREY .. "Paste lines from your script, one per line. Market lines post new markets or update the odds of open ones. FINAL lines (a final score) settle that game.|r")

    -- multi-line paste box inside a scroll frame
    p.boxBg = p:CreateTexture(nil, "BACKGROUND")
    p.boxBg:SetPoint("TOPLEFT", 8, -92)
    p.boxBg:SetPoint("BOTTOMRIGHT", -8, 165)
    p.boxBg:SetColorTexture(0, 0, 0, 0.4)
    p.scroll = CreateFrame("ScrollFrame", nil, p)
    p.scroll:SetPoint("TOPLEFT", 12, -96)
    p.scroll:SetPoint("BOTTOMRIGHT", -12, 169)
    p.box = CreateFrame("EditBox", nil, p.scroll)
    p.box:SetMultiLine(true)
    p.box:SetFontObject("GameFontHighlight")
    p.box:SetAutoFocus(false)
    p.box:SetWidth(PANEL_W - 28)
    p.box:SetHeight(300)
    p.box:SetScript("OnEscapePressed", p.box.ClearFocus)
    p.box:SetScript("OnTextChanged", onImportChanged)
    p.scroll:SetScrollChild(p.box)

    -- live summary, one line per outcome
    p.sumBg = p:CreateTexture(nil, "BACKGROUND")
    p.sumBg:SetPoint("BOTTOMLEFT", 8, 46)
    p.sumBg:SetPoint("BOTTOMRIGHT", -8, 46)
    p.sumBg:SetHeight(113)
    p.sumBg:SetColorTexture(0.1, 0.2, 0.1, 0.35)
    p.sum = {}
    for i = 1, 6 do
        p.sum[i] = label(p, "GameFontHighlight")
        p.sum[i]:SetPoint("BOTTOMLEFT", 14, 46 + (6 - i) * 17 + 6)
        p.sum[i]:SetWidth(PANEL_W - 28)
        p.sum[i]:SetWordWrap(false)
    end

    p.go = button(p, "Import", PANEL_W - 100, confirmImport)
    p.go:SetSize(PANEL_W - 100, 30)
    p.go:SetPoint("BOTTOMLEFT", 8, 10)
    p.clear = button(p, "Clear", 76, function()
        p.box:SetText("")
        onImportChanged()
    end)
    p.clear:SetSize(76, 30)
    p.clear:SetPoint("BOTTOMRIGHT", -8, 10)
    p:Hide()
    ui.panel = p
end

local function build()
    -- Named so Escape can close it (UISpecialFrames only takes global names).
    frame = CreateFrame("Frame", "SteveBookBookieFrame", UIParent, "BasicFrameTemplateWithInset")
    if UISpecialFrames then table.insert(UISpecialFrames, "SteveBookBookieFrame") end
    frame:SetSize(WIN_W, WIN_H)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("HIGH")
    frame:Hide()
    ui.frame = frame

    ui.title = label(frame, "GameFontNormal", "CENTER")
    ui.title:SetPoint("TOP", 0, -5)
    ui.title:SetText("SteveBook: Bookie")

    ui.book = button(frame, "", 250, cycleBook)
    ui.book:SetPoint("TOPLEFT", 12, -30)
    ui.new = button(frame, "+ New", 60, askNewBook)
    ui.new:SetPoint("LEFT", ui.book, "RIGHT", 6, 0)

    -- Join code: a read-only box you can click and Ctrl+C from (WoW has no clipboard API).
    ui.codeBox = editBox(frame, 110, 16)
    ui.codeBox:SetPoint("TOPRIGHT", -16, -30)
    ui.codeBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    ui.codeBox:SetScript("OnTextChanged", function(self, byUser)
        if byUser then self:SetText(self.code or ""); self:HighlightText() end
    end)
    local codeLabel = label(frame, "GameFontNormal", "RIGHT")
    codeLabel:SetPoint("RIGHT", ui.codeBox, "LEFT", -8, 0)
    codeLabel:SetText("Join code (click, Ctrl+C):")

    ui.tabs = {}
    local prev
    for _, t in ipairs({ { "markets", "Markets", 110 }, { "bets", "Bets", 90 },
                         { "members", "Members", 140 }, { "ledger", "Ledger", 80 }, { "import", "Import", 80 } }) do
        local b = button(frame, t[2], t[3], function() setTab(t[1]) end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 12, -58) end
        ui.tabs[t[1]] = b
        prev = b
    end

    -- Markets toolbar and column headings
    ui.newMarket = button(frame, "+ New market", 110, function() openForm("new") end)
    ui.newMarket:SetPoint("TOPLEFT", MARGIN, -CONTENT_Y)
    ui.lockAll = button(frame, "Lock all", 80, function()
        local book = currentBook()
        if book then askLockAll(book) end
    end)
    ui.lockAll:SetPoint("LEFT", ui.newMarket, "RIGHT", 6, 0)
    ui.openStakes = label(frame, "GameFontHighlight", "RIGHT")
    ui.openStakes:SetPoint("TOPRIGHT", -(MARGIN + PANEL_W + GAP + 4), -(CONTENT_Y + 5))
    ui.head = CreateFrame("Frame", nil, frame)
    ui.head:SetPoint("TOPLEFT", MARGIN, -HEAD_Y)
    ui.head:SetSize(WIN_W - 2 * MARGIN - PANEL_W - GAP, 16)
    for _, h in ipairs({ { "Game", COL.game, "LEFT" }, { "Market", COL.market, "LEFT" },
                         { "Odds (edit)", { x = COL.odds1.x, w = 100 }, "LEFT" }, { "Closes", COL.closes, "LEFT" },
                         { "Status", COL.status, "LEFT" }, { "At risk", COL.risk, "RIGHT" } }) do
        local fs = label(ui.head, "GameFontNormalSmall", h[3])
        fs:SetPoint("LEFT", ui.head, "LEFT", h[2].x, 0)
        fs:SetWidth(h[2].w)
        fs:SetText(h[1])
    end

    -- list view
    scroll = CreateFrame("ScrollFrame", nil, frame)
    scroll:SetPoint("TOPLEFT", MARGIN, -CONTENT_Y)
    scroll:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(WIN_W - 2 * MARGIN, 1)
    scroll:SetScrollChild(content)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, content:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 40)))
    end)
    ui.scroll = scroll

    buildImportPanel()

    -- prompt view
    local p = CreateFrame("Frame", nil, frame)
    p:SetPoint("TOPLEFT", MARGIN, -CONTENT_Y)
    p:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
    p.text = label(p, "GameFontNormal")
    p.text:SetPoint("TOPLEFT", 0, -8)
    p.text:SetWidth(WIN_W - 60)
    p.input = editBox(p, 260, 40)
    p.input:SetPoint("TOPLEFT", 6, -48)
    p.input:SetScript("OnEnterPressed", p.input.ClearFocus)
    p.input2 = editBox(p, 260, 60)             -- optional second line (payment note)
    p.input2:SetPoint("TOPLEFT", 6, -80)
    p.input2:SetScript("OnEnterPressed", p.input2.ClearFocus)
    p.hint2 = label(p, "GameFontHighlight")
    p.hint2:SetPoint("LEFT", p.input2, "RIGHT", 10, 0)
    p.hint2:SetText(GREY .. "note (optional)|r")
    p.msg = label(p, "GameFontHighlight")
    p.msg:SetPoint("TOPLEFT", 0, -112)
    p.msg:SetWidth(WIN_W - 60)
    p.btn = {}
    for i = 1, PROMPT_BTN do
        p.btn[i] = button(p, "", 120, nil)
        p.btn[i]:SetPoint("TOPLEFT", (i - 1) * 126, -140)
    end
    p:Hide()
    ui.prompt = p

    -- market form view
    local f = CreateFrame("Frame", nil, frame)
    f:SetPoint("TOPLEFT", MARGIN, -CONTENT_Y)
    f:SetPoint("BOTTOMRIGHT", -MARGIN, MARGIN)
    f.title = label(f, "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 0, -4)
    f.f = {}
    local function field(key, labelText, lx, ex, y, w, maxLetters)
        if labelText ~= "" then labelAt(f, labelText, lx, y - 4) end
        local e = editBox(f, w, maxLetters)
        e:SetPoint("TOPLEFT", ex, y)
        f.f[key] = e
        return e
    end
    field("sport", "Sport", 0, 70, -32, 110, 20)
    field("event", "Event", 200, 250, -32, 300, 60)
    labelAt(f, "Type", 0, -72)
    f.typeBtn = button(f, "ML", 80, function()
        formState.type = NEXT_TYPE[formState.type]
        if formState.type == "total" then
            if f.f.label1:GetText() == "" and f.f.label2:GetText() == "" then
                f.f.label1:SetText("Over"); f.f.label2:SetText("Under")
            end
        end
        syncTypeWidgets()
    end)
    f.typeBtn:SetPoint("TOPLEFT", 70, -68)
    f.lineLabel = labelAt(f, "Line", 200, -72)
    field("line", "", 0, 250, -68, 90, 10)
    field("label1", "Side 1", 0, 70, -104, 200, 24)
    field("odds1", "Odds", 300, 350, -104, 80, 6)
    field("label2", "Side 2", 0, 70, -136, 200, 24)
    field("odds2", "Odds", 300, 350, -136, 80, 6)
    field("closes", "Closes in", 0, 70, -176, 90, 10)
    labelAt(f, "e.g. 30m, 2h, 1d, 1h30m", 180, -180, "GameFontHighlight")
    f.msg = label(f, "GameFontHighlight")
    f.msg:SetPoint("TOPLEFT", 0, -214)
    f.msg:SetWidth(WIN_W - 60)
    f.ok = button(f, "Create", 100, submitForm)
    f.ok:SetPoint("TOPLEFT", 0, -244)
    f.cancel = button(f, "Cancel", 100, function() setView("list"); UI.Refresh() end)
    f.cancel:SetPoint("LEFT", f.ok, "RIGHT", 6, 0)
    f:Hide()
    ui.form = f
end

function UI.Show()
    if not frame then build() end
    frame:Show()
    setView(view)
    if not currentBook() and view == "list" then askNewBook() end
    UI.Refresh()
end

function UI.Hide() if frame then frame:Hide() end end
function UI.Toggle() if shown() then UI.Hide() else UI.Show() end end

-- Test seam: the widgets and the pooled rows.
UI.widgets = ui
UI.rows = rows
UI.mrows = mrows

Net.Subscribe(function() if shown() then UI.Refresh() end end)

return UI
