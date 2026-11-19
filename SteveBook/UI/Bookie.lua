-- UI/Bookie.lua: the bookie window (SPEC §6). Markets and Members tabs, a book picker, and the
-- join code. All state changes go through ns.BookieNet (which also does the broadcasting); form
-- parsing is Bookie.ParseMarketForm / ParseEditForm (pure, tested). Exposes
-- ns.UI.Bookie = { Show, Hide, Toggle, Refresh }.
-- Same frame templates as UI/Bettor.lua: BasicFrameTemplateWithInset, UIPanelButtonTemplate,
-- InputBoxTemplate (checked in game with the /run line in README.md).
local ADDON, ns = ...
ns.UI = ns.UI or {}

local Model, Bookie, Odds, Net, Import = ns.Model, ns.Bookie, ns.Odds, ns.BookieNet, ns.Import
local UI = {}
ns.UI.Bookie = UI

local WIN_W, WIN_H = 640, 520
local GREEN, RED, GOLD, GREY = "|cff40ff40", "|cffff5050", "|cffffd100", "|cff999999"
local MAX_BTN = 4            -- buttons per list row
local PROMPT_BTN = 4         -- buttons in the prompt view
local FINALS_SHOWN = 15          -- settled/void markets listed below the live ones

local frame, content, scroll
local ui = {}                    -- widgets, also handy for the smoke test
local rows = {}
local tab, view = "markets", "list"       -- tab: markets|bets|members|ledger|import; view: list|form|prompt|import
local importPlan                         -- Import.Plan result while the Import tab shows a preview
local formState = { mode = "new", type = "moneyline" }
local promptSeq = 0
local ledgerPlayer                       -- set while the Ledger tab shows one player's payments
local betFilter = {}                     -- Bets tab filters: { status, bettor, marketId }

local function say(msg) print(GOLD .. "SteveBook:|r " .. msg) end
local function now() return GetServerTime() end
local function money(c) return Odds.FormatMoney(c) end
local function when(t) return date("%a %b %d %H:%M", t) end
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
}
local function describe(code) return ERRORS[code] or tostring(code) end

local TYPE_NAME = { moneyline = "ML", spread = "Spread", total = "Total" }
local function signed(n) return (n > 0 and "+" or "") .. ("%g"):format(n) end

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

------------------------------------------------------------------------------------------
-- List view: pooled rows in a scroll frame. entry = { text, sub, h, buttons = { {label, fn} } }
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
            r.sub:SetText(GREY .. e.sub .. "|r")
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
-- Prompt view: a message, an optional text box, up to three buttons.
-- spec = { text, input = defaultText | nil, buttons = { {label, fn(inputText) -> errorString|nil} } }
-- A button whose fn returns a string keeps the prompt open and shows it.
------------------------------------------------------------------------------------------

local function setView(v)
    view = v
    ui.scroll:SetShown(v == "list")
    ui.form:SetShown(v == "form")
    ui.prompt:SetShown(v == "prompt")
    ui.import:SetShown(v == "import")
end

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
        f.title:SetText(("Edit %s: leave a box alone to keep it. Changes only affect new bets."):format(market.event))
        f.f.sport:SetText(market.sport or "")
        f.f.event:SetText(market.event)
        f.f.label1:SetText(market.selections[1].label)
        f.f.label2:SetText(market.selections[2].label)
        f.f.odds1:SetText(Odds.Format(market.selections[1].odds))
        f.f.odds2:SetText(Odds.Format(market.selections[2].odds))
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
-- Entries
------------------------------------------------------------------------------------------

local function askSettle(book, m)
    local s1, s2 = m.selections[1], m.selections[2]
    ask({ text = ("Settle %s: who won?"):format(m.event), buttons = {
        { s1.label .. " won", function() if not Net.Settle(book, m.id, s1.id) then return "Could not settle." end end },
        { s2.label .. " won", function() if not Net.Settle(book, m.id, s2.id) then return "Could not settle." end end },
        { "Push", function() if not Net.Settle(book, m.id, "push") then return "Could not settle." end end },
        { "Cancel" },
    } })
end

local function askVoid(book, m)
    ask({ text = ("Void %s? Every bet on it is refunded."):format(m.event), buttons = {
        { "Void market", function() local ok, err = Net.VoidMarket(book, m.id); if not ok then return describe(err) end end },
        { "Cancel" },
    } })
end

local function marketEntries(book)
    local live, final = {}, {}
    for _, m in pairs(book.markets) do
        if m.status == "open" or m.status == "locked" then live[#live + 1] = m else final[#final + 1] = m end
    end
    table.sort(live, function(a, b)
        if a.closesAt ~= b.closesAt then return a.closesAt < b.closesAt end
        return a.id < b.id
    end)
    table.sort(final, function(a, b) return (a.settledAt or 0) > (b.settledAt or 0) end)

    local entries = {}
    if #live == 0 and #final == 0 then
        entries[1] = { text = GREY .. "No markets yet. Click + Market to post one.|r" }
        return entries
    end
    local t = now()
    local function add(m)
        local s1, s2 = m.selections[1], m.selections[2]
        -- closesAt is the game's start: once it has passed the market takes no bets, whatever its
        -- stored status says (the Sweep ticker may not have caught up yet).
        local started = (m.status == "open" or m.status == "locked") and Bookie.HasStarted(m, t)
        local tag = ({ open = GREEN .. "OPEN", locked = GOLD .. "LOCKED", settled = GREY .. "SETTLED", void = GREY .. "VOID" })[m.status]
        if started then tag = GOLD .. "STARTED" end
        local lineText = ""
        if m.type == "spread" then lineText = ("  %s %s"):format(s1.label, signed(m.line))
        elseif m.type == "total" then lineText = ("  %g"):format(m.line) end
        local result = ""
        if m.status == "settled" then
            local w = m.result == "push" and "Push" or (m.selections[m.result] and m.selections[m.result].label .. " won") or "?"
            result = "  " .. GOLD .. w .. "|r"
        end
        local text = ("%s|r  %s  %s%s%s"):format(tag, TYPE_NAME[m.type], m.event, lineText, result)

        local sub = ("%s %s / %s %s"):format(s1.label, Odds.Format(s1.odds), s2.label, Odds.Format(s2.odds))
        local ex = Bookie.MarketExposure(book, m.id)
        if ex and ex.staked > 0 and (m.status == "open" or m.status == "locked") then
            sub = sub .. ("   |   %s staked   |   book if %s wins %s, if %s wins %s"):format(
                money(ex.staked), s1.label, money(ex.net[1]), s2.label, money(ex.net[2]))
        end
        if m.status == "open" or m.status == "locked" then
            sub = sub .. (started and "   |   started " or "   |   closes ") .. when(m.closesAt)
        end

        local buttons
        if started then
            -- only Settle and Void remain: no edits, no extending the close time, no reopening
            buttons = { { "Settle", function() askSettle(book, m) end },
                        { "Void", function() askVoid(book, m) end } }
        elseif m.status == "open" then
            buttons = { { "Odds", function() openForm("edit", m) end },
                        { "Lock", function() act(Net.LockMarket, book, m.id) end },
                        { "Settle", function() askSettle(book, m) end },
                        { "Void", function() askVoid(book, m) end } }
        elseif m.status == "locked" then
            buttons = { { "Odds", function() openForm("edit", m) end },
                        { "Unlock", function() act(Net.UnlockMarket, book, m.id) end },
                        { "Settle", function() askSettle(book, m) end },
                        { "Void", function() askVoid(book, m) end } }
        elseif m.status == "settled" then
            buttons = { { "Re-settle", function() askSettle(book, m) end },
                        { "Void", function() askVoid(book, m) end } }
        else
            buttons = { { "Settle", function() askSettle(book, m) end } }
        end
        entries[#entries + 1] = { text = text, sub = sub, h = 42, buttons = buttons }
    end
    for _, m in ipairs(live) do add(m) end
    for i = 1, math.min(#final, FINALS_SHOWN) do add(final[i]) end
    return entries
end

local STATUS_ORDER = { pending = 1, active = 2, removed = 3 }

local function askLimit(book, name, m)
    ask({ text = ("Credit limit for %s (e.g. 50g). Leave blank for no limit."):format(name),
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
    local rows = Bookie.LedgerRows(book)
    if #rows == 0 then
        entries[2] = { text = GREY .. "Nothing to settle yet.|r" }
        return entries
    end
    for _, r in ipairs(rows) do
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
-- Bets tab: every bet, filterable by status / bettor / market
------------------------------------------------------------------------------------------

local BETS_SHOWN = 100
local STATUS_LABEL = { accepted = "open", won = "won", lost = "lost", push = "push", void = "void" }

local function askVoidBet(book, b)
    ask({ text = ("Void bet #%d (%s, %s)? It is refunded and any result is reversed."):format(b.id, b.bettor, money(b.stake)),
          buttons = {
        { "Void bet", function() local ok, err = Net.VoidBet(book, b.id); if not ok then return describe(err) end end },
        { "Cancel" },
    } })
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
        local m = book.markets[b.marketId]
        local sel = m and m.selections[b.selectionId]
        local result
        if b.status == "accepted" then result = GOLD .. "OPEN|r"
        elseif b.status == "won" then result = GREEN .. "WON " .. money(b.delta or 0) .. "|r"
        elseif b.status == "lost" then result = RED .. "LOST " .. money(-(b.delta or 0)) .. "|r"
        elseif b.status == "push" then result = GREY .. "PUSH|r"
        else result = GREY .. "VOID|r" end
        entries[#entries + 1] = {
            text = ("#%d  %s  %s on %s %s  (%s)  %s"):format(b.id, b.bettor, money(b.stake),
                sel and sel.label or "?", Odds.Format(b.odds), m and m.event or "?", result),
            h = 24,
            buttons = b.status ~= "void" and { { "Void", function() askVoidBet(book, b) end } } or nil,
        }
    end
    if #bets > BETS_SHOWN then
        entries[#entries + 1] = { text = GREY .. ("... and %d more. Use the filters to narrow it down."):format(#bets - BETS_SHOWN) .. "|r" }
    end
    return entries
end

------------------------------------------------------------------------------------------
-- Import tab: paste -> preview -> confirm (format: SPEC §7, parser: Import.lua)
------------------------------------------------------------------------------------------

local function showImportEditor(msg)
    importPlan = nil
    ui.import.msg:SetText(msg or "")
    setView("import")
    UI.Refresh()
end

local function previewImport()
    local book = currentBook()
    if not book then return ui.import.msg:SetText("Create a book first (+ New).") end
    local plan = Import.Plan(book, ui.import.box:GetText(), now())
    if #plan.items == 0 then return ui.import.msg:SetText("Nothing to import: paste some lines first.") end
    importPlan = plan
    setView("list")
    UI.Refresh()
end

-- Re-plans from the text box at confirm time, so a stale preview can't import markets that have
-- closed since, or post duplicates after a double click.
local function confirmImport()
    local book = currentBook()
    if not book then return end
    local plan = Import.Plan(book, ui.import.box:GetText(), now())
    local added, failed = 0, {}
    for _, it in ipairs(plan.items) do
        if it.status == "ok" then
            local m, err = Net.AddMarket(book, it.spec)
            if m then added = added + 1 else failed[#failed + 1] = ("line %d: %s"):format(it.line, describe(err)) end
        end
    end
    say(("Imported %d market%s."):format(added, added == 1 and "" or "s"))
    for _, f in ipairs(failed) do say("Skipped " .. f) end
    if #failed == 0 then ui.import.box:SetText("") end    -- keep the text if something failed, to fix and retry
    importPlan = nil
    tab = "markets"
    setView("list")
    UI.Refresh()
end

local function importEntries(book)
    local plan = importPlan
    local entries = { { h = 26, bw = 110, text = ("%s%d to import|r   %s%d duplicate|r   %s%d with errors|r"):format(
            GREEN, plan.ok, GREY, plan.duplicate, plan.errors > 0 and RED or GREY, plan.errors),
        buttons = plan.ok > 0 and { { ("Import %d"):format(plan.ok), confirmImport }, { "Back", function() showImportEditor() end } }
                              or { { "Back", function() showImportEditor() end } } } }
    for _, it in ipairs(plan.items) do
        if it.status == "ok" then
            local s = it.spec
            local lineText = s.type == "spread" and ("  " .. s.selections[1].label .. " " .. signed(s.line))
                          or s.type == "total" and ("  " .. ("%g"):format(s.line)) or ""
            entries[#entries + 1] = { h = 22, text = ("%sOK|r  %s  %s%s   %s %s / %s %s   closes %s"):format(GREEN,
                TYPE_NAME[s.type], s.event, lineText, s.selections[1].label, Odds.Format(s.selections[1].odds),
                s.selections[2].label, Odds.Format(s.selections[2].odds), when(s.closesAt)) }
        elseif it.status == "duplicate" then
            entries[#entries + 1] = { h = 22, text = ("%sSKIP|r  %s%s: already posted (same type, game, time and line)|r"):format(
                GREY, GREY, it.spec.event) }
        else
            entries[#entries + 1] = { h = 40, text = ("%sERROR|r  line %d: %s"):format(RED, it.line, it.err),
                                      sub = esc(short(it.text, 90)) }
        end
    end
    return entries
end

local ENTRIES = { markets = marketEntries, bets = betEntries, members = memberEntries, ledger = ledgerEntries,
                  import = importEntries }

------------------------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------------------------

local function pendingCount(book)
    local n = 0
    for _, m in pairs(book.members) do if m.status == "pending" then n = n + 1 end end
    return n
end

function UI.Refresh()
    if not frame then return end
    local book = currentBook()

    ui.book:SetText(book and (book.name .. "  [" .. book.code .. "]") or "No book yet")
    ui.codeBox.code = book and book.code or ""
    ui.codeBox:SetText(book and book.code or "")
    ui.newMarket:SetShown(book ~= nil and tab == "markets")
    for name, b in pairs(ui.tabs) do b:SetEnabled(tab ~= name) end
    local pending = book and pendingCount(book) or 0
    ui.tabs.members:SetText(pending > 0 and ("Members (" .. pending .. ")") or "Members")

    if view ~= "list" then return end      -- don't disturb a form or prompt in progress
    if not book then
        render({ { text = GREY .. "No books yet. Click + New to create one.|r" } })
    elseif tab == "import" and not importPlan then
        setView("import")                  -- the list view only shows an import preview
    else
        render(ENTRIES[tab](book))
    end
end

local function setTab(name)
    tab = name
    ledgerPlayer, importPlan = nil, nil
    if name == "import" then setView("import") elseif view ~= "list" then setView("list") end
    UI.Refresh()
end

local function cycleBook()
    local list = Net.MyBooks()
    if #list == 0 then return askNewBook() end
    local cur, idx = currentBook(), 1
    for i, b in ipairs(list) do if cur and b.id == cur.id then idx = i end end
    Model.PickBook(SteveBookDB, list[idx % #list + 1].code)
    ledgerPlayer, betFilter = nil, {}
    if view ~= "list" then setView("list") end
    UI.Refresh()
end

local function build()
    frame = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
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

    local title = label(frame, "GameFontNormal", "CENTER")
    title:SetPoint("TOP", 0, -5)
    title:SetText("SteveBook: Bookie")

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
    codeLabel:SetText("Join code:")

    ui.tabs = {}
    local prev
    for _, t in ipairs({ { "markets", "Markets", 90 }, { "bets", "Bets", 70 },
                         { "members", "Members", 110 }, { "ledger", "Ledger", 80 }, { "import", "Import", 80 } }) do
        local b = button(frame, t[2], t[3], function() setTab(t[1]) end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 12, -58) end
        ui.tabs[t[1]] = b
        prev = b
    end
    ui.newMarket = button(frame, "+ Market", 80, function() openForm("new") end)
    ui.newMarket:SetPoint("TOPRIGHT", -16, -58)

    -- list view
    scroll = CreateFrame("ScrollFrame", nil, frame)
    scroll:SetPoint("TOPLEFT", 14, -90)
    scroll:SetPoint("BOTTOMRIGHT", -14, 14)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(WIN_W - 28, 1)
    scroll:SetScrollChild(content)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, content:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 40)))
    end)
    ui.scroll = scroll

    -- prompt view
    local p = CreateFrame("Frame", nil, frame)
    p:SetPoint("TOPLEFT", 14, -90)
    p:SetPoint("BOTTOMRIGHT", -14, 14)
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

    -- import view: a multi-line paste box. APIs not used elsewhere in the addon: EditBox:SetMultiLine,
    -- SetFontObject with a font name, Frame:CreateTexture + Texture:SetColorTexture (README /run check).
    local im = CreateFrame("Frame", nil, frame)
    im:SetPoint("TOPLEFT", 14, -90)
    im:SetPoint("BOTTOMRIGHT", -14, 14)
    im.help = label(im, "GameFontNormal")
    im.help:SetPoint("TOPLEFT", 0, -2)
    im.help:SetWidth(WIN_W - 60)
    im.help:SetText("Paste lines from your line-pulling script, one market per line, then Preview. # starts a comment.\n"
        .. GREY .. "ML||NFL||PHI @ DAL||2026-11-26T16:30-05:00||PHI:-150||DAL:+130|r")   -- "||" shows one "|"
    im.bg = im:CreateTexture(nil, "BACKGROUND")
    im.bg:SetPoint("TOPLEFT", 0, -44)
    im.bg:SetPoint("BOTTOMRIGHT", -4, 40)
    im.bg:SetColorTexture(0, 0, 0, 0.4)
    im.scroll = CreateFrame("ScrollFrame", nil, im)
    im.scroll:SetPoint("TOPLEFT", 4, -46)
    im.scroll:SetPoint("BOTTOMRIGHT", -8, 42)
    im.box = CreateFrame("EditBox", nil, im.scroll)
    im.box:SetMultiLine(true)
    im.box:SetFontObject("GameFontHighlight")
    im.box:SetAutoFocus(false)
    im.box:SetWidth(WIN_W - 70)
    im.box:SetHeight(340)
    im.box:SetScript("OnEscapePressed", im.box.ClearFocus)
    im.scroll:SetScrollChild(im.box)
    im.msg = label(im, "GameFontHighlight")
    im.msg:SetPoint("BOTTOMLEFT", 230, 14)
    im.msg:SetWidth(WIN_W - 280)
    im.preview = button(im, "Preview", 100, previewImport)
    im.preview:SetPoint("BOTTOMLEFT", 0, 8)
    im.clear = button(im, "Clear", 100, function() im.box:SetText(""); im.msg:SetText("") end)
    im.clear:SetPoint("LEFT", im.preview, "RIGHT", 6, 0)
    im:Hide()
    ui.import = im

    -- market form view
    local f = CreateFrame("Frame", nil, frame)
    f:SetPoint("TOPLEFT", 14, -90)
    f:SetPoint("BOTTOMRIGHT", -14, 14)
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

Net.Subscribe(function() if shown() then UI.Refresh() end end)

return UI
