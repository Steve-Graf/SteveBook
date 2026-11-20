-- Roulette.lua: roulette rules. Pure Lua: no WoW API calls, testable with plain lua5.1.
-- Money is integer copper. A bet is { kind, numbers?, pick?, amount }:
--   inside bets  straight (1 number), split (2), street (3), corner (4), sixline (6): `numbers`
--   outside bets red, black, odd, even, low (1-18), high (19-36): no extras
--                dozen, column: `pick` = 1..3
-- Pockets: 0..36, plus 37 for "00" when the wheel is "double". `zero` is "single" (0), "double"
-- (0 and 00) or "none" (no zero at all: a fair, friendly wheel with no house edge).
local ADDON, ns = ...
ns = ns or {}

local Roulette = {}
ns.Roulette = Roulette

Roulette.DOUBLE_ZERO = 37
Roulette.ZERO_MODES = { "single", "double", "none" }

-- Profit per 1 staked when the bet wins (the stake comes back as well).
local PAYOUT = {
    straight = 35, split = 17, street = 11, corner = 8, sixline = 5,
    dozen = 2, column = 2,
    red = 1, black = 1, odd = 1, even = 1, low = 1, high = 1,
}
Roulette.PAYOUT = PAYOUT

local RED = {}
for _, n in ipairs({ 1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36 }) do RED[n] = true end

local function isInt(n) return type(n) == "number" and n == math.floor(n) end

local function validZero(zero) return zero == "single" or zero == "double" or zero == "none" end

-- Highest pocket number for a wheel.
local function topPocket(zero)
    if zero == "double" then return 37 end
    return 36
end

-- "0", "00" or "17".
function Roulette.Label(n)
    if n == Roulette.DOUBLE_ZERO then return "00" end
    return tostring(n)
end

-- "red", "black" or "green" (0 and 00).
function Roulette.Color(n)
    if n == 0 or n == Roulette.DOUBLE_ZERO then return "green" end
    return RED[n] and "red" or "black"
end

-- All pockets of a wheel, in number order.
function Roulette.Pockets(zero)
    local list = {}
    local first = (zero == "none") and 1 or 0
    for n = first, topPocket(zero) do list[#list + 1] = n end
    return list
end

-- Spin: a pocket number. `rng(m, n)` defaults to math.random (the host passes its own).
function Roulette.Spin(zero, rng)
    rng = rng or math.random
    local pockets = Roulette.Pockets(zero)
    return pockets[rng(1, #pockets)]
end

-- Table geometry: numbers 1..36 sit in 12 rows of 3 columns.
local function row(n) return math.floor((n - 1) / 3) + 1 end
local function col(n) return (n - 1) % 3 + 1 end

local function sortedCopy(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    table.sort(out)
    return out
end

-- Are these two pockets neighbours for a split?
local function adjacent(a, b, zero)
    if a > b then a, b = b, a end
    if a == 0 then
        if b == Roulette.DOUBLE_ZERO then return zero == "double" end
        if zero == "double" then return b == 1 or b == 2 end
        return b == 1 or b == 2 or b == 3            -- a single zero touches the whole first row
    end
    if b == Roulette.DOUBLE_ZERO then
        return zero == "double" and (a == 2 or a == 3)
    end
    if row(a) == row(b) then return b - a == 1 end    -- side by side
    return b - a == 3                                 -- above and below
end

local function isStreet(nums)
    local a = nums[1]
    return col(a) == 1 and nums[2] == a + 1 and nums[3] == a + 2
end

local function isCorner(nums)
    local a = nums[1]
    return col(a) <= 2 and nums[2] == a + 1 and nums[3] == a + 3 and nums[4] == a + 4
end

local function isSixline(nums)
    local a = nums[1]
    if col(a) ~= 1 or a + 5 > 36 then return false end
    for i = 1, 6 do if nums[i] ~= a + i - 1 then return false end end
    return true
end

local COUNT = { straight = 1, split = 2, street = 3, corner = 4, sixline = 6 }

-- Check a bet's shape (not the amount limits: those belong to the table). Returns true, or
-- false, "bad_bet", message.
function Roulette.ValidateBet(bet, zero)
    zero = zero or "single"
    if type(bet) ~= "table" then return false, "bad_bet", "Not a bet." end
    if not validZero(zero) then return false, "bad_bet", "Unknown wheel." end
    if not (isInt(bet.amount) and bet.amount > 0) then return false, "bad_bet", "Bad amount." end
    local kind = bet.kind
    if not PAYOUT[kind] then return false, "bad_bet", "Unknown bet type." end

    if COUNT[kind] then
        local nums = bet.numbers
        if type(nums) ~= "table" or #nums ~= COUNT[kind] then
            return false, "bad_bet", ("A %s bet needs %d number(s)."):format(kind, COUNT[kind])
        end
        local lo = (zero == "none") and 1 or 0
        local hi = topPocket(zero)
        local seen = {}
        for _, n in ipairs(nums) do
            if not isInt(n) or n < lo or n > hi or seen[n] then return false, "bad_bet", "Bad number on the bet." end
            seen[n] = true
        end
        local s = sortedCopy(nums)
        if kind == "split" then
            if not adjacent(s[1], s[2], zero) then return false, "bad_bet", "Those numbers do not touch." end
        elseif kind == "street" then
            if s[1] == 0 or s[3] > 36 or not isStreet(s) then return false, "bad_bet", "Not a street." end
        elseif kind == "corner" then
            if s[1] == 0 or s[4] > 36 or not isCorner(s) then return false, "bad_bet", "Not a corner." end
        elseif kind == "sixline" then
            if s[1] == 0 or not isSixline(s) then return false, "bad_bet", "Not a six line." end
        end
    elseif kind == "dozen" or kind == "column" then
        if not (isInt(bet.pick) and bet.pick >= 1 and bet.pick <= 3) then
            return false, "bad_bet", "Pick 1, 2 or 3."
        end
    end
    return true
end

-- Does this bet win when `number` comes up?
function Roulette.Covers(bet, number)
    local kind = bet.kind
    if COUNT[kind] then
        for _, n in ipairs(bet.numbers) do if n == number then return true end end
        return false
    end
    if number == 0 or number == Roulette.DOUBLE_ZERO then return false end   -- zero beats every outside bet
    if kind == "red" then return RED[number] == true end
    if kind == "black" then return RED[number] ~= true end
    if kind == "odd" then return number % 2 == 1 end
    if kind == "even" then return number % 2 == 0 end
    if kind == "low" then return number <= 18 end
    if kind == "high" then return number >= 19 end
    if kind == "dozen" then return math.floor((number - 1) / 12) + 1 == bet.pick end
    if kind == "column" then return col(number) == bet.pick end
    return false
end

-- Copper returned for one bet (stake included), 0 if it lost.
function Roulette.Win(bet, number)
    if not Roulette.Covers(bet, number) then return 0 end
    return bet.amount * (PAYOUT[bet.kind] + 1)
end

-- Settle a list of bets against the result. Returns { wins = { copper per bet, same order },
-- staked = total, returned = total, net = returned - staked }.
function Roulette.Settle(bets, number)
    local wins, staked, returned = {}, 0, 0
    for i, b in ipairs(bets) do
        local w = Roulette.Win(b, number)
        wins[i] = w
        staked = staked + b.amount
        returned = returned + w
    end
    return { wins = wins, staked = staked, returned = returned, net = returned - staked }
end

-- The house's edge on any one bet, as a fraction of the stake: 0 (no zero), 1/37, 2/38.
function Roulette.HouseEdge(zero)
    if zero == "none" then return 0 end
    if zero == "double" then return 2 / 38 end
    return 1 / 37
end

-- A short description for chat and the board: "17", "3, 4", "Red", "2nd dozen".
local ORD = { "1st", "2nd", "3rd" }
function Roulette.Describe(bet)
    local kind = bet.kind
    if COUNT[kind] then
        local parts = {}
        for _, n in ipairs(sortedCopy(bet.numbers)) do parts[#parts + 1] = Roulette.Label(n) end
        return table.concat(parts, ", ")
    end
    if kind == "dozen" then return ORD[bet.pick] .. " dozen" end
    if kind == "column" then return ORD[bet.pick] .. " column" end
    if kind == "low" then return "1-18" end
    if kind == "high" then return "19-36" end
    return kind:sub(1, 1):upper() .. kind:sub(2)
end

return Roulette
