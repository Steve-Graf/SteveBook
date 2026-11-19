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

if fails == 0 then print("protocol: all tests passed") else os.exit(1) end
