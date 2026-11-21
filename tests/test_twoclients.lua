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

local function run(a, b, seconds)
    for _ = 1, seconds do
        for _, c in ipairs({ a, b }) do
            c.stub.advance(1); c.stub.runAfters(); c.stub.runTickers()
        end
        pump(a, b); pump(b, a)
    end
end

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
        assert(CNf.Wager(t.code, 500))
        run(host, friend, 6)
        local m = t.members[pending[1]]
        eq(m and #m.bets, 1, label .. ": the host has the friend's bet")
        eq(next(seat.pending), nil, label .. ": and the friend's bet is confirmed")
        -- the host deals; the friend decides
        host.env.math.random = math.random
        local ok, err = CNh.Deal(t)
        run(host, friend, 6)
        eq(t.status == "playing" or t.status == "dealer" or t.status == "results" or t.status == "betting", true, label .. ": the round runs")
    end
end

scenario("same realm, plain names", "Steve", "Tester")
scenario("two-word names", "Steve lol", "Tester lol")
scenario("other realm, two-word names", "Steve lol-Other Realm", "Tester lol-Other Realm")

if fails == 0 then realPrint("twoclients: all passed") else os.exit(1) end
