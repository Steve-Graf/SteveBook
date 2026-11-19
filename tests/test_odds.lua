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

if fails == 0 then print("odds: all tests passed") else os.exit(1) end
