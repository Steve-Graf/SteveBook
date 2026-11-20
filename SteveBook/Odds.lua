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

-- +150 / -110, always American. Use this wherever the text is typed back in (edit boxes, forms).
function Odds.FormatAmerican(odds)
    if not Odds.IsValid(odds) then return "?" end
    return odds > 0 and ("+" .. odds) or tostring(odds)
end

-- Ratio view: profit per 1 staked, so -500 is 0.2x, +150 is 1.5x and -110 is 0.91x (two decimals,
-- trailing zeros dropped). Display only: it is not exact (-230 and -233 both show 0.43x) and
-- Odds.Parse does not read it.
function Odds.FormatRatio(odds)
    if not Odds.IsValid(odds) then return "?" end
    local r = odds > 0 and odds / 100 or 100 / -odds
    local s = string.format("%.2f", r):gsub("0+$", "")
    return (s:gsub("%.$", "")) .. "x"
end

-- The player's display setting: "american" (default) or "ratio" (/book ratio).
Odds.view = "american"
function Odds.SetView(view) Odds.view = (view == "ratio") and "ratio" or "american" end
function Odds.GetView() return Odds.view end

-- Odds as the player wants to read them.
function Odds.Format(odds)
    if Odds.view == "ratio" then return Odds.FormatRatio(odds) end
    return Odds.FormatAmerican(odds)
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

------------------------------------------------------------------------------------------
-- Parlays (SPEC §3a). A parlay is one stake on 2+ legs; every leg must win. Pure math only.
------------------------------------------------------------------------------------------

Odds.MIN_PARLAY_LEGS = 2
Odds.MAX_PARLAY_LEGS = 8

-- Decimal odds (> 1) for American odds, or nil, "bad odds".
function Odds.Decimal(odds)
    if not Odds.IsValid(odds) then return nil, "bad odds" end
    if odds > 0 then return 1 + odds / 100 end
    return 1 + 100 / -odds
end

-- Combined decimal odds of a list of American odds, or nil, err.
function Odds.ParlayDecimal(oddsList)
    if type(oddsList) ~= "table" or #oddsList == 0 then return nil, "no legs" end
    local d = 1
    for _, o in ipairs(oddsList) do
        local x, err = Odds.Decimal(o)
        if not x then return nil, err end
        d = d * x
    end
    return d
end

-- American odds (an integer, |odds| >= 100) for a combined decimal price, rounded to nearest.
function Odds.FromDecimal(d)
    if type(d) ~= "number" or d <= 1 then return nil, "bad decimal" end
    local r = d - 1
    if r >= 1 then return math.floor(r * 100 + 0.5) end
    return -math.floor(100 / r + 0.5)
end

-- Combined American odds for display and for Bet.odds.
function Odds.ParlayOdds(oddsList)
    local d, err = Odds.ParlayDecimal(oddsList)
    if not d then return nil, err end
    return Odds.FromDecimal(d)
end

-- Profit on a winning parlay, floored to whole copper (computed from the decimal product, not
-- from the rounded American odds). nil, err on bad input.
function Odds.ParlayProfit(stake, oddsList)
    if not (isInt(stake) and stake > 0) then return nil, "bad stake" end
    local d, err = Odds.ParlayDecimal(oddsList)
    if not d then return nil, err end
    return math.floor(stake * (d - 1) + 1e-6)
end

-- Is this many legs allowed? true, or false, "bad_request", message.
function Odds.ParlayLegCheck(n)
    if not isInt(n) or n < Odds.MIN_PARLAY_LEGS or n > Odds.MAX_PARLAY_LEGS then
        return false, "bad_request",
            ("A parlay needs %d to %d legs."):format(Odds.MIN_PARLAY_LEGS, Odds.MAX_PARLAY_LEGS)
    end
    return true
end

-- Which legs may share a parlay. `markets` = list of { id, event, closesAt, type } (the markets the
-- legs are on, in leg order). Legs on different games never conflict. Within one game (same event
-- and close time) a parlay may hold one side bet (moneyline OR spread) plus one total (over/under):
-- ML + spread, two spreads, and over + under are all rejected, as is the same market twice.
-- Returns true, or false, reason, i, j (the 1-based positions of the first conflicting pair) where
-- reason is "duplicate_market" or "same_game_conflict".
function Odds.ParlayConflict(markets)
    for j = 2, #markets do
        local b = markets[j]
        for i = 1, j - 1 do
            local a = markets[i]
            if a.id ~= nil and a.id == b.id then return false, "duplicate_market", i, j end
            if a.event == b.event and a.closesAt == b.closesAt then
                local aTotal, bTotal = a.type == "total", b.type == "total"
                if aTotal == bTotal then return false, "same_game_conflict", i, j end
            end
        end
    end
    return true
end

-- Grade a parlay from its legs. legs = list of { odds, status } with status "pending", "won",
-- "lost", "push" or "void". Returns state, delta, effectiveOdds:
--   "lost"    any leg lost (decided even while other legs are pending); delta = -stake
--   "pending" no leg lost, some leg still pending
--   "won"     all legs resolved, none lost, at least one won; push/void legs drop out, so the
--             price is the product of the winning legs only; delta = that profit
--   "push"    nothing won or lost and at least one push; "void" when every leg is void; delta 0
function Odds.GradeParlay(stake, legs)
    if not (isInt(stake) and stake > 0) then return nil, "bad stake" end
    if type(legs) ~= "table" or #legs == 0 then return nil, "no legs" end
    local won, pending, push = {}, false, false
    for _, leg in ipairs(legs) do
        if leg.status == "lost" then return "lost", -stake end
        if leg.status == "won" then won[#won + 1] = leg.odds
        elseif leg.status == "push" then push = true
        elseif leg.status ~= "void" then pending = true end
    end
    if pending then return "pending", 0 end
    if #won > 0 then
        local profit, err = Odds.ParlayProfit(stake, won)
        if not profit then return nil, err end
        return "won", profit, Odds.ParlayOdds(won)
    end
    return push and "push" or "void", 0
end

return Odds
