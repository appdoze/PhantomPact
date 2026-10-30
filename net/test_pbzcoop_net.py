"""Loopback tests for pbzcoop_net.py (stdlib only): python -I net/test_pbzcoop_net.py"""

import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RELAY = os.path.join(HERE, "pbzcoop_net.py")
PORT = 47911


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def wait_for(pred, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


def event_lines(path):
    return [line for line in read(path).splitlines() if line and line[0].isdigit()]


class RelayLoopback(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.a = os.path.join(self.tmp.name, "a")
        self.b = os.path.join(self.tmp.name, "b")
        os.makedirs(self.a)
        os.makedirs(self.b)
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            p.kill()
            p.wait()
        self.tmp.cleanup()

    def start(self, *args):
        p = subprocess.Popen([sys.executable, "-I", RELAY, *args], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        self.procs.append(p)
        return p

    def test_snapshot_and_events_both_ways(self):
        write(os.path.join(self.a, "net_out.txt"), "P 1 10.0 20.0 30.0 90.0 0 0\nE Mob_1 1 2 3 4 50 100 1\n")
        write(os.path.join(self.b, "net_out.txt"), "P 7 -1.0 -2.0 -3.0 0.0 0 0\n")
        write(os.path.join(self.a, "net_events_out.txt"), "S 111\n1 A attack1\n2 K Mob_1\n")
        write(os.path.join(self.b, "net_events_out.txt"), "S 222\n1 D Mob_1 25\n")
        self.start("host", "--dir", self.a, "--port", str(PORT))
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))

        b_in = os.path.join(self.b, "net_in.txt")
        a_in = os.path.join(self.a, "net_in.txt")
        self.assertTrue(wait_for(lambda: "E Mob_1" in read(b_in)), "host snapshot never reached client")
        self.assertTrue(wait_for(lambda: read(a_in).startswith("P 7")), "client snapshot never reached host")

        b_ev = os.path.join(self.b, "net_events_in.txt")
        a_ev = os.path.join(self.a, "net_events_in.txt")
        self.assertTrue(wait_for(lambda: len(event_lines(b_ev)) == 2))
        self.assertEqual(event_lines(b_ev), ["1 A attack1", "2 K Mob_1"])
        self.assertTrue(wait_for(lambda: event_lines(a_ev) == ["1 D Mob_1 25"]))

        # New events append once each, even though the relay resends until acknowledged.
        write(os.path.join(self.a, "net_events_out.txt"), "S 111\n1 A attack1\n2 K Mob_1\n3 I Chest_2\n")
        self.assertTrue(wait_for(lambda: len(event_lines(b_ev)) == 3))
        time.sleep(0.5)
        self.assertEqual(event_lines(b_ev), ["1 A attack1", "2 K Mob_1", "3 I Chest_2"])

        # The host's mod restarts: a new session starts a fresh inbox, old events are not replayed.
        write(os.path.join(self.a, "net_events_out.txt"), "S 333\n1 A attack2\n")
        self.assertTrue(wait_for(lambda: read(b_ev).startswith("S 333")))
        self.assertTrue(wait_for(lambda: event_lines(b_ev) == ["1 A attack2"]))

    def test_receiving_relay_restart_resends_events(self):
        a_out = os.path.join(self.a, "net_events_out.txt")
        b_ev = os.path.join(self.b, "net_events_in.txt")
        write(os.path.join(self.a, "net_out.txt"), "P 1 0 0 0 0 0 0\n")
        write(a_out, "S 111\n1 A attack1\n2 K Mob_1\n3 I Chest_2\n")
        self.start("host", "--dir", self.a, "--port", str(PORT))
        client = self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))
        self.assertTrue(wait_for(lambda: len(event_lines(b_ev)) == 3))

        # The client's relay restarts mid-session: its inbox starts over and acks 0, which is lower than the 3 the
        # host already had. The host must take it and resend, or event 4 would never be accepted.
        client.kill()
        client.wait()
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))
        write(a_out, "S 111\n1 A attack1\n2 K Mob_1\n3 I Chest_2\n4 C 50\n")
        # The host only switches to the new client port once the old one was silent for PEER_TIMEOUT (3 s).
        self.assertTrue(wait_for(lambda: event_lines(b_ev) == ["1 A attack1", "2 K Mob_1", "3 I Chest_2", "4 C 50"],
                                 timeout=12.0), read(b_ev))

    def test_echo_shifts_player_only_and_echoes_events(self):
        write(os.path.join(self.a, "net_out.txt"), "P 5 100.0 0.0 0.0 0.0 0 0\nE Mob_1 1.0 2 3 4 50 100 1\n")
        write(os.path.join(self.a, "net_events_out.txt"), "S 9\n1 A attack1\n")
        self.start("echo", "--dir", self.a)
        a_in = os.path.join(self.a, "net_in.txt")
        self.assertTrue(wait_for(lambda: read(a_in).startswith("P 5 400.0")), read(a_in))
        self.assertIn("E Mob_1 1.0 2 3 4 50 100 1", read(a_in))
        self.assertTrue(wait_for(lambda: event_lines(os.path.join(self.a, "net_events_in.txt")) == ["1 A attack1"]))


def load_relay_module():
    # -I leaves this folder off sys.path, so import the relay by file path.
    import importlib.util
    spec = importlib.util.spec_from_file_location("pbzcoop_net", RELAY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FileReading(unittest.TestCase):
    def test_read_text_tolerates_invalid_utf8(self):
        relay = load_relay_module()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "net_out.txt")
            with open(path, "wb") as f:
                f.write(b"P 1 0 0 0 0 0 0 Map\xff\xfe\nE Mob_\xc3 1 2 3 4 50 100 0\n")
            text = relay.read_text(path)
            self.assertTrue(text.startswith("P 1 0 0 0 0 0 0 Map"))
            self.assertIn("E Mob_", text)

    def test_failed_writes_never_crash_and_lose_no_events(self):
        relay = load_relay_module()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "net_events_in.txt")
            real_replace, real_open = relay.os.replace, open

            def refuse(*_):
                raise OSError(1450, "Insufficient system resources exist to complete the requested service")
            relay.os.replace = refuse
            try:
                self.assertFalse(relay.write_atomic(os.path.join(tmp, "net_in.txt"), "P 1\n"))
            finally:
                relay.os.replace = real_replace

            inbox = relay.EventInbox(path)
            self.assertEqual(inbox.accept("s1", [(1, "1 A x")]), 1)
            relay.append_lines = lambda *_: False          # the disk refuses this time
            self.assertEqual(inbox.accept("s1", [(2, "2 K y")]), 1, "a failed write must not be acknowledged")
            del relay.append_lines                          # back to the module function
            relay.append_lines = load_relay_module().append_lines
            self.assertEqual(inbox.accept("s1", [(2, "2 K y")]), 2)
            self.assertEqual(event_lines(path), ["1 A x", "2 K y"])

    def test_partial_last_event_line_is_held_back(self):
        relay = load_relay_module()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "net_events_out.txt")
            write(path, "S 1\n1 A attack1\n2 D Mob_1 2")
            session, events = relay.parse_events(relay.read_complete_lines(path))
            self.assertEqual(session, "1")
            self.assertEqual(events, [(1, "1 A attack1")])


class RecordReplay(unittest.TestCase):
    def test_recorded_host_replays_to_a_client(self):
        with tempfile.TemporaryDirectory() as tmp:
            host, client = os.path.join(tmp, "host"), os.path.join(tmp, "client")
            os.makedirs(host)
            os.makedirs(client)
            rec = os.path.join(tmp, "host.jsonl")
            write(os.path.join(host, "net_out.txt"), "P 1 0 0 0 0 0 850 850 M\nE sp:Boss 1 2 3 0 2900 2900 1 1120 BP_X_C\n")
            write(os.path.join(host, "net_events_out.txt"), "S h1\n1 B sp:Boss\n")
            p = subprocess.Popen([sys.executable, "-I", RELAY, "record", "--dir", host, "--file", rec,
                                  "--seconds", "1.5"], stdout=subprocess.DEVNULL)
            time.sleep(0.6)
            write(os.path.join(host, "net_out.txt"), "P 2 50 0 0 0 0 850 850 M\nE sp:Boss 1 2 3 0 1000 2900 1 0 BP_X_C\n")
            write(os.path.join(host, "net_events_out.txt"), "S h1\n1 B sp:Boss\n2 K sp:Boss\n")
            p.wait(10)

            write(os.path.join(client, "net_events_out.txt"), "S c1\n1 D sp:Boss 80.0 10.0\n")
            log = os.path.join(tmp, "client.txt")
            q = subprocess.Popen([sys.executable, "-I", RELAY, "replay", "--dir", client, "--file", rec,
                                  "--client-log", log], stdout=subprocess.DEVNULL)
            q.wait(10)
            self.assertIn("E sp:Boss 1 2 3 0 1000 2900 1 0 BP_X_C", read(os.path.join(client, "net_in.txt")))
            self.assertEqual(event_lines(os.path.join(client, "net_events_in.txt")), ["1 B sp:Boss", "2 K sp:Boss"])
            self.assertIn("1 D sp:Boss 80.0 10.0", read(log))


sys.path.insert(0, HERE)
import pbzcoop_net  # noqa: E402  (unit tests of the relay's security helpers)


class Security(unittest.TestCase):
    def test_signed_packets_open_and_tampering_or_replay_is_dropped(self):
        a, b = pbzcoop_net.Auth("correct horse"), pbzcoop_net.Auth("correct horse")
        p1 = a.seal({"t": "state", "s": "P 1"})
        self.assertEqual(b.open(p1)["s"], "P 1")
        self.assertIsNone(b.open(p1), "a replayed packet is dropped")
        p2 = bytearray(a.seal({"t": "state", "s": "P 2"}))
        p2[10] ^= 1
        self.assertIsNone(b.open(bytes(p2)), "a modified packet is dropped")
        self.assertIsNone(pbzcoop_net.Auth("other").open(a.seal({"t": "ping"})), "a wrong secret is dropped")
        self.assertIsNone(b.open(pbzcoop_net.Auth("").seal({"t": "ping"})), "an unsigned packet is dropped")
        self.assertEqual(b.rejected, 3)

    def test_address_filter(self):
        ts = pbzcoop_net.ALLOWED_NETWORKS["tailscale"]
        self.assertTrue(pbzcoop_net.address_allowed(("100.101.102.103", 1), ts))
        self.assertTrue(pbzcoop_net.address_allowed(("127.0.0.1", 1), ts))
        self.assertFalse(pbzcoop_net.address_allowed(("192.168.1.20", 1), ts))
        self.assertFalse(pbzcoop_net.address_allowed(("8.8.8.8", 1), ts))
        self.assertTrue(pbzcoop_net.address_allowed(("8.8.8.8", 1), pbzcoop_net.ALLOWED_NETWORKS["any"]))

    def test_secret_comes_from_the_ini(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(os.path.join(tmp, "PhantomPact.ini"), "Role = Host\nSecret = hunter2 ; shared\n")
            self.assertEqual(pbzcoop_net.read_secret(tmp), "hunter2")
            inst = os.path.join(tmp, "inst2")
            os.makedirs(inst)
            self.assertEqual(pbzcoop_net.read_secret(inst), "hunter2", "extra instances use the mod's ini")
            write(os.path.join(tmp, "PhantomPact.ini"), "Secret = PUT-A-SHARED-SECRET-HERE\n")
            self.assertEqual(pbzcoop_net.read_secret(tmp), "", "the placeholder means off")


class SecureLoopback(RelayLoopback):
    """Two relays with the same secret talk; a stranger's packets (wrong secret, or another source port to the
    client) are counted and ignored."""

    def secret(self, folder, value):
        write(os.path.join(folder, "PhantomPact.ini"), f"Secret = {value}\n")

    def status(self, folder):
        return dict(kv.split("=", 1) for kv in read(os.path.join(folder, "net_status.txt")).split() if "=" in kv)

    def test_shared_secret_connects(self):
        self.secret(self.a, "s3cret")
        self.secret(self.b, "s3cret")
        write(os.path.join(self.a, "net_out.txt"), "P 1 1 2 3 0 0 0\n")
        write(os.path.join(self.b, "net_out.txt"), "P 2 4 5 6 0 0 0\n")
        self.start("host", "--dir", self.a, "--port", str(PORT))
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))
        self.assertTrue(wait_for(lambda: read(os.path.join(self.b, "net_in.txt")).startswith("P 1")))
        self.assertTrue(wait_for(lambda: read(os.path.join(self.a, "net_in.txt")).startswith("P 2")))
        self.assertTrue(wait_for(lambda: self.status(self.a).get("auth") == "on"))

    def test_wrong_secret_never_connects(self):
        self.secret(self.a, "s3cret")
        self.secret(self.b, "guess")
        write(os.path.join(self.b, "net_out.txt"), "P 2 4 5 6 0 0 0\n")
        self.start("host", "--dir", self.a, "--port", str(PORT))
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))
        self.assertTrue(wait_for(lambda: int(self.status(self.a).get("rejected", 0)) > 5))
        self.assertEqual(read(os.path.join(self.a, "net_in.txt")), "")
        self.assertEqual(self.status(self.a).get("connected"), "no")

    def test_client_ignores_packets_not_from_its_host(self):
        import socket
        write(os.path.join(self.b, "net_out.txt"), "P 2 4 5 6 0 0 0\n")
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))
        self.assertTrue(wait_for(lambda: self.status(self.b).get("role") == "client"))
        # Find the client's port from its first packet to a fake "host", then spoof from another port.
        fake = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        fake.bind(("127.0.0.1", PORT))
        fake.settimeout(3)
        _, client_addr = fake.recvfrom(65535)
        fake.close()
        stranger = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        stranger.sendto(b'{"t":"state","s":"P 99 0 0 0 0 0 0","v":2}', client_addr)
        stranger.close()
        self.assertTrue(wait_for(lambda: int(self.status(self.b).get("filtered", 0)) >= 1))
        self.assertEqual(read(os.path.join(self.b, "net_in.txt")), "")


class Latency(RelayLoopback):
    def test_new_snapshots_go_out_immediately(self):
        a_out, b_in = os.path.join(self.a, "net_out.txt"), os.path.join(self.b, "net_in.txt")
        write(a_out, "P 0 0 0 0 0 0 0\n")
        self.start("host", "--dir", self.a, "--port", str(PORT))
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))
        self.assertTrue(wait_for(lambda: read(b_in).startswith("P 0")))
        delays = []
        for seq in range(1, 16):
            line = f"P {seq} 0 0 0 0 0 0\n"
            t0 = time.perf_counter()
            write(a_out, line)
            while read(b_in) != line and time.perf_counter() - t0 < 1.0:
                time.sleep(0.001)
            delays.append(time.perf_counter() - t0)
            time.sleep(0.013)
        delays.sort()
        median = delays[len(delays) // 2]
        print(f"\nfile-to-file median {median * 1000:.1f} ms, max {delays[-1] * 1000:.1f} ms")
        # Before: up to one 50 ms relay tick on top of the network (median ~35-50 ms here). Now: one 5 ms file
        # check (median ~15-25 ms with the test's own polling); the bound only catches a return to tick-paced sends.
        self.assertLess(median, 0.035)


if __name__ == "__main__":
    unittest.main(verbosity=2)
