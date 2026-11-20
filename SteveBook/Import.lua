-- Import.lua: the SPEC §7 import format -> market specs. Pure Lua: no WoW API calls.
-- One market per line, '|'-separated; '#' starts a comment line; blank lines are skipped:
--   ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130
--   SPREAD|NFL|PHI @ DAL|2026-11-26T16:30-05:00|-3.5|PHI:-110|DAL:-110     (line is for side 1)
--   TOTAL|NFL|PHI @ DAL|2026-11-26T16:30-05:00|47.5|Over:-110|Under:-110
-- Bad lines are reported, never imported. A spec returned here has the same shape as the
-- spec Bookie.AddMarket takes, which still does the final validation.
-- Times are converted with date arithmetic (days-from-civil), never os.time, so the result
-- does not depend on the machine's timezone.
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

-- One line -> spec, or nil, message. `now` (optional) rejects markets that already closed.
local function parseMarketLine(line, now)
    local f = {}
    for piece in (line .. "|"):gmatch("([^|]*)|") do f[#f + 1] = trim(piece) end

    local kind = KINDS[f[1]:upper()]
    if not kind then
        return nil, ('unknown market type "%s" (use ML, SPREAD or TOTAL)'):format(f[1])
    end
    if #f ~= kind.fields then
        return nil, ("%s lines need %d |-separated fields, found %d"):format(f[1]:upper(), kind.fields, #f)
    end
    if f[3] == "" then return nil, "event is empty" end

    local closesAt, err = Import.ParseTime(f[4])
    if not closesAt then return nil, err end
    if now and closesAt <= now then return nil, "close time has already passed" end

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
-- err = message | nil }, one per non-blank, non-comment line, in order. `n` is the line number
-- in the pasted text. `now` is optional (epoch seconds).
function Import.Parse(text, now)
    local items, n = {}, 0
    -- WoW edit boxes escape every typed or pasted "|" as "||". Names cannot contain "|"
    -- (SPEC §7), so a doubled pipe is always one separator.
    text = tostring(text or ""):gsub("||", "|")
    for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        local line = trim(raw)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local spec, err
            if line:sub(1, 4):upper() == "GB1:" then
                err = "encoded (GB1:) import strings are not supported yet; paste the plain lines"
            else
                spec, err = parseMarketLine(line, now)
            end
            items[#items + 1] = { line = n, text = line, spec = spec, err = err }
        end
    end
    return items
end

local function key(spec)
    return table.concat({ spec.type, trim(spec.event):lower(), tostring(spec.closesAt), tostring(spec.line or "") }, "|")
end

-- Parse and classify against a book: each item gets status "ok" | "duplicate" | "error".
-- A duplicate is the same type, event, close time and line as an existing market, or as an
-- earlier line of this paste. Returns { items, ok = n, duplicate = n, errors = n }.
function Import.Plan(book, text, now)
    local plan = { items = Import.Parse(text, now), ok = 0, duplicate = 0, errors = 0 }
    local seen = {}
    for _, m in pairs(book.markets or {}) do
        seen[key({ type = m.type, event = m.event, closesAt = m.closesAt, line = m.line })] = true
    end
    for _, item in ipairs(plan.items) do
        if not item.spec then
            item.status = "error"
            plan.errors = plan.errors + 1
        elseif seen[key(item.spec)] then
            item.status = "duplicate"
            plan.duplicate = plan.duplicate + 1
        else
            item.status = "ok"
            seen[key(item.spec)] = true
            plan.ok = plan.ok + 1
        end
    end
    return plan
end

return Import
