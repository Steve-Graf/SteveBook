# SteveBook

An in-game sportsbook for World of Warcraft: Forever. One player runs a book, friends join
with a code and bet gold on credit. The addon is a ledger; gold never moves automatically.
See [SPEC.md](SPEC.md) for the design.

## Install (WowUp)

1. In WowUp choose **Install from URL** and paste this repository's GitHub URL.
2. WowUp installs the newest tagged release. Releases are made by pushing a `v*` tag.

While the repository is private, WowUp's install-from-URL will not be able to see releases. Use the
clone-and-link method below until the repository is made public.

## Develop and test on another machine

Fast loop: clone the repo on the machine that runs WoW and link the `SteveBook/` folder into
`Interface/AddOns/` (a directory junction on Windows: `mklink /J`). After that, `git pull` and
`/reload` in game is all it takes. Tagging a release is only needed for WowUp.

## Testing alone

`/book loopback` lets one character be both the bookie and a bettor of its own book. Create a book
(`/book new <name>`), turn loopback on, open `/bet`, join your own code, then approve the member
named **Loopback** in `/bookie`. Turn it off again (`/book loopback`) for real play.

## Odds display

`/book ratio` toggles the bettor window and chat between American odds (-110, +150, the default) and
ratios (profit per 1 staked: -500 is 0.2x, +150 is 1.5x). The bookie window always uses American odds.

## Settling from a paste

In `/bookie`, the Import panel also settles. Run `python3 tools/nba_lines.py --results` (it prints one
`FINAL|NBA|LAL @ BOS|<time>|LAL:104|BOS:109` line per finished game), paste the output into the panel
and press **Settle N markets**: each game's moneyline, spreads and totals are settled from the score.
Games that are not in your book, already settled, or not started yet are skipped, so pasting the same
block twice is harmless. You can type a line by hand too (the close time may be left out). Format: SPEC §7.

Or let the wowbook site pick the games from your book: press **Export games** in the Import panel (the
waiting games appear selected: Ctrl+C), paste them into the wowbook page's **Settle my book** mode, copy
the string it gives back, and paste that into the Import panel (Clear first) and press **Settle**.

## Minimap icon

A coin button on the minimap: left-click opens the bet window, right-click the bookie window, drag
to move it. `/book icon` hides or shows it.

## Joining a sportsbook

In the bet window, **Join** shows the list of open books: click Join next to the one you want and wait
for the bookie to approve you. A bookie can take their book off the list with `/book hide` (friends can
still join with the code). Typing a code still works.

## If a friend cannot see your table or book

Everyone with the casino open sits in one hidden "lobby" channel. The number you see in a debug line
(for example `channel #7`) is only your own slot; a friend's number can differ and it is still the
same channel. Run `/book lobby` on both sides: it says whether you are in the channel and who has been
heard there, with the version each of them runs (a friend who opens `/casino` and presses Join a table should show up on your list). If
you never hear each other, make sure you both run the latest version (from v0.4.0 on), and that you
are on the same realm group and faction; custom channels do not cross realms.

## Guild messages

From v0.8.0 messages can also go through guild chat (a second path that needs no channel), so friends
in your guild can reach each other even when the hidden channel fails. The game lets an addon send only about one message a second, so guild is the main path and the channel is added only for someone not reachable by guild. If the game refuses a message, chat says so and `/book net` shows the totals per path. `/book guild` turns it off or on, `/book net test` sends a test message down each path and prints the game's own answer (the normal send path never reports failures),
and `/book net` shows what was last heard on each path.

## If a channel shows as "disabled"

`/book net` lists each SteveBook channel and says whether it works. A channel can hold a slot number
and still be listed by the game as disabled (the server never let the character in): every send to it
fails with `InvalidChannel` and nothing is heard, so friends never see tables or join requests. From
v0.7.3 the addon notices this, leaves the channel and joins again on its own. The cause found in Forever: taking a channel off every chat window (what SteveBook did up to v0.7.2 to hide it) leaves it disabled; v0.7.4 stops doing that and puts such a channel back on the main chat window. Some channels stayed stuck even then, so from v0.7.5 the channel names carry an extra letter (`SBNLBYCSNO` instead of `SBLBYCSNO`) and the old name is left when found. Everyone has to be on v0.7.5 or later to reach each other. To check by hand:
`/run print(GetChannelList())` prints slot, name and disabled for every channel, and
`/run local id=GetChannelName("SBNLBYCSNO") print(id, C_ChatInfo.SendAddonMessage("SteveBook","t","CHANNEL",id))`
prints the slot and a result (0 is success, 7 is `InvalidChannel`).

## Casino (roulette and blackjack)

`/casino` opens the casino (also the Casino button in the bet window). Every casino window opens in the middle of the screen (drag it if you like). Pick a game and **Host a
table**, or **Join a table** from the list of open tables (a code still works for a table that is not
listed). Players sit down only when the host lets them in, and they have no chips until the host adds
some (for example after they pay in gold). Chips are the table's own credit, separate from the
sportsbook. Roulette: players click bets onto a bet slip, set the stakes and place them all at once (with "same as last round"), and the host spins. Blackjack: players bet, the host
deals, and everyone plays the dealer in turn (hit, stand, double, split). Both blackjack windows have a **Mini** button (saved): the host's shrinks to the dealer's cards, the status lines and Deal; the player's to the dealer's cards, their own hand, Hit/Stand/Double/Split and a one-line bet strip (Full brings everything back). Closing a window does not leave the table or stop the game; a player can leave and ask to rejoin (their chips are kept), and chat tells you when it is your turn in blackjack. **Auto: off / ON** in the host window (roulette
and blackjack) switches on automatic rounds: 20 seconds after the first bet of a round the bets lock and the
spin or hand starts by itself (later bets do not move the clock, and you can still press Spin or Deal sooner).
Players see "Bets lock in 14 s". To try a table alone, turn
on `/book loopback`, host a table and join it from the list.

**Play against the house.** A bookie can open a house (`/casino house`, or **My house** in the casino window):
friends then see **Play vs <bookie>** next to each game and play roulette or blackjack alone against the bookie's bank,
any time, even while the bookie is offline. Blackjack deals the moment the wager is in; in roulette the player places
bets and presses **Spin**. The game runs on the player's own client; it counts their results and sends the totals to
the bookie whenever both are online (the bookie must have been online once, so the friend's client knows the bet
limits). The bookie's **House** window lists each player's rounds, amount wagered and result, and what is owed; **Settle**
(click twice) records that you paid or were paid, in game. Players see "Steve owes you 5s" in their window. Because the
game runs on the player's side this is trust-based, like the rest of the credit system: the bookie's client only
rejects totals that cannot be true. Set the bet limits in the House window.

## Tests

Pure-logic modules are tested outside the game with plain Lua:

    for t in tests/test_*.lua; do lua5.1 "$t"; done

## In-game checks (APIs not verified in WoW: Forever)

Run these on the Windows machine and report anything that prints `nil` or `false`:

    /dump select(4, GetBuildInfo())                 -- Interface number (the .toc uses 16001)
    /dump JoinTemporaryChannel, GetChannelName, LeaveChannelByName
    /dump ChatFrame_RemoveChannel, ChatFrame_AddMessageEventFilter, Ambiguate
    /dump C_ChatInfo.RegisterAddonMessagePrefix, C_Timer.NewTicker, GetNormalizedRealmName
    /run for _,a in ipairs({{"Frame","BasicFrameTemplateWithInset"},{"Frame","BasicFrameTemplate"},{"Button","UIPanelButtonTemplate"},{"EditBox","InputBoxTemplate"}}) do print(a[2], pcall(CreateFrame,a[1],nil,UIParent,a[2])) end
    /run local e=CreateFrame("EditBox",nil,UIParent,"InputBoxTemplate") for _,m in ipairs({"HighlightText","SetFocus","SetEnabled","ClearAllPoints","SetMaxLetters"}) do print(m, e[m]~=nil) end e:Hide()
    /run local e=CreateFrame("EditBox",nil,UIParent) local t=UIParent:CreateTexture() print(e.SetMultiLine~=nil, e.SetFontObject~=nil, t.SetColorTexture~=nil) e:Hide()
    /dump ChatFrame_AddMessageEventFilter, ChatFrame_RemoveChannel, ChatFrameUtil, NUM_CHAT_WINDOWS
    /dump securecallfunction, GetFramerate, table.wipe, Enum.SendAddonMessageResult, C_ChatInfo.SendAddonMessageLogged, issecretvalue
    /run print(Ambiguate("Bob-"..GetNormalizedRealmName(), "none"), Ambiguate("Bob-Other Realm", "none"))   -- expect: Bob  and  Bob-OtherRealm
    /run local e=CreateFrame("EditBox",nil,UIParent) print(e.HasFocus~=nil, e.SetJustifyH~=nil, GameTooltip~=nil and GameTooltip.SetOwner~=nil, GameFontNormalSmall~=nil) e:Hide()
    /run print(GetGameTime(), date("!%H:%M", GetServerTime()))   -- realm hour, minute, then the UTC time; the All Bets "Placed" column uses the difference
    /run print(Minimap and Minimap:GetWidth(), GetCursorPosition ~= nil, math.atan2 ~= nil)   -- the minimap icon needs all three
    /run print(GameFontNormalHuge~=nil, GameFontHighlightLarge~=nil, GameFontNormalLarge~=nil, GameFontNormalSmall~=nil, GameFontHighlightSmall~=nil, UIParent:CreateFontString().SetJustifyV~=nil)   -- the casino windows use these fonts

Test messaging in a city or the open world only (addon messages are restricted in instances).
Saved data is per character (`SavedVariablesPerCharacter`), so each character has its own books and
bettor cache.
