-- Run from repo root: lua5.1 tests/test_bookie_views.lua
-- Pure helpers behind the Ledger and Bets tabs.
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

local NOW, G = 1000, 100   -- G = 1 silver in copper; the max stake is 1g = 100 * G
local book = Model.CreateBook(Model.NewDB(), "NFL", "Steve", NOW)
for _, n in ipairs({ "Bob", "Alice", "Carol" }) do Bookie.RequestJoin(book, n, NOW); Bookie.Approve(book, n, NOW) end
Bookie.RequestJoin(book, "Pending", NOW)   -- never approved: must not appear in the ledger
local function market(event)
    return assert(Bookie.AddMarket(book, { sport = "NFL", event = event, type = "moneyline", closesAt = NOW + 100,
        selections = { { label = "A", odds = 100 }, { label = "B", odds = 100 } } }, NOW))
end
local m1, m2 = market("one"), market("two")
local function bet(who, m, sel, stake)
    return assert(Bookie.PlaceBet(book, who, { marketId = m.id, selectionId = sel, stake = stake, odds = 100 }, NOW))
end
bet("Bob", m1, 1, 10 * G); bet("Alice", m1, 2, 5 * G); bet("Bob", m2, 1, 2 * G); bet("Carol", m2, 2, 1 * G)
Bookie.Settle(book, m1.id, 1, NOW + 1)      -- Bob +10g, Alice -5g

-- amounts
eq(Bookie.ParseAmount("250g", ns.Odds.ParseMoney), 2500000, "amount")
check(Bookie.ParseAmount("", ns.Odds.ParseMoney) == false, "blank amount is an error")
check(Bookie.ParseAmount("0", ns.Odds.ParseMoney) == false, "zero amount is an error")
check(select(2, Bookie.ParseAmount("x", ns.Odds.ParseMoney)):find("Enter an amount"), "junk amount message")

-- ledger rows: Bob +10g (book owes), Alice -5g (owes book), Carol 0 but has an open bet
local rows = Bookie.LedgerRows(book)
eq(#rows, 3, "pending member excluded: " .. #rows)
eq(rows[1].name, "Bob", "biggest balance first")
eq(rows[1].balance, 10 * G, "Bob balance")
eq(rows[1].openRisk, 2 * G, "Bob open risk")
eq(rows[2].name, "Alice", "then Alice")
eq(rows[2].balance, -5 * G, "Alice balance")
eq(rows[3].name, "Carol", "Carol listed for her open bet")
eq(rows[3].balance, 0, "Carol balance")
Bookie.Remove(book, "Carol")
eq(#Bookie.LedgerRows(book), 3, "removed member with an open bet stays listed")
Bookie.Settle(book, m2.id, "push", NOW + 2)
eq(#Bookie.LedgerRows(book), 2, "removed member with nothing outstanding drops off")
Bookie.RecordPayment(book, "Carol", "in", 1, "tip", NOW + 3)
eq(#Bookie.LedgerRows(book), 3, "payment history keeps a player listed")
eq(Bookie.LedgerRows(book)[3].payments, 1, "payment count")

-- Carol paid 1c with nothing owed, so the book owes her 1c back.
eq(Bookie.Balance(book, "Carol"), 1, "Carol balance after paying 1c up front")
local t = Bookie.LedgerTotals(book)
eq(t.owedByBook, 10 * G + 1, "book owes Bob 10g and Carol 1c")
eq(t.owedToBook, 5 * G, "Alice owes the book 5g")
eq(t.net, 5 * G - (10 * G + 1), "net = owed to book - owed by book")

-- bet listing and filters
local all = Bookie.ListBets(book)
eq(#all, 4, "all bets")
eq(all[1].id, 4, "newest first")
eq(#Bookie.ListBets(book, { bettor = "Bob" }), 2, "by bettor")
eq(#Bookie.ListBets(book, { marketId = m1.id }), 2, "by market")
eq(#Bookie.ListBets(book, { status = "won" }), 1, "by status won")
eq(#Bookie.ListBets(book, { status = "push" }), 2, "by status push")
eq(#Bookie.ListBets(book, { status = "accepted" }), 0, "no open bets left")
eq(#Bookie.ListBets(book, { bettor = "Bob", marketId = m2.id, status = "push" }), 1, "combined filter")
eq(#Bookie.ListBets(book, { bettor = "Nobody" }), 0, "no match")

local c = Bookie.BetFilterChoices(book)
eq(table.concat(c.bettors, ","), "Alice,Bob,Carol", "bettor choices sorted")
eq(table.concat(c.markets, ","), m1.id .. "," .. m2.id, "market choices ascending")

-- cycling
local L = { "a", "b" }
eq(Bookie.CycleFilter(L, nil), "a", "cycle from nil")
eq(Bookie.CycleFilter(L, "a"), "b", "cycle a->b")
eq(Bookie.CycleFilter(L, "b"), nil, "cycle wraps to nil")
eq(Bookie.CycleFilter(L, "gone"), nil, "unknown value resets")
eq(Bookie.CycleFilter({}, nil), nil, "empty list")

if fails == 0 then print("bookie_views: all tests passed") else os.exit(1) end
