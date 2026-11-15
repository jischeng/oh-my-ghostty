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

#[derive(serde::Deserialize, serde::Serialize)]
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
}

fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Default)]
struct ConnectOptions<'a> {
    cwd: Option<&'a str>,
    launch: Option<LocalLaunchSpec>,
    resurrect_launch: Option<LocalLaunchSpec>,
    inline_viewer: bool,
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
    mode: RuntimeMode,
    containment_root: Option<PathBuf>,
    last_maintenance: Instant,
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
            mode: RuntimeMode::Remote,
            containment_root: None,
            last_maintenance: Instant::now() - Duration::from_secs(30),
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
    fn sibling_session_roots(&self) -> Vec<PathBuf> {
        if self.mode != RuntimeMode::Local {
            return Vec::new();
        }
        let Some(current_state_dir) = self.root.parent() else {
            return Vec::new();
        };
        let Some(run_root) = current_state_dir.parent() else {
            return Vec::new();
        };
        if !Self::is_private_owned_dir(run_root) {
            return Vec::new();
        }
        let Ok(entries) = fs::read_dir(run_root) else {
            return Vec::new();
        };
        let mut roots = Vec::new();
        for entry in entries.flatten() {
            let state_dir = entry.path();
            if state_dir == current_state_dir || !Self::is_private_owned_dir(&state_dir) {
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

    fn is_closed_in_any_root(&self, id: &str) -> bool {
        if self.root.join(format!("{id}.closed")).exists() {
            return true;
        }
        self.sibling_session_roots()
            .into_iter()
            .any(|sessions_dir| sessions_dir.join(format!("{id}.closed")).exists())
    }

    fn find_sibling_local_session_root(&self, id: &str) -> Option<PathBuf> {
        let siblings = self.sibling_session_roots();
        if siblings.is_empty() {
            return None;
        }
        let mut record_candidates = Vec::new();
        let mut created_fallback = None;
        for sessions_dir in siblings {
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
        let owned_child_status = self
            .local_holders
            .get_mut(&record.id)
            .filter(|holder| holder.capability == capability)
            .and_then(|holder| holder.child.as_mut())
            .map(Child::try_wait)
            .transpose();
        match owned_child_status {
            Ok(Some(None)) if !verify_owned_child => return Ok(()),
            Ok(Some(Some(_))) => {
                self.local_holders.remove(&record.id);
            }
            Err(error) if !verify_owned_child => return Err(error),
            _ => {}
        }
        let session_socket = Self::session_socket_in(sessions_root, &record.id);
        let record_path = sessions_root.join(format!("{}.json", record.id));
        let attempts = if verify_owned_child { 3 } else { 1 };
        for attempt in 0..attempts {
            match crate::holder::probe_with_timeout(
                &session_socket,
                &record.id,
                &record.generation,
                capability,
                timeout,
            ) {
                Ok(probe) => {
                    let current = Record::load(&record_path)?;
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
                    if !self.local_holders.get(&record.id).is_some_and(|holder| {
                        holder.capability == capability && holder.child.is_some()
                    }) {
                        self.local_holders.insert(
                            record.id.clone(),
                            LocalHolder {
                                capability: capability.to_string(),
                                child: None,
                            },
                        );
                    }
                    return Ok(());
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
                    let current = Record::load(&record_path)?;
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

    fn local_holder_startup_grace_elapsed(&self, record: &Record) -> bool {
        let current_boot = crate::record::current_boot_time();
        if crate::record::is_prior_boot(record.boot_time, current_boot) {
            return true;
        }
        if record.boot_time.is_none()
            && current_boot.is_some_and(|boot| record.updated_at < boot.saturating_sub(5))
        {
            return true;
        }
        unix_time().saturating_sub(record.updated_at) >= LOCAL_HOLDER_STARTUP_GRACE_SECONDS
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
    pub fn maintenance(&mut self) {
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
        if self.last_maintenance.elapsed() < Duration::from_secs(30) {
            return;
        }
        self.last_maintenance = Instant::now();
        let now = unix_time();
        let mut local_probes = 0;
        let mut closed_paths = Vec::new();
        let mut snapshot_paths = Vec::new();
        if let Ok(entries) = fs::read_dir(&self.root) {
            for entry in entries.flatten() {
                let entry_path = entry.path();
                if entry_path.extension().is_some_and(|s| s == "closed") {
                    closed_paths.push(entry_path);
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
                        if !valid_id(&record.id) || self.workers.contains_key(&record.id) {
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
            if !valid_id(id) || self.workers.contains_key(id) || self.local_holders.contains_key(id)
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
        for closed_path in closed_paths {
            let Some(id) = closed_path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if !valid_id(id)
                || self.workers.contains_key(id)
                || self.local_holders.contains_key(id)
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
            let Ok(entries) = fs::read_dir(&sibling) else {
                continue;
            };
            for entry in entries.flatten() {
                let entry_path = entry.path();
                if entry_path.extension().is_some_and(|s| s == "json") {
                    if let Ok(record) = Record::load(&entry_path) {
                        if !valid_id(&record.id) {
                            continue;
                        }
                        if self.is_closed_in_any_root(&record.id) {
                            crate::server::remove_snapshot_files(&entry_path);
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
                    if self.is_closed_in_any_root(id) {
                        let _ = fs::remove_file(&entry_path);
                    } else if !sibling.join(format!("{id}.json")).exists()
                        && file_modified_unix(&entry_path).is_some_and(|m| {
                            now.saturating_sub(m) > LOCAL_HOLDER_STARTUP_GRACE_SECONDS
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
            if record.ended == Some(EndReason::Lost) {
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
        self.mode == RuntimeMode::Local || self.workers.is_empty()
    }

    pub fn is_local(&self) -> bool {
        self.mode == RuntimeMode::Local
    }
    pub fn list(&self) -> io::Result<Vec<Record>> {
        let mut records = vec![];
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if entry.path().extension().is_some_and(|s| s == "json") {
                if let Ok(r) = Record::load(&entry.path()) {
                    records.push(r);
                }
            }
        }
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
                inline_viewer: request.inline_viewer,
            },
        )
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
            inline_viewer,
        } = options;
        if !valid_id(id) {
            return Err(io::Error::other("invalid session identity"));
        }
        self.maintenance();
        if self.is_closed_in_any_root(id) {
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
                    cwd: None,
                    launch: local_launch,
                    resurrect_launch,
                    inline_viewer,
                },
            );
        }
        if self.workers.len() >= MAX_RUNNING {
            return Err(io::Error::other("active session quota exceeded"));
        }
        let mut argv = self.command.clone();
        let mut working_directory = None;
        let mut record = if path.exists() {
            let mut record = Record::load(&path)?;
            if record.ended.is_none() {
                record.pid = None;
                record.ended = Some(EndReason::Lost);
                record.save(&path)?;
            }
            if resume_generation != Some(record.generation.as_str())
                || !record.ended.is_some_and(EndReason::resumable)
            {
                return Err(io::Error::other(format!(
                    "session ended: {:?}; inspect its record before resuming",
                    record.ended
                )));
            }
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
        record.contained = self.containment_root.is_some();
        record.inline_viewer = inline_viewer;
        record.save(&path)?;
        // This host owns the runtime directory exclusively; stale sockets cannot
        // be a still-running worker. Remove only our validated session paths.
        let _ = fs::remove_file(&socket);
        let _ = fs::remove_file(socket.with_extension("evt"));
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

    fn resolve_resurrect_cwd(record: &Record, launch_cwd: Option<&str>, home: Option<&str>) -> String {
        let candidates = [
            record.cwd.as_deref(),
            record.resume.as_ref().map(|r| r.cwd.as_str()),
            launch_cwd,
            home,
        ];
        for candidate in candidates.into_iter().flatten() {
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

    fn resolve_shell_for_agent_resume(argv0: Option<&str>) -> String {
        if let Some(candidate) = argv0 {
            let base = Path::new(candidate)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("");
            if matches!(
                base,
                "zsh" | "bash" | "sh" | "dash" | "ksh" | "fish"
            ) {
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
                "\"$@\"; s=$OMG_FALLBACK_SHELL; unset OMG_FALLBACK_SHELL; exec \"$s\" -l"
                    .into(),
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
            None => {
                let shell = crate::user_login_shell();
                let env: BTreeMap<String, String> = std::env::vars()
                    .filter(|(k, v)| {
                        k.len() <= 256
                            && !k.contains('=')
                            && !k.contains('\0')
                            && !v.contains('\0')
                            && !k.starts_with("OMG_RUNTIME_")
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
        };
        let effective_home = spec
            .env
            .get("HOME")
            .cloned()
            .filter(|h| !h.is_empty() && Path::new(h).is_dir())
            .or_else(|| {
                std::env::var("HOME")
                    .ok()
                    .filter(|h| !h.is_empty() && Path::new(h).is_dir())
            });
        let resolved_cwd = Self::resolve_resurrect_cwd(
            record,
            spec.cwd.as_deref(),
            effective_home.as_deref(),
        );
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
            let shell_path = Self::resolve_shell_for_agent_resume(spec.argv.first().map(String::as_str));
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

    fn spawn_and_connect_local_holder(
        &mut self,
        id: &str,
        socket: &Path,
        path: &Path,
        record: &mut Record,
        launch: LocalLaunchSpec,
        resurrect: bool,
    ) -> io::Result<UnixStream> {
        let executable = std::env::current_exe()?;
        let request = crate::holder::HolderRequest {
            session_socket: socket.to_path_buf(),
            record_path: path.to_path_buf(),
            record: record.clone(),
            launch,
            resurrect,
        };
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let diagnostics_path = self.root.parent().unwrap().join("host.log");
        let diagnostics = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&diagnostics_path)?;
        fs::set_permissions(&diagnostics_path, fs::Permissions::from_mode(0o600))?;
        let child = match crate::holder::spawn(&executable, &request, Stdio::from(diagnostics)) {
            Ok(child) => child,
            Err(error) => {
                record.ended = Some(EndReason::Lost);
                let _ = record.save(path);
                return Err(error);
            }
        };
        self.local_holders.insert(
            id.into(),
            LocalHolder {
                capability: record.holder_capability.clone().unwrap(),
                child: Some(child),
            },
        );

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let holder_exited = self
                .local_holders
                .get_mut(id)
                .and_then(|holder| holder.child.as_mut())
                .map(Child::try_wait)
                .transpose()?
                .flatten()
                .is_some();
            if holder_exited {
                self.local_holders.remove(id);
                record.pid = None;
                record.ended = Some(EndReason::Lost);
                record.save(path)?;
                return Err(io::Error::other(
                    "local session holder exited during startup",
                ));
            }
            match crate::holder::probe(
                socket,
                id,
                &record.generation,
                record.holder_capability.as_deref().unwrap(),
            ) {
                Ok(status) if status.session_pid.is_some() => {
                    if let Ok(stream) = UnixStream::connect(socket) {
                        return Ok(stream);
                    }
                }
                _ => {}
            }
            if Instant::now() >= deadline {
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
        let launch = options.launch;
        let resurrect_launch = options.resurrect_launch;
        let existing_target = if path.exists() {
            Some((self.root.clone(), path.to_path_buf(), socket.to_path_buf()))
        } else if let Some(sibling_root) = self.find_sibling_local_session_root(id) {
            if sibling_root.join(format!("{id}.closed")).exists() {
                return Err(io::Error::other("session explicitly closed"));
            }
            let sibling_path = sibling_root.join(format!("{id}.json"));
            if sibling_path.exists() {
                let sibling_socket = Self::session_socket_in(&sibling_root, id);
                Some((sibling_root, sibling_path, sibling_socket))
            } else {
                if !create {
                    return Err(io::Error::other("unknown local session; cannot attach"));
                }
                if sibling_root.join(format!("{id}.created")).exists() {
                    return Err(io::Error::other(
                        "local session identity was already used; refusing to create a new shell",
                    ));
                }
                None
            }
        } else {
            None
        };
        if let Some((target_root, target_path, target_socket)) = existing_target {
            if self.is_closed_in_any_root(id) {
                return Err(io::Error::other("session explicitly closed"));
            }
            let mut record = Record::load(&target_path)?;
            if record.ended.is_none() {
                match self.probe_and_adopt_in(&target_root, &record, Duration::from_secs(1), true) {
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
                        let current = Record::load(&target_path)?;
                        if current.generation == record.generation && current.ended.is_some() {
                            record = current;
                        } else {
                            return Err(io::Error::other(format!(
                                "local session holder did not confirm ({:?}); session preserved",
                                error.kind()
                            )));
                        }
                    }
                }
            }
            let Some(ended) = record.ended else {
                return Err(io::Error::other("local session state unavailable"));
            };
            let resurrect_snapshot = if ended.local_resurrectable() {
                if let Some(expected_gen) = resume_generation {
                    if expected_gen != record.generation {
                        return Err(io::Error::other("local session generation mismatch"));
                    }
                }
                true
            } else if ended == EndReason::AgentCompleted && resume_generation.is_some() {
                if resume_generation != Some(record.generation.as_str()) {
                    return Err(io::Error::other("local session generation mismatch"));
                }
                false
            } else {
                return Err(io::Error::other(format!(
                    "local session ended: {:?}; it will not be recreated",
                    record.ended
                )));
            };
            if self.is_closed_in_any_root(id) {
                return Err(io::Error::other("session explicitly closed"));
            }
            let records = self.list()?;
            if records
                .iter()
                .filter(|r| r.id != id && r.ended.is_none())
                .count()
                >= MAX_RUNNING
            {
                return Err(io::Error::other("active session quota exceeded"));
            }
            let launch =
                Self::build_resurrect_launch(&record, resurrect_launch, !resurrect_snapshot)?;
            let migrated = target_root != self.root;
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
                }
                if resurrect_snapshot {
                    if let Some(snap_bytes) = Self::read_snapshot_file_bounded(&target_path) {
                        let _ = crate::server::save_snapshot_atomic(path, &snap_bytes);
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
            record.snapshot_revision = crate::current_snapshot_revision();
            record.save(path)?;
            if migrated {
                let _ = fs::remove_file(&target_path);
                crate::server::remove_snapshot_files(&target_path);
                let _ = fs::remove_file(target_root.join(format!("{id}.created")));
            }
            let _ = fs::remove_file(socket);
            let _ = fs::remove_file(socket.with_extension("evt"));
            let _ = fs::remove_file(crate::holder::control_path(socket));
            return self.spawn_and_connect_local_holder(
                id,
                socket,
                path,
                &mut record,
                launch,
                resurrect_snapshot,
            );
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
        let launch = launch
            .ok_or_else(|| io::Error::other("local session launch specification required"))?;
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
        record.inline_viewer = options.inline_viewer;
        record.holder_capability = Some(nonce()?);
        record.cwd = launch.cwd.clone();
        record.save(path)?;

        self.spawn_and_connect_local_holder(id, socket, path, &mut record, launch, false)
    }
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
        let mut inline = request;
        inline.inline_viewer = true;
        assert_eq!(serde_json::to_value(inline).unwrap()["inline_viewer"], true);
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
        let registry =
            Registry::new_local(root.join("sessions"), vec!["/bin/sh".into()], Policy::default());
        let now = unix_time();
        let cur_boot = crate::record::current_boot_time().unwrap();

        let mut prior_boot = Record::new("11111111-1111-1111-1111-111111111111", Policy::default()).unwrap();
        prior_boot.boot_time = Some(cur_boot.saturating_sub(60));
        prior_boot.updated_at = now;
        assert!(registry.local_holder_startup_grace_elapsed(&prior_boot));

        let mut legacy = Record::new("22222222-2222-2222-2222-222222222222", Policy::default()).unwrap();
        legacy.boot_time = None;
        legacy.updated_at = cur_boot.saturating_sub(60);
        assert!(registry.local_holder_startup_grace_elapsed(&legacy));

        let mut same_boot = Record::new("33333333-3333-3333-3333-333333333333", Policy::default()).unwrap();
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
        let mut remote =
            Registry::new(root.join("sessions"), vec!["/bin/sh".into()], Policy::default());
        let mut local =
            Registry::new_local(root.join("sessions"), vec!["/bin/sh".into()], Policy::default());

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

        let mut record = Record::new("99999999-9999-9999-9999-999999999999", Policy::default()).unwrap();
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

        let built = Registry::build_resurrect_launch(&record, Some(provide.clone()), false).unwrap();
        assert_eq!(built.cwd.as_deref(), Some(rec_dir.to_str().unwrap()));
        assert_eq!(built.env.get("OMG_FALLBACK_SHELL").map(String::as_str), Some("/bin/zsh"));
        assert_eq!(&built.argv[..4], ["/bin/zsh", "-l", "-i", "-c"]);
        assert_eq!(&built.argv[5..], ["omg-resurrect", "claude", "--resume", "conv-42"]);

        // Missing record.cwd + resume.cwd + launch.cwd falls through to HOME.
        record.cwd = Some("/tmp/missing-rec-cwd-xyz".into());
        let built_home = Registry::build_resurrect_launch(&record, Some(provide.clone()), false).unwrap();
        assert_eq!(built_home.cwd.as_deref(), Some(home.to_str().unwrap()));

        // Fish wrapper uses positional $argv without string interpolation.
        let mut fish_provide = launch(vec!["/opt/homebrew/bin/fish".into()], env);
        fish_provide.cwd = Some(home.to_string_lossy().into_owned());
        let fish_built = Registry::build_resurrect_launch(&record, Some(fish_provide), false).unwrap();
        assert_eq!(&fish_built.argv[..4], ["/opt/homebrew/bin/fish", "-l", "-i", "-c"]);
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
        fs::File::open(&orphan_snap).unwrap().set_modified(old_time).unwrap();

        let mut lost_record = Record::new(lost_id, Policy::default()).unwrap();
        lost_record.ended = Some(EndReason::Lost);
        lost_record.save(&sessions.join(format!("{lost_id}.json"))).unwrap();
        let lost_snap = sessions.join(format!("{lost_id}.snapshot"));
        fs::write(&lost_snap, b"keep-me").unwrap();

        registry.last_maintenance = Instant::now() - Duration::from_secs(31);
        registry.maintenance();

        assert!(!sessions.join(format!("{closed_id}.snapshot")).exists());
        assert!(!orphan_snap.exists());
        assert!(lost_snap.exists());
        fs::remove_dir_all(root).unwrap();
    }
}
