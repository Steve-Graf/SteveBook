-- The list of sportsbooks to join, through the real Comm. Run from repo root: luajit tests/test_book_lobby.lua
local stub = assert(loadfile("tests/wowstub.lua"))()
local out_ = stub.realPrint
local fails = 0
local function check(cond, label) if not cond then fails = fails + 1; out_("FAIL: " .. label) end end
local function eq(a, b, label) if a ~= b then fails = fails + 1; out_(("FAIL: %s (got %s, want %s)"):format(label, tostring(a), tostring(b))) end end

Minimap = stub.newFrame()
Ambiguate = function(name) return (name:gsub("%-Realm$", "")) end
local ADDON, DIR = "SteveBook", "SteveBook/"
local ns = {}
local function readFile(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
local loadFile
local function loadXml(path)
    local dir = path:match("^(.*)/[^/]*$") or "."
    for file in readFile(path):gmatch('<[SI][a-z]+%s+file="([^"]+)"') do loadFile(dir .. "/" .. file:gsub("\\", "/")) end
end
function loadFile(path)
    path = path:gsub("\\", "/")
    if path:match("%.xml$") then return loadXml(path) end
    local ok, e = pcall(assert(loadfile(path)), ADDON, ns)
    check(ok, "load " .. path .. (ok and "" or (": " .. tostring(e))))
end
for line in readFile(DIR .. "SteveBook.toc"):gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then loadFile(DIR .. line) end
end
stub.fire("ADDON_LOADED", ADDON)
local db = SteveBookDB
local BL, P = ns.BookLobby, ns.Protocol
local AceSer = LibStub("AceSerializer-3.0")
local function settle() for _ = 1, 25 do stub.advance(1); stub.runAfters() end end
local function fromWire(sender, msgType, payload)
    local env = assert(P.Wrap(msgType, P.LOBBY_CODE, payload))
    stub.fire("CHAT_MSG_ADDON", "SteveBook", AceSer:Serialize(env), "CHANNEL", sender)
end
local function codes(list) local c = {}; for _, e in ipairs(list) do c[e.code] = e end; return c end
-- What an outgoing addon message says (large ones are deflated; see Comm.lua).
local Deflate = LibStub("LibDeflate")
local function decode(text)
    if text:sub(1, 3) == "ZD1" then return AceSer:Deserialize(Deflate:DecompressDeflate(Deflate:DecodeForWoWAddonChannel(text:sub(4)))) end
    return AceSer:Deserialize(text)
end
local function lobbyMessages(msgType)
    local n = 0
    for _, m in ipairs(stub.addonMessages) do
        local ok, env = decode(m.text)
        if ok and type(env) == "table" and env.t == msgType and env.c == P.LOBBY_CODE then n = n + 1 end
    end
    return n
end

check(BL and BL.Books and BL.Ask and BL.Announce and BL.Subscribe, "BookLobby exposes its functions")
eq(#BL.Books(), 0, "nothing listed to start with")

-- announcements from other bookies
local entry = { code = "NFL-AAAA", name = "Burgers", owner = "Dealer", members = 4, markets = 9 }
local changes = 0
BL.Subscribe(function() changes = changes + 1 end)
fromWire("Dealer lol", "LOBBY_BOOKS", { books = { entry } })
local list = BL.Books()
eq(#list, 1, "an announced book is listed"); eq(list[1].name, "Burgers", "name"); eq(list[1].owner, "Dealer", "owner")
eq(list[1].members, 4, "members"); eq(list[1].markets, 9, "markets"); check(changes > 0, "listeners are told")
fromWire("Mallory lol", "LOBBY_BOOKS", { books = { { code = "NFL-EVIL", name = "Evil", owner = "Dealer" } } })
eq(codes(BL.Books())["NFL-EVIL"], nil, "only the owner may list their book")

-- expiry and refresh
stub.advance(101)
eq(#BL.Books(), 0, "a listing expires when the owner stops announcing")
fromWire("Dealer lol", "LOBBY_BOOKS", { books = { entry } }); stub.advance(60)
fromWire("Dealer lol", "LOBBY_BOOKS", { books = { entry } }); stub.advance(60)
eq(#BL.Books(), 1, "a fresh announcement keeps it listed")

-- books I already asked to join are left out
local Cache = ns.Cache
Cache.RequestJoin(db.cache, "NFL-AAAA")
eq(#BL.Books(), 0, "a book I asked to join is not offered again")
Cache.Forget(db.cache, "NFL-AAAA")
eq(#BL.Books(), 1, "forgetting it offers it again")

-- my own books are announced
SlashCmdList.STEVEBOOK("new Test Book")
local book = ns.Model.ListBooks(db)[1]
stub.addonMessages = {}
BL.Announce(); settle()
check(lobbyMessages("LOBBY_BOOKS") >= 1, "my book was announced to the lobby")
check(stub.channels[P.ChannelName(P.LOBBY_CODE)] ~= nil, "the bookie joined the lobby channel")
-- the announcement carries the right facts
do
    local found
    for _, m in ipairs(stub.addonMessages) do
        local ok, env = decode(m.text)
        if ok and env.t == "LOBBY_BOOKS" then found = env.p.books[1] end
    end
    check(found ~= nil, "the announcement can be read"); eq(found and found.code, book.code, "code"); eq(found and found.name, "Test Book", "name")
    eq(found and found.owner, stub.player, "owner"); eq(found and found.members, 0, "no members yet")
end
-- hidden books are not announced
SlashCmdList.STEVEBOOK("hide")
check(book.unlisted == true, "/book hide hides the active book")
stub.addonMessages = {}; stub.advance(10)
BL.Announce(); settle()
eq(lobbyMessages("LOBBY_BOOKS"), 0, "a hidden book is not announced")
SlashCmdList.STEVEBOOK("hide")
check(not book.unlisted, "/book hide again lists it")
-- an ask makes the bookie announce, and asks that arrive together are answered once
stub.advance(10); stub.addonMessages = {}
fromWire("Friend lol", "LOBBY_ASK", {}); fromWire("Other lol", "LOBBY_ASK", {}); fromWire("Third lol", "LOBBY_ASK", {})
settle()
eq(lobbyMessages("LOBBY_BOOKS"), 1, "a LOBBY_ASK makes the bookie announce, once for a burst of asks")
-- asking
stub.addonMessages = {}
BL.Ask(); settle()
eq(lobbyMessages("LOBBY_ASK"), 1, "Ask sends a LOBBY_ASK")
-- my own book is not offered to me, except in loopback
eq(codes(BL.Books())[book.code], nil, "my own book is not on my list")
SlashCmdList.STEVEBOOK("loopback")
check(codes(BL.Books())[book.code] ~= nil, "with loopback on my own book is listed so I can test joining")
SlashCmdList.STEVEBOOK("loopback")
-- a new book is announced on its own (a change in the book)
stub.advance(20)
stub.addonMessages = {}
SteveBookDB.casino = SteveBookDB.casino
ns.BookieNet.CreateBook("Another Book"); settle()
check(lobbyMessages("LOBBY_BOOKS") >= 1, "creating a book announces it")

eq(#stub.errors, 0, "no errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_book_lobby: all passed") else out_(fails .. " FAILED"); os.exit(1) end
