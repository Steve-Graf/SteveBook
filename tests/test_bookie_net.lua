-- Run from repo root: lua5.1 tests/test_bookie_net.lua
-- Bookie message handling: every outbound message must pass Protocol.Wrap.
local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)
local Model = assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)
local Bookie = assert(loadfile("SteveBook/Bookie.lua"))("SteveBook", ns)
local Protocol = ns.Protocol

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; print("FAIL: " .. label) end
end
local function eq(got, want, label)
    check(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

local NOW, G = 1000, 100   -- G = 1 silver in copper; the max stake is 1g = 100 * G
local book = Model.CreateBook(Model.NewDB(), "NFL", "Steve", NOW)

-- Every outbound message must wrap cleanly (field names/types match Protocol.Spec).
local function valid(m, label)
    local env, err = Protocol.Wrap(m.type, book.code, m.payload)
    check(env ~= nil, label .. ": " .. m.type .. " invalid: " .. tostring(err))
    if env then
        local t = Protocol.Unwrap(env, "bookie")
        check(t == m.type, label .. ": " .. m.type .. " should unwrap as bookie->bettor")
    end
end
local function one(out, label)
    eq(#out, 1, label .. " (message count)")
    if out[1] then valid(out[1], label) end
    return out[1]
end

local function handle(sender, t, p, now)
    return Bookie.Handle(book, sender, t, p, now or NOW)
end

------------------------------------------------------------------------------------------
-- join + sync
------------------------------------------------------------------------------------------
do
    local out, ev = handle("Bob", "JOIN_REQ", {})
    eq(#out, 0, "pending join: no reply")
    check(#ev == 1 and ev[1].kind == "join_request" and ev[1].name == "Bob", "join_request event")
    out, ev = handle("Bob", "JOIN_REQ", {})
    check(#out == 0 and #ev == 0, "repeat request: no reply, no second event")

    out = handle("Bob", "SYNC_REQ", { rev = 0 })
    eq(#out, 0, "SYNC_REQ from pending member is ignored")
    local deny = one(handle("Mallory", "SYNC_REQ", { rev = 0 }), "SYNC_REQ from stranger")
    check(deny and deny.type == "JOIN_DENY" and deny.payload.reason == "not_member" and deny.to == "Mallory" and deny.payload.ownerName == "Steve", "stranger gets JOIN_DENY not_member naming the owner")

    Bookie.Approve(book, "Bob", NOW)
    local ok = one(handle("Bob", "JOIN_REQ", {}), "JOIN_REQ from active member")
    check(ok and ok.type == "JOIN_OK" and ok.to == "Bob" and ok.payload.bookName == "NFL" and ok.payload.ownerName == "Steve", "JOIN_OK contents")

    local m = assert(Bookie.AddMarket(book, { sport = "NFL", event = "PHI @ DAL", type = "moneyline",
        closesAt = NOW + 3600, selections = { { label = "PHI", odds = -150 }, { label = "DAL", odds = 130 } } }, NOW))
    local sync = one(handle("Bob", "SYNC_REQ", { rev = 0 }), "SYNC_REQ from active member")
    check(sync and sync.type == "SYNC" and sync.to == "Bob", "SYNC addressed to Bob")
    eq(sync.payload.bookName, "NFL", "SYNC bookName")
    eq(#sync.payload.markets, 1, "SYNC carries the open market")
    eq(sync.payload.balance, 0, "SYNC balance")
    eq(sync.payload.rev, book.rev, "SYNC rev")

    Bookie.Remove(book, "Bob")
    local gone = one(handle("Bob", "JOIN_REQ", {}), "JOIN_REQ from removed member")
    check(gone and gone.type == "JOIN_DENY" and gone.payload.reason == "removed" and gone.payload.ownerName == "Steve", "removed member denied, naming the owner")
    deny = one(handle("Bob", "SYNC_REQ", { rev = 0 }), "SYNC_REQ from removed member")
    check(deny and deny.payload.reason == "not_member", "removed member's SYNC_REQ denied as non-member")
    Bookie.Approve(book, "Bob", NOW)
end

------------------------------------------------------------------------------------------
-- betting
------------------------------------------------------------------------------------------
do
    Bookie.RequestJoin(book, "Alice", NOW); Bookie.Approve(book, "Alice", NOW)
    local function place(who, p) return handle(who, "BET_PLACE", p) end
    local base = { ref = "r1", marketId = 1, selectionId = 1, stake = 10 * G, odds = -150 }

    local out, ev = place("Bob", base)
    local ack = one(out, "BET_PLACE accepted")
    check(ack and ack.type == "BET_ACK" and ack.to == "Bob" and ack.payload.ref == "r1", "BET_ACK echoes ref")
    check(ack.payload.bet.id == 1 and ack.payload.bet.stake == 10 * G and ack.payload.bet.odds == -150, "BET_ACK carries the bet")
    eq(ack.payload.balance, 0, "BET_ACK balance")
    check(#ev == 1 and ev[1].kind == "bet", "bet event")

    out, ev = place("Bob", base)
    ack = one(out, "BET_PLACE retried (same ref)")
    check(ack and ack.type == "BET_ACK" and ack.payload.bet.id == 1, "retry re-acks the same bet")
    eq(#ev, 0, "retry does not raise a second bet event")
    local n = 0; for _ in pairs(book.bets) do n = n + 1 end
    eq(n, 1, "retry did not double-book")

    local function rejected(who, p, want, label)
        local o, e = place(who, p)
        local r = one(o, label)
        check(r and r.type == "BET_REJECT" and r.payload.reason == want and r.payload.ref == p.ref, label .. ": reason " .. tostring(r and r.payload.reason))
        check(#e == 1 and e[1].kind == "bet_rejected" and e[1].reason == want, label .. ": event")
        return r and r.payload
    end
    local function with(over)
        local t = {}
        for k, v in pairs(base) do t[k] = v end
        for k, v in pairs(over) do t[k] = v end
        return t
    end
    local p = rejected("Bob", with({ ref = "r2", odds = -140 }), "odds_changed", "stale odds")
    eq(p.currentOdds, -150, "odds_changed carries currentOdds")
    rejected("Bob", with({ ref = "r3", stake = 0 }), "bad_stake", "zero stake")
    rejected("Bob", with({ ref = "r4", marketId = 99 }), "no_market", "unknown market")
    rejected("Bob", with({ ref = "r5", selectionId = 9 }), "bad_selection", "unknown selection")
    rejected("Mallory", with({ ref = "r6" }), "not_member", "non-member")
    Bookie.Lock(book, 1)
    rejected("Bob", with({ ref = "r7" }), "market_closed", "locked market")
    Bookie.Unlock(book, 1, NOW)
    Bookie.SetCreditLimit(book, "Alice", 15 * G)
    p = rejected("Alice", with({ ref = "r8", stake = 20 * G }), "credit_limit", "over credit limit")
    eq(p.available, 15 * G, "credit_limit carries available")

    -- every reason PlaceBet can produce is a reason Protocol accepts
    for _, reason in ipairs({ "not_member", "no_market", "market_closed", "bad_selection", "bad_stake", "odds_changed", "credit_limit" }) do
        local found = false
        for _, v in ipairs(Protocol.REJECT_REASONS) do if v == reason then found = true end end
        check(found, "Protocol.REJECT_REASONS lists " .. reason)
    end
end

------------------------------------------------------------------------------------------
-- ping, market broadcast, settlement fan-out, balance notice
------------------------------------------------------------------------------------------
do
    local pong = one(handle("Bob", "PING", {}), "PING")
    check(pong and pong.type == "PONG" and pong.to == "Bob" and pong.payload.rev == book.rev, "PONG with rev")
    eq(#handle("Bob", "WAT", {}), 0, "unknown message type is ignored")

    local mm = Bookie.MarketMessage(book, book.markets[1])
    valid(mm, "market message")
    check(mm.type == "MARKET" and mm.to == nil and mm.payload.market == book.markets[1], "MARKET is a broadcast of the whole market")

    handle("Alice", "BET_PLACE", { ref = "a1", marketId = 1, selectionId = 2, stake = 5 * G, odds = 130 })
    local results = Bookie.Settle(book, 1, 1, NOW + 10)
    local names = Bookie.AffectedBettors(results)
    eq(table.concat(names, ","), "Alice,Bob", "affected bettors, sorted and distinct")
    local msgs = Bookie.SyncMessages(book, names, NOW + 10)
    eq(#msgs, 2, "one SYNC per affected bettor")
    for _, m in ipairs(msgs) do valid(m, "settlement SYNC to " .. tostring(m.to)) end
    eq(msgs[1].payload.balance, -5 * G, "Alice lost 5g")
    eq(msgs[2].payload.balance, 666, "Bob won floor(1000c * 100 / 150)")
    eq(msgs[2].payload.bets[1].status, "won", "Bob's bet shows won in his SYNC")
    eq(msgs[1].payload.markets[1].status, "settled", "settled market in SYNC")

    Bookie.Remove(book, "Alice")
    eq(#Bookie.SyncMessages(book, { "Alice", "Bob", "Nobody" }, NOW + 11), 1, "removed/unknown names get no SYNC")

    local bal = Bookie.BalanceMessage(book, "Bob", "Paid 1g")
    valid(bal, "balance message")
    check(bal.to == "Bob" and bal.payload.note == "Paid 1g" and bal.payload.balance == Bookie.Balance(book, "Bob"), "BALANCE contents")
end

if fails == 0 then print("bookie_net: all tests passed") else os.exit(1) end
