# Nexus Mods page: Phantom Pact

Sections as in the Nexus form; the same text is in dist\Nexus-upload\paste\ for pasting.

## Name and summary

Phantom Pact - Online Co-op

Online co-op for Phantom Blade Zero. Play with a friend online, each in your own game and save: see each other fight, take on shared enemies and bosses together, share loot and dust, and rest at bells together. 2 players, connected over Tailscale.

## Description

Phantom Pact adds online co-op to Phantom Blade Zero. Two players each run their own game and keep their own save, and Phantom Pact links the two worlds: you see each other, fight the same enemies, take on bosses as a team, share loot and dust, and rest at bells together. The host’s world leads, and the friend joins in.

## Installation instructions

Install UE4SS for Phantom Blade Zero (see Requirements): put dwmapi.dll and the ue4ss folder in the game’s PBZ\platform\steam folder. To find it: Steam > right-click the game > Manage > Browse local files, then open platform\steam.
Download the mod and extract the zip anywhere, for example your Desktop.
Double-click “1 - Install Phantom Pact.bat”. It finds the game through Steam and installs the mod.
Start the game and load your save. The UE4SS console shows “[PBZCoop] Loaded” once the mod is running.
Host: double-click “2 - Host.bat”.
Friend: double-click “3 - Join friend.bat” and type the host’s Tailscale IP (it starts with 100. and is shown in the host’s Tailscale app).
Play together. To stop, both double-click “Stop co-op.bat”.

Updating: extract the new version and run “1 - Install Phantom Pact.bat” again.
To uninstall: delete the ue4ss\Mods\PBZCoop folder from the game folder.

## Main features

See your partner’s Hun live, with their moves, attacks, dodges and hit reactions
Shared enemies: the same enemies in both worlds, with shared health, posture and executions
Your partner’s hits land in the host’s world, so you can fight the same enemy together
Shared boss fights: boss health bar and arena fog walls for both players
Shared loot: when your partner picks up an item, you get it too
Shared dust: dust earned by either player goes to both
Shared resting: rest at a bell and enemies respawn for both
Your partner disappears while they’re down or on another map, and comes back when they return

## Requirements

Phantom Blade Zero on Steam, for both players
UE4SS for Phantom Blade Zero 1.0.1 by Vercadi (Nexus Mods), for both players
Python 3 (python.org), with “Add python to PATH” ticked during install
To connect: both use Tailscale (tailscale.com), signed in to the same network
Both players use the same Phantom Pact version

Early release, 2 players. The host leads into new areas and boss arenas. Cutscenes, dialogue and spending dust aren’t shared yet. Don’t press Ctrl+R (UE4SS hot reload) while playing together; restart the game instead.
Please report bugs in the Bugs tab with your ue4ss\UE4SS.log and ue4ss\Mods\PBZCoop\net_status.txt.

## Shout outs

Vercadi, for UE4SS for Phantom Blade Zero, which made modding this game possible
The UE4SS team, for RE-UE4SS
S-GAME and the game’s developers, for Phantom Blade Zero
Everyone testing this first release

Fan-made mod, not affiliated with or endorsed by S-GAME.
