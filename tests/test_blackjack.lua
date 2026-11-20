-- Run from repo root: luajit tests/test_blackjack.lua
local ns = {}
local B = assert(loadfile("SteveBook/Blackjack.lua"))("SteveBook", ns)
local fails = 0
local function eq(got, want, label)
    if got ~= want then fails = fails + 1; print(("FAIL: %s (got %s, want %s)"):format(label, tostring(got), tostring(want))) end
end
local function val(...) return (B.Value({ ... })) end

-- shoe
local shoe = B.NewShoe(1, function(m, n) return m end)
eq(#shoe, 52, "one deck is 52 cards")
local seen, dup = {}, false
for _, c in ipairs(shoe) do if seen[c] then dup = true end; seen[c] = true; if not B.IsCard(c) then fails = fails + 1; print("FAIL: bad card " .. c) end end
eq(dup, false, "no duplicate cards in one deck")
eq(#B.NewShoe(), 52 * 6, "default shoe is six decks")
local s6 = B.NewShoe(6)
local counts = {}
for _, c in ipairs(s6) do counts[c] = (counts[c] or 0) + 1 end
local ok6 = true
for _, n in pairs(counts) do if n ~= 6 then ok6 = false end end
eq(ok6, true, "each card appears six times")
local a, b = B.NewShoe(1), B.NewShoe(1)
local same = true
for i = 1, 52 do if a[i] ~= b[i] then same = false end end
eq(same, false, "two shuffles differ")
eq(B.IsCard("AS"), true, "AS"); eq(B.IsCard("1S"), false, "1S"); eq(B.IsCard("AX"), false, "AX"); eq(B.IsCard("A"), false, "A"); eq(B.IsCard(5), false, "number")

-- values
eq(val("2S", "3H"), 5, "2+3"); eq(val("KS", "QH"), 20, "K+Q"); eq(val("AS", "KH"), 21, "A+K")
eq(val("AS", "AH"), 12, "A+A is 12"); eq(val("AS", "AH", "9D"), 21, "A+A+9 is 21")
eq(val("AS", "6H", "KD"), 17, "A+6+K: the ace drops to 1"); eq(val("KS", "QH", "5D"), 25, "bust total")
eq(val("AS", "AH", "AD", "AC"), 14, "four aces are 14")
local t, soft = B.Value({ "AS", "6H" }); eq(t, 17, "soft 17 total"); eq(soft, true, "soft")
t, soft = B.Value({ "AS", "6H", "KD" }); eq(soft, false, "hard 17")
t, soft = B.Value({ "TS", "7H" }); eq(soft, false, "10+7 is hard")
eq(B.IsBlackjack({ "AS", "KH" }), true, "A+K is blackjack"); eq(B.IsBlackjack({ "TS", "AH" }), true, "10+A")
eq(B.IsBlackjack({ "7S", "7H", "7D" }), false, "three sevens are not blackjack")
eq(B.IsBlackjack({ "KS", "QH" }), false, "20 is not blackjack")

-- split
eq(B.CanSplit({ "8S", "8H" }), true, "pair of 8s"); eq(B.CanSplit({ "KS", "QH" }), true, "K and Q split")
eq(B.CanSplit({ "AS", "AH" }), true, "aces"); eq(B.CanSplit({ "8S", "9H" }), false, "8 and 9")
eq(B.CanSplit({ "8S", "8H", "2D" }), false, "three cards")

-- dealer
eq(B.DealerHits({ "TS", "6H" }), true, "dealer hits 16"); eq(B.DealerHits({ "TS", "7H" }), false, "dealer stands on 17")
eq(B.DealerHits({ "AS", "6H" }), false, "stands on soft 17"); eq(B.DealerHits({ "AS", "6H" }, true), true, "hits soft 17 when asked")
eq(B.DealerHits({ "AS", "7H" }), false, "stands on soft 18"); eq(B.DealerHits({ "TS", "5H", "AD" }), true, "10+5+A is a hard 16: dealer hits")

local function dealer(...) return B.DealerResult({ ... }) end
eq(dealer("KS", "7H").total, 17, "dealer total"); eq(dealer("KS", "QH", "5D").bust, true, "dealer bust")
eq(dealer("AS", "KH").blackjack, true, "dealer blackjack"); eq(dealer("7S", "7H", "7D").blackjack, false, "21 on three cards is not blackjack")

-- settlement
local function settle(cards, bet, natural, d)
    local o, r = B.Settle({ cards = cards, bet = bet, natural = natural }, d)
    return o, r
end
local d17 = dealer("KS", "7H")
local o, r = settle({ "KS", "9H" }, 1000, false, d17); eq(o, "win", "19 beats 17"); eq(r, 2000, "pays 1:1")
o, r = settle({ "KS", "7D" }, 1000, false, d17); eq(o, "push", "17 pushes 17"); eq(r, 1000, "stake back")
o, r = settle({ "KS", "6D" }, 1000, false, d17); eq(o, "lose", "16 loses to 17"); eq(r, 0, "nothing back")
o, r = settle({ "KS", "QH", "5D" }, 1000, false, d17); eq(o, "bust", "25 busts"); eq(r, 0, "nothing back")
o, r = settle({ "AS", "KH" }, 1000, true, d17); eq(o, "blackjack", "natural"); eq(r, 2500, "pays 3:2 (1000 + 1500)")
o, r = settle({ "AS", "KH" }, 100, true, d17); eq(r, 250, "3:2 on 1s is exact")
o, r = settle({ "AS", "KH" }, 100 * 3, true, d17); eq(r, 750, "3:2 on 3s")
o, r = settle({ "AS", "KH" }, 1000, true, dealer("AS", "QH")); eq(o, "push", "blackjack pushes a dealer blackjack"); eq(r, 1000, "stake back")
o, r = settle({ "KS", "9H", "2D" }, 1000, false, dealer("AS", "QH")); eq(o, "lose", "21 on three cards loses to a dealer blackjack"); eq(r, 0, "lost")
o, r = settle({ "AS", "KH" }, 1000, false, d17); eq(o, "win", "A+K after a split is a plain 21"); eq(r, 2000, "pays 1:1 only")
o, r = settle({ "KS", "6D" }, 1000, false, dealer("KS", "QH", "5D")); eq(o, "win", "any live hand wins when the dealer busts"); eq(r, 2000, "1:1")
o, r = settle({ "KS", "QH", "5D" }, 1000, false, dealer("KS", "QH", "5D")); eq(o, "bust", "the player busts first even if the dealer does too")
o, r = settle({ "KS", "6D" }, 2000, false, d17); eq(o, "lose", "a doubled bet loses double"); eq(r, 0, "0 back")
o, r = settle({ "KS", "9D" }, 2000, false, d17); eq(r, 4000, "a doubled bet wins double")
eq(B.RankLabel("TS"), "10", "ten label"); eq(B.RankLabel("AS"), "A", "ace label")

-- house edge sanity: basic play is not simulated here; just check that a long run of random hands vs dealer
-- (player stands on 17+, hits below, no doubles/splits) loses a little, never wildly
do
    math.randomseed(12345)
    local shoe, pos = B.NewShoe(6), 1
    local function draw() if pos > #shoe - 20 then shoe = B.NewShoe(6); pos = 1 end; local c = shoe[pos]; pos = pos + 1; return c end
    local net, staked = 0, 0
    for _ = 1, 40000 do
        local p, dl = { draw(), draw() }, {}
        dl = { draw(), draw() }
        local natural = B.IsBlackjack(p)
        if not natural then while (B.Value(p)) < 17 do p[#p + 1] = draw() end end
        while B.DealerHits(dl) do dl[#dl + 1] = draw() end
        local _, ret = B.Settle({ cards = p, bet = 100, natural = natural }, B.DealerResult(dl))
        net = net + ret - 100; staked = staked + 100
    end
    local edge = -net / staked
    eq(edge > 0.0 and edge < 0.08, true, ("naive strategy loses a few percent (%.3f)"):format(edge))
end

if fails == 0 then print("blackjack: all passed") else os.exit(1) end
