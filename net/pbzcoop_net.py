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


def mod_ini_path(folder):
    ini = os.path.join(folder, "PhantomPact.ini")
    if not os.path.exists(ini):
        # Extra test instances run in <mod>/inst<n>/; the ini lives in the mod folder above.
        ini = os.path.join(os.path.dirname(os.path.normpath(folder)), "PhantomPact.ini")
    return ini


def read_ini(folder):
    """PhantomPact.ini as {lowercase key: value}, comments stripped."""
    out = {}
    for line in read_text(mod_ini_path(folder)).splitlines():
        if line.lstrip().startswith(";"):
            continue
        key, sep, value = line.partition("=")
        if sep:
            out[key.strip().lower()] = value.split(";", 1)[0].strip()
    return out


# Settings both players must agree on; compared in the "hello" exchange and reported as mismatch= in the status.
SHARED_SETTINGS = ("network", "coopenemyhealth", "coopenemyposture", "shareprogress", "pvp", "pvpdamage",
                   "pvpparryposture")


def mod_version(folder):
    """VERSION from Scripts/main.lua next to the relay (or the mod folder above an instance folder)."""
    for base in (folder, os.path.dirname(os.path.normpath(folder))):
        for rel in (("Scripts", "main.lua"), ("mod", "PBZCoop", "Scripts", "main.lua")):
            text = read_text(os.path.join(base, *rel))
            marker = 'local VERSION = "'
            if marker in text:
                return text.split(marker, 1)[1].split('"', 1)[0]
    return "?"


def compare_settings(mine, theirs):
    """Differences between two hello payloads as "key=mine/theirs" strings."""
    diffs = []
    if mine.get("ver") != theirs.get("ver"):
        diffs.append(f"version={mine.get('ver')}/{theirs.get('ver')}")
    a, b = mine.get("cfg") or {}, theirs.get("cfg") or {}
    for key in SHARED_SETTINGS:
        if str(a.get(key, "")).lower() != str(b.get(key, "")).lower():
            diffs.append(f"{key}={a.get(key, '') or '-'}/{b.get(key, '') or '-'}")
    return diffs


def read_secret(folder, path=None):
    """The shared secret: --secret-file, else "Secret = ..." in PhantomPact.ini next to the mod. Empty = off."""
    if path:
        return read_text(path).strip()
    for line in read_text(mod_ini_path(folder)).splitlines():
        key, sep, value = line.partition("=")
        if sep and key.strip().lower() == "secret":
            value = value.split(";", 1)[0].strip()
            if value and not value.upper().startswith("PUT-"):
                return value
    return ""


class AesGcm:
    """AES-256-GCM through Windows' own crypto library (CNG, bcrypt.dll): Python's standard library has no
    authenticated cipher, and the game only runs on Windows. Raises OSError where CNG isn't available."""

    TAG = 16
    STATUS_AUTH_TAG_MISMATCH = 0xC000A002

    def __init__(self, key):
        import ctypes
        from ctypes import wintypes
        self.ct = ctypes
        if os.name != "nt":
            raise OSError("CNG needs Windows")
        bc = self.bc = ctypes.WinDLL("bcrypt")

        class Info(ctypes.Structure):    # BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO
            _fields_ = [("cbSize", wintypes.ULONG), ("dwInfoVersion", wintypes.ULONG),
                        ("pbNonce", ctypes.c_void_p), ("cbNonce", wintypes.ULONG),
                        ("pbAuthData", ctypes.c_void_p), ("cbAuthData", wintypes.ULONG),
                        ("pbTag", ctypes.c_void_p), ("cbTag", wintypes.ULONG),
                        ("pbMacContext", ctypes.c_void_p), ("cbMacContext", wintypes.ULONG),
                        ("cbAAD", wintypes.ULONG), ("cbData", ctypes.c_ulonglong), ("dwFlags", wintypes.ULONG)]
        self.Info = Info
        alg = ctypes.c_void_p()
        self.check(bc.BCryptOpenAlgorithmProvider(ctypes.byref(alg), ctypes.c_wchar_p("AES"), None, 0))
        mode = ctypes.create_unicode_buffer("ChainingModeGCM")
        self.check(bc.BCryptSetProperty(alg, ctypes.c_wchar_p("ChainingMode"), mode, ctypes.sizeof(mode), 0))
        self.key = ctypes.c_void_p()
        kb = ctypes.create_string_buffer(key, len(key))
        self.check(bc.BCryptGenerateSymmetricKey(alg, ctypes.byref(self.key), None, 0, kb, len(key), 0))
        self.alg = alg

    @staticmethod
    def check(status):
        if status != 0:
            raise OSError(f"CNG error 0x{status & 0xFFFFFFFF:08X}")

    def _info(self, nonce, aad, tag):
        i = self.Info()
        i.cbSize, i.dwInfoVersion = self.ct.sizeof(i), 1
        i.pbNonce, i.cbNonce = self.ct.cast(nonce, self.ct.c_void_p), len(nonce)
        i.pbAuthData, i.cbAuthData = self.ct.cast(aad, self.ct.c_void_p), len(aad)
        i.pbTag, i.cbTag = self.ct.cast(tag, self.ct.c_void_p), self.TAG
        return i

    def encrypt(self, nonce, plaintext, aad):
        ct = self.ct
        n, a = ct.create_string_buffer(nonce, len(nonce)), ct.create_string_buffer(aad, len(aad))
        tag = ct.create_string_buffer(self.TAG)
        info = self._info(n, a, tag)
        src = ct.create_string_buffer(plaintext, len(plaintext))
        out = ct.create_string_buffer(len(plaintext))
        done = ct.c_ulong()
        self.check(self.bc.BCryptEncrypt(self.key, src, len(plaintext), ct.byref(info), None, 0, out,
                                         len(plaintext), ct.byref(done), 0))
        return out.raw[:done.value] + tag.raw

    def decrypt(self, nonce, data, aad):
        """Plaintext, or None if the tag doesn't match (wrong key, modified packet)."""
        ct = self.ct
        if len(data) < self.TAG:
            return None
        body, tag_bytes = data[:-self.TAG], data[-self.TAG:]
        n, a = ct.create_string_buffer(nonce, len(nonce)), ct.create_string_buffer(aad, len(aad))
        tag = ct.create_string_buffer(tag_bytes, self.TAG)
        info = self._info(n, a, tag)
        src = ct.create_string_buffer(body, len(body))
        out = ct.create_string_buffer(max(len(body), 1))
        done = ct.c_ulong()
        status = self.bc.BCryptDecrypt(self.key, src, len(body), ct.byref(info), None, 0, out, len(body),
                                       ct.byref(done), 0)
        if status != 0:
            return None
        return out.raw[:done.value]


class Auth:
    """Optional packet protection with a secret both players share.

    On Windows (where the game runs) every packet is encrypted and authenticated with AES-256-GCM (Windows CNG);
    elsewhere it is signed with HMAC-SHA256. Either way it carries the sender's random session id and a counter, and
    packets with a bad tag, from another protocol, or replayed (counter not above the last one seen for that session)
    are dropped. Without a secret packets are plain (and only the address filter applies)."""

    AAD = b"PhantomPact/2"

    def __init__(self, secret, encrypt=True):
        self.key = hashlib.sha256(secret.encode()).digest() if secret else None
        self.aead = None
        if self.key is not None and encrypt and os.name == "nt":
            try:
                self.aead = AesGcm(self.key)
            except (OSError, AttributeError):
                self.aead = None
        self.sid = secrets.token_hex(8)
        self.sid_bytes = secrets.token_bytes(6)
        self.counter = 0
        self.seen = collections.OrderedDict()   # peer session id -> highest counter accepted
        self.rejected = 0

    @property
    def mode(self):
        return "aes-gcm" if self.aead else ("hmac" if self.key else "off")

    def seal(self, msg):
        if self.key is None:
            return json.dumps(msg, separators=(",", ":")).encode()
        self.counter += 1
        if self.aead:
            nonce = self.sid_bytes + self.counter.to_bytes(6, "big")
            body = json.dumps(msg, separators=(",", ":")).encode()
            return b"E" + nonce + self.aead.encrypt(nonce, body, self.AAD)
        msg["a"] = self.sid
        msg["n"] = self.counter
        body = json.dumps(msg, separators=(",", ":")).encode()
        return body + b"\n" + hmac.new(self.key, body, hashlib.sha256).digest()[:MAC_BYTES].hex().encode()

    def _fresh(self, sid, n):
        """Replay check: the counter must grow within each sender session."""
        if n <= self.seen.get(sid, 0):
            return False
        self.seen[sid] = n
        self.seen.move_to_end(sid)
        while len(self.seen) > REPLAY_SESSIONS:
            self.seen.popitem(last=False)
        return True

    def open(self, data):
        """The message dict, or None if the packet must be dropped."""
        if self.aead:
            # Encrypted only: a plain or HMAC packet is refused, so nobody can downgrade the session.
            if data[:1] != b"E" or len(data) < 13 + AesGcm.TAG:
                self.rejected += 1
                return None
            nonce = data[1:13]
            body = self.aead.decrypt(nonce, data[13:], self.AAD)
            if body is None or not self._fresh(nonce[:6].hex(), int.from_bytes(nonce[6:], "big")):
                self.rejected += 1
                return None
        elif self.key is None:
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
        if self.key is not None and not self.aead:
            sid, n = msg.get("a"), msg.get("n")
            if not isinstance(sid, str) or not isinstance(n, int) or not self._fresh(sid, n):
                self.rejected += 1
                return None
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


class UdpTransport:
    """Plain UDP: Tailscale (default) or Direct (port forwarding)."""

    name = "udp"

    def __init__(self, role, peer, port):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setblocking(False)
        if role == "host":
            self.sock.bind(("0.0.0.0", port))
            self.peer = None              # learned from the first packet
        else:
            self.sock.bind(("0.0.0.0", 0))
            # Resolved once: replies are only accepted from exactly this address and port.
            self.peer = (socket.gethostbyname(peer), port)

    def fileno(self):
        return self.sock

    def send(self, data, peer):
        self.sock.sendto(data, peer)

    def receive(self):
        while True:
            try:
                yield self.sock.recvfrom(65535)
            except BlockingIOError:
                return
            except ConnectionResetError:
                # Windows reports ICMP "port unreachable" this way while the peer isn't running yet.
                continue

    def poll(self):
        pass

    def close(self):
        self.sock.close()


# ---------------------------------------------------------------------------------------------------------- UPnP

SSDP_ADDR = ("239.255.255.250", 1900)
WAN_SERVICES = ("urn:schemas-upnp-org:service:WANIPConnection:2", "urn:schemas-upnp-org:service:WANIPConnection:1",
                "urn:schemas-upnp-org:service:WANPPPConnection:1")


def ssdp_location(response):
    """LOCATION header of an SSDP reply, or None."""
    for line in response.decode("latin-1").split("\r\n"):
        key, sep, value = line.partition(":")
        if sep and key.strip().lower() == "location":
            return value.strip()
    return None


def upnp_discover(timeout=2.0):
    """URL of the router's (Internet Gateway Device) description, found by SSDP multicast, or None."""
    msg = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n"
           "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n").encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(msg, SSDP_ADDR)
        while True:
            data, _ = s.recvfrom(4096)
            loc = ssdp_location(data)
            if loc:
                return loc
    except OSError:
        return None
    finally:
        s.close()


def upnp_control(location, timeout=3.0):
    """(control URL, service type) of the router's WAN connection service, from its description XML."""
    import urllib.parse
    import urllib.request
    import xml.etree.ElementTree as ET
    with urllib.request.urlopen(location, timeout=timeout) as r:
        root = ET.fromstring(r.read())
    ns = {"d": "urn:schemas-upnp-org:device-1-0"}
    base = root.findtext("d:URLBase", default="", namespaces=ns) or location
    for svc in root.iter("{urn:schemas-upnp-org:device-1-0}service"):
        stype = svc.findtext("d:serviceType", default="", namespaces=ns)
        if stype in WAN_SERVICES:
            return urllib.parse.urljoin(base, svc.findtext("d:controlURL", default="", namespaces=ns)), stype
    raise OSError("router has no WAN IP/PPP connection service")


def upnp_call(control, stype, action, args, timeout=3.0):
    """One SOAP action; returns the response body (raises OSError on an HTTP error)."""
    import urllib.request
    from xml.sax.saxutils import escape
    body = "".join(f"<{k}>{escape(str(v))}</{k}>" for k, v in args)
    envelope = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
                's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
                f'<u:{action} xmlns:u="{stype}">{body}</u:{action}></s:Body></s:Envelope>').encode()
    req = urllib.request.Request(control, data=envelope, method="POST", headers={
        "Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": f'"{stype}#{action}"'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def local_ip_toward(host):
    """This PC's address on the interface that reaches host (no packet is sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((host, 1900))
        return s.getsockname()[0]
    finally:
        s.close()


class PortMapping:
    """Asks the router to forward UDP <port> to this PC (UPnP IGD) and removes the mapping on close."""

    LEASE_S = 3600          # renewed while the relay runs; a crashed relay's mapping expires on its own
    DESCRIPTION = "Phantom Pact co-op"

    def __init__(self, port, location=None):
        import urllib.parse
        self.port = port
        self.location = location or upnp_discover()
        if not self.location:
            raise OSError("no UPnP router answered (UPnP off on the router?)")
        self.control, self.stype = upnp_control(self.location)
        self.client = local_ip_toward(urllib.parse.urlparse(self.control).hostname)
        self.external_ip = ""
        self.renewed = 0.0
        self.renew(time.monotonic())
        try:
            reply = upnp_call(self.control, self.stype, "GetExternalIPAddress", [])
            self.external_ip = reply.split("<NewExternalIPAddress>", 1)[1].split("<", 1)[0]
        except (OSError, IndexError):
            pass

    def renew(self, now):
        upnp_call(self.control, self.stype, "AddPortMapping", [
            ("NewRemoteHost", ""), ("NewExternalPort", self.port), ("NewProtocol", "UDP"),
            ("NewInternalPort", self.port), ("NewInternalClient", self.client), ("NewEnabled", 1),
            ("NewPortMappingDescription", self.DESCRIPTION), ("NewLeaseDuration", self.LEASE_S)])
        self.renewed = now

    def keep_alive(self, now):
        if now - self.renewed >= self.LEASE_S / 2:
            try:
                self.renew(now)
            except OSError:
                pass

    def close(self):
        try:
            upnp_call(self.control, self.stype, "DeletePortMapping", [
                ("NewRemoteHost", ""), ("NewExternalPort", self.port), ("NewProtocol", "UDP")])
        except OSError:
            pass


# ---------------------------------------------------------------------------------------------------------- Steam

STEAM_APP_ID = 4115450      # Phantom Blade Zero
STEAM_CHANNEL = 47800       # Steam Networking Messages channel for Phantom Pact
SEND_NO_NAGLE = 1           # k_nSteamNetworkingSend_NoNagle (unreliable): snapshots and events are resent anyway
SEND_AUTO_RESTART = 32      # k_nSteamNetworkingSend_AutoRestartBrokenSession
IDENTITY_BYTES = 136        # sizeof(SteamNetworkingIdentity)
IDENTITY_STEAMID = 16       # k_ESteamNetworkingIdentityType_SteamID
FRIEND_FLAG_IMMEDIATE = 4   # k_EFriendFlagImmediate: regular friends


class SteamTransport:
    """Steam Networking Messages through the game's steam_api64.dll: peer-to-peer with NAT traversal and Valve's
    relay network (SDR) as fallback, encrypted and authenticated by Steam. No VPN, no port forwarding, no IP
    address: each player sets the other's SteamID64. Steam must be running and signed in."""

    name = "steam"

    PRESENCE_KEY = b"phantompact"   # Steam rich presence: our role, so a friend's relay can find us
    FIND_EVERY = 2.0                # seconds between friend-list scans while looking for the partner

    def __init__(self, dll_path, partner_id, role="host"):
        import ctypes
        from ctypes import c_bool, c_char_p, c_int, c_int64, c_uint32, c_uint64, c_void_p, POINTER
        self.ct = ctypes
        os.environ.setdefault("SteamAppId", str(STEAM_APP_ID))
        os.environ.setdefault("SteamGameId", str(STEAM_APP_ID))
        if os.path.isdir(dll_path):
            dll_path = os.path.join(dll_path, "steam_api64.dll")
        self.api = api = ctypes.CDLL(dll_path)
        api.SteamAPI_InitFlat.argtypes = [c_char_p]
        api.SteamAPI_InitFlat.restype = c_int
        err = ctypes.create_string_buffer(1024)
        result = api.SteamAPI_InitFlat(err)
        if result != 0:
            raise OSError(f"SteamAPI init failed ({result}): {err.value.decode(errors='replace')}")
        for fn, res, args in [
            ("SteamAPI_SteamUser_v023", c_void_p, []),
            ("SteamAPI_ISteamUser_GetSteamID", c_uint64, [c_void_p]),
            ("SteamAPI_SteamNetworkingUtils_SteamAPI_v004", c_void_p, []),
            ("SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess", None, [c_void_p]),
            ("SteamAPI_SteamNetworkingMessages_SteamAPI_v002", c_void_p, []),
            ("SteamAPI_SteamNetworkingIdentity_SetSteamID64", None, [c_void_p, c_uint64]),
            ("SteamAPI_ISteamNetworkingMessages_SendMessageToUser", c_int,
             [c_void_p, c_void_p, c_void_p, c_uint32, c_int, c_int]),
            ("SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser", c_bool, [c_void_p, c_void_p]),
            ("SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel", c_int,
             [c_void_p, c_int, POINTER(c_void_p), c_int]),
            ("SteamAPI_SteamNetworkingMessage_t_Release", None, [c_void_p]),
            ("SteamAPI_RunCallbacks", None, []),
            ("SteamAPI_Shutdown", None, []),
            ("SteamAPI_SteamFriends_v018", c_void_p, []),
            ("SteamAPI_ISteamFriends_SetRichPresence", c_bool, [c_void_p, c_char_p, c_char_p]),
            ("SteamAPI_ISteamFriends_GetFriendCount", c_int, [c_void_p, c_int]),
            ("SteamAPI_ISteamFriends_GetFriendByIndex", c_uint64, [c_void_p, c_int, c_int]),
            ("SteamAPI_ISteamFriends_GetFriendRichPresence", c_char_p, [c_void_p, c_uint64, c_char_p]),
            ("SteamAPI_ISteamFriends_GetFriendPersonaName", c_char_p, [c_void_p, c_uint64]),
        ]:
            f = getattr(api, fn)
            f.restype, f.argtypes = res, args
        self.my_id = api.SteamAPI_ISteamUser_GetSteamID(api.SteamAPI_SteamUser_v023())
        api.SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(api.SteamAPI_SteamNetworkingUtils_SteamAPI_v004())
        self.msgs = api.SteamAPI_SteamNetworkingMessages_SteamAPI_v002()
        self.friends = api.SteamAPI_SteamFriends_v018()
        self.role = role
        # Advertise our role; friends playing PBZ see it, which is how PartnerSteamID = Auto finds the partner.
        api.SteamAPI_ISteamFriends_SetRichPresence(self.friends, self.PRESENCE_KEY, role.encode())
        self.identity = ctypes.create_string_buffer(IDENTITY_BYTES)
        self.partner, self.peer, self.partner_name = None, None, ""
        self.last_find = 0.0
        if str(partner_id).lower() != "auto":
            self.set_partner(int(partner_id))
        self.out = (c_void_p * 64)()
        self.last_result = None

    def set_partner(self, steam_id, name=""):
        self.partner = steam_id
        self.partner_name = name
        self.api.SteamAPI_SteamNetworkingIdentity_SetSteamID64(self.identity, steam_id)
        # Sending to the partner accepts their session too; accept explicitly as well in case they spoke first.
        self.api.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser(self.msgs, self.identity)
        self.peer = ("steam", steam_id)

    def find_partner(self):
        """PartnerSteamID = Auto: the first Steam friend whose Phantom Pact relay advertises the other role (a host
        looks for a client and the other way round). Rich presence is only visible for friends in the same game."""
        want = b"client" if self.role == "host" else b"host"
        api = self.api
        count = api.SteamAPI_ISteamFriends_GetFriendCount(self.friends, FRIEND_FLAG_IMMEDIATE)
        for i in range(max(0, count)):
            fid = api.SteamAPI_ISteamFriends_GetFriendByIndex(self.friends, i, FRIEND_FLAG_IMMEDIATE)
            if api.SteamAPI_ISteamFriends_GetFriendRichPresence(self.friends, fid, self.PRESENCE_KEY) == want:
                name = (api.SteamAPI_ISteamFriends_GetFriendPersonaName(self.friends, fid) or b"").decode(
                    "utf-8", "replace")
                self.set_partner(fid, name)
                return True
        return False

    def fileno(self):
        return None

    def send(self, data, peer):
        if self.partner is None:
            return                  # PartnerSteamID = Auto, partner not found yet
        buf = self.ct.create_string_buffer(data, len(data))
        self.last_result = self.api.SteamAPI_ISteamNetworkingMessages_SendMessageToUser(
            self.msgs, self.identity, buf, len(data), SEND_NO_NAGLE | SEND_AUTO_RESTART, STEAM_CHANNEL)

    def receive(self):
        ct = self.ct
        n = self.api.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(self.msgs, STEAM_CHANNEL, self.out, 64)
        for i in range(n):
            m = self.out[i]
            # SteamNetworkingMessage_t: void *m_pData; int m_cbSize; HSteamNetConnection m_conn;
            # SteamNetworkingIdentity m_identityPeer { int m_eType; int m_cbSize; uint64 m_steamID64; ... }
            data_ptr = ct.c_void_p.from_address(m).value
            size = ct.c_int.from_address(m + 8).value
            id_type = ct.c_int.from_address(m + 16).value
            sender = ct.c_uint64.from_address(m + 24).value if id_type == IDENTITY_STEAMID else 0
            data = ct.string_at(data_ptr, size) if data_ptr and size > 0 else b""
            self.api.SteamAPI_SteamNetworkingMessage_t_Release(m)
            yield data, ("steam", sender)

    def poll(self):
        self.api.SteamAPI_RunCallbacks()
        if self.partner is None and time.monotonic() - self.last_find >= self.FIND_EVERY:
            self.last_find = time.monotonic()
            self.find_partner()

    def close(self):
        # No SteamAPI_Shutdown: called while the networking thread is still flushing it sometimes ends the process
        # with an error ("Writing to pipe we closed locally"), and the relay only closes when it exits anyway;
        # Steam releases the session when the process ends.
        pass


class Relay:
    def __init__(self, role, folder, peer, port, secret="", allow="tailscale", transport=None):
        self.role = role
        self.auth = Auth(secret)
        self.allowed = ALLOWED_NETWORKS[allow]
        self.filtered = 0                 # packets dropped because of their sender address
        self.out_path = os.path.join(folder, "net_out.txt")
        self.in_path = os.path.join(folder, "net_in.txt")
        self.events_out_path = os.path.join(folder, "net_events_out.txt")
        self.status_path = os.path.join(folder, "net_status.txt")
        self.inbox = EventInbox(os.path.join(folder, "net_events_in.txt"))
        self.transport = transport or UdpTransport(role, peer, port)
        self.peer = self.transport.peer
        self.extra_status = ""            # transport details for net_status.txt (UPnP, Steam ids)
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
        ini = read_ini(folder)
        self.hello = {"t": "hello", "ver": mod_version(folder), "cfg": {k: ini.get(k, "") for k in SHARED_SETTINGS}}
        self.partner_version = None
        self.mismatch = []                # "key=mine/theirs" from the partner's hello

    def send(self, msg):
        if self.transport.name == "steam":
            self.peer = self.transport.peer          # may have just been found (PartnerSteamID = Auto)
        if self.peer is None:
            return
        msg["v"] = PROTOCOL
        try:
            self.transport.send(self.auth.seal(msg), self.peer)
            self.sent += 1
        except OSError:
            pass

    def receive_all(self, now):
        for data, addr in self.transport.receive():
            # The client only listens to the host it was given; the host only to allowed networks. Over Steam the
            # sender is the authenticated SteamID and only the configured partner is accepted.
            if self.transport.name == "steam":
                self.peer = self.transport.peer      # may have just been found (PartnerSteamID = Auto)
                if self.peer is None or addr != self.peer:
                    self.filtered += 1
                    continue
            elif (self.role != "host" and addr != self.peer) or not address_allowed(addr, self.allowed):
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
            if kind == "hello" and isinstance(msg.get("cfg"), dict):
                self.partner_version = str(msg.get("ver"))
                self.mismatch = compare_settings(self.hello, msg)
            elif kind == "ping":
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
            sock = self.transport.fileno()
            if sock is not None:
                ready, _, _ = select.select([sock], [], [], min(remaining, WATCH))
            else:
                # Steam delivers messages to a queue we poll; there is no socket to wait on.
                time.sleep(min(remaining, WATCH))
                self.transport.poll()
                ready = True
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
            self.send(dict(self.hello))
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
                f"version={self.hello['ver']} partner_version={self.partner_version or '-'} "
                f"mismatch={','.join(self.mismatch) or '-'} "
                f"events_acked={self.events_acked} events_in={self.inbox.last_id} "
                f"auth={self.auth.mode} rejected={self.auth.rejected} filtered={self.filtered} "
                f"{self.extra_status + ' ' if self.extra_status else ''}time={int(time.time())}")


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


def game_running():
    """Is PBZ.exe still running (Windows: tasklist; elsewhere the game doesn't run)."""
    if os.name != "nt":
        return False
    import subprocess
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq PBZ.exe", "/NH"], capture_output=True, text=True,
                             creationflags=0x08000000).stdout
    except OSError:
        return False
    return "pbz.exe" in out.lower()


def coop_sync_after_game(folder, running, timeout):
    """PhantomPact.ini CoopSyncTool = path to pbzsave.exe: once the game has closed, record what the partner shared
    (shared_world.txt) in the save with "pbzsave coop-sync" (it refuses while the game runs, so wait for it to
    exit). The tool's output goes to coop_sync.log in the mod folder."""
    import subprocess
    tool = read_ini(folder).get("coopsynctool", "")
    log = os.path.join(folder, "coop_sync.log")
    ledger = os.path.join(folder, "shared_world.txt")
    if not tool or not read_text(ledger).strip():
        return
    if not os.path.isfile(tool):
        write_atomic(log, f"CoopSyncTool not found: {tool}\n")
        return
    deadline = time.monotonic() + timeout
    while running():
        if time.monotonic() >= deadline:
            write_atomic(log, "the game didn't exit in time; nothing written (run pbzsave coop-sync by hand)\n")
            return
        time.sleep(2)
    try:
        p = subprocess.run([tool, "coop-sync", ledger], capture_output=True, text=True,
                           creationflags=0x08000000 if os.name == "nt" else 0)
        write_atomic(log, f"exit {p.returncode}\n{p.stdout}{p.stderr}")
    except OSError as e:
        write_atomic(log, f"couldn't run {tool}: {e}\n")


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
    ap.add_argument("--insecure", action="store_true", help="allow --allow any without a secret (not recommended)")
    ap.add_argument("--upnp", action="store_true", help="host, Direct: ask the router to forward the port (UPnP)")
    ap.add_argument("--upnp-location", help=argparse.SUPPRESS)   # tests: a fake router's description URL
    ap.add_argument("--transport", choices=["udp", "steam"], default="udp",
                    help="udp (Tailscale or Direct) or steam (Steam Networking Messages)")
    ap.add_argument("--partner", help="steam: the other player's SteamID64")
    ap.add_argument("--steam-dll", help="steam: steam_api64.dll (or the game folder that holds it)")
    args = ap.parse_args()
    if args.role == "client" and args.transport == "udp" and not args.peer:
        ap.error("client needs --peer <host IP>")
    if args.transport == "steam" and not (args.partner and (args.partner.isdigit() or args.partner.lower() == "auto")
                                          and args.steam_dll):
        ap.error("steam needs --partner <SteamID64 | auto> and --steam-dll <path>")
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
    status_path = os.path.join(args.dir, "net_status.txt")
    secret = read_secret(args.dir, args.secret_file)
    if args.transport == "udp" and args.allow == "any" and not secret and not args.insecure:
        # An open port without signing would let anyone who finds it join or send events.
        write_atomic(status_path, f"role={args.role} connected=no error=direct-needs-secret time={int(time.time())}\n")
        print("Direct needs a Secret: set the same Secret in PhantomPact.ini on both PCs", flush=True)
        raise SystemExit(2)
    transport, mapping = None, None
    if args.transport == "steam":
        try:
            transport = SteamTransport(args.steam_dll, args.partner, role=args.role)
        except OSError as e:
            write_atomic(status_path, f"role={args.role} connected=no error=steam-init time={int(time.time())}\n")
            print(f"Steam networking unavailable: {e}", flush=True)
            raise SystemExit(3)
    relay = Relay(args.role, args.dir, args.peer, args.port, secret=secret, allow=args.allow, transport=transport)
    if transport is not None:
        relay.extra_status = f"transport=steam me={transport.my_id} partner={transport.partner or 'searching'}"
    if args.upnp and args.role == "host" and args.transport == "udp":
        try:
            mapping = PortMapping(args.port, args.upnp_location)
            relay.extra_status = f"upnp=ok external_ip={mapping.external_ip or '?'}"
        except (OSError, ValueError) as e:
            relay.extra_status = "upnp=failed"
            print(f"UPnP port forwarding failed ({e}); forward UDP {args.port} on the router by hand", flush=True)
    print(f"PBZCoop relay {args.role} over {args.transport} (port {args.port}), files in {args.dir}, "
          f"auth {relay.auth.mode if secret else 'off (set Secret in PhantomPact.ini)'}, allow {args.allow} "
          f"{relay.extra_status}", flush=True)
    start = time.monotonic()
    last_status = 0.0
    game_closed = False
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
                game_closed = True
                break
            if mapping:
                mapping.keep_alive(now)
            if transport is not None:
                who = transport.partner and f"{transport.partner}" or "searching"
                relay.extra_status = f"transport=steam me={transport.my_id} partner={who}"
            relay.wait(TICK)
    except KeyboardInterrupt:
        pass
    finally:
        if mapping:
            mapping.close()
        relay.transport.close()
        write_atomic(relay.status_path, f"role={args.role} connected=no stopped=yes\n")
    if game_closed:
        coop_sync_after_game(args.dir, game_running, 120.0)


if __name__ == "__main__":
    main()
