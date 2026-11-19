-- Run from repo root: lua5.1 tests/test_bookie_forms.lua
local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)   -- Model.NormalizeCode needs Protocol.CanonicalCode
assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)
local Bookie = assert(loadfile("SteveBook/Bookie.lua"))("SteveBook", ns)

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; print("FAIL: " .. label) end
end
local function eq(got, want, label)
    check(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

-- durations
local D = Bookie.ParseDuration
eq(D("30m"), 1800, "30m")
eq(D("2h"), 7200, "2h")
eq(D("1d"), 86400, "1d")
eq(D("1h30m"), 5400, "1h30m")
eq(D(" 1D 2H "), 93600, "case and spaces")
eq(D("90"), 5400, "bare number is minutes")
eq(D("0m"), nil, "zero")
eq(D("0"), nil, "bare zero")
eq(D(""), nil, "empty")
eq(D("abc"), nil, "letters")
eq(D("2h2h"), nil, "repeated unit")
eq(D("h2"), nil, "unit first")
eq(D("1.5h"), nil, "fractional")
eq(D("-5m"), nil, "negative")
eq(D(nil), nil, "nil")

-- new-market form
local NOW = 5000
local function form(over)
    local f = { sport = " NFL ", event = " PHI @ DAL ", type = "spread", line = "-3.5",
                label1 = "PHI", odds1 = "-110", label2 = "DAL", odds2 = "+100", closes = "2h" }
    for k, v in pairs(over or {}) do f[k] = v end
    return f
end
local spec = Bookie.ParseMarketForm(form(), NOW)
check(spec and spec.sport == "NFL" and spec.event == "PHI @ DAL" and spec.type == "spread" and spec.line == -3.5, "spread spec")
check(spec and spec.closesAt == NOW + 7200, "closesAt = now + duration")
check(spec and spec.selections[1].label == "PHI" and spec.selections[1].odds == -110 and spec.selections[2].odds == 100, "selections")

-- and the spec is accepted by the real AddMarket
local book = { members = {}, markets = {}, bets = {}, ledger = {}, rev = 0 }
check(Bookie.AddMarket(book, spec, NOW), "AddMarket accepts a parsed spec")

local ml = Bookie.ParseMarketForm(form({ type = "moneyline", line = "" }), NOW)
check(ml and ml.line == nil, "moneyline ignores the line box")
check(Bookie.ParseMarketForm(form({ type = "total", line = "47.5", label1 = "Over", label2 = "Under" }), NOW).line == 47.5, "total line")
eq(Bookie.ParseMarketForm(form({ line = "47" }), NOW).line, 47, "integer line")
eq(Bookie.ParseMarketForm(form({ line = "+3" }), NOW).line, 3, "signed line")

local function bad(over, want, label)
    local s, err = Bookie.ParseMarketForm(form(over), NOW)
    check(s == nil and err and err:find(want, 1, true), label .. ": " .. tostring(err))
end
bad({ event = "  " }, "Event is required", "no event")
bad({ type = "parlay" }, "market type", "bad type")
bad({ label2 = "" }, "Both sides", "missing side")
bad({ label2 = "PHI" }, "different names", "same names")
bad({ event = "PHI | DAL" }, "can't contain the |", "pipe in event")
bad({ label1 = "P|HI" }, "can't contain the |", "pipe in a side name")
bad({ sport = "N|FL" }, "can't contain the |", "pipe in sport")
bad({ odds1 = "50" }, "Odds look like", "odds too small")
bad({ odds2 = "abc" }, "Odds look like", "odds junk")
bad({ line = "" }, "Line must be", "spread without line")
bad({ line = "abc" }, "Line must be", "junk line")
bad({ line = "inf" }, "Line must be", "inf line")
bad({ line = "0x10" }, "Line must be", "hex line")
bad({ closes = "" }, "Closes in", "no close time")
bad({ closes = "soon" }, "Closes in", "junk close time")

-- edit form
local m = { type = "spread", line = -3.5, selections = { { id = 1, odds = -110 }, { id = 2, odds = 100 } } }
local ch = Bookie.ParseEditForm(m, { odds1 = "-120", odds2 = "100", line = "-3.5", closes = "" }, NOW)
check(ch and ch.odds and ch.odds[1] == -120 and ch.odds[2] == nil and ch.line == nil and ch.closesAt == nil, "only changed fields")
ch = Bookie.ParseEditForm(m, { odds1 = "", odds2 = "", line = "-4", closes = "1h" }, NOW)
check(ch and ch.line == -4 and ch.closesAt == NOW + 3600 and ch.odds == nil, "line and close time")
eq(select(2, Bookie.ParseEditForm(m, { odds1 = "-110", odds2 = "+100", line = "-3.5", closes = "" }, NOW)), "Nothing to change.", "no-op edit")
eq(select(2, Bookie.ParseEditForm(m, {}, NOW)), "Nothing to change.", "empty edit")
check(select(2, Bookie.ParseEditForm(m, { odds1 = "7" }, NOW)):find("Odds look like"), "edit: bad odds")
check(select(2, Bookie.ParseEditForm(m, { line = "x" }, NOW)):find("Line must be"), "edit: bad line")
check(select(2, Bookie.ParseEditForm(m, { closes = "x" }, NOW)):find("Closes in"), "edit: bad close")
local mlm = { type = "moneyline", selections = { { id = 1, odds = -150 }, { id = 2, odds = 130 } } }
eq(Bookie.ParseEditForm(mlm, { line = "3", odds1 = "-160" }, NOW).line, nil, "moneyline edit ignores line")
-- the changes table is accepted by the real EditMarket
local mk = Bookie.AddMarket(book, spec, NOW)
check(Bookie.EditMarket(book, mk.id, Bookie.ParseEditForm(mk, { odds1 = "-125" }, NOW), NOW), "EditMarket accepts parsed changes")
eq(mk.selections[1].odds, -125, "edit applied")

-- credit limit input
local pm = ns.Odds.ParseMoney
eq(Bookie.ParseLimit("", pm), nil, "blank clears limit")
eq(Bookie.ParseLimit("  ", pm), nil, "spaces clear limit")
eq(Bookie.ParseLimit("50g", pm), 500000, "50g")
local v, err = Bookie.ParseLimit("zero", pm)
check(v == false and err:find("Enter an amount"), "junk limit rejected")
check(Bookie.ParseLimit("0", pm) == false, "zero limit rejected")

if fails == 0 then print("bookie_forms: all tests passed") else os.exit(1) end
