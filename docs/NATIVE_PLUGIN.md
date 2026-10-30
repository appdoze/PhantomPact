# Design: a native UE4SS plugin instead of the Python relay

Status: proposal, not implemented. Removes the Python requirement and the file hand-off between the mod and the
relay, which are the two remaining costs of the current design (install step, and ~15-25 ms of local latency
plus file-system timing jitter).

## Today

```
game (UE4SS Lua mod) --net_out.txt / net_events_out.txt--> relay (Python, UDP / Steam) --network-->
relay --net_in.txt / net_events_in.txt--> game
```

Lua in UE4SS has no sockets, so the mod and the relay meet in text files. The relay is ~1000 lines of stdlib
Python: snapshots (newest wins), reliable numbered events with acks, a hello/settings exchange, AES-GCM / HMAC
packet protection, an address filter, UPnP, and Steam Networking Messages.

## Proposal

A UE4SS C++ mod (`PBZCoopNet.dll` in `Mods/PBZCoop/dlls/main.dll`, loaded by UE4SS like Lua mods) that runs the
relay's protocol on a background thread inside the game process and exposes it to the Lua mod as functions:

| Lua side (registered by the C++ mod) | Replaces |
|---|---|
| `PBZNet.Start(role, settingsTable)` / `PBZNet.Stop()` | starting `pbzcoop_net.py` with `os.execute` |
| `PBZNet.SendSnapshot(text)` | writing `net_out.txt` |
| `PBZNet.SendEvent(line)` | appending to `net_events_out.txt` |
| `PBZNet.PollSnapshot()` -> text or nil | reading `net_in.txt` |
| `PBZNet.PollEvents()` -> array of lines | reading `net_events_in.txt` |
| `PBZNet.Status()` -> table | reading `net_status.txt` |

The wire protocol stays exactly the relay's (JSON packets, `v = 2`, same hello, same AES-GCM framing), so a native
player and a Python player interoperate during a transition.

Transports:
- UDP: Winsock, non-blocking, polled from the network thread.
- AES-GCM: Windows CNG (`BCryptEncrypt`), as the relay already does through ctypes.
- Steam: the game's own `steam_api64.dll` is already loaded in the process, so `SteamNetworkingMessages()` can be
  used directly, without a second `SteamAPI_Init` (the relay's separate process needs its own).
- UPnP: the same SSDP + SOAP calls with WinHTTP.

## Costs and risks

- Build: UE4SS's C++ mod template must be compiled against the exact UE4SS version shipped for PBZ
  (3.0.1-1183-gcdbc0b66) with MSVC; a UE4SS update can require a rebuild.
- Distribution: Nexus quarantines `.dll` uploads in mods that aren't marked as containing executables; the mod
  page has to declare it. Players have to trust a binary instead of readable Python.
- A crash in the DLL takes the game down; the Python relay can only fail by itself. The network thread must
  never call game objects (only the Lua side does, on the game thread).

## Suggested path

1. Keep the Python relay as the reference implementation and test suite (net/test_pbzcoop_net.py drives it over
   files; the same tests can drive the DLL through a small Lua harness).
2. Build the DLL with UDP + hello + events first, behind `Transport = Native` in PhantomPact.ini.
3. Add AES-GCM, then Steam (in-process), then UPnP.
4. Make Native the default once a release has been played in both roles without the Python relay.
