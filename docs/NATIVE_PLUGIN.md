# The native relay (Rust) instead of the Python relay

Status: implemented in `relay/`, but **not compatible with upstream 1.3+** (its relay changed the protocol; see
[FORK_EXTRAS.md](FORK_EXTRAS.md)). Not started by the mod; kept for its tests until it is ported.

It was a drop-in for the fork's earlier `net/pbzcoop_net.py` (before upstream 1.3): same command line, same files in
the mod folder, same wire protocol (JSON packets `v = 2`, hello/settings exchange, AES-256-GCM / HMAC framing, replay
window, address filter, UPnP, Steam Networking Messages), and played together with that Python relay. Upstream now
bundles Python with the mod, so the original reason (no Python needed) is gone too.

## Why a separate program, not a DLL inside the game

The first design (below, kept for reference) was a UE4SS C++ mod running the relay on a thread inside the game.
It was rejected, for a Rust build too:

- UE4SS for PBZ (3.0.1-1183-gcdbc0b66) exports no Lua C API, so a native Lua module can't register functions for
  the Lua mod. The only native entry point is UE4SS's C++ mod ABI (C++ classes compiled against UE4SS's own
  headers with MSVC). Reproducing that ABI from Rust means matching C++ vtable layouts by hand, and any mismatch,
  or any UE4SS update, crashes the game.
- A crash in an in-process plugin takes the game (and possibly an unsaved run) down. A separate relay can only fail
  by itself; the mod sees `net_status.txt` go stale.
- The file hand-off costs one 5 ms file check per direction (median 11-13 ms file to file on loopback, measured by
  the Latency tests), small next to network latency.

So the relay is native code but out of process: it removes the Python requirement, starts faster and uses less
memory, and keeps the game safe.

## Tests

- `cargo test --release --manifest-path relay/Cargo.toml`: packet protection (round trip, tampering, replay,
  downgrade), event files, ini, UPnP URL handling, settings comparison, and a Lua 5.4 compile of every mod script.
- `python -I net/test_pbzcoop_net.py` runs every loopback, security, handshake, Direct/UPnP and latency test again
  with native-native, native-host/Python-client and Python-host/native-client pairs (when the release build exists,
  or `PBZ_RUST_RELAY` points at it). CI does both on Windows and Linux.
- Steam: checked by hand with the game's `steam_api64.dll` and Steam running (SteamAPI_InitFlat, the user's
  SteamID, SendMessageToUser).

## Earlier proposal: in-process UE4SS C++ mod (not built)

A `PBZCoopNet.dll` loaded by UE4SS that would run the relay protocol on a background thread and expose
`PBZNet.Start / SendSnapshot / SendEvent / PollSnapshot / PollEvents / Status` to Lua, replacing the files. It
would have used the game's already-initialised Steam API in process. Costs: an MSVC build against the exact UE4SS
version, Nexus quarantine of `.dll` uploads, and game crashes from any bug.
