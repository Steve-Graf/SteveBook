-- Odds.lua: American-odds payout math. Pure logic: no WoW API calls, testable with plain lua5.1.
-- All money is integer copper. Shared by bookie and bettor (bettor uses Profit for the bet slip).
local ADDON, ns = ...
ns = ns or {}

local Odds = {}
ns.Odds = Odds

local function isInt(n)
    return type(n) == "number" and n == math.floor(n) and n > -2^53 and n < 2^53
end

-- floor(n / d) for positive integers, exact (avoids float division rounding).
local function floorDiv(n, d)
    return math.floor((n - n % d) / d)
end

-- American odds are integers with |odds| >= 100 (+100 and -100 are both even money).
function Odds.IsValid(odds)
    return isInt(odds) and (odds >= 100 or odds <= -100)
end

-- Profit on a winning bet, floored to whole copper. Returns nil, err on bad input.
function Odds.Profit(stake, odds)
    if not (isInt(stake) and stake > 0) then return nil, "bad stake" end
    if not Odds.IsValid(odds) then return nil, "bad odds" end
    if odds > 0 then
        return floorDiv(stake * odds, 100)
    else
        return floorDiv(stake * 100, -odds)
    end
end

-- Change to the bettor's balance for a bet outcome. `outcome` matches Bet.status:
-- "won" | "lost" | "push" | "void".
function Odds.Delta(stake, odds, outcome)
    if outcome == "won" then
        return Odds.Profit(stake, odds)
    elseif outcome == "lost" then
        if not (isInt(stake) and stake > 0) then return nil, "bad stake" end
        return -stake
    elseif outcome == "push" or outcome == "void" then
        return 0
    end
    return nil, "bad outcome"
end

-- +150 / -110 for display.
function Odds.Format(odds)
    if not Odds.IsValid(odds) then return "?" end
    return odds > 0 and ("+" .. odds) or tostring(odds)
end

-- "+150", "-110", "150" -> integer odds, or nil if not valid American odds.
function Odds.Parse(str)
    local s = tostring(str or ""):match("^%s*([+-]?%d+)%s*$")
    local n = s and tonumber(s)
    if n and Odds.IsValid(n) then return n end
end

-- Aliases for callers that prefer these names.
Odds.ValidOdds = Odds.IsValid
function Odds.Settle(status, stake, odds) return Odds.Delta(stake, odds, status) end

Odds.COPPER_PER_SILVER = 100
Odds.COPPER_PER_GOLD = 10000

-- Grade an over/under market. Returns "over" | "under" | "push".
function Odds.GradeTotal(line, total)
    if total > line then return "over" end
    if total < line then return "under" end
    return "push"
end

-- Grade a spread market. `line` applies to the first selection (e.g. -3.5 for PHI).
-- Returns "first" | "second" | "push".
function Odds.GradeSpread(line, firstScore, secondScore)
    local adjusted = firstScore + line
    if adjusted > secondScore then return "first" end
    if adjusted < secondScore then return "second" end
    return "push"
end

-- Format copper as "12g 34s 56c", omitting zero parts. 0 -> "0c". Negative gets a leading "-".
function Odds.FormatMoney(copper)
    if not isInt(copper) then return "?" end
    local sign = ""
    if copper < 0 then sign = "-"; copper = -copper end
    if copper == 0 then return "0c" end
    local g = floorDiv(copper, 10000)
    local s = floorDiv(copper % 10000, 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 then parts[#parts + 1] = c .. "c" end
    return sign .. table.concat(parts, " ")
end

local UNIT = { g = 10000, s = 100, c = 1 }

-- Parse "250", "250g", "12g 5s", "1.5g", "50s", "1500c" to copper. Bare numbers are gold.
-- Returns copper (>= 0) or nil.
function Odds.ParseMoney(str)
    if type(str) ~= "string" then return nil end
    local s = str:lower():gsub("%s+", "")
    if s == "" then return nil end
    local pos, total, seen, tokens = 1, 0, {}, 0
    while pos <= #s do
        local num, unit, nextPos = s:match("^(%d+%.?%d*)([gsc]?)()", pos)
        if not num then return nil end
        if unit == "" then
            if tokens > 0 or nextPos <= #s then return nil end
            unit = "g"
        end
        if seen[unit] then return nil end
        seen[unit] = true
        if unit == "c" and num:find(".", 1, true) then return nil end
        total = total + math.floor(tonumber(num) * UNIT[unit] + 0.5)
        tokens = tokens + 1
        pos = nextPos
    end
    return total
end

-- Stake rules (v1 starting limits; SPEC §3). Change them here and nowhere else.
Odds.MAX_STAKE = 10000      -- copper: 1g
Odds.STAKE_STEP = 100       -- copper: stakes are whole silver

-- Returns true, or false, "bad_stake", message. Used by the bookie (authority) and the bet slip.
function Odds.StakeCheck(stake)
    if not isInt(stake) or stake <= 0 then return false, "bad_stake", "Enter a stake." end
    if stake % Odds.STAKE_STEP ~= 0 then
        return false, "bad_stake", "Stakes are whole silver (for example 20s, 50s or 1g)."
    end
    if stake > Odds.MAX_STAKE then
        return false, "bad_stake", "The maximum stake is " .. Odds.FormatMoney(Odds.MAX_STAKE) .. "."
    end
    return true
end

return Odds
