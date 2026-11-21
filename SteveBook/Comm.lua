-- Comm.lua: transport. Hidden per-book chat channel + AceComm addon messages (SPEC §5).
-- WoW-dependent glue; the testable parts (channel names, routing, name normalising, message
-- shapes) live in Protocol.lua.
--
-- API (used by Bookie/Bettor code):
--   Comm.Register(msgType, function(sender, payload, bookCode) end)
--   Comm.Send(msgType, payload, bookCode, targetNameOrNil) -> true | false, err
--       target nil  -> everyone in the book acts on it
--       target name -> sent on the same hidden channel, addressed to that player (envelope field
--                      `to`); every other client drops it. Addon WHISPERs were not reliable in
--                      Forever (accepted by the API, never delivered), the channel is.
--   Comm.JoinBook(code), Comm.LeaveBook(code), Comm.IsJoined(code)
--   Comm.Me() -> the player's name as delivered to handlers
--
-- APIs not verified in WoW: Forever. Each is guarded; see the /dump checks in README.md.
local ADDON, ns = ...
local Protocol = ns.Protocol
local Model = ns.Model

local Comm = {}
ns.Comm = Comm

local PREFIX = "SteveBook"          -- addon message prefix (<= 16 chars)
local AceComm = LibStub("AceComm-3.0")
local AceSer = LibStub("AceSerializer-3.0")
local LibDeflate = LibStub("LibDeflate", true)        -- optional: without it messages go uncompressed
AceComm:Embed(Comm)

local handlers = {}                 -- msgType -> { fn, ... }
local queued = {}                   -- code -> { {text, prio}, ... } waiting for the channel
local joined = {}                   -- code -> true while we want to be in the channel
local lastTry = {}                  -- code -> GetTime() of the last JoinTemporaryChannel call
local attempts = {}                 -- code -> join attempts since the channel was last up
local MAX_QUEUE = 20
-- Big messages (a SYNC of a whole book is ~200 bytes per market) are deflated before they are
-- chunked: ChatThrottleLib moves only ~800 bytes a second, and this text compresses ~10x.
-- The wire form is "ZD1" .. encoded bytes; plain AceSerializer text starts with "^1".
Comm.Compress = true
local COMPRESS_MIN = 200
local ZMARK = "ZD1"

local function pack(text)
    if not (Comm.Compress and LibDeflate) or #text < COMPRESS_MIN then return text end
    local ok, z = pcall(LibDeflate.CompressDeflate, LibDeflate, text, { level = 6 })
    if not (ok and z) then return text end
    local ok2, enc = pcall(LibDeflate.EncodeForWoWAddonChannel, LibDeflate, z)
    if not (ok2 and enc) then return text end
    local wire = ZMARK .. enc
    return #wire < #text and wire or text
end

local function unpack_(message)
    if type(message) ~= "string" or message:sub(1, #ZMARK) ~= ZMARK then return message end
    if not LibDeflate then return nil end
    local ok, z = pcall(LibDeflate.DecodeForWoWAddonChannel, LibDeflate, message:sub(#ZMARK + 1))
    if not (ok and z) then return nil end
    local ok2, text = pcall(LibDeflate.DecompressDeflate, LibDeflate, z)
    if not (ok2 and text) then return nil end
    return text
end
local JOIN_RETRY_SECONDS = 5        -- minimum gap between join attempts for one channel
local MAX_JOIN_ATTEMPTS = 6         -- then give up, drop the queue and tell the player

-- Acks and presence jump ahead of bulk syncs (ChatThrottleLib services priorities separately).
local PRIORITY = {
    JOIN_OK = "ALERT", JOIN_DENY = "ALERT", BET_ACK = "ALERT", BET_REJECT = "ALERT",
    PING = "ALERT", PONG = "ALERT", SYNC = "BULK", BETS = "BULK",
    TBL_JOIN_OK = "ALERT", TBL_JOIN_DENY = "ALERT", TBL_BET_OK = "ALERT", TBL_BET_REJECT = "ALERT",
}

local function say(msg) print("|cffffd100SteveBook:|r " .. msg) end

-- /book debug: trace every message in and out (PING/PONG left out, they repeat). For finding out
-- why two players cannot talk; each side turns it on and reads its own chat.
local QUIET = { PING = true, PONG = true }
local function dbg(msgType, fmt, ...)
    local db = SteveBookDB
    if not (db and db.debug) or (msgType and QUIET[msgType]) then return end
    local args = { ... }
    for i = 1, select("#", ...) do args[i] = tostring(args[i]) end
    say("|cff9d9d9d[debug]|r " .. fmt:format(unpack(args)))
end
local function myName() return UnitName("player") end
local function myRealm() return GetNormalizedRealmName and GetNormalizedRealmName() or nil end
local function clock() return GetTime and GetTime() or 0 end

function Comm.Me() return myName() end

-- The addon's version from the .toc ("0.7.1"), or nil if the game will not say. Sent in the lobby so
-- /book lobby can show who runs an old version.
function Comm.Version()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if not get then return nil end
    local ok, v = pcall(get, ADDON, "Version")
    return ok and type(v) == "string" and v or nil
end

local function baseName(name) return type(name) == "string" and name:match("^([^%-]+)") or name end

-- One spelling per player. In Forever the sender of an addon message arrives as "Tuesday lol" or
-- "Steve Spinebreaker" (a space and a second word) while UnitName("player") is just "Tuesday" or
-- "Steve", so compare on the first word. Names with a "-Realm" suffix keep it.
local function normalize(name)
    local n
    if Ambiguate then
        local ok, r = pcall(Ambiguate, name, "none")
        if ok and r then n = r end
    end
    n = n or Protocol.NormalizeName(name, myRealm())
    if type(n) == "string" and not n:find("-", 1, true) then n = n:match("^(%S+)") or n end
    return n
end
Comm.NormalizeName = normalize

-- Do I run this code? True for a sportsbook I own and for a casino table I host.
local function isOwner(code)
    local db = SteveBookDB
    if not db then return false end
    local book = Model.FindByCode(db, code)
    if book ~= nil and book.ownerName == myName() then return true end
    local t = db.casino and db.casino.tables and db.casino.tables[code]
    return t ~= nil and t.hostName == myName()
end

-- ---------------------------------------------------------------------------------------
-- Channel handling

-- GetChannelList() returns id, name, disabled for every channel. A channel the game lists as
-- disabled has a slot number but the server never let us in: every send to it fails with
-- InvalidChannel and nobody hears it. (Seen in Forever: GetChannelName still returned the slot.)
local function listedDisabled(name)
    if not GetChannelList then return false end
    local ok, t = pcall(function() return { GetChannelList() } end)
    if not ok or type(t) ~= "table" then return false end
    for i = 1, #t, 3 do
        if t[i + 1] == name then return t[i + 2] == true end
    end
    return false
end

-- The slot of a channel we can really use: 0 when we are not in it, or it is listed but disabled.
local function channelId(code)
    if not GetChannelName then return 0 end
    local name = Protocol.ChannelName(code)
    local id = GetChannelName(name)
    if not id or id <= 0 then return 0 end
    if listedDisabled(name) then return 0 end
    return id
end

-- (slot, disabled) for /book net and /book lobby.
function Comm.ChannelState(code)
    local name = Protocol.ChannelName(code)
    local id = GetChannelName and GetChannelName(name) or 0
    return id or 0, (id or 0) > 0 and listedDisabled(name) or false
end

-- The chat API moved in some client versions; use whichever name exists.
local addChannel = ChatFrame_AddChannel or (ChatFrameUtil and ChatFrameUtil.AddChannel)
local addFilter = ChatFrame_AddMessageEventFilter or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)

-- Up to v0.7.2 every join took the channel OFF all chat windows to keep it out of sight. In
-- Forever such a channel stayed "disabled" (a slot, but InvalidChannel on every send), while a
-- channel left on a window worked. So the channel stays on the chat window now; the notice filter
-- below keeps its join/leave lines out of chat, and addon messages never show there. This puts a
-- channel back on the main window for characters that still carry the old removal.
local function showChannel(code)
    local name = Protocol.ChannelName(code)
    local f = _G.DEFAULT_CHAT_FRAME or _G.ChatFrame1
    if addChannel and f then pcall(addChannel, f, name) end
end

-- Keep "you joined/left" and other-player notices for our hidden channels out of chat.
if addFilter then
    local function filter(_, _, _, _, _, channelName)
        if type(channelName) == "string" and channelName:find("SB", 1, true) then
            return channelName:match("^%d*%.?%s*SB[A-Z0-9]+$") ~= nil
        end
        return false
    end
    addFilter("CHAT_MSG_CHANNEL_NOTICE", filter)
    addFilter("CHAT_MSG_CHANNEL_NOTICE_USER", filter)
end

function Comm.IsJoined(code) return channelId(code) > 0 end

-- /book net: one line per hidden channel this client wants to be in.
function Comm.NetReport()
    local lines = {}
    local codes = {}
    for code in pairs(joined) do codes[#codes + 1] = code end
    table.sort(codes)
    for _, code in ipairs(codes) do
        local id, disabled = Comm.ChannelState(code)
        local state
        if id == 0 then state = "NOT JOINED"
        elseif disabled then state = ("slot %d but DISABLED (the game has not let you in; it is retried every few seconds)"):format(id)
        else state = ("slot %d, working"):format(id) end
        lines[#lines + 1] = ("%s: %s"):format(Protocol.ChannelName(code), state)
    end
    if #lines == 0 then lines[1] = "No SteveBook channels are wanted right now (open /casino or join a book)." end
    return lines
end

-- A channel can sit in the list as disabled and stay that way (the join was refused, for instance
-- while the client was still loading). Joining a name we already hold does nothing, so leave it and
-- join again, once it has been disabled for DISABLED_GRACE seconds (a fresh join may show as
-- disabled for a moment).
local DISABLED_GRACE = 4
local disabledSince = {}            -- code -> clock() when first seen disabled

local function rejoinIfStuck(code)
    local name = Protocol.ChannelName(code)
    local id = GetChannelName and GetChannelName(name) or 0
    if not (id and id > 0 and listedDisabled(name)) then disabledSince[code] = nil; return false end
    local t = clock()
    disabledSince[code] = disabledSince[code] or t
    if t - disabledSince[code] < DISABLED_GRACE then return false end
    disabledSince[code] = nil
    dbg(nil, "channel %s (slot %s) is listed but disabled; leaving it and joining again", name, id)
    showChannel(code)
    if LeaveChannelByName then pcall(LeaveChannelByName, name) end
    local function join()
        if joined[code] and JoinTemporaryChannel then pcall(JoinTemporaryChannel, name); showChannel(code) end
    end
    if C_Timer and C_Timer.After then C_Timer.After(1.5, join) else join() end
    return true
end

-- One real join attempt, at most once per JOIN_RETRY_SECONDS per channel.
local legacyLeft = {}            -- code -> true once the pre-v0.7.5 channel name was left

local function leaveLegacy(code)
    if legacyLeft[code] then return end
    legacyLeft[code] = true
    local old = Protocol.LegacyChannelName(code)
    local id = GetChannelName and GetChannelName(old) or 0
    if id and id > 0 and LeaveChannelByName then
        dbg(nil, "leaving the old channel %s (slot %s)", old, id)
        pcall(LeaveChannelByName, old)
    end
end

local function tryJoin(code)
    leaveLegacy(code)
    if channelId(code) > 0 then attempts[code] = nil; disabledSince[code] = nil; return true end
    local t = clock()
    if lastTry[code] and t - lastTry[code] < JOIN_RETRY_SECONDS then return false, "waiting" end
    lastTry[code] = t
    attempts[code] = (attempts[code] or 0) + 1
    if rejoinIfStuck(code) then return false end
    if JoinTemporaryChannel then pcall(JoinTemporaryChannel, Protocol.ChannelName(code)) end
    return channelId(code) > 0
end

function Comm.JoinBook(code)
    if not code or code == "" then return false end
    joined[code] = true
    return tryJoin(code)
end

function Comm.LeaveBook(code)
    joined[code] = nil
    queued[code] = nil
    attempts[code] = nil
    lastTry[code] = nil
    if LeaveChannelByName then pcall(LeaveChannelByName, Protocol.ChannelName(code)) end
end

-- ---------------------------------------------------------------------------------------
-- Delivery to handlers, and loopback (testing alone)

local function dispatch(msgType, sender, payload, code)
    for _, fn in ipairs(handlers[msgType] or {}) do
        local hok, herr = pcall(fn, sender, payload, code)
        if not hok then
            Comm.lastError = herr
            if geterrorhandler then geterrorhandler()(herr) end
        end
    end
end

-- Loopback lets one character be bookie and bettor of its own book (/book loopback). A client
-- never hears its own messages, so with it on, Send also hands each message straight to this
-- client's own handlers for the other role. The bettor side shows up to the bookie as the
-- member LOOPBACK_NAME, so approve that member.
local LOOPBACK_NAME = "Loopback"
Comm.LOOPBACK_NAME = LOOPBACK_NAME
local BETTOR_ORIGIN = { JOIN_REQ = true, SYNC_REQ = true, BET_PLACE = true, BETS_REQ = true, PING = true,
    TBL_JOIN = true, TBL_LEAVE = true, TBL_SYNC_REQ = true, TBL_BET = true, TBL_BET_CLEAR = true, TBL_ACT = true }

function Comm.LoopbackActive(code)
    local db = SteveBookDB
    if not (db and db.loopback == true and isOwner(code)) then return false end
    local books = db.cache and db.cache.books
    local tables = db.casinoCache and db.casinoCache.tables
    return (books ~= nil and books[code] ~= nil) or (tables ~= nil and tables[code] ~= nil)
end

local function loopback(text, msgType, code, to)
    local sender
    if BETTOR_ORIGIN[msgType] then
        sender = LOOPBACK_NAME
    else
        if to and baseName(to) ~= LOOPBACK_NAME then return end   -- addressed to a real player
        sender = myName()
    end
    local function run()
        local ok, env = AceSer:Deserialize(text)                 -- same copy a real receiver gets
        if not ok then return end
        local t, c, payload = Protocol.Unwrap(env)
        if t then dispatch(t, sender, payload, c) end
    end
    if C_Timer and C_Timer.After then C_Timer.After(0.2, run) else run() end
end

-- ---------------------------------------------------------------------------------------
-- Sending

local function rawSend(text, code, prio)
    local id = channelId(code)
    if id <= 0 then return false, "channel not ready" end
    Comm:SendCommMessage(PREFIX, text, "CHANNEL", id, prio)
    return true
end

local flushTicker
local function stopFlush()
    if flushTicker then flushTicker:Cancel(); flushTicker = nil end
end

local function flush()
    local waiting = false
    for code, list in pairs(queued) do
        if #list == 0 then
            queued[code] = nil
        elseif channelId(code) > 0 then
            attempts[code] = nil
            for _, m in ipairs(list) do pcall(rawSend, m.text, code, m.prio) end
            queued[code] = nil
        elseif (attempts[code] or 0) >= MAX_JOIN_ATTEMPTS then
            queued[code] = nil
            attempts[code] = nil
            say("Could not join the channel for book " .. code .. ", so " .. #list ..
                " message(s) were dropped. Is the 10-channel limit reached?")
        else
            tryJoin(code)
            waiting = true
        end
    end
    if not waiting then stopFlush() end
end

local function enqueue(code, text, prio)
    local list = queued[code] or {}
    queued[code] = list
    if #list >= MAX_QUEUE then table.remove(list, 1) end
    list[#list + 1] = { text = text, prio = prio }
    if not flushTicker and C_Timer and C_Timer.NewTicker then
        flushTicker = C_Timer.NewTicker(1, flush)
    end
end

function Comm.Send(msgType, payload, bookCode, target)
    local env, err = Protocol.Wrap(msgType, bookCode, payload)
    if not env then return false, err end
    if target then env.to = normalize(target) end
    local sok, text = pcall(AceSer.Serialize, AceSer, env)
    if not sok then return false, tostring(text) end
    local prio = PRIORITY[msgType]
    local wire = pack(text)
    dbg(msgType, "send %s book %s to %s on channel #%s (%d bytes, %d on the wire)", msgType, bookCode,
        env.to or "everyone", channelId(bookCode), #text, #wire)
    if Comm.LoopbackActive(bookCode) then loopback(text, msgType, bookCode, env.to) end
    text = wire
    -- pcall returns (ok, rawSend's first result, rawSend's second result)
    local ok, sent, serr = pcall(rawSend, text, bookCode, prio)
    if not ok then return false, tostring(sent) end
    if sent == false and serr == "channel not ready" then
        enqueue(bookCode, text, prio)        -- joins are asynchronous; deliver once ready
        Comm.JoinBook(bookCode)
        return true, "queued"
    end
    return true
end

-- ---------------------------------------------------------------------------------------
-- Receiving

function Comm.Register(msgType, fn)
    handlers[msgType] = handlers[msgType] or {}
    table.insert(handlers[msgType], fn)
end

Comm:RegisterComm(PREFIX, function(_, message, distribution, sender)
    local sent = normalize(sender)
    message = unpack_(message)
    if not message then return dbg(nil, "dropped a compressed message from %s that did not decompress", sent) end
    local ok, env = AceSer:Deserialize(message)
    local label = ok and type(env) == "table" and env.t or "?"
    if sent == myName() then                                   -- our own channel echo
        dbg(label, "echo of my own %s (it left this client)", label)
        return
    end
    if not ok then return dbg(nil, "dropped a message from %s that did not deserialize", sent) end
    local msgType, code, payload = Protocol.Unwrap(env)
    if not msgType then return dbg(nil, "dropped a message from %s: %s", sent, tostring(code)) end
    -- Addressed to someone else (see Comm.Send)? Not for us.
    if env.to ~= nil and (type(env.to) ~= "string" or baseName(normalize(env.to)) ~= baseName(myName())) then
        return dbg(msgType, "ignored %s from %s: addressed to %s, I am %s", msgType, sent, env.to, myName())
    end
    if not Protocol.ShouldDeliver(msgType, isOwner(code)) then
        return dbg(msgType, "ignored %s from %s: not for my role (I %s book %s)", msgType, sent,
            isOwner(code) and "own" or "do not own", code)
    end
    dbg(msgType, "recv %s from %s via %s, book %s", msgType, sent, distribution, code)
    dispatch(msgType, sent, payload, code)
end)

-- ---------------------------------------------------------------------------------------
-- Login: join the hidden channel for every book we own or belong to.

local function joinAll()
    local db = SteveBookDB
    if not db then return end
    for _, book in pairs(db.books or {}) do
        if book.ownerName == myName() then Comm.JoinBook(book.code) end
    end
    local cache = db.cache and db.cache.books
    for code, bc in pairs(cache or {}) do
        if bc.status ~= "denied" and bc.status ~= "removed" then Comm.JoinBook(code) end
    end
    -- casino tables: the ones I host and the ones I sit at
    local hosting = false
    for code, t in pairs(db.casino and db.casino.tables or {}) do
        if t.hostName == myName() and t.status ~= "closed" then Comm.JoinBook(code); hosting = true end
    end
    if hosting or db.lobbyJoined then Comm.JoinBook(Protocol.LOBBY_CODE) end   -- the lobby: to announce my tables, or to hear others
    for code, tc in pairs(db.casinoCache and db.casinoCache.tables or {}) do
        if tc.status == "requested" or tc.status == "seated" then Comm.JoinBook(code) end
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
f:SetScript("OnEvent", function(_, event, a1, ...)
    if event == "CHAT_MSG_CHANNEL_NOTICE" then
        -- First argument is the notice type. Once a channel is up, hide it from chat windows.
        dbg(nil, "channel notice: %s", a1)
        return
    end
    -- Chat channels are not ready the instant the world loads; the player's own channels (General,
    -- Trade) should get their numbers first, so wait longer after a fresh login than after a
    -- loading screen. (a1 is isInitialLogin.)
    local delay = a1 and 15 or 5
    if C_Timer and C_Timer.After then C_Timer.After(delay, joinAll) else joinAll() end
end)
