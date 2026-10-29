# UE4SS setup

[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) is a scripting and modding system for Unreal Engine games.
It loads through a proxy DLL (`dwmapi.dll`) placed next to the game's executable, so the game's files
are never patched. That's also why it works alongside Denuvo.

## Which build

| Game | UE version | UE4SS build |
|---|---|---|
| Black Myth: Wukong (practice) | 5.0 | Latest **stable** (v3.0.1 at the time of writing) |
| Phantom Blade Zero | UE5, exact version unknown until launch | Probably **experimental-latest** (adds UE 5.4–5.8 support) |

Download from the [releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases). Take the main
`UE4SS_v*.zip`. For development, the `zDEV-` zip includes the GUI console and dumpers enabled.

## Install

1. Find the game's real executable. In UE games it lives in `<Game>\<Project>\Binaries\Win64\`
   and ends in `-Win64-Shipping.exe` (for Wukong: `BlackMythWukong\b1\Binaries\Win64\b1-Win64-Shipping.exe`).
2. Extract the UE4SS zip **into that `Win64` folder**, so `dwmapi.dll` and the `ue4ss\` folder sit
   next to the `-Shipping.exe`.
3. Open `ue4ss\UE4SS-settings.ini` and set:
   ```ini
   [Debug]
   ConsoleEnabled = 1
   GuiConsoleEnabled = 1
   GuiConsoleVisible = 1
   ```
4. Launch the game. A UE4SS console window should open next to it.

If the game crashes on start, **check for a custom game config first**. Many studios modify the
engine, and UE4SS then needs game-specific files. The release's `zCustomGameConfigs.zip` has a folder per
game; copy that game's `UE4SS-settings.ini`, `VTableLayout.ini`, `MemberVariableLayout.ini` and/or
`UE4SS_Signatures\` into the `ue4ss\` folder, then turn `ConsoleEnabled = 1` back on.

**Lesson from Black Myth: Wukong (2026-10-19):** with the default settings it crashed right after
`Event loop start` (access violation inside the game exe). Turning hooks off and flipping
`bUseUObjectArrayCache` didn't help. The `Wukong` custom config (`VTableLayout.ini` + engine version
pinned to 5.0) fixed it. Also: launch a game once **without** UE4SS first, so first-run setup isn't a
suspect. See UE4SS issues [#671](https://github.com/UE4SS-RE/RE-UE4SS/issues/671) and
[#632](https://github.com/UE4SS-RE/RE-UE4SS/issues/632).

For Phantom Blade Zero there won't be a custom config on day one. If it crashes the same way, we'll
have to build its `VTableLayout.ini` ourselves or wait for the UE4SS community.

## Dump the game's classes

In the GUI console, open the **Dumpers** tab and run:
- **Dump Objects & Properties**: a text file listing every loaded object
- **Generate .hpp files**: C++ headers for every class (the most useful for reading)
- **Generate Lua Types**: autocomplete for writing Lua mods

Run the dumpers **after loading into gameplay**, not in the main menu, so the combat classes are loaded.
Copy the output into this project's `dumps/<game>/` folder (it's git-ignored, because dumps are large).

## Install our mod

```powershell
.\tools\install-mod.ps1 -GameWin64 "D:\SteamLibrary\steamapps\common\BlackMythWukong\b1\Binaries\Win64"
```

Also add `{ "mod_name": "PBZCoop", "mod_enabled": true }` to `ue4ss\Mods\mods.json`. UE4SS also
honours our `enabled.txt`, but `mods.json` is the list this build reads first.

By default (`OFFSET_GAMEPADS = true` in `main.lua`), **keyboard/mouse controls player 1 and the first
gamepad controls player 2**, so one person can test with a single controller. UE4SS's bundled
`SplitScreenMod` showed us this engine setting (`GameMapsSettings.bOffsetPlayerGamepadIds`).

Hot reload (**Ctrl+R**) worked on Wukong, but **it crashes PBZ** while the mod's loops are running (two crash
dumps on 2026-10-29), so `EnableHotReloadSystem = 0` there. In PBZ, reinstall with `tools\install-mod.ps1` and
restart the game instead.

Then restart the game. Our mod's keys:

| Key | What it does |
|---|---|
| F6 | Print info about your character: class, location, components |
| F7 | List all characters near you (finds the enemy classes) |
| F8 | Spawn player 2: second local player + a copy of your character |
| F9 | Remove player 2 |
| F10 | Create player 2 only (split screen, no character) |
| F11 | Give player 2 the engine's plain `DefaultPawn` |

**Command file:** write commands (one per line) to `ue4ss\Mods\PBZCoop\cmd.txt` while in gameplay; the mod runs
them within half a second and empties the file. Commands: `info`, `nearby`, `where`, `p2only`, `plain`, `clone`,
`cloneonly`, `remove`, `exception`, `sdk`, `dumpobjects`, `actors`, and `eval <lua>` (the `PBZ` table exposes the
mod's helpers). `tools/game-driver.ps1` wraps this as `Send-ModCommand` / `Get-ModLog`.

Output appears in the UE4SS console and in `ue4ss\UE4SS.log`.
