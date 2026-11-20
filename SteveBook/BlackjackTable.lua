-- BlackjackTable.lua: the blackjack engine for a casino table (SPEC §11). Pure Lua, no WoW API
-- calls. It plugs into Casino.lua as Casino.Engines.blackjack; chips, members and the generic
-- messages stay in Casino.lua. The host's client holds the shoe and the dealer's hole card, so a
-- player only ever receives cards that are face up.
--
-- t.bj = { phase = "betting" | "playing" | "dealer", shoe, pos, dealer = { cards }, hole = bool,
--          order = { names dealt in }, hands = { [name] = { {cards, bet, state, natural, doubled,
--          split, aces} } }, turn = { name, hand } | nil, deadline }
-- Hand states: "playing" | "stand" | "bust" | "blackjack". t.status mirrors the phase
-- ("betting" | "playing" | "dealer") and is "closed" once the table is closed.
-- A member's m.bets lists every chip stack they have out (wager, doubles, splits) so the generic
-- refund (kick, leave, close, recover) returns exactly what is on the table.
local ADDON, ns = ...
ns = ns or {}

local Casino, Blackjack, Odds = ns.Casino, ns.Blackjack, ns.Odds
local E = {}
ns.BlackjackTable = E
Casino.Engines.blackjack = E

E.TURN_SECONDS = 30            -- a player who does nothing is stood after this long
E.DEALER_SECONDS = 2           -- the pause before the dealer's cards turn over
E.RESHUFFLE_BELOW = 60         -- shuffle a fresh shoe when fewer cards than this are left

local function touch(t) t.rev = (t.rev or 0) + 1 end
local function wholeSilver(n) return type(n) == "number" and n == math.floor(n) and n % Odds.STAKE_STEP == 0 end

local function copyCards(cards)
    local out = {}
    for i, c in ipairs(cards) do out[i] = c end
    return out
end

local function fresh()
    return { phase = "betting", shoe = {}, pos = 1, dealer = {}, hole = false, order = {}, hands = {} }
end

function E.Init(t) t.bj = fresh() end

local function resetRound(t)
    local bj = t.bj
    bj.phase = "betting"
    bj.dealer, bj.hole, bj.order, bj.hands = {}, false, {}, {}
    bj.turn, bj.deadline = nil, nil
    if t.status ~= "closed" then t.status = "betting" end
end

local function draw(t)
    local bj = t.bj
    if bj.pos > #bj.shoe then bj.shoe = Blackjack.NewShoe(); bj.pos = 1 end    -- only if a round outlasts the shoe
    local c = bj.shoe[bj.pos]
    bj.pos = bj.pos + 1
    return c
end

local function wagerOf(m)
    for _, b in ipairs(m.bets) do if b.kind == "wager" then return b end end
end

------------------------------------------------------------------------------------------
-- Betting
------------------------------------------------------------------------------------------

-- bet = { kind = "wager", amount }. One wager per round; take it back to change it.
function E.PlaceBet(t, name, round, bet, ref)
    local m = t.members[name]
    if not m or m.status ~= "seated" then return nil, "not_seated" end
    if ref ~= nil then
        for _, b in ipairs(m.bets) do if b.ref == ref then return b, nil, true end end
    end
    if t.status ~= "betting" or round ~= t.round then return nil, "round_closed" end
    if type(bet) ~= "table" or bet.kind ~= "wager" or not wholeSilver(bet.amount) or bet.amount <= 0 then return nil, "bad_bet" end
    if wagerOf(m) then return nil, "bad_bet" end
    if bet.amount < t.minBet then return nil, "min_bet", t.minBet end
    if bet.amount > t.maxBet then return nil, "max_bet", t.maxBet end
    if m.balance < bet.amount then return nil, "no_balance", m.balance end
    local stored = { id = t.nextBetId, ref = ref, kind = "wager", amount = bet.amount }
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
-- The round
------------------------------------------------------------------------------------------

-- Move to the next hand that still needs a decision, or to the dealer.
local function moveTurn(t, now)
    local bj = t.bj
    bj.lastNow = now or bj.lastNow or 0
    for _, name in ipairs(bj.order) do
        for i, h in ipairs(bj.hands[name] or {}) do
            if h.state == "playing" then
                bj.turn = { name = name, hand = i }
                bj.deadline = bj.lastNow + E.TURN_SECONDS
                touch(t)
                return
            end
        end
    end
    bj.turn, bj.deadline = nil, nil
    bj.phase = "dealer"
    t.status = "dealer"
    bj.hole = false                                   -- the hole card turns over
    touch(t)
end

-- Deal the round to everyone who has a wager. Returns true, info or nil, reason. info =
-- { shuffled, dealerBlackjack }: with dealerBlackjack the caller finishes the round straight away.
function E.Deal(t, rng, now)
    if t.status ~= "betting" then return nil, "not_betting" end
    local bj = t.bj
    local names = {}
    for _, name in ipairs(Casino.Seated(t)) do
        if wagerOf(t.members[name]) then names[#names + 1] = name end
    end
    if #names == 0 then return nil, "no_bets" end
    table.sort(names, function(a, b)
        local ja, jb = t.members[a].joinedAt or 0, t.members[b].joinedAt or 0
        if ja ~= jb then return ja < jb end
        return a < b
    end)
    local shuffled = false
    if #bj.shoe - bj.pos + 1 < E.RESHUFFLE_BELOW then
        bj.shoe = Blackjack.NewShoe(Blackjack.DECKS, rng); bj.pos = 1; shuffled = true
    end
    bj.hands = {}
    for _, name in ipairs(names) do
        bj.hands[name] = { { cards = {}, bet = wagerOf(t.members[name]).amount, state = "playing" } }
    end
    bj.dealer = {}
    for pass = 1, 2 do
        for _, name in ipairs(names) do
            local cards = bj.hands[name][1].cards
            cards[#cards + 1] = draw(t)
        end
        bj.dealer[#bj.dealer + 1] = draw(t)
    end
    for _, name in ipairs(names) do
        local h = bj.hands[name][1]
        if Blackjack.IsBlackjack(h.cards) then h.natural = true; h.state = "blackjack" end
    end
    bj.order = names
    bj.hole = true
    bj.phase = "playing"
    t.status = "playing"
    bj.lastNow = now or 0
    touch(t)
    local up = Blackjack.Points(Blackjack.Rank(bj.dealer[1]))
    if up >= 10 and Blackjack.IsBlackjack(bj.dealer) then       -- the dealer peeks
        bj.hole = false
        bj.phase = "dealer"
        t.status = "dealer"
        return true, { shuffled = shuffled, dealerBlackjack = true }
    end
    moveTurn(t, now)
    return true, { shuffled = shuffled }
end

-- One decision from the player whose turn it is. Returns true, or nil, reason:
-- "round_closed" (not playing, or stale round), "not_your_turn", "bad_action", "no_balance".
function E.Act(t, name, round, action, now)
    local bj = t.bj
    if t.status ~= "playing" or round ~= t.round then return nil, "round_closed" end
    if not (bj.turn and bj.turn.name == name) then return nil, "not_your_turn" end
    local m = t.members[name]
    local hands = bj.hands[name]
    local h = hands[bj.turn.hand]
    bj.lastNow = now or bj.lastNow

    if action == "hit" then
        if h.aces and h.split then return nil, "bad_action" end          -- split aces take one card only
        h.cards[#h.cards + 1] = draw(t)
        local v = Blackjack.Value(h.cards)
        if v > 21 then h.state = "bust" elseif v == 21 then h.state = "stand" end
    elseif action == "stand" then
        h.state = "stand"
    elseif action == "double" then
        if #h.cards ~= 2 or (h.aces and h.split) then return nil, "bad_action" end
        if m.balance < h.bet then return nil, "no_balance" end
        m.balance = m.balance - h.bet
        m.bets[#m.bets + 1] = { id = t.nextBetId, kind = "double", amount = h.bet }
        t.nextBetId = t.nextBetId + 1
        h.bet = h.bet * 2
        h.doubled = true
        h.cards[#h.cards + 1] = draw(t)
        h.state = Blackjack.Value(h.cards) > 21 and "bust" or "stand"
    elseif action == "split" then
        if #hands ~= 1 or not Blackjack.CanSplit(h.cards) then return nil, "bad_action" end
        if m.balance < h.bet then return nil, "no_balance" end
        m.balance = m.balance - h.bet
        m.bets[#m.bets + 1] = { id = t.nextBetId, kind = "split", amount = h.bet }
        t.nextBetId = t.nextBetId + 1
        local aces = Blackjack.Rank(h.cards[1]) == "A"
        local second = { cards = { h.cards[2], draw(t) }, bet = h.bet, state = "playing", split = true, aces = aces }
        h.cards = { h.cards[1], draw(t) }
        h.split, h.aces = true, aces
        h.state, second.state = "playing", "playing"
        if aces then h.state, second.state = "stand", "stand" end         -- one card each, no more
        for _, hh in ipairs({ h, second }) do
            if hh.state == "playing" and Blackjack.Value(hh.cards) == 21 then hh.state = "stand" end
        end
        hands[2] = second
    else
        return nil, "bad_action"
    end
    touch(t)
    moveTurn(t, now)
    return true
end

-- A turn that ran out of time. Returns the name stood, or nil.
function E.Tick(t, now)
    local bj = t.bj
    if t.status == "playing" and bj.turn and bj.deadline and now >= bj.deadline then
        return E.Skip(t, now)
    end
end

-- Stand the player whose turn it is (host button, or the timer). Returns their name, or nil.
function E.Skip(t, now)
    local bj = t.bj
    if t.status ~= "playing" or not bj.turn then return nil end
    local name = bj.turn.name
    bj.hands[name][bj.turn.hand].state = "stand"
    moveTurn(t, now)
    return name
end

-- The dealer plays out, hands are settled, the next round opens. Returns the result record.
function E.FinishDealer(t, now)
    if t.status ~= "dealer" then return nil, "not_dealer" end
    local bj = t.bj
    bj.hole = false
    local live = false
    for _, name in ipairs(bj.order) do
        for _, h in ipairs(bj.hands[name] or {}) do if h.state == "stand" then live = true end end
    end
    if live and not Blackjack.IsBlackjack(bj.dealer) then
        while Blackjack.DealerHits(bj.dealer) do bj.dealer[#bj.dealer + 1] = draw(t) end
    end
    local dres = Blackjack.DealerResult(bj.dealer)
    local results = {}
    for _, name in ipairs(bj.order) do
        local m, hands = t.members[name], bj.hands[name]
        if m and hands then
            local staked, returned, entries = 0, 0, {}
            for i, h in ipairs(hands) do
                local outcome, ret = Blackjack.Settle(h, dres)
                staked, returned = staked + h.bet, returned + ret
                entries[i] = { cards = copyCards(h.cards), bet = h.bet, outcome = outcome, win = ret }
            end
            m.balance = m.balance + returned
            m.bets = {}
            results[#results + 1] = { name = name, net = returned - staked, balance = m.balance, hands = entries }
        end
    end
    t.lastResult = {
        round = t.round, at = now, results = results,
        dealer = { cards = copyCards(bj.dealer), total = dres.total, bust = dres.bust, blackjack = dres.blackjack },
    }
    t.round = t.round + 1
    resetRound(t)
    touch(t)
    return t.lastResult
end

------------------------------------------------------------------------------------------
-- Leaving, closing, recovering
------------------------------------------------------------------------------------------

-- A player was removed or left (Casino already gave their chips back): drop their hands.
function E.OnRemoved(t, name)
    local bj = t.bj
    if not bj.hands[name] then return end
    bj.hands[name] = nil
    for i, n in ipairs(bj.order) do if n == name then table.remove(bj.order, i); break end end
    if #bj.order == 0 then resetRound(t); return end
    if t.status == "playing" and bj.turn and bj.turn.name == name then moveTurn(t, bj.lastNow) end
end

function E.OnClosed(t) resetRound(t) end

-- After a reload: a round that never finished is cancelled and every stack is returned.
function E.Recover(t)
    if t.status == "playing" or t.status == "dealer" then
        for _, m in pairs(t.members) do Casino.Refund(m) end
        resetRound(t)
        touch(t)
    end
end

------------------------------------------------------------------------------------------
-- What everyone may see
------------------------------------------------------------------------------------------

-- Public table state for TBL_STATE: the dealer's hole card is left out until it turns over.
function E.Public(t)
    local bj = t.bj
    local pub = { phase = bj.phase, shoe = math.max(0, #bj.shoe - bj.pos + 1), hands = {} }
    if bj.phase == "betting" then
        for _, name in ipairs(Casino.Seated(t)) do
            local w = wagerOf(t.members[name])
            if w then pub.hands[#pub.hands + 1] = { name = name, hands = { { cards = {}, bet = w.amount, state = "bet" } } } end
        end
        pub.dealer = { cards = {}, hidden = false }
        return pub
    end
    local up = {}
    if bj.hole then up[1] = bj.dealer[1] else up = copyCards(bj.dealer) end
    pub.dealer = { cards = up, hidden = bj.hole }
    if not bj.hole then pub.dealer.value = (Blackjack.Value(up)) end
    for _, name in ipairs(bj.order) do
        local hands = {}
        for i, h in ipairs(bj.hands[name] or {}) do
            local v, soft = Blackjack.Value(h.cards)
            hands[i] = { cards = copyCards(h.cards), bet = h.bet, state = h.state, value = v, soft = soft and true or false }
        end
        pub.hands[#pub.hands + 1] = { name = name, hands = hands }
    end
    if bj.turn then pub.turn, pub.turnHand, pub.deadline = bj.turn.name, bj.turn.hand, bj.deadline end
    return pub
end

return E
