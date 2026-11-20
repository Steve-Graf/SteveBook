-- Group bets ("All Bets", SPEC §3b), bookie side: Bookie.GroupBets / BetText and the BETS_REQ -> BETS
-- exchange (members only, rate limited), and BookieNet's registration of BETS_REQ.
-- Run from repo root: luajit tests/test_bookie_group.lua   (exit status is non-zero on any failure)
local realprint = print
local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; realprint("FAIL: " .. label) end
end
local function eq(got, want, label)
    check(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

local ns = {}
assert(loadfile("SteveBook/Odds.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Protocol.lua"))("SteveBook", ns)
local Model = assert(loadfile("SteveBook/Model.lua"))("SteveBook", ns)
local Bookie = assert(loadfile("SteveBook/Bookie.lua"))("SteveBook", ns)
assert(loadfile("SteveBook/Import.lua"))("SteveBook", ns)
local Odds, Protocol = ns.Odds, ns.Protocol

local NOW = 1000000
local S = 100                                   -- one silver in copper
local H = 3600

local function newBook(names)
    local book = Model.CreateBook(Model.NewDB(), "NBA", "Steve", NOW)
    for _, name in ipairs(names or { "Bob", "Alice" }) do
        Bookie.RequestJoin(book, name, NOW); Bookie.Approve(book, name, NOW)
    end
    return book
end
local function market(book, kind, event, o1, o2, line, labels, closes)
    local l = labels or (kind == "total" and { "Over", "Under" } or { "H", "A" })
    return assert(Bookie.AddMarket(book, { sport = "NBA", event = event, type = kind, line = line, closesAt = closes or NOW + 7 * 24 * H,
        selections = { { label = l[1], odds = o1 or -110 }, { label = l[2], odds = o2 or -110 } } }, NOW))
end
local function single(book, who, m, sel, stake, at, ref)
    local bet = assert(Bookie.PlaceBet(book, who, { marketId = m.id, selectionId = sel, stake = stake or 10 * S,
        odds = m.selections[sel].odds, ref = ref or (who .. m.id .. sel .. (at or 0)) }, at or NOW))
    return bet
end
local function leg(m, sel) return { marketId = m.id, selectionId = sel, odds = m.selections[sel].odds } end
local function parlay(book, who, legs, stake, at, ref)
    return assert(Bookie.PlaceBet(book, who, { legs = legs, stake = stake or 10 * S, ref = ref or (who .. tostring(at) .. #legs) }, at or NOW))
end
local function byId(list) local t = {}; for _, e in ipairs(list) do t[e.id] = e end; return t end

------------------------------------------------------------------------------------------
-- entries and their text
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local spread = market(book, "spread", "LAL @ BOS", -110, -110, 5.5, { "LAL", "BOS" })
    local total = market(book, "total", "LAL @ BOS", -110, -110, 231.5)
    local mia = market(book, "moneyline", "MIA @ NYK", 130, -150, nil, { "MIA", "NYK" })
    local b1 = single(book, "Bob", spread, 1, 20 * S, NOW - 50)
    local b2 = single(book, "Alice", mia, 1, 10 * S, NOW - 40)
    local b3 = single(book, "Alice", total, 1, 50 * S, NOW - 30)
    local b4 = single(book, "Bob", spread, 2, 10 * S, NOW - 20)

    local g = Bookie.GroupBets(book, NOW)
    eq(#g, 4, "four open bets")
    local e = byId(g)
    eq(e[b1.id].text, "LAL +5.5 -110, LAL @ BOS", "single spread text")
    eq(e[b2.id].text, "MIA ML +130, MIA @ NYK", "single moneyline text")
    eq(e[b3.id].text, "Over 231.5 -110, LAL @ BOS", "single total text")
    eq(e[b4.id].text, "BOS -5.5 -110, LAL @ BOS", "the second side of a spread gets the opposite line")
    eq(e[b1.id].who, "Bob", "who is the bettor")
    eq(e[b2.id].who, "Alice", "who, another member")
    eq(e[b1.id].stake, 20 * S, "stake in copper")
    eq(e[b1.id].status, "accepted", "an open bet's status is 'accepted'")
    eq(e[b1.id].at, NOW - 50, "at is when it was placed")
    eq(e[b1.id].id, b1.id, "id")
    eq(e[b1.id].win, Odds.Profit(20 * S, -110), "an open single's win is its profit")
    eq(e[b2.id].win, Odds.Profit(10 * S, 130), "an underdog's win")
    -- exactly the documented fields (no more: this travels to every member)
    local keys = {}
    for k in pairs(e[b1.id]) do keys[#keys + 1] = k end
    table.sort(keys)
    eq(table.concat(keys, ","), "at,id,stake,status,text,who,win", "an entry has id, who, text, stake, status, at, win")

    -- the text uses the line and odds the bet was taken at, not what the market says now
    assert(Bookie.EditMarket(book, spread.id, { line = 7, odds = { [1] = -125 } }, NOW))
    g = Bookie.GroupBets(book, NOW); e = byId(g)
    eq(e[b1.id].text, "LAL +5.5 -110, LAL @ BOS", "after a line and odds move the bet still reads as it was taken")
    eq(e[b1.id].win, Odds.Profit(20 * S, -110), "...and wins at its own odds")

    -- the text is rendered for other people: it is American whatever view the bookie has chosen
    Odds.SetView("ratio")
    local gr = byId(Bookie.GroupBets(book, NOW))
    Odds.SetView("american")
    eq(gr[b1.id].text, "LAL +5.5 -110, LAL @ BOS", "a single's text stays American in the ratio view")
    eq(gr[b2.id].text, "MIA ML +130, MIA @ NYK", "...also for an underdog")

    -- newest placed first
    eq(g[1].id, b4.id, "newest first (1)")
    eq(g[4].id, b1.id, "newest first (4)")
    -- ties on placedAt: higher id first
    local t1 = single(book, "Bob", mia, 2, S, NOW - 5, "t1")
    local t2 = single(book, "Alice", mia, 2, S, NOW - 5, "t2")
    g = Bookie.GroupBets(book, NOW)
    check(g[1].id == t2.id and g[2].id == t1.id, "equal placement times: the later id first")
end

-- parlays ---------------------------------------------------------------------------------------
do
    local book = newBook()
    local spread = market(book, "spread", "LAL @ BOS", -110, -110, 5.5, { "LAL", "BOS" })
    local total = market(book, "total", "LAL @ BOS", -110, -110, 231.5)
    local mia = market(book, "moneyline", "MIA @ NYK", 130, -150, nil, { "MIA", "NYK" })
    local p = parlay(book, "Bob", { leg(spread, 1), leg(total, 1), leg(mia, 1) }, 20 * S, NOW - 10)
    local g = Bookie.GroupBets(book, NOW)
    eq(#g, 1, "one entry for a parlay")
    eq(g[1].text, ("3-leg parlay %s: LAL +5.5, Over 231.5, MIA ML"):format(Odds.Format(p.odds)), "parlay text")
    check(g[1].text:find("^3%-leg parlay [+-]%d+: "), "parlay text starts with the leg count and combined odds: " .. g[1].text)
    eq(g[1].win, Odds.ParlayProfit(20 * S, { -110, -110, 130 }), "an open parlay's win is the parlay profit")
    eq(g[1].stake, 20 * S, "stake")
    eq(g[1].status, "accepted", "open")

    Odds.SetView("ratio")
    local pr = Bookie.GroupBets(book, NOW)[1].text
    Odds.SetView("american")
    eq(pr, ("3-leg parlay %s: LAL +5.5, Over 231.5, MIA ML"):format(Odds.FormatAmerican(p.odds)), "a parlay's combined odds stay American in the ratio view")

    -- the legs keep the line they were taken at after the market moves
    assert(Bookie.EditMarket(book, spread.id, { line = 9 }, NOW))
    assert(Bookie.EditMarket(book, total.id, { line = 240 }, NOW))
    check(Bookie.GroupBets(book, NOW)[1].text:find("LAL +5.5, Over 231.5, MIA ML", 1, true), "legs read at their own lines after the markets moved")

    -- a push leg drops out of the win calculation, a won leg stays in
    Bookie.Settle(book, spread.id, 1, NOW)
    Bookie.Settle(book, total.id, "push", NOW)
    g = Bookie.GroupBets(book, NOW)
    eq(g[1].status, "accepted", "still open while a leg is pending")
    eq(g[1].win, Odds.ParlayProfit(20 * S, { -110, 130 }), "win = the won and pending legs only")
    -- all legs won -> settled: shown with its result and no win field
    Bookie.Settle(book, mia.id, 1, NOW)
    g = Bookie.GroupBets(book, NOW)
    eq(g[1].status, "won", "a settled parlay shows its status")
    eq(g[1].win, nil, "no win field once settled")
    -- a one-leg-lost parlay is lost at once
    local book2 = newBook()
    local a, b = market(book2, "moneyline", "AAA @ BBB"), market(book2, "moneyline", "CCC @ DDD")
    parlay(book2, "Bob", { leg(a, 1), leg(b, 1) }, 10 * S, NOW - 1)
    Bookie.Settle(book2, a.id, 2, NOW)
    eq(Bookie.GroupBets(book2, NOW)[1].status, "lost", "a lost parlay is shown as lost even with a pending leg")
end

------------------------------------------------------------------------------------------
-- which bets are included: open, recently settled; never void or rejected
------------------------------------------------------------------------------------------
do
    local book = newBook()
    local keep = Bookie.GROUP_SETTLED_KEEP
    eq(keep, 48 * H, "settled bets stay 48 hours")
    eq(Bookie.GROUP_BETS_MAX, 60, "at most 60 entries")
    local m = {}
    for i = 1, 9 do m[i] = market(book, "moneyline", "G" .. i .. " @ H" .. i) end
    local open = single(book, "Bob", m[1], 1, S, NOW - 3 * keep)          -- placed long ago, still open
    local won = single(book, "Bob", m[2], 1, S, NOW - 100)
    local lost = single(book, "Alice", m[3], 1, S, NOW - 90)
    local push = single(book, "Alice", m[4], 1, S, NOW - 80)
    local edge = single(book, "Bob", m[5], 1, S, NOW - 70)                -- settled exactly 48 h ago
    local stale = single(book, "Bob", m[6], 1, S, NOW - 60)               -- settled 48 h and a second ago
    local voided = single(book, "Alice", m[7], 1, S, NOW - 50)
    local voidMkt = single(book, "Bob", m[8], 1, S, NOW - 45)
    Bookie.Settle(book, m[2].id, 1, NOW - 10)
    Bookie.Settle(book, m[3].id, 2, NOW - 10)
    Bookie.Settle(book, m[4].id, "push", NOW - 10)
    Bookie.Settle(book, m[5].id, 1, NOW - keep)
    Bookie.Settle(book, m[6].id, 1, NOW - keep - 1)
    assert(Bookie.VoidBet(book, voided.id, NOW - 10))
    Bookie.VoidMarket(book, m[8].id, NOW - 10)
    local rejectedBet = { id = 999, bettor = "Bob", marketId = m[9].id, selectionId = 1, stake = S, odds = -110, status = "rejected", placedAt = NOW, settledAt = NOW - 10 }
    book.bets[999] = rejectedBet

    local e = byId(Bookie.GroupBets(book, NOW))
    check(e[open.id] and e[open.id].status == "accepted", "an open bet is always included, however old")
    check(e[won.id] and e[won.id].status == "won" and e[won.id].win == nil, "won")
    check(e[lost.id] and e[lost.id].status == "lost", "lost")
    check(e[push.id] and e[push.id].status == "push", "push")
    check(e[edge.id], "settled exactly 48 hours ago: included (boundary inclusive)")
    check(not e[stale.id], "settled 48 hours and a second ago: left out")
    check(not e[voided.id], "a bet the bookie voided is left out")
    check(not e[voidMkt.id], "a bet on a voided market is left out")
    check(not e[999], "a rejected bet is left out")
    local n = 0; for _ in pairs(e) do n = n + 1 end
    eq(n, 5, "exactly the five expected entries")
    -- a later correction can bring a stale-settled bet back inside the window
    Bookie.Settle(book, m[6].id, 2, NOW - 5)
    check(byId(Bookie.GroupBets(book, NOW))[stale.id], "re-settling restarts the 48 hours")
    -- and the cutoff moves with `now`
    check(not byId(Bookie.GroupBets(book, NOW + keep))[won.id], "48 hours later the recently won bet has aged out")
    check(byId(Bookie.GroupBets(book, NOW + keep))[open.id], "...but the open one has not")
end

-- the cap: newest 60 --------------------------------------------------------------------------
do
    local book = newBook()
    local m = market(book, "moneyline", "AAA @ BBB")
    local ids = {}
    for i = 1, 75 do ids[i] = single(book, (i % 2 == 0) and "Bob" or "Alice", m, 1, S, NOW - 1000 + i, "c" .. i).id end
    local g = Bookie.GroupBets(book, NOW)
    eq(#g, 60, "capped at 60")
    eq(g[1].id, ids[75], "the newest bet is first")
    eq(g[60].id, ids[16], "the 60th is the 16th placed (the 15 oldest were cut)")
    local seen = byId(g)
    check(not seen[ids[15]] and seen[ids[16]], "the cut is exactly at the oldest 15")
    -- exactly 60 is not cut
    local book2 = newBook()
    local m2 = market(book2, "moneyline", "AAA @ BBB")
    for i = 1, 60 do single(book2, "Bob", m2, 1, S, NOW - 100 + i, "d" .. i) end
    eq(#Bookie.GroupBets(book2, NOW), 60, "60 bets: all shown")
    eq(#Bookie.GroupBets(newBook(), NOW), 0, "no bets: an empty list")
end

-- text length and safe truncation -------------------------------------------------------------------
do
    local MAX = Bookie.GROUP_TEXT_MAX
    local book = newBook()
    -- eight legs with long names: truncated at a leg boundary with an ellipsis, under the limit
    local legs = {}
    for i = 1, 8 do
        local m = market(book, "spread", "Team Number " .. i .. " Of The League @ Opponent Number " .. i .. " Of The League", -110, -110, 3.5 + i,
            { "Team Number " .. i .. " Of The League", "Opponent Number " .. i })
        legs[i] = leg(m, 1)
    end
    local p = parlay(book, "Bob", legs, S, NOW - 1)
    local text = Bookie.GroupBets(book, NOW)[1].text
    check(#text <= MAX, "an 8-leg parlay with long names fits in " .. MAX .. " bytes: " .. #text)
    check(text:sub(-5) == ", ..." and text:find("^8%-leg parlay [+-]%d+: Team Number 1 Of The League %+4.5"), "it keeps whole legs and ends with an ellipsis: " .. text)
    check(not text:find("Team Number 8", 1, true), "the last leg did not fit")
    -- a short parlay is not touched
    local book2 = newBook()
    local a, b = market(book2, "moneyline", "AAA @ BBB", 150, -170, nil, { "AAA", "BBB" }), market(book2, "moneyline", "CCC @ DDD", -200, 170, nil, { "CCC", "DDD" })
    parlay(book2, "Bob", { leg(a, 1), leg(b, 1) }, S, NOW - 1)
    check(not Bookie.GroupBets(book2, NOW)[1].text:find("...", 1, true), "a short parlay has no ellipsis")
    -- a single with an enormous event name
    local huge = market(book, "moneyline", string.rep("X", 400) .. " @ Y", 100, -120, nil, { "AAA", "BBB" })
    local sb = single(book, "Alice", huge, 1, S, NOW)
    local st = byId(Bookie.GroupBets(book, NOW))[sb.id].text
    check(#st == MAX and st:sub(-3) == "...", "a single's text is clipped to " .. MAX .. " bytes with an ellipsis (" .. #st .. ")")
    check(st:find("^AAA ML %+100, X"), "the pick and odds survive the clipping")
    -- multi-byte characters are never cut in half
    local accented = string.rep("\195\169", 100)                        -- 100 x "é" (2 bytes each)
    for cut = 150, 170 do
        local clipped = Bookie._clip(accented, cut)
        local ok = #clipped <= cut and clipped:sub(-3) == "..."
        local body = clipped:sub(1, -4)
        ok = ok and #body % 2 == 0 and body == string.rep("\195\169", #body / 2)
        check(ok, "clip at " .. cut .. " bytes keeps whole characters (" .. #clipped .. " bytes)")
    end
    eq(Bookie._clip("short", 160), "short", "clip leaves short text alone")
    eq(Bookie._clip(string.rep("a", 160), 160), string.rep("a", 160), "clip leaves text of exactly the limit alone")
    check(#Bookie._clip(string.rep("a", 161), 160) == 160, "clip: one byte over is cut to the limit")
    -- every text in a mixed list is within the limit
    for _, e in ipairs(Bookie.GroupBets(book, NOW)) do check(#e.text <= MAX, "entry " .. e.id .. " text within the limit") end
    -- text is plain ASCII unless the bookie's own names are not
    local ascii = true
    for _, e in ipairs(Bookie.GroupBets(book2, NOW)) do if e.text:find("[\128-\255]") then ascii = false end end
    check(ascii, "texts built from ASCII names are ASCII (no middle dot, no fancy dashes)")
end

------------------------------------------------------------------------------------------
-- BETS_REQ -> BETS
------------------------------------------------------------------------------------------
do
    local book = newBook({ "Bob", "Alice" })
    Bookie.RequestJoin(book, "Pat", NOW)                               -- pending
    Bookie.RequestJoin(book, "Gone", NOW); Bookie.Approve(book, "Gone", NOW); Bookie.Remove(book, "Gone")
    local m = market(book, "spread", "LAL @ BOS", -110, -110, 5.5, { "LAL", "BOS" })
    single(book, "Bob", m, 1, 10 * S, NOW - 20)
    single(book, "Alice", m, 2, 20 * S, NOW - 10)
    local function ask(who, t) return Bookie.Handle(book, who, "BETS_REQ", {}, t or NOW) end

    check(Protocol.Validate("BETS_REQ", {}), "BETS_REQ is valid with an empty payload")
    local out, events = ask("Bob")
    eq(#out, 1, "an active member gets one reply")
    local r = out[1]
    check(r and r.type == "BETS" and r.to == "Bob", "the reply is BETS addressed to the asker")
    eq(#events, 0, "no UI events")
    eq(r.payload.rev, book.rev, "BETS.rev is the book's rev")
    eq(#r.payload.bets, 2, "BETS carries the group's bets")
    local who = {}
    for _, e in ipairs(r.payload.bets) do who[e.who] = true end
    check(who.Bob and who.Alice, "...including other members' bets (the group view)")
    local env, err = Protocol.Wrap("BETS", "NBA-TEST", r.payload)
    check(env ~= nil, "the outgoing BETS passes Protocol.Wrap: " .. tostring(err))
    local t, code, p = Protocol.Unwrap(env, "bookie")
    check(t == "BETS" and p and #p.bets == 2, "...and unwraps as a bookie message")
    check(Protocol.Unwrap({ v = Protocol.VERSION, t = "BETS_REQ", c = "X", p = {} }, "bettor") == "BETS_REQ", "BETS_REQ unwraps as a bettor message")
    -- an empty book still answers (an empty list)
    local empty = newBook()
    out = Bookie.Handle(empty, "Bob", "BETS_REQ", {}, NOW)
    check(#out == 1 and out[1].type == "BETS" and #out[1].payload.bets == 0, "no bets yet: an empty BETS")
    check(Protocol.Wrap("BETS", "NBA-TEST", out[1].payload), "an empty BETS is valid")

    -- who may ask
    out = ask("Pat")
    eq(#out, 0, "a pending member gets nothing")
    out = ask("Stranger")
    check(#out == 1 and out[1].type == "JOIN_DENY" and out[1].payload.reason == "not_member" and out[1].to == "Stranger"
          and out[1].payload.ownerName == "Steve", "a non-member gets JOIN_DENY not_member, like SYNC_REQ")
    check(Protocol.Wrap("JOIN_DENY", "NBA-TEST", out[1].payload), "...which validates")
    out = ask("Gone")
    check(#out == 1 and out[1].type == "JOIN_DENY" and out[1].payload.reason == "not_member", "a removed member too")
    out = Bookie.Handle(book, "Pat", "SYNC_REQ", {}, NOW)
    eq(#out, 0, "(same as SYNC_REQ for a pending member)")
    -- nothing about those asks changed the book
    local rev = book.rev
    ask("Pat"); ask("Stranger")
    eq(book.rev, rev, "asking changes nothing")
    eq(book.members.Stranger, nil, "...and does not create a member")

    -- rate limit: one answer per member per 5 seconds
    local T0 = NOW + 1000
    out = ask("Alice", T0);       eq(#out, 1, "first ask is answered")
    out = ask("Alice", T0 + 1);   eq(#out, 0, "1 s later: ignored")
    out = ask("Alice", T0 + 4);   eq(#out, 0, "4 s later: ignored")
    out = ask("Alice", T0 + 4);   eq(#out, 0, "again: still ignored")
    out = ask("Alice", T0 + 5);   eq(#out, 1, "exactly 5 s after the last answer: answered")
    out = ask("Alice", T0 + 9);   eq(#out, 0, "4 s after that answer: ignored (ignored asks did not restart the timer)")
    out = ask("Alice", T0 + 10);  eq(#out, 1, "10 s: answered")
    out = ask("Bob", T0 + 10);    eq(#out, 1, "another member is limited separately")
    out = ask("Bob", T0 + 11);    eq(#out, 0, "...and is limited too")
    out = ask("Alice", T0 + 3);   eq(#out, 1, "a clock that went backwards does not lock a member out")
    -- the other books' limits are separate
    local other = newBook({ "Alice" })
    out = Bookie.Handle(other, "Alice", "BETS_REQ", {}, T0 + 10)
    eq(#out, 1, "the same member in another book is not limited by this one")
    -- the limit is only for BETS_REQ: a SYNC_REQ or a bet in the same second is unaffected
    out = Bookie.Handle(book, "Alice", "SYNC_REQ", { rev = 0 }, T0 + 3)
    eq(#out, 1, "the limit does not apply to SYNC_REQ")
    -- the limit is in memory only: nothing about it is stored on the book
    local function hasKey(t, name) for k, v in pairs(t) do if k == name or (type(v) == "table" and v ~= t and hasKey(v, name)) then return true end end end
    check(not hasKey(book, "betsAsked") and not hasKey(book, "lastAsked"), "no rate-limit state is stored in the book")
end

------------------------------------------------------------------------------------------
-- BookieNet: BETS_REQ is registered and answered to the asker only
------------------------------------------------------------------------------------------
do
    local gns = {}
    for _, f in ipairs({ "Odds", "Protocol", "Model", "Bookie", "Import" }) do assert(loadfile("SteveBook/" .. f .. ".lua"))("SteveBook", gns) end
    local T = NOW
    local sent, handlers, changedCount = {}, {}, 0
    GetServerTime = function() return T end
    UnitName = function() return "Steve" end
    print = function() end
    C_Timer = { NewTicker = function() end }
    gns.Comm = {
        Register = function(t, fn) handlers[t] = fn end,
        Send = function(t, payload, code, to)
            local env, err = gns.Protocol.Wrap(t, code, payload)
            if not env then fails = fails + 1; realprint("FAIL: BookieNet sent invalid " .. t .. ": " .. tostring(err)) end
            sent[#sent + 1] = { type = t, payload = payload, to = to }
            return true
        end,
        JoinBook = function() end, Me = function() return "Steve" end,
    }
    SteveBookDB = gns.Model.NewDB()
    local Net = assert(loadfile("SteveBook/BookieNet.lua"))("SteveBook", gns)
    check(handlers.BETS_REQ ~= nil, "BookieNet registers a BETS_REQ handler")
    local book = assert(Net.CreateBook("NBA"))
    Net.Subscribe(function() changedCount = changedCount + 1 end)
    gns.Bookie.RequestJoin(book, "Bob", T); gns.Bookie.Approve(book, "Bob", T)
    local m = assert(gns.Bookie.AddMarket(book, { sport = "NBA", event = "LAL @ BOS", type = "moneyline", closesAt = T + 3600,
        selections = { { label = "LAL", odds = 150 }, { label = "BOS", odds = -170 } } }, T))
    assert(gns.Bookie.PlaceBet(book, "Bob", { marketId = m.id, selectionId = 1, stake = 10 * S, odds = 150, ref = "g1" }, T))
    sent = {}
    changedCount = 0
    handlers.BETS_REQ("Bob", {}, book.code)
    check(#sent == 1 and sent[1].type == "BETS" and sent[1].to == "Bob" and #sent[1].payload.bets == 1, "BETS goes to the asker, with the book's bets")
    eq(sent[1] and sent[1].payload.bets[1].text, "LAL ML +150, LAL @ BOS", "the text rendered by the bookie")
    eq(changedCount, 0, "a read-only request does not redraw the bookie window")
    sent = {}
    handlers.BETS_REQ("Bob", {}, book.code)
    eq(#sent, 0, "a second ask in the same second is ignored")
    T = T + 5
    handlers.BETS_REQ("Bob", {}, book.code)
    eq(#sent, 1, "five seconds later it is answered again")
    sent = {}
    handlers.BETS_REQ("Nobody", {}, book.code)
    check(#sent == 1 and sent[1].type == "JOIN_DENY" and sent[1].to == "Nobody", "a stranger is told they are not a member")
    sent = {}
    handlers.BETS_REQ("Bob", {}, "ZZZ-0000")
    eq(#sent, 0, "a book this character does not own is not answered")
    local theirs = assert(gns.Model.CreateBook(SteveBookDB, "Theirs", "Other", T))
    gns.Bookie.RequestJoin(theirs, "Bob", T); gns.Bookie.Approve(theirs, "Bob", T)
    T = T + 100
    handlers.BETS_REQ("Bob", {}, theirs.code)
    eq(#sent, 0, "someone else's book is not answered either")
    handlers.BETS_REQ("Steve", {}, book.code)
    eq(#sent, 0, "our own echoed message is ignored")
    print = realprint
end

if fails == 0 then realprint("bookie_group: all tests passed") else os.exit(1) end
