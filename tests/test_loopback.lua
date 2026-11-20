-- Loopback test: ONE character is bookie and bettor of its own book (/book loopback), using the
-- real Comm (AceComm/AceSerializer/ChatThrottleLib on the stub) and every addon file.
-- Run from repo root: luajit tests/test_loopback.lua   (or lua5.1 / lua)
local stub = assert(loadfile("tests/wowstub.lua"))()
local out_ = stub.realPrint
local fails = 0
local function check(cond, label) if not cond then fails = fails + 1; out_("FAIL: " .. label) end end

local ADDON, DIR = "SteveBook", "SteveBook/"
local ns = {}
local function readFile(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
local loadFile
local function loadFileXml(path)
    local dir = path:match("^(.*)/[^/]*$") or "."
    for file in readFile(path):gmatch('<[SI][a-z]+%s+file="([^"]+)"') do loadFile(dir .. "/" .. file:gsub("\\", "/")) end
end
function loadFile(path)
    path = path:gsub("\\", "/")
    if path:match("%.xml$") then return loadFileXml(path) end
    local chunk = assert(loadfile(path))
    local ok, e = pcall(chunk, ADDON, ns)
    check(ok, "load " .. path .. (ok and "" or (": " .. tostring(e))))
end
for line in readFile(DIR .. "SteveBook.toc"):gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then loadFile(DIR .. line) end
end

stub.fire("ADDON_LOADED", ADDON)
local db = SteveBookDB
local slash = SlashCmdList.STEVEBOOK

-- Let async work run: channel/ChatThrottleLib timers, loopback deliveries, tickers.
local function settle()
    for _ = 1, 12 do stub.advance(1); stub.runAfters() end
end

slash("new Loop Book")
local book = ns.Model.ListBooks(db)[1]
local code = book.code
settle()

local st = db.cache
local function requestJoin()
    ns.Cache.RequestJoin(st, code)
    ns.Comm.Send("JOIN_REQ", {}, code)
    settle()
end

-- Loopback off: our own request goes nowhere (a client never hears itself).
requestJoin()
check(book.members.Loopback == nil, "loopback off: no member appears")

-- Loopback on.
slash("loopback")
check(db.loopback == true and ns.Comm.LoopbackActive(code), "/book loopback turns it on")
requestJoin()
check(book.members.Loopback and book.members.Loopback.status == "pending", "loopback: the request reaches the bookie side as 'Loopback'")
check(ns.Cache.Book(st, code).status == "requested", "bettor side still waiting for approval")

-- Approve: the JOIN_OK comes back to the bettor side, which then syncs.
check(ns.BookieNet.Approve(book, "Loopback"), "approve Loopback")
settle()
local cb = ns.Cache.Book(st, code)
check(cb.status == "active", "bettor side is approved (status " .. tostring(cb.status) .. ")")
check(cb.owner == stub.player, "bettor pinned the bookie (owner " .. tostring(cb.owner) .. ")")

-- A market posted by the bookie reaches the bettor's cache.
local m = assert(ns.Bookie.AddMarket(book, { sport = "NFL", event = "PHI @ DAL", type = "moneyline",
    closesAt = stub.time + 3600, selections = { { label = "PHI", odds = -150 }, { label = "DAL", odds = 130 } } }, stub.time))
ns.BookieNet.AddMarket(book, { sport = "NFL", event = "HOU @ IND", type = "moneyline",
    closesAt = stub.time + 3600, selections = { { label = "HOU", odds = -120 }, { label = "IND", odds = 100 } } })
settle()
local n = 0
for _ in pairs(cb.markets) do n = n + 1 end
check(n >= 1, "bettor cache received the market broadcast (" .. n .. ")")

-- Place a bet through the same calls the bettor window makes.
local mid = next(cb.markets)
local ref = "r-1"
ns.Cache.NewPending(st, code, { ref = ref, marketId = mid, selectionId = 1, stake = 1000, odds = cb.markets[mid].selections[1].odds }, stub.time)
check(ns.Comm.Send("BET_PLACE", { ref = ref, marketId = mid, selectionId = 1, stake = 1000,
    odds = cb.markets[mid].selections[1].odds }, code) == true, "send BET_PLACE")
settle()
local bets = 0
for _, b in pairs(book.bets) do if b.bettor == "Loopback" and b.status == "accepted" then bets = b.id and bets + 1 or bets end end
check(bets == 1, "bookie accepted the bet from Loopback (" .. bets .. ")")
check(cb.pending[ref] == nil, "bettor's pending bet was resolved by the ACK")
local acked = 0
for _ in pairs(cb.bets) do acked = acked + 1 end
check(acked == 1, "bettor cache holds the accepted bet (" .. acked .. ")")

-- A reply addressed to a real player is not handed to our own bettor side.
local before = cb.balance
ns.Comm.Send("BALANCE", { rev = 99, balance = 123456 }, code, "SomeoneElse")
settle()
check(cb.balance == before, "message addressed to someone else is not delivered locally")

-- Not the owner of the book: loopback never applies.
db.books = {}
check(not ns.Comm.LoopbackActive(code), "loopback needs us to own the book")

check(#stub.errors == 0, "no handler errors: " .. table.concat(stub.errors, "; "))
if fails == 0 then out_("test_loopback: all passed") else out_(fails .. " FAILED"); os.exit(1) end
