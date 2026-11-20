-- BookieNet.lua: glue between the bookie's pure logic (Bookie.lua) and the client (Comm.lua).
-- Registers the bettor->bookie handlers, runs the market-close sweep, and exposes one action
-- function per bookie operation (state change + the right broadcast) for UI/Bookie.lua to call,
-- so the window never talks to Comm itself.
--
-- WoW API used: GetServerTime, UnitName, print, C_Timer.NewTicker (guarded). Anything else is
-- Comm.lua's contract: ns.Comm.Register(type, fn(sender, payload, bookCode)), ns.Comm.Send(type,
-- payload, bookCode, targetOrNil), ns.Comm.JoinBook(code), ns.Comm.Me().
-- Load order: after Comm.lua (it registers at load), before UI/Bookie.lua.
local ADDON, ns = ...
ns = ns or {}
local Model, Bookie, Odds = ns.Model, ns.Bookie, ns.Odds

local BookieNet = {}
ns.BookieNet = BookieNet

local SWEEP_SECONDS = 5     -- a started game must stop taking bets promptly (Bookie.PlaceBet also checks the clock)

local function now() return GetServerTime() end
local function say(msg) print("|cffffd100SteveBook:|r " .. msg) end

-- This character's name, as Comm hands names to handlers (UnitName as a fallback).
local function me() return (ns.Comm and ns.Comm.Me and ns.Comm.Me()) or UnitName("player") end

function BookieNet.Me() return me() end

-- Books this character runs. A book only answers, sweeps and shows up for the character that
-- owns it, so e.g. a PING for someone else's book is never answered from here.
function BookieNet.MyBooks()
    local list = {}
    if not SteveBookDB then return list end
    for _, b in ipairs(Model.ListBooks(SteveBookDB)) do
        if b.ownerName == me() then list[#list + 1] = b end
    end
    return list
end

-- Send a list of { type, payload, to } built by Bookie.lua. `to` nil = broadcast on the channel.
local function send(book, msgs)
    for _, m in ipairs(msgs) do
        local ok, err = ns.Comm.Send(m.type, m.payload, book.code, m.to)
        if ok == false then say(("could not send %s: %s"):format(m.type, tostring(err))) end
    end
end

-- The window subscribes to learn that a book changed (new request, bet, market locked...).
local listeners = {}
function BookieNet.Subscribe(fn) listeners[#listeners + 1] = fn end
local function changed(book)
    for _, fn in ipairs(listeners) do fn(book) end
end

------------------------------------------------------------------------------------------
-- Incoming: JOIN_REQ, SYNC_REQ, BET_PLACE, PING
------------------------------------------------------------------------------------------

local function announce(book, events)
    for _, e in ipairs(events) do
        if e.kind == "join_request" then
            say(("%s wants to join %s. /book bookie to approve."):format(e.name, book.name))
        elseif e.kind == "bet" then
            local b = e.bet
            if b.legs then
                say(("%s bet %s on a %d-leg parlay (%s)."):format(b.bettor, Odds.FormatMoney(b.stake),
                    #b.legs, Odds.Format(b.odds)))
            else
                local m = book.markets[b.marketId]
                local sel = m and m.selections[b.selectionId]
                say(("%s bet %s on %s %s (%s)."):format(b.bettor, Odds.FormatMoney(b.stake),
                    sel and sel.label or "?", Odds.Format(b.odds), m and m.event or "?"))
            end
        end
        -- bet_rejected: the bettor already sees the reason; not worth chat noise here.
    end
end

local function onBettorMessage(msgType)
    return function(sender, payload, bookCode)
        local book = SteveBookDB and Model.FindByCode(SteveBookDB, bookCode)
        if not book then return end                    -- not one of our books (or we're a bettor there)
        -- PING is delivered to every client, so check ownership here too: Comm only filters the
        -- bettor->bookie types (JOIN_REQ, SYNC_REQ, BET_PLACE) by owner.
        if book.ownerName ~= me() then return end
        if sender == book.ownerName then return end    -- our own message echoed back
        local out, events = Bookie.Handle(book, sender, msgType, payload, now())
        send(book, out)
        announce(book, events)
        changed(book)
    end
end

for _, t in ipairs({ "JOIN_REQ", "SYNC_REQ", "BET_PLACE", "PING" }) do
    ns.Comm.Register(t, onBettorMessage(t))
end

------------------------------------------------------------------------------------------
-- Market-close sweep
------------------------------------------------------------------------------------------

-- Lock markets whose close time passed and tell the bettors. Runs on a ticker.
function BookieNet.Sweep()
    for _, book in ipairs(BookieNet.MyBooks()) do
        local locked = Bookie.Sweep(book, now())
        for _, m in ipairs(locked) do send(book, { Bookie.MarketMessage(book, m) }) end
        if #locked > 0 then changed(book) end
    end
end

if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(SWEEP_SECONDS, BookieNet.Sweep) end

------------------------------------------------------------------------------------------
-- Actions (called by the window). Each returns the result, or nil, reasonCode.
------------------------------------------------------------------------------------------

-- New book, and start listening on its channel.
function BookieNet.CreateBook(name)
    local book, err = Model.CreateBook(SteveBookDB, name, UnitName("player"), now())
    if not book then return nil, err end
    ns.Comm.JoinBook(book.code)
    return book
end

-- Markets: every change is broadcast whole. spec/changes shapes: see Bookie.AddMarket/EditMarket.
local function marketOp(fn)
    return function(book, ...)
        local m, err = fn(book, ...)
        if not m then return nil, err end
        send(book, { Bookie.MarketMessage(book, m) })
        changed(book)
        return m
    end
end

BookieNet.AddMarket = marketOp(function(book, spec) return Bookie.AddMarket(book, spec, now()) end)
BookieNet.EditMarket = marketOp(function(book, id, changes) return Bookie.EditMarket(book, id, changes, now()) end)   -- (book, marketId, changes)
BookieNet.LockMarket = marketOp(Bookie.Lock)                        -- (book, marketId)
BookieNet.UnlockMarket = marketOp(function(book, id) return Bookie.Unlock(book, id, now()) end)

-- Import (SPEC §7): re-plan the pasted text against the book as it is NOW (so a stale preview can't
-- post duplicates or touch a market that closed meanwhile), then add the new markets and update the
-- odds (and, for a moved spread or total line, the line) of the matching open market. Each change
-- is broadcast as a MARKET like any other edit.
-- Returns { added = n, updated = n, failed = { "line 3: message", ... }, plan = plan }.
function BookieNet.ApplyImport(book, text)
    local plan = ns.Import.Plan(book, text, now())
    local r = { added = 0, updated = 0, failed = {}, plan = plan }
    for _, it in ipairs(plan.items) do
        if it.status == "ok" then
            local m, err = BookieNet.AddMarket(book, it.spec)
            if m then r.added = r.added + 1 else r.failed[#r.failed + 1] = ("line %d: %s"):format(it.line, tostring(err)) end
        elseif it.status == "update" then
            local m, err = BookieNet.EditMarket(book, it.marketId,
                { odds = next(it.changes) and it.changes or nil, line = it.newLine })
            if m then r.updated = r.updated + 1 else r.failed[#r.failed + 1] = ("line %d: %s"):format(it.line, tostring(err)) end
        end
    end
    return r
end

-- Bets changed state: broadcast the market, and give each affected bettor a fresh SYNC (bet
-- statuses and balances changed; MARKET alone doesn't carry bets).
local function afterSettlement(book, marketId, results)
    send(book, { Bookie.MarketMessage(book, book.markets[marketId]) })
    send(book, Bookie.SyncMessages(book, Bookie.AffectedBettors(results), now()))
    changed(book)
    return results
end

-- result: winning selection id, or "push". Settling an already-settled market corrects it.
function BookieNet.Settle(book, marketId, result)
    local results, err = Bookie.Settle(book, marketId, result, now())
    if not results then return nil, err end
    return afterSettlement(book, marketId, results)
end

function BookieNet.VoidMarket(book, marketId)
    local results, err = Bookie.VoidMarket(book, marketId, now())
    if not results then return nil, err end
    return afterSettlement(book, marketId, results)
end

function BookieNet.VoidBet(book, betId)
    local bet, err = Bookie.VoidBet(book, betId, now())
    if not bet then return nil, err end
    send(book, Bookie.SyncMessages(book, { bet.bettor }, now()))
    changed(book)
    return bet
end

-- Members.
function BookieNet.Approve(book, name)
    local m, err = Bookie.Approve(book, name, now())
    if not m then return nil, err end
    send(book, { { type = "JOIN_OK", to = name,
                   payload = { bookName = book.name, ownerName = book.ownerName or "", rev = book.rev } } })
    changed(book)
    return m
end

local function denyOp(fn, reason)
    return function(book, name)
        local ok, err = fn(book, name)
        if not ok then return nil, err end
        send(book, { { type = "JOIN_DENY", to = name, payload = { reason = reason, ownerName = book.ownerName or "" } } })
        changed(book)
        return true
    end
end
BookieNet.Deny = denyOp(Bookie.Deny, "denied")           -- pending request refused
BookieNet.Remove = denyOp(Bookie.Remove, "removed")      -- active member removed

function BookieNet.SetCreditLimit(book, name, limit)
    local ok, err = Bookie.SetCreditLimit(book, name, limit)
    if not ok then return nil, err end
    send(book, Bookie.SyncMessages(book, { name }, now()))   -- their SYNC carries creditLimit
    changed(book)
    return true
end

-- Ledger. direction "in": the player paid the book; "out": the book paid the player.
function BookieNet.RecordPayment(book, player, direction, amount, note)
    local balance, err = Bookie.RecordPayment(book, player, direction, amount, note, now())
    if not balance then return nil, err end
    local text = (direction == "in" and "Payment received: " or "Book paid you: ") .. Odds.FormatMoney(amount)
    if note and note ~= "" then text = text .. " (" .. note .. ")" end
    send(book, { Bookie.BalanceMessage(book, player, text) })
    changed(book)
    return balance
end

return BookieNet
