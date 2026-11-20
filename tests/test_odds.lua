-- Run from repo root: lua5.1 tests/test_odds.lua
local ns = {}
local Odds = assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)

local fails = 0
local function eq(got, want, label)
    if got ~= want then fails = fails + 1; print(("FAIL: %s (got %s, want %s)"):format(label, tostring(got), tostring(want))) end
end

-- Profit
eq(Odds.Profit(100, 150), 150, "+150 on 100")
eq(Odds.Profit(110, -110), 100, "-110 on 110")
eq(Odds.Profit(100, -110), 90, "-110 on 100 floors 90.9")
eq(Odds.Profit(1, -110), 0, "tiny stake floors to 0")
eq(Odds.Profit(3, 150), 4, "+150 on 3 floors 4.5")
eq(Odds.Profit(150, -150), 100, "-150 on 150")
eq(Odds.Profit(10000, 100), 10000, "even money")
eq(select(2, Odds.Profit(0, 150)), "bad stake", "zero stake")
eq(select(2, Odds.Profit(-5, 150)), "bad stake", "negative stake")
eq(select(2, Odds.Profit(100.5, 150)), "bad stake", "fractional stake")
eq(select(2, Odds.Profit(100, 50)), "bad odds", "odds between -100 and 100")
eq(select(2, Odds.Profit(100, 0)), "bad odds", "zero odds")

-- Delta (bookie agent API: stake, odds, outcome)
eq(Odds.Delta(100, 150, "won"), 150, "delta won")
eq(Odds.Delta(100, 150, "lost"), -100, "delta lost")
eq(Odds.Delta(100, 150, "push"), 0, "delta push")
eq(Odds.Delta(100, 150, "void"), 0, "delta void")
eq(select(2, Odds.Delta(100, 150, "pending")), "bad outcome", "delta unknown outcome")
eq(Odds.IsValid(-100), true, "-100 valid")
eq(Odds.IsValid(99), false, "99 invalid")
eq(Odds.Format(150), "+150", "format plus")
eq(Odds.Format(-110), "-110", "format minus")
eq(Odds.Parse("+150"), 150, "parse plus")
eq(Odds.Parse(" -110 "), -110, "parse spaced")
eq(Odds.Parse("50"), nil, "parse invalid")

-- Settle (alias of Delta with status first)
eq(Odds.Settle("won", 100, 150), 150, "settle won")
eq(Odds.Settle("lost", 100, 150), -100, "settle lost")
eq(Odds.Settle("push", 100, 150), 0, "settle push")
eq(Odds.Settle("void", 100, 150), 0, "settle void")
eq(Odds.Settle("pending", 100, 150), nil, "settle pending is not an outcome")

-- Grading
eq(Odds.GradeTotal(47.5, 48), "over", "total over")
eq(Odds.GradeTotal(47.5, 47), "under", "total under")
eq(Odds.GradeTotal(47, 47), "push", "total push")
eq(Odds.GradeSpread(-3.5, 24, 20), "first", "favorite covers")
eq(Odds.GradeSpread(-3.5, 23, 20), "second", "favorite fails to cover")
eq(Odds.GradeSpread(-3, 23, 20), "push", "spread push")
eq(Odds.GradeSpread(3.5, 17, 20), "first", "dog covers on the line")

-- FormatMoney
eq(Odds.FormatMoney(0), "0c", "format zero")
eq(Odds.FormatMoney(123456), "12g 34s 56c", "format all parts")
eq(Odds.FormatMoney(250 * 10000), "250g", "format whole gold")
eq(Odds.FormatMoney(10005), "1g 5c", "format skips zero silver")
eq(Odds.FormatMoney(-1200000), "-120g", "format negative")

-- ParseMoney
eq(Odds.ParseMoney("250"), 2500000, "bare number is gold")
eq(Odds.ParseMoney("250g"), 2500000, "gold")
eq(Odds.ParseMoney("12g 5s"), 120500, "gold and silver")
eq(Odds.ParseMoney("1.5g"), 15000, "decimal gold")
eq(Odds.ParseMoney("50s"), 5000, "silver")
eq(Odds.ParseMoney("1500c"), 1500, "copper")
eq(Odds.ParseMoney("1g2s3c"), 10203, "no spaces")
eq(Odds.ParseMoney(" 2G "), 20000, "case and spaces")
eq(Odds.ParseMoney("0.1g"), 1000, "float rounding")
eq(Odds.ParseMoney(""), nil, "empty")
eq(Odds.ParseMoney("abc"), nil, "letters")
eq(Odds.ParseMoney("5g 5g"), nil, "repeated unit")
eq(Odds.ParseMoney("5g 6"), nil, "unitless after a unit")
eq(Odds.ParseMoney("1.5c"), nil, "fractional copper")
eq(Odds.ParseMoney("-5g"), nil, "negative rejected")
eq(Odds.ParseMoney(12), nil, "non-string")

-- StakeCheck
eq(Odds.StakeCheck(10000), true, "1g is allowed")
eq(Odds.StakeCheck(2000), true, "20s is allowed")
eq(Odds.StakeCheck(100), true, "1s is allowed")
eq(select(2, Odds.StakeCheck(2010)), "bad_stake", "20s 10c is not whole silver")
eq(select(2, Odds.StakeCheck(10)), "bad_stake", "10c is not whole silver")
eq(select(2, Odds.StakeCheck(10100)), "bad_stake", "over 1g")
eq(select(2, Odds.StakeCheck(0)), "bad_stake", "zero")
eq(select(2, Odds.StakeCheck(-100)), "bad_stake", "negative")
eq(select(2, Odds.StakeCheck(150.5)), "bad_stake", "fractional")
eq(select(2, Odds.StakeCheck("20s")), "bad_stake", "non-number")

-- Parlays
local function near(got, want, label) eq(got ~= nil and math.abs(got - want) < 1e-9, true, label .. " (got " .. tostring(got) .. ")") end
near(Odds.Decimal(150), 2.5, "decimal +150")
near(Odds.Decimal(-200), 1.5, "decimal -200")
eq(Odds.Decimal(50), nil, "decimal rejects +50")
near(Odds.ParlayDecimal({ -110, -110, 130 }), (1 + 100 / 110) ^ 2 * 2.3, "3-leg decimal")
eq(Odds.ParlayOdds({ -110, -110 }), 264, "two -110 legs are +264")
eq(Odds.ParlayOdds({ -110, -110, 130 }), 738, "-110 -110 +130 is +738")
eq(Odds.ParlayOdds({ 100, 100 }), 300, "two even-money legs are +300")
eq(Odds.ParlayOdds({ -1000, -1000 }), -476, "two -1000 legs are -476 (rounded)")
eq(Odds.FromDecimal(1.5), -200, "1.5 decimal is -200")
eq(Odds.FromDecimal(2.0), 100, "2.0 decimal is +100")
eq(Odds.FromDecimal(1), nil, "decimal must exceed 1")
eq(Odds.ParlayProfit(2000, { -110, -110, 130 }), 14765, "20s on a +738 parlay wins 1g 47s 65c")
eq(Odds.ParlayProfit(10000, { 100, 100 }), 30000, "1g on +300 wins 3g")
eq(select(2, Odds.ParlayProfit(0, { 100, 100 })), "bad stake", "parlay stake must be positive")
eq(select(2, Odds.ParlayProfit(100, { 100, 7 })), "bad odds", "parlay rejects bad leg odds")
eq(Odds.ParlayLegCheck(2), true, "2 legs ok")
eq(Odds.ParlayLegCheck(Odds.MAX_PARLAY_LEGS), true, "max legs ok")
eq(select(2, Odds.ParlayLegCheck(1)), "bad_request", "1 leg is not a parlay")
eq(select(2, Odds.ParlayLegCheck(Odds.MAX_PARLAY_LEGS + 1)), "bad_request", "too many legs")

local ML  = { id = 1, event = "LAL @ BOS", closesAt = 100, type = "moneyline" }
local SP  = { id = 2, event = "LAL @ BOS", closesAt = 100, type = "spread" }
local TOT = { id = 3, event = "LAL @ BOS", closesAt = 100, type = "total" }
local TOT2 = { id = 4, event = "LAL @ BOS", closesAt = 100, type = "total" }
local OTHER = { id = 5, event = "DEN @ PHX", closesAt = 200, type = "moneyline" }
local ML_LATER = { id = 6, event = "LAL @ BOS", closesAt = 999, type = "moneyline" }
eq(Odds.ParlayConflict({ ML, TOT }), true, "ML + total from one game is allowed")
eq(Odds.ParlayConflict({ SP, TOT }), true, "spread + total from one game is allowed")
eq(Odds.ParlayConflict({ ML, OTHER, TOT }), true, "different games never conflict")
eq(select(2, Odds.ParlayConflict({ ML, SP })), "same_game_conflict", "ML + spread conflict")
eq(select(2, Odds.ParlayConflict({ TOT, TOT2 })), "same_game_conflict", "over + under conflict")
eq(select(2, Odds.ParlayConflict({ ML, TOT, SP })), "same_game_conflict", "a second side bet conflicts")
eq(select(2, Odds.ParlayConflict({ ML, ML })), "duplicate_market", "same market twice")
eq(Odds.ParlayConflict({ ML, ML_LATER }), true, "same event string at another time is another game")
do
    local ok, why, i, j = Odds.ParlayConflict({ OTHER, ML, SP })
    eq(ok, false, "conflict found after a clean leg"); eq(i, 2, "first conflicting leg"); eq(j, 3, "second conflicting leg")
end

local function legs(...) local l = {}; for i, v in ipairs({ ... }) do l[i] = { odds = v[1], status = v[2] } end; return l end
do
    local st, d, o = Odds.GradeParlay(2000, legs({ -110, "won" }, { -110, "won" }, { 130, "won" }))
    eq(st, "won", "all legs won"); eq(d, 14765, "all-won profit"); eq(o, 738, "all-won odds")
    st, d = Odds.GradeParlay(2000, legs({ -110, "won" }, { -110, "lost" }, { 130, "pending" }))
    eq(st, "lost", "a lost leg decides it while others are pending"); eq(d, -2000, "lost delta")
    st, d = Odds.GradeParlay(2000, legs({ -110, "won" }, { 130, "pending" }))
    eq(st, "pending", "pending while a leg is open"); eq(d, 0, "pending delta")
    st, d, o = Odds.GradeParlay(2000, legs({ -110, "won" }, { -110, "push" }, { 130, "void" }))
    eq(st, "won", "push and void legs drop out"); eq(d, 1818, "profit on the one winning leg (-110 on 20s)"); eq(o, -110, "odds of the remaining leg")
    st, d = Odds.GradeParlay(2000, legs({ -110, "push" }, { 130, "void" }))
    eq(st, "push", "push + void with no winner is a push"); eq(d, 0, "push delta")
    st, d = Odds.GradeParlay(2000, legs({ -110, "void" }, { 130, "void" }))
    eq(st, "void", "all void"); eq(d, 0, "void delta")
    eq(select(2, Odds.GradeParlay(0, legs({ -110, "won" }, { 130, "won" }))), "bad stake", "grade needs a stake")
end

if fails == 0 then print("odds: all tests passed") else os.exit(1) end
