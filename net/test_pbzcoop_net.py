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


class FakeSteamNet:
    """Stands in for Steam's P2P network: messages addressed by SteamID64, delivered in memory."""

    def __init__(self):
        self.inbox = {}

    def link(self, my_id, friends_in_game, peer=None):
        self.inbox.setdefault(my_id, [])
        return FakeSteamLink(self, my_id, friends_in_game, peer)


class FakeSteamLink:
    """The relay's link interface (as SteamLink): send/receive by SteamID64, friends hosting as candidates."""

    def __init__(self, net, my_id, friends_in_game, peer):
        self.net, self.my_id, self.friends, self.peer = net, my_id, friends_in_game, peer

    def send(self, addr, data):
        self.net.inbox.setdefault(addr, []).append((self.my_id, data))

    def receive(self):
        out, self.net.inbox[self.my_id] = self.net.inbox[self.my_id], []
        return out

    def wait(self, seconds):
        time.sleep(min(seconds, 0.002))
        return True

    def candidates(self):
        return list(self.friends)

    def describe(self, addr):
        return f"friend{addr}"

    def describe_self(self):
        return f"Steam as {self.my_id}"


class SteamRelayLogic(unittest.TestCase):
    """The relay over a Steam-style link (everything but Valve's network itself, which needs two accounts)."""

    HOST, GUEST, OTHER = 76561190000000001, 76561190000000002, 76561190000000003

    def run_relays(self, relays, seconds=1.5):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            for r in relays:
                r.tick(time.monotonic())
            time.sleep(0.01)

    def folders(self, tmp, *names):
        out = []
        for n in names:
            d = os.path.join(tmp, n)
            os.makedirs(d)
            out.append(d)
        return out

    def test_guest_finds_the_hosting_friend_and_both_directions_flow(self):
        relay = load_relay_module()
        net = FakeSteamNet()
        with tempfile.TemporaryDirectory() as tmp:
            hd, gd = self.folders(tmp, "host", "guest")
            write(os.path.join(hd, "net_out.txt"), "P 1 10 20 30 0 0 850 850 M\nE sp:Boss 1 2 3 0 2900 2900 1 1120 BP_X_C\n")
            write(os.path.join(hd, "net_events_out.txt"), "S h1\n1 B sp:Boss\n2 K sp:Thug\n")
            write(os.path.join(gd, "net_out.txt"), "P 1 11 21 31 0 0 850 850 M\n")
            write(os.path.join(gd, "net_events_out.txt"), "S g1\n1 D sp:Boss 80.0 10.0 L\n")
            host = relay.Relay("host", hd, None, 0, net.link(self.HOST, [self.GUEST]))
            # The guest has two friends in the game; only the host answers pings, so it pins the host.
            guest = relay.Relay("client", gd, None, 0, net.link(self.GUEST, [self.OTHER, self.HOST]))
            self.run_relays([host, guest])
            self.assertEqual(guest.peer, self.HOST)
            self.assertEqual(host.peer, self.GUEST)
            self.assertIn("E sp:Boss", read(os.path.join(gd, "net_in.txt")))
            self.assertIn("P 1 11 21 31", read(os.path.join(hd, "net_in.txt")))
            self.assertEqual(event_lines(os.path.join(gd, "net_events_in.txt")), ["1 B sp:Boss", "2 K sp:Thug"])
            self.assertEqual(event_lines(os.path.join(hd, "net_events_in.txt")), ["1 D sp:Boss 80.0 10.0 L"])

    def test_two_guests_never_pin_each_other_and_the_host_keeps_its_first(self):
        relay = load_relay_module()
        net = FakeSteamNet()
        with tempfile.TemporaryDirectory() as tmp:
            hd, g1d, g2d = self.folders(tmp, "host", "g1", "g2")
            for d in (hd, g1d, g2d):
                write(os.path.join(d, "net_out.txt"), "P 1 0 0 0 0 0 850 850 M\n")
            host = relay.Relay("host", hd, None, 0, net.link(self.HOST, [self.GUEST, self.OTHER]))
            g1 = relay.Relay("client", g1d, None, 0, net.link(self.GUEST, [self.OTHER, self.HOST]))
            self.run_relays([host, g1], 0.6)
            g2 = relay.Relay("client", g2d, None, 0, net.link(self.OTHER, [self.GUEST, self.HOST]))
            self.run_relays([host, g1, g2], 1.5)
            self.assertEqual(g1.peer, self.HOST)
            self.assertEqual(host.peer, self.GUEST)    # pinned to the first guest while it keeps talking
            self.assertNotEqual(g2.peer, self.GUEST)   # a guest never answers another guest's pings
            self.assertIsNone(g2.peer)                 # the busy host doesn't take a second guest

    def test_guest_given_a_steamid_talks_only_to_it(self):
        relay = load_relay_module()
        net = FakeSteamNet()
        with tempfile.TemporaryDirectory() as tmp:
            hd, gd = self.folders(tmp, "host", "guest")
            write(os.path.join(hd, "net_out.txt"), "P 7 1 2 3 0 0 850 850 M\n")
            write(os.path.join(gd, "net_out.txt"), "P 1 0 0 0 0 0 850 850 M\n")
            host = relay.Relay("host", hd, None, 0, net.link(self.HOST, []))
            guest = relay.Relay("client", gd, None, 0, net.link(self.GUEST, [], peer=self.HOST))
            self.run_relays([host, guest])
            self.assertEqual(guest.peer, self.HOST)
            self.assertIn("P 7 1 2 3", read(os.path.join(gd, "net_in.txt")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
