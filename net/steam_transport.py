"""Steam P2P transport for the relay: Steam Networking Messages through the game's own steam_api64.dll.

The relay runs as its own small Steam app process (the game's app id), next to the game; nothing in the game is
touched. Steam finds the route (direct, or through Valve's relays when NAT gets in the way), so players need no
Tailscale, no port forwarding and no IP addresses: the guest finds the host among Steam friends who are in
Phantom Blade Zero and running a Phantom Pact host.

Only what the relay needs is wrapped: init, own id/name, friends in the same game, send, receive, and accepting
session requests (through manual callback dispatch, so no C++ callback classes are needed from Python).
"""

import ctypes
import os

APP_ID = 4115450
CHANNEL = 0

SEND_UNRELIABLE = 0
SEND_NO_NAGLE = 1
SEND_RELIABLE = 8
SEND_AUTO_RESTART_BROKEN_SESSION = 32

FRIEND_FLAG_IMMEDIATE = 4               # regular Steam friends
IDENTITY_TYPE_STEAMID = 16
CALLBACK_SESSION_REQUEST = 1251         # SteamNetworkingMessagesSessionRequest_t
CALLBACK_SESSION_FAILED = 1252          # SteamNetworkingMessagesSessionFailed_t


class Identity(ctypes.Structure):
    """SteamNetworkingIdentity: a type tag, a size and a 128-byte union (the SteamID64 sits at its start)."""
    _fields_ = [("type", ctypes.c_int32), ("size", ctypes.c_int32), ("steam_id", ctypes.c_uint64),
                ("rest", ctypes.c_uint8 * 120)]


class Message(ctypes.Structure):
    """The leading fields of SteamNetworkingMessage_t (it is released through the API, never freed here)."""
    _fields_ = [("data", ctypes.c_void_p), ("size", ctypes.c_int32), ("conn", ctypes.c_uint32),
                ("peer", Identity)]


class CallbackMsg(ctypes.Structure):
    _fields_ = [("user", ctypes.c_int32), ("callback", ctypes.c_int32), ("param", ctypes.c_void_p),
                ("param_size", ctypes.c_int32)]


class FriendGameInfo(ctypes.Structure):
    _fields_ = [("game_id", ctypes.c_uint64), ("ip", ctypes.c_uint32), ("port", ctypes.c_uint16),
                ("query_port", ctypes.c_uint16), ("lobby", ctypes.c_uint64)]


class SteamError(RuntimeError):
    pass


def find_steam_api(start):
    """The game ships steam_api64.dll in its root; the mod folder is <game>\\platform\\steam\\ue4ss\\Mods\\PBZCoop."""
    folder = os.path.abspath(start)
    for _ in range(8):
        candidate = os.path.join(folder, "steam_api64.dll")
        if os.path.isfile(candidate):
            return candidate
        parent = os.path.dirname(folder)
        if parent == folder:
            break
        folder = parent
    return None


def _fn(dll, name, restype, *argtypes):
    f = getattr(dll, name)
    f.restype = restype
    f.argtypes = list(argtypes)
    return f


class SteamTransport:
    """send(peer_id, bytes) / receive() -> [(peer_id, bytes)], where peer_id is a SteamID64 (int)."""

    def __init__(self, dll_path, app_id=APP_ID):
        os.environ["SteamAppId"] = os.environ["SteamGameId"] = str(app_id)
        self.app_id = app_id
        dll = ctypes.CDLL(dll_path)
        err = ctypes.create_string_buffer(1024)
        _fn(dll, "SteamAPI_InitFlat", ctypes.c_int, ctypes.c_char_p)
        result = dll.SteamAPI_InitFlat(err)
        if result != 0:
            raise SteamError(f"Steam didn't start for the relay (code {result}): {err.value.decode(errors='replace')}"
                             " - is Steam running and logged in?")
        self.dll = dll
        vp, u64, i32 = ctypes.c_void_p, ctypes.c_uint64, ctypes.c_int
        _fn(dll, "SteamAPI_ManualDispatch_Init", None)()
        self._pipe = _fn(dll, "SteamAPI_GetHSteamPipe", ctypes.c_int32)()
        self._run_frame = _fn(dll, "SteamAPI_ManualDispatch_RunFrame", None, ctypes.c_int32)
        self._next_cb = _fn(dll, "SteamAPI_ManualDispatch_GetNextCallback", ctypes.c_bool, ctypes.c_int32,
                            ctypes.POINTER(CallbackMsg))
        self._free_cb = _fn(dll, "SteamAPI_ManualDispatch_FreeLastCallback", None, ctypes.c_int32)

        user = _fn(dll, "SteamAPI_SteamUser_v023", vp)()
        self.my_id = _fn(dll, "SteamAPI_ISteamUser_GetSteamID", u64, vp)(user)
        self._friends = _fn(dll, "SteamAPI_SteamFriends_v018", vp)()
        self._persona = _fn(dll, "SteamAPI_ISteamFriends_GetPersonaName", ctypes.c_char_p, vp)
        self._friend_count = _fn(dll, "SteamAPI_ISteamFriends_GetFriendCount", i32, vp, i32)
        self._friend_by_index = _fn(dll, "SteamAPI_ISteamFriends_GetFriendByIndex", u64, vp, i32, i32)
        self._friend_game = _fn(dll, "SteamAPI_ISteamFriends_GetFriendGamePlayed", ctypes.c_bool, vp, u64,
                                ctypes.POINTER(FriendGameInfo))
        self._friend_name = _fn(dll, "SteamAPI_ISteamFriends_GetFriendPersonaName", ctypes.c_char_p, vp, u64)

        utils = _fn(dll, "SteamAPI_SteamNetworkingUtils_SteamAPI_v004", vp)()
        _fn(dll, "SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess", None, vp)(utils)
        self._msgs = _fn(dll, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002", vp)()
        self._send = _fn(dll, "SteamAPI_ISteamNetworkingMessages_SendMessageToUser", i32, vp,
                         ctypes.POINTER(Identity), vp, ctypes.c_uint32, i32, i32)
        self._receive = _fn(dll, "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel", i32, vp, i32,
                            ctypes.POINTER(ctypes.POINTER(Message)), i32)
        self._accept = _fn(dll, "SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser", ctypes.c_bool, vp,
                           ctypes.POINTER(Identity))
        self._release = _fn(dll, "SteamAPI_SteamNetworkingMessage_t_Release", None, ctypes.POINTER(Message))
        self._shutdown = _fn(dll, "SteamAPI_Shutdown", None)
        self.accept_from = None          # None: accept any friend; else a set of SteamID64s
        self.failures = 0

    @property
    def my_name(self):
        return self._persona(self._friends).decode("utf-8", errors="replace")

    def friend_name(self, steam_id):
        return (self._friend_name(self._friends, steam_id) or b"").decode("utf-8", errors="replace")

    def friends_in_game(self):
        """[(steam_id, name)] of Steam friends currently playing this app (the low 24 bits of a game id)."""
        out, info = [], FriendGameInfo()
        for i in range(self._friend_count(self._friends, FRIEND_FLAG_IMMEDIATE)):
            fid = self._friend_by_index(self._friends, i, FRIEND_FLAG_IMMEDIATE)
            if self._friend_game(self._friends, fid, ctypes.byref(info)) and info.game_id & 0xFFFFFF == self.app_id:
                out.append((fid, self.friend_name(fid)))
        return out

    def is_friend(self, steam_id):
        for i in range(self._friend_count(self._friends, FRIEND_FLAG_IMMEDIATE)):
            if self._friend_by_index(self._friends, i, FRIEND_FLAG_IMMEDIATE) == steam_id:
                return True
        return False

    @staticmethod
    def _identity(steam_id):
        ident = Identity()
        ident.type, ident.size, ident.steam_id = IDENTITY_TYPE_STEAMID, 8, steam_id
        return ident

    def send(self, steam_id, data, reliable=False):
        flags = (SEND_RELIABLE if reliable else SEND_UNRELIABLE) | SEND_NO_NAGLE | SEND_AUTO_RESTART_BROKEN_SESSION
        buf = ctypes.create_string_buffer(data, len(data))
        return self._send(self._msgs, ctypes.byref(self._identity(steam_id)), buf, len(data), flags, CHANNEL) == 1

    def _dispatch(self):
        """Accept session requests from friends (strangers are ignored, so their messages are dropped)."""
        self._run_frame(self._pipe)
        cb = CallbackMsg()
        while self._next_cb(self._pipe, ctypes.byref(cb)):
            try:
                if cb.callback == CALLBACK_SESSION_REQUEST and cb.param:
                    ident = Identity.from_address(cb.param)
                    sid = ident.steam_id
                    allowed = sid in self.accept_from if self.accept_from is not None else self.is_friend(sid)
                    if allowed:
                        self._accept(self._msgs, ctypes.byref(ident))
                elif cb.callback == CALLBACK_SESSION_FAILED:
                    self.failures += 1
            finally:
                self._free_cb(self._pipe)

    def receive(self):
        self._dispatch()
        out = []
        batch = (ctypes.POINTER(Message) * 32)()
        while True:
            n = self._receive(self._msgs, CHANNEL, batch, 32)
            for i in range(max(n, 0)):
                m = batch[i].contents
                out.append((m.peer.steam_id, ctypes.string_at(m.data, m.size)))
                self._release(batch[i])
            if n < 32:
                return out

    def close(self):
        if self.dll is not None:
            self._shutdown()
            self.dll = None
