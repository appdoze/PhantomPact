# Roadmap

## Phase 0: Prep (now until Oct 29)

Practice the whole pipeline on a UE5 game you already own. **Black Myth: Wukong** is the best fit:
it's UE5, a melee action game, and the WukongMP mod proves multiplayer can work on a game like it.

- [x] Reinstall Black Myth: Wukong (or another UE5 game you own)
- [x] Install UE4SS on it ([UE4SS_SETUP.md](UE4SS_SETUP.md)); needed the Wukong custom config
- [x] Get a UE4SS console open in-game (text console; GUI left off)
- [x] Run the dumpers (C++ headers + object dump), driven via `cmd.txt`
- [x] Install `PBZCoop` and run the recon keys (F6/F7) to see what they print
- [x] Try the F8 second-player spawn and write down what breaks (see [RECON_NOTES.md](RECON_NOTES.md))

**Status (2026-10-19):** Phase 0 done. Engine-level local co-op works in Wukong, but the game's C# layer rejects a
second player unit; see [PBZ_READINESS.md](PBZ_READINESS.md) for how that shapes the PBZ plan.

**Done when:** you can install UE4SS, dump a game's classes and run our Lua mod in under 30 minutes.

## Phase 1: Recon on PBZ (launch week)

- [ ] UE4SS loads in PBZ (check which UE5 version it is, then pick the stable or experimental UE4SS build)
- [ ] Dump everything and save the dumps outside the game folder
- [ ] Identify the player character class, player controller, game mode, camera manager
- [ ] Identify enemy base class, AI controller, health/damage component, hit/parry functions
- [ ] Record everything in [RECON_NOTES.md](RECON_NOTES.md)

**Done when:** we know the classes for player, enemy, damage and camera.

## Phase 2: Local co-op proof of concept

- [ ] Spawn a second local player (`GameplayStatics:CreatePlayer`)
- [ ] Spawn a second copy of the player character and possess it with player 2
- [ ] Gamepad 2 moves and attacks with it
- [ ] Enemies can hit and target player 2
- [ ] Camera keeps both players in view (shared camera, or split screen as a fallback)

**Done when:** two people can clear one combat encounter together on one PC.

## Phase 3: Make local co-op playable

- Player 2 death / revive rules, checkpoint and level-transition handling
- Cutscenes: hide or teleport player 2
- Bosses: scale health for two players
- Settings menu or config file

**Done when:** a full chapter is playable in local co-op, so Remote Play Together gives us online play too.

## Phase 4: Real online co-op (stretch goal)

- Steam P2P transport (Steamworks networking), with the host as the authority
- Sync: player transforms + animation state, hits/damage, enemy state, deaths, level progress
- Latency handling for parries (the host confirms; the client predicts its own inputs)

**Done when:** two PCs finish a chapter together over the internet.
