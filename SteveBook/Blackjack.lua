-- Blackjack.lua: cards, hand totals and payouts. Pure Lua: no WoW API calls, plain-lua5.1 testable.
-- A card is a two-letter string: rank then suit, e.g. "AS", "TH" (T = ten), "7D".
-- Rules used by the casino table (SPEC §11): six decks; blackjack pays 3:2; the dealer stands on
-- every 17 and peeks for blackjack; double down on any two cards (also after a split); one split per
-- hand (no re-splitting), split aces get one card each; no insurance, no surrender.
local ADDON, ns = ...
ns = ns or {}

local Blackjack = {}
ns.Blackjack = Blackjack

Blackjack.DECKS = 6
local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K" }
local SUITS = { "S", "H", "D", "C" }
Blackjack.RANKS, Blackjack.SUITS = RANKS, SUITS

function Blackjack.Rank(card) return card:sub(1, 1) end
function Blackjack.Suit(card) return card:sub(2, 2) end

-- Is this a real card string?
function Blackjack.IsCard(card)
    if type(card) ~= "string" or #card ~= 2 then return false end
    return ("A23456789TJQK"):find(card:sub(1, 1), 1, true) ~= nil and ("SHDC"):find(card:sub(2, 2), 1, true) ~= nil
end

-- Points of one rank with an ace counted as 11.
local function points(rank)
    if rank == "A" then return 11 end
    if rank == "T" or rank == "J" or rank == "Q" or rank == "K" then return 10 end
    return tonumber(rank)
end
Blackjack.Points = points

-- Shuffle in place (Fisher-Yates). `rng(m, n)` defaults to math.random.
function Blackjack.Shuffle(list, rng)
    rng = rng or math.random
    for i = #list, 2, -1 do
        local j = rng(1, i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

function Blackjack.NewShoe(decks, rng)
    local shoe = {}
    for _ = 1, decks or Blackjack.DECKS do
        for _, s in ipairs(SUITS) do
            for _, r in ipairs(RANKS) do shoe[#shoe + 1] = r .. s end
        end
    end
    return Blackjack.Shuffle(shoe, rng)
end

-- Best total of a hand, and whether it is "soft" (an ace is still counted as 11).
function Blackjack.Value(cards)
    local total, aces = 0, 0
    for _, c in ipairs(cards) do
        local p = points(c:sub(1, 1))
        total = total + p
        if p == 11 then aces = aces + 1 end
    end
    while total > 21 and aces > 0 do total = total - 10; aces = aces - 1 end
    return total, aces > 0
end

-- Two cards making 21.
function Blackjack.IsBlackjack(cards)
    return #cards == 2 and (Blackjack.Value(cards)) == 21
end

-- Can this two-card hand split? (same points: any two ten-value cards may split)
function Blackjack.CanSplit(cards)
    return #cards == 2 and points(cards[1]:sub(1, 1)) == points(cards[2]:sub(1, 1))
end

-- Does the dealer draw another card? (stands on every 17, or hits a soft 17 when asked to)
function Blackjack.DealerHits(cards, hitSoft17)
    local total, soft = Blackjack.Value(cards)
    if total < 17 then return true end
    if total == 17 and soft and hitSoft17 then return true end
    return false
end

-- The dealer's finished hand: { total, bust, blackjack }.
function Blackjack.DealerResult(cards)
    local total = Blackjack.Value(cards)
    return { total = total, bust = total > 21, blackjack = Blackjack.IsBlackjack(cards) }
end

-- One hand against the dealer. hand = { cards, bet, natural }, dealer = DealerResult.
-- Returns outcome ("bust" | "blackjack" | "win" | "push" | "lose") and the copper returned to the
-- player (stake included): 0 for a loss, bet for a push, 2x for a win, 2.5x for blackjack.
function Blackjack.Settle(hand, dealer)
    local total = Blackjack.Value(hand.cards)
    if total > 21 then return "bust", 0 end
    if hand.natural then
        if dealer.blackjack then return "push", hand.bet end
        return "blackjack", hand.bet + math.floor(hand.bet * 3 / 2)
    end
    if dealer.blackjack then return "lose", 0 end
    if dealer.bust or total > dealer.total then return "win", hand.bet * 2 end
    if total == dealer.total then return "push", hand.bet end
    return "lose", 0
end

-- "10" for a ten, else the rank letter.
function Blackjack.RankLabel(card)
    local r = card:sub(1, 1)
    return r == "T" and "10" or r
end

return Blackjack
