//! The text files the mod and the relay share (see net/pbzcoop_net.py): read tolerantly, written atomically, and
//! events appended to the inbox exactly once each, in order.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::Duration;

/// The whole file as text; a stray non-UTF-8 byte is replaced, a missing file is empty.
pub fn read_text(path: &Path) -> String {
    // Lua writes text files with CRLF on Windows; the Python relay reads them in text mode (LF), so do the same, or
    // a "\r" travels on the wire to a Python partner.
    fs::read(path).map(|b| String::from_utf8_lossy(&b).replace("\r\n", "\n")).unwrap_or_default()
}

/// read_text, minus a last line the mod is still writing (no newline yet): it is sent once it's complete.
pub fn read_complete_lines(path: &Path) -> String {
    let mut text = read_text(path);
    text.truncate(text.rfind('\n').map(|i| i + 1).unwrap_or(0));
    text
}

/// The mod may have the file open for a moment, and Windows can briefly refuse a rename: retry, then skip.
pub fn write_atomic(path: &Path, text: &str) -> bool {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    for attempt in 1..=5 {
        if fs::write(&tmp, text).is_ok() && fs::rename(&tmp, path).is_ok() {
            return true;
        }
        sleep(Duration::from_millis(2 * attempt));
    }
    false
}

/// Returns false if the lines couldn't be appended (the caller keeps them and retries next time).
pub fn append_lines(path: &Path, lines: &[String]) -> bool {
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    for attempt in 1..=5 {
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
            if f.write_all(text.as_bytes()).is_ok() {
                return true;
            }
        }
        sleep(Duration::from_millis(2 * attempt));
    }
    false
}

/// (session, [(id, line)]) from an events file: "S <session>" then "<id> <type> <args>" lines.
pub fn parse_events(text: &str) -> (Option<String>, Vec<(u64, String)>) {
    let mut session = None;
    let mut events = vec![];
    for line in text.lines() {
        let (first, rest) = match line.split_once(' ') {
            Some((f, r)) => (f, Some(r)),
            None => (line, None),
        };
        if first.is_empty() {
            continue;
        }
        if first == "S" {
            if let Some(r) = rest {
                session = Some(r.trim().to_string());
            }
        } else if first.bytes().all(|b| b.is_ascii_digit()) {
            if let Ok(id) = first.parse() {
                events.push((id, line.to_string()));
            }
        }
    }
    (session, events)
}

/// Writes the peer's events to net_events_in.txt exactly once each, in order.
pub struct EventInbox {
    path: PathBuf,
    session: Option<String>,
    pub last_id: u64,
}

impl EventInbox {
    pub fn new(path: PathBuf) -> EventInbox {
        EventInbox { path, session: None, last_id: 0 }
    }

    /// The highest event id written, to acknowledge.
    pub fn accept(&mut self, session: &str, mut events: Vec<(u64, String)>) -> u64 {
        if self.session.as_deref() != Some(session) {
            // The peer restarted its mod: start a fresh file so old events aren't replayed.
            if !write_atomic(&self.path, &format!("S {session}\n")) {
                return 0;
            }
            self.session = Some(session.to_string());
            self.last_id = 0;
        }
        events.sort();
        let mut last = self.last_id;
        let mut fresh = vec![];
        for (id, line) in events {
            if id == last + 1 {
                fresh.push(line);
                last = id;
            }
        }
        // Only acknowledged once written: if the write fails the peer keeps resending them.
        if !fresh.is_empty() && append_lines(&self.path, &fresh) {
            self.last_id = last;
        }
        self.last_id
    }
}

/// PhantomPact.ini next to the mod folder (extra test instances run in <mod>/inst<n>/, the ini is above).
pub fn ini_path(folder: &Path) -> PathBuf {
    let ini = folder.join("PhantomPact.ini");
    if ini.exists() {
        return ini;
    }
    folder.parent().map(|p| p.join("PhantomPact.ini")).unwrap_or(ini)
}

/// PhantomPact.ini as (lowercase key, value) pairs; ";" lines and trailing "; ..." comments are dropped.
pub fn read_ini(folder: &Path) -> Vec<(String, String)> {
    read_text(&ini_path(folder))
        .lines()
        .filter(|l| !l.trim_start().starts_with(';'))
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.trim().to_lowercase(), v.split(';').next().unwrap_or("").trim().to_string()))
        .collect()
}

/// "Secret = ..." from the ini (or a file), empty = off; the shipped placeholder (PUT-...) counts as off.
pub fn read_secret(folder: &Path, file: Option<&Path>) -> String {
    if let Some(f) = file {
        return read_text(f).trim().to_string();
    }
    for line in read_text(&ini_path(folder)).lines() {
        if let Some((k, v)) = line.split_once('=') {
            let v = v.split(';').next().unwrap_or("").trim();
            if k.trim().eq_ignore_ascii_case("secret") && !v.is_empty() && !v.to_uppercase().starts_with("PUT-") {
                return v.to_string();
            }
        }
    }
    String::new()
}

/// VERSION from Scripts/main.lua next to the relay (or the mod folder above an instance folder).
pub fn mod_version(folder: &Path) -> String {
    let bases = [Some(folder), folder.parent()];
    for base in bases.into_iter().flatten() {
        for rel in ["Scripts/main.lua", "mod/PBZCoop/Scripts/main.lua"] {
            let text = read_text(&base.join(rel));
            if let Some(rest) = text.split_once("local VERSION = \"").map(|(_, r)| r) {
                return rest.split('"').next().unwrap_or("?").to_string();
            }
        }
    }
    "?".into()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join("pbzcoop_relay_tests").join(name);
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn events_parse_and_inbox_writes_each_once_in_order() {
        let (s, ev) = parse_events("S 111\n2 K Mob_1\n1 A attack1\ngarbage\n\n3\n");
        assert_eq!(s.as_deref(), Some("111"));
        assert_eq!(ev.iter().map(|e| e.0).collect::<Vec<_>>(), [2, 1, 3]);
        let d = dir("inbox");
        let mut inbox = EventInbox::new(d.join("in.txt"));
        assert_eq!(inbox.accept("111", ev.clone()), 3);
        assert_eq!(inbox.accept("111", ev), 3, "resent events are not written again");
        assert_eq!(read_text(&d.join("in.txt")), "S 111\n1 A attack1\n2 K Mob_1\n3\n");
        assert_eq!(inbox.accept("222", vec![(2, "2 X".into())]), 0, "new session starts over; gaps wait");
        assert_eq!(read_text(&d.join("in.txt")), "S 222\n");
    }

    #[test]
    fn partial_last_line_is_held_back_and_bad_utf8_tolerated() {
        let d = dir("partial");
        fs::write(d.join("e.txt"), b"S 1\n1 A x\n2 B y\xff").unwrap();
        assert_eq!(read_complete_lines(&d.join("e.txt")), "S 1\n1 A x\n");
        assert!(read_text(&d.join("e.txt")).ends_with("y\u{fffd}"));
        assert_eq!(read_text(&d.join("missing.txt")), "");
    }

    #[test]
    fn ini_secret_and_version() {
        let d = dir("ini");
        fs::create_dir_all(d.join("inst2")).unwrap();
        fs::write(d.join("PhantomPact.ini"), "; Secret = no\nSecret = hunter2 ; comment\nPvP = On\n").unwrap();
        assert_eq!(read_secret(&d, None), "hunter2");
        assert_eq!(read_secret(&d.join("inst2"), None), "hunter2", "instances use the mod's ini");
        assert!(read_ini(&d).contains(&("pvp".into(), "On".into())));
        fs::write(d.join("PhantomPact.ini"), "Secret = PUT-A-SHARED-SECRET-HERE\n").unwrap();
        assert_eq!(read_secret(&d, None), "");
        fs::create_dir_all(d.join("Scripts")).unwrap();
        fs::write(d.join("Scripts/main.lua"), "local VERSION = \"9.8.7\"\n").unwrap();
        assert_eq!(mod_version(&d.join("inst2")), "9.8.7");
    }
}
