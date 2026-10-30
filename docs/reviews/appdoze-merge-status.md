# appdoze's contributions: what we merged and what we didn't

appdoze opened issue #1 and PRs #2/#4 (both closed), then issue #3 and **PR #5 ("Phantom Pact 1.5.0")**, which
replaces them. PR #5 is the reviewed PR #2 work plus two newer commits (1.4.0 and 1.5.0). Nothing is merged on
GitHub. Pieces are ported by hand into our own code, credited in comments ("from appdoze's PR #2").

- Full review of the PR #2 part: [PR2-appdoze.md](PR2-appdoze.md)
- Local branches for reading only: `review/pr-2` (the PR #2 state) and `review/pr-5` (PR #5)

## Merged (ported into our code, with fixes)

| Piece | Where in our code | What we changed from theirs |
|---|---|---|
| Event value checks: NaN/inf dropped, dust and damage capped per event | `coop.lua` `num()`, `handlers.C`, `handlers.D` | The cap runs before the lethal flag turns a hit into `math.huge` (theirs would have dropped every lethal hit); posture is clamped |
| Sender filter | `net/pbzcoop_net.py` `PARTNER_NETWORKS`, `address_allowed`, `UdpLink.receive`, `--allow` | Default also allows home networks (192.168/10/172.16), this PC and Hamachi/Radmin, not just Tailscale, so LAN/VPN play keeps working. The guest still accepts only its host's exact address. `filtered=` in status |
| Optional `Secret` (signed packets) | `net/pbzcoop_net.py` `Auth`, `Relay.send/receive_all`, `--ini`; ini `Secret =` | HMAC only (no AES). Fixes: refuses packets from its own role/session (reflection), a 2-minute time window plus a counter per session (replays, also across relay restarts), an scrypt-stretched key (theirs: bare SHA-256). Without a secret, signed packets are refused too. The relay reads the secret from the ini, never the command line. `rejected=` / `auth=` in status |
| Crash fixes from one bad packet | `parse_events` (ids like "²", huge ids), pong `ts` range check, max 256 packets per receive | Found while reviewing their code; also present in 1.2.0 |
| Settings handshake (version + shared settings, `mismatch=`) | `net/pbzcoop_net.py` `hello`, `SHARED_SETTINGS`, `clean_token`; `--mod-version` | Partner values cleaned before they reach net_status.txt (theirs let spaces/newlines inject fake keys) |
| Immediate send (files checked every 5 ms, sent on change; 1 ms Windows timer) | `Relay.wait`, `send_state`, `fine_timer` | The timer is released on exit. The mod keeps writing every ~48 ms (we didn't take their 33 ms, which would break our tick-counted timers) |
| `eval` only with dev.txt / `PBZCOOP_DEBUG=1` | `main.lua` `runCommand` | `tools/install-mod.ps1` creates dev.txt (developer install only; the release zip has none) |
| Game build check by PBZ.exe size (warning only) | `autostart.lua` (`KNOWN_BUILDS`) | Same |
| In-game status tips (game's ink-bar tip) | new `mod/PBZCoop/Scripts/status.lua`, `tips` command | Created from the widget class (theirs needed one already on screen, so it never showed); re-created after map travel; matches our status keys; polls by time, not ticks. Seen on screen: `art/screenshots/status-tip.jpg` |
| Dead reckoning for the partner's ghost | `coop.lua` `steerGhost`, snapshot `P` parsing | Velocity from snapshot numbers, not arrival times (jitter); off while the ghost is hidden or the partner is gone; shares our `lastRemoteAt` clock |
| CI: relay tests on Windows + Ubuntu | `.github/workflows/tests.yml` | Read-only token, actions pinned by commit, Python job only (no Rust) |
| Tips text reused | `status.lua` | Tailscale "via DERP" high-ping tip, Secret-mismatch tip |

## Not merged

### Skipped (unsafe or not wanted)

| Piece | Why |
|---|---|
| Shared quests (`Q`) | Forces `BeginQuest` + `SucceedQuest` for any quest the partner finishes, so a far-ahead host completes quests in the guest's save. That skips objectives (possible softlock), and the autosave makes it permanent. The quest path isn't validated, and rewards are paid twice. It was on by default |
| Shared enemy-group rewards (`G`) and challenge points (`N`) | They likely only mark things done without granting the reward, so the reward is lost. `N` accepted any node id, story flow included |
| Shared chests / rubbish piles (`A`) and the `shared_world.txt` ledger + `pbzsave coop-sync` | The ledger has no save or partner key, grows forever, is applied in unrelated saves, and records even when Off. Duplicate drops |
| Their Steam transport and rich-presence partner finding (`Network = Steam`, `PartnerSteamID`) | Ours (`net/steam_transport.py`) is sounder: typed structs, friends-only session filter, live ping handshake. Theirs locks onto the first advertiser and never searches again. The two can't talk anyway (channel 47800 vs our 0) |
| AES-256-GCM encryption (Windows CNG) | Their wrapper is correct, but authentication is what matters (game state isn't secret). HMAC is simpler and works everywhere. Could be added later |
| Rust native relay (`relay/**`, `Relay = Native`, `make-release -NativeRelay`) | It speaks their Steam/auth protocol. Shipping it means an unsigned hidden-window exe that changes the router and loads a DLL, so Nexus/antivirus trouble. Bugs: CRLF on the wire when mixed with Python; UPnP chunk decoding panics |
| README / INSTALL edits, version bump to 1.3.0/1.5.0 | They claim an exe ships by default (it doesn't) and present untested Steam/Direct/UPnP as working; the version is ours to decide |
| Mod writing every 33 ms + reading every tick | Would make our tick-counted timers run fast (heal check, aggro) and parse every snapshot 3x as often for nothing |

### Deferred (maybe later, behind an option that's off by default, after an in-game check)

| Piece | What has to happen first |
|---|---|
| Partner's outfit on the ghost (`EquipOutfit(..., true)`) | A save diff showing the wardrobe and save stay untouched |
| Direct connection + UPnP router forwarding | UPnP opt-in; fix crashes on bad router answers (malformed XML, `file://` locations); read limits; renew on a thread; require a Secret |
| Shared bells (`L`) | Check that `ActivateBellByID` doesn't trigger our rest hook (double refresh); it unlocks fast travel ahead of the receiver's progress |
| Codex sharing (`X`) | It writes a TSet from Lua (risky); keep it off both ways |
| Rust `lua_syntax.rs` test idea | A lighter `luac -p` step in CI instead |

## PR #5's newer additions (1.4.0 / 1.5.0)

Reviewed line by line after the first review (commits 46f1150 and 95cd365). Their "verified in game" claim is
mostly not backed: their own COOP_GUIDE says sync wasn't tried in a live co-op session, and regroup, tips and
equipment were only tried solo. The `pbzsave coop-sync` tool the gate/door feature depends on isn't in the repo.

| Piece | Decision | Why / what would have to change |
|---|---|---|
| Partner tips (partner down/back, health at 50%/25%, cutscene, 150 m apart) | **Merged** in new `partner.lua` (+ `partner` command) | Uses our `lastRemoteAt`/`partnerGone`; no regroup prompt; time-based polling. Checked in game: 40% / 20% / down / back / 200 m tips all fired |
| Cutscene awareness (cutscene flag in `P`, ghost hides) | **Merged** (`pbz.lua` `game.inCutscene`, `coop.lua`) | The manager lookup is cached (retried every 2 s while missing). We send `-` as field 10 (their outfit slot) and the flag as field 11, so their versions read it right; added to our ghost-hide rule |
| `status.notify` export | **Merged** | Plus a real fix to their tip widget: it copied an on-screen instance, and there are none until the game shows a tip itself, so their tips never appeared. Ours creates it from the class (`WB_TipsText_C`); seen on screen |
| Regroup (F5 teleport to the partner, `TeleportToTargetPoint`) | **Deferred** (option, default Off) | It takes the partner's map name and coordinates unchecked, so it can load any level. A chapter-1 guest can jump into a chapter-5 area (story skip, kept by autosave). No check for own death/spectating, cutscenes, PvP, boss fog, loading or partner gone; no ground check (can land in the void). Needed: same map only or an allowed-map list plus "area already unlocked here", bounded coordinates, all those refusals, a ground trace |
| Equipment sharing (`J`: accessories, medicine, weapons, Phantom Edge) | **Deferred** (option, default Off), or skip | Critical: the baseline isn't reset when you load another save, so loading a late save mid-session copies your whole inventory to the partner, permanently. Any id the backpack accepts is granted (debug/DLC/boss gear), in both directions, with no host decision. It overlaps our `I` pickups (double grants). Needed: per-save baseline, an id allow-list, never re-send received items, a per-session cap |
| Shared gates, doors, shortcuts, ropes, cages (`A` events, `shared_world.txt`) | **Skipped** | Progression blockers written into any save through a ledger with no save/partner key; `BP_NarrativeCage_C` is likely quest-bound; depends on a `pbzsave` tool that isn't in the repo |
| Live fog gates from the ledger (`OpenByMobScript`) | **Skipped** | Opens arena fog in a world where the boss isn't beaten, in any later session; our own `B`/`K` fog sync already covers live boss fights |
| Challenge-point fix (`EventPipelineManager` name) | **Skipped** | The "fix" switches on the `N` feature we skipped; it still accepts any node id, story flow included |
| `ShareCodex` on by default | **Skipped** | We keep codex sharing off both ways (raw TSet write from Lua) |
| `relay/tests/mod_logic.rs` | **Skipped** (idea kept) | It needs the Rust relay we skipped and runs against stubs. The idea of testing the Lua logic with fakes is worth copying in our own harness |
| README/COOP_GUIDE edits, version 1.4.0/1.5.0 | **Skipped** | Overstated claims; version is ours. Reusable fact: time of day and weather are fixed per area, so players in one area already share them |

## PR #5's newest additions (1.6.0 / 1.7.0): not reviewed yet

Added to PR #5 on 2026-10-30 after the 1.4/1.5 review (commits f33b0c3 and 6c62833, about 680 lines; local
branch `review/pr-5-now`).

| Piece | Status |
|---|---|
| Live gates and doors | not reviewed (the related shared-world feature was skipped) |
| Partner's moves played as montages (`moves.lua`) | **Merged** with fixes: only montage folders (`/PBZCombatAsset/`, `/Game/`) are accepted, the loaded object must be an `AnimMontage`, new loads are capped (30/min), and the ghost isn't steered while a montage plays. PvP keeps ability replays (the PvP double-hit undo needs them). Checked in game: 3 guest swings sent, 3 played on the host's ghost |
| Revive | not reviewed (we chose "each player's death stays their own"; needs a design decision) |
| Shared dialogue | not reviewed |
| Partner HUD and map marker (`hud.lua`) | **Reworked into a compass** (`hud.lua`, `PartnerCompass = On`): their top line ("Partner 82% · 35 m") and the label over the ghost were too big, so we replaced them with a compass. A dry-brush silver line at the top, and a silver seal with 伴 that slides to where the partner is relative to your camera (dim at the ends when behind, red when down, hidden in another area). Art painted in Lumina in the game's ink style (`art/compass_line.png`, `art/partner_dot.png`). Their widget code needed an on-screen tip to copy (none exist), so it never showed |
| Live kick-down stones | not reviewed |
| Regroup on join | not reviewed (regroup itself is deferred) |

## Credit

appdoze is credited in the README, in code comments next to each ported piece, and as `Co-authored-by` on the
commit that brings in their code, so GitHub counts it as their contribution once pushed.
