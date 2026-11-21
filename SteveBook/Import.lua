-- Import.lua: the SPEC §7 import format -> market specs. Pure Lua: no WoW API calls.
-- One market per line, '|'-separated; '#' starts a comment line; blank lines are skipped:
--   ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130
--   SPREAD|NFL|PHI @ DAL|2026-11-26T16:30-05:00|-3.5|PHI:-110|DAL:-110     (line is for side 1)
--   TOTAL|NFL|PHI @ DAL|2026-11-26T16:30-05:00|47.5|Over:-110|Under:-110
--   FINAL|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:24|DAL:20          (a result: see "Results" below)
-- Bad lines are reported, never imported. A spec returned here has the same shape as the
-- spec Bookie.AddMarket takes, which still does the final validation.
-- Importing is also how lines are UPDATED (Plan, status "update"). Which existing market an
-- import line means ("the same market"):
--   ML      same type + event + close time.
--   SPREAD / TOTAL, the game has exactly ONE market of that type (same event and close time, any
--           status): that market, whatever its line. Lines move all day, so a moved line updates the
--           market in place: its line AND odds change, existing bets keep the line and odds they
--           were accepted at. (If the paste also holds a line equal to that market's current line,
--           that line is the match and a different line in the paste is a new alternate line; of
--           several moved lines the first one is the update, the rest are new.)
--   SPREAD / TOTAL, the game has TWO OR MORE markets of that type (deliberate alternate lines): the
--           exact key, type + event + close time + line. An exact match is an update or a duplicate;
--           any other line is a new market.
-- A match that is not open (locked, settled, void, or its game has started) is skipped and never
-- touched, even if its line differs. Matching sides by name (case-insensitive) is required; a
-- mismatch is an error, not a guess. Identical lines are duplicates.
-- Times are converted with date arithmetic (days-from-civil), never os.time, so the result
-- does not depend on the machine's timezone.
-- Results: a FINAL line carries the final score and settles every market of that game that is still
-- waiting: the moneyline (higher score wins, a tie is a push), each spread (the line belongs to the
-- first-listed side of that market, like everywhere else) and each total (Over/Under against the sum;
-- landing exactly on the line is a push). The close time may be left out (5 fields) when the game is
-- posted once. Nothing already settled or void is ever touched (correct those by hand), and a game
-- that has not started is not settled.
local ADDON, ns = ...
ns = ns or {}
local Odds = ns.Odds

local Import = {}
ns.Import = Import

local function trim(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end

local function isLeap(y) return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end

local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function daysInMonth(y, m)
    if m == 2 and isLeap(y) then return 29 end
    return DAYS[m]
end

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400                              -- [0, 399]
    local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1   -- March-based day of year
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local TIME_HELP = "time must look like 2026-11-26T16:30-05:00 (a UTC offset or Z is required)"

-- "2026-11-26T16:30-05:00", "2026-11-26T16:30:00Z", "...+0530" -> epoch seconds, or nil, message.
function Import.ParseTime(s)
    s = trim(s)
    local y, mo, d, h, mi, rest = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d)(.*)$")
    if not y then return nil, TIME_HELP end
    local sec = 0
    local ss, afterSec = rest:match("^:(%d%d)(.*)$")
    if ss then sec = tonumber(ss); rest = afterSec end

    local offset
    if rest == "Z" or rest == "z" then
        offset = 0
    else
        local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
        if not sign then return nil, TIME_HELP end
        oh, om = tonumber(oh), tonumber(om)
        if oh > 23 or om > 59 then return nil, "UTC offset out of range" end
        offset = (oh * 3600 + om * 60) * (sign == "-" and -1 or 1)
    end

    y, mo, d, h, mi = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
    if y < 1970 then return nil, "year out of range" end
    if mo < 1 or mo > 12 then return nil, "month out of range" end
    if d < 1 or d > daysInMonth(y, mo) then return nil, "day out of range for that month" end
    if h > 23 or mi > 59 or sec > 59 then return nil, "time of day out of range" end
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - offset
end

local function parseLineValue(s)
    s = trim(s)
    if not (s:match("^[+-]?%d+%.?%d*$") or s:match("^[+-]?%.%d+$")) then return nil end
    return tonumber(s)
end

-- "PHI:-150" -> label, odds   (split on the LAST colon, so labels may contain colons)
local function parseSide(s)
    local label, o = trim(s):match("^(.-)%s*:%s*([+-]?%d+)$")
    if not label or label == "" then
        return nil, ('side "%s" should look like NAME:-110 or NAME:+150'):format(trim(s))
    end
    local odds = Odds.Parse(o)
    if not odds then return nil, ('odds "%s" are not valid American odds (e.g. -110, +150)'):format(o) end
    return label, odds
end

local KINDS = {
    ML = { type = "moneyline", fields = 6 },
    MONEYLINE = { type = "moneyline", fields = 6 },
    SPREAD = { type = "spread", fields = 7 },
    TOTAL = { type = "total", fields = 7 },
}

-- "PHI:24" -> label, score (split on the LAST colon). Scores are whole numbers.
local function parseScore(s)
    local label, n = trim(s):match("^(.-)%s*:%s*(%d+)$")
    if not label or label == "" then return nil, ('score "%s" should look like NAME:104'):format(trim(s)) end
    return label, tonumber(n)
end

-- FINAL|sport|event|[time|]A:score|B:score -> { sport, event, closesAt|nil, scores = { {label, score}, {label, score} } }
local function parseFinalLine(f)
    if #f ~= 5 and #f ~= 6 then
        return nil, ("FINAL lines need 5 or 6 |-separated fields (the close time is optional), found %d"):format(#f)
    end
    if f[3] == "" then return nil, "event is empty" end
    local closesAt, idx = nil, 4
    if #f == 6 then
        local err
        closesAt, err = Import.ParseTime(f[4])
        if not closesAt then return nil, err end
        idx = 5
    end
    local l1, s1 = parseScore(f[idx])
    if not l1 then return nil, s1 end
    local l2, s2 = parseScore(f[idx + 1])
    if not l2 then return nil, s2 end
    if l1:lower() == l2:lower() then return nil, "the two sides need different names" end
    return { sport = f[2], event = f[3], closesAt = closesAt, scores = { { label = l1, score = s1 }, { label = l2, score = s2 } } }
end

local function splitFields(line)
    local f = {}
    for piece in (line .. "|"):gmatch("([^|]*)|") do f[#f + 1] = trim(piece) end
    return f
end

-- One line -> spec, or nil, message. (Whether the game has started is Parse's business.)
local function parseMarketLine(line)
    local f = splitFields(line)

    local kind = KINDS[f[1]:upper()]
    if not kind then
        return nil, ('unknown line type "%s" (use ML, SPREAD, TOTAL or FINAL)'):format(f[1])
    end
    if #f ~= kind.fields then
        return nil, ("%s lines need %d |-separated fields, found %d"):format(f[1]:upper(), kind.fields, #f)
    end
    if f[3] == "" then return nil, "event is empty" end

    local closesAt, err = Import.ParseTime(f[4])
    if not closesAt then return nil, err end

    local idx, lineValue = 5, nil
    if kind.type ~= "moneyline" then
        lineValue = parseLineValue(f[5])
        if not lineValue then return nil, ('line "%s" must be a number, e.g. -3.5 or 47.5'):format(f[5]) end
        idx = 6
    end
    local label1, odds1 = parseSide(f[idx])
    if not label1 then return nil, odds1 end
    local label2, odds2 = parseSide(f[idx + 1])
    if not label2 then return nil, odds2 end
    if label1 == label2 then return nil, "the two sides need different names" end

    return {
        sport = f[2], event = f[3], type = kind.type, line = lineValue, closesAt = closesAt,
        selections = { { label = label1, odds = odds1 }, { label = label2, odds = odds2 } },
    }
end

-- Parse a pasted block. Returns an array of { line = n, text = trimmed line, spec = spec | nil,
-- err = message | nil, started = true | nil }, one per non-blank, non-comment line, in order. `n`
-- is the line number in the pasted text. `now` is optional (epoch seconds): with it, a well-formed
-- line whose close time has passed has `started = true` (still returned with its spec; it is
-- skipped, not an error, because a script that pulls a whole slate includes games under way).
function Import.Parse(text, now)
    local items, n = {}, 0
    -- WoW edit boxes escape every typed or pasted "|" as "||". Names cannot contain "|"
    -- (SPEC §7), so a doubled pipe is always one separator.
    text = tostring(text or ""):gsub("||", "|")
    for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        local line = trim(raw)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local spec, err, final
            if line:sub(1, 4):upper() == "GB1:" then
                err = "encoded (GB1:) import strings are not supported yet; paste the plain lines"
            elseif line:match("^[Ff][Ii][Nn][Aa][Ll]%s*|") then
                final, err = parseFinalLine(splitFields(line))
            else
                spec, err = parseMarketLine(line)
            end
            items[#items + 1] = { line = n, text = line, spec = spec, final = final, err = err,
                                  started = (spec and now and spec.closesAt <= now) or nil }
        end
    end
    return items
end

local function key(spec)
    return table.concat({ spec.type, trim(spec.event):lower(), tostring(spec.closesAt), tostring(spec.line or "") }, "|")
end

-- The game a market is on: type + event + close time, without the line.
local function gameKey(m)
    return table.concat({ m.type, trim(m.event):lower(), tostring(m.closesAt) }, "|")
end

local function sameLabel(a, b) return trim(a):lower() == trim(b):lower() end

-- Pair an import line's two sides with a market's selections. Returns { [selectionId] = odds }, or
-- nil if the side names don't match. Order may be swapped for a moneyline or total; never for a
-- spread, whose line belongs to the first side.
local function pairSides(market, spec)
    local a, b = market.selections[1], market.selections[2]
    local s1, s2 = spec.selections[1], spec.selections[2]
    if sameLabel(a.label, s1.label) and sameLabel(b.label, s2.label) then
        return { [1] = s1.odds, [2] = s2.odds }
    end
    if market.type ~= "spread" and sameLabel(a.label, s2.label) and sameLabel(b.label, s1.label) then
        return { [1] = s2.odds, [2] = s1.odds }
    end
end


local function signedLine(n) return (n > 0 and "+" or "") .. ("%g"):format(n) end

local function sideScore(final, label)
    for _, sc in ipairs(final.scores) do if sameLabel(sc.label, label) then return sc.score end end
end

-- Who won market `m` given the final score: returns the winning selection id or "push", then the
-- pick that won as text ("BOS ML", "LAL +5.5", "Over 231.5", or "ML push"). nil, reason if the
-- score's side names do not fit the market.
local function gradeMarket(m, final)
    local a, b = m.selections[1], m.selections[2]
    local result
    if m.type == "total" then
        local over, under
        for id = 1, 2 do
            local l = trim(m.selections[id].label):lower()
            if l == "over" then over = id elseif l == "under" then under = id end
        end
        if not (over and under) then return nil, "its sides are not Over and Under" end
        local sum = final.scores[1].score + final.scores[2].score
        result = sum > m.line and over or sum < m.line and under or "push"
    else
        local s1, s2 = sideScore(final, a.label), sideScore(final, b.label)
        if not (s1 and s2) then
            return nil, ("its sides are %s / %s but the score names %s / %s"):format(
                a.label, b.label, final.scores[1].label, final.scores[2].label)
        end
        local d = s1 - s2
        if m.type == "spread" then d = d + m.line end            -- the line belongs to selection 1
        result = d > 0 and 1 or d < 0 and 2 or "push"
    end
    local what = m.type == "moneyline" and "ML" or m.type == "spread" and "spread" or "total"
    if result == "push" then return result, what .. " push" end
    local sel = m.selections[result]
    if m.type == "moneyline" then return result, sel.label .. " ML" end
    if m.type == "spread" then return result, sel.label .. " " .. signedLine(result == 1 and m.line or -m.line) end
    return result, sel.label .. " " .. ("%g"):format(m.line)
end

-- A FINAL line against the book. Sets item.status: "settle" (item.settles = { { marketId, result, pick,
-- type } }, item.skipped = number of this game's markets left alone), "none" (item.why), or "error".
local function planFinal(book, item, ids, now, taken)
    local f = item.final
    local cands, times, nTimes = {}, {}, 0
    local found, already, early, dup = 0, 0, 0, 0
    for _, id in ipairs(ids) do
        local m = book.markets[id]
        if sameLabel(m.event, f.event) and (not f.closesAt or m.closesAt == f.closesAt) then
            found = found + 1
            if m.status == "settled" or m.status == "void" then already = already + 1
            elseif taken[m.id] then dup = dup + 1
            elseif m.status == "open" and now and now < m.closesAt then early = early + 1
            else
                cands[#cands + 1] = m
                if not times[m.closesAt] then times[m.closesAt] = true; nTimes = nTimes + 1 end
            end
        end
    end
    if #cands == 0 then
        item.status = "none"
        item.why = found == 0 and "no market on this game in this book"
            or dup > 0 and "listed twice in this paste"
            or early > 0 and "the game has not started yet"
            or "already settled"
        return
    end
    if nTimes > 1 then
        item.status = "error"
        item.err = "this game is posted at more than one time; add the close time to the FINAL line"
        return
    end
    local settles = {}
    for _, m in ipairs(cands) do
        local result, pick = gradeMarket(m, f)
        if result == nil then
            item.status, item.err = "error", ("%s market: %s"):format(m.type, pick)
            return
        end
        settles[#settles + 1] = { marketId = m.id, result = result, pick = pick, type = m.type }
    end
    for _, st in ipairs(settles) do taken[st.marketId] = true end
    item.status, item.settles, item.skipped = "settle", settles, already + early
end

-- Parse and classify against a book (see the matching rules at the top of this file). Each item
-- gets a status:
--   "ok"         a new market
--   "update"     matches an OPEN market whose line or odds differ; item.marketId,
--                item.changes = { [selectionId] = newOdds } (may be empty), item.before = { [selectionId] = oldOdds },
--                item.newLine / item.beforeLine when a spread or total line moved
--   "duplicate"  identical to an existing market, or to an earlier line of this paste
--   "started"    the game has already started, or it matches a market that is locked, settled or
--                void (item.why says which). Never touched.
--   "error"      unreadable, or it matches an existing market but the side names differ
-- A FINAL (result) line gets one of:
--   "settle"     item.settles = { { marketId, result, pick, type } }: this game's markets that are waiting
--   "none"       nothing to settle; item.why says why (not in this book, already settled, not started...)
--   "error"      unreadable, the sides do not fit, or the game is posted at more than one time
-- Returns { items, ok = new, updated, duplicate, started, errors, settle = FINAL lines that settle,
-- markets = markets they settle, none = FINAL lines with nothing to do } (counts per status).
function Import.Plan(book, text, now)
    local plan = { items = Import.Parse(text, now), ok = 0, updated = 0, duplicate = 0, started = 0, errors = 0,
                  settle = 0, markets = 0, none = 0 }
    local taken = {}                     -- markets an earlier FINAL line of this paste settles

    local function bettable(m) return m.status == "open" and (not now or now < m.closesAt) end
    local ids = {}
    for id in pairs(book.markets or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    local exact = {}                     -- key -> the market with that exact line (one that still takes bets wins)
    local games = {}                     -- gameKey -> every market on that game of that type, any status
    for _, id in ipairs(ids) do
        local m = book.markets[id]
        local k = key({ type = m.type, event = m.event, closesAt = m.closesAt, line = m.line })
        if not exact[k] or (bettable(m) and not bettable(exact[k])) then exact[k] = m end
        local g = gameKey(m)
        games[g] = games[g] or {}
        games[g][#games[g] + 1] = m
    end

    -- A game with exactly one spread (or total) market: a pasted line equal to its current line
    -- claims it, so a different line for that game in the same paste is an alternate, not a move.
    local function soleMarket(spec)
        if spec.type == "moneyline" then return nil end
        local g = games[gameKey(spec)]
        return g and #g == 1 and g[1] or nil
    end
    local claimed = {}
    for _, item in ipairs(plan.items) do
        local sole = item.spec and not item.started and soleMarket(item.spec)
        if sole and sole.line == item.spec.line then claimed[sole.id] = true end
    end

    local seen = {}                      -- keys of earlier lines of this paste
    local moved = {}                     -- markets an earlier line of this paste already moved
    for _, item in ipairs(plan.items) do
        local spec = item.spec
        if item.final then
            planFinal(book, item, ids, now, taken)
        elseif not spec then
            item.status = "error"
        elseif item.started then
            item.status, item.why = "started", "the game has already started"
        else
            local k = key(spec)
            local m
            if not seen[k] then
                local sole = soleMarket(spec)
                if sole then
                    if sole.line == spec.line then m = sole
                    elseif not claimed[sole.id] and not moved[sole.id] then m = sole; moved[sole.id] = true end
                else
                    m = exact[k]
                end
            end
            if seen[k] then
                item.status = "duplicate"
            elseif m then
                local odds = pairSides(m, spec)
                if not odds then
                    item.status = "error"
                    item.err = ("matches an existing market, but its sides are %s / %s"):format(m.selections[1].label, m.selections[2].label)
                else
                    local changes, before = {}, {}
                    for id, o in pairs(odds) do
                        if m.selections[id].odds ~= o then changes[id] = o; before[id] = m.selections[id].odds end
                    end
                    local lineMoved = spec.type ~= "moneyline" and m.line ~= spec.line
                    if next(changes) == nil and not lineMoved then
                        item.status = "duplicate"
                    elseif bettable(m) then
                        item.status, item.marketId, item.changes, item.before = "update", m.id, changes, before
                        if lineMoved then item.newLine, item.beforeLine = spec.line, m.line end
                    else
                        item.status, item.why = "started", "that market is already " .. (m.status == "open" and "closed" or m.status)
                    end
                end
            else
                item.status = "ok"
            end
            if item.status == "ok" or item.status == "update" or m then seen[k] = true end
        end
        local field = ({ ok = "ok", update = "updated", duplicate = "duplicate", started = "started", error = "errors",
                         settle = "settle", none = "none" })[item.status]
        plan[field] = plan[field] + 1
        if item.status == "settle" then plan.markets = plan.markets + #item.settles end
    end
    return plan
end

return Import
