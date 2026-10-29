# Nexus Mods page draft: Phantom Pact

- **Game:** Phantom Blade Zero
- **Name:** Phantom Pact - Online Co-op
- **Version:** 1.0.0
- **Category:** Gameplay (or Miscellaneous)
- **Author:** TheCodesAreReal
- **Summary (≤ 350 chars):** Play Phantom Blade Zero with a friend online. You see each other's Hun and fight the same enemies and bosses, and you share loot, dust and bell rests. The host's world decides enemies and deaths. Fan-made, two players, UE4SS Lua mod.
- **File:** `dist/PhantomPact-1.0.0.zip`, main file, "Phantom Pact 1.0.0"
- **Requirements:** UE4SS for Phantom Blade Zero (Vercadi) as a Nexus requirement; off-site: Python 3 and Tailscale
- **Media:** `art/nexus/` (banner 1300x372 as the header, the cover as the primary image, then the multiplayer card and screenshots 01–06)
- **Tags:** Co-op, Multiplayer, Gameplay

## Description (BBCode)

```
[center][size=6][b]PHANTOM PACT[/b][/size]
[size=4]Online co-op for Phantom Blade Zero - 2 players[/size][/center]

Phantom Blade Zero is single-player. Phantom Pact lets a friend join your world: two Huns, one campaign.

[size=4][b]What's shared[/b][/size]
[list]
[*]Each other's character: moving, attacking, dodging, reacting to hits
[*]Enemies and bosses: position, health, posture (executions) and deaths
[*]Boss health bar and arena fog walls for both players
[*]Loot picked up by either player goes to both; dust earned by either goes to both
[*]Resting at a bell respawns regular enemies for both players
[/list]

[size=4][b]Requirements (both players)[/b][/size]
[list=1]
[*]Phantom Blade Zero on Steam (each player needs their own copy)
[*][url=https://www.nexusmods.com/phantombladezero/mods/5]UE4SS for Phantom Blade Zero[/url] by Vercadi
[*][url=https://www.python.org/downloads/]Python 3[/url] (tick "Add python to PATH")
[*][url=https://tailscale.com/]Tailscale[/url], both on the same tailnet
[/list]

[size=4][b]Install[/b][/size]
Unzip anywhere, open PowerShell in that folder and run:
[code].\tools\install-mod.ps1 -GameWin64 '<Steam library>\steamapps\common\PBZ\platform\steam'[/code]
The UE4SS console should show [i][PBZCoop] Loaded (instance 1, v1.0.0, ...)[/i].

[size=4][b]Play[/b][/size]
[list=1]
[*]Both: start the game and load your save, on the same map near each other
[*]Host: [code].\tools\pbz-coop.ps1 -Role host[/code]
[*]Friend: [code].\tools\pbz-coop.ps1 -Role client -Peer <host's Tailscale IP>[/code]
[*]Stop: [code].\tools\pbz-coop.ps1 -Stop[/code]
[/list]
Full guide: INSTALL.md in the download.

[size=4][b]Good to know[/b][/size]
[list]
[*]The host leads into new areas and boss arenas; the friend follows
[*]Not shared yet: cutscenes, dialogue, spending dust
[*][b]Never press Ctrl+R (UE4SS hot reload) while co-op is on[/b]: it can crash the game
[*]No game files are modified or shared. Fan-made and unofficial; not affiliated with S-GAME
[/list]

[size=4][b]Found a bug?[/b][/size]
This is the first release, and bug reports are very welcome. Post in the [b]Bugs[/b] tab with:
[list]
[*]what happened, host or client, which area or boss
[*][i]PBZ\platform\steam\ue4ss\UE4SS.log[/i] (both players if you can)
[*][i]ue4ss\Mods\PBZCoop\net_status.txt[/i]
[/list]

[size=4][b]Tested[/b][/size]
Two copies of the game linked on one PC: players see each other, the client's hits land in the host's world, boss bar and kills sync, and bell rests, dust and loot are shared (13/13 automated checks).
```
