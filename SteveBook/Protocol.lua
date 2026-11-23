-- Protocol.lua: message names, payload shapes, envelope, validation (SPEC §5).
-- Pure Lua: no WoW API calls. Transport (channel, AceComm, serialization) lives in Comm.lua.
local ADDON, ns = ...
ns = ns or {}

local Protocol = {}
ns.Protocol = Protocol

Protocol.VERSION = 1
Protocol.LOBBY_CODE = "LBY-CSNO"          -- the casino lobby channel (SBNLBYCSNO)

-- dir: who may send it. "bettor" = bettor -> bookie, "bookie" = bookie -> bettor (or all),
-- "any" = either side.
-- fields: name = "type" where type is a Lua type name; a trailing "?" marks the field optional.
-- Shapes of nested tables (Market, Bet) are the SPEC §4 records.
Protocol.Spec = {
    JOIN_REQ   = { dir = "bettor", fields = {} },
    JOIN_OK    = { dir = "bookie", fields = { bookName = "string", ownerName = "string", rev = "number" } },
    JOIN_DENY  = { dir = "bookie", fields = { ownerName = "string", reason = "string?" } },   -- ownerName lets the bettor check who sent it

    SYNC_REQ   = { dir = "bettor", fields = { rev = "number" } },            -- last rev the bettor holds (0 if none)
    SYNC       = { dir = "bookie", fields = {
        rev = "number",
        bookName = "string",
        markets = "table",      -- array of Market
        bets = "table",         -- array of that bettor's Bets only
        balance = "number",     -- copper, positive = book owes bettor
        payments = "table?",    -- recent { amount, at, note } for this bettor
        creditLimit = "number?",    -- copper, nil = no limit
    } },
    -- A SYNC_REQ from a non-member is answered with JOIN_DENY { reason = "not_member" };
    -- from a pending member it is ignored (the bettor stays "requested").

    MARKET     = { dir = "bookie", fields = { rev = "number", market = "table" } },   -- new/updated/locked/settled/void

    BET_PLACE  = { dir = "bettor", fields = {
        ref = "string",         -- client nonce chosen by bettor; stored on the Bet, echoed in ACK/REJECT
        marketId = "number?",   -- SPEC §4 ids are numbers. A single bet has marketId, selectionId and
        selectionId = "number?",--   odds; a parlay has `legs` instead (checked in Validate).
        stake = "number",       -- copper
        odds = "number?",       -- American odds the bettor saw
        line = "number?",       -- spread/total only: the line the bettor saw (single bet; legs carry their own)
        legs = "table?",        -- parlay: list of { marketId, selectionId, odds, line? }, 2..8 long, in slip order
    } },
    BET_ACK    = { dir = "bookie", fields = { ref = "string", bet = "table", balance = "number?" } },
    BET_REJECT = { dir = "bookie", fields = {
        ref = "string",
        reason = "string",      -- one of Protocol.REJECT_REASONS
        currentOdds = "number?",    -- set when reason == "odds_changed"
        currentLine = "number?",    -- odds_changed because the spread/total line moved: the market's current line
        legIndex = "number?",       -- parlay only: 1-based leg the reason is about (odds_changed, market_closed,
                                    --   no_market, bad_selection) or the later leg of a parlay_conflict
        available = "number?",      -- copper still available, set when reason == "credit_limit"
    } },

    -- "All bets" view (SPEC §3b): any active member may ask for the group's bets. The bookie answers
    -- the asker only. `bets` is a list of entries { id, who, text, stake, status, at, win? } with `text`
    -- already rendered by the bookie ("LAL +5.5 -110, LAL @ BOS" or "3-leg parlay +738: ...").
    BETS_REQ   = { dir = "bettor", fields = {} },
    BETS       = { dir = "bookie", fields = { rev = "number", bets = "table" } },

    -- Casino tables (SPEC §11). The envelope's book code is the TABLE code ("RLT-K7Q2"). "bettor"
    -- = player -> host, "bookie" = host -> players, exactly as for books. Chips are the table's own
    -- credit balance in copper, allotted by the host; they are not the sportsbook balance.
    TBL_JOIN       = { dir = "bettor", fields = {} },                   -- ask for a seat
    TBL_LEAVE      = { dir = "bettor", fields = {} },
    TBL_SYNC_REQ   = { dir = "bettor", fields = { rev = "number" } },   -- last table rev the player holds (0 if none)
    TBL_BET        = { dir = "bettor", fields = {
        ref = "string",         -- client nonce, echoed in TBL_BET_OK / TBL_BET_REJECT
        round = "number",       -- the round the player saw; the host rejects a bet for any other round
        bet = "table",          -- game specific; roulette: { kind, numbers?, pick?, amount } (Roulette.lua)
    } },
    TBL_BET_CLEAR  = { dir = "bettor", fields = { round = "number" } }, -- take back all my bets this round
    TBL_ACT        = { dir = "bettor", fields = {      -- blackjack: a decision on my turn
        ref = "string?", round = "number",
        action = "string",      -- "hit" | "stand" | "double" | "split"
    } },

    -- The casino lobby (SPEC §11): everyone with the casino open sits in one shared hidden channel
    -- (envelope code Protocol.LOBBY_CODE). Hosts announce their open tables there; anyone may ask.
    LOBBY_ASK      = { dir = "any", fields = { ver = "string?" } },                      -- "who is hosting?"; hosts answer with LOBBY_TABLE
    LOBBY_TABLE    = { dir = "any", fields = { tables = "table", ver = "string?" } },    -- list of { code, game, name, host, seats, status, minBet, maxBet, zero? }
    LOBBY_BOOKS    = { dir = "any", fields = { books = "table", ver = "string?" } },     -- sportsbooks: list of { code, name, owner, members?, markets? }

    -- House play (SPEC §11a): a bookie's open invitation to play alone against their bank, and the players'
    -- results coming back. All three travel in the lobby channel; the last two are addressed (`to`).
    LOBBY_HOUSE    = { dir = "any", fields = {         -- the bookie: "my house is open" (on) or closed, and its bet limits (copper)
        on = "boolean", minBet = "number", maxBet = "number", ver = "string?",
    } },
    HOUSE_REPORT   = { dir = "any", fields = {         -- player -> bookie: my TOTALS so far (the latest replaces the earlier ones)
        rounds = "number", wagered = "number",
        net = "number",         -- copper, positive = the player is up
        games = "table?",       -- { roulette = { rounds, wagered, net }, blackjack = {...} }
        ver = "string?",
    } },
    HOUSE_ACK      = { dir = "any", fields = {         -- bookie -> player: I hold your results up to `rounds`; `paid` is settled
        rounds = "number", paid = "number",
    } },

    TBL_JOIN_OK    = { dir = "bookie", fields = { game = "string", name = "string", ownerName = "string", rev = "number" } },
    TBL_JOIN_DENY  = { dir = "bookie", fields = { ownerName = "string", reason = "string?" } },
    TBL_STATE      = { dir = "bookie", fields = {      -- public table state, broadcast (join, chips, spin, result)
        rev = "number", game = "string", name = "string",
        status = "string",      -- "betting" | "spinning" | "closed" (roulette); "betting" | "playing" | "dealer" | "results" | "closed" (blackjack)
        round = "number",
        minBet = "number", maxBet = "number",           -- copper per bet
        zero = "string?",       -- roulette wheel: "single" | "double" | "none"
        seats = "table",        -- list of { name, balance }
        history = "table",      -- last results, newest first (roulette: pocket numbers)
        bj = "table?",          -- blackjack: public hands, the dealer's face-up cards, whose turn (BlackjackTable.Public)
        auto = "boolean?",      -- automatic rounds are on (the host starts each round itself)
        autoAt = "number?",     -- ...and the server time the bets lock (set once the round's first bet is in)
    } },
    TBL_PLAYER     = { dir = "bookie", fields = {      -- addressed: my chips and my bets in this round
        rev = "number", balance = "number", bets = "table",   -- bets: list of { id, ...the bet }
    } },
    TBL_BET_OK     = { dir = "bookie", fields = { ref = "string", betId = "number", balance = "number" } },
    TBL_BET_REJECT = { dir = "bookie", fields = {
        ref = "string", reason = "string",              -- one of Protocol.TBL_REJECT_REASONS
        balance = "number?", min = "number?", max = "number?",
    } },
    TBL_RESULT     = { dir = "bookie", fields = {      -- broadcast after a spin
        rev = "number", round = "number",
        number = "number?",     -- roulette: the pocket (37 = 00)
        dealer = "table?",      -- blackjack: the dealer's final { cards, total, bust, blackjack }
        results = "table",      -- list of { name, net, balance, bets = list of { ..bet, win } } (roulette)
                                --   or { name, net, balance, hands = list of { cards, bet, outcome, win } } (blackjack)
    } },

    BALANCE    = { dir = "bookie", fields = { rev = "number", balance = "number", note = "string?" } },

    PING       = { dir = "any", fields = {} },
    PONG       = { dir = "any", fields = { rev = "number?" } },
}

Protocol.REJECT_REASONS = {
    "not_member", "no_market", "market_closed", "bad_selection",
    "bad_stake", "odds_changed", "credit_limit", "bad_request", "book_error",
    "parlay_conflict",      -- two legs that may not share a parlay (Odds.ParlayConflict)
}

Protocol.TBL_REJECT_REASONS = {
    "not_seated",       -- not admitted to this table
    "not_your_turn",    -- blackjack: it is someone else's turn
    "bad_action",       -- blackjack: that decision is not allowed on this hand
    "round_closed",     -- the table is spinning or closed, or the round number is stale
    "bad_bet",          -- the bet is not a valid bet for this game
    "min_bet", "max_bet",   -- amount outside the table limits (min / max in the reply)
    "no_balance",       -- the chips on hand do not cover it (balance in the reply)
    "table_error",
}

local function isTblReason(r)
    for _, v in ipairs(Protocol.TBL_REJECT_REASONS) do if v == r then return true end end
    return false
end

local function isReason(r)
    for _, v in ipairs(Protocol.REJECT_REASONS) do if v == r then return true end end
    return false
end

-- Validate a payload against the spec. Returns true, or false, err.
function Protocol.Validate(msgType, payload)
    local spec = Protocol.Spec[msgType]
    if not spec then return false, "unknown message type" end
    if type(payload) ~= "table" then return false, "payload must be a table" end
    for name, ty in pairs(spec.fields) do
        local optional = ty:sub(-1) == "?"
        if optional then ty = ty:sub(1, -2) end
        local v = payload[name]
        if v == nil then
            if not optional then return false, "missing field: " .. name end
        elseif type(v) ~= ty then
            return false, "field " .. name .. " must be a " .. ty
        end
    end
    if msgType == "BET_REJECT" and not isReason(payload.reason) then
        return false, "unknown reject reason"
    end
    if msgType == "TBL_BET_REJECT" and not isTblReason(payload.reason) then
        return false, "unknown table reject reason"
    end
    if msgType == "TBL_BET" then
        local b = payload.bet
        if type(b.kind) ~= "string" or type(b.amount) ~= "number" then return false, "bet needs kind and amount" end
    end
    if msgType == "LOBBY_BOOKS" then
        for i, e in ipairs(payload.books) do
            if type(e) ~= "table" or type(e.code) ~= "string" or type(e.name) ~= "string" or type(e.owner) ~= "string" then
                return false, "book " .. i .. " needs code, name and owner"
            end
        end
    end
    if msgType == "LOBBY_TABLE" then
        for i, e in ipairs(payload.tables) do
            if type(e) ~= "table" or type(e.code) ~= "string" or type(e.game) ~= "string" or type(e.name) ~= "string"
                or type(e.host) ~= "string" or type(e.status) ~= "string" then
                return false, "table " .. i .. " needs code, game, name, host and status"
            end
        end
    end
    if msgType == "TBL_STATE" then
        for i, seat in ipairs(payload.seats) do
            if type(seat) ~= "table" or type(seat.name) ~= "string" or type(seat.balance) ~= "number" then
                return false, "seat " .. i .. " needs name and balance"
            end
        end
    end
    if msgType == "TBL_RESULT" then
        for i, r in ipairs(payload.results) do
            if type(r) ~= "table" or type(r.name) ~= "string" or type(r.net) ~= "number" or type(r.balance) ~= "number" then
                return false, "result " .. i .. " needs name, net and balance"
            end
        end
    end
    if msgType == "BETS" then
        for i, e in ipairs(payload.bets) do
            if type(e) ~= "table" or type(e.who) ~= "string" or type(e.text) ~= "string"
                or type(e.stake) ~= "number" or type(e.status) ~= "string" then
                return false, "bets entry " .. i .. " needs who, text, stake and status"
            end
        end
    end
    if msgType == "BET_PLACE" then
        local single = payload.marketId ~= nil or payload.selectionId ~= nil or payload.odds ~= nil
        if payload.legs ~= nil then
            if payload.line ~= nil then return false, "a parlay's lines belong on its legs" end
            if single then return false, "a parlay has legs instead of marketId, selectionId and odds" end
            local n = #payload.legs
            local lo = ns.Odds and ns.Odds.MIN_PARLAY_LEGS or 2
            local hi = ns.Odds and ns.Odds.MAX_PARLAY_LEGS or 8
            if n < lo or n > hi then return false, "a parlay needs " .. lo .. " to " .. hi .. " legs" end
            for i = 1, n do
                local leg = payload.legs[i]
                if type(leg) ~= "table" or type(leg.marketId) ~= "number"
                    or type(leg.selectionId) ~= "number" or type(leg.odds) ~= "number" then
                    return false, "leg " .. i .. " needs numeric marketId, selectionId and odds"
                end
                if leg.line ~= nil and type(leg.line) ~= "number" then
                    return false, "leg " .. i .. " line must be a number"
                end
            end
        elseif payload.marketId == nil or payload.selectionId == nil or payload.odds == nil then
            return false, "missing field: marketId, selectionId and odds (or legs)"
        end
    end
    return true
end

-- Build the on-the-wire table: { v = version, t = type, c = book code, p = payload }.
function Protocol.Wrap(msgType, bookCode, payload)
    payload = payload or {}
    local ok, err = Protocol.Validate(msgType, payload)
    if not ok then return nil, err end
    if type(bookCode) ~= "string" or bookCode == "" then return nil, "book code required" end
    return { v = Protocol.VERSION, t = msgType, c = bookCode, p = payload }
end

-- Check a received table. Returns msgType, bookCode, payload, or nil, err.
-- `senderRole` is optional ("bettor" or "bookie"); when given, direction is enforced.
function Protocol.Unwrap(env, senderRole)
    if type(env) ~= "table" then return nil, "not a table" end
    if env.v ~= Protocol.VERSION then return nil, "protocol version mismatch" end
    local spec = Protocol.Spec[env.t]
    if not spec then return nil, "unknown message type" end
    if type(env.c) ~= "string" or env.c == "" then return nil, "missing book code" end
    if senderRole and spec.dir ~= "any" and spec.dir ~= senderRole then
        return nil, "wrong direction"
    end
    local ok, err = Protocol.Validate(env.t, env.p)
    if not ok then return nil, err end
    return env.t, env.c, env.p
end

-- Hidden channel name for a book code, e.g. "NFL-K7Q2" -> "SBNNFLK7Q2".
-- Up to v0.7.4 the name was "SB" .. code ("SBNFLK7Q2"). In Forever those names ended up stuck as
-- "disabled" on some characters (a slot, but the server refused every message, and leaving and
-- joining again did not help), while channels with other names worked at once. The extra "N" gives
-- every channel a fresh name; LegacyChannelName is the old one, left when found.
function Protocol.ChannelName(code)
    return "SBN" .. (code or ""):upper():gsub("[^A-Z0-9]", "")
end
function Protocol.LegacyChannelName(code)
    return "SB" .. (code or ""):upper():gsub("[^A-Z0-9]", "")
end

-- Should this client act on an incoming message? Bettor->bookie messages are for the book's
-- owner only; bookie->bettor messages are for everyone else. `isOwner` = I run this book.
function Protocol.ShouldDeliver(msgType, isOwner)
    local spec = Protocol.Spec[msgType]
    if not spec then return false end
    if spec.dir == "bettor" then return isOwner and true or false end
    if spec.dir == "bookie" then return not isOwner end
    return true
end

-- Strip the realm from "Name-Realm" when it is the player's own realm, so the same player is
-- always the same string. `myRealm` is the normalized realm name (no spaces).
function Protocol.NormalizeName(name, myRealm)
    if type(name) ~= "string" then return name end
    local base, realm = name:match("^([^%-]+)%-(.+)$")
    if base and myRealm and realm:gsub("%s", ""):lower() == myRealm:gsub("%s", ""):lower() then
        return base
    end
    return name
end

-- Canonical join code: uppercase letters and digits, written NNN-NNNN when it has 7 characters,
-- so "nflk7q2", "NFL K7Q2" and "NFL-K7Q2" are the same book everywhere.
function Protocol.CanonicalCode(code)
    local s = ((code or ""):upper():gsub("[^A-Z0-9]", ""))
    if #s == 7 then return s:sub(1, 3) .. "-" .. s:sub(4) end
    return s
end

return Protocol
