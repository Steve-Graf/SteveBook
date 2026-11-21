-- Comm.lua against the REAL vendored AceComm / ChatThrottleLib / AceSerializer / CallbackHandler,
-- on top of tests/wowstub.lua (unmodified; a few globals are overridden below). The real
-- UI/Bettor.lua handlers are loaded too, for the forged-message check.
-- Covers: LeaveBook stops rejoin attempts, give-up after repeated join failures and the join
-- rate limit, message priorities (SendCommMessage args and real wire order), queue then flush once
-- the channel is up, multi-part round trip, owner/bettor routing, the channel-notice filter and
-- hiding, login join delay, Serialize failures, and forged whispered "bookie" messages (Comm
-- delivers them; the Bettor's handlers must ignore them).
-- Run from repo root: luajit tests/test_comm.lua   (or lua5.1)
local stub = assert(loadfile("tests/wowstub.lua"))()
local out_ = stub.realPrint

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; out_("FAIL: " .. label) end
end
local function eq(got, want, label)
    check(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

local DIR = "SteveBook/"
stub.player = "Tester"

-- ---- what the real client has and the stub does not (or does differently) -----------------------
-- AceComm binds Ambiguate when it loads. The stub realm is "Realm".
Ambiguate = function(name) return (name:gsub("%-Realm$", "")) end
C_ChatInfo.SendAddonMessageLogged = function() return 0 end

-- Channel joins are asynchronous: remember the call; a test "completes" the join by setting
-- stub.channels[name] itself.
local joinCalls = {}
JoinTemporaryChannel = function(name) joinCalls[#joinCalls + 1] = { name = name, at = stub.mono } end
local function joinsFor(chan)
    local n = 0
    for _, c in ipairs(joinCalls) do if c.name == chan then n = n + 1 end end
    return n
end

-- Comm captures these two at load time.
local filters, removed = {}, {}
ChatFrame_AddMessageEventFilter = function(event, fn) filters[event] = fn end
ChatFrame_RemoveChannel = function(_, name) removed[#removed + 1] = name end
local added = {}                                      -- channels put (back) on the chat window
ChatFrame_AddChannel = function(_, name) added[#added + 1] = name end

-- ---- load the libs and the addon files in .toc order --------------------------------------------
for _, p in ipairs({ "Libs/LibStub/LibStub.lua", "Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
                     "Libs/AceComm-3.0/ChatThrottleLib.lua", "Libs/AceComm-3.0/AceComm-3.0.lua",
                     "Libs/AceSerializer-3.0/AceSerializer-3.0.lua", "Libs/LibDeflate/LibDeflate.lua" }) do
    assert(loadfile(DIR .. p))()
end
local ns = {}
for _, p in ipairs({ "Odds", "Protocol", "Model", "Bookie", "Import", "Cache", "Slip", "Comm", "UI/Bettor" }) do
    local chunk = assert(loadfile(DIR .. p .. ".lua"))
    local ok, err = pcall(chunk, "SteveBook", ns)
    check(ok, "load " .. p .. ": " .. tostring(err))
end
local Comm, Protocol, Model, Cache = ns.Comm, ns.Protocol, ns.Model, ns.Cache
local AceSer = LibStub("AceSerializer-3.0")

SteveBookDB = Model.NewDB()
SteveBookDB.cache = Cache.NewStore()

-- ---- helpers ---------------------------------------------------------------------------------------
-- Advance time in 0.1s steps (ChatThrottleLib despools from OnUpdate). Once a second, run only
-- Comm's flush ticker (interval 1); the Bettor's 30s ping ticker stays idle.
local function flushTickers()
    for _, t in ipairs(stub.tickers) do
        if t.interval == 1 and not t.cancelled then t.fn(t) end
    end
end
local function tick(seconds)
    for i = 1, math.floor(seconds * 10 + 0.5) do
        stub.advance(0.1)
        if i % 10 == 0 then flushTickers() end
    end
end
local function activeFlushTickers()
    local n = 0
    for _, t in ipairs(stub.tickers) do if t.interval == 1 and not t.cancelled then n = n + 1 end end
    return n
end
local function printed(pattern)
    local n = 0
    for _, line in ipairs(stub.printed) do if line:find(pattern) then n = n + 1 end end
    return n
end

-- Describe a captured C_ChatInfo.SendAddonMessage call without ever throwing, so a malformed
-- capture is reported with its fields instead of aborting the whole test.
local function describeMsg(m)
    if type(m) ~= "table" then return "a " .. type(m) .. " (" .. tostring(m):sub(1, 40) .. ")" end
    return ("table{prefix=%s, text=%s, chatType=%s, target=%s}"):format(
        tostring(m.prefix), m.text == nil and "nil" or ("string(" .. #tostring(m.text) .. ")"),
        tostring(m.chatType), tostring(m.target))
end
-- The text of a captured message, or nil (after recording a failure) if it has none.
local function textOf(m, i)
    if type(m) == "table" and type(m.text) == "string" then return m.text end
    check(false, "captured addon message " .. tostring(i) .. " has no text: " .. describeMsg(m))
    return nil
end

-- Deliver one addon message to AceComm exactly as the client would (CHAT_MSG_ADDON).
local function deliver(sender, msgType, code, payload, dist)
    local env = assert(Protocol.Wrap(msgType, code, payload))
    local text = AceSer:Serialize(env)
    assert(#text <= 254, "single-part message expected, got " .. #text .. " bytes")
    stub.fire("CHAT_MSG_ADDON", "SteveBook", text, dist or "WHISPER", sender)
end

-- Probes: record what Comm hands to handlers (registered after the Bettor's own handlers).
local seen = {}
local function probe(msgType)
    Comm.Register(msgType, function(sender, payload, code)
        seen[#seen + 1] = { type = msgType, sender = sender, payload = payload, code = code }
    end)
end
for _, t in ipairs({ "JOIN_REQ", "SYNC_REQ", "BET_PLACE", "PING", "MARKET", "SYNC", "BET_ACK", "BALANCE", "JOIN_OK", "JOIN_DENY", "PONG" }) do probe(t) end
local function drainSeen() local s = seen; seen = {}; return s end

-- let ChatThrottleLib's start-up throttling pass
tick(10)

------------------------------------------------------------------------------------------
-- 1. priorities reach SendCommMessage
------------------------------------------------------------------------------------------
do
    local spy = {}
    local orig = Comm.SendCommMessage
    Comm.SendCommMessage = function(self, prefix, text, dist, target, prio)
        spy[#spy + 1] = { prefix = prefix, dist = dist, target = target, prio = prio }
        return orig(self, prefix, text, dist, target, prio)
    end
    local P = {
        JOIN_OK = { bookName = "X", ownerName = "Tester", rev = 1 },
        JOIN_DENY = { ownerName = "Tester", reason = "denied" },
        BET_ACK = { ref = "r", bet = {} },
        BET_REJECT = { ref = "r", reason = "odds_changed", currentOdds = -120 },
        PING = {}, PONG = { rev = 1 },
        SYNC = { rev = 1, bookName = "X", markets = {}, bets = {}, balance = 0 },
        MARKET = { rev = 1, market = {} },
        BALANCE = { rev = 1, balance = 0 },
        JOIN_REQ = {}, SYNC_REQ = { rev = 0 },
        BET_PLACE = { ref = "r", marketId = 1, selectionId = 1, stake = 100, odds = -110 },
    }
    local want = { JOIN_OK = "ALERT", JOIN_DENY = "ALERT", BET_ACK = "ALERT", BET_REJECT = "ALERT",
                   PING = "ALERT", PONG = "ALERT", SYNC = "BULK" }
    stub.channels[Protocol.ChannelName("PRI-0001")] = 7         -- the channel is up
    for msgType, payload in pairs(P) do
        spy = {}
        local ok, err = Comm.Send(msgType, payload, "PRI-0001", "Bob")        -- addressed to Bob, on the channel
        check(ok == true, msgType .. " sent: " .. tostring(err))
        check(#spy == 1 and spy[1].dist == "CHANNEL" and spy[1].target == 7, msgType .. " went out on the channel, never as a WHISPER")
        eq(spy[1] and spy[1].prio, want[msgType], msgType .. " priority")
        eq(spy[1] and spy[1].prefix, "SteveBook", msgType .. " prefix")
    end
    Comm.SendCommMessage = orig
end

------------------------------------------------------------------------------------------
-- 2. real wire order: a BET_ACK must not wait behind a big SYNC
------------------------------------------------------------------------------------------
do
    stub.addonMessages = {}
    stub.channels[Protocol.ChannelName("ORD-0001")] = 9
    Comm.Compress = false      -- this test is about chunk order, so keep the SYNC big
    local markets = {}
    for i = 1, 40 do
        markets[i] = { id = i, sport = "NFL", event = "Team" .. i .. " @ Other" .. i, type = "spread", line = -3.5,
            selections = { { id = 1, label = "A" .. i, odds = -110 }, { id = 2, label = "B" .. i, odds = -110 } },
            closesAt = 1700000000 + i, status = "open" }
    end
    Comm.Send("SYNC", { rev = 9, bookName = "Big", markets = markets, bets = {}, balance = 0 }, "ORD-0001", "Bob")
    Comm.Send("BET_ACK", { ref = "r1", bet = { id = 1 } }, "ORD-0001", "Bob")
    tick(90)
    local n, iAck = #stub.addonMessages, nil
    for i, m in ipairs(stub.addonMessages) do
        local text = textOf(m, i)
        if text then
            check(#text <= 255, "chunk " .. i .. " is within 255 bytes")
            if text:find("BET_ACK", 1, true) then iAck = i end
        end
    end
    check(n >= 25, "the SYNC was split into many parts: " .. n)
    check(iAck ~= nil, "the BET_ACK was sent")
    check(iAck and iAck <= n - 10, "BET_ACK jumps ahead of the SYNC's remaining chunks (position " .. tostring(iAck) .. " of " .. n .. ")")
end

Comm.Compress = true

------------------------------------------------------------------------------------------
-- 3. join is asynchronous: queue, rate-limit joins, flush once the channel is up
------------------------------------------------------------------------------------------
do
    local code = "NFL-QQQQ"
    local chan = Protocol.ChannelName(code)
    joinCalls = {}
    stub.addonMessages = {}
    for i = 1, 10 do
        local ok, how = Comm.Send("MARKET", { rev = i, market = { id = i } }, code)
        check(ok == true and how == "queued", "send " .. i .. " queued while the channel is not up")
    end
    eq(joinsFor(chan), 1, "ten sends in the same second make one join attempt")
    eq(#stub.addonMessages, 0, "nothing sent before the channel exists")
    check(activeFlushTickers() == 1, "a flush ticker is running")
    stub.channels[chan] = 7                       -- the join completes
    tick(3)
    local ours = {}
    for _, m in ipairs(stub.addonMessages) do if m.chatType == "CHANNEL" then ours[#ours + 1] = m end end
    eq(#ours, 10, "all ten queued messages were sent once the channel was up")
    eq(ours[1] and ours[1].target, 7, "...to the channel number")
    eq(joinsFor(chan), 1, "no further join attempts once it is up")
    eq(activeFlushTickers(), 0, "the flush ticker stops when the queue is empty")
    -- and a later send goes straight out
    stub.addonMessages = {}
    local ok, how = Comm.Send("MARKET", { rev = 99, market = { id = 99 } }, code)
    check(ok == true and how == nil and #stub.addonMessages == 1, "a send with the channel up is immediate")
    stub.channels[chan] = nil
end

------------------------------------------------------------------------------------------
-- 4. LeaveBook stops rejoin attempts and drops the queue
------------------------------------------------------------------------------------------
do
    local code = "NBA-LEAV"
    local chan = Protocol.ChannelName(code)
    joinCalls = {}
    stub.addonMessages = {}
    Comm.Send("MARKET", { rev = 1, market = { id = 1 } }, code)
    eq(joinsFor(chan), 1, "first send tries to join")
    Comm.LeaveBook(code)
    tick(60)
    eq(joinsFor(chan), 1, "no join attempts after LeaveBook (60s later)")
    eq(activeFlushTickers(), 0, "the flush ticker is gone")
    stub.channels[chan] = 9                       -- even if the channel later appears...
    tick(5)
    eq(#stub.addonMessages, 0, "...the queued messages were dropped, not sent")
    stub.channels[chan] = nil
end

------------------------------------------------------------------------------------------
-- 5. a channel that never joins: bounded retries, spaced out, then give up
------------------------------------------------------------------------------------------
do
    local code = "MLB-FAIL"
    local chan = Protocol.ChannelName(code)
    joinCalls = {}
    stub.addonMessages = {}
    stub.printed = {}
    Comm.Send("MARKET", { rev = 1, market = { id = 1 } }, code)
    Comm.Send("MARKET", { rev = 2, market = { id = 2 } }, code)
    tick(60)
    local mine = {}
    for _, c in ipairs(joinCalls) do if c.name == chan then mine[#mine + 1] = c end end
    check(#mine >= 2 and #mine <= 6, "a few join attempts, not one per second: " .. #mine)
    for i = 2, #mine do
        check(mine[i].at - mine[i - 1].at >= 4.99, "attempts are at least 5s apart (gap " .. string.format("%.1f", mine[i].at - mine[i - 1].at) .. ")")
    end
    eq(printed("Could not join the channel for book MLB%-FAIL"), 1, "one chat warning")
    check(printed("2 message%(s%) were dropped") == 1, "the warning counts the dropped messages")
    local at60 = #mine
    tick(120)
    local after = 0
    for _, c in ipairs(joinCalls) do if c.name == chan then after = after + 1 end end
    eq(after, at60, "no attempts after giving up")
    eq(activeFlushTickers(), 0, "the flush ticker is gone")
    stub.channels[chan] = 3                       -- later the channel works...
    tick(5)
    eq(#stub.addonMessages, 0, "...but the dropped queue is not resurrected")
    -- a fresh send after giving up starts over
    stub.channels[chan] = nil
    joinCalls = {}
    Comm.Send("MARKET", { rev = 3, market = { id = 3 } }, code)
    check(joinsFor(chan) >= 1, "a new send after giving up tries again")
    Comm.LeaveBook(code)
end

------------------------------------------------------------------------------------------
-- 6. round trip of a multi-part message through AceComm's reassembly
------------------------------------------------------------------------------------------
do
    local code = "RND-TRIP"
    stub.addonMessages = {}
    local markets = {}
    for i = 1, 31 do
        markets[i] = { id = i, event = "Game " .. i, type = "moneyline",
            selections = { { id = 1, label = "A", odds = -150 }, { id = 2, label = "B", odds = 130 } }, status = "open" }
    end
    stub.channels[Protocol.ChannelName(code)] = 8
    Comm.Send("SYNC", { rev = 5, bookName = "Round", markets = markets, bets = {}, balance = -250, creditLimit = 50000 }, code, "Tester")
    tick(60)
    local parts = stub.addonMessages
    local plain = #AceSer:Serialize(assert(Protocol.Wrap("SYNC", code, { rev = 5, bookName = "Round", markets = markets, bets = {}, balance = -250, creditLimit = 50000 })))
    local wireBytes = 0
    for _, m in ipairs(parts) do wireBytes = wireBytes + #(m.text or "") end
    check(wireBytes * 4 < plain, ("compression shrinks the SYNC at least 4x (%d plain, ~%d on the wire)"):format(plain, wireBytes))
    check(#parts >= 1 and #parts < 10, "the compressed SYNC goes out in few parts: " .. #parts)
    drainSeen()
    -- feed them back as another client's channel message addressed to us (we do not own the code)
    for i, m in ipairs(parts) do
        local text = textOf(m, i)
        if text then stub.fire("CHAT_MSG_ADDON", m.prefix, text, "CHANNEL", "Real-Realm") end
    end
    local got = drainSeen()
    eq(#got, 1, "reassembled into exactly one delivery")
    local s = got[1]
    check(s and s.type == "SYNC" and s.sender == "Real" and s.code == code, "SYNC from Real (same-realm suffix stripped)")
    check(s and #s.payload.markets == 31 and s.payload.markets[31].event == "Game 31", "all 31 markets arrived intact")
    check(s and s.payload.balance == -250 and s.payload.creditLimit == 50000 and s.payload.bookName == "Round", "scalar fields arrived intact")
end

------------------------------------------------------------------------------------------
-- 7. routing: owner vs bettor, own echo, cross-realm names
------------------------------------------------------------------------------------------
do
    local mine = assert(Model.CreateBook(SteveBookDB, "Mine", "Tester", stub.time))       -- I run this book
    local theirs = "THE-IRS1"                                                           -- I am a bettor here
    Cache.RequestJoin(SteveBookDB.cache, theirs)
    drainSeen()
    deliver("Bob-Realm", "JOIN_REQ", mine.code, {}, "CHANNEL")
    local s = drainSeen()
    check(#s == 1 and s[1].type == "JOIN_REQ" and s[1].sender == "Bob", "owner gets a bettor's JOIN_REQ for its own book")
    deliver("Bob-Realm", "JOIN_REQ", theirs, {}, "CHANNEL")
    eq(#drainSeen(), 0, "a bettor->bookie message for a book I only belong to is dropped")
    deliver("Real-Realm", "MARKET", theirs, { rev = 1, market = { id = 1 } }, "CHANNEL")
    s = drainSeen()
    check(#s == 1 and s[1].type == "MARKET", "a bookie message for a book I belong to is delivered")
    deliver("Real-Realm", "MARKET", mine.code, { rev = 1, market = { id = 1 } }, "CHANNEL")
    eq(#drainSeen(), 0, "a bookie->bettor message for a book I run is dropped")
    deliver("Tester-Realm", "JOIN_REQ", mine.code, {}, "CHANNEL")
    eq(#drainSeen(), 0, "my own echoed message is dropped (even with my realm suffix)")
    deliver("Zed-OtherRealm", "JOIN_REQ", mine.code, {}, "CHANNEL")
    s = drainSeen()
    check(#s == 1 and s[1].sender == "Zed-OtherRealm", "a cross-realm sender keeps its realm: " .. tostring(s[1] and s[1].sender))
    deliver("Bob-Realm", "PING", mine.code, {}, "CHANNEL")
    deliver("Bob-Realm", "PING", theirs, {}, "CHANNEL")
    eq(#drainSeen(), 2, "PING (either direction) is delivered for every book")
    stub.channels[Protocol.ChannelName(mine.code)] = nil
end

------------------------------------------------------------------------------------------
-- 8. forged whispered "bookie" messages: Comm delivers, the Bettor must ignore
------------------------------------------------------------------------------------------
do
    local code, pending = "FOR-GED1", "PEN-DNG1"
    local st = SteveBookDB.cache
    stub.channels[Protocol.ChannelName(code)] = 5            -- the bettor's replies can go straight out
    stub.channels[Protocol.ChannelName(pending)] = 6
    Cache.RequestJoin(st, code)
    Cache.RequestJoin(st, pending)
    drainSeen()

    -- the real bookie approves: pins who the bookie is
    deliver("Real-Realm", "JOIN_OK", code, { bookName = "Real Book", ownerName = "Real", rev = 1 })
    eq(#drainSeen(), 1, "the real JOIN_OK was delivered")
    eq(st.books[code].status, "active", "approved by the real bookie")
    eq(st.books[code].owner, "Real", "the bookie is pinned to the JOIN_OK sender")

    deliver("Real-Realm", "MARKET", code, { rev = 2, market = { id = 1, event = "Real @ Game", type = "moneyline", status = "open", closesAt = stub.time + 3600,
        selections = { { id = 1, label = "A", odds = -110 }, { id = 2, label = "B", odds = -110 } } } })
    check(st.books[code].markets[1] ~= nil, "a legitimate MARKET from the real bookie is applied")
    drainSeen()

    local before = { balance = st.books[code].balance, markets = 0, status = st.books[code].status }
    for _ in pairs(st.books[code].markets) do before.markets = before.markets + 1 end

    -- Mallory whispers things that claim to come from the bookie
    deliver("Mallory", "MARKET", code, { rev = 99, market = { id = 99, event = "forged", type = "moneyline", status = "open", closesAt = stub.time + 3600,
        selections = { { id = 1, label = "A", odds = 100 }, { id = 2, label = "B", odds = 100 } } } })
    deliver("Mallory", "SYNC", code, { rev = 99, bookName = "Pwned", markets = {}, bets = {}, balance = 999999 })
    deliver("Mallory", "BALANCE", code, { rev = 99, balance = 888888 })
    deliver("Mallory", "BET_ACK", code, { ref = "x", bet = { id = 1, marketId = 99, selectionId = 1, stake = 100, odds = 100, status = "accepted" } })
    deliver("Mallory", "JOIN_DENY", code, { ownerName = "Mallory", reason = "denied" })
    deliver("Mallory", "JOIN_OK", code, { bookName = "Pwned", ownerName = "Real", rev = 99 })
    local delivered = drainSeen()
    local types = {}
    for _, d in ipairs(delivered) do types[#types + 1] = d.type .. "<" .. d.sender end
    eq(#delivered, 6, "Comm delivers all six forged messages to handlers (it only routes): " .. table.concat(types, ","))

    local b = st.books[code]
    local count = 0
    for _ in pairs(b.markets) do count = count + 1 end
    eq(b.markets[99], nil, "forged MARKET not applied")
    eq(count, before.markets, "market table untouched")
    eq(b.balance, before.balance, "forged SYNC/BALANCE did not change the balance")
    eq(b.name, "Real Book", "forged SYNC did not rename the book")
    eq(b.status, before.status, "forged JOIN_DENY did not change the membership")
    eq(b.owner, "Real", "forged JOIN_OK did not move the pinned bookie")
    eq(next(b.bets), nil, "forged BET_ACK did not add a bet")

    -- a forged JOIN_OK naming someone else as owner must not approve a pending request
    deliver("Mallory", "JOIN_OK", pending, { bookName = "Pwned", ownerName = "Real", rev = 1 })
    eq(st.books[pending].status, "requested", "a JOIN_OK whose sender is not the owner it names is ignored")
    deliver("Real-Realm", "JOIN_OK", pending, { bookName = "Honest", ownerName = "Real", rev = 1 })
    eq(st.books[pending].status, "active", "the same JOIN_OK from the named owner is accepted")
end

------------------------------------------------------------------------------------------
-- 9. the channel-notice filter, hiding the channel, login delay, joinAll
------------------------------------------------------------------------------------------
do
    check(filters.CHAT_MSG_CHANNEL_NOTICE and filters.CHAT_MSG_CHANNEL_NOTICE_USER, "filter registered for both notice events")
    local f = filters.CHAT_MSG_CHANNEL_NOTICE
    -- args: (chatFrame, event, text, playerName, language, channelName, ...)
    local function hides(name) return f({}, "CHAT_MSG_CHANNEL_NOTICE", "YOU_JOINED", "Tester", "", name) end
    local chan = Protocol.ChannelName("NFL-K7Q2")
    check(hides("5. " .. chan) == true and hides(chan) == true, "our channel's notices are hidden")
    check(hides("1. General - Stormwind") == false and hides("4. LookingForGroup") == false, "other channels' notices are not")
    check(filters.CHAT_MSG_CHANNEL_NOTICE_USER({}, "CHAT_MSG_CHANNEL_NOTICE_USER", "JOIN", "Bob", "", "5. " .. chan) == true, "other players' join notices are hidden too")

    removed = {}
    Comm.JoinBook("HID-DEN1")
    stub.fire("CHAT_MSG_CHANNEL_NOTICE", "YOU_JOINED", "Tester", "", "5. " .. Protocol.ChannelName("HID-DEN1"))
    eq(#removed, 0, "a channel is never taken off the chat windows (that left it disabled in Forever)")
    Comm.LeaveBook("HID-DEN1")

    -- login join delay and joinAll
    SteveBookDB = Model.NewDB()
    SteveBookDB.cache = Cache.NewStore()
    local own = assert(Model.CreateBook(SteveBookDB, "Own", "Tester", stub.time))
    local other = assert(Model.CreateBook(SteveBookDB, "Elsewhere", "Someone", stub.time))
    Cache.SetMembership(SteveBookDB.cache, "ACT-IVE1", true, "Active", "Real")
    Cache.SetMembership(SteveBookDB.cache, "DEN-IED1", false)
    stub.afters = {}
    stub.fire("PLAYER_ENTERING_WORLD", true, false)
    local a = stub.afters[#stub.afters]
    eq(a and a.sec, 15, "fresh login waits 15s before joining channels")
    stub.afters = {}
    stub.fire("PLAYER_ENTERING_WORLD", false, true)
    a = stub.afters[#stub.afters]
    eq(a and a.sec, 5, "a loading screen waits 5s")
    joinCalls = {}
    a.fn()
    check(joinsFor(Protocol.ChannelName(own.code)) == 1, "joinAll joins the books I own")
    check(joinsFor(Protocol.ChannelName("ACT-IVE1")) == 1, "...and the books I belong to")
    eq(joinsFor(Protocol.ChannelName("DEN-IED1")), 0, "...but not denied ones")
    eq(joinsFor(Protocol.ChannelName(other.code)), 0, "...and not books someone else runs")
end

------------------------------------------------------------------------------------------
-- 10. a payload AceSerializer cannot serialise fails cleanly
------------------------------------------------------------------------------------------
do
    local ok, ret
    local called = pcall(function() ok, ret = Comm.Send("MARKET", { rev = 1, market = { bad = function() end } }, "SER-FAIL", "Bob") end)
    check(called, "Comm.Send does not throw on an unserialisable payload")
    check(ok == false and type(ret) == "string", "it returns false, err: " .. tostring(ret))
    local ok2, err2 = Comm.Send("MARKET", { rev = "x", market = {} }, "SER-FAIL", "Bob")
    check(ok2 == false and err2 and err2:find("rev"), "a payload that breaks the protocol is refused: " .. tostring(err2))
end

if #stub.errors > 0 then
    fails = fails + 1
    out_("FAIL: errors reported to the error handler:\n  " .. table.concat(stub.errors, "\n  "))
end
------------------------------------------------------------------------------------------
-- 9. addressed messages: only the named player acts on them
------------------------------------------------------------------------------------------
do
    local code = "ADR-0001"
    local function send(to)
        local env = assert(Protocol.Wrap("JOIN_DENY", code, { ownerName = "Real", reason = "denied" }))
        if to ~= nil then env.to = to end
        stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", "Real-Realm")
        return #drainSeen()
    end
    drainSeen()
    eq(send("Tester"), 1, "addressed to us: delivered")
    eq(send("Tester-Realm"), 1, "addressed to us with our realm: delivered")
    eq(send("Someone"), 0, "addressed to another player: dropped")
    eq(send(42), 0, "malformed address: dropped")
    eq(send(nil), 1, "no address (everyone): delivered")
end

------------------------------------------------------------------------------------------
-- 10. Forever sender names look like "Tuesday lol" while UnitName("player") is "Tuesday"
------------------------------------------------------------------------------------------
do
    eq(Comm.NormalizeName("Tuesday lol"), "Tuesday", "a spaced sender name is reduced to the first word")
    eq(Comm.NormalizeName("Steve Spinebreaker"), "Steve", "second example")
    eq(Comm.NormalizeName("Real-Realm"), "Real", "same-realm suffix still stripped")
    eq(Comm.NormalizeName("Bob-Other Realm"), "Bob-Other Realm", "other-realm names keep their suffix")
    local code = "SPC-0001"
    local function send(sender, to)
        local env = assert(Protocol.Wrap("JOIN_DENY", code, { ownerName = "Steve", reason = "denied" }))
        env.to = to
        drainSeen()
        stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", sender)
        return drainSeen()
    end
    local got = send("Steve Spinebreaker", "Tester lol")
    eq(#got, 1, "a reply addressed to 'Tester lol' reaches the player Tester")
    eq(got[1] and got[1].sender, "Steve", "the sender is delivered as 'Steve'")
    eq(#send("Steve Spinebreaker", "Someone Else"), 0, "a reply for another player is dropped")
    -- our own echo arrives under our spaced name and must be recognised as ours
    stub.player = "Tester"
    eq(#send("Tester lol", nil), 0, "our own spaced-name echo is ignored")
end

------------------------------------------------------------------------------------------
-- 11. corrupt compressed data is dropped quietly
------------------------------------------------------------------------------------------
do
    drainSeen()
    local before = #stub.errors
    stub.fire("CHAT_MSG_ADDON", "SteveBook", "ZD1this is not deflate data", "CHANNEL", "Real-Realm")
    stub.fire("CHAT_MSG_ADDON", "SteveBook", "ZD1", "CHANNEL", "Real-Realm")
    eq(#drainSeen(), 0, "corrupt compressed messages deliver nothing")
    eq(#stub.errors, before, "and raise no errors")
end

------------------------------------------------------------------------------------------
-- 12. a channel the game lists as disabled is not "joined": leave it and join again
------------------------------------------------------------------------------------------
do
    local code = "STU-CK01"
    local chan = Protocol.ChannelName(code)
    local disabled = {}
    GetChannelList = function()
        local t = {}
        for name, id in pairs(stub.channels) do t[#t + 1] = id; t[#t + 1] = name; t[#t + 1] = disabled[name] == true end
        return unpack(t)
    end
    added = {}
    stub.channels[chan] = 7; disabled[chan] = true       -- a slot, but the server never let us in
    joinCalls = {}; stub.addonMessages = {}; stub.afters = {}
    local ok, how = Comm.Send("MARKET", { rev = 1, market = { id = 1 } }, code)
    eq(how, "queued", "a disabled channel is not ready, so the message is queued")
    eq(Comm.IsJoined(code), false, "IsJoined says no for a disabled channel")
    local id, dis = Comm.ChannelState(code)
    eq(id, 7, "ChannelState reports the slot"); eq(dis, true, "...and that it is disabled")
    local named = false
    for _, line in ipairs(Comm.NetReport()) do
        if line:find(chan, 1, true) and line:find("DISABLED", 1, true) then named = true end
    end
    check(named, "/book net names the problem")
    tick(12)
    check(stub.channels[chan] == nil, "after a few seconds disabled the channel was left")
    local back = false
    for _, n in ipairs(added) do if n == chan then back = true end end
    check(back, "...and put back on the chat window, undoing an old removal")
    for _, a in ipairs(stub.afters) do a.fn() end
    check(joinsFor(chan) >= 1, "...and joined again")
    stub.channels[chan] = 8; disabled[chan] = false      -- this time the join took
    tick(3)
    local sent = {}
    for _, m in ipairs(stub.addonMessages) do if m.chatType == "CHANNEL" then sent[#sent + 1] = m end end
    eq(#sent, 1, "the queued message went out once the channel was enabled")
    eq(sent[1] and sent[1].target, 8, "...to the new slot")
    Comm.LeaveBook(code)
    GetChannelList = nil
end

------------------------------------------------------------------------------------------
-- 13. the pre-v0.7.5 channel name is left when the new one is joined
------------------------------------------------------------------------------------------
do
    local code = "OLD-NAM1"
    local legacy = Protocol.LegacyChannelName(code)
    check(legacy ~= Protocol.ChannelName(code) and legacy == "SBOLDNAM1", "legacy name is the old spelling")
    stub.channels[legacy] = 3
    Comm.JoinBook(code)
    check(stub.channels[legacy] == nil, "joining a book leaves its old channel name")
    Comm.LeaveBook(code)
end

------------------------------------------------------------------------------------------
-- 14. guild transport: a second path, deduplicated on receive
------------------------------------------------------------------------------------------
do
    local code = "GLD-TEST"
    IsInGuild = function() return true end
    SteveBookDB.noGuild = nil
    stub.channels[Protocol.ChannelName(code)] = nil
    stub.addonMessages = {}
    local ok, how = Comm.Send("MARKET", { rev = 1, market = { id = 1 } }, code)
    eq(ok, true, "send ok with the channel down")
    eq(how, "guild", "reported as sent by guild while the channel is not ready")
    tick(2)
    local guildMsgs = 0
    for _, m in ipairs(stub.addonMessages) do if m.chatType == "GUILD" then guildMsgs = guildMsgs + 1 end end
    eq(guildMsgs, 1, "one GUILD addon message went out")
    check(Comm.NetReport()[#Comm.NetReport() - 1]:find("Guild messages: ON", 1, true) ~= nil, "/book net says guild is on")

    -- the same message (same id) arriving on both transports is handled once
    drainSeen()
    local env = assert(Protocol.Wrap("MARKET", "GLD-TEST", { rev = 5, market = { id = 5 } }))
    env.m = "t0001"
    local text = AceSer:Serialize(env)
    stub.fire("CHAT_MSG_ADDON", "SteveBook", text, "GUILD", "Zed-Realm")
    stub.fire("CHAT_MSG_ADDON", "SteveBook", text, "CHANNEL", "Zed-Realm")
    eq(#drainSeen(), 1, "both copies deliver one message")
    -- a new id from the same sender is a new message
    env.m = "t0002"
    text = AceSer:Serialize(env)
    stub.fire("CHAT_MSG_ADDON", "SteveBook", text, "GUILD", "Zed-Realm")
    eq(#drainSeen(), 1, "a different id is delivered")
    -- messages without an id (older versions) always deliver
    env.m = nil
    text = AceSer:Serialize(env)
    stub.fire("CHAT_MSG_ADDON", "SteveBook", text, "CHANNEL", "Zed-Realm")
    stub.fire("CHAT_MSG_ADDON", "SteveBook", text, "CHANNEL", "Zed-Realm")
    eq(#drainSeen(), 2, "messages with no id are never treated as duplicates")

    -- off switch and no guild
    SteveBookDB.noGuild = true
    stub.addonMessages = {}
    ok, how = Comm.Send("MARKET", { rev = 2, market = { id = 2 } }, code)
    eq(how, "queued", "with guild messages off, a down channel means queued")
    tick(2)
    guildMsgs = 0
    for _, m in ipairs(stub.addonMessages) do if m.chatType == "GUILD" then guildMsgs = guildMsgs + 1 end end
    eq(guildMsgs, 0, "nothing goes out by guild when it is off")
    SteveBookDB.noGuild = nil
    IsInGuild = function() return false end
    ok, how = Comm.Send("MARKET", { rev = 3, market = { id = 3 } }, code)
    eq(how, "queued", "not in a guild: the channel path alone")
    IsInGuild = nil
    Comm.LeaveBook(code)
end

------------------------------------------------------------------------------------------
-- 15. Comm.Health: a one-line answer for windows that are waiting on someone
------------------------------------------------------------------------------------------
do
    local code = "HLT-HEAL"
    stub.channels[Protocol.ChannelName(code)] = nil
    IsInGuild = function() return false end
    local ok, text = Comm.Health(code, "Nobody")
    eq(ok, false, "no channel and no guild is not connected")
    check(text:find("/book net", 1, true) ~= nil, "...and says where to look")
    IsInGuild = function() return true end
    ok, text = Comm.Health(code, "Nobody")
    eq(ok, true, "a guild path counts as connected")
    check(text:find("has not been heard", 1, true) ~= nil, "...but says the other side is silent")
    local env = assert(Protocol.Wrap("MARKET", code, { rev = 1, market = { id = 1 } }))
    stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "GUILD", "Heal-Realm")
    ok, text = Comm.Health(code, "Heal")
    eq(ok, true, "heard recently"); check(text:find("heard", 1, true) and text:find("guild", 1, true), "names the path: " .. text)
    IsInGuild = nil
    drainSeen()
end

-- 16. /book net test: reports the game's own answer for each path
do
    local sent = {}
    local realSend = C_ChatInfo.SendAddonMessage
    C_ChatInfo.SendAddonMessage = function(prefix, text, kind, target) sent[#sent + 1] = kind; return 11 end
    IsInGuild = function() return true end
    local lines = Comm.SendTest()
    local joinedText = table.concat(lines, "\n")
    check(joinedText:find("GUILD", 1, true) ~= nil, "test line for guild: " .. joinedText)
    check(sent[1] == "GUILD", "a test message really goes to GUILD")
    C_ChatInfo.SendAddonMessage = function() return 0 end
    joinedText = table.concat(Comm.SendTest(), "\n")
    check(joinedText:find("Test send to GUILD: 0", 1, true) ~= nil, "success code shown: " .. joinedText)
    C_ChatInfo.SendAddonMessage = function() error("boom") end
    joinedText = table.concat(Comm.SendTest(), "\n")
    check(joinedText:find("error", 1, true) ~= nil, "a throwing send is reported, not raised")
    C_ChatInfo.SendAddonMessage = realSend
    IsInGuild = nil
end

if fails == 0 then out_("comm: all tests passed") else os.exit(1) end
