# Review: PR #2 by appdoze ("Relay security and latency, shared progress, Direct and Steam networking")

This review was read-only and compared the PR against our local `main` (9 commits ahead of the published 1.2.0).
The PR has 7 commits, all from 2026-10-30 within about 65 minutes, touching about 4,100 lines in 27 files. It
contained no instructions aimed at an AI and no hidden binaries, build scripts or git dependencies. By the
author's own account it was never played between two PCs.

## Verdict

Don't merge it as is. Port the good parts into our code, skip what's unsafe for players' saves or for Nexus.

## Take (port into our code)

| Piece | Why | Changes needed while porting |
|---|---|---|
| Event value checks (`num()` rejects NaN/inf; caps on `C` dust and `D` damage) | Real hole: a forged packet could set infinite dust or damage | Merge with our lethal hit: check the reported amount and cap it first, then switch to `math.huge` when the flag is `L`. Their cap as written silently drops our lethal hits |
| Sender filter (host accepts only expected addresses; guest accepts only its host's exact ip:port) | Real hole: anyone on the host's LAN could join or inject events | The default must also allow private LAN ranges (192.168/10/172.16), not only Tailscale. Their default breaks LAN, Hamachi, ZeroTier and Radmin play that works today |
| Optional `Secret`: HMAC signing with replay protection, AES-GCM on Windows | Authentication beyond the address. The CNG AES wrapper is correct and passes NIST known-answer test case 13 | Fix first: (1) refuse packets carrying our own session id and bind the direction (reflection attack); (2) a time window, so replays across relay restarts are refused; (3) scrypt/PBKDF2 for the key, not bare SHA-256; (4) separate keys for HMAC and AES; (5) a clear status when the two sides use different modes |
| Immediate send (watch the files every 5 ms, send as soon as the mod writes) | Measured median 48 ms -> 15-25 ms | Call `timeEndPeriod` on exit. If the mod switches to writing every 33 ms, turn our tick-counted timers (heal 1 s, aggro) into real time first |
| Settings handshake (version and shared settings, `mismatch=` in the status) | Catches players with mismatched settings | Clean up partner values before they go into net_status.txt; spaces or newlines inject fake keys |
| eval only with `dev.txt` / `PBZCOOP_DEBUG` | Defence in depth | Our test tools must create dev.txt; add dev.txt to .gitignore |
| Build check by PBZ.exe size (warning only) | Cheap and harmless | none |
| In-game status tips (`status.lua`) | Nice for players | Re-create the tip widget after map travel; match the status keys to our relay |
| Dead reckoning for the ghost | Smoother partner movement | Compute dt from the snapshot sequence, not arrival time (jitter); no prediction while hidden or gone; share one clock with our `lastRemoteAt` |
| CI (Python tests on Windows and Ubuntu) | Safe trigger (`pull_request`, no secrets) | Add `permissions: contents: read`; pin actions by SHA; drop the Rust job |
| Robustness found during review, also present in 1.2.0 and our relay | Crashes from one bad packet | Huge ping `ts` (OverflowError); event ids like `"²"` pass `isdigit()` but `int()` fails; cap packets handled per receive (flood) |

## Defer (behind an option, default Off, after an in-game check)

- **Partner's outfit on the ghost** (`EquipOutfit(..., true)`): first check that a save diff shows no wardrobe or save change.
- **Direct / UPnP:** UPnP must be opt-in, since it changes the router. Fix the crashes from bad router answers (malformed XML raises a SyntaxError that nothing catches; a `file://` LOCATION), add read limits, renew on a thread, and require a Secret.
- **Shared bells (`L`):** check that `ActivateBellByID` doesn't trigger our rest hook (double refresh). It unlocks fast travel ahead of the receiver's own progress.
- **Codex (`X`):** a raw TSet write from Lua is risky. Off for both sending and receiving.

## Skip

- **Shared quests (`Q`):**
  - It forces `BeginQuest` and `SucceedQuest` for any quest the partner finishes, so a chapter-5 host can complete quests in a chapter-1 guest's save. That skips objectives (possible softlock) and autosaves it for good.
  - The quest path isn't validated (any asset gets loaded).
  - Rewards are paid twice, because the forced completion pays natively and our dust sync sends it back.
  - It is on by default.
- **Baseline / "never pushes your story":** wrong. The baseline is taken while waiting alone, survives loading another save, and the event backlog replays on join.
- **Mob-domain rewards (`G`) and challenge points (`N`):** they probably only mark them done without granting anything, so the reward is lost. `N` accepts any node id, story flow included.
- **Chests / rubbish piles (`A`) and the `shared_world.txt` ledger:** the ledger has no save or partner key, grows forever, is applied in unrelated saves, and records even when Off. Duplicate drops.
- **Steam transport and rich-presence partner discovery:**
  - Ours is sounder: typed structs, a session-request filter that accepts friends only, and a live ping handshake with no stale adverts.
  - Theirs locks onto the first advertiser and never searches again.
  - The two can't talk anyway: channel 47800 against our 0.
- **Rust native relay (`relay/**`):**
  - Well written, but it speaks their Steam/auth protocol.
  - Shipping means an unsigned hidden-window exe that changes the router and loads a DLL. That's the same Nexus/antivirus fight as before.
  - Bugs: CRLF goes on the wire when mixed with the Python relay; UPnP chunk decoding can panic.
  - Its Lua syntax-check test is a good idea, but a `luac -p` step in CI is lighter.
- **make-release `-NativeRelay`:** it exempts the exe from the quarantine check.
- **README/INSTALL edits:**
  - They claim the zip "includes pbzcoop_relay.exe" (false by default).
  - They present Steam/Direct/UPnP as working (untested).
  - They bump the version to 1.3.0 (not ours to decide).
  - Reusable bits: the Tailscale DERP lag tip and the Secret-mismatch troubleshooting.

## Conflicts with our local main

- **`coop.lua`:**
  - `handlers.D`: the lethal hit, as above.
  - `readSnapshot`: their velocity and `targetAt` alongside our `lastRemoteAt`/`partnerGone`.
  - `clearRemoteState`: take both sets of fields.
  - `tick()`: their per-tick read against our `watchOwnDeath`/`watchPartner`.
- **`autostart.lua`:** hard conflict. Their `Network`/`PartnerSteamID`/`--partner`/`--steam-dll`/Direct/UPnP/`Relay=` against our `Connect = Steam` with `--transport steam --peer <name>`. Keep ours; read `Network` as an alias.
- **`PhantomPact.ini`:** merge by hand.
- **`main.lua`:** clean.
- **`tools/make-release.ps1`, `tools/install-mod.ps1`:** text conflicts on the line that copies the relay. Their foreach also copies `mobdomains.txt` and `challengenodes.txt`, which we don't have.

## Suggested order

1. Robustness and security core: event checks (merged with our lethal path), sender filter with a LAN-friendly default, crash fixes from bad packets, a cap on packets per receive.
2. Optional `Secret` with the fixes above, plus the settings handshake.
3. Immediate send, plus time-based timers in the mod.
4. eval gating, build check, status tips, dead reckoning, CI.
5. Later and opt-in: outfit, Direct/UPnP, bells, codex, each after an in-game check.
