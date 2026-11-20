-- The blackjack engine. Run from repo root: luajit tests/test_blackjack_table.lua
local ns = {}
for _, f in ipairs({ "Odds", "Roulette", "Blackjack", "Protocol", "Model", "Casino", "BlackjackTable" }) do assert(loadfile("SteveBook/" .. f .. ".lua"))("SteveBook", ns) end
local C, E, B, P = ns.Casino, ns.BlackjackTable, ns.Blackjack, ns.Protocol
local fails = 0
local function eq(got, want, label)
    if got ~= want then fails = fails + 1; print(("FAIL: %s (got %s, want %s)"):format(label, tostring(got), tostring(want))) end
end
E.RESHUFFLE_BELOW = 0                       -- tests rig the shoe
local NOW = 1000
local seed = 0
local function rand(n) seed = seed + 11; return (seed % n) + 1 end

local function newTable(players)
    local db = {}
    local t = assert(C.Create(db, { game = "blackjack", name = "BJ" }, "Host", NOW, rand))
    for i, name in ipairs(players or {}) do
        C.RequestJoin(t, name, NOW + i); C.Admit(t, name, 10000, NOW + i)
    end
    return t
end
-- Rig the next cards. Deal order: every player's first card, dealer up, every player's second card, dealer hole, then draws.
local function rig(t, cards) t.bj.shoe = cards; t.bj.pos = 1 end
local function wager(t, name, amount, ref)
    return C.PlaceBet(t, name, t.round, { kind = "wager", amount = amount }, ref or ("w" .. name))
end

local t = newTable({ "Ann" })
eq(t.code:match("^BJK%-%w%w%w%w$") ~= nil, true, "blackjack codes start BJK: " .. t.code)
eq(t.zero, nil, "no wheel on a blackjack table"); eq(t.bj.phase, "betting", "betting phase"); eq(t.status, "betting", "status betting")
eq(C.Engines.blackjack, E, "the engine is registered")

-- wagers
local ann = t.members.Ann
local w = assert(wager(t, "Ann", 1000)); eq(w.kind, "wager", "wager entry"); eq(ann.balance, 9000, "wager taken from chips")
eq(select(2, wager(t, "Ann", 500, "again")), "bad_bet", "one wager per round")
local again, _, rep = wager(t, "Ann", 1000); eq(again, w, "retry returns the same wager"); eq(rep, true, "flagged as a repeat")
eq(select(2, C.PlaceBet(t, "Zed", 1, { kind = "wager", amount = 100 }, "z")), "not_seated", "strangers cannot bet")
eq(C.ClearBets(t, "Ann", 1), 1000, "take it back"); eq(ann.balance, 10000, "chips returned")
eq(select(2, C.PlaceBet(t, "Ann", 1, { kind = "red", amount = 100 }, "k")), "bad_bet", "only wagers at a blackjack table")
eq(select(2, C.PlaceBet(t, "Ann", 1, { kind = "wager", amount = 150 }, "k")), "bad_bet", "whole silver")
local _, why, extra = C.PlaceBet(t, "Ann", 1, { kind = "wager", amount = 20000 }, "k"); eq(why, "max_bet", "max"); eq(extra, 10000, "limit")
_, why, extra = C.PlaceBet(t, "Ann", 1, { kind = "wager", amount = 10000 }, "k2"); eq(why, nil, "1g is fine")
C.ClearBets(t, "Ann", 1)
t.members.Ann.balance = 500
_, why, extra = C.PlaceBet(t, "Ann", 1, { kind = "wager", amount = 1000 }, "k3"); eq(why, "no_balance", "not enough chips"); eq(extra, 500, "balance reported")
t.members.Ann.balance = 10000
eq(select(2, E.Deal(t, nil, NOW)), "no_bets", "cannot deal without a wager")
eq(select(2, C.PlaceBet(t, "Ann", 9, { kind = "wager", amount = 100 }, "k4")), "round_closed", "stale round")

-- public state while betting
wager(t, "Ann", 1000)
local pub = E.Public(t)
eq(pub.phase, "betting", "public phase"); eq(#pub.hands, 1, "the wager is public"); eq(pub.hands[1].name, "Ann", "whose"); eq(pub.hands[1].hands[1].bet, 1000, "how much")

-- a plain win: Ann K+Q (20), dealer 9 up + 8 hole (17)
rig(t, { "KS", "9H", "QD", "8C" })
local ok, info = E.Deal(t, nil, NOW); eq(ok, true, "deal"); eq(info.dealerBlackjack, nil, "no dealer blackjack")
eq(t.status, "playing", "playing"); eq(t.bj.turn.name, "Ann", "Ann acts"); eq(t.bj.turn.hand, 1, "first hand")
eq(t.bj.deadline, NOW + E.TURN_SECONDS, "turn timer set")
pub = E.Public(t)
eq(#pub.dealer.cards, 1, "only the up card is public"); eq(pub.dealer.cards[1], "9H", "which"); eq(pub.dealer.hidden, true, "hole hidden"); eq(pub.dealer.value, nil, "no total while hidden")
eq(#pub.hands[1].hands[1].cards, 2, "players' cards are public"); eq(pub.hands[1].hands[1].value, 20, "value shown"); eq(pub.turn, "Ann", "turn shown")
for _, c in ipairs(pub.dealer.cards) do if c == "8C" then fails = fails + 1; print("FAIL: the hole card leaked") end end
eq(select(2, E.Act(t, "Ann", 5, "stand", NOW)), "round_closed", "stale round")
eq(select(2, E.Act(t, "Zed", t.round, "stand", NOW)), "not_your_turn", "not the player's turn")
eq(select(2, E.Act(t, "Ann", t.round, "dance", NOW)), "bad_action", "bad action")
eq(E.Act(t, "Ann", t.round, "stand", NOW), true, "stand")
eq(t.status, "dealer", "dealer phase"); eq(t.bj.hole, false, "hole card turned over")
pub = E.Public(t); eq(#pub.dealer.cards, 2, "both dealer cards are public now"); eq(pub.dealer.value, 17, "value 17")
local res = assert(E.FinishDealer(t, NOW + 2))
eq(res.dealer.total, 17, "dealer stood on 17"); eq(res.results[1].net, 1000, "Ann won 10s"); eq(res.results[1].hands[1].outcome, "win", "outcome")
eq(ann.balance, 9000 + 2000, "paid 2x the bet back"); eq(#t.members.Ann.bets, 0, "the chips are settled")
eq(t.lastResult.round, 1, "result round")
-- the finished round stays on the table for a few seconds
eq(t.status, "results", "results are on show"); eq(t.round, 1, "the round number holds until betting reopens"); eq(t.bj.phase, "results", "phase")
eq(select(2, wager(t, "Ann", 1000, "early")), "round_closed", "no bets while the results show")
pub = E.Public(t)
eq(pub.phase, "results", "public phase"); eq(#pub.dealer.cards, 2, "the dealer's cards stay face up"); eq(pub.hands[1].hands[1].outcome, "win", "the outcome is shown")
eq(pub.hands[1].hands[1].win, 2000, "with what came back"); eq(pub.nextAt, NOW + 2 + E.RESULTS_SECONDS, "and when the next round opens")
eq(pub.turn, nil, "nobody's turn")
eq(select(2, E.Act(t, "Ann", 1, "hit", NOW)), "round_closed", "no decisions during the results")
eq(select(2, E.Deal(t, nil, NOW)), "not_betting", "cannot deal during the results")
eq(E.NextRound(t, NOW + 7), true, "the pause ends"); eq(t.round, 2, "next round"); eq(t.status, "betting", "betting again")
eq(#t.bj.order, 0, "the table is clear"); eq(E.Public(t).phase, "betting", "public phase is betting again")
eq(select(2, E.NextRound(t, NOW)), "not_results", "nothing to do twice")

-- natural blackjack pays 3:2, no turn
wager(t, "Ann", 1000, "n1")
rig(t, { "AS", "9H", "KD", "8C" })
E.Deal(t, nil, NOW)
eq(t.bj.hands.Ann[1].natural, true, "natural"); eq(t.bj.hands.Ann[1].state, "blackjack", "state blackjack")
eq(t.status, "dealer", "no decisions: straight to the dealer"); eq(t.bj.turn, nil, "no turn")
res = E.FinishDealer(t, NOW)
eq(res.results[1].hands[1].outcome, "blackjack", "blackjack"); eq(res.results[1].net, 1500, "3:2")
eq(#res.dealer.cards, 2, "the dealer did not draw against a natural")

-- dealer blackjack (peek): player loses, a player blackjack pushes
local t2 = newTable({ "Ann", "Bob" })
wager(t2, "Ann", 1000); wager(t2, "Bob", 1000)
rig(t2, { "KS", "AD", "AS", "KH", "KD", "TC" })      -- Ann K+A? see below
-- deal order: Ann c1=KS, Bob c1=AD, dealer up=AS, Ann c2=KH, Bob c2=KD, dealer hole=TC  -> Ann KS+KH (20), Bob AD+KD (blackjack), dealer AS+TC (blackjack)
ok, info = E.Deal(t2, nil, NOW)
eq(info.dealerBlackjack, true, "the dealer peeks and has blackjack"); eq(t2.status, "dealer", "straight to the result"); eq(t2.bj.hole, false, "revealed")
res = E.FinishDealer(t2, NOW)
local by = {}; for _, r in ipairs(res.results) do by[r.name] = r end
eq(by.Ann.hands[1].outcome, "lose", "20 loses to a dealer blackjack"); eq(by.Ann.net, -1000, "Ann loses her bet")
eq(by.Bob.hands[1].outcome, "push", "blackjack pushes"); eq(by.Bob.net, 0, "Bob gets his bet back")
eq(t2.members.Bob.balance, 10000, "Bob's chips are whole")

-- hit, bust
local t3 = newTable({ "Cy" })
wager(t3, "Cy", 1000)
rig(t3, { "TS", "9H", "6D", "7C", "KH" })            -- Cy 10+6=16, dealer 9+7=16, then Cy hits K
E.Deal(t3, nil, NOW)
eq(E.Act(t3, "Cy", 1, "hit", NOW), true, "hit"); eq(t3.bj.hands.Cy[1].state, "bust", "26 busts")
eq(t3.status, "dealer", "all busted: dealer's turn"); res = E.FinishDealer(t3, NOW)
eq(res.results[1].net, -1000, "bust loses"); eq(#res.dealer.cards, 2, "the dealer does not draw when everyone busted")
-- hit to 21 stands automatically
local t4 = newTable({ "Di" })
wager(t4, "Di", 1000)
rig(t4, { "5S", "9H", "6D", "7C", "TH", "KD" })      -- Di 5+6=11, hits TH -> 21 auto stand; dealer 16 draws K -> bust
E.Deal(t4, nil, NOW); E.Act(t4, "Di", 1, "hit", NOW)
eq(t4.bj.hands.Di[1].state, "stand", "5+6+10 is 21 and stands")
eq(t4.status, "dealer", "moves on at 21")
res = E.FinishDealer(t4, NOW)
eq(res.dealer.bust, true, "dealer 16 draws and busts"); eq(res.results[1].hands[1].outcome, "win", "win"); eq(res.results[1].net, 1000, "paid")

-- double down
local t5 = newTable({ "Ed" })
wager(t5, "Ed", 1000)
rig(t5, { "5S", "9H", "6D", "8C", "TH" })            -- Ed 11, dealer 17; double draws TH -> 21
E.Deal(t5, nil, NOW)
eq(E.Act(t5, "Ed", 1, "double", NOW), true, "double"); local ed = t5.members.Ed
eq(ed.balance, 10000 - 2000, "a second stake is taken"); eq(t5.bj.hands.Ed[1].bet, 2000, "the bet doubled"); eq(#t5.bj.hands.Ed[1].cards, 3, "one card"); eq(t5.bj.hands.Ed[1].state, "stand", "stands after")
res = E.FinishDealer(t5, NOW); eq(res.results[1].net, 2000, "doubled win pays 20s"); eq(ed.balance, 8000 + 4000, "chips")
-- cannot double on three cards, or without chips
local t6 = newTable({ "Flo" })
wager(t6, "Flo", 1000)
rig(t6, { "2S", "9H", "3D", "8C", "2H", "9S" })
E.Deal(t6, nil, NOW); E.Act(t6, "Flo", 1, "hit", NOW)
eq(select(2, E.Act(t6, "Flo", 1, "double", NOW)), "bad_action", "no double on three cards")
local t7 = newTable({ "Gus" })
t7.members.Gus.balance = 1500
wager(t7, "Gus", 1000)
rig(t7, { "5S", "9H", "6D", "8C", "TH" })
E.Deal(t7, nil, NOW)
eq(select(2, E.Act(t7, "Gus", 1, "double", NOW)), "no_balance", "not enough chips to double"); eq(t7.bj.turn.name, "Gus", "still his turn")

-- split
local t8 = newTable({ "Hal" })
wager(t8, "Hal", 1000)
rig(t8, { "8S", "9H", "8D", "TC", "3H", "KD", "2C" })   -- Hal 8,8; dealer 9,T=19; splits: second hand gets 3H, first gets KD -> 8+K=18, 8+3=11
E.Deal(t8, nil, NOW)
eq(E.Act(t8, "Hal", 1, "split", NOW), true, "split")
local hal = t8.members.Hal
eq(#t8.bj.hands.Hal, 2, "two hands"); eq(hal.balance, 8000, "a second stake")
eq(#t8.bj.hands.Hal[1].cards, 2, "one new card each"); eq(#t8.bj.hands.Hal[2].cards, 2, "second hand too")
eq(t8.bj.turn.hand, 1, "play the first hand")
eq(select(2, E.Act(t8, "Hal", 1, "split", NOW)), "bad_action", "no re-splitting")
eq(E.Act(t8, "Hal", 1, "stand", NOW), true, "stand the first"); eq(t8.bj.turn.hand, 2, "then the second")
eq(E.Act(t8, "Hal", 1, "stand", NOW), true, "stand the second"); eq(t8.status, "dealer", "dealer")
res = E.FinishDealer(t8, NOW)
eq(#res.results[1].hands, 2, "two hands in the result"); eq(res.results[1].net, -2000, "both hands lost to 19")
-- split aces: one card each, then straight to the dealer, and 21 is not a blackjack
local t9 = newTable({ "Ivy" })
wager(t9, "Ivy", 1000)
rig(t9, { "AS", "9H", "AD", "8C", "KH", "5S" })      -- Ivy A,A; dealer 9,8=17; splits: second gets KH(21), first gets 5S -> A+5=16
E.Deal(t9, nil, NOW)
E.Act(t9, "Ivy", 1, "split", NOW)
eq(t9.status, "dealer", "split aces take one card and stop")
eq(t9.bj.hands.Ivy[1].state, "stand", "first ace stands"); eq(t9.bj.hands.Ivy[2].state, "stand", "second ace stands")
res = E.FinishDealer(t9, NOW)
local outcomes = {}
for i, h in ipairs(res.results[1].hands) do outcomes[i] = h.outcome end
eq(outcomes[1], "lose", "A+5 loses to 17"); eq(outcomes[2], "win", "A+K after a split is a plain 21: 1:1"); eq(res.results[1].net, 0, "net is zero: one hand won, one lost")
-- cannot split unlike cards
local t10 = newTable({ "Jo" })
wager(t10, "Jo", 1000); rig(t10, { "8S", "9H", "9D", "8C" }); E.Deal(t10, nil, NOW)
eq(select(2, E.Act(t10, "Jo", 1, "split", NOW)), "bad_action", "8 and 9 do not split")

-- two players, turn order, timer, skip
local t11 = newTable({ "Kim", "Lee" })
wager(t11, "Lee", 1000); wager(t11, "Kim", 1000)
rig(t11, { "TS", "9D", "7H", "8C", "9S", "TD" })   -- order by join time: Kim, Lee. Kim T+9? deal: Kim c1=TS, Lee c1=9D, up=7H, Kim c2=8C, Lee c2=9S, hole=TD
E.Deal(t11, nil, NOW)
eq(t11.bj.order[1], "Kim", "seat order follows who sat first"); eq(t11.bj.turn.name, "Kim", "Kim first")
eq(select(2, E.Act(t11, "Lee", 1, "stand", NOW)), "not_your_turn", "Lee must wait")
eq(E.Tick(t11, NOW + 10), nil, "no timeout yet")
eq(E.Tick(t11, NOW + E.TURN_SECONDS), "Kim", "Kim is stood when the timer runs out"); eq(t11.bj.turn.name, "Lee", "Lee's turn")
eq(t11.bj.hands.Kim[1].state, "stand", "stood")
eq(t11.bj.deadline, NOW + E.TURN_SECONDS + E.TURN_SECONDS, "a fresh timer")
eq(E.Skip(t11, NOW + 31), "Lee", "the host can skip"); eq(t11.status, "dealer", "everyone has acted")
eq(E.Skip(t11, NOW), nil, "nothing to skip in the dealer phase")
res = E.FinishDealer(t11, NOW)
eq(#res.results, 2, "both players settled"); eq(res.results[1].name, "Kim", "in seat order")

-- a player removed mid-turn
local t12 = newTable({ "Max", "Nan" })
wager(t12, "Max", 1000); wager(t12, "Nan", 1000)
rig(t12, { "TS", "9D", "7H", "8C", "9S", "TD" })
E.Deal(t12, nil, NOW)
eq(C.Kick(t12, "Max"), true, "kick Max on his turn")
eq(t12.members.Max.balance, 10000, "his chips came back"); eq(t12.bj.turn.name, "Nan", "it is Nan's turn now"); eq(#t12.bj.order, 1, "one seat left")
eq(C.Leave(t12, "Nan"), true, "the last player leaves"); eq(t12.status, "betting", "an empty round is cancelled"); eq(t12.members.Nan.balance, 10000, "chips back")
eq(t12.bj.phase, "betting", "phase reset")

-- closing and recovering
local t13 = newTable({ "Oz" })
wager(t13, "Oz", 1000); rig(t13, { "TS", "9D", "7H", "8C", "9S" }); E.Deal(t13, nil, NOW)
E.Act(t13, "Oz", 1, "double", NOW)
eq(t13.members.Oz.balance, 8000, "two stacks out")
C.Recover({ casino = { tables = { [t13.code] = t13 } } })
eq(t13.status, "betting", "recovered"); eq(t13.members.Oz.balance, 10000, "every stack came back (wager and double)")
wager(t13, "Oz", 1000); rig(t13, { "TS", "9D", "7H", "8C" }); E.Deal(t13, nil, NOW)
C.Close(t13)
eq(t13.status, "closed", "closed"); eq(t13.members.Oz.balance, 10000, "closing returns the stacks")
eq(select(2, wager(t13, "Oz", 1000, "late")), "round_closed", "no wagers at a closed table")

-- shuffling: a short shoe is replaced before a deal
do
    E.RESHUFFLE_BELOW = 60
    local t14 = newTable({ "Pat" })
    t14.bj.shoe = { "AS" }; t14.bj.pos = 1
    wager(t14, "Pat", 1000)
    local _, inf = E.Deal(t14, nil, NOW)
    eq(inf.shuffled, true, "a fresh shoe is shuffled in"); eq(#t14.bj.shoe, 52 * 6, "six decks")
    eq(E.Public(t14).shoe > 52 * 6 - 12, true, "the shoe count is public")
    E.RESHUFFLE_BELOW = 0
end

-- messages built from a blackjack table validate
do
    local t15 = newTable({ "Quin" })
    wager(t15, "Quin", 1000); rig(t15, { "TS", "9D", "7H", "8C" }); E.Deal(t15, nil, NOW)
    local function valid(type_, payload)
        local env, err = P.Wrap(type_, t15.code, payload)
        if not env then fails = fails + 1; print("FAIL: " .. type_ .. " invalid: " .. tostring(err)) end
    end
    valid("TBL_STATE", C.StateMessage(t15))
    E.Act(t15, "Quin", 1, "stand", NOW); E.FinishDealer(t15, NOW)
    valid("TBL_RESULT", C.ResultMessage(t15))
    valid("TBL_STATE", C.StateMessage(t15))            -- the results state, with outcomes
    E.NextRound(t15, NOW + 5)
    -- Handle: TBL_ACT through the generic dispatcher
    wager(t15, "Quin", 1000); rig(t15, { "TS", "9D", "7H", "8C" }); E.Deal(t15, nil, NOW)
    local out, ev = C.Handle(t15, "Quin", "TBL_ACT", { ref = "a1", round = t15.round, action = "stand" }, NOW)
    eq(out[1].type, "TBL_PLAYER", "an accepted action answers with the player's chips"); eq(ev[1].kind, "act", "act event")
    out = C.Handle(t15, "Quin", "TBL_ACT", { ref = "a2", round = t15.round, action = "hit" }, NOW)
    eq(out[1].type, "TBL_BET_REJECT", "a refused action is rejected"); eq(out[1].payload.ref, "a2", "with its ref")
    valid("TBL_BET_REJECT", out[1].payload)
end

if fails == 0 then print("blackjack_table: all passed") else os.exit(1) end
