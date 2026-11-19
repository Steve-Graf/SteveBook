-- Model.lua: books, join codes. Pure logic: no WoW API calls, testable with plain lua5.1.
local ADDON, ns = ...
ns = ns or {}

local Model = {}
ns.Model = Model

-- Unambiguous alphabet (no 0/O, 1/I/L).
local ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

-- Random suffix of `len` chars. `rand(n)` returns an integer in 1..n (injectable for tests).
local function randomSuffix(len, rand)
    local out = {}
    for i = 1, len do
        local k = rand(#ALPHABET)
        out[i] = ALPHABET:sub(k, k)
    end
    return table.concat(out)
end

-- Prefix: first 3 letters/digits of the name, uppercased, padded with "X".
local function codePrefix(name)
    local p = (name or ""):upper():gsub("[^A-Z0-9]", ""):sub(1, 3)
    while #p < 3 do p = p .. "X" end
    return p
end

-- e.g. "NFL-K7Q2". `taken(code)` returns true if code already exists.
function Model.GenerateCode(name, taken, rand)
    rand = rand or function(n) return math.random(n) end
    local prefix = codePrefix(name)
    for _ = 1, 100 do
        local code = prefix .. "-" .. randomSuffix(4, rand)
        if not (taken and taken(code)) then return code end
    end
    error("could not generate a unique join code")
end

-- "NFLK7Q2", " nfl k7q2 " and "NFL-K7Q2" are the same book: Protocol.CanonicalCode decides how a
-- code is written. Protocol.lua loads before Model.lua (read at call time, not at load).
function Model.NormalizeCode(code)
    return ns.Protocol.CanonicalCode(code)
end

-- db = { books = { [id] = Book }, nextBookId = n, activeBook = id|nil }
function Model.NewDB()
    return { books = {}, nextBookId = 1, activeBook = nil }
end

function Model.FindByCode(db, code)
    code = Model.NormalizeCode(code)
    for _, b in pairs(db.books) do
        if b.code == code then return b end
    end
end

function Model.CreateBook(db, name, owner, now, rand)
    name = (name or ""):match("^%s*(.-)%s*$")
    if name == "" then return nil, "book name required" end
    local id = db.nextBookId
    db.nextBookId = id + 1
    local book = {
        id = id,
        code = Model.GenerateCode(name, function(c) return Model.FindByCode(db, c) ~= nil end, rand),
        name = name,
        ownerName = owner,
        createdAt = now,
        members = {},
        markets = {},
        bets = {},
        ledger = {},
        rev = 0,
    }
    db.books[id] = book
    db.activeBook = id
    return book
end

-- Books sorted by id, for stable numbering in the UI/chat.
function Model.ListBooks(db)
    local list = {}
    for _, b in pairs(db.books) do list[#list + 1] = b end
    table.sort(list, function(a, c) return a.id < c.id end)
    return list
end

-- ref: list index (number or numeric string) or join code.
function Model.PickBook(db, ref)
    local book
    local n = tonumber(ref)
    if n then book = Model.ListBooks(db)[n] else book = Model.FindByCode(db, ref) end
    if not book then return nil, "no such book" end
    db.activeBook = book.id
    return book
end

function Model.ActiveBook(db)
    return db.activeBook and db.books[db.activeBook] or nil
end

return Model
