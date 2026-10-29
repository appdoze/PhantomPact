"""PBZCoop bot friend: a scripted remote player for live tests without a second PC (stdlib only).

It plays the client side through the same files a client mod would use, in its own folder, with a normal
client relay carrying them to the host:

  python -I net/pbzcoop_bot.py --dir <bot folder> [--seconds 90]
  python -I net/pbzcoop_net.py client --dir <bot folder> --peer 127.0.0.1

Each tick it reads the host's snapshot (net_in.txt), runs its player toward the nearest enemy (P line in
net_out.txt), and when in reach "attacks": a move event (M, so the host's ghost swings) and a hit (D) every
ATTACK_EVERY seconds. It reacts to the host's events (K death, B boss fight, R bell rest) and follows the host
when no enemy is near. Everything it does and sees is printed, so a test can check the live back-and-forth.
"""

import argparse
import math
import os
import time

TICK = 0.05
SPEED = 450.0            # cm/s, Hun's jog
REACH = 180.0            # cm, attack range
FOLLOW_GAP = 250.0       # cm behind the host when idle
ATTACK_EVERY = 0.8       # s between hits
HIT_DAMAGE = 60.0
HIT_POSTURE = 25.0
ENGAGE_CM = 3000.0       # only chase enemies within this distance of the host
MOVE = "/PBZCombatAsset/ActorData/Players/Hun/Abilities/WoodenSword/YoungHun/GA_Hun_Young_A.GA_Hun_Young_A_C"


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    for _ in range(5):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            time.sleep(0.002)


def parse_snapshot(text):
    host, enemies = None, {}
    for line in text.splitlines():
        p = line.split()
        if len(p) >= 6 and p[0] == "P":
            host = {"x": float(p[2]), "y": float(p[3]), "z": float(p[4]), "map": p[9] if len(p) > 9 else "?"}
        elif len(p) >= 9 and p[0] == "E":
            enemies[p[1]] = {"x": float(p[2]), "y": float(p[3]), "z": float(p[4]), "hp": float(p[6]),
                             "boss": p[8] == "1"}
    return host, enemies


class Bot:
    def __init__(self, folder):
        self.folder = folder
        self.out = os.path.join(folder, "net_out.txt")
        self.inn = os.path.join(folder, "net_in.txt")
        self.ev_out = os.path.join(folder, "net_events_out.txt")
        self.ev_in = os.path.join(folder, "net_events_in.txt")
        self.session = f"bot{int(time.time())}"
        self.next_id = 1
        write_atomic(self.ev_out, f"S {self.session}\n")
        self.pos = None
        self.yaw = 0.0
        self.seq = 0
        self.target = None
        self.last_attack = 0.0
        self.dead = set()
        self.in_session, self.in_done = None, 0
        self.stats = {"hits": 0, "moves": 0, "kills_seen": 0, "boss_fights": 0, "rests": 0}

    def event(self, kind, *args):
        with open(self.ev_out, "a", encoding="utf-8") as f:
            f.write(" ".join([str(self.next_id), kind] + [str(a) for a in args]) + "\n")
        self.next_id += 1

    def host_events(self):
        text = read_text(self.ev_in)
        session = text[2:].split("\n", 1)[0].strip() if text.startswith("S ") else None
        if session != self.in_session:
            self.in_session, self.in_done = session, 0
        for line in text.splitlines():
            p = line.split()
            if len(p) >= 2 and p[0].isdigit() and int(p[0]) > self.in_done:
                self.in_done = int(p[0])
                kind = p[1]
                if kind == "K" and len(p) > 2:
                    self.dead.add(p[2])
                    self.stats["kills_seen"] += 1
                    print(f"host: {p[2]} died", flush=True)
                    if self.target == p[2]:
                        self.target = None
                elif kind == "B":
                    self.stats["boss_fights"] += 1
                    print(f"host: boss fight with {p[2] if len(p) > 2 else '?'}", flush=True)
                elif kind == "R":
                    self.stats["rests"] += 1
                    self.dead.clear()
                    print("host: rested at a bell, enemies respawned", flush=True)

    def step(self, now, dt):
        host, enemies = parse_snapshot(read_text(self.inn))
        self.host_events()
        if host is None:
            return
        if self.pos is None:
            self.pos = {"x": host["x"] - FOLLOW_GAP, "y": host["y"], "z": host["z"]}
            print("bot joined beside the host", flush=True)
        live = {k: e for k, e in enemies.items() if k not in self.dead and e["hp"] > 0
                and math.hypot(e["x"] - host["x"], e["y"] - host["y"]) <= ENGAGE_CM}
        if self.target not in live:
            self.target = min(live, key=lambda k: math.hypot(live[k]["x"] - self.pos["x"],
                                                             live[k]["y"] - self.pos["y"]), default=None)
            if self.target:
                print(f"bot: engaging {self.target} (hp {live[self.target]['hp']:.0f})", flush=True)
        goal, reach = (live[self.target], REACH) if self.target else (host, FOLLOW_GAP)
        dx, dy = goal["x"] - self.pos["x"], goal["y"] - self.pos["y"]
        dist = math.hypot(dx, dy)
        speed = 0.0
        if dist > reach:
            step = min(dist - reach, SPEED * dt)
            self.pos["x"] += dx / dist * step
            self.pos["y"] += dy / dist * step
            speed = step / dt
        self.pos["z"] = goal["z"]
        if dist > 1:
            self.yaw = math.degrees(math.atan2(dy, dx))
        if self.target and dist <= reach + 20 and now - self.last_attack >= ATTACK_EVERY:
            self.last_attack = now
            self.event("M", MOVE, f"{self.yaw:.1f}")
            self.event("D", self.target, f"{HIT_DAMAGE:.1f}", f"{HIT_POSTURE:.1f}")
            self.stats["moves"] += 1
            self.stats["hits"] += 1
        self.seq += 1
        write_atomic(self.out, f"P {self.seq} {self.pos['x']:.1f} {self.pos['y']:.1f} {self.pos['z']:.1f} "
                               f"{self.yaw:.1f} {speed:.0f} 850.0 850.0 {host['map']}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--seconds", type=float, default=90)
    args = ap.parse_args()
    os.makedirs(args.dir, exist_ok=True)
    bot = Bot(args.dir)
    start = last = time.monotonic()
    while time.monotonic() - start < args.seconds:
        now = time.monotonic()
        bot.step(now, max(0.001, now - last))
        last = now
        time.sleep(TICK)
    print("bot stats: " + " ".join(f"{k}={v}" for k, v in bot.stats.items()), flush=True)


if __name__ == "__main__":
    main()
