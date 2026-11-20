-- Host-side casino logic. Run from repo root: luajit tests/test_casino.lua
local ns = {}
for _, f in ipairs({ "Odds", "Roulette", "Protocol", "Model", "Casino" }) do assert(loadfile("SteveBook/" .. f .. ".lua"))("SteveBook", ns) end
local C, P = ns.Casino, ns.Protocol
local fails = 0
local function eq(got, want, label)
    if got ~= want then fails = fails + 1; print(("FAIL: %s (got %s, want %s)"):format(label, tostring(got), tostring(want))) end
end
local NOW = 1000000
local seed = 0
local function rand(n) seed = seed + 7; return (seed % n) + 1 end

local db = { }
local t = assert(C.Create(db, { game = "roulette", name = "Friday Night", zero = "single" }, "Steve", NOW, rand))
eq(t.code:match("^RLT%-%w%w%w%w$") ~= nil, true, "code looks like RLT-XXXX: " .. t.code)
eq(C.Find(db, t.code:lower()) == t, true, "Find accepts any case")
eq(t.status, "betting", "new table is taking bets"); eq(t.round, 1, "round 1")
eq(t.minBet, 100, "default min 1s"); eq(t.maxBet, 10000, "default max 1g")
eq(#C.List(db), 1, "one table listed")
eq(select(2, C.Create(db, { game = "blackjack" }, "Steve", NOW)), "Blackjack is not available yet.", "blackjack is not ready")
eq(C.Create(db, { game = "chess" }, "Steve", NOW), nil, "unknown game")
eq(C.Create(db, { game = "roulette", zero = "triple" }, "Steve", NOW), nil, "unknown wheel")
eq(C.Create(db, { game = "roulette", minBet = 50 }, "Steve", NOW), nil, "min bet must be whole silver")
eq(C.Create(db, { game = "roulette", minBet = 500, maxBet = 300 }, "Steve", NOW), nil, "max below min")
eq(C.Create(db, { game = "roulette", maxBet = 100000 + 100 }, "Steve", NOW), nil, "max above the cap")
eq(C.Create(db, { game = "roulette" }, "", NOW), nil, "needs a host")
do
    local t2 = C.Create(db, { game = "roulette", name = "   " }, "Steve", NOW, rand)
    eq(t2.name, "Roulette", "blank name falls back to the game")
end

-- joining
eq(C.RequestJoin(t, "Bob", NOW), "pending", "first request is pending")
eq(C.RequestJoin(t, "Bob", NOW), "pending", "asking again stays pending")
eq(#C.Pending(t), 1, "one pending"); eq(C.Pending(t)[1], "Bob", "Bob is pending")
eq(select(2, C.Admit(t, "Nobody", 0, NOW)), "no_member", "admit needs a request")
eq(select(2, C.Admit(t, "Bob", 150, NOW)), "bad_amount", "chips must be whole silver")
eq(select(2, C.Admit(t, "Bob", -100, NOW)), "bad_amount", "no negative chips")
local bob = assert(C.Admit(t, "Bob", 5000, NOW))
eq(bob.status, "seated", "Bob sits"); eq(bob.balance, 5000, "with 50s"); eq(bob.bought, 5000, "bought tracks the allotment")
eq(C.Seated(t)[1], "Bob", "seated list")
eq(#C.Pending(t), 0, "no longer pending")

-- chips
eq(C.Adjust(t, "Bob", 2000), 7000, "add 20s"); eq(bob.bought, 7000, "bought follows")
eq(C.Adjust(t, "Bob", -1000), 6000, "take 10s away")
eq(select(2, C.Adjust(t, "Bob", -7000)), "no_balance", "cannot take more than they have")
eq(select(2, C.Adjust(t, "Bob", 0)), "bad_amount", "zero is not an adjustment")
eq(select(2, C.Adjust(t, "Bob", 50)), "bad_amount", "adjust is whole silver")
eq(select(2, C.Adjust(t, "Zed", 100)), "not_seated", "adjust needs a seated player")

-- betting
local function bet(kind, amount, extra)
    local b = { kind = kind, amount = amount }
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
end
local b1 = assert(C.PlaceBet(t, "Bob", 1, bet("red", 1000), "r1"))
eq(bob.balance, 5000, "the bet came off the balance"); eq(b1.id, 1, "bet id 1"); eq(C.Staked(bob), 1000, "staked")
local again, _, repeated = C.PlaceBet(t, "Bob", 1, bet("red", 1000), "r1")
eq(again, b1, "a repeated ref returns the same bet"); eq(repeated, true, "flagged as a repeat"); eq(bob.balance, 5000, "and takes no more chips")
eq(select(2, C.PlaceBet(t, "Zed", 1, bet("red", 100), "z")), "not_seated", "strangers cannot bet")
eq(select(2, C.PlaceBet(t, "Bob", 2, bet("red", 100), "x")), "round_closed", "stale round")
eq(select(2, C.PlaceBet(t, "Bob", 1, bet("red", 50), "x")), "bad_bet", "amount must be whole silver")
eq(select(2, C.PlaceBet(t, "Bob", 1, { kind = "bogus", amount = 100 }, "x")), "bad_bet", "unknown bet")
eq(select(2, C.PlaceBet(t, "Bob", 1, bet("straight", 100, { numbers = { 37 } }), "x")), "bad_bet", "00 on a single-zero wheel")
local _, why, extra = C.PlaceBet(t, "Bob", 1, bet("red", 10100), "x"); eq(why, "max_bet", "over the max"); eq(extra, 10000, "max reported")
t.minBet = 200
_, why, extra = C.PlaceBet(t, "Bob", 1, bet("red", 100), "x"); eq(why, "min_bet", "under the min"); eq(extra, 200, "min reported")
t.minBet = 100
_, why, extra = C.PlaceBet(t, "Bob", 1, bet("red", 6000), "x"); eq(why, "no_balance", "more than the chips"); eq(extra, 5000, "balance reported")
local b2 = assert(C.PlaceBet(t, "Bob", 1, bet("straight", 500, { numbers = { 17 } }), "r2"))
eq(b2.id, 2, "bet id 2"); eq(bob.balance, 4500, "balance after two bets")
local b3 = assert(C.PlaceBet(t, "Bob", 1, bet("split", 500, { numbers = { 18, 17 } }), "r3"))
eq(b3.numbers[1], 17, "numbers are stored sorted")
eq(C.ClearBets(t, "Bob", 1), 2000, "clearing returns all chips")
eq(bob.balance, 6000, "back to 60s"); eq(#bob.bets, 0, "no bets left")
eq(select(2, C.ClearBets(t, "Bob", 9)), "round_closed", "clear needs the current round")

-- a round: Bob bets 10s on red, 5s on 17; Cy bets 20s on black
assert(C.Admit(C.RequestJoin(t, "Cy", NOW) and t, "Cy", 3000, NOW))
assert(C.PlaceBet(t, "Bob", 1, bet("red", 1000), "a"))
assert(C.PlaceBet(t, "Bob", 1, bet("straight", 500, { numbers = { 17 } }), "b"))
assert(C.PlaceBet(t, "Cy", 1, bet("black", 2000), "c"))
eq(bob.balance, 4500, "Bob 60 - 15"); eq(t.members.Cy.balance, 1000, "Cy 30 - 20")
eq(C.BeginSpin(t, NOW), true, "spin begins"); eq(t.status, "spinning", "spinning")
eq(select(2, C.BeginSpin(t, NOW)), "not_betting", "cannot spin twice")
eq(select(2, C.PlaceBet(t, "Bob", 1, bet("red", 100), "late")), "round_closed", "no bets while spinning")
eq(select(2, C.ClearBets(t, "Bob", 1)), "round_closed", "no clearing while spinning")
local r = assert(C.Finish(t, 17, NOW + 3))            -- 17 is black
eq(r.number, 17, "result number"); eq(r.round, 1, "result round"); eq(#r.results, 2, "two bettors in the results")
eq(r.results[1].name, "Bob", "results are sorted by name")
eq(r.results[1].net, 18000 - 1500, "Bob: 5s straight pays 36x back (180s), minus 15s staked")
eq(bob.balance, 4500 + 18000, "Bob's chips")
eq(r.results[1].balance, bob.balance, "result carries the new balance")
eq(r.results[2].net, 2000, "Cy wins even money on black"); eq(t.members.Cy.balance, 1000 + 4000, "Cy's chips")
eq(t.round, 2, "next round"); eq(t.status, "betting", "betting again"); eq(t.history[1], 17, "history has 17")
eq(#bob.bets, 0, "table cleared")
eq(r.results[1].bets[2].win, 18000, "per-bet wins are listed")
eq(select(2, C.Finish(t, 5, NOW)), "not_spinning", "cannot finish when not spinning")

-- history is trimmed
for i = 1, 20 do assert(C.BeginSpin(t, NOW)); assert(C.Finish(t, i % 37, NOW)) end
eq(#t.history, C.HISTORY_KEEP, "history keeps " .. C.HISTORY_KEEP); eq(t.history[1], 20, "newest first")
eq(t.round, 22, "rounds keep counting")

-- zero beats outside bets
do
    local zt = assert(C.Create(db, { game = "roulette", zero = "double" }, "Steve", NOW, rand))
    C.RequestJoin(zt, "Dee", NOW); C.Admit(zt, "Dee", 1000, NOW)
    assert(C.PlaceBet(zt, "Dee", 1, bet("red", 500), "z1"))
    assert(C.PlaceBet(zt, "Dee", 1, bet("straight", 100, { numbers = { 37 } }), "z2"))   -- 00 is on this wheel
    C.BeginSpin(zt, NOW)
    local res = C.Finish(zt, 37, NOW)
    eq(res.results[1].net, 100 * 35 - 500, "00 wins the straight and beats red")
end

-- leaving and kicking return open bets
assert(C.PlaceBet(t, "Bob", t.round, bet("red", 1000), "l1"))
local before = bob.balance
eq(C.Leave(t, "Bob"), true, "Bob leaves"); eq(bob.status, "left", "left"); eq(bob.balance, before + 1000, "his open bet came back")
eq(select(2, C.PlaceBet(t, "Bob", t.round, bet("red", 100), "l2")), "not_seated", "left players cannot bet")
eq(select(2, C.Leave(t, "Bob")), "not_seated", "cannot leave twice")
eq(C.RequestJoin(t, "Bob", NOW), "pending", "a player who left can ask again")
assert(C.Admit(t, "Bob", 0, NOW)); eq(bob.balance, before + 1000, "and keeps their chips")
assert(C.PlaceBet(t, "Cy", t.round, bet("red", 1000), "k1"))
local cyBefore = t.members.Cy.balance
eq(C.Kick(t, "Cy"), true, "kick"); eq(t.members.Cy.balance, cyBefore + 1000, "kicked player's bet returned")
eq(select(2, C.RequestJoin(t, "Cy", NOW)), "removed", "kicked players cannot rejoin by asking")
eq(C.Deny(t, "Nobody"), nil, "deny needs a request")
C.RequestJoin(t, "Eve", NOW); eq(C.Deny(t, "Eve"), true, "deny"); eq(C.RequestJoin(t, "Eve", NOW), "pending", "denied players may ask again")

-- ledger
do
    local led = C.Ledger(t)
    local by = {}
    for _, e in ipairs(led) do by[e.name] = e end
    eq(by.Bob ~= nil and by.Cy ~= nil, true, "ledger lists Bob and Cy")
    eq(by.Bob.result, by.Bob.chips - by.Bob.bought, "result = chips - bought")
    eq(by.Eve, nil, "pending players are not in the ledger")
end

-- settings
eq(C.SetLimits(t, 300, 5000), true, "set limits"); eq(t.minBet, 300, "min"); eq(t.maxBet, 5000, "max")
eq(C.SetLimits(t, 300, 100), nil, "bad limits")

-- closing refunds everything
do
    local ct = assert(C.Create(db, { game = "roulette" }, "Steve", NOW, rand))
    C.RequestJoin(ct, "Fay", NOW); C.Admit(ct, "Fay", 3000, NOW)
    assert(C.PlaceBet(ct, "Fay", 1, bet("red", 1000), "c1"))
    C.Close(ct)
    eq(ct.status, "closed", "closed"); eq(ct.members.Fay.balance, 3000, "bets came back")
    eq(select(2, C.RequestJoin(ct, "Gus", NOW)), "closed", "no new players at a closed table")
    eq(select(2, C.PlaceBet(ct, "Fay", 1, bet("red", 100), "c2")), "round_closed", "no bets at a closed table")
end

-- recovery: a spin that never finished is cancelled
do
    local rdb = {}
    local rt = assert(C.Create(rdb, { game = "roulette" }, "Steve", NOW, rand))
    C.RequestJoin(rt, "Hal", NOW); C.Admit(rt, "Hal", 2000, NOW)
    assert(C.PlaceBet(rt, "Hal", 1, bet("red", 1000), "h1"))
    C.BeginSpin(rt, NOW)
    C.Recover(rdb)
    eq(rt.status, "betting", "recovered to betting"); eq(rt.members.Hal.balance, 2000, "bet returned"); eq(#rt.members.Hal.bets, 0, "no bets")
    assert(C.PlaceBet(rt, "Hal", 1, bet("red", 1000), "h2"))
    C.Recover(rdb)
    eq(rt.members.Hal.balance, 1000, "a table that was taking bets keeps them")
end

-- Handle + messages (every outgoing payload must pass Protocol)
local function valid(out)
    for _, m in ipairs(out) do
        local env, err = P.Wrap(m.type, t.code, m.payload)
        if not env then fails = fails + 1; print("FAIL: outgoing " .. m.type .. " is invalid: " .. tostring(err)) end
    end
end
do
    local ht = assert(C.Create(db, { game = "roulette", name = "Handle" }, "Steve", NOW, rand))
    t = ht
    local out, ev = C.Handle(ht, "Ivy", "TBL_JOIN", {}, NOW)
    eq(#out, 0, "a new request gets no reply"); eq(ev[1].kind, "join_request", "the host is told"); eq(ev[1].name, "Ivy", "who")
    out, ev = C.Handle(ht, "Ivy", "TBL_JOIN", {}, NOW)
    eq(#ev, 0, "asking again is not announced again")
    out = C.Handle(ht, "Ivy", "TBL_SYNC_REQ", { rev = 0 }, NOW); eq(#out, 0, "pending players get nothing for a sync")
    out = C.Handle(ht, "Stranger", "TBL_SYNC_REQ", { rev = 0 }, NOW)
    eq(out[1].type, "TBL_JOIN_DENY", "strangers are told they are not seated"); eq(out[1].payload.reason, "not_seated", "reason"); valid(out)
    C.Admit(ht, "Ivy", 2000, NOW)
    out = C.Handle(ht, "Ivy", "TBL_JOIN", {}, NOW)
    eq(out[1].type, "TBL_JOIN_OK", "a seated player asking again is welcomed"); eq(out[2].type, "TBL_STATE", "with the state"); eq(out[3].type, "TBL_PLAYER", "and their chips")
    eq(out[1].payload.ownerName, "Steve", "JOIN_OK names the host"); eq(out[3].payload.balance, 2000, "balance"); valid(out)
    out = C.Handle(ht, "Ivy", "TBL_SYNC_REQ", { rev = 0 }, NOW); eq(#out, 3, "sync gives the same welcome"); valid(out)
    out, ev = C.Handle(ht, "Ivy", "TBL_BET", { ref = "q1", round = 1, bet = { kind = "red", amount = 500 } }, NOW)
    eq(out[1].type, "TBL_BET_OK", "bet accepted"); eq(out[1].payload.balance, 1500, "new balance"); eq(out[1].payload.betId, 1, "bet id"); eq(ev[1].kind, "bet", "bet event"); valid(out)
    out, ev = C.Handle(ht, "Ivy", "TBL_BET", { ref = "q1", round = 1, bet = { kind = "red", amount = 500 } }, NOW)
    eq(out[1].type, "TBL_BET_OK", "a retry is re-acknowledged"); eq(#ev, 0, "but not announced twice"); eq(ht.members.Ivy.balance, 1500, "and charged once")
    out = C.Handle(ht, "Ivy", "TBL_BET", { ref = "q2", round = 1, bet = { kind = "red", amount = 20000 } }, NOW)
    eq(out[1].type, "TBL_BET_REJECT", "rejected"); eq(out[1].payload.reason, "max_bet", "max_bet"); eq(out[1].payload.max, 10000, "with the limit"); valid(out)
    out = C.Handle(ht, "Ivy", "TBL_BET", { ref = "q3", round = 1, bet = { kind = "red", amount = 5000 } }, NOW)
    eq(out[1].payload.reason, "no_balance", "no_balance"); eq(out[1].payload.balance, 1500, "with the chips on hand"); valid(out)
    out = C.Handle(ht, "Ivy", "TBL_BET", { ref = "q4", round = 7, bet = { kind = "red", amount = 100 } }, NOW)
    eq(out[1].payload.reason, "round_closed", "stale round"); valid(out)
    out = C.Handle(ht, "Ivy", "TBL_BET", { ref = "q5", round = 1, bet = { kind = "bogus", amount = 100 } }, NOW)
    eq(out[1].payload.reason, "bad_bet", "bad bet"); valid(out)
    out = C.Handle(ht, "Ivy", "TBL_BET_CLEAR", { round = 1 }, NOW)
    eq(out[1].type, "TBL_PLAYER", "clearing answers with the truth"); eq(out[1].payload.balance, 2000, "chips back"); eq(#out[1].payload.bets, 0, "no bets"); valid(out)
    out = C.Handle(ht, "Stranger", "TBL_BET_CLEAR", { round = 1 }, NOW); eq(#out, 0, "strangers get nothing for a clear")
    C.PlaceBet(ht, "Ivy", 1, { kind = "straight", numbers = { 5 }, amount = 200 }, "w1")
    C.BeginSpin(ht, NOW); C.Finish(ht, 5, NOW)
    local rm = C.ResultMessage(ht); eq(rm.number, 5, "result message"); eq(rm.round, 1, "round"); valid({ { type = "TBL_RESULT", payload = rm } })
    valid({ { type = "TBL_STATE", payload = C.StateMessage(ht) } })
    eq(C.ResultMessage(assert(C.Create(db, { game = "roulette" }, "S", NOW, rand))), nil, "no result before the first spin")
    out, ev = C.Handle(ht, "Ivy", "TBL_LEAVE", {}, NOW)
    eq(out[1].type, "TBL_JOIN_DENY", "leaving answers with a deny"); eq(out[1].payload.reason, "left", "reason left"); eq(ev[1].kind, "left", "left event"); valid(out)
    out = C.Handle(ht, "Ivy", "TBL_JOIN", {}, NOW); eq(#out, 0, "a player who left must ask again (pending)")
    C.Kick(ht, "Ivy")
    out = C.Handle(ht, "Ivy", "TBL_JOIN", {}, NOW); eq(out[1].payload.reason, "removed", "kicked players are refused"); valid(out)
    C.Close(ht)
    out = C.Handle(ht, "Zoe", "TBL_JOIN", {}, NOW); eq(out[1].payload.reason, "closed", "closed table refuses"); valid(out)
end

if fails == 0 then print("casino: all passed") else os.exit(1) end
