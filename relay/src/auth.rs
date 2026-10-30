//! Optional packet protection with a secret both players share (pbzcoop_net.py `Auth`, byte for byte).
//!
//! On Windows every packet is encrypted and authenticated with AES-256-GCM: `b"E"` + 12-byte nonce (6-byte random
//! sender session + 6-byte counter) + ciphertext + 16-byte tag, AAD `PhantomPact/2`, key SHA-256(secret).
//! Elsewhere it is signed: JSON with "a" (session) and "n" (counter), `\n`, then HMAC-SHA256 truncated to 16 bytes
//! as hex. Either way packets with a bad tag or a counter not above the last one seen for that session are dropped.
//! Without a secret packets are plain JSON.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use hmac::{Hmac, Mac};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;

pub const AAD: &[u8] = b"PhantomPact/2";
const TAG: usize = 16;
const MAC_BYTES: usize = 16;
const REPLAY_SESSIONS: usize = 8;

pub type Msg = Map<String, Value>;

pub struct Auth {
    key: Option<[u8; 32]>,
    aead: Option<Aes256Gcm>,
    sid: String,
    sid_bytes: [u8; 6],
    counter: u64,
    seen: VecDeque<(String, u64)>, // peer session -> highest counter accepted, oldest first
    pub rejected: u64,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hmac_hex(key: &[u8; 32], body: &[u8]) -> String {
    let mut m = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("any key length");
    m.update(body);
    hex(&m.finalize().into_bytes()[..MAC_BYTES])
}

fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

impl Auth {
    /// `encrypt`: AES-GCM when a secret is set (as the Python relay on Windows); otherwise HMAC.
    pub fn new(secret: &str, encrypt: bool) -> Auth {
        let key: Option<[u8; 32]> = (!secret.is_empty()).then(|| Sha256::digest(secret.as_bytes()).into());
        let aead = key.filter(|_| encrypt).map(|k| Aes256Gcm::new(&k.into()));
        let mut r = [0u8; 14];
        getrandom::getrandom(&mut r).expect("OS random numbers");
        let mut sid_bytes = [0u8; 6];
        sid_bytes.copy_from_slice(&r[8..]);
        Auth { key, aead, sid: hex(&r[..8]), sid_bytes, counter: 0, seen: VecDeque::new(), rejected: 0 }
    }

    pub fn mode(&self) -> &'static str {
        if self.aead.is_some() {
            "aes-gcm"
        } else if self.key.is_some() {
            "hmac"
        } else {
            "off"
        }
    }

    pub fn seal(&mut self, mut msg: Msg) -> Vec<u8> {
        let Some(key) = self.key else {
            return serde_json::to_vec(&msg).expect("json");
        };
        self.counter += 1;
        if let Some(aead) = &self.aead {
            let mut nonce = [0u8; 12];
            nonce[..6].copy_from_slice(&self.sid_bytes);
            nonce[6..].copy_from_slice(&self.counter.to_be_bytes()[2..]);
            let body = serde_json::to_vec(&msg).expect("json");
            let sealed = aead.encrypt(Nonce::from_slice(&nonce), Payload { msg: &body, aad: AAD }).expect("aes-gcm");
            let mut out = Vec::with_capacity(13 + sealed.len());
            out.push(b'E');
            out.extend_from_slice(&nonce);
            out.extend_from_slice(&sealed);
            return out;
        }
        msg.insert("a".into(), Value::from(self.sid.clone()));
        msg.insert("n".into(), Value::from(self.counter));
        let mut body = serde_json::to_vec(&msg).expect("json");
        let mac = hmac_hex(&key, &body);
        body.push(b'\n');
        body.extend_from_slice(mac.as_bytes());
        body
    }

    /// Replay check: the counter must grow within each sender session.
    fn fresh(&mut self, sid: String, n: u64) -> bool {
        let pos = self.seen.iter().position(|(s, _)| *s == sid);
        if n <= pos.map(|i| self.seen[i].1).unwrap_or(0) {
            return false;
        }
        if let Some(i) = pos {
            self.seen.remove(i);
        }
        self.seen.push_back((sid, n));
        while self.seen.len() > REPLAY_SESSIONS {
            self.seen.pop_front();
        }
        true
    }

    fn reject(&mut self) -> Option<Msg> {
        self.rejected += 1;
        None
    }

    /// The message, or None if the packet must be dropped.
    pub fn open(&mut self, data: &[u8]) -> Option<Msg> {
        let body: Vec<u8> = if let Some(aead) = &self.aead {
            // Encrypted only: a plain or HMAC packet is refused, so nobody can downgrade the session.
            if data.first() != Some(&b'E') || data.len() < 13 + TAG {
                return self.reject();
            }
            let nonce = &data[1..13];
            let Ok(plain) = aead.decrypt(Nonce::from_slice(nonce), Payload { msg: &data[13..], aad: AAD }) else {
                return self.reject();
            };
            let mut n = [0u8; 8];
            n[2..].copy_from_slice(&nonce[6..]);
            if !self.fresh(hex(&nonce[..6]), u64::from_be_bytes(n)) {
                return self.reject();
            }
            plain
        } else if let Some(key) = self.key {
            let Some(cut) = data.iter().rposition(|b| *b == b'\n') else {
                return self.reject();
            };
            let (body, mac) = (&data[..cut], &data[cut + 1..]);
            if !same(mac, hmac_hex(&key, body).as_bytes()) {
                return self.reject();
            }
            body.to_vec()
        } else {
            data.to_vec()
        };
        let Ok(Value::Object(msg)) = serde_json::from_slice::<Value>(&body) else {
            return self.reject();
        };
        if self.key.is_some() && self.aead.is_none() {
            let (Some(sid), Some(n)) = (msg.get("a").and_then(Value::as_str), msg.get("n").and_then(Value::as_u64)) else {
                return self.reject();
            };
            if !self.fresh(sid.to_string(), n) {
                return self.reject();
            }
        }
        Some(msg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn msg(v: Value) -> Msg {
        v.as_object().unwrap().clone()
    }

    #[test]
    fn aes_gcm_round_trip_tamper_replay_and_downgrade() {
        let (mut a, mut b) = (Auth::new("s3cret", true), Auth::new("s3cret", true));
        assert_eq!(a.mode(), "aes-gcm");
        let p = a.seal(msg(json!({"t": "ping", "ts": 1.5})));
        assert_eq!(p[0], b'E');
        assert!(!p.windows(4).any(|w| w == b"ping"), "encrypted");
        assert_eq!(b.open(&p).unwrap()["t"], "ping");
        assert!(b.open(&p).is_none(), "replay dropped");
        let mut t = a.seal(msg(json!({"t": "x"})));
        let last = t.len() - 1;
        t[last] ^= 1;
        assert!(b.open(&t).is_none(), "tampered tag dropped");
        assert!(b.open(br#"{"t":"state","v":2}"#).is_none(), "plain packet refused");
        let mut h = Auth::new("s3cret", false);
        assert!(b.open(&h.seal(msg(json!({"t": "x"})))).is_none(), "HMAC packet refused: no downgrade");
        assert!(Auth::new("other", true).open(&a.seal(msg(json!({"t": "x"})))).is_none(), "wrong secret");
        assert_eq!(b.rejected, 4, "replay, tamper, plain, downgrade");
    }

    #[test]
    fn hmac_round_trip_tamper_and_replay() {
        let (mut a, mut b) = (Auth::new("s3cret", false), Auth::new("s3cret", false));
        assert_eq!(a.mode(), "hmac");
        let p = a.seal(msg(json!({"t": "pong"})));
        let m = b.open(&p).unwrap();
        assert_eq!(m["t"], "pong");
        assert_eq!(m["n"], 1);
        assert!(b.open(&p).is_none(), "replay dropped");
        let mut t = a.seal(msg(json!({"t": "pong"})));
        t[2] ^= 1;
        assert!(b.open(&t).is_none(), "tampered body dropped");
    }

    #[test]
    fn replay_window_keeps_the_newest_sessions() {
        let mut a = Auth::new("k", false);
        for i in 0..20 {
            assert!(a.fresh(format!("s{i}"), 1));
        }
        assert_eq!(a.seen.len(), REPLAY_SESSIONS);
        assert!(!a.fresh("s19".into(), 1));
        assert!(a.fresh("s19".into(), 2));
    }

    #[test]
    fn plain_without_secret() {
        let (mut a, mut b) = (Auth::new("", true), Auth::new("", true));
        assert_eq!(a.mode(), "off");
        let p = a.seal(msg(json!({"t": "hello", "v": 2})));
        assert_eq!(b.open(&p).unwrap()["v"], 2);
        assert!(b.open(b"not json").is_none());
        assert!(b.open(b"[1,2]").is_none(), "only objects");
    }
}
