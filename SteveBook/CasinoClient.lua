-- CasinoClient.lua: the PLAYER side's saved view of casino tables (SPEC §11). Pure logic: no WoW
-- API calls. The host's client is the authority; this only remembers what the host told us.
--   store = SteveBookDB.casinoCache = { tables = { [code] = Table } }
--   Table = { code, status = "requested" | "seated" | "denied" | "left" | "removed" | "closed",
--             owner, game, name, rev, state (the host's last TBL_STATE), balance, bets, pending,
--             lastResult = { round, number, results }, requestedAt }
local ADDON, ns = ...
ns = ns or {}

local Client = {}
ns.CasinoClient = Client

local PENDING_EXPIRE = 20          -- seconds before an unanswered bet is given up on

local function normalize(code) return ns.Protocol.CanonicalCode(code) end

function Client.NewStore() return { tables = {} } end

function Client.Ensure(db)
    db.casinoCache = db.casinoCache or Client.NewStore()
    db.casinoCache.tables = db.casinoCache.tables or {}
    return db.casinoCache
end

function Client.Table(store, code, create)
    code = normalize(code)
    local t = store.tables[code]
    if not t and create then
        t = { code = code, status = "requested", rev = 0, balance = 0, bets = {}, pending = {} }
        store.tables[code] = t
    end
    return t
end

-- Tables I have a relationship with, by code.
function Client.List(store)
    local list = {}
    for _, t in pairs(store.tables) do list[#list + 1] = t end
    table.sort(list, function(a, b) return a.code < b.code end)
    return list
end

function Client.Forget(store, code) store.tables[normalize(code)] = nil end

-- I typed a code. Starts (or restarts) a request.
function Client.RequestJoin(store, code, now)
    local t = Client.Table(store, code, true)
    if t.status ~= "seated" then t.status = "requested" end
    t.requestedAt = now
    return t
end

local function copyList(list)
    local out = {}
    for i, v in ipairs(list or {}) do
        if type(v) == "table" then
            local c = {}
            for k, x in pairs(v) do
                if type(x) == "table" then
                    local l = {}
                    for j, y in ipairs(x) do l[j] = y end
                    c[k] = l
                else
                    c[k] = x
                end
            end
            out[i] = c
        else
            out[i] = v
        end
    end
    return out
end

-- TBL_JOIN_OK from `sender` (already checked to be the host named in the payload).
function Client.ApplyJoinOk(store, code, sender, p)
    local t = Client.Table(store, code, false)
    if not t then return nil end
    t.status = "seated"
    t.owner = sender
    t.game = p.game
    t.name = p.name
    t.rev = math.max(t.rev or 0, p.rev or 0)
    return t
end

local DENY_STATUS = { left = "left", closed = "closed", removed = "removed" }

-- TBL_JOIN_DENY: the status follows the reason.
function Client.ApplyJoinDeny(store, code, reason)
    local t = Client.Table(store, code, false)
    if not t then return nil end
    t.status = DENY_STATUS[reason] or "denied"
    t.pending = {}
    t.bets = {}
    return t
end

-- TBL_STATE (public). Older revisions than the one we hold are ignored.
function Client.ApplyState(store, code, p)
    local t = Client.Table(store, code, false)
    if not t or p.rev < (t.rev or 0) then return nil end
    t.rev = p.rev
    t.game = p.game
    t.name = p.name
    t.state = {
        rev = p.rev, game = p.game, name = p.name, status = p.status, round = p.round,
        minBet = p.minBet, maxBet = p.maxBet, zero = p.zero,
        seats = copyList(p.seats), history = copyList(p.history),
        bj = p.bj,                       -- blackjack's public state (fresh from the wire, so not copied)
    }
    if p.status == "closed" and t.status == "seated" then t.status = "closed" end
    return t
end

-- TBL_PLAYER: my chips and the bets I have on the table this round.
function Client.ApplyPlayer(store, code, p)
    local t = Client.Table(store, code, false)
    if not t then return nil end
    t.rev = math.max(t.rev or 0, p.rev or 0)
    t.balance = p.balance
    t.bets = copyList(p.bets)
    return t         -- bets still waiting for an answer stay pending: this snapshot may predate them
end

-- I sent TBL_BET; remember it until the host answers.
function Client.NewPending(store, code, ref, bet, now)
    local t = Client.Table(store, code, true)
    t.pending[ref] = { bet = bet, placedAt = now }
end

-- TBL_BET_OK
function Client.ApplyBetOk(store, code, ref, betId, balance)
    local t = Client.Table(store, code, false)
    if not t then return nil end
    local pend = t.pending[ref]
    t.pending[ref] = nil
    if pend then
        local known = false
        for _, b in ipairs(t.bets) do if b.id == betId then known = true end end   -- a TBL_PLAYER already listed it
        if not known then
            local b = copyList({ pend.bet })[1]
            b.id = betId
            t.bets[#t.bets + 1] = b
        end
    end
    t.balance = balance
    return t
end

-- TBL_BET_REJECT. Returns the bet that was rejected (or nil if we were not waiting for it).
function Client.ApplyBetReject(store, code, ref, balance)
    local t = Client.Table(store, code, false)
    if not t then return nil end
    local pend = t.pending[ref]
    t.pending[ref] = nil
    if balance then t.balance = balance end
    return pend and pend.bet
end

-- Give up on bets the host never answered. Returns how many were dropped.
function Client.ExpirePending(store, code, now)
    local t = Client.Table(store, code, false)
    local n = 0
    if not t then return n end
    for ref, p in pairs(t.pending) do
        if now - p.placedAt >= PENDING_EXPIRE then t.pending[ref] = nil; n = n + 1 end
    end
    return n
end

-- TBL_RESULT. Returns the table.
function Client.ApplyResult(store, code, p)
    local t = Client.Table(store, code, false)
    if not t then return nil end
    t.rev = math.max(t.rev or 0, p.rev or 0)
    t.lastResult = { round = p.round, number = p.number, dealer = p.dealer, results = copyList(p.results) }
    t.bets = {}
    t.pending = {}
    for _, r in ipairs(p.results) do
        if r.name == t.me then t.balance = r.balance end
    end
    return t
end

-- My line in the last result (match on the base name), or nil if I did not bet.
function Client.MyResult(t, myName)
    if not (t and t.lastResult and myName) then return nil end
    for _, r in ipairs(t.lastResult.results) do
        if r.name == myName then return r end
    end
end

-- Chips I have on the table (confirmed + waiting for an answer).
function Client.Staked(t)
    local n = 0
    for _, b in ipairs(t.bets) do n = n + b.amount end
    for _, p in pairs(t.pending) do n = n + p.bet.amount end
    return n
end

-- Blackjack: is it my turn to decide? Returns my hand number (1 or 2), or nil.
function Client.MyTurn(t, myName)
    local bj = t and t.state and t.state.bj
    if not (t and t.status == "seated" and bj and t.state.status == "playing" and bj.turn == myName) then return nil end
    return bj.turnHand or 1
end

-- Blackjack: my hands as the table shows them, or nil.
function Client.MyHands(t, myName)
    local bj = t and t.state and t.state.bj
    if not bj then return nil end
    for _, h in ipairs(bj.hands or {}) do if h.name == myName then return h.hands end end
end

-- Can I place a bet right now?
function Client.CanBet(t)
    return t ~= nil and t.status == "seated" and t.state ~= nil and t.state.status == "betting"
end

return Client
