-- Two separate addon instances (a host and a friend), each with its own fake game, and the real wire
-- messages passed between them (every message goes out on both GUILD and CHANNEL, so both copies are
-- delivered). Everything else in the suite has one client talking to itself; this is the test that
-- catches "works alone, never seats the other player".
-- Run from repo root: luajit tests/test_twoclients.lua
local realPrint = print
local fails = 0
local function check(cond, label) if not cond then fails = fails + 1; realPrint("FAIL: " .. label) end end
local function eq(a, b, label) if a ~= b then fails = fails + 1; realPrint(("FAIL: %s (got %s, want %s)"):format(label, tostring(a), tostring(b))) end end

local function readFile(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end

-- One client: its own globals (so its own libraries, saved variables and fake game).
local function newClient(player, seenAs)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local chunk = assert(loadfile("tests/wowstub.lua"))
    setfenv(chunk, env)
    local stub = chunk()
    stub.player = player
    env.Minimap = stub.newFrame()
    env.Ambiguate = function(name) return (name:gsub("%-Realm$", "")) end
    env.IsInGuild = function() return true end
    local ns = {}
    local loadFile
    local function loadXml(path)
        local dir = path:match("^(.*)/[^/]*$") or "."
        for file in readFile(path):gmatch('<[SI][a-z]+%s+file="([^"]+)"') do loadFile(dir .. "/" .. file:gsub("\\", "/")) end
    end
    function loadFile(path)
        path = path:gsub("\\", "/")
        if path:match("%.xml$") then return loadXml(path) end
        local f = assert(loadfile(path)); setfenv(f, env)
        local ok, e = pcall(f, "SteveBook", ns)
        check(ok, player .. " loads " .. path .. (ok and "" or (": " .. tostring(e))))
    end
    for line in readFile("SteveBook/SteveBook.toc"):gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then loadFile("SteveBook/" .. line) end
    end
    stub.fire("ADDON_LOADED", "SteveBook")
    return { env = env, stub = stub, ns = ns, name = player, seenAs = seenAs, cursor = 0, db = env.SteveBookDB }
end

-- Deliver what `from` has sent since the last call to `to`, as the game would: the sender's name as
-- `from.seenAs`, once per distribution the message went out on.
local function pump(from, to)
    local list = from.stub.addonMessages
    for i = from.cursor + 1, #list do
        local m = list[i]
        if m.chatType == "GUILD" or m.chatType == "CHANNEL" then
            to.stub.fire("CHAT_MSG_ADDON", m.prefix, m.text, m.chatType, from.seenAs)
        end
    end
    from.cursor = #list
end

-- Each ticker fires at its own interval (not every simulated second), so traffic counts are honest.
local function runTickers(c)
    c.clock = (c.clock or 0) + 1
    for _, t in ipairs(c.stub.tickers) do
        if not t.cancelled and c.clock % math.max(1, math.floor(t.interval)) == 0 then t.fn(t) end
    end
end

local function run(a, b, seconds)
    for _ = 1, seconds do
        for _, c in ipairs({ a, b }) do
            c.stub.advance(1); c.stub.runAfters(); runTickers(c)
        end
        pump(a, b); pump(b, a)
    end
end

local function sent(c) return #c.stub.addonMessages end

local function scenario(label, hostSeenAs, friendSeenAs)
    local host = newClient("Steve", hostSeenAs)       -- what the FRIEND's game calls the host
    local friend = newClient("Tester", friendSeenAs)  -- what the HOST's game calls the friend
    local CNh, CNf = host.ns.CasinoNet, friend.ns.CasinoNet

    local t = assert(CNh.Create({ game = "blackjack", name = "Friday", minBet = 100, maxBet = 10000 }), label)
    run(host, friend, 3)
    local tc = assert(CNf.RequestJoin(t.code), label)
    run(host, friend, 4)
    local pending = host.ns.Casino.Pending(t)
    eq(#pending, 1, label .. ": the host sees the friend's request")
    if #pending == 1 then
        assert(CNh.Admit(t, pending[1], 5000))
        run(host, friend, 6)
    end
    local seat = friend.db.casinoCache.tables[t.code]
    eq(seat and seat.status, "seated", label .. ": the friend is seated after the host lets them in")
    check(seat and seat.state ~= nil, label .. ": and has received the table")
    eq(seat and seat.balance, 5000, label .. ": and has the chips")

    -- a bet reaches the host
    if seat and seat.status == "seated" and seat.state then
        local before = sent(host) + sent(friend)
        assert(CNf.Wager(t.code, 500))
        run(host, friend, 6)
        local m = t.members[pending[1]]
        eq(m and #m.bets, 1, label .. ": the host has the friend's bet")
        eq(next(seat.pending), nil, label .. ": and the friend's bet is confirmed")
        -- the host deals; the friend decides
        host.env.math.random = math.random
        local ok, err = CNh.Deal(t)
        run(host, friend, 6)
        -- traffic: the game allows about one message a second per prefix, so a bet and a deal must be cheap
        local used = sent(host) + sent(friend) - before
        realPrint(("  [%s] bet + deal: %d addon messages in 12 s"):format(label, used))
        check(used <= 9, label .. ": a bet and a deal stay within a small message budget (" .. used .. ")")
        eq(t.status == "playing" or t.status == "dealer" or t.status == "results" or t.status == "betting", true, label .. ": the round runs")
    end
end

scenario("same realm, plain names", "Steve", "Tester")
scenario("two-word names", "Steve lol", "Tester lol")
scenario("other realm, two-word names", "Steve lol-Other Realm", "Tester lol-Other Realm")

-- Three players at one table (host + two friends): everyone is seated, bets, plays in turn, and the
-- round finishes with everyone seeing the result.
local function runAll(clients, seconds)
    for _ = 1, seconds do
        for _, c in ipairs(clients) do c.stub.advance(1); c.stub.runAfters(); runTickers(c) end
        for i, a in ipairs(clients) do
            for j, b in ipairs(clients) do if i ~= j then pump2(a, b, i, j) end end
        end
    end
end

local function threePlayers()
    local label = "three players"
    local host = newClient("Steve", "Steve")
    local f1 = newClient("Ann", "Ann")
    local f2 = newClient("Bob", "Bob")
    local all = { host, f1, f2 }
    -- each pair needs its own cursor: a message is delivered to every other client
    for _, c in ipairs(all) do c.cursors = {} end
    function pump2(from, to, i, j)
        local list = from.stub.addonMessages
        local cur = from.cursors[j] or 0
        for k = cur + 1, #list do
            local m = list[k]
            if m.chatType == "GUILD" or m.chatType == "CHANNEL" then
                to.stub.fire("CHAT_MSG_ADDON", m.prefix, m.text, m.chatType, from.seenAs)
            end
        end
        from.cursors[j] = #list
    end
    local t = assert(host.ns.CasinoNet.Create({ game = "blackjack", name = "Three", minBet = 100, maxBet = 10000 }))
    runAll(all, 3)
    for _, f in ipairs({ f1, f2 }) do assert(f.ns.CasinoNet.RequestJoin(t.code)) end
    runAll(all, 5)
    local pending = host.ns.Casino.Pending(t)
    eq(#pending, 2, label .. ": the host sees both requests")
    for _, name in ipairs(pending) do assert(host.ns.CasinoNet.Admit(t, name, 5000)) end
    runAll(all, 8)
    for _, f in ipairs({ f1, f2 }) do
        local seat = f.db.casinoCache.tables[t.code]
        eq(seat and seat.status, "seated", label .. ": " .. f.name .. " is seated")
        check(seat and seat.state ~= nil, label .. ": " .. f.name .. " has the table")
        eq(seat and seat.balance, 5000, label .. ": " .. f.name .. " has the chips")
    end
    local before = 0
    for _, c in ipairs(all) do before = before + sent(c) end
    for _, f in ipairs({ f1, f2 }) do assert(f.ns.CasinoNet.Wager(t.code, 500)) end
    runAll(all, 8)
    for _, f in ipairs({ f1, f2 }) do
        local seat = f.db.casinoCache.tables[t.code]
        eq(next(seat.pending), nil, label .. ": " .. f.name .. "'s bet is confirmed")
    end
    assert(host.ns.CasinoNet.Deal(t))
    runAll(all, 6)
    -- play it out: whoever's turn it is stands
    for _ = 1, 8 do
        for _, f in ipairs({ f1, f2 }) do
            local seat = f.db.casinoCache.tables[t.code]
            if f.ns.CasinoClient.MyTurn(seat, f.name) and not f.ns.CasinoClient.ActPending(seat) then f.ns.CasinoNet.Act(t.code, "stand") end
        end
        runAll(all, 4)
    end
    runAll(all, 20)
    local round = t.round
    check(round >= 2 or t.status == "betting" or t.status == "results", label .. ": the round finished (status " .. tostring(t.status) .. ", round " .. round .. ")")
    local used = -before
    for _, c in ipairs(all) do used = used + sent(c) end
    realPrint(("  [%s] 2 bets + deal + 2 players + results: %d addon messages"):format(label, used))
    check(used <= 60, label .. ": a whole round stays within a modest message budget (" .. used .. ")")
    for _, f in ipairs({ f1, f2 }) do
        local seat = f.db.casinoCache.tables[t.code]
        check(seat.lastResult ~= nil or (seat.state and seat.state.round >= 2), label .. ": " .. f.name .. " saw the round finish")
    end
end
threePlayers()

-- The game's limit: about one addon message a second per prefix once the burst of 10 is spent. Measure how
-- long the things a player waits for take with that limit on, for a table with two friends.
local function lagTest()
    local label = "rate-limited"
    local host = newClient("Steve", "Steve")
    local f1 = newClient("Ann", "Ann")
    local f2 = newClient("Bob", "Bob")
    local all = { host, f1, f2 }
    for _, c in ipairs(all) do
        c.cursors = {}
        c.stub.addonBudget = { tokens = 10, burst = 10, rate = 1, last = c.stub.mono }
    end
    local function deliver(from, to, j)
        local list = from.stub.addonMessages
        for k = (from.cursors[j] or 0) + 1, #list do
            local m = list[k]
            if m.chatType == "GUILD" or m.chatType == "CHANNEL" then
                to.stub.fire("CHAT_MSG_ADDON", m.prefix, m.text, m.chatType, from.seenAs)
            end
        end
        from.cursors[j] = #list
    end
    local function step(seconds, untilFn)
        for n = 1, seconds do
            for _, c in ipairs(all) do c.stub.advance(1); c.stub.runAfters(); runTickers(c) end
            for i, a in ipairs(all) do for j, b in ipairs(all) do if i ~= j then deliver(a, b, j) end end end
            if untilFn and untilFn() then return n end
        end
        return seconds
    end
    local t = assert(host.ns.CasinoNet.Create({ game = "blackjack", name = "Laggy?", minBet = 100, maxBet = 10000 }))
    step(20)                                              -- a quiet minute of announcements, as at a real table
    for _, f in ipairs({ f1, f2 }) do assert(f.ns.CasinoNet.RequestJoin(t.code)) end
    step(6)
    for _, name in ipairs(host.ns.Casino.Pending(t)) do assert(host.ns.CasinoNet.Admit(t, name, 5000)) end
    local function seatedWithTable(f) local seat = f.db.casinoCache.tables[t.code]; return seat and seat.status == "seated" and seat.state ~= nil end
    local took = step(40, function() return seatedWithTable(f1) and seatedWithTable(f2) end)
    realPrint(("  [%s] admitted -> both friends seated with the table: %d s"):format(label, took))
    check(seatedWithTable(f1) and seatedWithTable(f2), label .. ": both friends get seated")
    check(took <= 8, label .. ": ...within 8 s of being let in (" .. took .. ")")

    for _, f in ipairs({ f1, f2 }) do assert(f.ns.CasinoNet.Wager(t.code, 500)) end
    took = step(40, function()
        for _, f in ipairs({ f1, f2 }) do if next(f.db.casinoCache.tables[t.code].pending) then return false end end
        return true
    end)
    realPrint(("  [%s] both bet -> both confirmed: %d s"):format(label, took))
    check(took <= 8, label .. ": bets are confirmed within 8 s (" .. took .. ")")

    assert(host.ns.CasinoNet.Deal(t))
    took = step(40, function()
        for _, f in ipairs({ f1, f2 }) do
            local seat = f.db.casinoCache.tables[t.code]
            if not (seat.state and seat.state.status ~= "betting") then return false end
        end
        return true
    end)
    realPrint(("  [%s] deal -> both see the deal: %d s"):format(label, took))
    check(took <= 8, label .. ": the deal reaches everyone within 8 s (" .. took .. ")")

    -- a player's move: click -> the table shows it, while the others are also waiting on their turn
    local movers = 0
    local worst = 0
    for round = 1, 4 do
        for _, f in ipairs({ f1, f2 }) do
            local seat = f.db.casinoCache.tables[t.code]
            if f.ns.CasinoClient.MyTurn(seat, f.name) then
                local revBefore = seat.state.rev
                assert(f.ns.CasinoNet.Act(t.code, "stand"))
                local n = step(30, function() return (seat.state.rev or 0) > revBefore end)
                worst = math.max(worst, n); movers = movers + 1
            end
        end
        step(2)
    end
    realPrint(("  [%s] a move (%d of them): the table updates in at most %d s"):format(label, movers, worst))
    check(movers >= 1, label .. ": players got to move")
    check(worst <= 5, label .. ": a move shows up within 5 s (" .. worst .. ")")
    realPrint(("  [%s] messages the game refused for being too fast: host %d, Ann %d, Bob %d"):format(label,
        host.stub.addonBudget.refused or 0, f1.stub.addonBudget.refused or 0, f2.stub.addonBudget.refused or 0))
end
lagTest()

if fails == 0 then realPrint("twoclients: all passed") else os.exit(1) end
