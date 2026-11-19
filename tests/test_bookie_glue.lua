-- Run from repo root: lua5.1 tests/test_bookie_glue.lua
-- BookieNet.lua with the WoW client and Comm.lua stubbed out. Every message it sends must
-- pass Protocol.Wrap (field names/types match Protocol.Spec).
local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)
local Model = assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)
local Bookie = assert(loadfile("SteveBook/Bookie.lua"))("SteveBook", ns)
local Protocol = ns.Protocol

local realprint = print   -- print is stubbed below to capture chat; failures must still show
local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; realprint("FAIL: " .. label) end
end
local function eq(got, want, label)
    check(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

-- stubs -----------------------------------------------------------------------------------
local T = 1000
local chat, handlers, sent, joined, tickers = {}, {}, {}, {}, {}
GetServerTime = function() return T end
UnitName = function() return "Steve" end
print = function(s) chat[#chat + 1] = s end
C_Timer = { NewTicker = function(sec, fn) tickers[#tickers + 1] = { sec = sec, fn = fn } end }
ns.Comm = {
    Register = function(t, fn) handlers[t] = fn end,
    Send = function(t, payload, code, to) sent[#sent + 1] = { type = t, payload = payload, code = code, to = to } end,
    JoinBook = function(code) joined[#joined + 1] = code end,
    Me = function() return "Steve" end,
}
SteveBookDB = Model.NewDB()

local Net = assert(loadfile("SteveBook/BookieNet.lua"))("SteveBook", ns)

local function drain()
    local s = sent
    sent = {}
    for _, m in ipairs(s) do
        local env, err = Protocol.Wrap(m.type, m.code, m.payload)
        check(env ~= nil, m.type .. " to " .. tostring(m.to) .. " invalid: " .. tostring(err))
    end
    return s
end
local function chatText() local c = table.concat(chat, "\n"); chat = {}; return c end

-- setup -----------------------------------------------------------------------------------
for _, t in ipairs({ "JOIN_REQ", "SYNC_REQ", "BET_PLACE", "PING" }) do
    check(handlers[t], "handler registered for " .. t)
end
eq(#tickers, 1, "one sweep ticker")
eq(tickers[1] and tickers[1].sec, 5, "sweep every 5s (a started game must stop taking bets promptly)")

local book = assert(Net.CreateBook("NFL"))
eq(joined[1], book.code, "CreateBook joins the book's channel")
eq(book.ownerName, "Steve", "owner is the player")
check(select(2, Net.CreateBook("  ")) == "book name required", "CreateBook rejects empty name")

local refreshed = 0
Net.Subscribe(function(b) if b == book then refreshed = refreshed + 1 end end)

-- join flow -------------------------------------------------------------------------------
handlers.JOIN_REQ("Bob", {}, book.code)
eq(#drain(), 0, "JOIN_REQ from new player: no reply")
check(chatText():find("Bob wants to join NFL"), "chat announces the request")
check(refreshed == 1, "window notified")
handlers.JOIN_REQ("Bob", {}, book.code)
eq(chatText(), "", "repeat JOIN_REQ stays quiet")

local m = Net.Approve(book, "Bob")
check(m and m.status == "active", "approve")
local s = drain()
check(#s == 1 and s[1].type == "JOIN_OK" and s[1].to == "Bob" and s[1].code == book.code, "JOIN_OK whispered to Bob")
eq(s[1].payload.ownerName, "Steve", "JOIN_OK ownerName")

handlers.JOIN_REQ("Eve", {}, book.code); chatText(); drain()
check(Net.Deny(book, "Eve"), "deny")
s = drain()
check(#s == 1 and s[1].type == "JOIN_DENY" and s[1].to == "Eve" and s[1].payload.reason == "denied" and s[1].payload.ownerName == "Steve", "JOIN_DENY denied, names the owner")
check(select(2, Net.Deny(book, "Nobody")) == "not_pending", "deny unknown")
eq(#drain(), 0, "failed deny sends nothing")

-- markets ---------------------------------------------------------------------------------
local mk = assert(Net.AddMarket(book, { sport = "NFL", event = "PHI @ DAL", type = "moneyline",
    closesAt = T + 100, selections = { { label = "PHI", odds = -150 }, { label = "DAL", odds = 130 } } }))
s = drain()
check(#s == 1 and s[1].type == "MARKET" and s[1].to == nil and s[1].payload.market == mk, "AddMarket broadcasts MARKET")
check(select(2, Net.AddMarket(book, { type = "nope" })) == "bad_type", "AddMarket bad spec")
eq(#drain(), 0, "failed AddMarket sends nothing")
Net.EditMarket(book, mk.id, { odds = { [1] = -160 } })
s = drain()
check(#s == 1 and s[1].payload.market.selections[1].odds == -160, "EditMarket broadcasts new odds")

-- bets ------------------------------------------------------------------------------------
handlers.SYNC_REQ("Bob", { rev = 0 }, book.code)
s = drain()
check(#s == 1 and s[1].type == "SYNC" and s[1].to == "Bob" and #s[1].payload.markets == 1, "SYNC_REQ answered with SYNC")

handlers.BET_PLACE("Bob", { ref = "r1", marketId = mk.id, selectionId = 1, stake = 10000, odds = -160 }, book.code)
s = drain()
check(#s == 1 and s[1].type == "BET_ACK" and s[1].to == "Bob" and s[1].payload.bet.odds == -160, "BET_ACK")
check(chatText():find("Bob bet 1g on PHI %-160 %(PHI @ DAL%)"), "chat announces the bet")
handlers.BET_PLACE("Bob", { ref = "r2", marketId = mk.id, selectionId = 1, stake = 10000, odds = -150 }, book.code)
s = drain()
check(#s == 1 and s[1].type == "BET_REJECT" and s[1].payload.reason == "odds_changed" and s[1].payload.currentOdds == -160, "BET_REJECT odds_changed")
eq(chatText(), "", "rejected bets are not announced in chat")

handlers.PING("Bob", {}, book.code)
s = drain()
check(#s == 1 and s[1].type == "PONG" and s[1].to == "Bob", "PING -> PONG")

handlers.PING("Bob", {}, "ZZZ-0000"); handlers.BET_PLACE("Bob", { ref = "x", marketId = 1, selectionId = 1, stake = 1, odds = -150 }, "ZZZ-0000")
eq(#drain(), 0, "messages for a book we don't own are ignored")
handlers.PING("Steve", {}, book.code)
eq(#drain(), 0, "our own echoed message is ignored")

-- lock / sweep ----------------------------------------------------------------------------
Net.LockMarket(book, mk.id); s = drain()
check(#s == 1 and s[1].payload.market.status == "locked", "lock broadcasts")
Net.UnlockMarket(book, mk.id); s = drain()
check(#s == 1 and s[1].payload.market.status == "open", "unlock broadcasts")
T = T + 200
tickers[1].fn()
s = drain()
check(#s == 1 and s[1].type == "MARKET" and s[1].payload.market.status == "locked", "sweep locks and broadcasts a closed market")
tickers[1].fn()
eq(#drain(), 0, "second sweep has nothing to do")
-- the game has started: the bookie layer refuses edits, extensions and reopening, and says nothing
check(select(2, Net.EditMarket(book, mk.id, { odds = { [1] = -170 } })) == "market_closed", "a started game can't have its odds edited")
check(select(2, Net.EditMarket(book, mk.id, { closesAt = T + 9999 })) == "market_closed", "...or its close time extended")
check(select(2, Net.UnlockMarket(book, mk.id)) == "market_closed", "...or be reopened")
eq(mk.closesAt < T and mk.status, "locked", "it stays locked")
eq(#drain(), 0, "refused changes broadcast nothing")

-- settlement ------------------------------------------------------------------------------
Bookie.RequestJoin(book, "Alice", T); Bookie.Approve(book, "Alice", T)
local r = Net.Settle(book, mk.id, 1)
check(r and #r == 1, "settle returns results")
s = drain()
check(#s == 2, "settle sends MARKET + one SYNC (only Bob had a bet): got " .. #s)
check(s[1] and s[1].type == "MARKET" and s[1].to == nil and s[1].payload.market.status == "settled", "settle broadcasts MARKET")
check(s[2] and s[2].type == "SYNC" and s[2].to == "Bob" and s[2].payload.bets[1].status == "won", "settle SYNCs Bob with the result")
eq(s[2] and s[2].payload.balance, 6250, "Bob won floor(10000*100/160)")
check(select(2, Net.Settle(book, mk.id, 9)) == "bad_result", "settle bad result")
eq(#drain(), 0, "failed settle sends nothing")

Net.Settle(book, mk.id, 2); s = drain()
eq(s[2] and s[2].payload.balance, -10000, "correcting the result re-syncs the corrected balance")

local vb = Net.VoidBet(book, 1)
s = drain()
check(vb and #s == 1 and s[1].type == "SYNC" and s[1].to == "Bob" and s[1].payload.balance == 0, "VoidBet re-syncs the bettor")
Net.VoidMarket(book, mk.id); s = drain()
check(#s >= 1 and s[1].payload.market.status == "void", "VoidMarket broadcasts void")

-- ledger / members ------------------------------------------------------------------------
check(Net.SetCreditLimit(book, "Bob", 500000), "set credit limit")
s = drain()
check(#s == 1 and s[1].type == "SYNC" and s[1].to == "Bob" and s[1].payload.creditLimit == 500000, "credit limit pushed in SYNC")

local bal = Net.RecordPayment(book, "Alice", "in", 25000, "gold trade")
eq(bal, 25000, "payment returns balance")
s = drain()
check(#s == 1 and s[1].type == "BALANCE" and s[1].to == "Alice" and s[1].payload.balance == 25000, "BALANCE sent")
check(s[1] and s[1].payload.note == "Payment received: 2g 50s (gold trade)", "BALANCE note: " .. tostring(s[1] and s[1].payload.note))
Net.RecordPayment(book, "Alice", "out", 5000); s = drain()
check(s[1] and s[1].payload.note == "Book paid you: 50s", "outgoing payment note: " .. tostring(s[1] and s[1].payload.note))
check(select(2, Net.RecordPayment(book, "Alice", "in", 0)) == "bad_amount", "bad payment")
eq(#drain(), 0, "failed payment sends nothing")

check(Net.Remove(book, "Bob"), "remove")
s = drain()
check(#s == 1 and s[1].type == "JOIN_DENY" and s[1].to == "Bob" and s[1].payload.reason == "removed" and s[1].payload.ownerName == "Steve", "removal notifies Bob, names the owner")

-- a book owned by another character is never answered, swept or listed (PING is delivered to
-- every client, so BookieNet has to check ownership itself) -----------------------------------------
local theirs = assert(Model.CreateBook(SteveBookDB, "Theirs", "Stevealt", T))
Bookie.RequestJoin(theirs, "Bob", T); Bookie.Approve(theirs, "Bob", T)
local tm = assert(Bookie.AddMarket(theirs, { sport = "NFL", event = "X @ Y", type = "moneyline", closesAt = T + 10,
    selections = { { label = "X", odds = -110 }, { label = "Y", odds = -110 } } }, T))
drain(); chatText()
for _, t in ipairs({ "PING", "JOIN_REQ", "SYNC_REQ" }) do handlers[t]("Bob", { rev = 0 }, theirs.code) end
handlers.BET_PLACE("Bob", { ref = "t1", marketId = tm.id, selectionId = 1, stake = 1000, odds = -110 }, theirs.code)
eq(#drain(), 0, "another character's book: no reply to PING, JOIN_REQ, SYNC_REQ or BET_PLACE")
eq(next(theirs.bets), nil, "another character's book: no bet booked")
eq(chatText(), "", "another character's book: nothing announced in chat")
T = T + 100
tickers[1].fn()
eq(#drain(), 0, "sweep leaves another character's book alone")
eq(tm.status, "open", "its market was not locked")
local mine = Net.MyBooks()
check(#mine == 1 and mine[1] == book, "MyBooks lists only the books this character owns")
eq(Net.Me(), "Steve", "Net.Me comes from Comm.Me")
check(#drain() == 0 and book.markets[1] ~= nil, "own book untouched")

-- a join code typed without the hyphen still reaches the right book (Protocol.CanonicalCode)
local bare = (book.code:gsub("%-", ""))
check(bare ~= book.code, "test setup: bare code has no hyphen: " .. bare)
handlers.JOIN_REQ("Zed", {}, bare:lower())
eq(book.members.Zed and book.members.Zed.status, "pending", "JOIN_REQ with c=" .. bare:lower() .. " reached the right book")
check(chatText():find("Zed wants to join NFL"), "the request was announced")
local out = Bookie.Handle(Model.FindByCode(SteveBookDB, bare), "Zed", "SYNC_REQ", { rev = 0 }, T)
eq(#out, 0, "the book found by its bare code answers through Bookie.Handle (pending: ignored)")
handlers.JOIN_REQ("Zed", {}, theirs.code)
eq(theirs.members.Zed, nil, "a request for another character's book is still ignored")
drain()

-- a failed Comm.Send is surfaced, not swallowed
local realSend = ns.Comm.Send
ns.Comm.Send = function() return false, "boom" end
handlers.PING("Bob", {}, book.code)
check(chatText():find("could not send PONG: boom"), "send failure reported in chat")
ns.Comm.Send = realSend

if fails == 0 then realprint("bookie_glue: all tests passed") else os.exit(1) end
