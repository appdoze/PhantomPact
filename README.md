<p align="center">
  <img src="art/phantom-pact-banner-1300x372.png" alt="Phantom Pact: Online Co-op for Phantom Blade Zero" width="100%">
</p>

# Phantom Pact: online co-op for Phantom Blade Zero

Phantom Pact adds online co-op to **Phantom Blade Zero**. Two players each run their own game and keep their own
save, and Phantom Pact links the two worlds: you see each other, fight the same enemies, take on bosses as a team,
share loot and dust, and rest at bells together. The host's world leads, and your partner joins in.

**Download:** [latest release](https://github.com/yhsharaf/PhantomPact/releases/latest) · **Install and play:**
[INSTALL.md](INSTALL.md) · **Found a bug?** [Open an issue](https://github.com/yhsharaf/PhantomPact/issues/new/choose)

## Features

- See your partner's Soul live, with their moves, attacks, dodges and hit reactions
- Shared enemies in both worlds, with shared health, posture and executions
- Your partner's hits count in the host's world, so you can fight the same enemy together
- Shared boss fights: the boss health bar and arena fog walls for both players
- Shared loot and dust: what either player picks up or earns goes to both
- Shared resting: rest at a bell and enemies respawn for both

## Quick start

1. Install [UE4SS for Phantom Blade Zero](https://www.nexusmods.com/phantombladezero/mods/5), [Python 3](https://www.python.org/downloads/) and [Tailscale](https://tailscale.com) (both players).
2. Unzip the release and double-click `1 - Install Phantom Pact.bat`.
3. Start the game and load your saves, the host first.
4. Host: `2 - Host.bat`. Partner: `3 - Join friend.bat` with the host's Tailscale IP.

Early release, 2 players. Connecting is over Tailscale for now; Steam joining is planned.

## Ground rules

- **No DRM bypassing.** Phantom Pact never touches Denuvo or patches the game executable. Everything loads
  through UE4SS and runs inside the normal, legitimately owned game.
- Each player needs their own copy of the game.
- Nothing here contains game files or assets.

## For developers

| Path | What it is |
|---|---|
| [mod/PBZCoop/](mod/PBZCoop/) | UE4SS Lua mod: `coop.lua` (online sync), `pbz.lua` (game adapter: enemies, health, moves, bosses, items), `main.lua` (loader, commands) |
| [net/pbzcoop_net.py](net/pbzcoop_net.py) | Relay over UDP (Tailscale): snapshots + reliable events; host, client, echo, record/replay |
| [net/test_pbzcoop_net.py](net/test_pbzcoop_net.py) | Relay tests: `python -I net\test_pbzcoop_net.py` |
| [net/pbzcoop_bot.py](net/pbzcoop_bot.py) | Bot partner for live tests without a second PC |
| [release/](release/) | The double-click `.bat` files that ship at the top of the zip |
| [tools/pbz-coop.ps1](tools/pbz-coop.ps1) | Starts co-op on a running game (`-Role host`, `-Role client -Peer <ip>`, `-Stop`) |
| [tools/install-mod.ps1](tools/install-mod.ps1) | Installs the mod into the game's UE4SS `Mods` folder (finds the game through Steam) |
| [tools/pbz-e2e.ps1](tools/pbz-e2e.ps1) | End-to-end test: two copies of the game on one PC, PASS/FAIL per feature |
| [tools/pbz-selftest.ps1](tools/pbz-selftest.ps1) | Starts two copies with `-allowmultipleinstances` plus relays; `-Stop` |
| [tools/make-release.ps1](tools/make-release.ps1) | Builds `dist\PhantomPact-<version>.zip` |
| [docs/COOP_GUIDE.md](docs/COOP_GUIDE.md) | What syncs and how: protocol, enemy matching, tests and results |
| [docs/RECON_NOTES.md](docs/RECON_NOTES.md) | Classes, functions and data tables found in the game |

## Credits

- **Vercadi**, for UE4SS for Phantom Blade Zero, which made modding this game possible
- **The UE4SS team** ([RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS))
- **S-GAME and the game's developers** for Phantom Blade Zero

*Fan-made mod, not affiliated with or endorsed by S-GAME.*
