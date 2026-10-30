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
PYTHON_RELAY = [sys.executable, "-I", RELAY]
# The native relay (relay/, cargo build --release): the same tests run against it, and against a mix of both.
NATIVE = os.environ.get("PBZ_RUST_RELAY") or os.path.join(HERE, "..", "relay", "target", "release",
                                                          "pbzcoop_relay.exe" if os.name == "nt" else "pbzcoop_relay")
HAVE_NATIVE = os.path.isfile(NATIVE)


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
    HOST = PYTHON_RELAY      # command for the host / echo relay
    CLIENT = PYTHON_RELAY    # command for the client relay

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
        cmd = self.CLIENT if args[0] == "client" else self.HOST
        p = subprocess.Popen([*cmd, *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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

    def test_hmac_mode_also_drops_tampering_and_replay(self):
        a, b = pbzcoop_net.Auth("k", encrypt=False), pbzcoop_net.Auth("k", encrypt=False)
        self.assertEqual(a.mode, "hmac")
        p = a.seal({"t": "ping"})
        self.assertIsNotNone(b.open(p))
        self.assertIsNone(b.open(p))

    @unittest.skipUnless(os.name == "nt", "AES-GCM uses Windows CNG")
    def test_aes_gcm_encrypts_and_rejects_plaintext_and_downgrade(self):
        a, b = pbzcoop_net.Auth("k"), pbzcoop_net.Auth("k")
        self.assertEqual(a.mode, "aes-gcm")
        p = a.seal({"t": "state", "s": "P 1 secret-position"})
        self.assertNotIn(b"secret-position", p, "the payload is encrypted")
        self.assertEqual(b.open(p)["s"], "P 1 secret-position")
        self.assertIsNone(b.open(p), "replay")
        self.assertIsNone(b.open(pbzcoop_net.Auth("k", encrypt=False).seal({"t": "ping"})), "HMAC downgrade refused")
        self.assertIsNone(b.open(b'{"t":"ping","v":2}'), "plain refused")
        q = bytearray(a.seal({"t": "ping"}))
        q[-1] ^= 1
        self.assertIsNone(b.open(bytes(q)), "tag mismatch")
        # Known-answer check of the CNG wrapper (NIST GCM test case 13: 256-bit zero key, zero nonce, empty input).
        g = pbzcoop_net.AesGcm(bytes(32))
        self.assertEqual(g.encrypt(bytes(12), b"", b"").hex(), "530f8afbc74536b9a963b4f1c4cb738b")

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
        want = "aes-gcm" if os.name == "nt" else "hmac"
        self.assertTrue(wait_for(lambda: self.status(self.a).get("auth") == want), self.status(self.a))

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


class Handshake(RelayLoopback):
    def status(self, folder):
        return dict(kv.split("=", 1) for kv in read(os.path.join(folder, "net_status.txt")).split() if "=" in kv)

    def test_settings_that_differ_are_reported_on_both_sides(self):
        write(os.path.join(self.a, "PhantomPact.ini"), "CoopEnemyHealth = 150\nPvP = On\nNetwork = Tailscale\n")
        write(os.path.join(self.b, "PhantomPact.ini"), "CoopEnemyHealth = 100\nPvP = on\nNetwork = Tailscale\n")
        self.start("host", "--dir", self.a, "--port", str(PORT))
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))
        self.assertTrue(wait_for(lambda: self.status(self.a).get("mismatch", "-") != "-", timeout=8))
        self.assertEqual(self.status(self.a)["mismatch"], "coopenemyhealth=150/100", "PvP On/on is the same setting")
        self.assertTrue(wait_for(lambda: self.status(self.b).get("mismatch") == "coopenemyhealth=100/150", timeout=8))

    def test_same_settings_report_no_mismatch(self):
        for d in (self.a, self.b):
            write(os.path.join(d, "PhantomPact.ini"), "CoopEnemyHealth = 150\n")
        self.start("host", "--dir", self.a, "--port", str(PORT))
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))
        self.assertTrue(wait_for(lambda: self.status(self.a).get("partner_version", "-") != "-", timeout=8))
        self.assertEqual(self.status(self.a).get("mismatch"), "-")


class Direct(unittest.TestCase):
    """Direct (port forwarding): open to any address, so a secret is required; UPnP asks the router for the
    forward. The router here is a fake on 127.0.0.1 that records the SOAP actions."""

    RELAY_CMD = PYTHON_RELAY

    def test_direct_refuses_to_start_without_a_secret(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = subprocess.run([*self.RELAY_CMD, "host", "--dir", tmp, "--port", str(PORT), "--allow", "any",
                                "--seconds", "1"], capture_output=True, text=True, timeout=20)
            self.assertEqual(p.returncode, 2)
            self.assertIn("error=direct-needs-secret", read(os.path.join(tmp, "net_status.txt")))

    def test_ssdp_reply_location(self):
        reply = b"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLocation: http://192.168.1.1:5000/rootDesc.xml\r\n\r\n"
        self.assertEqual(pbzcoop_net.ssdp_location(reply), "http://192.168.1.1:5000/rootDesc.xml")

    def test_upnp_forward_is_added_and_removed(self):
        import http.server
        import threading
        calls = []
        desc = ('<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceList><device>'
                '<deviceList><device><serviceList><service>'
                '<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>'
                '<controlURL>/ctl/IPConn</controlURL></service></serviceList></device></deviceList>'
                '</device></deviceList></device></root>')

        class Router(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(desc.encode())

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"])).decode()
                calls.append((self.headers["SOAPAction"].strip('"').split("#")[1], body))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"<s:Envelope><s:Body><NewExternalIPAddress>203.0.113.7</NewExternalIPAddress>"
                                 b"</s:Body></s:Envelope>")

        server = http.server.HTTPServer(("127.0.0.1", 0), Router)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                write(os.path.join(tmp, "PhantomPact.ini"), "Secret = s3cret\n")
                url = f"http://127.0.0.1:{server.server_port}/rootDesc.xml"
                p = subprocess.run([*self.RELAY_CMD, "host", "--dir", tmp, "--port", str(PORT),
                                    "--allow", "any", "--upnp", "--upnp-location", url, "--seconds", "1.5"],
                                   capture_output=True, text=True, timeout=30)
                self.assertIn("upnp=ok external_ip=203.0.113.7", p.stdout)
        finally:
            server.shutdown()
            server.server_close()
        actions = [a for a, _ in calls]
        self.assertEqual(actions[0], "AddPortMapping")
        self.assertIn("GetExternalIPAddress", actions)
        self.assertEqual(actions[-1], "DeletePortMapping", "the forward is removed when the relay stops")
        add = calls[0][1]
        for part in (f"<NewExternalPort>{PORT}</NewExternalPort>", "<NewProtocol>UDP</NewProtocol>",
                     "<NewInternalClient>127.0.0.1</NewInternalClient>"):
            self.assertIn(part, add)


STEAM_DLL = os.environ.get("PBZ_STEAM_DLL", "")


@unittest.skipUnless(STEAM_DLL, "set PBZ_STEAM_DLL to steam_api64.dll (Steam running) to test the Steam transport")
class Steam(unittest.TestCase):
    def test_steam_transport_starts_and_sends(self):
        # Runs in a child process: SteamAPI_Init / Shutdown once per process.
        code = ("import sys; sys.path.insert(0, %r); import pbzcoop_net as n; "
                "t = n.SteamTransport(%r, 76561197960265728); print('me', t.my_id); "
                "import time\n"
                "for _ in range(10):\n"
                "    t.send(b'hello', t.peer); t.poll(); time.sleep(0.05)\n"
                "    if t.last_result == 1: break\n"
                "print('send', t.last_result); t.close()") % (HERE, STEAM_DLL)
        p = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        me = int(p.stdout.split("me ", 1)[1].split()[0])
        self.assertTrue(str(me).startswith("7656119"), me)
        self.assertIn("send 1", p.stdout, "k_EResultOK from SendMessageToUser")


class Latency(RelayLoopback):
    @unittest.skipIf(os.environ.get("GITHUB_ACTIONS"), "timing on shared CI runners is too noisy")
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


# ------------------------------------------------------------------------------- native relay (relay/, Rust)

NATIVE_RELAY = [NATIVE]
needs_native = unittest.skipUnless(HAVE_NATIVE, "build relay/ (cargo build --release) or set PBZ_RUST_RELAY")


@needs_native
class NativeLoopback(SecureLoopback):
    """Native relay on both sides: every loopback, security and handshake test."""
    HOST = CLIENT = NATIVE_RELAY


@needs_native
class NativeHostPythonClient(SecureLoopback):
    """Mixed: a player on the native relay and one on the Python relay play together."""
    HOST, CLIENT = NATIVE_RELAY, PYTHON_RELAY


@needs_native
class PythonHostNativeClient(SecureLoopback):
    HOST, CLIENT = PYTHON_RELAY, NATIVE_RELAY


@needs_native
class NativeHandshake(Handshake):
    HOST, CLIENT = NATIVE_RELAY, PYTHON_RELAY


@needs_native
class NativeDirect(Direct):
    RELAY_CMD = NATIVE_RELAY


@needs_native
class NativeLatency(Latency):
    HOST = CLIENT = NATIVE_RELAY


if __name__ == "__main__":
    unittest.main(verbosity=2)
