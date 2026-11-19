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
- Stretch: watch the trade window (trade with a member, money changes hands) and offer
  "Record this as a settle-up payment?" automatically.

---

## 4. Data model (bookie's SavedVariables are the source of truth)

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
  id, bettor, marketId, selectionId,
  stake,                      -- copper
  odds,                       -- locked in at acceptance
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
| BET_PLACE      | bettor → bookie  | marketId, selectionId, stake, odds the bettor saw |
| BET_ACK / BET_REJECT | bookie → bettor | Accepted (with final odds) or rejected with reason |
| BALANCE        | bookie → bettor  | Balance changed (settlement or payment) |
| PING / PONG    | either           | Presence, so the bettor UI knows if the book is online |

Rules:
- Reject BET_PLACE if the market is not open, past `closesAt`, the bettor isn't active, the
  stake is ≤ 0, it breaks the credit limit, or the odds the bettor saw differ from current odds
  (return current odds so the UI can re-confirm).
- Bets can only be placed while the bookie is online (Place Bet disabled when no recent PONG).
- Messages over 255 bytes must be chunked; sends must be throttled. Use AceComm-3.0 +
  AceSerializer-3.0 (or LibSerialize + LibDeflate) rather than hand-rolling, vendored into
  `Libs/`.
- Addon messaging inside instances may be restricted under the Midnight/Forever API. Design for
  town/open world; fail gracefully (queue or show "book unreachable").

---

## 6. UI

Slash command `/book` opens the window; minimap button optional (LibDBIcon).

**Bookie window** (after picking a book) — tabs:
- **Markets**: list with status, close time, exposure; "New market" form (sport, event, type,
  line, selections with odds, close time); actions: edit odds, lock, void, settle (pick result).
- **Bets**: filterable list of all bets (by market, bettor, status).
- **Members**: pending requests (approve/deny), active members, credit limits, remove.
- **Ledger**: balance per bettor (who owes whom), record payment, payment history.
- **Import**: multi-line edit box to paste an import string; preview; confirm.
- Header shows book name and join code (click to copy).

**Bettor window**:
- **Join** screen: enter join code → "Request sent, waiting for approval".
- Book picker if in multiple books.
- **Lines**: open markets grouped by sport/event; click a selection → bet slip (stake,
  shows potential profit) → Place Bet. Shows book online/offline.
- **My Bets**: open and settled, with results.
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
- Optionally wrap the whole block with a `GB1:` prefix + base64 later, if pasting raw text proves
  fragile.

---

## 8. Not in v1 (notes for later)

- **Parlays**: multi-leg bets; combined decimal odds = product of each leg's decimal odds,
  converted back to American; a push/void leg drops out of the parlay. Needs a Bet model with
  `legs = {}`. Design the Bet table so this can be added without migration pain.
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
