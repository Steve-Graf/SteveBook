-- Clock.lua: turn an epoch (GetServerTime) into a clock time to show people.
-- Preferred: the realm's server time (offset learned from GetGameTime, which returns the realm's
-- local hour and minute). Fallback when that API is missing: US Pacific ("west coast") time with
-- the US daylight-saving rules. The calendar maths is pure; only ServerOffset touches the game.
local ADDON, ns = ...
ns = ns or {}

local Clock = {}
ns.Clock = Clock

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Days since 1970-01-01 for a civil date (proleptic Gregorian).
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- Broken-down UTC fields for an epoch (no os.date, so no dependence on the machine's time zone).
local function civil(t)
    local days = math.floor(t / 86400)
    local secs = t - days * 86400
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp + (mp < 10 and 3 or -9)
    if m <= 2 then y = y + 1 end
    return { year = y, month = m, day = d, hour = math.floor(secs / 3600), min = math.floor((secs % 3600) / 60),
             wday = (days + 4) % 7 }       -- 0 = Sunday
end
Clock.Civil = civil

-- Minutes to add to UTC for US Pacific time at this epoch: -420 (PDT) or -480 (PST). DST runs
-- from the second Sunday of March 2:00 local to the first Sunday of November 2:00 local.
function Clock.PacificOffset(t)
    local y = civil(t).year
    local wdMar1 = (daysFromCivil(y, 3, 1) + 4) % 7
    local secondSunday = 1 + (7 - wdMar1) % 7 + 7
    local wdNov1 = (daysFromCivil(y, 11, 1) + 4) % 7
    local firstSunday = 1 + (7 - wdNov1) % 7
    local startsAt = daysFromCivil(y, 3, secondSunday) * 86400 + 10 * 3600   -- 2:00 PST = 10:00 UTC
    local endsAt = daysFromCivil(y, 11, firstSunday) * 86400 + 9 * 3600      -- 2:00 PDT = 09:00 UTC
    if t >= startsAt and t < endsAt then return -420 end
    return -480
end

-- Minutes to add to UTC to get the realm's local time, learned from GetGameTime (the realm's
-- current hour and minute) against GetServerTime. nil if either API is missing or odd.
function Clock.ServerOffset(t)
    if not (GetGameTime and GetServerTime) then return nil end
    local ok, h, m = pcall(GetGameTime)
    if not (ok and type(h) == "number" and type(m) == "number") then return nil end
    local nowUtc = GetServerTime()
    if type(nowUtc) ~= "number" then return nil end
    local diff = (h * 60 + m) - (math.floor(nowUtc / 60) % 1440)
    diff = (diff + 720) % 1440 - 720                 -- into -720..719 minutes
    return diff
end

-- Which clock is in use: "server" or "PT" (for a column header).
function Clock.Label()
    return Clock.ServerOffset() and "server" or "PT"
end

local function clock12(c)
    local h = c.hour % 12
    if h == 0 then h = 12 end
    return ("%d:%02d %s"):format(h, c.min, c.hour < 12 and "AM" or "PM")
end

-- "3:42 PM" for today's times, "Nov 19 3:42 PM" for other days, in the chosen clock. `now` defaults
-- to GetServerTime(). Returns "?" for a bad epoch.
function Clock.Format(t, now)
    if type(t) ~= "number" then return "?" end
    now = now or (GetServerTime and GetServerTime()) or t
    local offset = Clock.ServerOffset(t) or Clock.PacificOffset(t)
    local nowOffset = Clock.ServerOffset(now) or Clock.PacificOffset(now)
    local c = civil(t + offset * 60)
    local n = civil(now + nowOffset * 60)
    if c.year == n.year and c.month == n.month and c.day == n.day then return clock12(c) end
    return ("%s %d %s"):format(MONTHS[c.month], c.day, clock12(c))
end

return Clock
