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
bad("PARLAY|NFL|x|2026-11-26T16:30Z|a:-110|b:-110", 'unknown line type "PARLAY"', "unknown type")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-150", "need 6", "ML missing a field")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|-3.5|PHI:-150|DAL:+130", "need 6", "ML with a line field")
bad("SPREAD|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-110|DAL:-110", "need 7", "spread without a line")
-- an empty field typed in game arrives as "||||" (each "|" doubled); "||" alone is one separator
bad("ML|NFL||||2026-11-26T16:30Z|PHI:-150|DAL:+130", "event is empty", "empty event")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30|PHI:-150|DAL:+130", "UTC offset", "time without an offset")
bad("ML|NFL|PHI @ DAL|2026-02-30T16:30Z|PHI:-150|DAL:+130", "day out of range", "impossible date")
-- a game that has already started is not an error: it comes back with its spec, flagged `started`
do
    local it = Import.Parse("ML|NFL|PHI @ DAL|2026-11-19T16:30Z|PHI:-150|DAL:+130", NOW)[1]
    check(it.spec and it.err == nil and it.started == true, "past close time: spec kept, flagged started")
    local live = Import.Parse("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-150|DAL:+130", NOW)[1]
    check(live.spec and live.started == nil, "future close time: not flagged")
    local edge = Import.Parse("ML|NFL|PHI @ DAL|2026-11-20T00:00Z|PHI:-150|DAL:+130", NOW)[1]
    check(edge.started == true, "closing exactly now counts as started (the game is on)")
    local junk = Import.Parse("ML|NFL|PHI @ DAL|2026-11-19T16:30Z|nope|DAL:+130", NOW)[1]
    check(junk.spec == nil and junk.err and junk.started == nil, "a malformed line is an error, never `started`")
end
bad("SPREAD|NFL|PHI @ DAL|2026-11-26T16:30Z|big|PHI:-110|DAL:-110", 'line "big"', "junk line")
bad("SPREAD|NFL|PHI @ DAL|2026-11-26T16:30Z|inf|PHI:-110|DAL:-110", 'line "inf"', "inf line")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI -150|DAL:+130", 'side "PHI -150"', "side without a colon")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|:-150|DAL:+130", "should look like", "side without a name")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-50|DAL:+130", "not valid American odds", "odds between -100 and +100")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:abc|DAL:+130", "should look like", "odds not a number")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-150|PHI:+130", "different names", "same side twice")
bad("ML|NFL|PHI @ DAL|2026-11-26T16:30Z|PHI:-150|DAL:+130|", "need 6", "trailing separator")
bad("GB1:abcdef", "not supported yet", "encoded string")
bad("|||", "unknown line type", "separators only")
-- without a `now`, nothing counts as started (callers that don't know the time)
check(Import.Parse("ML|NFL|PHI @ DAL|2026-11-19T16:30Z|PHI:-150|DAL:+130", nil)[1].started == nil, "no `now`: nothing is started")

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

-- plan: updating lines. A line that matches an open market with different odds changes its odds ----------
do
    local ubook = Model.CreateBook(Model.NewDB(), "U", "Steve", NOW)
    local function add(kind, event, closes, line, l1, o1, l2, o2)
        return assert(Bookie.AddMarket(ubook, { sport = "NFL", event = event, type = kind, line = line, closesAt = closes,
            selections = { { label = l1, odds = o1 }, { label = l2, odds = o2 } } }, NOW))
    end
    local T1 = P("2026-11-26T16:30-05:00")
    local ml1 = add("moneyline", "PHI @ DAL", T1, nil, "PHI", -150, "DAL", 130)
    local sp1 = add("spread", "PHI @ DAL", T1, -3.5, "PHI", -110, "DAL", -110)
    local to1 = add("total", "PHI @ DAL", T1, 47.5, "Over", -110, "Under", -110)
    local line = function(...) return table.concat({ ... }, "|") end
    local when = "2026-11-26T16:30-05:00"

    local plan = Import.Plan(ubook, table.concat({
        line("ML", "NFL", "PHI @ DAL", when, "PHI:-160", "DAL:+140"),              -- both sides moved
        line("SPREAD", "NFL", "PHI @ DAL", when, "-3.5", "PHI:-110", "DAL:-115"),   -- one side moved
        line("TOTAL", "NFL", "PHI @ DAL", when, "47.5", "Over:-110", "Under:-110"), -- identical
        line("ML", "NFL", "NYG @ WAS", when, "NYG:-120", "WAS:+100"),               -- new
        line("ML", "NFL", "OLD @ GAME", "2026-11-19T16:30Z", "OLD:-120", "GAME:+100"), -- already started
        "garbage",
    }, "\n"), NOW)
    eq(plan.ok, 1, "update plan: one new market")
    eq(plan.updated, 2, "update plan: two updates")
    eq(plan.duplicate, 1, "update plan: one identical line is a duplicate")
    eq(plan.started, 1, "update plan: one started game skipped")
    eq(plan.errors, 1, "update plan: one error")
    local it = plan.items
    eq(it[1].status, "update", "ML with new odds is an update")
    eq(it[1].marketId, ml1.id, "...of the existing ML market")
    check(it[1].changes[1] == -160 and it[1].changes[2] == 140, "...with both new prices")
    check(it[1].before[1] == -150 and it[1].before[2] == 130, "...and remembers the old ones for the preview")
    eq(it[2].status, "update", "spread with one side moved is an update")
    check(it[2].changes[1] == nil and it[2].changes[2] == -115, "...changing only the side that moved")
    eq(it[3].status, "duplicate", "an identical line is a duplicate")
    eq(it[4].status, "ok", "an unknown game is new")
    eq(it[5].status, "started", "an old game is skipped as started")
    check(it[5].spec ~= nil and it[5].why:find("started"), "...with the reason")
    eq(it[6].status, "error", "junk is an error")

    -- the plan itself changes nothing
    eq(ml1.selections[1].odds, -150, "planning does not touch the book")

    -- never touches a market that is not open
    Bookie.Lock(ubook, sp1.id)
    plan = Import.Plan(ubook, line("SPREAD", "NFL", "PHI @ DAL", when, "-3.5", "PHI:-120", "DAL:-100"), NOW)
    eq(plan.started, 1, "a locked market is skipped, not updated")
    check(plan.items[1].status == "started" and plan.items[1].why:find("locked"), "...because it is locked: " .. tostring(plan.items[1].why))
    plan = Import.Plan(ubook, line("SPREAD", "NFL", "PHI @ DAL", when, "-3.5", "PHI:-110", "DAL:-110"), NOW)
    eq(plan.duplicate, 1, "an identical line for a locked market is a duplicate")
    Bookie.Settle(ubook, to1.id, 1, NOW)
    plan = Import.Plan(ubook, line("TOTAL", "NFL", "PHI @ DAL", when, "47.5", "Over:-120", "Under:+100"), NOW)
    check(plan.started == 1 and plan.items[1].why:find("settled"), "a settled market is skipped: " .. tostring(plan.items[1].why))
    -- ...and one whose game has started (stored status still open) is skipped too: the line has started
    plan = Import.Plan(ubook, line("ML", "NFL", "PHI @ DAL", when, "PHI:-170", "DAL:+150"), T1 + 1)
    check(plan.started == 1 and plan.updated == 0, "after the start nothing is updated")

    -- sides may come in the other order for a moneyline (and a total), never for a spread
    plan = Import.Plan(ubook, line("ML", "NFL", "PHI @ DAL", when, "DAL:+150", "PHI:-170"), NOW)
    eq(plan.items[1].status, "update", "swapped order still matches an ML")
    check(plan.items[1].changes[1] == -170 and plan.items[1].changes[2] == 150, "...and each price goes to the right side")
    local ubook2 = Model.CreateBook(Model.NewDB(), "U2", "Steve", NOW)
    assert(Bookie.AddMarket(ubook2, { sport = "NFL", event = "PHI @ DAL", type = "spread", line = -3.5, closesAt = T1,
        selections = { { label = "PHI", odds = -110 }, { label = "DAL", odds = -110 } } }, NOW))
    plan = Import.Plan(ubook2, line("SPREAD", "NFL", "PHI @ DAL", when, "-3.5", "DAL:-110", "PHI:-110"), NOW)
    check(plan.items[1].status == "error" and plan.items[1].err:find("sides are PHI / DAL"), "a swapped spread is a different bet, not an update: " .. tostring(plan.items[1].err))
    plan = Import.Plan(ubook2, line("SPREAD", "NFL", "PHI @ DAL", when, "-3.5", "Philadelphia:-110", "Dallas:-115"), NOW)
    check(plan.items[1].status == "error" and plan.errors == 1, "same game and line with different side names: reported, not guessed")
    plan = Import.Plan(ubook2, line("SPREAD", "NFL", "phi @ dal", when, "-3.5", "phi:-120", "dal:-100"), NOW)
    eq(plan.items[1].status, "update", "event and side names are matched ignoring case")

    -- a moved spread line updates the game's only spread in place (see the sole-market block below)
    plan = Import.Plan(ubook2, line("SPREAD", "NFL", "PHI @ DAL", when, "-4", "PHI:-110", "DAL:-110"), NOW)
    check(plan.items[1].status == "update" and plan.items[1].newLine == -4 and plan.items[1].beforeLine == -3.5,
          "a different spread line for the game's only spread is an update of its line")

    -- within one paste: the first line wins, later lines for the same market are duplicates
    plan = Import.Plan(ubook2, table.concat({
        line("SPREAD", "NFL", "PHI @ DAL", when, "-3.5", "PHI:-120", "DAL:-100"),
        line("SPREAD", "NFL", "PHI @ DAL", when, "-3.5", "PHI:-130", "DAL:+110"),
    }, "\n"), NOW)
    check(plan.items[1].status == "update" and plan.items[2].status == "duplicate", "a repeated line in one paste is a duplicate")

    -- every spec of an "ok" item is accepted by the real AddMarket, every update by the real EditMarket
    for _, item in ipairs(Import.Plan(ubook, line("ML", "NFL", "NEW @ TEAM", when, "NEW:-120", "TEAM:+100"), NOW).items) do
        check(item.status == "ok" and Bookie.AddMarket(ubook, item.spec, NOW), "ok item is addable")
    end
    plan = Import.Plan(ubook2, line("SPREAD", "NFL", "PHI @ DAL", when, "-3.5", "PHI:-120", "DAL:-100"), NOW)
    local upd = plan.items[1]
    check(Bookie.EditMarket(ubook2, upd.marketId, { odds = upd.changes }, NOW), "update item is editable")
    eq(ubook2.markets[upd.marketId].selections[1].odds, -120, "...and the market now has the new price")
    plan = Import.Plan(ubook2, line("SPREAD", "NFL", "PHI @ DAL", when, "-3.5", "PHI:-120", "DAL:-100"), NOW)
    eq(plan.duplicate, 1, "re-importing the same lines afterwards is a duplicate")
end

-- plan: lines move all day. SPREAD/TOTAL lines match by type + event + close time when the game has
-- exactly ONE market of that type; with two or more (alternate lines) the exact line is the key. ---------
do
    local when = "2026-11-26T16:30-05:00"
    local T1 = P(when)
    local line = function(...) return table.concat({ ... }, "|") end
    local function fresh()
        local b = Model.CreateBook(Model.NewDB(), "L", "Steve", NOW)
        local function add(kind, event, closes, ln, l1, o1, l2, o2)
            return assert(Bookie.AddMarket(b, { sport = "NFL", event = event, type = kind, line = ln, closesAt = closes,
                selections = { { label = l1, odds = o1 }, { label = l2, odds = o2 } } }, NOW))
        end
        return b, add
    end
    local SP = function(ln, o1, o2, event) return line("SPREAD", "NFL", event or "PHI @ DAL", when, ln, "PHI:" .. o1, "DAL:" .. o2) end
    local TO = function(ln, o1, o2, event) return line("TOTAL", "NFL", event or "PHI @ DAL", when, ln, "Over:" .. o1, "Under:" .. o2) end

    -- moved spread: line AND odds updated in place, market identity kept
    do
        local b, add = fresh()
        local sp = add("spread", "PHI @ DAL", T1, -3.5, "PHI", -110, "DAL", -110)
        local plan = Import.Plan(b, SP("-4.5", "-105", "-115"), NOW)
        local it = plan.items[1]
        eq(it.status, "update", "moved spread: update")
        eq(it.marketId, sp.id, "...of the existing spread")
        check(it.newLine == -4.5 and it.beforeLine == -3.5, "...with the old and new line")
        check(it.changes[1] == -105 and it.changes[2] == -115 and it.before[1] == -110, "...and the odds")
        check(plan.updated == 1 and plan.ok == 0, "counted as updated, not new")
        -- the update is accepted by the real EditMarket and the market then matches the line
        assert(Bookie.EditMarket(b, it.marketId, { odds = it.changes, line = it.newLine }, NOW))
        eq(sp.line, -4.5, "market has the new line")
        eq(Import.Plan(b, SP("-4.5", "-105", "-115"), NOW).duplicate, 1, "re-importing it is a duplicate")
        -- the same line with only new odds is an update without a line change
        local only = Import.Plan(b, SP("-4.5", "-120", "+100"), NOW).items[1]
        check(only.status == "update" and only.newLine == nil and only.beforeLine == nil, "odds-only move: no line change")
        -- line moved but prices identical: still an update (line only)
        local lineOnly = Import.Plan(b, SP("-5", "-105", "-115"), NOW).items[1]
        check(lineOnly.status == "update" and next(lineOnly.changes) == nil and lineOnly.newLine == -5, "line-only move: update with empty odds changes")
    end

    -- moved total, and a total never matches a spread (or the other way round)
    do
        local b, add = fresh()
        local to = add("total", "PHI @ DAL", T1, 47.5, "Over", -110, "Under", -110)
        local sp = add("spread", "PHI @ DAL", T1, -3.5, "PHI", -110, "DAL", -110)
        local it = Import.Plan(b, TO("49", "-115", "-105"), NOW).items[1]
        check(it.status == "update" and it.marketId == to.id and it.newLine == 49 and it.beforeLine == 47.5, "moved total updates the total")
        it = Import.Plan(b, SP("-6", "-110", "-110"), NOW).items[1]
        check(it.status == "update" and it.marketId == sp.id, "moved spread updates the spread, not the total")
        -- the game's identity is event + close time: another time, or another event, is another game
        local other = Import.Plan(b, line("SPREAD", "NFL", "PHI @ DAL", "2026-11-26T20:30-05:00", "-6", "PHI:-110", "DAL:-110"), NOW).items[1]
        eq(other.status, "ok", "same teams at another time: a new market")
        other = Import.Plan(b, SP("-6", "-110", "-110", "NYG @ WAS"), NOW).items[1]
        eq(other.status, "ok", "another event: a new market")
        -- event matching ignores case and spacing
        it = Import.Plan(b, SP("-6", "-110", "-110", "  phi @ dal "), NOW).items[1]
        check(it.status == "update" and it.marketId == sp.id, "event matched ignoring case and spaces")
    end

    -- two or more markets of that type for the game (alternate lines): the exact line is the key
    do
        local b, add = fresh()
        local main = add("spread", "PHI @ DAL", T1, -3.5, "PHI", -110, "DAL", -110)
        local alt = add("spread", "PHI @ DAL", T1, -6.5, "PHI", 150, "DAL", -170)
        local it = Import.Plan(b, SP("-4", "-110", "-110"), NOW).items[1]
        eq(it.status, "ok", "two spreads: a line that matches neither is a new alternate line")
        it = Import.Plan(b, SP("-3.5", "-120", "+100"), NOW).items[1]
        check(it.status == "update" and it.marketId == main.id and it.newLine == nil, "an exact-line match is an odds update")
        it = Import.Plan(b, SP("-6.5", "+150", "-170"), NOW).items[1]
        eq(it.status, "duplicate", "an exact, identical line is a duplicate")
        it = Import.Plan(b, SP("-6.5", "+160", "-180"), NOW).items[1]
        check(it.status == "update" and it.marketId == alt.id, "the alternate line is updated by its own line")
        -- a locked alternate line is untouched
        Bookie.Lock(b, alt.id)
        it = Import.Plan(b, SP("-6.5", "+160", "-180"), NOW).items[1]
        check(it.status == "started" and it.why:find("locked"), "a locked alternate line is skipped")
        -- and a settled market still counts toward "two or more": the other one is not moved
        local b2, add2 = fresh()
        local live = add2("total", "PHI @ DAL", T1, 47.5, "Over", -110, "Under", -110)
        local done = add2("total", "PHI @ DAL", T1, 50.5, "Over", 120, "Under", -140)
        Bookie.Settle(b2, done.id, 1, NOW)
        it = Import.Plan(b2, TO("48", "-110", "-110"), NOW).items[1]
        eq(it.status, "ok", "a settled sibling still counts: the line is a new market, nothing is moved")
        eq(live.line, 47.5, "(planning moved nothing)")
    end

    -- a market that is not open is never touched, whatever its line
    do
        local b, add = fresh()
        local sp = add("spread", "PHI @ DAL", T1, -3.5, "PHI", -110, "DAL", -110)
        Bookie.Lock(b, sp.id)
        local plan = Import.Plan(b, SP("-4.5", "-105", "-115"), NOW)
        check(plan.items[1].status == "started" and plan.items[1].why:find("locked") and plan.started == 1 and plan.ok == 0 and plan.updated == 0,
              "a moved line for a locked spread is skipped, not posted as a new market: " .. tostring(plan.items[1].why))
        check(Import.Plan(b, SP("-3.5", "-110", "-110"), NOW).items[1].status == "duplicate", "...but an identical line is just a duplicate")
        Bookie.Settle(b, sp.id, 1, NOW)
        plan = Import.Plan(b, SP("-4.5", "-105", "-115"), NOW)
        check(plan.items[1].status == "started" and plan.items[1].why:find("settled"), "settled: skipped")
        local b3, add3 = fresh()
        local v = add3("total", "PHI @ DAL", T1, 47.5, "Over", -110, "Under", -110)
        Bookie.VoidMarket(b3, v.id, NOW)
        plan = Import.Plan(b3, TO("48.5", "-110", "-110"), NOW)
        check(plan.items[1].status == "started" and plan.items[1].why:find("void"), "void: skipped")
        -- the game has started (stored status still open): skipped as started, line irrelevant
        local b4, add4 = fresh()
        add4("spread", "PHI @ DAL", T1, -3.5, "PHI", -110, "DAL", -110)
        plan = Import.Plan(b4, SP("-4.5", "-105", "-115"), T1 + 1)
        check(plan.items[1].status == "started" and plan.started == 1 and plan.updated == 0, "after the start, nothing moves")
    end

    -- a moneyline is unchanged: same type + event + time, odds only
    do
        local b, add = fresh()
        local ml = add("moneyline", "PHI @ DAL", T1, nil, "PHI", -150, "DAL", 130)
        local it = Import.Plan(b, line("ML", "NFL", "PHI @ DAL", when, "PHI:-160", "DAL:+140"), NOW).items[1]
        check(it.status == "update" and it.marketId == ml.id and it.newLine == nil and it.beforeLine == nil, "ML odds update has no line change")
        it = Import.Plan(b, line("ML", "NFL", "PHI @ DAL", when, "PHI:-150", "DAL:+130"), NOW).items[1]
        eq(it.status, "duplicate", "identical ML is a duplicate")
        Bookie.Lock(b, ml.id)
        it = Import.Plan(b, line("ML", "NFL", "PHI @ DAL", when, "PHI:-160", "DAL:+140"), NOW).items[1]
        eq(it.status, "started", "a locked ML is skipped")
    end

    -- side names must still match, even when the line moved
    do
        local b, add = fresh()
        add("spread", "PHI @ DAL", T1, -3.5, "PHI", -110, "DAL", -110)
        local it = Import.Plan(b, line("SPREAD", "NFL", "PHI @ DAL", when, "-4.5", "Philadelphia:-110", "Dallas:-110"), NOW).items[1]
        check(it.status == "error" and it.err:find("sides are PHI / DAL"), "moved line with different side names: an error, not a guess")
        it = Import.Plan(b, line("SPREAD", "NFL", "PHI @ DAL", when, "-4.5", "DAL:-110", "PHI:-110"), NOW).items[1]
        eq(it.status, "error", "a swapped spread with a moved line is an error too")
        local bt, addt = fresh()
        addt("total", "PHI @ DAL", T1, 47.5, "Over", -110, "Under", -110)
        it = Import.Plan(bt, line("TOTAL", "NFL", "PHI @ DAL", when, "48.5", "Under:-105", "Over:-115"), NOW).items[1]
        check(it.status == "update" and it.changes[1] == -115 and it.changes[2] == -105 and it.newLine == 48.5,
              "a total may list its sides in the other order: prices go to the right sides")
    end

    -- several lines for one game in one paste
    do
        local function paste(b, ...) return Import.Plan(b, table.concat({ ... }, "\n"), NOW).items end
        local b, add = fresh()
        local main = add("spread", "PHI @ DAL", T1, -3.5, "PHI", -110, "DAL", -110)
        -- the main line (unchanged) and an alternate line: the existing line is the match, the other is new
        local it = paste(b, SP("-3.5", "-115", "-105"), SP("-6.5", "+150", "-170"))
        check(it[1].status == "update" and it[1].marketId == main.id and it[1].newLine == nil, "paste [main, alt]: main updates its odds")
        eq(it[2].status, "ok", "paste [main, alt]: the alternate line is new")
        it = paste(b, SP("-6.5", "+150", "-170"), SP("-3.5", "-115", "-105"))
        check(it[1].status == "ok" and it[2].status == "update" and it[2].marketId == main.id, "paste [alt, main]: same result in the other order")
        -- no line equal to the existing one: the first moved line is the update, the rest are new
        it = paste(b, SP("-4", "-110", "-110"), SP("-6.5", "+150", "-170"))
        check(it[1].status == "update" and it[1].newLine == -4 and it[1].marketId == main.id, "paste [moved, other]: the first moved line is the update")
        eq(it[2].status, "ok", "paste [moved, other]: the second is a new market")
        -- the same moved line twice: update, then duplicate
        it = paste(b, SP("-4", "-110", "-110"), SP("-4", "-110", "-110"))
        check(it[1].status == "update" and it[2].status == "duplicate", "a repeated moved line is a duplicate")
        -- totals behave the same way
        local bt, addt = fresh()
        addt("total", "PHI @ DAL", T1, 47.5, "Over", -110, "Under", -110)
        it = paste(bt, TO("48.5", "-110", "-110"), TO("51.5", "+130", "-150"))
        check(it[1].status == "update" and it[1].newLine == 48.5 and it[2].status == "ok", "paste of two total lines: first moves, second is new")
        -- every "ok" and "update" item is accepted by the real AddMarket / EditMarket
        local bb, addb = fresh()
        local mm = addb("spread", "PHI @ DAL", T1, -3.5, "PHI", -110, "DAL", -110)
        for _, item in ipairs(paste(bb, SP("-4", "-105", "-115"), SP("-6.5", "+150", "-170"))) do
            if item.status == "ok" then assert(Bookie.AddMarket(bb, item.spec, NOW))
            elseif item.status == "update" then assert(Bookie.EditMarket(bb, item.marketId, { odds = next(item.changes) and item.changes or nil, line = item.newLine }, NOW)) end
        end
        eq(mm.line, -4, "applied: the existing market moved")
        local spreads = 0
        for _, m2 in pairs(bb.markets) do if m2.type == "spread" then spreads = spreads + 1 end end
        eq(spreads, 2, "applied: plus the new alternate line")
        -- and the game now has two spreads, so the next import uses exact lines
        eq(Import.Plan(bb, SP("-5", "-110", "-110"), NOW).items[1].status, "ok", "afterwards (two spreads) a line matching neither is new")
    end
end

-- WoW edit boxes double every "|" (so a pasted line arrives as ML||NFL||...)
local dbl = Import.Parse("ML||NFL||PHI @ DAL||2026-11-26T16:30-05:00||PHI:-150||DAL:+130\nTOTAL||NFL||PHI @ DAL||2026-11-26T16:30-05:00||47.5||Over:-110||Under:-110", NOW)
eq(#dbl, 2, "doubled pipes: two lines")
check(dbl[1].spec ~= nil, "doubled pipes: ML parses: " .. tostring(dbl[1].err))
check(dbl[2].spec ~= nil, "doubled pipes: total parses: " .. tostring(dbl[2].err))
eq(dbl[1].text, "ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130", "doubled pipes: shown with single pipes")

-- FINAL lines: settle a game from its score ---------------------------------------------------------------
do
    local fbook = Model.CreateBook(Model.NewDB(), "F", "Steve", NOW)
    local T1 = P("2026-11-26T16:30-05:00")
    local LATER = P("2026-11-27T00:00:00Z")                       -- after the game has started
    local function add(kind, event, closes, line, l1, o1, l2, o2)
        return assert(Bookie.AddMarket(fbook, { sport = "NBA", event = event, type = kind, line = line, closesAt = closes,
            selections = { { label = l1, odds = o1 }, { label = l2, odds = o2 } } }, NOW))
    end
    local ml = add("moneyline", "LAL @ BOS", T1, nil, "LAL", 150, "BOS", -170)
    local sp = add("spread", "LAL @ BOS", T1, 5.5, "LAL", -110, "BOS", -110)        -- LAL +5.5
    local to = add("total", "LAL @ BOS", T1, 231.5, "Over", -110, "Under", -110)
    local when = "2026-11-26T16:30-05:00"
    local function final(game, a, sa, b, sb, time)
        return ("FINAL|NBA|%s|%s%s:%d|%s:%d"):format(game, time and (time .. "|") or "", a, sa, b, sb)
    end
    local function settles(text, now)
        local plan = Import.Plan(fbook, text, now or LATER)
        return plan, plan.items[1]
    end
    local function byType(item)
        local r = {}
        for _, st in ipairs(item.settles or {}) do r[st.type] = st end
        return r
    end

    -- BOS wins 109-104: BOS ML; LAL +5.5 covers a 5-point loss (104+5.5 > 109); 213 is under 231.5
    local plan, it = settles(final("LAL @ BOS", "LAL", 104, "BOS", 109, when))
    eq(it.status, "settle", "a final score settles the game")
    eq(plan.settle, 1, "one FINAL line settles"); eq(plan.markets, 3, "...three markets")
    local r = byType(it)
    eq(r.moneyline.result, 2, "ML: the higher score wins (BOS is selection 2)")
    eq(r.moneyline.pick, "BOS ML", "ML pick text")
    eq(r.spread.result, 1, "spread: LAL +5.5 covers a 5-point loss")
    eq(r.spread.pick, "LAL +5.5", "spread pick text")
    eq(r.total.result, 2, "total: 213 is under 231.5")
    eq(r.total.pick, "Under 231.5", "total pick text")

    -- the same game without the close time, and with the two sides in the other order
    _, it = settles(final("LAL @ BOS", "BOS", 109, "LAL", 104))
    eq(it.status, "settle", "the close time is optional")
    eq(byType(it).moneyline.result, 2, "...and the order of the sides does not matter")
    eq(byType(it).spread.result, 1, "...for the spread either")
    _, it = settles(final("lal @ bos", "lal", 104, "bos", 109))
    eq(it.status, "settle", "names are matched without regard to case")

    -- the spread: LAL +5.5 loses a 7-point loss (BOS 111 LAL 104); a push on a whole-number line
    _, it = settles(final("LAL @ BOS", "LAL", 104, "BOS", 111))
    eq(byType(it).spread.result, 2, "spread: LAL +5.5 does not cover a 7-point loss, BOS wins it")
    eq(byType(it).spread.pick, "BOS -5.5", "...and the winning pick reads from the other side")
    local sp2 = add("spread", "LAL @ BOS", T1, 6, "LAL", -110, "BOS", -110)         -- LAL +6: alternate line
    _, it = settles(final("LAL @ BOS", "LAL", 104, "BOS", 110))
    local pushed
    for _, st in ipairs(it.settles) do if st.marketId == sp2.id then pushed = st end end
    check(pushed and pushed.result == "push" and pushed.pick == "spread push", "a score landing on the spread line is a push")
    eq(#it.settles, 4, "every spread of the game settles, alternates too")

    -- totals: over, and exactly on the line is a push
    _, it = settles(final("LAL @ BOS", "LAL", 120, "BOS", 120))
    eq(byType(it).total.result, 1, "total: 240 is over 231.5")
    eq(byType(it).moneyline.result, "push", "a tied score pushes the moneyline")
    local to2 = add("total", "LAL @ BOS", T1, 230, "Over", -110, "Under", -110)
    _, it = settles(final("LAL @ BOS", "LAL", 115, "BOS", 115))
    local tp
    for _, st in ipairs(it.settles) do if st.marketId == to2.id then tp = st end end
    eq(tp and tp.result, "push", "a total landing on the line is a push")

    -- nothing is guessed or touched that should not be
    plan, it = settles(final("LAL @ BOS", "LAL", 104, "BOS", 110), T1 - 60)
    eq(it.status, "none", "a game that has not started is not settled")
    check(it.why:find("not started"), "...with the reason: " .. tostring(it.why))
    plan, it = settles(final("PHI @ DAL", "PHI", 1, "DAL", 0))
    eq(it.status, "none", "a game that is not in this book is skipped, not an error")
    eq(plan.errors, 0, "...and not counted as an error")
    plan, it = settles(final("LAL @ BOS", "Lakers", 104, "Celtics", 110))
    eq(it.status, "error", "side names that do not fit the market are an error")
    check(it.err:find("LAL / BOS"), "...naming the market's sides: " .. tostring(it.err))
    _, it = settles(final("LAL @ BOS", "LAL", 104, "BOS", 110, "2026-11-26T17:30-05:00"))
    eq(it.status, "none", "a FINAL line for another close time does not match")
    _, it = settles("FINAL|NBA|LAL @ BOS|LAL:abc|BOS:110")
    eq(it.status, "error", "a score that is not a number is an error")
    _, it = settles("FINAL|NBA|LAL @ BOS|LAL:104")
    eq(it.status, "error", "too few fields is an error")
    _, it = settles("FINAL|NBA|LAL @ BOS|LAL:104|LAL:110")
    eq(it.status, "error", "the two sides need different names")

    -- listed twice in one paste: the second finds nothing left
    plan = Import.Plan(fbook, final("LAL @ BOS", "LAL", 104, "BOS", 110) .. "\n" .. final("LAL @ BOS", "LAL", 104, "BOS", 110), LATER)
    eq(plan.items[1].status, "settle", "twice: the first line settles")
    eq(plan.items[2].status, "none", "twice: the second has nothing left")
    check(plan.items[2].why:find("twice"), "...because it is listed twice")

    -- already settled by hand, or void: never touched
    assert(Bookie.Settle(fbook, ml.id, 1, NOW))
    assert(Bookie.VoidMarket(fbook, to.id, NOW))
    _, it = settles(final("LAL @ BOS", "LAL", 104, "BOS", 110))
    local ids = {}
    for _, st in ipairs(it.settles) do ids[st.marketId] = true end
    check(not ids[ml.id] and not ids[to.id] and ids[sp.id], "a settled or void market is left alone")
    eq(it.skipped, 2, "...and counted as skipped")
    for _, st in ipairs(it.settles) do assert(Bookie.Settle(fbook, st.marketId, st.result, NOW)) end
    plan, it = settles(final("LAL @ BOS", "LAL", 104, "BOS", 110))
    eq(it.status, "none", "pasting the results again settles nothing")
    check(it.why:find("already settled"), "...because it is already settled")

    -- the same game posted at two times and no close time on the line: ask for one
    local tbook = Model.CreateBook(Model.NewDB(), "T", "Steve", NOW)
    for _, t in ipairs({ T1, T1 + 86400 }) do
        assert(Bookie.AddMarket(tbook, { sport = "NBA", event = "LAL @ BOS", type = "moneyline", closesAt = t,
            selections = { { label = "LAL", odds = 150 }, { label = "BOS", odds = -170 } } }, NOW))
    end
    local tp2 = Import.Plan(tbook, final("LAL @ BOS", "LAL", 104, "BOS", 110), T1 + 90000)
    eq(tp2.items[1].status, "error", "two games of the same name and no close time is an error")
    check(tp2.items[1].err:find("close time"), "...asking for the close time")
    tp2 = Import.Plan(tbook, final("LAL @ BOS", "LAL", 104, "BOS", 110, when), T1 + 90000)
    eq(tp2.items[1].status, "settle", "...and the close time picks the game")
    eq(#tp2.items[1].settles, 1, "...settling just that one")

    -- a mixed paste: market lines and results together
    local mixed = Import.Plan(fbook, "ML|NBA|NYK @ MIA|2026-12-01T00:00Z|NYK:-120|MIA:+100\n" .. final("LAL @ BOS", "LAL", 104, "BOS", 110) .. "\n# note", NOW)
    eq(mixed.ok, 1, "a mixed paste still posts new markets"); eq(#mixed.items, 2, "...and the comment is skipped")
    -- doubled pipes (WoW edit boxes) work for FINAL lines too
    local dbl2 = Import.Parse("FINAL||NBA||LAL @ BOS||LAL:104||BOS:110", NOW)
    check(dbl2[1].final ~= nil, "doubled pipes: FINAL parses: " .. tostring(dbl2[1].err))
end

if fails == 0 then print("import: all tests passed") else os.exit(1) end
