-- UI/Bettor.lua: the bettor window (SPEC §6) and the bettor side of the protocol (SPEC §5).
-- Bettors only REQUEST; the bookie validates. All state lives in ns.Cache (SteveBookDB.cache);
-- the bet slip's rules live in ns.Slip (pure). This file draws and wires.
-- Layout (design "B", odds board): a Lines tab with sport chips, an odds board (one block per
-- game: Spread / Total / Moneyline, two rows each) and a slip panel on the right with a
-- Single / Parlay switch; My Bets and Balance tabs use the full width.
-- Exposes ns.UI.Bettor = { Show, Hide, Toggle, Refresh, Select, SetStake }.
local ADDON, ns = ...
ns.UI = ns.UI or {}

local Cache, Odds, Slip = ns.Cache, ns.Odds, ns.Slip
local Bettor = {}
ns.UI.Bettor = Bettor

local PING_EVERY = 30
local GROUP_EVERY = 30     -- All Bets: ask the bookie again this often while the tab is shown
local REFRESH_EVERY = 5   -- while the window is open: games start, so the lists must age
local WIN_W, WIN_H = 900, 640
local SLIP_W = 276
local PAD = 14
local BOARD_W = WIN_W - 2 * PAD - SLIP_W - 10       -- the board's width
local GAME_COL_W = 150
local CELL_GAP = 4
local CELL_W = math.floor((BOARD_W - GAME_COL_W - 4 * CELL_GAP) / 3)
local GROUP_W = WIN_W - 2 * PAD
local GROUP_ROW_H = 22
-- All Bets columns: who, when placed (server time, see Clock.lua), the pick (the bookie's text),
-- stake, to win, status. The Placed header gets its clock name at render time.
local GROUP_COLS = {
    { title = "Who",    x = 6,   w = 104, justify = "LEFT" },
    { title = "Placed", x = 114, w = 108, justify = "LEFT", placed = true },
    { title = "Pick",   x = 226, w = 330, justify = "LEFT" },
    { title = "Stake",  x = 562, w = 84,  justify = "RIGHT" },
    { title = "To win", x = 650, w = 116, justify = "RIGHT" },
    { title = "Status", x = 774, w = 84,  justify = "CENTER" },
}
local BLOCK_H, CELL_H = 76, 30
local LEG_H = 32
local GREEN, RED, GOLD, GREY = "|cff40ff40", "|cffff5050", "|cffffd100", "|cff999999"

local frame, tab, showJoin, filter
local groupReqAt            -- when BETS_REQ was last sent (nil: send on the next refresh)
local slip = Slip.New()
local restoreStake            -- copper to put back in the stake box after a rejection
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
local function clock(t) return date("%a %I:%M %p", t) end

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

-- Markets of the shown book, for the slip.
local function getMarket(id)
    local b = currentBook()
    return b and b.markets[id] or nil
end

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

-- `req` is a BET_PLACE payload without a ref (Slip.Request builds it with one).
local function placeBet(code, req)
    Cache.NewPending(store(), code, req, now())
    if not send("BET_PLACE", req, code, true) then
        Cache.ApplyBetReject(store(), code, req.ref, "book_error", nil, now())
        return false
    end
    return true
end

local function newRef()
    seq = seq + 1
    return ("%d-%04d-%d"):format(now(), math.random(0, 9999), seq)
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
    if bet.legs then
        return ("%d-leg parlay @ %s for %s"):format(#bet.legs, Odds.Format(bet.odds), money(bet.stake))
    end
    local m = b.markets[bet.marketId]
    return ("%s %s @ %s for %s"):format(
        Cache.EventName(m), Cache.SelectionText(m, bet.selectionId, bet.line), Odds.Format(bet.odds), money(bet.stake))
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
            if Cache.BetOnMarket(bet, m.id) then
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
end

-- Put a rejected request back on the slip so the bettor can fix it and go again.
local function restoreSlip(b, bet, p)
    local mode = bet.legs and "parlay" or "single"
    local list = {}
    if bet.legs then
        for i, leg in ipairs(bet.legs) do list[i] = { marketId = leg.marketId, selectionId = leg.selectionId, odds = leg.odds, line = leg.line } end
    else
        list[1] = { marketId = bet.marketId, selectionId = bet.selectionId, odds = bet.odds, line = bet.line }
    end
    local notes = {}
    local idx = p.legIndex
    if p.reason == "odds_changed" and (p.currentOdds or p.currentLine) then
        local target = list[idx or 1]
        if target then
            if p.currentOdds then target.odds = p.currentOdds end
            if p.currentLine ~= nil then target.line = p.currentLine end
        end
        local now_ = {}
        if p.currentLine ~= nil then now_[#now_ + 1] = ("line %g"):format(p.currentLine) end
        if p.currentOdds then now_[#now_ + 1] = Odds.Format(p.currentOdds) end
        notes[#notes + 1] = ("%s now %s."):format(
            bet.legs and ("Leg " .. (idx or "?")) or "The bet", table.concat(now_, " at "))
    elseif idx and (p.reason == "market_closed" or p.reason == "no_market" or p.reason == "bad_selection") then
        table.remove(list, idx)                           -- that game is gone: drop the leg
        notes[#notes + 1] = ("Leg %d was dropped (%s)."):format(idx, (Cache.ReasonText(p.reason):gsub("%.$", "")))
    end
    Slip.Restore(slip, mode, list, function(id) return b.markets[id] end)
    if p.reason == "odds_changed" then slip.confirm[mode] = true end
    restoreStake = bet.stake
    tab, showJoin = "lines", false
    return table.concat(notes, " ")
end

function handlers.BET_REJECT(sender, p, code)
    local b = bookFor(code, sender)
    if not b then return end
    local bet = Cache.ApplyBetReject(store(), code, p.ref, p.reason, p.currentOdds, now(), p.available, p.legIndex, p.currentLine)
    if not bet then return end
    local text = Cache.ReasonText(p.reason)
    if p.reason == "credit_limit" and p.available then
        text = text .. " You can still bet " .. money(p.available) .. "."
    elseif p.reason == "parlay_conflict" and p.legIndex then
        text = text .. (" Leg %d clashes with an earlier leg."):format(p.legIndex)
    end
    local note = restoreSlip(b, bet, p)
    if p.reason == "odds_changed" then text = text .. " " .. note .. " Confirm to go ahead."
    elseif note ~= "" then text = text .. " " .. note end
    say((bet.legs and "Parlay" or "Bet") .. " rejected: " .. text)
end

-- All Bets: the group's bets as the bookie rendered them. Same sender rule as the other bookie
-- messages, and only from a bookie we already know (so nobody can fill our list before JOIN_OK).
function handlers.BETS(sender, p, code)
    local b = bookFor(code, sender)
    if not b or b.status ~= "active" or not b.owner then return end
    Cache.ApplyGroupBets(store(), code, p.bets, now())
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
    if not wasOnline then
        groupReqAt = nil                       -- back online: ask for the group's bets again if that tab is open
        send("SYNC_REQ", { rev = b.rev or 0 }, code)
    end
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

local function editBox(parent, w, maxLetters)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 22)
    e:SetAutoFocus(false)
    if maxLetters then e:SetMaxLetters(maxLetters) end
    e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

-- Fill a texture with a flat color (SetColorTexture, or the plain white texture tinted).
local function paint(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a or 1)
    else tex:SetTexture("Interface\\Buttons\\WHITE8X8"); tex:SetVertexColor(r, g, b, a or 1) end
end

-- An odds cell: a flat button with the line on the left and the price on the right.
local function newCell(parent, onClick)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(CELL_W, CELL_H)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    c.left = label(c, "GameFontHighlightSmall")
    c.left:SetPoint("LEFT", 6, 0)
    c.left:SetWidth(CELL_W - 52)
    c.left:SetWordWrap(false)
    c.right = label(c, "GameFontNormal", "RIGHT")
    c.right:SetPoint("RIGHT", -6, 0)
    c:SetScript("OnClick", onClick)
    c:SetScript("OnEnter", function(self) if not self.selected then paint(self.bg, 0.24, 0.19, 0.11, 1) end end)
    c:SetScript("OnLeave", function(self) if not self.selected then paint(self.bg, 0.165, 0.13, 0.085, 1) end end)
    return c
end

local function setCellSelected(c, selected)
    c.selected = selected
    if selected then paint(c.bg, 0.29, 0.23, 0.11, 1) else paint(c.bg, 0.165, 0.13, 0.085, 1) end
end

------------------------------------------------------------------------------------------
-- Board (Lines tab, left)
------------------------------------------------------------------------------------------

local ui = {}
local blocks = {}

local function onCellClick(code, market, selId)
    local act, msg = Slip.Select(slip, market, selId)
    if act == "refused" then say(msg) end
    Bettor.Refresh()
end

-- "PHI -3.5" / "O 47.5" / "PHI": the left text of a cell.
local function cellLeft(market, selId)
    if market.type == "total" then
        local lab = Cache.SelectionLabel(market, selId)
        return ("%s %g"):format(lab:sub(1, 1), market.line or 0)
    end
    return Cache.SelectionText(market, selId)
end

local function getBlock(i)
    local b = blocks[i]
    if b then return b end
    b = CreateFrame("Frame", nil, ui.boardContent)
    b:SetSize(BOARD_W, BLOCK_H)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    paint(b.bg, 0.12, 0.095, 0.06, 1)
    b.name = label(b, "GameFontNormal")
    b.name:SetPoint("TOPLEFT", 8, -18)
    b.name:SetWidth(GAME_COL_W - 12)
    b.name:SetWordWrap(false)
    b.time = label(b, "GameFontHighlightSmall")
    b.time:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -4)
    b.cells = {}
    for col = 1, 3 do
        b.cells[col] = {}
        for row = 1, 2 do
            local c = newCell(b, nil)
            c:SetPoint("TOPLEFT", GAME_COL_W + (col - 1) * (CELL_W + CELL_GAP), -(6 + (row - 1) * (CELL_H + 4)))
            b.cells[col][row] = c
        end
    end
    blocks[i] = b
    return b
end

local COLUMNS = { "spread", "total", "moneyline" }

local function renderBoard(board)
    local y = 0
    for i, g in ipairs(board.games) do
        local blk = getBlock(i)
        blk:SetPoint("TOPLEFT", ui.boardContent, "TOPLEFT", 0, -y)
        blk.name:SetText(g.event)
        blk.time:SetText(GREY .. clock(g.closesAt) .. "|r")
        for col, mtype in ipairs(COLUMNS) do
            local m = g[mtype]
            for row = 1, 2 do
                local c = blk.cells[col][row]
                local selId = m and g.rows[mtype] and g.rows[mtype][row]
                local sel = selId and Cache.Selection(m, selId)
                if sel then
                    c.left:SetText(cellLeft(m, selId))
                    c.right:SetText(GOLD .. Odds.Format(sel.odds) .. "|r")
                    c:SetScript("OnClick", function() onCellClick(board.code, m, selId) end)
                    setCellSelected(c, Slip.IsSelected(slip, m.id, selId))
                    c:Show()
                else
                    c:Hide()
                end
            end
        end
        blk:Show()
        y = y + BLOCK_H + 4
    end
    for i = #board.games + 1, #blocks do blocks[i]:Hide() end
    ui.boardContent:SetHeight(math.max(y, 1))
    ui.boardEmpty:SetShown(#board.games == 0)
end

local function renderChips(sports)
    local names = {}
    for _, s in ipairs(sports) do names[#names + 1] = s end
    names[#names + 1] = "All"
    local x = 0
    for i, name in ipairs(names) do
        local chip = ui.chips[i]
        if not chip then
            chip = button(ui.boardArea, "", 64, nil, 24)
            ui.chips[i] = chip
        end
        chip:SetText(name)
        chip:SetPoint("TOPLEFT", ui.boardArea, "TOPLEFT", x, 0)
        chip:SetScript("OnClick", function() filter = name; Bettor.Refresh() end)
        chip:SetEnabled((filter or "All") ~= name)
        chip:Show()
        x = x + 68
    end
    for i = #names + 1, #ui.chips do ui.chips[i]:Hide() end
end

------------------------------------------------------------------------------------------
-- List views (My Bets, Balance): pooled text rows in a scroll frame
------------------------------------------------------------------------------------------

local rows = {}

local function getRow(i)
    local r = rows[i]
    if r then return r end
    r = label(ui.listContent, "GameFontHighlight")
    r:SetWordWrap(false)
    rows[i] = r
    return r
end

-- entries: { { text=, h= } ... }
local function renderList(entries)
    local y, width = 0, ui.listContent:GetWidth()
    for i, e in ipairs(entries) do
        local r = getRow(i)
        r:SetPoint("TOPLEFT", ui.listContent, "TOPLEFT", e.indent or 0, -y)
        r:SetWidth(width - (e.indent or 0))
        r:SetText(e.text)
        r:Show()
        y = y + (e.h or 18)
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end
    ui.listContent:SetHeight(math.max(y, 1))
end

local LEG_STATUS = { pending = GREY .. "Pending|r", won = GREEN .. "Won|r", lost = RED .. "Lost|r",
    push = GREY .. "Push|r", void = GREY .. "Void|r" }

local function legLine(b, leg)
    local m = b.markets[leg.marketId]
    return ("%s  %s  %s%s%s  %s"):format(Cache.SelectionText(m, leg.selectionId, leg.line), Odds.Format(leg.odds),
        GREY, Cache.EventName(m), "|r", LEG_STATUS[leg.status or "pending"] or tostring(leg.status))
end

local function betLine(b, bet)
    local head
    if bet.legs then
        head = ("Parlay, %d legs @ %s  stake %s"):format(#bet.legs, Odds.Format(bet.odds), money(bet.stake))
    else
        local m = b.markets[bet.marketId]
        head = ("%s  %s @ %s  stake %s"):format(
            Cache.EventName(m), Cache.SelectionText(m, bet.selectionId, bet.line), Odds.Format(bet.odds), money(bet.stake))
    end
    local st = bet.status
    local win = ""
    if st == "accepted" or st == "pending" then
        local profit
        if bet.legs then
            local list = {}
            for i, leg in ipairs(bet.legs) do list[i] = leg.odds end
            profit = Odds.ParlayProfit(bet.stake, list)
        else
            profit = Odds.Profit(bet.stake, bet.odds)
        end
        win = GREY .. "  to win " .. money(profit or 0) .. "|r"
    end
    if st == "pending" then return GREY .. "Pending|r  " .. head end
    if st == "accepted" then return GOLD .. "Open|r  " .. head .. win end
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
    local function add(list)
        for _, bet in ipairs(list) do
            out[#out + 1] = { text = betLine(b, bet) }
            for _, leg in ipairs(bet.legs or {}) do out[#out + 1] = { text = legLine(b, leg), indent = 24 } end
        end
    end
    out[#out + 1] = { text = GOLD .. "Open bets (" .. #bets.open .. ")|r", h = 22 }
    add(bets.open)
    out[#out + 1] = { text = GOLD .. "Settled, last 14 days (" .. #bets.settled .. ")|r", h = 26 }
    if #bets.settled == 0 then out[#out + 1] = { text = GREY .. "None in the last 14 days.|r" } end
    add(bets.settled)
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
-- All Bets view
------------------------------------------------------------------------------------------

local groupRows = {}
local GROUP_STATUS = { accepted = GOLD .. "Open|r", pending = GOLD .. "Open|r", open = GOLD .. "Open|r",
    won = GREEN .. "Won|r", lost = RED .. "Lost|r", push = GREY .. "Push|r", void = GREY .. "Void|r" }

-- Text from other players goes into FontStrings: a "|" would start a colour/escape code.
local function plain(text) return (text:gsub("|", "||")) end

local function getGroupRow(i)
    local r = groupRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, ui.groupContent)
    r:SetSize(GROUP_W, GROUP_ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.cols = {}
    for i2, c in ipairs(GROUP_COLS) do
        local fs = label(r, "GameFontHighlight", c.justify)
        fs:SetPoint("LEFT", c.x, 0)
        fs:SetWidth(c.w)
        fs:SetWordWrap(false)          -- long picks are cut off instead of spilling into the next column
        r.cols[i2] = fs
    end
    groupRows[i] = r
    return r
end

local function renderGroup(b, t)
    local st = store()
    local Clock = ns.Clock
    -- "Placed (server)" or "Placed (PT)": never the player's own computer clock.
    ui.groupPlacedHead:SetText("Placed (" .. (Clock and Clock.Label() or "?") .. ")")
    local g = Cache.GroupBets(st, b.code)
    local online = Cache.IsOnline(st, b.code, t)
    local entries = {}
    if not g then
        ui.groupHead:SetText(online and (GREY .. "Loading...|r") or (GREY .. "Waiting for the bookie to come online.|r"))
        ui.groupAge:SetText("")
    else
        for _, e in ipairs(g.open) do entries[#entries + 1] = e end
        for _, e in ipairs(g.settled) do entries[#entries + 1] = e end
        if #entries == 0 then
            ui.groupHead:SetText(GREY .. "No bets yet|r")
        else
            ui.groupHead:SetText(("%d open, %d settled in the last 48h, total at stake %s"):format(
                #g.open, #g.settled, money(g.atStake)))
        end
        local age = Cache.GroupAge(st, b.code, t) or 0
        ui.groupAge:SetText(GREY .. ("Updated %ds ago"):format(age) .. (online and "" or "  (the bookie is offline)") .. "|r")
    end

    local me = baseName(UnitName and UnitName("player"))
    local y = 0
    for i, e in ipairs(entries) do
        local r = getGroupRow(i)
        r:SetPoint("TOPLEFT", ui.groupContent, "TOPLEFT", 0, -y)
        local mine = me and baseName(e.who) == me
        if mine then paint(r.bg, 0.29, 0.23, 0.11, 1)
        elseif i % 2 == 0 then paint(r.bg, 0.12, 0.095, 0.06, 1)
        else paint(r.bg, 0.095, 0.075, 0.05, 1) end
        r.cols[1]:SetText((mine and GOLD or "") .. plain(e.who) .. (mine and "|r" or ""))
        r.cols[2]:SetText(Clock and e.at and e.at > 0 and Clock.Format(e.at) or "")
        r.cols[3]:SetText(plain(e.text))
        r.cols[4]:SetText(money(e.stake))
        local open = e.status == "accepted" or e.status == "pending" or e.status == "open"
        r.cols[5]:SetText(open and e.win and (GREEN .. money(e.win) .. "|r") or "")
        r.cols[6]:SetText(GROUP_STATUS[e.status] or e.status)
        r:Show()
        y = y + GROUP_ROW_H
    end
    for i = #entries + 1, #groupRows do groupRows[i]:Hide() end
    ui.groupContent:SetHeight(math.max(y, 1))
end

------------------------------------------------------------------------------------------
-- Slip panel (Lines tab, right)
------------------------------------------------------------------------------------------

local updating = false

local function stakeValue()
    local text = ui.stake:GetText()
    if text == nil or text == "" then return nil, false end
    return Odds.ParseMoney(text), true
end

local PARLAY_NOTE = "All legs must win. A push or void leg drops out and the rest still pay. "
    .. "From one game you can take one side bet (moneyline or spread) plus one total."

local function slipUpdate()
    if not ui.slip or updating then return end
    local b = currentBook()
    if not b then return end
    local st, t = store(), now()
    updating = true

    -- Bring the slip in line with the cache: started games drop out, moved odds need a confirm.
    local dropped = Slip.Sync(slip, getMarket, t)
    for _, d in ipairs(dropped) do
        say(("Removed from the slip: %s (%s)."):format(Slip.Describe(d.leg),
            d.reason == "started" and "this game has started" or "no longer available"))
    end

    if restoreStake then
        ui.stake:SetText((money(restoreStake):gsub(" ", "")))
        restoreStake = nil
    end

    local mode = slip.mode
    local legs = Slip.Legs(slip)
    ui.modeSingle:SetEnabled(mode ~= "single")
    ui.modeParlay:SetText("Parlay (" .. Slip.ParlayCount(slip) .. ")")
    ui.modeParlay:SetEnabled(mode ~= "parlay")

    for i = 1, Odds.MAX_PARLAY_LEGS do
        local row = ui.legRows[i]
        local leg = legs[i]
        if leg then
            local m = leg.market
            row.pick:SetText(Cache.SelectionText(m, leg.selectionId))
            row.sub:SetText(GREY .. (m and Slip.TypeName[m.type] or "?") .. "  " .. Cache.EventName(m) .. "|r")
            row.odds:SetText(GOLD .. Odds.Format(leg.odds) .. "|r" .. (leg.changedFrom and (RED .. " (" .. Odds.Format(leg.changedFrom) .. ")|r") or ""))
            if leg.lineChangedFrom ~= nil then row.pick:SetText(row.pick:GetText() .. RED .. " (was " .. tostring(leg.lineChangedFrom) .. ")|r") end
            row.remove:SetScript("OnClick", function() Slip.Remove(slip, i); Bettor.Refresh() end)
            row:Show()
        else
            row:Hide()
        end
    end

    local hasLegs = #legs > 0
    ui.hint:SetShown(not hasLegs)
    if not hasLegs then
        ui.hint:SetText(mode == "single" and "Click an odds cell to start a bet." or "Click odds cells to add legs (2 to " .. Odds.MAX_PARLAY_LEGS .. ").")
    end
    ui.lower:SetShown(hasLegs)
    if not hasLegs then ui.place:SetEnabled(false) end
    ui.lower:ClearAllPoints()
    ui.lower:SetPoint("TOPLEFT", ui.slip, "TOPLEFT", 0, -(46 + #legs * LEG_H + 8))

    if hasLegs then
        local stake, typed = stakeValue()
        local combined = Slip.Odds(slip)
        ui.oddsLabel:SetText(mode == "parlay" and "Combined odds" or "Odds")
        ui.oddsValue:SetText(combined and (GOLD .. Odds.Format(combined) .. "|r") or (GREY .. "-|r"))

        local ok, code, msg = Slip.Validate(slip, stake, function(id) return Cache.CanBet(st, b.code, id, t) end)
        local validStake = stake and Odds.StakeCheck(stake)
        local win = validStake and Slip.ToWin(slip, stake)
        ui.win:SetText(win and (GREEN .. money(win) .. "|r") or (GREY .. "-|r"))

        -- Message: why it can't be placed (only once something is typed, for stake problems).
        local text = ""
        if typed and not stake then text = RED .. "Enter a stake like 20s or 1g." .. "|r"
        elseif code == "stake" and typed then text = RED .. msg .. "|r"
        elseif code == "stake_missing" or code == "empty" then text = ""
        elseif code == "confirm" then text = GOLD .. msg .. "|r"
        elseif not ok then text = RED .. msg .. "|r" end
        if ok then
            local avail = Cache.CreditAvailable(st, b.code)
            if avail and stake > avail then text = RED .. "Over your credit limit (" .. money(avail) .. " left)." .. "|r" end
        end
        ui.msg:SetText(text)
        ui.note:SetText(mode == "parlay" and (GREY .. PARLAY_NOTE .. "|r") or "")

        if code == "confirm" then
            ui.place:SetText("Confirm new odds")
            ui.place:SetEnabled(true)
        else
            ui.place:SetText(mode == "parlay" and "Place Parlay" or "Place Bet")
            ui.place:SetEnabled(ok)
        end
    end
    updating = false
end

-- Place (or confirm) the current slip.
local function slipPlace()
    local b = currentBook()
    if not b then return end
    slipUpdate()                                 -- a game may have started since the last refresh
    if #Slip.Legs(slip) == 0 or not ui.place:IsEnabled() then return end
    if Slip.NeedsConfirm(slip) then
        Slip.Confirm(slip)
        return Bettor.Refresh()
    end
    local stake = stakeValue()
    local req = Slip.Request(slip, newRef(), stake)
    -- Clear the slip first: a reply (e.g. odds_changed) may put it back before we return.
    Slip.Clear(slip)
    updating = true; ui.stake:SetText(""); updating = false
    if placeBet(b.code, req) then say("Bet sent: waiting for the bookie to accept.") end
    Bettor.Refresh()
end

local function buildSlip(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(SLIP_W, WIN_H - 100)
    s.bg = s:CreateTexture(nil, "BACKGROUND")
    s.bg:SetAllPoints()
    paint(s.bg, 0.105, 0.082, 0.055, 1)
    ui.slip = s

    ui.modeSingle = button(s, "Single", SLIP_W / 2 - 14, function() Slip.SetMode(slip, "single"); Bettor.Refresh() end, 26)
    ui.modeSingle:SetPoint("TOPLEFT", 10, -8)
    ui.modeParlay = button(s, "Parlay (0)", SLIP_W / 2 - 14, function() Slip.SetMode(slip, "parlay"); Bettor.Refresh() end, 26)
    ui.modeParlay:SetPoint("LEFT", ui.modeSingle, "RIGHT", 4, 0)

    ui.hint = label(s, "GameFontNormalSmall")
    ui.hint:SetPoint("TOPLEFT", 12, -52)
    ui.hint:SetWidth(SLIP_W - 24)
    ui.hint:SetJustifyV("TOP")

    ui.legRows = {}
    for i = 1, Odds.MAX_PARLAY_LEGS do
        local row = CreateFrame("Frame", nil, s)
        row:SetSize(SLIP_W - 20, LEG_H - 2)
        row:SetPoint("TOPLEFT", 10, -(46 + (i - 1) * LEG_H))
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        paint(row.bg, 0.165, 0.13, 0.085, 1)
        row.pick = label(row, "GameFontHighlight")
        row.pick:SetPoint("TOPLEFT", 6, -3)
        row.pick:SetWidth(SLIP_W - 120)
        row.pick:SetWordWrap(false)
        row.sub = label(row, "GameFontHighlightSmall")
        row.sub:SetPoint("TOPLEFT", row.pick, "BOTTOMLEFT", 0, -1)
        row.sub:SetWidth(SLIP_W - 120)
        row.sub:SetWordWrap(false)
        row.remove = button(row, "x", 22, nil, 22)
        row.remove:SetPoint("RIGHT", -4, 0)
        row.odds = label(row, "GameFontNormal", "RIGHT")
        row.odds:SetPoint("RIGHT", row.remove, "LEFT", -6, 0)
        ui.legRows[i] = row
    end

    -- Everything below the legs moves with the number of legs (ui.lower is re-anchored).
    local lower = CreateFrame("Frame", nil, s)
    lower:SetSize(SLIP_W, 250)
    ui.lower = lower
    ui.oddsLabel = label(lower, "GameFontNormal")
    ui.oddsLabel:SetPoint("TOPLEFT", 12, 0)
    ui.oddsValue = label(lower, "GameFontNormalLarge", "RIGHT")
    ui.oddsValue:SetPoint("TOPRIGHT", -12, 0)

    local sl = label(lower, "GameFontNormal")
    sl:SetPoint("TOPLEFT", 12, -34)
    sl:SetText("Stake (max " .. money(Odds.MAX_STAKE) .. ")")
    ui.stake = editBox(lower, 90)
    ui.stake:SetPoint("TOPRIGHT", -12, -30)
    ui.stake:SetScript("OnTextChanged", slipUpdate)
    ui.stake:SetScript("OnEnterPressed", function() slipPlace() end)

    local wl = label(lower, "GameFontNormal")
    wl:SetPoint("TOPLEFT", 12, -64)
    wl:SetText("To win")
    ui.win = label(lower, "GameFontHighlightLarge", "RIGHT")
    ui.win:SetPoint("TOPRIGHT", -12, -62)

    ui.place = button(lower, "Place Bet", SLIP_W - 24, function() slipPlace() end, 32)
    ui.place:SetPoint("TOPLEFT", 12, -92)
    ui.clear = button(lower, "Clear", 60, function() Slip.Clear(slip); ui.stake:SetText(""); Bettor.Refresh() end, 20)
    ui.clear:SetPoint("TOPLEFT", ui.place, "BOTTOMLEFT", 0, -6)
    ui.msg = label(lower, "GameFontNormalSmall")
    ui.msg:SetPoint("TOPLEFT", ui.place, "BOTTOMLEFT", 68, -6)
    ui.msg:SetWidth(SLIP_W - 100)
    ui.msg:SetJustifyV("TOP")
    ui.note = label(lower, "GameFontHighlightSmall")
    ui.note:SetPoint("TOPLEFT", 12, -158)
    ui.note:SetWidth(SLIP_W - 24)
    ui.note:SetJustifyV("TOP")
end

------------------------------------------------------------------------------------------
-- Main window
------------------------------------------------------------------------------------------

local function setTab(name)
    tab, showJoin = name, false
    if name == "all" then groupReqAt = nil end   -- opening the tab asks straight away
    Bettor.Refresh()
end

local function build()
    -- Named so Escape can close it (UISpecialFrames only takes global names).
    frame = CreateFrame("Frame", "SteveBookBettorFrame", UIParent, "BasicFrameTemplateWithInset")
    if UISpecialFrames then table.insert(UISpecialFrames, "SteveBookBettorFrame") end
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

    ui.title = label(frame, "GameFontNormal", "CENTER")
    ui.title:SetPoint("TOP", 0, -5)
    ui.title:SetText("SteveBook")

    -- Book picker (cycles through your books) and the join button.
    ui.book = button(frame, "", 250, function()
        local st = store()
        local list = Cache.ListBooks(st)
        if #list == 0 then showJoin = true; return Bettor.Refresh() end
        local cur = currentBook()
        local idx = 1
        for i, x in ipairs(list) do if x.code == cur.code then idx = i end end
        st.selected = list[idx % #list + 1].code
        showJoin = false
        Slip.ClearAll(slip)
        ui.stake:SetText("")
        groupReqAt = nil
        Bettor.Refresh()
    end)
    ui.book:SetPoint("TOPLEFT", PAD, -30)
    ui.join = button(frame, "+ Join", 60, function() showJoin = true; Bettor.Refresh() end)
    ui.join:SetPoint("LEFT", ui.book, "RIGHT", 6, 0)
    ui.status = label(frame, "GameFontNormal", "RIGHT")
    ui.status:SetPoint("TOPRIGHT", -PAD, -34)

    ui.tabs = {}
    local prev
    for _, t in ipairs({ { "lines", "Lines" }, { "bets", "My Bets" }, { "all", "All Bets" }, { "balance", "Balance" } }) do
        local b = button(frame, t[2], 100, function() setTab(t[1]) end, 24)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", PAD, -60) end
        ui.tabs[t[1]] = b
        prev = b
    end

    -- Lines: board area (left) and slip panel (right).
    local area = CreateFrame("Frame", nil, frame)
    area:SetPoint("TOPLEFT", PAD, -94)
    area:SetSize(BOARD_W, WIN_H - 110)
    ui.boardArea = area
    ui.chips = {}
    local header = CreateFrame("Frame", nil, area)
    header:SetPoint("TOPLEFT", 0, -30)
    header:SetSize(BOARD_W, 16)
    local heads = { { "Game", 8, GAME_COL_W } }
    for i, name in ipairs({ "Spread", "Total", "Moneyline" }) do
        heads[#heads + 1] = { name, GAME_COL_W + (i - 1) * (CELL_W + CELL_GAP), CELL_W, true }
    end
    for _, h in ipairs(heads) do
        local fs = label(header, "GameFontNormalSmall", h[4] and "CENTER" or "LEFT")
        fs:SetPoint("LEFT", h[2], 0)
        fs:SetWidth(h[3])
        fs:SetText(h[1])
    end
    ui.boardScroll = CreateFrame("ScrollFrame", nil, area)
    ui.boardScroll:SetPoint("TOPLEFT", 0, -50)
    ui.boardScroll:SetPoint("BOTTOMRIGHT", 0, 22)
    ui.boardContent = CreateFrame("Frame", nil, ui.boardScroll)
    ui.boardContent:SetSize(BOARD_W, 1)
    ui.boardScroll:SetScrollChild(ui.boardContent)
    ui.boardScroll:EnableMouseWheel(true)
    ui.boardScroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, ui.boardContent:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 50)))
    end)
    ui.boardEmpty = label(area, "GameFontNormal")
    ui.boardEmpty:SetPoint("TOPLEFT", 8, -60)
    ui.boardEmpty:SetText(GREY .. "No open games right now.|r")
    local foot = label(area, "GameFontHighlightSmall")
    foot:SetPoint("BOTTOMLEFT", 0, 0)
    foot:SetText(GREY .. "Games that have started are hidden. Lines update when the bookie edits them.|r")

    local slipHolder = CreateFrame("Frame", nil, frame)
    slipHolder:SetPoint("TOPRIGHT", -PAD, -94)
    slipHolder:SetSize(SLIP_W, WIN_H - 110)
    buildSlip(slipHolder)
    ui.slip:SetAllPoints(slipHolder)
    ui.slipHolder = slipHolder

    -- My Bets / Balance: full-width list.
    ui.listScroll = CreateFrame("ScrollFrame", nil, frame)
    ui.listScroll:SetPoint("TOPLEFT", PAD, -94)
    ui.listScroll:SetPoint("BOTTOMRIGHT", -PAD, 14)
    ui.listContent = CreateFrame("Frame", nil, ui.listScroll)
    ui.listContent:SetSize(WIN_W - 2 * PAD, 1)
    ui.listScroll:SetScrollChild(ui.listContent)
    ui.listScroll:EnableMouseWheel(true)
    ui.listScroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, ui.listContent:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 40)))
    end)

    -- All Bets: a summary, column labels and a scroll frame of rows.
    local g = CreateFrame("Frame", nil, frame)
    g:SetPoint("TOPLEFT", PAD, -94)
    g:SetSize(GROUP_W, WIN_H - 110)
    ui.group = g
    ui.groupHead = label(g, "GameFontNormal")
    ui.groupHead:SetPoint("TOPLEFT", 4, 0)
    ui.groupHead:SetWidth(GROUP_W - 8)
    ui.groupHead:SetWordWrap(false)
    ui.groupAge = label(g, "GameFontHighlightSmall")
    ui.groupAge:SetPoint("TOPLEFT", 4, -20)
    ui.groupAge:SetWidth(GROUP_W - 8)
    for _, c in ipairs(GROUP_COLS) do
        local fs = label(g, "GameFontNormalSmall", c.justify)
        fs:SetPoint("TOPLEFT", c.x, -44)
        fs:SetWidth(c.w)
        fs:SetText(c.title)
        if c.placed then ui.groupPlacedHead = fs end
    end
    ui.groupScroll = CreateFrame("ScrollFrame", nil, g)
    ui.groupScroll:SetPoint("TOPLEFT", 0, -62)
    ui.groupScroll:SetPoint("BOTTOMRIGHT", 0, 0)
    ui.groupContent = CreateFrame("Frame", nil, ui.groupScroll)
    ui.groupContent:SetSize(GROUP_W, 1)
    ui.groupScroll:SetScrollChild(ui.groupContent)
    ui.groupScroll:EnableMouseWheel(true)
    ui.groupScroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, ui.groupContent:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 44)))
    end)
    g:Hide()

    -- Join screen (replaces the body while visible)
    local j = CreateFrame("Frame", nil, frame)
    j:SetPoint("TOPLEFT", PAD, -94)
    j:SetPoint("BOTTOMRIGHT", -PAD, 14)
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

    ui.title:SetText("SteveBook" .. (b and b.name and (": " .. b.name) or ""))
    ui.book:SetText(b and bookTitle(b) or "No book yet")
    if b and b.status == "active" then
        local bal = b.balance or 0
        local dot = Cache.IsOnline(st, b.code, t) and (GREEN .. "online|r") or (RED .. "offline|r")
        ui.status:SetText("Balance " .. (bal == 0 and money(0) or colorMoney(bal)) .. "  |  " .. dot)
        ui.tabs.bets:SetText("My Bets (" .. #Cache.MyBets(st, b.code).open .. ")")
    else
        ui.status:SetText("")
        ui.tabs.bets:SetText("My Bets")
    end

    ui.joinPanel:SetShown(needJoin)
    if needJoin then
        for _, btn in pairs(ui.tabs) do btn:SetEnabled(false) end
        ui.boardArea:Hide(); ui.slipHolder:Hide(); ui.listScroll:Hide(); ui.group:Hide()
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
        return
    end

    tab = tab or "lines"
    for name, btn in pairs(ui.tabs) do btn:SetEnabled(name ~= tab) end

    ui.group:SetShown(tab == "all")
    if tab == "all" then
        -- Ask the bookie for the group's bets now, then every GROUP_EVERY seconds, only while the
        -- book is online (nothing is sent to an offline bookie).
        if Cache.IsOnline(st, b.code, t) and (not groupReqAt or t - groupReqAt >= GROUP_EVERY) then
            groupReqAt = t                        -- set first: a reply may arrive (and refresh) inside send
            send("BETS_REQ", {}, b.code)
        end
        ui.boardArea:Hide(); ui.slipHolder:Hide(); ui.listScroll:Hide()
        renderGroup(b, t)
        slipUpdate()
    elseif tab == "lines" then
        ui.listScroll:Hide()
        ui.boardArea:Show(); ui.slipHolder:Show()
        local board = Cache.Board(st, b.code, t, filter)
        -- A sport chip that no longer has games goes back to All.
        local known = false
        for _, s in ipairs(board.sports) do if s == filter then known = true end end
        if filter and filter ~= "All" and not known then filter = nil; board = Cache.Board(st, b.code, t, nil) end
        board.code = b.code
        renderChips(board.sports)
        renderBoard(board)
        slipUpdate()
    else
        ui.boardArea:Hide(); ui.slipHolder:Hide()
        ui.listScroll:Show()
        renderList(tab == "bets" and betsEntries(b) or balanceEntries(b))
        slipUpdate()   -- keeps announcing started games even while another tab is open
    end
end

------------------------------------------------------------------------------------------
-- Public helpers (also used by tests)
------------------------------------------------------------------------------------------

-- Click an odds cell programmatically: returns Slip.Select's results.
function Bettor.Select(marketId, selectionId)
    local b = currentBook()
    local m = b and b.markets[marketId]
    if not m then return "refused", "That game is not available." end
    local act, msg = Slip.Select(slip, m, selectionId)
    if act == "refused" then say(msg) end
    Bettor.Refresh()
    return act, msg
end

function Bettor.SetStake(text)
    if ui.stake then ui.stake:SetText(text) end
end

function Bettor.SlipState() return slip end

function Bettor.Show()
    if not store() then return say("SteveBook is still loading.") end
    register()
    if not frame then build() end
    tab = tab or "lines"
    if tab == "all" then groupReqAt = nil end      -- opening the window on this tab asks straight away
    frame:Show()
    Bettor.Refresh()
end

function Bettor.Hide() if frame then frame:Hide() end end

function Bettor.Toggle()
    if shown() then Bettor.Hide() else Bettor.Show() end
end

register()
