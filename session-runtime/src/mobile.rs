//! Authenticated LAN/Tailscale transport for local runtime sockets; never owns a PTY.
//! Handshake token selection and WebSocket/Unix splice adapted from Termio
//! 819658751635eb298a467f4d84e793729c5242bc, termiod/src/wss.rs (MIT).
//! See LICENSE.termio and THIRD-PARTY-NOTICES.
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    ffi::CStr,
    fs, io,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
            process::CommandExt,
        },
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::{
    handshake::server::{ErrorResponse, Request, Response},
    http::{HeaderValue, StatusCode},
    protocol::WebSocketConfig,
    Message,
};

mod control;
pub mod qr;

const PREFIX: &str = "omg.";
const DEFAULT_PORT: u16 = 8791;
const HELP: &str = "\
Usage: omg +mobile [pair | start | serve | status | stop | revoke] [options]
       omgd mobile [pair | start | serve | status | stop | revoke] [options]

Commands:
  pair                 Start or reuse this machine's mobile gateway and print QR + pairing link (default)
  start                Start or reuse this machine's mobile gateway in the background
  serve                Run the mobile gateway in the foreground
  status               Show gateway status, pairing link, and discovered local runtime endpoints
  stop                 Stop this machine's background mobile gateway
  revoke               Rotate the pairing token and restart the background gateway if running

Options:
  --listen IP:PORT     Bind a specific loopback, LAN, or Tailscale IPv4 address
  --port PORT          Port to bind when auto-detecting IP (default: 8791)
  --lan                Prefer this machine's private LAN IPv4 address
  --tailscale          Prefer this machine's Tailscale (100.64.0.0/10) IPv4 address
  --public-url URL     Advertise a custom ws:// or wss:// URL in the pairing link and QR code
  --state-dir PATH     Override the mobile state directory
  --app-support PATH   Use a desktop Application Support directory
  --socket PATH        Expose a single runtime host.sock
  --token-file PATH    Override the pairing token file path
  --allow-origin URL   Allow a specific browser Origin header
  --print-invite       Print only the omg://device pairing link without starting a listener
  --no-qr              Omit the terminal QR code when printing the pairing invite
  --json               Print structured JSON output (for pair / status / revoke)

The gateway only exposes this machine's local sessions, never registered SSH Cloud
hosts. To pair an SSH server with OMG Mobile, run `omg +mobile` on that server.
";

#[derive(Clone, Serialize)]
struct Endpoint {
    id: String,
    name: String,
    #[serde(skip)]
    socket: PathBuf,
    #[serde(skip)]
    relay: Option<omg_session_runtime::location::SshTarget>,
}

struct Config {
    endpoints: Vec<Endpoint>,
    support: Option<PathBuf>,
    token: String,
    origin: Option<String>,
    control: control::State,
}

#[derive(Debug, PartialEq, Eq)]
enum Route {
    Catalogue,
    Control,
    Session(PathBuf, bool),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Subcommand {
    LegacyServe,
    Pair,
    Start,
    Serve,
    Status,
    Stop,
    Revoke,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum IpPreference {
    Auto,
    Lan,
    Tailscale,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct GatewayRecord {
    pid: u32,
    listen: String,
    public_url: String,
    token_file: PathBuf,
    started_at: u64,
}

struct GatewayLock(fs::File);

impl GatewayLock {
    fn acquire(state_dir: &Path) -> io::Result<Self> {
        ensure_state_dir(state_dir)?;
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(state_dir.join("mobile-gateway.lock"))?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::other("OMG mobile gateway is already running"));
        }
        Ok(Self(file))
    }
}

impl Drop for GatewayLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

fn ensure_state_dir(path: &Path) -> io::Result<()> {
    if !path.exists() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)?;
    }
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.file_type().is_symlink() {
        return Err(io::Error::other(
            "Mobile state directory must be owned by the current user",
        ));
    }
    Ok(())
}

fn gateway_is_locked(state_dir: &Path) -> bool {
    let lock_path = state_dir.join("mobile-gateway.lock");
    let Ok(file) = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(lock_path)
    else {
        return false;
    };
    let locked = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0;
    if !locked {
        unsafe {
            libc::flock(file.as_raw_fd(), libc::LOCK_UN);
        }
    }
    locked
}

fn read_gateway_record(state_dir: &Path) -> Option<GatewayRecord> {
    if !gateway_is_locked(state_dir) {
        return None;
    }
    let bytes = fs::read(state_dir.join("mobile-gateway.json")).ok()?;
    let record: GatewayRecord = serde_json::from_slice(&bytes).ok()?;
    if record.pid > 1 && unsafe { libc::kill(record.pid as i32, 0) } == 0 {
        Some(record)
    } else {
        None
    }
}

fn write_gateway_record(state_dir: &Path, record: &GatewayRecord) -> io::Result<()> {
    ensure_state_dir(state_dir)?;
    let path = state_dir.join("mobile-gateway.json");
    let tmp = state_dir.join(format!(
        ".mobile-gateway-{}.tmp",
        omg_session_runtime::record::nonce()?
    ));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)?;
    use std::io::Write;
    file.write_all(&serde_json::to_vec_pretty(record)?)?;
    file.sync_all()?;
    if let Err(err) = fs::rename(&tmp, &path) {
        let _ = fs::remove_file(&tmp);
        return Err(err);
    }
    Ok(())
}

fn stop_gateway_in(state_dir: &Path) -> io::Result<bool> {
    let Some(record) = read_gateway_record(state_dir) else {
        let _ = fs::remove_file(state_dir.join("mobile-gateway.json"));
        return Ok(false);
    };
    unsafe {
        libc::kill(record.pid as i32, libc::SIGTERM);
    }
    for _ in 0..60 {
        if !gateway_is_locked(state_dir) {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    if gateway_is_locked(state_dir) {
        unsafe {
            libc::kill(record.pid as i32, libc::SIGKILL);
        }
        for _ in 0..20 {
            if !gateway_is_locked(state_dir) {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    let _ = fs::remove_file(state_dir.join("mobile-gateway.json"));
    Ok(true)
}

fn parse_route(path: &str, destinations: &[Endpoint]) -> Option<Route> {
    if path.is_empty() || path.contains("..") || path.contains('\\') {
        return None;
    }
    let clean = path.trim_end_matches('/');
    if clean == "/catalogue" || clean.ends_with("/catalogue") {
        return Some(Route::Catalogue);
    }
    if clean == "/control" || clean.ends_with("/control") {
        return Some(Route::Control);
    }
    let id = clean
        .strip_prefix("/ws/")
        .or_else(|| clean.rsplit_once("/ws/").map(|(_, id)| id))?;
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    destinations
        .iter()
        .find(|e| e.id == id)
        .map(|e| Route::Session(e.socket.clone(), e.relay.is_some()))
}

impl Config {
    fn endpoints(&self) -> io::Result<Vec<Endpoint>> {
        if let Some(support) = &self.support {
            let mut result = targets(super::session_cli::mobile_targets(support)?)?;
            for (name, socket, ssh) in super::session_cli::mobile_relay_targets(support) {
                if let Ok(mut ep) = targets(vec![(name, socket)]) {
                    if let Some(mut first) = ep.pop() {
                        first.relay = Some(ssh);
                        result.push(first);
                    }
                }
            }
            Ok(result)
        } else {
            Ok(self.endpoints.clone())
        }
    }
}

fn targets(values: Vec<(String, PathBuf)>) -> io::Result<Vec<Endpoint>> {
    values
        .into_iter()
        .map(|(name, socket)| {
            let parent = socket
                .parent()
                .ok_or_else(|| io::Error::other("Socket must have a private parent"))?;
            private(parent, true)?;
            let meta = fs::symlink_metadata(&socket)?;
            if meta.uid() != unsafe { libc::geteuid() } || meta.file_type().is_symlink() {
                return Err(io::Error::other(
                    "Runtime socket has an invalid owner or type",
                ));
            }
            Ok(Endpoint {
                id: format!("{:x}", Sha256::digest(socket.to_string_lossy().as_bytes())),
                name,
                socket,
                relay: None,
            })
        })
        .collect()
}

fn private(path: &Path, directory: bool) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
        || if directory {
            !meta.is_dir()
        } else {
            !meta.is_file()
        }
    {
        return Err(io::Error::other(
            "Path must be private and owned by the current user",
        ));
    }
    Ok(())
}

fn token(path: &Path) -> io::Result<String> {
    if let Some(parent) = path.parent() {
        ensure_state_dir(parent)?;
    }
    if !path.exists() {
        use std::io::Write;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        writeln!(
            file,
            "{}{}",
            omg_session_runtime::record::nonce()?,
            omg_session_runtime::record::nonce()?
        )?;
    }
    private(path, false)?;
    let value = fs::read_to_string(path)?;
    let value = value.trim();
    if value.len() < 32 || value.len() > 256 || !value.bytes().all(|c| c.is_ascii_alphanumeric()) {
        return Err(io::Error::other(
            "Token must contain 32–256 ASCII letters or digits",
        ));
    }
    Ok(value.into())
}

fn rotate_token(path: &Path) -> io::Result<String> {
    if let Some(parent) = path.parent() {
        ensure_state_dir(parent)?;
    }
    let _ = fs::remove_file(path);
    token(path)
}

// From Termio's wss.rs: the secret travels in a subprotocol, not a logged URL.
fn select_subprotocol(offered: Option<&str>, expected: &str) -> Option<String> {
    offered?
        .split(',')
        .map(str::trim)
        .find(|entry| {
            entry.strip_prefix(PREFIX).is_some_and(|candidate| {
                candidate.len() == expected.len()
                    && candidate
                        .bytes()
                        .zip(expected.bytes())
                        .fold(0u8, |d, (a, b)| d | a ^ b)
                        == 0
            })
        })
        .map(str::to_owned)
}

fn is_tailscale_ipv4(ip: Ipv4Addr) -> bool {
    let octets = ip.octets();
    octets[0] == 100 && (64..=127).contains(&octets[1])
}

fn is_allowed_listen_ipv4(ip: Ipv4Addr) -> bool {
    ip.is_loopback() || ip.is_private() || ip.is_link_local() || is_tailscale_ipv4(ip)
}

fn list_interface_ipv4() -> Vec<(String, Ipv4Addr)> {
    let mut result = Vec::new();
    let mut ifap: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut ifap) } != 0 {
        return result;
    }
    let mut cur = ifap;
    while !cur.is_null() {
        unsafe {
            let ifa = &*cur;
            let flags = ifa.ifa_flags as i32;
            if (flags & libc::IFF_UP) != 0
                && (flags & libc::IFF_LOOPBACK) == 0
                && !ifa.ifa_addr.is_null()
                && (*ifa.ifa_addr).sa_family as i32 == libc::AF_INET
            {
                let name = CStr::from_ptr(ifa.ifa_name).to_string_lossy().into_owned();
                let sin = &*(ifa.ifa_addr as *const libc::sockaddr_in);
                let ip = Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr));
                result.push((name, ip));
            }
            cur = ifa.ifa_next;
        }
    }
    unsafe {
        libc::freeifaddrs(ifap);
    }
    result
}

fn is_virtual_bridge(name: &str) -> bool {
    name.starts_with("docker")
        || name.starts_with("br-")
        || name.starts_with("veth")
        || name.starts_with("virbr")
}

fn is_preferred_lan_if(name: &str) -> bool {
    matches!(name, "en0" | "en1" | "eth0" | "wlan0" | "bond0")
        || name.starts_with("enp")
        || name.starts_with("ens")
        || name.starts_with("wl")
}

fn detect_ipv4(preference: IpPreference) -> io::Result<Ipv4Addr> {
    let interfaces = list_interface_ipv4();
    let lan = interfaces
        .iter()
        .filter(|(name, ip)| !is_virtual_bridge(name) && ip.is_private())
        .min_by_key(|(name, _)| !is_preferred_lan_if(name))
        .map(|(_, ip)| *ip);
    let tailscale = interfaces
        .iter()
        .find(|(_, ip)| is_tailscale_ipv4(*ip))
        .map(|(_, ip)| *ip);
    match preference {
        IpPreference::Lan => lan.ok_or_else(|| {
            io::Error::other("No active private LAN IPv4 address found; supply --listen IP:PORT")
        }),
        IpPreference::Tailscale => tailscale.ok_or_else(|| {
            io::Error::other(
                "No active Tailscale (100.64.0.0/10) IPv4 address found; supply --listen IP:PORT",
            )
        }),
        IpPreference::Auto => Ok(lan.or(tailscale).unwrap_or(Ipv4Addr::LOCALHOST)),
    }
}

fn validate_public_url(raw: &str) -> io::Result<String> {
    let trimmed = raw.trim().trim_end_matches('/');
    let (scheme, rest) = if let Some(r) = trimmed.strip_prefix("wss://") {
        ("wss", r)
    } else if let Some(r) = trimmed.strip_prefix("ws://") {
        ("ws", r)
    } else {
        return Err(io::Error::other(
            "--public-url must start with ws:// or wss://",
        ));
    };
    if rest.is_empty()
        || rest
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || matches!(c, '?' | '#' | '@' | '\\'))
        || rest.contains("..")
    {
        return Err(io::Error::other("Invalid --public-url"));
    }
    let authority = rest.split('/').next().unwrap_or("");
    let host = if let Some(bracketed) = authority.strip_prefix('[') {
        bracketed.split(']').next().unwrap_or("")
    } else {
        authority.split(':').next().unwrap_or("")
    };
    if host.is_empty() {
        return Err(io::Error::other("--public-url is missing a host"));
    }
    if scheme == "ws" {
        let lower = host.to_ascii_lowercase();
        let private_host = lower == "localhost"
            || lower == "::1"
            || lower.ends_with(".local")
            || lower.parse::<Ipv4Addr>().is_ok_and(is_allowed_listen_ipv4);
        if !private_host {
            return Err(io::Error::other(
                "Public hosts require wss:// in --public-url; ws:// is only allowed for LAN, loopback, or Tailscale",
            ));
        }
    }
    Ok(format!("{scheme}://{rest}"))
}

fn invite_uri(public_url: &str, token: &str) -> String {
    format!("omg://device?url={public_url}&token={token}")
}

fn print_pairing_output(
    listen: &str,
    public_url: &str,
    token_value: &str,
    state_dir: Option<&Path>,
    endpoints: &[Endpoint],
    no_qr: bool,
    json_output: bool,
) -> io::Result<()> {
    let invite = invite_uri(public_url, token_value);
    if json_output {
        let payload = serde_json::json!({
            "running": true,
            "listen": listen,
            "public_url": public_url,
            "invite_url": invite,
            "state_dir": state_dir,
            "endpoints": endpoints.iter().map(|e| serde_json::json!({
                "id": e.id,
                "name": e.name,
                "socket": e.socket,
            })).collect::<Vec<_>>(),
        });
        println!("{}", serde_json::to_string(&payload)?);
        return Ok(());
    }
    if !no_qr {
        if let Ok(code) = qr::render_unicode(&invite) {
            println!("\n{code}");
        }
    }
    println!("Pairing URL:  {invite}");
    println!("Gateway:      ws://{listen}");
    if public_url != format!("ws://{listen}") {
        println!("Public URL:   {public_url}");
    }
    if let Some(dir) = state_dir {
        println!("State dir:    {}", dir.display());
    }
    println!(
        "Runtimes:     {} local session endpoint(s) on this machine",
        endpoints.len()
    );
    Ok(())
}

pub fn run(args: &[String]) -> io::Result<()> {
    if args
        .iter()
        .any(|a| a == "--help" || a == "-h" || a == "help")
    {
        println!("{HELP}");
        return Ok(());
    }
    let mut subcommand = None;
    let mut slice = args;
    if let Some(first) = args.first() {
        subcommand = match first.as_str() {
            "pair" => Some(Subcommand::Pair),
            "start" => Some(Subcommand::Start),
            "serve" => Some(Subcommand::Serve),
            "status" => Some(Subcommand::Status),
            "stop" => Some(Subcommand::Stop),
            "revoke" => Some(Subcommand::Revoke),
            _ => None,
        };
        if subcommand.is_some() {
            slice = &args[1..];
        }
    }

    let mut listen_arg: Option<String> = None;
    let mut port: u16 = DEFAULT_PORT;
    let mut ip_pref = IpPreference::Auto;
    let mut public_url_arg: Option<String> = None;
    let mut support: Option<PathBuf> = None;
    let mut socket: Option<PathBuf> = None;
    let mut key: Option<PathBuf> = None;
    let mut origin: Option<String> = None;
    let mut print_invite = false;
    let mut no_qr = false;
    let mut json_output = false;

    let mut iter = slice.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--print-invite" => {
                print_invite = true;
                continue;
            }
            "--lan" => {
                ip_pref = IpPreference::Lan;
                continue;
            }
            "--tailscale" => {
                ip_pref = IpPreference::Tailscale;
                continue;
            }
            "--no-qr" => {
                no_qr = true;
                continue;
            }
            "--json" => {
                json_output = true;
                continue;
            }
            _ => {}
        }
        let value = iter
            .next()
            .ok_or_else(|| io::Error::other(format!("Missing option value for {arg}")))?;
        match arg.as_str() {
            "--listen" => listen_arg = Some(value.clone()),
            "--port" => {
                port = value
                    .parse::<u16>()
                    .map_err(|_| io::Error::other("Invalid --port"))?;
            }
            "--public-url" => public_url_arg = Some(validate_public_url(value)?),
            "--app-support" | "--state-dir" => support = Some(PathBuf::from(value)),
            "--socket" => socket = Some(PathBuf::from(value)),
            "--token-file" => key = Some(PathBuf::from(value)),
            "--allow-origin" => origin = Some(value.clone()),
            _ => return Err(io::Error::other(format!("Unknown option: {arg}"))),
        }
    }

    let mode = subcommand.unwrap_or({
        if key.is_some() || print_invite {
            Subcommand::LegacyServe
        } else {
            Subcommand::Pair
        }
    });

    if support.is_some() && socket.is_some() {
        return Err(io::Error::other("--app-support and --socket are exclusive"));
    }

    let endpoints = if let Some(ref sock) = socket {
        targets(vec![("This Machine".into(), sock.clone())])?
    } else {
        let dir = match support {
            Some(path) => path,
            None => super::session_cli::default_mobile_support()?,
        };
        ensure_state_dir(&dir)?;
        support = Some(dir);
        Vec::new()
    };

    if mode == Subcommand::Stop {
        let state_dir = support
            .as_ref()
            .ok_or_else(|| io::Error::other("--stop requires a state directory"))?;
        let stopped = stop_gateway_in(state_dir)?;
        if json_output {
            println!("{}", serde_json::json!({"stopped": stopped}));
        } else if stopped {
            println!("Stopped OMG mobile gateway.");
        } else {
            println!("OMG mobile gateway is not running.");
        }
        return Ok(());
    }

    let key_path = match key {
        Some(path) => path,
        None => {
            if mode == Subcommand::LegacyServe {
                return Err(io::Error::other("--token-file is required"));
            }
            let base = support
                .clone()
                .or_else(|| socket.as_ref().and_then(|s| s.parent().map(Path::to_owned)))
                .ok_or_else(|| io::Error::other("Missing mobile state directory"))?;
            base.join("mobile-pair.token")
        }
    };

    if mode == Subcommand::Status {
        let state_dir = support.as_deref();
        let active = state_dir.and_then(read_gateway_record);
        let tok = if key_path.exists() {
            token(&key_path).ok()
        } else {
            None
        };
        let config = Config {
            endpoints,
            support: support.clone(),
            token: tok.clone().unwrap_or_default(),
            origin,
            control: control::State::default(),
        };
        let discovered = config.endpoints().unwrap_or_default();
        if json_output {
            let invite = active
                .as_ref()
                .zip(tok.as_deref())
                .map(|(rec, t)| invite_uri(&rec.public_url, t));
            println!(
                "{}",
                serde_json::json!({
                    "running": active.is_some(),
                    "pid": active.as_ref().map(|r| r.pid),
                    "listen": active.as_ref().map(|r| &r.listen),
                    "public_url": active.as_ref().map(|r| &r.public_url),
                    "invite_url": invite,
                    "state_dir": state_dir,
                    "endpoints": discovered.iter().map(|e| serde_json::json!({
                        "id": e.id,
                        "name": e.name,
                        "socket": e.socket,
                    })).collect::<Vec<_>>(),
                })
            );
        } else if let Some(rec) = active {
            println!("Status:       running (pid {})", rec.pid);
            println!("Gateway:      ws://{}", rec.listen);
            if rec.public_url != format!("ws://{}", rec.listen) {
                println!("Public URL:   {}", rec.public_url);
            }
            if let Some(t) = tok.as_deref() {
                println!("Pairing URL:  {}", invite_uri(&rec.public_url, t));
            }
            if let Some(dir) = state_dir {
                println!("State dir:    {}", dir.display());
            }
            println!(
                "Runtimes:     {} local session endpoint(s) on this machine",
                discovered.len()
            );
        } else {
            println!("Status:       stopped");
            if let Some(dir) = state_dir {
                println!("State dir:    {}", dir.display());
            }
            println!(
                "Runtimes:     {} local session endpoint(s) on this machine",
                discovered.len()
            );
        }
        return Ok(());
    }

    if mode == Subcommand::Revoke {
        let state_dir = support.as_deref();
        let previous = state_dir.and_then(read_gateway_record);
        if let Some(dir) = state_dir {
            let _ = stop_gateway_in(dir)?;
        }
        let fresh_token = rotate_token(&key_path)?;
        if let Some(prev) = previous {
            let listen_str = listen_arg.as_deref().unwrap_or(&prev.listen);
            let address: SocketAddr = listen_str.parse().map_err(io::Error::other)?;
            let explicit_pub = public_url_arg.as_deref().or_else(|| {
                let default_prev = format!("ws://{}", prev.listen);
                (prev.public_url != default_prev).then_some(prev.public_url.as_str())
            });
            let record = ensure_background_gateway(
                support.as_deref(),
                socket.as_deref(),
                &key_path,
                address,
                explicit_pub,
                origin.as_deref(),
            )?;
            let config = Config {
                endpoints,
                support: support.clone(),
                token: fresh_token.clone(),
                origin,
                control: control::State::default(),
            };
            let discovered = config.endpoints().unwrap_or_default();
            if print_invite {
                println!("{}", invite_uri(&record.public_url, &fresh_token));
                return Ok(());
            }
            return print_pairing_output(
                &record.listen,
                &record.public_url,
                &fresh_token,
                support.as_deref(),
                &discovered,
                no_qr,
                json_output,
            );
        }
        if print_invite {
            let addr = resolve_listen_address(listen_arg.as_deref(), ip_pref, port, mode)?;
            let pub_url = public_url_arg.unwrap_or_else(|| format!("ws://{addr}"));
            println!("{}", invite_uri(&pub_url, &fresh_token));
            return Ok(());
        }
        if json_output {
            println!(
                "{}",
                serde_json::json!({"revoked": true, "running": false, "token_file": key_path})
            );
        } else {
            println!("Rotated mobile pairing token: {}", key_path.display());
        }
        return Ok(());
    }

    let address = resolve_listen_address(listen_arg.as_deref(), ip_pref, port, mode)?;
    let public_url = public_url_arg
        .clone()
        .unwrap_or_else(|| format!("ws://{address}"));
    let token_value = token(&key_path)?;

    if print_invite {
        if address.port() == 0 && public_url_arg.is_none() {
            return Err(io::Error::other("Choose a fixed port for pairing"));
        }
        println!("{}", invite_uri(&public_url, &token_value));
        return Ok(());
    }

    if matches!(mode, Subcommand::Pair | Subcommand::Start) {
        let explicit_net = listen_arg.is_some()
            || public_url_arg.is_some()
            || ip_pref != IpPreference::Auto
            || port != DEFAULT_PORT;
        let record = if let Some(existing) = support
            .as_deref()
            .and_then(read_gateway_record)
            .filter(|rec| {
                !explicit_net || (rec.listen == address.to_string() && rec.public_url == public_url)
            }) {
            existing
        } else {
            if let Some(dir) = support.as_deref() {
                let _ = stop_gateway_in(dir)?;
            }
            ensure_background_gateway(
                support.as_deref(),
                socket.as_deref(),
                &key_path,
                address,
                public_url_arg.as_deref(),
                origin.as_deref(),
            )?
        };
        let config = Config {
            endpoints,
            support: support.clone(),
            token: token_value.clone(),
            origin,
            control: control::State::default(),
        };
        let discovered = config.endpoints().unwrap_or_default();
        return print_pairing_output(
            &record.listen,
            &record.public_url,
            &token_value,
            support.as_deref(),
            &discovered,
            no_qr,
            json_output,
        );
    }

    let _gateway_lock = if let Some(ref dir) = support {
        if subcommand == Some(Subcommand::Serve) {
            Some(GatewayLock::acquire(dir)?)
        } else {
            None
        }
    } else {
        None
    };

    let config = Arc::new(Config {
        endpoints,
        support: support.clone(),
        token: token_value,
        origin,
        control: control::State::default(),
    });

    tokio::runtime::Runtime::new()?.block_on(async move {
        let listener = tokio::net::TcpListener::bind(address).await?;
        let bound = listener.local_addr()?;
        let effective_public = public_url_arg.unwrap_or_else(|| format!("ws://{bound}"));
        if let (Some(ref dir), Some(_)) = (&support, &_gateway_lock) {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let _ = write_gateway_record(
                dir,
                &GatewayRecord {
                    pid: std::process::id(),
                    listen: bound.to_string(),
                    public_url: effective_public.clone(),
                    token_file: key_path.clone(),
                    started_at: now,
                },
            );
        }
        eprintln!("OMG mobile listening on ws://{bound}/catalogue");
        let loopback_listener = if !bound.ip().is_loopback() && bound.port() != 0 {
            let lo = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), bound.port());
            tokio::net::TcpListener::bind(lo).await.ok()
        } else {
            None
        };
        if let Some(ref lo) = loopback_listener {
            if let Ok(addr) = lo.local_addr() {
                eprintln!("OMG mobile also listening on ws://{addr}/catalogue");
            }
        }
        eprintln!("Pairing token file: {}", key_path.display());
        let handshake_permits = Arc::new(tokio::sync::Semaphore::new(64));
        let session_permits = Arc::new(tokio::sync::Semaphore::new(16));
        let auth_failure_permits = Arc::new(tokio::sync::Semaphore::new(8));
        loop {
            let accepted = if let Some(ref lo) = loopback_listener {
                tokio::select! {
                    res = listener.accept() => res,
                    res = lo.accept() => res,
                }
            } else {
                listener.accept().await
            };
            let (stream, _) = accepted?;
            let Ok(handshake_permit) = handshake_permits.clone().try_acquire_owned() else {
                continue;
            };
            let config = config.clone();
            let session_permits = session_permits.clone();
            let auth_failure_permits = auth_failure_permits.clone();
            tokio::spawn(async move {
                if let Err(error) = serve(
                    stream,
                    config,
                    handshake_permit,
                    session_permits,
                    auth_failure_permits,
                )
                .await
                {
                    eprintln!("OMG mobile connection ended: {error}");
                }
            });
        }
    })
}

fn resolve_listen_address(
    listen_arg: Option<&str>,
    ip_pref: IpPreference,
    port: u16,
    mode: Subcommand,
) -> io::Result<SocketAddr> {
    let address: SocketAddr = if let Some(explicit) = listen_arg {
        explicit.parse().map_err(io::Error::other)?
    } else if mode == Subcommand::LegacyServe && ip_pref == IpPreference::Auto {
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port)
    } else {
        SocketAddr::new(IpAddr::V4(detect_ipv4(ip_pref)?), port)
    };
    if address.ip().is_unspecified() || address.ip().is_multicast() {
        return Err(io::Error::other(
            "Choose a specific loopback or LAN address",
        ));
    }
    if let IpAddr::V4(ip) = address.ip() {
        if !is_allowed_listen_ipv4(ip) {
            return Err(io::Error::other("The first mobile transport is LAN-only"));
        }
    } else if !address.ip().is_loopback() {
        return Err(io::Error::other("Use an IPv4 LAN address or loopback"));
    }
    Ok(address)
}

fn ensure_background_gateway(
    support: Option<&Path>,
    socket: Option<&Path>,
    token_file: &Path,
    address: SocketAddr,
    public_url: Option<&str>,
    origin: Option<&str>,
) -> io::Result<GatewayRecord> {
    let state_dir = support
        .or_else(|| socket.and_then(Path::parent))
        .ok_or_else(|| io::Error::other("No mobile state directory available"))?;
    ensure_state_dir(state_dir)?;
    let log_path = state_dir.join("mobile-gateway.log");
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&log_path)?;
    let exe = std::env::current_exe()?;
    let mut cmd = Command::new(&exe);
    cmd.args(["mobile", "serve", "--listen", &address.to_string()]);
    if let Some(dir) = support {
        cmd.arg("--state-dir").arg(dir);
    } else if let Some(sock) = socket {
        cmd.arg("--socket").arg(sock);
    }
    cmd.arg("--token-file").arg(token_file);
    if let Some(pub_url) = public_url {
        cmd.arg("--public-url").arg(pub_url);
    }
    if let Some(orig) = origin {
        cmd.arg("--allow-origin").arg(orig);
    }
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(log);
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            libc::signal(libc::SIGHUP, libc::SIG_IGN);
            Ok(())
        });
    }
    let mut child = cmd.spawn()?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    for _ in 0..100 {
        if let Some(record) = read_gateway_record(state_dir) {
            return Ok(record);
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    Err(io::Error::other(format!(
        "Mobile gateway did not start (check {})",
        log_path.display()
    )))
}

async fn serve(
    stream: tokio::net::TcpStream,
    config: Arc<Config>,
    handshake_permit: tokio::sync::OwnedSemaphorePermit,
    session_permits: Arc<tokio::sync::Semaphore>,
    auth_failure_permits: Arc<tokio::sync::Semaphore>,
) -> io::Result<()> {
    let endpoints = config.endpoints()?;
    let destinations = endpoints.clone();
    let key = config.token.clone();
    let allowed_origin = config.origin.clone();
    let (tx, rx) = tokio::sync::oneshot::channel();
    let mut tx = Some(tx);
    let auth_failed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let auth_failed_cb = auth_failed.clone();
    let handshake = tokio_tungstenite::accept_hdr_async_with_config(
        stream,
        #[allow(clippy::result_large_err)]
        move |request: &Request, mut response: Response| {
            let refuse = |status| {
                let mut response = ErrorResponse::new(None);
                *response.status_mut() = status;
                response
            };
            let selected = select_subprotocol(
                request
                    .headers()
                    .get("sec-websocket-protocol")
                    .and_then(|v| v.to_str().ok()),
                &key,
            )
            .ok_or_else(|| {
                auth_failed_cb.store(true, std::sync::atomic::Ordering::Relaxed);
                refuse(StatusCode::UNAUTHORIZED)
            })?;
            // Native clients send no Origin. Browser clients must be explicitly allowed.
            if let Some(origin) = request.headers().get("origin") {
                if origin.to_str().ok() != allowed_origin.as_deref() {
                    return Err(refuse(StatusCode::FORBIDDEN));
                }
            }
            if request.uri().query().is_some() {
                return Err(refuse(StatusCode::BAD_REQUEST));
            }
            let destination = parse_route(request.uri().path(), &destinations)
                .ok_or_else(|| refuse(StatusCode::NOT_FOUND))?;
            response.headers_mut().insert(
                "sec-websocket-protocol",
                HeaderValue::from_str(&selected).map_err(|_| refuse(StatusCode::BAD_REQUEST))?,
            );
            if let Some(tx) = tx.take() {
                let _ = tx.send(destination);
            }
            Ok(response)
        },
        Some(
            WebSocketConfig::default()
                .max_message_size(Some(omg_session_runtime::MAX_FRAME))
                .max_frame_size(Some(omg_session_runtime::MAX_FRAME)),
        ),
    );
    let ws = match tokio::time::timeout(Duration::from_secs(5), handshake).await {
        Ok(Ok(ws)) => ws,
        Ok(Err(error)) => {
            if auth_failed.load(std::sync::atomic::Ordering::Relaxed) {
                if let Ok(_tarpit) = auth_failure_permits.try_acquire() {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                }
            }
            return Err(io::Error::other(error));
        }
        Err(error) => return Err(io::Error::other(error)),
    };
    drop(handshake_permit);
    let _session_permit = session_permits
        .try_acquire_owned()
        .map_err(|_| io::Error::other("Too many active mobile connections"))?;
    let mut ws = ws;
    let destination = rx.await.map_err(io::Error::other)?;
    let destination = match destination {
        Route::Control => return control::serve(ws, config).await,
        Route::Catalogue => {
            ws.send(Message::Text(
                serde_json::json!({"endpoints": endpoints})
                    .to_string()
                    .into(),
            ))
            .await
            .map_err(io::Error::other)?;
            return ws.close(None).await.map_err(io::Error::other);
        }
        Route::Session(path, is_relay) => {
            if is_relay {
                return serve_relay_session(ws, path).await;
            }
            path
        }
    };
    // Adapted from Termio's splice. WebSocket messages are transport chunks,
    // never assumed to coincide with OMG's framed messages.
    let daemon = tokio::net::UnixStream::connect(destination).await?;
    let (mut read, mut write) = daemon.into_split();
    let mut buffer = vec![0u8; 64 * 1024];
    let mut ping = tokio::time::interval(Duration::from_secs(15));
    ping.tick().await;
    let mut awaiting_pong = false;
    loop {
        tokio::select! {
            incoming = ws.next() => match incoming {
                Some(Ok(Message::Binary(bytes))) => {
                    tokio::time::timeout(Duration::from_secs(10), write.write_all(&bytes))
                        .await.map_err(io::Error::other)??;
                }
                Some(Ok(Message::Pong(_))) => awaiting_pong = false,
                Some(Ok(Message::Ping(_))) => { ws.flush().await.map_err(io::Error::other)?; }
                Some(Ok(Message::Frame(_))) => {},
                _ => break,
            },
            result = read.read(&mut buffer) => {
                let count = result?;
                if count == 0 { break; }
                tokio::time::timeout(Duration::from_secs(10),
                    ws.send(Message::Binary(buffer[..count].to_vec().into())))
                    .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
            },
            _ = ping.tick() => {
                if awaiting_pong { break; }
                awaiting_pong = true;
                tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Ping(Vec::new().into())))
                    .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
            }
        }
    }
    let _ = write.shutdown().await;
    Ok(())
}

fn take_frame(buffer: &mut Vec<u8>) -> io::Result<Option<omg_session_runtime::Frame>> {
    if buffer.len() < 13 {
        return Ok(None);
    }
    let len = u32::from_be_bytes(buffer[9..13].try_into().unwrap()) as usize;
    if len > omg_session_runtime::MAX_FRAME {
        return Err(io::Error::other("Relay frame exceeds limit"));
    }
    if buffer.len() < 13 + len {
        return Ok(None);
    }
    let kind = buffer[0];
    let seq = u64::from_be_bytes(buffer[1..9].try_into().unwrap());
    let data = buffer[13..13 + len].to_vec();
    buffer.drain(..13 + len);
    Ok(Some(omg_session_runtime::Frame { kind, seq, data }))
}

async fn serve_relay_session(
    mut ws: tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
    relay_socket: PathBuf,
) -> io::Result<()> {
    use omg_session_runtime::Frame;
    let mut ws_buf = Vec::new();
    let mut daemon_buf = Vec::new();
    let mut read_chunk = vec![0u8; 64 * 1024];
    let mut active: Option<(
        u64,
        tokio::net::unix::OwnedReadHalf,
        tokio::net::unix::OwnedWriteHalf,
        u64,
        Option<String>,
    )> = None;
    let mut ping = tokio::time::interval(Duration::from_secs(15));
    ping.tick().await;
    let mut awaiting_pong = false;
    loop {
        tokio::select! {
            incoming = ws.next() => match incoming {
                Some(Ok(Message::Binary(bytes))) => {
                    if ws_buf.len() + bytes.len() > 2 * omg_session_runtime::MAX_FRAME {
                        break;
                    }
                    ws_buf.extend_from_slice(&bytes);
                    while let Some(frame) = take_frame(&mut ws_buf)? {
                        match frame.kind {
                            b'P' if frame.seq == 0 => {
                                let reply = Frame::new(b'P', 0, b"").encode();
                                tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Binary(reply.into())))
                                    .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                            }
                            b'L' if frame.seq == 0 => {
                                let sock = relay_socket.clone();
                                let listed = tokio::time::timeout(
                                    Duration::from_secs(4),
                                    tokio::task::spawn_blocking(move || omg_session_runtime::client::list_local(&sock)),
                                ).await;
                                let out = match listed {
                                    Ok(Ok(Ok(sessions))) => Frame::new(b'L', 0, &serde_json::to_vec(&sessions)?),
                                    Ok(Ok(Err(err))) => Frame::new(b'E', 0, err.to_string().as_bytes()),
                                    _ => Frame::new(b'E', 0, b"SSH relay catalogue timed out"),
                                };
                                tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Binary(out.encode().into())))
                                    .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                            }
                            b'U' if frame.seq != 0 => {
                                active = None;
                                daemon_buf.clear();
                                let req: serde_json::Value = serde_json::from_slice(&frame.data)
                                    .unwrap_or(serde_json::Value::Null);
                                let Some(id) = req["id"].as_str().map(str::to_owned) else {
                                    let err = Frame::new(b'E', frame.seq, b"Invalid attach request").encode();
                                    let _ = ws.send(Message::Binary(err.into())).await;
                                    continue;
                                };
                                let generation = req["generation"].as_str().map(str::to_owned);
                                let open = omg_session_runtime::registry::OpenRequest {
                                    id,
                                    create: false,
                                    policy: Default::default(),
                                    cwd: None,
                                    inline_viewer: false,
                                    launch: None,
                                };
                                match tokio::net::UnixStream::connect(&relay_socket).await {
                                    Ok(stream) => {
                                        let (r, mut w) = stream.into_split();
                                        let payload = Frame::new(b'H', 0, &serde_json::to_vec(&open)?).encode();
                                        tokio::time::timeout(Duration::from_secs(5), w.write_all(&payload))
                                            .await.map_err(io::Error::other)??;
                                        active = Some((frame.seq, r, w, 0, generation));
                                    }
                                    Err(err) => {
                                        let reply = Frame::new(b'E', frame.seq, err.to_string().as_bytes()).encode();
                                        tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Binary(reply.into())))
                                            .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                                    }
                                }
                            }
                            b'Q' => {
                                if active.as_ref().is_some_and(|(sid, _, _, _, _)| *sid == frame.seq) {
                                    active = None;
                                    daemon_buf.clear();
                                }
                            }
                            b'D' => {
                                if let Some((sid, _, ref mut w, peer_gen, _)) = active {
                                    if sid == frame.seq && peer_gen != 0 {
                                        let mut slice = frame.data.as_slice();
                                        let inner = Frame::read(&mut slice)?;
                                        let forwarded = if inner.kind == omg_session_runtime::ACK {
                                            Frame::new(omg_session_runtime::ACK, inner.seq, &peer_gen.to_be_bytes())
                                        } else {
                                            Frame::new(inner.kind, peer_gen, &inner.data)
                                        };
                                        tokio::time::timeout(Duration::from_secs(10), w.write_all(&forwarded.encode()))
                                            .await.map_err(io::Error::other)??;
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }
                Some(Ok(Message::Pong(_))) => awaiting_pong = false,
                Some(Ok(Message::Ping(_))) => { ws.flush().await.map_err(io::Error::other)?; }
                Some(Ok(Message::Frame(_))) => {}
                _ => break,
            },
            result = async {
                match active.as_mut() {
                    Some((_, r, _, _, _)) => r.read(&mut read_chunk).await,
                    None => std::future::pending().await,
                }
            } => {
                let count = result?;
                if count == 0 {
                    if let Some((sid, _, _, _, _)) = active.take() {
                        daemon_buf.clear();
                        let closed = Frame::new(b'Q', sid, &[]).encode();
                        tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Binary(closed.into())))
                            .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                    }
                    continue;
                }
                if daemon_buf.len() + count > 2 * omg_session_runtime::MAX_FRAME {
                    break;
                }
                daemon_buf.extend_from_slice(&read_chunk[..count]);
                let mut drop_stream = false;
                while let Some(frame) = take_frame(&mut daemon_buf)? {
                    let Some((sid, _, _, ref mut peer_gen, ref expected_gen)) = active else {
                        break;
                    };
                    match frame.kind {
                        b'T' => {
                            *peer_gen = frame.seq;
                            if let Ok(status) = serde_json::from_slice::<serde_json::Value>(&frame.data) {
                                if status["state"] == "attention" {
                                    let msg = status["message"].as_str().unwrap_or("SSH relay requires attention");
                                    let reply = Frame::new(b'E', sid, msg.as_bytes()).encode();
                                    tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Binary(reply.into())))
                                        .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                                    drop_stream = true;
                                }
                            }
                        }
                        b'E' => {
                            let reply = Frame::new(b'E', sid, &frame.data).encode();
                            tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Binary(reply.into())))
                                .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                            drop_stream = true;
                        }
                        b'J' => {
                            if let Some(expected) = expected_gen.as_deref() {
                                let actual = serde_json::from_slice::<serde_json::Value>(&frame.data)
                                    .ok()
                                    .and_then(|v| v["generation"].as_str().map(str::to_owned));
                                if actual.as_deref() != Some(expected) {
                                    let reply = Frame::new(b'E', sid, b"Session generation changed").encode();
                                    tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Binary(reply.into())))
                                        .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                                    drop_stream = true;
                                    break;
                                }
                            }
                            let outer = Frame::new(b'D', sid, &frame.encode()).encode();
                            tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Binary(outer.into())))
                                .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                        }
                        b'S' | b'G' | b'M' | b'O' | b'R' | b'W' | b'B' | b'X' => {
                            let outer = Frame::new(b'D', sid, &frame.encode()).encode();
                            tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Binary(outer.into())))
                                .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                        }
                        _ => {}
                    }
                }
                if drop_stream {
                    active = None;
                    daemon_buf.clear();
                }
            }
            _ = ping.tick() => {
                if awaiting_pong { break; }
                awaiting_pong = true;
                tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Ping(Vec::new().into())))
                    .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn token_requires_exact_prefix_and_value() {
        assert_eq!(
            select_subprotocol(Some("other, omg.secret"), "secret"),
            Some("omg.secret".into())
        );
        assert!(select_subprotocol(Some("omg.secreu"), "secret").is_none());
        assert!(select_subprotocol(Some("termiod.secret"), "secret").is_none());
    }

    #[test]
    fn route_accepts_direct_and_reverse_proxy_subpaths_while_rejecting_traversal() {
        let endpoints = vec![Endpoint {
            id: "a1b2c3".into(),
            name: "This Mac".into(),
            socket: PathBuf::from("/tmp/host.sock"),
            relay: None,
        }];
        assert_eq!(parse_route("/control", &endpoints), Some(Route::Control));
        assert_eq!(
            parse_route("/omg/control/", &endpoints),
            Some(Route::Control)
        );
        assert_eq!(
            parse_route("/catalogue", &endpoints),
            Some(Route::Catalogue)
        );
        assert_eq!(
            parse_route("/omg/ws/a1b2c3", &endpoints),
            Some(Route::Session(PathBuf::from("/tmp/host.sock"), false))
        );
        assert_eq!(parse_route("/omg/../control", &endpoints), None);
        assert_eq!(parse_route("/ws/not-hex!", &endpoints), None);
    }

    #[test]
    fn allows_private_loopback_and_tailscale_cgnat_ipv4() {
        assert!(is_allowed_listen_ipv4("127.0.0.1".parse().unwrap()));
        assert!(is_allowed_listen_ipv4("10.24.34.144".parse().unwrap()));
        assert!(is_allowed_listen_ipv4("192.168.1.20".parse().unwrap()));
        assert!(is_allowed_listen_ipv4("100.64.0.1".parse().unwrap()));
        assert!(is_allowed_listen_ipv4("100.127.255.254".parse().unwrap()));
        assert!(!is_allowed_listen_ipv4("100.63.255.255".parse().unwrap()));
        assert!(!is_allowed_listen_ipv4("100.128.0.1".parse().unwrap()));
        assert!(!is_allowed_listen_ipv4("119.29.60.90".parse().unwrap()));
    }

    #[test]
    fn validates_public_urls_and_enforces_tls_on_public_hosts() {
        assert_eq!(
            validate_public_url("ws://192.168.1.50:8791/").unwrap(),
            "ws://192.168.1.50:8791"
        );
        assert_eq!(
            validate_public_url("ws://100.88.1.2:8791").unwrap(),
            "ws://100.88.1.2:8791"
        );
        assert_eq!(
            validate_public_url("wss://devbox.example.com/omg/").unwrap(),
            "wss://devbox.example.com/omg"
        );
        assert!(validate_public_url("ws://devbox.example.com:8791").is_err());
        assert!(validate_public_url("https://devbox.example.com").is_err());
        assert!(validate_public_url("wss://user:pass@devbox.example.com").is_err());
    }
}
