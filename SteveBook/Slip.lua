-- Slip.lua: the bettor's bet slip (SPEC §3a). Pure logic: no WoW API calls, testable with plain
-- Lua. The window (UI/Bettor.lua) only draws what this holds.
--
-- A slip keeps two independent selections, one per mode:
--   single = one leg (a one-bet slip), or nil
--   parlay = a list of 2..8 legs
-- Clicking an odds cell calls Slip.Select, which acts on the current mode. A leg is
--   { marketId, selectionId, odds, market = Market }   (market is a reference to the cached
--   market, refreshed by Slip.Sync; changedFrom = old odds when the price moved under the bettor)
-- `s.confirm[mode]` is true while the bettor has to look at changed odds and confirm.
-- Load order: after Odds.lua and Cache.lua.
local ADDON, ns = ...
ns = ns or {}

local Slip = {}
ns.Slip = Slip

local function Odds() return ns.Odds end
local function Cache() return ns.Cache end

function Slip.New()
    return { mode = "single", single = nil, parlay = {}, confirm = {} }
end

function Slip.SetMode(s, mode)
    if mode == "single" or mode == "parlay" then s.mode = mode end
end

-- Legs of the current mode, in order.
function Slip.Legs(s)
    if s.mode == "parlay" then return s.parlay end
    return s.single and { s.single } or {}
end

function Slip.ParlayCount(s) return #s.parlay end

function Slip.Clear(s)
    if s.mode == "parlay" then s.parlay = {} else s.single = nil end
    s.confirm[s.mode] = nil
end

function Slip.ClearAll(s)
    s.single, s.parlay, s.confirm = nil, {}, {}
end

function Slip.IsSelected(s, marketId, selectionId)
    for _, leg in ipairs(Slip.Legs(s)) do
        if leg.marketId == marketId and leg.selectionId == selectionId then return true end
    end
    return false
end

local TYPE_NAME = { moneyline = "Moneyline", spread = "Spread", total = "Total" }
Slip.TypeName = TYPE_NAME

-- "LAL +5.5 (Spread, LAL @ BOS)": how a leg is named in messages.
function Slip.Describe(leg)
    local m = leg.market
    return ("%s (%s, %s)"):format(Cache().SelectionText(m, leg.selectionId),
        m and TYPE_NAME[m.type] or "?", m and m.event or "?")
end

local function newLeg(market, selectionId)
    local sel = Cache().Selection(market, selectionId)
    if not sel then return nil end
    return { marketId = market.id, selectionId = selectionId, odds = sel.odds, line = market.line, market = market }
end

-- Click on an odds cell. Returns action, message:
--   "set"      single mode: this is now the selection
--   "added"    parlay mode: leg added
--   "replaced" the other side of the same market replaced the previous pick
--   "removed"  the same pick again takes it off the slip
--   "refused"  with a message naming the reason (too many legs, or a conflicting leg)
function Slip.Select(s, market, selectionId)
    local leg = newLeg(market, selectionId)
    if not leg then return "refused", "That selection is not available." end

    if s.mode == "single" then
        local cur = s.single
        s.confirm.single = nil
        if cur and cur.marketId == leg.marketId then
            if cur.selectionId == selectionId then s.single = nil; return "removed" end
            s.single = leg
            return "replaced"
        end
        s.single = leg
        return "set"
    end

    local legs = s.parlay
    for i, cur in ipairs(legs) do
        if cur.marketId == leg.marketId then
            if cur.selectionId == selectionId then
                table.remove(legs, i)
                s.confirm.parlay = nil
                return "removed"
            end
            -- The other side of the same market: replaces the pick in place (like a normal slip).
            local trial = {}
            for k, l in ipairs(legs) do trial[k] = l end
            trial[i] = leg
            local ok, msg = Slip.CheckConflict(trial, i)
            if not ok then return "refused", msg end
            legs[i] = leg
            s.confirm.parlay = nil
            return "replaced"
        end
    end

    if #legs >= Odds().MAX_PARLAY_LEGS then
        return "refused", ("A parlay can have at most %d legs."):format(Odds().MAX_PARLAY_LEGS)
    end
    local trial = {}
    for k, l in ipairs(legs) do trial[k] = l end
    trial[#trial + 1] = leg
    local ok, msg = Slip.CheckConflict(trial, #trial)
    if not ok then return "refused", msg end
    legs[#legs + 1] = leg
    s.confirm.parlay = nil
    return "added"
end

-- Markets of the legs, in leg order, as Odds.ParlayConflict wants them.
function Slip.Markets(legs)
    local out = {}
    for i, leg in ipairs(legs) do out[i] = leg.market or { id = leg.marketId } end
    return out
end

-- Do the legs obey the parlay rules (Odds.ParlayConflict)? `newIndex` is the leg just added or
-- swapped in. Returns true, or false, message naming the leg it clashes with.
function Slip.CheckConflict(legs, newIndex)
    local ok, why, a, b = Odds().ParlayConflict(Slip.Markets(legs))
    if ok then return true end
    local mine = legs[newIndex]
    local other = legs[a == newIndex and b or a]
    if why == "duplicate_market" then
        return false, Slip.Describe(mine) .. " is already on the slip."
    end
    return false, ("%s can't go with %s: from one game a parlay may hold one side bet (moneyline or spread) plus one total.")
        :format(Slip.Describe(mine), other and Slip.Describe(other) or "another leg")
end

-- Remove the leg at `index` from the current mode's list.
function Slip.Remove(s, index)
    if s.mode == "parlay" then
        if s.parlay[index] then table.remove(s.parlay, index) end
        s.confirm.parlay = nil
    else
        s.single = nil
        s.confirm.single = nil
    end
end

-- Replace the legs of a mode wholesale (used to restore the slip after a rejection).
-- `list` = { {marketId, selectionId, odds, line}, ... }; `getMarket(id)` -> Market|nil. Legs whose
-- market is missing are skipped (returned in `skipped`).
function Slip.Restore(s, mode, list, getMarket)
    local legs, skipped = {}, {}
    for i, l in ipairs(list) do
        local m = getMarket(l.marketId)
        if m then
            legs[#legs + 1] = { marketId = l.marketId, selectionId = l.selectionId, odds = l.odds, line = l.line, market = m }
        else
            skipped[#skipped + 1] = i
        end
    end
    if mode == "parlay" then s.parlay = legs else s.single = legs[1] end
    s.confirm[mode] = nil
    s.mode = mode
    return skipped
end

-- Bring every leg (both modes) in line with the cache. Legs whose game has started, finished or
-- vanished are dropped; legs whose odds moved take the new odds and ask for a confirmation.
-- Returns dropped = { {leg, reason = "started"|"gone"} }, changed = { leg }.
function Slip.Sync(s, getMarket, now)
    local dropped, changed = {}, {}
    local function fix(leg, mode)
        local m = getMarket(leg.marketId)
        if not m then
            -- Gone from the cache (a SYNC drops started games nobody bet on). The market we kept
            -- when the leg was added still knows whether it had started.
            local started = leg.market and Cache().IsClosed(leg.market, now)
            dropped[#dropped + 1] = { leg = leg, reason = started and "started" or "gone" }
            return false
        end
        if Cache().IsClosed(m, now) then
            leg.market = m
            dropped[#dropped + 1] = { leg = leg, reason = "started" }
            return false
        end
        local sel = Cache().Selection(m, leg.selectionId)
        if not sel then dropped[#dropped + 1] = { leg = leg, reason = "gone" }; return false end
        leg.market = m
        -- Lines move in place (a spread or total), with new odds; either one needs a confirmation.
        local moved = false
        if sel.odds ~= leg.odds then
            leg.changedFrom = leg.changedFrom or leg.odds
            leg.odds = sel.odds
            moved = true
        end
        if m.line ~= leg.line then
            leg.lineChangedFrom = leg.lineChangedFrom or leg.line
            leg.line = m.line
            moved = true
        end
        if moved then
            s.confirm[mode] = true
            changed[#changed + 1] = leg
        end
        return true
    end
    if s.single and not fix(s.single, "single") then s.single = nil; s.confirm.single = nil end
    local keep = {}
    for _, leg in ipairs(s.parlay) do
        if fix(leg, "parlay") then keep[#keep + 1] = leg end
    end
    s.parlay = keep
    return dropped, changed
end

-- The bettor looked at the changed odds or line and wants to go ahead.
function Slip.Confirm(s)
    for _, leg in ipairs(Slip.Legs(s)) do leg.changedFrom, leg.lineChangedFrom = nil, nil end
    s.confirm[s.mode] = nil
end

function Slip.NeedsConfirm(s) return s.confirm[s.mode] == true end

-- Price of the current slip: a single's odds, or the parlay's combined American odds (2+ legs).
function Slip.Odds(s)
    local legs = Slip.Legs(s)
    if s.mode == "single" then return legs[1] and legs[1].odds or nil end
    if #legs < 2 then return nil end
    local list = {}
    for i, leg in ipairs(legs) do list[i] = leg.odds end
    return (Odds().ParlayOdds(list))
end

-- Profit if it wins, in copper, for a valid stake; nil otherwise.
function Slip.ToWin(s, stake)
    local legs = Slip.Legs(s)
    if not stake or #legs == 0 then return nil end
    if s.mode == "single" then return (Odds().Profit(stake, legs[1].odds)) end
    if #legs < 2 then return nil end
    local list = {}
    for i, leg in ipairs(legs) do list[i] = leg.odds end
    return (Odds().ParlayProfit(stake, list))
end

-- Can this slip be placed? `stake` is copper or nil (nothing valid typed). `canBet(marketId)` ->
-- true, or false, reason (online + market open; Cache.CanBet). Returns true, or false, code,
-- message. Codes: "empty", "legs", "confirm", "closed", "stake_missing", "stake".
function Slip.Validate(s, stake, canBet)
    local legs = Slip.Legs(s)
    if #legs == 0 then return false, "empty", "" end
    if s.mode == "parlay" then
        local ok, _, msg = Odds().ParlayLegCheck(#legs)
        if not ok then return false, "legs", ("Add at least %d legs."):format(Odds().MIN_PARLAY_LEGS) end
    end
    for _, leg in ipairs(legs) do
        local ok, why = canBet(leg.marketId)
        if not ok then return false, "closed", Cache().ReasonText(why == "no_market" and "market_closed" or why) end
    end
    if s.confirm[s.mode] then return false, "confirm", "The odds or line changed. Check them, then click again to confirm." end
    if not stake then return false, "stake_missing", "" end
    local ok, _, msg = Odds().StakeCheck(stake)
    if not ok then return false, "stake", msg end
    return true
end

-- The BET_PLACE payload for the current slip. Singles keep the flat fields; a parlay has legs.
-- `line` is the spread/total line the slip showed (nil for a moneyline, so it is simply absent).
function Slip.Request(s, ref, stake)
    local legs = Slip.Legs(s)
    if s.mode == "single" then
        local l = legs[1]
        return { ref = ref, marketId = l.marketId, selectionId = l.selectionId, stake = stake, odds = l.odds, line = l.line }
    end
    local out = {}
    for i, l in ipairs(legs) do out[i] = { marketId = l.marketId, selectionId = l.selectionId, odds = l.odds, line = l.line } end
    return { ref = ref, stake = stake, legs = out }
end

return Slip
