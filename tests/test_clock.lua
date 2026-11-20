-- Run from repo root: luajit tests/test_clock.lua
local ns = {}
local Clock = assert(loadfile("SteveBook/Clock.lua"))("SteveBook", ns)
local fails = 0
local function eq(got, want, label)
    if got ~= want then fails = fails + 1; print(("FAIL: %s (got %s, want %s)"):format(label, tostring(got), tostring(want))) end
end

-- calendar
local c = Clock.Civil(1795207320)
eq(c.year .. "-" .. c.month .. "-" .. c.day .. " " .. c.hour .. ":" .. c.min, "2026-11-20 20:42", "civil 2026-11-20 20:42 UTC")
eq(c.wday, 5, "2026-11-20 is a Friday")
eq(Clock.Civil(0).year, 1970, "epoch 0")
eq(Clock.Civil(951782400).day, 29, "leap day 2000-02-29")

-- Pacific DST boundaries (2026: starts Mar 8 10:00 UTC, ends Nov 1 09:00 UTC; 2027 starts Mar 14)
eq(Clock.PacificOffset(1772963999), -480, "just before DST starts")
eq(Clock.PacificOffset(1772964000), -420, "DST starts")
eq(Clock.PacificOffset(1782907200), -420, "July is PDT")
eq(Clock.PacificOffset(1793523599), -420, "just before DST ends")
eq(Clock.PacificOffset(1793523600), -480, "DST ends")
eq(Clock.PacificOffset(1795207320), -480, "late November is PST")
eq(Clock.PacificOffset(1805018399), -480, "2027: just before DST starts")
eq(Clock.PacificOffset(1805018400), -420, "2027: DST starts")

-- fallback: no game clock -> Pacific
local now = 1795207320                       -- Fri 2026-11-20 12:42 PST
eq(Clock.ServerOffset(), nil, "no GetGameTime: no server offset")
eq(Clock.Label(), "PT", "label falls back to PT")
eq(Clock.Format(now, now), "12:42 PM", "today shows only the time (Pacific)")
eq(Clock.Format(now - 86400, now), "Nov 19 12:42 PM", "another day shows the date")
eq(Clock.Format(now - 13 * 3600, now), "Nov 19 11:42 PM", "13 hours earlier is last night in Pacific time")
eq(Clock.Format("x"), "?", "bad epoch")

-- server time: realm clock three hours ahead of UTC
GetServerTime = function() return now end
GetGameTime = function() return 23, 42 end          -- 20:42 UTC + 3h = 23:42 realm time
eq(Clock.ServerOffset(), 180, "offset learned from GetGameTime")
eq(Clock.Label(), "server", "label says server")
eq(Clock.Format(now, now), "11:42 PM", "today in server time")
eq(Clock.Format(now - 4 * 3600, now), "7:42 PM", "four hours earlier")
eq(Clock.Format(now - 24 * 3600, now), "Nov 19 11:42 PM", "yesterday, server date")

-- realm clock behind UTC and across midnight
GetGameTime = function() return 12, 42 end          -- UTC-8
eq(Clock.ServerOffset(), -480, "negative offset")
GetServerTime = function() return 1795207320 + 5 * 3600 end        -- 01:42 UTC next day, realm 17:42
GetGameTime = function() return 17, 42 end
eq(Clock.ServerOffset(), -480, "offset across the UTC midnight")
GetGameTime = function() return nil end
eq(Clock.ServerOffset(), nil, "odd GetGameTime result is ignored")
GetGameTime = function() error("boom") end
eq(Clock.ServerOffset(), nil, "a failing GetGameTime is ignored")

if fails == 0 then print("clock: all passed") else os.exit(1) end
