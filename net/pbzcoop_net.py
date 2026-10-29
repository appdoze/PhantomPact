"""PBZCoop network relay: carries game state between two PCs over UDP (designed for Tailscale IPs).

The game mod and this relay talk through small text files in the mod folder:
  net_out.txt         written by the mod: the local snapshot, several lines (player "P ...", enemies "E ...")
  net_in.txt          written by the relay: the remote side's latest snapshot
  net_events_out.txt  written by the mod: "S <session>" then one numbered event per line ("<id> <type> <args>")
  net_events_in.txt   written by the relay: the remote side's events, in order, same format
  net_status.txt      written by the relay: connection state, peer address, round-trip time

Snapshots are newest-wins: a lost packet is simply replaced by the next one 50 ms later.
Events (attacks, kills, pickups) are reliable: resent every tick until the peer acknowledges them.
The relay doesn't interpret either; only echo mode shifts the "P" line so the fake friend stands aside.

Usage:
  host:   python -I pbzcoop_net.py host   --dir <mod folder>
  client: python -I pbzcoop_net.py client --dir <mod folder> --peer 100.112.4.45
  echo:   python -I pbzcoop_net.py echo   --dir <mod folder>
          (no network: plays your own snapshot and events back, 3 m to the side and 0.3 s late, as a fake
          friend for solo testing)
  record: python -I pbzcoop_net.py record --dir <mod folder> --file host.jsonl       (mod as host)
  replay: python -I pbzcoop_net.py replay --dir <mod folder> --file host.jsonl --client-log client.txt
          (mod as client, ideally in a fresh game session: a recorded real host plays against the client)
"""

import collections

import argparse
import json
import os
import select
import socket
import time

PORT = 47800
TICK = 0.05          # 20 sends per second
PING_EVERY = 1.0
PEER_TIMEOUT = 3.0
PROTOCOL = 2
MAX_EVENTS_PER_PACKET = 40
MAX_SNAPSHOT_BYTES = 48000


def read_text(path):
    # errors="replace": a stray non-UTF-8 byte (e.g. a half-written multibyte name) must not kill the relay.
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return ""


def read_complete_lines(path):
    """read_text, minus a last line the mod is still writing (no newline yet): it is sent once it's complete."""
    text = read_text(path)
    return text[:text.rfind("\n") + 1]


def write_atomic(path, text):
    """Returns False if the file couldn't be written this time; the next tick writes fresh data anyway."""
    tmp = path + ".tmp"
    # The mod may have the file open for a moment, and Windows can briefly refuse a rename for other reasons
    # (WinError 1450 "insufficient system resources" killed a relay mid-session): retry, then skip, never crash.
    for attempt in range(5):
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, path)
            return True
        except OSError:
            time.sleep(0.002 * (attempt + 1))
    return False


def append_lines(path, lines):
    """Returns False if the lines couldn't be appended (the caller keeps them and retries next time)."""
    for attempt in range(5):
        try:
            with open(path, "a", encoding="utf-8") as f:
                f.write("".join(line + "\n" for line in lines))
            return True
        except OSError:
            time.sleep(0.002 * (attempt + 1))
    return False


def parse_events(text):
    """Return (session, [(id, line), ...]) from an events file."""
    session, events = None, []
    for line in text.splitlines():
        parts = line.split(" ", 1)
        if not parts or not parts[0]:
            continue
        if parts[0] == "S" and len(parts) == 2:
            session = parts[1].strip()
        elif parts[0].isdigit():
            events.append((int(parts[0]), line))
    return session, events


class EventInbox:
    """Writes the peer's events to net_events_in.txt exactly once each, in order."""

    def __init__(self, path):
        self.path = path
        self.session = None
        self.last_id = 0

    def accept(self, session, events):
        if session != self.session:
            # The peer restarted its mod: start a fresh file so old events aren't replayed.
            if not write_atomic(self.path, f"S {session}\n"):
                return self.last_id if self.session == session else 0
            self.session = session
            self.last_id = 0
        fresh, last = [], self.last_id
        for eid, line in sorted(events):
            if eid == last + 1:
                fresh.append(line)
                last = eid
        # Only acknowledged once written: if the write fails the peer keeps resending them.
        if fresh and append_lines(self.path, fresh):
            self.last_id = last
        return self.last_id


class UdpLink:
    """Plain UDP (Tailscale or LAN IPs). Peers are (ip, port) tuples."""

    def __init__(self, role, peer, port):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setblocking(False)
        self.sock.bind(("0.0.0.0", port if role == "host" else 0))
        # Resolved once (a Tailscale name works too): replies are matched against this exact address.
        self.peer = (socket.gethostbyname(peer), port) if role != "host" else None

    def send(self, addr, data):
        self.sock.sendto(data, addr)

    def receive(self):
        out = []
        while True:
            try:
                data, addr = self.sock.recvfrom(65535)
            except BlockingIOError:
                return out
            except ConnectionResetError:
                # Windows reports ICMP "port unreachable" this way while the peer isn't running yet.
                continue
            out.append((addr, data))

    def wait(self, seconds):
        """True once a packet is waiting (or False when the time ran out)."""
        return bool(select.select([self.sock], [], [], seconds)[0])

    def candidates(self):
        return []

    def describe(self, addr):
        return f"{addr[0]}:{addr[1]}"

    def describe_self(self):
        return f"UDP {self.sock.getsockname()[1]}"


class SteamLink:
    """Steam P2P through the game's steam_api64.dll. Peers are SteamID64s; only Steam friends are accepted.

    A guest with no host given finds one by pinging every Steam friend who is in Phantom Blade Zero: only a
    Phantom Pact host answers, and the first answer pins it.
    """

    FRIENDS_REFRESH = 5.0

    def __init__(self, role, peer, folder):
        # Loaded by path: the relay runs with python -I, which leaves its own folder off sys.path.
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "steam_transport", os.path.join(os.path.dirname(os.path.abspath(__file__)), "steam_transport.py"))
        steam_transport = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(steam_transport)
        dll = steam_transport.find_steam_api(folder)
        if dll is None:
            raise SystemExit("Steam mode: steam_api64.dll not found above " + folder)
        self.st = steam_transport.SteamTransport(dll)
        self.peer = None
        self.wanted = None                # a friend name to look for, case-insensitive
        if role != "host" and peer:
            if peer.isdigit() and len(peer) == 17:
                self.peer = int(peer)
            else:
                self.wanted = peer.strip().lower()
        self._friends, self._friends_at = [], -1e9

    def send(self, addr, data):
        self.st.send(addr, data)

    def receive(self):
        return self.st.receive()

    def wait(self, seconds):
        # Steam has no socket to select on: poll every few ms, cheap next to the 50 ms tick.
        time.sleep(min(seconds, 0.005))
        return True

    def candidates(self):
        now = time.monotonic()
        if now - self._friends_at >= self.FRIENDS_REFRESH:
            self._friends_at = now
            self._friends = [fid for fid, name in self.st.friends_in_game()
                             if self.wanted is None or name.strip().lower() == self.wanted]
        return self._friends

    def describe(self, addr):
        return f"{self.st.friend_name(addr) or addr}"

    def describe_self(self):
        return f"Steam as {self.st.my_name}"


class Relay:
    def __init__(self, role, folder, peer, port, link=None):
        self.role = role
        self.out_path = os.path.join(folder, "net_out.txt")
        self.in_path = os.path.join(folder, "net_in.txt")
        self.events_out_path = os.path.join(folder, "net_events_out.txt")
        self.status_path = os.path.join(folder, "net_status.txt")
        self.inbox = EventInbox(os.path.join(folder, "net_events_in.txt"))
        self.link = link or UdpLink(role, peer, port)
        self.peer = self.link.peer        # host: learned from the first packet; Steam guest: maybe found later
        self.last_heard = 0.0
        self.rtt_ms = None
        self.last_ping = 0.0
        self.received = 0
        self.sent = 0
        self.acked = {}                   # our session -> highest event id the peer confirmed
        self.events_acked = 0
        self.in_blanked = False           # net_in.txt emptied because the peer went silent

    def send(self, msg, to=None):
        to = to if to is not None else self.peer
        if to is None:
            return
        msg["v"] = PROTOCOL
        try:
            self.link.send(to, json.dumps(msg, separators=(",", ":")).encode())
            self.sent += 1
        except OSError:
            pass

    def receive_all(self, now):
        for addr, data in self.link.receive():
            try:
                msg = json.loads(data)
            except ValueError:
                continue
            if not isinstance(msg, dict) or msg.get("v") != PROTOCOL:
                continue
            if self.role == "host" and self.peer != addr:
                # Pinned to the first peer: another sender is only taken once the current one went silent.
                if self.peer is not None and now - self.last_heard <= PEER_TIMEOUT:
                    continue
                self.peer = addr
                print(f"peer connected: {self.link.describe(addr)}", flush=True)
            elif self.role != "host" and self.peer != addr:
                # A guest still looking for its host pins the first friend that answers a ping; it never
                # answers other guests' pings itself.
                if self.peer is not None or msg.get("t") != "pong":
                    continue
                self.peer = addr
                print(f"found the host: {self.link.describe(addr)}", flush=True)
            self.last_heard = now
            self.received += 1
            kind = msg.get("t")
            if kind == "ping":
                self.send({"t": "pong", "ts": msg.get("ts")})
            elif kind == "pong" and isinstance(msg.get("ts"), (int, float)):
                self.rtt_ms = (now - msg["ts"]) * 1000.0
            elif kind == "state":
                if isinstance(msg.get("s"), str):
                    write_atomic(self.in_path, msg["s"])
                    self.in_blanked = False
                ev = msg.get("e")
                if isinstance(ev, dict) and isinstance(ev.get("sid"), str) and isinstance(ev.get("l"), list):
                    lines = [line for line in ev["l"] if isinstance(line, str)]
                    _, events = parse_events("\n".join(lines))
                    last = self.inbox.accept(ev["sid"], events)
                    self.send({"t": "ack", "sid": ev["sid"], "id": last})
            elif kind == "ack" and isinstance(msg.get("sid"), str) and isinstance(msg.get("id"), int):
                # Taken as is, even when lower: a restarted peer relay starts its inbox over and acks 0, and
                # only then do we resend the events it lost.
                self.acked[msg["sid"]] = msg["id"]

    def wait(self, seconds):
        """Sleep until the next tick, but handle incoming packets the moment they arrive."""
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            if self.link.wait(remaining):
                self.receive_all(time.monotonic())

    def tick(self, now):
        self.receive_all(now)
        if self.peer is not None and self.last_heard > 0 and now - self.last_heard > PEER_TIMEOUT:
            if not self.in_blanked:
                # The peer is gone: don't leave its last snapshot for the mod to keep applying.
                write_atomic(self.in_path, "")
                self.in_blanked = True
        if now - self.last_ping >= PING_EVERY:
            if self.peer is None and self.role != "host":
                for friend in self.link.candidates():
                    self.send({"t": "ping", "ts": now}, to=friend)
            else:
                self.send({"t": "ping", "ts": now})
            self.last_ping = now
        msg = {"t": "state"}
        snapshot = read_text(self.out_path)
        if snapshot.strip():
            # Resend the newest snapshot every tick even if unchanged, so a dropped packet heals itself.
            msg["s"] = snapshot[:MAX_SNAPSHOT_BYTES]
        session, events = parse_events(read_complete_lines(self.events_out_path))
        if session is not None:
            acked = self.acked.get(session, 0)
            pending = [line for eid, line in events if eid > acked][:MAX_EVENTS_PER_PACKET]
            # Always include the session (even with nothing pending) so the peer's inbox follows restarts.
            msg["e"] = {"sid": session, "l": pending}
            self.events_acked = acked
        if len(msg) > 1:
            self.send(msg)

    def status(self, now):
        connected = self.peer is not None and now - self.last_heard <= PEER_TIMEOUT
        peer = self.link.describe(self.peer).replace(" ", "_") if self.peer else "-"
        rtt = f"{self.rtt_ms:.0f}" if self.rtt_ms is not None else "-"
        # time= (wall clock) lets the mod tell a running relay from a stale status file before starting another.
        via = "steam" if isinstance(self.link, SteamLink) else "udp"
        return (f"role={self.role} via={via} connected={'yes' if connected else 'no'} peer={peer} "
                f"rtt_ms={rtt} sent={self.sent} received={self.received} "
                f"events_acked={self.events_acked} events_in={self.inbox.last_id} time={int(time.time())}")


ECHO_OFFSET_X = 300.0   # cm
ECHO_DELAY = 0.3        # s


def shift_player_line(snapshot, dx):
    """Echo mode: move the "P seq x y z ..." line dx cm along X so the fake friend stands aside."""
    out = []
    for line in snapshot.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0] == "P":
            try:
                parts[2] = f"{float(parts[2]) + dx:.1f}"
            except ValueError:
                pass
            line = " ".join(parts)
        out.append(line)
    return "\n".join(out) + "\n"


def run_echo(folder, seconds):
    """Solo test: feed our own snapshot and events back as the remote player's, shifted and delayed."""
    out_path = os.path.join(folder, "net_out.txt")
    in_path = os.path.join(folder, "net_in.txt")
    events_out_path = os.path.join(folder, "net_events_out.txt")
    status_path = os.path.join(folder, "net_status.txt")
    inbox = EventInbox(os.path.join(folder, "net_events_in.txt"))
    history = collections.deque()
    start = time.monotonic()
    last_status = 0.0
    echoed = 0
    print(f"PBZCoop relay echo, files in {folder}", flush=True)
    try:
        while not (seconds and time.monotonic() - start >= seconds):
            now = time.monotonic()
            snapshot = read_text(out_path)
            session, events = parse_events(read_complete_lines(events_out_path))
            history.append((now, snapshot, session, events))
            while history and now - history[0][0] >= ECHO_DELAY:
                _, snap, sess, evs = history.popleft()
                if snap.strip():
                    write_atomic(in_path, shift_player_line(snap, ECHO_OFFSET_X))
                    echoed += 1
                if sess is not None:
                    inbox.accept(sess, evs)
            if now - last_status >= 1.0:
                line = (f"role=echo connected=yes peer=self rtt_ms={ECHO_DELAY * 1000:.0f} echoed={echoed} "
                        f"events_in={inbox.last_id}")
                write_atomic(status_path, line + "\n")
                print(line, flush=True)
                last_status = now
            time.sleep(TICK)
    except KeyboardInterrupt:
        pass
    finally:
        write_atomic(status_path, "role=echo connected=no stopped=yes\n")


def run_record(folder, path, seconds):
    """Solo two-PC stand-in, part 1: log what this side sends (snapshot changes and new events) with timing.

    Run the mod as host while recording; replay the file later against a client (a fresh game session, so
    runtime names differ just as they would on a second PC)."""
    out_path = os.path.join(folder, "net_out.txt")
    events_out_path = os.path.join(folder, "net_events_out.txt")
    status_path = os.path.join(folder, "net_status.txt")
    start = time.monotonic()
    last_snapshot, sent_ids, lines, last_status = None, {}, 0, 0.0
    print(f"PBZCoop relay record -> {path}", flush=True)
    with open(path, "w", encoding="utf-8") as rec:
        try:
            while not (seconds and time.monotonic() - start >= seconds):
                now = time.monotonic()
                entry = {"t": round(now - start, 3)}
                snapshot = read_text(out_path)
                if snapshot.strip() and snapshot != last_snapshot:
                    entry["s"] = snapshot
                    last_snapshot = snapshot
                session, events = parse_events(read_complete_lines(events_out_path))
                if session is not None:
                    done = sent_ids.get(session, 0)
                    fresh = [line for eid, line in events if eid > done]
                    if fresh or session not in sent_ids:
                        entry["e"] = {"sid": session, "l": fresh}
                        sent_ids[session] = max([done] + [eid for eid, _ in events])
                if len(entry) > 1:
                    rec.write(json.dumps(entry, ensure_ascii=False) + "\n")
                    lines += 1
                if now - last_status >= 1.0:
                    line = f"role=record connected=yes peer=file recorded={lines}"
                    write_atomic(status_path, line + "\n")
                    print(line, flush=True)
                    last_status = now
                time.sleep(TICK)
        except KeyboardInterrupt:
            pass
    write_atomic(status_path, "role=record connected=no stopped=yes\n")


def run_replay(folder, path, seconds, client_log):
    """Solo two-PC stand-in, part 2: feed a recorded host session to this side (run the mod as client), on the
    recorded timing, and log every event the client sends back."""
    in_path = os.path.join(folder, "net_in.txt")
    events_out_path = os.path.join(folder, "net_events_out.txt")
    status_path = os.path.join(folder, "net_status.txt")
    inbox = EventInbox(os.path.join(folder, "net_events_in.txt"))
    with open(path, "r", encoding="utf-8") as f:
        entries = [json.loads(line) for line in f if line.strip()]
    start = time.monotonic()
    i, last_status, client_seen = 0, 0.0, {}
    print(f"PBZCoop relay replay <- {path} ({len(entries)} entries)", flush=True)
    log = open(client_log, "w", encoding="utf-8") if client_log else None
    try:
        while i < len(entries) or (seconds and time.monotonic() - start < seconds):
            now = time.monotonic() - start
            if seconds and now >= seconds:
                break
            while i < len(entries) and entries[i]["t"] <= now:
                entry = entries[i]
                if "s" in entry:
                    write_atomic(in_path, entry["s"])
                if "e" in entry:
                    _, events = parse_events("\n".join(entry["e"]["l"]))
                    inbox.accept(entry["e"]["sid"], events)
                i += 1
            if log:
                session, events = parse_events(read_complete_lines(events_out_path))
                if session is not None:
                    done = client_seen.get(session, 0)
                    for eid, line in events:
                        if eid > done:
                            log.write(f"{now:.2f} {line}\n")
                            log.flush()
                    client_seen[session] = max([done] + [eid for eid, _ in events])
            if time.monotonic() - start - last_status >= 1.0:
                line = f"role=replay connected=yes peer=file played={i}/{len(entries)} events_in={inbox.last_id}"
                write_atomic(status_path, line + "\n")
                print(line, flush=True)
                last_status = time.monotonic() - start
            time.sleep(TICK)
    except KeyboardInterrupt:
        pass
    finally:
        if log:
            log.close()
        write_atomic(status_path, "role=replay connected=no stopped=yes\n")


ALIVE_TIMEOUT = 30.0     # s without a heartbeat from the mod before a relay the mod started gives up


def game_alive(path, timeout):
    """The mod rewrites its heartbeat file (a unix time) every few seconds while the game runs."""
    try:
        beat = float(read_text(path).strip() or 0)
    except ValueError:
        return True       # caught mid-write
    return time.time() - beat <= timeout


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("role", choices=["host", "client", "echo", "record", "replay"])
    ap.add_argument("--file", help="record/replay: the recording (JSON lines)")
    ap.add_argument("--client-log", help="replay: write the events the client sends back to this file")
    ap.add_argument("--dir", required=True, help="the PBZCoop mod folder (where cmd.txt lives)")
    ap.add_argument("--peer", help="client only: the host's Tailscale IP (udp); with --transport steam, the host's "
                                   "Steam name or SteamID64, or nothing to find any friend hosting in the game")
    ap.add_argument("--transport", choices=["udp", "steam"], default="udp")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = run until Ctrl+C)")
    ap.add_argument("--alive-file", help="stop once this file (the mod's heartbeat: a unix time) is older than "
                                         "--alive-timeout, i.e. the game was closed")
    ap.add_argument("--alive-timeout", type=float, default=ALIVE_TIMEOUT)
    args = ap.parse_args()
    if args.role == "client" and args.transport == "udp" and not args.peer:
        ap.error("client needs --peer <host IP>")
    os.makedirs(args.dir, exist_ok=True)
    if args.role == "echo":
        run_echo(args.dir, args.seconds)
        return
    if args.role in ("record", "replay"):
        if not args.file:
            ap.error(f"{args.role} needs --file <recording>")
        if args.role == "record":
            run_record(args.dir, args.file, args.seconds)
        else:
            run_replay(args.dir, args.file, args.seconds, args.client_log)
        return

    link = SteamLink(args.role, args.peer, args.dir) if args.transport == "steam" else None
    relay = Relay(args.role, args.dir, args.peer, args.port, link)
    print(f"PBZCoop relay {args.role} on {relay.link.describe_self()}, files in {args.dir}", flush=True)
    start = time.monotonic()
    last_status = 0.0
    try:
        while True:
            now = time.monotonic()
            relay.tick(now)
            if now - last_status >= 1.0:
                line = relay.status(now)
                write_atomic(relay.status_path, line + "\n")
                print(line, flush=True)
                last_status = now
            if args.seconds and now - start >= args.seconds:
                break
            if args.alive_file and not game_alive(args.alive_file, args.alive_timeout):
                print("the game's heartbeat stopped: game closed, relay exiting", flush=True)
                break
            relay.wait(TICK)
    except KeyboardInterrupt:
        pass
    finally:
        write_atomic(relay.status_path, f"role={args.role} connected=no stopped=yes\n")


if __name__ == "__main__":
    main()
