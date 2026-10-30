//! Transports: plain UDP (Tailscale or Direct) and Steam Networking Messages through the game's steam_api64.dll.

use std::fmt;
use std::io::ErrorKind;
use std::net::{SocketAddr, ToSocketAddrs, UdpSocket};
use std::thread::sleep;
use std::time::{Duration, Instant};

#[derive(Clone, Debug, PartialEq)]
pub enum Peer {
    Udp(SocketAddr),
    Steam(u64),
}

impl fmt::Display for Peer {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Peer::Udp(a) => write!(f, "{}:{}", a.ip(), a.port()),
            Peer::Steam(id) => write!(f, "steam:{id}"),
        }
    }
}

pub trait Transport {
    fn name(&self) -> &'static str;
    /// The peer to send to: the client's host, or the Steam partner once known; None for a host until it hears one.
    fn peer(&self) -> Option<Peer>;
    fn send(&mut self, data: &[u8], peer: &Peer);
    /// Waits up to `wait` for a packet, then returns everything that arrived.
    fn receive(&mut self, wait: Duration) -> Vec<(Vec<u8>, Peer)>;
    /// Extra fields for net_status.txt.
    fn status(&self) -> String {
        String::new()
    }
}

pub struct Udp {
    sock: UdpSocket,
    peer: Option<Peer>,
    buf: Vec<u8>,
}

impl Udp {
    pub fn new(host: bool, peer: Option<&str>, port: u16) -> std::io::Result<Udp> {
        let sock = UdpSocket::bind(("0.0.0.0", if host { port } else { 0 }))?;
        // Resolved once: replies are only accepted from exactly this address and port.
        let peer = match (host, peer) {
            (false, Some(p)) => Some(Peer::Udp(
                (p, port)
                    .to_socket_addrs()?
                    .find(SocketAddr::is_ipv4)
                    .ok_or_else(|| std::io::Error::new(ErrorKind::NotFound, format!("no IPv4 address for {p}")))?,
            )),
            _ => None,
        };
        Ok(Udp { sock, peer, buf: vec![0; 65535] })
    }
}

impl Transport for Udp {
    fn name(&self) -> &'static str {
        "udp"
    }
    fn peer(&self) -> Option<Peer> {
        self.peer.clone()
    }
    fn send(&mut self, data: &[u8], peer: &Peer) {
        if let Peer::Udp(a) = peer {
            let _ = self.sock.send_to(data, a);
        }
    }
    fn receive(&mut self, wait: Duration) -> Vec<(Vec<u8>, Peer)> {
        let deadline = Instant::now() + wait;
        let mut out = vec![];
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            // Block for the first packet (until the deadline), then drain whatever else is queued.
            let blocking = out.is_empty() && !left.is_zero();
            let _ = self.sock.set_nonblocking(!blocking);
            if blocking {
                let _ = self.sock.set_read_timeout(Some(left.max(Duration::from_millis(1))));
            }
            match self.sock.recv_from(&mut self.buf) {
                Ok((n, a)) => out.push((self.buf[..n].to_vec(), Peer::Udp(a))),
                // Windows reports ICMP "port unreachable" this way while the peer isn't running yet.
                Err(e) if e.kind() == ErrorKind::ConnectionReset => continue,
                Err(_) => break,
            }
        }
        out
    }
}

// ------------------------------------------------------------------------------------------------------- Steam

pub const STEAM_APP_ID: u32 = 4115450; // Phantom Blade Zero
const STEAM_CHANNEL: i32 = 47800; // Steam Networking Messages channel for Phantom Pact
const SEND_FLAGS: i32 = 1 | 32; // NoNagle (unreliable; we resend anyway) | AutoRestartBrokenSession
const IDENTITY_BYTES: usize = 136; // sizeof(SteamNetworkingIdentity)
const IDENTITY_STEAMID: i32 = 16;
const FRIEND_FLAG_IMMEDIATE: i32 = 4;
const PRESENCE_KEY: &[u8] = b"phantompact\0";
const FIND_EVERY: Duration = Duration::from_secs(2);
const WATCH: Duration = Duration::from_millis(5);

type P = *mut std::ffi::c_void;

/// The steam_api64.dll flat functions we use (same as the Python relay's ctypes list).
struct SteamApi {
    _lib: libloading::Library,
    user_get_steam_id: unsafe extern "C" fn(P) -> u64,
    identity_set_steam_id: unsafe extern "C" fn(P, u64),
    send_message: unsafe extern "C" fn(P, P, *const u8, u32, i32, i32) -> i32,
    accept_session: unsafe extern "C" fn(P, P) -> bool,
    receive_messages: unsafe extern "C" fn(P, i32, *mut P, i32) -> i32,
    release_message: unsafe extern "C" fn(P),
    run_callbacks: unsafe extern "C" fn(),
    set_rich_presence: unsafe extern "C" fn(P, *const u8, *const u8) -> bool,
    friend_count: unsafe extern "C" fn(P, i32) -> i32,
    friend_by_index: unsafe extern "C" fn(P, i32, i32) -> u64,
    friend_rich_presence: unsafe extern "C" fn(P, u64, *const u8) -> *const std::ffi::c_char,
}

pub struct Steam {
    api: SteamApi,
    msgs: P,
    friends: P,
    pub my_id: u64,
    role_host: bool,
    identity: Vec<u8>,
    pub partner: Option<u64>,
    last_find: Option<Instant>,
    pub last_result: i32,
}

impl Steam {
    /// `partner`: a SteamID64, or "auto" to find the friend whose relay advertises the other role.
    pub fn new(dll: &std::path::Path, partner: &str, host: bool) -> Result<Steam, String> {
        if std::env::var_os("SteamAppId").is_none() {
            std::env::set_var("SteamAppId", STEAM_APP_ID.to_string());
        }
        if std::env::var_os("SteamGameId").is_none() {
            std::env::set_var("SteamGameId", STEAM_APP_ID.to_string());
        }
        let dll = if dll.is_dir() { dll.join("steam_api64.dll") } else { dll.to_path_buf() };
        // SAFETY: steam_api64.dll is Valve's library shipped with the game; every symbol is looked up by its flat-API
        // name with the signature from steam_api_flat.h, and pointers it returns are only passed back to it.
        unsafe {
            let lib = libloading::Library::new(&dll).map_err(|e| format!("{}: {e}", dll.display()))?;
            macro_rules! f {
                ($name:literal) => {
                    *lib.get(concat!($name, "\0").as_bytes()).map_err(|e| format!("{}: {e}", $name))?
                };
            }
            let init: unsafe extern "C" fn(*mut u8) -> i32 = f!("SteamAPI_InitFlat");
            let mut err = vec![0u8; 1024];
            let r = init(err.as_mut_ptr());
            if r != 0 {
                let msg = String::from_utf8_lossy(&err[..err.iter().position(|b| *b == 0).unwrap_or(0)]).into_owned();
                return Err(format!("SteamAPI init failed ({r}): {msg}"));
            }
            let steam_user: unsafe extern "C" fn() -> P = f!("SteamAPI_SteamUser_v023");
            let utils: unsafe extern "C" fn() -> P = f!("SteamAPI_SteamNetworkingUtils_SteamAPI_v004");
            let relay_access: unsafe extern "C" fn(P) = f!("SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess");
            let messages: unsafe extern "C" fn() -> P = f!("SteamAPI_SteamNetworkingMessages_SteamAPI_v002");
            let friends: unsafe extern "C" fn() -> P = f!("SteamAPI_SteamFriends_v018");
            let api = SteamApi {
                user_get_steam_id: f!("SteamAPI_ISteamUser_GetSteamID"),
                identity_set_steam_id: f!("SteamAPI_SteamNetworkingIdentity_SetSteamID64"),
                send_message: f!("SteamAPI_ISteamNetworkingMessages_SendMessageToUser"),
                accept_session: f!("SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser"),
                receive_messages: f!("SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel"),
                release_message: f!("SteamAPI_SteamNetworkingMessage_t_Release"),
                run_callbacks: f!("SteamAPI_RunCallbacks"),
                set_rich_presence: f!("SteamAPI_ISteamFriends_SetRichPresence"),
                friend_count: f!("SteamAPI_ISteamFriends_GetFriendCount"),
                friend_by_index: f!("SteamAPI_ISteamFriends_GetFriendByIndex"),
                friend_rich_presence: f!("SteamAPI_ISteamFriends_GetFriendRichPresence"),
                _lib: lib,
            };
            let my_id = (api.user_get_steam_id)(steam_user());
            relay_access(utils());
            let mut s = Steam {
                msgs: messages(),
                friends: friends(),
                my_id,
                role_host: host,
                identity: vec![0; IDENTITY_BYTES],
                partner: None,
                last_find: None,
                last_result: 0,
                api,
            };
            // Advertise our role; friends playing PBZ see it, which is how PartnerSteamID = Auto finds the partner.
            let role: &[u8] = if host { b"host\0" } else { b"client\0" };
            (s.api.set_rich_presence)(s.friends, PRESENCE_KEY.as_ptr(), role.as_ptr());
            if !partner.eq_ignore_ascii_case("auto") {
                s.set_partner(partner.parse().map_err(|_| format!("not a SteamID64: {partner}"))?);
            }
            Ok(s)
        }
    }

    fn set_partner(&mut self, id: u64) {
        self.partner = Some(id);
        // SAFETY: identity is a SteamNetworkingIdentity-sized buffer owned by self.
        unsafe {
            (self.api.identity_set_steam_id)(self.identity.as_mut_ptr().cast(), id);
            // Sending accepts their session too; accept explicitly as well in case they spoke first.
            (self.api.accept_session)(self.msgs, self.identity.as_mut_ptr().cast());
        }
    }

    /// The first Steam friend whose Phantom Pact relay advertises the other role.
    fn find_partner(&mut self) {
        let want: &[u8] = if self.role_host { b"client" } else { b"host" };
        // SAFETY: flat Steam API calls with the interface pointer Steam gave us; the returned C string is
        // owned by Steam and copied before the next call.
        unsafe {
            let n = (self.api.friend_count)(self.friends, FRIEND_FLAG_IMMEDIATE);
            for i in 0..n.max(0) {
                let id = (self.api.friend_by_index)(self.friends, i, FRIEND_FLAG_IMMEDIATE);
                let v = (self.api.friend_rich_presence)(self.friends, id, PRESENCE_KEY.as_ptr());
                if !v.is_null() && std::ffi::CStr::from_ptr(v).to_bytes() == want {
                    self.set_partner(id);
                    return;
                }
            }
        }
    }
}

impl Transport for Steam {
    fn name(&self) -> &'static str {
        "steam"
    }
    fn peer(&self) -> Option<Peer> {
        self.partner.map(Peer::Steam)
    }
    fn send(&mut self, data: &[u8], _peer: &Peer) {
        if self.partner.is_none() {
            return; // PartnerSteamID = Auto, partner not found yet
        }
        // SAFETY: data outlives the call (Steam copies it); identity was set by set_partner.
        self.last_result = unsafe {
            (self.api.send_message)(self.msgs, self.identity.as_mut_ptr().cast(), data.as_ptr(), data.len() as u32,
                SEND_FLAGS, STEAM_CHANNEL)
        };
    }
    fn receive(&mut self, wait: Duration) -> Vec<(Vec<u8>, Peer)> {
        // Steam delivers messages to a queue we poll; there is no socket to wait on.
        sleep(wait.min(WATCH));
        // SAFETY: see Steam::new.
        unsafe { (self.api.run_callbacks)() };
        if self.partner.is_none() && self.last_find.map_or(true, |t| t.elapsed() >= FIND_EVERY) {
            self.last_find = Some(Instant::now());
            self.find_partner();
        }
        let mut out = vec![];
        let mut ptrs: [P; 64] = [std::ptr::null_mut(); 64];
        // SAFETY: Steam fills up to 64 message pointers; each is read per SteamNetworkingMessage_t's layout
        // (void *m_pData; int m_cbSize; HSteamNetConnection m_conn; SteamNetworkingIdentity m_identityPeer
        // { int m_eType; int m_cbSize; uint64 m_steamID64 }) and released once copied.
        unsafe {
            let n = (self.api.receive_messages)(self.msgs, STEAM_CHANNEL, ptrs.as_mut_ptr(), 64);
            for &m in &ptrs[..n.clamp(0, 64) as usize] {
                let b = m as *const u8;
                let data = *(b as *const *const u8);
                let size = *(b.add(8) as *const i32);
                let kind = *(b.add(16) as *const i32);
                let sender = if kind == IDENTITY_STEAMID { *(b.add(24) as *const u64) } else { 0 };
                let bytes = if !data.is_null() && size > 0 { std::slice::from_raw_parts(data, size as usize).to_vec() } else { vec![] };
                (self.api.release_message)(m);
                out.push((bytes, Peer::Steam(sender)));
            }
        }
        out
    }
    fn status(&self) -> String {
        let partner = self.partner.map(|p| p.to_string()).unwrap_or_else(|| "searching".into());
        format!("transport=steam me={} partner={partner}", self.my_id)
    }
    // No SteamAPI_Shutdown: Steam releases the session when the process ends (shutting down while its networking
    // thread flushes can end the process with an error).
}
