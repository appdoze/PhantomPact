# Phantom Blade Zero: readiness guide

Everything we know before launch, what we learned on Black Myth: Wukong, and exactly what to do on day one.
Last updated 2026-10-19.

## 1. What we know about the game

| Topic | Status | Source |
|---|---|---|
| PC release | **October 29, 2026** (Steam may show Oct 28 because of US time zones) | [KeenGamer](https://www.keengamer.com/articles/news/phantom-blade-zero-release-confirmed-for-october-29/), [jeu.video](https://jeu.video/article/phantom-blade-zero-date) |
| Engine | Unreal Engine 5 (Lumen, Nanite); exact 5.x version unknown until launch | [RPG Site](https://www.rpgsite.net/news/14287-s-game-reveals-action-rpg-phantom-blade-zero-for-playstation-5-and-other-consoles), [Notebookcheck](https://www.notebookcheck.org/Phantom-Blade-Zero-confirma-su-fecha-de-lanzamiento-en-octubre-para-PS5-y-PC.1368606.0.html) |
| DRM | **Denuvo**, stated on the Steam page | [SteamDRM](https://www.steamdrm.info/games/phantom-blade-zero), [AllKeyShop](https://www.allkeyshop.com/blog/en-us/phantom-blade-zero-pc-specs-path-tracing-denuvo-news-r/) |
| PC demo | **None announced** (PS5 demo only, reported for Aug 17) | [GameGPU](https://en.gamegpu.com/news/igry/igroki-smogut-oprobovat-demoversiyu-phantom-blade-zero-uzhe-17-avgusta) |
| Preload | PS5 reportedly Oct 27 (134.9 GB); PC unconfirmed | [GamerFuzion](https://www.gamerfuzion.com/phantom-blade-zero-download-size-134-gb-ps5-preload-october-27/) |
| Multiplayer | Single-player only | [Wikipedia](https://en.wikipedia.org/wiki/Phantom_Blade_Zero) |
| Combat | Parry, block, dodge; **Sha-Chi** resource (builds on hits, spent on combos, blocks, Power Surge); **Brutal Moves** (drain Sha-Chi when blocked) and **Killer Moves** (unblockable, unparryable); two customizable command chains | [The Outer Haven](https://www.theouterhaven.net/phantom-blade-zero-preview-definitely-not-a-soulslike/), [CGMagazine](https://www.cgmagonline.com/articles/previews/gamescom-phantom-blade-zero) |

**Consequences:**
- No demo means **no PBZ-specific prep is possible before Oct 29**. Everything below is pipeline and method, proven on Wukong.
- Denuvo is fine for UE4SS (it loads as `dwmapi.dll` and never patches the exe). Denuvo does count hardware/activation
  changes, so don't swap GPUs or reinstall Windows around launch. **We never touch or bypass Denuvo.**
- A fast combat system with parries and Killer Moves makes online sync hard. Local co-op plus Remote Play first is still the right order.

## 2. What's ready

| Piece | Where | Proven on Wukong |
|---|---|---|
| UE4SS experimental (supports UE 5.4–5.8) | release `experimental-latest` | ✅ (needed a custom game config) |
| PBZCoop mod (F6–F11 + `cmd.txt` command file + `eval`) | `mod/PBZCoop/` | ✅ |
| Installer | `tools/install-mod.ps1` | ✅ |
| Game driver: launch, focus, click, keys, screenshots, mod commands, log | `tools/game-driver.ps1` | ✅ |
| Recon method: SDK dump → grep the game's own function libraries | `docs/RECON_NOTES.md` | ✅ |

## 3. Lessons from Wukong that decide the PBZ plan

1. **Engine-level local co-op works:** `GameplayStatics:CreatePlayer` gives a second controller and split screen,
   and `Possess` works. Expect the same in PBZ.
2. **The game's own gameplay layer is the real wall.** Wukong's C#/ECS code threw a NullReferenceException for *any*
   second copy of the player class, even via the game's own spawner. PBZ will have its own single-player assumptions.
3. **Spawn transforms may be ignored**, so always teleport after spawning and log the actual position.
4. **The game's own dialogs can be caught:** Wukong's `BP_UI_ExceptionPanel_C` kept the real error in a hidden text box.
   Look for a similar panel in PBZ and read it.
5. **Borrowed bodies** (summons, NPCs, monsters) come with owner and lifetime rules. Prefer spawning through the game's own skill/summon path.
6. **Custom engine configs:** if UE4SS crashes right after `Event loop start`, the studio changed the engine. Check
   `zCustomGameConfigs.zip` for a PBZ folder; if none, ask the UE4SS Discord or build `VTableLayout.ini`.
7. **Launch the game once without UE4SS first**, so first-run setup isn't a suspect.

## 4. Launch day procedure

### Before Oct 29
- [ ] Buy/preload PBZ on Steam. Note the Steam app ID (from the store URL) for `Restart-Game -SteamAppId`.
- [ ] Re-download UE4SS `experimental-latest` that day (it's rebuilt often) and the matching `zCustomGameConfigs.zip`.

### Hour 0–1: baseline
1. Launch PBZ **without** UE4SS. Play until you have control and reach a first fight; let it save. Quit.
2. Back up saves: find the folder (likely `%LOCALAPPDATA%\<project>\Saved\SaveGames` or under the install's `Saved\`).
3. Record exe name, project folder and UE version (exe → Properties → Details) in `RECON_NOTES.md`.

### Hour 1–2: UE4SS
Shortcut: `.\tools\pbz-setup.ps1 -UE4SSZip <zip> -ConfigsZip <zip>` does steps 2–5 and records the build
(it refuses to run until the game has been launched once without mods).

4. Extract UE4SS into `<PBZ>\<Project>\Binaries\Win64\`. Set `ConsoleEnabled = 1`, keep the GUI off at first.
5. Disable the sample mods in `Mods\mods.txt`; enable only PBZCoop (`tools/install-mod.ps1`).
6. Launch. If it crashes after `Event loop start`: check for a PBZ custom config; try `bUseUObjectArrayCache` both ways;
   check the UE4SS issue tracker and Discord. Don't brute-force random settings for more than an hour.

### Hour 2–4: recon (driver + `cmd.txt`)
7. `. .\tools\game-driver.ps1 -GameWin64 <path> -ProcessName <exe without .exe>`
8. Load into gameplay, then `Send-ModCommand info, nearby, where`, then `sdk` and `dumpobjects`.
   Copy `CXXHeaderDump` and `UE4SS_ObjectDump.txt` to `dumps/pbz-<version>/`.
9. Grep the dumps for the targets in section 5.

### Hour 4+: co-op proof of concept (escalation ladder)
| Step | Command | Pass condition |
|---|---|---|
| A | `p2only` | Second controller, split screen, no game error |
| B | `plain` | Engine pawn beside P1, no game error |
| C | `clone` | Copy of the player class works → **jackpot** |
| D | If C breaks: use the game's own spawn function from its function library (`eval`) | Body exists, no error |
| E | If still broken: a companion/summon/NPC unit spawned the game's way, possessed by P2 | P2 moves it |
| F | Enemies react to P2 | AI target selection includes P2 |

Watch for an error/exception widget after every step (list visible widgets with `eval`, as on Wukong).

## 5. Recon targets (what to search the dumps for)

| Need | Search terms in `CXXHeaderDump` |
|---|---|
| Player character + controller + game mode | `PlayerCharacter`, `PlayerController`, `GameMode` (classes deriving from `ACharacter` / `APlayerController`) |
| The game's own function libraries | `: public UBlueprintFunctionLibrary` (look for spawn/summon/attribute helpers) |
| Spawn paths | `Spawn`, `Summon`, `Partner`, `Companion`, `Ally` |
| Health / damage / death | `Health`, `Damage`, `Hit`, `Die`, `Dead`, `Attr` |
| Parry / Sha-Chi / Killer Moves | `Parry`, `Deflect`, `ShaChi`, `Sha`, `Killer`, `Brutal`, `Surge` |
| AI targeting | `Perception`, `Target`, `Aggro`, `Threat`, `Enemy`, `Team` |
| Camera / lock-on | `Camera`, `LockOn`, `Lock`, `SpringArm` |
| Flow | `Checkpoint`, `Save`, `Respawn`, `Sequence`, `Cinematic`, `Boss` |
| Error UI | `Exception`, `Error` widgets |

## 6. Online over Tailscale (built 2026-10-28)

Tailscale first because we can test it ourselves; Steam networking comes later as a second transport.

| Piece | What it does |
|---|---|
| `net/pbzcoop_net.py` | UDP relay, Python standard library only. `host` listens on UDP 47800, `client` connects to the host's Tailscale IP, `echo` fakes a friend from your own movement (solo test). Ping/timeout built in; writes `net_status.txt`. |
| Mod `neton` / `netoff` / `netstatus` | Every 50 ms writes `<seq> <x> <y> <z> <yaw>` to `net_out.txt`, reads the friend's line from `net_in.txt`, shows them as a collision-free ghost pawn moved smoothly (~60 Hz). A puppet, not a local player, so no P2 controller. |
| `tools/pbz-setup.ps1` | One-shot launch-day setup (game info, save backup, UE4SS, configs, mod). `-Disable` / `-Enable` toggles UE4SS. |

**Machines:** this PC `yhsharaf` = `100.112.4.45`; second PC `desktop-gfqd042` = `100.92.213.68`.

**Tested 2026-10-28:** host ↔ client over `127.0.0.1` and over the Tailscale IP on this PC (both sides received each
other's state; ping ~0 ms after switching to `select`), and echo mode (state returned +300 cm). **Not yet tested:**
two different PCs, and anything inside the game.

**Two-PC relay test (no game needed):** copy `net\pbzcoop_net.py` to the other PC (needs Python 3), then:
- This PC: `python -I net\pbzcoop_net.py host --dir C:\temp\pbznet`
- Other PC: `python -I pbzcoop_net.py client --dir C:\temp\pbznet --peer 100.112.4.45`
- Both print `connected=yes` with a ping. If the host never connects, Windows Firewall is blocking Python on the
  host: allow it when Windows asks (private network).

**Main test method: two copies on this PC (like Blood Pact's self-test).** `tools/pbz-selftest.ps1` starts copy 1
(host, files in the mod folder) and copy 2 (client, files in `inst2\`), each with its own `PBZCOOP_INSTANCE`, plus a
host and client relay over `127.0.0.1`. It backs up saves first; `-Stop` closes only what it started. The driver
targets one copy with `Select-GameInstance -ProcessId <pid> -Instance <1|2>`. Dry run on a stand-in window passed
(2026-10-28). Why this method: one Steam account can't run PBZ on two PCs at once, so the second PC would need a
second account that owns the game.

Unknowns to check at unlock (the script reports each):
- **PBZ may refuse a second copy** (single-instance check, Steam or Denuvo). Then fall back to solo `echo`.
- **The game may relaunch itself through Steam** when started directly, dropping `PBZCOOP_INSTANCE`. A
  `steam_appid.txt` next to the exe usually stops that, but it's a change to the game folder, so ask first.
- **Both copies share one save folder and one `UE4SS.log`.** Saves are backed up per run; log lines from copy 2
  are tagged `[PBZCoop#2]`.

**In-game, at unlock:** run `pbz-setup.ps1`, load into gameplay, then:
1. Solo: `python -I net\pbzcoop_net.py echo --dir "<PBZ Win64>\ue4ss\Mods\PBZCoop"` and `Send-ModCommand neton`;
   a ghost should follow you 3 m to the side. `netstatus` reports the distance.
2. Two PCs: host + client relays (each pointing `--dir` at its own game's mod folder), `neton` on both.

**Next layers after the ghost works:** swap the ghost for a proper character (animation from replicated speed/state),
then attacks/hits (host decides damage), then enemy state (host-owned AI, client puppets).

## 7. Online later (stretch)

- Proven route by others: **Steam networking + the mod's own sync** (Lies of P co-op by Ember Wave uses Steam networking,
  no VPN; [DSOGaming](https://www.dsogaming.com/pc-performance-analyses/lies-of-p-just-got-a-cool-fun-co-op-mod/)).
  Their open problem was world events (doors, elevators, quests), so plan for that.
- Worth one experiment: whether PBZ still ships Unreal's built-in networking (`open <map>?listen`). Unreal's replication works
  only for what the game marked as replicated, which a single-player game usually didn't do, so expect partial results at best.
- Until then, **Steam Remote Play Together** turns working local co-op into online co-op for free.
