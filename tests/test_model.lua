-- Run from repo root: lua5.1 tests/test_model.lua
package.path = "SteveBook/?.lua;" .. package.path
local ns = {}
assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)   -- Model.NormalizeCode needs Protocol.CanonicalCode
local Model = assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; print("FAIL: " .. label) end
end
local function eq(got, want, label)
    check(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
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

-- a code typed any reasonable way finds the same book (Protocol.CanonicalCode)
local bare = (b.code:gsub("%-", ""))
check(bare ~= b.code and #bare == 7, "test setup: the bare code has no hyphen: " .. bare)
eq(Model.NormalizeCode(bare), b.code, "NormalizeCode puts the hyphen back")
eq(Model.NormalizeCode(" " .. bare:lower():sub(1, 3) .. " " .. bare:lower():sub(4) .. " "), b.code, "spaces and case")
eq(Model.NormalizeCode(b.code), b.code, "canonical code is unchanged")
check(Model.FindByCode(db, bare) == b, "FindByCode accepts a code typed without the hyphen")
check(Model.FindByCode(db, bare:lower()) == b, "FindByCode accepts lowercase without the hyphen")
check(Model.FindByCode(db, " " .. b.code:lower() .. " ") == b, "FindByCode accepts spaces and lowercase")
check(Model.FindByCode(db, "ZZZ-9999") == nil, "unknown code finds nothing")
check(Model.FindByCode(db, "") == nil and Model.FindByCode(db, nil) == nil, "empty code finds nothing")
check(Model.PickBook(db, bare) == b and db.activeBook == b.id, "PickBook accepts a code without the hyphen")
-- generated codes are canonical, so they survive the round trip
for _ = 1, 50 do
    local c = Model.GenerateCode("NFL", nil, function(n) return math.random(n) end)
    if Model.NormalizeCode(c) ~= c then fails = fails + 1; print("FAIL: generated code is not canonical: " .. c); break end
end

if fails == 0 then print("all tests passed") else os.exit(1) end
