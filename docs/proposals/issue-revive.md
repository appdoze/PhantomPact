# Revive, Nightreign style: design proposal

This is the design issue you asked for before anyone builds revive. Nothing here is built yet, and nothing here
writes to a save. The "Checked" notes below come from one PC, solo, on build 26266538, with the save snapshotted and
compared byte-for-byte afterwards. Nothing has been tried with two copies or two PCs yet.

## What Nightreign does

| Rule | Nightreign |
|---|---|
| Going down | At 0 HP you don't die. You fall into a near-death state with a ring gauge over you. |
| Reviving | Teammates **attack the downed player**. Any attack counts: light, heavy, arrows, skills. Each hit drains the gauge. |
| Harder each time | Every down in the same stretch adds a segment. It grows faster than the UI shows: about 6x the work at 3 segments compared with 1. |
| Reset | Resting at a Site of Grace clears the segments. |
| Bleed-out | Outside boss fights, a timer of about 15 s runs out and you die normally: you respawn at grace and pay the usual penalty. |
| Boss fights | No timer. Teammates are the only way back. If everyone is down, the run fails. |
| Revived | You get back up with part of your health (guides say 40%). |

Sources: [eldenring.wiki.gg Near-Death Gauge](https://eldenring.wiki.gg/wiki/Near-Death_Gauge),
[PC Gamer (3 segments ≈ 6x)](https://www.pcgamer.com/games/rpg/you-arent-just-imagining-things-elden-ring-nightreign-player-confirms-its-6x-harder-to-revive-someone-at-3-bars-when-compared-to-1-because-fromsoftwares-ui-is-basically-lying-to-you),
[Beebom (death and respawn)](https://beebom.com/elden-ring-nightreign-death-explained),
[Deltia's (40% health)](https://deltiasgaming.com/?p=248672),
[Automaton (why attacks revive)](https://automaton-media.com/en/news/elden-ring-nightreigns-devs-thought-it-looked-funny-to-revive-teammates-by-attacking-them/).
Guides disagree on the exact timer and segment counts.

## Proposal for Phantom Pact

### Rules

| | Proposal |
|---|---|
| Going down | A hit that would kill you leaves you at 1 HP, **downed**. You can't move and you take no damage. Your partner sees the red compass seal and a tip (no lying pose in v1; see below). |
| Reviving | Your partner strikes your ghost: each attack they **start** within 3 m and facing you (within 60°) counts as one strike. |
| Strikes needed | 1st down: 3. 2nd down: 6. 3rd and later: 10. Resting at a bell resets the count (that's our Site of Grace). |
| Bleed-out | 15 s, then a normal death: the game's own death screen, respawn and enemy refresh, as today. |
| Boss fights | No timer while a boss bar is up. If both players are down, both die normally. |
| Revived | 40% of max HP, a second of i-frames (the invulnerability effect is removed a moment later), and your input back. The health must be set through a path the game hears about: writing `Health` directly (as `game.setHealth` does for ghosts) left the low-health screen look on after a test, until the game's own `GM_FullHeal` cleared it. |
| No revive (normal death right away) | Solo, or the partner is silent or gone (`partnerGone`); a different map; PvP on; either player in a cutscene; the partner is already down or dead; scripted kills. **Falls:** the floor catches fatal falls too (checked below), so a hit that lands you at 1 HP while your movement was `Falling` the moment before counts as a fall: the floor drops to 0 and you die as normal. |

Each player's game still decides that player's own life, as the mod does today. The downed player's PC holds the
gauge and the timer. The reviver's PC only reports "I swung at you".

### How it would work in game

| Piece | How | Proven? |
|---|---|---|
| Can't die while revivable | `Health_Min = 1` on our own pawn while the rules above allow a revive, back to 0 otherwise. This is `game.setMinHealth`, the same call that holds the client's enemy copies at 1. | **Checked on the player:** at 30 HP next to an enemy, health went to 1 and stayed there for every hit after; no death. |
| Detect "downed" | Health at 1 right after a hit, while `Health_Min` is 1. | Follows from the check above. |
| No damage | `asc:BP_ApplyGameplayEffectToSelf(GA_PlayerUtilitiesPassive.LieInvulnerableEffect, 1, ctx)`. Both lie and get-up point to one class, `GE_PBZLieInvulnerable`. | **Checked:** with it on and `Health_Min` back at 0, an enemy 1–2 m away for 40 s did no damage (30 HP stayed 30). `RemoveActiveGameplayEffect` took it off cleanly (count 0). It doesn't block input or lay you down. The screen shows the game's own low-health look. |
| Lying down | `/PBZCombatAsset/ActorData/Players/Hun/Montage/Hit/AM_Hun_Unarmed_HitDown_B` (0.97 s), then `AM_Hun_Unarmed_Getup_B` (1.23 s). Both are under `/PBZCombatAsset/`, so `moves.lua` accepts them and the ghost plays them. | **Rejected after testing.** Playing these hit montages raw on the player crashes the game when they end: three times, paused or not, the last one right after a normal get-up. They likely carry notifies that expect the game's knock-down ability to be running. The pose itself holds fine (seen on screen). |
| Lying down via the hit state | `HitreactComponent:ChangeHitState({TagName = "CharacterState.Hitreact.State.Lying"})` on the player. | **Rejected: it crashed the game at once.** `ChangeHitState` is safe for PvP's stagger, but not for `Lying`. |
| **Downed look (v1)** | No pose. While down: the invulnerability effect, input blocked, the game's own low-health screen look (it appears by itself at low health), and on the partner's side the red compass seal and a tip. A real knock-down pose needs the game's own knock-down ability, which no mod call has started safely. | Every piece here was checked safe. |
| No input while down | `PlayerController:SetIgnoreMoveInput(true)`, then `ResetIgnoreMoveInput()` on revive or bleed-out. | **Checked:** the flag sets and resets. Whether it really stops movement needs someone pressing keys. |
| Counting strikes | The reviver's own attack montages, which `moves.lua` already sees, checked against the ghost's distance and facing. No faction change and no hit boxes on a friendly ghost. | The montage half is proven; the range check is plain math. |
| Bleed-out | `game.setMinHealth(pawn, 0)` then `game.kill(pawn)`. The game's normal death flow runs, so `hookRest` "death" and spectating work unchanged. | `game.kill` is proven on enemies. |
| Boss fight | `game.isBoss` and the boss-bar registration already in `pbz.lua`. | Exists. |
| Bell resets the count | `game.hookRest(onRest)`, kind "bell". | Exists. |
| Compass | The seal turns red while the partner is downed (it already does on death), plus a tip: "Partner down: strike them to revive (3)". | Exists. |

New reliable events (the same channel as `B`/`K`/`R`):
`DOWN <need> <secondsLeft|-1>` (downed), `STRIKE` (reviver → downed), `UP` (revived), `OUT` (bled out).

### Saves

Nothing is written to a save:
- Everything is a runtime attribute, effect or input flag.
- While downed, the mod holds a save veto: `EnterSaveVeto("PhantomPactDown", DeathIntrinsic)`. That's the
  reason the game uses around its own deaths, so no autosave can catch you at 1 HP.
- The game postpones a vetoed save (`TrySave` returns `Suspended`), so the save fires when you're back up or dead.

Checked: no health attribute is stored in a save slot at all (no `Health` or `Health_Min` in any slot's JSON).
A stuck `Health_Min` of 1 could only last until the next load, never into a save. Every exit path still has to put
it back to 0.

### Settings

`Revive = Off` by default until a two-PC run.
Tunable: `ReviveStrikes = 3,6,10`, `BleedOutSeconds = 15`, `ReviveHealth = 40`.
`Revive` goes in `SHARED_SETTINGS`, so both players must agree.

### In-game checks (solo done; two copies and two PCs to do)

1. **Done:** `Health_Min = 1` on the player holds against enemy hits. **It also holds against falls:** a 60 m drop
   took 3596 HP to exactly 1, and the player lived. Hence the fall rule above (a fall that would kill still kills).
2. **Done:** the lie effect makes you invulnerable and comes off cleanly.
3. **No pose in v1:** forcing a lying pose on the player crashed the game four times (raw montages ending three
   times, the `Lying` hit state once). The downed state goes without a pose. If you know a safe way into the game's
   knock-down ability, it can come back later.
4. *To do (two copies):* strikes. Three swings in range count 3; out of range or facing away count 0.
5. *To do (two copies):* bleed-out. A normal death and respawn, enemies refresh as today, and spectating starts.
6. **Done differently:** health isn't in the save at all, so a down can't leak into one.
7. *To do (two copies):* a boss fight. No timer; both down → both die.

### Open questions for you

- Strike counts and the 15 s timer: keep Nightreign's numbers, or tune them for Phantom Blade's faster fights?
- Should a revive cost something (a medicine charge, some Sha Qi), or stay free like Nightreign?
- Should ranged attacks and weapon skills count as 2 strikes, like Nightreign's stronger attacks filling more?
- Do you know a safe way to start the game's own knock-down from Lua? Your `moves.lua` works with the game's
  montages, so you may see something I missed. With it, the downed player could really lie on the ground.
