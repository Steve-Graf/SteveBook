-- House.lua: "play against the house" (SPEC §11a). Pure logic: no WoW API calls.
--
-- A friend plays roulette or blackjack alone against a bookie's bank, whether or not the bookie is online.
-- The game runs on the PLAYER's client: a one-seat casino table (`t.house` = the bookie's name) that the
-- player's own character both hosts and sits at, with nothing sent on the wire. The player's client counts
-- its results and reports them to the bookie whenever the two are online together.
--
-- Player side (SteveBookDB.houses[bookie]):
--   { host, on, minBet, maxBet, seen,                    -- what the bookie last announced (limits are cached for offline play)
--     games = { roulette = { rounds, wagered, net }, blackjack = {...} },   -- my results, since the start
--     acked = rounds the bookie has confirmed, paid = copper the bookie says it has settled }
-- Bookie side (SteveBookDB.houseBook):
--   { enabled, minBet, maxBet, players = { [name] = { rounds, wagered, net, games, paid, at, since } } }
-- `net` is from the PLAYER's point of view (positive = the player is up). "Owed" is net - paid: positive means
-- the bookie owes the player, negative means the player owes the bookie. All money is integer copper.
local ADDON, ns = ...
ns = ns or {}

local House = {}
ns.House = House

local Casino = ns.Casino

House.GAMES = { "roulette", "blackjack", "dice" }
House.FLOAT_BETS = 5              -- before each round a player's chips are topped up to this many maximum bets
House.MAX_WIN_RATIO = 49          -- no honest total wins more than 49 times what was wagered (dice at its lowest target pays 49x)
House.STEP = 100                  -- stakes are whole silver (Odds.STAKE_STEP)

local function base(name) return type(name) == "string" and name:match("^([^%-%s]+)") or name end
House.BaseName = base

local function isInt(n) return type(n) == "number" and n == math.floor(n) and n == n and n > -1e12 and n < 1e12 end

local function newGame() return { rounds = 0, wagered = 0, net = 0 } end

------------------------------------------------------------------------------------------
-- The bookie's side
------------------------------------------------------------------------------------------

function House.EnsureBook(db)
    local b = db.houseBook
    if not b then
        b = { enabled = false, minBet = Casino.DEFAULT_MIN_BET, maxBet = Casino.DEFAULT_MAX_BET, players = {} }
        db.houseBook = b
    end
    b.players = b.players or {}
    return b
end

function House.SetLimits(book, minBet, maxBet)
    local ok, msg = Casino.CheckLimits(minBet, maxBet)
    if not ok then return nil, msg end
    book.minBet, book.maxBet = minBet, maxBet
    return true
end

-- A report is believable if its numbers are whole, not negative where they cannot be, and the total is not
-- better than the best possible luck (a 2% dice roll pays 49x) or worse than losing everything staked.
function House.Plausible(p)
    if type(p) ~= "table" then return false, "no report" end
    if not (isInt(p.rounds) and isInt(p.wagered) and isInt(p.net)) then return false, "the numbers are not whole" end
    if p.rounds < 0 or p.wagered < 0 then return false, "negative counts" end
    if p.rounds == 0 and (p.wagered ~= 0 or p.net ~= 0) then return false, "money without rounds" end
    if p.net < -p.wagered then return false, "lost more than was wagered" end
    if p.net > p.wagered * House.MAX_WIN_RATIO then return false, "won more than any luck allows" end
    return true
end

local function cleanGames(g)
    local out = {}
    if type(g) ~= "table" then return out end
    for _, game in ipairs(House.GAMES) do
        local e = g[game]
        if type(e) == "table" and isInt(e.rounds) and isInt(e.wagered) and isInt(e.net) then
            out[game] = { rounds = e.rounds, wagered = e.wagered, net = e.net }
        end
    end
    return out
end

-- A report (cumulative totals) from a player. Newer totals replace older ones, so a resent or reordered
-- report does nothing. Returns "new" | "updated" | "stale" | "rejected", the entry (nil when rejected), why.
function House.Apply(book, name, p, now)
    local ok, why = House.Plausible(p)
    if not ok then return "rejected", nil, why end
    name = base(name)
    local e = book.players[name]
    if e and p.rounds <= e.rounds then return "stale", e end
    local status = e and "updated" or "new"
    if not e then e = { paid = 0, since = now }; book.players[name] = e end
    e.rounds, e.wagered, e.net, e.at = p.rounds, p.wagered, p.net, now
    e.games = cleanGames(p.games)
    return status, e
end

function House.Owed(e) return (e.net or 0) - (e.paid or 0) end

-- The bookie has settled up with a player in full (paid them, or collected from them, in game).
-- Returns the amount settled (what was owed, from the player's side), or nil, reason.
function House.Settle(book, name)
    local e = book.players[base(name)]
    if not e then return nil, "no_player" end
    local owed = House.Owed(e)
    e.paid = e.net
    return owed
end

function House.Forget(book, name)
    name = base(name)
    if not book.players[name] then return nil, "no_player" end
    book.players[name] = nil
    return true
end

-- Players, the biggest balance first: { name, rounds, wagered, net, paid, owed, at, games }.
function House.Rows(book)
    local rows = {}
    for name, e in pairs(book.players or {}) do
        rows[#rows + 1] = { name = name, rounds = e.rounds, wagered = e.wagered, net = e.net, paid = e.paid or 0,
                            owed = House.Owed(e), at = e.at, games = e.games or {} }
    end
    table.sort(rows, function(a, b)
        if math.abs(a.owed) ~= math.abs(b.owed) then return math.abs(a.owed) > math.abs(b.owed) end
        return a.name < b.name
    end)
    return rows
end

-- What the whole house stands at: players, rounds, wagered, net (the players' result), owed (net not yet settled).
function House.Totals(book)
    local t = { players = 0, rounds = 0, wagered = 0, net = 0, owed = 0 }
    for _, e in pairs(book.players or {}) do
        t.players, t.rounds, t.wagered = t.players + 1, t.rounds + e.rounds, t.wagered + e.wagered
        t.net, t.owed = t.net + e.net, t.owed + House.Owed(e)
    end
    return t
end

------------------------------------------------------------------------------------------
-- The player's side
------------------------------------------------------------------------------------------

function House.EnsureCache(db)
    db.houses = db.houses or {}
    return db.houses
end

function House.Record(db, host)
    host = base(host)
    local houses = House.EnsureCache(db)
    local rec = houses[host]
    if not rec then rec = { host = host, games = {}, acked = 0, paid = 0 }; houses[host] = rec end
    rec.games = rec.games or {}
    return rec
end

-- The bookie's announcement (LOBBY_HOUSE). Remembers the limits for offline play. Returns the record and
-- whether the limits changed, or nil, reason.
function House.Heard(db, host, p, now)
    local ok, msg = Casino.CheckLimits(p.minBet, p.maxBet)
    if not ok then return nil, msg end
    local rec = House.Record(db, host)
    local changed = rec.minBet ~= p.minBet or rec.maxBet ~= p.maxBet
    rec.on, rec.minBet, rec.maxBet, rec.seen = p.on == true, p.minBet, p.maxBet, now
    return rec, changed
end

-- Houses I know of, most recently heard first: records that have announced limits at least once.
function House.Known(db)
    local list = {}
    for _, rec in pairs(db.houses or {}) do
        if rec.minBet then list[#list + 1] = rec end
    end
    table.sort(list, function(a, b)
        if (a.seen or 0) ~= (b.seen or 0) then return (a.seen or 0) > (b.seen or 0) end
        return a.host < b.host
    end)
    return list
end

-- My totals against one house: rounds, wagered, net.
function House.PlayerTotals(rec)
    local r, w, n = 0, 0, 0
    for _, g in pairs(rec.games or {}) do r, w, n = r + g.rounds, w + g.wagered, n + g.net end
    return r, w, n
end

-- What the house owes me (positive) or I owe the house (negative), as far as I know.
function House.Balance(rec)
    local _, _, net = House.PlayerTotals(rec)
    return net - (rec.paid or 0)
end

-- How much of one result entry was staked: roulette lists bets, blackjack lists hands.
function House.Staked(entry)
    local n = 0
    for _, b in ipairs(entry.bets or {}) do n = n + (b.amount or 0) end
    for _, h in ipairs(entry.hands or {}) do n = n + (h.bet or 0) end
    return n
end

-- One finished round: `entry` is my line in the table's result, `net` my total result at this table
-- (from the chips, so it can never drift from what the table shows).
function House.RecordRound(rec, game, entry, net)
    local g = rec.games[game]
    if not g then g = newGame(); rec.games[game] = g end
    g.rounds = g.rounds + 1
    g.wagered = g.wagered + House.Staked(entry)
    g.net = net
    return g
end

function House.Report(rec)
    local rounds, wagered, net = House.PlayerTotals(rec)
    local games = {}
    for game, g in pairs(rec.games or {}) do games[game] = { rounds = g.rounds, wagered = g.wagered, net = g.net } end
    return { rounds = rounds, wagered = wagered, net = net, games = games }
end

function House.Unsynced(rec)
    local rounds = House.PlayerTotals(rec)
    return rounds > (rec.acked or 0)
end

-- HOUSE_ACK from the bookie: they hold my results up to `rounds` and have settled `paid`.
function House.ApplyAck(rec, p)
    rec.acked = math.max(rec.acked or 0, p.rounds or 0)
    if type(p.paid) == "number" then rec.paid = p.paid end
end

------------------------------------------------------------------------------------------
-- The one-seat table
------------------------------------------------------------------------------------------

function House.FindTable(db, host, game)
    host = base(host)
    for _, t in pairs(db.casino and db.casino.tables or {}) do
        if t.house == host and t.game == game and t.status ~= "closed" then return t end
    end
end

-- The player's table against `host` for `game`, made if it is not there yet. `hostName` is the player's own
-- character (they host it). Limits follow the bookie's announcement. Blackjack and dice go by themselves the
-- moment a bet is in; roulette waits for the player's own Spin.
function House.NewTable(db, host, game, hostName, now, rand)
    host = base(host)
    local rec = House.Record(db, host)
    if not rec.minBet then return nil, "No limits known for that house yet." end
    local t = House.FindTable(db, host, game)
    if t then
        t.minBet, t.maxBet = rec.minBet, rec.maxBet
        return t
    end
    local label = host .. "'s house"
    local t, err = Casino.Create(db, { game = game, name = label, zero = game == "roulette" and "single" or nil,
                                       minBet = rec.minBet, maxBet = rec.maxBet, house = true }, hostName, now, rand)
    if not t then return nil, err end
    t.house = host
    t.maxSeats = 1
    if game == "blackjack" or game == "dice" then t.auto = true; t.autoSeconds = 0 end
    return t
end

-- Top the player's chips up to House.FLOAT_BETS maximum bets when the table is waiting for bets and they have
-- nothing on it. The chips are the house's credit (`bought` grows with them), so the result stays chips - bought.
-- Returns how many chips were added (0 if none).
function House.Refill(t, name)
    local m = t.members[name]
    if not (m and m.status == "seated" and t.status == "betting" and #m.bets == 0) then return 0 end
    local want = House.FLOAT_BETS * t.maxBet
    local delta = math.floor((want - m.balance) / House.STEP) * House.STEP
    if delta <= 0 then return 0 end
    Casino.Adjust(t, name, delta)
    return delta
end

-- My result at a table, in copper (chips - credit given).
function House.TableNet(t)
    local net = 0
    for _, row in ipairs(Casino.Ledger(t)) do net = net + row.result end
    return net
end

return House
