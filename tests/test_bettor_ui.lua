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
for _, f in ipairs({ "Odds", "Protocol", "Cache" }) do assert(loadfile("SteveBook/" .. f .. ".lua"))("SteveBook", ns) end
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
local function market(id, status)
    return { id = id, sport = "NFL", event = "PHI @ DAL", type = "spread", line = -3.5, status = status or "open", closesAt = T + 3600,
        selections = { { id = 1, label = "PHI", odds = -110 }, { id = 2, label = "DAL", odds = -110 } } }
end
handlers.SYNC("Bookie", { rev = 2, bookName = "NFL Week 12", markets = { market(1) }, bets = {}, balance = 0,
    payments = {}, creditLimit = 50000 }, CODE)
check(b.markets[1] and b.name == "NFL Week 12" and b.creditLimit == 50000, "SYNC applied")
check(Cache.IsOnline(SteveBookDB.cache, CODE, T), "SYNC from the bookie counts as online")

B.Refresh()
-- Slip.
B.OpenSlip(CODE, 1, 1, -110)
local stake = nil
for _, f in ipairs(frames) do if script(f, "OnEnterPressed") and script(f, "OnTextChanged") then stake = f end end
check(stake ~= nil, "slip stake box exists")
stake:SetText("25g")
local place = findButton("Place Bet")
check(rawget(place, "_enabled") == false, "stake over 1g disabled")
stake:SetText("20s 10c")
check(rawget(place, "_enabled") == false, "stake with loose copper disabled")
stake:SetText("1g 1s")
check(rawget(place, "_enabled") == false, "1g 1s disabled")
stake:SetText("20s")
check(place and rawget(place, "_enabled") == true, "Place Bet enabled with online book and valid stake")
stake:SetText("nonsense")
check(rawget(place, "_enabled") == false, "Place Bet disabled for bad stake")
stake:SetText("20s")
b.lastPong = T - 1000
B.Refresh()
check(rawget(place, "_enabled") == false, "Place Bet disabled when no recent PONG")
Cache.MarkPong(SteveBookDB.cache, CODE, T, "Bookie")
B.Refresh()
check(rawget(place, "_enabled") == true, "Place Bet re-enabled by PONG")
place:Click()
local bp = lastSent("BET_PLACE")
check(bp and bp.p.stake == 2000 and bp.p.odds == -110 and bp.p.marketId == 1 and bp.p.selectionId == 1 and type(bp.p.ref) == "string", "BET_PLACE payload")
check(next(b.pending) == bp.p.ref, "pending recorded under ref")

-- Reject with changed odds re-opens the slip.
handlers.BET_REJECT("Bookie", { ref = bp.p.ref, reason = "odds_changed", currentOdds = -120 }, CODE)
check(lastPrint():find("rejected") and lastPrint():find("%-120"), "odds_changed printed")
check(next(b.pending) == nil and #b.rejected == 1, "rejection moved out of pending")

-- Place again and get ACK.
B.OpenSlip(CODE, 1, 1, -120)
stake:SetText("20s")
place:Click()
bp = lastSent("BET_PLACE")
check(bp.p.odds == -120, "second BET_PLACE uses new odds")
handlers.BET_ACK("Bookie", { ref = bp.p.ref, bet = { id = 7, ref = bp.p.ref, bettor = "me", marketId = 1, selectionId = 1,
    stake = 2000, odds = -120, status = "accepted", placedAt = T }, balance = 0 }, CODE)
check(b.bets[7] and next(b.pending) == nil and lastPrint():find("accepted"), "ACK recorded")

-- Time passes while the window is open: the game starts.
do
    check(ticker(5) ~= nil, "window refreshes on a 5s ticker while shown")
    B.OpenSlip(CODE, 1, 1, -120)
    stake:SetText("10s")
    check(rawget(place, "_enabled") == true, "slip enabled before the game starts")
    local nBets = 0
    for _, e in ipairs(sent) do if e.t == "BET_PLACE" then nBets = nBets + 1 end end
    local startsIn = b.markets[1].closesAt - T
    T = T + startsIn + 1                  -- the game starts; nothing else happens yet
    Cache.MarkPong(SteveBookDB.cache, CODE, T, "Bookie")
    ticker(5).fn()                         -- the refresh tick
    check(rawget(place, "_enabled") == false, "slip disabled once the game has started")
    check(frameWithTextContaining("This game has started.") ~= nil, "slip says why: This game has started.")
    local before = #sent
    place:Click()
    check(#sent == before, "Place Bet does nothing after the start time")
    T = T - startsIn - 1
    Cache.MarkPong(SteveBookDB.cache, CODE, T, "Bookie")
    B.Refresh()
end

-- My Bets copes with a bet whose market is not in the cache, and says the history window.
do
    b.bets[900] = { id = 900, marketId = 404, selectionId = 1, stake = 100, odds = -110, status = "lost", placedAt = T - 5, delta = -100 }
    findButton("My Bets"):Click()
    check(frameWithTextContaining("Game no longer listed") ~= nil, "bet row without a market names a placeholder")
    check(frameWithTextContaining("last 14 days") ~= nil, "My Bets says it shows the last 14 days")
    b.bets[900] = nil
    findButton("Lines"):Click()
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
    B.OpenSlip(CODE, 1, 1, -120)
    stake:SetText("1g")
    place:Click()
    check(next(b.pending) == nil and lastPrint():find("Could not send"), "failed BET_PLACE send is not left pending")
    ns.Comm.Send = realSend
end

-- Views render without error.
for _, tabName in ipairs({ "My Bets", "Balance", "Lines" }) do findButton(tabName):Click() end

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
findButton("Balance"):Click()
findButton("My Bets"):Click()

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

print = print_real
if fails == 0 then print("test_bettor_ui: all passed") else print(fails .. " FAILED"); os.exit(1) end
