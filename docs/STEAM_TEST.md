# Testing Steam joining (two real accounts)

The one thing not yet tested is Steam carrying Phantom Pact's traffic between two different Steam accounts. Since 1.4
the relay runs inside the game and shares the game's Steam connection. `tools\steam-check.ps1` shows that much on one
PC: both copies reach Steam and stay up. The first thing to watch in a real test is the host taking the guest's
session: that request reaches the DLL through a Steam callback, which only fires if the game runs Steam callbacks, and
one account can't test that alone.
This needs two people, or one person with two PCs, each signed into their own Steam account that owns the game.

## Setup (both players)

1. Install the local build: `tools\install-mod.ps1` on your PC. The friend extracts the zip from
   `tools\make-release.ps1` into their game folder.
2. Both players are Steam friends, and Steam is running and signed in.
3. In `platform\steam\ue4ss\Mods\PBZCoop\PhantomPact.ini`:
   - Host: `Role = Host` and `Connect = Steam`.
   - Guest: `Role = Guest` and `Connect = Steam`. Leave `HostAddress` as is to join any friend who's hosting,
     or put the host's Steam name there.

## Run

1. The host starts the game and loads the save (CONTINUE).
2. The guest starts the game and loads theirs.
3. Within a few seconds each player should see the other's character.

## What to look for

In `platform\steam\ue4ss\UE4SS.log`, both players:

- `Relay started as host over Steam.` / `Relay started as guest, looking for a Steam friend who's hosting over Steam.`
- Guest: `found the host: <host's Steam name>` in the relay output, then `Phantom Pact Guest: co-op on`.
- `netstatus` (type it in `cmd.txt`): `via=steam connected=yes peer=<the other's name>` with an `rtt_ms` value.

Then play a minute: hit an enemy as the guest (its health drops for the host too), kill one as the host (it dies
for the guest too), and pick something up.

## If it doesn't connect

- `Steam isn't ready` in `relay_error.txt`: Steam isn't running or signed in.
- The guest sees the host but never connects, and the host shows no `peer connected` in `relay_log.txt`: the session
  request didn't reach the DLL (see above). That's a mod bug, so send both logs.
- The guest keeps `looking for a Steam friend`: the two accounts aren't Steam friends, or the host isn't in the
  game yet. Putting the host's Steam name in `HostAddress` rules out picking the wrong friend.
- Send both `UE4SS.log` files. Tailscale (`Connect = Tailscale`) keeps working as before in the meantime.
