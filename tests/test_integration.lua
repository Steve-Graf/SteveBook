-- Integration test: a bookie client and a bettor client (plus a non-member) in one process,
-- joined by a fake Comm bus. Everything above the transport is the real code: Protocol
-- Wrap/Unwrap/ShouldDeliver, real AceSerializer on the wire, Bookie/BookieNet, Cache, and the
-- real bettor window (driven through stubbed frames). Only ns.Comm and the WoW API are fake.
-- Run from repo root: luajit tests/test_integration.lua   (or lua5.1 / lua)
local stub = assert(loadfile("tests/wowstub.lua"))()
local out_ = stub.realPrint
local unpack = table.unpack or unpack

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; out_("FAIL: " .. label) end
end
local function eq(a, b, label)
    if a ~= b then fails = fails + 1; out_(("FAIL: %s (got %s, want %s)"):format(label, tostring(a), tostring(b))) end
end

-- Make labels (font strings) findable by text in this test only; wowstub.lua stays as it is.
do
    local Frame = getmetatable(stub.newFrame())
    function Frame.CreateFontString() local f = stub.newFrame(); rawset(f, "_text", ""); return f end
end

local DIR = "SteveBook/"

------------------------------------------------------------------------------------------
-- Real AceSerializer for the wire
------------------------------------------------------------------------------------------

assert(loadfile(DIR .. "Libs/LibStub/LibStub.lua"))()
assert(loadfile(DIR .. "Libs/AceSerializer-3.0/AceSerializer-3.0.lua"))()
local AceSer = LibStub("AceSerializer-3.0")

------------------------------------------------------------------------------------------
-- Clients and the bus
------------------------------------------------------------------------------------------

local clients, byName = {}, {}
local bus = { log = {}, errors = {} }

local function isOwner(client, code)
    local book = client.ns.Model.FindByCode(client.db, code)
    return book ~= nil and book.ownerName == client.name
end

-- Run fn as `client`: its SavedVariables global, its character name.
local current
local function as(client, fn, ...)
    local prevDb, prevName, prevCur = SteveBookDB, stub.player, current
    SteveBookDB, stub.player, current = client.db, client.name, client
    local res = { pcall(fn, ...) }
    SteveBookDB, stub.player, current = prevDb, prevName, prevCur
    if not res[1] then bus.errors[#bus.errors + 1] = tostring(res[2]); error(res[2], 0) end
    return unpack(res, 2)
end

local function newComm(client)
    local Comm = { handlers = {} }
    function Comm.Register(msgType, fn)
        Comm.handlers[msgType] = Comm.handlers[msgType] or {}
        table.insert(Comm.handlers[msgType], fn)
    end
    function Comm.JoinBook(code) client.joined[code] = true; return true end
    function Comm.LeaveBook(code) client.joined[code] = nil end
    function Comm.IsJoined(code) return client.joined[code] == true end
    function Comm.Me() return client.name end
    function Comm.Send(msgType, payload, code, target)
        local env, err = client.ns.Protocol.Wrap(msgType, code, payload)
        if not env then return false, err end
        local text = AceSer:Serialize(env)
        if #text > 255 * 40 then return false, "too big" end
        client.joined[code] = true                            -- Send auto-joins, like the real one
        local entry = { from = client.name, type = msgType, code = code, target = target, delivered = {} }
        bus.log[#bus.log + 1] = entry
        for _, to in ipairs(clients) do
            local hears = target and (to.name == target) or (not target and to.joined[code])
            if to ~= client and hears then
                local ok, wire = AceSer:Deserialize(text)
                local t, c, p = to.ns.Protocol.Unwrap(wire)
                if t and to.ns.Protocol.ShouldDeliver(t, isOwner(to, c)) then
                    entry.delivered[#entry.delivered + 1] = to.name
                    entry.payload = p
                    for _, fn in ipairs(to.ns.Comm.handlers[t] or {}) do
                        as(to, fn, client.name, p, c)
                    end
                end
            end
        end
        return true
    end
    return Comm
end

local function newClient(name, files)
    local client = { name = name, ns = {}, joined = {}, db = nil }
    clients[#clients + 1] = client
    byName[name] = client
    client.ns.Comm = newComm(client)
    local t0 = #stub.tickers
    for _, f in ipairs(files) do
        local chunk = assert(loadfile(DIR .. f))
        as(client, function() assert(pcall(chunk, "SteveBook", client.ns)) end)
    end
    client.tickers = {}
    for i = t0 + 1, #stub.tickers do client.tickers[#client.tickers + 1] = stub.tickers[i] end
    local Model, Cache = client.ns.Model, client.ns.Cache
    client.db = Model.NewDB()
    client.db.cache = Cache.NewStore()
    return client
end

local function runTickers(client)
    as(client, function() for _, t in ipairs(client.tickers) do t.fn(t) end end)
end

local COMMON = { "Odds.lua", "Protocol.lua", "Clock.lua", "Model.lua", "Bookie.lua", "Cache.lua", "Slip.lua" }
local function files(...)
    local list = {}
    for _, f in ipairs(COMMON) do list[#list + 1] = f end
    for _, f in ipairs({ ... }) do list[#list + 1] = f end
    return list
end

-- Comm is injected before these load, so they register on the fake bus.
local bookie = newClient("Bookie", files("BookieNet.lua"))
local bettor = newClient("Bettor", files("UI/Bettor.lua"))
local mallory = newClient("Mallory", files())   -- never approved; sends raw messages only

local BN = bookie.ns.BookieNet
local Odds = bookie.ns.Odds
local Cache = bettor.ns.Cache
local UI = bettor.ns.UI.Bettor

local function printedSince(n) local o = {}; for i = n + 1, #stub.printed do o[#o + 1] = stub.printed[i] end; return table.concat(o, "\n") end
local function lastLog(msgType, to)
    for i = #bus.log, 1, -1 do
        local e = bus.log[i]
        if e.type == msgType and (not to or e.target == to) then return e end
    end
end
local function countLog(msgType, from)
    local n = 0
    for _, e in ipairs(bus.log) do if e.type == msgType and (not from or e.from == from) then n = n + 1 end end
    return n
end
local function findStakeBox()
    for _, f in ipairs(stub.frames) do
        local s = rawget(f, "_scripts")
        if s and s.OnEnterPressed and s.OnTextChanged then return f end
    end
end
local function frameWithText(substr)
    for _, f in ipairs(stub.frames) do
        local t = rawget(f, "_text")
        if type(t) == "string" and t:find(substr, 1, true) then return f end
    end
end

local CODE
local function bettorBook() return Cache.Book(bettor.db.cache, CODE) end

------------------------------------------------------------------------------------------
-- 1. Bookie creates a book
------------------------------------------------------------------------------------------

local book = as(bookie, BN.CreateBook, "NFL Week 12")
check(book and book.code, "bookie created a book")
CODE = book.code
check(bookie.joined[CODE], "bookie joined the book's channel")
eq(book.ownerName, "Bookie", "book owner is the bookie character")

------------------------------------------------------------------------------------------
-- 2. Bettor requests to join (through the real window)
------------------------------------------------------------------------------------------

local p0 = #stub.printed
as(bettor, UI.Show)
local codeBox
for _, f in ipairs(stub.frames) do
    local s = rawget(f, "_scripts")
    if s and s.OnEnterPressed and not s.OnTextChanged then codeBox = f end
end
check(codeBox ~= nil, "join code box exists")
as(bettor, function() codeBox:SetText((CODE:gsub("-", ""):lower())); stub.findByText("Request to join"):Click() end)

eq(bettorBook() and bettorBook().status, "requested", "bettor cache: requested")
check(book.members.Bettor and book.members.Bettor.status == "pending", "bookie sees a pending member")
check(printedSince(p0):find("Bettor wants to join"), "bookie is told about the request")
eq(countLog("JOIN_REQ", "Bettor"), 1, "one JOIN_REQ sent")
local jr = lastLog("JOIN_REQ")
check(#jr.delivered == 1 and jr.delivered[1] == "Bookie", "JOIN_REQ delivered to the bookie only")
check(not lastLog("JOIN_OK"), "no reply to a pending request")

-- A third player whispering a forged JOIN_OK (claiming the bookie as owner) changes nothing.
as(mallory, function() mallory.ns.Comm.Send("JOIN_OK", { bookName = "Fake", ownerName = "Bookie", rev = 1 }, CODE, "Bettor") end)
eq(bettorBook().status, "requested", "forged JOIN_OK does not approve the bettor")
check(bettorBook().owner == nil, "forged JOIN_OK does not set the owner")
check(not lastLog("SYNC_REQ"), "forged JOIN_OK does not trigger a SYNC_REQ")

-- A non-member's channel messages reach the bookie, never another bettor.
as(mallory, function() mallory.ns.Comm.Send("JOIN_REQ", {}, CODE) end)
jr = lastLog("JOIN_REQ", nil)
check(#jr.delivered == 1 and jr.delivered[1] == "Bookie", "another bettor's JOIN_REQ is not delivered to bettors")
as(bookie, BN.Deny, book, "Mallory")
local denied = lastLog("JOIN_DENY", "Mallory")
check(denied and denied.payload.reason == "denied", "Mallory was denied")

------------------------------------------------------------------------------------------
-- 3. Bookie approves; bettor syncs
------------------------------------------------------------------------------------------

p0 = #stub.printed
as(bookie, BN.Approve, book, "Bettor")
eq(bettorBook().status, "active", "bettor cache: active")
eq(bettorBook().owner, "Bookie", "bettor knows the bookie's name")
eq(bettorBook().name, "NFL Week 12", "bettor knows the book name")
check(printedSince(p0):find("approved"), "bettor is told they were approved")
check(lastLog("SYNC_REQ", nil) and lastLog("SYNC", "Bettor"), "SYNC_REQ then SYNC happened after approval")
check(Cache.IsOnline(bettor.db.cache, CODE, stub.time), "book counts as online after the SYNC")
check(not lastLog("SYNC_REQ").delivered[2], "SYNC_REQ went only to the bookie")

-- Window now shows the book (no join screen).
as(bettor, UI.Refresh)

-- PING/PONG: offline after a minute of silence, online again after the next ping, and the
-- reconnect triggers a re-sync.
stub.advance(61)
check(not Cache.IsOnline(bettor.db.cache, CODE, stub.time), "book goes offline after 60s without a PONG")
local syncs = countLog("SYNC_REQ", "Bettor")
runTickers(bettor)
check(lastLog("PING", nil) and lastLog("PONG", "Bettor"), "bettor pinged and the bookie ponged")
check(Cache.IsOnline(bettor.db.cache, CODE, stub.time), "online again after PONG")
eq(countLog("SYNC_REQ", "Bettor"), syncs + 1, "coming back online re-syncs")

------------------------------------------------------------------------------------------
-- 4. Bookie posts markets; bettor sees them
------------------------------------------------------------------------------------------

local T = stub.time
local m1 = as(bookie, BN.AddMarket, book, { sport = "NFL", event = "PHI @ DAL", type = "spread", line = -3.5, closesAt = T + 3600,
    selections = { { label = "PHI", odds = -110 }, { label = "DAL", odds = -110 } } })
local m2 = as(bookie, BN.AddMarket, book, { sport = "NFL", event = "NYG @ WAS", type = "moneyline", closesAt = T + 600,
    selections = { { label = "NYG", odds = 150 }, { label = "WAS", odds = -170 } } })
check(m1 and m2, "markets created")
check(bettorBook().markets[m1.id] and bettorBook().markets[m2.id], "bettor cache received both markets")
local lines = Cache.Lines(bettor.db.cache, CODE, stub.time)
check(#lines == 1 and #lines[1].events == 2, "Lines shows two NFL events")
eq(Cache.SelectionText(bettorBook().markets[m1.id], 2), "DAL +3.5", "spread text for the second side")
as(bettor, UI.Refresh)

------------------------------------------------------------------------------------------
-- 5. Bet accepted (through the bet slip)
------------------------------------------------------------------------------------------

-- The window's single-bet slip: pick a cell, type a stake. (`odds` is only what the caller
-- expects to see on the slip.)
local function betViaSlip(marketId, selectionId, odds, stakeText)
    as(bettor, function()
        bettor.ns.Slip.ClearAll(UI.SlipState())
        UI.Select(marketId, selectionId)
        UI.SetStake(stakeText)
    end)
end
local function placeButton()
    return stub.findByText("Place Bet") or stub.findByText("Confirm new odds") or stub.findByText("Place Parlay")
end
local function placeClick() as(bettor, function() placeButton():Click() end) end
local function place(stakeText, marketId, selectionId, odds)
    betViaSlip(marketId, selectionId, odds, stakeText)
    placeClick()
end
-- Tab buttons ("My Bets" carries a count, so match the start of the text).
local function tabClick(name)
    for _, f in ipairs(stub.frames) do
        local x, s = rawget(f, "_text"), rawget(f, "_scripts")
        if type(x) == "string" and x:sub(1, #name) == name and s and s.OnClick then as(bettor, function() f:Click() end); return true end
    end
end

p0 = #stub.printed
place("20s", m1.id, 1, -110)
local bet1 = book.bets[1]
check(bet1 and bet1.bettor == "Bettor" and bet1.stake == 2000 and bet1.odds == -110 and bet1.status == "accepted", "bookie recorded bet 1")
check(bettorBook().bets[1] and bettorBook().bets[1].status == "accepted", "bettor cache has bet 1 accepted")
check(next(bettorBook().pending) == nil, "no pending bets left")
check(printedSince(p0):find("Bet accepted"), "bettor told the bet was accepted")
check(printedSince(p0):find("Bettor bet 20s on PHI"), "bookie told about the bet")
local bp = lastLog("BET_PLACE")
check(bp and #bp.delivered == 1 and bp.delivered[1] == "Bookie", "BET_PLACE delivered only to the bookie")
eq(bp.payload.stake, 2000, "BET_PLACE carried the stake in copper")

------------------------------------------------------------------------------------------
-- 6. Rejections
------------------------------------------------------------------------------------------

-- The window refuses bad stakes before anything is sent.
local sent = #bus.log
betViaSlip(m1.id, 1, -110, "2g")
eq(rawget(placeButton(), "_enabled"), false, "window blocks a stake over 1g")
betViaSlip(m1.id, 1, -110, "20s 10c")
eq(rawget(placeButton(), "_enabled"), false, "window blocks a stake with loose copper")
as(bettor, function() findStakeBox():SetText("") end)
as(bettor, function() stub.findByText("Clear"):Click() end)
eq(#bus.log, sent, "nothing was sent for blocked stakes")

-- The bookie refuses them too (raw requests, as a modified client would send).
local function raw(ref, marketId, selectionId, stake, odds)
    as(bettor, function()
        Cache.NewPending(bettor.db.cache, CODE, { ref = ref, marketId = marketId, selectionId = selectionId, stake = stake, odds = odds }, stub.time)
        bettor.ns.Comm.Send("BET_PLACE", { ref = ref, marketId = marketId, selectionId = selectionId, stake = stake, odds = odds }, CODE)
    end)
end
local function lastRejected() local r = bettorBook().rejected; return r[#r] end

raw("raw-big", m1.id, 1, 20000, -110)
eq(lastRejected() and lastRejected().rejectReason, "bad_stake", "bookie rejects a stake over 1g")
raw("raw-copper", m1.id, 1, 2010, -110)
eq(lastRejected() and lastRejected().rejectReason, "bad_stake", "bookie rejects a stake with loose copper")
raw("raw-zero", m1.id, 1, 0, -110)
eq(lastRejected() and lastRejected().rejectReason, "bad_stake", "bookie rejects a zero stake")
raw("raw-sel", m1.id, 9, 1000, -110)
eq(lastRejected() and lastRejected().rejectReason, "bad_selection", "bookie rejects an unknown selection")
raw("raw-mkt", 99, 1, 1000, -110)
eq(lastRejected() and lastRejected().rejectReason, "no_market", "bookie rejects an unknown market")
eq(next(bettorBook().pending), nil, "rejections clear pending")

-- Not a member: Mallory's bet gets a not_member reject from the bookie.
as(mallory, function() mallory.ns.Comm.Send("BET_PLACE", { ref = "m1", marketId = m1.id, selectionId = 1, stake = 1000, odds = -110 }, CODE) end)
local mr = lastLog("BET_REJECT", "Mallory")
check(mr and mr.payload.reason == "not_member", "non-member bet is rejected as not_member")
check(not book.bets[2], "no bet was recorded for the non-member")

-- Odds changed: the slip is open at -110, then the bookie moves the line. The cache follows and the
-- slip asks for a confirmation before anything is sent.
betViaSlip(m1.id, 1, -110, "10s")
p0 = #stub.printed
as(bookie, BN.EditMarket, book, m1.id, { odds = { [1] = -120 } })
eq(Cache.Selection(bettorBook().markets[m1.id], 1).odds, -120, "bettor cache has the new odds")
check(stub.findByText("Confirm new odds") ~= nil, "the slip asks to confirm the new odds")
local nPlace = countLog("BET_PLACE", "Bettor")
placeClick()                                               -- confirms; sends nothing
eq(countLog("BET_PLACE", "Bettor"), nPlace, "confirming the odds sends nothing")
eq(#book.bets, 1, "bookie has not seen a bet yet")
placeClick()                                               -- now it goes out at -120
local bet2 = book.bets[2]
check(bet2 and bet2.odds == -120 and bet2.stake == 1000 and bet2.status == "accepted", "bet booked at the new odds")
eq(bettorBook().bets[2] and bettorBook().bets[2].odds, -120, "bettor cache has bet 2 at -120")
eq(bet1.odds, -110, "bet 1 keeps its original odds")

-- A stale client that still sends -110 is rejected with the current odds, and the window puts the
-- bet back on the slip with the new odds, asking for a confirmation.
as(bettor, function() bettor.ns.Slip.ClearAll(UI.SlipState()) end)
p0 = #stub.printed
raw("stale-odds", m1.id, 1, 1000, -110)
local rej = lastRejected()
check(rej and rej.rejectReason == "odds_changed" and rej.currentOdds == -120, "stale odds are rejected with the current odds")
check(printedSince(p0):find("odds changed") or printedSince(p0):find("The odds changed"), "bettor is told the odds changed")
local restored = UI.SlipState().single
check(restored and restored.marketId == m1.id and restored.odds == -120 and UI.SlipState().confirm.single, "the slip comes back with the new odds")
eq(#book.bets, 2, "bookie did not book the stale bet")
as(bettor, function() bettor.ns.Slip.ClearAll(UI.SlipState()) end)

-- Credit limit: 5000 copper limit, 3000 already at risk.
as(bookie, BN.SetCreditLimit, book, "Bettor", 5000)
eq(bettorBook().creditLimit, 5000, "bettor learned the credit limit from the SYNC")
eq(Cache.CreditAvailable(bettor.db.cache, CODE), 2000, "bettor computes 20s still available")
place("30s", m1.id, 1, -120)
rej = lastRejected()
check(rej and rej.rejectReason == "credit_limit" and rej.available == 2000, "over-limit bet rejected with the amount available")
place("20s", m1.id, 1, -120)
local bet3 = book.bets[3]
check(bet3 and bet3.status == "accepted" and bet3.stake == 2000, "bet exactly at the limit is accepted")
eq(Cache.CreditAvailable(bettor.db.cache, CODE), 0, "nothing available after reaching the limit")

-- Market closing: the sweep locks m2 after its close time and the bettor sees it.
stub.advance(601)
runTickers(bookie)
eq(book.markets[m2.id].status, "locked", "bookie sweep locked the market after its close time")
eq(bettorBook().markets[m2.id].status, "locked", "bettor saw the market lock")
runTickers(bettor)   -- keep the book online after the time jump
local ok, why = Cache.CanBet(bettor.db.cache, CODE, m2.id, stub.time)
check(not ok and (why == "market_closed" or why == "no_market"), "bettor cannot bet on a locked market (" .. tostring(why) .. ")")
check(bettorBook().markets[m2.id] == nil, "the re-sync dropped the closed market the bettor had no bets on")
raw("raw-closed", m2.id, 1, 1000, 150)
eq(lastRejected() and lastRejected().rejectReason, "market_closed", "bookie rejects a bet on a locked market")

------------------------------------------------------------------------------------------
-- 7. Settlement
------------------------------------------------------------------------------------------

p0 = #stub.printed
local expected = Odds.Profit(2000, -110) + Odds.Profit(1000, -120) + Odds.Profit(2000, -120)
as(bookie, BN.Settle, book, m1.id, 1)                      -- PHI wins
eq(bettorBook().markets[m1.id].status, "settled", "bettor saw the market settle")
eq(bettorBook().markets[m1.id].result, 1, "bettor saw the result")
check(printedSince(p0):find("settled"), "bettor told the market settled")
for id = 1, 3 do
    eq(bettorBook().bets[id] and bettorBook().bets[id].status, "won", "bet " .. id .. " won on the bettor side")
end
eq(bettorBook().balance, expected, "bettor balance equals total winnings")
eq(bookie.ns.Bookie.Balance(book, "Bettor"), expected, "bookie ledger matches")
local mine = Cache.MyBets(bettor.db.cache, CODE)
eq(#mine.open, 0, "no open bets after settlement")
check(#mine.settled >= 3, "My Bets lists settled bets")
as(bettor, function()
    for _, tabName in ipairs({ "My Bets", "Balance", "Lines" }) do check(tabClick(tabName), "tab " .. tabName) end
end)
check(#bus.errors == 0, "no handler errors so far: " .. table.concat(bus.errors, "; "))

-- A correction: re-settling flips the result and the bettor follows via SYNC.
as(bookie, BN.Settle, book, m1.id, 2)
eq(bettorBook().bets[1].status, "lost", "corrected settlement: bet 1 now lost")
eq(bettorBook().balance, -(2000 + 1000 + 2000), "balance after the correction")
as(bookie, BN.Settle, book, m1.id, 1)
eq(bettorBook().balance, expected, "balance restored after correcting back")
eq(bookie.ns.Bookie.Balance(book, "Bettor"), expected, "bookie ledger restored too")

------------------------------------------------------------------------------------------
-- 8. Payments
------------------------------------------------------------------------------------------

p0 = #stub.printed
local paid = 4000
as(bookie, BN.RecordPayment, book, "Bettor", "out", paid, "paid 40s")
eq(bettorBook().balance, expected - paid, "balance drops when the book pays the bettor")
check(printedSince(p0):find("Balance with"), "bettor told the balance changed")
local last = bettorBook().payments[#bettorBook().payments]
check(last and last.amount == -paid and last.note, "payment history entry recorded on the bettor side")
as(bookie, BN.RecordPayment, book, "Bettor", "in", 500, "paid back 5s")
eq(bettorBook().balance, expected - paid + 500, "balance rises when the bettor pays the book")
tabClick("Balance")

------------------------------------------------------------------------------------------
-- 9. A loss, and the bookie voiding a bet
------------------------------------------------------------------------------------------

local m3 = as(bookie, BN.AddMarket, book, { sport = "NBA", event = "LAL @ BOS", type = "total", line = 220.5, closesAt = stub.time + 3600,
    selections = { { label = "Over", odds = -105 }, { label = "Under", odds = -115 } } })
runTickers(bettor)
tabClick("Lines")
place("10s", m3.id, 1, -105)
place("10s", m3.id, 2, -115)
local bet4, bet5 = book.bets[4], book.bets[5]
check(bet4 and bet5 and bet4.selectionId == 1 and bet5.selectionId == 2, "two bets on the total")
eq(bettorBook().bets[4] and bettorBook().bets[5] and true, true, "bettor sees both")

local before = bettorBook().balance
as(bookie, BN.VoidBet, book, bet4.id)
eq(bettorBook().bets[4].status, "void", "voided bet shows as void for the bettor")
eq(bettorBook().balance, before, "voiding an open bet leaves the balance alone")
check(Cache.BetDelta(bettorBook().bets[4]) == 0, "void bet has a zero delta")

as(bookie, BN.Settle, book, m3.id, 1)                      -- Over wins: bet 5 (Under) loses
eq(bettorBook().bets[5].status, "lost", "bet on the other side lost")
eq(bettorBook().bets[4].status, "void", "voided bet stays void through settlement")
eq(bettorBook().balance, before - 1000, "a loss costs exactly the stake")
eq(bettorBook().balance, bookie.ns.Bookie.Balance(book, "Bettor"), "bettor and bookie balances agree")

-- A push pays nothing.
local m4 = as(bookie, BN.AddMarket, book, { sport = "NBA", event = "MIA @ NYK", type = "spread", line = -2, closesAt = stub.time + 3600,
    selections = { { label = "MIA", odds = -110 }, { label = "NYK", odds = -110 } } })
runTickers(bettor)
place("10s", m4.id, 1, -110)
before = bettorBook().balance
as(bookie, BN.Settle, book, m4.id, "push")
eq(bettorBook().bets[6] and bettorBook().bets[6].status, "push", "push recorded")
eq(bettorBook().balance, before, "a push leaves the balance alone")

-- Voiding a whole market.
local m5 = as(bookie, BN.AddMarket, book, { sport = "NBA", event = "DEN @ PHX", type = "moneyline", closesAt = stub.time + 3600,
    selections = { { label = "DEN", odds = 120 }, { label = "PHX", odds = -140 } } })
runTickers(bettor)
place("10s", m5.id, 1, 120)
as(bookie, BN.VoidMarket, book, m5.id)
eq(bettorBook().markets[m5.id].status, "void", "bettor saw the market void")
eq(bettorBook().bets[7] and bettorBook().bets[7].status, "void", "bet on a voided market is void")
eq(bettorBook().balance, before, "voiding a market leaves the balance alone")

------------------------------------------------------------------------------------------
-- A game starts while the bettor has the window open
------------------------------------------------------------------------------------------

local function refreshTicker()
    for i = #stub.tickers, 1, -1 do
        local tk = stub.tickers[i]
        if tk.interval == 5 and not tk.cancelled then return tk end
    end
end

local m6 = as(bookie, BN.AddMarket, book, { sport = "NFL", event = "SEA @ SF", type = "moneyline", closesAt = stub.time + 120,
    selections = { { label = "SEA", odds = 110 }, { label = "SF", odds = -130 } } })
runTickers(bettor)
check(Cache.Lines(bettor.db.cache, CODE, stub.time)[1] ~= nil and bettorBook().markets[m6.id], "bettor sees the game before it starts")
as(bettor, function() UI.Show() end)
betViaSlip(m6.id, 1, 110, "10s")
check(refreshTicker() ~= nil, "the open window has a refresh ticker")
eq(rawget(placeButton(), "_enabled"), true, "Place Bet is enabled before the start")

p0 = #stub.printed
stub.advance(121)                                          -- the game starts; the bookie has not swept yet
runTickers(bettor)                                          -- keeps the book online (PONG) after the time jump
as(bettor, function() refreshTicker().fn() end)
check(not Cache.CanBet(bettor.db.cache, CODE, m6.id, stub.time), "the started game takes no bets")
for _, sp in ipairs(Cache.Lines(bettor.db.cache, CODE, stub.time)) do
    for _, ev in ipairs(sp.events) do check(ev.event ~= "SEA @ SF", "the started game is gone from Lines") end
end
eq(UI.SlipState().single, nil, "the started game is taken off the slip")
check(printedSince(p0):find("this game has started"), "the bettor is told why")
check(rawget(placeButton(), "_enabled") == false, "Place Bet is disabled with nothing on the slip")
nPlace = countLog("BET_PLACE", "Bettor")
placeClick()
eq(countLog("BET_PLACE", "Bettor"), nPlace, "the window does not send a bet for a started game")

-- A late BET_PLACE (stale client) still reaches the bookie, which refuses it even before its sweep.
eq(book.markets[m6.id].status, "open", "the bookie has not locked the market yet")
raw("late-1", m6.id, 1, 1000, 110)
eq(lastRejected() and lastRejected().rejectReason, "market_closed", "the late BET_PLACE is rejected with market_closed")
check(not book.bets[#book.bets + 0] or book.bets[#book.bets].marketId ~= m6.id, "no bet was booked on the started game")
as(bookie, BN.Sweep)
eq(book.markets[m6.id].status, "locked", "the sweep locks it afterwards")
as(bettor, function() refreshTicker().fn() end)
check(#bettor.ns.Cache.MyBets(bettor.db.cache, CODE).open == 0, "the bettor holds no open bets on it")

------------------------------------------------------------------------------------------
-- Parlays: the board and slip, the bookie's acceptance and grading, rejections
------------------------------------------------------------------------------------------

local function addMarket(event, type_, line, l1, o1, l2, o2)
    return as(bookie, BN.AddMarket, book, { sport = "NFL", event = event, type = type_, line = line, closesAt = stub.time + 3600,
        selections = { { label = l1, odds = o1 }, { label = l2, odds = o2 } } })
end
local gML = addMarket("GGG @ HHH", "moneyline", nil, "GGG", 120, "HHH", -140)
local gTot = addMarket("GGG @ HHH", "total", 41.5, "Over", -110, "Under", -110)
local gSp = addMarket("GGG @ HHH", "spread", 2.5, "GGG", -105, "HHH", -115)
local iML = addMarket("III @ JJJ", "moneyline", nil, "III", -200, "JJJ", 170)
runTickers(bettor)
tabClick("Lines")
as(bettor, function() bettor.ns.Slip.ClearAll(UI.SlipState()) end)
check(frameWithText("GGG @ HHH") ~= nil, "the board shows the new game")

local function parlayMode()
    for _, f in ipairs(stub.frames) do
        local x, s = rawget(f, "_text"), rawget(f, "_scripts")
        if type(x) == "string" and x:sub(1, 8) == "Parlay (" and s and s.OnClick then as(bettor, function() f:Click() end); return end
    end
end
parlayMode()
eq(UI.SlipState().mode, "parlay", "switched the slip to parlay mode")
local function sel(marketId, selectionId) return (as(bettor, UI.Select, marketId, selectionId)) end
eq(sel(gML.id, 1), "added", "leg 1 (moneyline)")
eq(sel(gTot.id, 2), "added", "leg 2 (total from the same game: allowed)")
p0 = #stub.printed
eq(sel(gSp.id, 1), "refused", "a spread with the moneyline from the same game is refused")
check(printedSince(p0):find("can't go with"), "the refusal names the conflicting leg")
eq(sel(iML.id, 2), "added", "leg 3 (another game)")
eq(#UI.SlipState().parlay, 3, "three legs on the slip")

local legOddsA = { 120, -110, 170 }
as(bettor, function() UI.SetStake("10s") end)
check(stub.findByText("Place Parlay") ~= nil and rawget(stub.findByText("Place Parlay"), "_enabled") == true, "Place Parlay is enabled")
check(frameWithText("Combined odds") ~= nil, "the slip shows combined odds")

local nBets = #book.bets
p0 = #stub.printed
placeClick()
local parlayA = book.bets[nBets + 1]
check(parlayA and parlayA.legs and #parlayA.legs == 3 and parlayA.stake == 1000 and parlayA.status == "accepted", "bookie booked the parlay")
eq(parlayA and parlayA.odds, Odds.ParlayOdds(legOddsA), "the booked price is the combined odds")
local pa = bettorBook().bets[parlayA.id]
check(pa and pa.legs and #pa.legs == 3 and pa.legs[1].status == "pending" and next(bettorBook().pending) == nil, "bettor has the parlay with pending legs")
check(printedSince(p0):find("parlay"), "bettor told the parlay was accepted")
eq(#UI.SlipState().parlay, 0, "the parlay slip was cleared")
tabClick("My Bets")
check(frameWithText("Parlay, 3 legs") ~= nil, "My Bets lists the parlay")
tabClick("Lines")

-- Rejections from the real bookie (raw requests, as a modified or stale client would send them).
local function rawParlay(ref, legs, stake)
    as(bettor, function()
        Cache.NewPending(bettor.db.cache, CODE, { ref = ref, stake = stake, legs = legs }, stub.time)
        bettor.ns.Comm.Send("BET_PLACE", { ref = ref, stake = stake, legs = legs }, CODE)
    end)
end
local function lastRej() local r = bettorBook().rejected; return r[#r] end
rawParlay("pc", { { marketId = gML.id, selectionId = 1, odds = 120 }, { marketId = gSp.id, selectionId = 1, odds = -105 } }, 1000)
check(lastRej().rejectReason == "parlay_conflict" and lastRej().legIndex == 2, "moneyline + spread: parlay_conflict on leg 2")
rawParlay("pd", { { marketId = gML.id, selectionId = 1, odds = 120 }, { marketId = gML.id, selectionId = 2, odds = -140 } }, 1000)
check(lastRej().rejectReason == "parlay_conflict", "the same market twice is a parlay_conflict")
rawParlay("po", { { marketId = gTot.id, selectionId = 1, odds = -110 }, { marketId = gTot.id, selectionId = 2, odds = -110 } }, 1000)
check(lastRej().rejectReason == "parlay_conflict", "over + under is a parlay_conflict")
rawParlay("pb", { { marketId = gML.id, selectionId = 1, odds = 120 }, { marketId = iML.id, selectionId = 2, odds = 170 } }, 20000)
check(lastRej().rejectReason == "bad_stake", "a parlay stake over 1g is rejected")
rawParlay("pm", { { marketId = gML.id, selectionId = 1, odds = 120 }, { marketId = 9999, selectionId = 1, odds = 100 } }, 1000)
check(lastRej().rejectReason == "no_market" and lastRej().legIndex == 2, "an unknown market is rejected with its leg index")
as(bettor, function() bettor.ns.Slip.ClearAll(UI.SlipState()) end)

-- Odds moved on leg 2 (the bettor's request is stale): odds_changed with legIndex, and the window
-- puts the parlay back with the new price and asks for a confirmation.
as(bookie, BN.EditMarket, book, iML.id, { odds = { [1] = -220 } })
p0 = #stub.printed
rawParlay("pq", { { marketId = gML.id, selectionId = 1, odds = 120 }, { marketId = iML.id, selectionId = 1, odds = -200 } }, 1000)
check(lastRej().rejectReason == "odds_changed" and lastRej().legIndex == 2 and lastRej().currentOdds == -220, "stale leg odds: odds_changed with legIndex and the current odds")
local sp = UI.SlipState()
check(sp.mode == "parlay" and #sp.parlay == 2 and sp.parlay[2].odds == -220 and sp.confirm.parlay, "the parlay is back on the slip with leg 2 at -220, awaiting confirmation")
check(printedSince(p0):find("Leg 2"), "the message names leg 2")
eq(#book.bets, nBets + 1, "nothing was booked for any rejected parlay")
as(bettor, function() bettor.ns.Slip.ClearAll(UI.SlipState()) end)

-- Two more parlays to settle: B loses on its first leg, C has a push leg.
local kML = addMarket("KKK @ LLL", "moneyline", nil, "KKK", 130, "LLL", -150)
local lML = addMarket("MMM @ NNN", "moneyline", nil, "MMM", 105, "NNN", -125)
local mSp = addMarket("OOO @ PPP", "spread", -3, "OOO", -110, "PPP", -110)
local nML = addMarket("QQQ @ RRR", "moneyline", nil, "QQQ", -130, "RRR", 110)
runTickers(bettor)
local function placeParlay(a, b2)
    as(bettor, function() bettor.ns.Slip.ClearAll(UI.SlipState()) end)
    sel(a[1], a[2]); sel(b2[1], b2[2])
    as(bettor, function() UI.SetStake("10s") end)
    placeClick()
    return book.bets[#book.bets]
end
local parlayB = placeParlay({ kML.id, 1 }, { lML.id, 1 })
local parlayC = placeParlay({ mSp.id, 1 }, { nML.id, 1 })
check(parlayB.legs and parlayC.legs and bettorBook().bets[parlayB.id] and bettorBook().bets[parlayC.id], "parlays B and C booked and acknowledged")

-- Settle A leg by leg: the parlay stays open until the last leg wins.
local bal0 = bettorBook().balance
p0 = #stub.printed
as(bookie, BN.Settle, book, gML.id, 1)
eq(bettorBook().bets[parlayA.id].legs[1].status, "won", "leg 1 shows won")
eq(bettorBook().bets[parlayA.id].status, "accepted", "the parlay is still open with legs pending")
eq(bettorBook().balance, bal0, "no money moves until the parlay is decided")
as(bookie, BN.Settle, book, gTot.id, 2)
eq(bettorBook().bets[parlayA.id].legs[2].status, "won", "leg 2 shows won")
as(bookie, BN.Settle, book, iML.id, 2)
eq(bettorBook().bets[parlayA.id].status, "won", "all legs won: the parlay won")
local profitA = Odds.ParlayProfit(1000, legOddsA)
eq(bettorBook().balance, bal0 + profitA, "balance rose by the parlay profit")
eq(Cache.BetDelta(bettorBook().bets[parlayA.id]), profitA, "the parlay's delta is its profit")

-- B: the first leg loses and the parlay is lost at once, with the second leg still pending.
bal0 = bettorBook().balance
as(bookie, BN.Settle, book, kML.id, 2)
eq(bettorBook().bets[parlayB.id].status, "lost", "a lost leg loses the parlay immediately")
eq(bettorBook().bets[parlayB.id].legs[2].status, "pending", "the other leg is still pending")
eq(bettorBook().balance, bal0 - 1000, "the stake is lost")
as(bookie, BN.Settle, book, lML.id, 1)
eq(bettorBook().balance, bal0 - 1000, "settling the remaining leg changes nothing")

-- C: a push leg drops out; the other leg is paid as a single price.
bal0 = bettorBook().balance
as(bookie, BN.Settle, book, mSp.id, "push")
eq(bettorBook().bets[parlayC.id].status, "accepted", "a push leg leaves the parlay open while the other leg is pending")
as(bookie, BN.Settle, book, nML.id, 1)
eq(bettorBook().bets[parlayC.id].status, "won", "the remaining leg won")
eq(bettorBook().balance, bal0 + Odds.ParlayProfit(1000, { -130 }), "paid at the winning leg's price only")
tabClick("My Bets"); tabClick("Balance"); tabClick("Lines")
check(Cache.OpenRisk(bettor.db.cache, CODE) == 0, "no open risk after the parlays settle")

------------------------------------------------------------------------------------------
-- A line moves in place: bets keep the line they were accepted on
------------------------------------------------------------------------------------------

local lnSp = addMarket("SSS @ TTT", "spread", -2, "SSS", -110, "TTT", -110)
runTickers(bettor)
tabClick("Lines")
tabClick("Single")                                         -- the slip's Single button (the parlay section left it in parlay mode)
eq(UI.SlipState().mode, "single", "back on the single slip")
place("10s", lnSp.id, 1, -110)
local lineBet = book.bets[#book.bets]
check(lineBet and lineBet.marketId == lnSp.id and lineBet.line == -2, "the bookie recorded the line the bet was accepted on")
eq(bettorBook().bets[lineBet.id].line, -2, "the bettor's cache has the bet with its line")
as(bookie, BN.EditMarket, book, lnSp.id, { line = -3 })
eq(bettorBook().markets[lnSp.id].line, -3, "the bettor saw the line move")
tabClick("My Bets")
check(frameWithText("SSS -2 @") ~= nil and frameWithText("SSS -3 @") == nil, "My Bets still shows the bet at -2")
tabClick("Lines")

-- A slip that was open on the old line must confirm the new one.
as(bettor, function() bettor.ns.Slip.ClearAll(UI.SlipState()) end)
as(bookie, BN.EditMarket, book, lnSp.id, { line = -2 })
betViaSlip(lnSp.id, 1, -110, "10s")
as(bookie, BN.EditMarket, book, lnSp.id, { line = -4 })
check(stub.findByText("Confirm new odds") ~= nil, "a line move under an open slip needs a confirmation")
eq(UI.SlipState().single.line, -4, "the slip took the new line")
as(bettor, function() bettor.ns.Slip.ClearAll(UI.SlipState()) end)

-- A stale request (old line, same odds) is rejected with the current line and comes back on the slip.
local nb = #book.bets
as(bettor, function()
    Cache.NewPending(bettor.db.cache, CODE, { ref = "stale-line", marketId = lnSp.id, selectionId = 1, stake = 1000, odds = -110, line = -2 }, stub.time)
    bettor.ns.Comm.Send("BET_PLACE", { ref = "stale-line", marketId = lnSp.id, selectionId = 1, stake = 1000, odds = -110, line = -2 }, CODE)
end)
local lr = bettorBook().rejected[#bettorBook().rejected]
check(lr and lr.rejectReason == "odds_changed" and lr.currentLine == -4, "a stale line is rejected with the current line")
eq(#book.bets, nb, "nothing was booked on the stale line")
check(UI.SlipState().single and UI.SlipState().single.line == -4 and UI.SlipState().confirm.single, "the bet is back on the slip at the new line")
as(bettor, function() bettor.ns.Slip.ClearAll(UI.SlipState()) end)
as(bookie, BN.Settle, book, lnSp.id, 1)
eq(Cache.OpenRisk(bettor.db.cache, CODE), 0, "the line-move bet is settled")

------------------------------------------------------------------------------------------
-- All Bets: the group's bets, from the real bookie
------------------------------------------------------------------------------------------

do
    -- A second member bets too, so the list has someone other than the viewer.
    local ann = bookie.ns.Bookie
    as(bookie, function() book.members.Ann = { status = "active", joinedAt = stub.time } end)
    local gm = addMarket("UUU @ VVV", "moneyline", nil, "UUU", 110, "VVV", -130)
    runTickers(bettor)
    local annBet
    as(bookie, function() annBet = ann.PlaceBet(book, "Ann", { marketId = gm.id, selectionId = 1, stake = 3000, odds = 110, ref = "ann1" }, stub.time) end)
    place("20s", gm.id, 2, -130)
    tabClick("All Bets")
    local before = countLog("BETS_REQ", "Bettor")
    tabClick("Lines"); tabClick("All Bets")
    eq(countLog("BETS_REQ", "Bettor"), before + 1, "opening All Bets asks the bookie")
    local reply = lastLog("BETS", "Bettor")
    check(reply and #reply.delivered == 1 and reply.delivered[1] == "Bettor", "BETS went to the asker only")
    local g = Cache.GroupBets(bettor.db.cache, CODE)
    check(g ~= nil and #g.open >= 2, "the bettor stored the group's bets")
    local whos = {}
    for _, e in ipairs(g.open) do whos[e.who] = true end
    check(whos.Ann and whos.Bettor, "both members' open bets are listed")
    check(frameWithText("UUU ML") ~= nil or frameWithText("UUU") ~= nil, "the rows show the bookie's pick text")
    check(frameWithText("open,") ~= nil, "the count header is drawn")
    -- Another BETS_REQ right away is ignored by the bookie (rate limit), and nothing breaks.
    as(bettor, function() bettor.ns.Comm.Send("BETS_REQ", {}, CODE) end)
    tabClick("Lines")
    as(bookie, BN.VoidBet, book, annBet.id)        -- keeps the ledger test below about the bettor only
    as(bookie, BN.Settle, book, gm.id, 2)
    eq(Cache.OpenRisk(bettor.db.cache, CODE), 0, "settled again")
end

------------------------------------------------------------------------------------------
-- Forged removals are ignored
------------------------------------------------------------------------------------------

as(mallory, function() mallory.ns.Comm.Send("JOIN_DENY", { ownerName = "Mallory", reason = "removed" }, CODE, "Bettor") end)
eq(bettorBook().status, "active", "forged JOIN_DENY does not remove the bettor")
as(mallory, function() mallory.ns.Comm.Send("JOIN_DENY", { ownerName = "Bookie", reason = "removed" }, CODE, "Bettor") end)
eq(bettorBook().status, "active", "JOIN_DENY impersonating the owner by name is ignored")

------------------------------------------------------------------------------------------
-- 10. Final consistency
------------------------------------------------------------------------------------------

for id, b in pairs(book.bets) do
    if b.bettor == "Bettor" then
        local cb = bettorBook().bets[id]
        check(cb ~= nil, "bettor has bet " .. id)
        if cb then
            eq(cb.status, b.status, "bet " .. id .. " status agrees")
            eq(cb.stake, b.stake, "bet " .. id .. " stake agrees")
            eq(cb.odds, b.odds, "bet " .. id .. " odds agrees")
            eq(cb.line, b.line, "bet " .. id .. " line agrees")
            for i, leg in ipairs(b.legs or {}) do
                eq(cb.legs and cb.legs[i] and cb.legs[i].status, leg.status, "bet " .. id .. " leg " .. i .. " status agrees")
            end
        end
    end
end
eq(bettorBook().balance, bookie.ns.Bookie.Balance(book, "Bettor"), "final balances agree")
eq(Cache.OpenRisk(bettor.db.cache, CODE), 0, "no open risk at the end")
local ledgerSum = 0
for _, l in pairs(book.ledger) do ledgerSum = ledgerSum + l.balance end
eq(ledgerSum, bookie.ns.Bookie.Balance(book, "Bettor"), "ledger only holds the bettor's balance")
check(#bus.errors == 0, "no handler errors: " .. table.concat(bus.errors, "; "))
check(#stub.errors == 0, "no errors reached the error handler: " .. table.concat(stub.errors, "; "))
for _, e in ipairs(bus.log) do
    check(e.delivered, "every message was routed")
    if e.type == "BET_PLACE" or e.type == "JOIN_REQ" or e.type == "SYNC_REQ" then
        for _, name in ipairs(e.delivered) do check(name == "Bookie", e.type .. " from " .. e.from .. " reached " .. name) end
    end
end

-- The real removal comes last because it ends the bettor's membership.
as(bookie, BN.Remove, book, "Bettor")
eq(bettorBook().status, "denied", "the bookie's real removal reaches the bettor")
local rm = lastLog("JOIN_DENY", "Bettor")
check(rm and rm.payload.ownerName == "Bookie" and rm.payload.reason == "removed", "bookie's JOIN_DENY names the owner")

if fails == 0 then out_("test_integration: all passed") else out_(fails .. " FAILED"); os.exit(1) end
