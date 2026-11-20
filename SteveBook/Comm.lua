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
AceComm:Embed(Comm)

local handlers = {}                 -- msgType -> { fn, ... }
local queued = {}                   -- code -> { {text, prio}, ... } waiting for the channel
local joined = {}                   -- code -> true while we want to be in the channel
local lastTry = {}                  -- code -> GetTime() of the last JoinTemporaryChannel call
local attempts = {}                 -- code -> join attempts since the channel was last up
local MAX_QUEUE = 20
local JOIN_RETRY_SECONDS = 5        -- minimum gap between join attempts for one channel
local MAX_JOIN_ATTEMPTS = 6         -- then give up, drop the queue and tell the player

-- Acks and presence jump ahead of bulk syncs (ChatThrottleLib services priorities separately).
local PRIORITY = {
    JOIN_OK = "ALERT", JOIN_DENY = "ALERT", BET_ACK = "ALERT", BET_REJECT = "ALERT",
    PING = "ALERT", PONG = "ALERT", SYNC = "BULK",
}

local function say(msg) print("|cffffd100SteveBook:|r " .. msg) end
local function myName() return UnitName("player") end
local function myRealm() return GetNormalizedRealmName and GetNormalizedRealmName() or nil end
local function clock() return GetTime and GetTime() or 0 end

function Comm.Me() return myName() end

local function baseName(name) return type(name) == "string" and name:match("^([^%-]+)") or name end

local function normalize(name)
    if Ambiguate then
        local ok, n = pcall(Ambiguate, name, "none")
        if ok and n then return n end
    end
    return Protocol.NormalizeName(name, myRealm())
end

local function isOwner(code)
    local db = SteveBookDB
    local book = db and Model.FindByCode(db, code)
    return book ~= nil and book.ownerName == myName()
end

-- ---------------------------------------------------------------------------------------
-- Channel handling

local function channelId(code)
    if not GetChannelName then return 0 end
    local id = GetChannelName(Protocol.ChannelName(code))
    return id or 0
end

-- The chat API moved in some client versions; use whichever name exists.
local removeChannel = ChatFrame_RemoveChannel or (ChatFrameUtil and ChatFrameUtil.RemoveChannel)
local addFilter = ChatFrame_AddMessageEventFilter or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)

local function hideChannel(code)
    local name = Protocol.ChannelName(code)
    if removeChannel and NUM_CHAT_WINDOWS then
        for i = 1, NUM_CHAT_WINDOWS do
            local f = _G["ChatFrame" .. i]
            if f then pcall(removeChannel, f, name) end
        end
    end
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

-- One real join attempt, at most once per JOIN_RETRY_SECONDS per channel.
local function tryJoin(code)
    if channelId(code) > 0 then attempts[code] = nil; return true end
    local t = clock()
    if lastTry[code] and t - lastTry[code] < JOIN_RETRY_SECONDS then return false, "waiting" end
    lastTry[code] = t
    attempts[code] = (attempts[code] or 0) + 1
    if JoinTemporaryChannel then pcall(JoinTemporaryChannel, Protocol.ChannelName(code)) end
    hideChannel(code)   -- the join is asynchronous; the notice event below hides it again
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
local BETTOR_ORIGIN = { JOIN_REQ = true, SYNC_REQ = true, BET_PLACE = true, PING = true }

function Comm.LoopbackActive(code)
    local db = SteveBookDB
    local cached = db and db.cache and db.cache.books
    return db ~= nil and db.loopback == true and isOwner(code) and cached ~= nil and cached[code] ~= nil
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
    if Comm.LoopbackActive(bookCode) then loopback(text, msgType, bookCode, env.to) end
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

Comm:RegisterComm(PREFIX, function(_, message, _, sender)
    local sent = normalize(sender)
    if sent == myName() then return end                       -- our own channel echo
    local ok, env = AceSer:Deserialize(message)
    if not ok then return end
    local msgType, code, payload = Protocol.Unwrap(env)
    if not msgType then return end
    -- Addressed to someone else (see Comm.Send)? Not for us.
    if env.to ~= nil and (type(env.to) ~= "string" or baseName(normalize(env.to)) ~= baseName(myName())) then return end
    if not Protocol.ShouldDeliver(msgType, isOwner(code)) then return end
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
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
f:SetScript("OnEvent", function(_, event, a1, ...)
    if event == "CHAT_MSG_CHANNEL_NOTICE" then
        -- First argument is the notice type. Once a channel is up, hide it from chat windows.
        if a1 == "YOU_JOINED" then
            for code in pairs(joined) do hideChannel(code) end
        end
        return
    end
    -- Chat channels are not ready the instant the world loads; the player's own channels (General,
    -- Trade) should get their numbers first, so wait longer after a fresh login than after a
    -- loading screen. (a1 is isInitialLogin.)
    local delay = a1 and 15 or 5
    if C_Timer and C_Timer.After then C_Timer.After(delay, joinAll) else joinAll() end
end)
