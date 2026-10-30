//! Phantom Pact network relay, native build: a drop-in for net/pbzcoop_net.py (same command line, same files in
//! the mod folder, same wire protocol, so a native relay and a Python relay play together). No Python needed.
//!
//!   host:   pbzcoop_relay host   --dir <mod folder>
//!   client: pbzcoop_relay client --dir <mod folder> --peer 100.112.4.45
//!   echo:   pbzcoop_relay echo   --dir <mod folder>   (solo test: your own snapshot and events played back)
//!   options: --port N  --allow tailscale|any  --secret-file F  --insecure  --upnp  --transport udp|steam
//!            --partner <SteamID64|auto>  --steam-dll <path>  --alive-file F  --alive-timeout S  --seconds S
//!
//! It runs out of the game process: whatever happens on the network, it can't crash the game.

// No console window when the mod starts it; output still goes to a pipe or file if one is given.
#![windows_subsystem = "windows"]

mod auth;
mod files;
mod relay;
mod transport;
mod upnp;

use relay::{Allow, Relay, PORT, TICK};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const ALIVE_TIMEOUT: f64 = 30.0;

struct Args {
    role: String,
    opts: HashMap<String, String>,
    flags: Vec<String>,
}

impl Args {
    fn get(&self, k: &str) -> Option<&str> {
        self.opts.get(k).map(String::as_str)
    }
    fn flag(&self, k: &str) -> bool {
        self.flags.iter().any(|f| f == k)
    }
}

fn parse() -> Result<Args, String> {
    let mut it = std::env::args().skip(1);
    let mut a = Args { role: String::new(), opts: HashMap::new(), flags: vec![] };
    while let Some(x) = it.next() {
        match x.as_str() {
            "--insecure" | "--upnp" => a.flags.push(x),
            k if k.starts_with("--") => {
                let v = it.next().ok_or_else(|| format!("{k} needs a value"))?;
                a.opts.insert(k.to_string(), v);
            }
            r if a.role.is_empty() => a.role = r.to_string(),
            other => return Err(format!("unexpected argument {other}")),
        }
    }
    if !["host", "client", "echo"].contains(&a.role.as_str()) {
        return Err("usage: pbzcoop_relay host|client|echo --dir <mod folder> [options] (record/replay: use the Python relay)".into());
    }
    if a.get("--dir").is_none() {
        return Err("--dir <mod folder> is required".into());
    }
    Ok(a)
}

fn unix_now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// The mod rewrites its heartbeat file (a unix time) every few seconds while the game runs.
fn game_alive(path: &Path, timeout: f64) -> bool {
    match files::read_text(path).trim() {
        "" => unix_now() <= timeout,
        t => t.parse::<f64>().map(|beat| unix_now() - beat <= timeout).unwrap_or(true), // caught mid-write
    }
}

/// Windows wakes sleeping threads on a 15.6 ms clock by default; ask for 1 ms, as games do.
fn fine_timer() {
    #[cfg(windows)]
    {
        #[link(name = "winmm")]
        extern "system" {
            fn timeBeginPeriod(period: u32) -> u32;
        }
        // SAFETY: plain Win32 call; released by Windows when the process exits.
        unsafe {
            timeBeginPeriod(1);
        }
    }
}

const ECHO_OFFSET_X: f64 = 300.0;
const ECHO_DELAY: Duration = Duration::from_millis(300);

/// Echo mode: move the "P seq x y z ..." line dx cm along X so the fake friend stands aside.
fn shift_player_line(snapshot: &str, dx: f64) -> String {
    snapshot
        .lines()
        .map(|line| {
            let mut parts: Vec<String> = line.split_whitespace().map(String::from).collect();
            if parts.len() >= 5 && parts[0] == "P" {
                if let Ok(x) = parts[2].parse::<f64>() {
                    parts[2] = format!("{:.1}", x + dx);
                }
                parts.join(" ")
            } else {
                line.to_string()
            }
        })
        .map(|l| l + "\n")
        .collect()
}

fn run_echo(folder: &Path, seconds: f64) {
    let (out, inp, ev_out, status) =
        (folder.join("net_out.txt"), folder.join("net_in.txt"), folder.join("net_events_out.txt"), folder.join("net_status.txt"));
    let mut inbox = files::EventInbox::new(folder.join("net_events_in.txt"));
    let mut history = VecDeque::new();
    let start = Instant::now();
    let mut last_status: Option<Instant> = None;
    let mut echoed = 0u64;
    while seconds <= 0.0 || start.elapsed().as_secs_f64() < seconds {
        let now = Instant::now();
        history.push_back((now, files::read_text(&out), files::parse_events(&files::read_complete_lines(&ev_out))));
        while history.front().map_or(false, |(t, _, _)| now.duration_since(*t) >= ECHO_DELAY) {
            let (_, snap, (session, events)) = history.pop_front().unwrap();
            if !snap.trim().is_empty() {
                files::write_atomic(&inp, &shift_player_line(&snap, ECHO_OFFSET_X));
                echoed += 1;
            }
            if let Some(s) = session {
                inbox.accept(&s, events);
            }
        }
        if last_status.map_or(true, |t| t.elapsed() >= Duration::from_secs(1)) {
            let line = format!("role=echo connected=yes peer=self rtt_ms={} echoed={echoed} events_in={} relay=native",
                ECHO_DELAY.as_millis(), inbox.last_id);
            files::write_atomic(&status, &format!("{line}\n"));
            println!("{line}");
            last_status = Some(now);
        }
        std::thread::sleep(TICK);
    }
    files::write_atomic(&status, "role=echo connected=no stopped=yes\n");
}

fn main() -> ExitCode {
    let a = match parse() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(2);
        }
    };
    let dir = PathBuf::from(a.get("--dir").unwrap());
    let _ = std::fs::create_dir_all(&dir);
    let seconds: f64 = a.get("--seconds").and_then(|s| s.parse().ok()).unwrap_or(0.0);
    if a.role == "echo" {
        run_echo(&dir, seconds);
        return ExitCode::SUCCESS;
    }
    let host = a.role == "host";
    let port: u16 = a.get("--port").and_then(|p| p.parse().ok()).unwrap_or(PORT);
    let steam = a.get("--transport") == Some("steam");
    let allow = if a.get("--allow") == Some("any") { Allow::Any } else { Allow::Tailscale };
    let status_path = dir.join("net_status.txt");
    let status_error = |e: &str| {
        files::write_atomic(&status_path, &format!("role={} connected=no error={e} time={}\n", a.role, unix_now() as u64));
    };
    if !host && !steam && a.get("--peer").is_none() {
        eprintln!("client needs --peer <host IP>");
        return ExitCode::from(2);
    }
    fine_timer();
    let secret = files::read_secret(&dir, a.get("--secret-file").map(Path::new));
    if !steam && allow == Allow::Any && secret.is_empty() && !a.flag("--insecure") {
        // An open port without signing would let anyone who finds it join or send events.
        status_error("direct-needs-secret");
        println!("Direct needs a Secret: set the same Secret in PhantomPact.ini on both PCs");
        return ExitCode::from(2);
    }
    let transport: Box<dyn transport::Transport> = if steam {
        let (Some(partner), Some(dll)) = (a.get("--partner"), a.get("--steam-dll")) else {
            eprintln!("steam needs --partner <SteamID64 | auto> and --steam-dll <path>");
            return ExitCode::from(2);
        };
        match transport::Steam::new(Path::new(dll), partner, host) {
            Ok(s) => Box::new(s),
            Err(e) => {
                status_error("steam-init");
                println!("Steam networking unavailable: {e}");
                return ExitCode::from(3);
            }
        }
    } else {
        match transport::Udp::new(host, a.get("--peer"), port) {
            Ok(u) => Box::new(u),
            Err(e) => {
                status_error("udp");
                println!("UDP port {port} unavailable: {e}");
                return ExitCode::from(3);
            }
        }
    };
    let mut relay = Relay::new(&a.role, &dir, &secret, allow, transport);
    let mut mapping = None;
    if a.flag("--upnp") && host && !steam {
        match upnp::PortMapping::new(port, a.get("--upnp-location")) {
            Ok(m) => {
                relay.extra_status = format!("upnp=ok external_ip={}", if m.external_ip.is_empty() { "?" } else { &m.external_ip });
                mapping = Some(m);
            }
            Err(e) => {
                relay.extra_status = "upnp=failed".into();
                println!("UPnP port forwarding failed ({e}); forward UDP {port} on the router by hand");
            }
        }
    }
    println!("PBZCoop relay (native) {} over {} (port {port}), files in {}, auth {}, {}", a.role,
        relay.transport.name(), dir.display(), relay.auth.mode(), relay.extra_status);
    let alive = a.get("--alive-file").map(PathBuf::from);
    let alive_timeout = a.get("--alive-timeout").and_then(|s| s.parse().ok()).unwrap_or(ALIVE_TIMEOUT);
    let start = Instant::now();
    let mut last_status: Option<Instant> = None;
    let mut game_closed = false;
    loop {
        relay.tick();
        if last_status.map_or(true, |t| t.elapsed() >= Duration::from_secs(1)) {
            let line = relay.status();
            files::write_atomic(&relay.status_path, &format!("{line}\n"));
            println!("{line}");
            last_status = Some(Instant::now());
        }
        if seconds > 0.0 && start.elapsed().as_secs_f64() >= seconds {
            break;
        }
        if let Some(f) = &alive {
            if !game_alive(f, alive_timeout) {
                println!("the game's heartbeat stopped: game closed, relay exiting");
                game_closed = true;
                break;
            }
        }
        if let Some(m) = &mut mapping {
            m.keep_alive();
        }
        relay.wait(TICK);
    }
    drop(mapping); // removes the router's port forward
    files::write_atomic(&relay.status_path, &format!("role={} connected=no stopped=yes\n", a.role));
    if game_closed {
        coop_sync_after_game(&dir, game_running, Duration::from_secs(120));
    }
    ExitCode::SUCCESS
}

/// PhantomPact.ini CoopSyncTool = path to pbzsave.exe: once the game has closed, record what the partner shared
/// (shared_world.txt) in the save with "pbzsave coop-sync" (it refuses while the game runs, so wait for it to exit).
/// The tool's output goes to coop_sync.log in the mod folder.
fn coop_sync_after_game(dir: &Path, running: impl Fn() -> bool, timeout: Duration) {
    let tool = files::read_ini(dir).into_iter().rev().find(|(k, _)| k == "coopsynctool").map(|(_, v)| v).unwrap_or_default();
    let log = dir.join("coop_sync.log");
    let ledger = dir.join("shared_world.txt");
    if tool.is_empty() || !files::read_text(&ledger).lines().any(|l| !l.trim().is_empty()) {
        return;
    }
    if !Path::new(&tool).is_file() {
        files::write_atomic(&log, &format!("CoopSyncTool not found: {tool}\n"));
        return;
    }
    let deadline = Instant::now() + timeout;
    while running() {
        if Instant::now() >= deadline {
            files::write_atomic(&log, "the game didn't exit in time; nothing written (run pbzsave coop-sync by hand)\n");
            return;
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    let mut cmd = std::process::Command::new(&tool);
    cmd.arg("coop-sync").arg(&ledger);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let text = match cmd.output() {
        Ok(o) => format!("exit {}\n{}{}", o.status, String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr)),
        Err(e) => format!("couldn't run {tool}: {e}\n"),
    };
    files::write_atomic(&log, &text);
}

/// Is PBZ.exe still running (Windows: tasklist; elsewhere the game doesn't run).
fn game_running() -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        if let Ok(o) = std::process::Command::new("tasklist")
            .args(["/FI", "IMAGENAME eq PBZ.exe", "/NH"])
            .creation_flags(0x0800_0000)
            .output()
        {
            return String::from_utf8_lossy(&o.stdout).to_ascii_lowercase().contains("pbz.exe");
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn coop_sync_runs_the_tool_once_the_game_is_gone() {
        let d = std::env::temp_dir().join("pbzcoop_relay_tests").join("coopsync");
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        // A stand-in for pbzsave.exe: writes its arguments.
        let tool = d.join("fake_pbzsave.cmd");
        std::fs::write(&tool, "@echo args: %*\r\n").unwrap();
        std::fs::write(d.join("PhantomPact.ini"), format!("CoopSyncTool = {}\n", tool.display())).unwrap();
        // Nothing shared: nothing run.
        coop_sync_after_game(&d, || false, Duration::from_secs(5));
        assert!(!d.join("coop_sync.log").exists());
        std::fs::write(d.join("shared_world.txt"), "A PBZ_Xigu_WP-BP_Chest_C_1\n").unwrap();
        // The game still running past the timeout: refused, nothing run.
        coop_sync_after_game(&d, || true, Duration::from_millis(10));
        assert!(files::read_text(&d.join("coop_sync.log")).contains("didn't exit"));
        // The game gone: the tool runs with coop-sync and the ledger.
        let calls = std::cell::Cell::new(0);
        coop_sync_after_game(&d, || { calls.set(calls.get() + 1); calls.get() < 2 }, Duration::from_secs(10));
        let log = files::read_text(&d.join("coop_sync.log"));
        assert!(log.contains("args: coop-sync") && log.contains("shared_world.txt"), "{log}");
    }

    #[test]
    fn echo_moves_only_the_player_line() {
        assert_eq!(shift_player_line("P 5 100.0 0.0 0.0 0.0 0 0\nE Mob_1 1.0 2 3 4 50 100 1\n", 300.0),
            "P 5 400.0 0.0 0.0 0.0 0 0\nE Mob_1 1.0 2 3 4 50 100 1\n");
    }
}
