# SteveBook — WoW: Forever sportsbook addon (spec v0.1)

A sportsbook that runs entirely inside World of Warcraft: Forever. One player runs a **book**
(the bookie); friends **join** it and bet in-game gold on lines the bookie posts. All bets
run on **credit**: nothing is collected up front, and the addon keeps a running balance per
bettor that gets settled up in gold whenever people feel like it.

"SteveBook" is a working name. Rename freely (addon folder, .toc, SavedVariables, comm prefix).

---

## 1. Roles

### Bookie
- On open, chooses which sportsbook to manage: **create new** or **pick existing** (a bookie
  can run several books).
- Creating a book generates a **join code** (e.g. `NFL-K7Q2`) to share with friends.
- Approves or denies join requests; can remove members.
- Posts markets (moneyline, spread, over/under) with American odds and a close time.
- Can edit odds (affects only new bets), lock, void, and settle markets.
- Sees all bets, exposure per market, and every bettor's balance.
- Records settle-up payments (gold changing hands).
- Imports lines in bulk from a pasted import string (see §7).

### Bettor
- Enters a join code to request access to a book; waits for approval.
- Sees open markets, places bets by clicking a selection and entering a stake.
- Sees their open bets, settled bets, and running balance with the book.
- May belong to more than one book.

---

## 2. Odds and payout math (American odds)

Stakes and balances are stored in **copper** (integer). 1g = 10000c. Display as g/s/c.

Profit on a winning bet:
- odds > 0 (e.g. +150): `profit = floor(stake * odds / 100)`
- odds < 0 (e.g. -110): `profit = floor(stake * 100 / |odds|)`

Outcomes:
- **Win**: bettor balance `+profit`
- **Loss**: bettor balance `-stake`
- **Push** (spread/total lands exactly on the line): `0`
- **Void** (bookie cancels the market or bet): `0`

The odds stored on a bet are the odds **at the moment the bookie accepted it**. Later line
changes never affect existing bets.

Rounding: always floor profit to whole copper. Keep the math in one pure function with tests
(it can be unit-tested outside WoW with plain Lua 5.1).

---

## 3. Credit model

- Every bettor has a **balance** per book. Positive = book owes the bettor; negative = bettor
  owes the book.
- Settlement of a market updates balances immediately.
- **Settle-up**: the bookie records a payment ("Bob paid 250g" or "paid Bob 120g"), which moves
  the balance toward zero. v1 records payments manually from the Ledger tab.
- Optional per-bettor **credit limit** (max negative balance + open risk). Default: none.
  When set, the book rejects bets that would exceed it.
- **Stake limits** (v1 starting values): a stake is a whole number of silver and at most 1g,
  for example 20s, 50s or 1g. The constants live in `Odds.lua` (`MAX_STAKE`, `STAKE_STEP`,
  `StakeCheck`) so the bookie and the bet slip share one rule. Raise them there when the
  group is comfortable.
- Stretch: watch the trade window (trade with a member, money changes hands) and offer
  "Record this as a settle-up payment?" automatically.

---

## 3a. Parlays

A parlay is one stake on 2 to 8 legs (`Odds.MIN_PARLAY_LEGS`, `Odds.MAX_PARLAY_LEGS`). Every leg is a
selection on an open market. There is no payout cap in v1 (a huge hit is a feature). The stake rules
in §3 apply unchanged, and the stake is the amount at risk (credit limits count it like any bet).

- **Price:** multiply each leg's decimal odds; the stored `Bet.odds` is the combined American odds
  (rounded, for display). Profit is computed from the decimal product and floored to whole copper
  (`Odds.ParlayProfit`), never from the rounded American number.
- **Which legs may share a parlay** (`Odds.ParlayConflict`): legs on different games never conflict.
  Within one game (same event and close time) a parlay may hold **one side bet (moneyline or spread)
  plus one total (over or under)**. Rejected: moneyline + spread, two spreads, over + under, and the
  same market twice.
- **Lines:** BET_PLACE carries the spread/total line the bettor saw (per leg for parlays). If the
  market's line moved, the bookie rejects with `odds_changed` plus `currentOdds` and `currentLine`,
  and the slip re-confirms, exactly as for moved odds.
- **Locked-in odds:** each leg keeps the odds at the moment the bookie accepted the parlay. If any
  leg's odds changed since the bettor saw them, the whole parlay is rejected (`odds_changed`, with
  `legIndex`), same as a single bet.
- **Grading** (`Odds.GradeParlay`): a lost leg loses the parlay at once, even while other legs are
  still pending. Otherwise the parlay stays open until every leg is resolved. A push or void leg
  drops out and the rest are priced without it. If nothing won, the result is a push (or void when
  every leg is void). Correcting a market result re-grades every parlay with a leg on it, reversing
  the old ledger effect first, exactly like single bets.
- A game that has started is closed for parlays too: the bookie rejects any parlay with a leg whose
  market is not open (`market_closed`, `legIndex`).

## 3b. Group bets ("All Bets")

Any active member can see what everyone in the book has bet. This is a deliberate loosening of
privacy (the group asked for it): other members' picks and stakes are visible to every member.

- A bettor's **All Bets** tab sends `BETS_REQ` when it opens and again every 30 s while it is shown.
  The bookie answers the asker only with `BETS` (priority BULK), and ignores a member who asks more
  often than every 5 s.
- `BETS.bets` holds open bets plus bets settled in the last 48 hours (`Bookie.GROUP_SETTLED_KEEP`),
  voided bets left out, newest first, at most 60 (`Bookie.GROUP_BETS_MAX`). Entry:
  `{ id, who, text, stake (copper), status, at (placed), win? (open bets: profit if it wins) }`.
  `text` is rendered by the bookie so the client needs no market data (at most 160 bytes; a parlay drops trailing legs and ends ", ..."): a single reads
  "LAL +5.5 -110, LAL @ BOS", a parlay "3-leg parlay +738: LAL +5.5, Over 231.5, MIA ML".
- The bookie window already lists every bet in its Bets tab.

## 4. Data model (bookie's SavedVariables are the source of truth)

Saved data is per character (`SavedVariablesPerCharacter`): a book belongs to the character that
created it, and each character keeps its own bettor cache.

```
Book {
  id, code, name, ownerName, createdAt,
  members = { [playerName] = { status = "pending"|"active"|"removed", joinedAt, creditLimit? } },
  markets = { [marketId] = Market },
  bets    = { [betId] = Bet },
  ledger  = { [playerName] = { balance = copper, payments = { {amount, at, note} } } },
  rev     -- monotonically increasing revision number, bumped on every change
}

Market {
  id, sport, event,           -- e.g. "NFL", "PHI @ DAL"
  type = "moneyline"|"spread"|"total",
  line,                       -- spread (e.g. -3.5 for the first selection) or total (47.5); nil for ML
  selections = { { id, label, odds } },   -- ML/spread: 2 sides; total: Over/Under
  closesAt,                   -- GetServerTime() epoch; betting auto-locks after this
  status = "open"|"locked"|"settled"|"void",
  result,                     -- winning selection id, or "push"
}

Bet {
  id, bettor, marketId, selectionId,   -- a single bet; a parlay has `legs` instead (below)
  legs? = { { marketId, selectionId, odds, status = "pending"|"won"|"lost"|"push"|"void" }, ... },
  stake,                      -- copper
  odds,                       -- locked in at acceptance (a parlay: combined American odds)
  line?,                      -- spread/total: the line at acceptance (a parlay leg carries its own `line`);
                              -- a market's line can move later (import updates), bets keep theirs
  status = "pending"|"accepted"|"rejected"|"won"|"lost"|"push"|"void",
  placedAt, settledAt, rejectReason?
}
```

Bettor clients keep a **cache** of each book they belong to (markets + their own bets +
their balance) so the UI works when the bookie is offline. The cache is replaced on sync.

---

## 5. Networking

Uses addon messages (`C_ChatInfo.SendAddonMessage`), invisible to players' chat.

**Finding the book:** the join code maps to a hidden custom chat channel (e.g.
`gb` + code). Both bookie and bettors join it via `JoinTemporaryChannel`, hide it from all chat
frames, and send addon messages over `CHANNEL`. Bettors never need the bookie's character name.
Fallback if CHANNEL addon messages are restricted in Forever: bettor enters the bookie's name
too and everything goes over addon `WHISPER`.

**Addressed replies:** messages meant for one player (JOIN_OK/DENY, SYNC, BET_ACK/REJECT, BALANCE)
go out on the same hidden channel with the envelope field `to` set to that player's name; every
other client drops them. Addon WHISPERs are not used: in Forever the send call returned success
but the message never arrived. Consequence: other members' clients receive (and ignore) each
other's balances and bets on the wire, which fits the friends-only trust model below.

**Testing alone:** `/book loopback` lets one character act as bookie and bettor of its own book.
`Comm.Send` then also hands each message to the same client's handlers for the other role (the
bettor side appears to the bookie as the member `Loopback`, whom you approve). It is a test aid;
leave it off for real play.

**Compression:** a message over 200 bytes is deflated (LibDeflate, vendored in `Libs/`) and sent
as `ZD1` + encoded bytes before AceComm chunks it. A whole-book SYNC of 90 markets drops from
19.5 KB (about 28 s at the throttle rate) to about 1.5 KB. Clients older than this change cannot
read compressed messages, so everyone in a book must update together.

**Player names:** in Forever the sender of an addon message arrives as "Tuesday lol" or "Steve
Spinebreaker" (a space and a second word) while `UnitName("player")` returns only "Tuesday" or
"Steve". `Comm` reduces every sender and every `to` to the first word (names with a `-Realm` suffix
keep it), so members, owners and addresses are all the short form. Two friends who share a first
name would collide; revisit if that ever happens.

**Authority:** the bookie's client validates everything. Bettor clients only *request*.
(These are friends; clients can be modified, so this is about preventing mistakes and races,
not cheating.)

**Messages** (all carry protocol version + book code):

| Message        | From → To        | Purpose |
|----------------|------------------|---------|
| JOIN_REQ       | bettor → bookie  | Ask to join |
| JOIN_OK / JOIN_DENY | bookie → bettor | Approval result |
| SYNC_REQ       | bettor → bookie  | "Send me current state" (on login, on join, on reconnect) with last known `rev` |
| SYNC           | bookie → bettor  | Markets + that bettor's bets + balance (chunked) |
| MARKET         | bookie → all     | New/updated/locked/settled market |
| BET_PLACE      | bettor → bookie  | marketId, selectionId, stake, odds the bettor saw; or `legs` (parlay, §3a) instead of the three |
| BET_ACK / BET_REJECT | bookie → bettor | Accepted (with final odds) or rejected with reason |
| BALANCE        | bookie → bettor  | Balance changed (settlement or payment) |
| PING / PONG    | either           | Presence, so the bettor UI knows if the book is online |

Rules:
- Reject BET_PLACE if the market is not open, past `closesAt`, the bettor isn't active, the
  stake is ≤ 0 or breaks the stake limits (§3, reason `bad_stake`), it breaks the credit limit, or the odds the bettor saw differ from current odds
  (return current odds so the UI can re-confirm).
- **Games that have started or finished are closed to betting and hidden from bettors.**
  `closesAt` is the game's start. From that moment (and whenever a market is locked, settled or
  voided) the bookie rejects BET_PLACE with `market_closed`, and the bettor's Lines view does not
  list the market. A market past `closesAt` can never be reopened or have its close time extended;
  only Settle and Void remain. Bettors keep only the closed markets their own bets belong to
  (for My Bets). The bookie may still Lock a market early, and Unlock it again before `closesAt`.
- Bets can only be placed while the bookie is online (Place Bet disabled when no recent PONG).
- **SYNC size:** the bettor's balance is absolute, so old history is not needed for correctness.
  A SYNC carries the bettor's open bets, their settled bets from the last 14 days, and the
  markets those bets (and parlay legs) refer to, plus all open markets. Older settled bets drop out of My Bets.
  Measured size: 10 settled 3-leg parlays is about 11.5 KB (roughly 17 s at the throttle rate); if that
  hurts in play, cap the settled bets per SYNC or send settlement deltas instead.
- **Trust model:** friends only. Clients can be modified. The bettor pins the first sender whose
  JOIN_OK names themself as the owner; after that, only that sender's bookie messages count.
  A third party who answers a pending join request before the real bookie could still be
  pinned. There is no shared secret in v1; if that matters later, derive a key from the join code.
- Messages over 255 bytes must be chunked; sends must be throttled. Use AceComm-3.0 +
  AceSerializer-3.0 (or LibSerialize + LibDeflate) rather than hand-rolling, vendored into
  `Libs/`.
- Addon messaging inside instances may be restricted under the Midnight/Forever API. Design for
  town/open world; fail gracefully (queue or show "book unreachable").

---

## 6. UI

Slash command `/book` opens the window; minimap button optional (LibDBIcon).

**Bookie window** (after picking a book) — tabs:
- **Markets**: a table (Game, Market, two inline odds boxes, Closes, Status, At risk, actions) plus
  the Import panel on its right (paste box, live summary, Import N / Clear). Odds boxes save on
  Enter or click-away and only affect new bets. Toolbar: "New market", "Lock all", and open stakes
  (with the part that sits in parlays). Started games offer only Settle (winner prompt with Void).
  "At risk" counts single-bet stakes only; parlays appear in the toolbar total and the Bets tab.
- **Bets**: filterable list of all bets (by market, bettor, status). A parlay shows a headline
  plus one line per leg with its own status; Void voids the whole parlay.
- **Members**: pending requests (approve/deny), active members, credit limits, remove.
- **Ledger**: balance per bettor (who owes whom), record payment, payment history.
- **Import**: the same panel with a line-by-line preview (NEW / UPDATE old->new / SKIP / ERROR).
- Header shows book name and join code (click to copy).

**Bettor window**:
- **Join** screen: enter join code → "Request sent, waiting for approval".
- Book picker if in multiple books.
- **Lines**: an odds board. Sport chips (NBA / NFL / All); a header row Game / Spread / Total /
  Moneyline; one block per game with two rows (away, home) of clickable odds cells; started games
  are hidden. A slip panel on the right switches between **Single** and **Parlay (n)**: stake,
  to-win, Place Bet / Place Parlay. Shows book online/offline.
- **My Bets**: open and settled (last 14 days), with results; parlays list each leg and its status.
- **Balance**: current balance with the book and recent changes.

Chat output only for notable events (bet accepted/rejected, market settled, you were approved).

---

## 7. Import string (for the future off-WoW line-pulling script)

Addons can't read files or reach the internet at runtime, so an external script will print a
text block the bookie pastes into the Import tab. Format, one market per line, `|`-separated:

```
ML|NFL|PHI @ DAL|2026-11-26T16:30-05:00|PHI:-150|DAL:+130
SPREAD|NFL|PHI @ DAL|2026-11-26T16:30-05:00|-3.5|PHI:-110|DAL:-110
TOTAL|NFL|PHI @ DAL|2026-11-26T16:30-05:00|47.5|Over:-110|Under:-110
```

- Spread line applies to the first selection (the other side is the opposite).
- Lines starting with `#` are comments. Invalid lines are reported, not imported.
- Close times need a UTC offset or `Z`. Names cannot contain `|` (it is a WoW text escape).
- **Importing again updates lines.** A line is matched to an existing market of the same type,
  event and close time (sides matched by label). If exactly one spread (or total) exists for that
  game, its line and odds are updated in place; if several exist (deliberate alternate lines) the
  line is part of the match and an unmatched line becomes a new market. Moneylines match on
  type, event and time. A matching **open** market with different odds is updated (existing bets
  keep their locked line and odds, and bettors get the new market); identical lines are skipped as
  duplicates; locked, settled, void or started markets are never touched. Games that have already
  started are skipped, not errors. Same game but different side names is an error (not guessed).
  The preview reports new / updated / skipped (started or closed) / duplicate / errors.
- Optionally wrap the whole block with a `GB1:` prefix + base64 later, if pasting raw text proves
  fragile. Not supported yet: such a block is reported as unsupported.

---

## 8. Not in v1 (notes for later)

- **Parlays** moved into v1: see §3a.
- Off-WoW line-pulling script (outputs the §7 format).
- Automatic settle-up detection from trades.
- Live in-game notifications when a line moves.
- Teasers, props, futures.

---

## 9. Milestones

1. Skeleton: .toc, SavedVariables, `/book`, book create/pick, join code generation.
2. Odds/payout module + plain-Lua unit tests.
3. Comms layer: hidden channel, AceComm, JOIN/SYNC/PING. Test with two accounts or a friend.
4. Bookie Markets tab + MARKET broadcast; bettor Lines view.
5. Bet slip, BET_PLACE/ACK/REJECT, My Bets.
6. Settlement, ledger, balances, payments.
7. Import tab.
8. Polish, README, GitHub release for WowUp.

---

## 10. Practical notes

- Gold never moves automatically; the addon is a ledger.
- Keep stakes modest: Forever runs aggressive anti-RMT monitoring ("Temporary Economy Holds"),
  and large unexplained gold flows between characters could draw attention.
- If a friend stiffs the book, Blizzard won't recover it. Credit limits exist for a reason.
