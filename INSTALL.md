# Phantom Pact 1.0: online co-op for Phantom Blade Zero

(The mod's folder and log tag are `PBZCoop`.)

**Found a bug?** Post in the Bugs tab of the mod's Nexus Mods page with what happened (host or client, which
area or boss), your `ue4ss\UE4SS.log` and `ue4ss\Mods\PBZCoop\net_status.txt`, or open an issue at
https://github.com/yhsharaf/PhantomPact/issues (Bug report template).

Play the campaign with a friend: you see each other as a second Soul, fight the same enemies and bosses, and
share loot, dust and bell rests. The host's game decides enemies, bosses and deaths; the friend's game follows.

Fan-made, unofficial. Each player needs their own copy of PBZ on Steam. No game files are modified or shared.

## What you need (both players)

1. **Phantom Blade Zero** (Steam), launched once without mods and played into gameplay.
2. **UE4SS for Phantom Blade Zero** from Nexus Mods (by Vercadi, nexusmods.com/phantombladezero/mods/5): put
   `dwmapi.dll` and the `ue4ss` folder next to the real game exe, `...\steamapps\common\PBZ\platform\steam\`.
3. **Python 3** (python.org), with "Add python to PATH" ticked during install.
4. **Tailscale** (tailscale.com), both signed in to the same tailnet; or any network where the friend can reach
   the host's UDP port 47800.

## Install Phantom Pact (both players)

1. Unzip this package anywhere (for example your Desktop).
2. Double-click **`1 - Install Phantom Pact.bat`**. It finds the game through Steam, copies the mod into
   `ue4ss\Mods\PBZCoop` and turns it on in `mods.txt`.
3. Start the game. The UE4SS console shows `[PBZCoop] Loaded (instance 1, v1.0.0, ...)`.

## Play

1. Both: start the game and load your save. Be on the same map, near each other.
2. Host: double-click **`2 - Host.bat`**.
3. Friend: double-click **`3 - Join friend.bat`** and type the host's Tailscale IP (shown in the host's
   Tailscale app, it starts with 100.).
4. To stop: **`Stop co-op.bat`** on both PCs.

If the game isn't found (an unusual Steam setup), run the scripts from PowerShell with
`-GameWin64 '<Steam library>\steamapps\common\PBZ\platform\steam'`, e.g.
`powershell -ExecutionPolicy Bypass -File .\tools\install-mod.ps1 -GameWin64 '...'`.

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
  the game's own launch option `-allowmultipleinstances`.
- **No `[PBZCoop] Loaded` line**: check `ue4ss\Mods\mods.txt` contains `PBZCoop : 1` (install-mod adds it).
- **Never press Ctrl+R (UE4SS hot reload) while co-op is on**: it can crash the game. Restart the game instead.
- **`connected=no`**: check both are on Tailscale, the IP is right, and Windows Firewall allows Python on
  private networks.
