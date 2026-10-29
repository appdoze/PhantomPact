# Launch day checklist (October 29, 2026)

> The full procedure, with the Wukong lessons and the co-op escalation ladder, is in
> [PBZ_READINESS.md](PBZ_READINESS.md). This page is the short version.

## Before launch
- [ ] Phase 0 in [ROADMAP.md](ROADMAP.md) is done on a practice game
- [ ] Both UE4SS builds (stable and experimental-latest) downloaded and unzipped in a folder outside the game
- [ ] Phantom Blade Zero pre-loaded on Steam

## Day 1
1. [ ] Play the opening normally until you have control of the character and reach a first fight.
       Make a save there; it's our test spot.
2. [ ] Find the executable: `<PBZ install>\<Project>\Binaries\Win64\*-Win64-Shipping.exe`.
       Write the project name down in [RECON_NOTES.md](RECON_NOTES.md).
3. [ ] Find the UE version: right-click the `-Shipping.exe` → Properties → Details → File/Product version.
4. [ ] Install UE4SS (stable first; if the game crashes, switch to experimental). Don't keep trying
       builds that crash: note the crash and ask in the UE4SS Discord.
5. [ ] Load the test save, then run all three dumpers. Copy the output to `dumps/pbz-<game version>/`.
6. [ ] Install `PBZCoop` and press F6 and F7 at the test spot. Paste the output into RECON_NOTES.md.
7. [ ] Press F8 near the first fight. Record exactly what happens:
       - Does a second character appear?
       - Does gamepad 2 control it?
       - Does the screen split?
       - Do enemies notice it?
       - Does the game crash?

## After every game patch
- [ ] Re-run the dumpers and compare with the previous dump (class or function renames break the mod)
- [ ] Re-test F6–F9
