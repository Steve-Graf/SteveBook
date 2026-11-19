-- Run from repo root: lua tests/test_bettor_cache.lua
local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
local Cache = assert(loadfile("SteveBook/Cache.lua"))("SteveBook", ns)

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; print("FAIL: " .. label) end
end

local NOW = 1000000
local function mkt(id, sport, event, type_, closes, status)
    return { id = id, sport = sport, event = event, type = type_, closesAt = closes, status = status or "open",
        selections = { { id = 1, label = "A", odds = -110 }, { id = 2, label = "B", odds = 100 } } }
end

local s = Cache.NewStore()
check(Cache.Book(s, "nfl-abcd", false) == nil, "no book until created")
local b = Cache.RequestJoin(s, " nfl-abcd ")
check(b.code == "NFL-ABCD" and b.status == "requested", "join request normalizes code")
check(Cache.Book(s, "NFL-ABCD") == b, "lookup normalizes")
check(not Cache.CanBet(s, "NFL-ABCD", 1, NOW), "cannot bet while not a member")

Cache.SetMembership(s, "NFL-ABCD", false)
check(b.status == "denied", "denied")
Cache.SetMembership(s, "NFL-ABCD", true, "NFL Week 12")
check(b.status == "active" and b.name == "NFL Week 12", "approved")

-- SYNC replaces wholesale.
Cache.ApplySync(s, "NFL-ABCD", {
    rev = 5, balance = -2500,
    markets = { mkt(1, "NFL", "PHI @ DAL", "total", NOW + 100), mkt(2, "NFL", "PHI @ DAL", "moneyline", NOW + 100),
                mkt(3, "NBA", "LAL @ BOS", "moneyline", NOW + 50), mkt(4, "NFL", "old", "moneyline", NOW - 10, "settled") },
    bets = { { id = 1, ref = "r1", marketId = 2, selectionId = 1, stake = 1000, odds = -110, status = "accepted", placedAt = NOW - 5 } },
    payments = { { amount = 500, at = NOW - 99, note = "paid" } }, creditLimit = 10000,
}, NOW)
check(b.rev == 5 and b.balance == -2500 and b.creditLimit == 10000 and b.syncedAt == NOW, "sync scalars")

Cache.ApplySync(s, "NFL-ABCD", { rev = 6, markets = { mkt(9, "NFL", "X", "moneyline", NOW + 9) }, bets = {}, balance = 0 }, NOW)
check(b.markets[1] == nil and b.markets[9] ~= nil and next(b.bets) == nil and b.creditLimit == nil, "sync replaces, not merges")

Cache.ApplySync(s, "NFL-ABCD", {
    rev = 7, balance = -2500, creditLimit = 10000,
    markets = { mkt(1, "NFL", "PHI @ DAL", "total", NOW + 100), mkt(2, "NFL", "PHI @ DAL", "moneyline", NOW + 100),
                mkt(3, "NBA", "LAL @ BOS", "moneyline", NOW + 50), mkt(4, "NFL", "old", "moneyline", NOW - 10, "settled") },
    bets = { { id = 1, ref = "r1", marketId = 2, selectionId = 1, stake = 1000, odds = -110, status = "accepted", placedAt = NOW - 5 } },
}, NOW)

-- Lines: grouped by sport, ML before total, settled excluded.
local lines = Cache.Lines(s, "NFL-ABCD", NOW)
check(#lines == 2 and lines[1].sport == "NBA" and lines[2].sport == "NFL", "sports sorted")
check(#lines[2].events == 1 and lines[2].events[1].event == "PHI @ DAL", "settled/old event excluded")
check(lines[2].events[1].markets[1].type == "moneyline" and lines[2].events[1].markets[2].type == "total", "market type order")
check(#Cache.Lines(s, "NFL-ABCD", NOW + 200) == 0, "past-close markets drop out of Lines")
check(#Cache.Lines(s, "NOPE-1234", NOW) == 0, "unknown book has no lines")

-- Online / CanBet.
check(not Cache.IsOnline(s, "NFL-ABCD", NOW), "offline before any PONG")
local ok, why = Cache.CanBet(s, "NFL-ABCD", 2, NOW)
check(not ok and why == "offline", "Place Bet disabled with no PONG")
Cache.MarkPong(s, "NFL-ABCD", NOW)
check(Cache.CanBet(s, "NFL-ABCD", 2, NOW + 10), "can bet with recent PONG")
ok, why = Cache.CanBet(s, "NFL-ABCD", 2, NOW + Cache.PONG_TTL + 1)
check(not ok and why == "offline", "PONG goes stale")
Cache.MarkPong(s, "NFL-ABCD", NOW + 150)
ok, why = Cache.CanBet(s, "NFL-ABCD", 2, NOW + 150)
check(not ok and why == "market_closed", "closed by time")
ok, why = Cache.CanBet(s, "NFL-ABCD", 4, NOW)
check(not ok and why == "market_closed", "settled market")
ok, why = Cache.CanBet(s, "NFL-ABCD", 77, NOW)
check(not ok and why == "no_market", "unknown market")

-- MARKET updates.
local m2 = mkt(2, "NFL", "PHI @ DAL", "moneyline", NOW + 100, "locked")
Cache.ApplyMarket(s, "NFL-ABCD", m2)
check(b.markets[2] == m2 and #Cache.Lines(s, "NFL-ABCD", NOW)[2].events[1].markets == 1, "locked market leaves Lines")

-- Pending -> ACK.
local p = Cache.NewPending(s, "NFL-ABCD", { ref = "r2", marketId = 3, selectionId = 2, stake = 500, odds = 100 }, NOW)
check(p.status == "pending" and b.pending.r2 == p, "pending recorded")
check(Cache.OpenRisk(s, "NFL-ABCD") == 1500, "open risk counts pending + accepted")
check(Cache.CreditAvailable(s, "NFL-ABCD") == 10000 - 2500 - 1500, "credit available")
local bets = Cache.MyBets(s, "NFL-ABCD")
check(#bets.open == 2 and #bets.settled == 0 and bets.open[1].ref == "r2", "MyBets open, newest first")
check(bets.open[2].market == b.markets[2], "bet row carries its market")
Cache.ApplyBetAck(s, "NFL-ABCD", "r2", { id = 2, ref = "r2", marketId = 3, selectionId = 2, stake = 500, odds = 100, status = "accepted", placedAt = NOW })
check(b.pending.r2 == nil and b.bets[2].status == "accepted" and #Cache.MyBets(s, "NFL-ABCD").open == 2, "ack moves pending -> bets without duplicating")

-- Pending -> REJECT.
Cache.NewPending(s, "NFL-ABCD", { ref = "r3", marketId = 3, selectionId = 1, stake = 99, odds = -110 }, NOW + 1)
local rej = Cache.ApplyBetReject(s, "NFL-ABCD", "r3", "odds_changed", -120, NOW + 2)
check(rej and rej.rejectReason == "odds_changed" and rej.currentOdds == -120, "reject keeps reason and current odds")
check(Cache.ApplyBetReject(s, "NFL-ABCD", "zzz", "x", nil, NOW) == nil, "unknown ref ignored")
bets = Cache.MyBets(s, "NFL-ABCD")
check(#bets.open == 2 and #bets.settled == 1 and bets.settled[1].status == "rejected", "rejected shows under settled")

-- SYNC keeps un-acked pending bets, drops ones the snapshot now contains.
Cache.NewPending(s, "NFL-ABCD", { ref = "r4", marketId = 3, selectionId = 1, stake = 10, odds = -110 }, NOW + 3)
Cache.NewPending(s, "NFL-ABCD", { ref = "r5", marketId = 3, selectionId = 1, stake = 20, odds = -110 }, NOW + 3)
Cache.ApplySync(s, "NFL-ABCD", { rev = 8, markets = { mkt(3, "NBA", "LAL @ BOS", "moneyline", NOW + 50) },
    bets = { { id = 7, ref = "r4", marketId = 3, selectionId = 1, stake = 10, odds = -110, status = "accepted", placedAt = NOW + 3 } },
    balance = 0 }, NOW + 4)
check(b.pending.r4 == nil and b.pending.r5 ~= nil, "sync resolves acked pending, keeps the rest")

-- Expiry.
check(#Cache.ExpirePending(s, "NFL-ABCD", NOW + 10) == 0, "not expired yet")
local dropped = Cache.ExpirePending(s, "NFL-ABCD", NOW + 3 + 120)
check(#dropped == 1 and dropped[1].rejectReason == "no_reply" and b.pending.r5 == nil, "unanswered request expires")

-- Settled bets and balance.
Cache.ApplyBalance(s, "NFL-ABCD", 1234, { amount = 1234, at = NOW, note = "paid you" })
check(b.balance == 1234 and #b.payments == 1, "balance absolute + payment entry")
b.bets[7].status = "won"
check(#Cache.MyBets(s, "NFL-ABCD").settled == 3, "won bet + r3 reject + r5 no_reply are settled")
check(Cache.CreditAvailable(s, "NFL-ABCD") == nil, "no limit -> nil")
b.creditLimit = 1000
check(Cache.CreditAvailable(s, "NFL-ABCD") == 1000, "positive balance, no open risk: full limit")
b.balance = -5000
check(Cache.CreditAvailable(s, "NFL-ABCD") == 0, "credit available never negative")
check(Cache.SelectionLabel(b.markets[3], 2) == "B" and Cache.SelectionLabel(nil, 2) == "#2", "selection label fallback")

-- Grading from MARKET results.
do
    local gs = Cache.NewStore()
    Cache.ApplySync(gs, "G-1", { rev = 1, balance = 0, markets = { mkt(1, "NFL", "e", "moneyline", NOW + 9) },
        bets = { { id = 1, ref = "a", marketId = 1, selectionId = 1, stake = 100, odds = -110, status = "accepted", placedAt = 1 },
                 { id = 2, ref = "b", marketId = 1, selectionId = 2, stake = 100, odds = 100, status = "accepted", placedAt = 2 },
                 { id = 3, ref = "c", marketId = 1, selectionId = 2, stake = 100, odds = 100, status = "void", placedAt = 3 } } }, NOW)
    local g = Cache.Book(gs, "G-1")
    local m = mkt(1, "NFL", "e", "moneyline", NOW + 9, "settled"); m.result = 1
    Cache.ApplyMarket(gs, "G-1", m)
    check(g.bets[1].status == "won" and g.bets[2].status == "lost" and g.bets[3].status == "void", "settle grades my bets, keeps voided bet")
    m = mkt(1, "NFL", "e", "moneyline", NOW + 9, "settled"); m.result = "push"
    Cache.ApplyMarket(gs, "G-1", m)
    check(g.bets[1].status == "push" and g.bets[2].status == "push", "re-settle as push")
    Cache.ApplyMarket(gs, "G-1", mkt(1, "NFL", "e", "moneyline", NOW + 9, "void"))
    check(g.bets[1].status == "void" and g.bets[2].status == "void", "void market voids bets")
    local _, old = Cache.ApplyMarket(gs, "G-1", mkt(1, "NFL", "e", "moneyline", NOW + 9, "locked"))
    check(old and old.status == "void" and g.bets[1].status == "void", "ApplyMarket returns the previous market")
    local m5 = mkt(5, "NFL", "e", "moneyline", NOW + 9)
    check(select(2, Cache.ApplyMarket(gs, "G-1", m5)) == nil, "new market has no previous")
end

-- Display helpers.
local spread = { type = "spread", line = -3.5, selections = { { id = 1, label = "PHI" }, { id = 2, label = "DAL" } } }
check(Cache.SelectionText(spread, 1) == "PHI -3.5" and Cache.SelectionText(spread, 2) == "DAL +3.5", "spread text")
local total = { type = "total", line = 47.5, selections = { { id = 1, label = "Over" }, { id = 2, label = "Under" } } }
check(Cache.SelectionText(total, 1) == "Over 47.5" and Cache.SelectionText(total, 2) == "Under 47.5", "total text")
check(Cache.SelectionText({ type = "moneyline", selections = { { id = 1, label = "PHI" } } }, 1) == "PHI", "moneyline text")
check(Cache.ReasonText("credit_limit"):find("credit") and Cache.ReasonText("zzz"):find("zzz"), "reason text")
check(Cache.BetDelta({ status = "won", stake = 1000, odds = -110 }) == 909, "won delta")
check(Cache.BetDelta({ status = "lost", stake = 1000, odds = -110 }) == -1000, "lost delta")
check(Cache.BetDelta({ status = "push", stake = 1000, odds = -110 }) == 0, "push delta")
check(Cache.BetDelta({ status = "accepted", stake = 1000, odds = -110 }) == nil, "open bet has no delta")
check(Cache.BetDelta({ status = "won", stake = 1000, odds = -110, delta = 5 }) == 5, "bookie delta preferred")

-- PONG sender check.
local pb = Cache.SetMembership(s, "NFL-ABCD", true, nil, "Bookie")
check(Cache.MarkPong(s, "NFL-ABCD", 5, "Mallory") == nil and pb.lastPong ~= 5, "PONG from non-owner ignored")
check(Cache.MarkPong(s, "NFL-ABCD", 5, "Bookie") and pb.lastPong == 5, "PONG from owner counts")

-- Books.
Cache.RequestJoin(s, "AAA-1111")
check(#Cache.ListBooks(s) == 2 and Cache.ListBooks(s)[1].code == "AAA-1111", "books listed sorted")
Cache.Forget(s, "aaa-1111")
check(#Cache.ListBooks(s) == 1, "forget")

if fails == 0 then print("test_bettor_cache: all passed") else print(fails .. " FAILED"); os.exit(1) end
