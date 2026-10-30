# Fork extras (appdoze/PhantomPact)

This fork is upstream [yhsharaf/PhantomPact](https://github.com/yhsharaf/PhantomPact) `main` plus a few modules that
upstream hasn't taken (see upstream's `docs/reviews/appdoze-merge-status.md` for why). They load from one line in
`main.lua` (`fork.lua`), read their own settings from `PhantomPact.ini` (the "Fork extras" block at the end), and
touch upstream files in three small places only: the `fork.lua` line in `main.lua`, the enemy glide and the
guest-side ghost aggro in `coop.lua`, and `coop_sync_after_game` in `net/pbzcoop_net.py`.

"Solo" = one game with stand-ins (a spawned copy of the player as the partner, or a fake network); nothing here was
played between two PCs.

| Module | What it does | Checked |
|---|---|---|
| `sync.lua` (`ShareProgress`) | Quests, bells, enemy-group rewards, challenge points, codex, quest steps, base-game equipment and upgrades, chests, rubbish piles, gates, doors, ropes, blocked paths, kick-down stones, lifts; catch-up (`CatchUp`); a cycle/difficulty tip | Every scan and receive handler ran in game with a fake network (solo); the game functions each one calls were checked in game one by one |
| `regroup.lua` (`RegroupKey`, `ReviveAtPartner`, `RegroupOnJoin`) | Teleport to the partner inside the area you're both in; revive at the reviver's side through the game's revive point | The teleport and the revive point read/set/restore in game (solo); a real revival not tested |
| `dialogue.lua` (`ShareDialogue`) | The partner's dialogue lines as tips | Offline only (no conversation was open while testing) |
| `mapicon.lua` (`PartnerMapIcon`) | Your own map icon in cyan at the partner's position, turned the way they face | In game with a stand-in position (solo), on game screenshots |
| `smoothing.lua` | Guest: mirrored enemies glide back to the host's position, jump only across 20 m | Offline only |
| `coop.lua` (2 lines) | Guest enemies also add the host's ghost to their target list | Offline only |
| `CoopSyncTool` (relay) | When the game closes, runs `pbzsave coop-sync` for each `shared_world_<slot>.txt` | Relay test with a stand-in tool |

## Fixes from upstream's review

- The ledger is per save slot (`shared_world_<slot>.txt`, the save system's continue slot), and nothing is recorded
  while sharing is off or before a save is loaded. `pbzsave coop-sync` takes the slot from the file name.
- Loading another save mid-session starts a new baseline for it (nothing from it is sent as new progress).
- Equipment: only base-game ids (`equipment.txt`, read from a complete save) are granted, at most 40 equipment and
  upgrade grants per session, and received items aren't sent back.
- Regroup: only within the area you're both in (never loads another level), not while you or your partner is down,
  in a cutscene, in PvP or silent; it lands on the partner's own position.
- Widgets: the fork's tips go through upstream's `status.notify` (which creates the tip from its class).
- Rust relay (`relay/`): CRLF from the mod's files no longer reaches the wire; chunked UPnP replies are decoded on
  bytes (a chunk boundary inside a UTF-8 character panicked).

## Not compatible: the Rust relay

`relay/` speaks the protocol of the fork's earlier relay (AES-GCM / HMAC with SHA-256 keys, Steam channel 47800).
Upstream 1.3 changed it (scrypt-stretched HMAC with a time window, its own Steam transport on channel 0, a different
hello). Upstream's `autostart.lua` starts only its Python relay, so `relay/` isn't used; it stays for its tests (the
Lua checks above run from it) until it is ported to the new protocol.
