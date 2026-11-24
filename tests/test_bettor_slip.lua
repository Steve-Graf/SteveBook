-- Run from repo root: luajit tests/test_bettor_slip.lua
local ns = {}
for _, f in ipairs({ "Odds", "Protocol", "Cache", "Slip" }) do assert(loadfile("SteveBook/" .. f .. ".lua"))("SteveBook", ns) end
local Odds, Cache, Slip, Protocol = ns.Odds, ns.Cache, ns.Slip, ns.Protocol

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; print("FAIL: " .. label) end
end

local NOW, CLOSE = 1000000, 1003600
local nextId = 0
local function market(event, type_, line, odds1, odds2, labels, closes)
    nextId = nextId + 1
    labels = labels or (type_ == "total" and { "Over", "Under" } or { "AAA", "BBB" })
    return { id = nextId, sport = "NBA", event = event, type = type_, line = line, status = "open", closesAt = closes or CLOSE,
        selections = { { id = 1, label = labels[1], odds = odds1 or -110 }, { id = 2, label = labels[2], odds = odds2 or -110 } } }
end

-- Two games: AAA @ BBB (ML, spread, total) and CCC @ DDD (ML, total).
local g1ml  = market("AAA @ BBB", "moneyline", nil, 150, -170)
local g1sp  = market("AAA @ BBB", "spread", -3.5, -110, -110)
local g1tot = market("AAA @ BBB", "total", 220.5, -110, -110)
local g2ml  = market("CCC @ DDD", "moneyline", nil, -120, 100, { "CCC", "DDD" })
local g2tot = market("CCC @ DDD", "total", 200.5, -105, -115)
local markets = { [g1ml.id] = g1ml, [g1sp.id] = g1sp, [g1tot.id] = g1tot, [g2ml.id] = g2ml, [g2tot.id] = g2tot }
local function getMarket(id) return markets[id] end

------------------------------------------------------------------------------------------
-- Single mode
------------------------------------------------------------------------------------------
local s = Slip.New()
check(s.mode == "single" and #Slip.Legs(s) == 0, "new slip is empty, single")
check(Slip.Select(s, g1ml, 1) == "set" and #Slip.Legs(s) == 1, "single: click sets the selection")
check(Slip.Select(s, g1sp, 2) == "set" and #Slip.Legs(s) == 1 and Slip.Legs(s)[1].marketId == g1sp.id, "single: another cell replaces it")
check(Slip.Select(s, g1sp, 1) == "replaced" and Slip.Legs(s)[1].selectionId == 1, "single: other side of the same market replaces")
check(Slip.IsSelected(s, g1sp.id, 1) and not Slip.IsSelected(s, g1sp.id, 2), "single: IsSelected")
check(Slip.Select(s, g1sp, 1) == "removed" and #Slip.Legs(s) == 0, "single: same cell again clears it")
Slip.Select(s, g1ml, 1)
check(Slip.Odds(s) == 150, "single odds")
check(Slip.ToWin(s, 2000) == Odds.Profit(2000, 150), "single to-win")
check(Slip.ToWin(s, nil) == nil, "no stake, no to-win")
local req = Slip.Request(s, "r1", 2000)
check(req.marketId == g1ml.id and req.selectionId == 1 and req.odds == 150 and req.stake == 2000 and req.legs == nil, "single request is flat")
check(Protocol.Validate("BET_PLACE", req), "single request is valid on the wire")
check(Slip.Select(s, { id = 99, selections = {} }, 1) == "refused", "unknown selection refused")

------------------------------------------------------------------------------------------
-- Parlay rules
------------------------------------------------------------------------------------------
Slip.SetMode(s, "parlay")
check(#Slip.Legs(s) == 0 and Slip.ParlayCount(s) == 0, "parlay starts empty (single selection is separate)")
local a, msg = Slip.Select(s, g1ml, 1)
check(a == "added" and #s.parlay == 1, "parlay: add a leg")
check(Slip.Odds(s) == nil and Slip.ToWin(s, 1000) == nil, "one leg has no combined odds")

a, msg = Slip.Select(s, g1tot, 1)
check(a == "added" and #s.parlay == 2, "parlay: ML + total from the same game is allowed")
a, msg = Slip.Select(s, g1tot, 2)
check(a == "replaced" and #s.parlay == 2 and s.parlay[2].selectionId == 2, "parlay: the other side of the same market replaces the pick")
a, msg = Slip.Select(s, g1sp, 1)
check(a == "refused" and #s.parlay == 2, "parlay: spread with a moneyline from the same game is refused")
check(msg and msg:find("AAA") and msg:find("Moneyline"), "refusal names the conflicting leg: " .. tostring(msg))
a = Slip.Select(s, g1tot, 2)
check(a == "removed" and #s.parlay == 1, "parlay: same pick again removes the leg")
a = Slip.Select(s, g1sp, 1)
check(a == "refused" and #s.parlay == 1, "parlay: ML + spread still refused with only the ML on the slip")
a = Slip.Select(s, g1ml, 1)
check(a == "removed" and #s.parlay == 0, "parlay: remove the ML")
Slip.Select(s, g1sp, 1)                                   -- spread first this time
a, msg = Slip.Select(s, g1ml, 1)
check(a == "refused" and msg:find("Spread"), "parlay: ML after a spread is refused, naming the spread: " .. tostring(msg))
a = Slip.Select(s, g1tot, 1)
check(a == "added", "parlay: spread + total is allowed")
a = Slip.Select(s, g1tot, 2)
check(a == "replaced", "over -> under in the same market is a replacement, not an over+under pair")
check(#s.parlay == 2, "still two legs")

-- Different games never conflict.
Slip.Select(s, g2ml, 1); Slip.Select(s, g2tot, 2)
check(#s.parlay == 4, "legs from another game are all fine (ML + total there)")
a = Slip.Select(s, g2ml, 2)
check(a == "replaced" and s.parlay[3].selectionId == 2, "other game: swap sides in place, order kept")

-- Combined price and to-win.
local list = {}
for i, l in ipairs(s.parlay) do list[i] = l.odds end
check(Slip.Odds(s) == Odds.ParlayOdds(list) and Slip.Odds(s) ~= nil, "combined odds")
check(Slip.ToWin(s, 2000) == Odds.ParlayProfit(2000, list), "parlay to-win comes from the decimal product")

-- Remove buttons.
local n = #s.parlay
Slip.Remove(s, 1)
check(#s.parlay == n - 1, "remove a leg by index")
Slip.Remove(s, 99)
check(#s.parlay == n - 1, "removing a missing leg does nothing")

-- Max legs.
do
    local big = Slip.New(); Slip.SetMode(big, "parlay")
    local ids = {}
    for i = 1, 10 do
        local m = market("T" .. i .. " @ U" .. i, "moneyline", nil, -110, -110)
        markets[m.id] = m
        local act, why = Slip.Select(big, m, 1)
        if i <= Odds.MAX_PARLAY_LEGS then check(act == "added", "leg " .. i .. " added")
        else check(act == "refused" and why:find("at most"), "leg " .. i .. " refused: too many") end
    end
    check(#big.parlay == Odds.MAX_PARLAY_LEGS, "8 legs max")
end

-- Modes keep separate selections.
do
    local m = Slip.New()
    Slip.Select(m, g1ml, 1)                  -- single
    Slip.SetMode(m, "parlay"); Slip.Select(m, g2ml, 1); Slip.Select(m, g2tot, 1)
    check(m.single and m.single.marketId == g1ml.id and #m.parlay == 2, "single and parlay selections are independent")
    check(Slip.IsSelected(m, g2ml.id, 1) and not Slip.IsSelected(m, g1ml.id, 1), "highlight follows the current mode")
    Slip.SetMode(m, "single")
    check(Slip.IsSelected(m, g1ml.id, 1) and not Slip.IsSelected(m, g2ml.id, 1), "highlight follows the mode back")
    Slip.Clear(m)
    check(m.single == nil and #m.parlay == 2, "Clear only clears the current mode")
    Slip.ClearAll(m)
    check(#m.parlay == 0, "ClearAll")
end

------------------------------------------------------------------------------------------
-- Validate
------------------------------------------------------------------------------------------
local function canBet(id) local m = markets[id]; if Cache.IsClosed(m, NOW) then return false, "market_closed" end; return true end
local v = Slip.New(); Slip.SetMode(v, "parlay")
check(select(2, Slip.Validate(v, 1000, canBet)) == "empty", "empty slip")
Slip.Select(v, g1ml, 1)
local ok, code = Slip.Validate(v, 1000, canBet)
check(not ok and code == "legs", "one leg is not a parlay")
Slip.Select(v, g2ml, 1)
check(Slip.Validate(v, 1000, canBet), "two legs and a valid stake can be placed")
ok, code = Slip.Validate(v, nil, canBet); check(not ok and code == "stake_missing", "no stake yet")
ok, code, msg = Slip.Validate(v, 20000, canBet); check(not ok and code == "stake" and msg:find("maximum"), "stake over the maximum")
ok, code, msg = Slip.Validate(v, 2010, canBet); check(not ok and code == "stake" and msg:find("silver"), "stake with loose copper")
ok, code, msg = Slip.Validate(v, 1000, function() return false, "offline" end)
check(not ok and code == "closed" and msg:find("offline"), "offline blocks placing: " .. tostring(msg))
ok, code, msg = Slip.Validate(v, 1000, function(id) if id == g2ml.id then return false, "market_closed" end return true end)
check(not ok and code == "closed" and msg == "This game has started.", "a started game blocks placing")

req = Slip.Request(v, "p1", 1000)
check(req.legs and #req.legs == 2 and req.marketId == nil and req.selectionId == nil and req.odds == nil, "parlay request has legs and no flat fields")
check(req.legs[1].marketId == g1ml.id and req.legs[2].marketId == g2ml.id, "legs in slip order")
check(Protocol.Validate("BET_PLACE", req), "parlay request is valid on the wire")

------------------------------------------------------------------------------------------
-- Sync with the cache: started games drop out, moved odds need a confirmation
------------------------------------------------------------------------------------------
do
    local w = Slip.New()
    Slip.Select(w, g1ml, 1)
    Slip.SetMode(w, "parlay")
    Slip.Select(w, g1ml, 1); Slip.Select(w, g2ml, 1); Slip.Select(w, g2tot, 2)
    local dropped, changed = Slip.Sync(w, getMarket, NOW)
    check(#dropped == 0 and #changed == 0 and #w.parlay == 3, "nothing changed, nothing happens")

    -- Odds move on g2ml: the leg takes the new price and asks for a confirmation.
    markets[g2ml.id] = { id = g2ml.id, sport = "NBA", event = "CCC @ DDD", type = "moneyline", status = "open", closesAt = CLOSE,
        selections = { { id = 1, label = "CCC", odds = -140 }, { id = 2, label = "DDD", odds = 120 } } }
    dropped, changed = Slip.Sync(w, getMarket, NOW)
    check(#changed == 1 and changed[1].odds == -140 and changed[1].changedFrom == -120, "moved odds are updated and remembered")
    check(Slip.NeedsConfirm(w), "the parlay needs a confirmation")
    ok, code = Slip.Validate(w, 1000, canBet)
    check(not ok and code == "confirm", "cannot place before confirming")
    Slip.Confirm(w)
    check(not Slip.NeedsConfirm(w) and w.parlay[2].changedFrom == nil, "confirm clears the flag")
    check(Slip.Validate(w, 1000, canBet), "can place after confirming")
    local before = Slip.Odds(w)
    Slip.Sync(w, getMarket, NOW)
    check(Slip.Odds(w) == before and not Slip.NeedsConfirm(w), "a second sync with the same odds asks for nothing")

    -- The single selection's game starts; the parlay loses the legs of that game too.
    markets[g1ml.id].closesAt = NOW - 1
    dropped, changed = Slip.Sync(w, getMarket, NOW)
    local started = 0
    for _, d in ipairs(dropped) do if d.reason == "started" then started = started + 1 end end
    check(started == 2 and w.single == nil and #w.parlay == 2, "legs on a started game are dropped from both modes")
    -- A market that disappeared from the cache.
    markets[g2tot.id] = nil
    dropped = Slip.Sync(w, getMarket, NOW)
    check(#dropped == 1 and dropped[1].reason == "gone" and #w.parlay == 1, "a vanished market drops its leg")
    markets[g2tot.id] = g2tot
    markets[g1ml.id].closesAt = CLOSE

    -- A started game that a SYNC already dropped from the cache is still reported as started.
    local x = Slip.New(); Slip.SetMode(x, "parlay")
    Slip.Select(x, g2ml, 1); Slip.Select(x, g2tot, 1)
    markets[g2ml.id] = nil
    local d2 = Slip.Sync(x, getMarket, CLOSE + 1)
    check(#d2 == 2 and d2[1].reason == "started" and d2[2].reason == "started", "a pruned game whose start time has passed counts as started")
    markets[g2ml.id] = nil
    local y = Slip.New(); Slip.Select(y, g1sp, 1)
    markets[g1sp.id] = nil
    local d3 = Slip.Sync(y, getMarket, NOW)
    check(#d3 == 1 and d3[1].reason == "gone", "a pruned game that has not started is just gone")
    markets[g1sp.id] = g1sp
    markets[g2ml.id] = g2ml
end

-- A line that moves in place needs a confirmation, like moved odds.
do
    local w = Slip.New()
    local mv = { id = 500, sport = "NBA", event = "LL @ MM", type = "spread", line = -3, status = "open", closesAt = CLOSE,
        selections = { { id = 1, label = "LL", odds = -110 }, { id = 2, label = "MM", odds = -110 } } }
    markets[mv.id] = mv
    Slip.Select(w, mv, 1)
    check(w.single.line == -3, "the leg remembers the line")
    markets[mv.id] = { id = 500, sport = "NBA", event = "LL @ MM", type = "spread", line = -4, status = "open", closesAt = CLOSE,
        selections = { { id = 1, label = "LL", odds = -110 }, { id = 2, label = "MM", odds = -110 } } }
    local _, changed = Slip.Sync(w, getMarket, NOW)
    check(#changed == 1 and w.single.line == -4 and w.single.lineChangedFrom == -3 and Slip.NeedsConfirm(w), "a line move (same odds) asks for a confirmation")
    Slip.Confirm(w)
    check(w.single.lineChangedFrom == nil and not Slip.NeedsConfirm(w), "confirming clears it")
    markets[mv.id] = nil
end

-- Requests carry the line the slip showed (spread/total), and none for a moneyline.
do
    local w = Slip.New()
    Slip.Select(w, g1sp, 1)
    local r = Slip.Request(w, "q1", 1000)
    check(r.line == -3.5 and Protocol.Validate("BET_PLACE", r), "single spread request carries its line")
    Slip.Select(w, g1ml, 1)
    r = Slip.Request(w, "q2", 1000)
    check(r.line == nil and Protocol.Validate("BET_PLACE", r), "moneyline request has no line")
    Slip.SetMode(w, "parlay")
    Slip.Select(w, g1sp, 2); Slip.Select(w, g2tot, 1); Slip.Select(w, g2ml, 1)
    r = Slip.Request(w, "q3", 1000)
    check(r.legs[1].line == -3.5 and r.legs[2].line == 200.5 and r.legs[3].line == nil and r.line == nil, "parlay legs carry their lines; the moneyline leg has none")
    check(Protocol.Validate("BET_PLACE", r), "parlay with lines is valid on the wire")
    local back = {}
    Slip.Restore(w, "parlay", { { marketId = g1sp.id, selectionId = 1, odds = -110, line = -4 }, { marketId = g2ml.id, selectionId = 1, odds = -120 } }, getMarket)
    check(w.parlay[1].line == -4 and w.parlay[2].line == nil, "Restore keeps lines")
end

-- Restore after a rejection.
do
    local w = Slip.New()
    local skipped = Slip.Restore(w, "parlay", { { marketId = g1ml.id, selectionId = 2, odds = -170 }, { marketId = 777, selectionId = 1, odds = 100 },
        { marketId = g2ml.id, selectionId = 1, odds = -140 } }, getMarket)
    check(w.mode == "parlay" and #w.parlay == 2 and skipped[1] == 2, "Restore rebuilds the parlay and reports skipped legs")
    check(w.parlay[1].market == g1ml, "restored legs carry their markets")
    Slip.Restore(w, "single", { { marketId = g1sp.id, selectionId = 2, odds = -105 } }, getMarket)
    check(w.mode == "single" and w.single.odds == -105, "Restore a single")
end

-- Tail: someone else's picks on my slip, at today's prices.
do
    local w = Slip.New()
    local r = Slip.Tail(w, { { m = g1ml.id, s = 1 } }, getMarket, NOW)
    check(r.mode == "single" and r.added == 1 and #r.skipped == 0, "tail of one pick is a single")
    check(w.mode == "single" and w.single.marketId == g1ml.id and w.single.selectionId == 1, "the pick is on the slip")
    check(w.single.odds == 150 and w.single.market == g1ml, "at the market's current odds, with the market")
    r = Slip.Tail(w, { { m = g2ml.id, s = 2 } }, getMarket, NOW)
    check(r.added == 1 and w.single.marketId == g2ml.id, "a single replaces the single before it")

    Slip.SetMode(w, "parlay"); Slip.Select(w, g1tot, 2)
    Slip.SetMode(w, "single")
    r = Slip.Tail(w, { { m = g1sp.id, s = 1 }, { m = g1tot.id, s = 1 }, { m = g2ml.id, s = 1 } }, getMarket, NOW)
    check(r.mode == "parlay" and r.added == 3 and #w.parlay == 3 and w.mode == "parlay", "several picks make a parlay, and the slip switches to it")
    check(w.parlay[1].marketId == g1sp.id and w.parlay[3].selectionId == 1, "in order")
    check(w.single and w.single.marketId == g2ml.id, "the single pick is left alone")
    check(Slip.Odds(w) == Odds.ParlayOdds({ -110, -110, -120 }), "priced as a parlay at today's odds")
    check(not w.confirm.parlay, "nothing to confirm")

    -- a game that has started, one that has gone, and one that clashes with an earlier pick
    local p = Slip.New()
    local started = market("EEE @ FFF", "moneyline", nil, -110, -110, nil, NOW - 1)
    markets[started.id] = started
    r = Slip.Tail(p, { { m = g1ml.id, s = 2 }, { m = started.id, s = 1 }, { m = 9999, s = 1 }, { m = g2tot.id, s = 1 } }, getMarket, NOW)
    check(r.added == 2 and #p.parlay == 2 and #r.skipped == 2, "the started and the missing game are skipped")
    check(r.skipped[1].index == 2 and r.skipped[1].reason == "started" and r.skipped[2].index == 3 and r.skipped[2].reason == "gone", "with the reason for each")
    r = Slip.Tail(p, { { m = g1ml.id, s = 1 }, { m = g1sp.id, s = 1 } }, getMarket, NOW)
    check(r.added == 1 and r.skipped[1].reason == "conflict" and r.skipped[1].index == 2, "a pick that breaks the parlay rules is skipped")
    r = Slip.Tail(p, { { m = g1ml.id, s = 1 }, { m = g1ml.id, s = 2 } }, getMarket, NOW)
    check(r.added == 1 and r.skipped[1].reason == "conflict", "the same game twice is skipped too")

    -- nothing left: the slip is as it was
    local q = Slip.New(); Slip.Select(q, g1ml, 1)
    r = Slip.Tail(q, { { m = started.id, s = 1 } }, getMarket, NOW)
    check(r.added == 0 and q.single.marketId == g1ml.id and q.mode == "single", "when every pick is gone the slip is untouched")
    r = Slip.Tail(q, { { m = started.id, s = 1 }, { m = 9999, s = 1 } }, getMarket, NOW)
    check(r.added == 0 and #q.parlay == 0 and q.mode == "single", "...also for a parlay")
    r = Slip.Tail(q, { { m = g1ml.id, s = 7 } }, getMarket, NOW)
    check(r.added == 0 and r.skipped[1].reason == "gone", "a selection the market does not have is gone")

    -- tailing clears an odds confirmation the slip was waiting on
    local c = Slip.New(); Slip.Select(c, g1ml, 1); c.confirm.single = true
    Slip.Tail(c, { { m = g1sp.id, s = 1 } }, getMarket, NOW)
    check(not c.confirm.single, "a fresh pick has nothing to confirm")
end

if fails == 0 then print("test_bettor_slip: all passed") else print(fails .. " FAILED"); os.exit(1) end
