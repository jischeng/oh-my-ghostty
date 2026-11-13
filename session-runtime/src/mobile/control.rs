//! Termio's existing companion UI contract projected onto omgd.
//! This control plane never attaches a PTY viewer to populate a list.
mod experience;
use super::{Config, Endpoint};
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::{SinkExt, StreamExt};
use omg_session_runtime::{activity, holder, record, Frame};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io::{self, Read, Write},
    os::unix::{
        fs::{DirBuilderExt, OpenOptionsExt},
        net::UnixStream,
    },
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant, UNIX_EPOCH},
};
use tokio_tungstenite::{tungstenite::Message, WebSocketStream};

const PERSONAL: &str = "00000000-0000-4000-8000-000000000001";
const FILE_LIMIT: usize = 1024 * 1024;
const AGENTS: [(&str, &str, &str); 4] = [
    ("codex", "Codex", "codex"),
    ("claude", "Claude Code", "claude"),
    ("pi", "Pi", "pi-favicon"),
    ("antigravity", "Antigravity", "antigravity-favicon"),
];

type SnapshotKey = (String, String);
type SnapshotEntry = (Instant, Option<activity::Snapshot>);

#[derive(Default)]
pub(super) struct State {
    cached: Mutex<Option<(Instant, Arc<View>)>>,
    phone: Mutex<Option<HashMap<String, PhoneMeta>>>,
    acknowledged: Mutex<Option<HashMap<String, AcknowledgedSession>>>,
    snapshots: Mutex<HashMap<SnapshotKey, SnapshotEntry>>,
}
#[derive(Clone, Serialize, Deserialize)]
struct AcknowledgedSession {
    generation: String,
    max_revision: u64,
}
#[derive(Clone, Serialize, Deserialize)]
struct PhoneMeta {
    generation: String,
    workspace: String,
    agent: String,
    #[serde(default)]
    project: Option<String>,
}
#[derive(Clone)]
struct Project {
    id: String,
    root: PathBuf,
    workspace: String,
    endpoint: Option<Endpoint>,
    host: Option<String>,
}
struct View {
    roster: Value,
    projects: HashMap<String, Project>,
}
#[derive(Default, Clone, Debug, PartialEq, Eq)]
struct PaneDesktopMeta {
    workspace: String,
    title: Option<String>,
    directory: Option<PathBuf>,
    remote_cwd: Option<String>,
    ssh_target: Option<omg_session_runtime::location::SshTarget>,
    agent: Option<String>,
    acknowledged_program: Option<(String, Option<String>)>,
    acknowledged_reducer: Option<(String, String)>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct InlineOwnerMeta {
    remote_session_id: String,
    ssh_target: omg_session_runtime::location::SshTarget,
}
#[derive(Clone)]
struct InlineRemoteSession {
    endpoint: Endpoint,
    session_id: String,
    generation: String,
    cwd: Option<String>,
    resume_agent: Option<String>,
}
#[derive(Default)]
struct Desktop {
    workspaces: Vec<(String, String)>,
    panes: HashMap<String, PaneDesktopMeta>,
    inline_owners: HashMap<String, InlineOwnerMeta>,
}

fn hash(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}
fn home() -> io::Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .ok_or_else(|| io::Error::other("HOME is unavailable"))
}
fn bounded(path: &Path, limit: usize) -> io::Result<Vec<u8>> {
    let mut file = fs::File::open(path)?;
    if file.metadata()?.len() > limit as u64 {
        return Err(io::Error::other("File exceeds limit"));
    }
    let mut bytes = Vec::new();
    std::io::Read::by_ref(&mut file)
        .take((limit + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(io::Error::other("File exceeds limit"));
    }
    Ok(bytes)
}
fn desktop(config: &Config) -> Desktop {
    let mut result = Desktop::default();
    if let Some(support) = &config.support {
        let state = bounded(&support.join("workspaces/state.json"), 32 * FILE_LIMIT)
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok());
        let catalog = state
            .as_ref()
            .and_then(|s| s.get("catalog"))
            .cloned()
            .or_else(|| {
                bounded(&support.join("workspaces/catalog.json"), 4 * FILE_LIMIT)
                    .ok()
                    .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            });
        if let Some(catalog) = catalog {
            if let Some(workspaces) = catalog["workspaces"].as_array() {
                for workspace in workspaces.iter().take(100) {
                    if let (Some(id), Some(name)) =
                        (workspace["id"].as_str(), workspace["name"].as_str())
                    {
                        if id.len() <= 128 && name.len() <= 160 {
                            result.workspaces.push((id.into(), name.into()));
                        }
                    }
                }
            }
        }
        if let Some(tabs) = state.as_ref().and_then(|s| s["tabs"].as_array()) {
            for tab in tabs.iter().take(2048) {
                if let (Some(workspace), Some(data)) =
                    (tab["workspace"].as_str(), tab["state"].as_str())
                {
                    if let Ok(bytes) = STANDARD.decode(data) {
                        if bytes.len() <= FILE_LIMIT {
                            if let Ok(state) = serde_json::from_slice::<Value>(&bytes) {
                                collect_panes(
                                    &state["surfaceTree"]["root"],
                                    workspace,
                                    0,
                                    &mut result.panes,
                                );
                            }
                        }
                    }
                }
            }
        }
        collect_inline_owners(support, &mut result.inline_owners);
    }
    if result.workspaces.is_empty() {
        result.workspaces.push((PERSONAL.into(), "Personal".into()));
    }
    result
}
fn collect_inline_owners(support: &Path, out: &mut HashMap<String, InlineOwnerMeta>) {
    let Ok(entries) = fs::read_dir(support.join("session-runtime/inline-owners")) else {
        return;
    };
    for entry in entries.take(512).flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let remote_session_id = path
            .file_stem()
            .and_then(|s| s.to_str())
            .filter(|id| omg_session_runtime::host::valid_id(id))
            .unwrap_or_default()
            .to_owned();
        let Ok(bytes) = bounded(&path, 32 * 1024) else {
            continue;
        };
        let Ok(owner) = serde_json::from_slice::<Value>(&bytes) else {
            continue;
        };
        let Some(local_pane) = owner["localPane"]
            .as_str()
            .filter(|id| omg_session_runtime::host::valid_id(id))
        else {
            continue;
        };
        let conn = &owner["descriptor"]["connection"];
        let Some(destination) = conn["destination"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 256)
        else {
            continue;
        };
        let options = conn["options"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect::<Vec<_>>();
        let active_cwd = owner["activeRecord"]
            .as_str()
            .map(Path::new)
            .filter(|p| p.is_absolute())
            .and_then(|p| bounded(p, 16 * 1024).ok())
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|rec| {
                rec["workingDirectory"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() <= 4096)
                    .map(str::to_owned)
            });
        let launch_cwd = owner["descriptor"]["launchWorkingDirectory"]
            .as_str()
            .filter(|s| !s.is_empty() && (s.starts_with('/') || s.starts_with('~')))
            .map(str::to_owned);
        out.insert(
            local_pane.to_ascii_lowercase(),
            InlineOwnerMeta {
                remote_session_id,
                ssh_target: omg_session_runtime::location::SshTarget {
                    destination: destination.to_owned(),
                    options,
                    remote_cwd: active_cwd.or(launch_cwd),
                },
            },
        );
    }
}
fn resolve_inline_relays(
    config: &Config,
    inline_owners: &HashMap<String, InlineOwnerMeta>,
) -> HashMap<String, InlineRemoteSession> {
    let mut resolved = HashMap::new();
    let Some(support) = config.support.as_deref() else {
        return resolved;
    };
    let wanted: std::collections::BTreeSet<&str> = inline_owners
        .values()
        .map(|io| io.remote_session_id.as_str())
        .filter(|id| !id.is_empty())
        .collect();
    if wanted.is_empty() {
        return resolved;
    }
    let mut queried_hosts: std::collections::BTreeSet<(PathBuf, String, Vec<String>)> =
        std::collections::BTreeSet::new();
    for (bundle, sock_path, ssh_target) in crate::session_cli::mobile_inline_relay_targets(support)
    {
        let host_key = (
            bundle,
            ssh_target.destination.clone(),
            ssh_target.options.clone(),
        );
        if queried_hosts.contains(&host_key) {
            continue;
        }
        let Ok(sessions) = list_relay_with_timeout(&sock_path, Duration::from_millis(400)) else {
            continue;
        };
        queried_hosts.insert(host_key);
        let endpoint = Endpoint {
            id: format!("inline-{}", &hash(&sock_path.to_string_lossy())[..12]),
            name: format!("SSH · {}", ssh_target.destination),
            socket: sock_path,
            relay: Some(ssh_target),
        };
        for s in sessions {
            if s.ended.is_none() && wanted.contains(s.id.as_str()) {
                resolved.insert(
                    s.id.clone(),
                    InlineRemoteSession {
                        endpoint: endpoint.clone(),
                        session_id: s.id,
                        generation: s.generation,
                        cwd: s.cwd,
                        resume_agent: s
                            .resume
                            .map(|r| normalize_agent(&r.agent))
                            .filter(|a| !a.is_empty()),
                    },
                );
            }
        }
        if resolved.len() >= wanted.len() {
            break;
        }
    }
    resolved
}
fn collect_panes(
    node: &Value,
    workspace: &str,
    depth: usize,
    result: &mut HashMap<String, PaneDesktopMeta>,
) {
    if depth >= 64 || result.len() >= 4096 {
        return;
    }
    if let Some(pane) = node.get("view") {
        if let Some(id) = pane["uuid"]
            .as_str()
            .filter(|id| omg_session_runtime::host::valid_id(id))
        {
            let title = pane["title"]
                .as_str()
                .filter(|s| s.len() <= 512 && !s.chars().any(char::is_control));
            let is_remote_runtime = !pane["runtimeDescriptor"]["connection"].is_null();
            let directory = if !is_remote_runtime {
                pane["pwd"]
                    .as_str()
                    .or_else(|| {
                        (pane["agentResumeDescriptor"]["scope"].as_str() != Some("remote"))
                            .then(|| pane["agentResumeDescriptor"]["workingDirectory"].as_str())
                            .flatten()
                    })
                    .filter(|s| s.len() <= 4096 && Path::new(s).is_absolute())
                    .map(PathBuf::from)
                    .filter(|p| p.is_dir())
            } else {
                None
            };
            let remote_cwd = if is_remote_runtime {
                pane["pwd"]
                    .as_str()
                    .or_else(|| pane["runtimeDescriptor"]["launchWorkingDirectory"].as_str())
                    .or_else(|| pane["runtimeDescriptor"]["initialWorkingDirectory"].as_str())
                    .or_else(|| pane["sshResumeDescriptor"]["remoteWorkingDirectory"].as_str())
            } else {
                pane["sshResumeDescriptor"]["remoteWorkingDirectory"]
                    .as_str()
                    .or_else(|| {
                        (pane["agentResumeDescriptor"]["scope"].as_str() == Some("remote"))
                            .then(|| pane["agentResumeDescriptor"]["workingDirectory"].as_str())
                            .flatten()
                    })
            }
            .filter(|s| {
                !s.is_empty() && s.len() <= 4096 && (s.starts_with('/') || s.starts_with('~'))
            })
            .map(str::to_owned);
            let ssh_target = if is_remote_runtime {
                let conn = &pane["runtimeDescriptor"]["connection"];
                conn["destination"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() <= 256)
                    .map(|dest| omg_session_runtime::location::SshTarget {
                        destination: dest.to_owned(),
                        options: conn["options"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|v| v.as_str().map(str::to_owned))
                            .collect(),
                        remote_cwd: remote_cwd.clone(),
                    })
            } else {
                pane["sshResumeDescriptor"]["sshReplay"]["args"]
                    .as_array()
                    .or_else(|| pane["agentResumeDescriptor"]["sshReplay"]["args"].as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(str::to_owned))
                            .collect::<Vec<_>>()
                    })
                    .and_then(|args| omg_session_runtime::location::parse_ssh_args(&args))
                    .map(|mut t| {
                        if t.remote_cwd.is_none() {
                            t.remote_cwd = remote_cwd.clone();
                        }
                        t
                    })
            };
            let agent = pane["agentResumeDescriptor"]["agent"]
                .as_str()
                .map(normalize_agent)
                .filter(|s| !s.is_empty());
            let acknowledged_program = pane["acknowledgedAgentStatus"]["program"]
                .as_object()
                .and_then(|prog| {
                    let record_id = prog.get("id")?.as_str()?.to_owned();
                    let agent = prog
                        .get("agent")
                        .and_then(Value::as_str)
                        .map(normalize_agent)
                        .filter(|s| !s.is_empty());
                    Some((record_id, agent))
                });
            let acknowledged_reducer = pane["acknowledgedAgentStatus"]["reducer"]
                .as_object()
                .and_then(|red| {
                    let context_id = red.get("contextID")?.as_str()?.to_owned();
                    let source = normalize_agent(red.get("source")?.as_str()?);
                    (!context_id.is_empty() && !source.is_empty()).then_some((context_id, source))
                });
            result.insert(
                id.to_ascii_lowercase(),
                PaneDesktopMeta {
                    workspace: workspace.into(),
                    title: title.map(str::to_owned),
                    directory,
                    remote_cwd,
                    ssh_target,
                    agent,
                    acknowledged_program,
                    acknowledged_reducer,
                },
            );
        }
    } else if let Some(split) = node.get("split") {
        collect_panes(&split["left"], workspace, depth + 1, result);
        collect_panes(&split["right"], workspace, depth + 1, result);
    }
}

fn project_root(cwd: &Path) -> (PathBuf, String) {
    let cwd = fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_owned());
    for ancestor in cwd.ancestors() {
        let marker = ancestor.join(".git");
        let git = if marker.is_dir() {
            Some(marker)
        } else {
            bounded(&marker, 4096)
                .ok()
                .and_then(|b| String::from_utf8(b).ok())
                .and_then(|s| s.trim().strip_prefix("gitdir: ").map(|p| ancestor.join(p)))
        };
        if let Some(git) = git {
            let branch = bounded(&git.join("HEAD"), 4096)
                .ok()
                .and_then(|b| String::from_utf8(b).ok())
                .map(|s| {
                    s.trim()
                        .strip_prefix("ref: refs/heads/")
                        .unwrap_or(s.trim())
                        .to_owned()
                })
                .unwrap_or_default();
            return (ancestor.to_owned(), branch);
        }
    }
    (cwd, String::new())
}
fn fields(text: &str, separator: char) -> HashMap<&str, &str> {
    text.split(separator)
        .filter_map(|p| p.split_once('='))
        .map(|(k, v)| (k.trim(), v.trim()))
        .collect()
}
fn normalize_agent(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "agy" | "jetski" | "jetski-cli" | "antigravity-cli" => "antigravity".into(),
        other => other.into(),
    }
}
fn decode_percent_value(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(byte) = u8::from_str_radix(hex, 16) {
                    out.push(byte);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
fn local_signal_cwd(snapshot: &activity::Snapshot) -> Option<PathBuf> {
    snapshot.records.iter().rev().find_map(|signal| {
        if !signal.id.starts_with("omg-agent-") {
            return None;
        }
        let parsed = fields(&signal.metadata, ';');
        if parsed.get("omg_scope") == Some(&"remote") {
            return None;
        }
        let raw = *parsed.get("omg_cwd")?;
        let decoded = decode_percent_value(raw);
        let path = PathBuf::from(decoded);
        (path.is_absolute() && path.is_dir()).then_some(path)
    })
}
fn apply_desktop_acknowledgement(snap: &mut activity::Snapshot, owner: &PaneDesktopMeta) {
    for signal in &mut snap.records {
        if signal.id == "omg-program-status" {
            let Some((ref ack_id, ref ack_agent)) = owner.acknowledged_program else {
                continue;
            };
            let parsed = fields(&signal.metadata, ':');
            let sig_id = parsed.get("id").copied().unwrap_or("");
            let sig_agent = parsed
                .get("app")
                .map(|a| normalize_agent(a))
                .filter(|s| !s.is_empty());
            let is_terminal = matches!(
                parsed.get("state").copied(),
                Some("done" | "completed" | "error" | "failed")
            );
            if is_terminal && sig_id == ack_id && &sig_agent == ack_agent {
                let mut tmp = activity::Snapshot {
                    version: snap.version,
                    revision: snap.revision,
                    records: vec![signal.clone()],
                    pending: None,
                    remote_host: None,
                    remote_cwd: None,
                };
                if tmp.acknowledge() {
                    if let Some(updated) = tmp.records.into_iter().next() {
                        *signal = updated;
                    }
                }
            }
        } else if let Some((ref ack_ctx, ref ack_source)) = owner.acknowledged_reducer {
            let parsed = fields(&signal.metadata, ';');
            let sig_source = parsed
                .get("omg_agent")
                .map(|a| normalize_agent(a))
                .unwrap_or_default();
            let is_terminal = matches!(
                parsed.get("omg_state").copied(),
                Some("done" | "completed" | "error" | "failed")
            );
            if is_terminal && &signal.id == ack_ctx && &sig_source == ack_source {
                let mut tmp = activity::Snapshot {
                    version: snap.version,
                    revision: snap.revision,
                    records: vec![signal.clone()],
                    pending: None,
                    remote_host: None,
                    remote_cwd: None,
                };
                if tmp.acknowledge() {
                    if let Some(updated) = tmp.records.into_iter().next() {
                        *signal = updated;
                    }
                }
            }
        }
    }
}
fn state_rank(state: &str) -> u8 {
    match state {
        "needsAttention" => 0,
        "working" => 1,
        "done" => 2,
        _ => 3,
    }
}
fn parse_signal_presentation(signal: &activity::Signal) -> Option<(bool, String, String, String)> {
    let native = signal.id == "omg-program-status";
    let fields = fields(&signal.metadata, if native { ':' } else { ';' });
    let agent = normalize_agent(fields.get(if native { "app" } else { "omg_agent" })?);
    let state = match *fields.get(if native { "state" } else { "omg_state" })? {
        "working" | "processing" | "active" => "working",
        "waiting" | "awaiting" | "blocked" | "needsAttention" | "error" | "failed" => {
            "needsAttention"
        }
        "done" | "completed" => "done",
        "idle" => "idle",
        _ => return None,
    };
    let message = if native {
        fields
            .get("msg")
            .and_then(|s| STANDARD.decode(s).ok())
            .and_then(|b| String::from_utf8(b).ok())
    } else {
        fields.get("message").map(|s| decode_percent_value(s))
    }
    .filter(|s| !s.is_empty())
    .unwrap_or_else(|| {
        match state {
            "working" => "Working",
            "needsAttention" => {
                if fields.get(if native { "kind" } else { "omg_attention" }) == Some(&"permission")
                {
                    "Waiting for permission"
                } else {
                    "Waiting for you"
                }
            }
            "done" => "Done",
            _ => "",
        }
        .into()
    });
    Some((native, agent, state.to_owned(), message))
}
fn presentation(snapshot: &activity::Snapshot) -> Option<(String, String, String)> {
    let mut last_native: Option<(String, String, String)> = None;
    let mut best_hook: Option<(String, String, String)> = None;
    for signal in &snapshot.records {
        let Some((native, agent, state, message)) = parse_signal_presentation(signal) else {
            continue;
        };
        if native {
            last_native = Some((agent, state, message));
        } else if best_hook
            .as_ref()
            .is_none_or(|(_, prev, _)| state_rank(&state) <= state_rank(prev))
        {
            best_hook = Some((agent, state, message));
        }
    }
    if let Some(program) = last_native {
        if program.1 != "idle" {
            return Some(program);
        }
        if let Some(fallback) = best_hook.filter(|f| f.1 != "idle") {
            return Some(fallback);
        }
        return Some(program);
    }
    best_hook
}
fn acknowledged_path(config: &Config) -> Option<PathBuf> {
    config
        .support
        .as_ref()
        .map(|p| p.join("mobile-acknowledged.json"))
        .or_else(|| {
            config
                .endpoints
                .first()?
                .socket
                .parent()
                .map(|p| p.join("mobile-acknowledged.json"))
        })
}
fn index_path(config: &Config) -> Option<PathBuf> {
    config
        .support
        .as_ref()
        .map(|p| p.join("mobile-sessions.json"))
        .or_else(|| {
            config
                .endpoints
                .first()?
                .socket
                .parent()
                .map(|p| p.join("mobile-sessions.json"))
        })
}

fn device_identity(config: &Config) -> io::Result<String> {
    let directory = config
        .support
        .clone()
        .or_else(|| {
            config
                .endpoints
                .first()?
                .socket
                .parent()
                .map(Path::to_owned)
        })
        .ok_or_else(|| io::Error::other("Mobile device identity has no state directory"))?;
    let path = directory.join("mobile-device-id");
    if !path.exists() {
        let temporary = directory.join(format!(".mobile-device-{}.tmp", record::nonce()?));
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temporary)?;
        let identity = record::nonce()?;
        file.write_all(identity.as_bytes())?;
        file.sync_all()?;
        let installed = fs::hard_link(&temporary, &path);
        let _ = fs::remove_file(&temporary);
        if let Err(error) = installed {
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error);
            }
        }
    }
    super::private(&path, false)?;
    let identity = String::from_utf8(bounded(&path, 64)?).map_err(io::Error::other)?;
    if identity.len() != 32 || !identity.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(io::Error::other("Invalid mobile device identity"));
    }
    Ok(format!("omgd-{identity}"))
}

fn computer_name() -> String {
    let mut bytes = [0 as libc::c_char; 256];
    if unsafe { libc::gethostname(bytes.as_mut_ptr(), 255) } == 0 {
        return unsafe { std::ffi::CStr::from_ptr(bytes.as_ptr()) }
            .to_string_lossy()
            .into_owned();
    }
    "Mac".into()
}
fn list_relay_with_timeout(
    socket_path: &Path,
    timeout: Duration,
) -> io::Result<Vec<record::SessionSummary>> {
    let mut socket = UnixStream::connect(socket_path)?;
    socket.set_read_timeout(Some(timeout))?;
    socket.set_write_timeout(Some(Duration::from_millis(800)))?;
    Frame::new(b'L', 0, &[]).send(&mut socket)?;
    loop {
        let frame = Frame::read(&mut socket)?;
        match frame.kind {
            b'T' | b'P' if frame.seq == 0 || frame.kind == b'T' => {}
            b'L' if frame.seq == 0 => {
                if frame.data.len() > 8 * FILE_LIMIT {
                    return Err(io::Error::other("Catalogue exceeds limit"));
                }
                return Ok(serde_json::from_slice(&frame.data)?);
            }
            b'E' => {
                return Err(io::Error::other(
                    String::from_utf8_lossy(&frame.data).into_owned(),
                ))
            }
            _ => return Err(io::Error::other("Invalid relay catalogue response")),
        }
    }
}
fn inventory(endpoint: &Endpoint) -> io::Result<(Vec<record::SessionSummary>, bool)> {
    if endpoint.relay.is_some() {
        return Ok((
            list_relay_with_timeout(&endpoint.socket, Duration::from_millis(1200))?,
            false,
        ));
    }
    let mut socket = UnixStream::connect(&endpoint.socket)?;
    socket.set_read_timeout(Some(Duration::from_secs(3)))?;
    socket.set_write_timeout(Some(Duration::from_secs(1)))?;
    Frame::new(b'P', 0, &[]).send(&mut socket)?;
    Frame::new(b'L', 0, &[]).send(&mut socket)?;
    let mut presentation = false;
    loop {
        let frame = Frame::read(&mut socket)?;
        match frame.kind {
            b'P' => {
                presentation = frame
                    .data
                    .split(|b| *b == b',')
                    .any(|s| s == b"holder-presentation/1")
            }
            b'L' => {
                if frame.data.len() > 8 * FILE_LIMIT {
                    return Err(io::Error::other("Catalogue exceeds limit"));
                }
                return Ok((serde_json::from_slice(&frame.data)?, presentation));
            }
            b'E' => {
                return Err(io::Error::other(
                    String::from_utf8_lossy(&frame.data).into_owned(),
                ))
            }
            _ => {}
        }
    }
}
fn read_session_activity(
    endpoint: &Endpoint,
    session_id: &str,
    generation: &str,
    send_acknowledge: bool,
) -> (Option<activity::Snapshot>, bool) {
    if endpoint.relay.is_some() {
        let Ok(mut stream) = UnixStream::connect(&endpoint.socket) else {
            return (None, false);
        };
        let _ = stream.set_read_timeout(Some(Duration::from_millis(600)));
        let _ = stream.set_write_timeout(Some(Duration::from_millis(400)));
        let open = omg_session_runtime::registry::OpenRequest {
            id: session_id.to_owned(),
            create: false,
            policy: Default::default(),
            cwd: None,
            inline_viewer: false,
            launch: None,
        };
        let Ok(open_bytes) = serde_json::to_vec(&open) else {
            return (None, false);
        };
        if Frame::new(b'H', 0, &open_bytes).send(&mut stream).is_err() {
            return (None, false);
        }
        let mut peer_gen = 0u64;
        let mut snapshot_seq = None;
        let mut can_ack = false;
        let mut snapshot = None;
        for _ in 0..16 {
            let Ok(frame) = Frame::read(&mut stream) else {
                break;
            };
            match frame.kind {
                b'T' => peer_gen = frame.seq,
                b'J' => {
                    if let Ok(info) = serde_json::from_slice::<Value>(&frame.data) {
                        if info["generation"].as_str() != Some(generation) {
                            return (None, false);
                        }
                        can_ack = info["activity_acknowledge"] == true;
                    }
                }
                b'S' => snapshot_seq = Some(frame.seq),
                activity::FRAME => {
                    snapshot = activity::Snapshot::decode(&frame.data).ok();
                    break;
                }
                b'E' | b'X' => break,
                _ => {}
            }
        }
        let mut sent_ack = false;
        if send_acknowledge && can_ack && peer_gen != 0 {
            if let Some(seq) = snapshot_seq {
                sent_ack = Frame::new(omg_session_runtime::ACK, seq, &peer_gen.to_be_bytes())
                    .send(&mut stream)
                    .is_ok()
                    && Frame::new(omg_session_runtime::ACKNOWLEDGE, peer_gen, &[])
                        .send(&mut stream)
                        .is_ok();
            }
        }
        return (snapshot, sent_ack);
    }
    let Some(parent) = endpoint.socket.parent() else {
        return (None, false);
    };
    let session_socket = parent.join(format!("{}.sock", &hash(session_id)[..16]));
    let Ok(mut stream) = UnixStream::connect(&session_socket) else {
        return (None, false);
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));
    let mut snapshot_seq = None;
    let mut can_ack = false;
    let mut snapshot = None;
    for _ in 0..12 {
        let Ok(frame) = Frame::read(&mut stream) else {
            break;
        };
        match frame.kind {
            b'J' => {
                if let Ok(info) = serde_json::from_slice::<Value>(&frame.data) {
                    if info["generation"].as_str() != Some(generation) {
                        return (None, false);
                    }
                    can_ack = info["activity_acknowledge"] == true;
                }
            }
            b'S' => snapshot_seq = Some(frame.seq),
            activity::FRAME => {
                snapshot = activity::Snapshot::decode(&frame.data).ok();
                break;
            }
            b'E' | b'X' => break,
            _ => {}
        }
    }
    let mut sent_ack = false;
    if send_acknowledge && can_ack {
        if let Some(seq) = snapshot_seq {
            sent_ack = Frame::new(omg_session_runtime::ACK, seq, &[])
                .send(&mut stream)
                .is_ok()
                && Frame::new(omg_session_runtime::ACKNOWLEDGE, 0, &[])
                    .send(&mut stream)
                    .is_ok();
        }
    }
    (snapshot, sent_ack)
}
impl State {
    fn phone(
        &self,
        config: &Config,
    ) -> std::sync::MutexGuard<'_, Option<HashMap<String, PhoneMeta>>> {
        let mut guard = self.phone.lock().unwrap_or_else(|p| p.into_inner());
        if guard.is_none() {
            *guard = Some(
                index_path(config)
                    .and_then(|p| bounded(&p, FILE_LIMIT).ok())
                    .and_then(|b| serde_json::from_slice(&b).ok())
                    .unwrap_or_default(),
            );
        }
        guard
    }
    fn acknowledged(
        &self,
        config: &Config,
    ) -> std::sync::MutexGuard<'_, Option<HashMap<String, AcknowledgedSession>>> {
        let mut guard = self.acknowledged.lock().unwrap_or_else(|p| p.into_inner());
        if guard.is_none() {
            *guard = Some(
                acknowledged_path(config)
                    .and_then(|p| bounded(&p, FILE_LIMIT).ok())
                    .and_then(|b| serde_json::from_slice(&b).ok())
                    .unwrap_or_default(),
            );
        }
        guard
    }
    fn save_acknowledged(config: &Config, map: &HashMap<String, AcknowledgedSession>) {
        let Some(path) = acknowledged_path(config) else {
            return;
        };
        let Ok(nonce) = record::nonce() else {
            return;
        };
        let temporary = path.with_extension(format!("{nonce}.tmp"));
        let result = (|| -> io::Result<()> {
            let mut file = fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(&serde_json::to_vec(map)?)?;
            fs::rename(&temporary, &path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
    }
    fn cached_snapshot(
        &self,
        endpoint: &Endpoint,
        session_id: &str,
        generation: &str,
    ) -> Option<activity::Snapshot> {
        let key = (session_id.to_owned(), generation.to_owned());
        let ttl = if endpoint.relay.is_some() {
            Duration::from_secs(5)
        } else {
            Duration::from_millis(1500)
        };
        {
            let guard = self.snapshots.lock().unwrap_or_else(|p| p.into_inner());
            if let Some((when, snap)) = guard.get(&key) {
                if when.elapsed() < ttl {
                    return snap.clone();
                }
            }
        }
        let (fetched, _) = read_session_activity(endpoint, session_id, generation, false);
        let mut guard = self.snapshots.lock().unwrap_or_else(|p| p.into_inner());
        if guard.len() >= 1024 {
            guard.retain(|_, (when, _)| when.elapsed() < Duration::from_secs(10));
        }
        guard.insert(key, (Instant::now(), fetched.clone()));
        fetched
    }
    fn evict_snapshot(&self, session_id: &str, generation: &str) {
        let mut guard = self.snapshots.lock().unwrap_or_else(|p| p.into_inner());
        guard.remove(&(session_id.to_owned(), generation.to_owned()));
    }
    fn invalidate(&self) {
        *self.cached.lock().unwrap_or_else(|p| p.into_inner()) = None;
    }
    fn view(&self, config: &Config) -> io::Result<Arc<View>> {
        let mut cache = self.cached.lock().unwrap_or_else(|p| p.into_inner());
        if let Some((when, view)) = &*cache {
            if when.elapsed() < Duration::from_millis(750) {
                return Ok(view.clone());
            }
        }
        let view = Arc::new(build_view(config)?);
        *cache = Some((Instant::now(), view.clone()));
        Ok(view)
    }
}
fn build_view(config: &Config) -> io::Result<View> {
    let desktop = desktop(config);
    let home = home()?;
    let mut endpoints = Vec::new();
    for endpoint in config.endpoints()? {
        match inventory(&endpoint) {
            Ok((sessions, presentation)) => endpoints.push((endpoint, sessions, presentation)),
            Err(error) if holder::listener_is_gone(&error) || endpoint.relay.is_some() => {}
            Err(error) => return Err(error),
        }
    }
    endpoints.sort_by_key(|(endpoint, _, presentation)| (endpoint.relay.is_some(), !*presentation));
    let current_rev_socket = config.support.as_ref().map(|support| {
        let rev = crate::session_cli::current_revision();
        home.join(".omg/run")
            .join(&hash(&format!("{}\0{rev}", support.display()))[..20])
            .join("host.sock")
    });
    let preferred = current_rev_socket
        .as_ref()
        .and_then(|expected_socket| {
            endpoints
                .iter()
                .find(|(endpoint, _, presentation)| {
                    endpoint.relay.is_none() && *presentation && &endpoint.socket == expected_socket
                })
                .map(|(endpoint, _, _)| endpoint.clone())
        })
        .or_else(|| {
            endpoints
                .iter()
                .find(|(endpoint, _, presentation)| endpoint.relay.is_none() && *presentation)
                .or_else(|| {
                    endpoints
                        .iter()
                        .find(|(endpoint, _, _)| endpoint.relay.is_none())
                })
                .map(|(endpoint, _, _)| endpoint.clone())
        });
    let phone_guard = config.control.phone(config);
    let phone = phone_guard.as_ref().unwrap();
    let mut ack_guard = config.control.acknowledged(config);
    let acknowledged = ack_guard.as_mut().unwrap();
    let mut ack_dirty = false;
    let mut projects: BTreeMap<String, (Project, Value)> = BTreeMap::new();
    for (workspace, name) in &desktop.workspaces {
        for (kind, label) in [("terminals", "Terminals"), ("chats", "Chats")] {
            let id = format!("{workspace}-{kind}");
            projects.insert(
                id.clone(),
                (
                    Project {
                        id: id.clone(),
                        root: home.clone(),
                        workspace: workspace.clone(),
                        endpoint: preferred.clone(),
                        host: None,
                    },
                    json!({"id":id,"name":label,"path":"","workspaceID":workspace,
                "workspaceName":name,"branch":"","kind":kind,"sessions":[]}),
                ),
            );
        }
    }
    for meta in desktop.panes.values() {
        let Some(path) = &meta.directory else {
            continue;
        };
        let Some((_, workspace_name)) = desktop
            .workspaces
            .iter()
            .find(|(id, _)| id == &meta.workspace)
        else {
            continue;
        };
        let (root, branch) = project_root(path);
        if root == home || root == Path::new("/") {
            continue;
        }
        let id = format!(
            "project-{}",
            &hash(&format!("{}\0{}", meta.workspace, root.display()))[..24]
        );
        let name = root
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        projects.entry(id.clone()).or_insert_with(|| (Project {
            id: id.clone(), root: root.clone(), workspace: meta.workspace.clone(), endpoint: preferred.clone(),
                        host: None,
        }, json!({"id":id,"name":name,"path":root,"workspaceID":meta.workspace,"workspaceName":workspace_name,
            "branch":branch,"kind":"folder","sessions":[]})));
    }
    experience::append_projects(config, &desktop, preferred.as_ref(), &mut projects)?;
    let inline_relays = resolve_inline_relays(config, &desktop.inline_owners);
    let mut seen_sessions = std::collections::BTreeSet::new();
    for (endpoint, sessions, supports_presentation) in endpoints {
        let is_relay = endpoint.relay.is_some();
        let endpoint_is_remote = is_relay
            || endpoint
                .socket
                .parent()
                .and_then(|p| p.parent())
                .is_some_and(|p| p.file_name().is_some_and(|n| n == "bridges"));
        for session in sessions
            .into_iter()
            .filter(|s| s.ended.is_none())
            .take(2048)
        {
            let pane_key = session.id.to_ascii_lowercase();
            let owner = desktop.panes.get(&pane_key);
            let saved = phone
                .get(&session.id)
                .filter(|m| m.generation == session.generation);
            if is_relay && owner.is_none() && saved.is_none() {
                continue;
            }
            if !is_relay {
                let sessions_dir = endpoint.socket.parent().unwrap().join("sessions");
                if sessions_dir.join(format!("{}.closed", session.id)).exists() {
                    continue;
                }
            }
            if !seen_sessions.insert((session.id.clone(), session.generation.clone())) {
                continue;
            }
            let record = if !is_relay {
                let sessions_dir = endpoint.socket.parent().unwrap().join("sessions");
                let record_path = sessions_dir.join(format!("{}.json", session.id));
                record::Record::load(&record_path).ok().filter(|r| {
                    r.generation == session.generation && r.pid == session.pid && r.ended.is_none()
                })
            } else {
                None
            };
            let inline_owner = desktop.inline_owners.get(&pane_key);
            let inline_remote = inline_owner
                .filter(|io| !io.remote_session_id.is_empty())
                .and_then(|io| inline_relays.get(&io.remote_session_id));
            let mut facts = record
                .as_ref()
                .filter(|_| supports_presentation)
                .and_then(|rec| {
                    let socket = endpoint
                        .socket
                        .parent()?
                        .join(format!("{}.sock", &hash(&session.id)[..16]));
                    holder::presentation(&socket, rec).ok()
                })
                .or_else(|| {
                    config
                        .control
                        .cached_snapshot(&endpoint, &session.id, &session.generation)
                })
                .or_else(|| {
                    inline_remote.and_then(|remote| {
                        config.control.cached_snapshot(
                            &remote.endpoint,
                            &remote.session_id,
                            &remote.generation,
                        )
                    })
                });
            if let Some(ref mut snap) = facts {
                if let Some(ack) = acknowledged.get(&session.id) {
                    if ack.generation != session.generation {
                        acknowledged.remove(&session.id);
                        ack_dirty = true;
                    } else if snap.revision <= ack.max_revision {
                        snap.acknowledge();
                    } else {
                        acknowledged.remove(&session.id);
                        ack_dirty = true;
                    }
                }
                if let Some(owner) = owner {
                    apply_desktop_acknowledgement(snap, owner);
                }
            }
            let mut active_ssh = session
                .ssh
                .clone()
                .or_else(|| record.as_ref().and_then(|r| r.ssh.clone()))
                .or_else(|| endpoint.relay.clone())
                .or_else(|| inline_owner.map(|io| io.ssh_target.clone()));
            if active_ssh.is_none() && !endpoint_is_remote {
                if let Some(pid) = session.pid.filter(|&p| p > 0) {
                    active_ssh = omg_session_runtime::location::leader_ssh(pid);
                }
            }
            if active_ssh.is_none() {
                if let Some(target) = owner.and_then(|o| o.ssh_target.clone()) {
                    active_ssh = Some(target);
                } else if let Some(host) = facts
                    .as_ref()
                    .and_then(|f| f.remote_host.as_deref())
                    .filter(|h| !h.is_empty())
                {
                    active_ssh = Some(omg_session_runtime::location::SshTarget {
                        destination: host.to_owned(),
                        options: Vec::new(),
                        remote_cwd: facts.as_ref().and_then(|f| f.remote_cwd.clone()),
                    });
                } else if endpoint_is_remote {
                    active_ssh = Some(omg_session_runtime::location::SshTarget {
                        destination: endpoint.id.clone(),
                        options: Vec::new(),
                        remote_cwd: session.cwd.clone(),
                    });
                }
            }
            if let Some(ssh) = active_ssh.as_mut() {
                let live_remote_cwd = facts
                    .as_ref()
                    .and_then(|f| f.remote_cwd.clone())
                    .or_else(|| inline_remote.and_then(|r| r.cwd.clone()))
                    .or_else(|| endpoint_is_remote.then(|| session.cwd.clone()).flatten())
                    .or_else(|| inline_owner.and_then(|io| io.ssh_target.remote_cwd.clone()))
                    .or_else(|| owner.and_then(|o| o.remote_cwd.clone()));
                if live_remote_cwd.is_some() {
                    ssh.remote_cwd = live_remote_cwd;
                }
            }
            let observed = facts.as_ref().and_then(presentation);
            let (agent, state, mut subtitle) = observed.unwrap_or_else(|| {
                let agent = saved
                    .map(|m| m.agent.clone())
                    .or_else(|| {
                        if facts.is_none() || active_ssh.is_some() {
                            owner.and_then(|o| o.agent.clone()).or_else(|| {
                                facts
                                    .is_none()
                                    .then(|| {
                                        inline_remote.and_then(|r| r.resume_agent.clone()).or_else(
                                            || {
                                                session
                                                    .resume
                                                    .as_ref()
                                                    .map(|r| normalize_agent(&r.agent))
                                            },
                                        )
                                    })
                                    .flatten()
                            })
                        } else {
                            None
                        }
                    })
                    .unwrap_or_else(|| "terminal".into());
                let subtitle = if facts.is_some() || agent == "terminal" {
                    String::new()
                } else {
                    "Activity unavailable on this runtime".into()
                };
                (agent, "idle".into(), subtitle)
            });
            let workspace = saved
                .map(|m| m.workspace.as_str())
                .or_else(|| owner.map(|o| o.workspace.as_str()))
                .filter(|w| desktop.workspaces.iter().any(|(id, _)| id == w))
                .unwrap_or(&desktop.workspaces[0].0);
            let workspace_name = desktop
                .workspaces
                .iter()
                .find(|(id, _)| id == workspace)
                .unwrap()
                .1
                .clone();
            let saved_project = saved
                .and_then(|m| m.project.as_ref())
                .filter(|id| projects.contains_key(*id))
                .cloned();
            if active_ssh.is_none() {
                if let Some(ref pid) = saved_project {
                    if let Some((proj, _)) = projects.get(pid) {
                        if let Some(host) = proj.host.as_deref() {
                            active_ssh = experience::resolve_remote_ssh(config, host).ok().map(
                                |(destination, options)| omg_session_runtime::location::SshTarget {
                                    destination,
                                    options,
                                    remote_cwd: Some(proj.root.to_string_lossy().into_owned()),
                                },
                            );
                        }
                    }
                }
            }
            let (id, name, branch, remote_host, remote_path, remote_project_id) =
                if let Some(ssh) = active_ssh.as_ref() {
                    experience::remember_ssh_target(config, ssh);
                    let host_label = experience::host_display_name(&ssh.destination);
                    let r_path = ssh
                        .remote_cwd
                        .clone()
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "~".into());
                    let tail = Path::new(&r_path)
                        .file_name()
                        .and_then(|s| s.to_str())
                        .filter(|s| !s.is_empty() && *s != "~");
                    let project_name = match tail {
                        Some(folder) => format!("{host_label} · {folder}"),
                        None => host_label.clone(),
                    };
                    let existing_remote = saved_project.clone().or_else(|| {
                        projects.iter().find_map(|(pid, (proj, _))| {
                            let h = proj.host.as_deref()?;
                            (proj.workspace == workspace
                                && experience::host_display_name(h) == host_label
                                && proj.root == Path::new(&r_path))
                            .then(|| pid.clone())
                        })
                    });
                    let r_project_id = existing_remote.unwrap_or_else(|| {
                        format!(
                            "ssh-session-{}",
                            &hash(&format!(
                                "{workspace}\0{}\0{}\0{r_path}",
                                ssh.destination,
                                ssh.options.join("\0")
                            ))[..24]
                        )
                    });
                    let r_branch = format!("SSH · {host_label}");
                    projects.entry(r_project_id.clone()).or_insert_with(|| {
                        (
                            Project {
                                id: r_project_id.clone(),
                                root: PathBuf::from(&r_path),
                                workspace: workspace.into(),
                                endpoint: preferred.clone(),
                                host: serde_json::to_string(ssh).ok(),
                            },
                            json!({
                                "id": r_project_id,
                                "name": project_name,
                                "path": r_path,
                                "workspaceID": workspace,
                                "workspaceName": workspace_name,
                                "branch": r_branch,
                                "kind": "folder",
                                "deviceAlias": host_label,
                                "sessions": []
                            }),
                        )
                    });
                    (
                        r_project_id.clone(),
                        project_name,
                        r_branch,
                        Some(host_label),
                        Some(r_path),
                        Some(r_project_id),
                    )
                } else {
                    let fallback_cwd = facts
                        .as_ref()
                        .and_then(local_signal_cwd)
                        .or_else(|| {
                            session
                                .resume
                                .as_ref()
                                .map(|r| PathBuf::from(&r.cwd))
                                .filter(|p| p.is_absolute() && p.is_dir())
                        })
                        .or_else(|| owner.and_then(|o| o.directory.clone()));
                    let cwd = session
                        .cwd
                        .as_deref()
                        .map(Path::new)
                        .or(fallback_cwd.as_deref())
                        .unwrap_or(&home);
                    let (root, branch) = project_root(cwd);
                    let loose = root == home || root == Path::new("/");
                    let kind = if loose {
                        if agent == "terminal" {
                            "terminals"
                        } else {
                            "chats"
                        }
                    } else {
                        "folder"
                    };
                    let id = if let Some(id) = saved_project {
                        id
                    } else if loose {
                        format!("{workspace}-{kind}")
                    } else {
                        format!(
                            "project-{}",
                            &hash(&format!("{workspace}\0{}", root.display()))[..24]
                        )
                    };
                    let name = root
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned();
                    projects.entry(id.clone()).or_insert_with(|| {
                        (
                            Project {
                                id: id.clone(),
                                root: root.clone(),
                                workspace: workspace.into(),
                                endpoint: preferred.clone().or_else(|| Some(endpoint.clone())),
                                host: None,
                            },
                            json!({"id":id,"name":name,"path":root,"workspaceID":workspace,
                        "workspaceName":workspace_name,"branch":branch,"kind":kind,"sessions":[]}),
                        )
                    });
                    (id, name, branch, None, None, None)
                };
            let mut title = owner
                .and_then(|o| o.title.as_deref())
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| {
                    if agent == "terminal" {
                        name.clone()
                    } else {
                        AGENTS
                            .iter()
                            .find(|a| a.0 == agent)
                            .map(|a| a.1)
                            .unwrap_or(&agent)
                            .into()
                    }
                });
            if let (Some(ref host_label), Some(ref r_path)) = (&remote_host, &remote_path) {
                if agent == "terminal" && (title == "Terminal" || title == "~" || title.is_empty())
                {
                    title = name.clone();
                }
                if subtitle.is_empty() {
                    subtitle = if r_path != "~" {
                        format!("SSH · {host_label}:{r_path}")
                    } else {
                        format!("SSH · {host_label}")
                    };
                }
            }
            let is_background = config.support.is_some() && owner.is_none();
            let mobile_created = saved.is_some();
            let mut session_json = json!({
                "id":format!("{}/{}/{}",endpoint.id,session.id,session.generation),"title":title,"agent":agent,
                "status":state,"subtitle":subtitle,"branch":branch,
                "background":is_background,"mobileCreated":mobile_created,
            });
            if let Some(object) = session_json.as_object_mut() {
                if let Some(host) = remote_host {
                    object.insert("remoteHost".into(), json!(host));
                }
                if let Some(path) = remote_path {
                    object.insert("remotePath".into(), json!(path));
                }
                if let Some(pid) = remote_project_id {
                    object.insert("remoteProjectID".into(), json!(pid));
                }
            }
            if let Some((_, value)) = projects.get_mut(&id) {
                value["sessions"].as_array_mut().unwrap().push(session_json);
            }
        }
    }
    if ack_dirty {
        State::save_acknowledged(config, acknowledged);
    }
    drop(ack_guard);
    for (_, value) in projects.values_mut() {
        if let Some(sessions) = value["sessions"].as_array_mut() {
            sessions.sort_by_key(|s| {
                let bg = s["background"].as_bool().unwrap_or(false);
                let mobile = s["mobileCreated"].as_bool().unwrap_or(false);
                bg && !mobile
            });
        }
    }
    let agents = AGENTS.iter().map(|(id, name, icon)| json!({
        "id":id,"name":name,
        "icon": if icon.ends_with("-favicon") { json!({"asset":icon}) } else { json!({"vector":icon}) },
    })).collect::<Vec<_>>();
    let identity = device_identity(config)?;
    let channel = config
        .support
        .as_ref()
        .and_then(|p| p.file_name())
        .map(|s| s.to_string_lossy().into_owned())
        .filter(|s| s != "mobile")
        .unwrap_or_else(|| "OMG".into());
    let workspace_order: HashMap<&str, usize> = desktop
        .workspaces
        .iter()
        .enumerate()
        .map(|(idx, (id, _))| (id.as_str(), idx))
        .collect();
    let mut project_values: Vec<Value> = projects.values().map(|(_, p)| p.clone()).collect();
    project_values.sort_by(|a, b| {
        let wa = a["workspaceID"]
            .as_str()
            .and_then(|w| workspace_order.get(w).copied())
            .unwrap_or(usize::MAX);
        let wb = b["workspaceID"]
            .as_str()
            .and_then(|w| workspace_order.get(w).copied())
            .unwrap_or(usize::MAX);
        let ra = a.get("deviceAlias").is_some_and(|v| !v.is_null());
        let rb = b.get("deviceAlias").is_some_and(|v| !v.is_null());
        wa.cmp(&wb)
            .then_with(|| ra.cmp(&rb))
            .then_with(|| a["id"].as_str().cmp(&b["id"].as_str()))
    });
    let roster = json!({"t":"roster","wire":2,"macID":identity,
        "macName":format!("{} · {channel}",computer_name()),
        "agents":agents,"projects":project_values});
    let projects: HashMap<String, Project> =
        projects.into_iter().map(|(id, (p, _))| (id, p)).collect();
    Ok(View { roster, projects })
}

pub(super) async fn serve(
    mut ws: WebSocketStream<tokio::net::TcpStream>,
    config: Arc<Config>,
) -> io::Result<()> {
    let mut refresh = tokio::time::interval(Duration::from_secs(1));
    let mut ping = tokio::time::interval(Duration::from_secs(15));
    ping.tick().await;
    let mut awaiting_pong = false;
    let mut previous = String::new();
    loop {
        tokio::select! {
            _ = refresh.tick() => {
                let source = config.clone();
                let view = tokio::task::spawn_blocking(move || source.control.view(&source))
                    .await.map_err(io::Error::other)??;
                let text = view.roster.to_string();
                if text != previous {
                    tokio::time::timeout(Duration::from_secs(5), ws.send(Message::Text(text.clone().into())))
                        .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                    previous = text;
                }
            }
            _ = ping.tick() => {
                if awaiting_pong { break; }
                awaiting_pong = true;
                ws.send(Message::Ping(Vec::new().into())).await.map_err(io::Error::other)?;
            }
            incoming = ws.next() => match incoming {
                Some(Ok(Message::Pong(_))) => awaiting_pong = false,
                Some(Ok(Message::Ping(bytes))) => ws.send(Message::Pong(bytes)).await.map_err(io::Error::other)?,
                Some(Ok(Message::Text(text))) if text.len() <= 12 * FILE_LIMIT => {
                    let request = serde_json::from_str::<Value>(&text).map_err(io::Error::other)?;
                    let source = config.clone();
                    let request_id = request.get("_request").cloned();
                    let mut reply = tokio::task::spawn_blocking(move || request_control(&source, &request))
                        .await.map_err(io::Error::other)?
                        .unwrap_or_else(|error| json!({"t":"error","message":error.to_string()}));
                    if let (Some(id), Some(object)) = (request_id, reply.as_object_mut()) { object.insert("_request".into(), id); }
                    if !reply.is_null() {
                        tokio::time::timeout(Duration::from_secs(5), ws.send(Message::Text(reply.to_string().into())))
                            .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                    }
                    let source = config.clone();
                    if let Ok(Ok(view)) = tokio::task::spawn_blocking(move || source.control.view(&source)).await {
                        let next_roster = view.roster.to_string();
                        if next_roster != previous {
                            tokio::time::timeout(Duration::from_secs(5), ws.send(Message::Text(next_roster.clone().into())))
                                .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
                            previous = next_roster;
                        }
                    }
                }
                _ => break,
            },
        }
    }
    ws.close(None).await.map_err(io::Error::other)
}

fn text<'a>(request: &'a Value, key: &str) -> io::Result<&'a str> {
    request[key]
        .as_str()
        .filter(|s| s.len() <= 4096 && !s.contains('\0'))
        .ok_or_else(|| io::Error::other(format!("Missing or invalid {key}")))
}
fn route(config: &Config, id: &str) -> io::Result<(Endpoint, String, String)> {
    let pieces = id.split('/').collect::<Vec<_>>();
    if pieces.len() != 3 {
        return Err(io::Error::other("Invalid session"));
    }
    let (endpoint, session, generation) = (pieces[0], pieces[1], pieces[2]);
    if !omg_session_runtime::host::valid_id(session) {
        return Err(io::Error::other("Invalid session"));
    }
    let endpoint = config
        .endpoints()?
        .into_iter()
        .find(|e| e.id == endpoint)
        .ok_or_else(|| io::Error::other("Session endpoint is unavailable"))?;
    if !omg_session_runtime::client::list_local(&endpoint.socket)?
        .iter()
        .any(|s| s.id == session && s.generation == generation && s.ended.is_none())
    {
        return Err(io::Error::other("Session generation changed"));
    }
    Ok((endpoint, session.into(), generation.into()))
}
fn confine(root: &Path, path: &str) -> io::Result<PathBuf> {
    // Adapted from Termio termiod/src/files.rs: canonical root and target,
    // reject parent traversal and symlink escapes before reading or writing.
    if Path::new(path)
        .components()
        .any(|c| matches!(c, Component::ParentDir))
    {
        return Err(io::Error::other("Path escapes project"));
    }
    let root = fs::canonicalize(root)?;
    let path = fs::canonicalize(root.join(path))?;
    if !path.starts_with(&root) {
        return Err(io::Error::other("Path escapes project"));
    }
    Ok(path)
}
fn mtime(metadata: &fs::Metadata) -> u64 {
    metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
fn request_control(config: &Config, request: &Value) -> io::Result<Value> {
    let kind = text(request, "t")?;
    if matches!(kind, "workspaces" | "hosts" | "directories" | "addProject") {
        return experience::request(config, request);
    }
    if kind == "auth" {
        return Ok(Value::Null);
    }
    if kind == "sshConfigHosts" {
        return Ok(json!({"t":"sshConfigList","hosts":ssh_hosts_for_config(config)}));
    }
    if kind == "acknowledge" {
        let Ok((endpoint, id, generation)) = route(config, text(request, "session")?) else {
            return Ok(Value::Null);
        };
        let mut pre_snap: Option<activity::Snapshot> = None;
        if endpoint.relay.is_none() {
            let sessions_dir = endpoint.socket.parent().unwrap().join("sessions");
            let record_path = sessions_dir.join(format!("{id}.json"));
            if let Some(rec) = record::Record::load(&record_path)
                .ok()
                .filter(|r| r.generation == generation && r.ended.is_none())
            {
                let sock = endpoint
                    .socket
                    .parent()
                    .unwrap()
                    .join(format!("{}.sock", &hash(&id)[..16]));
                if let Ok(snap) = holder::presentation(&sock, &rec) {
                    pre_snap = Some(snap);
                }
            }
        }
        let (snap, mut sent_ack) = read_session_activity(&endpoint, &id, &generation, true);
        let mut candidate = snap.or(pre_snap);
        if endpoint.relay.is_none() {
            let desktop_meta = desktop(config);
            let pane_key = id.to_ascii_lowercase();
            if let Some(io) = desktop_meta
                .inline_owners
                .get(&pane_key)
                .filter(|io| !io.remote_session_id.is_empty())
            {
                let inline_relays = resolve_inline_relays(config, &desktop_meta.inline_owners);
                if let Some(remote) = inline_relays.get(&io.remote_session_id) {
                    let (remote_snap, remote_ack) = read_session_activity(
                        &remote.endpoint,
                        &remote.session_id,
                        &remote.generation,
                        true,
                    );
                    config
                        .control
                        .evict_snapshot(&remote.session_id, &remote.generation);
                    if candidate.is_none() {
                        candidate = remote_snap;
                        sent_ack |= remote_ack;
                    }
                }
            }
        }
        {
            let mut ack_guard = config.control.acknowledged(config);
            if let Some(map) = ack_guard.as_mut() {
                if sent_ack {
                    if map.remove(&id).is_some() {
                        State::save_acknowledged(config, map);
                    }
                } else if let Some(mut probe) = candidate {
                    let rev = probe.revision;
                    if probe.acknowledge() {
                        map.insert(
                            id.clone(),
                            AcknowledgedSession {
                                generation: generation.clone(),
                                max_revision: rev,
                            },
                        );
                        State::save_acknowledged(config, map);
                    }
                }
            }
        }
        config.control.evict_snapshot(&id, &generation);
        config.control.invalidate();
        return Ok(Value::Null);
    }
    if kind == "stop" {
        let (endpoint, id, generation) = route(config, text(request, "session")?)?;
        let mut socket = UnixStream::connect(&endpoint.socket)?;
        socket.set_read_timeout(Some(Duration::from_secs(5)))?;
        Frame::new(
            b'K',
            if endpoint.relay.is_some() { 0 } else { 1 },
            id.as_bytes(),
        )
        .send(&mut socket)?;
        let reply = loop {
            let frame = Frame::read(&mut socket)?;
            if frame.kind != b'T' {
                break frame;
            }
        };
        if reply.kind == b'E' {
            return Err(io::Error::other(
                String::from_utf8_lossy(&reply.data).into_owned(),
            ));
        }
        config.control.evict_snapshot(&id, &generation);
        {
            let mut phone = config.control.phone(config);
            if let Some(phone) = phone.as_mut() {
                if phone.remove(&id).is_some() {
                    if let Some(path) = index_path(config) {
                        if let Ok(nonce) = record::nonce() {
                            let temporary = path.with_extension(format!("{nonce}.tmp"));
                            let _ = (|| -> io::Result<()> {
                                let mut file = fs::OpenOptions::new()
                                    .create_new(true)
                                    .write(true)
                                    .mode(0o600)
                                    .open(&temporary)?;
                                file.write_all(&serde_json::to_vec(phone)?)?;
                                fs::rename(&temporary, &path)
                            })();
                            let _ = fs::remove_file(temporary);
                        }
                    }
                }
            }
        }
        config.control.invalidate();
        return Ok(Value::Null);
    }
    let view = config.control.view(config)?;
    if matches!(kind, "start" | "startTerminal" | "startSSH") {
        return start(config, &view, request);
    }
    let project = view
        .projects
        .get(text(request, "project")?)
        .ok_or_else(|| io::Error::other("Project is no longer in the roster"))?;
    let path = request["path"].as_str().unwrap_or("");
    if path.len() > 4096 || path.contains('\0') {
        return Err(io::Error::other("Invalid project path"));
    }
    if let Some(host) = &project.host {
        return experience::remote_project_control(config, project, host, kind, path, request);
    }
    match kind {
        "listFiles" => {
            let directory = confine(&project.root, path)?;
            let root = fs::canonicalize(&project.root)?;
            let changed = git_changes(&project.root)
                .ok()
                .map(|value| {
                    value["files"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|file| file["path"].as_str().map(str::to_owned))
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let mut entries = fs::read_dir(directory)?
                .take(2001)
                .collect::<Result<Vec<_>, _>>()?;
            entries.sort_by_key(|e| e.file_name());
            let entries = entries
                .into_iter()
                .take(2000)
                .filter_map(|entry| {
                    let name = entry.file_name().to_str()?.to_owned();
                    if matches!(name.as_str(), ".git" | ".hg" | ".svn") {
                        return None;
                    }
                    let resolved = confine(&project.root, &entry.path().to_string_lossy()).ok()?;
                    let entry_path = entry.path();
                    let relative = entry_path.strip_prefix(&root).ok()?.to_string_lossy();
                    let prefix = format!("{relative}/");
                    let changed = changed
                        .iter()
                        .any(|path| path == relative.as_ref() || path.starts_with(&prefix));
                    Some(json!({"name":name,"dir":resolved.is_dir(),"changed":changed}))
                })
                .collect::<Vec<_>>();
            Ok(json!({"t":"fileList","path":path,"entries":entries}))
        }
        "readFile" => {
            let target = confine(&project.root, path)?;
            let size = fs::metadata(&target)?.len();
            let mut bytes = Vec::new();
            fs::File::open(&target)?
                .take((FILE_LIMIT + 1) as u64)
                .read_to_end(&mut bytes)?;
            let truncated = bytes.len() > FILE_LIMIT;
            bytes.truncate(FILE_LIMIT);
            let binary = bytes.contains(&0) || std::str::from_utf8(&bytes).is_err();
            Ok(
                json!({"t":"file","path":path,"data":STANDARD.encode(&bytes),"size":size,
                "binary":binary,"truncated":truncated,"mtime":mtime(&fs::metadata(target)?)}),
            )
        }
        "writeFile" => {
            let target = confine(&project.root, path)?;
            let expected = request["baseMtime"]
                .as_u64()
                .ok_or_else(|| io::Error::other("Missing file version"))?;
            if expected != 0 && mtime(&fs::metadata(&target)?) != expected {
                return Err(io::Error::other(
                    "conflict: File changed on the host; reload before saving",
                ));
            }
            let encoded = request["data"]
                .as_str()
                .filter(|s| s.len() <= 4 * FILE_LIMIT.div_ceil(3))
                .ok_or_else(|| io::Error::other("Invalid file payload"))?;
            let bytes = STANDARD.decode(encoded).map_err(io::Error::other)?;
            if bytes.len() > FILE_LIMIT {
                return Err(io::Error::other("File exceeds edit limit"));
            }
            let mut file = fs::OpenOptions::new()
                .write(true)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&target)?;
            if expected != 0 && mtime(&file.metadata()?) != expected {
                return Err(io::Error::other("conflict: File changed on the host"));
            }
            file.set_len(0)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            Ok(json!({"t":"written","path":path,"mtime":mtime(&file.metadata()?)}))
        }
        "upload" => {
            let name = text(request, "name")?;
            if name.is_empty() || Path::new(name).file_name().and_then(|s| s.to_str()) != Some(name)
            {
                return Err(io::Error::other("Invalid upload name"));
            }
            let encoded = request["data"]
                .as_str()
                .ok_or_else(|| io::Error::other("Missing upload"))?;
            let bytes = STANDARD.decode(encoded).map_err(io::Error::other)?;
            if bytes.len() > 8 * FILE_LIMIT {
                return Err(io::Error::other("Upload exceeds 8 MiB"));
            }
            let root = fs::canonicalize(&project.root)?;
            let directory = root.join(".omg-mobile-uploads");
            if let Ok(meta) = fs::symlink_metadata(&directory) {
                if meta.file_type().is_symlink() || !meta.is_dir() {
                    return Err(io::Error::other("Path escapes project"));
                }
            } else {
                fs::DirBuilder::new().mode(0o700).create(&directory)?;
            }
            let directory = confine(&root, ".omg-mobile-uploads")?;
            let target = directory.join(format!("{}-{name}", record::nonce()?));
            fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&target)?
                .write_all(&bytes)?;
            Ok(json!({"t":"uploaded","path":target}))
        }
        "searchFiles" => {
            let query = text(request, "query")?.to_lowercase();
            let mut paths = Vec::new();
            let mut stack = vec![project.root.clone()];
            let mut visited = 0;
            while let Some(directory) = stack.pop() {
                for entry in fs::read_dir(directory)?.take(2000).flatten() {
                    visited += 1;
                    if visited > 10000 || paths.len() >= 200 {
                        break;
                    }
                    let name = entry.file_name().to_string_lossy().into_owned();
                    if matches!(name.as_str(), ".git" | "node_modules" | ".build" | "target") {
                        continue;
                    }
                    let kind = entry.file_type()?;
                    if kind.is_dir() {
                        stack.push(entry.path());
                    } else if kind.is_file() {
                        let relative = entry
                            .path()
                            .strip_prefix(&project.root)
                            .unwrap()
                            .to_string_lossy()
                            .into_owned();
                        if relative.to_lowercase().contains(&query) {
                            paths.push(relative);
                        }
                    }
                }
                if visited > 10000 || paths.len() >= 200 {
                    break;
                }
            }
            let truncated = visited > 10000 || paths.len() >= 200;
            Ok(
                json!({"t":"searchResults","query":request["query"],"paths":paths,"truncated":truncated}),
            )
        }
        "listChanges" => git_changes(&project.root),
        "readDiff" => git_diff(
            &project.root,
            path,
            request["status"].as_str().unwrap_or(""),
        ),
        _ => Err(io::Error::other("Unsupported OMG control operation")),
    }
}

fn ssh_hosts() -> Vec<Value> {
    let Some(path) = home().ok().map(|h| h.join(".ssh/config")) else {
        return vec![];
    };
    let Some(text) = bounded(&path, FILE_LIMIT)
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
    else {
        return vec![];
    };
    text.lines()
        .filter_map(|line| {
            let fields = line.split_whitespace().collect::<Vec<_>>();
            if fields
                .first()
                .is_some_and(|s| s.eq_ignore_ascii_case("Host"))
            {
                Some(
                    fields
                        .into_iter()
                        .skip(1)
                        .filter(|s| !s.contains(['*', '?', '!']) && !s.starts_with('-'))
                        .map(|alias| json!({"alias":alias,"hostName":alias,"user":"","port":22}))
                        .collect::<Vec<_>>(),
                )
            } else {
                None
            }
        })
        .flatten()
        .take(512)
        .collect()
}

fn ssh_hosts_for_config(config: &Config) -> Vec<Value> {
    let mut hosts = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for remembered in experience::load_remembered_ssh_hosts(config) {
        if seen.insert(remembered.alias.clone()) {
            hosts.push(json!({
                "alias": remembered.alias,
                "hostName": remembered.host_name,
                "user": remembered.user,
                "port": remembered.port,
            }));
        }
    }
    for entry in ssh_hosts() {
        if let Some(alias) = entry["alias"].as_str() {
            if seen.insert(alias.to_owned()) {
                hosts.push(entry);
            }
        }
    }
    hosts
}

fn start(config: &Config, view: &View, request: &Value) -> io::Result<Value> {
    let kind = text(request, "t")?;
    let project = if kind == "start" {
        view.projects.get(text(request, "project")?)
    } else {
        let workspace = request["workspace"].as_str();
        view.projects
            .values()
            .find(|p| p.id.ends_with("-terminals") && workspace.is_none_or(|w| w == p.workspace))
    }
    .ok_or_else(|| io::Error::other("Workspace is unavailable"))?;
    let endpoint = project
        .endpoint
        .clone()
        .or_else(|| restart_endpoint(config).ok())
        .ok_or_else(|| {
            io::Error::other("Open a local terminal in OMG Dev before starting a mobile session")
        })?;
    let shell = std::env::var("SHELL")
        .ok()
        .filter(|s| s.starts_with('/') && Path::new(s).is_file())
        .unwrap_or_else(|| {
            if Path::new("/bin/zsh").is_file() {
                "/bin/zsh".into()
            } else if Path::new("/bin/bash").is_file() {
                "/bin/bash".into()
            } else {
                "/bin/sh".into()
            }
        });
    let agent = if kind == "start" {
        request["agent"].as_str().unwrap_or("codex")
    } else {
        "terminal"
    };
    let mut argv = if kind == "startSSH" {
        let host = text(request, "host")?;
        if !ssh_hosts_for_config(config)
            .iter()
            .any(|h| h["alias"].as_str() == Some(host))
        {
            return Err(io::Error::other("Choose an existing SSH host alias"));
        }
        let mut cmd = vec!["/usr/bin/ssh".into()];
        if let Some(remembered) = experience::load_remembered_ssh_hosts(config)
            .into_iter()
            .find(|h| h.alias == host)
        {
            cmd.extend(remembered.options);
        }
        cmd.push(host.into());
        cmd
    } else if agent == "terminal" {
        vec![shell, "-l".into()]
    } else {
        let command = match agent {
            "codex" => "codex",
            "claude" => "claude",
            "pi" => "pi",
            "antigravity" => "agy",
            _ => return Err(io::Error::other("Unsupported agent")),
        };
        vec![shell, "-lic".into(), format!("exec {command}")]
    };
    if let Some(host) = &project.host {
        let remote = experience::ssh_command(config, host)?;
        let destination = text(&remote, "destination")?;
        let mut ssh = vec!["/usr/bin/ssh".into(), "-t".into()];
        ssh.extend(
            remote["options"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str().map(str::to_owned)),
        );
        ssh.push(destination.into());
        let remote_command = if agent == "terminal" {
            "${SHELL:-/bin/sh} -l".to_owned()
        } else {
            let command = argv.last().cloned().unwrap_or_default();
            format!(
                "${{SHELL:-/bin/sh}} -lic {}",
                experience::quote(command.strip_prefix("exec ").unwrap_or(&command))
            )
        };
        let root_str = project.root.to_string_lossy();
        if root_str.is_empty() || root_str == "~" {
            ssh.push(format!("exec {remote_command}"));
        } else {
            ssh.push(format!(
                "cd {} && exec {}",
                experience::quote(&root_str),
                remote_command
            ));
        }
        argv = ssh;
    }
    let nonce = record::nonce()?;
    let id = format!(
        "{}-{}-{}-{}-{}",
        &nonce[..8],
        &nonce[8..12],
        &nonce[12..16],
        &nonce[16..20],
        &nonce[20..]
    );
    let mut environment = std::env::vars()
        .filter(|(k, _)| {
            !k.starts_with("OMG_MOBILE_")
                && !k.starts_with("OMG_RUNTIME_")
                && k != "OMG_SESSION_RUNTIME_DESCRIPTOR"
                && k != "GHOSTTY_SURFACE_ID"
        })
        .collect::<BTreeMap<_, _>>();
    if environment
        .get("TERM")
        .is_none_or(|term| term.trim().is_empty() || term == "dumb")
    {
        environment.insert("TERM".into(), "xterm-256color".into());
    }
    let policy_path = endpoint.socket.parent().unwrap().join("policy.json");
    let policy = if policy_path.exists() {
        serde_json::from_slice::<omg_session_runtime::lifecycle::Policy>(&bounded(
            &policy_path,
            8192,
        )?)?
    } else {
        omg_session_runtime::lifecycle::Policy::default()
    };
    policy.validate()?;
    let supports_launch = inventory(&endpoint).map(|(_, p)| p).unwrap_or(true);
    let cwd = if project.host.is_some() {
        home()?
    } else {
        project.root.clone()
    };
    let request = if supports_launch {
        json!({"id":id,"create":true,"policy":policy,
            "launch":{"argv":argv,"env":environment,"cwd":cwd,"cols":100,"rows":30,"pixel_width":0,"pixel_height":0}})
    } else if agent == "terminal" && kind != "startSSH" && project.host.is_none() {
        json!({"id":id,"create":true,"policy":policy,"cwd":cwd})
    } else {
        return Err(io::Error::other(
            "Agent launch requires a local session broker",
        ));
    };
    let mut socket = UnixStream::connect(&endpoint.socket)?;
    socket.set_read_timeout(Some(Duration::from_secs(8)))?;
    socket.set_write_timeout(Some(Duration::from_secs(2)))?;
    Frame::new(b'C', 1, &serde_json::to_vec(&request)?).send(&mut socket)?;
    loop {
        let reply = Frame::read(&mut socket)?;
        if reply.kind == b'E' {
            return Err(io::Error::other(
                String::from_utf8_lossy(&reply.data).into_owned(),
            ));
        }
        if reply.kind == b'D' {
            let mut input = reply.data.as_slice();
            let inner = Frame::read(&mut input)?;
            if inner.kind == b'S' {
                Frame::new(b'D', 1, &Frame::new(b'A', inner.seq, &[]).encode())
                    .send(&mut socket)?;
                break;
            }
        }
    }
    let summary = omg_session_runtime::client::list_local(&endpoint.socket)?
        .into_iter()
        .find(|s| s.id == id)
        .ok_or_else(|| io::Error::other("Session was not catalogued"))?;
    {
        let mut phone = config.control.phone(config);
        let phone = phone.as_mut().unwrap();
        phone.insert(
            id.clone(),
            PhoneMeta {
                generation: summary.generation.clone(),
                workspace: project.workspace.clone(),
                agent: agent.into(),
                project: Some(project.id.clone()),
            },
        );
        if let Some(path) = index_path(config) {
            let temporary = path.with_extension(format!("{}.tmp", record::nonce()?));
            let result = (|| {
                let mut file = fs::OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .mode(0o600)
                    .open(&temporary)?;
                file.write_all(&serde_json::to_vec(phone)?)?;
                fs::rename(&temporary, &path)
            })();
            if result.is_err() {
                let _ = fs::remove_file(temporary);
            }
        }
    }
    config.control.invalidate();
    Ok(
        json!({"t":"started","session":format!("{}/{}/{}",endpoint.id,id,summary.generation),"agent":agent}),
    )
}

fn ensure_local_broker(binary: &Path, support: &Path, revision: &str) -> io::Result<Endpoint> {
    let root = home()?
        .join(".omg/run")
        .join(&hash(&format!("{}\0{revision}", support.display()))[..20]);
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&root)?;
    super::private(&root, true)?;
    let socket = root.join("host.sock");
    let running = match UnixStream::connect(&socket) {
        Ok(_) => true,
        Err(error) if holder::listener_is_gone(&error) => false,
        Err(error) => return Err(error),
    };
    if !running {
        let log_path = root.join("host.log");
        let command = vec![
            binary.to_string_lossy().into_owned(),
            "host-local".into(),
            root.to_string_lossy().into_owned(),
            "--".into(),
            "/bin/sh".into(),
        ];
        let launch_helper = std::env::current_exe().unwrap_or_else(|_| binary.to_path_buf());
        if omg_session_runtime::launchd::spawn(&launch_helper, &command, &log_path)?.is_none() {
            use std::os::unix::process::CommandExt;
            let log = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&log_path)?;
            let mut child = std::process::Command::new(binary);
            child
                .args(&command[1..])
                .env("TERM", "xterm-256color")
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(log);
            unsafe {
                child.pre_exec(|| {
                    if libc::setsid() < 0 {
                        return Err(io::Error::last_os_error());
                    }
                    libc::signal(libc::SIGHUP, libc::SIG_IGN);
                    Ok(())
                });
            }
            let mut child = child.spawn()?;
            std::thread::spawn(move || {
                let _ = child.wait();
            });
        }
        let mut ready = false;
        for _ in 0..100 {
            if UnixStream::connect(&socket).is_ok() {
                ready = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        if !ready {
            return Err(io::Error::other("Local broker did not start"));
        }
    }
    Ok(Endpoint {
        id: hash(&socket.to_string_lossy()),
        name: "This Machine".into(),
        socket,
        relay: None,
    })
}

fn restart_endpoint(config: &Config) -> io::Result<Endpoint> {
    let support = config
        .support
        .as_ref()
        .ok_or_else(|| io::Error::other("No app channel"))?;
    let current_rev = crate::session_cli::current_revision();
    let expected_snapshot = crate::session_cli::current_snapshot_revision();
    let current_cached = support
        .join("session-runtime/versions")
        .join(&current_rev)
        .join("omgd");
    if current_cached.is_file() {
        return ensure_local_broker(&current_cached, support, &current_rev);
    }
    if let Ok(current_exe) = std::env::current_exe() {
        if current_exe.is_file()
            && current_exe
                .parent()
                .is_some_and(|dir| dir.join("revision").is_file() || dir.join("verified").is_file())
        {
            return ensure_local_broker(&current_exe, support, &current_rev);
        }
    }
    let archive_path = support.join("session-runtime/endpoints.json");
    if archive_path.exists() {
        let archive: Value = serde_json::from_slice(&bounded(&archive_path, 4 * FILE_LIMIT)?)?;
        for entry in archive["endpoints"].as_array().into_iter().flatten() {
            let descriptor = &entry["descriptor"];
            if !descriptor["connection"].is_null() {
                continue;
            }
            let Some(revision) = descriptor["revision"].as_str().filter(|s| {
                !s.is_empty()
                    && !matches!(*s, "." | "..")
                    && s.len() <= 128
                    && s.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            }) else {
                continue;
            };
            if let Some(expected) = &expected_snapshot {
                let snap_path = support
                    .join("session-runtime/versions")
                    .join(revision)
                    .join("snapshot-revision");
                if fs::read_to_string(snap_path)
                    .ok()
                    .is_none_or(|s| crate::session_cli::canonical_snapshot_revision(&s) != expected)
                {
                    continue;
                }
            }
            let version_dir = support.join("session-runtime/versions").join(revision);
            let binary = version_dir.join("omgd");
            if !binary.is_file() || !version_dir.join("omg-mobile-support").is_file() {
                continue;
            }
            return ensure_local_broker(&binary, support, revision);
        }
    }
    let current = std::env::current_exe()?;
    if current.is_file() {
        return ensure_local_broker(&current, support, &current_rev);
    }
    Err(io::Error::other("No installed local runtime"))
}

fn git(root: &Path, args: &[&str]) -> io::Result<Vec<u8>> {
    // Termio's git plane also uses the installed git with optional locks disabled.
    let mut child = std::process::Command::new("git")
        .args(["--no-optional-locks", "-c", "core.fsmonitor=false", "-C"])
        .arg(root)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    let stdout = child.stdout.take().unwrap();
    let (send, receive) = std::sync::mpsc::sync_channel(1);
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.take((FILE_LIMIT + 1) as u64).read_to_end(&mut bytes);
        let _ = send.send(result.map(|_| bytes));
    });
    let received = receive.recv_timeout(Duration::from_secs(5));
    if !matches!(&received, Ok(Ok(bytes)) if bytes.len() <= FILE_LIMIT) {
        let _ = child.kill();
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err(io::Error::other("Git preview timed out"));
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let _ = reader.join();
    let bytes = received.map_err(|_| io::Error::other("Git preview timed out"))??;
    if bytes.len() > FILE_LIMIT {
        return Err(io::Error::other("Git preview exceeds 1 MiB"));
    }
    if !status.success() && status.code() != Some(1) {
        return Err(io::Error::other("Git request failed"));
    }
    Ok(bytes)
}
fn git_changes(root: &Path) -> io::Result<Value> {
    if !root.join(".git").exists() {
        return Ok(json!({"t":"changes","files":[]}));
    }
    let bytes = git(root, &["status", "--porcelain=v1", "-z"])?;
    let statistics = git(
        root,
        &[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--numstat",
            "-z",
            "HEAD",
        ],
    )
    .or_else(|_| {
        git(
            root,
            &["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z"],
        )
    })
    .unwrap_or_default();
    let mut counts = HashMap::new();
    let mut stats = statistics.split(|b| *b == 0).filter(|b| !b.is_empty());
    while let Some(row) = stats.next() {
        let mut parts = row.splitn(3, |b| *b == b'\t');
        let (Some(add), Some(del), Some(path)) = (parts.next(), parts.next(), parts.next()) else {
            continue;
        };
        let path = if path.is_empty() {
            let _ = stats.next();
            stats.next().unwrap_or_default()
        } else {
            path
        };
        let binary = add == b"-" || del == b"-";
        let add = std::str::from_utf8(add)
            .ok()
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        let del = std::str::from_utf8(del)
            .ok()
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        counts.insert(
            String::from_utf8_lossy(path).into_owned(),
            (add, del, binary),
        );
    }
    let mut fields = bytes.split(|b| *b == 0).filter(|b| !b.is_empty());
    let mut result = Vec::new();
    while let Some(entry) = fields.next() {
        if entry.len() < 4 {
            continue;
        }
        let x = entry[0] as char;
        let y = entry[1] as char;
        let path = String::from_utf8_lossy(&entry[3..]);
        let status = if x == '?' {
            'U'
        } else if x == 'U' || y == 'U' {
            '!'
        } else if y != ' ' {
            y
        } else {
            x
        };
        if x == 'R' || x == 'C' {
            let _ = fields.next();
        }
        let (add, del, binary) = counts.get(path.as_ref()).copied().unwrap_or_else(|| {
            if status == 'U' {
                if let Ok(target) = confine(root, &path) {
                    if let Ok(bytes) = bounded(&target, FILE_LIMIT) {
                        let binary = bytes.contains(&0) || std::str::from_utf8(&bytes).is_err();
                        return (
                            if binary || bytes.is_empty() {
                                0
                            } else {
                                bytes.split(|b| *b == b'\n').count() as i64
                                    - i64::from(bytes.last() == Some(&b'\n'))
                            },
                            0,
                            binary,
                        );
                    }
                }
            }
            (-1, -1, false)
        });
        result.push(json!({"path":path,"status":status.to_string(),"add":add,"del":del,"binary":binary,"staged":x!=' '&&y==' '}));
        if result.len() >= 2000 {
            break;
        }
    }
    Ok(json!({"t":"changes","files":result}))
}
fn git_diff(root: &Path, path: &str, status: &str) -> io::Result<Value> {
    if Path::new(path)
        .components()
        .any(|p| matches!(p, Component::ParentDir | Component::RootDir))
    {
        return Err(io::Error::other("Invalid diff path"));
    }
    let bytes = if status == "U" {
        let target = confine(root, path)?;
        git(
            root,
            &[
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--no-index",
                "--",
                "/dev/null",
                &target.to_string_lossy(),
            ],
        )?
    } else {
        git(
            root,
            &["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", path],
        )
        .or_else(|_| {
            git(
                root,
                &["diff", "--no-ext-diff", "--no-textconv", "--", path],
            )
        })?
    };
    let binary = bytes.windows(12).any(|s| s == b"Binary files");
    Ok(json!({"t":"diff","path":path,"text":String::from_utf8_lossy(&bytes),"binary":binary}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    struct Workspace {
        directory: PathBuf,
        root: PathBuf,
        config: Config,
    }
    impl Workspace {
        fn new() -> Self {
            let directory =
                std::env::temp_dir().join(format!("omg-control-{}", record::nonce().unwrap()));
            let root = directory.join("project");
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&root)
                .unwrap();
            let config = Config {
                endpoints: vec![],
                support: None,
                token: "t".repeat(64),
                origin: None,
                control: State::default(),
            };
            Self {
                directory,
                root,
                config,
            }
        }
        fn request(&self, mut request: Value) -> io::Result<Value> {
            request["project"] = json!("project");
            *self.config.control.cached.lock().unwrap() = Some((
                Instant::now(),
                Arc::new(View {
                    roster: Value::Null,
                    projects: HashMap::from([(
                        "project".into(),
                        Project {
                            id: "project".into(),
                            root: self.root.clone(),
                            workspace: PERSONAL.into(),
                            endpoint: None,
                            host: None,
                        },
                    )]),
                }),
            ));
            request_control(&self.config, &request)
        }
    }
    impl Drop for Workspace {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.directory);
        }
    }

    #[test]
    fn file_plane_refuses_parent_and_symlink_escapes() {
        let workspace = Workspace::new();
        fs::write(workspace.directory.join("outside"), b"private").unwrap();
        symlink(
            workspace.directory.join("outside"),
            workspace.root.join("escape"),
        )
        .unwrap();
        assert!(workspace
            .request(json!({"t":"readFile","path":"../outside"}))
            .is_err());
        assert!(workspace
            .request(json!({"t":"readFile","path":"escape"}))
            .is_err());
        assert!(workspace
            .request(json!({"t":"upload","name":"../outside","data":"YQ=="}))
            .is_err());
        let files = workspace
            .request(json!({"t":"listFiles","path":""}))
            .unwrap();
        assert!(files["entries"].as_array().unwrap().is_empty());
    }

    #[test]
    fn file_edits_use_mtime_and_accept_realistic_payload_sizes() {
        let workspace = Workspace::new();
        fs::write(workspace.root.join("README.md"), b"before").unwrap();
        let original = workspace
            .request(json!({"t":"readFile","path":"README.md"}))
            .unwrap();
        let bytes = vec![b'a'; 96 * 1024];
        let saved = workspace
            .request(json!({"t":"writeFile","path":"README.md",
            "baseMtime":original["mtime"],"data":STANDARD.encode(&bytes)}))
            .unwrap();
        assert_eq!(saved["t"], "written");
        assert_eq!(fs::read(workspace.root.join("README.md")).unwrap(), bytes);
        std::thread::sleep(Duration::from_millis(5));
        fs::write(workspace.root.join("README.md"), b"external edit").unwrap();
        assert!(workspace
            .request(json!({"t":"writeFile","path":"README.md",
            "baseMtime":saved["mtime"],"data":"YQ=="}))
            .is_err());
        assert_eq!(
            fs::read(workspace.root.join("README.md")).unwrap(),
            b"external edit"
        );
        workspace
            .request(json!({"t":"writeFile","path":"README.md","baseMtime":0,"data":"Zm9yY2Vk"}))
            .unwrap();
        assert_eq!(
            fs::read(workspace.root.join("README.md")).unwrap(),
            b"forced"
        );
    }

    #[test]
    fn file_previews_are_bounded_and_uploads_are_unique() {
        let workspace = Workspace::new();
        fs::write(
            workspace.root.join("large.txt"),
            vec![b'a'; FILE_LIMIT + 20],
        )
        .unwrap();
        let file = workspace
            .request(json!({"t":"readFile","path":"large.txt"}))
            .unwrap();
        assert_eq!(file["truncated"], true);
        assert_eq!(
            STANDARD
                .decode(file["data"].as_str().unwrap())
                .unwrap()
                .len(),
            FILE_LIMIT
        );
        let first = workspace
            .request(json!({"t":"upload","name":"photo.txt","data":"YQ=="}))
            .unwrap();
        let second = workspace
            .request(json!({"t":"upload","name":"photo.txt","data":"Yg=="}))
            .unwrap();
        assert_ne!(first["path"], second["path"]);
        assert_eq!(fs::read(first["path"].as_str().unwrap()).unwrap(), b"a");
    }

    #[test]
    fn desktop_checkpoint_projects_only_metadata_and_preserves_workspace_identity() {
        let workspace = Workspace::new();
        fs::create_dir(workspace.directory.join("workspaces")).unwrap();
        let pane = json!({"surfaceTree":{"root":{"view":{
            "uuid":"12345678-1234-1234-1234-123456789abc","title":"My agent",
        }}}});
        let state = json!({"version":2,"catalog":{"workspaces":[{"id":"work","name":"Work"}]},
            "tabs":[{"workspace":"work","state":STANDARD.encode(pane.to_string())}]});
        fs::write(
            workspace.directory.join("workspaces/state.json"),
            state.to_string(),
        )
        .unwrap();
        let config = Config {
            endpoints: vec![],
            support: Some(workspace.directory.clone()),
            token: "t".repeat(64),
            origin: None,
            control: State::default(),
        };
        let result = desktop(&config);
        assert_eq!(result.workspaces, vec![("work".into(), "Work".into())]);
        assert_eq!(
            result.panes["12345678-1234-1234-1234-123456789abc"],
            PaneDesktopMeta {
                workspace: "work".into(),
                title: Some("My agent".into()),
                directory: None,
                remote_cwd: None,
                ssh_target: None,
                agent: None,
                acknowledged_program: None,
                acknowledged_reducer: None,
            }
        );
    }

    #[test]
    fn retained_agent_facts_keep_completion_distinct_from_attention() {
        let mut state = activity::State::default();
        state.consume(
            false,
            "omg-agent-pi-42",
            "type=app;omg_agent=pi;omg_state=done",
        );
        assert_eq!(presentation(&state.snapshot()).unwrap().1, "done");
        state.consume(false, "omg-program-status", "state=idle:app=agy");
        assert_eq!(
            presentation(&state.snapshot()).unwrap(),
            ("pi".into(), "done".into(), "Done".into())
        );
        state.consume(
            false,
            "omg-program-status",
            "state=blocked:app=claude:id=permission:kind=permission",
        );
        let (agent, status, preview) = presentation(&state.snapshot()).unwrap();
        assert_eq!(
            (agent.as_str(), status.as_str(), preview.as_str()),
            ("claude", "needsAttention", "Waiting for permission")
        );
    }

    #[test]
    fn inline_owner_records_project_remote_ssh_host_and_live_cwd() {
        let workspace = Workspace::new();
        let owners = workspace.directory.join("session-runtime/inline-owners");
        fs::create_dir_all(&owners).unwrap();
        let active_path = workspace.directory.join("active.json");
        fs::write(
            &active_path,
            json!({"phase":"ready","workingDirectory":"/home/dev/mapping-platform"}).to_string(),
        )
        .unwrap();
        fs::write(
            owners.join("07eb791d-6558-4ccc-9b6a-8b059ac5f6a6.json"),
            json!({
                "localPane": "3FFA2669-C134-471A-BC6B-A227DF616BF7",
                "activeRecord": active_path,
                "descriptor": {
                    "connection": {
                        "destination": "cloud",
                        "options": ["-p", "2222"]
                    },
                    "launchWorkingDirectory": "~"
                }
            })
            .to_string(),
        )
        .unwrap();
        let config = Config {
            endpoints: vec![],
            support: Some(workspace.directory.clone()),
            token: "t".repeat(64),
            origin: None,
            control: State::default(),
        };
        let result = desktop(&config);
        let owner = &result.inline_owners["3ffa2669-c134-471a-bc6b-a227df616bf7"];
        assert_eq!(
            owner.remote_session_id,
            "07eb791d-6558-4ccc-9b6a-8b059ac5f6a6"
        );
        assert_eq!(owner.ssh_target.destination, "cloud");
        assert_eq!(owner.ssh_target.options, vec!["-p", "2222"]);
        assert_eq!(
            owner.ssh_target.remote_cwd.as_deref(),
            Some("/home/dev/mapping-platform")
        );
    }

    #[test]
    fn inline_relay_resolves_work_ssh_sessions_large_hook_configs_and_workspace_order() {
        use std::os::unix::net::UnixListener;
        let short_root =
            PathBuf::from("/tmp").join(format!("omg-ir-{}", &record::nonce().unwrap()[..8]));
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&short_root)
            .unwrap();
        struct Guard(PathBuf);
        impl Drop for Guard {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let _guard = Guard(short_root.clone());

        let rev = crate::session_cli::current_revision();
        let bundle = short_root.join("session-runtime/versions").join(&rev);
        fs::create_dir_all(&bundle).unwrap();
        fs::create_dir_all(short_root.join("workspaces")).unwrap();
        let owners = short_root.join("session-runtime/inline-owners");
        fs::create_dir_all(&owners).unwrap();

        let local_pane = "3FFA2669-C134-471A-BC6B-A227DF616BF7";
        let remote_id = "07eb791d-6558-4ccc-9b6a-8b059ac5f6a6";
        // Simulate work tab 6: sshResumeDescriptor is absent, agentResumeDescriptor has scope=remote + sshReplay.
        let pane = json!({"surfaceTree":{"root":{"view":{
            "uuid": local_pane,
            "title": "agy",
            "pwd": "/Users/test",
            "agentResumeDescriptor": {
                "agent": "antigravity",
                "scope": "remote",
                "workingDirectory": "/home/dev/fallback",
                "sshReplay": { "args": ["cloud"] }
            }
        }}}});
        fs::write(
            short_root.join("workspaces/state.json"),
            json!({
                "version": 2,
                "catalog": { "workspaces": [
                    { "id": PERSONAL, "name": "Personal" },
                    { "id": "work", "name": "work" }
                ]},
                "tabs": [{ "workspace": "work", "state": STANDARD.encode(pane.to_string()) }]
            })
            .to_string(),
        )
        .unwrap();
        // Inline owner has activeRecord: null and launchWorkingDirectory: null (live work shape).
        fs::write(
            owners.join(format!("{remote_id}.json")),
            json!({
                "localPane": local_pane,
                "activeRecord": null,
                "descriptor": {
                    "connection": { "destination": "cloud", "options": [] },
                    "launchWorkingDirectory": null
                }
            })
            .to_string(),
        )
        .unwrap();

        let uid = unsafe { libc::geteuid() };
        let inline_dir = short_root
            .join("session-runtime/inline-relays")
            .join(format!("omg-inline-{uid}-abcdef012345"));
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&inline_dir)
            .unwrap();
        // Embed >64KB hooks payload (~100KB) like real inline connection.json files.
        fs::write(
            inline_dir.join("connection.json"),
            json!({
                "transport": "ssh",
                "bundle": bundle,
                "revision": rev,
                "cwd": "/Users/test",
                "hooks": "h".repeat(100 * 1024),
                "arguments": ["-T", "--", "cloud"]
            })
            .to_string(),
        )
        .unwrap();
        let relay_sock = inline_dir.join("relay.sock");
        let relay_listener = UnixListener::bind(&relay_sock).unwrap();

        let relay_thread = std::thread::spawn(move || {
            for _ in 0..2 {
                let Ok((mut stream, _)) = relay_listener.accept() else {
                    break;
                };
                let Ok(req) = Frame::read(&mut stream) else {
                    break;
                };
                if req.kind == b'L' {
                    let _ = Frame::new(b'T', 0, br#"{"attempt":0,"state":"connecting"}"#)
                        .send(&mut stream);
                    let list = json!([{
                        "id": remote_id,
                        "generation": "remgen1",
                        "created_at": 1,
                        "updated_at": 2,
                        "pid": 4242,
                        "ended": null,
                        "resume": null,
                        "policy": {},
                        "cwd": "/home/dev/lance-spark"
                    }]);
                    let _ =
                        Frame::new(b'L', 0, &serde_json::to_vec(&list).unwrap()).send(&mut stream);
                } else if req.kind == b'H' {
                    let mut st = activity::State::default();
                    st.consume(
                        false,
                        "omg-agent-antigravity-99",
                        "type=app;omg_agent=antigravity;omg_scope=remote;omg_state=done",
                    );
                    let _ =
                        Frame::new(b'T', 7, br#"{"attempt":0,"state":"ready"}"#).send(&mut stream);
                    let _ = Frame::new(
                        b'J',
                        1,
                        br#"{"generation":"remgen1","activity_acknowledge":false}"#,
                    )
                    .send(&mut stream);
                    let _ = Frame::new(
                        activity::FRAME,
                        1,
                        &serde_json::to_vec(&st.snapshot()).unwrap(),
                    )
                    .send(&mut stream);
                }
            }
        });

        let custom = Config {
            endpoints: vec![],
            support: Some(short_root.clone()),
            token: "t".repeat(64),
            origin: None,
            control: State::default(),
        };
        let desktop_meta = desktop(&custom);
        assert_eq!(
            desktop_meta.panes[&local_pane.to_ascii_lowercase()]
                .ssh_target
                .as_ref()
                .unwrap()
                .destination,
            "cloud"
        );
        let inline_map = resolve_inline_relays(&custom, &desktop_meta.inline_owners);
        let remote = inline_map.get(remote_id).expect("inline relay resolved");
        assert_eq!(remote.cwd.as_deref(), Some("/home/dev/lance-spark"));
        let snap = custom
            .control
            .cached_snapshot(&remote.endpoint, &remote.session_id, &remote.generation)
            .expect("remote activity snapshot fetched");
        assert_eq!(
            presentation(&snap),
            Some(("antigravity".into(), "done".into(), "Done".into()))
        );

        // Verify workspace ordering places local containers before ssh-session-* even for "work".
        let mut sample_projects: BTreeMap<String, (Project, Value)> = BTreeMap::new();
        sample_projects.insert(
            "work-terminals".into(),
            (
                Project {
                    id: "work-terminals".into(),
                    root: short_root.clone(),
                    workspace: "work".into(),
                    endpoint: None,
                    host: None,
                },
                json!({"id":"work-terminals","workspaceID":"work","workspaceName":"work","kind":"terminals","sessions":[]}),
            ),
        );
        sample_projects.insert(
            "ssh-session-123".into(),
            (
                Project {
                    id: "ssh-session-123".into(),
                    root: PathBuf::from("/home/dev/lance-spark"),
                    workspace: "work".into(),
                    endpoint: None,
                    host: Some("cloud".into()),
                },
                json!({"id":"ssh-session-123","workspaceID":"work","workspaceName":"work","deviceAlias":"cloud","kind":"folder","sessions":[]}),
            ),
        );
        let ws_order = HashMap::from([(PERSONAL, 0usize), ("work", 1usize)]);
        let mut vals: Vec<Value> = sample_projects.values().map(|(_, p)| p.clone()).collect();
        vals.sort_by(|a, b| {
            let wa = a["workspaceID"]
                .as_str()
                .and_then(|w| ws_order.get(w).copied())
                .unwrap_or(usize::MAX);
            let wb = b["workspaceID"]
                .as_str()
                .and_then(|w| ws_order.get(w).copied())
                .unwrap_or(usize::MAX);
            let ra = a.get("deviceAlias").is_some_and(|v| !v.is_null());
            let rb = b.get("deviceAlias").is_some_and(|v| !v.is_null());
            wa.cmp(&wb)
                .then_with(|| ra.cmp(&rb))
                .then_with(|| a["id"].as_str().cmp(&b["id"].as_str()))
        });
        assert_eq!(vals[0]["id"], "work-terminals");
        assert_eq!(vals[1]["id"], "ssh-session-123");

        let _ = relay_thread.join();
    }

    #[test]
    fn device_identity_is_persistent_and_distinct_between_channels() {
        let first = Workspace::new();
        let second = Workspace::new();
        let make = |path: &Path| Config {
            endpoints: vec![],
            support: Some(path.to_owned()),
            token: "t".repeat(64),
            origin: None,
            control: State::default(),
        };
        let a = make(&first.directory);
        let b = make(&second.directory);
        assert_eq!(device_identity(&a).unwrap(), device_identity(&a).unwrap());
        assert_ne!(device_identity(&a).unwrap(), device_identity(&b).unwrap());
    }

    #[test]
    fn an_open_desktop_project_remains_available_without_live_sessions() {
        let workspace = Workspace::new();
        fs::create_dir(workspace.directory.join("workspaces")).unwrap();
        let pane = json!({"surfaceTree":{"root":{"view":{
            "uuid":"12345678-1234-1234-1234-123456789abc","pwd":workspace.root,
        }}}});
        fs::write(
            workspace.directory.join("workspaces/state.json"),
            json!({
                "version":2, "catalog":{"workspaces":[{"id":"work","name":"Work"}]},
                "tabs":[{"workspace":"work","state":STANDARD.encode(pane.to_string())}],
            })
            .to_string(),
        )
        .unwrap();
        let config = Config {
            endpoints: vec![],
            support: Some(workspace.directory.clone()),
            token: "t".repeat(64),
            origin: None,
            control: State::default(),
        };
        let view = build_view(&config).unwrap();
        let folder = view.roster["projects"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["kind"] == "folder")
            .unwrap();
        assert_eq!(folder["workspaceName"], "Work");
        assert!(folder["sessions"].as_array().unwrap().is_empty());
    }
}
