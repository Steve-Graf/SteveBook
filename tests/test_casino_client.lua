-- Run from repo root: luajit tests/test_casino_client.lua
local ns = {}
for _, f in ipairs({ "Odds", "Roulette", "Protocol", "CasinoClient" }) do assert(loadfile("SteveBook/" .. f .. ".lua"))("SteveBook", ns) end
local K = ns.CasinoClient
local fails = 0
local function eq(got, want, label)
    if got ~= want then fails = fails + 1; print(("FAIL: %s (got %s, want %s)"):format(label, tostring(got), tostring(want))) end
end

local db = {}
local store = K.Ensure(db)
eq(db.casinoCache, store, "Ensure creates the store")
local t = K.RequestJoin(store, "rltk7q2", 100)
eq(t.code, "RLT-K7Q2", "code canonicalised"); eq(t.status, "requested", "requested"); eq(K.Table(store, "RLT-K7Q2"), t, "same table")
eq(#K.List(store), 1, "listed")
eq(K.CanBet(t), false, "cannot bet before being seated")

K.ApplyJoinOk(store, "RLT-K7Q2", "Steve", { game = "roulette", name = "Friday", ownerName = "Steve", rev = 2 })
eq(t.status, "seated", "seated"); eq(t.owner, "Steve", "owner pinned"); eq(t.name, "Friday", "name"); eq(t.rev, 2, "rev")
eq(K.ApplyJoinOk(store, "NOP-AAAA", "x", { game = "roulette", name = "x", ownerName = "x", rev = 1 }), nil, "unknown table ignored")
eq(K.CanBet(t), false, "no state yet")

local state = { rev = 3, game = "roulette", name = "Friday", status = "betting", round = 4, minBet = 100, maxBet = 10000, zero = "single",
    seats = { { name = "Bob", balance = 500 } }, history = { 17, 0 } }
K.ApplyState(store, "RLT-K7Q2", state)
eq(t.state.round, 4, "state stored"); eq(t.state.seats[1].name, "Bob", "seats"); eq(t.state.history[1], 17, "history")
state.seats[1].name = "Changed"; eq(t.state.seats[1].name, "Bob", "state is a copy")
eq(K.CanBet(t), true, "can bet while betting")
eq(K.ApplyState(store, "RLT-K7Q2", { rev = 1, game = "roulette", name = "Old", status = "closed", round = 1, minBet = 100, maxBet = 100, seats = {}, history = {} }), nil, "an old state is ignored")
eq(t.state.status, "betting", "still betting")

K.ApplyPlayer(store, "RLT-K7Q2", { rev = 3, balance = 5000, bets = { { id = 1, kind = "red", amount = 500 } } })
eq(t.balance, 5000, "balance"); eq(#t.bets, 1, "one bet"); eq(K.Staked(t), 500, "staked")

K.NewPending(store, "RLT-K7Q2", "r1", { kind = "black", amount = 200 }, 100)
eq(K.Staked(t), 700, "pending counts as staked")
K.ApplyBetOk(store, "RLT-K7Q2", "r1", 2, 4800)
eq(#t.bets, 2, "the bet is confirmed"); eq(t.bets[2].id, 2, "with its id"); eq(t.balance, 4800, "new balance"); eq(next(t.pending), nil, "nothing pending")
K.NewPending(store, "RLT-K7Q2", "r2", { kind = "red", amount = 99900 }, 100)
local rejected = K.ApplyBetReject(store, "RLT-K7Q2", "r2", 4800)
eq(rejected.amount, 99900, "the rejected bet comes back"); eq(K.ApplyBetReject(store, "RLT-K7Q2", "r2"), nil, "unknown ref")
K.NewPending(store, "RLT-K7Q2", "r3", { kind = "red", amount = 100 }, 100)
eq(K.ExpirePending(store, "RLT-K7Q2", 110), 0, "not yet"); eq(K.ExpirePending(store, "RLT-K7Q2", 130), 1, "expired"); eq(K.Staked(t), 700, "staked again")

t.me = "Me"
K.ApplyResult(store, "RLT-K7Q2", { rev = 5, round = 4, number = 17, results = { { name = "Me", net = 1700, balance = 6500, bets = { { kind = "red", amount = 500, win = 0 } } }, { name = "Bob", net = -100, balance = 400, bets = {} } } })
eq(t.lastResult.number, 17, "result stored"); eq(#t.bets, 0, "bets cleared after the spin"); eq(t.balance, 6500, "my balance from the result")
eq(K.MyResult(t, "Me").net, 1700, "my result line"); eq(K.MyResult(t, "Zed"), nil, "no line when I did not bet")

K.ApplyState(store, "RLT-K7Q2", { rev = 6, game = "roulette", name = "Friday", status = "closed", round = 5, minBet = 100, maxBet = 100, seats = {}, history = {} })
eq(t.status, "closed", "a closed table closes my seat"); eq(K.CanBet(t), false, "cannot bet at a closed table")

local t2 = K.RequestJoin(store, "RLT-AAAA", 1)
K.ApplyJoinDeny(store, "RLT-AAAA", "denied"); eq(t2.status, "denied", "denied")
K.ApplyJoinDeny(store, "RLT-AAAA", "left"); eq(t2.status, "left", "left")
K.ApplyJoinDeny(store, "RLT-AAAA", "removed"); eq(t2.status, "removed", "removed")
K.ApplyJoinDeny(store, "RLT-AAAA", "closed"); eq(t2.status, "closed", "closed")
eq(K.RequestJoin(store, "RLT-AAAA", 5).status, "requested", "asking again restarts the request")
K.Forget(store, "RLT-AAAA"); eq(K.Table(store, "RLT-AAAA"), nil, "forgotten")

-- a TBL_PLAYER that arrives while a bet is waiting must not lose it, nor double-count it
do
    local t3 = K.RequestJoin(store, "RLT-RACE", 1)
    K.ApplyJoinOk(store, "RLT-RACE", "Steve", { game = "roulette", name = "R", ownerName = "Steve", rev = 1 })
    K.ApplyPlayer(store, "RLT-RACE", { rev = 1, balance = 1000, bets = {} })
    K.NewPending(store, "RLT-RACE", "q1", { kind = "red", amount = 100 }, 5)
    K.ApplyPlayer(store, "RLT-RACE", { rev = 2, balance = 1000, bets = {} })        -- an older snapshot arrives first
    eq(K.Staked(t3), 100, "the waiting bet survives a snapshot")
    K.ApplyBetOk(store, "RLT-RACE", "q1", 7, 900)
    eq(#t3.bets, 1, "then the OK confirms it"); eq(t3.bets[1].id, 7, "with its id")
    K.NewPending(store, "RLT-RACE", "q2", { kind = "black", amount = 100 }, 6)
    K.ApplyPlayer(store, "RLT-RACE", { rev = 3, balance = 800, bets = { { id = 7, kind = "red", amount = 100 }, { id = 8, kind = "black", amount = 100 } } })
    K.ApplyBetOk(store, "RLT-RACE", "q2", 8, 800)
    eq(#t3.bets, 2, "a snapshot that already lists the bet is not doubled by its OK")
end

if fails == 0 then print("casino_client: all passed") else os.exit(1) end
