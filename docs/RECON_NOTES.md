# Recon notes

Fill this in as we discover things. Always note the **game version** the finding came from.

## Practice game: Black Myth: Wukong (game 1.0.21.23831, Steam build 21393610, UE 5.0)

UE4SS needs the `Wukong` custom game config (see [UE4SS_SETUP.md](UE4SS_SETUP.md)).

| Role | Value |
|---|---|
| Player controller | `/Game/00Main/BPLibrary/BGW/BP_B1PlayerController.BP_B1PlayerController_C` |
| Player character | `/Game/00Main/Design/Units/Player/Unit_Player_Wukong.Unit_Player_Wukong_C` |
| Test map | `BYS_persistentlevel` |

**2026-10-19, first F8 test (clone the player class):**
- `CreatePlayer` worked: a second `BP_B1PlayerController_C` was created and the screen split top/bottom.
- Spawning `Unit_Player_Wukong_C` and possessing it with player 2 worked at engine level, with no crash.
- A few seconds later the game's **own error dialog** appeared ("An issue occurred while running the
  game… exit and restart"). The game log showed nothing useful. Likely cause: the clone skipped the
  game's own unit setup. Not confirmed yet; F10/F11 isolate it.
- F7 found no characters within 50 m (the area may simply have been empty); F7 now also lists the nearest ones.

**2026-10-19, second test (F10 controller only, F11 engine DefaultPawn):**
- Both worked without errors in the logs.
- **Spawn position is ignored:** the DefaultPawn landed at the world origin, 356,705 cm from player 1.
  So the first clone also spawned at (0,0,0), probably out of bounds, which likely caused the error dialog.
  Fix: teleport with `K2_SetActorLocationAndRotation` after spawning.
- F7 here: no enemies loaded nearby. Only the player, the spawned pawns, `SpectatorPawn` and
  `DefaultEmptyPawn_C` (created with player 2's controller) exist.
- Player has 63–65 components, mostly Wukong's own `BUS_*` / `BGU*` / `GS*` systems
  (e.g. `BUS_PlayerDataComp`, `GSInputComponent`, `BGUCharacterMovementComponent`).
- Game mode: `/Game/00Main/Design/Blueprints/GameMap/BP_GameMode.BP_GameMode_C`.

**2026-10-19, autonomous loop (10 iterations, driven via `tools/game-driver.ps1` + `cmd.txt`):**

| # | Test | Result |
|---|---|---|
| 1 | Plain `DefaultPawn` for P2 + teleport after spawn | ✅ 200 cm from P1, split screen, **no error** |
| 2 | Clone `Unit_Player_Wukong_C` + teleport + possess | ❌ placed correctly, error dialog within 3 s |
| 3 | Read the dialog | It's `BP_UI_ExceptionPanel_C`; hidden `TextArea` = `未将对象引用设置到对象的实例。` = **C# NullReferenceException** |
| 4 | Clone with **no** P2 controller (`cloneonly`) | ❌ same exception → the unit itself is the problem, not possession |
| 5 | Spawn clone via the game's `UBGUFunctionLibraryCS::BGUSpawnActor` | ❌ position honoured, same exception |
| 6 | `BGUSpawnActorAndECSBeginPlay` | ❌ returns nothing, same exception |
| 7 | Spawn Pigsy's Tamer (`TAMER_NPC_ZhuBaJie_01B_Guibei_C`) | ✅ no exception, but the Tamer never wakes (not registered with level streaming) |
| 8 | Resolve Tamer's `MonsterClass` via `KismetSystemLibrary::Conv_SoftClassReferenceToString` / `LoadClassAsset_Blocking` | ✅ `/Game/00Main/Design/Units/PSD/Unit_PSD_ZhuBaJie_Summon.Unit_PSD_ZhuBaJie_Summon_C` |
| 9 | Spawn Pigsy summon via `BGUSpawnActor`, possess with P2 | ⚠️ no exception, but he ignores teleport (stays at origin) and is destroyed shortly after |
| 10 | Spawn Pigsy, no possession, watch | ⚠️ alive at 2 s and 8 s, gone by ~25 s: summons need a summoner and have a lifetime |

**Conclusions (transferable to PBZ):**
1. The **engine side of local co-op works out of the box**: `CreatePlayer` → second `PlayerController`, split screen, `Possess`.
2. Game-specific gameplay code (here C#/ECS) **assumes exactly one player**. A second copy of the player class
   crashes its logic even when spawned through the game's own spawner.
3. Plain `BeginDeferredActorSpawnFromClass` ignored the spawn transform in Wukong → always teleport after spawning.
4. Units that the game spawns for you (summons, Tamer monsters) carry owner/lifetime rules. A "borrowed body" for P2
   has to come from the game's own spawn path (e.g. cast the real summon skill with P1 as summoner) or have its
   lifetime/owner logic hooked out.
5. Practical next idea for Wukong (not done): make P1 cast the Pigsy summon skill (`BGUTryCastSpell`), then possess
   the summoned Pigsy with P2 and hook its lifetime.

**Useful Wukong API found** (`/Script/b1-Managed.Default__BGUFunctionLibraryCS`): `BGUSpawnActor`, `BGUTryCastSpell`,
`BGUAddBuff`, `BGUSetAttrValue`, `BGUIsEnemyTeam`, `GetUnitLockTargetActor`, `BGUPlayerCameraLockTarget`, `RunGMCommand`.
Dumps: `dumps/wukong-1.0.21.23831/` (CXX headers + object dump; git-ignored).

## Game build

| Field | Value |
|---|---|
| Game version | CL-301524_JKS-17219 (Steam build 26266538) |
| UE version | 5.7 (detected by UE4SS) |
| Project folder / exe name | `ProjectPBZ`; real game `platform\steam\PBZ.exe` (launcher `steam\PBZ.exe` runs it with `ProjectPBZ -basedir=…\ProjectPBZ\Binaries\Win64 -pc-platform=Steam`) |
| UE4SS build that works | Vercadi's "UE4SS for Phantom Blade Zero 1.0.1" (Nexus mod 5), installed in `platform\steam` |
| Saves | `PBZ\ProjectPBZ\Saved\SaveGames\Steam\<steamid>\` (game folder, not AppData); game log is encrypted |

## Core classes

| Role | Class (full path) | Notes |
|---|---|---|
| Player character | `/Game/RenewalContent/Actors/Players/BP_Renewal_Hun_Young.BP_Renewal_Hun_Young_C` | 91 components incl. `PBZAbilitySystemComponent` (GAS), `PBZCharacterMovementComponent`, `AttributeComponent`, `DeflectComponent`, `PBZTargetingComponent`, `BP_PBZHatredManagerComponent_C` (aggro?), `BP_DeathComponent_C` |
| Player controller | `/Game/PBZContent/Blueprint/Character/Player/BP_PlayerController.BP_PlayerController_C` | |
| Player camera manager | | |
| Game mode | `/Game/PBZContent/Blueprint/BP_GameMode_Build_ZLGW.BP_GameMode_Build_ZLGW_C` | first map `/Game/Maps/B01/PBZ_WP_ZhuLinGuWu` |
| Game state | | |
| HUD / UI root | | |

## Combat

| Role | Class / function | Notes |
|---|---|---|
| Enemy base class | `APBZCharacter_NPC` (`BIsMonster`) → `ABP_RenewalNPC_C` → `BP_Monster_*_C` | 177 enemies in `DT_CodexEnemyDataTable` (row = BP name, `EnemyClass`, `bIsBoss`; 75 bosses) |
| Enemy AI controller | `BP_PBZAIController_C` with `BP_SGameAIComponent_C` (state `AI.State.Combat`), behaviour/state trees, perception | Spawned by class + `SpawnDefaultController()`; engages once in a fight |
| Health / attribute component | `AttributeSetBase` (`UBasicAttributeSet`): `Health`/`Health_Max`, posture `Shachi`/`Shachi_Max` | Thug 400 HP / 200 posture, Club thug 1700, tutorial boss 2900 / 1120, Hun 850 |
| Apply-damage function | Native; `APBZCharacter::OnDamage` is **not** hookable (never fires in UE4SS) | Mod writes Health/Shachi directly and calls `Kill(EPBZDieReason)` at 0 |
| Parry / deflect function | `UDeflectComponent`, `GA_Hun_Young_DeflectEscape` | Not synced separately (abilities replay generically) |
| Death function | `APBZCharacter_NPC::Kill(EPBZDieReason)` (Damaged=1, GameLogic=3); `IsDead()` lags at 0 HP | Works for thugs and the boss |
| Lock-on / targeting | `UTargetingComponent` / `PBZTargetingComponent`; aggro via hatred `AddActorToHatredList` | Ghost added to hatred lists |
| Player abilities | `GA_Hun_Young_A`…`AAAA`, `_A_Draw`, `_Jump`, `_AdvancedDash` in `/PBZCombatAsset/ActorData/Players/Hun/Abilities/WoodenSword/YoungHun/` | Poll ASC `ActivatableAbilities.Items[].ActiveCount`; ghost `TryActivateAbilityByClass` |
| Items | `APBZPickupActor.ItemId`; `UPBZBackPackSubsystem` (`Inventories`, `AddPropsToBackPack`, `AddDustNum`); player `GiveItem` | Item ids are `DT_InventoryData` rows (often Chinese names); prologue backpack refuses materials |
| Boss bar | `UPBZHUDLayout::RegisterBossHPBar(AActor*)` | Hookable; calling it shows the boss bar |

## Flow

| Role | Class / function | Notes |
|---|---|---|
| Checkpoint / save point | | |
| Level load / streaming | | |
| Cutscene player | | |
| Boss fight start | | |

## F8 (second player) test results

| Date | Game version | Result |
|---|---|---|
| 2026-10-29 | CL-301524 | A `p2only`: split screen appears. B `plain`: DefaultPawn possessed by P2, own camera. C `clone`: second `BP_Renewal_Hun_Young_C` possessed by P2, **no errors** (unlike Wukong); keyboard moves only P1. No gamepad was connected, so P2 input is untested. |
| 2026-10-29 | CL-301524 | Echo (online, solo): Hun-clone ghost follows P1 at +300 cm X, stable 60 s+ with the game-thread net loop. Both crashes that day came at a UE4SS hot reload (Ctrl+R) with the mod's loops running: **never hot-reload PBZ, restart it**. |
| 2026-10-29 | CL-301524 | Walking ghost: steered with `AddMovementInput` (`CharacterMovement.bRunPhysicsWithNoController = true`, walking mode, capsule ignores Pawn). PBZ leaves `MaxWalkSpeed` = 0 on an unpossessed Hun, so the mod sets it from the distance to the target (100–750 cm/s, acceleration 2000). Result: real run animation, follows the ground, stops within ~45 cm. |
| 2026-10-29 | CL-301524 | Two copies on one PC: blocked. Copy 2 shows "Phantom Blade Zero is already running." `steam_appid.txt` stops the Steam relaunch; closing `PBZ_SingleInstance_Mutex` and `UnrealEngine4` in copy 1 is not enough (remaining unknown lock `CDdf212806D6EmB31yE0c` looks DRM-related, left alone). Sandboxie: "Failed to load" even for a single sandboxed copy. |
