//! The relay loop (pbzcoop_net.py `Relay`): newest-wins snapshots resent every tick, reliable numbered events with
//! acks, ping/pong round-trip time, the hello settings exchange, and the status line the mod reads.

use crate::auth::{Auth, Msg};
use crate::files::{self, EventInbox};
use crate::transport::{Peer, Transport};
use serde_json::{json, Value};
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const PORT: u16 = 47800;
pub const TICK: Duration = Duration::from_millis(50);
const WATCH: Duration = Duration::from_millis(5);
const PING_EVERY: f64 = 1.0;
const PEER_TIMEOUT: f64 = 3.0;
const PROTOCOL: u64 = 2;
const MAX_EVENTS_PER_PACKET: usize = 40;
const MAX_SNAPSHOT_BYTES: usize = 48000;

/// Settings both players must agree on; compared in the hello exchange and reported as mismatch=.
pub const SHARED_SETTINGS: [&str; 7] =
    ["network", "coopenemyhealth", "coopenemyposture", "shareprogress", "pvp", "pvpdamage", "pvpparryposture"];

/// Who may talk to this relay: Tailscale (100.64.0.0/10) and this PC, or anyone.
#[derive(Clone, Copy, PartialEq)]
pub enum Allow {
    Tailscale,
    Any,
}

pub fn address_allowed(peer: &Peer, allow: Allow) -> bool {
    match (allow, peer) {
        (Allow::Any, _) => true,
        (Allow::Tailscale, Peer::Udp(a)) => match a.ip() {
            IpAddr::V4(ip) => {
                let o = ip.octets();
                (o[0] == 100 && (o[1] & 0xC0) == 64) || o[0] == 127
            }
            IpAddr::V6(_) => false,
        },
        (Allow::Tailscale, Peer::Steam(_)) => true,
    }
}

fn text(v: Option<&Value>) -> String {
    match v {
        Some(Value::String(s)) => s.clone(),
        None | Some(Value::Null) => String::new(),
        Some(other) => other.to_string(),
    }
}

/// Differences between two hello payloads as "key=mine/theirs".
pub fn compare_settings(mine: &Msg, theirs: &Msg) -> Vec<String> {
    let mut diffs = vec![];
    if mine.get("ver") != theirs.get("ver") {
        let show = |v: Option<&Value>| if v.is_none() || v == Some(&Value::Null) { "None".into() } else { text(v) };
        diffs.push(format!("version={}/{}", show(mine.get("ver")), show(theirs.get("ver"))));
    }
    let empty = serde_json::Map::new();
    let a = mine.get("cfg").and_then(Value::as_object).unwrap_or(&empty);
    let b = theirs.get("cfg").and_then(Value::as_object).unwrap_or(&empty);
    for key in SHARED_SETTINGS {
        let (x, y) = (text(a.get(key)), text(b.get(key)));
        if x.to_lowercase() != y.to_lowercase() {
            let dash = |s: String| if s.is_empty() { "-".to_string() } else { s };
            diffs.push(format!("{key}={}/{}", dash(x), dash(y)));
        }
    }
    diffs
}

pub struct Relay {
    pub role: String,
    pub auth: Auth,
    allow: Allow,
    pub filtered: u64,
    out_path: PathBuf,
    in_path: PathBuf,
    events_out_path: PathBuf,
    pub status_path: PathBuf,
    inbox: EventInbox,
    pub transport: Box<dyn Transport>,
    peer: Option<Peer>,
    pub extra_status: String,
    start: Instant,
    last_heard: f64,
    last_out_sig: Option<[Option<(SystemTime, u64)>; 2]>,
    last_sent_at: f64,
    rtt_ms: Option<f64>,
    last_ping: f64,
    received: u64,
    sent: u64,
    acked: std::collections::HashMap<String, u64>,
    events_acked: u64,
    in_blanked: bool,
    hello: Msg,
    partner_version: Option<String>,
    mismatch: Vec<String>,
}

impl Relay {
    pub fn new(role: &str, folder: &Path, secret: &str, allow: Allow, transport: Box<dyn Transport>) -> Relay {
        let ini = files::read_ini(folder);
        let cfg: serde_json::Map<String, Value> = SHARED_SETTINGS
            .iter()
            .map(|k| (k.to_string(), Value::from(ini.iter().rev().find(|(key, _)| key == k).map(|(_, v)| v.clone()).unwrap_or_default())))
            .collect();
        let hello = json!({"t": "hello", "ver": files::mod_version(folder), "cfg": cfg});
        Relay {
            role: role.into(),
            // AES-GCM where the Python relay uses it (Windows, through CNG); HMAC elsewhere, so both always agree.
            auth: Auth::new(secret, cfg!(windows)),
            allow,
            filtered: 0,
            out_path: folder.join("net_out.txt"),
            in_path: folder.join("net_in.txt"),
            events_out_path: folder.join("net_events_out.txt"),
            status_path: folder.join("net_status.txt"),
            inbox: EventInbox::new(folder.join("net_events_in.txt")),
            peer: transport.peer(),
            transport,
            extra_status: String::new(),
            start: Instant::now(),
            last_heard: 0.0,
            last_out_sig: None,
            last_sent_at: f64::NEG_INFINITY,
            rtt_ms: None,
            last_ping: f64::NEG_INFINITY,
            received: 0,
            sent: 0,
            acked: Default::default(),
            events_acked: 0,
            in_blanked: false,
            hello: hello.as_object().unwrap().clone(),
            partner_version: None,
            mismatch: vec![],
        }
    }

    /// Seconds since the relay started (the clock for ping timestamps, which only this side reads back).
    pub fn now(&self) -> f64 {
        self.start.elapsed().as_secs_f64() + 1.0
    }

    fn send(&mut self, mut msg: Msg) {
        if self.transport.name() == "steam" {
            self.peer = self.transport.peer(); // may have just been found (PartnerSteamID = Auto)
        }
        let Some(peer) = self.peer.clone() else { return };
        msg.insert("v".into(), Value::from(PROTOCOL));
        let data = self.auth.seal(msg);
        self.transport.send(&data, &peer);
        self.sent += 1;
    }

    fn handle(&mut self, data: &[u8], from: Peer, now: f64) {
        // The client only listens to the host it was given; the host only to allowed networks. Over Steam the
        // sender is the authenticated SteamID and only the configured partner is accepted.
        if self.transport.name() == "steam" {
            self.peer = self.transport.peer();
            if self.peer.as_ref() != Some(&from) {
                self.filtered += 1;
                return;
            }
        } else if (self.role != "host" && self.peer.as_ref() != Some(&from)) || !address_allowed(&from, self.allow) {
            self.filtered += 1;
            return;
        }
        let Some(msg) = self.auth.open(data) else { return };
        if msg.get("v").and_then(Value::as_u64) != Some(PROTOCOL) {
            return;
        }
        if self.role == "host" && self.peer.as_ref() != Some(&from) {
            // Pinned to the first peer: another sender is only taken once the current one went silent.
            if self.peer.is_some() && now - self.last_heard <= PEER_TIMEOUT {
                return;
            }
            println!("peer connected from {from}");
            self.peer = Some(from);
        }
        self.last_heard = now;
        self.received += 1;
        match msg.get("t").and_then(Value::as_str) {
            Some("hello") if msg.get("cfg").map_or(false, Value::is_object) => {
                self.partner_version = Some(text(msg.get("ver")));
                self.mismatch = compare_settings(&self.hello, &msg);
            }
            Some("ping") => {
                let ts = msg.get("ts").cloned().unwrap_or(Value::Null);
                self.send(json!({"t": "pong", "ts": ts}).as_object().unwrap().clone());
            }
            Some("pong") => {
                if let Some(ts) = msg.get("ts").and_then(Value::as_f64) {
                    self.rtt_ms = Some((now - ts) * 1000.0);
                }
            }
            Some("state") => {
                if let Some(s) = msg.get("s").and_then(Value::as_str) {
                    files::write_atomic(&self.in_path, s);
                    self.in_blanked = false;
                }
                if let Some(ev) = msg.get("e").and_then(Value::as_object) {
                    if let (Some(sid), Some(lines)) = (ev.get("sid").and_then(Value::as_str), ev.get("l").and_then(Value::as_array)) {
                        let joined: Vec<&str> = lines.iter().filter_map(Value::as_str).collect();
                        let (_, events) = files::parse_events(&joined.join("\n"));
                        let last = self.inbox.accept(sid, events);
                        self.send(json!({"t": "ack", "sid": sid, "id": last}).as_object().unwrap().clone());
                    }
                }
            }
            Some("ack") => {
                if let (Some(sid), Some(id)) = (msg.get("sid").and_then(Value::as_str), msg.get("id").and_then(Value::as_u64)) {
                    // Taken as is, even when lower: a restarted peer relay starts its inbox over and acks 0.
                    self.acked.insert(sid.to_string(), id);
                }
            }
            _ => {}
        }
    }

    fn receive_all(&mut self, wait: Duration) {
        for (data, from) in self.transport.receive(wait) {
            let now = self.now();
            self.handle(&data, from, now);
        }
    }

    fn out_signature(&self) -> [Option<(SystemTime, u64)>; 2] {
        let sig = |p: &Path| std::fs::metadata(p).ok().and_then(|m| Some((m.modified().ok()?, m.len())));
        [sig(&self.out_path), sig(&self.events_out_path)]
    }

    /// Sleeps until the next tick, but handles packets the moment they arrive and sends what the mod wrote the
    /// moment it appears.
    pub fn wait(&mut self, seconds: Duration) {
        let deadline = Instant::now() + seconds;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            self.receive_all(left.min(WATCH));
            if Some(self.out_signature()) != self.last_out_sig {
                let now = self.now();
                self.send_state(now);
            }
        }
    }

    pub fn tick(&mut self) {
        self.receive_all(Duration::ZERO);
        let now = self.now();
        if self.peer.is_some() && self.last_heard > 0.0 && now - self.last_heard > PEER_TIMEOUT && !self.in_blanked {
            // The peer is gone: don't leave its last snapshot for the mod to keep applying.
            files::write_atomic(&self.in_path, "");
            self.in_blanked = true;
        }
        if now - self.last_ping >= PING_EVERY {
            self.send(json!({"t": "ping", "ts": now}).as_object().unwrap().clone());
            self.send(self.hello.clone());
            self.last_ping = now;
        }
        if now - self.last_sent_at >= TICK.as_secs_f64() * 0.9 {
            self.send_state(now);
        }
    }

    fn send_state(&mut self, now: f64) {
        self.last_out_sig = Some(self.out_signature());
        self.last_sent_at = now;
        let mut msg = json!({"t": "state"}).as_object().unwrap().clone();
        let snapshot = files::read_text(&self.out_path);
        if !snapshot.trim().is_empty() {
            // Resend the newest snapshot every tick even if unchanged, so a dropped packet heals itself.
            let cut = (0..=snapshot.len().min(MAX_SNAPSHOT_BYTES)).rev().find(|i| snapshot.is_char_boundary(*i)).unwrap_or(0);
            msg.insert("s".into(), Value::from(&snapshot[..cut]));
        }
        let (session, events) = files::parse_events(&files::read_complete_lines(&self.events_out_path));
        if let Some(session) = session {
            let acked = self.acked.get(&session).copied().unwrap_or(0);
            let pending: Vec<Value> = events.into_iter().filter(|(id, _)| *id > acked).take(MAX_EVENTS_PER_PACKET).map(|(_, l)| Value::from(l)).collect();
            // Always include the session (even with nothing pending) so the peer's inbox follows restarts.
            msg.insert("e".into(), json!({"sid": session, "l": pending}));
            self.events_acked = acked;
        }
        if msg.len() > 1 {
            self.send(msg);
        }
    }

    pub fn status(&self) -> String {
        let now = self.now();
        let connected = self.peer.is_some() && now - self.last_heard <= PEER_TIMEOUT;
        let peer = self.peer.as_ref().map(|p| p.to_string()).unwrap_or_else(|| "-".into());
        let rtt = self.rtt_ms.map(|r| format!("{r:.0}")).unwrap_or_else(|| "-".into());
        let extra = [self.extra_status.clone(), self.transport.status()].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ");
        let time = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        format!(
            "role={} connected={} peer={peer} rtt_ms={rtt} sent={} received={} version={} partner_version={} \
             mismatch={} events_acked={} events_in={} auth={} rejected={} filtered={} {}time={time} relay=native",
            self.role,
            if connected { "yes" } else { "no" },
            self.sent,
            self.received,
            text(self.hello.get("ver")),
            self.partner_version.as_deref().unwrap_or("-"),
            if self.mismatch.is_empty() { "-".into() } else { self.mismatch.join(",") },
            self.events_acked,
            self.inbox.last_id,
            self.auth.mode(),
            self.auth.rejected,
            self.filtered,
            if extra.is_empty() { String::new() } else { format!("{extra} ") },
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_filter() {
        let p = |s: &str| Peer::Udp(s.parse().unwrap());
        assert!(address_allowed(&p("100.112.4.45:1"), Allow::Tailscale));
        assert!(address_allowed(&p("127.0.0.1:1"), Allow::Tailscale));
        assert!(!address_allowed(&p("100.128.0.1:1"), Allow::Tailscale));
        assert!(!address_allowed(&p("192.168.1.5:1"), Allow::Tailscale));
        assert!(address_allowed(&p("192.168.1.5:1"), Allow::Any));
    }

    #[test]
    fn settings_compare_like_the_python_relay() {
        let m = |v: Value| v.as_object().unwrap().clone();
        let a = m(json!({"ver": "1.3.0", "cfg": {"pvp": "On", "coopenemyhealth": "150"}}));
        let b = m(json!({"ver": "1.3.0", "cfg": {"pvp": "on", "coopenemyhealth": "100"}}));
        assert_eq!(compare_settings(&a, &b), ["coopenemyhealth=150/100"]);
        let c = m(json!({"ver": "1.2.0", "cfg": {"pvp": "on", "coopenemyhealth": "150", "network": "Steam"}}));
        assert_eq!(compare_settings(&a, &c), ["version=1.3.0/1.2.0", "network=-/Steam"]);
    }
}
