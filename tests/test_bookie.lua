-- Run from repo root: luajit tests/test_bookie.lua   (or lua5.1)
local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)   -- Model.NormalizeCode needs Protocol.CanonicalCode
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
local G = 100   -- 1 silver in copper. The max stake is 1g = 100 * G (Odds.MAX_STAKE).

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
    local ok = Bookie.EditMarket(book, m.id, { odds = { [1] = -200, [2] = 170 }, closesAt = NOW + 7200 }, NOW)
    check(ok and m.selections[1].odds == -200 and m.selections[2].odds == 170 and m.closesAt == NOW + 7200, "edit odds+close")
    check(select(2, Bookie.EditMarket(book, m.id, { odds = { [1] = 5 } }, NOW)) == "bad_odds", "edit bad odds")
    check(select(2, Bookie.EditMarket(book, m.id, { odds = { [1] = -300, [3] = 100 } }, NOW)) == "bad_selection", "edit bad selection")
    eq(m.selections[1].odds, -200, "failed edit changes nothing")
    check(select(2, Bookie.EditMarket(book, m.id, { line = 3 }, NOW)) == "bad_line", "no line on moneyline")
    check(Bookie.EditMarket(book, sp.id, { line = -4 }, NOW) and sp.line == -4, "edit spread line")
    check(select(2, Bookie.EditMarket(book, 99, {}, NOW)) == "no_market", "edit missing market")

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
    Bookie.EditMarket(book, m.id, { odds = { [1] = -200 } }, NOW)
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
    check(Bookie.PlaceBet(book, "Alice", { marketId = m2.id, selectionId = 1, stake = 100 * G, odds = -150 }, NOW + 3), "no limit = no cap (up to the 1g max stake)")
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

    -- a bet voided on its own stays void when its market is settled again or voided later
    Bookie.Settle(book, m2.id, 2, NOW + 65)      -- correct the result: PHI side now loses
    eq(b2.status, "void", "voided bet stays void through a re-settle")
    eq(b3.status, "lost", "other bet follows the new result")
    eq(Bookie.Balance(book, "Bob"), -3 * G, "balance counts only the live bet")
    Bookie.VoidMarket(book, m2.id, NOW + 66)
    eq(b2.status, "void", "voided bet stays void through a market void")
    eq(b3.status, "void", "market void refunds the live bet")
    eq(Bookie.Balance(book, "Bob"), 0, "market void clears the balance")
    -- and re-settling a void market brings the market-voided bet back, but not the single-voided one
    Bookie.Settle(book, m2.id, 1, NOW + 67)
    eq(b3.status, "won", "market-voided bet is settled again")
    eq(b2.status, "void", "single-voided bet still void")
    eq(Bookie.Balance(book, "Bob"), 2 * G, "only the live bet pays out")

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
-- snapshot (SPEC §5): only markets that still take bets, plus the markets THIS bettor's bets
-- refer to. Games that have started or finished are not presented to anyone who did not bet.
------------------------------------------------------------------------------------------
do
    local book = newBook()                       -- members Bob and Alice
    local DAY = 24 * 3600
    local function mk(event, closes)
        return assert(Bookie.AddMarket(book, { sport = "NFL", event = event, type = "moneyline", closesAt = closes,
            selections = { { label = "A", odds = -150 }, { label = "B", odds = 130 } } }, NOW))
    end
    local function bet(who, m, ref)
        return assert(Bookie.PlaceBet(book, who, { marketId = m.id, selectionId = 1, stake = G, odds = -150, ref = ref }, NOW))
    end
    local function events(list)
        local names = {}
        for _, m in ipairs(list) do names[#names + 1] = m.event end
        table.sort(names)
        return table.concat(names, ",")
    end
    local function snapEvents(who, now) return events(Bookie.Snapshot(book, who, now).markets) end

    local open1       = mk("open", NOW + 3600)           -- bettable until NOW + 3600
    local lockedEarly = mk("locked-early", NOW + 3600)   -- the bookie locks it; the game has not started
    local settledBob  = mk("settled-bob", NOW + 3600)    -- Bob bets, then it is settled
    local settledNone = mk("settled-nobody", NOW + 3600)
    local voidNone    = mk("void-nobody", NOW + 3600)
    local started     = mk("started", NOW + 100)         -- stays "open" in the book, but the game starts at NOW + 100
    local startedBob  = mk("started-bob", NOW + 100)     -- same, and Bob bet on it before it started
    bet("Bob", settledBob, "b1"); bet("Bob", startedBob, "b2")
    bet("Alice", open1, "a1"); bet("Alice", lockedEarly, "a2")
    Bookie.Lock(book, lockedEarly.id)
    Bookie.Settle(book, settledBob.id, 1, NOW + 10)      -- Bob wins at -150: +66
    Bookie.Settle(book, settledNone.id, 2, NOW + 10)
    Bookie.VoidMarket(book, voidNone.id, NOW + 10)
    eq(started.status, "open", "test setup: the started market was never swept")

    local later = NOW + 200                               -- the games at NOW + 100 have started; the rest have not
    -- a bettor with no bets sees only what still takes bets
    eq(snapEvents("Stranger", later), "open", "no bets: only the open, not-yet-started market")
    -- locked, settled, void and started markets are hidden unless that bettor bet on them
    eq(snapEvents("Bob", later), "open,settled-bob,started-bob", "Bob: open + the two markets his bets refer to")
    eq(snapEvents("Alice", later), "locked-early,open", "Alice: her bets' markets (one is locked) + open")
    local sb = Bookie.Snapshot(book, "Bob", later)
    eq(#sb.bets, 2, "Bob's bets are all there")
    eq(sb.bets[1].marketId, settledBob.id, "bets sorted by id")
    eq(sb.balance, 66, "balance included")
    eq(sb.rev, book.rev, "rev included")
    -- never anyone else's bets
    for _, b in ipairs(Bookie.Snapshot(book, "Alice", later).bets) do eq(b.bettor, "Alice", "only Alice's bets") end
    -- hidden for everyone who did not bet, whatever the market's stored status is
    local function shown(who, now, name) return ("," .. snapEvents(who, now) .. ","):find("," .. name .. ",", 1, true) ~= nil end
    for _, hidden in ipairs({ "locked-early", "settled-nobody", "void-nobody", "started" }) do
        check(not shown("Bob", later, hidden), "Bob is not shown " .. hidden)
    end
    check(shown("Bob", later, "started-bob"), "...but is shown started-bob, which his bet refers to")
    check(not shown("Stranger", later, "started"), "an unswept started market is not shown to a stranger")

    -- the clock, not the stored status, decides: bettable before closesAt, not at or after it
    eq(snapEvents("Stranger", NOW + 3599), "open", "one second before closesAt: still presented")
    eq(snapEvents("Stranger", NOW + 3600), "", "at closesAt: no longer presented to someone who did not bet")
    eq(snapEvents("Alice", NOW + 3600), "locked-early,open", "...but Alice still has it (her bet)")
    eq(snapEvents("Bob", NOW + 3600), "settled-bob,started-bob", "...and Bob's list is just his bets' markets")
    -- no time window: a market a bettor bet on stays, however old
    -- a year later: his settled bet has aged out of the 14-day window, but his bet on started-bob is still open
    eq(snapEvents("Bob", NOW + 365 * DAY), "started-bob", "a year later Bob sees only the market of his still-open bet")
    eq(snapEvents("Stranger", NOW + 365 * DAY), "", "...and a stranger sees nothing")

    for i = 1, 25 do Bookie.RecordPayment(book, "Bob", "in", i, nil, NOW + i) end
    eq(#Bookie.Snapshot(book, "Bob", NOW + 1).payments, 20, "payments capped at 20")
    local u = Bookie.Snapshot(book, "Unknown", NOW)
    check(#u.bets == 0 and u.balance == 0, "unknown player: empty bets, zero balance")
    eq(events(u.markets), "open,started,started-bob", "unknown player sees only what takes bets at NOW (the games at NOW + 100 have not started yet)")
end

------------------------------------------------------------------------------------------
-- SYNC history cap (SPEC §5): open bets always; settled/void bets for 14 days; the markets those
-- bets refer to. The balance is absolute, so the cap never changes it.
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local DAY = 24 * 3600
    local WINDOW = 14 * DAY
    local NOWS = NOW + 100 * DAY                       -- "now" for every snapshot below
    local function mk(event)
        return assert(Bookie.AddMarket(book, { sport = "NFL", event = event, type = "moneyline", closesAt = NOW + 3600,
            selections = { { label = "A", odds = -150 }, { label = "B", odds = 130 } } }, NOW))
    end
    local function bet(m, sel, ref)
        return assert(Bookie.PlaceBet(book, "Bob", { marketId = m.id, selectionId = sel, stake = G,
            odds = sel == 1 and -150 or 130, ref = ref }, NOW))
    end
    local function ids(list, key)
        local out = {}
        for _, x in ipairs(list) do out[#out + 1] = x[key] end
        return table.concat(out, ",")
    end
    local function names(list)
        local out = {}
        for _, m in ipairs(list) do out[#out + 1] = m.event end
        table.sort(out)
        return table.concat(out, ",")
    end

    -- one bet per market, settled at different ages (win = selection 1 wins, loss = selection 2 wins)
    local old15  = mk("15d");      local b15 = bet(old15, 1, "r15")          -- won  +66, settled 15 days ago
    local old14p = mk("14d+1s");   local b14p = bet(old14p, 1, "r14p")       -- lost -100, settled 14 days and 1s ago
    local old14  = mk("14d");      local b14 = bet(old14, 1, "r14")          -- won  +66, settled exactly 14 days ago
    local old13  = mk("13d");      local b13 = bet(old13, 1, "r13")          -- lost -100, settled 13 days ago
    local voided = mk("void-13d"); local bv = bet(voided, 1, "rv")           -- void, 13 days ago
    local voidOld = mk("void-15d"); local bvo = bet(voidOld, 1, "rvo")       -- void, 15 days ago
    local stale  = mk("stale-open"); local bs = bet(stale, 1, "rs")          -- still open: its market never settled
    Bookie.Settle(book, old15.id, 1, NOWS - 15 * DAY)
    Bookie.Settle(book, old14p.id, 2, NOWS - WINDOW - 1)
    Bookie.Settle(book, old14.id, 1, NOWS - WINDOW)
    Bookie.Settle(book, old13.id, 2, NOWS - 13 * DAY)
    Bookie.VoidMarket(book, voided.id, NOWS - 13 * DAY)
    Bookie.VoidMarket(book, voidOld.id, NOWS - 15 * DAY)
    eq(bs.status, "accepted", "test setup: the stale bet is still open")
    eq(Bookie.Balance(book, "Bob"), 66 - 100 + 66 - 100, "test setup: balance after four settled bets")

    local s = Bookie.Snapshot(book, "Bob", NOWS)
    eq(ids(s.bets, "id"), table.concat({ b14.id, b13.id, bv.id, bs.id }, ","), "kept: exactly 14d, 13d, void 13d and the open bet; dropped: 15d, 14d+1s, void 15d")
    eq(names(s.markets), "13d,14d,stale-open,void-13d", "the markets of the kept bets, and no others")
    eq(s.balance, 66 - 100 + 66 - 100, "the balance still counts the dropped bets")
    eq(Bookie.Balance(book, "Bob"), s.balance, "...and matches the ledger")

    -- the boundary is the second: one second later the 14-day bet falls out, one second earlier everything is as above
    eq(ids(Bookie.Snapshot(book, "Bob", NOWS - 1).bets, "id"), table.concat({ b14p.id, b14.id, b13.id, bv.id, bs.id }, ","), "one second earlier the 14d+1s bet is exactly on the boundary and kept")
    eq(ids(Bookie.Snapshot(book, "Bob", NOWS + 1).bets, "id"), table.concat({ b13.id, bv.id, bs.id }, ","), "one second later the 14d bet is dropped too")
    eq(Bookie.Snapshot(book, "Bob", NOWS + 1).balance, 66 - 100 + 66 - 100, "balance unchanged")

    -- an open bet is never aged out, however old
    local far = Bookie.Snapshot(book, "Bob", NOWS + 3650 * DAY)
    eq(ids(far.bets, "id"), tostring(bs.id), "ten years on only the open bet remains")
    eq(names(far.markets), "stale-open", "...with its market")

    -- a market shared by a kept bet and a dropped bet stays (it is referenced by a kept bet)
    local shared = mk("shared")
    local sOld = bet(shared, 1, "rsh1")
    local sNew = bet(shared, 2, "rsh2")
    Bookie.Settle(book, shared.id, 1, NOWS - 20 * DAY)
    Bookie.RecordPayment(book, "Bob", "in", 5, nil, NOWS)
    -- both bets share the settle time, so both are dropped together; the market goes with them
    local s2 = Bookie.Snapshot(book, "Bob", NOWS)
    check(not names(s2.markets):find("shared", 1, true), "a market whose bets are all dropped is dropped")
    -- re-settle recently (a correction): the bets are fresh again, so they and the market come back
    Bookie.Settle(book, shared.id, 2, NOWS - 1 * DAY)
    local s3 = Bookie.Snapshot(book, "Bob", NOWS)
    check(names(s3.markets):find("shared", 1, true), "a corrected settlement brings the bets and the market back")
    check(ids(s3.bets, "id"):find(tostring(sOld.id)) and ids(s3.bets, "id"):find(tostring(sNew.id)), "...with both bets")

    -- other bettors are unaffected, and a stranger sees no history at all
    eq(#Bookie.Snapshot(book, "Alice", NOWS).bets, 0, "Alice has no bets")
    eq(#Bookie.Snapshot(book, "Unknown", NOWS).bets, 0, "unknown player: no bets")
end

------------------------------------------------------------------------------------------
-- strict close (SPEC §5): closesAt is the game's start. Once it has passed nothing reopens or
-- extends the market and nothing is edited; only Settle and Void remain.
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local m = ml(book, NOW + 100)
    local function bet(now, ref)
        return Bookie.PlaceBet(book, "Bob", { marketId = m.id, selectionId = 1, stake = G, odds = -150, ref = ref }, now)
    end
    local function refused(fn, want, label)
        local r, reason = fn()
        check(r == nil and reason == want, label .. ": " .. tostring(reason))
    end

    -- betting
    check(bet(NOW + 99, "a"), "a bet one second before closesAt is accepted")
    local b, reason = bet(NOW + 100, "b")
    check(b == nil and reason == "market_closed", "a bet exactly at closesAt is rejected: " .. tostring(reason))
    b, reason = bet(NOW + 101, "c")
    check(b == nil and reason == "market_closed", "a bet one second after closesAt is rejected: " .. tostring(reason))
    eq(m.status, "open", "the stored status is still open (Sweep has not run): the clock decides")

    -- the helpers agree
    check(Bookie.IsBettable(m, NOW + 99) and not Bookie.IsBettable(m, NOW + 100), "IsBettable follows the clock")
    check(not Bookie.HasStarted(m, NOW + 99) and Bookie.HasStarted(m, NOW + 100), "HasStarted follows the clock")
    eq(Bookie.EffectiveStatus(m, NOW + 99), "open", "effective status before the start")
    eq(Bookie.EffectiveStatus(m, NOW + 100), "locked", "an unswept open market past closesAt reads as locked")
    Bookie.Lock(book, m.id)
    check(not Bookie.IsBettable(m, NOW + 50), "a market locked early is not bettable")
    eq(Bookie.EffectiveStatus(m, NOW + 50), "locked", "locked early")
    Bookie.Unlock(book, m.id, NOW + 50)
    check(Bookie.IsBettable(m, NOW + 50), "...and can be unlocked before the start")

    -- no edits and no extending once the game has started
    local started = NOW + 100
    refused(function() return Bookie.EditMarket(book, m.id, { closesAt = NOW + 9999 }, started) end, "market_closed", "extending the close time after the start")
    refused(function() return Bookie.EditMarket(book, m.id, { closesAt = NOW + 9999 }, started + 1) end, "market_closed", "...one second later too")
    refused(function() return Bookie.EditMarket(book, m.id, { odds = { [1] = -200 } }, started) end, "market_closed", "changing odds after the start")
    refused(function() return Bookie.EditMarket(book, m.id, { closesAt = NOW + 50 }, started) end, "market_closed", "moving the close time earlier after the start")
    refused(function() return Bookie.EditMarket(book, m.id, { odds = { [1] = 5 } }, started) end, "market_closed", "even an invalid edit reports the start first")
    eq(m.closesAt, NOW + 100, "the close time is unchanged")
    eq(m.selections[1].odds, -150, "the odds are unchanged")
    refused(function() return Bookie.EditMarket(book, m.id, { odds = { [1] = -200 } }) end, "bad_time", "EditMarket requires the time")

    -- no reopening, even after the bookie locked it early or Sweep ran
    Bookie.Lock(book, m.id)
    refused(function() return Bookie.Unlock(book, m.id, started) end, "market_closed", "unlock after the start (locked early)")
    local swept = Bookie.Sweep(book, started)
    check(#swept == 0 and m.status == "locked", "an already locked market is not swept twice")
    refused(function() return Bookie.Unlock(book, m.id, started + 1000) end, "market_closed", "unlock long after the start")
    check(select(2, bet(started + 1000, "d")) == "market_closed", "still no bets")

    -- a market still stored as "open" (never locked, never swept) is refused too, not a silent no-op
    local m3 = ml(book, NOW + 100)
    refused(function() return Bookie.Unlock(book, m3.id, started) end, "market_closed", "unlock of a started market stored as open")
    check(Bookie.Unlock(book, m3.id, NOW + 99), "...but before the start an unlock of an open market is a harmless no-op")

    -- before the start the bookie keeps its tools
    local m2 = ml(book, NOW + 100)
    check(Bookie.EditMarket(book, m2.id, { closesAt = NOW + 200 }, NOW + 50), "extending before the start is allowed")
    refused(function() return Bookie.EditMarket(book, m2.id, { closesAt = NOW + 10 }, NOW + 50) end, "bad_close_time", "a new close time must be in the future")
    refused(function() return Bookie.EditMarket(book, m2.id, { closesAt = "soon" }, NOW + 50) end, "bad_close_time", "...and a number")
    check(Bookie.EditMarket(book, m2.id, { odds = { [1] = -170 } }, NOW + 150), "odds can still change before the (extended) start")
    check(Bookie.PlaceBet(book, "Bob", { marketId = m2.id, selectionId = 1, stake = G, odds = -170, ref = "e" }, NOW + 150), "betting works until the extended start")
    check(select(2, Bookie.PlaceBet(book, "Bob", { marketId = m2.id, selectionId = 1, stake = G, odds = -170, ref = "f" }, NOW + 200)) == "market_closed", "...and stops at it")

    -- only Settle and Void remain after the start
    check(Bookie.Settle(book, m.id, 1, started + 5), "Settle works on a started market")
    check(Bookie.Settle(book, m.id, "push", started + 6), "...and re-settling")
    check(Bookie.VoidMarket(book, m.id, started + 7), "...and Void")
    -- a finished market can't be edited or unlocked either
    refused(function() return Bookie.EditMarket(book, m.id, { odds = { [1] = -200 } }, NOW) end, "market_final", "editing a void market")
end

------------------------------------------------------------------------------------------
-- stake rule (SPEC §3): enforced by the bookie through Odds.StakeCheck, so a modified client
-- cannot bypass the bet slip. The constants live in Odds.lua; nothing here depends on their values
-- except the explicit examples (20s 10c, 10c, 1g 1s rejected; 20s, 50s, 1g accepted).
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local m = ml(book)
    local n = 0
    local function place(stake)
        n = n + 1
        return Bookie.PlaceBet(book, "Bob", { marketId = m.id, selectionId = 1, stake = stake, odds = -150, ref = "stake" .. n }, NOW)
    end
    local function rejected(stake, label)
        local bet, reason = place(stake)
        check(bet == nil and reason == "bad_stake", label .. ": " .. tostring(reason))
    end
    local SILVER, GOLD = 100, 10000
    check(place(20 * SILVER), "20s accepted")
    check(place(50 * SILVER), "50s accepted")
    check(place(GOLD), "1g accepted")
    check(place(1 * SILVER), "1s accepted")
    rejected(20 * SILVER + 10, "20s 10c is not whole silver")
    rejected(10, "10c is not whole silver")
    rejected(GOLD + SILVER, "1g 1s is over the max")
    rejected(ns.Odds.MAX_STAKE + ns.Odds.STAKE_STEP, "one step over MAX_STAKE")
    rejected(ns.Odds.MAX_STAKE - 1, "one copper under MAX_STAKE is not a whole step")
    check(place(ns.Odds.MAX_STAKE), "exactly MAX_STAKE accepted")
    rejected(0, "zero")
    rejected(-SILVER, "negative")
    rejected(150.5, "fractional")
    rejected("20s", "a string")
    rejected(nil, "missing")
    -- a rejected stake books nothing and consumes no id
    local count = 0
    for _ in pairs(book.bets) do count = count + 1 end
    eq(count, 5, "only the accepted bets were booked")
    -- the credit limit still applies on top of the stake rule
    Bookie.SetCreditLimit(book, "Alice", 30 * SILVER)
    local bet, reason, extra = Bookie.PlaceBet(book, "Alice", { marketId = m.id, selectionId = 1, stake = 50 * SILVER, odds = -150 }, NOW)
    check(bet == nil and reason == "credit_limit" and extra == 30 * SILVER, "valid stake over the credit limit: " .. tostring(reason))
    -- the stake check happens before the credit check: an invalid stake is bad_stake, not credit_limit
    bet, reason = Bookie.PlaceBet(book, "Alice", { marketId = m.id, selectionId = 1, stake = 50 * SILVER + 1, odds = -150 }, NOW)
    check(bet == nil and reason == "bad_stake", "invalid stake reports bad_stake: " .. tostring(reason))
end

if fails == 0 then print("bookie: all tests passed") else os.exit(1) end
