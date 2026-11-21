-- Run from repo root: lua5.1 tests/test_bookie_glue.lua
-- BookieNet.lua with the WoW client and Comm.lua stubbed out. Every message it sends must
-- pass Protocol.Wrap (field names/types match Protocol.Spec).
local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)
local Model = assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)
local Bookie = assert(loadfile("SteveBook/Bookie.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Import.lua"))("SteveBook", ns)
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

-- parlays through the glue: ACK/REJECT with legs, chat, settle -> MARKET + SYNC for the bettor ----------------
do
    local function addMl(event, o1, o2)
        return assert(Net.AddMarket(book, { sport = "NBA", event = event, type = "moneyline", closesAt = T + 3600,
            selections = { { label = "H", odds = o1 }, { label = "A", odds = o2 } } }))
    end
    local pa, pb = addMl("AAA @ BBB", 150, -170), addMl("CCC @ DDD", -200, 170)
    local spread = assert(Net.AddMarket(book, { sport = "NBA", event = "AAA @ BBB", type = "spread", line = -3.5, closesAt = pa.closesAt,
        selections = { { label = "H", odds = -110 }, { label = "A", odds = -110 } } }))
    drain(); chatText()
    local function leg(m, sel, odds) return { marketId = m.id, selectionId = sel, odds = odds or m.selections[sel].odds } end

    handlers.BET_PLACE("Alice", { ref = "par1", stake = 2000, legs = { leg(pa, 1), leg(pb, 1) } }, book.code)
    s = drain()
    check(#s == 1 and s[1].type == "BET_ACK" and s[1].to == "Alice" and s[1].payload.bet.legs and #s[1].payload.bet.legs == 2, "a parlay is acked with its legs")
    local expectOdds = ns.Odds.ParlayOdds({ 150, -200 })
    check(chatText():find("Alice bet 20s on a 2%-leg parlay %(%+" .. expectOdds .. "%)"), "chat announces the parlay")
    local parlayBet = s[1].payload.bet

    handlers.BET_PLACE("Alice", { ref = "par2", stake = 2000, legs = { leg(pa, 1), leg(pb, 1, -210) } }, book.code)
    s = drain()
    check(#s == 1 and s[1].type == "BET_REJECT" and s[1].payload.reason == "odds_changed" and s[1].payload.currentOdds == -200
          and s[1].payload.legIndex == 2, "stale leg odds: BET_REJECT with currentOdds and legIndex 2")
    handlers.BET_PLACE("Alice", { ref = "par3", stake = 2000, legs = { leg(pa, 1), leg(spread, 1) } }, book.code)
    s = drain()
    check(#s == 1 and s[1].payload.reason == "parlay_conflict" and s[1].payload.legIndex == 2, "ML + spread of one game: parlay_conflict, legIndex 2")
    eq(chatText(), "", "rejected parlays are not announced")

    -- settling one leg: MARKET to everyone, and a SYNC to Alice carrying the updated leg status
    Net.Settle(book, pa.id, 1)
    s = drain()
    check(#s == 2 and s[1].type == "MARKET" and s[1].to == nil and s[2].type == "SYNC" and s[2].to == "Alice", "settling a leg: MARKET then Alice's SYNC")
    local synced
    for _, b in ipairs(s[2].payload.bets) do if b.legs then synced = b end end
    check(synced and synced.status == "accepted" and synced.legs[1].status == "won" and synced.legs[2].status == "pending", "the SYNC shows leg 1 won, parlay still open")
    local balBefore = s[2].payload.balance
    -- the other leg loses: the parlay is lost, balance moves by the stake
    Net.Settle(book, pb.id, 2)
    s = drain()
    for _, b in ipairs(s[2].payload.bets) do if b.legs then synced = b end end
    check(synced.status == "lost" and s[2].payload.balance == balBefore - 2000, "a lost leg: SYNC shows the lost parlay and the new balance")
    -- the SYNC carries every leg's market even though both are settled
    local have = {}
    for _, mk2 in ipairs(s[2].payload.markets) do have[mk2.id] = true end
    check(have[pa.id] and have[pb.id], "the SYNC includes the parlay's leg markets")
    -- correcting leg 2 re-grades the parlay and re-syncs
    Net.Settle(book, pb.id, 1)
    s = drain()
    for _, b in ipairs(s[2].payload.bets) do if b.legs then synced = b end end
    check(synced.status == "won" and s[2].payload.balance == balBefore + ns.Odds.ParlayProfit(2000, { 150, -200 }), "correcting the result re-grades the parlay")
    local vb2 = Net.VoidBet(book, parlayBet.id)
    s = drain()
    check(vb2 and #s == 1 and s[1].type == "SYNC" and s[1].payload.balance == balBefore, "VoidBet on a parlay re-syncs the bettor, win reversed")
end

-- import through the glue: new markets are added, matching open ones updated, the rest skipped ------------------
do
    local ML = function(event, when, a, b) return ("ML|NBA|%s|%s|%s|%s"):format(event, when, a, b) end
    local when = "2026-11-26T16:30-05:00"
    drain(); chatText()
    local r = Net.ApplyImport(book, ML("IMP @ ORT", when, "IMP:-120", "ORT:+100"))
    check(r.added == 1 and r.updated == 0 and #r.failed == 0, "import: one new market")
    s = drain()
    check(#s == 1 and s[1].type == "MARKET" and s[1].to == nil, "...broadcast as a MARKET")
    local imported
    for _, mk2 in pairs(book.markets) do if mk2.event == "IMP @ ORT" then imported = mk2 end end
    check(imported and imported.selections[1].odds == -120, "...with the imported odds")

    -- a bet at the old price, then the line moves through an import
    handlers.BET_PLACE("Alice", { ref = "imp1", marketId = imported.id, selectionId = 1, stake = 1000, odds = -120 }, book.code)
    drain()
    local text = table.concat({
        ML("IMP @ ORT", when, "IMP:-135", "ORT:+115"),                   -- update
        ML("NEW @ GAM", when, "NEW:-110", "GAM:-110"),                    -- new
        ML("OLD @ GAM", "1970-01-01T00:00Z", "OLD:-110", "GAM:-110"),    -- already started
    }, "\n")
    r = Net.ApplyImport(book, text)
    check(r.added == 1 and r.updated == 1 and #r.failed == 0, "import: one new, one updated")
    eq(r.plan.started, 1, "...and one skipped as started")
    eq(imported.selections[1].odds, -135, "the open market's odds were updated")
    eq(imported.selections[2].odds, 115, "...both sides")
    eq(book.bets[#book.bets] and book.bets[#book.bets].odds or -120, -120, "(the existing bet keeps its odds)")
    local bobBet
    for _, b in pairs(book.bets) do if b.ref == "imp1" then bobBet = b end end
    eq(bobBet and bobBet.odds, -120, "an existing bet keeps the odds it was accepted at")
    s = drain()
    local types = {}
    for _, x in ipairs(s) do types[#types + 1] = x.type .. ">" .. tostring(x.payload.market and x.payload.market.event) end
    eq(#s, 2, "two MARKET broadcasts (the update and the new market): " .. table.concat(types, ","))
    check(s[1].payload.market.selections[1].odds == -135, "the update is broadcast with the new odds")

    -- a stale preview cannot double-post: the same text now has nothing left to do
    r = Net.ApplyImport(book, text)
    check(r.added == 0 and r.updated == 0 and r.plan.duplicate == 2, "importing the same text again changes nothing")
    eq(#drain(), 0, "...and broadcasts nothing")

    -- a market that was locked meanwhile is not touched
    Net.LockMarket(book, imported.id); drain()
    r = Net.ApplyImport(book, ML("IMP @ ORT", when, "IMP:-150", "ORT:+130"))
    check(r.updated == 0 and r.plan.started == 1 and imported.selections[1].odds == -135, "a locked market is never updated by an import")

    -- a moved spread line: the line AND odds change in place, broadcast whole; bets keep their line
    local SPL = function(ln, a, b) return ("SPREAD|NBA|SPR @ EAD|%s|%s|SPR:%s|EAD:%s"):format(when, ln, a, b) end
    r = Net.ApplyImport(book, SPL("-3.5", "-110", "-110")); drain()
    check(r.added == 1, "setup: the spread is posted")
    local spr
    for _, mk2 in pairs(book.markets) do if mk2.event == "SPR @ EAD" then spr = mk2 end end
    handlers.BET_PLACE("Alice", { ref = "sl1", marketId = spr.id, selectionId = 1, stake = 1000, odds = -110 }, book.code)
    local sbet
    for _, b in pairs(book.bets) do if b.ref == "sl1" then sbet = b end end
    check(sbet and sbet.line == -3.5 and sbet.odds == -110, "setup: the bet was taken at -3.5 (-110)")
    drain(); chatText()
    r = Net.ApplyImport(book, SPL("-5", "-105", "-115"))
    check(r.added == 0 and r.updated == 1 and #r.failed == 0, "a moved spread line is an update, not a new market")
    eq(spr.line, -5, "the market's line moved")
    check(spr.selections[1].odds == -105 and spr.selections[2].odds == -115, "...with the new odds")
    s = drain()
    check(#s == 1 and s[1].type == "MARKET" and s[1].to == nil and s[1].payload.market.id == spr.id and s[1].payload.market.line == -5,
          "the move is broadcast as a MARKET carrying the new line")
    check(sbet.line == -3.5 and sbet.odds == -110, "the existing bet keeps the line and odds it was accepted at")
    -- a line-only move (same prices) applies too
    r = Net.ApplyImport(book, SPL("-6", "-105", "-115"))
    check(r.updated == 1 and spr.line == -6 and spr.selections[1].odds == -105, "a line-only move applies")
    drain()
    -- with a deliberate alternate line the game has two spreads: a line matching neither is a new market,
    -- an exact line is an update of that one
    local alt = assert(Net.AddMarket(book, { sport = "NBA", event = "SPR @ EAD", type = "spread", line = -9, closesAt = spr.closesAt,
        selections = { { label = "SPR", odds = 120 }, { label = "EAD", odds = -140 } } })); drain()
    r = Net.ApplyImport(book, SPL("-12", "+200", "-240"))
    check(r.added == 1 and r.updated == 0 and spr.line == -6 and alt.line == -9, "a line matching neither of two spreads is a new market; nothing moves")
    s = drain()
    check(#s == 1 and s[1].payload.market.id ~= spr.id and s[1].payload.market.id ~= alt.id and s[1].payload.market.line == -12, "...and it is broadcast")
    r = Net.ApplyImport(book, SPL("-9", "+125", "-145"))
    check(r.updated == 1 and r.added == 0 and alt.selections[1].odds == 125 and alt.line == -9, "an exact line is an update of that market")
    drain()
    -- a bet placed on the line the bettor saw before the move is rejected with the current terms
    handlers.BET_PLACE("Alice", { ref = "stale-line", marketId = spr.id, selectionId = 1, stake = 1000, odds = -105, line = -5 }, book.code)
    s = drain()
    check(#s == 1 and s[1].type == "BET_REJECT" and s[1].to == "Alice" and s[1].payload.reason == "odds_changed"
          and s[1].payload.currentLine == -6 and s[1].payload.currentOdds == -105, "a stale line is rejected via the handler with currentOdds and currentLine")
    handlers.BET_PLACE("Alice", { ref = "fresh-line", marketId = spr.id, selectionId = 1, stake = 1000, odds = -105, line = -6 }, book.code)
    s = drain()
    check(#s == 1 and s[1].type == "BET_ACK" and s[1].payload.bet.line == -6, "re-confirmed at the current line: accepted, bet.line recorded")
    chatText()

    -- a locked spread is not moved
    Net.LockMarket(book, spr.id); drain()
    r = Net.ApplyImport(book, SPL("-6", "-120", "+100"))
    check(r.updated == 0 and r.added == 0 and r.plan.started == 1 and spr.selections[1].odds == -105, "a locked spread is left alone")
    eq(#drain(), 0, "...and nothing is broadcast")
end

-- a failed Comm.Send is surfaced, not swallowed
local realSend = ns.Comm.Send
ns.Comm.Send = function() return false, "boom" end
handlers.PING("Bob", {}, book.code)
check(chatText():find("could not send PONG: boom"), "send failure reported in chat")
ns.Comm.Send = realSend

-- settling a slate from pasted FINAL lines, through the glue -------------------------------------------------
do
    local sbook = assert(Net.CreateBook("Slate"))
    for _, who in ipairs({ "Ann", "Cal", "Dee" }) do
        handlers.JOIN_REQ(who, {}, sbook.code); assert(Net.Approve(sbook, who))
    end
    local function market(event, kind, line, l1, l2)
        return assert(Net.AddMarket(sbook, { sport = "NBA", event = event, type = kind, line = line, closesAt = T + 100,
            selections = { { label = l1, odds = -110 }, { label = l2, odds = -110 } } }))
    end
    local ml1, to1 = market("AAA @ BBB", "moneyline", nil, "AAA", "BBB"), market("AAA @ BBB", "total", 200.5, "Over", "Under")
    local ml2 = market("CCC @ DDD", "moneyline", nil, "CCC", "DDD")
    local ml3 = market("EEE @ FFF", "moneyline", nil, "EEE", "FFF")             -- no result pasted for this one
    drain(); chatText()
    local function bet(who, ref, mk, sel, stake)
        handlers.BET_PLACE(who, { ref = ref, marketId = mk.id, selectionId = sel, stake = stake, odds = -110, line = mk.line }, sbook.code)
    end
    bet("Ann", "s1", ml1, 1, 10000); bet("Ann", "s2", to1, 1, 10000); bet("Cal", "s3", ml1, 2, 10000)
    bet("Cal", "s4", ml2, 1, 10000); bet("Dee", "s5", ml3, 1, 10000)
    drain(); chatText()

    local text = "FINAL|NBA|AAA @ BBB|AAA:110|BBB:101\nFINAL|NBA|CCC @ DDD|CCC:90|DDD:95\nFINAL|NBA|XXX @ YYY|XXX:1|YYY:0"
    T = T + 200                                                          -- the games have started
    local r = Net.ApplyImport(sbook, text)
    eq(r.settled, 3, "three markets settled by the paste")
    eq(#r.failed, 0, "...none failed")
    eq(sbook.markets[ml1.id].status, "settled", "AAA @ BBB moneyline settled")
    eq(sbook.markets[ml1.id].result, 1, "...AAA won")
    eq(sbook.markets[to1.id].result, 1, "...the total went over (211 > 200.5)")
    eq(sbook.markets[ml2.id].result, 2, "DDD won the other game")
    eq(sbook.markets[ml3.id].status, "open", "a game with no result pasted is untouched")
    eq(Bookie.Balance(sbook, "Ann"), 9090 + 9090, "Ann won both her bets (10000 at -110 pays 9090)")
    eq(Bookie.Balance(sbook, "Cal"), -10000 - 10000, "Cal lost both")
    local s = drain()
    local markets, syncs, to = 0, 0, {}
    for _, m in ipairs(s) do
        if m.type == "MARKET" then markets = markets + 1; check(m.to == nil, "MARKET is a broadcast") end
        if m.type == "SYNC" then syncs = syncs + 1; to[m.to] = (to[m.to] or 0) + 1 end
    end
    eq(markets, 3, "one MARKET per settled market")
    eq(syncs, 2, "one SYNC per affected bettor, not one per market (Ann and Cal)")
    check(to.Ann == 1 and to.Cal == 1 and not to.Dee, "...to Ann and Cal only; Dee's market was not settled")

    r = Net.ApplyImport(sbook, text)
    eq(r.settled, 0, "pasting the same results again settles nothing")
    eq(#drain(), 0, "...and sends nothing")
end

if fails == 0 then realprint("bookie_glue: all tests passed") else os.exit(1) end
