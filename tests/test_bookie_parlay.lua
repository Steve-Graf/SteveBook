-- Parlays on the bookie side (SPEC §3a): placement rules, grading as legs settle, corrections,
-- voids, SYNC contents, the BET_PLACE/BET_REJECT message layer, open-stake totals.
-- Run from repo root: luajit tests/test_bookie_parlay.lua   (or lua5.1)
local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)
local Model = assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)
local Bookie = assert(loadfile("SteveBook/Bookie.lua"))("SteveBook", ns)
local Odds, Protocol = ns.Odds, ns.Protocol

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; print("FAIL: " .. label) end
end
local function eq(got, want, label)
    check(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

local NOW = 1000
local S = 100                        -- one silver in copper; the max stake is 100 * S

local function newBook()
    local book = Model.CreateBook(Model.NewDB(), "NBA", "Steve", NOW)
    for _, name in ipairs({ "Bob", "Alice" }) do
        Bookie.RequestJoin(book, name, NOW)
        Bookie.Approve(book, name, NOW)
    end
    return book
end

local function market(book, kind, event, closes, o1, o2, line)
    local labels = { moneyline = { "H", "A" }, spread = { "H", "A" }, total = { "Over", "Under" } }
    local l = labels[kind]
    return assert(Bookie.AddMarket(book, {
        sport = "NBA", event = event, type = kind, line = line, closesAt = closes or NOW + 3600,
        selections = { { label = l[1], odds = o1 or -110 }, { label = l[2], odds = o2 or -110 } },
    }, NOW))
end

local function leg(m, sel) return { marketId = m.id, selectionId = sel, odds = m.selections[sel].odds } end
local function parlay(book, who, legs, stake, ref)
    return Bookie.PlaceBet(book, who, { legs = legs, stake = stake or 10 * S, ref = ref }, NOW)
end

------------------------------------------------------------------------------------------
-- placement
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "moneyline", "CCC @ DDD", NOW + 3600, -200, 170)
    local c = market(book, "moneyline", "EEE @ FFF", NOW + 3600, 120, -140)

    local bet, reason = parlay(book, "Bob", { leg(a, 1), leg(b, 1) }, 20 * S, "p1")
    check(bet and bet.status == "accepted", "a two-leg parlay is accepted: " .. tostring(reason))
    check(bet.legs and #bet.legs == 2 and bet.marketId == nil and bet.selectionId == nil, "a parlay has legs and no marketId/selectionId")
    eq(bet.stake, 20 * S, "stake kept")
    eq(bet.odds, Odds.ParlayOdds({ 150, -200 }), "Bet.odds is the combined American odds")
    check(bet.legs[1].status == "pending" and bet.legs[2].status == "pending", "legs start pending")
    check(bet.legs[1].marketId == a.id and bet.legs[1].selectionId == 1 and bet.legs[1].odds == 150, "leg 1 fields")
    eq(bet.ref, "p1", "ref stored")
    eq(book.bets[bet.id], bet, "booked")

    -- idempotent on ref: same bet back, third value true, nothing new booked
    local again, r2, repeated = parlay(book, "Bob", { leg(a, 1), leg(b, 1) }, 20 * S, "p1")
    check(again == bet and r2 == nil and repeated == true, "a repeated ref returns the original parlay")
    local n = 0; for _ in pairs(book.bets) do n = n + 1 end
    eq(n, 1, "no duplicate parlay booked")

    -- leg odds are locked at acceptance: a later line change does not move them
    Bookie.EditMarket(book, a.id, { odds = { [1] = 200 } }, NOW)
    eq(bet.legs[1].odds, 150, "later line change does not move a leg's odds")

    -- three and eight legs are fine; one and nine are not
    local legs8 = {}
    for i = 1, 8 do legs8[i] = leg(market(book, "moneyline", "T" .. i .. " @ U" .. i), 1) end
    check(parlay(book, "Alice", legs8, 10 * S, "p8"), "eight legs accepted")
    local legs9 = {}
    for i = 1, 9 do legs9[i] = leg(market(book, "moneyline", "V" .. i .. " @ W" .. i), 1) end
    local x, why = parlay(book, "Alice", legs9, 10 * S, "p9")
    check(x == nil and why == "bad_request", "nine legs: bad_request (" .. tostring(why) .. ")")
    x, why = parlay(book, "Alice", { leg(c, 1) }, 10 * S, "p0")
    check(x == nil and why == "bad_request", "one leg: bad_request (" .. tostring(why) .. ")")
    x, why = parlay(book, "Alice", {}, 10 * S, "pe")
    check(x == nil and why == "bad_request", "no legs: bad_request (" .. tostring(why) .. ")")
    x, why = Bookie.PlaceBet(book, "Alice", { legs = "x", stake = 10 * S, ref = "px" }, NOW)
    check(x == nil and why == "bad_request", "legs that is not a table: bad_request")
    x, why = Bookie.PlaceBet(book, "Alice", { legs = { leg(a, 1), leg(b, 1) }, marketId = a.id, stake = 10 * S, odds = 150, ref = "pm" }, NOW)
    check(x == nil and why == "bad_request", "legs plus a single bet's fields: bad_request")
    x, why = Bookie.PlaceBet(book, "Mallory", { legs = { leg(a, 1), leg(b, 1) }, stake = 10 * S }, NOW)
    check(x == nil and why == "not_member", "a non-member cannot place a parlay")
end

-- each leg is checked in order and reports its index ---------------------------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "moneyline", "CCC @ DDD", NOW + 3600, -200, 170)
    local c = market(book, "moneyline", "EEE @ FFF", NOW + 3600, 120, -140)
    local function rej(label, want, wantExtra, wantLeg, legs, stake)
        local bet, reason, extra, legIndex = parlay(book, "Bob", legs, stake)
        check(bet == nil and reason == want, label .. ": reason " .. tostring(reason))
        if wantExtra ~= nil then eq(extra, wantExtra, label .. ": extra") end
        eq(legIndex, wantLeg, label .. ": legIndex")
    end

    -- the odds of leg 2 moved since the bettor saw them
    local stale = leg(b, 1); stale.odds = -210
    rej("stale odds on leg 2", "odds_changed", -200, 2, { leg(a, 1), stale })
    local stale3 = leg(c, 2); stale3.odds = -150
    rej("stale odds on leg 3", "odds_changed", -140, 3, { leg(a, 1), leg(b, 1), stale3 })
    -- the first failing leg wins, even when a later leg would also fail
    rej("first bad leg reported", "odds_changed", -200, 1, { { marketId = b.id, selectionId = 1, odds = 999 }, { marketId = 999, selectionId = 1, odds = 100 } })

    rej("unknown market", "no_market", nil, 2, { leg(a, 1), { marketId = 999, selectionId = 1, odds = -110 } })
    rej("unknown selection", "bad_selection", nil, 2, { leg(a, 1), { marketId = b.id, selectionId = 3, odds = -200 } })
    local lg = leg(b, 1); lg.selectionId = nil
    rej("leg without a selection", "bad_selection", nil, 2, { leg(a, 1), lg })
    rej("a leg that is not a table", "bad_request", nil, 2, { leg(a, 1), "junk" })

    -- a locked market, and one whose game has started (stored status still "open")
    Bookie.Lock(book, b.id)
    rej("locked market", "market_closed", nil, 2, { leg(a, 1), leg(b, 1) })
    Bookie.Unlock(book, b.id, NOW)
    local early = market(book, "moneyline", "GGG @ HHH", NOW + 10, -110, -110)
    local bet, reason, _, li = Bookie.PlaceBet(book, "Bob", { legs = { leg(c, 1), leg(early, 1) }, stake = 10 * S, ref = "late" }, NOW + 10)
    check(bet == nil and reason == "market_closed" and li == 2, "started game (status still open): market_closed on leg 2: " .. tostring(reason))
    eq(early.status, "open", "(the stored status had not caught up)")

    -- the stake rule runs after the legs
    rej("stake not whole silver", "bad_stake", nil, nil, { leg(a, 1), leg(b, 1) }, 10 * S + 1)
    rej("stake over the maximum", "bad_stake", nil, nil, { leg(a, 1), leg(b, 1) }, Odds.MAX_STAKE + S)
    rej("zero stake", "bad_stake", nil, nil, { leg(a, 1), leg(b, 1) }, 0)
    -- a bad leg beats a bad stake
    rej("leg problems come before stake problems", "no_market", nil, 1, { { marketId = 999, selectionId = 1, odds = 100 }, leg(b, 1) }, 3)

    local n = 0; for _ in pairs(book.bets) do n = n + 1 end
    eq(n, 0, "rejected parlays book nothing")
end

-- which legs may share a parlay (the user's rule: one side bet + one total per game) --------------
do
    local book = newBook()
    local closes = NOW + 7200
    local mlA = market(book, "moneyline", "PHI @ DAL", closes, 130, -150)
    local spA = market(book, "spread", "PHI @ DAL", closes, -110, -110, 3.5)
    local sp2 = market(book, "spread", "PHI @ DAL", closes, -105, -115, 6.5)
    local toA = market(book, "total", "PHI @ DAL", closes, -110, -110, 47.5)
    local to2 = market(book, "total", "PHI @ DAL", closes, -115, -105, 51.5)
    local mlB = market(book, "moneyline", "NYG @ WAS", closes, -120, 100)
    local spB = market(book, "spread", "NYG @ WAS", closes, -110, -110, -2.5)
    local otherTime = market(book, "moneyline", "PHI @ DAL", closes + 600, 125, -145)   -- same teams, a different game

    local function ok(label, legs)
        local bet, reason = parlay(book, "Bob", legs, S, label)
        check(bet, label .. ": accepted (" .. tostring(reason) .. ")")
    end
    local function bad(label, kind, wantLeg, legs)
        local bet, reason, extra, li = parlay(book, "Bob", legs, S, label)
        check(bet == nil and reason == "parlay_conflict", label .. ": parlay_conflict (" .. tostring(reason) .. ")")
        eq(extra, kind, label .. ": which conflict")
        eq(li, wantLeg, label .. ": legIndex is the later leg of the pair")
    end

    ok("ML + total, same game", { leg(mlA, 1), leg(toA, 1) })
    ok("spread + total, same game", { leg(spA, 2), leg(toA, 2) })
    ok("total + ML, other order", { leg(toA, 1), leg(mlA, 2) })
    ok("different games never conflict", { leg(mlA, 1), leg(mlB, 1) })
    ok("a side bet in each of two games plus a total", { leg(spA, 1), leg(spB, 2), leg(toA, 2) })
    ok("one side + one total per game, two games", { leg(mlA, 1), leg(toA, 1), leg(spB, 1) })
    ok("same teams at a different time is a different game", { leg(mlA, 1), leg(otherTime, 1) })

    bad("ML + spread", "same_game_conflict", 2, { leg(mlA, 1), leg(spA, 1) })
    bad("ML + spread, later in the slip", "same_game_conflict", 3, { leg(mlB, 1), leg(mlA, 1), leg(spA, 2) })
    bad("two spreads", "same_game_conflict", 2, { leg(spA, 1), leg(sp2, 1) })
    bad("over + under of two total lines", "same_game_conflict", 2, { leg(toA, 1), leg(to2, 2) })
    bad("two totals, both over", "same_game_conflict", 2, { leg(toA, 1), leg(to2, 1) })
    bad("the same market twice, same side", "duplicate_market", 2, { leg(mlA, 1), leg(mlA, 1) })
    bad("the same market twice, both sides", "duplicate_market", 2, { leg(mlA, 1), leg(mlA, 2) })
    bad("a conflict in the middle of three", "same_game_conflict", 3, { leg(mlB, 1), leg(mlA, 1), leg(spA, 1) })
end

-- credit limit: the stake is the risk, and a parlay counts like any open bet ------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "moneyline", "CCC @ DDD", NOW + 3600, -200, 170)
    Bookie.SetCreditLimit(book, "Bob", 30 * S)
    local bet, reason, extra = parlay(book, "Bob", { leg(a, 1), leg(b, 1) }, 40 * S, "c1")
    check(bet == nil and reason == "credit_limit" and extra == 30 * S, "a parlay over the limit: credit_limit, 30s available (" .. tostring(reason) .. ")")
    check(parlay(book, "Bob", { leg(a, 1), leg(b, 1) }, 20 * S, "c2"), "a parlay within the limit is accepted")
    local _, openRisk = Bookie.Credit(book, "Bob")
    eq(openRisk, 20 * S, "the parlay's stake is in Bob's open risk once")
    bet, reason, extra = Bookie.PlaceBet(book, "Bob", { marketId = a.id, selectionId = 1, stake = 20 * S, odds = 150, ref = "s1" }, NOW)
    check(bet == nil and reason == "credit_limit" and extra == 10 * S, "a single after the parlay sees the parlay's stake used: " .. tostring(extra))
end

-- the line a bet was taken at is kept on the bet (a later line edit moves the market's, not the bet's) ---
do
    local book = newBook()
    local sp = market(book, "spread", "PHI @ DAL", NOW + 3600, -110, -110, -3.5)
    local to = market(book, "total", "PHI @ DAL", NOW + 3600, -110, -110, 47.5)
    local mlm = market(book, "moneyline", "PHI @ DAL", NOW + 3600, 130, -150)
    local function single(m, sel, ref)
        return assert(Bookie.PlaceBet(book, "Bob", { marketId = m.id, selectionId = sel, stake = S, odds = m.selections[sel].odds, ref = ref }, NOW))
    end
    local bs, bt, bm = single(sp, 2, "a"), single(to, 1, "b"), single(mlm, 1, "c")
    eq(bs.line, -3.5, "a spread bet records the market's line")
    eq(bt.line, 47.5, "a total bet records the line")
    eq(bm.line, nil, "a moneyline bet has no line")
    local par = assert(parlay(book, "Alice", { leg(sp, 1), leg(to, 2), leg(market(book, "moneyline", "AAA @ BBB"), 1) }, S, "p"))
    check(par.legs[1].line == -3.5 and par.legs[2].line == 47.5 and par.legs[3].line == nil, "parlay legs record their lines (none for a moneyline)")
    assert(Bookie.EditMarket(book, sp.id, { line = -5, odds = { [1] = -105 } }, NOW))
    assert(Bookie.EditMarket(book, to.id, { line = 49 }, NOW))
    check(bs.line == -3.5 and bt.line == 47.5 and par.legs[1].line == -3.5 and par.legs[2].line == 47.5, "moving the market's line does not move bets already taken")
    eq(bs.odds, -110, "...nor their odds")
    -- display helpers prefer the bet's own line
    eq(Bookie.SelectionText(sp, 2), "A +5", "with no line given the market's current line is used (spread side 2 is the opposite)")
    eq(Bookie.SelectionText(sp, 2, bs.line), "A +3.5", "with the bet's line it reads as it was taken")
    eq(Bookie.SelectionText(sp, 1, -3.5), "H -3.5", "side 1 with a given line")
    eq(Bookie.SelectionText(to, 1, bt.line), "Over 47.5", "a total with the bet's line")
    eq(Bookie.SelectionText(mlm, 1, nil), "H ML", "a moneyline")
    local rows = Bookie.LegRows(book, par)
    check(rows[1].pick == "H -3.5" and rows[2].pick == "Under 47.5" and rows[3].pick == "H ML", "LegRows use each leg's own line: " .. rows[1].pick .. " / " .. rows[2].pick)
    -- a SYNC carries the lines on the bets
    local snap = Bookie.Snapshot(book, "Alice", NOW)
    check(snap.bets[1].legs[1].line == -3.5, "the SYNC's parlay legs carry their line")
end

-- the line the bettor saw must still be the market's line (BET_PLACE `line`, per leg for parlays) ----------
do
    local book = newBook()
    local sp = market(book, "spread", "PHI @ DAL", NOW + 3600, -110, -110, -3.5)
    local to = market(book, "total", "PHI @ DAL", NOW + 3600, -110, -110, 47.5)
    local mlm = market(book, "moneyline", "PHI @ DAL", NOW + 3600, 130, -150)
    local other = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local function try(req)
        req.stake = req.stake or S
        return Bookie.PlaceBet(book, "Bob", req, NOW)
    end
    local function rejected(label, req, wantOdds, wantLine, wantLeg)
        local bet, reason, extra, legIndex, currentLine = try(req)
        check(bet == nil and reason == "odds_changed", label .. ": odds_changed (" .. tostring(reason) .. ")")
        eq(extra, wantOdds, label .. ": currentOdds")
        eq(currentLine, wantLine, label .. ": currentLine")
        eq(legIndex, wantLeg, label .. ": legIndex")
    end
    local nbets = function() local n = 0; for _ in pairs(book.bets) do n = n + 1 end; return n end

    -- single bets
    local b = try({ marketId = sp.id, selectionId = 1, odds = -110, line = -3.5, ref = "s1" })
    check(b and b.line == -3.5, "the line the bettor saw matches: accepted, line recorded")
    b = try({ marketId = to.id, selectionId = 2, odds = -110, line = 47.5, ref = "s2" })
    check(b and b.line == 47.5, "a total with the right line: accepted")
    b = try({ marketId = sp.id, selectionId = 1, odds = -110, ref = "s3" })
    check(b and b.line == -3.5, "no line sent (an older client): accepted, the market's line is recorded")
    b = try({ marketId = mlm.id, selectionId = 1, odds = 130, line = -3.5, ref = "s4" })
    check(b and b.line == nil, "a line sent for a moneyline is ignored (it has none)")
    local before = nbets()

    assert(Bookie.EditMarket(book, sp.id, { line = -4.5 }, NOW))            -- the bookie moved the line, prices unchanged
    rejected("spread line moved, odds the same", { marketId = sp.id, selectionId = 1, odds = -110, line = -3.5, ref = "s5" }, -110, -4.5)
    rejected("same, second side", { marketId = sp.id, selectionId = 2, odds = -110, line = 3.5, ref = "s6" }, -110, -4.5)
    eq(nbets(), before, "a line mismatch books nothing")
    b = try({ marketId = sp.id, selectionId = 1, odds = -110, line = -4.5, ref = "s7" })
    check(b and b.line == -4.5, "the re-confirmed bet (the new line) is accepted at the new line")
    b = try({ marketId = sp.id, selectionId = 1, odds = -110, ref = "s8" })
    check(b and b.line == -4.5, "a request with no line still goes through at the current line")

    assert(Bookie.EditMarket(book, sp.id, { line = -5, odds = { [1] = -125 } }, NOW))   -- both moved
    rejected("line and odds both moved", { marketId = sp.id, selectionId = 1, odds = -110, line = -4.5, ref = "s9" }, -125, -5)
    rejected("only odds moved (line current)", { marketId = sp.id, selectionId = 1, odds = -110, line = -5, ref = "s10" }, -125, -5)
    rejected("odds changed on a moneyline: no currentLine", { marketId = mlm.id, selectionId = 1, odds = 999, ref = "s11" }, 130, nil)
    assert(Bookie.EditMarket(book, to.id, { line = 49 }, NOW))
    rejected("total line moved", { marketId = to.id, selectionId = 1, odds = -110, line = 47.5, ref = "s12" }, -110, 49)
    -- precedence: the stake rule is checked before the odds/line terms, as before
    local bet, reason = try({ marketId = sp.id, selectionId = 1, odds = -110, line = -9, stake = S + 1, ref = "s13" })
    check(bet == nil and reason == "bad_stake", "an invalid stake is reported before a changed line")
    -- a half-point line is compared exactly
    assert(Bookie.EditMarket(book, to.id, { line = 49.5 }, NOW))
    rejected("49 vs 49.5", { marketId = to.id, selectionId = 1, odds = -110, line = 49, ref = "s14" }, -110, 49.5)
    check(try({ marketId = to.id, selectionId = 1, odds = -110, line = 49.5, ref = "s15" }), "49.5 matches 49.5")

    -- a retried ref is still answered with the original bet even if the line moved since
    local first = try({ marketId = to.id, selectionId = 2, odds = -110, line = 49.5, ref = "retry" })
    assert(Bookie.EditMarket(book, to.id, { line = 50.5 }, NOW))
    local again, r, repeated = try({ marketId = to.id, selectionId = 2, odds = -110, line = 49.5, ref = "retry" })
    check(again == first and repeated == true, "a retried ref is re-acked even after the line moved")

    -- parlay legs carry their own line
    local function pleg(m, sel, line)
        local l = { marketId = m.id, selectionId = sel, odds = m.selections[sel].odds }
        l.line = line
        return l
    end
    local p = try({ legs = { pleg(sp, 1, -5), pleg(to, 2, 50.5), pleg(other, 1) }, ref = "pl1" })
    check(p and p.legs[1].line == -5 and p.legs[2].line == 50.5 and p.legs[3].line == nil, "a parlay with every line current: accepted, legs record them")
    local n1 = nbets()
    rejected("leg 2 line moved", { legs = { pleg(sp, 1, -5), pleg(to, 1, 49.5), pleg(other, 1) }, ref = "pl2" }, -110, 50.5, 2)
    rejected("leg 1 line moved", { legs = { pleg(sp, 1, -4), pleg(other, 1) }, ref = "pl3" }, -125, -5, 1)
    rejected("the first bad leg wins (odds on leg 1, line on leg 2)",
             { legs = { { marketId = other.id, selectionId = 1, odds = 999 }, pleg(to, 1, 49) }, ref = "pl4" }, 150, nil, 1)
    eq(nbets(), n1, "rejected parlays book nothing")
    p = try({ legs = { pleg(sp, 1), pleg(to, 1), pleg(other, 1) }, ref = "pl5" })
    check(p and p.legs[1].line == -5 and p.legs[2].line == 50.5, "legs without a line are accepted at the current lines")
    -- a parlay with a top-level line is malformed (the line belongs on each leg)
    local bad, why = try({ legs = { pleg(sp, 1), pleg(to, 1) }, line = -5, ref = "pl6" })
    check(bad == nil and why == "bad_request", "a parlay with a top-level line: bad_request")
end

------------------------------------------------------------------------------------------
-- grading as legs settle
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "moneyline", "CCC @ DDD", NOW + 3600, -200, 170)
    local c = market(book, "moneyline", "EEE @ FFF", NOW + 3600, 120, -140)
    local stake = 50 * S
    local bet = assert(parlay(book, "Bob", { leg(a, 1), leg(b, 1), leg(c, 1) }, stake, "g1"))
    local quoted = bet.odds
    local full = Odds.ParlayProfit(stake, { 150, -200, 120 })

    -- a leg wins: the parlay waits for the others
    local out = assert(Bookie.Settle(book, a.id, 1, NOW + 10))
    eq(#out, 1, "settling a market reports the parlay")
    check(out[1].bet == bet and out[1].delta == 0, "a parlay still waiting reports delta 0")
    check(bet.status == "accepted" and bet.legs[1].status == "won", "leg 1 won, parlay still open")
    eq(Bookie.Balance(book, "Bob"), 0, "no ledger effect while pending")
    eq(bet.odds, quoted, "still shows the quoted odds")
    check(bet.delta == nil and bet.settledAt == nil, "pending parlay has no delta or settledAt")
    local _, risk = Bookie.Credit(book, "Bob")
    eq(risk, stake, "still counts as open risk")

    -- a leg loses: the parlay loses at once, with the third leg still pending
    out = assert(Bookie.Settle(book, b.id, 2, NOW + 20))
    check(bet.status == "lost" and bet.legs[2].status == "lost" and bet.legs[3].status == "pending", "a lost leg loses the parlay immediately")
    eq(out[1].delta, -stake, "delta is minus the stake")
    eq(Bookie.Balance(book, "Bob"), -stake, "ledger charged")
    eq(bet.settledAt, NOW + 20, "settledAt set")
    _, risk = Bookie.Credit(book, "Bob")
    eq(risk, 0, "a lost parlay is no longer open risk")

    -- the pending leg settles later: still lost, charged once
    Bookie.Settle(book, c.id, 1, NOW + 30)
    eq(bet.status, "lost", "still lost after the last leg settles")
    eq(Bookie.Balance(book, "Bob"), -stake, "charged once, not twice")
    eq(bet.legs[3].status, "won", "leg 3 recorded as won")

    -- correct leg 2's result: now every leg won
    out = assert(Bookie.Settle(book, b.id, 1, NOW + 40))
    check(bet.status == "won", "correcting the losing leg makes the parlay a winner: " .. tostring(bet.status))
    eq(out[1].delta, full, "delta is the parlay profit")
    eq(Bookie.Balance(book, "Bob"), full, "ledger = +profit (the earlier loss was reversed)")
    eq(bet.odds, quoted, "no leg dropped out, so the paid price is the quoted one")
    eq(bet.delta, full, "bet.delta kept for the next correction")

    -- correct again: leg 1 actually lost
    Bookie.Settle(book, a.id, 2, NOW + 50)
    check(bet.status == "lost" and Bookie.Balance(book, "Bob") == -stake, "correcting back to a loss: ledger returns to -stake")
    check(bet.legs[1].status == "lost", "leg 1 now lost")
end

-- push and void legs drop out and the rest are repriced ------------------------------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "total", "CCC @ DDD", NOW + 3600, -110, -110, 200.5)
    local c = market(book, "moneyline", "EEE @ FFF", NOW + 3600, 120, -140)
    local stake = 40 * S
    local bet = assert(parlay(book, "Bob", { leg(a, 1), leg(b, 1), leg(c, 1) }, stake, "d1"))
    local quoted = bet.odds

    Bookie.Settle(book, a.id, 1, NOW + 1)
    Bookie.Settle(book, b.id, "push", NOW + 2)
    check(bet.status == "accepted" and bet.legs[2].status == "push", "a push leg does not decide anything")
    Bookie.Settle(book, c.id, 1, NOW + 3)
    check(bet.status == "won", "won with a push leg dropped")
    local repriced = Odds.ParlayProfit(stake, { 150, 120 })
    eq(bet.delta, repriced, "profit is from the two winning legs only")
    eq(bet.odds, Odds.ParlayOdds({ 150, 120 }), "odds updated to the effective price")
    check(bet.odds ~= quoted, "the effective price differs from the quoted one")
    eq(Bookie.Balance(book, "Bob"), repriced, "ledger = repriced profit")

    -- correct the push into a real result: it is priced with all three legs again, and the old
    -- (repriced) profit is reversed exactly
    Bookie.Settle(book, b.id, 1, NOW + 4)
    eq(bet.delta, Odds.ParlayProfit(stake, { 150, -110, 120 }), "back to the three-leg price")
    eq(Bookie.Balance(book, "Bob"), bet.delta, "ledger moved by the difference only")
    eq(bet.odds, quoted, "odds back to the quoted price")

    -- a voided leg market drops out the same way
    Bookie.VoidMarket(book, b.id, NOW + 5)
    eq(bet.legs[2].status, "void", "void leg")
    eq(bet.delta, repriced, "void leg: repriced without it")
    eq(Bookie.Balance(book, "Bob"), repriced, "ledger follows")

    -- nothing won, a push leg: the parlay pushes; every leg void: it is void
    local book2 = newBook()
    local p, q = market(book2, "moneyline", "AAA @ BBB"), market(book2, "moneyline", "CCC @ DDD")
    local bet2 = assert(parlay(book2, "Bob", { leg(p, 1), leg(q, 1) }, stake, "e1"))
    Bookie.Settle(book2, p.id, "push", NOW + 1)
    Bookie.Settle(book2, q.id, "push", NOW + 2)
    check(bet2.status == "push" and bet2.delta == 0 and Bookie.Balance(book2, "Bob") == 0, "all legs push: the parlay pushes, no money moves")
    Bookie.VoidMarket(book2, q.id, NOW + 3)
    check(bet2.status == "push", "a push and a void is still a push")
    Bookie.VoidMarket(book2, p.id, NOW + 4)
    check(bet2.status == "void" and bet2.delta == 0, "every leg void: the parlay is void")
    eq(bet2.odds, Odds.ParlayOdds({ -110, -110 }), "a void parlay shows its quoted odds")
    -- one push and one loss: lost
    Bookie.Settle(book2, p.id, "push", NOW + 5)
    Bookie.Settle(book2, q.id, 2, NOW + 6)
    check(bet2.status == "lost" and Bookie.Balance(book2, "Bob") == -stake, "push + loss is a loss")
end

-- singles and parlays settle together; the ledger always adds up ---------------------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "moneyline", "CCC @ DDD", NOW + 3600, -200, 170)
    local single = assert(Bookie.PlaceBet(book, "Bob", { marketId = a.id, selectionId = 1, stake = 20 * S, odds = 150, ref = "s" }, NOW))
    local par = assert(parlay(book, "Bob", { leg(a, 1), leg(b, 1) }, 30 * S, "p"))
    local other = assert(parlay(book, "Alice", { leg(a, 2), leg(b, 2) }, 10 * S, "q"))

    local out = assert(Bookie.Settle(book, a.id, 1, NOW + 1))
    eq(#out, 3, "market A: one single and two parlays are affected")
    local names = Bookie.AffectedBettors(out)
    eq(table.concat(names, ","), "Alice,Bob", "both bettors are affected (a pending parlay still needs a SYNC)")
    check(single.status == "won" and par.status == "accepted" and other.status == "lost", "single won, parlay waiting, other parlay lost at once")
    eq(Bookie.Balance(book, "Bob"), Odds.Profit(20 * S, 150), "Bob: single profit only")
    eq(Bookie.Balance(book, "Alice"), -10 * S, "Alice: her parlay lost")

    Bookie.Settle(book, b.id, 1, NOW + 2)
    eq(par.status, "won", "second leg wins the parlay")
    eq(Bookie.Balance(book, "Bob"), Odds.Profit(20 * S, 150) + Odds.ParlayProfit(30 * S, { 150, -200 }), "Bob: single + parlay")

    -- the sum of every balance is the negative of what the book makes
    -- (here: re-grade everything the other way and check the ledger returns to the same values)
    Bookie.Settle(book, a.id, 2, NOW + 3)
    Bookie.Settle(book, a.id, 1, NOW + 4)
    eq(Bookie.Balance(book, "Bob"), Odds.Profit(20 * S, 150) + Odds.ParlayProfit(30 * S, { 150, -200 }), "settling twice with the same result changes nothing")
    eq(Bookie.Balance(book, "Alice"), -10 * S, "Alice unchanged")
end

-- correcting through a void and back --------------------------------------------------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "moneyline", "CCC @ DDD", NOW + 3600, -200, 170)
    local par = assert(parlay(book, "Bob", { leg(a, 1), leg(b, 1) }, 30 * S, "p"))
    Bookie.Settle(book, a.id, 2, NOW + 1)              -- leg 1 loses
    eq(Bookie.Balance(book, "Bob"), -30 * S, "lost")
    Bookie.VoidMarket(book, a.id, NOW + 2)             -- ...but the game was voided
    check(par.status == "accepted" and Bookie.Balance(book, "Bob") == 0, "voiding the losing leg's market frees the parlay again (pending on leg 2)")
    Bookie.Settle(book, b.id, 1, NOW + 3)
    check(par.status == "won" and par.delta == Odds.ParlayProfit(30 * S, { -200 }), "leg 2 wins alone: repriced to one leg")
    eq(Bookie.Balance(book, "Bob"), par.delta, "ledger follows")
end

-- voiding a bet voids the whole parlay and it stays void --------------------------------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "moneyline", "CCC @ DDD", NOW + 3600, -200, 170)
    local par = assert(parlay(book, "Bob", { leg(a, 1), leg(b, 1) }, 30 * S, "p"))
    Bookie.Settle(book, a.id, 1, NOW + 1)
    Bookie.Settle(book, b.id, 1, NOW + 2)
    local profit = par.delta
    eq(Bookie.Balance(book, "Bob"), profit, "parlay won")
    local v = assert(Bookie.VoidBet(book, par.id, NOW + 3))
    check(v == par and par.status == "void" and par.voided, "VoidBet voids the parlay (sticky)")
    eq(Bookie.Balance(book, "Bob"), 0, "its win is reversed")
    eq(par.odds, Odds.ParlayOdds({ 150, -200 }), "shows the quoted odds again")
    Bookie.Settle(book, a.id, 1, NOW + 4)
    Bookie.VoidMarket(book, b.id, NOW + 5)
    check(par.status == "void" and Bookie.Balance(book, "Bob") == 0, "later settlements leave a voided parlay alone")
    local _, risk = Bookie.Credit(book, "Bob")
    eq(risk, 0, "a void parlay is not open risk")

    -- a won parlay that had a push leg shows its repriced odds; voiding it shows the quoted ones again
    local e1, e2, e3 = market(book, "moneyline", "III @ JJJ", NOW + 3600, 150, -170), market(book, "moneyline", "KKK @ LLL", NOW + 3600, -200, 170), market(book, "moneyline", "MMM @ NNN", NOW + 3600, 120, -140)
    local rp = assert(parlay(book, "Alice", { leg(e1, 1), leg(e2, 1), leg(e3, 1) }, 10 * S, "rp"))
    local quoted = rp.odds
    Bookie.Settle(book, e1.id, 1, NOW + 8)
    Bookie.Settle(book, e2.id, "push", NOW + 9)
    Bookie.Settle(book, e3.id, 1, NOW + 10)
    eq(rp.status, "won", "setup: the parlay won with a push leg dropped")
    eq(rp.odds, Odds.ParlayOdds({ 150, 120 }), "setup: showing the repriced odds")
    assert(Bookie.VoidBet(book, rp.id, NOW + 11))
    eq(rp.odds, quoted, "voiding it shows the odds it was quoted at, not the repriced ones")
    eq(Bookie.Balance(book, "Alice"), 0, "and its win is reversed")

    -- a settled market takes no new parlay legs
    local x, why, _, li = parlay(book, "Alice", { leg(a, 1), leg(b, 1) }, 10 * S, "p2")
    check(x == nil and why == "market_closed" and li == 1, "a settled market is closed to new parlays (leg 1)")

    -- voiding a parlay that is still open
    local c = market(book, "moneyline", "EEE @ FFF", NOW + 3600, 120, -140)
    local d = market(book, "moneyline", "GGG @ HHH", NOW + 3600, 100, -120)
    local open = assert(parlay(book, "Alice", { leg(c, 1), leg(d, 1) }, 10 * S, "p3"))
    assert(Bookie.VoidBet(book, open.id, NOW + 6))
    check(open.status == "void" and Bookie.Balance(book, "Alice") == 0, "an open parlay voids with no ledger effect")
    Bookie.Settle(book, c.id, 2, NOW + 7)
    check(open.status == "void" and Bookie.Balance(book, "Alice") == 0, "...and a later losing leg does not revive it")
    local ret, err = Bookie.VoidBet(book, 9999, NOW)
    check(ret == nil and err == "no_bet", "unknown bet id")
end

-- exposure and open stakes: a parlay is not attributed to one market --------------------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "moneyline", "CCC @ DDD", NOW + 3600, -200, 170)
    assert(Bookie.PlaceBet(book, "Bob", { marketId = a.id, selectionId = 1, stake = 20 * S, odds = 150, ref = "s" }, NOW))
    assert(parlay(book, "Bob", { leg(a, 1), leg(b, 1) }, 30 * S, "p"))
    assert(parlay(book, "Alice", { leg(a, 2), leg(b, 2) }, 10 * S, "q"))
    eq(Bookie.MarketExposure(book, a.id).staked, 20 * S, "market A: only the single is attributed")
    eq(Bookie.MarketExposure(book, b.id).staked, 0, "market B: parlay legs add nothing")
    local ex = Bookie.MarketExposure(book, a.id)
    eq(ex.net[1], -Odds.Profit(20 * S, 150), "net if A1 wins: the book pays the single")
    eq(ex.net[2], 20 * S, "net if A2 wins: the book keeps the single's stake")
    local o = Bookie.OpenStakes(book)
    check(o.singles == 20 * S and o.parlays == 40 * S and o.total == 60 * S and o.count == 3, "OpenStakes: singles, parlays, total, count")
    local _, risk = Bookie.Credit(book, "Bob")
    eq(risk, 50 * S, "Bob's open risk counts the parlay stake once")
    local rows, live = Bookie.MarketRows(book, NOW, 15)
    eq(live, 2, "two live markets")
    check(rows[1].staked == 20 * S and rows[2].staked == 0, "table staked column counts singles only")

    -- filters see parlays through their legs
    eq(#Bookie.ListBets(book, { marketId = b.id }), 2, "market filter finds parlays by leg")
    eq(#Bookie.ListBets(book, { marketId = a.id }), 3, "market filter finds the single and both parlays")
    local choices = Bookie.BetFilterChoices(book)
    eq(table.concat(choices.markets, ","), a.id .. "," .. b.id, "filter choices include leg markets")
end

------------------------------------------------------------------------------------------
-- SYNC: parlays bring their leg markets; the 14-day history cap applies to them too
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "moneyline", "CCC @ DDD", NOW + 3600, -200, 170)
    local c = market(book, "moneyline", "EEE @ FFF", NOW + 3600, 120, -140)
    local par = assert(parlay(book, "Bob", { leg(a, 1), leg(b, 1) }, 20 * S, "p"))
    local snap = Bookie.Snapshot(book, "Bob", NOW)
    eq(#snap.bets, 1, "the parlay is in Bob's SYNC")
    check(snap.bets[1].legs and #snap.bets[1].legs == 2, "with its legs")
    eq(#snap.markets, 3, "all open markets")

    -- both games start (so neither is bettable); Alice, who has no bets, sees neither, Bob sees both
    local later = NOW + 3600 + 5
    local ids = function(s) local t = {}; for _, m in ipairs(s.markets) do t[#t + 1] = m.id end; return table.concat(t, ",") end
    eq(ids(Bookie.Snapshot(book, "Alice", later)), "", "after the start, Alice (no bets) sees no markets")
    eq(ids(Bookie.Snapshot(book, "Bob", later)), a.id .. "," .. b.id, "Bob keeps exactly his parlay's leg markets")

    -- settle both legs; the parlay is a settled bet now
    Bookie.Settle(book, a.id, 1, later)
    Bookie.Settle(book, b.id, 1, later)
    snap = Bookie.Snapshot(book, "Bob", later)
    check(snap.bets[1].status == "won" and snap.bets[1].legs[1].status == "won", "settled parlay with leg statuses in the SYNC")
    eq(ids(snap), a.id .. "," .. b.id, "leg markets still travel with the settled parlay")
    eq(snap.balance, par.delta, "balance")

    -- 14 days: kept at the boundary, dropped beyond, and its leg markets go with it
    local keep = 14 * 24 * 3600
    snap = Bookie.Snapshot(book, "Bob", later + keep)
    eq(#snap.bets, 1, "settled exactly 14 days ago: kept (boundary inclusive)")
    snap = Bookie.Snapshot(book, "Bob", later + keep + 1)
    eq(#snap.bets, 0, "settled 14 days and a second ago: dropped")
    eq(#snap.markets, 0, "...and its leg markets are no longer sent")
    eq(snap.balance, par.delta, "the balance is unchanged by the cap")

    -- an open parlay is never dropped, however old; its leg markets always come
    local book2 = newBook()
    local x, y = market(book2, "moneyline", "AAA @ BBB", NOW + 100), market(book2, "moneyline", "CCC @ DDD", NOW + 100)
    assert(parlay(book2, "Bob", { leg(x, 1), leg(y, 1) }, 10 * S, "p"))
    snap = Bookie.Snapshot(book2, "Bob", NOW + keep * 3)
    check(#snap.bets == 1 and #snap.markets == 2, "an open parlay and its leg markets stay forever")

    -- a parlay still waiting on one leg: only Bob sees the finished leg's market too
    local book3 = newBook()
    local m1, m2 = market(book3, "moneyline", "AAA @ BBB", NOW + 100), market(book3, "moneyline", "CCC @ DDD", NOW + 9000)
    assert(parlay(book3, "Bob", { leg(m1, 1), leg(m2, 1) }, 10 * S, "p"))
    Bookie.Settle(book3, m1.id, 1, NOW + 200)
    snap = Bookie.Snapshot(book3, "Bob", NOW + 300)
    eq(#snap.markets, 2, "a settled leg's market stays while its parlay is open")
    eq(#Bookie.Snapshot(book3, "Alice", NOW + 300).markets, 1, "other bettors only get the bettable market")
end

------------------------------------------------------------------------------------------
-- messages: BET_PLACE in, BET_ACK / BET_REJECT out, and everything validates
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local a = market(book, "moneyline", "AAA @ BBB", NOW + 3600, 150, -170)
    local b = market(book, "moneyline", "CCC @ DDD", NOW + 3600, -200, 170)
    local spreadA = market(book, "spread", "AAA @ BBB", NOW + 3600, -110, -110, 3.5)

    local function handle(payload) return Bookie.Handle(book, "Bob", "BET_PLACE", payload, NOW) end
    local function valid(msg)
        local env, err = Protocol.Wrap(msg.type, "NBA-TEST", msg.payload)
        check(env, "outgoing " .. msg.type .. " validates: " .. tostring(err))
    end

    local payload = { ref = "m1", stake = 20 * S, legs = { leg(a, 1), leg(b, 2) } }
    check(Protocol.Validate("BET_PLACE", payload), "the parlay payload is valid on the wire")
    local out, events = handle(payload)
    eq(#out, 1, "one reply")
    eq(out[1].type, "BET_ACK", "accepted")
    eq(out[1].to, "Bob", "addressed to the bettor")
    check(out[1].payload.bet.legs and #out[1].payload.bet.legs == 2 and out[1].payload.bet.odds == Odds.ParlayOdds({ 150, 170 }), "the ACK carries the parlay with legs and combined odds")
    valid(out[1])
    check(events[1] and events[1].kind == "bet" and events[1].bet.legs, "a bet event")
    -- a retry: re-ACK, but not a new event
    out, events = handle(payload)
    check(out[1].type == "BET_ACK" and #events == 0, "a retried ref is re-acked without a second event")

    -- stale odds on leg 2
    local stale = { ref = "m2", stake = 20 * S, legs = { leg(a, 1), { marketId = b.id, selectionId = 2, odds = 160 } } }
    out, events = handle(stale)
    eq(out[1].type, "BET_REJECT", "rejected")
    eq(out[1].payload.reason, "odds_changed", "reason")
    eq(out[1].payload.currentOdds, 170, "current odds of the stale leg")
    eq(out[1].payload.legIndex, 2, "legIndex 2")
    valid(out[1])
    eq(events[1].legIndex, 2, "the event carries the leg too")

    -- conflict: ML + spread of one game
    out = handle({ ref = "m3", stake = 20 * S, legs = { leg(a, 1), leg(spreadA, 1) } })
    check(out[1].type == "BET_REJECT" and out[1].payload.reason == "parlay_conflict" and out[1].payload.legIndex == 2, "parlay_conflict with the later leg")
    valid(out[1])
    out = handle({ ref = "m4", stake = 20 * S, legs = { leg(a, 1), leg(a, 2) } })
    check(out[1].payload.reason == "parlay_conflict" and out[1].payload.legIndex == 2, "the same market twice: parlay_conflict, leg 2")

    -- credit limit shows the available amount, with no legIndex
    Bookie.SetCreditLimit(book, "Bob", 25 * S)
    out = handle({ ref = "m5", stake = 20 * S, legs = { leg(b, 1), leg(spreadA, 2) } })
    check(out[1].payload.reason == "credit_limit" and out[1].payload.available == 5 * S and out[1].payload.legIndex == nil, "credit_limit: available, no legIndex")
    valid(out[1])

    -- a moved line: odds_changed with currentOdds and currentLine (and legIndex for a leg); validates on the wire
    Bookie.SetCreditLimit(book, "Bob", nil)
    assert(Bookie.EditMarket(book, spreadA.id, { line = 4.5 }, NOW))
    local saw = { ref = "m8", marketId = spreadA.id, selectionId = 1, stake = 10 * S, odds = -110, line = 3.5 }
    check(Protocol.Validate("BET_PLACE", saw), "a single bet carrying its line is valid on the wire")
    out = handle(saw)
    check(out[1].type == "BET_REJECT" and out[1].payload.reason == "odds_changed" and out[1].payload.currentOdds == -110
          and out[1].payload.currentLine == 4.5 and out[1].payload.legIndex == nil, "single: odds_changed with currentOdds and currentLine")
    valid(out[1])
    local legSaw = { ref = "m9", stake = 10 * S, legs = { leg(a, 1), { marketId = spreadA.id, selectionId = 1, odds = -110, line = 3.5 } } }
    check(Protocol.Validate("BET_PLACE", legSaw), "legs carrying lines are valid on the wire")
    out = handle(legSaw)
    check(out[1].payload.reason == "odds_changed" and out[1].payload.currentLine == 4.5 and out[1].payload.legIndex == 2
          and out[1].payload.currentOdds == -110, "parlay: odds_changed with currentOdds, currentLine and legIndex 2")
    valid(out[1])
    -- re-confirmed at the current line: accepted, and the ACK's bet carries the line
    out = handle({ ref = "m10", marketId = spreadA.id, selectionId = 1, stake = 10 * S, odds = -110, line = 4.5 })
    check(out[1].type == "BET_ACK" and out[1].payload.bet.line == 4.5, "re-confirmed at the new line: BET_ACK carries bet.line")
    valid(out[1])
    out = handle({ ref = "m11", stake = 10 * S, legs = { leg(b, 1), { marketId = spreadA.id, selectionId = 2, odds = -110, line = 4.5 } } })
    check(out[1].type == "BET_ACK" and out[1].payload.bet.legs[2].line == 4.5, "parlay accepted: BET_ACK legs carry their lines")
    valid(out[1])
    -- a moneyline odds_changed has no currentLine
    out = handle({ ref = "m12", marketId = a.id, selectionId = 1, stake = 10 * S, odds = 999 })
    check(out[1].payload.reason == "odds_changed" and out[1].payload.currentLine == nil and out[1].payload.currentOdds == 150, "moneyline odds_changed: no currentLine")
    valid(out[1])

    -- a single bet's rejection never carries a legIndex
    out = handle({ ref = "m6", marketId = a.id, selectionId = 1, stake = 10 * S, odds = 999 })
    check(out[1].payload.reason == "odds_changed" and out[1].payload.legIndex == nil, "singles: no legIndex")

    -- leg count out of range gets bad_request from the bookie (Protocol would drop it on the wire first)
    out = Bookie.Handle(book, "Bob", "BET_PLACE", { ref = "m7", stake = 10 * S, legs = { leg(a, 1) } }, NOW)
    check(out[1].payload.reason == "bad_request" and out[1].payload.legIndex == nil, "one leg: bad_request")
    valid(out[1])
end

if fails == 0 then print("bookie_parlay: all tests passed") else os.exit(1) end
