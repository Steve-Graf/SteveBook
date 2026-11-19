# SteveBook

World of Warcraft: Forever addon: an in-game sportsbook where one player runs a book and
friends bet gold on credit. **Read SPEC.md first**; it is the source of truth for features,
data model, protocol, and milestones. Update it when decisions change.

## About the user
Developer, comfortable with git and code. Plays WoW: Forever with friends. Prefers practical,
minimal solutions; chat output is fine where a UI isn't needed. Previously shipped
`Steve-Graf/BlessingCount` (small addon, distributed to friends through WowUp from GitHub).

## Target client and API
- WoW: Forever uses the **modern (Midnight / 12.x) UI engine and API**, not Classic-era APIs.
- Interface number: beta was `16001`. Confirm in game with `/dump select(4, GetBuildInfo())`.
- Midnight-era restrictions apply: "secret values" (check with `issecretvalue`), no
  `COMBAT_LOG_EVENT_UNFILTERED`, `GetSpellInfo` removed (use `C_Spell.*`), addon
  communication restricted inside instances. This addon is non-combat, so mostly unaffected,
  but test comms in town and the open world.
- Do not invent API functions. If unsure whether something exists in Forever, say so and
  suggest a `/dump` or `/run` check the user can do in game.
- Addons cannot read files or access the network at runtime.

## Conventions
- Lua 5.1 (WoW's dialect). One addon namespace table (`local ADDON, ns = ...`); no globals
  except SavedVariables and slash command registrations.
- Money in integer copper everywhere; format only for display.
- Keep pure logic (odds math, validation, serialization) in files with no WoW API calls so it
  can be unit-tested with plain `lua5.1`/`busted` outside the game.
- Vendored libs live in `Libs/` (Ace3: AceComm-3.0, AceSerializer-3.0, CallbackHandler,
  LibStub; optional LibDBIcon). Load them via the .toc.

## Layout (planned)
```
SteveBook/            -- the addon folder that ships (zip root)
  SteveBook.toc
  Libs/
  Core.lua           -- init, SavedVariables, slash commands
  Odds.lua           -- pure payout math
  Model.lua          -- books, markets, bets, ledger
  Comm.lua           -- channel + AceComm protocol
  UI/Bookie.lua
  UI/Bettor.lua
tests/               -- plain-Lua tests for pure modules
.github/workflows/release.yml   -- tag v* → zip SteveBook/ → GitHub release (for WowUp)
SPEC.md
README.md
```

## Release
Same flow as BlessingCount: push a `v*` tag; the workflow zips the `SteveBook/` folder and
attaches it to a GitHub release. WowUp's "Install from URL" needs a tagged release with a zip.
