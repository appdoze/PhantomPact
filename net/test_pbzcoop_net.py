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


if __name__ == "__main__":
    unittest.main(verbosity=2)
