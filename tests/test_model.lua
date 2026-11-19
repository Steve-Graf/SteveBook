-- Run from repo root: lua5.1 tests/test_model.lua
package.path = "SteveBook/?.lua;" .. package.path
local ns = {}
local Model = assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; print("FAIL: " .. label) end
end

local db = Model.NewDB()
local seq = 0
local function rand(n) seq = seq + 1; return (seq % n) + 1 end

local b = Model.CreateBook(db, "  NFL Week 12 ", "Steve", 1000, rand)
check(b and b.code:match("^NFL%-[A-Z2-9]+$") and #b.code == 8, "code format: " .. tostring(b and b.code))
check(not b.code:sub(5):find("[01OIL]"), "no ambiguous chars")
check(db.activeBook == b.id, "new book becomes active")
check(Model.FindByCode(db, " " .. b.code:lower() .. " ") == b, "code lookup normalizes")
check(select(2, Model.CreateBook(db, "  ", "Steve", 1)) == "book name required", "empty name rejected")

local b2 = Model.CreateBook(db, "x", "Steve", 1001, rand)
check(b2.code:match("^XXX%-"), "short name padded")
check(b2.id ~= b.id, "unique ids")

-- collision handling: constant rand forces retries, must error out eventually
local ok = pcall(Model.GenerateCode, "NFL", function() return true end, rand)
check(not ok, "errors when no unique code")

check(Model.PickBook(db, 1) == b and db.activeBook == b.id, "pick by index")
check(Model.PickBook(db, b2.code) == b2 and db.activeBook == b2.id, "pick by code")
check(select(2, Model.PickBook(db, "nope")) == "no such book", "pick missing")

if fails == 0 then print("all tests passed") else os.exit(1) end
