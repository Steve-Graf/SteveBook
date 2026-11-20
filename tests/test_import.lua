-- Run from repo root: lua5.1 tests/test_import.lua
-- Expected epochs below came from GNU `date -u -d ...` (independent of Import.lua). The result
-- must not depend on the machine's timezone: try `TZ=Pacific/Auckland lua5.1 tests/test_import.lua`.
local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)   -- Model.NormalizeCode needs Protocol.CanonicalCode
local Model = assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)
local Bookie = assert(loadfile("SteveBook/Bookie.lua"))("SteveBook", ns)
local Import = assert(loadfile("SteveBook/Import.lua"))("SteveBook", ns)

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; print("FAIL: " .. label) end
end
local function eq(got, want, label)
    check(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

-- times -----------------------------------------------------------------------------------
local P = Import.ParseTime
eq(P("1970-01-01T00:00:00Z"), 0, "epoch")
eq(P("2000-02-29T12:00:00Z"), 951825600, "leap day 2000")
eq(P("2026-11-26T16:30-05:00"), 1795728600, "SPEC example (EST)")
eq(P("2026-11-26T16:30:00-05:00"), 1795728600, "with seconds")
eq(P("2026-11-26T16:30:00+05:30"), 1795690800, "half-hour positive offset")
eq(P("2026-11-26T16:30:00+0530"), 1795690800, "offset without colon")
eq(P("2024-02-29T23:59:59-12:00"), 1709294399, "leap day, extreme offset, rolls into March")
eq(P("2026-03-08T02:30-08:00"), 1772965800, "a local-time DST gap is irrelevant with an explicit offset")
eq(P("2100-03-01T00:00:00Z"), 4107542400, "2100 is not a leap year")
eq(P("2026-12-31T23:59:00Z"), 1798761540, "end of year")
eq(P("2027-01-01T00:00:00Z"), 1798761600, "start of next year")
eq(P("2026-11-26t21:30z"), 1795728600, "lowercase t and z")
eq(P("2026-11-26T16:30Z"), 1795710600, "16:30Z is 5h earlier than 16:30-05:00")
eq(P("  2026-11-26T16:30-05:00  "), 1795728600, "surrounding spaces")
eq(P("2026-11-26T21:30:00Z"), P("2026-11-26T16:30-05:00"), "Z and offset forms agree")

local function badTime(s, want, label)
    local v, err = P(s)
    check(v == nil and err and err:find(want, 1, true), label .. ": " .. tostring(err))
end
badTime("2026-11-26T16:30", "UTC offset or Z is required", "no offset")
badTime("2026-11-26", "must look like", "date only")
badTime("tomorrow", "must look like", "junk")
badTime("", "must look like", "empty")
badTime("2026-02-30T10:00Z", "day out of range", "Feb 30")
badTime("2025-02-29T10:00Z", "day out of range", "Feb 29, non-leap")
badTime("2100-02-29T10:00Z", "day out of range", "Feb 29, 2100")
badTime("2026-04-31T10:00Z", "day out of range", "Apr 31")
badTime("2026-13-01T10:00Z", "month out of range", "month 13")
badTime("2026-00-10T10:00Z", "month out of range", "month 0")
badTime("2026-11-26T24:00Z", "time of day out of range", "hour 24")
badTime("2026-11-26T16:60Z", "time of day out of range", "minute 60")
badTime("2026-11-26T16:30:60Z", "time of day out of range", "second 60")
badTime("1969-12-31T23:00Z", "year out of range", "before 1970")
badTime("2026-11-26T16:30+24:00", "offset out of range", "offset hour 24")
badTime("2026-11-26T16:30+05:60", "offset out of range", "offset minute 60")
badTime("2026-11-26T16:30+5", "UTC offset or Z is required", "short offset")

-- the SPEC §7 sample, with comments, blanks and Windows line endings ----------------------------
local NOW = P("2026-11-20T00:00:00Z")
local sample = table.concat({
    "# NFL week 12",
    "ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130",
    "",
    "SPREAD|NFL|PHI @ DAL|2026-11-26T16:30-05:00|-3.5|PHI:-110|DAL:-110",
    "   # indented comment",
    "TOTAL|NFL|PHI @ DAL|2026-11-26T16:30-05:00|47.5|Over:-110|Under:-110",
}, "\r\n")
local items = Import.Parse(sample, NOW)
eq(#items, 3, "three market lines")
eq(items[1].line, 2, "line numbers count comments and blanks")
eq(items[2].line, 4, "second market is on line 4")
eq(items[3].line, 6, "third market is on line 6")
local ml, sp, to = items[1].spec, items[2].spec, items[3].spec
check(ml and ml.type == "moneyline" and ml.sport == "NFL" and ml.event == "PHI @ DAL" and ml.line == nil, "ML spec")
check(ml and ml.closesAt == 1795728600, "ML close time")
check(ml and ml.selections[1].label == "PHI" and ml.selections[1].odds == -150 and ml.selections[2].label == "DAL" and ml.selections[2].odds == 130, "ML sides")
check(sp and sp.type == "spread" and sp.line == -3.5 and sp.selections[1].odds == -110 and sp.selections[2].odds == -110, "spread: line is for side 1")
check(to and to.type == "total" and to.line == 47.5 and to.selections[1].label == "Over" and to.selections[2].label == "Under", "total")

-- every parsed spec is accepted by the real AddMarket
local book = Model.CreateBook(Model.NewDB(), "NFL", "Steve", NOW)
for i, it in ipairs(items) do check(Bookie.AddMarket(book, it.spec, NOW), "AddMarket accepts imported spec " .. i) end

-- case, spacing, labels with colons -------------------------------------------------------------
local odd = Import.Parse("moneyline | nfl | NYG @ WAS | 2026-11-26T13:00Z | Team A: Red : +120 | Team B:-140", NOW)
check(odd[1].spec and odd[1].spec.selections[1].label == "Team A: Red" and odd[1].spec.selections[1].odds == 120, "label may contain a colon; spaces and case are forgiven: " .. tostring(odd[1].err))
eq(odd[1].spec and odd[1].spec.sport, "nfl", "sport kept as written")
local ints = Import.Parse("TOTAL|NBA|A @ B|2026-11-26T13:00Z|215|Over:-110|Under:-110", NOW)
eq(ints[1].spec and ints[1].spec.line, 215, "integer line")
local pos = Import.Parse("SPREAD|NBA|A @ B|2026-11-26T13:00Z|+6.5|A:-110|B:-110", NOW)
eq(pos[1].spec and pos[1].spec.line, 6.5, "signed positive line")

-- invalid lines are reported, not imported -------------------------------------------------------
local function bad(line, want, label, now)
    local it = Import.Parse(line, now == nil and NOW or now)[1]
    check(it and it.spec == nil and it.err and it.err:find(want, 1, true), label .. ": " .. tostring(it and it.err))
end
bad("PARLAY|NFL|x|2026-11-26T16:30Z|a:-110|b:-110", 'unknown market type "PARLAY"', "unknown type")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-150", "need 6", "ML missing a field")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|-3.5|PHI:-150|DAL:+130", "need 6", "ML with a line field")
bad("SPREAD|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-110|DAL:-110", "need 7", "spread without a line")
-- an empty field typed in game arrives as "||||" (each "|" doubled); "||" alone is one separator
bad("ML|NFL||||2026-11-26T16:30Z|PHI:-150|DAL:+130", "event is empty", "empty event")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30|PHI:-150|DAL:+130", "UTC offset", "time without an offset")
bad("ML|NFL|PHI @ DAL|2026-02-30T16:30Z|PHI:-150|DAL:+130", "day out of range", "impossible date")
bad("ML|NFL|PHI @ DAL|2026-11-19T16:30Z|PHI:-150|DAL:+130", "already passed", "already closed")
bad("SPREAD|NFL|PHI @ DAL|2026-11-26T16:30Z|big|PHI:-110|DAL:-110", 'line "big"', "junk line")
bad("SPREAD|NFL|PHI @ DAL|2026-11-26T16:30Z|inf|PHI:-110|DAL:-110", 'line "inf"', "inf line")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI -150|DAL:+130", 'side "PHI -150"', "side without a colon")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|:-150|DAL:+130", "should look like", "side without a name")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-50|DAL:+130", "not valid American odds", "odds between -100 and +100")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:abc|DAL:+130", "should look like", "odds not a number")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-150|PHI:+130", "different names", "same side twice")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-150|DAL:+130|", "need 6", "trailing separator")
bad("GB1:abcdef", "not supported yet", "encoded string")
bad("|||", "unknown market type", "separators only")
-- without a `now`, the past-close check is skipped (callers that don't know the time)
check(Import.Parse("ML|NFL|PHI @ DAL|2026-11-19T16:30Z|PHI:-150|DAL:+130", nil)[1].spec ~= nil, "no `now`: no close check")

-- a mixed paste keeps the good lines and reports the bad ones with their line numbers ----------------
local mixed = Import.Parse("ML|NFL|A @ B|2026-11-26T16:30Z|A:-150|B:+130\nnonsense\nML|NFL|C @ D|2026-11-26T16:30Z|C:-150|D:+130", NOW)
check(#mixed == 3 and mixed[1].spec and mixed[2].err and mixed[2].line == 2 and mixed[3].spec, "mixed paste: good lines survive a bad one")
eq(#Import.Parse("", NOW), 0, "empty paste")
eq(#Import.Parse("# only a comment\n\n   \n", NOW), 0, "comments only")
eq(#Import.Parse(nil, NOW), 0, "nil paste")

-- plan: duplicates against the book and within the paste -------------------------------------------
local pbook = Model.CreateBook(Model.NewDB(), "X", "Steve", NOW)
local text = "ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130\n"
          .. "ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130\n"      -- repeated in the same paste
          .. "SPREAD|NFL|PHI @ DAL|2026-11-26T16:30-05:00|-3.5|PHI:-110|DAL:-110\n"
          .. "SPREAD|NFL|PHI @ DAL|2026-11-26T16:30-05:00|-4|PHI:-110|DAL:-110\n"   -- different line: not a duplicate
          .. "oops"
local plan = Import.Plan(pbook, text, NOW)
eq(plan.ok, 3, "plan: ok count")
eq(plan.duplicate, 1, "plan: duplicate within the paste")
eq(plan.errors, 1, "plan: error count")
eq(plan.items[1].status, "ok", "first line ok")
eq(plan.items[2].status, "duplicate", "repeat is a duplicate")
eq(plan.items[5].status, "error", "junk is an error")
for _, it in ipairs(plan.items) do if it.status == "ok" then assert(Bookie.AddMarket(pbook, it.spec, NOW)) end end
local again = Import.Plan(pbook, text, NOW)
eq(again.ok, 0, "re-importing the same paste imports nothing")
eq(again.duplicate, 4, "all four market lines are now duplicates of existing markets")
local other = Import.Plan(pbook, "ML|NFL|phi @ dal|2026-11-26T16:30-05:00|PHI:-150|DAL:+130", NOW)
eq(other.duplicate, 1, "duplicate check ignores event case")
local later = Import.Plan(pbook, "ML|NFL|PHI @ DAL|2026-11-26T16:35-05:00|PHI:-150|DAL:+130", NOW)
eq(later.ok, 1, "same game at a different time is not a duplicate")

-- WoW edit boxes double every "|" (so a pasted line arrives as ML||NFL||...)
local dbl = Import.Parse("ML||NFL||PHI @ DAL||2026-11-26T16:30-05:00||PHI:-150||DAL:+130\nTOTAL||NFL||PHI @ DAL||2026-11-26T16:30-05:00||47.5||Over:-110||Under:-110", NOW)
eq(#dbl, 2, "doubled pipes: two lines")
check(dbl[1].spec ~= nil, "doubled pipes: ML parses: " .. tostring(dbl[1].err))
check(dbl[2].spec ~= nil, "doubled pipes: total parses: " .. tostring(dbl[2].err))
eq(dbl[1].text, "ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130", "doubled pipes: shown with single pipes")

if fails == 0 then print("import: all tests passed") else os.exit(1) end
