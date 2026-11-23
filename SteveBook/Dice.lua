-- Dice.lua: "roll under" dice for a casino table (SPEC §11b). Pure Lua, no WoW API calls. It plugs into
-- Casino.lua as Casino.Engines.dice; chips, members and the generic messages stay in Casino.lua.
--
-- The player picks a target and a stake. The die has 100 sides (like WoW's /roll); the bet wins when the roll
-- is the target or lower. A win pays (100 - E.EDGE) / target times the stake, stake included, so the house
-- keeps E.EDGE percent whatever target is picked: a lower target is less likely and pays more.
-- A bet is { kind = "roll", amount, pick = target }. One bet per roll; take it back to change it.
-- Dice is only played against a house (Casino.GAMES.dice.houseOnly, see House.lua): there is no multi-player table.
-- t.status: "betting" | "rolling" (for E.ROLL_SECONDS, then the number is drawn) | "closed".
local ADDON, ns = ...
ns = ns or {}

local Casino, Odds = ns.Casino, ns.Odds
local E = {}
ns.Dice = E
Casino.Engines.dice = E

E.SIDES = 100                      -- rolls are 1..100
E.EDGE = 2                         -- percent the house keeps
E.MIN_TARGET, E.MAX_TARGET = 2, 95 -- "roll under" this number or lower: 2% to 95% to win
E.ROLL_SECONDS = 1.2               -- the dice "tumble" for show; the number is drawn when they stop

local function touch(t) t.rev = (t.rev or 0) + 1 end
local function wholeSilver(n) return type(n) == "number" and n == math.floor(n) and n % Odds.STAKE_STEP == 0 end

function E.ValidTarget(n)
    return type(n) == "number" and n == math.floor(n) and n >= E.MIN_TARGET and n <= E.MAX_TARGET
end

-- Chance to win, 0..1.
function E.Chance(target) return target / E.SIDES end

-- What the payout is, as a multiple of the stake (stake included): 49 -> 2.0.
function E.Multiplier(target) return (E.SIDES - E.EDGE) / target end

-- Copper returned for a winning bet (stake included). Whole copper, rounded down.
function E.Payout(amount, target) return math.floor(amount * (E.SIDES - E.EDGE) / target) end

------------------------------------------------------------------------------------------
-- Betting
------------------------------------------------------------------------------------------

function E.PlaceBet(t, name, round, bet, ref)
    local m = t.members[name]
    if not m or m.status ~= "seated" then return nil, "not_seated" end
    if ref ~= nil then
        for _, b in ipairs(m.bets) do if b.ref == ref then return b, nil, true end end
    end
    if t.status ~= "betting" or round ~= t.round then return nil, "round_closed" end
    if type(bet) ~= "table" or bet.kind ~= "roll" or not wholeSilver(bet.amount) or bet.amount <= 0
        or not E.ValidTarget(bet.pick) then return nil, "bad_bet" end
    if #m.bets > 0 then return nil, "bad_bet" end
    if bet.amount < t.minBet then return nil, "min_bet", t.minBet end
    if bet.amount > t.maxBet then return nil, "max_bet", t.maxBet end
    if m.balance < bet.amount then return nil, "no_balance", m.balance end
    local stored = { id = t.nextBetId, ref = ref, kind = "roll", amount = bet.amount, pick = bet.pick }
    t.nextBetId = t.nextBetId + 1
    m.balance = m.balance - bet.amount
    m.bets[#m.bets + 1] = stored
    touch(t)
    return stored
end

function E.ClearBets(t, name, round)
    local m = t.members[name]
    if not m or m.status ~= "seated" then return nil, "not_seated" end
    if t.status ~= "betting" or round ~= t.round then return nil, "round_closed" end
    local back = 0
    for _, b in ipairs(m.bets) do back = back + b.amount end
    Casino.Refund(m)
    if back > 0 then touch(t) end
    return back
end

------------------------------------------------------------------------------------------
-- The roll
------------------------------------------------------------------------------------------

-- Betting stops; the glue waits E.ROLL_SECONDS, then calls Finish.
function E.Roll(t, now)
    if t.status ~= "betting" then return nil, "not_betting" end
    local any = false
    for _, name in ipairs(Casino.Seated(t)) do
        if #t.members[name].bets > 0 then any = true end
    end
    if not any then return nil, "no_bets" end
    t.status = "rolling"
    t.rollAt = now
    t.autoAt = nil
    touch(t)
    return true
end

-- Draw the number (rng(n) returns 1..n), pay everyone, record it and open the next round. Returns the
-- result record (the same shape as a roulette result: `number` is the roll).
function E.Finish(t, rng, now)
    if t.status ~= "rolling" then return nil, "not_rolling" end
    local roll = (rng or math.random)(E.SIDES)
    local results = {}
    for _, name in ipairs(Casino.Seated(t)) do
        local m = t.members[name]
        if #m.bets > 0 then
            local staked, returned, bets = 0, 0, {}
            for i, b in ipairs(m.bets) do
                local win = roll <= b.pick and E.Payout(b.amount, b.pick) or 0
                staked, returned = staked + b.amount, returned + win
                bets[i] = { kind = b.kind, amount = b.amount, pick = b.pick, id = b.id, win = win }
            end
            m.balance = m.balance + returned
            m.bets = {}
            results[#results + 1] = { name = name, net = returned - staked, balance = m.balance, bets = bets }
        end
    end
    table.insert(t.history, 1, roll)
    while #t.history > Casino.HISTORY_KEEP do table.remove(t.history) end
    t.lastResult = { round = t.round, number = roll, results = results, at = now }
    t.round = t.round + 1
    t.status = "betting"
    t.rollAt = nil
    touch(t)
    return t.lastResult
end

-- After a reload: a roll that never finished is cancelled and the bets returned.
function E.Recover(t)
    if t.status == "rolling" then
        for _, m in pairs(t.members) do Casino.Refund(m) end
        t.status = "betting"
        t.rollAt = nil
        touch(t)
    end
end

return E
