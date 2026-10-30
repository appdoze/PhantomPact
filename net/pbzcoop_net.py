"""PBZCoop network relay: carries game state between two PCs over UDP (designed for Tailscale IPs).

The game mod and this relay talk through small text files in the mod folder:
  net_out.txt         written by the mod: the local snapshot, several lines (player "P ...", enemies "E ...")
  net_in.txt          written by the relay: the remote side's latest snapshot
  net_events_out.txt  written by the mod: "S <session>" then one numbered event per line ("<id> <type> <args>")
  net_events_in.txt   written by the relay: the remote side's events, in order, same format
  net_status.txt      written by the relay: connection state, peer address, round-trip time

Snapshots are newest-wins: a new one is sent as soon as the mod writes it (the files are checked every 5 ms) and
the newest is resent every 50 ms, so a lost packet is replaced shortly after.
Events (attacks, kills, pickups) are reliable: resent every tick until the peer acknowledges them.
The relay doesn't interpret either; only echo mode shifts the "P" line so the fake friend stands aside.

Security: only Tailscale addresses (and this PC) are accepted by default (--allow any to change that), the client
only accepts its host's address, and with "Secret = ..." in PhantomPact.ini (same on both PCs) every packet is
signed with HMAC-SHA256 and replays are dropped.

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
import hashlib
import hmac
import ipaddress
import json
import os
import secrets
import select
import socket
import time

PORT = 47800
TICK = 0.05          # resend interval: the newest snapshot goes out at least this often, so a lost packet heals
WATCH = 0.005        # how often the mod's files are checked; anything new is sent at once instead of on the tick
PING_EVERY = 1.0
PEER_TIMEOUT = 3.0
PROTOCOL = 2
MAX_EVENTS_PER_PACKET = 40
MAX_SNAPSHOT_BYTES = 48000

# Who may talk to this relay. "tailscale": Tailscale addresses (100.64.0.0/10) and this PC only, so the open UDP
# port can't be used from the LAN or the internet even if a firewall lets packets through. "any": no filter (for
# other VPNs or a LAN game; set a Secret then).
ALLOWED_NETWORKS = {
    "tailscale": [ipaddress.ip_network("100.64.0.0/10"), ipaddress.ip_network("127.0.0.0/8")],
    "any": None,
}
MAC_BYTES = 16       # HMAC-SHA256 truncated to 128 bits
REPLAY_SESSIONS = 8  # peer relay sessions whose packet counters are remembered


def fine_timer():
    """Windows wakes sleeping threads on a 15.6 ms clock by default, which made the 5 ms file check (and select's
    timeout) effectively 15.6 ms. Ask for 1 ms, as games do; it is released when the process exits."""
    if os.name == "nt":
        try:
            import ctypes
            ctypes.WinDLL("winmm").timeBeginPeriod(1)
        except (OSError, AttributeError):
            pass


def read_secret(folder, path=None):
    """The shared secret: --secret-file, else "Secret = ..." in PhantomPact.ini next to the mod. Empty = off."""
    if path:
        return read_text(path).strip()
    ini = os.path.join(folder, "PhantomPact.ini")
    if not os.path.exists(ini):
        # Extra test instances run in <mod>/inst<n>/; the ini lives in the mod folder above.
        ini = os.path.join(os.path.dirname(os.path.normpath(folder)), "PhantomPact.ini")
    for line in read_text(ini).splitlines():
        key, sep, value = line.partition("=")
        if sep and key.strip().lower() == "secret":
            value = value.split(";", 1)[0].strip()
            if value and not value.upper().startswith("PUT-"):
                return value
    return ""


class Auth:
    """Optional packet authentication with a secret both players share.

    Every packet carries the sender's random session id and a counter and is signed with HMAC-SHA256; packets with
    a bad signature, from another protocol, or replayed (counter not above the last one seen for that session) are
    dropped. Without a secret packets are unsigned (and only the address filter applies)."""

    def __init__(self, secret):
        self.key = hashlib.sha256(secret.encode()).digest() if secret else None
        self.sid = secrets.token_hex(8)
        self.counter = 0
        self.seen = collections.OrderedDict()   # peer session id -> highest counter accepted
        self.rejected = 0

    def seal(self, msg):
        if self.key is None:
            return json.dumps(msg, separators=(",", ":")).encode()
        self.counter += 1
        msg["a"] = self.sid
        msg["n"] = self.counter
        body = json.dumps(msg, separators=(",", ":")).encode()
        return body + b"\n" + hmac.new(self.key, body, hashlib.sha256).digest()[:MAC_BYTES].hex().encode()

    def open(self, data):
        """The message dict, or None if the packet must be dropped."""
        if self.key is None:
            body = data
        else:
            body, sep, mac = data.rpartition(b"\n")
            want = hmac.new(self.key, body, hashlib.sha256).digest()[:MAC_BYTES].hex().encode()
            if not sep or not hmac.compare_digest(mac, want):
                self.rejected += 1
                return None
        try:
            msg = json.loads(body)
        except ValueError:
            self.rejected += 1
            return None
        if not isinstance(msg, dict):
            self.rejected += 1
            return None
        if self.key is not None:
            sid, n = msg.get("a"), msg.get("n")
            if not isinstance(sid, str) or not isinstance(n, int) or n <= self.seen.get(sid, 0):
                self.rejected += 1
                return None
            self.seen[sid] = n
            self.seen.move_to_end(sid)
            while len(self.seen) > REPLAY_SESSIONS:
                self.seen.popitem(last=False)
        return msg


def address_allowed(addr, networks):
    if networks is None:
        return True
    try:
        ip = ipaddress.ip_address(addr[0])
    except ValueError:
        return False
    return any(ip in net for net in networks)


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


class Relay:
    def __init__(self, role, folder, peer, port, secret="", allow="tailscale"):
        self.role = role
        self.auth = Auth(secret)
        self.allowed = ALLOWED_NETWORKS[allow]
        self.filtered = 0                 # packets dropped because of their sender address
        self.out_path = os.path.join(folder, "net_out.txt")
        self.in_path = os.path.join(folder, "net_in.txt")
        self.events_out_path = os.path.join(folder, "net_events_out.txt")
        self.status_path = os.path.join(folder, "net_status.txt")
        self.inbox = EventInbox(os.path.join(folder, "net_events_in.txt"))
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setblocking(False)
        if role == "host":
            self.sock.bind(("0.0.0.0", port))
            self.peer = None              # learned from the first packet
        else:
            self.sock.bind(("0.0.0.0", 0))
            # Resolved once: replies are only accepted from exactly this address and port.
            self.peer = (socket.gethostbyname(peer), port)
        self.last_heard = 0.0
        self.last_out_sig = None          # (mtime, size) of net_out.txt / net_events_out.txt when last sent
        self.last_sent_at = 0.0
        self.rtt_ms = None
        self.last_ping = 0.0
        self.received = 0
        self.sent = 0
        self.acked = {}                   # our session -> highest event id the peer confirmed
        self.events_acked = 0
        self.in_blanked = False           # net_in.txt emptied because the peer went silent

    def send(self, msg):
        if self.peer is None:
            return
        msg["v"] = PROTOCOL
        try:
            self.sock.sendto(self.auth.seal(msg), self.peer)
            self.sent += 1
        except OSError:
            pass

    def receive_all(self, now):
        while True:
            try:
                data, addr = self.sock.recvfrom(65535)
            except BlockingIOError:
                return
            except ConnectionResetError:
                # Windows reports ICMP "port unreachable" this way while the peer isn't running yet.
                continue
            # The client only listens to the host it was given; the host only to allowed networks.
            if (self.role != "host" and addr != self.peer) or not address_allowed(addr, self.allowed):
                self.filtered += 1
                continue
            msg = self.auth.open(data)
            if msg is None or msg.get("v") != PROTOCOL:
                continue
            if self.role == "host" and self.peer != addr:
                # Pinned to the first peer: another sender is only taken once the current one went silent.
                if self.peer is not None and now - self.last_heard <= PEER_TIMEOUT:
                    continue
                self.peer = addr
                print(f"peer connected from {addr[0]}:{addr[1]}", flush=True)
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

    def out_signature(self):
        sig = []
        for path in (self.out_path, self.events_out_path):
            try:
                st = os.stat(path)
                sig.append((st.st_mtime_ns, st.st_size))
            except OSError:
                sig.append(None)
        return tuple(sig)

    def wait(self, seconds):
        """Sleep until the next tick, but handle incoming packets the moment they arrive and send what the mod
        wrote the moment it appears (instead of up to one tick later)."""
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            ready, _, _ = select.select([self.sock], [], [], min(remaining, WATCH))
            now = time.monotonic()
            if ready:
                self.receive_all(now)
            if self.out_signature() != self.last_out_sig:
                self.send_state(now)

    def tick(self, now):
        self.receive_all(now)
        if self.peer is not None and self.last_heard > 0 and now - self.last_heard > PEER_TIMEOUT:
            if not self.in_blanked:
                # The peer is gone: don't leave its last snapshot for the mod to keep applying.
                write_atomic(self.in_path, "")
                self.in_blanked = True
        if now - self.last_ping >= PING_EVERY:
            self.send({"t": "ping", "ts": now})
            self.last_ping = now
        if now - self.last_sent_at >= TICK * 0.9:
            self.send_state(now)

    def send_state(self, now):
        self.last_out_sig = self.out_signature()
        self.last_sent_at = now
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
        peer = f"{self.peer[0]}:{self.peer[1]}" if self.peer else "-"
        rtt = f"{self.rtt_ms:.0f}" if self.rtt_ms is not None else "-"
        # time= (wall clock) lets the mod tell a running relay from a stale status file before starting another.
        return (f"role={self.role} connected={'yes' if connected else 'no'} peer={peer} "
                f"rtt_ms={rtt} sent={self.sent} received={self.received} "
                f"events_acked={self.events_acked} events_in={self.inbox.last_id} "
                f"auth={'on' if self.auth.key else 'off'} rejected={self.auth.rejected} filtered={self.filtered} "
                f"time={int(time.time())}")


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
    ap.add_argument("--peer", help="host's Tailscale IP (client only)")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = run until Ctrl+C)")
    ap.add_argument("--alive-file", help="stop once this file (the mod's heartbeat: a unix time) is older than "
                                         "--alive-timeout, i.e. the game was closed")
    ap.add_argument("--alive-timeout", type=float, default=ALIVE_TIMEOUT)
    ap.add_argument("--allow", choices=sorted(ALLOWED_NETWORKS), default="tailscale",
                    help="who may connect: tailscale (100.64.0.0/10 and this PC, default) or any")
    ap.add_argument("--secret-file", help="file holding the shared secret (default: Secret in <dir>/PhantomPact.ini)")
    args = ap.parse_args()
    if args.role == "client" and not args.peer:
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

    fine_timer()
    secret = read_secret(args.dir, args.secret_file)
    relay = Relay(args.role, args.dir, args.peer, args.port, secret=secret, allow=args.allow)
    print(f"PBZCoop relay {args.role} on UDP {args.port}, files in {args.dir}, "
          f"auth {'on' if secret else 'off (set Secret in PhantomPact.ini)'}, allow {args.allow}", flush=True)
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
