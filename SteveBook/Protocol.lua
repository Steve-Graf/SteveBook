-- Protocol.lua: message names, payload shapes, envelope, validation (SPEC §5).
-- Pure Lua: no WoW API calls. Transport (channel, AceComm, serialization) lives in Comm.lua.
local ADDON, ns = ...
ns = ns or {}

local Protocol = {}
ns.Protocol = Protocol

Protocol.VERSION = 1

-- dir: who may send it. "bettor" = bettor -> bookie, "bookie" = bookie -> bettor (or all),
-- "any" = either side.
-- fields: name = "type" where type is a Lua type name; a trailing "?" marks the field optional.
-- Shapes of nested tables (Market, Bet) are the SPEC §4 records.
Protocol.Spec = {
    JOIN_REQ   = { dir = "bettor", fields = {} },
    JOIN_OK    = { dir = "bookie", fields = { bookName = "string", ownerName = "string", rev = "number" } },
    JOIN_DENY  = { dir = "bookie", fields = { reason = "string?" } },

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
        marketId = "number",    -- SPEC §4 ids are numbers
        selectionId = "number",
        stake = "number",       -- copper
        odds = "number",        -- American odds the bettor saw
    } },
    BET_ACK    = { dir = "bookie", fields = { ref = "string", bet = "table", balance = "number?" } },
    BET_REJECT = { dir = "bookie", fields = {
        ref = "string",
        reason = "string",      -- one of Protocol.REJECT_REASONS
        currentOdds = "number?",    -- set when reason == "odds_changed"
        available = "number?",      -- copper still available, set when reason == "credit_limit"
    } },

    BALANCE    = { dir = "bookie", fields = { rev = "number", balance = "number", note = "string?" } },

    PING       = { dir = "any", fields = {} },
    PONG       = { dir = "any", fields = { rev = "number?" } },
}

Protocol.REJECT_REASONS = {
    "not_member", "no_market", "market_closed", "bad_selection",
    "bad_stake", "odds_changed", "credit_limit", "bad_request", "book_error",
}

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

return Protocol
