-- Smoke test for SteveBook/UI/Bettor.lua with a stubbed WoW API. Catches runtime errors and
-- checks the message flow (JOIN_OK -> SYNC -> lines -> BET_PLACE -> ACK/REJECT). It cannot check
-- that real frame templates exist; do that in game (see the notes in the Bettor agent report).
-- Run from repo root: lua tests/test_bettor_ui.lua
local realPrint = print   -- print is replaced below to capture the addon's chat output
local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; realPrint("FAIL: " .. label) end
end

local T = 1000000
local frames = {}
local Frame = {}
Frame.__index = function(self, k)
    local v = rawget(Frame, k)
    if v ~= nil then return v end
    return function() return self end   -- any other method: no-op returning the frame
end
local function script(self, name) local s = rawget(self, "_scripts"); return s and s[name] end
function Frame.SetText(self, t) rawset(self, "_text", t); local f = script(self, "OnTextChanged"); if f then f(self) end end
function Frame.GetText(self) return rawget(self, "_text") or "" end
function Frame.SetScript(self, name, fn) local s = rawget(self, "_scripts"); if not s then s = {}; rawset(self, "_scripts", s) end; s[name] = fn end
function Frame.GetWidth() return 500 end
function Frame.GetHeight() return 400 end
function Frame.GetVerticalScroll() return 0 end
function Frame.Show(self) rawset(self, "_shown", true); local f = script(self, "OnShow"); if f then f(self) end end
function Frame.Hide(self) rawset(self, "_shown", false); local f = script(self, "OnHide"); if f then f(self) end end
function Frame.SetShown(self, v) rawset(self, "_shown", v and true or false) end
function Frame.IsShown(self) return rawget(self, "_shown") == true end
function Frame.SetEnabled(self, v) rawset(self, "_enabled", v and true or false) end
function Frame.IsEnabled(self) return rawget(self, "_enabled") ~= false end
function Frame.GetFrameLevel() return 1 end
function Frame.Click(self) local f = script(self, "OnClick"); if f then f(self) end end
local function newFrame() local f = setmetatable({}, Frame); frames[#frames + 1] = f; return f end
function Frame.CreateFontString(self) return newFrame() end

function CreateFrame() return newFrame() end
UIParent = newFrame()
function GetServerTime() return T end
date = os.date
UnitName = function() return "Me" end
local tickers = {}
C_Timer = {
    NewTicker = function(iv, fn)
        local tk = { fn = fn, iv = iv }
        function tk:Cancel() self.cancelled = true end
        tickers[#tickers + 1] = tk
        return tk
    end,
    After = function() end,
}
local function ticker(iv) for i = #tickers, 1, -1 do if tickers[i].iv == iv and not tickers[i].cancelled then return tickers[i] end end end
local printed = {}
print_real = print
print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
local function lastPrint() return printed[#printed] or "" end

local ns = {}
for _, f in ipairs({ "Odds", "Protocol", "Clock", "Cache", "Slip" }) do assert(loadfile("SteveBook/" .. f .. ".lua"))("SteveBook", ns) end
local Cache = ns.Cache
SteveBookDB = { cache = Cache.NewStore() }

local handlers, sent = {}, {}
ns.Comm = {
    Register = function(t, fn) handlers[t] = fn end,
    Send = function(t, p, code) sent[#sent + 1] = { t = t, p = p, code = code }; assert(ns.Protocol.Validate(t, p)) end,
}
assert(loadfile("SteveBook/UI/Bettor.lua"))("SteveBook", ns)
local B = ns.UI.Bettor
check(B and B.Show and B.Hide and B.Toggle, "exposes Show/Hide/Toggle")
for _, t in ipairs({ "JOIN_OK", "JOIN_DENY", "SYNC", "MARKET", "BET_ACK", "BET_REJECT", "BALANCE", "PONG" }) do
    check(handlers[t], "handler registered: " .. t)
end

local function findButton(text)
    for _, f in ipairs(frames) do if rawget(f, "_text") == text then return f end end
end
local function frameWithTextContaining(s)
    for _, f in ipairs(frames) do local x = rawget(f, "_text"); if type(x) == "string" and x:find(s, 1, true) then return f end end
end
local function lastSent(t)
    for i = #sent, 1, -1 do if sent[i].t == t then return sent[i] end end
end

local lobby = { asks = 0, books = {}, subs = {} }
lobby.Books = function() return lobby.books end
lobby.Ask = function() lobby.asks = lobby.asks + 1 end
lobby.Subscribe = function(fn) lobby.subs[#lobby.subs + 1] = fn end
ns.BookLobby = lobby        -- the window subscribes when it is first built

B.Show()   -- no books: join screen
check(findButton("No book yet") ~= nil, "no-book header")

-- The join box canonicalizes what was typed, and refuses things that aren't codes.
do
    local codeBox
    for _, f in ipairs(frames) do
        local s = rawget(f, "_scripts")
        if s and s.OnEnterPressed and not s.OnTextChanged then codeBox = f end
    end
    check(codeBox ~= nil, "join box exists")
    local n = #sent
    codeBox:SetText("abc")
    findButton("Request to join"):Click()
    check(#sent == n and lastPrint():find("join code"), "invalid code is not sent")
    codeBox:SetText("zzz 9999")
    findButton("Request to join"):Click()
    local jr = lastSent("JOIN_REQ")
    check(#sent == n + 1 and jr.code == "ZZZ-9999", "typed code is canonicalized before JOIN_REQ")
    check(Cache.Book(SteveBookDB.cache, "ZZZ-9999").status == "requested", "request recorded under the canonical code")
    Cache.Forget(SteveBookDB.cache, "ZZZ-9999")
    SteveBookDB.cache.selected = nil
    B.Refresh()
end

-- Join flow.
local CODE = "NFL-ABCD"
Cache.RequestJoin(SteveBookDB.cache, CODE)
B.Refresh()
ticker(30).fn()
check(lastSent("JOIN_REQ") and lastSent("JOIN_REQ").code == CODE, "requested book re-sends JOIN_REQ on tick")
handlers.PONG("Bookie", {}, CODE)
check(not Cache.IsOnline(SteveBookDB.cache, CODE, T), "PONG ignored until approved")
-- A forged JOIN_OK (from a third player, or naming a different owner) is ignored.
handlers.JOIN_OK("Mallory", { bookName = "Fake", ownerName = "Bookie", rev = 1 }, CODE)
check(Cache.Book(SteveBookDB.cache, CODE).status == "requested", "JOIN_OK from someone other than the named owner is ignored")
handlers.JOIN_OK("Mallory", { bookName = "Fake", ownerName = "", rev = 1 }, CODE)
check(Cache.Book(SteveBookDB.cache, CODE).status == "requested", "JOIN_OK with no owner is ignored")
handlers.JOIN_OK("Bookie", { bookName = "NFL Week 12", ownerName = "Someone", rev = 1 }, CODE)
check(Cache.Book(SteveBookDB.cache, CODE).status == "requested", "JOIN_OK naming a different owner is ignored")
check(#sent == 0 or not lastSent("SYNC_REQ"), "no SYNC_REQ after a forged JOIN_OK")
handlers.JOIN_OK("Bookie-OtherRealm", { bookName = "NFL Week 12", ownerName = "Bookie", rev = 1 }, CODE)
check(Cache.Book(SteveBookDB.cache, CODE).status == "active", "realm suffix on the sender is ignored when comparing names")
Cache.Book(SteveBookDB.cache, CODE).status, Cache.Book(SteveBookDB.cache, CODE).owner = "requested", nil
handlers.JOIN_OK("Bookie", { bookName = "NFL Week 12", ownerName = "Bookie", rev = 1 }, CODE)
local b = Cache.Book(SteveBookDB.cache, CODE)
check(b.status == "active" and b.owner == "Bookie", "approved + owner recorded")
check(lastSent("SYNC_REQ") ~= nil, "SYNC_REQ sent after approval")
check(lastPrint():find("approved"), "approval printed")

handlers.SYNC("Mallory", { rev = 2, bookName = "evil", markets = {}, bets = {}, balance = 999 }, CODE)
check(b.balance == 0, "SYNC from non-owner ignored")
local function market(id, status, odds1)
    return { id = id, sport = "NFL", event = "PHI @ DAL", type = "spread", line = -3.5, status = status or "open", closesAt = T + 3600,
        selections = { { id = 1, label = "PHI", odds = odds1 or -110 }, { id = 2, label = "DAL", odds = -110 } } }
end
local function mlMarket(id, event, o1, o2)
    return { id = id, sport = "NFL", event = event, type = "moneyline", status = "open", closesAt = T + 3600,
        selections = { { id = 1, label = "AAA", odds = o1 }, { id = 2, label = "BBB", odds = o2 } } }
end
local function totalMarket(id, event)
    return { id = id, sport = "NFL", event = event, type = "total", line = 47.5, status = "open", closesAt = T + 3600,
        selections = { { id = 1, label = "Over", odds = -110 }, { id = 2, label = "Under", odds = -110 } } }
end
local function bookieSync(markets, bets)
    if not bets then bets = {}; for _, x in pairs(b.bets) do bets[#bets + 1] = x end end   -- the bookie re-sends my bets
    handlers.SYNC("Bookie", { rev = 2, bookName = "NFL Week 12", markets = markets, bets = bets, balance = 0,
        payments = {}, creditLimit = 50000 }, CODE)
end
bookieSync({ market(1), mlMarket(2, "NYG @ WAS", 150, -170), totalMarket(3, "PHI @ DAL") })
check(b.markets[1] and b.name == "NFL Week 12" and b.creditLimit == 50000, "SYNC applied")
check(Cache.IsOnline(SteveBookDB.cache, CODE, T), "SYNC from the bookie counts as online")

local function findPrefix(prefix)
    for _, f in ipairs(frames) do local x = rawget(f, "_text"); if type(x) == "string" and x:sub(1, #prefix) == prefix then return f end end
end
local function stakeBox()
    for _, f in ipairs(frames) do if script(f, "OnEnterPressed") and script(f, "OnTextChanged") then return f end end
end
local function nBetPlace() local n = 0; for _, e in ipairs(sent) do if e.t == "BET_PLACE" then n = n + 1 end end; return n end

B.Refresh()
-- The odds board shows the open games.
check(frameWithTextContaining("PHI @ DAL") and frameWithTextContaining("NYG @ WAS"), "board shows both games")
check(frameWithTextContaining("PHI -3.5") and frameWithTextContaining("DAL +3.5"), "spread cells carry the line")
check(frameWithTextContaining("O 47.5") and frameWithTextContaining("U 47.5"), "total cells carry the line")

-- Single slip: the same stake rules as before.
check(B.Select(1, 1) == "set", "clicking a cell puts it on the single slip")
local stake = stakeBox()
check(stake ~= nil, "slip stake box exists")
local place = findButton("Place Bet")
check(place ~= nil, "Place Bet button")
stake:SetText("25g")
check(rawget(place, "_enabled") == false, "stake over 1g disabled")
stake:SetText("20s 10c")
check(rawget(place, "_enabled") == false, "stake with loose copper disabled")
stake:SetText("1g 1s")
check(rawget(place, "_enabled") == false, "1g 1s disabled")
stake:SetText("20s")
check(rawget(place, "_enabled") == true, "Place Bet enabled with online book and valid stake")
stake:SetText("nonsense")
check(rawget(place, "_enabled") == false, "Place Bet disabled for bad stake")
check(frameWithTextContaining("Enter a stake") ~= nil, "unparsable stake explained")
stake:SetText("20s")
b.lastPong = T - 1000
B.Refresh()
check(rawget(place, "_enabled") == false, "Place Bet disabled when no recent PONG")
Cache.MarkPong(SteveBookDB.cache, CODE, T, "Bookie")
B.Refresh()
check(rawget(place, "_enabled") == true, "Place Bet re-enabled by PONG")
-- any message from the bookie proves they are online, not only the answer to our ping
b.lastPong = T - 1000
handlers.BALANCE("Stranger", { rev = 1, balance = 0 }, CODE)
check(not Cache.IsOnline(SteveBookDB.cache, CODE, GetServerTime()), "a message from someone else does not mark the bookie online")
handlers.BALANCE("Bookie", { rev = 1, balance = 0 }, CODE)
check(Cache.IsOnline(SteveBookDB.cache, CODE, GetServerTime()), "a message from the bookie marks them online without a PONG")
b.lastHeard = nil; b.lastPong = T                          -- leave the book as the later tests expect
place:Click()
local bp = lastSent("BET_PLACE")
check(bp and bp.p.stake == 2000 and bp.p.odds == -110 and bp.p.marketId == 1 and bp.p.selectionId == 1 and bp.p.legs == nil and type(bp.p.ref) == "string", "single BET_PLACE payload is flat")
check(next(b.pending) == bp.p.ref, "pending recorded under ref")
check(B.SlipState().single == nil, "the slip is cleared once sent")

-- The bookie says the odds moved (the MARKET update arrives too): the slip comes back, odds updated.
handlers.MARKET("Bookie", { rev = 3, market = market(1, "open", -120) }, CODE)
handlers.BET_REJECT("Bookie", { ref = bp.p.ref, reason = "odds_changed", currentOdds = -120 }, CODE)
B.Refresh()
check(lastPrint():find("rejected") and lastPrint():find("%-120"), "odds_changed printed")
check(next(b.pending) == nil and #b.rejected == 1, "rejection moved out of pending")
check(B.SlipState().single and B.SlipState().single.odds == -120, "the slip is restored with the new odds")
check(stake:GetText() == "20s", "the stake is put back for re-confirming")
check(place:GetText() == "Confirm new odds" and rawget(place, "_enabled") == true, "the button asks for a confirmation")
local n0 = nBetPlace()
place:Click()
check(nBetPlace() == n0 and place:GetText() == "Place Bet", "confirming sends nothing and unlocks Place Bet")
place:Click()
bp = lastSent("BET_PLACE")
check(nBetPlace() == n0 + 1 and bp.p.odds == -120, "second BET_PLACE uses the new odds")
handlers.BET_ACK("Bookie", { ref = bp.p.ref, bet = { id = 7, ref = bp.p.ref, bettor = "me", marketId = 1, selectionId = 1,
    stake = 2000, odds = -120, status = "accepted", placedAt = T }, balance = 0 }, CODE)
check(b.bets[7] and next(b.pending) == nil and lastPrint():find("accepted"), "ACK recorded")

-- Moved odds while the slip is open (the usual way: a MARKET update): confirmation needed.
B.Select(2, 1)
stake:SetText("10s")
check(rawget(place, "_enabled") == true, "slip ready")
handlers.MARKET("Bookie", { rev = 4, market = mlMarket(2, "NYG @ WAS", 140, -160) }, CODE)
B.Refresh()
check(place:GetText() == "Confirm new odds", "a line move under an open slip needs a confirmation")
B.SlipState().single = nil; B.Refresh()

-- Parlay slip.
findPrefix("Parlay ("):Click()
check(B.SlipState().mode == "parlay", "Parlay tab switches the slip mode")
check(B.Select(1, 1) == "added" and B.Select(2, 2) == "added", "two legs from different games")
check(findPrefix("Parlay (2)") ~= nil, "the tab counts the legs")
local act, msg = B.Select(3, 1)                       -- over in PHI @ DAL, with the spread already on the slip
check(act == "added", "spread + total of the same game is allowed")
act, msg = B.Select(3, 2)
check(act == "replaced", "under replaces over (same market)")
check(frameWithTextContaining("Combined odds") ~= nil, "combined odds label")
local place2 = findButton("Place Parlay")
check(place2 ~= nil, "Place Parlay button")
stake:SetText("20s")
check(rawget(place2, "_enabled") == true, "Place Parlay enabled with 3 legs and a stake")
check(frameWithTextContaining("All legs must win") ~= nil, "the parlay note is shown")
-- A leg that conflicts is refused with a message that names the other leg.
bookieSync({ market(1), mlMarket(2, "NYG @ WAS", 150, -170), totalMarket(3, "PHI @ DAL"), mlMarket(4, "PHI @ DAL", -150, 130) })
act, msg = B.Select(4, 1)
check(act == "refused" and lastPrint():find("can't go with"), "moneyline + spread from one game is refused with a message")
check(B.SlipState().mode == "parlay" and #B.SlipState().parlay == 3, "the refused leg was not added")
-- Remove a leg through its button.
local removeBtn
for _, f in ipairs(frames) do if rawget(f, "_text") == "x" then removeBtn = f; break end end
check(removeBtn ~= nil, "leg remove buttons exist")
local before = #B.SlipState().parlay
removeBtn:Click()
check(#B.SlipState().parlay == before - 1, "the x button removes a leg")
B.Select(2, 2)  -- remove or re-add: make sure we have 3 legs again
B.Select(1, 1)
local nLegs = #B.SlipState().parlay
check(nLegs >= 2, "legs on the slip: " .. nLegs)
stake:SetText("20s")
place2 = findButton("Place Parlay")
n0 = nBetPlace()
place2:Click()
bp = lastSent("BET_PLACE")
check(nBetPlace() == n0 + 1 and bp.p.legs and #bp.p.legs == nLegs and bp.p.marketId == nil and bp.p.odds == nil and bp.p.stake == 2000, "parlay BET_PLACE has legs and no flat fields")
check(b.pending[bp.p.ref] and b.pending[bp.p.ref].legs and #B.SlipState().parlay == 0, "parlay pending recorded; parlay slip cleared")
local ref1 = bp.p.ref

-- ACK -> My Bets shows the parlay with its legs.
local ackLegs = {}
for i, l in ipairs(bp.p.legs) do ackLegs[i] = { marketId = l.marketId, selectionId = l.selectionId, odds = l.odds, status = "pending" } end
handlers.BET_ACK("Bookie", { ref = ref1, bet = { id = 8, ref = ref1, bettor = "me", stake = 2000, odds = 400, status = "accepted", placedAt = T, legs = ackLegs }, balance = 0 }, CODE)
check(b.bets[8] and next(b.pending) == nil and lastPrint():find("parlay"), "parlay ACK recorded")
findPrefix("My Bets"):Click()
check(frameWithTextContaining("Parlay, " .. nLegs .. " legs") ~= nil, "My Bets lists the parlay")
check(frameWithTextContaining("Pending") ~= nil and frameWithTextContaining("PHI -3.5") ~= nil, "My Bets lists each leg with its status")
findPrefix("Lines"):Click()

-- Parlay rejections restore the slip and say what happened.
local function sendParlay(legIdx)
    findPrefix("Parlay ("):Click()
    B.SlipState().parlay = {}
    B.Select(1, 1); B.Select(2, 1); B.Select(3, 1)
    stakeBox():SetText("10s")
    findButton("Place Parlay"):Click()
    return lastSent("BET_PLACE")
end
local pb = sendParlay()
handlers.MARKET("Bookie", { rev = 5, market = mlMarket(2, "NYG @ WAS", 120, -140) }, CODE)
handlers.BET_REJECT("Bookie", { ref = pb.p.ref, reason = "odds_changed", legIndex = 2, currentOdds = 120 }, CODE)
B.Refresh()
check(#B.SlipState().parlay == 3 and B.SlipState().parlay[2].odds == 120, "odds_changed with legIndex updates that leg")
check(B.SlipState().confirm.parlay == true and findButton("Confirm new odds") ~= nil, "and asks for a confirmation")
check(lastPrint():find("Leg 2") and lastPrint():find("%+120"), "the message names the leg and the new odds")
check(stakeBox():GetText() == "10s", "parlay stake restored")

pb = sendParlay()
handlers.BET_REJECT("Bookie", { ref = pb.p.ref, reason = "market_closed", legIndex = 3 }, CODE)
B.Refresh()
check(#B.SlipState().parlay == 2, "market_closed with legIndex drops that leg")
check(lastPrint():find("Leg 3 was dropped"), "and says so")

pb = sendParlay()
handlers.BET_REJECT("Bookie", { ref = pb.p.ref, reason = "parlay_conflict", legIndex = 2 }, CODE)
B.Refresh()
check(lastPrint():find("can't be combined") and #B.SlipState().parlay == 3, "parlay_conflict is explained and the legs stay")

pb = sendParlay()
handlers.BET_REJECT("Bookie", { ref = pb.p.ref, reason = "credit_limit", available = 500 }, CODE)
check(lastPrint():find("credit limit") and lastPrint():find("5s"), "parlay credit_limit tells how much is left")
B.Refresh()
B.SlipState().parlay = {}
findPrefix("Single"):Click()

-- Time passes while the window is open: the game starts.
do
    check(ticker(5) ~= nil, "window refreshes on a 5s ticker while shown")
    B.Select(1, 1)
    stakeBox():SetText("10s")
    local placeNow = findButton("Place Bet")
    check(rawget(placeNow, "_enabled") == true, "slip enabled before the game starts")
    local startsIn = b.markets[1].closesAt - T
    T = T + startsIn + 1                  -- the game starts; nothing else happens yet
    Cache.MarkPong(SteveBookDB.cache, CODE, T, "Bookie")
    local nbefore = nBetPlace()
    local p0 = #printed
    ticker(5).fn()                         -- the refresh tick
    check(B.SlipState().single == nil, "the slip drops the game that started")
    local said = false
    for i = p0 + 1, #printed do if printed[i]:find("this game has started") then said = true end end
    check(said, "and says why: this game has started")
    placeNow:Click()
    check(nBetPlace() == nbefore, "Place Bet does nothing after the start time")
    check(#Cache.Board(SteveBookDB.cache, CODE, T).games == 0 or frameWithTextContaining("PHI @ DAL") ~= nil, "board re-rendered without the started game")
    T = T - startsIn - 1
    Cache.MarkPong(SteveBookDB.cache, CODE, T, "Bookie")
    B.Refresh()
end

-- My Bets copes with a bet whose market is not in the cache, and says the history window.
do
    b.bets[900] = { id = 900, marketId = 404, selectionId = 1, stake = 100, odds = -110, status = "lost", placedAt = T - 5, delta = -100 }
    findPrefix("My Bets"):Click()
    check(frameWithTextContaining("Game no longer listed") ~= nil, "bet row without a market names a placeholder")
    check(frameWithTextContaining("last 14 days") ~= nil, "My Bets says it shows the last 14 days")
    b.bets[900] = nil
    findPrefix("Lines"):Click()
end

-- A bet keeps the line it was accepted on even after the market's line moves.
do
    b.bets[901] = { id = 901, marketId = 1, selectionId = 1, line = -2.5, stake = 100, odds = -110, status = "accepted", placedAt = T - 5 }
    findPrefix("My Bets"):Click()
    check(frameWithTextContaining("PHI -2.5") ~= nil, "My Bets shows the bet's own line, not the market's current -3.5")
    b.bets[901] = nil
    findPrefix("Lines"):Click()
end

-- A line move: odds_changed with currentLine puts the bet back with the new line, to confirm.
do
    local mv = market(1, "open", -110); mv.line = -4.5
    handlers.MARKET("Bookie", { rev = 20, market = mv }, CODE)     -- the bettor learned of the move
    B.SlipState().single = nil
    B.Select(1, 1)
    stakeBox():SetText("10s")
    check(B.SlipState().single.line == -4.5, "the slip shows the current line")
    local before = nBetPlace()
    local confirmBtn = findButton("Place Bet")
    confirmBtn:Click()
    local lb = lastSent("BET_PLACE")
    check(nBetPlace() == before + 1 and lb.p.line == -4.5, "BET_PLACE carries the line the slip showed")
    local mv2 = market(1, "open", -110); mv2.line = -5
    handlers.MARKET("Bookie", { rev = 21, market = mv2 }, CODE)
    handlers.BET_REJECT("Bookie", { ref = lb.p.ref, reason = "odds_changed", currentOdds = -110, currentLine = -5 }, CODE)
    B.Refresh()
    check(B.SlipState().single and B.SlipState().single.line == -5 and B.SlipState().confirm.single, "the slip is restored with the new line, awaiting confirmation")
    check(lastPrint():find("line %-5"), "the message names the new line: " .. lastPrint())
    B.SlipState().single = nil
    handlers.MARKET("Bookie", { rev = 22, market = market(1, "open", -110) }, CODE)   -- back to -3.5
    B.Refresh()
end

-- All Bets (the group's bets).
do
    local function nReq() local n = 0; for _, e in ipairs(sent) do if e.t == "BETS_REQ" then n = n + 1 end end; return n end
    local entries = {
        { id = 1, who = "Me", text = "PHI -3.5 -110 · PHI @ DAL", stake = 2000, status = "accepted", at = T - 10, win = 1818, legs = { { m = 1, s = 1 } } },
        { id = 2, who = "Ann", text = ("a very long parlay description "):rep(6), stake = 1000, status = "accepted", at = T - 5, win = 4000,
          legs = { { m = 2, s = 2 }, { m = 3, s = 1 } } },
        { id = 3, who = "Bob", text = "NYG ML +150", stake = 500, status = "lost", at = T - 90000 },
    }
    -- Forged and misplaced BETS are ignored.
    local before = Cache.GroupBets(SteveBookDB.cache, CODE)
    handlers.BETS("Mallory", { rev = 1, bets = entries }, CODE)
    check(Cache.GroupBets(SteveBookDB.cache, CODE) == nil, "BETS from someone other than the bookie is ignored")
    handlers.BETS("Bookie", { rev = 1, bets = entries }, "NOP-1234")
    check(Cache.Book(SteveBookDB.cache, "NOP-1234") == nil, "BETS for a book I never joined is ignored")
    Cache.RequestJoin(SteveBookDB.cache, "REQ-1111")
    handlers.BETS("Bookie", { rev = 1, bets = entries }, "REQ-1111")
    check(Cache.GroupBets(SteveBookDB.cache, "REQ-1111") == nil, "BETS for a book that has not approved me is ignored")
    Cache.Forget(SteveBookDB.cache, "REQ-1111")

    -- Opening the tab asks straight away (and shows Loading... until the answer).
    local r0 = nReq()
    findPrefix("All Bets"):Click()
    check(nReq() == r0 + 1, "opening All Bets sends BETS_REQ immediately")
    check(frameWithTextContaining("Loading...") ~= nil, "Loading... until the first BETS arrives")
    ticker(5).fn()
    check(nReq() == r0 + 1, "no second request within 30 s")
    T = T + 29; Cache.MarkPong(SteveBookDB.cache, CODE, T, "Bookie"); ticker(5).fn()
    check(nReq() == r0 + 1, "still none at 29 s")
    T = T + 1; Cache.MarkPong(SteveBookDB.cache, CODE, T, "Bookie"); ticker(5).fn()
    check(nReq() == r0 + 2, "asks again after 30 s")

    -- The answer renders.
    handlers.BETS("Bookie", { rev = 2, bets = entries }, CODE)
    B.Refresh()
    check(frameWithTextContaining("2 open, 1 settled in the last 48h, total at stake 30s") ~= nil, "count header")
    check(frameWithTextContaining("Updated 0s ago") ~= nil, "Updated Ns ago")
    check(frameWithTextContaining("PHI -3.5 -110") ~= nil and frameWithTextContaining("NYG ML +150") ~= nil, "pick text rows")
    check(frameWithTextContaining("Ann") ~= nil and frameWithTextContaining("Bob") ~= nil, "who column")
    -- Placed column: server/west-coast clock via Clock, never the machine's own time zone.
    check(ns.Clock.Label() == "PT" and frameWithTextContaining("Placed (PT)") ~= nil, "header says Placed (PT) without a game clock")
    for _, e in ipairs(entries) do
        check(frameWithTextContaining(ns.Clock.Format(e.at)) ~= nil, "Placed cell shows Clock.Format for " .. e.who)
    end
    check(ns.Clock.Format(entries[3].at):find("%a%a%a %d+ ") ~= nil, "an older bet shows its date")
    GetGameTime = function() return 23, 42 end          -- a realm clock: the label follows Clock.Label()
    B.Refresh()
    check(ns.Clock.Label() == "server" and frameWithTextContaining("Placed (server)") ~= nil, "header says Placed (server) when the game clock is available")
    check(frameWithTextContaining(ns.Clock.Format(entries[1].at)) ~= nil, "cells follow the server clock too")
    GetGameTime = nil
    B.Refresh()
    local mine
    for _, f in ipairs(frames) do local x = rawget(f, "_text"); if type(x) == "string" and x:find("Me", 1, true) and x:find("|cffffd100", 1, true) and x:sub(-2) == "|r" then mine = f end end
    check(mine ~= nil, "the viewer's own rows are highlighted")

    -- Tail: the picks of a bet go on my slip and the window goes to Lines.
    do
        local slip = B.SlipState()
        local tails = {}
        for _, f in ipairs(frames) do if rawget(f, "_text") == "Tail" then tails[#tails + 1] = f end end
        check(#tails >= 3, "every row has a Tail button")
        -- rows: Ann (open, newest), Me (open), Bob (settled)
        check(tails[1]:IsEnabled() and tails[2]:IsEnabled(), "Tail is on for open bets with picks")
        check(not tails[3]:IsEnabled(), "and off for a settled bet")
        tails[1]:Click()
        check(slip.mode == "parlay" and #slip.parlay == 2, "tailing a parlay puts all its legs on the parlay slip")
        check(slip.parlay[1].marketId == 2 and slip.parlay[1].selectionId == 2 and slip.parlay[2].marketId == 3, "the right picks, in order")
        check(slip.parlay[1].odds == b.markets[2].selections[2].odds, "at today's odds (" .. tostring(slip.parlay[1].odds) .. ")")
        check(not findPrefix("Lines"):IsEnabled(), "the window is on the Lines tab")
        check(lastPrint():find("Tailing Ann: 2-leg parlay on your slip", 1, true) ~= nil, "and says what happened: " .. lastPrint())
        findPrefix("All Bets"):Click()
        tails[2]:Click()
        check(slip.mode == "single" and slip.single and slip.single.marketId == 1 and slip.single.selectionId == 1, "tailing a single fills the single slip")
        check(#slip.parlay == 2, "the parlay slip is left as it was")
        check(lastPrint():find("Tailing Me: the pick", 1, true) ~= nil, "single wording")
        -- a game that is gone, and a bet from a bookie that sends no picks
        local before = slip.single
        check(B.Tail({ who = "Zed", status = "accepted", legs = { { m = 99, s = 1 } } }).added == 0, "a vanished game cannot be tailed")
        check(lastPrint():find("Can't tail Zed", 1, true) ~= nil and slip.single == before, "and the slip is untouched")
        check(B.Tail({ who = "Old", status = "accepted" }) == nil and lastPrint():find("newest SteveBook", 1, true) ~= nil, "no picks: the bookie needs an update")
        check(B.Tail({ who = "Done", status = "won" }) == nil and lastPrint():find("settled", 1, true) ~= nil, "a settled bet cannot be tailed")
        ns.Slip.ClearAll(slip); slip.parlay = {}
        findPrefix("All Bets"):Click()
    end
    T = T + 12
    Cache.MarkPong(SteveBookDB.cache, CODE, T, "Bookie")
    B.Refresh()
    check(frameWithTextContaining("Updated 12s ago") ~= nil, "the age counts up")

    -- Other players' text cannot inject colour codes into the list.
    handlers.BETS("Bookie", { rev = 2, bets = { { id = 9, who = "Eve|cffff0000", text = "|cff00ff00hacked|r", stake = 100, status = "won", at = T } } }, CODE)
    B.Refresh()
    check(frameWithTextContaining("||cff00ff00hacked||r") ~= nil and frameWithTextContaining("Eve||cffff0000") ~= nil, "pipes in names and picks are escaped")
    handlers.BETS("Bookie", { rev = 2, bets = entries }, CODE)
    B.Refresh()

    -- Offline: never ask. Online again: ask straight away.
    r0 = nReq()
    b.lastPong = T - 1000
    b.lastHeard = nil                                       -- the bookie's own messages above also count as life signs
    T = T + 40
    ticker(5).fn()
    check(nReq() == r0, "nothing is sent while the book is offline")
    check(frameWithTextContaining("the bookie is offline") ~= nil, "offline note")
    handlers.PONG("Bookie", {}, CODE)
    B.Refresh()
    check(nReq() == r0 + 1, "coming back online asks again")

    -- Empty state.
    handlers.BETS("Bookie", { rev = 3, bets = {} }, CODE)
    B.Refresh()
    check(frameWithTextContaining("No bets yet") ~= nil, "empty state")
    -- Hiding the window sends nothing, even when 30 s pass.
    B.Hide()
    T = T + 100
    Cache.MarkPong(SteveBookDB.cache, CODE, T, "Bookie")
    r0 = nReq()
    check(ticker(5) == nil and nReq() == r0, "nothing is sent while the window is hidden")
    B.Show()
    check(nReq() == r0 + 1, "showing the window on All Bets asks straight away")
    findPrefix("Lines"):Click()
end

-- Hiding the window stops the refresh ticker; showing starts it again.
do
    local t5 = ticker(5)
    B.Hide()
    check(t5.cancelled == true and ticker(5) == nil, "refresh ticker stops while hidden")
    B.Show()
    check(ticker(5) ~= nil, "refresh ticker restarts when shown")
end

-- A failed send is surfaced and not left pending.
do
    local realSend = ns.Comm.Send
    ns.Comm.Send = function() return false, "no channel" end
    B.Select(1, 1)
    stakeBox():SetText("1g")
    findButton("Place Bet"):Click()
    check(next(b.pending) == nil and lastPrint():find("Could not send"), "failed BET_PLACE send is not left pending")
    ns.Comm.Send = realSend
end

-- Views render without error.
for _, tabName in ipairs({ "My Bets", "Balance", "Lines" }) do findPrefix(tabName):Click() end
-- The sport chips filter the board.
check(findButton("NFL") ~= nil and findButton("All") ~= nil, "sport chips")
findButton("All"):Click()

-- Settlement.
local m = market(1, "settled"); m.result = 1
handlers.MARKET("Bookie", { rev = 9, market = m }, CODE)
check(lastPrint():find("settled"), "market settle printed for a market I bet on")
check(b.bets[7].status == "accepted", "MARKET alone does not grade bets")
handlers.SYNC("Bookie", { rev = 10, bookName = "NFL Week 12", markets = { m }, balance = 0,
    bets = { { id = 7, ref = b.bets[7].ref, marketId = 1, selectionId = 1, stake = 2000, odds = -120, status = "won", delta = 1667, settledAt = T } } }, CODE)
check(b.bets[7].status == "won", "SYNC carries the outcome")
handlers.BALANCE("Bookie", { rev = 10, balance = 208333, note = "PHI @ DAL won" }, CODE)
check(b.balance == 208333 and #b.payments == 1 and b.payments[1].amount == 208333, "BALANCE recorded")
findPrefix("Balance"):Click()
findPrefix("My Bets"):Click()

-- Denied.
Cache.RequestJoin(SteveBookDB.cache, "OTH-1111")
-- Before the owner is known, a deny only counts if the sender is the owner the payload names.
handlers.JOIN_DENY("Mallory", { ownerName = "Other", reason = "denied" }, "OTH-1111")
check(Cache.Book(SteveBookDB.cache, "OTH-1111").status == "requested", "forged JOIN_DENY (names someone else) ignored")
handlers.JOIN_DENY("Mallory", { reason = "denied" }, "OTH-1111")
check(Cache.Book(SteveBookDB.cache, "OTH-1111").status == "requested", "JOIN_DENY with no ownerName ignored")
handlers.JOIN_DENY("Other-Realm", { ownerName = "Other", reason = "denied" }, "OTH-1111")
check(Cache.Book(SteveBookDB.cache, "OTH-1111").status == "denied", "genuine JOIN_DENY accepted (realm suffix ignored)")
check(lastPrint():find("denied"), "denial printed")

-- Once JOIN_OK pinned the owner, only they can deny or remove us.
check(Cache.Book(SteveBookDB.cache, CODE).owner == "Bookie", "owner pinned by JOIN_OK")
handlers.JOIN_DENY("Mallory", { ownerName = "Mallory", reason = "removed" }, CODE)
check(Cache.Book(SteveBookDB.cache, CODE).status == "active", "deny from a non-owner who names themselves is ignored after JOIN_OK")
handlers.JOIN_DENY("Bookie", { ownerName = "Mallory", reason = "removed" }, CODE)
check(Cache.Book(SteveBookDB.cache, CODE).status == "active", "deny whose ownerName does not match the sender is ignored")
handlers.JOIN_DENY("Bookie", { ownerName = "Bookie", reason = "removed" }, CODE)
check(Cache.Book(SteveBookDB.cache, CODE).status == "denied", "genuine removal from the pinned owner accepted")
B.Toggle(); B.Toggle()

-- Casino button: hides this window and opens the casino window (looked up at click time).
do
    local casino = findButton("Casino")
    check(casino ~= nil, "Casino button exists")
    B.Show()
    local shown = 0
    casino:Click()   -- ns.UI.Casino not loaded: nothing happens, no error
    ns.UI.Casino = { Show = function() shown = shown + 1 end }
    local f
    for _, fr in ipairs(frames) do
        local sc = rawget(fr, "_scripts")
        if sc and sc.OnShow and sc.OnHide then f = fr end   -- the main window
    end
    check(f ~= nil, "found the bettor window frame")
    B.Show()
    check(f:IsShown(), "bettor window is open before the click")
    casino:Click()
    check(shown == 1, "Casino click calls ns.UI.Casino.Show")
    check(not f:IsShown(), "Casino click hides the bettor window")
    ns.UI.Casino = nil
end

-- Join screen: open books from ns.BookLobby, one Join button per row.
do
    ns.BookLobby = lobby
    lobby.asks, lobby.books = 0, {}
    local subs = lobby.subs
    B.Hide()
    check(Cache.Book(SteveBookDB.cache, "NFL-AAAA") == nil, "lobby test starts with no such book")
    B.Show()            -- the selected book was denied, so the join screen is up
    check(lobby.asks == 1, "opening the join screen asks the lobby (" .. lobby.asks .. ")")
    B.Refresh(); B.Refresh()
    check(lobby.asks == 1, "refreshes don't ask again")
    local empty = frameWithTextContaining("No open books yet. Books show up here when a bookie lists one.")
    check(empty and empty:IsShown(), "empty list shows the note")
    check(frameWithTextContaining("Open books") ~= nil, "title 'Open books'")
    check(frameWithTextContaining("Have a code? Type it here.") ~= nil, "code box is labelled")

    -- Refresh button: asks and redraws.
    findButton("Refresh"):Click()
    check(lobby.asks == 2, "Refresh button asks the lobby")

    lobby.books = {
        { code = "NFL-AAAA", name = "Sunday NFL", owner = "Alice", members = 3, markets = 5, age = 4 },
        { code = "NBA-BBBB", name = "Hoops|cffff0000", owner = "Bob", members = 1, markets = 0, age = 9 },
    }
    check(#subs == 1, "subscribed to the lobby once (" .. #subs .. ")")
    subs[1]()           -- the lobby says the list changed
    local r1 = frameWithTextContaining("Sunday NFL")
    check(r1 and r1._text:find("host Alice", 1, true)
        and r1._text:find("3 members", 1, true) and r1._text:find("5 open markets", 1, true), "row 1 text")
    local r2 = frameWithTextContaining("Hoops||cffff0000")
    check(r2 and r2._text:find("1 member ", 1, true) and r2._text:find("0 open markets", 1, true), "row 2 text, singular and escaped")
    check(empty:IsShown() == false, "empty note hidden with rows")
    check(frameWithTextContaining("Sunday NFL") ~= frameWithTextContaining("Hoops"), "one row each")

    local joins = {}
    for _, f in ipairs(frames) do if rawget(f, "_text") == "Join" then joins[#joins + 1] = f end end
    check(#joins >= 2, "a Join button per row")
    local n = #sent
    joins[1]:Click()
    local req = lastSent("JOIN_REQ")
    check(#sent == n + 1 and req and req.code == "NFL-AAAA", "Join on a row sends JOIN_REQ for that code")
    local bc = Cache.Book(SteveBookDB.cache, "NFL-AAAA")
    check(bc and bc.status == "requested" and SteveBookDB.cache.selected == "NFL-AAAA", "and marks it requested and selected")

    -- The code box still works.
    local codeBox
    for _, f in ipairs(frames) do
        local sc = rawget(f, "_scripts")
        if sc and sc.OnEnterPressed and not sc.OnTextChanged then codeBox = f end
    end
    B.Refresh()
    codeBox:SetText("nba bbbb")
    findButton("Request to join"):Click()
    local req2 = lastSent("JOIN_REQ")
    check(req2 and req2.code == "NBA-BBBB", "typing a code still requests it")
    check(Cache.Book(SteveBookDB.cache, "NBA-BBBB").status == "requested", "typed code is requested")

    -- Closing and reopening the join screen asks again; no BookLobby at all is fine.
    B.Hide(); lobby.asks = 0
    B.Show()
    check(lobby.asks == 1, "reopening the window on the join screen asks again")
    ns.BookLobby = nil
    B.Hide(); B.Show(); B.Refresh()
    check(true, "no ns.BookLobby: join screen still draws")
end

-- Connection status line on the join screen and on "Request sent, waiting".
do
    local calls, answer = {}, { true, "Connected, but Zed has not been heard yet. Are they online?" }
    ns.Comm.Health = function(code, who) calls[#calls + 1] = { code, who }; return answer[1], answer[2] end
    Cache.RequestJoin(SteveBookDB.cache, "HLT-1111")
    Cache.Book(SteveBookDB.cache, "HLT-1111").owner = "Zed"
    SteveBookDB.cache.selected = "HLT-1111"
    B.Hide(); B.Show()
    check(frameWithTextContaining("Waiting for the bookie to approve you") ~= nil, "waiting state is up")
    local line = frameWithTextContaining("has not been heard yet")
    check(line ~= nil and not line._text:find("|cff", 1, true), "healthy line shows in normal colour: " .. tostring(line and line._text))
    local last = calls[#calls]
    check(last and last[1] == "HLT-1111" and last[2] == "Zed", "Health is asked about the waiting book and its owner")

    -- A broken connection turns the line red, and the 5 s refresh ticker picks the change up.
    answer = { false, "Not connected: the SteveBook channel is not working and this character is not in a guild. Run /book net." }
    ticker(5).fn()
    line = frameWithTextContaining("Not connected")
    check(line ~= nil and line._text:find("|cffff5050", 1, true) == 1 and line._text:sub(-2) == "|r", "failing line is red")
    check(not frameWithTextContaining("has not been heard yet"), "old line replaced")

    -- With no book waiting on (code-entry screen) it is the lobby channel that is checked, with no name.
    Cache.Forget(SteveBookDB.cache, "HLT-1111")
    SteveBookDB.cache.selected = nil
    calls = {}
    findButton("+ Join"):Click()
    last = calls[#calls]
    check(last and last[1] == ns.Protocol.LOBBY_CODE and last[2] == nil, "join screen asks about the lobby channel")

    -- No Health (older Comm) or a Health that errors: the screen still draws.
    ns.Comm.Health = nil
    B.Refresh()
    ns.Comm.Health = function() error("boom") end
    B.Refresh()
    check(true, "missing or failing Comm.Health is tolerated")
    ns.Comm.Health = nil
end

-- My own book in my own bettor window: nothing can ever answer a ping (a client does not hear its
-- own messages), so it must not read "offline", must not be pinged, and cannot be joined by code.
do
    local OWN = "OWN-1234"
    ns.Model = { FindByCode = function(d, code) return d.books and d.books[code] end }
    SteveBookDB.books = { [OWN] = { code = OWN, ownerName = "Me" } }
    Cache.RequestJoin(SteveBookDB.cache, OWN)
    Cache.SetMembership(SteveBookDB.cache, OWN, true, "Mine", "Me")       -- left over from an earlier test
    SteveBookDB.cache.selected = OWN
    B.Show()
    local n = #sent
    ticker(30).fn()
    local pinged = false
    for i = n + 1, #sent do if sent[i].t == "PING" and sent[i].code == OWN then pinged = true end end
    check(not pinged, "my own book is not pinged")
    check(frameWithTextContaining("your own book") ~= nil, "my own book is labelled, not 'offline'")
    check(not (frameWithTextContaining("Balance") and frameWithTextContaining("Balance")._text:find("offline", 1, true)),
        "my own book does not say offline")

    -- with loopback on it behaves like any other book (Comm hands the messages back)
    SteveBookDB.loopback = true
    n = #sent
    ticker(30).fn()
    pinged = false
    for i = n + 1, #sent do if sent[i].t == "PING" and sent[i].code == OWN then pinged = true end end
    check(pinged, "with loopback on my own book is pinged like any other")
    SteveBookDB.loopback = nil

    -- and typing my own code on the join screen is refused
    Cache.Forget(SteveBookDB.cache, OWN)
    SteveBookDB.cache.selected = nil
    B.Refresh()
    local codeBox
    for _, f in ipairs(frames) do
        local sc = rawget(f, "_scripts")
        if sc and sc.OnEnterPressed and not sc.OnTextChanged then codeBox = f end
    end
    n = #sent
    codeBox:SetText(OWN)
    findButton("Request to join"):Click()
    check(#sent == n and lastPrint():find("your own book"), "my own code is not sent as a join request")
    SteveBookDB.books = nil
    ns.Model = nil
end

print = print_real
if fails == 0 then print("test_bettor_ui: all passed") else print(fails .. " FAILED"); os.exit(1) end
