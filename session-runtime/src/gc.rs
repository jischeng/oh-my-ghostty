//! Safe, conservative remote garbage collection for stale runtime versions and
//! inactive run directories. Never removes active dirs, dirs with live
//! processes/sockets/unended sessions, or recently modified dirs.
use crate::{host, lifecycle::unix_time, record::Record, registry};
use std::{
    fs, io,
    os::{
        fd::AsRawFd,
        unix::{
            fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
            net::UnixStream,
        },
    },
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

pub const DEFAULT_MIN_AGE_SECONDS: u64 = 300;

#[derive(Clone, Debug)]
pub struct GcOptions {
    pub active_revision: Option<String>,
    pub active_state_dir: Option<PathBuf>,
    pub min_age_secs: u64,
    pub dry_run: bool,
}

impl Default for GcOptions {
    fn default() -> Self {
        Self {
            active_revision: None,
            active_state_dir: None,
            min_age_secs: DEFAULT_MIN_AGE_SECONDS,
            dry_run: false,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GcReport {
    pub removed_run_dirs: Vec<PathBuf>,
    pub removed_version_dirs: Vec<PathBuf>,
    pub skipped_busy: bool,
}

struct GcLock(fs::File);

impl GcLock {
    fn try_acquire(path: &Path) -> io::Result<Option<Self>> {
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc == 0 {
            Ok(Some(Self(file)))
        } else {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::WouldBlock
                || err.raw_os_error() == Some(libc::EWOULDBLOCK)
                || err.raw_os_error() == Some(libc::EAGAIN)
            {
                Ok(None)
            } else {
                Err(err)
            }
        }
    }
}

impl Drop for GcLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

fn is_private_owned_dir(path: &Path) -> bool {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return false;
    };
    meta.file_type().is_dir()
        && !meta.file_type().is_symlink()
        && meta.uid() == unsafe { libc::geteuid() }
        && (meta.mode() & 0o077) == 0
}

fn mtime_unix(path: &Path) -> Option<u64> {
    fs::symlink_metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

fn latest_mtime_shallow(dir: &Path, include_sessions: bool) -> Option<u64> {
    let mut latest = mtime_unix(dir)?;
    let entries = fs::read_dir(dir).ok()?;
    for entry in entries.take(4096).flatten() {
        let path = entry.path();
        if let Some(t) = mtime_unix(&path) {
            latest = latest.max(t);
        }
    }
    if include_sessions {
        let sessions = dir.join("sessions");
        if sessions.exists() {
            if let Some(t) = mtime_unix(&sessions) {
                latest = latest.max(t);
            }
            let Ok(entries) = fs::read_dir(&sessions) else {
                return None;
            };
            for entry in entries.take(4096).flatten() {
                if let Some(t) = mtime_unix(&entry.path()) {
                    latest = latest.max(t);
                }
            }
        }
    }
    Some(latest)
}

fn is_within_grace(latest_mtime: u64, now: u64, min_age_secs: u64) -> bool {
    if min_age_secs == 0 {
        return false;
    }
    now.saturating_sub(latest_mtime) < min_age_secs
}

fn lock_file_is_held(path: &Path) -> bool {
    let Ok(file) = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
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

fn pid_is_alive(pid: u32) -> bool {
    if pid <= 1 {
        return false;
    }
    let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if rc == 0 {
        return true;
    }
    io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

fn read_lock_pid(path: &Path) -> Option<u32> {
    let text = fs::read_to_string(path).ok()?;
    text.trim().parse::<u32>().ok().filter(|&p| p > 1)
}

struct LiveProcessSnapshot {
    entries: Vec<String>,
}

impl LiveProcessSnapshot {
    fn capture() -> Option<Self> {
        #[cfg(target_os = "linux")]
        {
            if let Some(snap) = Self::capture_linux_proc() {
                return Some(snap);
            }
        }
        Self::capture_ps()
    }

    #[cfg(target_os = "linux")]
    fn capture_linux_proc() -> Option<Self> {
        let uid = unsafe { libc::geteuid() };
        let proc_dir = fs::read_dir("/proc").ok()?;
        let mut entries = Vec::new();
        for entry in proc_dir.flatten() {
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            if !name.bytes().all(|b| b.is_ascii_digit()) {
                continue;
            }
            let pid_path = entry.path();
            let Ok(meta) = fs::symlink_metadata(&pid_path) else {
                continue;
            };
            if meta.uid() != uid {
                continue;
            }
            if let Ok(exe) = fs::read_link(pid_path.join("exe")) {
                let s = exe.to_string_lossy();
                let cleaned = s.strip_suffix(" (deleted)").unwrap_or(&s);
                entries.push(cleaned.to_owned());
            }
            if let Ok(bytes) = fs::read(pid_path.join("cmdline")) {
                if !bytes.is_empty() {
                    let text: String = bytes
                        .split(|&b| b == 0)
                        .filter(|s| !s.is_empty())
                        .map(|s| String::from_utf8_lossy(s))
                        .collect::<Vec<_>>()
                        .join(" ");
                    if !text.is_empty() {
                        entries.push(text);
                    }
                }
            }
        }
        Some(Self { entries })
    }

    fn capture_ps() -> Option<Self> {
        let uid = unsafe { libc::geteuid() }.to_string();
        let output = std::process::Command::new("/bin/ps")
            .args(["-u", &uid, "-o", "args="])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let entries = text
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect();
        Some(Self { entries })
    }

    fn references_path(&self, dir: &Path) -> bool {
        let mut needles = Vec::new();
        let raw = dir.to_string_lossy().into_owned();
        if !raw.is_empty() {
            needles.push(raw);
        }
        if let Ok(canon) = fs::canonicalize(dir) {
            let c = canon.to_string_lossy().into_owned();
            if !c.is_empty() && !needles.contains(&c) {
                needles.push(c);
            }
        }
        self.entries
            .iter()
            .any(|line| needles.iter().any(|needle| line.contains(needle.as_str())))
    }
}

fn run_dir_is_safe_to_remove(
    dir: &Path,
    active_state_dir: Option<&Path>,
    now: u64,
    min_age_secs: u64,
    procs: Option<&LiveProcessSnapshot>,
) -> bool {
    if !is_private_owned_dir(dir) {
        return false;
    }
    if active_state_dir.is_some_and(|active| registry::same_canonical_path(dir, active)) {
        return false;
    }
    let Some(latest) = latest_mtime_shallow(dir, true) else {
        return false;
    };
    if is_within_grace(latest, now, min_age_secs) {
        return false;
    }
    let host_lock = dir.join("host.lock");
    if lock_file_is_held(&host_lock) || lock_file_is_held(&dir.join("bootstrap.lock")) {
        return false;
    }
    if read_lock_pid(&host_lock).is_some_and(pid_is_alive) {
        return false;
    }
    if host::read_host_meta(dir).is_some_and(|meta| pid_is_alive(meta.pid)) {
        return false;
    }
    let host_sock = dir.join("host.sock");
    if host_sock.exists() && UnixStream::connect(&host_sock).is_ok() {
        return false;
    }
    // Check any session sockets or control sockets in the run dir.
    let Ok(top_entries) = fs::read_dir(dir) else {
        return false;
    };
    for entry in top_entries.take(4096).flatten() {
        let path = entry.path();
        if path
            .extension()
            .is_some_and(|ext| ext == "sock" || ext == "ctl")
            && UnixStream::connect(&path).is_ok()
        {
            return false;
        }
    }
    let sessions_dir = dir.join("sessions");
    if sessions_dir.exists() {
        if !is_private_owned_dir(&sessions_dir) {
            return false;
        }
        let Ok(entries) = fs::read_dir(&sessions_dir) else {
            return false;
        };
        for entry in entries.take(4096).flatten() {
            let path = entry.path();
            if path
                .extension()
                .is_some_and(|ext| ext == "sock" || ext == "ctl")
                && UnixStream::connect(&path).is_ok()
            {
                return false;
            }
            if path.extension().is_some_and(|ext| ext == "json") {
                let Ok(record) = Record::load(&path) else {
                    // Unreadable or mid-write record: preserve conservatively.
                    return false;
                };
                if record.ended.is_none() {
                    return false;
                }
                if record.pid.is_some_and(pid_is_alive) {
                    return false;
                }
            }
        }
    }
    if let Some(procs) = procs {
        if procs.references_path(dir) {
            return false;
        }
    }
    true
}

struct RemainingRunRefs {
    dir_names: std::collections::HashSet<String>,
    metas: Vec<host::HostIdentity>,
}

fn collect_remaining_run_references(run_root: &Path) -> RemainingRunRefs {
    let mut dir_names = std::collections::HashSet::new();
    let mut metas = Vec::new();
    let Ok(entries) = fs::read_dir(run_root) else {
        return RemainingRunRefs { dir_names, metas };
    };
    for entry in entries.take(4096).flatten() {
        let path = entry.path();
        if !is_private_owned_dir(&path) {
            continue;
        }
        if let Some(name) = entry.file_name().to_str() {
            dir_names.insert(name.to_owned());
        }
        if let Some(meta) = host::read_host_meta(&path) {
            metas.push(meta);
        }
    }
    RemainingRunRefs { dir_names, metas }
}

fn version_dir_is_safe_to_remove(
    dir: &Path,
    rev: &str,
    active_revision: Option<&str>,
    now: u64,
    min_age_secs: u64,
    remaining: &RemainingRunRefs,
    procs: &LiveProcessSnapshot,
) -> bool {
    if !crate::valid_revision(rev) || !is_private_owned_dir(dir) {
        return false;
    }
    if active_revision == Some(rev) {
        return false;
    }
    let Some(latest) = latest_mtime_shallow(dir, false) else {
        return false;
    };
    if is_within_grace(latest, now, min_age_secs) {
        return false;
    }
    use sha2::{Digest, Sha256};
    let legacy_key = format!("{:x}", Sha256::digest(rev.as_bytes()));
    if remaining.dir_names.contains(&legacy_key[..12]) {
        return false;
    }
    if remaining.metas.iter().any(|meta| {
        meta.revision == rev
            || meta
                .executable
                .as_deref()
                .is_some_and(|exe| Path::new(exe).starts_with(dir))
    }) {
        return false;
    }
    if procs.references_path(dir) {
        return false;
    }
    true
}

pub fn gc_remote_in(
    versions_root: &Path,
    run_root: &Path,
    options: &GcOptions,
) -> io::Result<GcReport> {
    let lock_parent = if is_private_owned_dir(run_root) {
        run_root
    } else if versions_root.parent().is_some_and(is_private_owned_dir) {
        versions_root.parent().unwrap()
    } else {
        return Ok(GcReport::default());
    };
    let Some(_lock) = GcLock::try_acquire(&lock_parent.join(".gc.lock"))? else {
        return Ok(GcReport {
            skipped_busy: true,
            ..Default::default()
        });
    };

    let now = unix_time();
    let procs = LiveProcessSnapshot::capture();
    let mut report = GcReport::default();

    // Pass 1: Reap dead, stale run directories under run_root.
    if is_private_owned_dir(run_root) {
        if let Ok(entries) = fs::read_dir(run_root) {
            let mut dirs: Vec<PathBuf> = entries
                .take(4096)
                .flatten()
                .filter(|e| {
                    e.file_name()
                        .to_str()
                        .is_some_and(|name| !name.starts_with('.'))
                })
                .map(|e| e.path())
                .collect();
            dirs.sort();
            for dir in dirs {
                if run_dir_is_safe_to_remove(
                    &dir,
                    options.active_state_dir.as_deref(),
                    now,
                    options.min_age_secs,
                    procs.as_ref(),
                ) {
                    if !options.dry_run {
                        if fs::remove_dir_all(&dir).is_ok() {
                            report.removed_run_dirs.push(dir);
                        }
                    } else {
                        report.removed_run_dirs.push(dir);
                    }
                }
            }
        }
    }

    // Pass 2: Reap unreferenced, stale version directories under versions_root.
    // Only delete version directories when we have a verified live-process snapshot.
    if let Some(ref procs) = procs {
        if is_private_owned_dir(versions_root) {
            let remaining = collect_remaining_run_references(run_root);
            if let Ok(entries) = fs::read_dir(versions_root) {
                let mut dirs: Vec<(String, PathBuf)> = entries
                    .take(4096)
                    .flatten()
                    .filter_map(|e| {
                        let name = e.file_name().to_str()?.to_owned();
                        if name.starts_with('.') {
                            return None;
                        }
                        Some((name, e.path()))
                    })
                    .collect();
                dirs.sort_by(|a, b| a.0.cmp(&b.0));
                for (rev, dir) in dirs {
                    if version_dir_is_safe_to_remove(
                        &dir,
                        &rev,
                        options.active_revision.as_deref(),
                        now,
                        options.min_age_secs,
                        &remaining,
                        procs,
                    ) {
                        if !options.dry_run {
                            if fs::remove_dir_all(&dir).is_ok() {
                                report.removed_version_dirs.push(dir);
                            }
                        } else {
                            report.removed_version_dirs.push(dir);
                        }
                    }
                }
            }
        }
    }

    Ok(report)
}

pub fn gc_remote_default(options: &GcOptions) -> io::Result<GcReport> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .ok_or_else(|| io::Error::other("HOME must be an absolute directory"))?;
    let versions_root = home.join(".local/share/oh-my-ghostty/session-runtime/versions");
    let run_root = home.join(".omg/run");
    gc_remote_in(&versions_root, &run_root, options)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lifecycle::{EndReason, Policy};

    fn private_dir(path: &Path) {
        fs::create_dir_all(path).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn gc_reaps_dead_dirs_and_preserves_active_live_unended_and_recent_dirs() {
        let base = PathBuf::from(format!(
            "/tmp/omg-gc-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        let versions = base.join("versions");
        let run_root = base.join("run");
        private_dir(&base);
        private_dir(&versions);
        private_dir(&run_root);

        // 1. Active state dir + active version dir -> MUST preserve.
        let active_run = run_root.join("s-active111111");
        private_dir(&active_run);
        private_dir(&active_run.join("sessions"));
        let active_ver = versions.join("rev-active");
        private_dir(&active_ver);

        // 2. Dead stale run dir (ended session, no lock, no socket) -> MUST reap.
        let dead_run = run_root.join("dead12345678");
        private_dir(&dead_run);
        private_dir(&dead_run.join("sessions"));
        let mut ended_rec =
            Record::new("11111111-1111-1111-1111-111111111111", Policy::default()).unwrap();
        ended_rec.ended = Some(EndReason::ProcessExited);
        ended_rec.pid = None;
        ended_rec
            .save(&dead_run.join("sessions/11111111-1111-1111-1111-111111111111.json"))
            .unwrap();

        // 3. Run dir with an unended session -> MUST preserve!
        let unended_run = run_root.join("unended12345");
        private_dir(&unended_run);
        private_dir(&unended_run.join("sessions"));
        let mut live_rec =
            Record::new("22222222-2222-2222-2222-222222222222", Policy::default()).unwrap();
        live_rec.ended = None;
        live_rec
            .save(&unended_run.join("sessions/22222222-2222-2222-2222-222222222222.json"))
            .unwrap();

        // 4. Run dir with a live host.sock listener -> MUST preserve!
        let live_sock_run = run_root.join("livesock1234");
        private_dir(&live_sock_run);
        let _listener =
            std::os::unix::net::UnixListener::bind(live_sock_run.join("host.sock")).unwrap();

        // 5. Dead stale version dir (no remaining run dir, no live process) -> MUST reap.
        let dead_ver = versions.join("rev-stale-old");
        private_dir(&dead_ver);
        fs::write(dead_ver.join("verified"), "rev-stale-old\n").unwrap();

        // 6. Legacy version dir whose legacy hash run dir still exists (unended) -> MUST preserve!
        let legacy_rev = "rev-legacy-live";
        use sha2::{Digest, Sha256};
        let legacy_key = format!("{:x}", Sha256::digest(legacy_rev.as_bytes()));
        let legacy_run = run_root.join(&legacy_key[..12]);
        private_dir(&legacy_run);
        private_dir(&legacy_run.join("sessions"));
        let mut legacy_rec =
            Record::new("33333333-3333-3333-3333-333333333333", Policy::default()).unwrap();
        legacy_rec.ended = None;
        legacy_rec
            .save(&legacy_run.join("sessions/33333333-3333-3333-3333-333333333333.json"))
            .unwrap();
        let legacy_ver = versions.join(legacy_rev);
        private_dir(&legacy_ver);

        // First run with default 300s grace window: everything is brand new -> NOTHING reaped!
        let grace_report = gc_remote_in(
            &versions,
            &run_root,
            &GcOptions {
                active_revision: Some("rev-active".into()),
                active_state_dir: Some(active_run.clone()),
                min_age_secs: 300,
                dry_run: false,
            },
        )
        .unwrap();
        assert!(grace_report.removed_run_dirs.is_empty());
        assert!(grace_report.removed_version_dirs.is_empty());
        assert!(dead_run.exists());
        assert!(dead_ver.exists());

        // Now run with min_age_secs = 0: only dead_run and dead_ver should be reaped!
        let report = gc_remote_in(
            &versions,
            &run_root,
            &GcOptions {
                active_revision: Some("rev-active".into()),
                active_state_dir: Some(active_run.clone()),
                min_age_secs: 0,
                dry_run: false,
            },
        )
        .unwrap();
        assert!(!report.skipped_busy);
        assert_eq!(report.removed_run_dirs, vec![dead_run.clone()]);
        assert_eq!(report.removed_version_dirs, vec![dead_ver.clone()]);
        assert!(!dead_run.exists());
        assert!(!dead_ver.exists());
        assert!(active_run.exists());
        assert!(active_ver.exists());
        assert!(unended_run.exists());
        assert!(live_sock_run.exists());
        assert!(legacy_run.exists());
        assert!(legacy_ver.exists());

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn gc_skips_when_lock_is_busy() {
        let base = PathBuf::from(format!(
            "/tmp/omg-gcl-{}",
            &crate::record::nonce().unwrap()[..8]
        ));
        let versions = base.join("versions");
        let run_root = base.join("run");
        private_dir(&base);
        private_dir(&versions);
        private_dir(&run_root);
        let dead_run = run_root.join("dead99999999");
        private_dir(&dead_run);

        let _held = GcLock::try_acquire(&run_root.join(".gc.lock"))
            .unwrap()
            .unwrap();
        let report = gc_remote_in(
            &versions,
            &run_root,
            &GcOptions {
                active_revision: None,
                active_state_dir: None,
                min_age_secs: 0,
                dry_run: false,
            },
        )
        .unwrap();
        assert!(report.skipped_busy);
        assert!(report.removed_run_dirs.is_empty());
        assert!(dead_run.exists());

        drop(_held);
        fs::remove_dir_all(&base).unwrap();
    }
}
