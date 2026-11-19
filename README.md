# SteveBook

An in-game sportsbook for World of Warcraft: Forever. One player runs a book, friends join
with a code and bet gold on credit. The addon is a ledger; gold never moves automatically.
See [SPEC.md](SPEC.md) for the design.

## Install (WowUp)

1. In WowUp choose **Install from URL** and paste this repository's GitHub URL.
2. WowUp installs the newest tagged release. Releases are made by pushing a `v*` tag.

## Develop and test on another machine

Fast loop: clone the repo on the machine that runs WoW and link the `SteveBook/` folder into
`Interface/AddOns/` (a directory junction on Windows: `mklink /J`). After that, `git pull` and
`/reload` in game is all it takes. Tagging a release is only needed for WowUp.

## Tests

Pure-logic modules are tested outside the game with plain Lua:

    for t in tests/test_*.lua; do lua5.1 "$t"; done
