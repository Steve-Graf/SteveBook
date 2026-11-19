-- UI/Bettor.lua: the bettor window (SPEC §6) and the bettor side of the protocol (SPEC §5).
-- Bettors only REQUEST; the bookie validates. All state lives in ns.Cache (SteveBookDB.cache).
-- Exposes ns.UI.Bettor = { Show, Hide, Toggle }.
local ADDON, ns = ...
ns.UI = ns.UI or {}

local Cache, Odds = ns.Cache, ns.Odds
local Bettor = {}
ns.UI.Bettor = Bettor

local PING_EVERY = 30
local REFRESH_EVERY = 5   -- while the window is open: games start, so the lists must age
local WIN_W, WIN_H = 540, 500
local GREEN, RED, GOLD, GREY = "|cff40ff40", "|cffff5050", "|cffffd100", "|cff999999"

local frame, tab, slip, showJoin
local rows = {}
local seq = 0

local function say(msg) print(GOLD .. "SteveBook:|r " .. msg) end
local function now() return GetServerTime() end
local function money(c) return Odds.FormatMoney(c) end
local function store() return SteveBookDB and SteveBookDB.cache end
local function shown() return frame and frame:IsShown() end

local function colorMoney(c)
    if c > 0 then return GREEN .. "+" .. money(c) .. "|r" end
    if c < 0 then return RED .. money(c) .. "|r" end
    return money(c)
end

local function when(t) return date("%a %b %d %H:%M", t) end

-- The book currently shown: the remembered one if it still exists, else the first active
-- book, else the first book at all.
local function currentBook()
    local st = store()
    if not st then return nil end
    local b = st.selected and Cache.Book(st, st.selected)
    if b then return b end
    local list = Cache.ListBooks(st)
    for _, x in ipairs(list) do if x.status == "active" then return x end end
    return list[1]
end

local function bookTitle(b) return (b.name and b.name ~= "" and b.name or "Book") .. " (" .. b.code .. ")" end

------------------------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------------------------

-- Returns true if Comm accepted the message (it may be queued until the channel is ready).
-- Failures are only announced when `loud` (a user action), so a 30s ping can't spam chat.
local function send(msgType, payload, code, loud)
    local ok, err = ns.Comm.Send(msgType, payload, code)
    if ok == false and loud then say("Could not send " .. msgType .. ": " .. tostring(err)) end
    return ok ~= false
end

local function requestJoin(code)
    code = Cache.NormalizeCode(code)
    if code == "" then return say("Enter a join code first.") end
    if not Cache.IsValidCode(code) then return say("That doesn't look like a join code (like NFL-K7Q2).") end
    local st = store()
    Cache.RequestJoin(st, code)
    st.selected = code
    showJoin = false
    send("JOIN_REQ", {}, code, true)
    say("Join request sent to " .. code .. ". Waiting for the bookie to approve.")
end

local function placeBet(code, marketId, selectionId, stake, odds)
    seq = seq + 1
    local ref = ("%d-%04d-%d"):format(now(), math.random(0, 9999), seq)
    local req = { ref = ref, marketId = marketId, selectionId = selectionId, stake = stake, odds = odds }
    Cache.NewPending(store(), code, req, now())
    if not send("BET_PLACE", req, code, true) then
        Cache.ApplyBetReject(store(), code, ref, "book_error", nil, now())
        return false
    end
    return true
end

-- Periodic PING per active book. First PONG after being offline triggers a SYNC_REQ.
local function tick()
    local st = store()
    if not st then return end
    local t = now()
    for _, b in ipairs(Cache.ListBooks(st)) do
        if b.status == "active" then
            send("PING", {}, b.code)
            Cache.ExpirePending(st, b.code, t)
        elseif b.status == "requested" then
            send("JOIN_REQ", {}, b.code)   -- idempotent on the bookie's side; covers a bookie who was offline
        end
    end
    if shown() then Bettor.Refresh() end
end

------------------------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------------------------

-- Look up the book a message is about. Messages for books we never asked about are ignored,
-- and once we know the bookie only their messages count.
local function bookFor(code, sender)
    local st = store()
    local b = st and Cache.Book(st, code)
    if not b then return nil end
    if b.owner and sender ~= b.owner then return nil end
    return b
end

local function betSummary(b, bet)
    local m = b.markets[bet.marketId]
    return ("%s %s @ %s for %s"):format(
        Cache.EventName(m), Cache.SelectionText(m, bet.selectionId), Odds.Format(bet.odds), money(bet.stake))
end

local handlers = {}

-- "Name-Realm" -> "Name".
local function baseName(name) return type(name) == "string" and name:match("^([^%-]+)") or nil end

function handlers.JOIN_OK(sender, p, code)
    local st = store()
    local b = st and Cache.Book(st, code)
    if not b or b.status == "active" then return end
    -- Anyone can whisper us "bookie" messages: only the character the payload names as the
    -- owner may approve us, and only if they are the one who sent it.
    if not baseName(sender) or baseName(sender) ~= baseName(p.ownerName) then return end
    Cache.SetMembership(st, code, true, p.bookName, sender)
    Cache.MarkPong(st, code, now(), sender)
    say("You were approved for " .. bookTitle(b) .. ".")
    send("SYNC_REQ", { rev = 0 }, code)
end

function handlers.JOIN_DENY(sender, p, code)
    local st = store()
    local b = st and Cache.Book(st, code)
    if not b then return end
    -- Same rule as JOIN_OK: the sender must be the character the payload names as the owner,
    -- and once we know the bookie (from JOIN_OK) it must be that character.
    local who = baseName(sender)
    if not who or who ~= baseName(p.ownerName) then return end
    if b.owner and who ~= baseName(b.owner) then return end
    Cache.SetMembership(st, code, false)
    say("Your request to join " .. code .. " was denied" .. (p.reason and (" (" .. p.reason .. ")") or "") .. ".")
end

function handlers.SYNC(sender, p, code)
    local b = bookFor(code, sender)
    if not b then return end
    Cache.ApplySync(store(), code, p, now())
    if p.bookName then b.name = p.bookName end
    Cache.MarkPong(store(), code, now(), sender)
end

function handlers.MARKET(sender, p, code)
    local b = bookFor(code, sender)
    if not b then return end
    local _, old = Cache.ApplyMarket(store(), code, p.market, now())
    b.rev = math.max(b.rev or 0, p.rev or 0)
    local m = p.market
    if (m.status == "settled" or m.status == "void") and not (old and old.status == m.status) then
        for _, bet in pairs(b.bets) do
            if bet.marketId == m.id then
                local res = m.status == "void" and "voided"
                    or (m.result == "push" and "push" or ("won by " .. Cache.SelectionLabel(m, m.result)))
                say(("%s %s: %s."):format(m.event, m.status == "void" and "was" or "settled", res))
                break
            end
        end
    end
end

function handlers.BET_ACK(sender, p, code)
    local b = bookFor(code, sender)
    if not b then return end
    Cache.ApplyBetAck(store(), code, p.ref, p.bet, p.balance)
    say("Bet accepted: " .. betSummary(b, p.bet) .. ".")
    if slip and slip.code == code then slip = nil end
end

function handlers.BET_REJECT(sender, p, code)
    local b = bookFor(code, sender)
    if not b then return end
    local bet = Cache.ApplyBetReject(store(), code, p.ref, p.reason, p.currentOdds, now(), p.available)
    if not bet then return end
    local text = Cache.ReasonText(p.reason)
    if p.reason == "odds_changed" and p.currentOdds then
        text = text .. " Now " .. Odds.Format(p.currentOdds) .. "; confirm again."
        if shown() then Bettor.OpenSlip(code, bet.marketId, bet.selectionId, p.currentOdds, bet.stake) end
    elseif p.reason == "credit_limit" and p.available then
        text = text .. " You can still bet " .. money(p.available) .. "."
    end
    say("Bet rejected: " .. text)
end

function handlers.BALANCE(sender, p, code)
    local b = bookFor(code, sender)
    if not b then return end
    local delta = p.balance - (b.balance or 0)
    local entry = delta ~= 0 and { amount = delta, at = now(), note = p.note } or nil
    Cache.ApplyBalance(store(), code, p.balance, entry)
    b.rev = math.max(b.rev or 0, p.rev or 0)
    say("Balance with " .. bookTitle(b) .. ": " .. colorMoney(p.balance) .. (p.note and (" (" .. p.note .. ")") or ""))
end

function handlers.PONG(sender, p, code)
    local st = store()
    local b = st and Cache.Book(st, code)
    if not b or b.status ~= "active" then return end
    local wasOnline = Cache.IsOnline(st, code, now())
    if not Cache.MarkPong(st, code, now(), sender) then return end
    if not wasOnline then send("SYNC_REQ", { rev = b.rev or 0 }, code) end
end

local registered
local function register()
    if registered or not (ns.Comm and ns.Comm.Register) then return end
    registered = true
    for msgType, fn in pairs(handlers) do
        ns.Comm.Register(msgType, function(sender, payload, code)
            fn(sender, payload, code)
            if shown() then Bettor.Refresh() end
        end)
    end
    C_Timer.NewTicker(PING_EVERY, tick)
    C_Timer.After(10, tick)
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

------------------------------------------------------------------------------------------
-- Body: a pooled list of rows inside a scroll frame
------------------------------------------------------------------------------------------

local scroll, content

local function getRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, content)
    r.text = label(r, "GameFontHighlight")
    r.text:SetPoint("LEFT", 0, 0)
    r.text:SetWordWrap(false)
    r.b1 = button(r, "", 200, nil)
    r.b2 = button(r, "", 200, nil)
    r.b1:SetPoint("LEFT", 60, 0)
    r.b2:SetPoint("LEFT", r.b1, "RIGHT", 6, 0)
    rows[i] = r
    return r
end

-- entries: { { text=, h=, header=true } | { market=Market, code= } }
local function render(entries)
    local y, width = 0, content:GetWidth()
    for i, e in ipairs(entries) do
        local r = getRow(i)
        local h = e.h or 18
        r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        r:SetSize(width, h)
        r:Show()
        if e.market then
            local m = e.market
            r.text:SetText(GREY .. ({ moneyline = "ML", spread = "Spread", total = "Total" })[m.type] .. "|r")
            r.text:SetWidth(56)
            for k, btn in ipairs({ r.b1, r.b2 }) do
                local sel = m.selections[k]   -- position only decides which button; ids come from sel.id
                btn:SetText(Cache.SelectionText(m, sel.id) .. "  " .. Odds.Format(sel.odds))
                btn:SetScript("OnClick", function() Bettor.OpenSlip(e.code, m.id, sel.id, sel.odds) end)
                btn:SetSize(200, h - 2)
                btn:Show()
            end
        else
            r.text:SetWidth(width)
            r.text:SetText(e.text)
            r.b1:Hide(); r.b2:Hide()
        end
        y = y + h
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(y, 1))
end

local function linesEntries(b, t)
    local out = {}
    local sports = Cache.Lines(store(), b.code, t)
    if #sports == 0 then out[1] = { text = GREY .. "No open lines right now." .. "|r" } end
    for _, s in ipairs(sports) do
        out[#out + 1] = { text = GOLD .. s.sport .. "|r", h = 22 }
        for _, ev in ipairs(s.events) do
            out[#out + 1] = { text = ev.event .. GREY .. "   closes " .. when(ev.closesAt) .. "|r" }
            for _, m in ipairs(ev.markets) do out[#out + 1] = { market = m, code = b.code, h = 26 } end
        end
    end
    return out
end

local function betLine(b, bet)
    local m = b.markets[bet.marketId]
    local head = ("%s  %s @ %s  stake %s"):format(
        Cache.EventName(m), Cache.SelectionText(m, bet.selectionId), Odds.Format(bet.odds), money(bet.stake))
    local st = bet.status
    if st == "pending" then return GREY .. "Pending|r  " .. head end
    if st == "accepted" then
        return GOLD .. "Open|r  " .. head .. GREY .. "  to win " .. money(Odds.Profit(bet.stake, bet.odds) or 0) .. "|r"
    end
    if st == "rejected" then
        return RED .. "Rejected|r  " .. head .. GREY .. "  " .. Cache.ReasonText(bet.rejectReason) .. "|r"
    end
    local d = Cache.BetDelta(bet)
    local word = ({ won = "Won", lost = "Lost", push = "Push", void = "Void" })[st] or st
    return word .. "  " .. head .. "  " .. (d and colorMoney(d) or "")
end

local function betsEntries(b)
    local bets = Cache.MyBets(store(), b.code)
    local out = {}
    out[#out + 1] = { text = GOLD .. "Open bets (" .. #bets.open .. ")|r", h = 22 }
    for _, bet in ipairs(bets.open) do out[#out + 1] = { text = betLine(b, bet) } end
    out[#out + 1] = { text = GOLD .. "Settled, last 14 days (" .. #bets.settled .. ")|r", h = 26 }
    if #bets.settled == 0 then out[#out + 1] = { text = GREY .. "None in the last 14 days.|r" } end
    for _, bet in ipairs(bets.settled) do out[#out + 1] = { text = betLine(b, bet) } end
    return out
end

local function balanceEntries(b)
    local out = {}
    local bal = b.balance or 0
    local who = bal > 0 and "The book owes you " or (bal < 0 and "You owe the book " or "All square: ")
    local color = bal > 0 and GREEN or (bal < 0 and RED or "")
    out[#out + 1] = { text = who .. color .. money(bal < 0 and -bal or bal) .. (color ~= "" and "|r" or ""), h = 28 }
    out[#out + 1] = { text = "Open bets at risk: " .. money(Cache.OpenRisk(store(), b.code)) }
    if b.creditLimit then
        out[#out + 1] = { text = "Credit limit: " .. money(b.creditLimit) ..
            "   still available: " .. money(Cache.CreditAvailable(store(), b.code) or 0), h = 22 }
    end
    out[#out + 1] = { text = GOLD .. "Recent changes|r", h = 26 }
    local p = b.payments or {}
    if #p == 0 then out[#out + 1] = { text = GREY .. "None yet." .. "|r" } end
    for i = #p, 1, -1 do
        out[#out + 1] = { text = ("%s  %s  %s"):format(when(p[i].at), colorMoney(p[i].amount), p[i].note or "") }
    end
    return out
end

------------------------------------------------------------------------------------------
-- Bet slip
------------------------------------------------------------------------------------------

local slipFrame

local function slipUpdate()
    if not slip or not slipFrame then return end
    local b = Cache.Book(store(), slip.code)
    -- Remember the market: a SYNC may drop a game that has started, and the slip should still
    -- be able to say so instead of vanishing.
    local m = b and b.markets[slip.marketId]
    if m then slip.market = m else m = slip.market end
    if not m then slipFrame:Hide(); return end
    slipFrame.title:SetText(m.event .. GREY .. "  " .. ({ moneyline = "Moneyline", spread = "Spread", total = "Total" })[m.type] .. "|r")
    slipFrame.pick:SetText(Cache.SelectionText(m, slip.selectionId) .. "  " .. GOLD .. Odds.Format(slip.odds) .. "|r")
    local stake = Odds.ParseMoney(slipFrame.stake:GetText())
    local ok, why = Cache.CanBet(store(), slip.code, slip.marketId, now())
    if not ok and why == "no_market" and Cache.IsClosed(m, now()) then why = "market_closed" end
    local msg = ""
    local stakeOk, _, stakeMsg = Odds.StakeCheck(stake)
    if stake and stake > 0 and not stakeOk then
        msg = RED .. stakeMsg .. "|r"
        slipFrame.win:SetText("To win: " .. GREY .. "-|r")
        stake = nil
    elseif stake and stake > 0 then
        slipFrame.win:SetText("To win: " .. GREEN .. money(Odds.Profit(stake, slip.odds) or 0) .. "|r")
        local avail = Cache.CreditAvailable(store(), slip.code)
        if avail and stake > avail then msg = RED .. "Over your credit limit (" .. money(avail) .. " left)." .. "|r" end
    else
        slipFrame.win:SetText("To win: " .. GREY .. "-|r")
        stake = nil
    end
    if not ok then msg = RED .. Cache.ReasonText(why) .. "|r" end
    if slip.note and msg == "" then msg = GOLD .. slip.note .. "|r" end
    slipFrame.msg:SetText(msg)
    slipFrame.place:SetEnabled(ok and stake ~= nil)
    slipFrame.stakeValue = stake
end

local function buildSlip()
    local f = CreateFrame("Frame", nil, frame, "BasicFrameTemplate")
    f:SetSize(340, 190)
    f:SetPoint("CENTER", frame, "CENTER", 0, 0)
    f:SetFrameLevel(frame:GetFrameLevel() + 20)
    f:EnableMouse(true)
    f.title = label(f, "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -28)
    f.pick = label(f, "GameFontHighlightLarge")
    f.pick:SetPoint("TOPLEFT", 12, -50)
    local sl = label(f, "GameFontNormal")
    sl:SetPoint("TOPLEFT", 12, -84)
    sl:SetText("Stake (e.g. 20s, 1g; max " .. money(Odds.MAX_STAKE) .. "):")
    f.stake = editBox(f, 110)
    f.stake:SetPoint("LEFT", sl, "RIGHT", 10, 0)
    f.stake:SetScript("OnTextChanged", slipUpdate)
    f.stake:SetScript("OnEnterPressed", function() if f.place:IsEnabled() then f.place:Click() end end)
    f.win = label(f, "GameFontHighlight")
    f.win:SetPoint("TOPLEFT", 12, -112)
    f.msg = label(f, "GameFontNormalSmall")
    f.msg:SetPoint("TOPLEFT", 12, -134)
    f.msg:SetWidth(316)
    f.place = button(f, "Place Bet", 100, function()
        slipUpdate()   -- the game may have started since the last refresh
        if not slip or not f.stakeValue or not f.place:IsEnabled() then return end
        -- Close the slip first: a reply (e.g. odds_changed) may reopen it before we return.
        local s, stake = slip, f.stakeValue
        slip = nil
        f:Hide()
        if placeBet(s.code, s.marketId, s.selectionId, stake, s.odds) then
            say("Bet sent: waiting for the bookie to accept.")
        end
        Bettor.Refresh()
    end)
    f.place:SetPoint("BOTTOMLEFT", 12, 12)
    f.cancel = button(f, "Cancel", 80, function() slip = nil; f:Hide() end)
    f.cancel:SetPoint("LEFT", f.place, "RIGHT", 8, 0)
    f:Hide()
    return f
end

-- Open the bet slip. `stake` (copper) and a changed `odds` are used when re-confirming.
function Bettor.OpenSlip(code, marketId, selectionId, odds, stake)
    if not frame then return end
    slipFrame = slipFrame or buildSlip()
    slip = { code = code, marketId = marketId, selectionId = selectionId, odds = odds }
    if stake then
        slip.note = "The odds changed. Check them and confirm again."
        slipFrame.stake:SetText((Odds.FormatMoney(stake):gsub(" ", "")))
    else
        slipFrame.stake:SetText("")
    end
    slipFrame:Show()
    slipUpdate()
    if not stake then slipFrame.stake:SetFocus() end
end

------------------------------------------------------------------------------------------
-- Main window
------------------------------------------------------------------------------------------

local ui = {}

local function setTab(name) tab = name; showJoin = false; Bettor.Refresh() end

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
    -- Refresh on a timer only while the window is shown.
    local refresher
    frame:SetScript("OnShow", function()
        if not refresher then refresher = C_Timer.NewTicker(REFRESH_EVERY, function() Bettor.Refresh() end) end
    end)
    frame:SetScript("OnHide", function()
        if refresher then refresher:Cancel(); refresher = nil end
    end)

    local title = label(frame, "GameFontNormal", "CENTER")
    title:SetPoint("TOP", 0, -5)
    title:SetText("SteveBook: Place Bets")

    ui.book = button(frame, "", 250, function()
        local st = store()
        local list = Cache.ListBooks(st)
        if #list == 0 then showJoin = true; return Bettor.Refresh() end
        local cur = currentBook()
        local idx = 1
        for i, x in ipairs(list) do if x.code == cur.code then idx = i end end
        st.selected = list[idx % #list + 1].code
        showJoin = false
        slip = nil
        if slipFrame then slipFrame:Hide() end
        Bettor.Refresh()
    end)
    ui.book:SetPoint("TOPLEFT", 12, -30)
    ui.join = button(frame, "+ Join", 60, function() showJoin = true; Bettor.Refresh() end)
    ui.join:SetPoint("LEFT", ui.book, "RIGHT", 6, 0)
    ui.online = label(frame, "GameFontNormal", "RIGHT")
    ui.online:SetPoint("TOPRIGHT", -14, -34)

    ui.tabs = {}
    local prev
    for _, t in ipairs({ { "lines", "Lines" }, { "bets", "My Bets" }, { "balance", "Balance" } }) do
        local b = button(frame, t[2], 90, function() setTab(t[1]) end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 12, -58) end
        ui.tabs[t[1]] = b
        prev = b
    end

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

    -- Join screen (replaces the body while visible)
    local j = CreateFrame("Frame", nil, frame)
    j:SetPoint("TOPLEFT", 14, -90)
    j:SetPoint("BOTTOMRIGHT", -14, 14)
    local jl = label(j, "GameFontNormal")
    jl:SetPoint("TOPLEFT", 0, -6)
    jl:SetText("Join code from your bookie (e.g. NFL-K7Q2):")
    j.code = editBox(j, 140, 16)
    j.code:SetPoint("TOPLEFT", jl, "BOTTOMLEFT", 6, -6)
    local go = function() requestJoin(j.code:GetText()); j.code:SetText(""); j.code:ClearFocus(); Bettor.Refresh() end
    j.code:SetScript("OnEnterPressed", go)
    j.go = button(j, "Request to join", 120, go)
    j.go:SetPoint("LEFT", j.code, "RIGHT", 10, 0)
    j.status = label(j, "GameFontHighlight")
    j.status:SetPoint("TOPLEFT", j.code, "BOTTOMLEFT", -6, -18)
    j.status:SetWidth(WIN_W - 40)
    j.forget = button(j, "Forget this book", 130, function()
        local cur = currentBook()
        if cur then
            Cache.Forget(store(), cur.code)
            if store().selected == cur.code then store().selected = nil end
        end
        showJoin = false
        Bettor.Refresh()
    end)
    j.forget:SetPoint("TOPLEFT", j.status, "BOTTOMLEFT", 0, -14)
    j:Hide()
    ui.joinPanel = j
end

function Bettor.Refresh()
    if not frame then return end
    local st = store()
    if not st then return end
    local b = currentBook()
    local t = now()
    local needJoin = showJoin or not b or b.status ~= "active"

    ui.book:SetText(b and bookTitle(b) or "No book yet")
    if b and b.status == "active" then
        ui.online:SetText(Cache.IsOnline(st, b.code, t) and (GREEN .. "Book online|r") or (RED .. "Book offline|r"))
    else
        ui.online:SetText("")
    end

    ui.joinPanel:SetShown(needJoin)
    scroll:SetShown(not needJoin)
    if needJoin then
        for _, btn in pairs(ui.tabs) do btn:SetEnabled(false) end
        ui.joinPanel.forget:SetShown(b ~= nil and b.status ~= "active")
        local msg = "Ask your bookie for their join code."
        if b and not showJoin then
            if b.status == "requested" then
                msg = "Request sent to " .. b.code .. ". Waiting for the bookie to approve you.\n"
                    .. GREY .. "You can also enter a code above to join a different book.|r"
            elseif b.status == "denied" then
                msg = RED .. "The bookie denied your request for " .. b.code .. ".|r"
            end
        end
        ui.joinPanel.status:SetText(msg)
        if slipFrame then slipFrame:Hide() end
        return
    end

    local entries
    if tab == "bets" then entries = betsEntries(b)
    elseif tab == "balance" then entries = balanceEntries(b)
    else tab = "lines"; entries = linesEntries(b, t) end
    for name, btn in pairs(ui.tabs) do btn:SetEnabled(name ~= tab) end
    render(entries)
    if slip then slipUpdate() end
end

function Bettor.Show()
    if not store() then return say("SteveBook is still loading.") end
    register()
    if not frame then build() end
    tab = tab or "lines"
    frame:Show()
    Bettor.Refresh()
end

function Bettor.Hide() if frame then frame:Hide() end end

function Bettor.Toggle()
    if shown() then Bettor.Hide() else Bettor.Show() end
end

register()
