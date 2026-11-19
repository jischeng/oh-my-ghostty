//! Host session registry with durable tombstones, bounded retention and safe resume.
use crate::{
    host::valid_id,
    lifecycle::{unix_time, EndReason, Policy},
    record::{nonce, Record},
    server::{self, ManagedSession},
};
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    io::{self, Read},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    process::{Child, Stdio},
    sync::{Arc, Mutex},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
const MAX_RUNNING: usize = 64;
const MAX_RECORDS: usize = 2048;
const MAX_OPEN_REQUEST_BYTES: usize = 16 * 1024 * 1024;
const LOCAL_HOLDER_STARTUP_GRACE_SECONDS: u64 = 10;
const LOCAL_MAINTENANCE_PROBE_TIMEOUT: Duration = Duration::from_millis(30);
const MAX_LOCAL_MAINTENANCE_PROBES: usize = MAX_RUNNING;
const TOMBSTONE_RETENTION_SECONDS: u64 = 7 * 24 * 3600;
const ORPHAN_CREATED_MARKER_MAX_AGE_SECONDS: u64 = 60;

fn file_modified_unix(path: &Path) -> Option<u64> {
    let meta = fs::symlink_metadata(path).ok()?;
    if !meta.file_type().is_file() {
        return None;
    }
    meta.modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

pub fn normalize_support_path(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in path.components() {
        if !matches!(comp, std::path::Component::CurDir) {
            out.push(comp.as_os_str());
        }
    }
    if out.as_os_str().is_empty() && !path.as_os_str().is_empty() {
        PathBuf::from(".")
    } else {
        out
    }
}

pub fn same_canonical_path(a: &Path, b: &Path) -> bool {
    let na = normalize_support_path(a);
    let nb = normalize_support_path(b);
    if na == nb {
        return true;
    }
    match (fs::canonicalize(&na), fs::canonicalize(&nb)) {
        (Ok(ca), Ok(cb)) => ca == cb,
        _ => false,
    }
}

pub fn prefer_logical_home_path_with_home(path: &Path, home: Option<&Path>) -> PathBuf {
    let norm = normalize_support_path(path);
    let Some(logical_home) = home.map(normalize_support_path).filter(|p| p.is_absolute()) else {
        return norm;
    };
    if let Some(channel_name) = norm.file_name() {
        let app_sup_candidate = normalize_support_path(
            &logical_home
                .join("Library/Application Support")
                .join(channel_name),
        );
        if same_canonical_path(&app_sup_candidate, &norm) {
            return app_sup_candidate;
        }
    }
    if let Ok(canon_home) = fs::canonicalize(&logical_home) {
        let canon_target = fs::canonicalize(&norm).unwrap_or_else(|_| norm.clone());
        if let Ok(rel) = canon_target.strip_prefix(&canon_home) {
            let home_rel = normalize_support_path(&logical_home.join(rel));
            if same_canonical_path(&home_rel, &norm) {
                return home_rel;
            }
        }
    }
    norm
}

pub fn prefer_logical_home_path(path: &Path) -> PathBuf {
    let env_home = std::env::var_os("HOME").map(PathBuf::from);
    prefer_logical_home_path_with_home(path, env_home.as_deref())
}

pub fn local_channel_run_dir_key(support: &Path) -> String {
    use sha2::{Digest, Sha256};
    let normalized = normalize_support_path(support);
    let hex = format!(
        "{:x}",
        Sha256::digest(format!("omg-local-v2\0{}", normalized.display()).as_bytes())
    );
    hex[..20].to_owned()
}

pub fn legacy_local_run_dir_key(support: &Path, revision: &str) -> String {
    use sha2::{Digest, Sha256};
    let normalized = normalize_support_path(support);
    let hex = format!(
        "{:x}",
        Sha256::digest(format!("{}\0{revision}", normalized.display()).as_bytes())
    );
    hex[..20].to_owned()
}

pub fn local_run_dir_key(support: &Path, _revision: &str) -> String {
    local_channel_run_dir_key(support)
}

pub fn infer_support_root_from_exe(exe: &Path) -> Option<PathBuf> {
    let exe = normalize_support_path(exe);
    if exe.file_name().and_then(|s| s.to_str()) != Some("omgd") {
        return None;
    }
    let rev_dir = exe.parent()?;
    let rev = rev_dir.file_name()?.to_str()?;
    if !crate::valid_revision(rev) {
        return None;
    }
    let versions_dir = rev_dir.parent()?;
    if versions_dir.file_name()?.to_str()? != "versions" {
        return None;
    }
    let sr_dir = versions_dir.parent()?;
    if sr_dir.file_name()?.to_str()? != "session-runtime" {
        return None;
    }
    let support = normalize_support_path(sr_dir.parent()?);
    (support.is_absolute() && !support.as_os_str().is_empty()).then_some(support)
}

pub fn infer_support_root_from_env() -> Option<PathBuf> {
    let raw = std::env::var_os("OMG_APP_SUPPORT")?;
    let p = normalize_support_path(Path::new(&raw));
    let s = p.to_string_lossy();
    (p.is_absolute() && !s.is_empty() && s.len() <= 4096 && !s.contains('\0') && !s.contains('\n'))
        .then_some(p)
}

pub fn infer_support_root_from_env_or_exe() -> Option<PathBuf> {
    if let Some(p) = infer_support_root_from_env() {
        return Some(p);
    }
    std::env::current_exe()
        .ok()
        .and_then(|exe| infer_support_root_from_exe(&exe))
        .map(|p| prefer_logical_home_path(&p))
}

pub fn write_support_root_stamp(state_dir: &Path, support: &Path) -> io::Result<()> {
    use std::{
        io::Write,
        os::unix::fs::{MetadataExt, OpenOptionsExt},
    };
    let support = normalize_support_path(support);
    let support_str = support
        .to_str()
        .ok_or_else(|| io::Error::other("support path must be valid UTF-8"))?;
    if !support.is_absolute()
        || support_str.is_empty()
        || support_str.len() > 4096
        || support_str.contains('\0')
        || support_str.contains('\n')
    {
        return Err(io::Error::other("invalid support path"));
    }
    let dir_meta = fs::symlink_metadata(state_dir)?;
    if !dir_meta.file_type().is_dir()
        || dir_meta.uid() != unsafe { libc::geteuid() }
        || (dir_meta.mode() & 0o077) != 0
    {
        return Err(io::Error::other(
            "state directory must be private and owned by current user",
        ));
    }
    if let Some(existing) = read_support_root_stamp(state_dir) {
        if same_canonical_path(&existing, &support) {
            return Ok(());
        }
    }
    let target = state_dir.join("support-root");
    if let Ok(existing) = fs::symlink_metadata(&target) {
        if existing.file_type().is_symlink() || existing.file_type().is_dir() {
            return Err(io::Error::other(
                "support-root target is not a regular file",
            ));
        }
    }
    let tmp = state_dir.join(format!(".support-root.{}.tmp", &nonce()?[..12]));
    let write_res = (|| -> io::Result<()> {
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&tmp)?;
        file.write_all(support_str.as_bytes())?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&tmp, &target)
    })();
    if write_res.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    write_res
}

pub fn read_support_root_stamp(state_dir: &Path) -> Option<PathBuf> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let path = state_dir.join("support-root");
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)
        .ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file()
        || meta.uid() != unsafe { libc::geteuid() }
        || (meta.mode() & 0o077) != 0
        || meta.len() > 4096
    {
        return None;
    }
    let mut bytes = Vec::with_capacity(meta.len() as usize);
    if file.take(4097).read_to_end(&mut bytes).is_err() || bytes.len() > 4096 {
        return None;
    }
    let raw = std::str::from_utf8(&bytes)
        .ok()?
        .trim_end_matches(['\r', '\n']);
    if raw.is_empty() || raw.contains(['\0', '\n']) {
        return None;
    }
    let p = normalize_support_path(Path::new(raw));
    p.is_absolute().then_some(p)
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RuntimeMode {
    Remote,
    Local,
}

struct LocalHolder {
    capability: String,
    child: Option<Child>,
}

pub const MAX_LOCAL_LAUNCH_INPUT: usize = 10 * 1024 * 1024;
pub const MAX_LOCAL_SCROLLBACK_BYTES: usize = crate::DEFAULT_SCROLLBACK_MAX_BYTES;

#[derive(Clone, serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct LocalLaunchSpec {
    pub argv: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: Option<String>,
    pub cols: u16,
    pub rows: u16,
    pub pixel_width: u16,
    pub pixel_height: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scrollback_max_bytes: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scrollback_max_lines: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_base64: Option<String>,
}

impl LocalLaunchSpec {
    pub fn validate(&self) -> io::Result<()> {
        self.validate_with(true)
    }

    pub fn validate_with(&self, require_existing_cwd: bool) -> io::Result<()> {
        if self.argv.is_empty()
            || self.argv.len() > 128
            || self.argv[0].is_empty()
            || self
                .argv
                .iter()
                .any(|value| value.len() > 64 * 1024 || value.contains('\0'))
        {
            return Err(io::Error::other("invalid local launch arguments"));
        }
        if self.cols == 0
            || self.rows == 0
            || self.cols > 500
            || self.rows > 300
            || self.pixel_width > 16_000
            || self.pixel_height > 16_000
        {
            return Err(io::Error::other("invalid local launch terminal size"));
        }
        if self
            .scrollback_max_bytes
            .is_some_and(|bytes| bytes > MAX_LOCAL_SCROLLBACK_BYTES)
        {
            return Err(io::Error::other(
                "local session scrollback exceeds the runtime limit",
            ));
        }
        let mut size = self.argv.iter().map(String::len).sum::<usize>();
        for (key, value) in &self.env {
            if key.len() > 256 || key.contains('=') || key.contains('\0') || value.contains('\0') {
                return Err(io::Error::other("invalid local launch environment"));
            }
            size = size.saturating_add(key.len()).saturating_add(value.len());
        }
        if let Some(cwd) = &self.cwd {
            if !cwd.starts_with('/') || cwd.len() > 4096 || cwd.contains('\0') {
                return Err(io::Error::other("invalid local launch working directory"));
            }
            if require_existing_cwd && !fs::metadata(cwd)?.is_dir() {
                return Err(io::Error::other(
                    "local launch working directory is not a directory",
                ));
            }
            size = size.saturating_add(cwd.len());
        }
        if let Some(encoded) = &self.input_base64 {
            if encoded.len() > 4 * MAX_LOCAL_LAUNCH_INPUT.div_ceil(3) {
                return Err(io::Error::other("local startup input exceeds limit"));
            }
            let decoded =
                base64::Engine::decode(&base64::engine::general_purpose::STANDARD, encoded)
                    .map_err(|_| io::Error::other("invalid local startup input encoding"))?;
            if decoded.len() > MAX_LOCAL_LAUNCH_INPUT {
                return Err(io::Error::other("local startup input exceeds limit"));
            }
            size = size.saturating_add(decoded.len());
        }
        if size > crate::MAX_FRAME {
            return Err(io::Error::other("local launch specification exceeds limit"));
        }
        Ok(())
    }

    pub fn initial_input(&self) -> io::Result<Vec<u8>> {
        self.input_base64.as_deref().map_or_else(
            || Ok(Vec::new()),
            |encoded| {
                let bytes =
                    base64::Engine::decode(&base64::engine::general_purpose::STANDARD, encoded)
                        .map_err(|_| io::Error::other("invalid local startup input encoding"))?;
                if bytes.len() > MAX_LOCAL_LAUNCH_INPUT {
                    return Err(io::Error::other("local startup input exceeds limit"));
                }
                Ok(bytes)
            },
        )
    }
}

#[derive(Default, serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct OpenRequest {
    pub id: String,
    pub policy: Policy,
    pub create: bool,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch: Option<LocalLaunchSpec>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resurrect_launch: Option<LocalLaunchSpec>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub inline_viewer: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub recreate_if_gone: bool,
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
}

fn valid_remote_header_value(value: Option<&String>) -> bool {
    value.is_none_or(|s| s.len() <= 128 && !s.chars().any(char::is_control))
}

impl OpenRequest {
    pub fn validate_remote_options(&self) -> io::Result<()> {
        if self.cols.is_some_and(|c| c == 0 || c > 500)
            || self.rows.is_some_and(|r| r == 0 || r > 300)
            || !valid_remote_header_value(self.term.as_ref())
            || !valid_remote_header_value(self.colorterm.as_ref())
            || !valid_remote_header_value(self.term_program.as_ref())
            || !valid_remote_header_value(self.term_program_version.as_ref())
            || !valid_remote_header_value(self.color_scheme.as_ref())
        {
            return Err(io::Error::other("invalid remote session options"));
        }
        Ok(())
    }

    pub fn clear_remote_options(&mut self) {
        self.clear_init_size();
        self.clear_remote_env();
    }

    pub fn clear_init_size(&mut self) {
        self.cols = None;
        self.rows = None;
        self.pixel_width = None;
        self.pixel_height = None;
    }

    pub fn clear_remote_env(&mut self) {
        self.term = None;
        self.colorterm = None;
        self.term_program = None;
        self.term_program_version = None;
        self.color_scheme = None;
        self.foreground = None;
        self.background = None;
        self.cursor = None;
    }

    fn to_remote_launch(&self, state_dir: &Path) -> server::RemoteSessionLaunch {
        server::RemoteSessionLaunch {
            cols: self.cols,
            rows: self.rows,
            pixel_width: self.pixel_width,
            pixel_height: self.pixel_height,
            term: self.term.clone(),
            colorterm: self.colorterm.clone(),
            term_program: self.term_program.clone(),
            term_program_version: self.term_program_version.clone(),
            color_scheme: self.color_scheme.clone(),
            foreground: self.foreground,
            background: self.background,
            cursor: self.cursor,
            state_dir: Some(state_dir.to_path_buf()),
        }
    }
}

fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Default)]
struct ConnectOptions<'a> {
    cwd: Option<&'a str>,
    launch: Option<LocalLaunchSpec>,
    resurrect_launch: Option<LocalLaunchSpec>,
    remote_launch: Option<server::RemoteSessionLaunch>,
    inline_viewer: bool,
    recreate_if_gone: bool,
    initial_resume: Option<&'a crate::record::Resume>,
}

type SessionInflightTable = Arc<(Mutex<std::collections::HashSet<String>>, std::sync::Condvar)>;

struct SessionInflightGuard {
    table: SessionInflightTable,
    id: String,
}

impl SessionInflightGuard {
    fn acquire(table: &SessionInflightTable, id: &str) -> Self {
        let (lock, cvar) = &**table;
        let mut active = lock.lock().unwrap_or_else(|p| p.into_inner());
        while active.contains(id) {
            active = cvar.wait(active).unwrap_or_else(|p| p.into_inner());
        }
        active.insert(id.to_owned());
        Self {
            table: table.clone(),
            id: id.to_owned(),
        }
    }
}

impl Drop for SessionInflightGuard {
    fn drop(&mut self) {
        let (lock, cvar) = &*self.table;
        let mut active = lock.lock().unwrap_or_else(|p| p.into_inner());
        active.remove(&self.id);
        cvar.notify_all();
    }
}

struct LocalHolderSpawnPlan {
    id: String,
    socket: PathBuf,
    path: PathBuf,
    record: Record,
    child: Option<Child>,
    migrated_from: Option<(PathBuf, PathBuf)>,
    created_new_record: bool,
    created_dest_marker: bool,
}

impl LocalHolderSpawnPlan {
    fn terminate_and_reap_child(&mut self) {
        if let Some(mut child) = self.child.take() {
            if child.try_wait().ok().flatten().is_none() {
                let _ = child.kill();
            }
            let _ = child.wait();
        }
    }
}

impl Drop for LocalHolderSpawnPlan {
    fn drop(&mut self) {
        self.terminate_and_reap_child();
    }
}

pub struct Registry {
    pub root: PathBuf,
    pub command: Vec<String>,
    pub policy: Policy,
    workers: HashMap<String, JoinHandle<()>>,
    presentations: HashMap<String, Arc<Mutex<crate::activity::Snapshot>>>,
    finished_workers: Arc<Mutex<Vec<String>>>,
    wakeup: Option<crate::WakePipe>,
    local_holders: HashMap<String, LocalHolder>,
    inflight_sessions: SessionInflightTable,
    mode: RuntimeMode,
    containment_root: Option<PathBuf>,
    last_maintenance: Instant,
    #[cfg(test)]
    holder_executable: Option<PathBuf>,
}
impl Registry {
    pub fn new(root: PathBuf, command: Vec<String>, policy: Policy) -> Self {
        Self {
            root,
            command,
            policy,
            workers: HashMap::new(),
            presentations: HashMap::new(),
            finished_workers: Arc::new(Mutex::new(Vec::new())),
            wakeup: None,
            local_holders: HashMap::new(),
            inflight_sessions: Arc::new((
                Mutex::new(std::collections::HashSet::new()),
                std::sync::Condvar::new(),
            )),
            mode: RuntimeMode::Remote,
            containment_root: None,
            last_maintenance: Instant::now() - Duration::from_secs(30),
            #[cfg(test)]
            holder_executable: None,
        }
    }

    pub fn new_local(root: PathBuf, command: Vec<String>, policy: Policy) -> Self {
        let mut registry = Self::new(root, command, policy);
        registry.mode = RuntimeMode::Local;
        registry
    }

    pub(crate) fn set_wakeup(&mut self, wakeup: crate::WakePipe) {
        self.wakeup = Some(wakeup);
    }

    pub fn supports_local_launch(&self) -> bool {
        self.mode == RuntimeMode::Local
    }
    pub fn set_containment_root(&mut self, root: Option<PathBuf>) {
        self.containment_root = root;
    }
    fn is_session_inflight(&self, id: &str) -> bool {
        self.inflight_sessions
            .0
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .contains(id)
    }
    fn session_socket_in(sessions_root: &Path, id: &str) -> PathBuf {
        use sha2::{Digest, Sha256};
        let key = format!("{:x}", Sha256::digest(id.as_bytes()));
        sessions_root
            .parent()
            .unwrap()
            .join(format!("{}.sock", &key[..16]))
    }
    #[cfg(test)]
    fn session_socket(&self, id: &str) -> PathBuf {
        Self::session_socket_in(&self.root, id)
    }
    fn is_private_owned_dir(path: &Path) -> bool {
        use std::os::unix::fs::MetadataExt;
        let Ok(meta) = fs::symlink_metadata(path) else {
            return false;
        };
        meta.file_type().is_dir()
            && meta.uid() == unsafe { libc::geteuid() }
            && (meta.mode() & 0o077) == 0
    }
    fn support_path_variants(cur_support: &Path, home: Option<&Path>) -> Vec<PathBuf> {
        let mut variants = Vec::new();
        let mut push_unique = |p: PathBuf| {
            let norm = normalize_support_path(&p);
            if !norm.as_os_str().is_empty() && !variants.contains(&norm) {
                variants.push(norm);
            }
        };
        let norm = normalize_support_path(cur_support);
        push_unique(norm.clone());
        if let Ok(canon) = fs::canonicalize(&norm) {
            push_unique(canon);
        }
        push_unique(prefer_logical_home_path_with_home(&norm, home));
        if let Some(logical_home) = home.map(normalize_support_path).filter(|p| p.is_absolute()) {
            if let Some(channel_name) = norm.file_name() {
                let candidate = logical_home
                    .join("Library/Application Support")
                    .join(channel_name);
                if same_canonical_path(&candidate, &norm) {
                    push_unique(candidate);
                }
            }
        }
        variants
    }
    fn sibling_session_roots_for(root: &Path) -> Vec<PathBuf> {
        let env_home = std::env::var_os("HOME").map(PathBuf::from);
        Self::sibling_session_roots_for_with_home(root, env_home.as_deref())
    }
    fn sibling_session_roots_for_with_home(root: &Path, home: Option<&Path>) -> Vec<PathBuf> {
        let Some(current_state_dir) = root.parent() else {
            return Vec::new();
        };
        let Some(run_root) = current_state_dir.parent() else {
            return Vec::new();
        };
        if !Self::is_private_owned_dir(run_root) {
            return Vec::new();
        }
        let current_support = read_support_root_stamp(current_state_dir);
        let current_canonical = current_support
            .as_ref()
            .and_then(|cur| fs::canonicalize(cur).ok());
        let legacy_allowed_hashes = if let Some(ref cur_support) = current_support {
            if !cur_support.exists() {
                return Vec::new();
            }
            let variants = Self::support_path_variants(cur_support, home);
            let mut hashes = std::collections::HashSet::new();
            for variant in &variants {
                hashes.insert(legacy_local_run_dir_key(variant, env!("CARGO_PKG_VERSION")));
            }
            if let Ok(entries) = fs::read_dir(cur_support.join("session-runtime/versions")) {
                for entry in entries.take(256).flatten() {
                    if let Some(rev) = entry.file_name().to_str() {
                        if crate::valid_revision(rev) {
                            for variant in &variants {
                                hashes.insert(legacy_local_run_dir_key(variant, rev));
                            }
                        }
                    }
                }
            }
            Some(hashes)
        } else {
            None
        };
        let Ok(entries) = fs::read_dir(run_root) else {
            return Vec::new();
        };
        let mut roots = Vec::new();
        for entry in entries.flatten() {
            let state_dir = entry.path();
            if state_dir == current_state_dir || !Self::is_private_owned_dir(&state_dir) {
                continue;
            }
            let sibling_support = read_support_root_stamp(&state_dir);
            let channel_matches = match (&current_support, sibling_support) {
                (Some(cur), Some(sib)) => {
                    &sib == cur
                        || current_canonical
                            .as_ref()
                            .zip(fs::canonicalize(&sib).ok())
                            .is_some_and(|(cur_c, sib_c)| cur_c == &sib_c)
                }
                (Some(_), None) => {
                    state_dir
                        .file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|name| {
                            legacy_allowed_hashes
                                .as_ref()
                                .is_some_and(|set| set.contains(name))
                        })
                }
                (None, None) => true,
                (None, Some(_)) => false,
            };
            if !channel_matches {
                continue;
            }
            let sessions_dir = state_dir.join("sessions");
            if Self::is_private_owned_dir(&sessions_dir) {
                roots.push(sessions_dir);
            }
        }
        roots.sort();
        roots
    }
    fn sibling_has_live_host_lock(sibling_sessions_dir: &Path) -> bool {
        use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
        let Some(state_dir) = sibling_sessions_dir.parent() else {
            return false;
        };
        let lock_path = state_dir.join("host.lock");
        let Ok(file) = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&lock_path)
        else {
            return false;
        };
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) };
        if rc == 0 {
            unsafe {
                libc::flock(file.as_raw_fd(), libc::LOCK_UN);
            }
            false
        } else {
            true
        }
    }

    fn sibling_session_roots(&self) -> Vec<PathBuf> {
        if self.mode != RuntimeMode::Local {
            return Vec::new();
        }
        Self::sibling_session_roots_for(&self.root)
    }

    fn is_closed_in_any_root(&self, id: &str) -> bool {
        if self.mode != RuntimeMode::Local {
            return self.root.join(format!("{id}.closed")).exists();
        }
        is_local_session_closed(&self.root, id)
    }

    fn find_sibling_local_session_root(&self, id: &str) -> Option<PathBuf> {
        let siblings = self.sibling_session_roots();
        if siblings.is_empty() {
            return None;
        }
        let mut record_candidates = Vec::new();
        let mut created_fallback = None;
        for sessions_dir in siblings {
            if Self::sibling_has_live_host_lock(&sessions_dir) {
                continue;
            }
            if sessions_dir.join(format!("{id}.closed")).exists() {
                return Some(sessions_dir);
            }
            let record_path = sessions_dir.join(format!("{id}.json"));
            if record_path.exists() {
                let key = Record::load(&record_path)
                    .map(|record| (record.updated_at, record.created_at))
                    .unwrap_or((0, 0));
                record_candidates.push((key, sessions_dir));
                continue;
            }
            if created_fallback.is_none() && sessions_dir.join(format!("{id}.created")).exists() {
                created_fallback = Some(sessions_dir);
            }
        }
        if !record_candidates.is_empty() {
            record_candidates.sort_by(|a, b| b.cmp(a));
            return record_candidates.into_iter().next().map(|(_, dir)| dir);
        }
        created_fallback
    }
    fn probe_local_holder_outside_lock(
        session_socket: &Path,
        record_path: &Path,
        record: &Record,
        capability: &str,
        timeout: Duration,
        verify_owned_child: bool,
    ) -> io::Result<crate::holder::HolderStatusView> {
        let attempts = if verify_owned_child { 3 } else { 1 };
        for attempt in 0..attempts {
            match crate::holder::probe_with_timeout(
                session_socket,
                &record.id,
                &record.generation,
                capability,
                timeout,
            ) {
                Ok(probe) => {
                    let current = Record::load(record_path)?;
                    if current.id != record.id
                        || current.generation != record.generation
                        || current.holder_capability.as_deref() != Some(capability)
                    {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "local holder record identity changed",
                        ));
                    }
                    if let Some(ended) = current.ended {
                        return Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            format!("local session ended: {ended:?}"),
                        ));
                    }
                    if current.pid.is_some() && probe.session_pid != current.pid {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "local holder process identity did not match its record",
                        ));
                    }
                    return Ok(probe);
                }
                Err(error)
                    if verify_owned_child
                        && attempt + 1 < attempts
                        && matches!(
                            error.kind(),
                            io::ErrorKind::UnexpectedEof
                                | io::ErrorKind::ConnectionReset
                                | io::ErrorKind::ConnectionAborted
                                | io::ErrorKind::BrokenPipe
                        ) =>
                {
                    let current = Record::load(record_path)?;
                    if current.id != record.id
                        || current.generation != record.generation
                        || current.holder_capability.as_deref() != Some(capability)
                    {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "local holder record identity changed",
                        ));
                    }
                    if let Some(ended) = current.ended {
                        return Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            format!("local session ended: {ended:?}"),
                        ));
                    }
                    thread::sleep(Duration::from_millis(20));
                }
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::other("local holder probe failed"))
    }

    fn adopt_probed_holder(&mut self, id: &str, capability: &str) {
        if !self
            .local_holders
            .get(id)
            .is_some_and(|holder| holder.capability == capability && holder.child.is_some())
        {
            self.local_holders.insert(
                id.to_owned(),
                LocalHolder {
                    capability: capability.to_owned(),
                    child: None,
                },
            );
        }
    }

    fn check_owned_holder_child(
        &mut self,
        id: &str,
        capability: &str,
        verify_owned_child: bool,
    ) -> io::Result<bool> {
        let owned_child_status = self
            .local_holders
            .get_mut(id)
            .filter(|holder| holder.capability == capability)
            .and_then(|holder| holder.child.as_mut())
            .map(Child::try_wait)
            .transpose();
        match owned_child_status {
            Ok(Some(None)) if !verify_owned_child => Ok(true),
            Ok(Some(Some(_))) => {
                self.local_holders.remove(id);
                Ok(false)
            }
            Err(error) if !verify_owned_child => Err(error),
            _ => Ok(false),
        }
    }

    fn probe_and_adopt(
        &mut self,
        record: &Record,
        timeout: Duration,
        verify_owned_child: bool,
    ) -> io::Result<()> {
        let root = self.root.clone();
        self.probe_and_adopt_in(&root, record, timeout, verify_owned_child)
    }
    fn probe_and_adopt_in(
        &mut self,
        sessions_root: &Path,
        record: &Record,
        timeout: Duration,
        verify_owned_child: bool,
    ) -> io::Result<()> {
        let Some(capability) = record.holder_capability.as_deref() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "local holder capability is missing",
            ));
        };
        if self.check_owned_holder_child(&record.id, capability, verify_owned_child)? {
            return Ok(());
        }
        let session_socket = Self::session_socket_in(sessions_root, &record.id);
        let record_path = sessions_root.join(format!("{}.json", record.id));
        Self::probe_local_holder_outside_lock(
            &session_socket,
            &record_path,
            record,
            capability,
            timeout,
            verify_owned_child,
        )?;
        self.adopt_probed_holder(&record.id, capability);
        Ok(())
    }

    fn pid_known_dead(pid: Option<u32>) -> bool {
        let Some(pid) = pid else {
            return false;
        };
        if pid <= 1 {
            return true;
        }
        let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
        rc != 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
    }

    fn local_holder_startup_grace_elapsed(&self, record: &Record) -> bool {
        if Self::pid_known_dead(record.pid) {
            return true;
        }
        let current_boot = crate::record::current_boot_time();
        if crate::record::is_prior_boot(record.boot_time, current_boot) {
            return true;
        }
        if record.boot_time.is_none()
            && current_boot.is_some_and(|boot| {
                record.created_at.min(record.updated_at) < boot.saturating_sub(5)
            })
        {
            return true;
        }
        unix_time().saturating_sub(record.created_at) >= LOCAL_HOLDER_STARTUP_GRACE_SECONDS
    }

    fn mark_local_lost(&mut self, record: &mut Record, path: &std::path::Path) -> io::Result<bool> {
        let root = self.root.clone();
        self.mark_local_lost_in(&root, record, path)
    }

    fn mark_local_lost_in(
        &mut self,
        sessions_root: &Path,
        record: &mut Record,
        path: &std::path::Path,
    ) -> io::Result<bool> {
        let mut current = Record::load(path)?;
        if current.id != record.id
            || current.generation != record.generation
            || current.ended.is_some()
        {
            *record = current;
            return Ok(false);
        }
        current.pid = None;
        current.ended = Some(EndReason::Lost);
        current.save(path)?;
        *record = current;
        self.local_holders.remove(&record.id);
        let socket = Self::session_socket_in(sessions_root, &record.id);
        let _ = fs::remove_file(socket.with_extension("evt"));
        let _ = fs::remove_file(crate::holder::control_path(&socket));
        let _ = fs::remove_file(socket);
        Ok(true)
    }
    fn reap_finished_children(&mut self) {
        let notified: Vec<_> = std::mem::take(&mut *self.finished_workers.lock().unwrap());
        for id in notified {
            self.presentations.remove(&id);
            if let Some(h) = self.workers.remove(&id) {
                let _ = h.join();
            }
        }
        let finished: Vec<_> = self
            .workers
            .iter()
            .filter(|(_, h)| h.is_finished())
            .map(|(id, _)| id.clone())
            .collect();
        for id in finished {
            self.presentations.remove(&id);
            if let Some(h) = self.workers.remove(&id) {
                let _ = h.join();
            }
        }
        if self.mode == RuntimeMode::Local {
            let finished: Vec<_> = self
                .local_holders
                .iter_mut()
                .filter_map(|(id, holder)| {
                    holder
                        .child
                        .as_mut()
                        .and_then(|child| child.try_wait().ok().flatten())
                        .map(|_| id.clone())
                })
                .collect();
            for id in finished {
                self.local_holders.remove(&id);
            }
        }
    }

    pub fn maintenance(&mut self) {
        self.reap_finished_children();
        if self.last_maintenance.elapsed() < Duration::from_secs(30) {
            return;
        }
        self.last_maintenance = Instant::now();
        let now = unix_time();
        let mut local_probes = 0;
        let mut closed_paths = Vec::new();
        let mut created_paths = Vec::new();
        let mut snapshot_paths = Vec::new();
        if let Ok(entries) = fs::read_dir(&self.root) {
            for entry in entries.flatten() {
                let entry_path = entry.path();
                if entry_path.extension().is_some_and(|s| s == "closed") {
                    closed_paths.push(entry_path);
                    continue;
                }
                if entry_path.extension().is_some_and(|s| s == "created") {
                    created_paths.push(entry_path);
                    continue;
                }
                if entry_path.extension().is_some_and(|s| s == "snapshot") {
                    snapshot_paths.push(entry_path);
                    continue;
                }
                if entry_path
                    .file_name()
                    .and_then(|s| s.to_str())
                    .is_some_and(|name| name.contains(".snapshot.tmp."))
                {
                    if file_modified_unix(&entry_path)
                        .is_some_and(|m| now.saturating_sub(m) > LOCAL_HOLDER_STARTUP_GRACE_SECONDS)
                    {
                        let _ = fs::remove_file(&entry_path);
                    }
                    continue;
                }
                if entry_path.extension().is_some_and(|s| s == "json") {
                    if let Ok(mut record) = Record::load(&entry_path) {
                        if !valid_id(&record.id)
                            || self.workers.contains_key(&record.id)
                            || self.is_session_inflight(&record.id)
                        {
                            continue;
                        }
                        if self.mode == RuntimeMode::Local {
                            if record.ended.is_none() {
                                if local_probes >= MAX_LOCAL_MAINTENANCE_PROBES {
                                    continue;
                                }
                                local_probes += 1;
                                match self.probe_and_adopt(
                                    &record,
                                    LOCAL_MAINTENANCE_PROBE_TIMEOUT,
                                    false,
                                ) {
                                    Ok(()) => continue,
                                    Err(error)
                                        if crate::holder::listener_is_gone(&error)
                                            && self.local_holder_startup_grace_elapsed(&record) =>
                                    {
                                        if self.mark_local_lost(&mut record, &entry_path).is_err() {
                                            continue;
                                        }
                                    }
                                    Err(_) => continue,
                                }
                            }
                            if record.ended.is_some()
                                && now.saturating_sub(record.updated_at)
                                    > record.policy.record_retention_seconds
                            {
                                crate::server::remove_snapshot_files(&entry_path);
                                let _ = fs::remove_file(&entry_path);
                            }
                            continue;
                        }
                        if record.ended.is_none() || record.pid.is_some() {
                            if let Some(root) = &self.containment_root {
                                if crate::containment::Group::finish_generation(
                                    root,
                                    &record.generation,
                                )
                                .is_err()
                                {
                                    continue;
                                }
                            }
                            record.pid = None;
                            record.ended = Some(EndReason::Lost);
                            if record.save(&entry_path).is_err() {
                                continue;
                            }
                        }
                        // We hold the host lock and there is no actor for this UUID.
                        // Never signal the numeric PID stored by a previous host.
                        use sha2::{Digest, Sha256};
                        let key = format!("{:x}", Sha256::digest(record.id.as_bytes()));
                        if let Some(parent) = self.root.parent() {
                            let socket = parent.join(format!("{}.sock", &key[..16]));
                            let _ = fs::remove_file(socket.with_extension("evt"));
                            let _ = fs::remove_file(socket);
                        }
                        if record.ended.is_some()
                            && now.saturating_sub(record.updated_at)
                                > record.policy.record_retention_seconds
                        {
                            crate::server::remove_snapshot_files(&entry_path);
                            let _ = fs::remove_file(&entry_path);
                        }
                    }
                }
            }
        }
        for snap_path in snapshot_paths {
            let Some(id) = snap_path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if !valid_id(id)
                || self.workers.contains_key(id)
                || self.local_holders.contains_key(id)
                || self.is_session_inflight(id)
            {
                continue;
            }
            if self.is_closed_in_any_root(id) {
                let _ = fs::remove_file(&snap_path);
                continue;
            }
            if !self.root.join(format!("{id}.json")).exists()
                && file_modified_unix(&snap_path)
                    .is_some_and(|m| now.saturating_sub(m) > LOCAL_HOLDER_STARTUP_GRACE_SECONDS)
            {
                let _ = fs::remove_file(&snap_path);
            }
        }
        for created_path in created_paths {
            let Some(id) = created_path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if !valid_id(id)
                || self.workers.contains_key(id)
                || self.local_holders.contains_key(id)
                || self.is_session_inflight(id)
                || self.root.join(format!("{id}.json")).exists()
            {
                continue;
            }
            if file_modified_unix(&created_path)
                .is_some_and(|m| now.saturating_sub(m) > ORPHAN_CREATED_MARKER_MAX_AGE_SECONDS)
            {
                let _ = fs::remove_file(&created_path);
            }
        }
        for closed_path in closed_paths {
            let Some(id) = closed_path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if !valid_id(id)
                || self.workers.contains_key(id)
                || self.local_holders.contains_key(id)
                || self.is_session_inflight(id)
            {
                continue;
            }
            crate::server::remove_snapshot_files(&closed_path.with_extension("json"));
            if self.root.join(format!("{id}.json")).exists() {
                continue;
            }
            if let Some(modified) = file_modified_unix(&closed_path) {
                if now.saturating_sub(modified) > TOMBSTONE_RETENTION_SECONDS {
                    let _ = fs::remove_file(&closed_path);
                }
            }
        }
        for sibling in self.sibling_session_roots() {
            let sibling_live_broker = Self::sibling_has_live_host_lock(&sibling);
            let Ok(entries) = fs::read_dir(&sibling) else {
                continue;
            };
            for entry in entries.flatten() {
                let entry_path = entry.path();
                if entry_path.extension().is_some_and(|s| s == "json") {
                    if let Ok(mut record) = Record::load(&entry_path) {
                        if !valid_id(&record.id) {
                            continue;
                        }
                        if self.is_closed_in_any_root(&record.id) {
                            crate::server::remove_snapshot_files(&entry_path);
                        } else if !sibling_live_broker && record.ended.is_none() {
                            let prior_boot = crate::record::is_prior_boot(
                                record.boot_time,
                                crate::record::current_boot_time(),
                            );
                            let dead_listener = prior_boot || {
                                let sock = Self::session_socket_in(&sibling, &record.id);
                                record
                                    .holder_capability
                                    .as_deref()
                                    .and_then(|cap| {
                                        crate::holder::probe_with_timeout(
                                            &sock,
                                            &record.id,
                                            &record.generation,
                                            cap,
                                            LOCAL_MAINTENANCE_PROBE_TIMEOUT,
                                        )
                                        .err()
                                    })
                                    .is_some_and(|err| {
                                        crate::holder::listener_is_gone(&err)
                                            && self.local_holder_startup_grace_elapsed(&record)
                                    })
                            };
                            if dead_listener {
                                let _ = self.mark_local_lost_in(&sibling, &mut record, &entry_path);
                            }
                        }
                        if record.ended.is_some()
                            && now.saturating_sub(record.updated_at)
                                > record.policy.record_retention_seconds
                        {
                            crate::server::remove_snapshot_files(&entry_path);
                            let _ = fs::remove_file(&entry_path);
                        }
                    }
                } else if entry_path.extension().is_some_and(|s| s == "snapshot") {
                    let Some(id) = entry_path.file_stem().and_then(|s| s.to_str()) else {
                        continue;
                    };
                    if !valid_id(id) {
                        continue;
                    }
                    if self.is_closed_in_any_root(id)
                        || (!sibling.join(format!("{id}.json")).exists()
                            && file_modified_unix(&entry_path).is_some_and(|m| {
                                now.saturating_sub(m) > LOCAL_HOLDER_STARTUP_GRACE_SECONDS
                            }))
                    {
                        let _ = fs::remove_file(&entry_path);
                    }
                } else if !sibling_live_broker
                    && entry_path.extension().is_some_and(|s| s == "created")
                {
                    let Some(id) = entry_path.file_stem().and_then(|s| s.to_str()) else {
                        continue;
                    };
                    if valid_id(id)
                        && !sibling.join(format!("{id}.json")).exists()
                        && file_modified_unix(&entry_path).is_some_and(|m| {
                            now.saturating_sub(m) > ORPHAN_CREATED_MARKER_MAX_AGE_SECONDS
                        })
                    {
                        let _ = fs::remove_file(&entry_path);
                    }
                }
            }
        }
    }
    /// Durable close intent, independent of attachments. UUIDs are never reused:
    /// the permanent marker also prohibits an automatic Agent resume/new generation.
    pub fn close(&mut self, id: &str) -> io::Result<bool> {
        if !valid_id(id) {
            return Err(io::Error::other("invalid session identity"));
        }
        let marker = self.root.join(format!("{id}.closed"));
        let file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(marker)?;
        file.sync_all()?;
        fs::File::open(&self.root)?.sync_all()?;
        if self.workers.get(id).is_some_and(|w| !w.is_finished()) {
            return Ok(false);
        }
        self.maintenance();
        let own_path = self.root.join(format!("{id}.json"));
        let (target_root, path) = if own_path.exists() {
            (self.root.clone(), own_path)
        } else if let Some(sibling_root) = self.find_sibling_local_session_root(id) {
            let sibling_marker = sibling_root.join(format!("{id}.closed"));
            let sibling_file = fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .open(sibling_marker)?;
            sibling_file.sync_all()?;
            fs::File::open(&sibling_root)?.sync_all()?;
            let sibling_path = sibling_root.join(format!("{id}.json"));
            (sibling_root, sibling_path)
        } else {
            (self.root.clone(), own_path)
        };
        if let Ok(mut record) = Record::load(&path) {
            if self.mode == RuntimeMode::Local && (record.ended.is_none() || record.pid.is_some()) {
                match self.probe_and_adopt_in(&target_root, &record, Duration::from_secs(1), true) {
                    Ok(()) => return Ok(false),
                    Err(error)
                        if crate::holder::listener_is_gone(&error)
                            && self.local_holder_startup_grace_elapsed(&record) =>
                    {
                        if self.mark_local_lost_in(&target_root, &mut record, &path)? {
                            return Err(io::Error::other(
                                "local holder is unavailable; cleanup is unconfirmed",
                            ));
                        }
                        if record.pid.is_some() {
                            return Err(io::Error::other(
                                "local session is still ending; cleanup is unconfirmed",
                            ));
                        }
                        if record.ended.is_none() {
                            return Err(io::Error::other(
                                "local session identity changed; cleanup is unconfirmed",
                            ));
                        }
                        record.ended = Some(EndReason::ExplicitClose);
                        crate::server::remove_snapshot_files(&path);
                        record.save(&path)?;
                        return Ok(true);
                    }
                    Err(error) if crate::holder::listener_is_gone(&error) => {
                        return Err(io::Error::other(
                            "local holder may still be starting; cleanup is unconfirmed",
                        ));
                    }
                    Err(error) => {
                        let current = Record::load(&path)?;
                        if current.generation == record.generation && current.ended.is_some() {
                            if current.pid.is_some() {
                                return Err(io::Error::other(
                                    "local session is still ending; cleanup is unconfirmed",
                                ));
                            }
                            record = current;
                            record.ended = Some(EndReason::ExplicitClose);
                            crate::server::remove_snapshot_files(&path);
                            record.save(&path)?;
                            return Ok(true);
                        }
                        return Err(io::Error::other(format!(
                            "local holder did not confirm cleanup ({:?}); session preserved",
                            error.kind()
                        )));
                    }
                }
            }
            if self.mode != RuntimeMode::Local && record.ended == Some(EndReason::Lost) {
                // Only an owned cgroup provides evidence for cleanup after loss.
                if !record.contained {
                    return Err(io::Error::other("legacy session loss; cleanup unconfirmed"));
                }
                let root = self.containment_root.as_ref().ok_or_else(|| {
                    io::Error::other("session lost; cleanup could not be confirmed")
                })?;
                crate::containment::Group::finish_generation(root, &record.generation)?;
            }
            record.pid = None;
            record.ended = Some(EndReason::ExplicitClose);
            crate::server::remove_snapshot_files(&path);
            record.save(&path)?;
        } else {
            crate::server::remove_snapshot_files(&path);
        }
        Ok(true)
    }
    pub fn is_empty(&self) -> bool {
        if self.mode != RuntimeMode::Local {
            return self.workers.is_empty();
        }
        if !self.local_holders.is_empty() {
            return false;
        }
        let Ok(entries) = fs::read_dir(&self.root) else {
            return true;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|s| s == "json") {
                if let Ok(record) = Record::load(&path) {
                    if record.ended.is_none() && !self.is_closed_in_any_root(&record.id) {
                        return false;
                    }
                }
            }
        }
        true
    }

    pub fn is_local(&self) -> bool {
        self.mode == RuntimeMode::Local
    }
    pub fn list(&self) -> io::Result<Vec<Record>> {
        let mut records = vec![];
        let mut seen_ids = std::collections::HashSet::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().is_some_and(|s| s == "json") {
                if let Ok(r) = Record::load(&path) {
                    seen_ids.insert(r.id.clone());
                    records.push(r);
                }
            } else if path.extension().is_some_and(|s| s == "created") {
                if let Some(id) = path.file_stem().and_then(|s| s.to_str()) {
                    seen_ids.insert(id.to_owned());
                }
            }
        }
        if self.mode == RuntimeMode::Local {
            let mut sibling_best: BTreeMap<String, Record> = BTreeMap::new();
            for sibling in self.sibling_session_roots() {
                if Self::sibling_has_live_host_lock(&sibling) {
                    continue;
                }
                let Ok(entries) = fs::read_dir(&sibling) else {
                    continue;
                };
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().is_some_and(|s| s == "json") {
                        if let Ok(r) = Record::load(&path) {
                            if !valid_id(&r.id)
                                || seen_ids.contains(&r.id)
                                || self.is_closed_in_any_root(&r.id)
                                || r.ended != Some(EndReason::Lost)
                            {
                                continue;
                            }
                            let replace = sibling_best.get(&r.id).is_none_or(|prev| {
                                (r.updated_at, r.created_at) > (prev.updated_at, prev.created_at)
                            });
                            if replace {
                                sibling_best.insert(r.id.clone(), r);
                            }
                        }
                    }
                }
            }
            records.extend(sibling_best.into_values());
        }
        records.sort_by(|a, b| {
            a.created_at
                .cmp(&b.created_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(records)
    }

    pub fn catalogue(&mut self) -> io::Result<Vec<Record>> {
        if self.mode == RuntimeMode::Local {
            self.last_maintenance = Instant::now() - Duration::from_secs(30);
            self.maintenance();
        }
        self.list()
    }

    pub fn catalogue_summaries(&mut self) -> io::Result<Vec<crate::record::SessionSummary>> {
        let records = self.catalogue()?;
        let mut local_queries = 0usize;
        let mut summaries = Vec::with_capacity(records.len());
        for record in &records {
            let mut summary = crate::record::SessionSummary::from(record);
            if record.ended.is_none() {
                if self.mode == RuntimeMode::Remote {
                    if self
                        .workers
                        .get(&record.id)
                        .is_some_and(|w| !w.is_finished())
                    {
                        if let Some(pres) = self.presentations.get(&record.id) {
                            summary.activity = pres.lock().ok().map(|s| s.clone());
                        }
                    }
                } else if local_queries < MAX_RUNNING && record.holder_capability.is_some() {
                    local_queries += 1;
                    let socket = Self::session_socket_in(&self.root, &record.id);
                    summary.activity = crate::holder::presentation_with_timeout(
                        &socket,
                        record,
                        Duration::from_millis(50),
                    )
                    .ok();
                }
            }
            summaries.push(summary);
        }
        Ok(summaries)
    }
    pub fn connect(&mut self, id: &str, resume_generation: Option<&str>) -> io::Result<UnixStream> {
        self.connect_with(id, resume_generation, None, true, ConnectOptions::default())
    }
    pub fn open(&mut self, request: &OpenRequest) -> io::Result<UnixStream> {
        request.policy.validate()?;
        request.validate_remote_options()?;
        let request_size = serde_json::to_vec(request)?.len();
        if request_size > MAX_OPEN_REQUEST_BYTES {
            return Err(io::Error::other("session open request exceeds limit"));
        }
        let mut local_launch = request.launch.clone();
        match (self.mode, request.create, local_launch.as_mut()) {
            (RuntimeMode::Remote, _, Some(_)) => {
                return Err(io::Error::other(
                    "local launch specifications are forbidden on SSH sessions",
                ));
            }
            (RuntimeMode::Local, true, Some(launch)) => {
                launch.validate()?;
            }
            (RuntimeMode::Local, true, None) => {
                return Err(io::Error::other(
                    "local session launch specification required",
                ));
            }
            (RuntimeMode::Local, false, Some(_)) => {
                return Err(io::Error::other(
                    "reattaching a local session cannot send a launch specification",
                ));
            }
            _ => {}
        }
        if let Some(resurrect) = &request.resurrect_launch {
            if self.mode != RuntimeMode::Local {
                return Err(io::Error::other(
                    "local resurrection specifications are forbidden on SSH sessions",
                ));
            }
            if request.create {
                return Err(io::Error::other(
                    "creating a local session cannot send a resurrection launch specification",
                ));
            }
            resurrect.validate_with(false)?;
            if resurrect
                .input_base64
                .as_ref()
                .is_some_and(|value| !value.is_empty())
            {
                return Err(io::Error::other(
                    "local resurrection specification cannot carry initial input",
                ));
            }
        }
        self.connect_with(
            &request.id,
            None,
            Some(request.policy.clone()),
            request.create,
            ConnectOptions {
                cwd: request.cwd.as_deref(),
                launch: local_launch,
                resurrect_launch: request.resurrect_launch.clone(),
                remote_launch: Some(request.to_remote_launch(&self.root)),
                inline_viewer: request.inline_viewer,
                recreate_if_gone: request.recreate_if_gone,
                initial_resume: request.resume.as_ref(),
            },
        )
    }
    fn recreate_remote_record(
        &self,
        id: &str,
        initial_cwd: Option<&str>,
        record_cwd: Option<&str>,
        resume_cwd: Option<&str>,
        policy: Option<Policy>,
    ) -> io::Result<(Record, PathBuf)> {
        let home = std::env::var("HOME")
            .ok()
            .filter(|h| !h.is_empty() && Path::new(h).is_dir());
        let resolved =
            Self::resolve_existing_cwd(&[initial_cwd, record_cwd, resume_cwd], home.as_deref());
        Self::remove_session_artifacts_in(&self.root, id);
        if self.list()?.len() >= MAX_RECORDS {
            return Err(io::Error::other("session metadata quota exceeded"));
        }
        use std::os::unix::fs::OpenOptionsExt;
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(self.root.join(format!("{id}.created")))?;
        let mut fresh = Record::new(id, policy.unwrap_or_else(|| self.policy.clone()))?;
        fresh.cwd = Some(resolved.clone());
        Ok((fresh, PathBuf::from(resolved)))
    }
    fn connect_with(
        &mut self,
        id: &str,
        resume_generation: Option<&str>,
        policy: Option<Policy>,
        create: bool,
        options: ConnectOptions<'_>,
    ) -> io::Result<UnixStream> {
        let ConnectOptions {
            cwd: initial_cwd,
            launch: local_launch,
            resurrect_launch,
            remote_launch,
            inline_viewer,
            recreate_if_gone,
            initial_resume,
        } = options;
        if !valid_id(id) {
            return Err(io::Error::other("invalid session identity"));
        }
        self.maintenance();
        if !recreate_if_gone && self.is_closed_in_any_root(id) {
            return Err(io::Error::other("session explicitly closed"));
        }
        use sha2::{Digest, Sha256};
        let key = format!("{:x}", Sha256::digest(id.as_bytes()));
        let socket = self
            .root
            .parent()
            .unwrap()
            .join(format!("{}.sock", &key[..16]));
        let path = self.root.join(format!("{id}.json"));
        if self.workers.contains_key(id) {
            match UnixStream::connect(&socket) {
                Ok(stream) => return Ok(stream),
                Err(_) => {
                    self.presentations.remove(id);
                    if let Some(worker) = self.workers.remove(id) {
                        let _ = worker.join();
                    }
                }
            }
        }
        if self.mode == RuntimeMode::Local {
            return self.connect_local(
                id,
                resume_generation,
                &socket,
                &path,
                create && local_launch.is_some(),
                policy,
                ConnectOptions {
                    cwd: initial_cwd,
                    launch: local_launch,
                    resurrect_launch,
                    remote_launch,
                    inline_viewer,
                    recreate_if_gone,
                    initial_resume: None,
                },
            );
        }
        if self.workers.len() >= MAX_RUNNING {
            return Err(io::Error::other("active session quota exceeded"));
        }
        let mut argv = self.command.clone();
        let mut working_directory = None;
        let allow_recreate = recreate_if_gone && !create && resume_generation.is_none();
        let closed = self.is_closed_in_any_root(id);
        let existing_record = if path.exists() {
            match Record::load(&path) {
                Ok(mut record) => {
                    if !closed && record.ended.is_none() {
                        record.pid = None;
                        record.ended = Some(EndReason::Lost);
                        record.save(&path)?;
                    }
                    Some(record)
                }
                Err(_) if allow_recreate => None,
                Err(error) => return Err(error),
            }
        } else {
            None
        };
        let mut record = if let Some(mut record) = existing_record {
            if !closed
                && resume_generation == Some(record.generation.as_str())
                && record.ended.is_some_and(EndReason::resumable)
            {
                let resume = record
                    .resume
                    .as_ref()
                    .ok_or_else(|| io::Error::other("session has no Agent recovery descriptor"))?;
                if !resume.store_exists() {
                    return Err(io::Error::other(
                        "Agent conversation store unavailable; refusing new conversation",
                    ));
                }
                let args = resume.arguments()?;
                let quote = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
                let script = format!(
                    "exec {}",
                    args.iter().map(|s| quote(s)).collect::<Vec<_>>().join(" ")
                );
                let shell = self
                    .command
                    .first()
                    .ok_or_else(|| io::Error::other("missing shell"))?
                    .clone();
                argv = vec![shell, "-l".into(), "-i".into(), "-c".into(), script];
                record.generation = nonce()?;
                record.ended = None;
                record.pid = None;
                record
            } else if allow_recreate {
                let record_cwd = record.cwd.clone();
                let resume_cwd = record.resume.as_ref().map(|r| r.cwd.clone());
                let (fresh, cwd_path) = self.recreate_remote_record(
                    id,
                    initial_cwd,
                    record_cwd.as_deref(),
                    resume_cwd.as_deref(),
                    policy,
                )?;
                working_directory = Some(cwd_path);
                fresh
            } else {
                return Err(io::Error::other(format!(
                    "session ended: {:?}; inspect its record before resuming",
                    record.ended
                )));
            }
        } else if allow_recreate {
            let (fresh, cwd_path) =
                self.recreate_remote_record(id, initial_cwd, None, None, policy)?;
            working_directory = Some(cwd_path);
            fresh
        } else {
            if resume_generation.is_some() || !create {
                return Err(io::Error::other("unknown session; cannot resume"));
            }
            if self.list()?.len() >= MAX_RECORDS {
                return Err(io::Error::other("session metadata quota exceeded"));
            }
            if let Some(cwd) = initial_cwd {
                if !cwd.starts_with('/') || cwd.len() > 4096 || cwd.contains('\0') {
                    return Err(io::Error::other("invalid initial working directory"));
                }
                if !fs::metadata(cwd)?.is_dir() {
                    return Err(io::Error::other(
                        "initial working directory is not a directory",
                    ));
                }
                working_directory = Some(PathBuf::from(cwd));
            }
            // A compact permanent marker distinguishes a new pane from an
            // expired/deleted recovery record, avoiding silent recreation.
            fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(self.root.join(format!("{id}.created")))?;
            Record::new(id, policy.unwrap_or_else(|| self.policy.clone()))?
        };
        if let Some(resume) = initial_resume {
            resume.validate()?;
            let args = resume.arguments()?;
            let quote = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
            let cmd = args.iter().map(|s| quote(s)).collect::<Vec<_>>().join(" ");
            let shell = self
                .command
                .first()
                .ok_or_else(|| io::Error::other("missing shell"))?
                .clone();
            let script = format!("{cmd}; exec {} -l", quote(&shell));
            argv = vec![shell, "-l".into(), "-i".into(), "-c".into(), script];
            record.resume = Some(resume.clone());
            if working_directory.is_none()
                && fs::metadata(&resume.cwd).is_ok_and(|meta| meta.is_dir())
            {
                working_directory = Some(PathBuf::from(&resume.cwd));
            }
        }
        record.contained = self.containment_root.is_some();
        record.inline_viewer = inline_viewer;
        record.save(&path)?;
        // This host owns the runtime directory exclusively; stale sockets cannot
        // be a still-running worker. Remove only our validated session paths.
        let _ = fs::remove_file(&socket);
        let _ = fs::remove_file(socket.with_extension("evt"));
        let _ = fs::remove_file(crate::holder::control_path(&socket));
        let p = socket.clone();
        let record_path = path.clone();
        let containment_root = self.containment_root.clone();
        struct WorkerExitGuard {
            id: String,
            finished: Arc<Mutex<Vec<String>>>,
            wakeup: Option<crate::WakePipe>,
        }
        impl Drop for WorkerExitGuard {
            fn drop(&mut self) {
                self.finished
                    .lock()
                    .unwrap()
                    .push(std::mem::take(&mut self.id));
                if let Some(wakeup) = &self.wakeup {
                    wakeup.notify();
                }
            }
        }
        let exit_guard = WorkerExitGuard {
            id: id.into(),
            finished: self.finished_workers.clone(),
            wakeup: self.wakeup.clone(),
        };
        let presentation = Arc::new(Mutex::new(crate::activity::Snapshot::default()));
        let worker_presentation = presentation.clone();
        let worker = thread::Builder::new()
            .name(format!("session-{id}"))
            .spawn(move || {
                let _exit_guard = exit_guard;
                if let Err(error) = server::serve_managed(
                    &p,
                    argv,
                    Some(ManagedSession {
                        path: record_path.clone(),
                        record,
                        containment_root,
                        initial_cwd: working_directory,
                        local_launch: None,
                        remote_launch,
                        presentation: Some(worker_presentation),
                        resurrect: false,
                        shutdown_wake: None,
                    }),
                ) {
                    if let Ok(mut r) = Record::load(&record_path) {
                        r.pid = None;
                        r.ended = Some(EndReason::Lost);
                        let _ = r.save(&record_path);
                    }
                    eprintln!("session worker failed: {error}");
                }
            })?;
        self.presentations.insert(id.into(), presentation);
        self.workers.insert(id.into(), worker);
        let start = Instant::now();
        loop {
            match UnixStream::connect(&socket) {
                Ok(s) => return Ok(s),
                Err(_) if start.elapsed() < Duration::from_secs(2) => {
                    thread::sleep(Duration::from_millis(5))
                }
                Err(e) => return Err(e),
            }
        }
    }

    fn resolve_existing_cwd(candidates: &[Option<&str>], home: Option<&str>) -> String {
        for candidate in candidates.iter().copied().flatten().chain(home) {
            if candidate.starts_with('/')
                && candidate.len() <= 4096
                && !candidate.contains('\0')
                && fs::metadata(candidate).is_ok_and(|meta| meta.is_dir())
            {
                return candidate.to_owned();
            }
        }
        "/".to_owned()
    }

    fn resolve_resurrect_cwd(
        record: &Record,
        launch_cwd: Option<&str>,
        home: Option<&str>,
    ) -> String {
        Self::resolve_existing_cwd(
            &[
                record.cwd.as_deref(),
                record.resume.as_ref().map(|r| r.cwd.as_str()),
                launch_cwd,
            ],
            home,
        )
    }

    fn resolve_effective_home(spec: &LocalLaunchSpec) -> Option<String> {
        spec.env
            .get("HOME")
            .cloned()
            .filter(|h| !h.is_empty() && Path::new(h).is_dir())
            .or_else(|| {
                std::env::var("HOME")
                    .ok()
                    .filter(|h| !h.is_empty() && Path::new(h).is_dir())
            })
    }

    fn build_default_login_launch() -> LocalLaunchSpec {
        let shell = crate::user_login_shell();
        let env: BTreeMap<String, String> = std::env::vars()
            .filter(|(k, v)| {
                k.len() <= 256
                    && !k.contains('=')
                    && !k.contains('\0')
                    && !v.contains('\0')
                    && !k.starts_with("OMG_RUNTIME_")
                    && k != "OMG_APP_SUPPORT"
            })
            .collect();
        LocalLaunchSpec {
            argv: vec![shell, "-l".into()],
            env,
            cwd: None,
            cols: 80,
            rows: 24,
            pixel_width: 640,
            pixel_height: 384,
            scrollback_max_bytes: Some(crate::DEFAULT_SCROLLBACK_MAX_BYTES),
            scrollback_max_lines: None,
            input_base64: None,
        }
    }

    fn build_recreate_launch(
        initial_cwd: Option<&str>,
        record_cwd: Option<&str>,
        resume_cwd: Option<&str>,
        resurrect_launch: Option<LocalLaunchSpec>,
    ) -> io::Result<LocalLaunchSpec> {
        let mut spec = match resurrect_launch {
            Some(mut provided) => {
                provided.input_base64 = None;
                provided
            }
            None => Self::build_default_login_launch(),
        };
        let effective_home = Self::resolve_effective_home(&spec);
        let provided_cwd = spec.cwd.clone();
        spec.cwd = Some(Self::resolve_existing_cwd(
            &[initial_cwd, record_cwd, provided_cwd.as_deref(), resume_cwd],
            effective_home.as_deref(),
        ));
        spec.validate()?;
        Ok(spec)
    }

    fn remove_session_artifacts_in(sessions_dir: &Path, id: &str) {
        let record_path = sessions_dir.join(format!("{id}.json"));
        let _ = fs::remove_file(&record_path);
        let _ = fs::remove_file(sessions_dir.join(format!("{id}.created")));
        let _ = fs::remove_file(sessions_dir.join(format!("{id}.closed")));
        crate::server::remove_snapshot_files(&record_path);
        let sock = Self::session_socket_in(sessions_dir, id);
        let _ = fs::remove_file(&sock);
        let _ = fs::remove_file(sock.with_extension("evt"));
        let _ = fs::remove_file(crate::holder::control_path(&sock));
    }

    fn retire_local_session_artifacts(&self, id: &str) {
        Self::remove_session_artifacts_in(&self.root, id);
        for sibling_dir in self.sibling_session_roots() {
            if !Self::sibling_has_live_host_lock(&sibling_dir) {
                Self::remove_session_artifacts_in(&sibling_dir, id);
            }
        }
    }

    fn should_resurrect_local_record(
        &self,
        id: &str,
        record: &Record,
        target_path: &Path,
        resume_generation: Option<&str>,
        resurrect_launch: Option<&LocalLaunchSpec>,
        recreate_if_gone: bool,
    ) -> io::Result<Option<bool>> {
        let Some(ended) = record.ended else {
            return Err(io::Error::other(
                "local session holder is active; retry the attach",
            ));
        };
        if recreate_if_gone {
            if let Some(expected_gen) = resume_generation {
                if expected_gen != record.generation {
                    return Err(io::Error::other("local session generation mismatch"));
                }
            }
            if ended.local_resurrectable()
                && !self.is_closed_in_any_root(id)
                && resurrect_launch.is_some()
                && crate::server::load_snapshot(target_path, record.snapshot_revision.as_deref())
                    .is_some()
            {
                return Ok(Some(true));
            }
            return Ok(None);
        }
        if ended.local_resurrectable() {
            if let Some(expected_gen) = resume_generation {
                if expected_gen != record.generation {
                    return Err(io::Error::other("local session generation mismatch"));
                }
            }
            Ok(Some(true))
        } else if ended == EndReason::AgentCompleted && resume_generation.is_some() {
            if resume_generation != Some(record.generation.as_str()) {
                return Err(io::Error::other("local session generation mismatch"));
            }
            Ok(Some(false))
        } else {
            Err(io::Error::other(format!(
                "local session ended: {:?}; it will not be recreated",
                record.ended
            )))
        }
    }

    fn resolve_shell_for_agent_resume(argv0: Option<&str>) -> String {
        if let Some(candidate) = argv0 {
            let base = Path::new(candidate)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("");
            if matches!(base, "zsh" | "bash" | "sh" | "dash" | "ksh" | "fish") {
                return candidate.to_owned();
            }
        }
        crate::user_login_shell()
    }

    fn wrap_agent_resume_argv(shell_path: &str, agent_args: Vec<String>) -> Vec<String> {
        let base = Path::new(shell_path)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        let mut argv = if base == "fish" {
            vec![
                shell_path.to_owned(),
                "-l".into(),
                "-i".into(),
                "-c".into(),
                "set -l __omg_cmd $argv[1]; set -l __omg_args $argv[2..]; $__omg_cmd $__omg_args; set -l s \"$OMG_FALLBACK_SHELL\"; set -e OMG_FALLBACK_SHELL; exec \"$s\" -l".into(),
            ]
        } else {
            vec![
                shell_path.to_owned(),
                "-l".into(),
                "-i".into(),
                "-c".into(),
                "\"$@\"; s=$OMG_FALLBACK_SHELL; unset OMG_FALLBACK_SHELL; exec \"$s\" -l".into(),
                "omg-resurrect".into(),
            ]
        };
        argv.extend(agent_args);
        argv
    }

    fn build_resurrect_launch(
        record: &Record,
        resurrect_launch: Option<LocalLaunchSpec>,
        require_agent_resume: bool,
    ) -> io::Result<LocalLaunchSpec> {
        let mut spec = match resurrect_launch {
            Some(mut provided) => {
                provided.input_base64 = None;
                provided
            }
            None => Self::build_default_login_launch(),
        };
        let effective_home = Self::resolve_effective_home(&spec);
        let resolved_cwd =
            Self::resolve_resurrect_cwd(record, spec.cwd.as_deref(), effective_home.as_deref());
        spec.cwd = Some(resolved_cwd);

        let effective_home_path = effective_home.as_deref().map(Path::new);
        let resumed_agent = if let Some(resume) = record.resume.as_ref() {
            if resume.validate().is_ok()
                && crate::agents::resolve(&resume.agent)
                    .is_some_and(|agent_spec| !agent_spec.resume_args.is_empty())
                && resume.store_exists_in_home(effective_home_path)
            {
                resume.arguments().ok()
            } else {
                None
            }
        } else {
            None
        };

        if let Some(agent_args) = resumed_agent {
            let shell_path =
                Self::resolve_shell_for_agent_resume(spec.argv.first().map(String::as_str));
            spec.env
                .insert("OMG_FALLBACK_SHELL".into(), shell_path.clone());
            spec.argv = Self::wrap_agent_resume_argv(&shell_path, agent_args);
        } else if require_agent_resume {
            return Err(io::Error::other(
                "Agent conversation store unavailable; refusing new conversation",
            ));
        }

        spec.validate()?;
        Ok(spec)
    }

    fn read_snapshot_file_bounded(record_path: &Path) -> Option<Vec<u8>> {
        use std::os::unix::fs::OpenOptionsExt;
        let snap = crate::server::snapshot_path(record_path);
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(snap)
            .ok()?;
        let meta = file.metadata().ok()?;
        if !meta.is_file() || meta.len() > crate::MAX_FRAME as u64 {
            return None;
        }
        let mut bytes = Vec::with_capacity((meta.len() as usize).min(crate::MAX_FRAME));
        file.take((crate::MAX_FRAME + 1) as u64)
            .read_to_end(&mut bytes)
            .ok()?;
        (!bytes.is_empty() && bytes.len() <= crate::MAX_FRAME).then_some(bytes)
    }

    #[allow(clippy::too_many_arguments)]
    fn cleanup_failed_local_holder_prep(
        &self,
        id: &str,
        socket: &Path,
        path: &Path,
        record: &mut Record,
        migrated_from: Option<&(PathBuf, PathBuf)>,
        created_new_record: bool,
        created_dest_marker: bool,
    ) {
        let _ = fs::remove_file(socket);
        let _ = fs::remove_file(socket.with_extension("evt"));
        let _ = fs::remove_file(crate::holder::control_path(socket));
        if migrated_from.is_some() || created_new_record {
            let _ = fs::remove_file(path);
            crate::server::remove_snapshot_files(path);
            if created_dest_marker {
                let _ = fs::remove_file(self.root.join(format!("{id}.created")));
            }
        } else {
            record.pid = None;
            record.ended = Some(EndReason::Lost);
            let _ = record.save(path);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn prepare_local_holder_spawn(
        &mut self,
        id: &str,
        socket: &Path,
        path: &Path,
        record: &mut Record,
        launch: LocalLaunchSpec,
        resurrect: bool,
        migrated_from: Option<(PathBuf, PathBuf)>,
        created_new_record: bool,
        created_dest_marker: bool,
    ) -> io::Result<LocalHolderSpawnPlan> {
        #[cfg(test)]
        let executable_override = self.holder_executable.clone();
        #[cfg(not(test))]
        let executable_override: Option<PathBuf> = None;
        let executable = match executable_override {
            Some(executable) => executable,
            None => match std::env::current_exe() {
                Ok(executable) => executable,
                Err(error) => {
                    self.cleanup_failed_local_holder_prep(
                        id,
                        socket,
                        path,
                        record,
                        migrated_from.as_ref(),
                        created_new_record,
                        created_dest_marker,
                    );
                    return Err(error);
                }
            },
        };
        self.prepare_local_holder_spawn_with_exe(
            &executable,
            id,
            socket,
            path,
            record,
            launch,
            resurrect,
            migrated_from,
            created_new_record,
            created_dest_marker,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn prepare_local_holder_spawn_with_exe(
        &mut self,
        executable: &Path,
        id: &str,
        socket: &Path,
        path: &Path,
        record: &mut Record,
        launch: LocalLaunchSpec,
        resurrect: bool,
        migrated_from: Option<(PathBuf, PathBuf)>,
        created_new_record: bool,
        created_dest_marker: bool,
    ) -> io::Result<LocalHolderSpawnPlan> {
        let request = crate::holder::HolderRequest {
            session_socket: socket.to_path_buf(),
            record_path: path.to_path_buf(),
            record: record.clone(),
            launch,
            resurrect,
        };
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let diagnostics_path = self.root.parent().unwrap().join("host.log");
        let open_res = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&diagnostics_path)
            .and_then(|file| {
                fs::set_permissions(&diagnostics_path, fs::Permissions::from_mode(0o600))?;
                Ok(file)
            });
        let diagnostics = match open_res {
            Ok(file) => file,
            Err(error) => {
                self.cleanup_failed_local_holder_prep(
                    id,
                    socket,
                    path,
                    record,
                    migrated_from.as_ref(),
                    created_new_record,
                    created_dest_marker,
                );
                return Err(error);
            }
        };
        let child = match crate::holder::spawn(executable, &request, Stdio::from(diagnostics)) {
            Ok(child) => child,
            Err(error) => {
                self.cleanup_failed_local_holder_prep(
                    id,
                    socket,
                    path,
                    record,
                    migrated_from.as_ref(),
                    created_new_record,
                    created_dest_marker,
                );
                return Err(error);
            }
        };
        Ok(LocalHolderSpawnPlan {
            id: id.to_owned(),
            socket: socket.to_path_buf(),
            path: path.to_path_buf(),
            record: record.clone(),
            child: Some(child),
            migrated_from,
            created_new_record,
            created_dest_marker,
        })
    }

    fn finish_migrated_source_cleanup(migrated_from: Option<&(PathBuf, PathBuf)>, id: &str) {
        if let Some((target_root, target_path)) = migrated_from {
            let _ = fs::remove_file(target_path);
            crate::server::remove_snapshot_files(target_path);
            let _ = fs::remove_file(target_root.join(format!("{id}.created")));
        }
    }

    fn rollback_failed_spawn(&mut self, plan: &mut LocalHolderSpawnPlan) -> io::Result<()> {
        plan.terminate_and_reap_child();
        if let Some(mut holder) = self.local_holders.remove(&plan.id) {
            if let Some(child) = holder.child.as_mut() {
                if child.try_wait().ok().flatten().is_none() {
                    let _ = child.kill();
                }
                let _ = child.wait();
            }
        }
        let _ = fs::remove_file(&plan.socket);
        let _ = fs::remove_file(plan.socket.with_extension("evt"));
        let _ = fs::remove_file(crate::holder::control_path(&plan.socket));
        if plan.migrated_from.is_some() || plan.created_new_record {
            let _ = fs::remove_file(&plan.path);
            crate::server::remove_snapshot_files(&plan.path);
            if plan.created_dest_marker {
                let _ = fs::remove_file(self.root.join(format!("{}.created", plan.id)));
            }
        } else {
            let mut updated = plan.record.clone();
            updated.pid = None;
            updated.ended = Some(EndReason::Lost);
            updated.save(&plan.path)?;
        }
        Ok(())
    }

    fn connect_local_holder_plan(
        &mut self,
        mut plan: LocalHolderSpawnPlan,
    ) -> io::Result<UnixStream> {
        let capability = match plan.record.holder_capability.clone() {
            Some(cap) => cap,
            None => {
                let _ = self.rollback_failed_spawn(&mut plan);
                return Err(io::Error::other("local holder capability is missing"));
            }
        };
        let id = plan.id.clone();
        let socket = plan.socket.clone();
        let generation = plan.record.generation.clone();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let holder_exited = match plan.child.as_mut().map(Child::try_wait).transpose() {
                Ok(status) => status.flatten().is_some(),
                Err(error) => {
                    let _ = self.rollback_failed_spawn(&mut plan);
                    return Err(error);
                }
            };
            if holder_exited {
                self.rollback_failed_spawn(&mut plan)?;
                return Err(io::Error::other(
                    "local session holder exited during startup",
                ));
            }
            match crate::holder::probe(&socket, &id, &generation, &capability) {
                Ok(status) if status.session_pid.is_some() => {
                    if let Ok(stream) = UnixStream::connect(&socket) {
                        let child = plan.child.take();
                        self.local_holders
                            .insert(id.clone(), LocalHolder { capability, child });
                        Self::finish_migrated_source_cleanup(plan.migrated_from.as_ref(), &id);
                        return Ok(stream);
                    }
                }
                _ => {}
            }
            if Instant::now() >= deadline {
                let exited_at_deadline = plan
                    .child
                    .as_mut()
                    .and_then(|c| c.try_wait().ok().flatten())
                    .is_some();
                let _ = self.rollback_failed_spawn(&mut plan);
                if exited_at_deadline {
                    return Err(io::Error::other(
                        "local session holder exited during startup",
                    ));
                }
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "local session holder started but did not become attachable",
                ));
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn connect_local(
        &mut self,
        id: &str,
        resume_generation: Option<&str>,
        socket: &Path,
        path: &Path,
        create: bool,
        policy: Option<Policy>,
        options: ConnectOptions<'_>,
    ) -> io::Result<UnixStream> {
        let allow_recreate = options.recreate_if_gone && !create && resume_generation.is_none();
        let closed = self.is_closed_in_any_root(id);
        if !allow_recreate && closed {
            return Err(io::Error::other("session explicitly closed"));
        }
        if !closed {
            let existing_target = if path.exists() {
                Some((self.root.clone(), path.to_path_buf(), socket.to_path_buf()))
            } else if let Some(sibling_root) = self.find_sibling_local_session_root(id) {
                let sibling_path = sibling_root.join(format!("{id}.json"));
                if sibling_path.exists() {
                    let sibling_socket = Self::session_socket_in(&sibling_root, id);
                    Some((sibling_root, sibling_path, sibling_socket))
                } else {
                    None
                }
            } else {
                None
            };
            if let Some((target_root, target_path, target_socket)) = existing_target {
                let maybe_record = match Record::load(&target_path) {
                    Ok(record) => Some(record),
                    Err(_) if allow_recreate => None,
                    Err(error) => return Err(error),
                };
                if let Some(mut record) = maybe_record {
                    if record.ended.is_none() {
                        match self.probe_and_adopt_in(
                            &target_root,
                            &record,
                            Duration::from_secs(1),
                            true,
                        ) {
                            Ok(()) => return UnixStream::connect(&target_socket),
                            Err(error)
                                if crate::holder::listener_is_gone(&error)
                                    && self.local_holder_startup_grace_elapsed(&record) =>
                            {
                                self.mark_local_lost_in(&target_root, &mut record, &target_path)?;
                            }
                            Err(error) if crate::holder::listener_is_gone(&error) => {
                                return Err(io::Error::other(
                                    "local session holder may still be starting; retry the attach",
                                ));
                            }
                            Err(error) => {
                                let current_ended =
                                    Record::load(&target_path).ok().is_some_and(|c| {
                                        c.generation == record.generation && c.ended.is_some()
                                    });
                                if !current_ended {
                                    return Err(io::Error::other(format!(
                                        "local session holder did not confirm ({:?}); session preserved",
                                        error.kind()
                                    )));
                                }
                            }
                        }
                    }
                }
            }
        }
        let plan = self.prepare_connect_local_plan(
            id,
            resume_generation,
            socket,
            path,
            create,
            policy,
            options,
        )?;
        self.connect_local_holder_plan(plan)
    }

    pub fn maintenance_unlocked(registry: &Mutex<Self>, force: bool) {
        let (own_root, own_probes, sibling_probes) = {
            let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
            state.reap_finished_children();
            if !force && state.last_maintenance.elapsed() < Duration::from_secs(30) {
                return;
            }
            if state.mode != RuntimeMode::Local {
                if force {
                    state.last_maintenance = Instant::now() - Duration::from_secs(30);
                }
                state.maintenance();
                return;
            }
            state.last_maintenance = Instant::now();
            let now = unix_time();
            let mut own_probes: Vec<(PathBuf, Record)> = Vec::new();
            let mut sibling_probes: Vec<(PathBuf, PathBuf, Record)> = Vec::new();
            let mut closed_paths = Vec::new();
            let mut created_paths = Vec::new();
            let mut snapshot_paths = Vec::new();
            if let Ok(entries) = fs::read_dir(&state.root) {
                for entry in entries.flatten() {
                    let entry_path = entry.path();
                    if entry_path.extension().is_some_and(|s| s == "closed") {
                        closed_paths.push(entry_path);
                        continue;
                    }
                    if entry_path.extension().is_some_and(|s| s == "created") {
                        created_paths.push(entry_path);
                        continue;
                    }
                    if entry_path.extension().is_some_and(|s| s == "snapshot") {
                        snapshot_paths.push(entry_path);
                        continue;
                    }
                    if entry_path
                        .file_name()
                        .and_then(|s| s.to_str())
                        .is_some_and(|name| name.contains(".snapshot.tmp."))
                    {
                        if file_modified_unix(&entry_path).is_some_and(|m| {
                            now.saturating_sub(m) > LOCAL_HOLDER_STARTUP_GRACE_SECONDS
                        }) {
                            let _ = fs::remove_file(&entry_path);
                        }
                        continue;
                    }
                    if entry_path.extension().is_some_and(|s| s == "json") {
                        if let Ok(record) = Record::load(&entry_path) {
                            if !valid_id(&record.id)
                                || state.workers.contains_key(&record.id)
                                || state.is_session_inflight(&record.id)
                            {
                                continue;
                            }
                            if record.ended.is_none() {
                                if own_probes.len() >= MAX_LOCAL_MAINTENANCE_PROBES {
                                    continue;
                                }
                                if let Some(cap) = record.holder_capability.as_deref() {
                                    if matches!(
                                        state.check_owned_holder_child(&record.id, cap, false),
                                        Ok(true)
                                    ) {
                                        continue;
                                    }
                                }
                                own_probes.push((entry_path, record));
                            } else if now.saturating_sub(record.updated_at)
                                > record.policy.record_retention_seconds
                            {
                                crate::server::remove_snapshot_files(&entry_path);
                                let _ = fs::remove_file(&entry_path);
                            }
                        }
                    }
                }
            }
            for snap_path in snapshot_paths {
                let Some(id) = snap_path.file_stem().and_then(|s| s.to_str()) else {
                    continue;
                };
                if !valid_id(id)
                    || state.workers.contains_key(id)
                    || state.local_holders.contains_key(id)
                    || state.is_session_inflight(id)
                {
                    continue;
                }
                if state.is_closed_in_any_root(id) {
                    let _ = fs::remove_file(&snap_path);
                    continue;
                }
                if !state.root.join(format!("{id}.json")).exists()
                    && file_modified_unix(&snap_path)
                        .is_some_and(|m| now.saturating_sub(m) > LOCAL_HOLDER_STARTUP_GRACE_SECONDS)
                {
                    let _ = fs::remove_file(&snap_path);
                }
            }
            for created_path in created_paths {
                let Some(id) = created_path.file_stem().and_then(|s| s.to_str()) else {
                    continue;
                };
                if !valid_id(id)
                    || state.workers.contains_key(id)
                    || state.local_holders.contains_key(id)
                    || state.is_session_inflight(id)
                    || state.root.join(format!("{id}.json")).exists()
                {
                    continue;
                }
                if file_modified_unix(&created_path)
                    .is_some_and(|m| now.saturating_sub(m) > ORPHAN_CREATED_MARKER_MAX_AGE_SECONDS)
                {
                    let _ = fs::remove_file(&created_path);
                }
            }
            for closed_path in closed_paths {
                let Some(id) = closed_path.file_stem().and_then(|s| s.to_str()) else {
                    continue;
                };
                if !valid_id(id)
                    || state.workers.contains_key(id)
                    || state.local_holders.contains_key(id)
                    || state.is_session_inflight(id)
                {
                    continue;
                }
                crate::server::remove_snapshot_files(&closed_path.with_extension("json"));
                if state.root.join(format!("{id}.json")).exists() {
                    continue;
                }
                if let Some(modified) = file_modified_unix(&closed_path) {
                    if now.saturating_sub(modified) > TOMBSTONE_RETENTION_SECONDS {
                        let _ = fs::remove_file(&closed_path);
                    }
                }
            }
            let current_boot = crate::record::current_boot_time();
            for sibling in state.sibling_session_roots() {
                let sibling_live_broker = Self::sibling_has_live_host_lock(&sibling);
                let Ok(entries) = fs::read_dir(&sibling) else {
                    continue;
                };
                for entry in entries.flatten() {
                    let entry_path = entry.path();
                    if entry_path.extension().is_some_and(|s| s == "json") {
                        if let Ok(mut record) = Record::load(&entry_path) {
                            if !valid_id(&record.id) {
                                continue;
                            }
                            if state.is_closed_in_any_root(&record.id) {
                                crate::server::remove_snapshot_files(&entry_path);
                            } else if !sibling_live_broker && record.ended.is_none() {
                                if crate::record::is_prior_boot(record.boot_time, current_boot) {
                                    let _ = state.mark_local_lost_in(
                                        &sibling,
                                        &mut record,
                                        &entry_path,
                                    );
                                } else if record.holder_capability.is_some()
                                    && own_probes.len() + sibling_probes.len()
                                        < MAX_LOCAL_MAINTENANCE_PROBES
                                {
                                    sibling_probes.push((
                                        sibling.clone(),
                                        entry_path.clone(),
                                        record.clone(),
                                    ));
                                    continue;
                                }
                            }
                            if record.ended.is_some()
                                && now.saturating_sub(record.updated_at)
                                    > record.policy.record_retention_seconds
                            {
                                crate::server::remove_snapshot_files(&entry_path);
                                let _ = fs::remove_file(&entry_path);
                            }
                        }
                    } else if entry_path.extension().is_some_and(|s| s == "snapshot") {
                        let Some(id) = entry_path.file_stem().and_then(|s| s.to_str()) else {
                            continue;
                        };
                        if !valid_id(id) {
                            continue;
                        }
                        if state.is_closed_in_any_root(id)
                            || (!sibling.join(format!("{id}.json")).exists()
                                && file_modified_unix(&entry_path).is_some_and(|m| {
                                    now.saturating_sub(m) > LOCAL_HOLDER_STARTUP_GRACE_SECONDS
                                }))
                        {
                            let _ = fs::remove_file(&entry_path);
                        }
                    } else if !sibling_live_broker
                        && entry_path.extension().is_some_and(|s| s == "created")
                    {
                        let Some(id) = entry_path.file_stem().and_then(|s| s.to_str()) else {
                            continue;
                        };
                        if valid_id(id)
                            && !sibling.join(format!("{id}.json")).exists()
                            && file_modified_unix(&entry_path).is_some_and(|m| {
                                now.saturating_sub(m) > ORPHAN_CREATED_MARKER_MAX_AGE_SECONDS
                            })
                        {
                            let _ = fs::remove_file(&entry_path);
                        }
                    }
                }
            }
            (state.root.clone(), own_probes, sibling_probes)
        };

        if own_probes.is_empty() && sibling_probes.is_empty() {
            return;
        }

        let mut own_results = Vec::with_capacity(own_probes.len());
        for (entry_path, record) in own_probes {
            let res = match record.holder_capability.as_deref() {
                Some(cap) => {
                    let sock = Self::session_socket_in(&own_root, &record.id);
                    Self::probe_local_holder_outside_lock(
                        &sock,
                        &entry_path,
                        &record,
                        cap,
                        LOCAL_MAINTENANCE_PROBE_TIMEOUT,
                        false,
                    )
                    .map(|_| ())
                }
                None => Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "local holder capability is missing",
                )),
            };
            own_results.push((entry_path, record, res));
        }

        let mut sibling_results = Vec::with_capacity(sibling_probes.len());
        for (sibling, entry_path, record) in sibling_probes {
            let sock = Self::session_socket_in(&sibling, &record.id);
            let res = record
                .holder_capability
                .as_deref()
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "local holder capability is missing",
                    )
                })
                .and_then(|cap| {
                    crate::holder::probe_with_timeout(
                        &sock,
                        &record.id,
                        &record.generation,
                        cap,
                        LOCAL_MAINTENANCE_PROBE_TIMEOUT,
                    )
                });
            sibling_results.push((sibling, entry_path, record, res));
        }

        let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
        let now = unix_time();
        for (entry_path, mut record, res) in own_results {
            match res {
                Ok(()) => {
                    if let Some(cap) = record.holder_capability.as_deref() {
                        state.adopt_probed_holder(&record.id, cap);
                    }
                }
                Err(error)
                    if crate::holder::listener_is_gone(&error)
                        && state.local_holder_startup_grace_elapsed(&record) =>
                {
                    if state.mark_local_lost(&mut record, &entry_path).is_ok()
                        && record.ended.is_some()
                        && now.saturating_sub(record.updated_at)
                            > record.policy.record_retention_seconds
                    {
                        crate::server::remove_snapshot_files(&entry_path);
                        let _ = fs::remove_file(&entry_path);
                    }
                }
                Err(_) => {}
            }
        }
        for (sibling, entry_path, mut record, res) in sibling_results {
            if let Err(error) = res {
                if crate::holder::listener_is_gone(&error)
                    && !Self::sibling_has_live_host_lock(&sibling)
                    && state.local_holder_startup_grace_elapsed(&record)
                    && state
                        .mark_local_lost_in(&sibling, &mut record, &entry_path)
                        .is_ok()
                    && record.ended.is_some()
                    && now.saturating_sub(record.updated_at)
                        > record.policy.record_retention_seconds
                {
                    crate::server::remove_snapshot_files(&entry_path);
                    let _ = fs::remove_file(&entry_path);
                }
            }
        }
    }

    pub fn catalogue_summaries_unlocked(
        registry: &Mutex<Self>,
    ) -> io::Result<Vec<crate::record::SessionSummary>> {
        let is_local = registry
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .is_local();
        if !is_local {
            return registry
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .catalogue_summaries();
        }
        Self::maintenance_unlocked(registry, true);
        let (root, records) = {
            let state = registry.lock().unwrap_or_else(|p| p.into_inner());
            (state.root.clone(), state.list()?)
        };
        let mut local_queries = 0usize;
        let mut summaries = Vec::with_capacity(records.len());
        for record in &records {
            let mut summary = crate::record::SessionSummary::from(record);
            if record.ended.is_none()
                && local_queries < MAX_RUNNING
                && record.holder_capability.is_some()
            {
                local_queries += 1;
                let socket = Self::session_socket_in(&root, &record.id);
                summary.activity = crate::holder::presentation_with_timeout(
                    &socket,
                    record,
                    Duration::from_millis(50),
                )
                .ok();
            }
            summaries.push(summary);
        }
        Ok(summaries)
    }

    pub fn close_unlocked(registry: &Mutex<Self>, id: &str) -> io::Result<bool> {
        if !valid_id(id) {
            return Err(io::Error::other("invalid session identity"));
        }
        let (is_local, inflight) = {
            let state = registry.lock().unwrap_or_else(|p| p.into_inner());
            (state.is_local(), state.inflight_sessions.clone())
        };
        let _session_guard = SessionInflightGuard::acquire(&inflight, id);
        if !is_local {
            return registry.lock().unwrap_or_else(|p| p.into_inner()).close(id);
        }
        Self::maintenance_unlocked(registry, false);
        let (target_root, path, record) = {
            let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
            state.reap_finished_children();
            let marker = state.root.join(format!("{id}.closed"));
            let file = fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .open(marker)?;
            file.sync_all()?;
            fs::File::open(&state.root)?.sync_all()?;
            let own_path = state.root.join(format!("{id}.json"));
            let (target_root, path) = if own_path.exists() {
                (state.root.clone(), own_path)
            } else if let Some(sibling_root) = state.find_sibling_local_session_root(id) {
                let sibling_marker = sibling_root.join(format!("{id}.closed"));
                let sibling_file = fs::OpenOptions::new()
                    .write(true)
                    .create(true)
                    .truncate(false)
                    .open(sibling_marker)?;
                sibling_file.sync_all()?;
                fs::File::open(&sibling_root)?.sync_all()?;
                let sibling_path = sibling_root.join(format!("{id}.json"));
                (sibling_root, sibling_path)
            } else {
                (state.root.clone(), own_path)
            };
            if let Ok(mut record) = Record::load(&path) {
                if record.ended.is_none() || record.pid.is_some() {
                    if let Some(cap) = record.holder_capability.as_deref() {
                        let _ = state.check_owned_holder_child(&record.id, cap, true);
                    }
                    (target_root, path, record)
                } else {
                    record.pid = None;
                    record.ended = Some(EndReason::ExplicitClose);
                    crate::server::remove_snapshot_files(&path);
                    record.save(&path)?;
                    return Ok(true);
                }
            } else {
                crate::server::remove_snapshot_files(&path);
                return Ok(true);
            }
        };

        let probe_res = match record.holder_capability.as_deref() {
            Some(cap) => {
                let sock = Self::session_socket_in(&target_root, &record.id);
                Self::probe_local_holder_outside_lock(
                    &sock,
                    &path,
                    &record,
                    cap,
                    Duration::from_secs(1),
                    true,
                )
                .map(|_| ())
            }
            None => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "local holder capability is missing",
            )),
        };

        let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
        let mut record = record;
        match probe_res {
            Ok(()) => {
                if let Some(cap) = record.holder_capability.as_deref() {
                    state.adopt_probed_holder(&record.id, cap);
                }
                Ok(false)
            }
            Err(error)
                if crate::holder::listener_is_gone(&error)
                    && state.local_holder_startup_grace_elapsed(&record) =>
            {
                if state.mark_local_lost_in(&target_root, &mut record, &path)? {
                    return Err(io::Error::other(
                        "local holder is unavailable; cleanup is unconfirmed",
                    ));
                }
                if record.pid.is_some() {
                    return Err(io::Error::other(
                        "local session is still ending; cleanup is unconfirmed",
                    ));
                }
                if record.ended.is_none() {
                    return Err(io::Error::other(
                        "local session identity changed; cleanup is unconfirmed",
                    ));
                }
                record.ended = Some(EndReason::ExplicitClose);
                crate::server::remove_snapshot_files(&path);
                record.save(&path)?;
                Ok(true)
            }
            Err(error) if crate::holder::listener_is_gone(&error) => Err(io::Error::other(
                "local holder may still be starting; cleanup is unconfirmed",
            )),
            Err(error) => {
                let current = Record::load(&path)?;
                if current.generation == record.generation && current.ended.is_some() {
                    if current.pid.is_some() {
                        return Err(io::Error::other(
                            "local session is still ending; cleanup is unconfirmed",
                        ));
                    }
                    record = current;
                    record.ended = Some(EndReason::ExplicitClose);
                    crate::server::remove_snapshot_files(&path);
                    record.save(&path)?;
                    return Ok(true);
                }
                Err(io::Error::other(format!(
                    "local holder did not confirm cleanup ({:?}); session preserved",
                    error.kind()
                )))
            }
        }
    }

    pub fn connect_unlocked(
        registry: &Mutex<Self>,
        id: &str,
        resume_generation: Option<&str>,
        reload_policy: bool,
    ) -> io::Result<UnixStream> {
        if !valid_id(id) {
            return Err(io::Error::other("invalid session identity"));
        }
        let (is_local, inflight) = {
            let state = registry.lock().unwrap_or_else(|p| p.into_inner());
            (state.is_local(), state.inflight_sessions.clone())
        };
        let _session_guard = SessionInflightGuard::acquire(&inflight, id);
        if !is_local {
            let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
            if reload_policy {
                state.reload_policy_from_disk();
            }
            return state.connect(id, resume_generation);
        }
        Self::connect_local_unlocked_inner(
            registry,
            id,
            resume_generation,
            reload_policy,
            None,
            false,
            ConnectOptions::default(),
        )
    }

    pub fn open_unlocked(registry: &Mutex<Self>, request: &OpenRequest) -> io::Result<UnixStream> {
        if !valid_id(&request.id) {
            return Err(io::Error::other("invalid session identity"));
        }
        request.policy.validate()?;
        let request_size = serde_json::to_vec(request)?.len();
        if request_size > MAX_OPEN_REQUEST_BYTES {
            return Err(io::Error::other("session open request exceeds limit"));
        }
        let (mode, inflight) = {
            let state = registry.lock().unwrap_or_else(|p| p.into_inner());
            (state.mode, state.inflight_sessions.clone())
        };
        let mut local_launch = request.launch.clone();
        match (mode, request.create, local_launch.as_mut()) {
            (RuntimeMode::Remote, _, Some(_)) => {
                return Err(io::Error::other(
                    "local launch specifications are forbidden on SSH sessions",
                ));
            }
            (RuntimeMode::Local, true, Some(launch)) => {
                launch.validate()?;
            }
            (RuntimeMode::Local, true, None) => {
                return Err(io::Error::other(
                    "local session launch specification required",
                ));
            }
            (RuntimeMode::Local, false, Some(_)) => {
                return Err(io::Error::other(
                    "reattaching a local session cannot send a launch specification",
                ));
            }
            _ => {}
        }
        if let Some(resurrect) = &request.resurrect_launch {
            if mode != RuntimeMode::Local {
                return Err(io::Error::other(
                    "local resurrection specifications are forbidden on SSH sessions",
                ));
            }
            if request.create {
                return Err(io::Error::other(
                    "creating a local session cannot send a resurrection launch specification",
                ));
            }
            resurrect.validate_with(false)?;
            if resurrect
                .input_base64
                .as_ref()
                .is_some_and(|value| !value.is_empty())
            {
                return Err(io::Error::other(
                    "local resurrection specification cannot carry initial input",
                ));
            }
        }
        let _session_guard = SessionInflightGuard::acquire(&inflight, &request.id);
        if mode != RuntimeMode::Local {
            return registry
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .open(request);
        }
        let create = request.create && local_launch.is_some();
        Self::connect_local_unlocked_inner(
            registry,
            &request.id,
            None,
            false,
            Some(request.policy.clone()),
            create,
            ConnectOptions {
                cwd: request.cwd.as_deref(),
                launch: local_launch,
                resurrect_launch: request.resurrect_launch.clone(),
                remote_launch: None,
                inline_viewer: request.inline_viewer,
                recreate_if_gone: request.recreate_if_gone,
                initial_resume: None,
            },
        )
    }

    fn reload_policy_from_disk(&mut self) {
        if let Some(root) = self.root.parent() {
            if let Ok(bytes) = fs::read(root.join("policy.json")) {
                if let Ok(policy) = serde_json::from_slice::<Policy>(&bytes) {
                    if policy.validate().is_ok() {
                        self.policy = policy;
                    }
                }
            }
        }
    }

    fn connect_local_unlocked_inner(
        registry: &Mutex<Self>,
        id: &str,
        resume_generation: Option<&str>,
        reload_policy: bool,
        policy: Option<Policy>,
        create: bool,
        options: ConnectOptions<'_>,
    ) -> io::Result<UnixStream> {
        Self::maintenance_unlocked(registry, false);
        let allow_recreate = options.recreate_if_gone && !create && resume_generation.is_none();
        let probe_candidate = {
            let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
            state.reap_finished_children();
            if reload_policy {
                state.reload_policy_from_disk();
            }
            let closed = state.is_closed_in_any_root(id);
            if !allow_recreate && closed {
                return Err(io::Error::other("session explicitly closed"));
            }
            if closed {
                None
            } else {
                let socket = Self::session_socket_in(&state.root, id);
                let path = state.root.join(format!("{id}.json"));
                let target = if path.exists() {
                    Some((state.root.clone(), path, socket))
                } else if let Some(sibling_root) = state.find_sibling_local_session_root(id) {
                    if !allow_recreate && sibling_root.join(format!("{id}.closed")).exists() {
                        return Err(io::Error::other("session explicitly closed"));
                    }
                    let sibling_path = sibling_root.join(format!("{id}.json"));
                    if sibling_path.exists() {
                        let sibling_socket = Self::session_socket_in(&sibling_root, id);
                        Some((sibling_root, sibling_path, sibling_socket))
                    } else {
                        None
                    }
                } else {
                    None
                };
                if let Some((target_root, target_path, target_socket)) = target {
                    match Record::load(&target_path) {
                        Ok(record) if record.ended.is_none() => {
                            if let Some(cap) = record.holder_capability.as_deref() {
                                let _ = state.check_owned_holder_child(&record.id, cap, true);
                            }
                            Some((target_root, target_path, target_socket, record))
                        }
                        Ok(_) => None,
                        Err(_) if allow_recreate => None,
                        Err(error) => return Err(error),
                    }
                } else {
                    None
                }
            }
        };

        if let Some((target_root, target_path, target_socket, mut record)) = probe_candidate {
            let probe_res = match record.holder_capability.as_deref() {
                Some(cap) => Self::probe_local_holder_outside_lock(
                    &target_socket,
                    &target_path,
                    &record,
                    cap,
                    Duration::from_secs(1),
                    true,
                )
                .map(|_| ()),
                None => Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "local holder capability is missing",
                )),
            };
            match probe_res {
                Ok(()) => {
                    {
                        let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
                        if !allow_recreate && state.is_closed_in_any_root(id) {
                            return Err(io::Error::other("session explicitly closed"));
                        }
                        if let Some(cap) = record.holder_capability.as_deref() {
                            state.adopt_probed_holder(&record.id, cap);
                        }
                    }
                    return UnixStream::connect(&target_socket);
                }
                Err(error) => {
                    let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
                    if crate::holder::listener_is_gone(&error)
                        && state.local_holder_startup_grace_elapsed(&record)
                    {
                        state.mark_local_lost_in(&target_root, &mut record, &target_path)?;
                    } else if crate::holder::listener_is_gone(&error) {
                        return Err(io::Error::other(
                            "local session holder may still be starting; retry the attach",
                        ));
                    } else {
                        let current_ended = match Record::load(&target_path) {
                            Ok(current) => {
                                current.generation == record.generation && current.ended.is_some()
                            }
                            Err(_) if allow_recreate => true,
                            Err(load_err) => return Err(load_err),
                        };
                        if !current_ended {
                            return Err(io::Error::other(format!(
                                "local session holder did not confirm ({:?}); session preserved",
                                error.kind()
                            )));
                        }
                    }
                }
            }
        }

        let plan = {
            let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
            state.reap_finished_children();
            if !allow_recreate && state.is_closed_in_any_root(id) {
                return Err(io::Error::other("session explicitly closed"));
            }
            let socket = Self::session_socket_in(&state.root, id);
            let path = state.root.join(format!("{id}.json"));
            state.prepare_connect_local_plan(
                id,
                resume_generation,
                &socket,
                &path,
                create,
                policy,
                options,
            )?
        };

        Self::await_spawned_local_holder(registry, plan)
    }

    #[allow(clippy::too_many_arguments)]
    fn prepare_fresh_local_record(
        &self,
        id: &str,
        socket: &Path,
        path: &Path,
        launch: &LocalLaunchSpec,
        policy: Option<Policy>,
        inline_viewer: bool,
    ) -> io::Result<Record> {
        launch.validate()?;
        let records = self.list()?;
        if records.len() >= MAX_RECORDS {
            return Err(io::Error::other("session metadata quota exceeded"));
        }
        if records
            .iter()
            .filter(|record| record.ended.is_none())
            .count()
            >= MAX_RUNNING
        {
            return Err(io::Error::other("active session quota exceeded"));
        }
        use std::os::unix::fs::OpenOptionsExt;
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(self.root.join(format!("{id}.created")))?;
        let mut record = Record::new(id, policy.unwrap_or_else(|| self.policy.clone()))?;
        record.inline_viewer = inline_viewer;
        record.holder_capability = Some(nonce()?);
        record.cwd = launch.cwd.clone();
        record.save(path)?;
        let _ = fs::remove_file(socket);
        let _ = fs::remove_file(socket.with_extension("evt"));
        let _ = fs::remove_file(crate::holder::control_path(socket));
        Ok(record)
    }

    #[allow(clippy::too_many_arguments)]
    fn prepare_local_recreate_plan(
        &mut self,
        id: &str,
        socket: &Path,
        path: &Path,
        policy: Option<Policy>,
        options: ConnectOptions<'_>,
        record_cwd: Option<&str>,
        resume_cwd: Option<&str>,
    ) -> io::Result<LocalHolderSpawnPlan> {
        self.retire_local_session_artifacts(id);
        let launch = Self::build_recreate_launch(
            options.cwd,
            record_cwd,
            resume_cwd,
            options.resurrect_launch,
        )?;
        let mut record = self.prepare_fresh_local_record(
            id,
            socket,
            path,
            &launch,
            policy,
            options.inline_viewer,
        )?;
        self.prepare_local_holder_spawn(
            id,
            socket,
            path,
            &mut record,
            launch,
            false,
            None,
            true,
            true,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn prepare_connect_local_plan(
        &mut self,
        id: &str,
        resume_generation: Option<&str>,
        socket: &Path,
        path: &Path,
        create: bool,
        policy: Option<Policy>,
        options: ConnectOptions<'_>,
    ) -> io::Result<LocalHolderSpawnPlan> {
        let allow_recreate = options.recreate_if_gone && !create && resume_generation.is_none();
        if !allow_recreate && self.is_closed_in_any_root(id) {
            return Err(io::Error::other("session explicitly closed"));
        }
        let existing_target = if path.exists() {
            Some((self.root.clone(), path.to_path_buf()))
        } else if let Some(sibling_root) = self.find_sibling_local_session_root(id) {
            if !allow_recreate && sibling_root.join(format!("{id}.closed")).exists() {
                return Err(io::Error::other("session explicitly closed"));
            }
            let sibling_path = sibling_root.join(format!("{id}.json"));
            if sibling_path.exists() {
                Some((sibling_root, sibling_path))
            } else {
                if !create && !allow_recreate {
                    return Err(io::Error::other("unknown local session; cannot attach"));
                }
                if create && sibling_root.join(format!("{id}.created")).exists() {
                    return Err(io::Error::other(
                        "local session identity was already used; refusing to create a new shell",
                    ));
                }
                None
            }
        } else {
            None
        };
        if let Some((target_root, target_path)) = existing_target {
            if target_root != self.root && Self::sibling_has_live_host_lock(&target_root) {
                return Err(io::Error::other(
                    "sibling local runtime is active; retry the attach",
                ));
            }
            if !allow_recreate && self.is_closed_in_any_root(id) {
                return Err(io::Error::other("session explicitly closed"));
            }
            let loaded_record = match Record::load(&target_path) {
                Ok(record) => Some(record),
                Err(_) if allow_recreate => None,
                Err(error) => return Err(error),
            };
            if allow_recreate && self.is_closed_in_any_root(id) {
                let (record_cwd, resume_cwd) = loaded_record
                    .as_ref()
                    .map(|r| (r.cwd.clone(), r.resume.as_ref().map(|x| x.cwd.clone())))
                    .unwrap_or((None, None));
                return self.prepare_local_recreate_plan(
                    id,
                    socket,
                    path,
                    policy,
                    options,
                    record_cwd.as_deref(),
                    resume_cwd.as_deref(),
                );
            }
            let Some(mut record) = loaded_record else {
                return self
                    .prepare_local_recreate_plan(id, socket, path, policy, options, None, None);
            };
            let resurrect_snapshot = match self.should_resurrect_local_record(
                id,
                &record,
                &target_path,
                resume_generation,
                options.resurrect_launch.as_ref(),
                allow_recreate,
            )? {
                Some(resurrect) => resurrect,
                None => {
                    let record_cwd = record.cwd.clone();
                    let resume_cwd = record.resume.as_ref().map(|r| r.cwd.clone());
                    return self.prepare_local_recreate_plan(
                        id,
                        socket,
                        path,
                        policy,
                        options,
                        record_cwd.as_deref(),
                        resume_cwd.as_deref(),
                    );
                }
            };
            let records = self.list()?;
            if records
                .iter()
                .filter(|r| r.id != id && r.ended.is_none())
                .count()
                >= MAX_RUNNING
            {
                return Err(io::Error::other("active session quota exceeded"));
            }
            let resurrect_launch = options.resurrect_launch;
            let launch =
                Self::build_resurrect_launch(&record, resurrect_launch, !resurrect_snapshot)?;
            let original_snapshot_revision = record.snapshot_revision.clone();
            let migrated = target_root != self.root;
            let mut created_dest_marker = false;
            if migrated {
                use std::os::unix::fs::OpenOptionsExt;
                let created_marker = self.root.join(format!("{id}.created"));
                if !created_marker.exists() {
                    fs::OpenOptions::new()
                        .write(true)
                        .create(true)
                        .truncate(false)
                        .mode(0o600)
                        .open(&created_marker)?;
                    created_dest_marker = true;
                }
                if resurrect_snapshot {
                    if target_path.with_extension("snapshot").exists() {
                        let snap_res = Self::read_snapshot_file_bounded(&target_path)
                            .ok_or_else(|| {
                                io::Error::other("failed to read source session snapshot")
                            })
                            .and_then(|snap_bytes| {
                                crate::server::save_snapshot_atomic(path, &snap_bytes)
                            });
                        if let Err(err) = snap_res {
                            if created_dest_marker {
                                let _ = fs::remove_file(&created_marker);
                            }
                            return Err(err);
                        }
                    } else {
                        crate::server::remove_snapshot_files(path);
                    }
                } else {
                    crate::server::remove_snapshot_files(path);
                }
            } else if !resurrect_snapshot {
                crate::server::remove_snapshot_files(path);
            }
            record.generation = nonce()?;
            record.pid = None;
            record.ended = None;
            record.cwd = launch.cwd.clone();
            if let Some(policy) = policy {
                record.policy = policy;
            }
            record.holder_capability = Some(nonce()?);
            record.inline_viewer = options.inline_viewer;
            record.boot_time = crate::record::current_boot_time();
            record.snapshot_revision = if resurrect_snapshot {
                original_snapshot_revision
            } else {
                crate::current_snapshot_revision()
            };
            if let Err(err) = record.save(path) {
                if migrated {
                    let _ = fs::remove_file(path);
                    crate::server::remove_snapshot_files(path);
                    if created_dest_marker {
                        let _ = fs::remove_file(self.root.join(format!("{id}.created")));
                    }
                }
                return Err(err);
            }
            let _ = fs::remove_file(socket);
            let _ = fs::remove_file(socket.with_extension("evt"));
            let _ = fs::remove_file(crate::holder::control_path(socket));
            let migrated_from = migrated.then_some((target_root, target_path));
            return self.prepare_local_holder_spawn(
                id,
                socket,
                path,
                &mut record,
                launch,
                resurrect_snapshot,
                migrated_from,
                false,
                created_dest_marker,
            );
        }
        if allow_recreate {
            return self.prepare_local_recreate_plan(id, socket, path, policy, options, None, None);
        }
        if !create {
            return Err(io::Error::other("unknown local session; cannot attach"));
        }
        if self.root.join(format!("{id}.created")).exists() {
            return Err(io::Error::other(
                "local session identity was already used; refusing to create a new shell",
            ));
        }
        if socket.exists() || crate::holder::control_path(socket).exists() {
            return Err(io::Error::other(
                "unregistered local session endpoint exists; refusing to replace it",
            ));
        }
        let launch = options
            .launch
            .ok_or_else(|| io::Error::other("local session launch specification required"))?;
        let mut record = self.prepare_fresh_local_record(
            id,
            socket,
            path,
            &launch,
            policy,
            options.inline_viewer,
        )?;

        self.prepare_local_holder_spawn(
            id,
            socket,
            path,
            &mut record,
            launch,
            false,
            None,
            true,
            true,
        )
    }

    fn await_spawned_local_holder(
        registry: &Mutex<Self>,
        plan: LocalHolderSpawnPlan,
    ) -> io::Result<UnixStream> {
        Self::await_spawned_local_holder_with_timeout(registry, plan, Duration::from_secs(5))
    }

    fn await_spawned_local_holder_with_timeout(
        registry: &Mutex<Self>,
        mut plan: LocalHolderSpawnPlan,
        timeout: Duration,
    ) -> io::Result<UnixStream> {
        let capability = match plan.record.holder_capability.clone() {
            Some(cap) => cap,
            None => {
                plan.terminate_and_reap_child();
                let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
                let _ = state.rollback_failed_spawn(&mut plan);
                return Err(io::Error::other("local holder capability is missing"));
            }
        };
        let deadline = Instant::now() + timeout;
        loop {
            let holder_exited = match plan.child.as_mut().map(Child::try_wait).transpose() {
                Ok(status) => status.flatten().is_some(),
                Err(error) => {
                    plan.terminate_and_reap_child();
                    let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
                    let _ = state.rollback_failed_spawn(&mut plan);
                    return Err(error);
                }
            };
            if holder_exited {
                plan.terminate_and_reap_child();
                let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
                state.rollback_failed_spawn(&mut plan)?;
                return Err(io::Error::other(
                    "local session holder exited during startup",
                ));
            }
            match crate::holder::probe(&plan.socket, &plan.id, &plan.record.generation, &capability)
            {
                Ok(status) if status.session_pid.is_some() => {
                    if let Ok(stream) = UnixStream::connect(&plan.socket) {
                        let child = plan.child.take();
                        {
                            let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
                            state
                                .local_holders
                                .insert(plan.id.clone(), LocalHolder { capability, child });
                        }
                        Self::finish_migrated_source_cleanup(plan.migrated_from.as_ref(), &plan.id);
                        return Ok(stream);
                    }
                }
                _ => {}
            }
            if Instant::now() >= deadline {
                let exited_at_deadline = plan
                    .child
                    .as_mut()
                    .and_then(|c| c.try_wait().ok().flatten())
                    .is_some();
                plan.terminate_and_reap_child();
                let mut state = registry.lock().unwrap_or_else(|p| p.into_inner());
                let _ = state.rollback_failed_spawn(&mut plan);
                if exited_at_deadline {
                    return Err(io::Error::other(
                        "local session holder exited during startup",
                    ));
                }
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "local session holder started but did not become attachable",
                ));
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
}

pub fn find_local_record(sessions_dir: &Path, id: &str) -> Option<(PathBuf, Record)> {
    let direct = sessions_dir.join(format!("{id}.json"));
    if let Ok(record) = Record::load(&direct) {
        return Some((direct, record));
    }
    let mut best: Option<((u64, u64), PathBuf, Record)> = None;
    for sibling in Registry::sibling_session_roots_for(sessions_dir) {
        if Registry::sibling_has_live_host_lock(&sibling) {
            continue;
        }
        let path = sibling.join(format!("{id}.json"));
        if let Ok(record) = Record::load(&path) {
            let key = (record.updated_at, record.created_at);
            if best.as_ref().is_none_or(|(prev, _, _)| key > *prev) {
                best = Some((key, path, record));
            }
        }
    }
    best.map(|(_, path, record)| (path, record))
}

/// Checks whether a local session has an explicit `.closed` tombstone in
/// `sessions_dir` or any sibling state directory under the same `run` root.
pub fn is_local_session_closed(sessions_dir: &Path, id: &str) -> bool {
    if sessions_dir.join(format!("{id}.closed")).exists() {
        return true;
    }
    Registry::sibling_session_roots_for(sessions_dir)
        .into_iter()
        .any(|sibling_dir| sibling_dir.join(format!("{id}.closed")).exists())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ordinary_open_does_not_send_new_fields_to_a_pinned_legacy_host() {
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct LegacyOpen {
            id: String,
            policy: Policy,
            create: bool,
            cwd: Option<String>,
            launch: Option<LocalLaunchSpec>,
        }
        let request: OpenRequest = serde_json::from_value(serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000001",
            "policy": {}, "create": false
        }))
        .unwrap();
        let encoded = serde_json::to_vec(&request).unwrap();
        let old: LegacyOpen = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(old.id, request.id);
        assert!(!old.create && old.cwd.is_none() && old.launch.is_none());
        assert_eq!(
            old.policy.detached_ttl_seconds,
            request.policy.detached_ttl_seconds
        );
        let mut inline: OpenRequest = serde_json::from_slice(&encoded).unwrap();
        inline.inline_viewer = true;
        assert_eq!(serde_json::to_value(inline).unwrap()["inline_viewer"], true);
        let mut recreate = request;
        recreate.recreate_if_gone = true;
        let recreate_json = serde_json::to_value(recreate).unwrap();
        assert_eq!(recreate_json["recreate_if_gone"], true);
        assert!(
            serde_json::to_value(serde_json::from_slice::<OpenRequest>(&encoded).unwrap())
                .unwrap()
                .get("recreate_if_gone")
                .is_none()
        );
    }

    fn launch(argv: Vec<String>, env: BTreeMap<String, String>) -> LocalLaunchSpec {
        LocalLaunchSpec {
            argv,
            env,
            cwd: None,
            cols: 80,
            rows: 24,
            pixel_width: 640,
            pixel_height: 384,
            scrollback_max_bytes: None,
            scrollback_max_lines: None,
            input_base64: None,
        }
    }

    #[test]
    fn local_launch_preserves_empty_nonzero_arguments_and_native_environment_names() {
        let mut env = BTreeMap::new();
        env.insert("BASH_FUNC_example%%".into(), "() { echo ok; }".into());
        let spec = launch(vec!["/bin/sh".into(), "".into(), "tail".into()], env);
        assert!(spec.validate().is_ok());
    }

    #[test]
    fn local_launch_without_scrollback_fields_uses_legacy_defaults() {
        let bytes = br#"{"argv":["/bin/sh"],"env":{},"cwd":null,"cols":80,"rows":24,"pixel_width":640,"pixel_height":384}"#;
        let spec: LocalLaunchSpec = serde_json::from_slice(bytes).unwrap();
        assert_eq!(spec.scrollback_max_bytes, None);
        assert_eq!(spec.scrollback_max_lines, None);
        assert!(spec.validate().is_ok());
    }

    #[test]
    fn local_launch_rejects_empty_argv_zero_and_unrepresentable_environment_keys() {
        let empty_argv0 = launch(vec!["".into(), "argument".into()], BTreeMap::new());
        assert!(empty_argv0.validate().is_err());

        let mut env = BTreeMap::new();
        env.insert("BAD=KEY".into(), "value".into());
        assert!(launch(vec!["/bin/sh".into()], env).validate().is_err());
    }

    #[test]
    fn local_launch_preserves_zero_scrollback_and_caps_bytes() {
        let mut spec = launch(vec!["/bin/sh".into()], BTreeMap::new());
        spec.scrollback_max_bytes = Some(0);
        spec.scrollback_max_lines = Some(0);
        assert!(spec.validate().is_ok());

        spec.scrollback_max_bytes = Some(MAX_LOCAL_SCROLLBACK_BYTES);
        assert!(spec.validate().is_ok());
        spec.scrollback_max_bytes = Some(MAX_LOCAL_SCROLLBACK_BYTES + 1);
        assert!(spec.validate().is_err());
    }

    fn local_test_root() -> PathBuf {
        let path = PathBuf::from(format!("/tmp/omg-local-{}", &nonce().unwrap()[..8]));
        fs::create_dir_all(path.join("sessions")).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(path.join("sessions"), fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    fn save_stale_control_record(
        registry: &Registry,
        id: &str,
        updated_at: u64,
    ) -> (PathBuf, PathBuf) {
        let mut record = Record::new(id, Policy::default()).unwrap();
        record.pid = Some(std::process::id());
        record.holder_capability = Some(nonce().unwrap());
        record.created_at = updated_at;
        record.updated_at = updated_at;
        let record_path = registry.root.join(format!("{id}.json"));
        fs::write(&record_path, serde_json::to_vec(&record).unwrap()).unwrap();
        let session_socket = registry.session_socket(id);
        let listener =
            std::os::unix::net::UnixListener::bind(crate::holder::control_path(&session_socket))
                .unwrap();
        drop(listener);
        (record_path, session_socket)
    }

    #[test]
    fn catalogue_marks_stale_holder_socket_lost_after_startup_grace() {
        let root = local_test_root();
        let mut registry = Registry::new_local(
            root.join("sessions"),
            vec!["/bin/sh".into()],
            Policy::default(),
        );
        let id = "11111111-1111-1111-1111-111111111111";
        let (record_path, session_socket) = save_stale_control_record(&registry, id, 1);
        let entries = registry.catalogue().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].ended, Some(EndReason::Lost));
        assert_eq!(entries[0].pid, None);
        assert!(!crate::holder::control_path(&session_socket).exists());
        assert!(record_path.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn catalogue_preserves_a_recent_unconfirmed_holder_during_startup_grace() {
        let root = local_test_root();
        let mut registry = Registry::new_local(
            root.join("sessions"),
            vec!["/bin/sh".into()],
            Policy::default(),
        );
        let id = "22222222-2222-2222-2222-222222222222";
        let (record_path, session_socket) = save_stale_control_record(&registry, id, unix_time());
        let entries = registry.catalogue().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].ended, None);
        assert!(entries[0].pid.is_some());
        assert!(crate::holder::control_path(&session_socket).exists());
        assert!(Record::load(&record_path).unwrap().ended.is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn sibling_local_session_root_locates_private_sibling_revisions() {
        use std::os::unix::fs::PermissionsExt;
        let run_root = PathBuf::from(format!("/tmp/omg-run-{}", &nonce().unwrap()[..8]));
        let older_sessions = run_root.join("older-rev/sessions");
        let current_sessions = run_root.join("current-rev/sessions");
        fs::create_dir_all(&older_sessions).unwrap();
        fs::create_dir_all(&current_sessions).unwrap();
        for dir in [
            &run_root,
            &run_root.join("older-rev"),
            &older_sessions,
            &run_root.join("current-rev"),
            &current_sessions,
        ] {
            fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).unwrap();
        }
        let id = "33333333-3333-3333-3333-333333333333";
        let mut record = Record::new(id, Policy::default()).unwrap();
        record
            .save(&older_sessions.join(format!("{id}.json")))
            .unwrap();

        let registry = Registry::new_local(
            current_sessions.clone(),
            vec!["/bin/sh".into()],
            Policy::default(),
        );
        assert_eq!(
            registry.find_sibling_local_session_root(id),
            Some(older_sessions)
        );
        fs::remove_dir_all(run_root).unwrap();
    }

    #[test]
    fn maintenance_purges_expired_closed_tombstones_while_preserving_fresh_or_live_records() {
        let root = local_test_root();
        let sessions = root.join("sessions");
        let mut registry =
            Registry::new_local(sessions.clone(), vec!["/bin/sh".into()], Policy::default());

        let expired_id = "44444444-4444-4444-4444-444444444444";
        let fresh_id = "55555555-5555-5555-5555-555555555555";
        let retained_record_id = "66666666-6666-6666-6666-666666666666";

        let expired_marker = sessions.join(format!("{expired_id}.closed"));
        let fresh_marker = sessions.join(format!("{fresh_id}.closed"));
        let retained_marker = sessions.join(format!("{retained_record_id}.closed"));

        let eight_days_ago =
            std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(unix_time() - 8 * 24 * 3600);
        for marker in [&expired_marker, &retained_marker] {
            let file = fs::File::create(marker).unwrap();
            file.set_modified(eight_days_ago).unwrap();
        }
        fs::File::create(&fresh_marker).unwrap();

        let retained_policy = Policy {
            record_retention_seconds: 30 * 24 * 3600,
            ..Policy::default()
        };
        let mut record = Record::new(retained_record_id, retained_policy).unwrap();
        record.ended = Some(EndReason::ExplicitClose);
        record
            .save(&sessions.join(format!("{retained_record_id}.json")))
            .unwrap();

        registry.last_maintenance = Instant::now() - Duration::from_secs(31);
        registry.maintenance();

        assert!(!expired_marker.exists());
        assert!(fresh_marker.exists());
        assert!(retained_marker.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn local_holder_startup_grace_bypasses_delay_on_prior_boot() {
        let root = local_test_root();
        let registry = Registry::new_local(
            root.join("sessions"),
            vec!["/bin/sh".into()],
            Policy::default(),
        );
        let now = unix_time();
        let cur_boot = crate::record::current_boot_time().unwrap();

        let mut prior_boot =
            Record::new("11111111-1111-1111-1111-111111111111", Policy::default()).unwrap();
        prior_boot.boot_time = Some(cur_boot.saturating_sub(60));
        prior_boot.updated_at = now;
        assert!(registry.local_holder_startup_grace_elapsed(&prior_boot));

        let mut legacy =
            Record::new("22222222-2222-2222-2222-222222222222", Policy::default()).unwrap();
        legacy.boot_time = None;
        legacy.created_at = cur_boot.saturating_sub(60);
        legacy.updated_at = cur_boot.saturating_sub(60);
        assert!(registry.local_holder_startup_grace_elapsed(&legacy));

        let mut same_boot =
            Record::new("33333333-3333-3333-3333-333333333333", Policy::default()).unwrap();
        same_boot.boot_time = Some(cur_boot);
        same_boot.updated_at = now;
        assert!(!registry.local_holder_startup_grace_elapsed(&same_boot));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn sibling_roots_prioritize_closed_over_newer_records_deterministically() {
        use std::os::unix::fs::PermissionsExt;
        let run_root = PathBuf::from(format!("/tmp/omg-sib-{}", &nonce().unwrap()[..8]));
        let rev_a = run_root.join("rev-a/sessions");
        let rev_b = run_root.join("rev-b/sessions");
        let rev_c = run_root.join("rev-c/sessions");
        let cur = run_root.join("cur/sessions");
        for dir in [
            &run_root,
            &run_root.join("rev-a"),
            &rev_a,
            &run_root.join("rev-b"),
            &rev_b,
            &run_root.join("rev-c"),
            &rev_c,
            &run_root.join("cur"),
            &cur,
        ] {
            fs::create_dir_all(dir).unwrap();
            fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).unwrap();
        }
        let id = "77777777-7777-7777-7777-777777777777";
        let mut r_old = Record::new(id, Policy::default()).unwrap();
        r_old.updated_at = 100;
        r_old.created_at = 50;
        r_old.save(&rev_a.join(format!("{id}.json"))).unwrap();

        let mut r_new = Record::new(id, Policy::default()).unwrap();
        r_new.updated_at = 200;
        r_new.created_at = 60;
        r_new.save(&rev_b.join(format!("{id}.json"))).unwrap();

        let registry = Registry::new_local(cur, vec!["/bin/sh".into()], Policy::default());
        assert_eq!(
            registry.find_sibling_local_session_root(id),
            Some(rev_b.clone())
        );
        assert!(!registry.is_closed_in_any_root(id));

        fs::write(rev_c.join(format!("{id}.closed")), b"").unwrap();
        assert!(registry.is_closed_in_any_root(id));
        assert_eq!(registry.find_sibling_local_session_root(id), Some(rev_c));

        fs::remove_dir_all(run_root).unwrap();
    }

    #[test]
    fn open_validates_resurrect_launch_invariants() {
        let root = local_test_root();
        let mut remote = Registry::new(
            root.join("sessions"),
            vec!["/bin/sh".into()],
            Policy::default(),
        );
        let mut local = Registry::new_local(
            root.join("sessions"),
            vec!["/bin/sh".into()],
            Policy::default(),
        );

        let mut spec = launch(vec!["/bin/sh".into()], BTreeMap::new());
        spec.cwd = Some("/tmp/does-not-exist-resurrect-cwd".into());
        assert!(spec.validate().is_err());
        assert!(spec.validate_with(false).is_ok());

        let remote_err = remote
            .open(&OpenRequest {
                id: "88888888-8888-8888-8888-888888888888".into(),
                policy: Policy::default(),
                create: false,
                cwd: None,
                launch: None,
                resurrect_launch: Some(spec.clone()),
                inline_viewer: false,
                recreate_if_gone: false,
                ..Default::default()
            })
            .unwrap_err();
        assert!(remote_err.to_string().contains("SSH"));

        let create_err = local
            .open(&OpenRequest {
                id: "88888888-8888-8888-8888-888888888888".into(),
                policy: Policy::default(),
                create: true,
                cwd: None,
                launch: Some(launch(vec!["/bin/sh".into()], BTreeMap::new())),
                resurrect_launch: Some(spec.clone()),
                inline_viewer: false,
                recreate_if_gone: false,
                ..Default::default()
            })
            .unwrap_err();
        assert!(create_err.to_string().contains("creating"));

        let mut with_input = spec;
        with_input.input_base64 = Some("aGk=".into());
        let input_err = local
            .open(&OpenRequest {
                id: "88888888-8888-8888-8888-888888888888".into(),
                policy: Policy::default(),
                create: false,
                cwd: None,
                launch: None,
                resurrect_launch: Some(with_input),
                inline_viewer: false,
                recreate_if_gone: false,
                ..Default::default()
            })
            .unwrap_err();
        assert!(input_err.to_string().contains("initial input"));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn resurrect_cwd_fallback_and_typed_agent_resume_argv() {
        let dir = PathBuf::from(format!("/tmp/omg-resurrect-cwd-{}", &nonce().unwrap()[..8]));
        let home = dir.join("home");
        let rec_dir = dir.join("rec");
        let store = home.join(".claude/projects/proj");
        fs::create_dir_all(&store).unwrap();
        fs::create_dir_all(&rec_dir).unwrap();
        fs::write(store.join("conv-42.jsonl"), "{}\n").unwrap();

        let mut record =
            Record::new("99999999-9999-9999-9999-999999999999", Policy::default()).unwrap();
        record.cwd = Some(rec_dir.to_string_lossy().into_owned());
        record.resume = Some(crate::record::Resume {
            agent: "claude".into(),
            conversation_id: "conv-42".into(),
            cwd: "/tmp/missing-resume-cwd-xyz".into(),
        });

        let mut env = BTreeMap::new();
        env.insert("HOME".into(), home.to_string_lossy().into_owned());
        let mut provide = launch(vec!["/bin/zsh".into(), "-l".into()], env.clone());
        provide.cwd = Some("/tmp/missing-launch-cwd-xyz".into());

        let built =
            Registry::build_resurrect_launch(&record, Some(provide.clone()), false).unwrap();
        assert_eq!(built.cwd.as_deref(), Some(rec_dir.to_str().unwrap()));
        assert_eq!(
            built.env.get("OMG_FALLBACK_SHELL").map(String::as_str),
            Some("/bin/zsh")
        );
        assert_eq!(&built.argv[..4], ["/bin/zsh", "-l", "-i", "-c"]);
        assert_eq!(
            &built.argv[5..],
            ["omg-resurrect", "claude", "--resume", "conv-42"]
        );

        // Missing record.cwd + resume.cwd + launch.cwd falls through to HOME.
        record.cwd = Some("/tmp/missing-rec-cwd-xyz".into());
        let built_home =
            Registry::build_resurrect_launch(&record, Some(provide.clone()), false).unwrap();
        assert_eq!(built_home.cwd.as_deref(), Some(home.to_str().unwrap()));

        // Fish wrapper uses positional $argv without string interpolation.
        let mut fish_provide = launch(vec!["/opt/homebrew/bin/fish".into()], env);
        fish_provide.cwd = Some(home.to_string_lossy().into_owned());
        let fish_built =
            Registry::build_resurrect_launch(&record, Some(fish_provide), false).unwrap();
        assert_eq!(
            &fish_built.argv[..4],
            ["/opt/homebrew/bin/fish", "-l", "-i", "-c"]
        );
        assert_eq!(&fish_built.argv[5..], ["claude", "--resume", "conv-42"]);

        // Missing conversation store degrades cleanly to login shell for Lost sessions.
        fs::remove_file(store.join("conv-42.jsonl")).unwrap();
        let fallback = Registry::build_resurrect_launch(&record, Some(provide), false).unwrap();
        assert_eq!(fallback.argv, ["/bin/zsh", "-l"]);
        assert!(!fallback.env.contains_key("OMG_FALLBACK_SHELL"));

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn maintenance_cleans_closed_orphaned_and_expired_snapshots() {
        let root = local_test_root();
        let sessions = root.join("sessions");
        let mut registry =
            Registry::new_local(sessions.clone(), vec!["/bin/sh".into()], Policy::default());
        let closed_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        let orphan_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
        let lost_id = "cccccccc-cccc-cccc-cccc-cccccccccccc";

        fs::write(sessions.join(format!("{closed_id}.closed")), b"").unwrap();
        fs::write(sessions.join(format!("{closed_id}.snapshot")), b"stale").unwrap();

        let orphan_snap = sessions.join(format!("{orphan_id}.snapshot"));
        fs::write(&orphan_snap, b"orphan").unwrap();
        let old_time = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(unix_time() - 60);
        fs::File::open(&orphan_snap)
            .unwrap()
            .set_modified(old_time)
            .unwrap();

        let mut lost_record = Record::new(lost_id, Policy::default()).unwrap();
        lost_record.ended = Some(EndReason::Lost);
        lost_record
            .save(&sessions.join(format!("{lost_id}.json")))
            .unwrap();
        let lost_snap = sessions.join(format!("{lost_id}.snapshot"));
        fs::write(&lost_snap, b"keep-me").unwrap();

        registry.last_maintenance = Instant::now() - Duration::from_secs(31);
        registry.maintenance();

        assert!(!sessions.join(format!("{closed_id}.snapshot")).exists());
        assert!(!orphan_snap.exists());
        assert!(lost_snap.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn local_is_empty_and_sibling_paused_discovery_preserve_channel_isolation_and_failed_migration()
    {
        use std::os::{
            fd::AsRawFd,
            unix::fs::{OpenOptionsExt, PermissionsExt},
        };
        let run_root = PathBuf::from(format!("/tmp/omg-sibling-run-{}", &nonce().unwrap()[..8]));
        let cur = run_root.join("cur/sessions");
        let old_unlocked = run_root.join("old/sessions");
        let other_locked = run_root.join("other/sessions");
        fs::create_dir_all(&cur).unwrap();
        fs::create_dir_all(&old_unlocked).unwrap();
        fs::create_dir_all(&other_locked).unwrap();
        for p in [
            &run_root,
            &run_root.join("cur"),
            &cur,
            &run_root.join("old"),
            &old_unlocked,
            &run_root.join("other"),
            &other_locked,
        ] {
            fs::set_permissions(p, fs::Permissions::from_mode(0o700)).unwrap();
        }

        // Hold exclusive flock on `other/host.lock` simulating a live concurrent channel.
        let other_lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(run_root.join("other/host.lock"))
            .unwrap();
        assert_eq!(
            unsafe { libc::flock(other_lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );

        let registry = Registry::new_local(cur.clone(), vec!["/bin/sh".into()], Policy::default());
        assert!(registry.is_empty());

        // Non-closed running record in `cur/sessions` keeps `is_empty()` false even if `local_holders` is empty.
        let live_id = "12121212-1212-1212-1212-121212121212";
        let mut live_rec = Record::new(live_id, Policy::default()).unwrap();
        live_rec.save(&cur.join(format!("{live_id}.json"))).unwrap();
        assert!(!registry.is_empty());

        fs::write(cur.join(format!("{live_id}.closed")), b"").unwrap();
        assert!(registry.is_empty());
        fs::remove_file(cur.join(format!("{live_id}.closed"))).unwrap();
        fs::remove_file(cur.join(format!("{live_id}.json"))).unwrap();

        // Paused session in unlocked `old/sessions` appears in `list()` and `find_local_record`,
        // while paused session in locked `other/sessions` stays isolated.
        let old_paused = "23232323-2323-2323-2323-232323232323";
        let mut r_old = Record::new(old_paused, Policy::default()).unwrap();
        r_old.ended = Some(EndReason::Lost);
        r_old.snapshot_revision = Some("snap-rev-old".into());
        let old_record_path = old_unlocked.join(format!("{old_paused}.json"));
        r_old.save(&old_record_path).unwrap();
        fs::write(
            old_unlocked.join(format!("{old_paused}.snapshot")),
            b"SNAPDATA",
        )
        .unwrap();
        fs::write(old_unlocked.join(format!("{old_paused}.created")), b"").unwrap();

        let locked_paused = "34343434-3434-3434-3434-343434343434";
        let mut r_locked = Record::new(locked_paused, Policy::default()).unwrap();
        r_locked.ended = Some(EndReason::Lost);
        r_locked
            .save(&other_locked.join(format!("{locked_paused}.json")))
            .unwrap();

        let listed = registry.list().unwrap();
        assert!(listed.iter().any(|r| r.id == old_paused));
        assert!(!listed.iter().any(|r| r.id == locked_paused));
        assert!(find_local_record(&cur, old_paused).is_some());
        assert!(find_local_record(&cur, locked_paused).is_none());

        // Make destination `cur/sessions` read-only so `save_snapshot_atomic` / `.created` fails,
        // and verify source sibling `.json`/`.snapshot`/`.created` are NOT deleted!
        fs::set_permissions(&cur, fs::Permissions::from_mode(0o500)).unwrap();
        let mut reg_mut =
            Registry::new_local(cur.clone(), vec!["/bin/sh".into()], Policy::default());
        let sock = reg_mut.session_socket(old_paused);
        let dest_path = cur.join(format!("{old_paused}.json"));
        let res = reg_mut.prepare_connect_local_plan(
            old_paused,
            Some(&r_old.generation),
            &sock,
            &dest_path,
            false,
            None,
            ConnectOptions::default(),
        );
        fs::set_permissions(&cur, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(res.is_err());
        assert!(old_record_path.exists());
        assert!(old_unlocked.join(format!("{old_paused}.snapshot")).exists());
        assert!(old_unlocked.join(format!("{old_paused}.created")).exists());

        // Closing a local `Lost` (`pid: None`, `contained: false`) session transitions
        // cleanly to `ExplicitClose` and removes its `.snapshot` without failing.
        assert!(reg_mut.close(old_paused).unwrap());
        assert_eq!(
            Record::load(&old_record_path).unwrap().ended,
            Some(EndReason::ExplicitClose)
        );
        assert!(!old_unlocked.join(format!("{old_paused}.snapshot")).exists());

        drop(other_lock);
        fs::remove_dir_all(run_root).unwrap();
    }

    #[test]
    fn list_order_is_deterministic_across_repeated_calls_with_multiple_sibling_paused_sessions() {
        use std::os::unix::fs::PermissionsExt;
        let run_root = std::env::temp_dir().join(format!(
            "omg-reg-det-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        let cur = run_root.join("cur/sessions");
        let sib_a = run_root.join("sib_a/sessions");
        let sib_b = run_root.join("sib_b/sessions");
        for dir in [&run_root, &cur, &sib_a, &sib_b] {
            fs::create_dir_all(dir).unwrap();
        }
        for dir in [
            run_root.as_path(),
            run_root.join("cur").as_path(),
            cur.as_path(),
            run_root.join("sib_a").as_path(),
            sib_a.as_path(),
            run_root.join("sib_b").as_path(),
            sib_b.as_path(),
        ] {
            fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).unwrap();
        }

        let entries = [
            (
                &sib_b,
                "40000000-0000-4000-8000-000000000004",
                200u64,
                Some(EndReason::Lost),
            ),
            (
                &sib_a,
                "20000000-0000-4000-8000-000000000002",
                100u64,
                Some(EndReason::Lost),
            ),
            (
                &sib_b,
                "10000000-0000-4000-8000-000000000001",
                100u64,
                Some(EndReason::Lost),
            ),
            (&cur, "30000000-0000-4000-8000-000000000003", 150u64, None),
            (
                &sib_a,
                "50000000-0000-4000-8000-000000000005",
                50u64,
                Some(EndReason::Lost),
            ),
        ];
        for (dir, id, created_at, ended) in entries {
            let mut r = Record::new(id, Policy::default()).unwrap();
            r.created_at = created_at;
            r.updated_at = created_at + 10;
            r.ended = ended;
            r.save(&dir.join(format!("{id}.json"))).unwrap();
        }

        let registry = Registry::new_local(cur, vec!["/bin/sh".into()], Policy::default());
        let expected = vec![
            "50000000-0000-4000-8000-000000000005",
            "10000000-0000-4000-8000-000000000001",
            "20000000-0000-4000-8000-000000000002",
            "30000000-0000-4000-8000-000000000003",
            "40000000-0000-4000-8000-000000000004",
        ];
        for _ in 0..10 {
            let ids: Vec<String> = registry.list().unwrap().into_iter().map(|r| r.id).collect();
            assert_eq!(ids, expected);
        }

        fs::remove_dir_all(run_root).unwrap();
    }

    #[test]
    fn support_root_stamp_isolates_channels_and_supports_legacy_version_hashes() {
        use sha2::{Digest, Sha256};
        use std::os::unix::fs::PermissionsExt;

        let base = std::env::temp_dir().join(format!(
            "omg-reg-chan-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        let support_dev = base.join("Application Support/OMG Dev");
        let support_rel = base.join("Application Support/OMG");
        fs::create_dir_all(support_dev.join("session-runtime/versions/revdevlegacy")).unwrap();
        fs::create_dir_all(support_rel.join("session-runtime/versions/revrellegacy")).unwrap();

        let legacy_dev_hash = format!(
            "{:x}",
            Sha256::digest(format!("{}\0revdevlegacy", support_dev.display()).as_bytes())
        )[..20]
            .to_owned();
        let legacy_rel_hash = format!(
            "{:x}",
            Sha256::digest(format!("{}\0revrellegacy", support_rel.display()).as_bytes())
        )[..20]
            .to_owned();

        let run_root = base.join(".omg/run");
        let cur_dev = run_root.join("curdev00000000000000");
        let sib_dev_stamped = run_root.join("sibdev00000000000000");
        let sib_dev_legacy = run_root.join(&legacy_dev_hash);
        let sib_rel_stamped = run_root.join("sibrel00000000000000");
        let sib_rel_legacy = run_root.join(&legacy_rel_hash);
        let sib_unstamped_raw = run_root.join("rawtmp00000000000000");

        for state_dir in [
            &cur_dev,
            &sib_dev_stamped,
            &sib_dev_legacy,
            &sib_rel_stamped,
            &sib_rel_legacy,
            &sib_unstamped_raw,
        ] {
            fs::create_dir_all(state_dir.join("sessions")).unwrap();
            fs::set_permissions(state_dir, fs::Permissions::from_mode(0o700)).unwrap();
            fs::set_permissions(
                state_dir.join("sessions"),
                fs::Permissions::from_mode(0o700),
            )
            .unwrap();
        }
        fs::set_permissions(&run_root, fs::Permissions::from_mode(0o700)).unwrap();

        write_support_root_stamp(&cur_dev, &support_dev).unwrap();
        write_support_root_stamp(&sib_dev_stamped, &support_dev).unwrap();
        write_support_root_stamp(&sib_rel_stamped, &support_rel).unwrap();

        let id_dev_stamped = "a1111111-1111-4111-8111-111111111111";
        let id_dev_legacy = "a2222222-2222-4222-8222-222222222222";
        let id_rel_stamped = "b1111111-1111-4111-8111-111111111111";
        let id_rel_legacy = "b2222222-2222-4222-8222-222222222222";
        let id_raw = "c1111111-1111-4111-8111-111111111111";

        for (state_dir, id) in [
            (&sib_dev_stamped, id_dev_stamped),
            (&sib_dev_legacy, id_dev_legacy),
            (&sib_rel_stamped, id_rel_stamped),
            (&sib_rel_legacy, id_rel_legacy),
            (&sib_unstamped_raw, id_raw),
        ] {
            let mut r = Record::new(id, Policy::default()).unwrap();
            r.ended = Some(EndReason::Lost);
            r.save(&state_dir.join("sessions").join(format!("{id}.json")))
                .unwrap();
        }

        let cur_sessions = cur_dev.join("sessions");
        let mut reg_dev = Registry::new_local(
            cur_sessions.clone(),
            vec!["/bin/sh".into()],
            Policy::default(),
        );
        let listed_ids: Vec<String> = reg_dev.list().unwrap().into_iter().map(|r| r.id).collect();
        assert!(listed_ids.contains(&id_dev_stamped.to_owned()));
        assert!(listed_ids.contains(&id_dev_legacy.to_owned()));
        assert!(!listed_ids.contains(&id_rel_stamped.to_owned()));
        assert!(!listed_ids.contains(&id_rel_legacy.to_owned()));
        assert!(!listed_ids.contains(&id_raw.to_owned()));

        assert!(find_local_record(&cur_sessions, id_dev_stamped).is_some());
        assert!(find_local_record(&cur_sessions, id_dev_legacy).is_some());
        assert!(find_local_record(&cur_sessions, id_rel_stamped).is_none());
        assert!(find_local_record(&cur_sessions, id_rel_legacy).is_none());
        assert!(find_local_record(&cur_sessions, id_raw).is_none());

        // Closing a release session ID on the OMG Dev registry must NOT touch release `OMG` record!
        let _ = reg_dev.close(id_rel_stamped).unwrap();
        assert!(!sib_rel_stamped
            .join("sessions")
            .join(format!("{id_rel_stamped}.closed"))
            .exists());
        assert_eq!(
            Record::load(
                &sib_rel_stamped
                    .join("sessions")
                    .join(format!("{id_rel_stamped}.json"))
            )
            .unwrap()
            .ended,
            Some(EndReason::Lost)
        );

        // Unstamped raw test root (`None`) sees unstamped siblings, NEVER stamped `OMG`/`OMG Dev` dirs.
        let raw_sessions = sib_unstamped_raw.join("sessions");
        let reg_raw = Registry::new_local(
            raw_sessions.clone(),
            vec!["/bin/sh".into()],
            Policy::default(),
        );
        let raw_ids: Vec<String> = reg_raw.list().unwrap().into_iter().map(|r| r.id).collect();
        assert!(!raw_ids.contains(&id_dev_stamped.to_owned()));
        assert!(!raw_ids.contains(&id_rel_stamped.to_owned()));
        assert!(raw_ids.contains(&id_dev_legacy.to_owned()));

        // If the disposable `support_dev` profile was deleted, `cur_dev` discovers zero siblings!
        fs::remove_dir_all(&support_dev).unwrap();
        assert!(reg_dev.list().unwrap().is_empty());

        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn normalize_support_path_and_symlinked_support_root_preserve_sibling_discovery() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        assert_eq!(normalize_support_path(Path::new("/")), PathBuf::from("/"));
        assert_eq!(normalize_support_path(Path::new("///")), PathBuf::from("/"));
        assert_eq!(normalize_support_path(Path::new("/.")), PathBuf::from("/"));
        assert_eq!(
            normalize_support_path(Path::new(
                "/Users/alice/./Library//Application Support/OMG/."
            )),
            PathBuf::from("/Users/alice/Library/Application Support/OMG")
        );
        assert_eq!(
            normalize_support_path(Path::new("/Users/alice/Library/Application Support/OMG/")),
            PathBuf::from("/Users/alice/Library/Application Support/OMG")
        );
        assert_eq!(normalize_support_path(Path::new(".")), PathBuf::from("."));
        assert_eq!(
            normalize_support_path(Path::new("./rel/path/")),
            PathBuf::from("rel/path")
        );
        assert_eq!(
            local_run_dir_key(
                Path::new("/Users/alice/Library/Application Support/OMG"),
                "0.21.0"
            ),
            local_run_dir_key(
                Path::new("/Users/alice/./Library//Application Support/OMG/"),
                "0.21.0"
            )
        );
        assert_eq!(
            local_run_dir_key(
                Path::new("/Users/alice/Library/Application Support/OMG"),
                "0.21.0"
            ),
            local_channel_run_dir_key(Path::new("/Users/alice/Library/Application Support/OMG"))
        );
        assert_eq!(
            local_run_dir_key(
                Path::new("/Users/alice/Library/Application Support/OMG"),
                "0.21.0"
            ),
            local_run_dir_key(
                Path::new("/Users/alice/Library/Application Support/OMG"),
                "0.22.0"
            )
        );
        assert_ne!(
            local_channel_run_dir_key(Path::new("/Users/alice/Library/Application Support/OMG")),
            legacy_local_run_dir_key(
                Path::new("/Users/alice/Library/Application Support/OMG"),
                "0.21.0"
            )
        );
        assert_eq!(
            infer_support_root_from_exe(Path::new(
                "/Users/alice/./Library/Application Support/OMG//session-runtime/versions/0.21.0/omgd"
            )),
            Some(PathBuf::from("/Users/alice/Library/Application Support/OMG"))
        );

        let base = std::env::temp_dir().join(format!(
            "omg-reg-sym-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        let real_home = base.join("Volumes/Data/Users/alice");
        let logical_home = base.join("Users/alice");
        fs::create_dir_all(&real_home).unwrap();
        fs::create_dir_all(logical_home.parent().unwrap()).unwrap();
        symlink(&real_home, &logical_home).unwrap();

        let logical_omg = logical_home.join("Library/Application Support/OMG");
        let logical_dev = logical_home.join("Library/Application Support/OMG Dev");
        fs::create_dir_all(logical_omg.join("session-runtime/versions/0.20.0")).unwrap();
        fs::create_dir_all(logical_dev.join("session-runtime/versions/0.20.0")).unwrap();

        let realpath_omg = fs::canonicalize(&logical_omg).unwrap();
        let realpath_dev = fs::canonicalize(&logical_dev).unwrap();
        assert_ne!(logical_omg, realpath_omg);
        assert_eq!(
            prefer_logical_home_path_with_home(&realpath_omg, Some(&logical_home)),
            logical_omg
        );

        let run_root = logical_home.join(".omg/run");
        let cur_realpath_stamped = run_root.join("curreal0000000000000");
        let sib_logical_stamped = run_root.join("siblogi0000000000000");
        let sib_logical_legacy = run_root.join(legacy_local_run_dir_key(&logical_omg, "0.20.0"));
        let sib_realpath_legacy = run_root.join(legacy_local_run_dir_key(&realpath_omg, "0.20.0"));
        let sib_dev_stamped = run_root.join("sibdevs0000000000000");
        let sib_dev_legacy = run_root.join(legacy_local_run_dir_key(&logical_dev, "0.20.0"));

        for dir in [
            &cur_realpath_stamped,
            &sib_logical_stamped,
            &sib_logical_legacy,
            &sib_realpath_legacy,
            &sib_dev_stamped,
            &sib_dev_legacy,
        ] {
            fs::create_dir_all(dir.join("sessions")).unwrap();
            fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).unwrap();
            fs::set_permissions(dir.join("sessions"), fs::Permissions::from_mode(0o700)).unwrap();
        }
        fs::set_permissions(&run_root, fs::Permissions::from_mode(0o700)).unwrap();

        // Stamping logical path first, then calling write_support_root_stamp with realpath
        // (or trailing slash) must NOT overwrite the logical stamp!
        write_support_root_stamp(
            &sib_logical_stamped,
            Path::new(&format!("{}/", logical_omg.display())),
        )
        .unwrap();
        assert_eq!(
            read_support_root_stamp(&sib_logical_stamped).as_deref(),
            Some(logical_omg.as_path())
        );
        write_support_root_stamp(&sib_logical_stamped, &realpath_omg).unwrap();
        assert_eq!(
            read_support_root_stamp(&sib_logical_stamped).as_deref(),
            Some(logical_omg.as_path())
        );

        // Even if an upgraded state dir was previously stamped with realpath,
        // sibling_session_roots_for_with_home discovers both logical-stamped and
        // logical-hashed pre-stamp siblings while isolating OMG Dev!
        write_support_root_stamp(&cur_realpath_stamped, &realpath_omg).unwrap();
        write_support_root_stamp(&sib_dev_stamped, &realpath_dev).unwrap();

        let siblings = Registry::sibling_session_roots_for_with_home(
            &cur_realpath_stamped.join("sessions"),
            Some(&logical_home),
        );
        assert!(siblings.contains(&sib_logical_stamped.join("sessions")));
        assert!(siblings.contains(&sib_logical_legacy.join("sessions")));
        assert!(siblings.contains(&sib_realpath_legacy.join("sessions")));
        assert!(!siblings.contains(&sib_dev_stamped.join("sessions")));
        assert!(!siblings.contains(&sib_dev_legacy.join("sessions")));

        // Symmetric check: logical-stamped current dir also discovers realpath-stamped sibling.
        let siblings_reverse = Registry::sibling_session_roots_for_with_home(
            &sib_logical_stamped.join("sessions"),
            Some(&logical_home),
        );
        assert!(siblings_reverse.contains(&cur_realpath_stamped.join("sessions")));
        assert!(siblings_reverse.contains(&sib_logical_legacy.join("sessions")));
        assert!(siblings_reverse.contains(&sib_realpath_legacy.join("sessions")));
        assert!(!siblings_reverse.contains(&sib_dev_stamped.join("sessions")));

        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn concurrent_reap_during_failed_holder_spawn_fails_fast_and_rolls_back_record() {
        use std::os::unix::fs::PermissionsExt;
        use std::sync::atomic::{AtomicBool, Ordering};

        let base = std::env::temp_dir().join(format!(
            "omg-reg-toctou-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        let sessions = base.join("state/sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::set_permissions(&base, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(base.join("state"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();

        let fake_holder = base.join("fail-holder.sh");
        fs::write(&fake_holder, b"#!/bin/sh\ncat >/dev/null\nexit 1\n").unwrap();
        fs::set_permissions(&fake_holder, fs::Permissions::from_mode(0o700)).unwrap();

        let registry = Arc::new(Mutex::new(Registry::new_local(
            sessions.clone(),
            vec!["/bin/sh".into()],
            Policy::default(),
        )));

        let stop = Arc::new(AtomicBool::new(false));
        let stop_reaper = stop.clone();
        let reg_reaper = registry.clone();
        let reaper = thread::spawn(move || {
            while !stop_reaper.load(Ordering::Relaxed) {
                reg_reaper.lock().unwrap().reap_finished_children();
                thread::sleep(Duration::from_millis(1));
            }
        });

        let launch = LocalLaunchSpec {
            argv: vec!["/bin/sh".into(), "-c".into(), "exit 0".into()],
            env: BTreeMap::new(),
            cwd: Some(base.to_string_lossy().into_owned()),
            cols: 80,
            rows: 24,
            pixel_width: 640,
            pixel_height: 384,
            scrollback_max_bytes: None,
            scrollback_max_lines: None,
            input_base64: None,
        };

        // 1. Newly created session: must fail fast (< 1.5s, not 5s!) and remove .json + .created.
        let new_id = "11111111-2222-4333-8444-555555555555";
        let new_path = sessions.join(format!("{new_id}.json"));
        let new_created = sessions.join(format!("{new_id}.created"));
        let new_sock = Registry::session_socket_in(&sessions, new_id);
        fs::write(&new_created, b"").unwrap();
        let mut new_rec = Record::new(new_id, Policy::default()).unwrap();
        new_rec.holder_capability = Some(nonce().unwrap());
        new_rec.save(&new_path).unwrap();

        let plan_new = registry
            .lock()
            .unwrap()
            .prepare_local_holder_spawn_with_exe(
                &fake_holder,
                new_id,
                &new_sock,
                &new_path,
                &mut new_rec,
                launch.clone(),
                false,
                None,
                true,
                true,
            )
            .unwrap();
        assert!(registry.lock().unwrap().local_holders.is_empty());

        let started = Instant::now();
        let err = Registry::await_spawned_local_holder(&registry, plan_new).unwrap_err();
        assert!(
            started.elapsed() < Duration::from_millis(1500),
            "expected fast exit detection despite concurrent reap_finished_children, took {:?}",
            started.elapsed()
        );
        assert!(err.to_string().contains("exited during startup"));
        assert!(!new_path.exists());
        assert!(!new_created.exists());

        // 2. Existing resurrected session: must fail fast and roll {id}.json back to EndReason::Lost!
        let res_id = "22222222-3333-4444-8555-666666666666";
        let res_path = sessions.join(format!("{res_id}.json"));
        let res_snap = sessions.join(format!("{res_id}.snapshot"));
        let res_sock = Registry::session_socket_in(&sessions, res_id);
        fs::write(&res_snap, b"SNAP").unwrap();
        let mut res_rec = Record::new(res_id, Policy::default()).unwrap();
        res_rec.holder_capability = Some(nonce().unwrap());
        res_rec.ended = None;
        res_rec.save(&res_path).unwrap();

        let plan_res = registry
            .lock()
            .unwrap()
            .prepare_local_holder_spawn_with_exe(
                &fake_holder,
                res_id,
                &res_sock,
                &res_path,
                &mut res_rec,
                launch,
                true,
                None,
                false,
                false,
            )
            .unwrap();

        let started_res = Instant::now();
        let err_res = Registry::await_spawned_local_holder(&registry, plan_res).unwrap_err();
        assert!(started_res.elapsed() < Duration::from_millis(1500));
        assert!(err_res.to_string().contains("exited during startup"));
        let rolled_back = Record::load(&res_path).unwrap();
        assert_eq!(rolled_back.ended, Some(EndReason::Lost));
        assert_eq!(rolled_back.pid, None);
        assert!(res_snap.exists());

        stop.store(true, Ordering::Relaxed);
        reaper.join().unwrap();
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn wedged_holder_spawn_timeout_kills_and_reaps_child_and_rolls_back() {
        use std::os::unix::fs::PermissionsExt;

        let base = std::env::temp_dir().join(format!(
            "omg-reg-wedge-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        let sessions = base.join("state/sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::set_permissions(&base, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(base.join("state"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();

        let wedged_holder = base.join("wedged-holder.sh");
        fs::write(
            &wedged_holder,
            b"#!/bin/sh\ncat >/dev/null\ntrap '' TERM INT HUP\nsleep 60\n",
        )
        .unwrap();
        fs::set_permissions(&wedged_holder, fs::Permissions::from_mode(0o700)).unwrap();

        let registry = Arc::new(Mutex::new(Registry::new_local(
            sessions.clone(),
            vec!["/bin/sh".into()],
            Policy::default(),
        )));
        let launch = LocalLaunchSpec {
            argv: vec!["/bin/sh".into(), "-c".into(), "exit 0".into()],
            env: BTreeMap::new(),
            cwd: Some(base.to_string_lossy().into_owned()),
            cols: 80,
            rows: 24,
            pixel_width: 640,
            pixel_height: 384,
            scrollback_max_bytes: None,
            scrollback_max_lines: None,
            input_base64: None,
        };

        // 1. Existing resurrected record timeout: kills + reaps wedged child, cleans sockets, marks Lost.
        let res_id = "33333333-4444-4555-8666-777777777777";
        let res_path = sessions.join(format!("{res_id}.json"));
        let res_sock = Registry::session_socket_in(&sessions, res_id);
        let res_ctl = crate::holder::control_path(&res_sock);
        fs::write(&res_sock, b"stale").unwrap();
        fs::write(&res_ctl, b"stale").unwrap();
        let mut res_rec = Record::new(res_id, Policy::default()).unwrap();
        res_rec.holder_capability = Some(nonce().unwrap());
        res_rec.ended = None;
        res_rec.save(&res_path).unwrap();

        let plan_res = registry
            .lock()
            .unwrap()
            .prepare_local_holder_spawn_with_exe(
                &wedged_holder,
                res_id,
                &res_sock,
                &res_path,
                &mut res_rec,
                launch.clone(),
                true,
                None,
                false,
                false,
            )
            .unwrap();
        let wedged_pid_1 = plan_res.child.as_ref().unwrap().id() as libc::pid_t;
        assert_eq!(unsafe { libc::kill(wedged_pid_1, 0) }, 0);

        let err = Registry::await_spawned_local_holder_with_timeout(
            &registry,
            plan_res,
            Duration::from_millis(120),
        )
        .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::TimedOut);
        assert_ne!(unsafe { libc::kill(wedged_pid_1, 0) }, 0);
        assert!(!res_sock.exists());
        assert!(!res_ctl.exists());
        assert_eq!(
            Record::load(&res_path).unwrap().ended,
            Some(EndReason::Lost)
        );

        // 2. Newly created record timeout: kills + reaps wedged child and removes .json + .created.
        let new_id = "44444444-5555-4666-8777-888888888888";
        let new_path = sessions.join(format!("{new_id}.json"));
        let new_created = sessions.join(format!("{new_id}.created"));
        let new_sock = Registry::session_socket_in(&sessions, new_id);
        fs::write(&new_created, b"").unwrap();
        let mut new_rec = Record::new(new_id, Policy::default()).unwrap();
        new_rec.holder_capability = Some(nonce().unwrap());
        new_rec.save(&new_path).unwrap();

        let plan_new = registry
            .lock()
            .unwrap()
            .prepare_local_holder_spawn_with_exe(
                &wedged_holder,
                new_id,
                &new_sock,
                &new_path,
                &mut new_rec,
                launch,
                false,
                None,
                true,
                true,
            )
            .unwrap();
        let wedged_pid_2 = plan_new.child.as_ref().unwrap().id() as libc::pid_t;
        assert_eq!(unsafe { libc::kill(wedged_pid_2, 0) }, 0);

        let err2 = Registry::await_spawned_local_holder_with_timeout(
            &registry,
            plan_new,
            Duration::from_millis(120),
        )
        .unwrap_err();
        assert_eq!(err2.kind(), io::ErrorKind::TimedOut);
        assert_ne!(unsafe { libc::kill(wedged_pid_2, 0) }, 0);
        assert!(!new_path.exists());
        assert!(!new_created.exists());

        fs::remove_dir_all(base).unwrap();
    }

    fn set_file_mtime_seconds_ago(path: &Path, seconds_ago: u64) {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let target_sec = unix_time().saturating_sub(seconds_ago) as libc::time_t;
        let times = [
            libc::timespec {
                tv_sec: target_sec,
                tv_nsec: 0,
            },
            libc::timespec {
                tv_sec: target_sec,
                tv_nsec: 0,
            },
        ];
        let c_path = CString::new(path.as_os_str().as_bytes()).unwrap();
        let rc = unsafe { libc::utimensat(libc::AT_FDCWD, c_path.as_ptr(), times.as_ptr(), 0) };
        assert_eq!(rc, 0);
    }

    fn write_capture_holder_script(dir: &Path) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let script = dir.join("capture-holder.sh");
        fs::write(&script, b"#!/bin/sh\ncat >/dev/null\nexit 0\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        script
    }

    #[test]
    fn local_channel_run_dir_key_is_stable_across_revisions() {
        let support = Path::new("/tmp/omg-support/Library/Application Support/OMG");
        assert_eq!(
            local_channel_run_dir_key(support),
            local_run_dir_key(support, "rev-a")
        );
        assert_eq!(
            local_run_dir_key(support, "rev-a"),
            local_run_dir_key(support, "rev-b")
        );
        assert_ne!(
            local_channel_run_dir_key(support),
            legacy_local_run_dir_key(support, "rev-a")
        );
    }

    #[test]
    fn recreate_if_gone_preserves_valid_lost_snapshot_resurrection_and_recreates_gone_sessions() {
        use std::os::unix::fs::PermissionsExt;

        let base = local_test_root();
        let sessions = base.join("sessions");
        let work_cwd = base.join("work-cwd");
        let req_cwd = base.join("req-cwd");
        fs::create_dir_all(&work_cwd).unwrap();
        fs::create_dir_all(&req_cwd).unwrap();

        let fake_holder = write_capture_holder_script(&base);
        let mut registry =
            Registry::new_local(sessions.clone(), vec!["/bin/sh".into()], Policy::default());
        registry.holder_executable = Some(fake_holder);

        let mut res_launch = launch(vec!["/bin/sh".into(), "-l".into()], BTreeMap::new());
        res_launch.cwd = Some(work_cwd.to_string_lossy().into_owned());

        // 1. Strict attach/resurrect (`recreate_if_gone: false`) fails on gone/unknown sessions.
        let unknown_id = "11111111-1111-4111-8111-111111111111";
        let unknown_err = registry
            .open(&OpenRequest {
                id: unknown_id.into(),
                policy: Policy::default(),
                create: false,
                cwd: None,
                launch: None,
                resurrect_launch: Some(res_launch.clone()),
                inline_viewer: false,
                recreate_if_gone: false,
                ..Default::default()
            })
            .unwrap_err();
        assert!(unknown_err.to_string().contains("unknown"));

        // 2. EndReason::Lost WITH valid snapshot + resurrect_launch -> normal snapshot resurrection.
        let lost_snap_id = "22222222-2222-4222-8222-222222222222";
        let lost_snap_path = sessions.join(format!("{lost_snap_id}.json"));
        let mut lost_snap_rec = Record::new(lost_snap_id, Policy::default()).unwrap();
        lost_snap_rec.ended = Some(EndReason::Lost);
        lost_snap_rec.cwd = Some(work_cwd.to_string_lossy().into_owned());
        lost_snap_rec.snapshot_revision = crate::current_snapshot_revision();
        let orig_gen = lost_snap_rec.generation.clone();
        lost_snap_rec.save(&lost_snap_path).unwrap();
        fs::write(sessions.join(format!("{lost_snap_id}.created")), b"").unwrap();
        let rev = crate::current_snapshot_revision().unwrap_or_default();
        let mut blob = b"OMGSNAP1\0".to_vec();
        blob.extend_from_slice(rev.as_bytes());
        blob.push(0);
        blob.extend_from_slice(b"valid-vt-bytes");
        crate::server::save_snapshot_atomic(&lost_snap_path, &blob).unwrap();

        let lost_sock = Registry::session_socket_in(&sessions, lost_snap_id);
        let mut plan = registry
            .prepare_connect_local_plan(
                lost_snap_id,
                None,
                &lost_sock,
                &lost_snap_path,
                false,
                None,
                ConnectOptions {
                    cwd: None,
                    launch: None,
                    resurrect_launch: Some(res_launch.clone()),
                    inline_viewer: false,
                    recreate_if_gone: true,
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(!plan.created_new_record);
        assert_ne!(plan.record.generation, orig_gen);
        assert!(crate::server::snapshot_path(&lost_snap_path).exists());
        plan.terminate_and_reap_child();
        let _ = registry.rollback_failed_spawn(&mut plan);

        // 3. Unknown, corrupt snapshot, and non-resurrectable ended sessions all recreate when enabled.
        for (idx, ended_opt) in [
            None,
            Some(EndReason::Lost),
            Some(EndReason::ProcessExited),
            Some(EndReason::DetachedTimeout),
            Some(EndReason::ExplicitClose),
            Some(EndReason::AgentCompleted),
            Some(EndReason::Deadline),
        ]
        .into_iter()
        .enumerate()
        {
            let id = format!("33333333-3333-4333-8333-{idx:012}");
            let rec_path = sessions.join(format!("{id}.json"));
            let sock = Registry::session_socket_in(&sessions, &id);
            let evt = sock.with_extension("evt");
            let ctl = crate::holder::control_path(&sock);
            let created = sessions.join(format!("{id}.created"));
            let closed = sessions.join(format!("{id}.closed"));

            fs::write(&evt, b"").unwrap();
            fs::write(&ctl, b"").unwrap();
            if let Some(ended) = ended_opt {
                fs::write(&created, b"").unwrap();
                let mut rec = Record::new(&id, Policy::default()).unwrap();
                rec.ended = Some(ended);
                rec.cwd = Some(work_cwd.to_string_lossy().into_owned());
                rec.save(&rec_path).unwrap();
                if ended == EndReason::Lost {
                    // Corrupt snapshot payload (magic with empty vt bytes) -> must fall back to recreate.
                    crate::server::save_snapshot_atomic(&rec_path, b"OMGSNAP1\0\0").unwrap();
                } else if ended == EndReason::ExplicitClose {
                    fs::write(&closed, b"").unwrap();
                }

                // Strict mode (`recreate_if_gone: false`) must reject non-Lost / closed!
                if ended != EndReason::Lost {
                    let strict_err = registry
                        .prepare_connect_local_plan(
                            &id,
                            None,
                            &sock,
                            &rec_path,
                            false,
                            None,
                            ConnectOptions {
                                cwd: Some(&req_cwd.to_string_lossy()),
                                launch: None,
                                resurrect_launch: Some(res_launch.clone()),
                                inline_viewer: false,
                                recreate_if_gone: false,
                                ..Default::default()
                            },
                        )
                        .err()
                        .expect("strict attach must reject ended/closed session");
                    assert!(!strict_err.to_string().is_empty());
                }
            }

            let mut recreated = registry
                .prepare_connect_local_plan(
                    &id,
                    None,
                    &sock,
                    &rec_path,
                    false,
                    None,
                    ConnectOptions {
                        cwd: Some(&req_cwd.to_string_lossy()),
                        launch: None,
                        resurrect_launch: if idx % 2 == 0 {
                            Some(res_launch.clone())
                        } else {
                            None
                        },
                        inline_viewer: true,
                        recreate_if_gone: true,
                        ..Default::default()
                    },
                )
                .unwrap();
            assert!(recreated.created_new_record);
            assert!(recreated.record.ended.is_none());
            assert!(recreated.record.inline_viewer);
            assert_eq!(
                recreated.record.cwd.as_deref(),
                Some(req_cwd.to_string_lossy().as_ref())
            );
            assert!(!closed.exists());
            assert!(created.exists());
            assert!(!evt.exists());
            assert!(!ctl.exists());
            assert!(!crate::server::snapshot_path(&rec_path).exists());
            recreated.terminate_and_reap_child();
            let _ = registry.rollback_failed_spawn(&mut recreated);
        }

        let _ = fs::set_permissions(&base, fs::Permissions::from_mode(0o700));
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn recreate_if_gone_remote_ssh_recreates_unknown_and_lost_sessions_only_when_enabled() {
        let base = local_test_root();
        let sessions = base.join("sessions");
        let fallback_cwd = base.join("saved-cwd");
        let req_cwd = base.join("requested-cwd");
        fs::create_dir_all(&fallback_cwd).unwrap();
        fs::create_dir_all(&req_cwd).unwrap();

        let mut remote = Registry::new(
            sessions.clone(),
            vec!["/bin/sh".into(), "-c".into(), "exec sleep 5".into()],
            Policy::default(),
        );

        let missing_id = "44444444-4444-4444-8444-444444444444";
        let strict_missing = remote
            .open(&OpenRequest {
                id: missing_id.into(),
                policy: Policy::default(),
                create: false,
                cwd: None,
                launch: None,
                resurrect_launch: None,
                inline_viewer: false,
                recreate_if_gone: false,
                ..Default::default()
            })
            .unwrap_err();
        assert!(strict_missing.to_string().contains("unknown"));

        let mut stream = remote
            .open(&OpenRequest {
                id: missing_id.into(),
                policy: Policy::default(),
                create: false,
                cwd: Some(req_cwd.to_string_lossy().into_owned()),
                launch: None,
                resurrect_launch: None,
                inline_viewer: false,
                recreate_if_gone: true,
                ..Default::default()
            })
            .unwrap();
        let _ = crate::Frame::new(crate::CLOSE, 0, &[]).send(&mut stream);
        drop(stream);
        if let Some(worker) = remote.workers.remove(missing_id) {
            let _ = worker.join();
        }
        assert_eq!(
            Record::load(&sessions.join(format!("{missing_id}.json")))
                .unwrap()
                .cwd
                .as_deref()
                .map(Path::new)
                .and_then(|p| fs::canonicalize(p).ok()),
            fs::canonicalize(&req_cwd).ok()
        );

        for (idx, reason) in [
            EndReason::Lost,
            EndReason::ProcessExited,
            EndReason::ExplicitClose,
        ]
        .into_iter()
        .enumerate()
        {
            let id = format!("55555555-5555-4555-8555-{idx:012}");
            let rec_path = sessions.join(format!("{id}.json"));
            let mut rec = Record::new(&id, Policy::default()).unwrap();
            rec.ended = Some(reason);
            rec.cwd = Some(fallback_cwd.to_string_lossy().into_owned());
            rec.save(&rec_path).unwrap();
            fs::write(sessions.join(format!("{id}.created")), b"").unwrap();
            if reason == EndReason::ExplicitClose {
                fs::write(sessions.join(format!("{id}.closed")), b"").unwrap();
            }

            let strict_err = remote
                .open(&OpenRequest {
                    id: id.clone(),
                    policy: Policy::default(),
                    create: false,
                    cwd: None,
                    launch: None,
                    resurrect_launch: None,
                    inline_viewer: false,
                    recreate_if_gone: false,
                    ..Default::default()
                })
                .unwrap_err();
            assert!(!strict_err.to_string().is_empty());

            let mut stream = remote
                .open(&OpenRequest {
                    id: id.clone(),
                    policy: Policy::default(),
                    create: false,
                    cwd: None,
                    launch: None,
                    resurrect_launch: None,
                    inline_viewer: false,
                    recreate_if_gone: true,
                    ..Default::default()
                })
                .unwrap();
            let updated = Record::load(&rec_path).unwrap();
            assert!(updated.ended.is_none());
            assert_eq!(
                updated
                    .cwd
                    .as_deref()
                    .map(Path::new)
                    .and_then(|p| fs::canonicalize(p).ok()),
                fs::canonicalize(&fallback_cwd).ok()
            );
            assert!(!sessions.join(format!("{id}.closed")).exists());
            let _ = crate::Frame::new(crate::CLOSE, 0, &[]).send(&mut stream);
            drop(stream);
            if let Some(worker) = remote.workers.remove(&id) {
                let _ = worker.join();
            }
        }

        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn maintenance_reaps_orphan_created_markers_older_than_60_seconds() {
        let root = local_test_root();
        let sessions = root.join("sessions");
        let mut registry =
            Registry::new_local(sessions.clone(), vec!["/bin/sh".into()], Policy::default());
        let old_id = "66666666-6666-4666-8666-666666666661";
        let fresh_id = "66666666-6666-4666-8666-666666666662";
        let old_marker = sessions.join(format!("{old_id}.created"));
        let fresh_marker = sessions.join(format!("{fresh_id}.created"));
        fs::write(&old_marker, b"").unwrap();
        fs::write(&fresh_marker, b"").unwrap();
        set_file_mtime_seconds_ago(&old_marker, ORPHAN_CREATED_MARKER_MAX_AGE_SECONDS + 15);

        let _ = registry.catalogue().unwrap();
        assert!(!old_marker.exists());
        assert!(fresh_marker.exists());

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn prepare_local_holder_spawn_rolls_back_record_ended_on_pre_spawn_error() {
        let root = local_test_root();
        let sessions = root.join("sessions");
        let mut registry =
            Registry::new_local(sessions.clone(), vec!["/bin/sh".into()], Policy::default());
        // Force OpenOptions::open(root.join("host.log")) to fail before holder::spawn().
        fs::create_dir_all(root.join("host.log")).unwrap();

        let existing_id = "77777777-7777-4777-8777-777777777771";
        let existing_path = sessions.join(format!("{existing_id}.json"));
        let existing_sock = Registry::session_socket_in(&sessions, existing_id);
        let mut existing_rec = Record::new(existing_id, Policy::default()).unwrap();
        existing_rec.pid = Some(12345);
        existing_rec.ended = None;
        existing_rec.save(&existing_path).unwrap();

        let mut spec = launch(vec!["/bin/sh".into()], BTreeMap::new());
        spec.cwd = Some(root.to_string_lossy().into_owned());
        let err = registry
            .prepare_local_holder_spawn_with_exe(
                Path::new("/bin/sh"),
                existing_id,
                &existing_sock,
                &existing_path,
                &mut existing_rec,
                spec.clone(),
                false,
                None,
                false,
                false,
            )
            .err()
            .expect("host.log directory must fail spawn prep");
        assert!(
            err.kind() == io::ErrorKind::IsADirectory || err.raw_os_error() == Some(libc::EISDIR)
        );
        let rolled_back = Record::load(&existing_path).unwrap();
        assert_eq!(rolled_back.ended, Some(EndReason::Lost));
        assert_eq!(rolled_back.pid, None);

        let new_id = "77777777-7777-4777-8777-777777777772";
        let new_path = sessions.join(format!("{new_id}.json"));
        let new_created = sessions.join(format!("{new_id}.created"));
        let new_sock = Registry::session_socket_in(&sessions, new_id);
        fs::write(&new_created, b"").unwrap();
        let mut new_rec = Record::new(new_id, Policy::default()).unwrap();
        new_rec.save(&new_path).unwrap();
        let err_new = registry
            .prepare_local_holder_spawn_with_exe(
                Path::new("/bin/sh"),
                new_id,
                &new_sock,
                &new_path,
                &mut new_rec,
                spec,
                false,
                None,
                true,
                true,
            )
            .err()
            .expect("host.log directory must fail spawn prep for new record");
        assert!(
            err_new.kind() == io::ErrorKind::IsADirectory
                || err_new.raw_os_error() == Some(libc::EISDIR)
        );
        assert!(!new_path.exists());
        assert!(!new_created.exists());

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn local_holder_startup_grace_uses_created_at_and_checks_pid_liveness() {
        let root = local_test_root();
        let registry = Registry::new_local(
            root.join("sessions"),
            vec!["/bin/sh".into()],
            Policy::default(),
        );
        let now = unix_time();
        let cur_boot = crate::record::current_boot_time();

        let mut old_created_fresh_updated =
            Record::new("88888888-8888-4888-8888-888888888881", Policy::default()).unwrap();
        old_created_fresh_updated.pid = Some(std::process::id());
        old_created_fresh_updated.boot_time = cur_boot;
        old_created_fresh_updated.created_at =
            now.saturating_sub(LOCAL_HOLDER_STARTUP_GRACE_SECONDS + 5);
        old_created_fresh_updated.updated_at = now;
        assert!(registry.local_holder_startup_grace_elapsed(&old_created_fresh_updated));

        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "exit 0"])
            .spawn()
            .unwrap();
        let dead_pid = child.id();
        let _ = child.wait();
        let mut dead_pid_recent =
            Record::new("88888888-8888-4888-8888-888888888882", Policy::default()).unwrap();
        dead_pid_recent.pid = Some(dead_pid);
        dead_pid_recent.boot_time = cur_boot;
        dead_pid_recent.created_at = now;
        dead_pid_recent.updated_at = now;
        assert!(registry.local_holder_startup_grace_elapsed(&dead_pid_recent));

        fs::remove_dir_all(root).unwrap();
    }
}
