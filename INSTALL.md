# Phantom Pact 1.1.1: online co-op for Phantom Blade Zero

Play the campaign with a friend: you see each other as a second Soul, fight the same enemies and bosses, and
share loot, dust and bell rests. The host's world decides enemies, bosses and deaths; the guest's world follows.

Fan-made, unofficial. Each player needs their own copy of the game on Steam. No game files are modified or shared.

**Found a bug?** Post in the Bugs tab on Nexus Mods or open an issue at
https://github.com/yhsharaf/PhantomPact/issues, with what happened (host or guest, which area or boss) and your
`ue4ss\UE4SS.log`.

## What you need (both players)

1. **Phantom Blade Zero** on Steam.
2. **UE4SS for Phantom Blade Zero** by Vercadi (Nexus Mods), installed in `PBZ\platform\steam`.
3. **Python 3** from python.org, with "Add python to PATH" ticked during install.
4. **Tailscale** (tailscale.com), both signed in to the same network.

## Install (both players)

1. Open the game folder: Steam > right-click the game > Manage > Browse local files.
2. Extract everything in the zip into that folder (the `PBZ` folder) and say yes to merging folders.
   The mod lands in `platform\steam\ue4ss\Mods\PBZCoop`.
3. Open `platform\steam\ue4ss\Mods\PBZCoop\PhantomPact.ini` in Notepad:
   - **Host:** change `Role = Guest` to `Role = Host`
   - **Guest:** set `HostAddress` to the host's Tailscale IP (it starts with 100.; the host sees it in the
     Tailscale app)
4. Start the game and load your saves, the host first. Co-op starts by itself once you're in the world.

The UE4SS console shows `Phantom Pact Host: co-op on` (or Guest), and
`ue4ss\Mods\PBZCoop\net_status.txt` shows `connected=yes` once you're linked.

- **Updating:** extract the new version over the old one, then set `Role` / `HostAddress` again.
- **Playing alone:** set `Role = Off`.
- **Uninstalling:** delete the `platform\steam\ue4ss\Mods\PBZCoop` folder.

## Co-op difficulty

Like Elden Ring, enemies and bosses get tougher while your partner is with you: 150% health and 130% posture by
default. Change `CoopEnemyHealth` / `CoopEnemyPosture` in `PhantomPact.ini` (percent; 100 = normal). Both
players should use the same numbers.

## PvP (duels)

Both players set `PvP = On` in `PhantomPact.ini`. Your partner becomes an opponent you can fight:

- Their attacks hit you through the game's own combat: **block** (hold the guard button) costs posture,
  a well-timed **parry** (tap guard just before the hit) costs nothing, and dodges work as usual.
- A parry is rewarded like against a boss: the attacker staggers and loses posture (`PvPParryPosture`, default 60).
- The loser dies for real and respawns at their bell, as after any death. A kill by your partner is scored
  in the UE4SS console (`PvP: you WON the duel. Score 1 - 0.`); dying to an enemy doesn't count.
  (In the prologue area the game won't let you die, so duel there for fun and the score still counts.)
- Both players fight with the same strength (your partner's ghost uses your stats), so skill decides.
  `PvPDamage` scales the damage you take (100 = normal).

Not in PvP yet: executions (posture break only staggers), and you don't see your partner's guard pose.

## Good to know

- The host should lead into new areas and boss arenas; the guest follows.
- If your partner disappears, they are down or on another map; they come back.
- Not shared yet: cutscenes, dialogue, spending dust.
- Never press Ctrl+R (UE4SS hot reload) while playing together: it can crash the game. Restart the game instead.

## Troubleshooting

- **No "co-op on" line:** check `PhantomPact.ini` (Role, and HostAddress for the guest). The UE4SS log says what's
  missing.
- **"Python 3 wasn't found":** install Python 3 from python.org with "Add python to PATH" ticked, then restart the
  game.
- **`connected=no`:** both on Tailscale? The right IP in the guest's `HostAddress`? Windows Firewall must allow
  Python on private networks (Windows asks the first time the host plays; click Allow).
- **No `[PBZCoop] Loaded` line at all:** UE4SS isn't installed in `PBZ\platform\steam`, or the mod folder isn't at
  `platform\steam\ue4ss\Mods\PBZCoop`.
