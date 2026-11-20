-- Run from repo root: lua5.1 tests/test_protocol.lua
local ns = {}
local P = assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)

local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; print("FAIL: " .. label) end
end

local env = P.Wrap("BET_PLACE", "NFL-K7Q2", { ref = "r1", marketId = 1, selectionId = 2, stake = 50000, odds = -110 })
check(env and env.v == P.VERSION and env.t == "BET_PLACE" and env.c == "NFL-K7Q2", "wrap builds envelope")
local t, code, payload = P.Unwrap(env, "bettor")
check(t == "BET_PLACE" and code == "NFL-K7Q2" and payload.stake == 50000, "unwrap round trip")

check(select(2, P.Unwrap(env, "bookie")) == "wrong direction", "direction enforced")
check(P.Unwrap(env) == "BET_PLACE", "direction optional")
check(select(2, P.Wrap("BET_PLACE", "X", { ref = "r" })):find("^missing field"), "missing field rejected")
check(select(2, P.Wrap("BET_PLACE", "X", { ref = "r", marketId = 1, selectionId = 1, stake = "5", odds = 100 })) ==
      "field stake must be a number", "wrong type rejected")
check(select(2, P.Wrap("NOPE", "X", {})) == "unknown message type", "unknown type")
check(select(2, P.Wrap("PING", "", {})) == "book code required", "book code required")
check(P.Wrap("PING", "X") ~= nil, "empty payload ok when no fields")
check(P.Wrap("PONG", "X", { rev = 3 }) ~= nil, "optional field accepted")
check(P.Wrap("BET_REJECT", "X", { ref = "r", reason = "credit_limit", available = 100 }) ~= nil, "valid reject reason")
check(select(2, P.Wrap("BET_REJECT", "X", { ref = "r", reason = "because" })) == "unknown reject reason", "bad reject reason")
check(select(2, P.Unwrap({ v = 99, t = "PING", c = "X", p = {} })) == "protocol version mismatch", "version mismatch")
check(select(2, P.Unwrap("junk")) == "not a table", "non-table")
check(select(2, P.Unwrap({ v = 1, t = "PING", p = {} })) == "missing book code", "missing code")

check(P.ChannelName("NFL-K7Q2") == "SBNFLK7Q2", "channel name")
check(P.ChannelName("nfl-k7q2") == "SBNFLK7Q2", "channel name uppercases")
check(P.ShouldDeliver("BET_PLACE", true) and not P.ShouldDeliver("BET_PLACE", false), "bettor msgs go to the owner")
check(P.ShouldDeliver("SYNC", false) and not P.ShouldDeliver("SYNC", true), "bookie msgs go to non-owners")
check(P.ShouldDeliver("PING", true) and P.ShouldDeliver("PING", false), "any msgs go to everyone")
check(not P.ShouldDeliver("NOPE", true), "unknown type not delivered")
check(P.NormalizeName("Bob-Area52", "Area52") == "Bob", "same realm stripped")
check(P.NormalizeName("Bob-Area 52", "Area52") == "Bob", "realm spaces ignored")
check(P.NormalizeName("Bob-Tichondrius", "Area52") == "Bob-Tichondrius", "other realm kept")
check(P.NormalizeName("Bob", "Area52") == "Bob", "plain name unchanged")

check(P.CanonicalCode("NFLK7Q2") == "NFL-K7Q2", "code without hyphen")
check(P.CanonicalCode(" nfl k7q2 ") == "NFL-K7Q2", "code with spaces and case")
check(P.CanonicalCode("NFL-K7Q2") == "NFL-K7Q2", "canonical stays")
check(P.CanonicalCode("") == "" and P.CanonicalCode(nil) == "", "empty code")
check(P.CanonicalCode("AB-1") == "AB1", "short codes lose the hyphen")

-- parlay BET_PLACE
do
    local function leg(m, s, o) return { marketId = m, selectionId = s, odds = o } end
    local ok = P.Wrap("BET_PLACE", "NFL-K7Q2", { ref = "p1", stake = 2000, legs = { leg(1, 1, -110), leg(2, 2, 130) } })
    check(ok, "a two-leg parlay validates")
    check(not P.Wrap("BET_PLACE", "X", { ref = "p", stake = 2000, legs = { leg(1, 1, -110) } }), "one leg is not a parlay")
    local many = {}
    for i = 1, 9 do many[i] = leg(i, 1, -110) end
    check(not P.Wrap("BET_PLACE", "X", { ref = "p", stake = 2000, legs = many }), "too many legs rejected")
    check(not P.Wrap("BET_PLACE", "X", { ref = "p", stake = 2000, legs = { leg(1, 1, -110), { marketId = 2 } } }), "a malformed leg is rejected")
    check(not P.Wrap("BET_PLACE", "X", { ref = "p", stake = 2000, marketId = 1, selectionId = 1, odds = -110, legs = { leg(1, 1, -110), leg(2, 1, 100) } }),
        "single fields and legs together are rejected")
    check(not P.Wrap("BET_PLACE", "X", { ref = "p", stake = 2000 }), "neither single fields nor legs is rejected")
    check(not P.Wrap("BET_PLACE", "X", { ref = "p", stake = 2000, marketId = 1 }), "a half-filled single bet is rejected")
    check(P.Wrap("BET_REJECT", "X", { ref = "p", reason = "parlay_conflict", legIndex = 2 }), "parlay_conflict reject with legIndex")
    check(P.Wrap("BET_REJECT", "X", { ref = "p", reason = "odds_changed", currentOdds = -120, legIndex = 1 }), "odds_changed reject names the leg")
end

-- lines (spread/total) travel with the bet so a moved line is caught
do
    check(P.Wrap("BET_PLACE", "X", { ref = "l1", stake = 2000, marketId = 1, selectionId = 1, odds = -110, line = -3.5 }), "single bet with a line")
    check(not P.Wrap("BET_PLACE", "X", { ref = "l1", stake = 2000, marketId = 1, selectionId = 1, odds = -110, line = "-3.5" }), "line must be a number")
    check(P.Wrap("BET_PLACE", "X", { ref = "l2", stake = 2000, legs = { { marketId = 1, selectionId = 1, odds = -110, line = 5.5 }, { marketId = 2, selectionId = 2, odds = 130 } } }), "parlay legs may carry a line")
    check(not P.Wrap("BET_PLACE", "X", { ref = "l2", stake = 2000, legs = { { marketId = 1, selectionId = 1, odds = -110, line = "x" }, { marketId = 2, selectionId = 2, odds = 130 } } }), "a non-numeric leg line is rejected")
    check(not P.Wrap("BET_PLACE", "X", { ref = "l2", stake = 2000, line = 1.5, legs = { { marketId = 1, selectionId = 1, odds = -110 }, { marketId = 2, selectionId = 2, odds = 130 } } }), "a parlay's line is on its legs")
    check(P.Wrap("BET_REJECT", "X", { ref = "l1", reason = "odds_changed", currentOdds = -110, currentLine = -4.5 }), "odds_changed can carry currentLine")
end

-- group bets
do
    check(P.Wrap("BETS_REQ", "X", {}), "BETS_REQ is an empty request")
    check(P.ShouldDeliver("BETS_REQ", true) and not P.ShouldDeliver("BETS_REQ", false), "BETS_REQ goes to the owner")
    check(P.Wrap("BETS", "X", { rev = 3, bets = { { id = 1, who = "Bob", text = "LAL +5.5 -110, LAL @ BOS", stake = 2000, status = "accepted", at = 5 } } }), "BETS with an entry")
    check(P.Wrap("BETS", "X", { rev = 3, bets = {} }), "BETS may be empty")
    check(not P.Wrap("BETS", "X", { rev = 3, bets = { { who = "Bob" } } }), "a malformed BETS entry is rejected")
    check(P.ShouldDeliver("BETS", false) and not P.ShouldDeliver("BETS", true), "BETS goes to bettors")
end

-- casino tables
do
    local W = function(t, p) return P.Wrap(t, "RLT-K7Q2", p) end
    check(W("TBL_JOIN", {}), "TBL_JOIN"); check(W("TBL_LEAVE", {}), "TBL_LEAVE")
    check(W("TBL_SYNC_REQ", { rev = 0 }), "TBL_SYNC_REQ")
    check(W("TBL_BET", { ref = "r1", round = 3, bet = { kind = "red", amount = 100 } }), "TBL_BET")
    check(not W("TBL_BET", { ref = "r1", round = 3, bet = { kind = "red" } }), "TBL_BET needs an amount")
    check(not W("TBL_BET", { ref = "r1", round = 3 }), "TBL_BET needs a bet")
    check(W("TBL_BET_CLEAR", { round = 3 }), "TBL_BET_CLEAR")
    check(W("TBL_JOIN_OK", { game = "roulette", name = "Friday", ownerName = "Steve", rev = 1 }), "TBL_JOIN_OK")
    check(W("TBL_JOIN_DENY", { ownerName = "Steve", reason = "full" }), "TBL_JOIN_DENY")
    check(W("TBL_STATE", { rev = 2, game = "roulette", name = "Friday", status = "betting", round = 1, minBet = 100, maxBet = 10000,
        zero = "single", seats = { { name = "Bob", balance = 5000 } }, history = { 17, 0 } }), "TBL_STATE")
    check(not W("TBL_STATE", { rev = 2, game = "roulette", name = "F", status = "betting", round = 1, minBet = 100, maxBet = 10000,
        seats = { { name = "Bob" } }, history = {} }), "a seat needs a balance")
    check(W("TBL_PLAYER", { rev = 2, balance = 5000, bets = { { id = 1, kind = "red", amount = 100 } } }), "TBL_PLAYER")
    check(W("TBL_BET_OK", { ref = "r1", betId = 1, balance = 4900 }), "TBL_BET_OK")
    for _, r in ipairs(P.TBL_REJECT_REASONS) do check(W("TBL_BET_REJECT", { ref = "r1", reason = r }), "reject reason " .. r) end
    check(not W("TBL_BET_REJECT", { ref = "r1", reason = "because" }), "unknown table reject reason")
    check(W("TBL_BET_REJECT", { ref = "r1", reason = "no_balance", balance = 50 }), "reject carries balance")
    check(W("TBL_RESULT", { rev = 3, round = 1, number = 17, results = { { name = "Bob", net = 3500, balance = 8500, bets = {} } } }), "TBL_RESULT")
    check(not W("TBL_RESULT", { rev = 3, round = 1, number = 17, results = { { name = "Bob" } } }), "a result needs net and balance")
    check(P.ShouldDeliver("TBL_BET", true) and not P.ShouldDeliver("TBL_BET", false), "player messages go to the host")
    check(P.ShouldDeliver("TBL_RESULT", false) and not P.ShouldDeliver("TBL_RESULT", true), "host messages go to players")
    check(P.CanonicalCode("rltk7q2") == "RLT-K7Q2", "table codes canonicalise like book codes")
    check(P.ChannelName("RLT-K7Q2") == "SBRLTK7Q2", "table channel name")
end

if fails == 0 then print("protocol: all tests passed") else os.exit(1) end
