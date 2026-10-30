//! UPnP IGD port forwarding for Direct hosts: SSDP discovery, the router's description, SOAP AddPortMapping /
//! DeletePortMapping (same requests as the Python relay). Plain HTTP over std's TcpStream.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs, UdpSocket};
use std::time::{Duration, Instant};

const WAN_SERVICES: [&str; 3] = [
    "urn:schemas-upnp-org:service:WANIPConnection:2",
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    "urn:schemas-upnp-org:service:WANPPPConnection:1",
];
const LEASE_S: u64 = 3600; // renewed while the relay runs; a crashed relay's mapping expires on its own
const DESCRIPTION: &str = "Phantom Pact co-op";

/// LOCATION header of an SSDP reply.
pub fn ssdp_location(reply: &[u8]) -> Option<String> {
    String::from_utf8_lossy(reply)
        .split("\r\n")
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("location"))
        .map(|(_, v)| v.trim().to_string())
}

fn discover(timeout: Duration) -> Option<String> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.set_read_timeout(Some(timeout)).ok()?;
    let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n\
               ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n";
    s.send_to(msg.as_bytes(), "239.255.255.250:1900").ok()?;
    let mut buf = [0u8; 4096];
    let end = Instant::now() + timeout;
    while Instant::now() < end {
        let (n, _) = s.recv_from(&mut buf).ok()?;
        if let Some(l) = ssdp_location(&buf[..n]) {
            return Some(l);
        }
    }
    None
}

struct Url {
    host: String,
    port: u16,
    path: String,
}

fn parse_url(url: &str) -> Result<Url, String> {
    let rest = url.strip_prefix("http://").ok_or_else(|| format!("not an http URL: {url}"))?;
    let (hostport, path) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}"))).unwrap_or((rest, "/".into()));
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) => (h.to_string(), p.parse().map_err(|_| format!("bad port in {url}"))?),
        None => (hostport.to_string(), 80),
    };
    Ok(Url { host, port, path })
}

/// urllib.parse.urljoin for the cases routers use: absolute URL, absolute path, relative path.
fn join(base: &str, rel: &str) -> String {
    if rel.starts_with("http://") {
        return rel.to_string();
    }
    let Ok(b) = parse_url(base) else { return rel.to_string() };
    let root = format!("http://{}:{}", b.host, b.port);
    if rel.starts_with('/') {
        format!("{root}{rel}")
    } else {
        format!("{root}{}{rel}", &b.path[..b.path.rfind('/').map(|i| i + 1).unwrap_or(1)])
    }
}

fn http(method: &str, url: &str, headers: &[(&str, String)], body: &[u8]) -> Result<String, String> {
    let u = parse_url(url)?;
    let addr = (u.host.as_str(), u.port).to_socket_addrs().map_err(|e| e.to_string())?.next().ok_or("no address")?;
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_secs(3)).map_err(|e| e.to_string())?;
    s.set_read_timeout(Some(Duration::from_secs(3))).map_err(|e| e.to_string())?;
    let mut req = format!("{method} {} HTTP/1.1\r\nHost: {}:{}\r\nConnection: close\r\nContent-Length: {}\r\n", u.path,
        u.host, u.port, body.len());
    for (k, v) in headers {
        req += &format!("{k}: {v}\r\n");
    }
    req += "\r\n";
    s.write_all(req.as_bytes()).and_then(|_| s.write_all(body)).map_err(|e| e.to_string())?;
    let mut raw = vec![];
    let _ = s.read_to_end(&mut raw); // routers may reset after the body; whatever arrived is used
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or("no HTTP reply")?;
    let head = String::from_utf8_lossy(&raw[..split]).into_owned();
    let mut body = raw[split + 4..].to_vec();
    let status: u16 = head.split_whitespace().nth(1).and_then(|c| c.parse().ok()).unwrap_or(0);
    if !(200..300).contains(&status) {
        return Err(format!("HTTP {status}"));
    }
    if head.to_ascii_lowercase().contains("transfer-encoding: chunked") {
        body = dechunk(&body);
    }
    Ok(String::from_utf8_lossy(&body).into_owned())
}

/// Chunked transfer encoding, on bytes: a chunk boundary can fall inside a UTF-8 character (slicing a String there
/// panicked), and a size larger than what arrived ends the body instead of reading past it.
fn dechunk(mut rest: &[u8]) -> Vec<u8> {
    let mut out = vec![];
    while let Some(eol) = rest.windows(2).position(|w| w == b"\r\n") {
        let size = std::str::from_utf8(&rest[..eol]).ok().map(|s| s.split(';').next().unwrap_or("").trim().to_string());
        let Some(n) = size.and_then(|s| usize::from_str_radix(&s, 16).ok()) else { break };
        let after = &rest[eol + 2..];
        if n == 0 || after.len() < n {
            break;
        }
        out.extend_from_slice(&after[..n]);
        rest = &after[n..];
        if rest.starts_with(b"\r\n") {
            rest = &rest[2..];
        }
    }
    out
}

fn tag<'a>(xml: &'a str, name: &str) -> Option<&'a str> {
    let open = format!("<{name}>");
    let start = xml.find(&open)? + open.len();
    Some(xml[start..].split_once(&format!("</{name}>"))?.0.trim())
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn soap(control: &str, stype: &str, action: &str, args: &[(&str, String)]) -> Result<String, String> {
    let body: String = args.iter().map(|(k, v)| format!("<{k}>{}</{k}>", escape(v))).collect();
    let envelope = format!("<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" \
        s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:{action} xmlns:u=\"{stype}\">{body}\
        </u:{action}></s:Body></s:Envelope>");
    http("POST", control, &[("Content-Type", "text/xml; charset=\"utf-8\"".into()), ("SOAPAction", format!("\"{stype}#{action}\""))],
        envelope.as_bytes())
}

/// Asks the router to forward UDP <port> to this PC and removes the mapping on drop.
pub struct PortMapping {
    port: u16,
    control: String,
    stype: String,
    client: String,
    pub external_ip: String,
    renewed: Instant,
}

impl PortMapping {
    pub fn new(port: u16, location: Option<&str>) -> Result<PortMapping, String> {
        let location = match location {
            Some(l) => l.to_string(),
            None => discover(Duration::from_secs(2)).ok_or("no UPnP router answered (UPnP off on the router?)")?,
        };
        let desc = http("GET", &location, &[], b"")?;
        let base = tag(&desc, "URLBase").filter(|b| !b.is_empty()).unwrap_or(&location).to_string();
        let (control, stype) = desc
            .split("<service>")
            .skip(1)
            .filter_map(|svc| Some((tag(svc, "serviceType")?, tag(svc, "controlURL")?)))
            .find(|(t, _)| WAN_SERVICES.contains(t))
            .map(|(t, c)| (join(&base, c), t.to_string()))
            .ok_or("router has no WAN IP/PPP connection service")?;
        let u = parse_url(&control)?;
        let probe = UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
        probe.connect((u.host.as_str(), 1900)).map_err(|e| e.to_string())?;
        let client = probe.local_addr().map_err(|e| e.to_string())?.ip().to_string();
        let mut m = PortMapping { port, control, stype, client, external_ip: String::new(), renewed: Instant::now() };
        m.renew()?;
        if let Ok(r) = soap(&m.control, &m.stype, "GetExternalIPAddress", &[]) {
            m.external_ip = tag(&r, "NewExternalIPAddress").unwrap_or("").to_string();
        }
        Ok(m)
    }

    fn renew(&mut self) -> Result<(), String> {
        soap(&self.control, &self.stype, "AddPortMapping", &[
            ("NewRemoteHost", String::new()),
            ("NewExternalPort", self.port.to_string()),
            ("NewProtocol", "UDP".into()),
            ("NewInternalPort", self.port.to_string()),
            ("NewInternalClient", self.client.clone()),
            ("NewEnabled", "1".into()),
            ("NewPortMappingDescription", DESCRIPTION.into()),
            ("NewLeaseDuration", LEASE_S.to_string()),
        ])?;
        self.renewed = Instant::now();
        Ok(())
    }

    pub fn keep_alive(&mut self) {
        if self.renewed.elapsed() >= Duration::from_secs(LEASE_S / 2) {
            let _ = self.renew();
        }
    }
}

impl Drop for PortMapping {
    fn drop(&mut self) {
        let _ = soap(&self.control, &self.stype, "DeletePortMapping", &[
            ("NewRemoteHost", String::new()),
            ("NewExternalPort", self.port.to_string()),
            ("NewProtocol", "UDP".into()),
        ]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssdp_and_urls() {
        let reply = b"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLocation: http://192.168.1.1:5000/rootDesc.xml\r\n\r\n";
        assert_eq!(ssdp_location(reply).as_deref(), Some("http://192.168.1.1:5000/rootDesc.xml"));
        assert_eq!(join("http://192.168.1.1:5000/rootDesc.xml", "/ctl/IPConn"), "http://192.168.1.1:5000/ctl/IPConn");
        assert_eq!(join("http://192.168.1.1:5000/a/desc.xml", "ctl"), "http://192.168.1.1:5000/a/ctl");
        assert_eq!(join("http://x:1/", "http://y:2/c"), "http://y:2/c");
        assert_eq!(tag("<a><NewExternalIPAddress>203.0.113.7</NewExternalIPAddress>", "NewExternalIPAddress"), Some("203.0.113.7"));
    }

    #[test]
    fn chunked_bodies_split_inside_a_character_or_cut_short_dont_panic() {
        // "é" is two bytes; the first chunk ends between them.
        let body = b"3\r\nab\xC3\r\n1\r\n\xA9\r\n0\r\n\r\n";
        assert_eq!(String::from_utf8(dechunk(body)).unwrap(), "abé");
        assert_eq!(dechunk(b"ff\r\nshort"), b"");
        assert_eq!(dechunk(b"zz\r\nbad"), b"");
    }
}
