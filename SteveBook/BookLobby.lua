-- BookLobby.lua: a list of sportsbooks to join, instead of typing a code (SPEC §5). A bookie's
-- client announces each of their listed books in the casino's shared lobby channel; anyone can ask
-- who is out there. Nothing here is secret: a book can still be joined by code, and joining still
-- needs the bookie's approval. WoW-dependent glue (it uses Comm).
--   BookLobby.Books()        -> listed books I could join, { code, name, owner, members, markets, age }
--   BookLobby.Ask()          -> join the lobby and ask who is hosting (when the join screen opens)
--   BookLobby.Announce()     -> tell the lobby about my listed books
--   BookLobby.Subscribe(fn)  -> fn() whenever the list changed
-- A book the bookie has hidden (/book hide) is never announced.
local ADDON, ns = ...
ns = ns or {}

local Model, Bookie, Protocol = ns.Model, ns.Bookie, ns.Protocol
local BL = {}
ns.BookLobby = BL

local ROOM_TTL = 100                 -- a listing disappears this long after the last announcement
local ANNOUNCE_EVERY = 15
local rooms = {}                     -- code -> { entry, seen }
local lastAnnounce = 0
local listeners = {}

local function db() return SteveBookDB end
local function me() return UnitName("player") end
local function now() return GetServerTime() end
local function baseName(name) return type(name) == "string" and name:match("^([^%-]+)") or nil end

function BL.Subscribe(fn) listeners[#listeners + 1] = fn end
local function changed() for _, fn in ipairs(listeners) do pcall(fn) end end

local function entryFor(book)
    local members, open = 0, 0
    for _, m in pairs(book.members) do if m.status == "active" then members = members + 1 end end
    local t = now()
    for _, mk in pairs(book.markets) do if Bookie.IsBettable(mk, t) then open = open + 1 end end
    return { code = book.code, name = book.name, owner = book.ownerName, members = members, markets = open }
end

-- My listed books, as lobby entries.
local function myEntries()
    local d = db()
    local list = {}
    if not d then return list end
    for _, book in ipairs(Model.ListBooks(d)) do
        if book.ownerName == me() and not book.unlisted then list[#list + 1] = entryFor(book) end
    end
    return list
end

function BL.Announce()
    local list = myEntries()
    if #list == 0 then return end
    lastAnnounce = now()
    ns.Comm.JoinBook(Protocol.LOBBY_CODE)
    ns.Comm.Send("LOBBY_BOOKS", { books = list, ver = ns.Comm.Version() }, Protocol.LOBBY_CODE)
end

function BL.Ask()
    if db() then db().lobbyJoined = true end          -- stay in the lobby from now on
    ns.Comm.JoinBook(Protocol.LOBBY_CODE)
    ns.Comm.Send("LOBBY_ASK", { ver = ns.Comm.Version() }, Protocol.LOBBY_CODE)
end

-- Listed books I am not already in (or waiting on). With /book loopback my own books are listed
-- too, so one character can test the join flow alone.
function BL.Books()
    local t0 = now()
    local d = db()
    local skip = {}
    for code, bc in pairs(d and d.cache and d.cache.books or {}) do
        if bc.status == "requested" or bc.status == "active" then skip[code] = true end
    end
    local list = {}
    local function add(entry, age) local e = {}; for k, v in pairs(entry) do e[k] = v end; e.age = age; list[#list + 1] = e end
    for code, r in pairs(rooms) do
        if t0 - r.seen > ROOM_TTL then rooms[code] = nil
        elseif not skip[code] and r.entry.owner ~= me() then add(r.entry, t0 - r.seen) end
    end
    if d and d.loopback == true then
        for _, e in ipairs(myEntries()) do if not skip[e.code] then add(e, 0) end end
    end
    table.sort(list, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.code < b.code
    end)
    return list
end

local handlers = {}

function handlers.LOBBY_ASK()
    if now() - lastAnnounce >= 2 then BL.Announce() end
end

function handlers.LOBBY_BOOKS(sender, p)
    for _, e in ipairs(p.books) do
        if baseName(sender) == baseName(e.owner) then rooms[e.code] = { entry = e, seen = now() } end   -- only the owner may list their book
    end
end

local registered
function BL.Init()
    if registered or not (ns.Comm and ns.Comm.Register) then return end
    registered = true
    for msgType, fn in pairs(handlers) do
        ns.Comm.Register(msgType, function(sender, payload, code)
            fn(sender, payload, code)
            changed()
        end)
    end
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(ANNOUNCE_EVERY, BL.Announce) end
    if C_Timer and C_Timer.After then C_Timer.After(20, BL.Announce) end        -- once the channels are up after login
    if ns.BookieNet and ns.BookieNet.CreateBook then
        local create = ns.BookieNet.CreateBook
        ns.BookieNet.CreateBook = function(...)               -- a new book goes on the list at once
            local book, err = create(...)
            if book then BL.Announce() end
            return book, err
        end
    end
    if ns.BookieNet and ns.BookieNet.Subscribe then
        local last = 0
        ns.BookieNet.Subscribe(function()                                       -- a new book, a new member, a new market
            if now() - last >= 10 then last = now(); BL.Announce() end
        end)
    end
end

return BL
