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

Test messaging in a city or the open world only (addon messages are restricted in instances).
Saved data is per character (`SavedVariablesPerCharacter`), so each character has its own books and
bettor cache.
