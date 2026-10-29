# Who decides what

Phantom Pact runs two full copies of the single-player game, one per PC. Nothing is shared by default: each game
simulates its own world. The mod then decides, per system, whose copy is the truth and what crosses the network.
The rule of thumb: **sync outcomes, not inputs and not every variable.** A hit is sent as "this much damage",
a kill as "this enemy died", never as raw animation state or per-frame values that the other game already
simulates on its own.

Host = the player whose world is shared (Role = Host). Client = the guest.

## The map

| System | Decided by | Runs where | Crosses the network as | Runs once because |
|---|---|---|---|---|
| Your own player: movement, stamina, healing, items used | **That player** | own PC | snapshot `P` (position, facing, speed, health), 20x/s, newest wins | the other side only steers a ghost toward it, never simulates it |
| Your own hits taken, your death | **That player** | own PC | health in `P`; hit reactions as `H` | the ghost is cosmetic: kept at full health on the host, its health shown, never killed |
| Moves (attacks, dodges, guard) | **That player** | own PC | `M <ability>` when a move starts | the ghost replays it for the animation; the ghost has Attack 0 in co-op, and in PvP its hits on enemies are undone (below) |
| Enemy position, health, posture | **Host** | host simulates; client mirrors | snapshot `E` lines from the host, for enemies within 60 m of either player (so a client fighting far from the host still fights the host's enemy) | the client only ever lowers its copy to the host's numbers (or follows a heal the host keeps for 1 s) |
| Enemy AI (which attack it throws) | each world | both | not synced | each world's enemy fights the players in it; outcomes (health, death) are the host's |
| Client hits on enemies | **Client detects, host applies** | client measures its copy's drop, host applies it | reliable `D <enemy> <hp> <posture>` | event ids are acked and played once; a drop caused by the ghost's replay is undone, not reported |
| Enemy death | **Host** | host | reliable `K <enemy>` | the client's copies of host enemies are held at 1 health (Health_Min) so they can't die on their own; a client hit that reaches that floor is sent as lethal (`D ... L`) and the host kills; only `K` kills the copy, once, even if it loads later |
| Enemy spawning | each world's own level | both | not synced (both load the same level) | the mod never spawns enemies; matching pairs the two copies (spawner id, else class + position) |
| Boss fight start | **whoever starts it** | both | `B <boss>` | the receiving side shows the bar and closes the fog walls; its own hook ignores the mirrored start, so it never echoes |
| Boss phases | **Host** (through health) | both run the boss's own phase logic | host health in `E` | phases follow health; a heal on the host reaches the client after 1 s instead of being ignored |
| Bell rest (enemies respawn) | **whoever rests** | both | `R bell` | the receiver's refresh is flagged as mirrored, so it isn't sent back |
| Death respawn | **the one who died** | own PC (the game refreshes your world) | host: `R death`; client: nothing | a client's death leaves the host's world (and fight) alone; the client re-kills what the host killed |
| Pickups | **whoever picks it up** | own PC | reliable `I <pickup> <item>` | the other side removes its copy and gets the item; if both grabbed it in the same moment, nobody gets a second one |
| Dust (currency) | **whoever earns it** | own PC | reliable `C <amount>` | amounts the mod added for the other player are excluded from what it sends back |
| PvP (duels) | **the defender** | each player's own PC | `V lose`, `V parry` | the loser's own PC decides the death; scores move once per death |
| Events in general | sender | | `<session> <id> ...` | the relay resends until acked; the receiver plays ids in order, once each, per session |

## The duplication cases, one by one

**Duplicate enemy damage.** Your swing hits your copy of the enemy. That drop is reported once (`D`) and applied
once on the host. Your ghost in the other world replays the swing for show. In co-op the ghost's Attack is 0, so it
does no damage (measured: 600 to 600 health). In PvP the ghost needs a real Attack to hit the other player. Its
hits on enemies did land (measured: 600 to 536, and they were reported as the receiver's own). Now a drop that
follows a ghost replay, with no local move started, is undone instead of reported. That check is on the client for
every copy, and on the host in PvP.

**Duplicate item pickups.** Both players can grab the same item in the same 100 ms. Each then also receives the
other's `I`. The pickup you took yourself is remembered per map, and the other's `I` for it then only removes
nothing and grants nothing.

**Duplicate enemy spawning.** The mod spawns no enemies. Both games load the same level, and the client pairs
each host enemy with its own copy. Bell refreshes are mirrored once (`R`), never echoed back.

**Conflicting player movement.** Each player is only ever moved by their own game. The ghost walks toward the
received position and is the only thing moved by the network. Ghost collision ignores pawns, so it never pushes.

**Repeated animation events.** A move is sent when it starts, not every tick. A hit reaction already playing
on the ghost isn't restarted by the same hit arriving over the network. On the host, enemies hit the ghost too.

**Desynchronized boss phases.** Phases follow health, and the host owns health. Before, the client only ever
lowered its copy, so a boss that healed in a phase stayed low on the client and could die there first. Now a heal
the host keeps for a second is followed, and the client's copy can't die before the host's anyway.

**Multiple executions of the same game event.** Every event has a session and an id. It is resent until acked,
and played once in order. A killing blow on the client doesn't kill its copy locally (Health_Min 1). The host's
`K` does, so death animations, drops and boss-beaten logic run once per world, at the host's word.

## Deaths, spectating, and the boss fight

- **You die (either role):** the death screen plays. After 3 s, the camera follows your partner while they're
  up and on your map. It comes back to you when you respawn, or sooner if they go down too. The death screen is
  dimmed, not removed: removing it would run the game's monster refresh.
- **The client dies while the host fights a boss:** the client's game respawns it at its bell and refreshes the
  client's world, as single-player would. The host's world isn't touched, so the host's boss fight goes on. When
  the host wins, `K` reaches the client and kills its copy of the boss. Enemies the host had already killed are
  killed again in the client's refreshed world.
- **The host dies while the client fights a boss:** the host's world is everyone's truth, and the host's game
  refreshes it. So both worlds refresh and the fight starts over, as when the host dies in Elden Ring co-op.
  Until the host respawns, the host's boss keeps fighting the client's ghost, and the client's hits still land.
  The client can finish the boss in that window.

- **Your partner vanishes** (quits, crashes, loses the connection): after 5 s with nothing heard, their ghost
  hides instead of standing frozen. Fog walls closed for their fight open, and the enemies held for the host go
  back to normal. Their last snapshot is ignored even if a crashed relay left it on disk.

## What can't be checked in the prologue

The tested save is in the prologue. The game blocks respawns there (`RespawnSequenceBlockTag`, "first teleport
into the ambush forest"), and kills there pay no dust. Checked by calling the respawn's own refresh step, not by a
real respawn:

- a real death respawn (it also autosaves and costs "days", so it isn't run on a real save)
- dust for a kill made by the client's reported hit. The host kills that enemy with no instigator and the client's
  copy dies by the host's word, so the game may pay that kill to nobody. Kills pay no dust in the prologue at all,
  so this needs a later save to check.
- whether a boss killed by reported damage counts as beaten for the host's save

## Executions and late joins

- **Executions** (`GA_SimpleExecution_Young` and the other execution abilities) aren't sent as moves. Only
  `GA_Hun_*` moves are, so the ghost never replays one. A paired execution animation would grab the other world's
  copy of the enemy and could hit it a second time. The partner sees the enemy fall when the host's `K` arrives.
  Measured: five client swings took a thug from 600 to 68 in both worlds, with five reports and five applied.
- **Joining late or rejoining:** events are kept for the whole host session and resent until the client acks them.
  A client that rejoins with its inbox on disk only plays what it hasn't seen. A first join mid-session plays the
  host's whole backlog once: deaths (`K`), rests, shared items and dust from before it joined. That's the same
  "shared rewards" rule, applied late, not a duplicate.

## Known limits

- If both players swing at the same enemy within the same 1.5 s in PvP, the ghost's replay can't be told from your
  own hit, so that drop is reported. It's harmless outside PvP, where the ghost does no damage.
- Enemy AI isn't synced: each world's copy picks its own attacks. Its position snaps back if it drifts over 4 m.
