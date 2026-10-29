# Phantom Pact 1.0: online co-op for Phantom Blade Zero

(The mod's folder and log tag are `PBZCoop`.)

**Found a bug?** Open an issue with the bug-report template (it asks for your `UE4SS.log` and
`net_status.txt`), or post in the Nexus Mods Bugs tab.

Play the campaign with a friend: you see each other as a second Hun, fight the same enemies and bosses, and
share loot, dust and bell rests. The host's game decides enemies, bosses and deaths; the friend's game follows.

Fan-made, unofficial. Each player needs their own copy of PBZ on Steam. No game files are modified or shared.

## What you need (both players)

1. **Phantom Blade Zero** (Steam), launched once without mods and played into gameplay.
2. **UE4SS for Phantom Blade Zero** from Nexus Mods (by Vercadi, nexusmods.com/phantombladezero/mods/5): put
   `dwmapi.dll` and the `ue4ss` folder next to the real game exe, `...\steamapps\common\PBZ\platform\steam\`.
3. **Python 3** (python.org), with "Add python to PATH" ticked during install.
4. **Tailscale** (tailscale.com), both signed in to the same tailnet; or any network where the friend can reach
   the host's UDP port 47800.

## Install PBZCoop (both players)

Unzip this package anywhere, open PowerShell in that folder and run:

    .\tools\install-mod.ps1 -GameWin64 'D:\SteamLibrary\steamapps\common\PBZ\platform\steam'

(use your own Steam library path). It copies the mod into `ue4ss\Mods\PBZCoop` and enables it in `mods.txt`.
Start the game: the UE4SS console should show `[PBZCoop] Loaded (instance 1, v1.0.0, ...)`.

## Play

1. Both: start PBZ and load your save. Be on the same map, near each other.
2. Host: `.\tools\pbz-coop.ps1 -Role host`
3. Friend: `.\tools\pbz-coop.ps1 -Role client -Peer <host's Tailscale IP>`
   (the host's IP is shown in the Tailscale app, it starts with 100.)
4. Stop: `.\tools\pbz-coop.ps1 -Stop` (on both PCs).

Add `-GameWin64 '<your path>\PBZ\platform\steam'` to these commands if your library isn't
`D:\SteamLibrary`.

## What's shared

- Each other's character, moving, attacking, dodging and reacting to hits.
- Enemies and bosses: position, health, posture (executions), deaths; boss health bar and arena fog walls.
- Loot picked up by either player goes to both; dust earned by either player goes to both.
- Resting at a bell respawns regular enemies for both players.

## Good to know

- If the friend's character disappears, the other player is down or on another map; it comes back.
- The host should lead into new areas and boss arenas; the friend follows.
- Not shared: cutscenes, dialogue, spending dust.
- Link status: `ue4ss\Mods\PBZCoop\net_status.txt` shows `connected=yes` and the round-trip time.

## Troubleshooting

- **"Phantom Blade Zero is already running"** when testing two copies on one PC: start the second copy with
  the game's own launch option `-allowmultipleinstances` (`tools\pbz-selftest.ps1` does this).
- **No `[PBZCoop] Loaded` line**: check `ue4ss\Mods\mods.txt` contains `PBZCoop : 1` (install-mod adds it).
- **Never press Ctrl+R (UE4SS hot reload) while co-op is on**: it can crash the game. Restart the game instead.
- **`connected=no`**: check both are on Tailscale, the IP is right, and Windows Firewall allows Python on
  private networks.
