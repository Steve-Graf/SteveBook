-- Run from repo root: luajit tests/test_bookie.lua   (or lua5.1)
local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
local Model = assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)
local Bookie = assert(loadfile("SteveBook/Bookie.lua"))("SteveBook", ns)

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; print("FAIL: " .. label) end
end
local function eq(got, want, label)
    check(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

local NOW = 1000
local G = 10000 -- 1 gold in copper

local function newBook()
    local db = Model.NewDB()
    local book = Model.CreateBook(db, "NFL", "Steve", NOW)
    for _, name in ipairs({ "Bob", "Alice" }) do
        Bookie.RequestJoin(book, name, NOW)
        Bookie.Approve(book, name, NOW)
    end
    return book
end

local function ml(book, closes)
    return Bookie.AddMarket(book, {
        sport = "NFL", event = "PHI @ DAL", type = "moneyline", closesAt = closes or NOW + 3600,
        selections = { { label = "PHI", odds = -150 }, { label = "DAL", odds = 130 } },
    }, NOW)
end

------------------------------------------------------------------------------------------
-- members
------------------------------------------------------------------------------------------
do
    local book = Model.CreateBook(Model.NewDB(), "NFL", "Steve", NOW)
    eq(Bookie.RequestJoin(book, "Bob", NOW), "pending", "new request is pending")
    eq(Bookie.RequestJoin(book, "Bob", NOW), "pending", "repeat request stays pending")
    check(select(2, Bookie.PlaceBet(book, "Bob", {}, NOW)) == "not_member", "pending member cannot bet")
    check(Bookie.Approve(book, "Bob", NOW + 5).status == "active", "approve")
    eq(book.members.Bob.joinedAt, NOW + 5, "joinedAt set")
    eq(Bookie.RequestJoin(book, "Bob", NOW), "active", "active member re-requesting gets active")
    check(Bookie.Remove(book, "Bob"), "remove")
    check(select(2, Bookie.RequestJoin(book, "Bob", NOW)) == "removed", "removed member blocked")
    check(Bookie.Approve(book, "Bob", NOW).status == "active", "removed member can be re-approved")
    Bookie.RequestJoin(book, "Eve", NOW)
    check(Bookie.Deny(book, "Eve"), "deny")
    check(book.members.Eve == nil, "deny deletes request")
    eq(Bookie.RequestJoin(book, "Eve", NOW), "pending", "denied player may ask again")
    check(select(2, Bookie.Deny(book, "Bob")) == "not_pending", "cannot deny active member")
    check(select(2, Bookie.RequestJoin(book, "", NOW)) == "bad_name", "empty name")
    check(Bookie.SetCreditLimit(book, "Bob", 50 * G) and book.members.Bob.creditLimit == 50 * G, "set limit")
    check(select(2, Bookie.SetCreditLimit(book, "Bob", -1)) == "bad_limit", "bad limit")
    check(Bookie.SetCreditLimit(book, "Bob", nil) and book.members.Bob.creditLimit == nil, "clear limit")
end

------------------------------------------------------------------------------------------
-- markets
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local rev0 = book.rev
    local m = ml(book)
    check(m and m.id == 1 and m.status == "open", "market created open")
    check(m.line == nil, "moneyline has no line")
    check(m.selections[1].id == 1 and m.selections[2].id == 2, "selection ids 1,2")
    check(book.rev > rev0, "rev bumped")

    local function bad(spec, want, label)
        local got, err = Bookie.AddMarket(book, spec, NOW)
        check(got == nil and err == want, label .. ": " .. tostring(err))
    end
    local sels = { { label = "A", odds = -110 }, { label = "B", odds = -110 } }
    bad(nil, "bad_spec", "nil spec")
    bad({ type = "parlay", event = "x", closesAt = NOW + 1, selections = sels }, "bad_type", "type")
    bad({ type = "moneyline", event = "", closesAt = NOW + 1, selections = sels }, "bad_event", "event")
    bad({ type = "moneyline", event = "x", closesAt = NOW, selections = sels }, "bad_close_time", "close in past")
    bad({ type = "spread", event = "x", closesAt = NOW + 1, selections = sels }, "bad_line", "spread needs line")
    bad({ type = "moneyline", event = "x", closesAt = NOW + 1, selections = { sels[1] } }, "need_two_selections", "one side")
    bad({ type = "moneyline", event = "x", closesAt = NOW + 1,
          selections = { sels[1], { label = "B", odds = 50 } } }, "bad_odds", "bad odds")
    bad({ type = "moneyline", event = "x", closesAt = NOW + 1,
          selections = { sels[1], { label = "A", odds = -110 } } }, "duplicate_label", "dup label")

    local sp = Bookie.AddMarket(book, { sport = "NFL", event = "PHI @ DAL", type = "spread", line = -3.5,
        closesAt = NOW + 100, selections = sels }, NOW)
    check(sp and sp.line == -3.5 and sp.id == 2, "spread market with line, next id")

    -- edit
    local ok = Bookie.EditMarket(book, m.id, { odds = { [1] = -200, [2] = 170 }, closesAt = NOW + 7200 })
    check(ok and m.selections[1].odds == -200 and m.selections[2].odds == 170 and m.closesAt == NOW + 7200, "edit odds+close")
    check(select(2, Bookie.EditMarket(book, m.id, { odds = { [1] = 5 } })) == "bad_odds", "edit bad odds")
    check(select(2, Bookie.EditMarket(book, m.id, { odds = { [1] = -300, [3] = 100 } })) == "bad_selection", "edit bad selection")
    eq(m.selections[1].odds, -200, "failed edit changes nothing")
    check(select(2, Bookie.EditMarket(book, m.id, { line = 3 })) == "bad_line", "no line on moneyline")
    check(Bookie.EditMarket(book, sp.id, { line = -4 }) and sp.line == -4, "edit spread line")
    check(select(2, Bookie.EditMarket(book, 99, {})) == "no_market", "edit missing market")

    -- lock / unlock / sweep
    check(Bookie.Lock(book, m.id).status == "locked", "lock")
    check(Bookie.Unlock(book, m.id, NOW).status == "open", "unlock before close")
    Bookie.Lock(book, sp.id)
    check(select(2, Bookie.Unlock(book, sp.id, NOW + 100)) == "market_closed", "cannot unlock after close")
    local locked = Bookie.Sweep(book, NOW + 101)
    eq(#locked, 0, "sweep: already-locked market not re-reported")
    sp.status = "open"
    locked = Bookie.Sweep(book, NOW + 101)
    check(#locked == 1 and locked[1] == sp and sp.status == "locked", "sweep locks past-close market")
    eq(m.status, "open", "sweep leaves future market open")
end

------------------------------------------------------------------------------------------
-- betting
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local m = ml(book)
    local function place(who, sel, stake, odds, ref, now)
        return Bookie.PlaceBet(book, who, { marketId = m.id, selectionId = sel, stake = stake, odds = odds, ref = ref }, now or NOW)
    end

    local b = place("Bob", 1, 10 * G, -150, "r1")
    check(b and b.status == "accepted" and b.odds == -150 and b.id == 1, "bet accepted")
    eq(place("Bob", 1, 10 * G, -150, "r1"), b, "same ref returns same bet (idempotent)")
    eq(#Bookie.Snapshot(book, "Bob", NOW).bets, 1, "no duplicate booked")
    check(place("Bob", 1, 10 * G, -150, "r2").id == 2, "new ref is a new bet")

    local function rej(label, want, ...)
        local bet, reason, extra = place(...)
        check(bet == nil and reason == want, label .. ": " .. tostring(reason))
        return extra
    end
    rej("stranger", "not_member", "Mallory", 1, G, -150)
    rej("zero stake", "bad_stake", "Bob", 1, 0, -150)
    rej("fractional stake", "bad_stake", "Bob", 1, 1.5, -150)
    rej("bad selection", "bad_selection", "Bob", 3, G, -150)
    eq(rej("stale odds", "odds_changed", "Bob", 1, G, -140), -150, "stale odds returns current")
    rej("closed by time", "market_closed", "Bob", 1, G, -150, nil, NOW + 3600)
    check(select(2, Bookie.PlaceBet(book, "Bob", { marketId = 99, selectionId = 1, stake = G, odds = 1 }, NOW)) == "no_market", "no market")
    Bookie.Lock(book, m.id)
    rej("locked", "market_closed", "Bob", 1, G, -150)
    Bookie.Unlock(book, m.id, NOW)

    -- odds edits don't touch existing bets
    Bookie.EditMarket(book, m.id, { odds = { [1] = -200 } })
    eq(book.bets[1].odds, -150, "existing bet keeps odds after line move")
    local b3 = place("Alice", 1, G, -200, "a1")
    eq(b3 and b3.odds, -200, "new bet gets new odds")
end

------------------------------------------------------------------------------------------
-- credit limit
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local m = ml(book)
    Bookie.SetCreditLimit(book, "Bob", 100 * G)
    local function place(stake, ref)
        return Bookie.PlaceBet(book, "Bob", { marketId = m.id, selectionId = 1, stake = stake, odds = -150, ref = ref }, NOW)
    end
    check(place(60 * G, "1"), "60g under 100g limit")
    local bet, reason, extra = place(50 * G, "2")
    check(bet == nil and reason == "credit_limit" and extra == 40 * G, "open risk counts: 40g left")
    check(place(40 * G, "3"), "exactly the limit is allowed")
    -- existing debt counts too
    Bookie.Settle(book, m.id, 2, NOW + 1) -- PHI loses: Bob owes 100g
    eq(Bookie.Balance(book, "Bob"), -100 * G, "Bob owes 100g")
    local m2 = ml(book)
    local bet2, r2, e2 = Bookie.PlaceBet(book, "Bob", { marketId = m2.id, selectionId = 1, stake = G, odds = -150 }, NOW + 2)
    check(bet2 == nil and r2 == "credit_limit" and e2 == 0, "debt at limit: nothing available")
    -- paying down frees credit
    Bookie.RecordPayment(book, "Bob", "in", 30 * G, "paid", NOW + 3)
    check(Bookie.PlaceBet(book, "Bob", { marketId = m2.id, selectionId = 1, stake = 30 * G, odds = -150 }, NOW + 3), "payment frees credit")
    -- members without limits are unrestricted
    check(Bookie.PlaceBet(book, "Alice", { marketId = m2.id, selectionId = 1, stake = 9999 * G, odds = -150 }, NOW + 3), "no limit = no cap")
end

------------------------------------------------------------------------------------------
-- settlement and ledger
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local m = ml(book)
    local function bet(who, sel, stake, odds)
        return assert(Bookie.PlaceBet(book, who, { marketId = m.id, selectionId = sel, stake = stake, odds = odds }, NOW))
    end
    local bobBet = bet("Bob", 1, 15 * G, -150)    -- PHI -150: profit 10g
    local aliceBet = bet("Alice", 2, 10 * G, 130) -- DAL +130: profit 13g

    local ex = Bookie.MarketExposure(book, m.id)
    eq(ex.staked, 25 * G, "staked")
    eq(ex.net[1], 10 * G - 10 * G, "book net if PHI wins (Alice's 10g stake - Bob's 10g profit)")
    eq(ex.net[2], 15 * G - 13 * G, "book net if DAL wins")
    eq(ex.net.push, 0, "book net on push")

    local out = Bookie.Settle(book, m.id, 1, NOW + 10)
    eq(#out, 2, "settle returns both bets")
    eq(bobBet.status, "won", "Bob won")
    eq(aliceBet.status, "lost", "Alice lost")
    eq(Bookie.Balance(book, "Bob"), 10 * G, "Bob +10g")
    eq(Bookie.Balance(book, "Alice"), -10 * G, "Alice -10g")
    eq(m.status, "settled", "market settled")
    eq(m.result, 1, "result recorded")
    eq(bobBet.settledAt, NOW + 10, "settledAt")
    check(select(2, Bookie.PlaceBet(book, "Bob", { marketId = m.id, selectionId = 1, stake = G, odds = -150 }, NOW + 11)) == "market_closed", "no bets on settled market")

    -- correcting a wrong result reverses the old one
    Bookie.Settle(book, m.id, 2, NOW + 20)
    eq(Bookie.Balance(book, "Bob"), -15 * G, "re-settle: Bob now -15g")
    eq(Bookie.Balance(book, "Alice"), 13 * G, "re-settle: Alice now +13g")
    eq(bobBet.status, "lost", "re-settle bet status")

    -- push
    Bookie.Settle(book, m.id, "push", NOW + 30)
    eq(Bookie.Balance(book, "Bob"), 0, "push: Bob back to 0")
    eq(Bookie.Balance(book, "Alice"), 0, "push: Alice back to 0")
    eq(bobBet.status, "push", "push status")
    eq(m.result, "push", "push result")

    -- void market after settlement
    Bookie.Settle(book, m.id, 1, NOW + 40)
    Bookie.VoidMarket(book, m.id, NOW + 50)
    eq(Bookie.Balance(book, "Bob"), 0, "void market reverses settlement")
    eq(bobBet.status, "void", "void status")
    eq(m.status, "void", "market void")

    check(select(2, Bookie.Settle(book, m.id, 7, NOW)) == "bad_result", "bad result id")
    check(select(2, Bookie.Settle(book, 99, 1, NOW)) == "no_market", "settle missing market")

    -- void single bet
    local m2 = ml(book)
    local b2 = assert(Bookie.PlaceBet(book, "Bob", { marketId = m2.id, selectionId = 1, stake = 15 * G, odds = -150 }, NOW))
    local b3 = assert(Bookie.PlaceBet(book, "Bob", { marketId = m2.id, selectionId = 1, stake = 3 * G, odds = -150 }, NOW))
    Bookie.Settle(book, m2.id, 1, NOW + 60)
    eq(Bookie.Balance(book, "Bob"), 12 * G, "two winners: 10g + 2g")
    Bookie.VoidBet(book, b2.id, NOW + 61)
    eq(Bookie.Balance(book, "Bob"), 2 * G, "voided bet removed from balance")
    eq(b2.status, "void", "single void status")
    eq(b3.status, "won", "other bet untouched")
    check(select(2, Bookie.VoidBet(book, 999, NOW)) == "no_bet", "void missing bet")

    -- payments
    -- Bob balance is +2g (book owes Bob); Alice is 0
    eq(Bookie.RecordPayment(book, "Bob", "out", 2 * G, "paid Bob", NOW + 70), 0, "book pays Bob 2g -> 0")
    eq(Bookie.RecordPayment(book, "Alice", "in", 5 * G, "overpay", NOW + 71), 5 * G, "overpayment allowed")
    eq(book.ledger.Bob.payments[1].amount, -2 * G, "payment stored as signed delta")
    check(select(2, Bookie.RecordPayment(book, "Alice", "in", 0, nil, NOW)) == "bad_amount", "zero payment")
    check(select(2, Bookie.RecordPayment(book, "Alice", "sideways", 5, nil, NOW)) == "bad_direction", "bad direction")
    check(select(2, Bookie.RecordPayment(book, "Nobody", "in", 5, nil, NOW)) == "no_member", "unknown player")
end

------------------------------------------------------------------------------------------
-- snapshot
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local old = ml(book)
    local cur = ml(book, NOW + 9 * 24 * 3600)
    Bookie.PlaceBet(book, "Bob", { marketId = old.id, selectionId = 1, stake = G, odds = -150 }, NOW)
    Bookie.PlaceBet(book, "Alice", { marketId = cur.id, selectionId = 1, stake = G, odds = -150 }, NOW)
    Bookie.Settle(book, old.id, 1, NOW)
    local later = NOW + 8 * 24 * 3600
    local s = Bookie.Snapshot(book, "Bob", later)
    eq(#s.markets, 1, "old settled market dropped after 7 days")
    eq(s.markets[1].id, cur.id, "open market kept")
    eq(#s.bets, 0, "bets on dropped market dropped")
    eq(s.balance, 10000 * 0 + 6666, "balance included even when its market is old")
    eq(s.rev, book.rev, "rev included")

    local s2 = Bookie.Snapshot(book, "Bob", NOW + 1)
    eq(#s2.markets, 2, "recent settled market kept")
    eq(#s2.bets, 1, "own bets only")
    eq(s2.bets[1].bettor, "Bob", "bet belongs to Bob")
    local sa = Bookie.Snapshot(book, "Alice", NOW + 1)
    eq(#sa.bets, 1, "Alice sees her bet")
    eq(sa.balance, 0, "Alice balance 0 (bet still open)")

    for i = 1, 25 do Bookie.RecordPayment(book, "Bob", "in", i, nil, NOW + i) end
    eq(#Bookie.Snapshot(book, "Bob", NOW + 1).payments, 20, "payments capped at 20")
    eq(#Bookie.Snapshot(book, "Stranger", NOW).bets, 0, "unknown player: empty snapshot")
end

if fails == 0 then print("bookie: all tests passed") else os.exit(1) end
