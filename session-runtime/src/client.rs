//! Persistent local client endpoint with one reconnecting transport per host.
use crate::{
    host::{self, inner_frame},
    record::SessionSummary,
    registry::OpenRequest,
    Frame, Peer, ACK, CLAIM, CLOSE, EXIT, INPUT, MAX_FRAME, RESIZE, SNAPSHOT,
};
use std::{
    collections::HashMap,
    io,
    os::unix::net::{UnixListener, UnixStream},
    path::Path,
    sync::{mpsc, Arc},
    thread,
    time::{Duration, Instant},
};

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(45);
const PEER_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const PARENT_ALIVE_PEER_IDLE_TIMEOUT: Duration = Duration::from_secs(3600);
const STABLE_RESET: Duration = Duration::from_secs(60);
const RECREATE_GRANT_TTL: Duration = Duration::from_secs(60);
const MAX_PEERS: usize = 512;
const MAX_LIST_WAITERS: usize = 3;
const LIST_REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

fn default_recreate_version() -> String {
    "recreate/1".into()
}

#[derive(Clone, Debug, Default, serde::Deserialize, serde::Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RecreateRequest {
    #[serde(default = "default_recreate_version")]
    pub version: String,
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cols: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pixel_width: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pixel_height: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub term: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub colorterm: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub term_program: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub term_program_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_scheme: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreground: Option<[u8; 3]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<[u8; 3]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<[u8; 3]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<crate::record::Resume>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interactive: Option<bool>,
}

impl RecreateRequest {
    pub fn validate(&self) -> io::Result<()> {
        if self.version != "recreate/1" || !host::valid_id(&self.id) {
            return Err(io::Error::other("invalid recreate request identity"));
        }
        if let Some(cwd) = &self.cwd {
            if !cwd.starts_with('/') || cwd.len() > 4096 || cwd.contains('\0') {
                return Err(io::Error::other(
                    "invalid recreate request working directory",
                ));
            }
        }
        if self.cols.is_some_and(|c| c == 0 || c > 500)
            || self.rows.is_some_and(|r| r == 0 || r > 300)
            || self.pixel_width.is_some_and(|w| w > 16_000)
            || self.pixel_height.is_some_and(|h| h > 16_000)
            || !valid_recreate_header(self.term.as_deref())
            || !valid_recreate_header(self.colorterm.as_deref())
            || !valid_recreate_header(self.term_program.as_deref())
            || !valid_recreate_header(self.term_program_version.as_deref())
            || !valid_recreate_header(self.color_scheme.as_deref())
        {
            return Err(io::Error::other(
                "invalid recreate request terminal options",
            ));
        }
        if let Some(resume) = &self.resume {
            resume.validate()?;
        }
        Ok(())
    }
}

fn valid_recreate_header(value: Option<&str>) -> bool {
    value.is_none_or(|s| s.len() <= 128 && !s.chars().any(char::is_control))
}

fn parse_recreate_request(data: &[u8]) -> io::Result<RecreateRequest> {
    if data.len() > 64 * 1024 {
        return Err(io::Error::other("recreate request exceeds limit"));
    }
    let body = data
        .strip_prefix(b"recreate/1\n")
        .or_else(|| data.strip_prefix(b"recreate/1 "))
        .unwrap_or(data);
    let request: RecreateRequest = serde_json::from_slice(body)
        .map_err(|_| io::Error::other("invalid recreate request payload"))?;
    request.validate()?;
    Ok(request)
}

struct RecreateGrant {
    request: RecreateRequest,
    expires_at: Instant,
    legacy_create_sent: bool,
}

pub struct RelayTransport {
    pub socket: UnixStream,
    pub guard: Box<dyn Send>,
}

pub type Connector = Arc<dyn Fn(bool) -> io::Result<RelayTransport> + Send + Sync>;

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Connecting,
    Reconnecting,
    Online,
    Attention,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            Self::Connecting => "connecting",
            Self::Reconnecting => "reconnecting",
            Self::Online => "connecting",
            Self::Attention => "attention",
        }
    }
}

struct LocalPeer {
    peer: Peer,
    generation: u64,
    session_id: Option<String>,
    open: Option<Vec<u8>>,
    initial_create: bool,
    recreate_if_gone: bool,
    recreate_fallback_used: bool,
    hold_on_session_gone: bool,
    session_gone: bool,
    remote_stream: Option<u64>,
    snapshot_generation: Option<u64>,
    snapshot_confirmed: bool,
    snapshot_acked: bool,
    writer_requested: bool,
    writer_ready: bool,
    retry_requested: bool,
    failed: bool,
    ended: bool,
    control: bool,
    control_done: bool,
    exec_stream: bool,
    close_id: Option<String>,
    list_requested: bool,
}

impl LocalPeer {
    fn new(peer: Peer, generation: u64) -> Self {
        Self {
            peer,
            generation,
            session_id: None,
            open: None,
            initial_create: false,
            recreate_if_gone: false,
            recreate_fallback_used: false,
            hold_on_session_gone: false,
            session_gone: false,
            remote_stream: None,
            snapshot_generation: None,
            snapshot_confirmed: false,
            snapshot_acked: false,
            writer_requested: false,
            writer_ready: false,
            retry_requested: false,
            failed: false,
            ended: false,
            control: false,
            control_done: false,
            exec_stream: false,
            close_id: None,
            list_requested: false,
        }
    }
}

#[derive(Default)]
struct RemoteCapabilities {
    received: bool,
    strict_open: bool,
    durable_close: bool,
    local_launch: bool,
    local_resurrect: bool,
    inline_viewer: bool,
    recreate_if_gone: bool,
    exec: bool,
    init_size: bool,
    remote_env: bool,
    handoff_resume: bool,
}

impl RemoteCapabilities {
    fn reset(&mut self) {
        *self = Self::default();
    }

    fn update(&mut self, data: &[u8]) {
        self.received = true;
        self.strict_open = has_capability(data, "strict-open/1");
        self.durable_close = has_capability(data, "durable-close/1");
        self.local_launch = has_capability(data, "local-launch/1");
        self.local_resurrect = has_capability(data, "local-resurrect/1");
        self.inline_viewer = has_capability(data, "inline-viewer/1");
        self.recreate_if_gone = has_capability(data, "recreate-if-gone/1");
        self.exec = has_capability(data, "exec/1");
        self.init_size = has_capability(data, "init-size/1");
        self.remote_env = has_capability(data, "remote-env/1");
        self.handoff_resume = has_capability(data, "handoff-resume/1");
    }
}

fn is_active_peer(p: &LocalPeer) -> bool {
    !p.ended
        && (!p.control
            || p.close_id.is_some() && !p.control_done
            || p.list_requested && !p.control_done
            || p.exec_stream && !p.control_done)
}

fn next_generation(generation: u64) -> u64 {
    generation.wrapping_add(1).max(1)
}

fn retry_delay(attempt: u32) -> Duration {
    let exponent = attempt.saturating_sub(1).min(6);
    Duration::from_millis((500u64 << exponent).min(30_000))
}

fn has_capability(data: &[u8], capability: &str) -> bool {
    std::str::from_utf8(data).is_ok_and(|text| text.split(',').any(|item| item == capability))
}

fn status_frame(
    generation: u64,
    state: State,
    attempt: u32,
    retry_in: Option<Duration>,
    message: Option<&str>,
) -> Frame {
    let mut value = serde_json::json!({
        "state": state.name(),
        "attempt": attempt,
    });
    if let Some(delay) = retry_in {
        value["retry_in_ms"] = serde_json::json!(delay.as_millis().min(u64::MAX as u128) as u64);
    }
    if let Some(message) = message {
        value["message"] = serde_json::json!(message);
    }
    Frame::new(b'T', generation, value.to_string().as_bytes())
}

fn status_frame_session_gone(generation: u64, attempt: u32, message: Option<&str>) -> Frame {
    let mut value = serde_json::json!({
        "state": "session_gone",
        "session_gone": true,
        "attempt": attempt,
    });
    if let Some(message) = message {
        value["message"] = serde_json::json!(message);
    }
    Frame::new(b'T', generation, value.to_string().as_bytes())
}

fn sanitize_status_message(data: &[u8]) -> String {
    String::from_utf8_lossy(data)
        .chars()
        .take(512)
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect()
}

fn set_status(
    peers: &mut HashMap<u64, LocalPeer>,
    state: State,
    attempt: u32,
    retry_in: Option<Duration>,
    message: Option<&str>,
) {
    for peer in peers
        .values_mut()
        .filter(|p| !p.control && !p.ended && (!p.failed || p.retry_requested))
    {
        peer.peer.push(status_frame(
            peer.generation,
            state,
            attempt,
            retry_in,
            message,
        ));
    }
}

fn set_peer_status(peer: &mut LocalPeer, attempt: u32) {
    if !peer.control && !peer.ended {
        peer.peer.push(status_frame(
            peer.generation,
            State::Connecting,
            attempt,
            None,
            None,
        ));
    }
}

#[cfg(test)]
fn open_request(peer: &LocalPeer, capabilities: &RemoteCapabilities) -> io::Result<(u8, Vec<u8>)> {
    let mut empty = HashMap::new();
    open_request_with_grants(peer, capabilities, &mut empty, Instant::now())
}

fn open_request_with_grants(
    peer: &LocalPeer,
    capabilities: &RemoteCapabilities,
    recreate_grants: &mut HashMap<String, RecreateGrant>,
    now: Instant,
) -> io::Result<(u8, Vec<u8>)> {
    let bytes = peer
        .open
        .as_ref()
        .ok_or_else(|| io::Error::other("missing open request"))?;
    let mut request: OpenRequest = serde_json::from_slice(bytes)?;
    request.hold_on_session_gone = false;
    let allow_local_resurrect = capabilities.local_launch && capabilities.local_resurrect;
    let allow_recreate_if_gone = capabilities.recreate_if_gone;
    let active_grant = if !capabilities.local_launch {
        recreate_grants
            .get_mut(&request.id)
            .filter(|grant| grant.expires_at > now)
    } else {
        None
    };

    let mut using_grant = false;
    if let Some(grant) = active_grant {
        if allow_recreate_if_gone
            || (capabilities.received && !allow_recreate_if_gone && !grant.legacy_create_sent)
        {
            using_grant = true;
            if grant.request.cwd.is_some() {
                request.cwd = grant.request.cwd.clone();
            }
            request.cols = grant.request.cols;
            request.rows = grant.request.rows;
            request.pixel_width = grant.request.pixel_width;
            request.pixel_height = grant.request.pixel_height;
            request.term = grant.request.term.clone();
            request.colorterm = grant.request.colorterm.clone();
            request.term_program = grant.request.term_program.clone();
            request.term_program_version = grant.request.term_program_version.clone();
            request.color_scheme = grant.request.color_scheme.clone();
            request.foreground = grant.request.foreground;
            request.background = grant.request.background;
            request.cursor = grant.request.cursor;
            request.resume = grant.request.resume.clone();
            if allow_recreate_if_gone {
                request.create = false;
                request.recreate_if_gone = true;
            } else {
                grant.legacy_create_sent = true;
                request.create = true;
                request.recreate_if_gone = false;
            }
            request.launch = None;
            request.resurrect_launch = None;
        }
    }

    if !using_grant {
        // A snapshot-confirmed session is attach-only. An unconfirmed initial create
        // may still retry create=true after transient pre-open errors.
        request.create = request.create && !peer.snapshot_confirmed;
        request.recreate_if_gone =
            request.recreate_if_gone && !peer.snapshot_confirmed && allow_recreate_if_gone;
        if !request.create {
            request.launch = None;
        }
        if request.create || peer.snapshot_confirmed || !allow_local_resurrect {
            request.resurrect_launch = None;
        }
    }

    let spawns_session = request.create || request.recreate_if_gone;
    let suppress_spawn_fields = peer.snapshot_confirmed && !using_grant;
    if !capabilities.init_size || suppress_spawn_fields || !spawns_session {
        request.clear_init_size();
    }
    if !capabilities.remote_env || suppress_spawn_fields || !spawns_session {
        request.clear_remote_env();
    }
    if !capabilities.handoff_resume || suppress_spawn_fields || !spawns_session {
        request.resume = None;
    }
    Ok((b'C', serde_json::to_vec(&request)?))
}

fn is_session_gone_error(data: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(data) else {
        return false;
    };
    let lower = text.to_ascii_lowercase();
    !lower.contains("local session ended")
        && (lower.contains("unknown session") || lower.contains("session ended"))
}

fn clear_launch_data(peer: &mut LocalPeer, clear_resurrect: bool) {
    let Some(bytes) = peer.open.as_ref() else {
        return;
    };
    let Ok(mut request) = serde_json::from_slice::<OpenRequest>(bytes) else {
        return;
    };
    request.create = false;
    request.launch = None;
    request.recreate_if_gone = false;
    request.resume = None;
    request.clear_remote_options();
    if clear_resurrect {
        request.resurrect_launch = None;
    }
    if let Ok(bytes) = serde_json::to_vec(&request) {
        peer.open = Some(bytes);
    }
}

fn begin_list(remote: &mut Peer, peers: &HashMap<u64, LocalPeer>, in_flight: &mut bool) {
    if !*in_flight
        && peers
            .values()
            .any(|peer| peer.list_requested && !peer.control_done)
    {
        remote.push(Frame::new(b'L', 0, &[]));
        *in_flight = true;
    }
}

fn begin_open(
    remote: &mut Peer,
    peers: &mut HashMap<u64, LocalPeer>,
    remote_streams: &mut HashMap<u64, u64>,
    next_stream: &mut u64,
    capabilities: &RemoteCapabilities,
    recreate_grants: &mut HashMap<String, RecreateGrant>,
) -> io::Result<()> {
    let now = Instant::now();
    let ids: Vec<_> = peers
        .iter()
        .filter(|(_, p)| {
            !p.control
                && !p.ended
                && p.open.is_some()
                && p.remote_stream.is_none()
                && (!p.failed || p.retry_requested)
        })
        .map(|(id, _)| *id)
        .collect();
    for id in ids {
        let (kind, data) = {
            let peer = peers.get(&id).unwrap();
            open_request_with_grants(peer, capabilities, recreate_grants, now)?
        };
        let stream = *next_stream;
        *next_stream = next_generation(*next_stream);
        remote_streams.insert(stream, id);
        peers.get_mut(&id).unwrap().remote_stream = Some(stream);
        peers.get_mut(&id).unwrap().snapshot_generation = None;
        peers.get_mut(&id).unwrap().snapshot_acked = false;
        remote.push(Frame::new(kind, stream, &data));
    }
    Ok(())
}

fn begin_controls(
    remote: &mut Peer,
    peers: &mut HashMap<u64, LocalPeer>,
    remote_streams: &mut HashMap<u64, u64>,
    next_stream: &mut u64,
) {
    let ids: Vec<_> = peers
        .iter()
        .filter(|(_, p)| p.control && p.close_id.is_some() && p.remote_stream.is_none())
        .map(|(id, _)| *id)
        .collect();
    for id in ids {
        let peer = peers.get_mut(&id).unwrap();
        let stream = *next_stream;
        *next_stream = next_generation(*next_stream);
        remote_streams.insert(stream, id);
        peer.remote_stream = Some(stream);
        remote.push(Frame::new(
            b'K',
            stream,
            peer.close_id.as_deref().unwrap().as_bytes(),
        ));
    }
}

fn attention_required(error: &io::Error) -> bool {
    let text = error.to_string().to_ascii_lowercase();
    [
        "permission denied",
        "host key verification failed",
        "remote host identification has changed",
        "bad configuration option",
        "unknown option",
        "no matching host key type",
        "no matching key exchange method",
        "too many authentication failures",
        "load key",
        "unsupported ssh host",
        "runtime revision unavailable",
        "cannot stat",
        "not a directory",
    ]
    .iter()
    .any(|marker| text.contains(marker))
}

fn send_outer_open(remote: &mut Peer, id: u64, kind: u8, data: &[u8]) {
    remote.push(Frame::new(kind, id, data));
}

fn discard_queued_output(peer: &mut Peer) {
    peer.discard_queued_output();
}

fn reset_remote_streams(peers: &mut HashMap<u64, LocalPeer>, discard_output: bool) {
    for peer in peers.values_mut() {
        peer.remote_stream = None;
        peer.snapshot_generation = None;
        peer.snapshot_acked = false;
        peer.writer_requested = false;
        peer.writer_ready = false;
        if peer.exec_stream && !peer.control_done {
            peer.peer.push(Frame::new(b'E', 0, b"exec-disconnected"));
            peer.control_done = true;
        } else if !peer.failed && !peer.ended && !peer.control {
            peer.retry_requested = false;
            if discard_output {
                discard_queued_output(&mut peer.peer);
            }
        }
    }
}

fn advance_peer_generations(peers: &mut HashMap<u64, LocalPeer>, generation_counter: &mut u64) {
    for peer in peers
        .values_mut()
        .filter(|p| !p.control && !p.ended && !p.failed)
    {
        *generation_counter = next_generation(*generation_counter);
        peer.generation = *generation_counter;
    }
}

fn effective_idle_timeout(initial_ppid: libc::pid_t) -> Duration {
    #[cfg(unix)]
    let parent_alive = initial_ppid > 1 && unsafe { libc::getppid() } == initial_ppid;
    #[cfg(not(unix))]
    let parent_alive = {
        let _ = initial_ppid;
        false
    };
    if parent_alive {
        PARENT_ALIVE_PEER_IDLE_TIMEOUT
    } else {
        PEER_IDLE_TIMEOUT
    }
}

/// Bind the stable local endpoint before starting any network or deployment
/// work. Local Ghostty surfaces therefore survive every SSH transport attempt.
pub fn supervise(local: &Path, connector: Connector, interactive_first: bool) -> io::Result<()> {
    supervise_with_timeouts(
        local,
        connector,
        interactive_first,
        HEARTBEAT_INTERVAL,
        HEARTBEAT_TIMEOUT,
    )
}

fn supervise_with_timeouts(
    local: &Path,
    connector: Connector,
    interactive_first: bool,
    heartbeat_interval: Duration,
    heartbeat_timeout: Duration,
) -> io::Result<()> {
    #[cfg(unix)]
    let initial_ppid = unsafe { libc::getppid() };
    #[cfg(not(unix))]
    let initial_ppid: libc::pid_t = 0;
    host::private(
        local
            .parent()
            .ok_or_else(|| io::Error::other("missing socket parent"))?,
    )?;
    let listener = UnixListener::bind(local)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(local, std::fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let nonce = crate::record::nonce()?;
    let initial_generation = u64::from_str_radix(&nonce[..16], 16)
        .map_err(io::Error::other)?
        .max(1);

    let mut peers: HashMap<u64, LocalPeer> = HashMap::new();
    let mut recreate_grants: HashMap<String, RecreateGrant> = HashMap::new();
    let mut next_peer = 1u64;
    let mut next_stream = 1u64;
    let mut remote_streams: HashMap<u64, u64> = HashMap::new();
    let mut remote: Option<Peer> = None;
    let mut _transport_guard: Option<Box<dyn Send>> = None;
    let mut capabilities = RemoteCapabilities::default();
    let mut list_in_flight = false;
    let mut generation_counter = initial_generation;
    let mut state = State::Connecting;
    let mut attempt = 0u32;
    let mut retry_at = Instant::now();
    let mut stable_since: Option<Instant> = None;
    let mut last_heartbeat = Instant::now() - heartbeat_interval;
    let mut last_pong = Instant::now();
    let mut had_transport = false;
    let mut interactive_next = interactive_first;
    let mut attempt_pending = false;
    let mut attempt_rx = None;
    let mut attempt_tx_id = 0u64;
    let mut idle_since = Instant::now();
    let wake = crate::WakePipe::new()?;

    loop {
        wake.drain();
        let now_loop = Instant::now();
        recreate_grants.retain(|_, grant| grant.expires_at > now_loop);
        let idle_timeout = effective_idle_timeout(initial_ppid);
        if peers.values().any(is_active_peer) || !recreate_grants.is_empty() {
            idle_since = Instant::now();
        } else if idle_since.elapsed() > idle_timeout {
            return Ok(());
        }

        if remote.is_some() {
            if let Some(since) = stable_since {
                if since.elapsed() >= STABLE_RESET {
                    attempt = 0;
                    stable_since = None;
                }
            }
        }

        if remote.is_some() && last_pong.elapsed() > heartbeat_timeout {
            remote = None;
            _transport_guard = None;
            remote_streams.clear();
            reset_remote_streams(&mut peers, true);
            list_in_flight = false;
            capabilities.reset();
            advance_peer_generations(&mut peers, &mut generation_counter);
            stable_since = None;
            state = State::Reconnecting;
            let delay = retry_delay(attempt.max(1));
            set_status(&mut peers, state, attempt, Some(delay), None);
            retry_at = Instant::now() + delay;
            had_transport = true;
        }

        if !attempt_pending && remote.is_none() && Instant::now() >= retry_at {
            attempt += 1;
            attempt_tx_id = next_generation(attempt_tx_id);
            let attempt_id = attempt_tx_id;
            let connect = connector.clone();
            let interactive = interactive_next;
            interactive_next = false;
            let (tx, rx) = mpsc::channel();
            let wake_attempt = wake.clone();
            thread::spawn(move || {
                struct NotifyOnDrop(crate::WakePipe);
                impl Drop for NotifyOnDrop {
                    fn drop(&mut self) {
                        self.0.notify();
                    }
                }
                let _notify = NotifyOnDrop(wake_attempt);
                let _ = tx.send((attempt_id, connect(interactive)));
            });
            attempt_rx = Some(rx);
            attempt_pending = true;
            state = if had_transport {
                State::Reconnecting
            } else {
                State::Connecting
            };
            set_status(&mut peers, state, attempt, None, None);
        }

        if let Some(rx) = &attempt_rx {
            match rx.try_recv() {
                Ok((id, result)) if id == attempt_tx_id => {
                    attempt_pending = false;
                    attempt_rx = None;
                    match result {
                        Ok(transport) => {
                            let peer = Peer::new(transport.socket, 0)?;
                            _transport_guard = Some(transport.guard);
                            remote_streams.clear();
                            next_stream = 1;
                            remote = Some(peer);
                            last_pong = Instant::now();
                            capabilities.reset();
                            list_in_flight = false;
                            remote.as_mut().unwrap().push(Frame::new(b'P', 0, &[]));
                            last_heartbeat = Instant::now();
                            stable_since = None;
                            had_transport = true;
                            state = State::Online;
                            for peer in peers.values_mut().filter(|p| {
                                !p.control && !p.ended && (!p.failed || p.retry_requested)
                            }) {
                                if peer.open.is_some() {
                                    peer.peer.push(status_frame(
                                        peer.generation,
                                        State::Connecting,
                                        attempt,
                                        None,
                                        None,
                                    ));
                                }
                            }
                        }
                        Err(error) => {
                            let attention = attention_required(&error);
                            let detail = error.to_string();
                            let detail = detail
                                .strip_prefix("SSH runtime setup failed: ")
                                .or_else(|| detail.strip_prefix("SSH runtime reconnect failed: "))
                                .unwrap_or(&detail);
                            let detail: String = detail
                                .chars()
                                .take(512)
                                .map(|c| if c.is_control() { ' ' } else { c })
                                .collect();
                            state = if attention {
                                State::Attention
                            } else {
                                State::Reconnecting
                            };
                            let delay = retry_delay(attempt.max(1));
                            set_status(
                                &mut peers,
                                state,
                                attempt,
                                (!attention).then_some(delay),
                                attention.then_some(detail.as_str()),
                            );
                            if attention {
                                retry_at = Instant::now() + Duration::from_secs(365 * 24 * 3600);
                            } else {
                                retry_at = Instant::now() + delay;
                            }
                            eprintln!("session runtime connect failed: {error}");
                        }
                    }
                }
                Ok(_) => {}
                Err(mpsc::TryRecvError::Empty) => {}
                Err(mpsc::TryRecvError::Disconnected) => {
                    attempt_pending = false;
                    attempt_rx = None;
                    state = State::Attention;
                    set_status(
                        &mut peers,
                        state,
                        attempt,
                        None,
                        Some("The connection attempt could not be started."),
                    );
                    retry_at = Instant::now() + Duration::from_secs(365 * 24 * 3600);
                }
            }
        }

        for _ in 0..8 {
            match listener.accept() {
                Ok((socket, _)) if peers.len() < MAX_PEERS => {
                    generation_counter = next_generation(generation_counter);
                    let mut peer =
                        LocalPeer::new(Peer::new(socket, next_peer)?, generation_counter);
                    next_peer = next_generation(next_peer);
                    peer.peer
                        .push(status_frame(peer.generation, state, attempt, None, None));
                    peers.insert(peer.peer.id, peer);
                }
                Ok((_socket, _)) => {}
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error),
            }
        }

        let ids: Vec<_> = peers.keys().copied().collect();
        let mut manual_retry = None;
        let mut manual_recreate: Vec<(String, bool)> = Vec::new();
        for id in ids {
            let list_waiters = peers
                .values()
                .filter(|candidate| candidate.list_requested && !candidate.control_done)
                .count();
            let has_failed_stream = peers.values().any(|p| !p.control && p.failed && !p.ended);
            let has_observer = peers.values().any(|p| {
                !p.control
                    && !p.failed
                    && !p.ended
                    && p.snapshot_acked
                    && p.remote_stream.is_some()
                    && !p.writer_ready
            });
            let Some(peer) = peers.get_mut(&id) else {
                continue;
            };
            match peer.peer.read() {
                Ok(frames) => {
                    for frame in frames {
                        if peer.control && !peer.exec_stream {
                            continue;
                        }
                        if peer.exec_stream {
                            if peer.control_done {
                                continue;
                            }
                            if matches!(frame.kind, b'i' | b'z') {
                                if frame.data.len() > MAX_FRAME.saturating_sub(13) {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"exec input frame too large",
                                    ));
                                    peer.control_done = true;
                                } else if let (Some(remote), Some(stream)) =
                                    (remote.as_mut(), peer.remote_stream)
                                {
                                    remote.push(Frame::new(b'D', stream, &frame.encode()));
                                }
                            }
                            continue;
                        }
                        if peer.open.is_none() {
                            if frame.kind == b'x' {
                                peer.control = true;
                                peer.exec_stream = true;
                                match remote.as_mut() {
                                    Some(remote_peer)
                                        if state == State::Online && capabilities.received =>
                                    {
                                        if !capabilities.exec {
                                            peer.peer.push(Frame::new(
                                                b'E',
                                                0,
                                                b"exec-unsupported",
                                            ));
                                            peer.control_done = true;
                                        } else if frame.seq != 0
                                            || frame.data.len() > MAX_FRAME
                                            || serde_json::from_slice::<host::ExecOpen>(&frame.data)
                                                .is_err()
                                        {
                                            peer.peer.push(Frame::new(
                                                b'E',
                                                0,
                                                b"invalid exec request",
                                            ));
                                            peer.control_done = true;
                                        } else {
                                            let mut stream = next_stream;
                                            while remote_streams.contains_key(&stream) {
                                                stream = next_generation(stream);
                                            }
                                            next_stream = next_generation(stream);
                                            peer.remote_stream = Some(stream);
                                            remote_streams.insert(stream, id);
                                            remote_peer.push(Frame::new(b'x', stream, &frame.data));
                                        }
                                    }
                                    _ => {
                                        peer.peer.push(Frame::new(b'E', 0, b"relay-offline"));
                                        peer.control_done = true;
                                    }
                                }
                                continue;
                            }
                            if frame.kind == b'L' {
                                peer.control = true;
                                if frame.seq != 0 || !frame.data.is_empty() {
                                    peer.peer.push(Frame::new(b'E', 0, b"invalid list request"));
                                    peer.control_done = true;
                                } else if list_waiters >= MAX_LIST_WAITERS {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"too many pending catalogue requests",
                                    ));
                                    peer.control_done = true;
                                } else {
                                    peer.list_requested = true;
                                }
                                continue;
                            }
                            if frame.kind == b'y' {
                                peer.control = true;
                                let interactive = frame.data == b"interactive/1";
                                if frame.seq == 0 && !frame.data.is_empty() && !interactive {
                                    match parse_recreate_request(&frame.data) {
                                        Ok(req) => {
                                            let interactive_flag = req.interactive.unwrap_or(true);
                                            let target_id = req.id.clone();
                                            recreate_grants.insert(
                                                target_id.clone(),
                                                RecreateGrant {
                                                    request: req,
                                                    expires_at: Instant::now() + RECREATE_GRANT_TTL,
                                                    legacy_create_sent: false,
                                                },
                                            );
                                            manual_recreate.push((target_id, interactive_flag));
                                            peer.peer.push(Frame::new(
                                                b'y',
                                                peer.generation,
                                                b"accepted",
                                            ));
                                        }
                                        Err(_) => {
                                            peer.peer.push(Frame::new(
                                                b'y',
                                                peer.generation,
                                                b"invalid request",
                                            ));
                                        }
                                    }
                                    peer.control_done = true;
                                } else if frame.seq != 0 || (!frame.data.is_empty() && !interactive)
                                {
                                    peer.peer.push(Frame::new(
                                        b'y',
                                        peer.generation,
                                        b"invalid request",
                                    ));
                                    peer.control_done = true;
                                } else if !attempt_pending
                                    && (state != State::Online || has_failed_stream || has_observer)
                                {
                                    manual_retry = Some(interactive);
                                    peer.peer
                                        .push(Frame::new(b'y', peer.generation, b"accepted"));
                                    peer.control_done = true;
                                } else if attempt_pending && (has_failed_stream || has_observer) {
                                    manual_retry = Some(interactive);
                                    peer.peer.push(Frame::new(
                                        b'y',
                                        peer.generation,
                                        b"connect attempt already running",
                                    ));
                                    peer.control_done = true;
                                } else {
                                    peer.peer.push(Frame::new(
                                        b'y',
                                        peer.generation,
                                        if attempt_pending {
                                            &b"connect attempt already running"[..]
                                        } else {
                                            &b"endpoint online"[..]
                                        },
                                    ));
                                    peer.control_done = true;
                                }
                                continue;
                            }
                            if frame.kind == CLOSE
                                && frame.data.len() == 36
                                && std::str::from_utf8(&frame.data).is_ok_and(host::valid_id)
                            {
                                peer.control = true;
                                let close_id =
                                    String::from_utf8(frame.data).expect("validated UUID");
                                recreate_grants.remove(&close_id);
                                peer.close_id = Some(close_id);
                                if capabilities.received && !capabilities.durable_close {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"remote runtime does not support confirmed close",
                                    ));
                                    peer.control_done = true;
                                }
                                continue;
                            }
                            if frame.kind != b'H' || frame.data.len() > MAX_FRAME {
                                peer.peer.push(Frame::new(b'E', 0, b"invalid open request"));
                                peer.failed = true;
                                continue;
                            }
                            match serde_json::from_slice::<OpenRequest>(&frame.data) {
                                Ok(request) if host::valid_id(&request.id) => {
                                    peer.session_id = Some(request.id.clone());
                                    peer.initial_create = request.create;
                                    peer.recreate_if_gone = request.recreate_if_gone;
                                    peer.recreate_fallback_used = false;
                                    peer.hold_on_session_gone = request.hold_on_session_gone;
                                    peer.session_gone = false;
                                    peer.open = Some(frame.data);
                                    if capabilities.received
                                        && request.launch.is_some()
                                        && !capabilities.local_launch
                                    {
                                        peer.failed = true;
                                        peer.peer.push(Frame::new(
                                            b'E',
                                            0,
                                            b"runtime does not support persistent local launches; no session was created",
                                        ));
                                    } else if capabilities.received
                                        && request.inline_viewer
                                        && !capabilities.inline_viewer
                                    {
                                        peer.failed = true;
                                        peer.peer.push(Frame::new(b'E', 0,
                                            b"runtime does not support inline viewers; no session was created"));
                                    } else if capabilities.received && !capabilities.strict_open {
                                        peer.failed = true;
                                        peer.peer.push(Frame::new(
                                            b'E',
                                            0,
                                            b"remote runtime is too old for safe session attach; remote process was preserved",
                                        ));
                                    }
                                }
                                _ => {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"invalid session open request",
                                    ));
                                    peer.failed = true;
                                }
                            }
                            continue;
                        }

                        if peer.ended || peer.control_done {
                            continue;
                        }
                        if frame.kind == b'y' {
                            if (frame.seq == 0 || frame.seq == peer.generation)
                                && !frame.data.is_empty()
                            {
                                if let Ok(req) = parse_recreate_request(&frame.data) {
                                    if peer.session_id.as_deref() == Some(req.id.as_str()) {
                                        let interactive_flag = req.interactive.unwrap_or(true);
                                        let target_id = req.id.clone();
                                        recreate_grants.insert(
                                            target_id.clone(),
                                            RecreateGrant {
                                                request: req,
                                                expires_at: Instant::now() + RECREATE_GRANT_TTL,
                                                legacy_create_sent: false,
                                            },
                                        );
                                        manual_recreate.push((target_id, interactive_flag));
                                    }
                                }
                            }
                            continue;
                        }
                        if frame.kind == ACK {
                            if frame.data.len() != 8
                                || u64::from_be_bytes(frame.data[..8].try_into().unwrap())
                                    != peer.generation
                                || peer.snapshot_generation != Some(peer.generation)
                                || peer.remote_stream.is_none()
                                || state != State::Online
                            {
                                continue;
                            }
                            peer.snapshot_acked = true;
                        } else if frame.kind == crate::ACKNOWLEDGE {
                            if frame.seq != peer.generation
                                || !(frame.data.is_empty() || frame.data.len() == 8)
                                || state != State::Online
                                || peer.remote_stream.is_none()
                                || !peer.snapshot_acked
                            {
                                continue;
                            }
                        } else if matches!(frame.kind, INPUT | RESIZE | CLAIM | CLOSE) {
                            if frame.seq != peer.generation
                                || state != State::Online
                                || peer.remote_stream.is_none()
                                || !peer.writer_ready && frame.kind != CLAIM
                            {
                                continue;
                            }
                            if frame.kind == CLAIM {
                                if peer.snapshot_generation != Some(peer.generation)
                                    || !peer.snapshot_acked
                                {
                                    continue;
                                }
                                peer.writer_requested = true;
                                peer.writer_ready = false;
                            }
                        } else {
                            continue;
                        }
                        if let (Some(remote), Some(stream)) = (remote.as_mut(), peer.remote_stream)
                        {
                            remote.push(Frame::new(b'D', stream, &frame.encode()));
                        }
                    }
                }
                Err(_) => peer.peer.dead = true,
            }
        }

        for (target_id, interactive) in manual_recreate {
            let matched: Vec<_> = peers
                .iter_mut()
                .filter(|(_, p)| {
                    !p.control
                        && !p.ended
                        && p.open.is_some()
                        && p.remote_stream.is_none()
                        && p.session_id.as_deref() == Some(target_id.as_str())
                })
                .map(|(id, p)| {
                    p.failed = true;
                    p.session_gone = false;
                    p.retry_requested = true;
                    p.writer_requested = false;
                    p.writer_ready = false;
                    p.recreate_fallback_used = false;
                    *id
                })
                .collect();
            for id in &matched {
                if let Some(peer) = peers.get_mut(id) {
                    generation_counter = next_generation(generation_counter);
                    peer.generation = generation_counter;
                    set_peer_status(peer, attempt);
                }
            }
            if let Some(remote) = remote.as_mut() {
                let now_open = Instant::now();
                for id in &matched {
                    if let Some(peer) = peers.get_mut(id) {
                        if !capabilities.received {
                            continue;
                        }
                        if !capabilities.strict_open {
                            peer.retry_requested = false;
                            peer.peer.push(Frame::new(
                                b'E',
                                0,
                                b"remote runtime is too old for safe session attach; remote process was preserved",
                            ));
                            continue;
                        }
                        match open_request_with_grants(
                            peer,
                            &capabilities,
                            &mut recreate_grants,
                            now_open,
                        ) {
                            Ok((kind, data)) => {
                                let stream = next_stream;
                                next_stream = next_generation(next_stream);
                                peer.remote_stream = Some(stream);
                                peer.snapshot_generation = None;
                                peer.snapshot_acked = false;
                                remote_streams.insert(stream, *id);
                                send_outer_open(remote, stream, kind, &data);
                            }
                            Err(error) => {
                                peer.retry_requested = false;
                                peer.peer
                                    .push(Frame::new(b'E', 0, error.to_string().as_bytes()));
                            }
                        }
                    }
                }
            } else if !attempt_pending {
                interactive_next = interactive;
                retry_at = Instant::now();
                state = State::Connecting;
                set_status(&mut peers, state, attempt, None, None);
            }
        }

        if let Some(interactive) = manual_retry {
            let failed: Vec<_> = peers
                .iter_mut()
                .filter(|(_, p)| !p.control && !p.ended && p.failed)
                .map(|(id, p)| {
                    if p.snapshot_confirmed {
                        clear_launch_data(p, false);
                    }
                    p.retry_requested = true;
                    p.writer_requested = false;
                    p.writer_ready = false;
                    *id
                })
                .collect();
            let observers: Vec<_> = peers
                .iter()
                .filter(|(_, p)| {
                    !p.control
                        && !p.ended
                        && !p.failed
                        && p.open.is_some()
                        && p.remote_stream.is_some()
                        && p.snapshot_acked
                        && !p.writer_ready
                        && !p.writer_requested
                })
                .map(|(id, _)| *id)
                .collect();
            for id in &failed {
                if let Some(peer) = peers.get_mut(id) {
                    generation_counter = next_generation(generation_counter);
                    peer.generation = generation_counter;
                    set_peer_status(peer, attempt);
                }
            }
            if let Some(remote) = remote.as_mut() {
                let now_open = Instant::now();
                for id in &failed {
                    if let Some(peer) = peers.get_mut(id) {
                        if !capabilities.received {
                            continue;
                        }
                        if !capabilities.strict_open {
                            peer.retry_requested = false;
                            peer.peer.push(Frame::new(
                                b'E',
                                0,
                                b"remote runtime is too old for safe session attach; remote process was preserved",
                            ));
                            continue;
                        }
                        match open_request_with_grants(
                            peer,
                            &capabilities,
                            &mut recreate_grants,
                            now_open,
                        ) {
                            Ok((kind, data)) => {
                                let stream = next_stream;
                                next_stream = next_generation(next_stream);
                                peer.remote_stream = Some(stream);
                                peer.snapshot_generation = None;
                                peer.snapshot_acked = false;
                                remote_streams.insert(stream, *id);
                                send_outer_open(remote, stream, kind, &data);
                            }
                            Err(error) => {
                                peer.retry_requested = false;
                                peer.peer
                                    .push(Frame::new(b'E', 0, error.to_string().as_bytes()));
                            }
                        }
                    }
                }
                for id in observers {
                    if let Some(peer) = peers.get_mut(&id) {
                        peer.writer_requested = true;
                        peer.writer_ready = false;
                        if let Some(stream) = peer.remote_stream {
                            remote.push(Frame::new(
                                b'D',
                                stream,
                                &Frame::new(CLAIM, peer.generation, &[]).encode(),
                            ));
                        }
                    }
                }
            } else if !attempt_pending {
                interactive_next = interactive;
                retry_at = Instant::now();
                state = State::Connecting;
                set_status(&mut peers, state, attempt, None, None);
            }
        }

        let remote_frames = if let Some(remote) = remote.as_mut() {
            if capabilities.received && capabilities.strict_open {
                if let Err(error) = begin_open(
                    remote,
                    &mut peers,
                    &mut remote_streams,
                    &mut next_stream,
                    &capabilities,
                    &mut recreate_grants,
                ) {
                    eprintln!("session runtime open failed: {error}");
                }
            }
            if capabilities.received && capabilities.durable_close {
                begin_controls(remote, &mut peers, &mut remote_streams, &mut next_stream);
            }
            if last_heartbeat.elapsed() >= heartbeat_interval {
                remote.push(Frame::new(b'P', 0, &[]));
                last_heartbeat = Instant::now();
            }
            if capabilities.received {
                begin_list(remote, &peers, &mut list_in_flight);
            }
            Some(remote.read())
        } else {
            None
        };
        if let Some(remote_frames) = remote_frames {
            match remote_frames {
                Ok(frames) => {
                    for frame in frames {
                        last_pong = Instant::now();
                        if frame.kind == b'P' && frame.seq == 0 {
                            let first_capabilities = !capabilities.received;
                            capabilities.update(&frame.data);
                            if first_capabilities {
                                for peer in peers
                                    .values_mut()
                                    .filter(|p| !p.control && !p.ended && p.open.is_some())
                                {
                                    let request = peer.open.as_ref().and_then(|bytes| {
                                        serde_json::from_slice::<OpenRequest>(bytes).ok()
                                    });
                                    let requires_local_launch = request
                                        .as_ref()
                                        .is_some_and(|request| request.launch.is_some());
                                    let requires_inline = request
                                        .as_ref()
                                        .is_some_and(|request| request.inline_viewer);
                                    if requires_local_launch && !capabilities.local_launch {
                                        peer.failed = true;
                                        peer.retry_requested = false;
                                        clear_launch_data(peer, true);
                                        peer.remote_stream = None;
                                        peer.peer.push(Frame::new(
                                            b'E',
                                            0,
                                            b"runtime does not support persistent local launches; no session was created",
                                        ));
                                    } else if requires_inline && !capabilities.inline_viewer {
                                        peer.failed = true;
                                        peer.retry_requested = false;
                                        clear_launch_data(peer, true);
                                        peer.remote_stream = None;
                                        peer.peer.push(Frame::new(b'E', 0,
                                            b"runtime does not support inline viewers; no session was created"));
                                    } else if !capabilities.strict_open {
                                        peer.failed = true;
                                        peer.retry_requested = false;
                                        clear_launch_data(peer, true);
                                        peer.remote_stream = None;
                                        peer.peer.push(Frame::new(
                                            b'E',
                                            0,
                                            b"remote runtime is too old for safe session attach; remote process was preserved",
                                        ));
                                    }
                                }
                            }
                            if first_capabilities && !capabilities.strict_open {
                                for peer in peers.values_mut().filter(|p| {
                                    p.control && !p.control_done && p.close_id.is_some()
                                }) {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"remote runtime does not support confirmed close",
                                    ));
                                    peer.control_done = true;
                                }
                            }
                            continue;
                        }
                        if frame.kind == b'L' && frame.seq == 0 {
                            list_in_flight = false;
                            if frame.data.len() > 8 * 1024 * 1024 {
                                for peer in peers
                                    .values_mut()
                                    .filter(|peer| peer.list_requested && !peer.control_done)
                                {
                                    peer.peer.push(Frame::new(
                                        b'E',
                                        0,
                                        b"session catalogue exceeds size limit",
                                    ));
                                    peer.control_done = true;
                                }
                            } else {
                                for peer in peers
                                    .values_mut()
                                    .filter(|peer| peer.list_requested && !peer.control_done)
                                {
                                    peer.peer.push(Frame::new(b'L', 0, &frame.data));
                                    peer.control_done = true;
                                }
                            }
                            continue;
                        }
                        if frame.kind == b'E' && frame.seq == 0 && list_in_flight {
                            list_in_flight = false;
                            for peer in peers
                                .values_mut()
                                .filter(|peer| peer.list_requested && !peer.control_done)
                            {
                                peer.peer.push(Frame::new(b'E', 0, &frame.data));
                                peer.control_done = true;
                            }
                            continue;
                        }
                        if frame.kind == b'E' {
                            if let Some(id) = remote_streams.remove(&frame.seq) {
                                if let Some(peer) = peers.get_mut(&id) {
                                    peer.remote_stream = None;
                                    if peer.control && (peer.close_id.is_some() || peer.exec_stream)
                                    {
                                        peer.peer.push(Frame::new(b'E', 0, &frame.data));
                                        peer.control_done = true;
                                        continue;
                                    }
                                    if !capabilities.local_launch
                                        && !capabilities.recreate_if_gone
                                        && peer.recreate_if_gone
                                        && !peer.snapshot_confirmed
                                        && !peer.recreate_fallback_used
                                        && is_session_gone_error(&frame.data)
                                    {
                                        if let Some(bytes) = peer.open.as_ref() {
                                            if let Ok(mut request) =
                                                serde_json::from_slice::<OpenRequest>(bytes)
                                            {
                                                peer.recreate_fallback_used = true;
                                                request.create = true;
                                                request.recreate_if_gone = false;
                                                if let Ok(updated) = serde_json::to_vec(&request) {
                                                    peer.open = Some(updated);
                                                    peer.initial_create = true;
                                                    peer.recreate_if_gone = false;
                                                    peer.snapshot_generation = None;
                                                    peer.snapshot_acked = false;
                                                    peer.writer_requested = false;
                                                    peer.writer_ready = false;
                                                    peer.retry_requested = false;
                                                    peer.failed = false;
                                                    continue;
                                                }
                                            }
                                        }
                                    }
                                    if let Some(sid) = peer.session_id.as_deref() {
                                        recreate_grants.remove(sid);
                                    }
                                    peer.snapshot_generation = None;
                                    peer.writer_ready = false;
                                    peer.writer_requested = false;
                                    peer.retry_requested = false;
                                    peer.failed = true;
                                    if peer.snapshot_confirmed {
                                        clear_launch_data(peer, false);
                                    }
                                    let session_gone = !capabilities.local_launch
                                        && is_session_gone_error(&frame.data);
                                    peer.session_gone = session_gone;
                                    if session_gone {
                                        generation_counter = next_generation(generation_counter);
                                        peer.generation = generation_counter;
                                        let detail = sanitize_status_message(&frame.data);
                                        peer.peer.push(status_frame_session_gone(
                                            peer.generation,
                                            attempt,
                                            Some(&detail),
                                        ));
                                        if !peer.hold_on_session_gone {
                                            peer.peer.push(Frame::new(b'E', 0, &frame.data));
                                        }
                                    } else {
                                        peer.peer.push(Frame::new(b'E', 0, &frame.data));
                                    }
                                }
                            }
                            continue;
                        }
                        if frame.kind == b'Q' {
                            if let Some(id) = remote_streams.remove(&frame.seq) {
                                if let Some(peer) = peers.get_mut(&id) {
                                    peer.remote_stream = None;
                                    if peer.control {
                                        if peer.exec_stream && !peer.control_done {
                                            peer.peer.push(Frame::new(
                                                b'E',
                                                0,
                                                b"exec stream closed unexpectedly",
                                            ));
                                        }
                                        peer.control_done = true;
                                        continue;
                                    }
                                    if let Some(sid) = peer.session_id.as_deref() {
                                        recreate_grants.remove(sid);
                                    }
                                    let was_retrying = peer.retry_requested;
                                    peer.retry_requested = false;
                                    if peer.snapshot_confirmed {
                                        clear_launch_data(peer, false);
                                    }
                                    if !peer.ended && (!peer.failed || was_retrying) {
                                        peer.failed = true;
                                        peer.peer.push(Frame::new(
                                            b'E',
                                            0,
                                            b"remote session stream ended",
                                        ));
                                    }
                                }
                            }
                            continue;
                        }
                        if frame.kind != b'D' {
                            return Err(io::Error::other("invalid host response"));
                        }
                        let Some(id) = remote_streams.get(&frame.seq).copied() else {
                            continue;
                        };
                        let Some(peer) = peers.get_mut(&id) else {
                            continue;
                        };
                        let mut inner = inner_frame(&frame.data)?;
                        if peer.control && peer.close_id.is_some() {
                            remote_streams.remove(&frame.seq);
                            if inner.kind == CLOSE {
                                peer.peer.push(inner);
                                peer.control_done = true;
                                peer.remote_stream = None;
                            } else {
                                peer.peer
                                    .push(Frame::new(b'E', 0, b"invalid close confirmation"));
                                peer.control_done = true;
                            }
                            continue;
                        }
                        if peer.control && peer.exec_stream {
                            match inner.kind {
                                b'o' | b'e' => {
                                    if !peer.control_done {
                                        peer.peer.push(inner);
                                    }
                                }
                                b'x' | b'E' => {
                                    if !peer.control_done {
                                        peer.peer.push(inner);
                                        peer.control_done = true;
                                    }
                                    remote_streams.remove(&frame.seq);
                                    peer.remote_stream = None;
                                }
                                _ => {}
                            }
                            continue;
                        }
                        match inner.kind {
                            SNAPSHOT => {
                                if let Some(sid) = peer.session_id.as_deref() {
                                    recreate_grants.remove(sid);
                                }
                                peer.snapshot_generation = Some(peer.generation);
                                peer.snapshot_confirmed = true;
                                clear_launch_data(peer, true);
                                peer.failed = false;
                                peer.session_gone = false;
                                peer.retry_requested = false;
                                peer.snapshot_acked = false;
                                peer.writer_requested = false;
                                peer.writer_ready = false;
                            }
                            CLAIM => {
                                if peer.writer_requested
                                    && peer.snapshot_generation == Some(peer.generation)
                                {
                                    peer.writer_ready = true;
                                    if stable_since.is_none() {
                                        stable_since = Some(Instant::now());
                                    }
                                }
                                inner.seq = peer.generation;
                            }
                            b'B' => {
                                peer.writer_requested = false;
                                peer.writer_ready = false;
                                inner.seq = peer.generation;
                            }
                            b'E' => {
                                if let Some(sid) = peer.session_id.as_deref() {
                                    recreate_grants.remove(sid);
                                }
                                peer.snapshot_generation = None;
                                peer.writer_requested = false;
                                peer.writer_ready = false;
                                peer.retry_requested = false;
                                peer.failed = true;
                                clear_launch_data(peer, false);
                                let session_gone = !capabilities.local_launch
                                    && is_session_gone_error(&inner.data);
                                peer.session_gone = session_gone;
                                if session_gone {
                                    generation_counter = next_generation(generation_counter);
                                    peer.generation = generation_counter;
                                    let detail = sanitize_status_message(&inner.data);
                                    peer.peer.push(status_frame_session_gone(
                                        peer.generation,
                                        attempt,
                                        Some(&detail),
                                    ));
                                    if peer.hold_on_session_gone {
                                        continue;
                                    }
                                }
                            }
                            EXIT => {
                                if let Some(sid) = peer.session_id.as_deref() {
                                    recreate_grants.remove(sid);
                                }
                                peer.ended = true;
                                peer.retry_requested = false;
                                peer.writer_ready = false;
                            }
                            _ => {}
                        }
                        peer.peer.push(inner);
                    }
                    if let Some(remote) = remote.as_mut() {
                        if capabilities.received && capabilities.strict_open {
                            if let Err(error) = begin_open(
                                remote,
                                &mut peers,
                                &mut remote_streams,
                                &mut next_stream,
                                &capabilities,
                                &mut recreate_grants,
                            ) {
                                eprintln!("session runtime open failed: {error}");
                            }
                        }
                        if capabilities.received && capabilities.durable_close {
                            begin_controls(
                                remote,
                                &mut peers,
                                &mut remote_streams,
                                &mut next_stream,
                            );
                        }
                        if capabilities.received {
                            begin_list(remote, &peers, &mut list_in_flight);
                        }
                    }
                }
                Err(_) => {
                    remote = None;
                    _transport_guard = None;
                    remote_streams.clear();
                    reset_remote_streams(&mut peers, true);
                    list_in_flight = false;
                    advance_peer_generations(&mut peers, &mut generation_counter);
                    stable_since = None;
                    capabilities.reset();
                    state = State::Reconnecting;
                    let delay = retry_delay(attempt.max(1));
                    set_status(&mut peers, state, attempt, Some(delay), None);
                    retry_at = Instant::now() + delay;
                }
            }
        }

        for peer in peers.values_mut() {
            if peer.peer.flush().is_err() {
                peer.peer.dead = true;
            }
        }
        let remove: Vec<_> = peers
            .iter()
            .filter(|(_, peer)| {
                peer.peer.dead
                    || peer.control_done && peer.peer.queued == 0
                    || peer.ended && peer.peer.queued == 0
            })
            .map(|(id, peer)| (*id, peer.remote_stream))
            .collect();
        if let Some(remote) = remote.as_mut() {
            for (id, stream) in remove {
                if let Some(stream) = stream {
                    remote.push(Frame::new(b'Q', stream, &[]));
                    remote_streams.remove(&stream);
                } else {
                    let _ = id;
                }
            }
        }
        peers.retain(|_, p| {
            !(p.peer.dead || p.control_done && p.peer.queued == 0 || p.ended && p.peer.queued == 0)
        });

        let remote_dead = remote
            .as_mut()
            .is_some_and(|peer| peer.flush().is_err() || peer.dead);
        if remote_dead {
            remote = None;
            _transport_guard = None;
            remote_streams.clear();
            reset_remote_streams(&mut peers, true);
            list_in_flight = false;
            advance_peer_generations(&mut peers, &mut generation_counter);
            stable_since = None;
            capabilities.reset();
            state = State::Reconnecting;
            let delay = retry_delay(attempt.max(1));
            set_status(&mut peers, state, attempt, Some(delay), None);
            for peer in peers.values_mut() {
                if peer.peer.flush().is_err() {
                    peer.peer.dead = true;
                }
            }
            peers.retain(|_, p| !(p.peer.dead || p.control_done && p.peer.queued == 0));
            retry_at = Instant::now() + delay;
        }

        use std::os::fd::AsRawFd;
        let mut descriptors = Vec::with_capacity(peers.len() + 3);
        descriptors.push(libc::pollfd {
            fd: listener.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
        descriptors.push(wake.poll_fd());
        if let Some(remote) = &remote {
            descriptors.push(remote.poll_fd());
        }
        for peer in peers.values() {
            descriptors.push(peer.peer.poll_fd());
        }
        let now = Instant::now();
        let has_active_peers = peers.values().any(is_active_peer);
        let mut timeout_ms: libc::c_int = 60_000;
        if let Some(earliest_grant_expiry) = recreate_grants.values().map(|g| g.expires_at).min() {
            timeout_ms = timeout_ms.min(crate::deadline_poll_ms(
                now,
                earliest_grant_expiry + Duration::from_nanos(1),
            ));
        }
        if !has_active_peers && recreate_grants.is_empty() {
            let idle_timeout = effective_idle_timeout(initial_ppid);
            timeout_ms = timeout_ms.min(crate::deadline_poll_ms(
                now,
                idle_since + idle_timeout + Duration::from_nanos(1),
            ));
        }
        if remote.is_some() {
            timeout_ms = timeout_ms
                .min(crate::deadline_poll_ms(
                    now,
                    last_pong + heartbeat_timeout + Duration::from_nanos(1),
                ))
                .min(crate::deadline_poll_ms(
                    now,
                    last_heartbeat + heartbeat_interval,
                ));
            if let Some(since) = stable_since {
                timeout_ms = timeout_ms.min(crate::deadline_poll_ms(now, since + STABLE_RESET));
            }
        } else if !attempt_pending {
            timeout_ms = timeout_ms.min(crate::deadline_poll_ms(now, retry_at));
        }
        crate::poll_fds(&mut descriptors, timeout_ms)?;
    }
}

/// One-shot explicit recreate grant (`recreate/1`) over the local control socket.
pub fn recreate_local(socket: &Path, request: &RecreateRequest) -> io::Result<()> {
    request.validate()?;
    let payload = serde_json::to_vec(request)?;
    let mut attempts = 0usize;
    let mut stream = loop {
        match UnixStream::connect(socket) {
            Ok(stream) => break stream,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                ) && attempts < 40 =>
            {
                attempts += 1;
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(error),
        }
    };
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    Frame::new(b'y', 0, &payload).send(&mut stream)?;
    let response = loop {
        let response = Frame::read(&mut stream)?;
        if response.kind != b'T' {
            break response;
        }
    };
    if response.kind == b'y' && response.data.as_slice() == b"accepted" {
        Ok(())
    } else {
        Err(io::Error::other(
            String::from_utf8_lossy(&response.data).into_owned(),
        ))
    }
}

/// One-shot local control request. It never opens a session or writes terminal
/// input; the supervisor decides which offline stream can be attached again.
pub fn retry_local(socket: &Path, interactive: bool) -> io::Result<()> {
    let mut attempts = 0usize;
    let mut stream = loop {
        match UnixStream::connect(socket) {
            Ok(stream) => break stream,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                ) && attempts < 40 =>
            {
                attempts += 1;
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(error),
        }
    };
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    Frame::new(b'y', 0, if interactive { b"interactive/1" } else { &[] }).send(&mut stream)?;
    let response = loop {
        let response = Frame::read(&mut stream)?;
        if response.kind != b'T' {
            break response;
        }
    };
    if response.kind == b'y'
        && matches!(
            response.data.as_slice(),
            b"accepted" | b"endpoint online" | b"connect attempt already running"
        )
    {
        Ok(())
    } else {
        Err(io::Error::other(
            String::from_utf8_lossy(&response.data).into_owned(),
        ))
    }
}

/// Read the session catalogue through an existing relay without opening a pane.
pub fn list_local(socket: &Path) -> io::Result<Vec<SessionSummary>> {
    let deadline = Instant::now() + LIST_REQUEST_TIMEOUT;
    let mut last_error = None;
    for attempt in 0..3 {
        let mut stream = match UnixStream::connect(socket) {
            Ok(stream) => stream,
            Err(error) => {
                last_error = Some(error);
                if attempt < 2 {
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
                break;
            }
        };
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "session catalogue request timed out",
            ));
        }
        stream.set_read_timeout(Some(remaining))?;
        stream.set_write_timeout(Some(Duration::from_secs(2)))?;
        Frame::new(b'L', 0, &[]).send(&mut stream)?;
        loop {
            match Frame::read(&mut stream) {
                Ok(frame) if frame.kind == b'T' || frame.kind == b'P' && frame.seq == 0 => {}
                Ok(frame) if frame.kind == b'L' && frame.seq == 0 => {
                    if frame.data.len() > 8 * 1024 * 1024 {
                        return Err(io::Error::other("session catalogue exceeds size limit"));
                    }
                    let sessions: Vec<SessionSummary> = serde_json::from_slice(&frame.data)?;
                    if sessions.len() > 2048 {
                        return Err(io::Error::other("session catalogue exceeds entry limit"));
                    }
                    return Ok(sessions);
                }
                Ok(frame) if frame.kind == b'E' => {
                    let message = String::from_utf8_lossy(&frame.data);
                    return Err(io::Error::other(
                        message.chars().take(1024).collect::<String>(),
                    ));
                }
                Ok(_) => {
                    return Err(io::Error::other("invalid session catalogue response"));
                }
                Err(error)
                    if attempt < 2
                        && matches!(
                            error.kind(),
                            io::ErrorKind::UnexpectedEof
                                | io::ErrorKind::ConnectionReset
                                | io::ErrorKind::BrokenPipe
                                | io::ErrorKind::NotConnected
                        ) =>
                {
                    last_error = Some(error);
                    break;
                }
                Err(error) => return Err(error),
            }
        }
        if attempt < 2 {
            thread::sleep(Duration::from_millis(100));
        }
    }
    Err(last_error.unwrap_or_else(|| {
        io::Error::new(
            io::ErrorKind::TimedOut,
            "session catalogue request timed out",
        )
    }))
}

#[cfg(test)]
mod error_classification_tests {
    use super::{
        attention_required, list_local, retry_local, supervise, Connector, RelayTransport,
    };
    use crate::{lifecycle::Policy, registry::OpenRequest, Frame};
    use std::{
        collections::BTreeMap,
        io,
        os::unix::net::{UnixListener, UnixStream},
        path::PathBuf,
        sync::{
            atomic::{AtomicUsize, Ordering},
            mpsc, Arc,
        },
        thread,
        time::{Duration, Instant},
    };

    #[test]
    fn malformed_proxy_banner_is_retryable_but_a_broken_private_key_is_not() {
        assert!(!attention_required(&io::Error::other(
            "banner exchange: Connection to proxy port 80: invalid format"
        )));
        assert!(attention_required(&io::Error::other(
            "Load key \"/private/key\": invalid format"
        )));
        assert!(attention_required(&io::Error::other(
            "Permission denied (publickey)."
        )));
    }

    #[test]
    fn manual_retry_after_inner_snapshot_error_performs_single_attach_attempt() {
        use std::os::unix::fs::DirBuilderExt;
        let nonce = crate::record::nonce().unwrap();
        let dir = std::env::temp_dir().join(format!("omg-rt-{}", &nonce[..8]));
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .unwrap();
        let socket_path = dir.join("s.sock");
        let open_count = Arc::new(AtomicUsize::new(0));
        let open_creates = Arc::new(std::sync::Mutex::new(Vec::new()));

        let open_count_remote = open_count.clone();
        let open_creates_remote = open_creates.clone();
        let connector = Arc::new(move |_| {
            let (client_side, mut server_side) = UnixStream::pair()?;
            let open_count_thread = open_count_remote.clone();
            let open_creates_thread = open_creates_remote.clone();
            thread::spawn(move || {
                Frame::new(
                    b'P',
                    0,
                    b"strict-open/1,durable-close/1,local-launch/1,inline-viewer/1",
                )
                .send(&mut server_side)
                .unwrap();
                while let Ok(frame) = Frame::read(&mut server_side) {
                    if frame.kind == b'C' {
                        let req: OpenRequest = serde_json::from_slice(&frame.data).unwrap();
                        open_creates_thread.lock().unwrap().push(req.create);
                        open_count_thread.fetch_add(1, Ordering::SeqCst);
                        let inner_err =
                            Frame::new(b'E', 1, b"terminal snapshot is unavailable").encode();
                        let _ = Frame::new(b'D', frame.seq, &inner_err).send(&mut server_side);
                        let _ = Frame::new(b'Q', frame.seq, &[]).send(&mut server_side);
                    } else if frame.kind == b'P' {
                        let _ = Frame::new(
                            b'P',
                            0,
                            b"strict-open/1,durable-close/1,local-launch/1,inline-viewer/1",
                        )
                        .send(&mut server_side);
                    }
                }
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });

        let socket_for_supervisor = socket_path.clone();
        thread::spawn(move || {
            let _ = supervise(&socket_for_supervisor, connector, false);
        });

        let deadline = Instant::now() + Duration::from_secs(2);
        let mut peer = loop {
            match UnixStream::connect(&socket_path) {
                Ok(stream) => break stream,
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                Err(err) => panic!("failed to connect to local relay: {err}"),
            }
        };
        peer.set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();

        let request = OpenRequest {
            id: "d2956168-0ade-4c3e-ade4-3bc908d7dfd6".to_string(),
            policy: Policy::default(),
            create: true,
            cwd: None,
            launch: None,
            resurrect_launch: None,
            inline_viewer: false,
            recreate_if_gone: false,
            ..Default::default()
        };
        Frame::new(b'H', 0, &serde_json::to_vec(&request).unwrap())
            .send(&mut peer)
            .unwrap();

        let first_err = loop {
            let frame = Frame::read(&mut peer).unwrap();
            if frame.kind == b'E' {
                break frame;
            }
        };
        assert_eq!(first_err.data, b"terminal snapshot is unavailable");
        assert_eq!(open_count.load(Ordering::SeqCst), 1);

        // No duplicate b'E' ("remote session stream ended") or automatic retry storm.
        thread::sleep(Duration::from_millis(40));
        assert_eq!(open_count.load(Ordering::SeqCst), 1);

        // Manual retry triggers exactly one attach-only attempt and stops cleanly.
        retry_local(&socket_path, true).unwrap();
        let retry_err = loop {
            let frame = Frame::read(&mut peer).unwrap();
            if frame.kind == b'E' {
                break frame;
            }
        };
        assert_eq!(retry_err.data, b"terminal snapshot is unavailable");
        thread::sleep(Duration::from_millis(50));
        assert_eq!(open_count.load(Ordering::SeqCst), 2);
        assert_eq!(*open_creates.lock().unwrap(), vec![true, false]);

        drop(peer);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resurrect_launch_is_stripped_without_capability_and_preserved_across_manual_retry() {
        use crate::{
            lifecycle::Policy,
            registry::{LocalLaunchSpec, OpenRequest},
            Frame, SNAPSHOT,
        };
        use std::collections::BTreeMap;
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc, Mutex,
        };

        let run_case = |advertise_resurrect: bool, reject_first: bool| -> Vec<bool> {
            use std::os::unix::fs::DirBuilderExt;
            let dir = std::path::PathBuf::from(format!(
                "/tmp/omg-client-resurrect-{}",
                crate::record::nonce().unwrap()
            ));
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&dir)
                .unwrap();
            let socket_path = dir.join("relay.sock");
            let requests = Arc::new(Mutex::new(Vec::<bool>::new()));
            let requests_clone = requests.clone();
            let reject_once = Arc::new(AtomicBool::new(reject_first));
            let connector = Arc::new(move |_| {
                let (client_side, mut server_side) = UnixStream::pair()?;
                let requests_thread = requests_clone.clone();
                let reject_once = reject_once.clone();
                thread::spawn(move || {
                    let caps: &[u8] = if advertise_resurrect {
                        b"strict-open/1,durable-close/1,local-launch/1,local-resurrect/1"
                    } else {
                        b"strict-open/1,durable-close/1,local-launch/1"
                    };
                    Frame::new(b'P', 0, caps).send(&mut server_side).unwrap();
                    while let Ok(frame) = Frame::read(&mut server_side) {
                        match frame.kind {
                            b'P' => {
                                let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                            }
                            b'C' => {
                                let req: OpenRequest = serde_json::from_slice(&frame.data).unwrap();
                                requests_thread
                                    .lock()
                                    .unwrap()
                                    .push(req.resurrect_launch.is_some());
                                if reject_once.swap(false, Ordering::SeqCst) {
                                    let _ = Frame::new(b'E', frame.seq, b"temporary failure")
                                        .send(&mut server_side);
                                } else {
                                    let snap = Frame::new(SNAPSHOT, 1, b"snap").encode();
                                    let _ =
                                        Frame::new(b'D', frame.seq, &snap).send(&mut server_side);
                                }
                            }
                            b'Q' => {
                                let _ = Frame::new(b'Q', frame.seq, &[]).send(&mut server_side);
                            }
                            _ => {}
                        }
                    }
                });
                Ok(RelayTransport {
                    socket: client_side,
                    guard: Box::new(()),
                })
            });

            let socket_clone = socket_path.clone();
            thread::spawn(move || {
                let _ = supervise(&socket_clone, connector, false);
            });

            let deadline = Instant::now() + Duration::from_secs(2);
            let mut peer = loop {
                match UnixStream::connect(&socket_path) {
                    Ok(s) => break s,
                    Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                    Err(err) => panic!("connect failed: {err}"),
                }
            };
            peer.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
            let req = OpenRequest {
                id: "d2956168-0ade-4c3e-ade4-3bc908d7dfd7".into(),
                policy: Policy::default(),
                create: false,
                cwd: None,
                launch: None,
                resurrect_launch: Some(LocalLaunchSpec {
                    argv: vec!["/bin/sh".into()],
                    env: BTreeMap::new(),
                    cwd: None,
                    cols: 80,
                    rows: 24,
                    pixel_width: 640,
                    pixel_height: 384,
                    scrollback_max_bytes: None,
                    scrollback_max_lines: None,
                    input_base64: None,
                }),
                inline_viewer: false,
                recreate_if_gone: false,
                ..Default::default()
            };
            Frame::new(b'H', 0, &serde_json::to_vec(&req).unwrap())
                .send(&mut peer)
                .unwrap();
            let saw_snapshot;
            loop {
                let frame = Frame::read(&mut peer).unwrap();
                if frame.kind == b'E' {
                    retry_local(&socket_path, true).unwrap();
                } else if frame.kind == SNAPSHOT {
                    saw_snapshot = true;
                    break;
                }
            }
            assert!(saw_snapshot);
            drop(peer);
            let _ = std::fs::remove_dir_all(&dir);
            let observed = requests.lock().unwrap().clone();
            observed
        };

        // Legacy host without local-resurrect/1 receives resurrect_launch == None.
        assert_eq!(run_case(false, false), vec![false]);
        // Capable host preserves resurrect_launch across manual retry after b'E'.
        assert_eq!(run_case(true, true), vec![true, true]);
    }

    #[test]
    fn supervise_forwards_watermarked_8byte_acknowledge_and_drops_invalid_payload_len() {
        use crate::{lifecycle::Policy, registry::OpenRequest, Frame, ACK, ACKNOWLEDGE, SNAPSHOT};
        use std::os::unix::fs::DirBuilderExt;
        use std::sync::{Arc, Mutex};

        let dir = std::path::PathBuf::from(format!(
            "/tmp/omg-client-ack-{}",
            crate::record::nonce().unwrap()
        ));
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .unwrap();
        let socket_path = dir.join("relay.sock");
        let forwarded_acks = Arc::new(Mutex::new(Vec::<Vec<u8>>::new()));
        let forwarded_clone = forwarded_acks.clone();
        let (done_tx, done_rx) = std::sync::mpsc::channel();

        let connector = Arc::new(move |_| {
            let (client_side, mut server_side) = UnixStream::pair()?;
            let forwarded_thread = forwarded_clone.clone();
            let done_tx = done_tx.clone();
            thread::spawn(move || {
                let caps = b"strict-open/1,durable-close/1,agent-state/1";
                Frame::new(b'P', 0, caps).send(&mut server_side).unwrap();
                while let Ok(frame) = Frame::read(&mut server_side) {
                    match frame.kind {
                        b'P' => {
                            let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                        }
                        b'C' => {
                            let snap = Frame::new(SNAPSHOT, 7, b"snap").encode();
                            let _ = Frame::new(b'D', frame.seq, &snap).send(&mut server_side);
                        }
                        b'D' => {
                            if let Ok(inner) = Frame::read(&mut frame.data.as_slice()) {
                                if inner.kind == ACKNOWLEDGE {
                                    forwarded_thread.lock().unwrap().push(inner.data.clone());
                                    if forwarded_thread.lock().unwrap().len() == 2 {
                                        let _ = done_tx.send(());
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });

        let socket_clone = socket_path.clone();
        thread::spawn(move || {
            let _ = supervise(&socket_clone, connector, false);
        });

        let deadline = Instant::now() + Duration::from_secs(2);
        let mut peer = loop {
            match UnixStream::connect(&socket_path) {
                Ok(s) => break s,
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                Err(err) => panic!("connect failed: {err}"),
            }
        };
        peer.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let req = OpenRequest {
            id: "d2956168-0ade-4c3e-ade4-3bc908d7dfd8".into(),
            policy: Policy::default(),
            create: false,
            cwd: None,
            launch: None,
            resurrect_launch: None,
            inline_viewer: false,
            recreate_if_gone: false,
            ..Default::default()
        };
        Frame::new(b'H', 0, &serde_json::to_vec(&req).unwrap())
            .send(&mut peer)
            .unwrap();
        let mut peer_gen = 0u64;
        let snap_seq = loop {
            let frame = Frame::read(&mut peer).unwrap();
            if frame.kind == b'T' {
                peer_gen = frame.seq;
            } else if frame.kind == SNAPSHOT {
                break frame.seq;
            }
        };
        assert_ne!(peer_gen, 0);
        Frame::new(ACK, snap_seq, &peer_gen.to_be_bytes())
            .send(&mut peer)
            .unwrap();
        // Malformed 4-byte ACKNOWLEDGE must be dropped.
        Frame::new(ACKNOWLEDGE, peer_gen, &[1, 2, 3, 4])
            .send(&mut peer)
            .unwrap();
        // 8-byte watermarked ACKNOWLEDGE and legacy 0-byte ACKNOWLEDGE must forward.
        Frame::new(ACKNOWLEDGE, peer_gen, &42u64.to_be_bytes())
            .send(&mut peer)
            .unwrap();
        Frame::new(ACKNOWLEDGE, peer_gen, &[])
            .send(&mut peer)
            .unwrap();

        done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let observed = forwarded_acks.lock().unwrap().clone();
        assert_eq!(observed, vec![42u64.to_be_bytes().to_vec(), Vec::new()]);
        drop(peer);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn recreate_if_gone_is_omitted_for_legacy_remote_and_triggers_once_create_fallback() {
        use crate::{lifecycle::Policy, registry::OpenRequest, Frame, SNAPSHOT};
        use std::sync::{Arc, Mutex};

        let dir = PathBuf::from(format!(
            "/tmp/omg-client-fallback-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        std::fs::create_dir_all(&dir).unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let socket_path = dir.join("relay.sock");
        let recorded = Arc::new(Mutex::new(Vec::<(bool, Option<String>, bool)>::new()));
        let recorded_srv = recorded.clone();
        let (done_tx, done_rx) = mpsc::channel();

        let connector: Connector = Arc::new(move |_| {
            let (client_side, mut server_side) = UnixStream::pair()?;
            let recorded_conn = recorded_srv.clone();
            let done_tx = done_tx.clone();
            thread::spawn(move || {
                let mut open_seq = 0usize;
                while let Ok(frame) = Frame::read(&mut server_side) {
                    match frame.kind {
                        b'P' => {
                            let _ = Frame::new(b'P', 0, b"strict-open/1,durable-close/1")
                                .send(&mut server_side);
                        }
                        b'C' => {
                            open_seq += 1;
                            let raw_has_recreate = std::str::from_utf8(&frame.data)
                                .is_ok_and(|s| s.contains("recreate_if_gone"));
                            let req: OpenRequest = serde_json::from_slice(&frame.data).unwrap();
                            recorded_conn.lock().unwrap().push((
                                req.create,
                                req.cwd.clone(),
                                raw_has_recreate,
                            ));
                            if open_seq == 1 {
                                let _ =
                                    Frame::new(b'E', frame.seq, b"unknown session; cannot resume")
                                        .send(&mut server_side);
                            } else {
                                let _ = Frame::new(
                                    b'D',
                                    frame.seq,
                                    &Frame::new(SNAPSHOT, 1, b"ok").encode(),
                                )
                                .send(&mut server_side);
                                let _ = done_tx.send(());
                                if open_seq >= 2 {
                                    // Keep waiting until closed; if a 3rd fallback ever fired it'd error.
                                    while let Ok(f) = Frame::read(&mut server_side) {
                                        if f.kind == b'P' {
                                            let _ =
                                                Frame::new(b'P', 0, b"ok").send(&mut server_side);
                                        }
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });

        let socket_clone = socket_path.clone();
        thread::spawn(move || {
            let _ = supervise(&socket_clone, connector, false);
        });

        let deadline = Instant::now() + Duration::from_secs(2);
        let mut peer = loop {
            match UnixStream::connect(&socket_path) {
                Ok(s) => break s,
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                Err(err) => panic!("connect failed: {err}"),
            }
        };
        peer.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let req = OpenRequest {
            id: "d2956168-0ade-4c3e-ade4-3bc908d7dfd9".into(),
            policy: Policy::default(),
            create: false,
            cwd: Some("/tmp/proj-restore".into()),
            launch: None,
            resurrect_launch: None,
            inline_viewer: false,
            recreate_if_gone: true,
            ..Default::default()
        };
        Frame::new(b'H', 0, &serde_json::to_vec(&req).unwrap())
            .send(&mut peer)
            .unwrap();
        let got_snapshot = loop {
            let frame = Frame::read(&mut peer).unwrap();
            assert_ne!(frame.kind, b'E', "legacy fallback must suppress first E");
            if frame.kind == SNAPSHOT {
                break true;
            }
        };
        assert!(got_snapshot);
        done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(
            *recorded.lock().unwrap(),
            vec![
                (false, Some("/tmp/proj-restore".into()), false),
                (true, Some("/tmp/proj-restore".into()), false),
            ]
        );
        drop(peer);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn recreate_if_gone_forwarded_only_when_capability_advertised_and_cleared_after_snapshot() {
        use crate::{lifecycle::Policy, registry::OpenRequest, Frame, SNAPSHOT};
        use std::sync::{Arc, Mutex};

        let dir = PathBuf::from(format!(
            "/tmp/omg-client-cap-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        std::fs::create_dir_all(&dir).unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let socket_path = dir.join("relay.sock");
        let observed = Arc::new(Mutex::new(Vec::<(bool, bool)>::new()));
        let observed_srv = observed.clone();
        let conn_count = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let conn_srv = conn_count.clone();
        let (done_tx, done_rx) = mpsc::channel();

        let connector: Connector = Arc::new(move |_| {
            let n = conn_srv.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let (client_side, mut server_side) = UnixStream::pair()?;
            let observed_conn = observed_srv.clone();
            let done_tx = done_tx.clone();
            thread::spawn(move || {
                while let Ok(frame) = Frame::read(&mut server_side) {
                    match frame.kind {
                        b'P' => {
                            let _ = Frame::new(
                                b'P',
                                0,
                                b"strict-open/1,local-launch/1,local-resurrect/1,recreate-if-gone/1",
                            )
                            .send(&mut server_side);
                        }
                        b'C' => {
                            let req: OpenRequest = serde_json::from_slice(&frame.data).unwrap();
                            observed_conn
                                .lock()
                                .unwrap()
                                .push((req.create, req.recreate_if_gone));
                            let _ = Frame::new(
                                b'D',
                                frame.seq,
                                &Frame::new(SNAPSHOT, 1, b"snap").encode(),
                            )
                            .send(&mut server_side);
                            if n == 0 {
                                // Drop first transport right after confirming snapshot to force reconnect.
                                break;
                            } else {
                                let _ = done_tx.send(());
                            }
                        }
                        _ => {}
                    }
                }
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });

        let socket_clone = socket_path.clone();
        thread::spawn(move || {
            let _ = supervise(&socket_clone, connector, false);
        });
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut peer = loop {
            match UnixStream::connect(&socket_path) {
                Ok(s) => break s,
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                Err(err) => panic!("connect failed: {err}"),
            }
        };
        let req = OpenRequest {
            id: "d2956168-0ade-4c3e-ade4-3bc908d7dfda".into(),
            policy: Policy::default(),
            create: false,
            cwd: None,
            launch: None,
            resurrect_launch: None,
            inline_viewer: false,
            recreate_if_gone: true,
            ..Default::default()
        };
        Frame::new(b'H', 0, &serde_json::to_vec(&req).unwrap())
            .send(&mut peer)
            .unwrap();
        done_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        assert_eq!(
            *observed.lock().unwrap(),
            vec![(false, true), (false, false)]
        );
        drop(peer);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn initial_create_preserves_create_true_after_outer_error_and_retry() {
        use crate::{
            lifecycle::Policy,
            registry::{LocalLaunchSpec, OpenRequest},
            Frame, SNAPSHOT,
        };
        use std::sync::{Arc, Mutex};

        let dir = PathBuf::from(format!(
            "/tmp/omg-client-retry-create-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        std::fs::create_dir_all(&dir).unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let socket_path = dir.join("relay.sock");
        let opens = Arc::new(Mutex::new(Vec::<(bool, bool)>::new()));
        let opens_srv = opens.clone();

        let connector: Connector = Arc::new(move |_| {
            let (client_side, mut server_side) = UnixStream::pair()?;
            let opens_conn = opens_srv.clone();
            thread::spawn(move || {
                let mut count = 0usize;
                while let Ok(frame) = Frame::read(&mut server_side) {
                    match frame.kind {
                        b'P' => {
                            let _ = Frame::new(
                                b'P',
                                0,
                                b"strict-open/1,durable-close/1,local-launch/1,recreate-if-gone/1",
                            )
                            .send(&mut server_side);
                        }
                        b'C' => {
                            count += 1;
                            let req: OpenRequest = serde_json::from_slice(&frame.data).unwrap();
                            opens_conn
                                .lock()
                                .unwrap()
                                .push((req.create, req.launch.is_some()));
                            if count == 1 {
                                let _ = Frame::new(b'E', frame.seq, b"transient pre-open failure")
                                    .send(&mut server_side);
                            } else {
                                let _ = Frame::new(
                                    b'D',
                                    frame.seq,
                                    &Frame::new(SNAPSHOT, 1, b"ok").encode(),
                                )
                                .send(&mut server_side);
                            }
                        }
                        _ => {}
                    }
                }
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });

        let socket_clone = socket_path.clone();
        thread::spawn(move || {
            let _ = supervise(&socket_clone, connector, false);
        });
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut peer = loop {
            match UnixStream::connect(&socket_path) {
                Ok(s) => break s,
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                Err(err) => panic!("connect failed: {err}"),
            }
        };
        peer.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let req = OpenRequest {
            id: "d2956168-0ade-4c3e-ade4-3bc908d7dfdb".into(),
            policy: Policy::default(),
            create: true,
            cwd: None,
            launch: Some(LocalLaunchSpec {
                argv: vec!["/bin/sh".into()],
                env: BTreeMap::new(),
                cwd: None,
                cols: 80,
                rows: 24,
                pixel_width: 640,
                pixel_height: 384,
                scrollback_max_bytes: None,
                scrollback_max_lines: None,
                input_base64: None,
            }),
            resurrect_launch: None,
            inline_viewer: false,
            recreate_if_gone: false,
            ..Default::default()
        };
        Frame::new(b'H', 0, &serde_json::to_vec(&req).unwrap())
            .send(&mut peer)
            .unwrap();
        loop {
            let f = Frame::read(&mut peer).unwrap();
            if f.kind == b'E' {
                break;
            }
        }
        retry_local(&socket_path, false).unwrap();
        loop {
            let f = Frame::read(&mut peer).unwrap();
            if f.kind == SNAPSHOT {
                break;
            }
        }
        assert_eq!(*opens.lock().unwrap(), vec![(true, true), (true, true)]);
        drop(peer);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn retry_local_retries_enoent_and_accepts_online_or_pending_responses() {
        let dir = PathBuf::from(format!(
            "/tmp/omg-retry-local-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("relay.sock");
        let sock_srv = sock.clone();
        let handle = thread::spawn(move || {
            thread::sleep(Duration::from_millis(120));
            let listener = UnixListener::bind(&sock_srv).unwrap();
            for reply in [
                &b"endpoint online"[..],
                &b"connect attempt already running"[..],
            ] {
                let (mut stream, _) = listener.accept().unwrap();
                let req = crate::Frame::read(&mut stream).unwrap();
                assert_eq!(req.kind, b'y');
                crate::Frame::new(b'y', 1, reply).send(&mut stream).unwrap();
            }
        });
        retry_local(&sock, false).unwrap();
        retry_local(&sock, true).unwrap();
        handle.join().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn effective_idle_timeout_tracks_parent_liveness() {
        use super::{effective_idle_timeout, PARENT_ALIVE_PEER_IDLE_TIMEOUT, PEER_IDLE_TIMEOUT};

        assert_eq!(effective_idle_timeout(0), PEER_IDLE_TIMEOUT);
        assert_eq!(effective_idle_timeout(1), PEER_IDLE_TIMEOUT);

        #[cfg(unix)]
        {
            let ppid = unsafe { libc::getppid() };
            if ppid > 1 {
                assert_eq!(effective_idle_timeout(ppid), PARENT_ALIVE_PEER_IDLE_TIMEOUT);
                let mismatched = if ppid == 2 { 3 } else { 2 };
                assert_eq!(effective_idle_timeout(mismatched), PEER_IDLE_TIMEOUT);
            }
        }
    }

    #[test]
    fn incoming_data_frames_refresh_remote_liveness_without_pong() {
        use super::{supervise_with_timeouts, ACK, SNAPSHOT};
        use crate::OUTPUT;
        use std::sync::atomic::AtomicBool;

        let dir = PathBuf::from(format!(
            "/tmp/omg-client-liveness-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        std::fs::create_dir_all(&dir).unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let socket_path = dir.join("relay.sock");
        let conn_count = Arc::new(AtomicUsize::new(0));
        let conn_srv = conn_count.clone();
        let stop_stream = Arc::new(AtomicBool::new(false));
        let stop_srv = stop_stream.clone();
        let (opened_tx, opened_rx) = mpsc::channel();
        let (reconnected_tx, reconnected_rx) = mpsc::channel();

        let connector: Connector = Arc::new(move |_| {
            let n = conn_srv.fetch_add(1, Ordering::SeqCst);
            if n > 0 {
                let _ = reconnected_tx.send(n);
                return Err(io::Error::other("simulated reconnect trigger"));
            }
            let (client_side, mut server_side) = UnixStream::pair()?;
            let stop_stream = stop_srv.clone();
            let opened_tx = opened_tx.clone();
            thread::spawn(move || {
                let caps = b"strict-open/1,durable-close/1";
                Frame::new(b'P', 0, caps).send(&mut server_side).unwrap();
                let stream_id = loop {
                    let Ok(frame) = Frame::read(&mut server_side) else {
                        return;
                    };
                    if frame.kind == b'C' {
                        break frame.seq;
                    }
                };
                let snap = Frame::new(SNAPSHOT, 1, b"init").encode();
                Frame::new(b'D', stream_id, &snap)
                    .send(&mut server_side)
                    .unwrap();
                let _ = opened_tx.send(());

                // Drain incoming pings without sending any b'P' pongs back.
                let mut reader = server_side.try_clone().unwrap();
                let drain_handle = thread::spawn(move || while Frame::read(&mut reader).is_ok() {});

                let mut seq = 1u64;
                while !stop_stream.load(Ordering::SeqCst) {
                    let out = Frame::new(OUTPUT, seq + 2, b"ok").encode();
                    seq += 2;
                    if Frame::new(b'D', stream_id, &out)
                        .send(&mut server_side)
                        .is_err()
                    {
                        break;
                    }
                    thread::sleep(Duration::from_millis(25));
                }
                thread::sleep(Duration::from_millis(500));
                drop(server_side);
                let _ = drain_handle.join();
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });

        let socket_clone = socket_path.clone();
        thread::spawn(move || {
            let _ = supervise_with_timeouts(
                &socket_clone,
                connector,
                false,
                Duration::from_millis(20),
                Duration::from_millis(120),
            );
        });

        let deadline = Instant::now() + Duration::from_secs(2);
        let mut peer = loop {
            match UnixStream::connect(&socket_path) {
                Ok(s) => break s,
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                Err(err) => panic!("connect failed: {err}"),
            }
        };
        peer.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let req = OpenRequest {
            id: "d2956168-0ade-4c3e-ade4-3bc908d7dfdc".into(),
            policy: Policy::default(),
            create: false,
            cwd: None,
            launch: None,
            resurrect_launch: None,
            inline_viewer: false,
            recreate_if_gone: false,
            ..Default::default()
        };
        Frame::new(b'H', 0, &serde_json::to_vec(&req).unwrap())
            .send(&mut peer)
            .unwrap();
        let mut peer_gen = 0u64;
        let snap_seq = loop {
            let frame = Frame::read(&mut peer).unwrap();
            if frame.kind == b'T' {
                peer_gen = frame.seq;
            } else if frame.kind == SNAPSHOT {
                break frame.seq;
            }
        };
        Frame::new(ACK, snap_seq, &peer_gen.to_be_bytes())
            .send(&mut peer)
            .unwrap();
        opened_rx.recv_timeout(Duration::from_secs(2)).unwrap();

        let stream_until = Instant::now() + Duration::from_millis(320);
        let mut output_frames = 0usize;
        while Instant::now() < stream_until || output_frames < 8 {
            let frame = Frame::read(&mut peer).unwrap();
            assert_ne!(
                frame.kind,
                b'T',
                "unexpected status frame while receiving b'D' traffic: {}",
                String::from_utf8_lossy(&frame.data)
            );
            if frame.kind == OUTPUT {
                output_frames += 1;
            }
        }
        assert_eq!(conn_count.load(Ordering::SeqCst), 1);

        stop_stream.store(true, Ordering::SeqCst);
        assert_eq!(
            reconnected_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
            1
        );
        drop(peer);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn exec_stream_reports_offline_and_unsupported_capabilities() {
        use std::os::unix::fs::DirBuilderExt;

        let dir = PathBuf::from(format!(
            "/tmp/omg-client-exec-err-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .unwrap();
        let socket_path = dir.join("relay.sock");
        let allow_connect = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let allow_connect_srv = allow_connect.clone();

        let connector: Connector = Arc::new(move |_| {
            if !allow_connect_srv.load(Ordering::SeqCst) {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "offline"));
            }
            let (client_side, mut server_side) = UnixStream::pair()?;
            thread::spawn(move || {
                let caps = b"strict-open/1,durable-close/1";
                let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                while let Ok(frame) = Frame::read(&mut server_side) {
                    if frame.kind == b'P' {
                        let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                    }
                }
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });

        let socket_clone = socket_path.clone();
        thread::spawn(move || {
            let _ = supervise(&socket_clone, connector, false);
        });

        let deadline = Instant::now() + Duration::from_secs(2);
        let connect_peer = || loop {
            match UnixStream::connect(&socket_path) {
                Ok(s) => {
                    s.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                    return s;
                }
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                Err(err) => panic!("connect failed: {err}"),
            }
        };

        let open = serde_json::to_vec(&crate::host::ExecOpen {
            command: "echo hi".into(),
            max_output_bytes: 1024,
        })
        .unwrap();

        // 1) Offline relay -> immediate "relay-offline".
        let mut offline_peer = connect_peer();
        Frame::new(b'x', 0, &open).send(&mut offline_peer).unwrap();
        let err = loop {
            let f = Frame::read(&mut offline_peer).unwrap();
            if f.kind != b'T' {
                break f;
            }
        };
        assert_eq!(err.kind, b'E');
        assert_eq!(err.data, b"relay-offline");
        drop(offline_peer);

        // 2) Online remote without exec/1 -> immediate "exec-unsupported".
        allow_connect.store(true, Ordering::SeqCst);
        retry_local(&socket_path, false).unwrap();
        let wait_deadline = Instant::now() + Duration::from_secs(2);
        let unsupported = loop {
            let mut peer = connect_peer();
            Frame::new(b'x', 0, &open).send(&mut peer).unwrap();
            let f = loop {
                let f = Frame::read(&mut peer).unwrap();
                if f.kind != b'T' {
                    break f;
                }
            };
            if f.kind == b'E' && f.data == b"exec-unsupported" {
                break f;
            }
            assert!(Instant::now() < wait_deadline);
            thread::sleep(Duration::from_millis(20));
        };
        assert_eq!(unsupported.data, b"exec-unsupported");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn exec_stream_handles_remote_disconnect_early_local_close_and_large_flush() {
        use std::os::unix::fs::DirBuilderExt;

        let dir = PathBuf::from(format!(
            "/tmp/omg-client-exec-flow-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .unwrap();
        let socket_path = dir.join("relay.sock");
        let conn_num = Arc::new(AtomicUsize::new(0));
        let conn_srv = conn_num.clone();
        let (quit_tx, quit_rx) = mpsc::channel::<u64>();
        let (drop_tx, drop_rx) = mpsc::channel::<mpsc::Sender<()>>();

        let connector: Connector = Arc::new(move |_| {
            let n = conn_srv.fetch_add(1, Ordering::SeqCst);
            let (client_side, mut server_side) = UnixStream::pair()?;
            let quit_tx = quit_tx.clone();
            let drop_tx = drop_tx.clone();
            thread::spawn(move || {
                let caps = b"strict-open/1,durable-close/1,exec/1";
                let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                let (trigger_drop_tx, trigger_drop_rx) = mpsc::channel::<()>();
                let _ = drop_tx.send(trigger_drop_tx);
                while let Ok(frame) = Frame::read(&mut server_side) {
                    match frame.kind {
                        b'P' => {
                            let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                        }
                        b'L' => {
                            let _ = Frame::new(b'L', 0, b"[]").send(&mut server_side);
                        }
                        b'x' => {
                            let req: crate::host::ExecOpen =
                                serde_json::from_slice(&frame.data).unwrap();
                            if req.command == "large" {
                                // Send > 4 MiB output across multiple frames then exit 0 to verify
                                // client flushes all queued bytes before dropping control_done peer.
                                let chunk = vec![b'X'; 512 * 1024];
                                for _ in 0..10 {
                                    let _ = Frame::new(
                                        b'D',
                                        frame.seq,
                                        &Frame::new(b'o', 0, &chunk).encode(),
                                    )
                                    .send(&mut server_side);
                                }
                                let _ = Frame::new(
                                    b'D',
                                    frame.seq,
                                    &Frame::new(b'x', 0, b"0").encode(),
                                )
                                .send(&mut server_side);
                                let _ = Frame::new(b'Q', frame.seq, &[]).send(&mut server_side);
                            } else if req.command == "stay-open" {
                                let _ = Frame::new(
                                    b'D',
                                    frame.seq,
                                    &Frame::new(b'o', 0, b"started").encode(),
                                )
                                .send(&mut server_side);
                            } else if req.command == "wait-disconnect" && n == 0 {
                                let _ = Frame::new(
                                    b'D',
                                    frame.seq,
                                    &Frame::new(b'o', 0, b"started").encode(),
                                )
                                .send(&mut server_side);
                                // Wait for test to trigger sudden remote disconnect.
                                let _ = trigger_drop_rx.recv_timeout(Duration::from_secs(2));
                                break;
                            }
                        }
                        b'Q' => {
                            let _ = quit_tx.send(frame.seq);
                        }
                        _ => {}
                    }
                }
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });

        let socket_clone = socket_path.clone();
        thread::spawn(move || {
            let _ = supervise(&socket_clone, connector, false);
        });

        let deadline = Instant::now() + Duration::from_secs(2);
        let connect_peer = || loop {
            match UnixStream::connect(&socket_path) {
                Ok(s) => {
                    s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
                    return s;
                }
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                Err(err) => panic!("connect failed: {err}"),
            }
        };

        let trigger_drop = drop_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let ready_deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match list_local(&socket_path) {
                Ok(_) => break,
                Err(_) if Instant::now() < ready_deadline => {
                    thread::sleep(Duration::from_millis(5));
                }
                Err(err) => panic!("relay failed to become capability-ready: {err}"),
            }
        }

        // 1) Large (> 4 MiB) output followed immediately by b'x' must flush completely before close.
        let mut large_peer = connect_peer();
        let large_open = serde_json::to_vec(&crate::host::ExecOpen {
            command: "large".into(),
            max_output_bytes: 16 * 1024 * 1024,
        })
        .unwrap();
        Frame::new(b'x', 0, &large_open)
            .send(&mut large_peer)
            .unwrap();
        let mut total_bytes = 0usize;
        let exit_frame = loop {
            let f = Frame::read(&mut large_peer).unwrap();
            match f.kind {
                b'T' => {}
                b'o' => total_bytes += f.data.len(),
                b'x' => break f,
                other => panic!("unexpected frame {other}"),
            }
        };
        assert_eq!(total_bytes, 10 * 512 * 1024);
        assert_eq!(exit_frame.data, b"0");
        drop(large_peer);

        // 2) Early local peer disconnect sends outer b'Q' to remote.
        let mut cancel_peer = connect_peer();
        let cancel_open = serde_json::to_vec(&crate::host::ExecOpen {
            command: "stay-open".into(),
            max_output_bytes: 1024,
        })
        .unwrap();
        Frame::new(b'x', 0, &cancel_open)
            .send(&mut cancel_peer)
            .unwrap();
        let started = loop {
            let f = Frame::read(&mut cancel_peer).unwrap();
            if f.kind != b'T' {
                break f;
            }
        };
        assert_eq!(started.kind, b'o');
        assert_eq!(started.data, b"started");
        drop(cancel_peer);
        let cancelled_stream = quit_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_ne!(cancelled_stream, 0);

        // 3) Remote disconnect mid-exec delivers b'E' "exec-disconnected".
        let mut inflight_peer = connect_peer();
        let inflight_open = serde_json::to_vec(&crate::host::ExecOpen {
            command: "wait-disconnect".into(),
            max_output_bytes: 1024,
        })
        .unwrap();
        Frame::new(b'x', 0, &inflight_open)
            .send(&mut inflight_peer)
            .unwrap();
        let started = loop {
            let f = Frame::read(&mut inflight_peer).unwrap();
            if f.kind != b'T' {
                break f;
            }
        };
        assert_eq!(started.kind, b'o');
        assert_eq!(started.data, b"started");
        let _ = trigger_drop.send(());
        let disc_err = loop {
            let f = Frame::read(&mut inflight_peer).unwrap();
            if f.kind != b'T' {
                break f;
            }
        };
        assert_eq!(disc_err.kind, b'E');
        assert_eq!(disc_err.data, b"exec-disconnected");
        drop(inflight_peer);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn init_size_and_remote_env_are_gated_on_capabilities_and_session_creation() {
        let req = OpenRequest {
            id: "d2956168-0ade-4c3e-ade4-3bc908d7dfdf".into(),
            policy: Policy::default(),
            create: true,
            cols: Some(120),
            rows: Some(36),
            pixel_width: Some(1200),
            pixel_height: Some(720),
            term: Some("xterm-ghostty".into()),
            colorterm: Some("truecolor".into()),
            term_program: Some("ghostty".into()),
            term_program_version: Some("1.3.2-dev".into()),
            color_scheme: Some("dark".into()),
            foreground: Some([0xff, 0xff, 0xff]),
            background: Some([0x28, 0x2c, 0x34]),
            cursor: Some([0xff, 0xff, 0xff]),
            ..Default::default()
        };
        let (sock, _other) = UnixStream::pair().unwrap();
        let mut peer = super::LocalPeer::new(super::Peer::new(sock, 1).unwrap(), 1);
        peer.open = Some(serde_json::to_vec(&req).unwrap());

        // Legacy host without init-size/1 or remote-env/1: must strip all new fields cleanly.
        let legacy_caps = super::RemoteCapabilities::default();
        let (_, encoded_legacy) = super::open_request(&peer, &legacy_caps).unwrap();
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        #[allow(dead_code)]
        struct PinnedLegacyOpen {
            id: String,
            policy: Policy,
            create: bool,
            cwd: Option<String>,
            launch: Option<crate::registry::LocalLaunchSpec>,
        }
        assert!(serde_json::from_slice::<PinnedLegacyOpen>(&encoded_legacy).is_ok());

        // Modern host advertising init-size/1 and remote-env/1: forwards all create fields.
        let mut modern_caps = super::RemoteCapabilities::default();
        modern_caps.update(b"init-size/1,remote-env/1,recreate-if-gone/1");
        let (_, encoded_modern) = super::open_request(&peer, &modern_caps).unwrap();
        let parsed: OpenRequest = serde_json::from_slice(&encoded_modern).unwrap();
        assert_eq!(parsed.cols, Some(120));
        assert_eq!(parsed.rows, Some(36));
        assert_eq!(parsed.term.as_deref(), Some("xterm-ghostty"));
        assert_eq!(parsed.colorterm.as_deref(), Some("truecolor"));

        // Confirmed reattach omits create-only size/env metadata.
        peer.snapshot_confirmed = true;
        let (_, encoded_reattach) = super::open_request(&peer, &modern_caps).unwrap();
        assert!(serde_json::from_slice::<PinnedLegacyOpen>(&encoded_reattach).is_ok());
    }

    #[test]
    fn handoff_resume_open_request_is_gated_by_capability_and_cleared_after_snapshot() {
        let req = OpenRequest {
            id: "22222222-2222-2222-2222-222222222222".into(),
            policy: Policy::default(),
            create: true,
            cwd: Some("/srv/app".into()),
            resume: Some(crate::record::Resume {
                agent: "antigravity".into(),
                conversation_id: "conv-abc".into(),
                cwd: "/srv/app".into(),
            }),
            ..Default::default()
        };
        let (sock, _other) = UnixStream::pair().unwrap();
        let mut peer = super::LocalPeer::new(super::Peer::new(sock, 1).unwrap(), 1);
        peer.open = Some(serde_json::to_vec(&req).unwrap());

        let legacy_caps = super::RemoteCapabilities::default();
        let (_, encoded_legacy) = super::open_request(&peer, &legacy_caps).unwrap();
        let parsed_legacy: OpenRequest = serde_json::from_slice(&encoded_legacy).unwrap();
        assert!(parsed_legacy.resume.is_none());

        let mut modern_caps = super::RemoteCapabilities::default();
        modern_caps.update(b"handoff-resume/1");
        let (_, encoded_modern) = super::open_request(&peer, &modern_caps).unwrap();
        let parsed_modern: OpenRequest = serde_json::from_slice(&encoded_modern).unwrap();
        assert_eq!(
            parsed_modern
                .resume
                .as_ref()
                .map(|r| r.conversation_id.as_str()),
            Some("conv-abc")
        );

        peer.snapshot_confirmed = true;
        let (_, encoded_reattach) = super::open_request(&peer, &modern_caps).unwrap();
        let parsed_reattach: OpenRequest = serde_json::from_slice(&encoded_reattach).unwrap();
        assert!(parsed_reattach.resume.is_none());
    }

    #[test]
    fn session_gone_never_auto_recreates_and_recreate_grant_arms_once() {
        use super::{recreate_local, RecreateRequest};
        use crate::SNAPSHOT;
        use std::os::unix::fs::DirBuilderExt;
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Mutex,
        };

        let dir = PathBuf::from(format!(
            "/tmp/omg-client-recreate-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .unwrap();
        let socket_path = dir.join("relay.sock");
        let rebooted = Arc::new(AtomicBool::new(false));
        let rebooted_srv = rebooted.clone();
        let observed = Arc::new(Mutex::new(Vec::<OpenRequest>::new()));
        let observed_srv = observed.clone();
        let (drop_tx, drop_rx) = mpsc::channel::<mpsc::Sender<()>>();

        let connector: Connector = Arc::new(move |_| {
            let (client_side, mut server_side) = UnixStream::pair()?;
            let rebooted = rebooted_srv.clone();
            let observed = observed_srv.clone();
            let drop_tx = drop_tx.clone();
            thread::spawn(move || {
                let caps =
                    b"strict-open/1,durable-close/1,recreate-if-gone/1,init-size/1,remote-env/1,handoff-resume/1";
                let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                let server_kill = server_side.try_clone().unwrap();
                let (kill_tx, kill_rx) = mpsc::channel::<()>();
                thread::spawn(move || {
                    if kill_rx.recv().is_ok() {
                        let _ = server_kill.shutdown(std::net::Shutdown::Both);
                    }
                });
                let _ = drop_tx.send(kill_tx);
                while let Ok(frame) = Frame::read(&mut server_side) {
                    match frame.kind {
                        b'P' => {
                            let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                        }
                        b'C' => {
                            assert!(
                                !std::str::from_utf8(&frame.data)
                                    .unwrap()
                                    .contains("hold_on_session_gone"),
                                "hold_on_session_gone must never be sent to remote host"
                            );
                            let req: OpenRequest = serde_json::from_slice(&frame.data).unwrap();
                            let spawns = req.create || req.recreate_if_gone;
                            observed.lock().unwrap().push(req);
                            if rebooted.load(Ordering::SeqCst) && !spawns {
                                let _ = Frame::new(
                                    b'E',
                                    frame.seq,
                                    b"session ended: Some(Lost); inspect its record before resuming",
                                )
                                .send(&mut server_side);
                            } else {
                                rebooted.store(false, Ordering::SeqCst);
                                let _ = Frame::new(
                                    b'D',
                                    frame.seq,
                                    &Frame::new(SNAPSHOT, 1, b"snap").encode(),
                                )
                                .send(&mut server_side);
                            }
                        }
                        b'D' => {
                            if let Ok(inner) = Frame::read(&mut frame.data.as_slice()) {
                                if inner.kind == crate::CLAIM {
                                    let _ = Frame::new(
                                        b'D',
                                        frame.seq,
                                        &Frame::new(crate::CLAIM, inner.seq, &[]).encode(),
                                    )
                                    .send(&mut server_side);
                                }
                            }
                        }
                        _ => {}
                    }
                }
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });

        let socket_clone = socket_path.clone();
        thread::spawn(move || {
            let _ = supervise(&socket_clone, connector, false);
        });
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut peer = loop {
            match UnixStream::connect(&socket_path) {
                Ok(s) => break s,
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
                Err(err) => panic!("connect failed: {err}"),
            }
        };
        peer.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let pane_id = "11111111-2222-4333-8444-555555555555";
        let open = OpenRequest {
            id: pane_id.into(),
            policy: Policy::default(),
            create: true,
            cwd: Some("/srv/initial".into()),
            hold_on_session_gone: true,
            ..Default::default()
        };
        Frame::new(b'H', 0, &serde_json::to_vec(&open).unwrap())
            .send(&mut peer)
            .unwrap();
        let kill_first = drop_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        loop {
            let f = Frame::read(&mut peer).unwrap();
            if f.kind == SNAPSHOT {
                break;
            }
        }

        // Simulate remote host reboot and drop transport.
        rebooted.store(true, Ordering::SeqCst);
        let _ = kill_first.send(());
        let kill_second = drop_rx.recv_timeout(Duration::from_secs(2)).unwrap();

        let gone_status = loop {
            let f = Frame::read(&mut peer).unwrap();
            assert_ne!(
                f.kind, b'E',
                "hold_on_session_gone peer must stay parked without b'E'"
            );
            if f.kind == b'T' {
                let v: serde_json::Value = serde_json::from_slice(&f.data).unwrap();
                if v["session_gone"] == true {
                    break v;
                }
            }
        };
        assert_eq!(gone_status["state"], "session_gone");

        // Ordinary retry_local MUST still keep create=false and recreate_if_gone=false!
        retry_local(&socket_path, true).unwrap();
        loop {
            let f = Frame::read(&mut peer).unwrap();
            assert_ne!(f.kind, b'E');
            if f.kind == b'T' {
                let v: serde_json::Value = serde_json::from_slice(&f.data).unwrap();
                if v["session_gone"] == true {
                    break;
                }
            }
        }

        // Explicit one-shot recreate_local (`b'y'` recreate/1) arms recreate_if_gone=true once!
        recreate_local(
            &socket_path,
            &RecreateRequest {
                version: "recreate/1".into(),
                id: pane_id.into(),
                cwd: Some("/srv/live-cwd".into()),
                cols: Some(132),
                rows: Some(42),
                pixel_width: Some(1320),
                pixel_height: Some(840),
                term: Some("xterm-ghostty".into()),
                colorterm: Some("truecolor".into()),
                term_program: Some("ghostty".into()),
                term_program_version: Some("0.25.3".into()),
                color_scheme: Some("dark".into()),
                foreground: Some([0xee, 0xee, 0xee]),
                background: Some([0x11, 0x11, 0x11]),
                cursor: Some([0xff, 0xaa, 0x00]),
                resume: Some(crate::record::Resume {
                    agent: "codex".into(),
                    conversation_id: "conv-89".into(),
                    cwd: "/srv/live-cwd".into(),
                }),
                interactive: Some(true),
            },
        )
        .unwrap();

        let mut peer_gen = 0u64;
        let snap_seq = loop {
            let f = Frame::read(&mut peer).unwrap();
            if f.kind == b'T' {
                peer_gen = f.seq;
            } else if f.kind == SNAPSHOT {
                break f.seq;
            }
        };
        Frame::new(crate::ACK, snap_seq, &peer_gen.to_be_bytes())
            .send(&mut peer)
            .unwrap();
        Frame::new(crate::CLAIM, peer_gen, &[])
            .send(&mut peer)
            .unwrap();
        loop {
            let f = Frame::read(&mut peer).unwrap();
            if f.kind == crate::CLAIM {
                break;
            }
        }

        // Subsequent disconnect after SNAPSHOT MUST NOT reuse the consumed RecreateGrant!
        let _ = kill_second.send(());
        let _kill_third = drop_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        loop {
            let f = Frame::read(&mut peer).unwrap();
            if f.kind == SNAPSHOT {
                break;
            }
        }

        let log = observed.lock().unwrap();
        assert_eq!(log.len(), 5);
        assert!(log[0].create && !log[0].recreate_if_gone);
        assert!(!log[1].create && !log[1].recreate_if_gone); // auto reconnect after reboot
        assert!(!log[2].create && !log[2].recreate_if_gone); // manual retry_local
        assert!(!log[3].create && log[3].recreate_if_gone); // explicit recreate/1 grant
        assert_eq!(log[3].cwd.as_deref(), Some("/srv/live-cwd"));
        assert_eq!(log[3].cols, Some(132));
        assert_eq!(log[3].rows, Some(42));
        assert_eq!(
            log[3].resume.as_ref().map(|r| r.conversation_id.as_str()),
            Some("conv-89")
        );
        assert!(!log[4].create && !log[4].recreate_if_gone); // grant cleared after SNAPSHOT!
        assert!(log[4].resume.is_none());
        assert!(log[4].cols.is_none());

        drop(peer);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn recreate_grant_survives_relay_restart_race_and_direct_peer_frame_and_legacy_fallback() {
        use super::{is_session_gone_error, recreate_local, RecreateRequest};
        use crate::SNAPSHOT;
        use std::os::unix::fs::DirBuilderExt;
        use std::sync::Mutex;

        assert!(is_session_gone_error(b"unknown session; cannot resume"));
        assert!(is_session_gone_error(
            b"session ended: Some(Lost); inspect its record before resuming"
        ));
        assert!(!is_session_gone_error(b"session explicitly closed"));
        assert!(!is_session_gone_error(b"local session ended: Lost"));

        let dir = PathBuf::from(format!(
            "/tmp/omg-client-race-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .unwrap();
        let socket_path = dir.join("relay.sock");
        let observed = Arc::new(Mutex::new(Vec::<(bool, bool, Option<String>)>::new()));
        let observed_srv = observed.clone();
        let legacy_mode = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let legacy_srv = legacy_mode.clone();

        let connector: Connector = Arc::new(move |_| {
            let (client_side, mut server_side) = UnixStream::pair()?;
            let observed = observed_srv.clone();
            let legacy = legacy_srv.clone();
            thread::spawn(move || {
                let caps: &[u8] = if legacy.load(Ordering::SeqCst) {
                    b"strict-open/1,durable-close/1"
                } else {
                    b"strict-open/1,durable-close/1,recreate-if-gone/1"
                };
                let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                while let Ok(frame) = Frame::read(&mut server_side) {
                    match frame.kind {
                        b'P' => {
                            let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                        }
                        b'C' => {
                            let req: OpenRequest = serde_json::from_slice(&frame.data).unwrap();
                            let spawns = req.create || req.recreate_if_gone;
                            observed.lock().unwrap().push((
                                req.create,
                                req.recreate_if_gone,
                                req.cwd.clone(),
                            ));
                            if !spawns {
                                let _ =
                                    Frame::new(b'E', frame.seq, b"unknown session; cannot resume")
                                        .send(&mut server_side);
                            } else {
                                let _ = Frame::new(
                                    b'D',
                                    frame.seq,
                                    &Frame::new(SNAPSHOT, 1, b"snap").encode(),
                                )
                                .send(&mut server_side);
                            }
                        }
                        _ => {}
                    }
                }
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });

        let socket_clone = socket_path.clone();
        thread::spawn(move || {
            let _ = supervise(&socket_clone, connector, false);
        });

        // 1) Relay-restart race: `recreate_local` arrives while `peers` is completely empty!
        let race_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        recreate_local(
            &socket_path,
            &RecreateRequest {
                version: "recreate/1".into(),
                id: race_id.into(),
                cwd: Some("/srv/after-idle-restart".into()),
                ..Default::default()
            },
        )
        .unwrap();

        // SessionBackend.zig then connects with attachOnly(race_id) (`create: false, recreate_if_gone: false`)
        // and consumes the held RecreateGrant once!
        let mut peer1 = UnixStream::connect(&socket_path).unwrap();
        peer1
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let attach_only = OpenRequest {
            id: race_id.into(),
            policy: Policy::default(),
            create: false,
            hold_on_session_gone: true,
            ..Default::default()
        };
        Frame::new(b'H', 0, &serde_json::to_vec(&attach_only).unwrap())
            .send(&mut peer1)
            .unwrap();
        loop {
            let f = Frame::read(&mut peer1).unwrap();
            if f.kind == SNAPSHOT {
                break;
            }
        }
        drop(peer1);

        // 2) Direct `b'y'` on an existing LocalPeer stream (inline.rs style):
        let inline_id = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff";
        let mut peer2 = UnixStream::connect(&socket_path).unwrap();
        peer2
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let inline_open = OpenRequest {
            id: inline_id.into(),
            policy: Policy::default(),
            create: false,
            inline_viewer: false,
            hold_on_session_gone: true,
            ..Default::default()
        };
        Frame::new(b'H', 0, &serde_json::to_vec(&inline_open).unwrap())
            .send(&mut peer2)
            .unwrap();
        loop {
            let f = Frame::read(&mut peer2).unwrap();
            if f.kind == b'T' {
                let v: serde_json::Value = serde_json::from_slice(&f.data).unwrap();
                if v["session_gone"] == true {
                    break;
                }
            }
        }
        let direct_recreate = RecreateRequest {
            version: "recreate/1".into(),
            id: inline_id.into(),
            cwd: Some("/srv/inline-recreate".into()),
            ..Default::default()
        };
        Frame::new(b'y', 0, &serde_json::to_vec(&direct_recreate).unwrap())
            .send(&mut peer2)
            .unwrap();
        loop {
            let f = Frame::read(&mut peer2).unwrap();
            assert_ne!(
                f.kind, b'y',
                "session stream must never receive control ack frame b'y'"
            );
            if f.kind == SNAPSHOT {
                break;
            }
        }
        drop(peer2);

        // 3) Legacy remote without recreate-if-gone/1 falls back to one-shot create=true!
        legacy_mode.store(true, Ordering::SeqCst);
        let legacy_dir = PathBuf::from(format!(
            "/tmp/omg-client-legacy-grant-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&legacy_dir)
            .unwrap();
        let legacy_sock = legacy_dir.join("relay.sock");
        let legacy_observed = Arc::new(Mutex::new(Vec::<(bool, bool)>::new()));
        let legacy_obs_srv = legacy_observed.clone();
        let legacy_connector: Connector = Arc::new(move |_| {
            let (client_side, mut server_side) = UnixStream::pair()?;
            let obs = legacy_obs_srv.clone();
            thread::spawn(move || {
                let caps = b"strict-open/1,durable-close/1";
                let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                while let Ok(frame) = Frame::read(&mut server_side) {
                    if frame.kind == b'P' {
                        let _ = Frame::new(b'P', 0, caps).send(&mut server_side);
                    } else if frame.kind == b'C' {
                        let req: OpenRequest = serde_json::from_slice(&frame.data).unwrap();
                        obs.lock().unwrap().push((req.create, req.recreate_if_gone));
                        let _ =
                            Frame::new(b'D', frame.seq, &Frame::new(SNAPSHOT, 1, b"snap").encode())
                                .send(&mut server_side);
                    }
                }
            });
            Ok(RelayTransport {
                socket: client_side,
                guard: Box::new(()),
            })
        });
        let legacy_sock_clone = legacy_sock.clone();
        thread::spawn(move || {
            let _ = supervise(&legacy_sock_clone, legacy_connector, false);
        });
        let legacy_id = "cccccccc-dddd-4eee-8fff-000000000000";
        recreate_local(
            &legacy_sock,
            &RecreateRequest {
                version: "recreate/1".into(),
                id: legacy_id.into(),
                cwd: Some("/srv/legacy".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let mut peer3 = UnixStream::connect(&legacy_sock).unwrap();
        peer3
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        Frame::new(
            b'H',
            0,
            &serde_json::to_vec(&OpenRequest {
                id: legacy_id.into(),
                policy: Policy::default(),
                create: false,
                hold_on_session_gone: true,
                ..Default::default()
            })
            .unwrap(),
        )
        .send(&mut peer3)
        .unwrap();
        loop {
            let f = Frame::read(&mut peer3).unwrap();
            if f.kind == SNAPSHOT {
                break;
            }
        }
        drop(peer3);
        assert_eq!(*legacy_observed.lock().unwrap(), vec![(true, false)]);
        let _ = std::fs::remove_dir_all(&legacy_dir);

        let log = observed.lock().unwrap().clone();
        assert_eq!(
            log,
            vec![
                (false, true, Some("/srv/after-idle-restart".into())),
                (false, false, None),
                (false, true, Some("/srv/inline-recreate".into())),
            ]
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}
