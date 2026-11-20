-- Run from repo root: luajit tests/test_roulette.lua
local ns = {}
local R = assert(loadfile("SteveBook/Roulette.lua"))("SteveBook", ns)
local fails = 0
local function eq(got, want, label)
    if got ~= want then fails = fails + 1; print(("FAIL: %s (got %s, want %s)"):format(label, tostring(got), tostring(want))) end
end
local function ok(bet, zero) return (R.ValidateBet(bet, zero)) end
local function why(bet, zero) return select(2, R.ValidateBet(bet, zero)) end

-- colours
eq(R.Color(0), "green", "0 is green"); eq(R.Color(37), "green", "00 is green")
eq(R.Color(1), "red", "1 red"); eq(R.Color(2), "black", "2 black"); eq(R.Color(36), "red", "36 red"); eq(R.Color(10), "black", "10 black")
local reds = 0
for n = 1, 36 do if R.Color(n) == "red" then reds = reds + 1 end end
eq(reds, 18, "18 red numbers")
eq(R.Label(37), "00", "label 00"); eq(R.Label(17), "17", "label 17")

-- pockets and spin
eq(#R.Pockets("single"), 37, "single zero: 37 pockets")
eq(#R.Pockets("double"), 38, "double zero: 38 pockets")
eq(#R.Pockets("none"), 36, "no zero: 36 pockets")
eq(R.Pockets("none")[1], 1, "no zero starts at 1")
eq(R.Spin("single", function(m, n) return m end), 0, "lowest roll is 0")
eq(R.Spin("single", function(m, n) return n end), 36, "highest roll is 36")
eq(R.Spin("double", function(m, n) return n end), 37, "highest double-zero roll is 00")
eq(R.Spin("none", function(m, n) return m end), 1, "no zero: lowest is 1")
do
    local seen = {}
    for i = 1, 5000 do seen[R.Spin("single")] = true end
    local n = 0; for _ in pairs(seen) do n = n + 1 end
    eq(n, 37, "5000 real spins hit every pocket")
end

-- validation: straight
eq(ok({ kind = "straight", numbers = { 17 }, amount = 100 }), true, "straight 17")
eq(ok({ kind = "straight", numbers = { 0 }, amount = 100 }), true, "straight 0")
eq(ok({ kind = "straight", numbers = { 37 }, amount = 100 }), false, "00 is not on a single-zero wheel")
eq(ok({ kind = "straight", numbers = { 37 }, amount = 100 }, "double"), true, "00 on a double-zero wheel")
eq(ok({ kind = "straight", numbers = { 0 }, amount = 100 }, "none"), false, "no 0 on a no-zero wheel")
eq(ok({ kind = "straight", numbers = { 37 }, amount = 100 }, "none"), false, "no 00 on a no-zero wheel")
eq(ok({ kind = "straight", numbers = { 40 }, amount = 100 }), false, "40 is off the wheel")
eq(ok({ kind = "straight", numbers = { 1.5 }, amount = 100 }), false, "fractional number")
eq(ok({ kind = "straight", numbers = { 17, 18 }, amount = 100 }), false, "straight takes one number")
eq(ok({ kind = "straight", numbers = { 17 }, amount = 0 }), false, "zero amount")
eq(ok({ kind = "straight", numbers = { 17 }, amount = 10.5 }), false, "fractional amount")
eq(ok({ kind = "bogus", amount = 100 }), false, "unknown kind")
eq(why({ kind = "bogus", amount = 100 }), "bad_bet", "reason is bad_bet")
eq(ok(nil), false, "not a table")
-- splits
eq(ok({ kind = "split", numbers = { 17, 18 }, amount = 100 }), true, "split side by side")
eq(ok({ kind = "split", numbers = { 18, 17 }, amount = 100 }), true, "split order does not matter")
eq(ok({ kind = "split", numbers = { 17, 20 }, amount = 100 }), true, "split above and below")
eq(ok({ kind = "split", numbers = { 3, 4 }, amount = 100 }), false, "3 and 4 are on different rows")
eq(ok({ kind = "split", numbers = { 17, 19 }, amount = 100 }), false, "17 and 19 do not touch")
eq(ok({ kind = "split", numbers = { 17, 17 }, amount = 100 }), false, "same number twice")
eq(ok({ kind = "split", numbers = { 0, 3 }, amount = 100 }), true, "single zero touches 3")
eq(ok({ kind = "split", numbers = { 0, 4 }, amount = 100 }), false, "0 does not touch 4")
eq(ok({ kind = "split", numbers = { 0, 3 }, amount = 100 }, "double"), false, "double-zero 0 does not touch 3")
eq(ok({ kind = "split", numbers = { 0, 2 }, amount = 100 }, "double"), true, "double-zero 0 touches 2")
eq(ok({ kind = "split", numbers = { 37, 3 }, amount = 100 }, "double"), true, "00 touches 3")
eq(ok({ kind = "split", numbers = { 0, 37 }, amount = 100 }, "double"), true, "0 touches 00")
eq(ok({ kind = "split", numbers = { 36, 35 }, amount = 100 }), true, "last row split")
-- streets, corners, six lines
eq(ok({ kind = "street", numbers = { 7, 8, 9 }, amount = 100 }), true, "street 7-8-9")
eq(ok({ kind = "street", numbers = { 8, 9, 10 }, amount = 100 }), false, "8-9-10 is not a street")
eq(ok({ kind = "street", numbers = { 34, 35, 36 }, amount = 100 }), true, "last street")
eq(ok({ kind = "corner", numbers = { 1, 2, 4, 5 }, amount = 100 }), true, "corner 1-2-4-5")
eq(ok({ kind = "corner", numbers = { 2, 3, 5, 6 }, amount = 100 }), true, "corner 2-3-5-6")
eq(ok({ kind = "corner", numbers = { 3, 4, 6, 7 }, amount = 100 }), false, "3-4-6-7 wraps a row")
eq(ok({ kind = "corner", numbers = { 32, 33, 35, 36 }, amount = 100 }), true, "last corner")
eq(ok({ kind = "sixline", numbers = { 1, 2, 3, 4, 5, 6 }, amount = 100 }), true, "six line 1-6")
eq(ok({ kind = "sixline", numbers = { 31, 32, 33, 34, 35, 36 }, amount = 100 }), true, "last six line")
eq(ok({ kind = "sixline", numbers = { 2, 3, 4, 5, 6, 7 }, amount = 100 }), false, "2-7 is not a six line")
-- outside
for _, k in ipairs({ "red", "black", "odd", "even", "low", "high" }) do
    eq(ok({ kind = k, amount = 100 }), true, k .. " bet")
end
eq(ok({ kind = "dozen", pick = 2, amount = 100 }), true, "dozen 2")
eq(ok({ kind = "dozen", pick = 4, amount = 100 }), false, "dozen 4")
eq(ok({ kind = "dozen", amount = 100 }), false, "dozen needs a pick")
eq(ok({ kind = "column", pick = 3, amount = 100 }), true, "column 3")

-- coverage
local function covers(bet, n) return R.Covers(bet, n) end
eq(covers({ kind = "straight", numbers = { 17 } }, 17), true, "straight wins on its number")
eq(covers({ kind = "straight", numbers = { 17 } }, 18), false, "and loses elsewhere")
eq(covers({ kind = "split", numbers = { 17, 18 } }, 18), true, "split covers either")
eq(covers({ kind = "red" }, 1), true, "red covers 1"); eq(covers({ kind = "red" }, 2), false, "red misses 2")
eq(covers({ kind = "black" }, 2), true, "black covers 2")
eq(covers({ kind = "red" }, 0), false, "zero beats red"); eq(covers({ kind = "black" }, 0), false, "zero beats black")
eq(covers({ kind = "even" }, 0), false, "zero is not even"); eq(covers({ kind = "low" }, 0), false, "zero is not low")
eq(covers({ kind = "odd" }, 37), false, "00 beats odd")
eq(covers({ kind = "odd" }, 35), true, "35 odd"); eq(covers({ kind = "even" }, 36), true, "36 even")
eq(covers({ kind = "low" }, 18), true, "18 low"); eq(covers({ kind = "low" }, 19), false, "19 not low")
eq(covers({ kind = "high" }, 19), true, "19 high"); eq(covers({ kind = "high" }, 36), true, "36 high")
eq(covers({ kind = "dozen", pick = 1 }, 12), true, "12 in dozen 1"); eq(covers({ kind = "dozen", pick = 2 }, 13), true, "13 in dozen 2")
eq(covers({ kind = "dozen", pick = 3 }, 36), true, "36 in dozen 3"); eq(covers({ kind = "dozen", pick = 3 }, 24), false, "24 not in dozen 3")
eq(covers({ kind = "column", pick = 1 }, 34), true, "34 in column 1"); eq(covers({ kind = "column", pick = 2 }, 2), true, "2 in column 2")
eq(covers({ kind = "column", pick = 3 }, 36), true, "36 in column 3"); eq(covers({ kind = "column", pick = 3 }, 35), false, "35 not in column 3")

-- payouts (stake comes back too)
eq(R.Win({ kind = "straight", numbers = { 17 }, amount = 100 }, 17), 3600, "straight pays 35:1")
eq(R.Win({ kind = "split", numbers = { 17, 18 }, amount = 100 }, 17), 1800, "split pays 17:1")
eq(R.Win({ kind = "street", numbers = { 7, 8, 9 }, amount = 100 }, 8), 1200, "street pays 11:1")
eq(R.Win({ kind = "corner", numbers = { 1, 2, 4, 5 }, amount = 100 }, 5), 900, "corner pays 8:1")
eq(R.Win({ kind = "sixline", numbers = { 1, 2, 3, 4, 5, 6 }, amount = 100 }, 6), 600, "six line pays 5:1")
eq(R.Win({ kind = "dozen", pick = 1, amount = 100 }, 5), 300, "dozen pays 2:1")
eq(R.Win({ kind = "column", pick = 2, amount = 100 }, 5), 300, "column pays 2:1")
eq(R.Win({ kind = "red", amount = 100 }, 1), 200, "red pays 1:1")
eq(R.Win({ kind = "red", amount = 100 }, 2), 0, "a losing bet returns nothing")

-- settle
do
    local bets = { { kind = "straight", numbers = { 17 }, amount = 100 }, { kind = "red", amount = 500 }, { kind = "black", amount = 200 } }
    local s = R.Settle(bets, 17)        -- 17 is black: straight wins 3600, red loses, black wins 400
    eq(s.staked, 800, "staked"); eq(s.returned, 4000, "returned"); eq(s.net, 3200, "net")
    eq(s.wins[1], 3600, "win 1"); eq(s.wins[2], 0, "win 2"); eq(s.wins[3], 400, "win 3")
    s = R.Settle(bets, 0)
    eq(s.net, -800, "zero takes everything")
    eq(R.Settle({}, 5).net, 0, "no bets, no result")
end

-- house edge: even money on a single-zero wheel, summed over every pocket, loses 1/37 of the stake
for _, zero in ipairs({ "single", "double", "none" }) do
    local total, pockets = 0, R.Pockets(zero)
    local checks = { { kind = "red", amount = 1000 }, { kind = "straight", numbers = { 17 }, amount = 1000 }, { kind = "dozen", pick = 2, amount = 1000 } }
    for _, bet in ipairs(checks) do
        local net = 0
        for _, p in ipairs(pockets) do net = net + R.Settle({ bet }, p).net end
        local edge = -net / (#pockets * bet.amount)
        eq(math.abs(edge - R.HouseEdge(zero)) < 1e-9, true, ("%s %s: house edge %.4f"):format(zero, bet.kind, edge))
    end
end

eq(R.Describe({ kind = "straight", numbers = { 17 } }), "17", "describe straight")
eq(R.Describe({ kind = "split", numbers = { 18, 17 } }), "17, 18", "describe split")
eq(R.Describe({ kind = "dozen", pick = 2 }), "2nd dozen", "describe dozen")
eq(R.Describe({ kind = "red" }), "Red", "describe red")
eq(R.Describe({ kind = "low" }), "1-18", "describe low")

if fails == 0 then print("roulette: all passed") else os.exit(1) end
