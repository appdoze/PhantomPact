# A co-op save per partner ("pact save"): your main save is never touched

## Why

Every "not taking it" in `docs/reviews/appdoze-merge-status.md` has the same root: **the partner's progress lands
in the player's real campaign, and the autosave makes it permanent.** The Rust exe and the second Steam transport
were turned down for other reasons; this proposal needs neither.

| Turned down | Your reason | With a pact save |
|---|---|---|
| Shared quests (`Q`) | A far-ahead host completes quests in the guest's save. That can softlock, and the autosave keeps it. | It happens only in the pact slot. Quest-path checks and double rewards are still worth fixing, but a bad result stays in a slot you can throw away. |
| Enemy-group rewards (`G`), challenge points (`N`) | They mark things done without paying the reward. `N` takes any node. | Pact only. The node allow-list and the "grant the reward" fix still apply. |
| Chests, gates, doors (`A`) and the `shared_world.txt` ledger | No save or partner key, grows forever, applied in unrelated saves, records while Off, needs `pbzsave`. | **No ledger.** Things open live and are saved into the pact. The slot name is the partner key. No Rust tool. |
| Equipment (`J`) | The baseline isn't per save, any id gets through, both directions. | The baseline is per pact. The allow-list and cap stay. |
| Regroup across maps | A chapter-1 guest jumps into chapter 5, and the autosave keeps it. | It's kept only in the pact. Same-map-only stays the default. |
| Live fog gates from the ledger | Opens arena fog where the boss isn't beaten. | Gone: there's no ledger. |
| Rust relay exe, second Steam transport | Nexus and antivirus trouble, a different protocol. | Not used. It's all Lua in the mod. |

## What I checked in game

Build 26266538, one PC, solo. The full save set was snapshotted first, and slots were compared byte-for-byte with
`pbzsave dump`. Most checks ran in a normal-difficulty save (`ManualSave1`); the first ones ran in a Nightmare run.

### Where the game's saves go

| Check | Result |
|---|---|
| Normal autosaves | **The slot names are fixed in C++, whatever slot you loaded.** A bell save rotated `AutoSave0/1/2` (`RotateBellSaveAndWriteToDisk`); the exe only has `AutoSave0` and `AutoSave%d`. The game's own autosave calls pass no slot name. Loading a pact and letting the game save would overwrite your main autosaves. |
| Nightmare run | `TrySave` ignores `SaveSlotName` and writes `NightmareRun{i}`; the game's `BellMenu.js` says so. |
| `TrySave(0, {SaveSlotName = "Pact_test"})`, normal mode | It honours the name: only `Pact_test` was written. |
| `ForceSave(Flow, {SaveSlotName = "Pact_test"})` | It writes **immediately and only that slot, even while a veto is held**. The game's own comment says Flow saves go around the veto by design. |
| `SaveJsonObjectToString` → `ReplaceSaveString({SaveSlotName = X})` | Writes exactly slot X. But the string is the last in-memory commit, not necessarily live, so the Flow save is the better writer. |

### The save veto

| Check | Result |
|---|---|
| V1: what the veto holds | `TrySave` (general and bell) returns `Suspended`. `ForceSave` QuestNode, Respawn and TeleportCrossLevel return `Queued`. Nothing reached the file. **`ForceSave` Flow wrote anyway.** |
| V2: what happens when the veto ends | The veto is **counted** (two enters need two exits). On release, only **one** save fires: the **latest request's** parameters, with the state **at that moment**. So requesting `TrySave(0, {SaveSlotName = pact})` last makes the postponed save go to the pact. |
| V4: quit to title | Quitting to the title with the veto held **dropped** the pending save. Nothing was written, even after releasing the veto at the title. |
| V4: crash | The game crashed (an unrelated test) while the veto was held. The save file was byte-identical afterwards. |

### Loading and the rest

| Check | Result |
|---|---|
| V3: loading a slot from Lua | `PBZGameInstance:LoadGame("Pact_test", res)`, then `GameplayStatics:OpenLevel(pc, "/Game/Maps/B02/" .. res.LevelName, true, "")`, as the game's `TsHelper.LoadGame` does. **From the title: works.** The loaded game carried `Pact_test`'s play-time stamp, not `AutoSave0`'s. In game with the short map name, it went to the title instead. |
| Respawn | In place (`Respawn()` moves you, restores health, refreshes enemies). No reload from disk, so a death in the pact stays in the pact. |
| `MarkLoadedSlotAsContinue("Pact_test")` | No effect: Continue doesn't move to a custom slot. |
| V5: deleting a pact in game | `DeleteManualSaveSlot` refuses anything that isn't `ManualSave<N>`. `PBZSaveLoadUtils.DeleteSaveGame` does nothing. |
| Side effects | `GetAllSaveSlots` lists the pact, and its summary is valid. Any save also bumps an account-wide counter in `__Advanced__` (`Pool_XiGu`). |

## Design (from these results)

1. **Start.** Both players set `CoopSave = Pact` (a shared setting). The mod holds a save veto from the moment the
   pact session starts: `EnterSaveVeto("PhantomPact", GameplayFlow)`.
2. **First time with this partner.** `ForceSave(Flow, {SaveSlotName = "Pact_<key>", bShowSaveTip = false})` copies
   your current game into the pact.
3. **Enter.** Return to the title. Then `LoadGame("Pact_<key>")` + `OpenLevel(<full map path>)`. From the title,
   that's the path verified above.
4. **Play.** The veto holds every game save (V1). The mod writes the pact itself with the Flow save, after a bell
   rest (`hookRest`), every few minutes, and on leaving. A death respawns in place.
5. **Leave.** Write the pact one last time. Request `TrySave(0, {SaveSlotName = pact})`, so any pending save points
   at the pact, then return to the title, which drops it (V4). Release the veto at the title. You load your own game
   from the menu as usual.
6. **Crash or quit mid-session.** The veto dies with the game, and nothing is written (V4). Your main slots keep
   their last pre-session state. The pact keeps its last write.

Shared progress (`Q`/`A`/`J`/regroup) runs only while the mod has a pact loaded (it did the load, so it knows). In
any other game it refuses.

### Known gaps

- **The game's own Flow saves pass the veto (checked).** In the scripts this is one call,
  `captureEndingReturnSnapshot` (the "return after an ending" snapshot, taken once before an ending). Reproduced
  with the veto held (key, `FlagEndingReturnSnapshot`, `ForceSave(Flow)`), it wrote **the run's own slot**
  (`NightmareRun0`) plus a new `EndingReturn_<key>` slot. In a normal game the game's comment says it lands in
  `AutoSave0`. So during a pact session it would write a main slot. Options: end the pact session before that
  story point (the mod can see the flow node coming), or a pre-hook on `ForceSave` that sets `SaveSlotName` to the
  pact (normal-mode `ForceSave` honours the name; the hook itself is untested).
- **Removing a pact** has no working in-game function. Pacts stay (about 100 KB each); `pbzsave delete-slot`
  removes one with the game closed.
- `__Advanced__` and `__Achievements__` are account-wide. Codex sharing (`X`) stays off.

## Order of work, one PR each

1. The pact itself: create, enter, veto, write, leave. No shared progress, so it can be checked alone.
2. Revive (#8). It doesn't need the pact, because it never writes a save.
3. Shared-progress pieces, each gated on the pact, in your order.
