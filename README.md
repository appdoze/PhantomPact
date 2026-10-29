<p align="center">
  <img src="art/phantom-pact-banner-1300x372.png" alt="Phantom Pact: Online Co-op for Phantom Blade Zero" width="100%">
</p>

# Phantom Pact: online co-op for Phantom Blade Zero (mod folder: PBZCoop)

A fan-made co-op mode for **Phantom Blade Zero** (S-GAME, Unreal Engine 5, PC release **October 29, 2026**).
The game ships single-player only and uses Denuvo anti-tamper.

> This folder was originally created for an Onimusha: Way of the Sword idea. The target changed to
> Phantom Blade Zero because nobody is building co-op for it yet.

## Goal

Two players fight through the campaign together, in this order:

1. **Local co-op**: a second swordsman on the same PC with a second gamepad.
2. **Online via Steam Remote Play Together / Parsec**: this works as soon as stage 1 works.
3. **True online co-op**: our own netcode, with the host deciding enemy AI and hits.

## Ground rules

- **No DRM bypassing.** We never touch Denuvo or patch the game executable. Everything loads through
  UE4SS's proxy DLL and runs inside the normal, legitimately owned game.
- Each player needs their own copy of the game.
- We release nothing that contains game files or assets.

## Layout

| Path | What it is |
|---|---|
| [INSTALL.md](INSTALL.md) | **For players**: requirements, install, how to play, troubleshooting (ships in the release zip) |
| [tools/make-release.ps1](tools/make-release.ps1) | Builds `dist\PBZCoop-<version>.zip` for players |
| [tools/pbz-e2e.ps1](tools/pbz-e2e.ps1) | One-command end-to-end test with two copies (host + client), PASS/FAIL per feature |
| [docs/COOP_GUIDE.md](docs/COOP_GUIDE.md) | **How to play online co-op**, what syncs (moves, enemies, bosses, items), protocol, test results |
| [docs/PBZ_READINESS.md](docs/PBZ_READINESS.md) | Launch-day guide: facts, Wukong lessons, procedure, recon targets |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Phases, milestones and what "done" means for each |
| [docs/UE4SS_SETUP.md](docs/UE4SS_SETUP.md) | How to install UE4SS on a practice game and on PBZ |
| [docs/LAUNCH_DAY_CHECKLIST.md](docs/LAUNCH_DAY_CHECKLIST.md) | Step-by-step plan for October 29 |
| [docs/RECON_NOTES.md](docs/RECON_NOTES.md) | Where we record discovered classes, functions and offsets |
| [mod/PBZCoop/](mod/PBZCoop/) | UE4SS Lua mod: `main.lua` (recon tools, local P2, commands), `coop.lua` (online sync), `pbz.lua` (PBZ adapter: enemies, health, moves, items) |
| [tools/pbz-coop.ps1](tools/pbz-coop.ps1) | Start co-op on a running game: `-Role host`, `-Role client -Peer <ip>`, solo `echo`/`loop`; `-Stop` |
| [tools/install-mod.ps1](tools/install-mod.ps1) | Copies the mod into a game's UE4SS `Mods` folder |
| [tools/game-driver.ps1](tools/game-driver.ps1) | Drives a running game: restart, click, keys, screenshots, mod commands, log |
| [tools/pbz-setup.ps1](tools/pbz-setup.ps1) | One-shot PBZ launch-day setup; `-Disable` / `-Enable` toggles UE4SS |
| [tools/pbz-selftest.ps1](tools/pbz-selftest.ps1) | Two copies of PBZ on this PC + relays (Blood Pact-style self-test); `-Stop` |
| [net/pbzcoop_net.py](net/pbzcoop_net.py) | Online relay over Tailscale (UDP): snapshots + reliable events; `host`, `client`, or solo `echo` |
| [net/test_pbzcoop_net.py](net/test_pbzcoop_net.py) | Relay loopback tests: `python -I net\test_pbzcoop_net.py` |
| [net/pbzcoop_bot.py](net/pbzcoop_bot.py) | Bot friend for live tests without a second PC (plays the client side, fights the host's enemies) |
| `dumps/` | UE4SS class/object dumps per game version (git-ignored) |
