use crate::*;
use crate::{
    lifecycle::{unix_time, EndReason, Lifetime},
    record::{nonce, AgentEvent, Record},
    registry::LocalLaunchSpec,
};
use std::{
    collections::HashSet,
    ffi::{c_void, CStr},
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
            net::{UnixDatagram, UnixListener},
            process::CommandExt,
        },
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering},
    time::{Duration, Instant},
};
static PTY_SPAWN: std::sync::Mutex<()> = std::sync::Mutex::new(());
static SHUTDOWN_SIGNALED: AtomicBool = AtomicBool::new(false);
static SHUTDOWN_WAKE_FD: AtomicI32 = AtomicI32::new(-1);
static SNAPSHOT_TMP_SEQ: AtomicU64 = AtomicU64::new(0);

const SNAPSHOT_MAGIC: &[u8] = b"OMGSNAP1\0";
const SNAPSHOT_DEBOUNCE: Duration = Duration::from_secs(3);
const SNAPSHOT_MAX_INTERVAL: Duration = Duration::from_secs(30);
const SNAPSHOT_RETRY_INITIAL: Duration = Duration::from_secs(3);
// Exit alternate screen (?1049l) only when actually on the alternate screen so
// DECRC inside ?1049l never rewinds the primary-screen cursor over saved rows.
const HYGIENE_RESET: &str =
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[>0u\x1b]8;;\x1b\\\x1b[0m";

extern "C" fn handle_shutdown_signal(_sig: libc::c_int) {
    SHUTDOWN_SIGNALED.store(true, Ordering::SeqCst);
    let fd = SHUTDOWN_WAKE_FD.load(Ordering::SeqCst);
    if fd >= 0 {
        let byte: u8 = 1;
        unsafe {
            let _ = libc::write(fd, (&byte as *const u8).cast(), 1);
        }
    }
}

pub fn shutdown_signaled() -> bool {
    SHUTDOWN_SIGNALED.load(Ordering::SeqCst)
}

pub struct ShutdownSignalGuard {
    previous: libc::sigaction,
}

impl ShutdownSignalGuard {
    pub(crate) fn install(wake: &crate::WakePipe) -> io::Result<Self> {
        SHUTDOWN_SIGNALED.store(false, Ordering::SeqCst);
        SHUTDOWN_WAKE_FD.store(wake.writer_raw_fd(), Ordering::SeqCst);
        let mut sa: libc::sigaction = unsafe { std::mem::zeroed() };
        sa.sa_sigaction = handle_shutdown_signal as *const () as usize;
        sa.sa_flags = 0;
        unsafe { libc::sigemptyset(&mut sa.sa_mask) };
        let mut previous: libc::sigaction = unsafe { std::mem::zeroed() };
        if unsafe { libc::sigaction(libc::SIGTERM, &sa, &mut previous) } < 0 {
            SHUTDOWN_WAKE_FD.store(-1, Ordering::SeqCst);
            return Err(io::Error::last_os_error());
        }
        Ok(Self { previous })
    }
}

impl Drop for ShutdownSignalGuard {
    fn drop(&mut self) {
        unsafe {
            let _ = libc::sigaction(libc::SIGTERM, &self.previous, std::ptr::null_mut());
        }
        SHUTDOWN_WAKE_FD.store(-1, Ordering::SeqCst);
        SHUTDOWN_SIGNALED.store(false, Ordering::SeqCst);
    }
}

pub fn snapshot_path(record_path: &Path) -> PathBuf {
    record_path.with_extension("snapshot")
}

pub fn remove_snapshot_files(record_path: &Path) {
    let _ = fs::remove_file(snapshot_path(record_path));
}

pub fn encode_snapshot(vt: &Vt, revision: Option<&str>) -> io::Result<Vec<u8>> {
    let raw = vt.snapshot()?;
    let rev = revision.unwrap_or("");
    let total = SNAPSHOT_MAGIC.len() + rev.len() + 1 + raw.len();
    if total > MAX_FRAME {
        return Err(io::Error::other("VT snapshot exceeds MAX_FRAME"));
    }
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(SNAPSHOT_MAGIC);
    out.extend_from_slice(rev.as_bytes());
    out.push(0);
    out.extend_from_slice(&raw);
    Ok(out)
}

pub fn save_snapshot_atomic(record_path: &Path, data: &[u8]) -> io::Result<()> {
    if data.len() > MAX_FRAME {
        return Err(io::Error::other("VT snapshot exceeds MAX_FRAME"));
    }
    let snap = snapshot_path(record_path);
    let closed = record_path.with_extension("closed");
    if closed.exists() {
        let _ = fs::remove_file(&snap);
        return Ok(());
    }
    let seq = SNAPSHOT_TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = record_path.with_extension(format!("snapshot.tmp.{}.{seq}", std::process::id()));
    let _ = fs::remove_file(&tmp);
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)?;
    let write_res = file.write_all(data).and_then(|()| file.sync_all());
    drop(file);
    if let Err(err) = write_res {
        let _ = fs::remove_file(&tmp);
        return Err(err);
    }
    if closed.exists() {
        let _ = fs::remove_file(&tmp);
        let _ = fs::remove_file(&snap);
        return Ok(());
    }
    if let Err(err) = fs::rename(&tmp, &snap) {
        let _ = fs::remove_file(&tmp);
        return Err(err);
    }
    Ok(())
}

pub fn load_snapshot(record_path: &Path, record_revision: Option<&str>) -> Option<Vec<u8>> {
    let snap = snapshot_path(record_path);
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&snap)
        .ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > MAX_FRAME as u64 {
        return None;
    }
    let mut buf = Vec::with_capacity((meta.len() as usize).min(MAX_FRAME));
    file.take((MAX_FRAME + 1) as u64)
        .read_to_end(&mut buf)
        .ok()?;
    if buf.is_empty() || buf.len() > MAX_FRAME {
        return None;
    }
    let expected_rev = crate::current_snapshot_revision();
    if let Some(after_magic) = buf.strip_prefix(SNAPSHOT_MAGIC) {
        let nul = after_magic.iter().position(|&b| b == 0)?;
        if nul > 128 {
            return None;
        }
        let header_rev = std::str::from_utf8(&after_magic[..nul]).ok()?;
        let vt_bytes = &after_magic[nul + 1..];
        if vt_bytes.is_empty() {
            return None;
        }
        if let Some(expected) = expected_rev.as_deref() {
            let candidate = if header_rev.is_empty() {
                record_revision.map(crate::canonical_snapshot_revision)
            } else {
                Some(crate::canonical_snapshot_revision(header_rev))
            };
            if candidate != Some(expected) {
                return None;
            }
        }
        return Some(vt_bytes.to_vec());
    }
    if let Some(expected) = expected_rev.as_deref() {
        if record_revision.map(crate::canonical_snapshot_revision) != Some(expected) {
            return None;
        }
    }
    Some(buf)
}

struct SnapshotSchedule {
    output_dirty_rev: u64,
    last_persisted_rev: u64,
    last_output_at: Instant,
    last_snapshot_at: Instant,
    retry_after: Option<Instant>,
    consecutive_failures: u32,
}

impl SnapshotSchedule {
    fn new(now: Instant) -> Self {
        Self {
            output_dirty_rev: 0,
            last_persisted_rev: 0,
            last_output_at: now,
            last_snapshot_at: now,
            retry_after: None,
            consecutive_failures: 0,
        }
    }

    fn mark_dirty(&mut self, now: Instant) {
        self.output_dirty_rev = self.output_dirty_rev.wrapping_add(1);
        self.last_output_at = now;
    }

    fn is_dirty(&self) -> bool {
        self.output_dirty_rev != self.last_persisted_rev
    }

    fn next_deadline(&self) -> Option<Instant> {
        if !self.is_dirty() {
            return None;
        }
        let base_due = (self.last_output_at + SNAPSHOT_DEBOUNCE)
            .min(self.last_snapshot_at + SNAPSHOT_MAX_INTERVAL);
        Some(match self.retry_after {
            Some(retry_at) => base_due.max(retry_at),
            None => base_due,
        })
    }

    fn should_flush(&self, now: Instant) -> bool {
        self.next_deadline().is_some_and(|deadline| now >= deadline)
    }

    fn record_persisted(&mut self, rev: u64, now: Instant) {
        self.last_persisted_rev = rev;
        self.last_snapshot_at = now;
        self.retry_after = None;
        self.consecutive_failures = 0;
    }

    fn record_failure(&mut self, now: Instant) {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        let shift = self.consecutive_failures.saturating_sub(1).min(4);
        let backoff = SNAPSHOT_RETRY_INITIAL
            .saturating_mul(1u32 << shift)
            .min(SNAPSHOT_MAX_INTERVAL);
        self.last_snapshot_at = now;
        self.retry_after = Some(now + backoff);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RecordSlotDisposition {
    Owned,
    AlreadyReconciled,
    Superseded,
}

fn record_slot_disposition(m: &ManagedSession, orphaned: bool) -> RecordSlotDisposition {
    match Record::load(&m.path) {
        Ok(on_disk) => {
            if on_disk.id != m.record.id || on_disk.generation != m.record.generation {
                RecordSlotDisposition::Superseded
            } else if orphaned && on_disk.ended.is_some() {
                RecordSlotDisposition::AlreadyReconciled
            } else {
                RecordSlotDisposition::Owned
            }
        }
        Err(_) => RecordSlotDisposition::Owned,
    }
}

fn file_identity(path: &Path) -> Option<(u64, u64)> {
    fs::symlink_metadata(path)
        .ok()
        .map(|meta| (meta.dev(), meta.ino()))
}

fn socket_missing_or_replaced(path: &Path, expected: Option<(u64, u64)>) -> bool {
    let Some(expected_id) = expected else {
        return false;
    };
    match fs::symlink_metadata(path) {
        Ok(meta) => (meta.dev(), meta.ino()) != expected_id,
        Err(err) => err.kind() == io::ErrorKind::NotFound,
    }
}

fn flush_vt_snapshot(vt: &Vt, managed: Option<&ManagedSession>, schedule: &mut SnapshotSchedule) {
    let dirty_rev = schedule.output_dirty_rev;
    let Some(m) = managed else {
        schedule.record_persisted(dirty_rev, Instant::now());
        return;
    };
    if m.path.with_extension("closed").exists() {
        if record_slot_disposition(m, false) == RecordSlotDisposition::Owned {
            remove_snapshot_files(&m.path);
        }
        schedule.record_persisted(dirty_rev, Instant::now());
        return;
    }
    if record_slot_disposition(m, false) == RecordSlotDisposition::Superseded {
        schedule.record_persisted(dirty_rev, Instant::now());
        return;
    }
    let revision = crate::current_snapshot_revision();
    let encoded = match encode_snapshot(vt, revision.as_deref()) {
        Ok(bytes) => bytes,
        Err(_) => {
            schedule.record_failure(Instant::now());
            return;
        }
    };
    if save_snapshot_atomic(&m.path, &encoded).is_ok() {
        schedule.record_persisted(dirty_rev, Instant::now());
    } else {
        schedule.record_failure(Instant::now());
    }
}

fn format_local_timestamp() -> String {
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        if !libc::localtime_r(&now, &mut tm).is_null() {
            return format!(
                "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
                tm.tm_year + 1900,
                tm.tm_mon + 1,
                tm.tm_mday,
                tm.tm_hour,
                tm.tm_min,
                tm.tm_sec
            );
        }
    }
    unix_time().to_string()
}
struct ReplyBuffer {
    bytes: VecDeque<u8>,
    delegated: bool,
    unclaimed: VecDeque<u8>,
    awaiting_writer: bool,
}
impl ReplyBuffer {
    fn new(bytes: VecDeque<u8>, delegated: bool) -> Self {
        Self {
            bytes,
            delegated,
            unclaimed: VecDeque::new(),
            awaiting_writer: delegated,
        }
    }
    fn claim(&mut self, delegated: bool) {
        self.delegated = delegated;
        self.awaiting_writer = false;
        if !delegated {
            self.bytes.append(&mut self.unclaimed);
        }
        self.unclaimed.clear();
    }
}
impl std::ops::Deref for ReplyBuffer {
    type Target = VecDeque<u8>;
    fn deref(&self) -> &Self::Target {
        &self.bytes
    }
}
impl std::ops::DerefMut for ReplyBuffer {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.bytes
    }
}
struct OutputScreen<'a> {
    vt: &'a mut Vt,
    replies: *const ReplyBuffer,
}
impl crate::terminal_output::Screen for OutputScreen<'_> {
    fn write(&mut self, bytes: &[u8]) {
        self.vt.write(bytes);
    }
    fn pending_responses(&self) -> usize {
        unsafe { (&*self.replies).len() }
    }
}

extern "C" fn reply(context: *mut c_void, data: *const u8, len: usize) {
    let queue = unsafe { &mut *(context as *mut ReplyBuffer) };
    if queue.delegated {
        if queue.awaiting_writer && queue.unclaimed.len() + len <= 64 * 1024 {
            queue
                .unclaimed
                .extend(unsafe { std::slice::from_raw_parts(data, len) });
        }
    } else if queue.len() + len <= 1024 * 1024 {
        queue.extend(unsafe { std::slice::from_raw_parts(data, len) });
    }
}
fn terminate_group(master: i32, leader: u32, signal: i32) {
    unsafe {
        let foreground = libc::tcgetpgrp(master);
        // Foreground jobs may be a different process group from the login shell.
        if foreground > 1
            && foreground != leader as i32
            && libc::getsid(foreground) == leader as i32
        {
            libc::kill(-foreground, signal);
        }
        if libc::getsid(leader as i32) == leader as i32 {
            libc::kill(-(leader as i32), signal);
        }
    }
}

fn foreground_session_group(master: i32, leader: u32) -> Option<u64> {
    let foreground = unsafe { libc::tcgetpgrp(master) };
    if foreground <= 1 || unsafe { libc::getsid(foreground) } != leader as i32 {
        return None;
    }
    Some(foreground as u64)
}

fn terminal_name(fd: i32) -> Option<String> {
    let mut buffer = [0 as libc::c_char; 4096];
    if unsafe { libc::ttyname_r(fd, buffer.as_mut_ptr(), buffer.len()) } != 0 {
        return None;
    }
    let value = unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_str().ok()?;
    (value.starts_with("/dev/") && value.len() <= 4096).then(|| value.to_string())
}

fn password_input(master: i32) -> bool {
    let mut settings = unsafe { std::mem::zeroed::<libc::termios>() };
    if unsafe { libc::tcgetattr(master, &mut settings) } != 0 {
        return false;
    }
    settings.c_lflag & libc::ICANON != 0 && settings.c_lflag & libc::ECHO == 0
}

fn enable_utf8_input(master: i32) -> io::Result<()> {
    let mut settings = unsafe { std::mem::zeroed::<libc::termios>() };
    if unsafe { libc::tcgetattr(master, &mut settings) } != 0 {
        return Err(io::Error::last_os_error());
    }
    settings.c_iflag |= libc::IUTF8;
    if unsafe { libc::tcsetattr(master, libc::TCSANOW, &settings) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn runtime_millis(started: Instant) -> u64 {
    started.elapsed().as_millis().min(u64::MAX as u128) as u64
}

fn resize_dimensions(data: &[u8]) -> Option<(u16, u16, u16, u16)> {
    match data.len() {
        4 => {
            let cols = u16::from_be_bytes(data[..2].try_into().ok()?);
            let rows = u16::from_be_bytes(data[2..4].try_into().ok()?);
            Some((cols, rows, cols.saturating_mul(8), rows.saturating_mul(16)))
        }
        8 => Some((
            u16::from_be_bytes(data[..2].try_into().ok()?),
            u16::from_be_bytes(data[2..4].try_into().ok()?),
            u16::from_be_bytes(data[4..6].try_into().ok()?),
            u16::from_be_bytes(data[6..8].try_into().ok()?),
        )),
        _ => None,
    }
}

fn peer_wants_write(peer: &Peer) -> bool {
    peer.wants_write()
}

fn pty_poll_interests(eof: bool, input_pending: bool) -> libc::c_short {
    if eof {
        return 0;
    }
    libc::POLLIN | if input_pending { libc::POLLOUT } else { 0 }
}

fn queue_snapshot(peer: &mut Peer, seq: u64, snapshot: io::Result<Vec<u8>>) -> bool {
    match snapshot {
        Ok(bytes) if bytes.len() <= MAX_FRAME => {
            peer.push(Frame::new(SNAPSHOT, seq, &bytes));
            peer.ack = Some(seq);
            true
        }
        Ok(_) => {
            peer.push(Frame::new(
                b'E',
                seq,
                b"terminal snapshot exceeds the protocol size limit",
            ));
            false
        }
        Err(_) => {
            peer.push(Frame::new(b'E', seq, b"terminal snapshot is unavailable"));
            false
        }
    }
}

struct ChildGuard(Child);
impl std::ops::Deref for ChildGuard {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.0
    }
}
impl std::ops::DerefMut for ChildGuard {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.0
    }
}
impl Drop for ChildGuard {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(Some(_))) {
            unsafe {
                libc::kill(-(self.0.id() as i32), libc::SIGKILL);
            }
            let _ = self.0.wait();
        }
    }
}
struct SocketGuard {
    path: PathBuf,
    identity: Option<(u64, u64)>,
}

impl SocketGuard {
    fn new(path: PathBuf) -> Self {
        let identity = file_identity(&path);
        Self { path, identity }
    }

    fn remove_now(&mut self) {
        let should_remove = match (self.identity, file_identity(&self.path)) {
            (Some(expected), Some(current)) => current == expected,
            (None, Some(_)) => true,
            (_, None) => false,
        };
        if should_remove {
            let _ = fs::remove_file(&self.path);
        }
        self.identity = Some((u64::MAX, u64::MAX));
    }
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        self.remove_now();
    }
}

fn sniff_remote_cwd(bytes: &[u8], current: &mut Option<String>) {
    let mut i = 0;
    while i + 4 < bytes.len() {
        if bytes[i] == 0x1b && bytes[i + 1] == b']' {
            let mut end = i + 2;
            while end < bytes.len()
                && bytes[end] != 0x07
                && !(bytes[end] == 0x1b && end + 1 < bytes.len() && bytes[end + 1] == b'\\')
            {
                end += 1;
            }
            if end < bytes.len() {
                if let Ok(osc) = std::str::from_utf8(&bytes[i + 2..end]) {
                    if let Some(rest) = osc.strip_prefix("7;") {
                        let url = rest.trim();
                        if let Some(after_scheme) = url
                            .strip_prefix("file://")
                            .or_else(|| url.strip_prefix("kitty-shell-cwd://"))
                        {
                            if let Some(slash) = after_scheme.find('/') {
                                let raw_path = &after_scheme[slash..];
                                if !raw_path.is_empty() && raw_path.len() <= 4096 {
                                    *current = Some(raw_path.to_owned());
                                }
                            }
                        }
                    } else if let Some(title) =
                        osc.strip_prefix("0;").or_else(|| osc.strip_prefix("2;"))
                    {
                        if let Some((prefix, candidate)) = title.rsplit_once(':') {
                            let prefix = prefix.trim();
                            let candidate = candidate.trim();
                            if !prefix.is_empty()
                                && (candidate == "~"
                                    || candidate.starts_with("~/")
                                    || candidate.starts_with('/'))
                                && candidate.len() <= 4096
                                && !candidate.chars().any(char::is_control)
                            {
                                *current = Some(candidate.to_owned());
                            }
                        }
                    }
                }
            }
            i = end + 1;
        } else {
            i += 1;
        }
    }
}

fn resolve_session_ssh(
    master: i32,
    leader: u32,
    vt: &Vt,
    sniffed_cwd: &mut Option<String>,
) -> Option<crate::location::SshTarget> {
    let mut target = crate::location::session_ssh(master, leader).or_else(|| {
        vt.activity()
            .remote_host()
            .map(|host| crate::location::SshTarget {
                destination: host.to_owned(),
                options: Vec::new(),
                remote_cwd: None,
            })
    });
    if let Some(ref mut ssh) = target {
        if let Some(cwd) = vt.activity().remote_cwd() {
            ssh.remote_cwd = Some(cwd.to_owned());
        } else if let Some(cwd) = sniffed_cwd.as_ref() {
            ssh.remote_cwd = Some(cwd.clone());
        }
    } else {
        *sniffed_cwd = None;
    }
    target
}
/// Prototype intentionally has one session, created explicitly at daemon startup.
/// Disconnect never touches the PTY; only Close or child exit ends the session.
pub fn serve(path: &Path, argv: &[String]) -> io::Result<()> {
    serve_managed(path, argv.to_vec(), None)
}

pub struct ManagedSession {
    pub path: PathBuf,
    pub record: Record,
    pub containment_root: Option<PathBuf>,
    pub initial_cwd: Option<PathBuf>,
    pub local_launch: Option<LocalLaunchSpec>,
    pub presentation: Option<std::sync::Arc<std::sync::Mutex<crate::activity::Snapshot>>>,
    pub resurrect: bool,
    pub shutdown_wake: Option<crate::WakePipe>,
}

pub fn serve_managed(
    path: &Path,
    argv: Vec<String>,
    mut managed: Option<ManagedSession>,
) -> io::Result<()> {
    let policy = managed
        .as_ref()
        .map(|m| m.record.policy.clone())
        .unwrap_or_default();
    policy.validate()?;
    let token = nonce()?;
    let event_path = path.with_extension("evt");
    if argv.is_empty() {
        return Err(io::Error::other("missing command"));
    }
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("socket needs private directory"))?;
    let meta = fs::symlink_metadata(parent)?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        return Err(io::Error::other(
            "socket directory must be owned by current user with mode 0700",
        ));
    }
    let events = UnixDatagram::bind(&event_path)?;
    let _event_guard = SocketGuard::new(event_path.clone());
    fs::set_permissions(&event_path, fs::Permissions::from_mode(0o600))?;
    events.set_nonblocking(true)?;
    let listener = UnixListener::bind(path)?;
    let mut socket_guard = SocketGuard::new(path.to_owned());
    let bound_socket_id = socket_guard.identity;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let mut listener = Some(listener);
    // openpty cannot atomically set CLOEXEC. Serialize every session spawn
    // across that small window so another shell cannot inherit these FDs.
    let spawn_guard = PTY_SPAWN
        .lock()
        .map_err(|_| io::Error::other("PTY spawn lock poisoned"))?;
    let mut master = -1;
    let mut slave = -1;
    let mut local_launch = managed.as_mut().and_then(|value| value.local_launch.take());
    let shutdown_wake = managed
        .as_mut()
        .and_then(|value| value.shutdown_wake.take());
    let is_resurrect = managed.as_ref().is_some_and(|value| value.resurrect);
    let local_mode = local_launch.is_some();
    let scrollback_max_bytes = local_launch
        .as_ref()
        .and_then(|launch| launch.scrollback_max_bytes)
        .unwrap_or(DEFAULT_SCROLLBACK_MAX_BYTES);
    let scrollback_max_lines = local_launch
        .as_ref()
        .and_then(|launch| launch.scrollback_max_lines);
    let mut initial_input = local_launch
        .as_ref()
        .map(LocalLaunchSpec::initial_input)
        .transpose()?
        .unwrap_or_default();
    if let Some(launch) = &mut local_launch {
        launch.input_base64 = None;
    }
    let mut size = local_launch.as_ref().map_or(
        libc::winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 640,
            ws_ypixel: 384,
        },
        |launch| libc::winsize {
            ws_row: launch.rows,
            ws_col: launch.cols,
            ws_xpixel: launch.pixel_width,
            ws_ypixel: launch.pixel_height,
        },
    );
    if unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    } < 0
    {
        return Err(io::Error::last_os_error());
    }
    let mut pty = unsafe { File::from_raw_fd(master) };
    let slave = unsafe { File::from_raw_fd(slave) };
    enable_utf8_input(pty.as_raw_fd())?;
    let tty_name = terminal_name(slave.as_raw_fd());
    // Prevent one session's exec from retaining another session's PTY.
    if unsafe { libc::fcntl(master, libc::F_SETFD, libc::FD_CLOEXEC) } < 0
        || unsafe { libc::fcntl(slave.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    let group = managed
        .as_ref()
        .and_then(|m| {
            m.containment_root
                .as_ref()
                .map(|root| (root, &m.record.generation))
        })
        .map(|(root, generation)| crate::containment::Group::create(root, generation))
        .transpose()?;
    let membership = group.as_ref().map(|g| g.membership()).transpose()?;
    let membership_fd = membership.as_ref().map(|f| f.as_raw_fd());
    let id = managed
        .as_ref()
        .map(|m| m.record.id.clone())
        .unwrap_or_else(|| token[..16.min(token.len())].to_owned());
    let generation = managed
        .as_ref()
        .map(|m| m.record.generation.clone())
        .unwrap_or_else(|| token.clone());
    let mut command = Command::new(&argv[0]);
    let has_explicit_osc7501 = if let Some(launch) = local_launch.as_ref() {
        command.env_clear().envs(launch.env.iter());
        if launch
            .env
            .get("TERM")
            .is_none_or(|term| term.trim().is_empty() || term == "dumb")
        {
            command.env("TERM", "xterm-256color");
        }
        if let Some(cwd) = launch.cwd.as_deref() {
            command.current_dir(cwd).env("PWD", cwd);
        }
        launch.env.contains_key("AGY_CLI_OSC7501")
    } else {
        command.env("TERM", "xterm-256color");
        std::env::var_os("AGY_CLI_OSC7501").is_some()
    };
    if !has_explicit_osc7501 {
        command.env("AGY_CLI_OSC7501", "on");
    }
    command
        .args(&argv[1..])
        .env("OMG_SESSION_ID", &id)
        .env("OMG_AGENT_SOCK", &event_path)
        .env("OMG_RUNTIME_EVENT_SOCKET", &event_path)
        .env("OMG_RUNTIME_EVENT_TOKEN", &token)
        .env("OMG_RUNTIME_GENERATION", &generation)
        .env("OMG_RUNTIME_BIN", std::env::current_exe()?)
        .stdin(Stdio::from(slave.try_clone()?))
        .stdout(Stdio::from(slave.try_clone()?))
        .stderr(Stdio::from(slave));
    let mut _draft_bridge = None;
    if local_mode {
        command.env_remove("OMG_RUNTIME_REMOTE");
    } else {
        command.env("OMG_RUNTIME_REMOTE", "1");
        if let Ok(exe) = std::env::current_exe() {
            if let Some(dir) = exe.parent().filter(|d| d.join("omg").is_file()) {
                let path = std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into());
                let dir_str = dir.to_string_lossy();
                if !path.split(':').any(|entry| entry == dir_str) {
                    command.env("PATH", format!("{path}:{dir_str}"));
                }
            }
        }
        if let (Some(managed), Some(tty)) = (managed.as_ref(), tty_name.as_deref()) {
            let original = std::env::var("VISUAL")
                .ok()
                .filter(|s| !s.is_empty())
                .or_else(|| std::env::var("EDITOR").ok().filter(|s| !s.is_empty()))
                .unwrap_or_else(|| "nano".into());
            if let Ok(bridge) =
                crate::remote_draft::prepare(parent, &managed.record, tty, &original)
            {
                command
                    .env("VISUAL", &bridge.editor)
                    .env("EDITOR", &bridge.editor);
                _draft_bridge = Some(bridge);
            }
        }
    }
    if let Some(resume) = managed
        .as_ref()
        .filter(|m| !m.resurrect)
        .and_then(|m| m.record.resume.as_ref())
    {
        command.current_dir(&resume.cwd).env("PWD", &resume.cwd);
    } else if let Some(cwd) = managed
        .as_ref()
        .and_then(|m| m.initial_cwd.as_ref())
        .filter(|_| !local_mode)
    {
        // Set cwd on this child command only; the host serves other sessions on
        // parallel threads. Treat paths as data, never a shell `cd` expression.
        command.current_dir(cwd).env("PWD", cwd);
    }
    unsafe {
        command.pre_exec(move || {
            // Join before exec/fork: "0" means this child. Only async-signal-safe
            // operations are allowed in the multithreaded host's fork child.
            if let Some(fd) = membership_fd {
                if libc::write(fd, b"0".as_ptr().cast(), 1) != 1 {
                    return Err(io::Error::last_os_error());
                }
            }
            // Background launchers/nohup may ignore SIGINT/SIGQUIT. A fresh
            // controlling terminal must not inherit that disposition or mask.
            for signal in [
                libc::SIGHUP,
                libc::SIGINT,
                libc::SIGQUIT,
                libc::SIGTERM,
                libc::SIGPIPE,
                libc::SIGCHLD,
                libc::SIGTSTP,
                libc::SIGTTIN,
                libc::SIGTTOU,
            ] {
                if libc::signal(signal, libc::SIG_DFL) == libc::SIG_ERR {
                    return Err(io::Error::last_os_error());
                }
            }
            let mut mask: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut mask);
            if libc::sigprocmask(libc::SIG_SETMASK, &mask, std::ptr::null_mut()) < 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::setsid() < 0 || libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = ChildGuard(command.spawn()?);
    let started_at = Instant::now();
    drop(command);
    drop(argv);
    drop(local_launch);
    drop(membership);
    if let Some(m) = &mut managed {
        m.record.pid = Some(child.id());
        m.record.ended = None;
        m.record.save(&m.path)?;
    }
    // Release the parent's slave handles so child exit produces EOF on the master.
    drop(spawn_guard);
    if unsafe { libc::fcntl(master, libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::last_os_error());
    }
    let inline_viewer = managed.as_ref().is_some_and(|m| m.record.inline_viewer);
    let mut input = Box::new(ReplyBuffer::new(
        VecDeque::from(std::mem::take(&mut initial_input)),
        inline_viewer,
    ));
    let mut vt = Vt::with_reply_pixels_scrollback(
        size.ws_col,
        size.ws_row,
        size.ws_xpixel,
        size.ws_ypixel,
        ScrollbackLimits {
            max_bytes: scrollback_max_bytes,
            max_lines: scrollback_max_lines,
        },
        Some(reply),
        (&mut *input as *mut ReplyBuffer).cast(),
    )?;
    let mut seq = 0u64;
    let mut snapshot_schedule = SnapshotSchedule::new(Instant::now());
    if is_resurrect {
        if let Some(m) = managed
            .as_ref()
            .filter(|m| !m.path.with_extension("closed").exists())
        {
            if let Some(snap_bytes) = load_snapshot(&m.path, m.record.snapshot_revision.as_deref())
            {
                if vt.restore(&snap_bytes).is_ok() {
                    if size.ws_xpixel > 0 && size.ws_ypixel > 0 {
                        let _ = vt.resize_pixels(
                            size.ws_col,
                            size.ws_row,
                            size.ws_xpixel,
                            size.ws_ypixel,
                        );
                    } else {
                        let _ = vt.resize(size.ws_col, size.ws_row);
                    }
                }
            }
            let alt_reset = if vt.in_alt_screen() {
                "\x1b[?1049l"
            } else {
                ""
            };
            let banner = format!(
                "{alt_reset}{HYGIENE_RESET}\r\n\x1b[0;2m  ──────  Session resurrected after system restart · {}  ──────\x1b[0m\r\n",
                format_local_timestamp()
            );
            vt.write(banner.as_bytes());
            input.bytes.clear();
            input.unclaimed.clear();
            let _ = vt.activity_mut().take_last_change_sync_restore();
            seq = seq.saturating_add(banner.len() as u64);
            snapshot_schedule.mark_dirty(Instant::now());
        }
    }
    vt.activity_mut().local = local_mode;
    vt.activity_mut().session_leader = Some(child.id() as i32);
    let mut last_broadcast_revision = vt.activity().revision();
    let mut output = crate::terminal_output::Relay::default();
    let mut presentation_revision = None;
    let mut peers: Vec<Peer> = vec![];
    let mut close_after_flush = HashSet::new();
    let mut next_id = 1;
    let mut had_peer = false;
    let mut writer = None;
    // A first inline viewer can continue at its local shell cursor instead of
    // clearing the screen to paint a newly-created, mostly empty terminal.
    // Stop retaining this bounded prefix once anyone has claimed the PTY.
    let mut initial_output = (!is_resurrect).then(Vec::<u8>::new);
    let mut lifetime = Lifetime::new(Instant::now());
    let mut end_reason = EndReason::ProcessExited;
    let mut shutdown_interrupted = false;
    let mut shutdown_handled = false;
    let mut orphaned = false;
    let mut agent_done = false;
    let mut completed_group = None;
    let mut recovery_checked_at = Instant::now() - Duration::from_secs(5);
    let mut recovery_available = false;
    let mut exited = None;
    let mut eof = false;
    let mut closing = None;
    let mut draining = None;
    let mut last_cwd = crate::location::session_cwd(master, child.id()).or_else(|| {
        managed
            .as_ref()
            .and_then(|session| session.record.cwd.clone())
    });
    let mut sniffed_remote_cwd: Option<String> = None;
    let mut last_ssh = resolve_session_ssh(master, child.id(), &vt, &mut sniffed_remote_cwd);
    let mut last_foreground = local_mode
        .then(|| foreground_session_group(master, child.id()))
        .flatten();
    let mut last_password_input = password_input(master);
    let mut cwd_checked = Instant::now();
    let mut password_checked = Instant::now();
    if let Some(session) = &mut managed {
        if session.record.cwd != last_cwd || session.record.ssh != last_ssh {
            session.record.cwd = last_cwd.clone();
            session.record.ssh = last_ssh.clone();
            session.record.save(&session.path)?;
        }
    }
    loop {
        if let Some(wake) = &shutdown_wake {
            wake.drain();
        }
        if closing.is_none()
            && managed
                .as_ref()
                .is_some_and(|m| m.path.with_extension("closed").exists())
        {
            end_reason = EndReason::ExplicitClose;
            if let Some(m) = managed.as_ref() {
                remove_snapshot_files(&m.path);
            }
            terminate_group(master, child.id(), libc::SIGTERM);
            closing = Some(Instant::now());
        }
        if shutdown_signaled() && !shutdown_handled {
            shutdown_handled = true;
            let has_closed = managed
                .as_ref()
                .is_some_and(|m| m.path.with_extension("closed").exists());
            if has_closed || end_reason == EndReason::ExplicitClose {
                end_reason = EndReason::ExplicitClose;
                if let Some(m) = managed.as_ref() {
                    remove_snapshot_files(&m.path);
                }
            } else if closing.is_none()
                && !matches!(
                    end_reason,
                    EndReason::DetachedTimeout | EndReason::Deadline | EndReason::AgentCompleted
                )
            {
                end_reason = EndReason::Lost;
                shutdown_interrupted = true;
                if local_mode {
                    flush_vt_snapshot(&vt, managed.as_ref(), &mut snapshot_schedule);
                }
                if let Some(m) = &mut managed {
                    if record_slot_disposition(m, false) == RecordSlotDisposition::Owned {
                        m.record.ended = Some(EndReason::Lost);
                        let _ = m.record.save(&m.path);
                    }
                }
                if exited.is_none() {
                    terminate_group(master, child.id(), libc::SIGTERM);
                    closing = Some(Instant::now());
                }
            }
        }
        if exited.is_none() && cwd_checked.elapsed() >= Duration::from_millis(500) {
            if closing.is_none()
                && peers.is_empty()
                && listener.is_some()
                && socket_missing_or_replaced(path, bound_socket_id)
            {
                orphaned = true;
                shutdown_interrupted = true;
                if managed
                    .as_ref()
                    .is_some_and(|m| m.path.with_extension("closed").exists())
                {
                    end_reason = EndReason::ExplicitClose;
                } else {
                    end_reason = EndReason::Lost;
                }
                terminate_group(master, child.id(), libc::SIGTERM);
                closing = Some(Instant::now());
            }
            let cur_fg = unsafe { libc::tcgetpgrp(master) };
            vt.activity_mut().foreground = (cur_fg > 1).then_some(cur_fg);
            let _ = vt.activity_mut().prune(child.id() as i32);
            let cwd = crate::location::session_cwd(master, child.id());
            let ssh = resolve_session_ssh(master, child.id(), &vt, &mut sniffed_remote_cwd);
            let foreground = local_mode
                .then(|| foreground_session_group(master, child.id()))
                .flatten();
            if cwd != last_cwd || foreground != last_foreground || ssh != last_ssh {
                last_cwd = cwd;
                last_foreground = foreground;
                last_ssh = ssh;
                if let Some(session) = &mut managed {
                    if (session.record.cwd != last_cwd || session.record.ssh != last_ssh)
                        && record_slot_disposition(session, orphaned)
                            == RecordSlotDisposition::Owned
                    {
                        let mut updated = session.record.clone();
                        updated.cwd = last_cwd.clone();
                        updated.ssh = last_ssh.clone();
                        if updated.save(&session.path).is_ok() {
                            session.record = updated;
                        }
                    }
                }
                let metadata = serde_json::to_vec(&serde_json::json!({
                    "cwd": last_cwd,
                    "ssh": last_ssh,
                    "foreground_pid": foreground,
                    "tty_name": if local_mode { tty_name.as_deref() } else { None },
                    "password_input": last_password_input,
                    "runtime_ms": runtime_millis(started_at)
                }))?;
                for peer in &mut peers {
                    peer.push(Frame::new(b'M', seq, &metadata));
                }
            }
            cwd_checked = Instant::now();
        }
        if exited.is_none() && password_checked.elapsed() >= Duration::from_millis(200) {
            let password = password_input(master);
            if password != last_password_input {
                last_password_input = password;
                let metadata = serde_json::to_vec(&serde_json::json!({
                    "cwd": last_cwd,
                    "foreground_pid": if local_mode { last_foreground } else { None },
                    "tty_name": if local_mode { tty_name.as_deref() } else { None },
                    "password_input": last_password_input,
                    "runtime_ms": runtime_millis(started_at)
                }))?;
                for peer in &mut peers {
                    peer.push(Frame::new(b'M', seq, &metadata));
                }
            }
            password_checked = Instant::now();
        }
        // Hooks use an inherited per-session capability, never terminal text.
        let mut event_bytes = [0u8; 16384];
        for _ in 0..16 {
            match events.recv_from(&mut event_bytes) {
                Ok((n, source)) => {
                    let mut accepted = false;
                    if let Ok(event) = serde_json::from_slice::<AgentEvent>(&event_bytes[..n]) {
                        let canonical_state = match event.state.as_str() {
                            "working" | "processing" | "active" => Some("working"),
                            "idle" => Some("idle"),
                            "done" | "completed" => Some("done"),
                            "needsAttention" | "waiting" | "awaiting" | "blocked" => {
                                Some("needsAttention")
                            }
                            "error" | "failed" => Some("error"),
                            "end" | "clear" => Some("end"),
                            _ => None,
                        };
                        let resume_check_ok = match &event.resume {
                            Some(r) if !r.conversation_id.is_empty() => r.validate().is_ok(),
                            _ => true,
                        };
                        let raw_agent = event
                            .agent
                            .as_deref()
                            .or_else(|| event.resume.as_ref().map(|r| r.agent.as_str()));
                        let fg_pgid = unsafe { libc::tcgetpgrp(master) };
                        if event.token == token && event.generation == generation && resume_check_ok
                        {
                            if let (
                                Some(state_str),
                                Some(agent_str),
                                Some((owner_id, owner_is_group, job_pgid)),
                            ) = (
                                canonical_state,
                                raw_agent.and_then(crate::agents::normalize_id),
                                crate::activity::resolve_event_owner(
                                    event.pid,
                                    event.group,
                                    event.owner_pid,
                                    child.id() as i32,
                                    fg_pgid,
                                ),
                            ) {
                                let conv_id = event
                                    .resume
                                    .as_ref()
                                    .map(|r| r.conversation_id.as_str())
                                    .filter(|s| !s.is_empty());
                                let report_cwd = event
                                    .cwd
                                    .as_deref()
                                    .or_else(|| event.resume.as_ref().map(|r| r.cwd.as_str()));
                                vt.activity_mut().foreground = (fg_pgid > 1).then_some(fg_pgid);
                                vt.activity_mut().consume_report(
                                    &agent_str,
                                    state_str,
                                    owner_id,
                                    owner_is_group,
                                    local_mode,
                                    conv_id,
                                    report_cwd,
                                    event.context_id.as_deref(),
                                    event.attention.as_deref(),
                                    event.phase.as_deref(),
                                    event.message.as_deref(),
                                    event.tier.as_deref(),
                                    event.event.as_deref(),
                                );
                                if let Some(m) = &mut managed {
                                    if let Some(mut resume) =
                                        event.resume.filter(|r| !r.conversation_id.is_empty())
                                    {
                                        resume.agent = agent_str;
                                        m.record.resume = Some(resume);
                                        // Persist first: a completion must never destroy its own recovery data.
                                        m.record.save(&m.path)?;
                                    }
                                    agent_done = state_str == "done";
                                    completed_group = agent_done.then_some(job_pgid);
                                    recovery_checked_at = Instant::now() - Duration::from_secs(5);
                                    lifetime.activity(agent_done, Instant::now());
                                }
                                accepted = true;
                            }
                        }
                    }
                    if let Some(path) = source.as_pathname() {
                        let _ = events.send_to(if accepted { b"OK" } else { b"NO" }, path);
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        // A bounded accept batch cannot starve PTY processing.
        for _ in 0..8 {
            let Some(active_listener) = &listener else {
                break;
            };
            match active_listener.accept() {
                Ok((socket, _)) => {
                    if peers.len() >= 16 {
                        continue;
                    }
                    let mut peer = Peer::new(socket, next_id)?;
                    had_peer = true;
                    next_id += 1;
                    let info = serde_json::json!({
                        "version": 2,
                        "session_id": id,
                        "pid": child.id(),
                        "attachment": peer.id,
                        "cols": size.ws_col,
                        "rows": size.ws_row,
                        "pixel_width": size.ws_xpixel,
                        "pixel_height": size.ws_ypixel,
                        "generation": generation,
                        "detached_ttl_seconds": policy.detached_ttl_seconds,
                        "experimental": true,
                        "foreground_pid": if local_mode { last_foreground } else { None },
                        "tty_name": if local_mode { tty_name.as_deref() } else { None },
                        "password_input": last_password_input,
                        "runtime_ms": runtime_millis(started_at),
                        "inline_viewer": inline_viewer,
                        "writer_transfer": true,
                        "activity_acknowledge": true,
                        "initial_output": initial_output.as_ref().map(|bytes| {
                            use base64::Engine;
                            base64::engine::general_purpose::STANDARD.encode(bytes)
                        })
                    });
                    peer.push(Frame::new(INFO, seq, info.to_string().as_bytes()));
                    if queue_snapshot(&mut peer, seq, vt.snapshot()) {
                        peer.push(Frame::new(
                            crate::activity::FRAME,
                            seq,
                            &serde_json::to_vec(&vt.activity().snapshot())?,
                        ));
                        peer.push(Frame::new(
                            b'M',
                            seq,
                            &serde_json::to_vec(&serde_json::json!({
                                "cwd": last_cwd,
                                "foreground_pid": if local_mode { last_foreground } else { None },
                                "tty_name": if local_mode { tty_name.as_deref() } else { None },
                                "password_input": last_password_input,
                                "runtime_ms": runtime_millis(started_at)
                            }))?,
                        ));
                    } else {
                        close_after_flush.insert(peer.id);
                    }
                    if !close_after_flush.contains(&peer.id) {
                        if let Some(code) = exited {
                            peer.push(Frame::new(EXIT, seq, format!("{code}").as_bytes()));
                        }
                    }
                    peers.push(peer);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        let mut resizes = Vec::new();
        let mut revoked = Vec::new();
        for peer in &mut peers {
            if close_after_flush.contains(&peer.id) {
                continue;
            }
            let frames = match peer.read() {
                Ok(f) => f,
                Err(_) => {
                    peer.dead = true;
                    continue;
                }
            };
            for f in frames {
                if f.kind == ACK && peer.ack == Some(f.seq) {
                    peer.ack = None;
                    continue;
                }
                if peer.ack.is_some() {
                    peer.dead = true;
                    break;
                }
                match f.kind {
                    CLAIM
                        if writer.is_none()
                            || writer == Some(peer.id)
                            || matches!(
                                f.data.as_slice(),
                                b"takeover/1" | b"inline-takeover/1"
                            ) =>
                    {
                        if !f.data.is_empty()
                            && !matches!(
                                f.data.as_slice(),
                                b"inline/1" | b"takeover/1" | b"inline-takeover/1"
                            )
                        {
                            peer.dead = true;
                            continue;
                        }
                        if let Some(previous) = writer.filter(|id| *id != peer.id) {
                            revoked.push(previous);
                        }
                        initial_output = None;
                        input.claim(matches!(
                            f.data.as_slice(),
                            b"inline/1" | b"inline-takeover/1"
                        ));
                        writer = Some(peer.id);
                        peer.push(Frame::new(CLAIM, seq, &[]));
                    }
                    CLAIM => peer.push(Frame::new(b'B', seq, b"writer occupied")),
                    INPUT if writer == Some(peer.id) && exited.is_none() => {
                        // Never blindly acknowledge `done`/`error` on INPUT: mouse motion,
                        // focus events, and terminal replies must never wipe terminal status!
                        // Run the Interrupt Fence (`Ctrl+C` / bare `Esc`) and reset the
                        // `close_on_agent_done` reaper only on genuine user keystrokes.
                        let outcome = vt.activity_mut().consume_input_detailed(&f.data);
                        if outcome.user_interaction {
                            agent_done = false;
                            completed_group = None;
                            lifetime.activity(false, Instant::now());
                        }
                        if input.len() + f.data.len() > 1024 * 1024 {
                            peer.dead = true;
                        } else {
                            input.extend(f.data);
                        }
                    }
                    crate::ACKNOWLEDGE if f.data.is_empty() || f.data.len() == 8 => {
                        agent_done = false;
                        completed_group = None;
                        lifetime.activity(false, Instant::now());
                        if f.data.len() == 8 {
                            let up_to = u64::from_be_bytes(f.data[..8].try_into().unwrap());
                            let _ = vt.activity_mut().acknowledge_up_to(up_to);
                        } else {
                            let _ = vt.activity_mut().acknowledge();
                        }
                    }
                    RESIZE if writer == Some(peer.id) => {
                        let Some((cols, rows, pixel_width, pixel_height)) =
                            resize_dimensions(&f.data)
                        else {
                            peer.dead = true;
                            continue;
                        };
                        if cols == 0
                            || rows == 0
                            || cols > 500
                            || rows > 300
                            || pixel_width > 16_000
                            || pixel_height > 16_000
                        {
                            peer.dead = true;
                            continue;
                        }
                        let changed = size.ws_col != cols
                            || size.ws_row != rows
                            || size.ws_xpixel != pixel_width
                            || size.ws_ypixel != pixel_height;
                        if changed {
                            size.ws_col = cols;
                            size.ws_row = rows;
                            size.ws_xpixel = pixel_width;
                            size.ws_ypixel = pixel_height;
                            vt.resize_pixels(cols, rows, pixel_width, pixel_height)?;
                            if unsafe { libc::ioctl(pty.as_raw_fd(), libc::TIOCSWINSZ, &size) } < 0
                            {
                                return Err(io::Error::last_os_error());
                            }
                            snapshot_schedule.mark_dirty(Instant::now());
                        }
                        resizes.push(f.data);
                    }
                    CLOSE if writer == Some(peer.id) && closing.is_none() => {
                        end_reason = EndReason::ExplicitClose;
                        if let Some(m) = managed.as_ref() {
                            remove_snapshot_files(&m.path);
                        }
                        terminate_group(master, child.id(), libc::SIGTERM);
                        closing = Some(Instant::now());
                    }
                    // A former writer can have frames in flight when another
                    // viewer takes over. Drop those frames without detaching it.
                    INPUT | RESIZE | CLOSE => {}
                    _ => {
                        peer.dead = true;
                    }
                }
            }
        }
        for id in revoked {
            if writer != Some(id) {
                if let Some(peer) = peers.iter_mut().find(|p| p.id == id) {
                    peer.push(Frame::new(b'B', seq, b"writer transferred"));
                }
            }
        }
        for dimensions in resizes {
            for p in &mut peers {
                p.push(Frame::new(RESIZE, seq, &dimensions));
            }
        }
        if !input.is_empty() && !eof {
            let bytes = input.make_contiguous();
            let n = bytes.len().min(65536);
            match pty.write(&bytes[..n]) {
                Ok(n) => {
                    bytes[..n].fill(0);
                    input.drain(..n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => {
                    input.make_contiguous().fill(0);
                    input.clear();
                }
            }
        }
        // Never gate this read on the number or speed of attachments.
        if !eof {
            let raw_fg = unsafe { libc::tcgetpgrp(master) };
            vt.activity_mut().foreground = (raw_fg > 1).then_some(raw_fg);
            let foreground = foreground_session_group(master, child.id());
            if local_mode && foreground != last_foreground {
                last_foreground = foreground;
                let ssh = resolve_session_ssh(master, child.id(), &vt, &mut sniffed_remote_cwd);
                if ssh != last_ssh {
                    last_ssh = ssh;
                    if let Some(session) = &mut managed {
                        if session.record.ssh != last_ssh
                            && record_slot_disposition(session, orphaned)
                                == RecordSlotDisposition::Owned
                        {
                            let mut updated = session.record.clone();
                            updated.ssh = last_ssh.clone();
                            if updated.save(&session.path).is_ok() {
                                session.record = updated;
                            }
                        }
                    }
                }
                let metadata = serde_json::to_vec(&serde_json::json!({
                    "cwd": last_cwd,
                    "ssh": last_ssh,
                    "foreground_pid": foreground,
                    "tty_name": tty_name.as_deref(),
                    "password_input": last_password_input,
                    "runtime_ms": runtime_millis(started_at)
                }))?;
                for peer in &mut peers {
                    peer.push(Frame::new(b'M', seq, &metadata));
                }
            }
            let mut bytes = [0; 65536];
            match pty.read(&mut bytes) {
                Ok(0) => eof = true,
                Ok(n) => {
                    if last_ssh.is_some() {
                        sniff_remote_cwd(&bytes[..n], &mut sniffed_remote_cwd);
                    }
                    let visible = output.feed(
                        &mut OutputScreen {
                            vt: &mut vt,
                            replies: &*input,
                        },
                        &bytes[..n],
                    );
                    if n > 0 {
                        snapshot_schedule.mark_dirty(Instant::now());
                    }
                    if let Some(prefix) = &mut initial_output {
                        if prefix.len() + visible.len() <= 8 * 1024 {
                            prefix.extend_from_slice(&visible);
                        } else {
                            initial_output = None;
                        }
                    }
                    seq += visible.len() as u64;
                    if !visible.is_empty() {
                        for peer in &mut peers {
                            peer.push(Frame::new(OUTPUT, seq, &visible));
                        }
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) if e.raw_os_error() == Some(libc::EIO) => eof = true,
                Err(e) => return Err(e),
            }
        }
        // Keep the session leader unreaped during termination escalation. A
        // zombie retains its PID/SID, so foreground jobs can still be validated
        // and killed even if they outlive the shell after SIGTERM.
        let grace_duration = if shutdown_interrupted {
            Duration::from_millis(policy.terminate_grace_seconds.min(1).saturating_mul(800))
        } else {
            Duration::from_secs(policy.terminate_grace_seconds)
        };
        let may_reap = closing.is_none_or(|start: Instant| start.elapsed() > grace_duration);
        if exited.is_none() && may_reap {
            if closing.is_some() {
                terminate_group(master, child.id(), libc::SIGKILL);
            }
            if let Some(status) = child.try_wait()? {
                exited = Some(status.code().unwrap_or(-1));
                #[cfg(unix)]
                {
                    use std::os::unix::process::ExitStatusExt;
                    let signaled_shutdown = matches!(
                        status.signal(),
                        Some(sig) if sig == libc::SIGTERM || sig == libc::SIGKILL
                    );
                    if closing.is_none()
                        && signaled_shutdown
                        && !managed
                            .as_ref()
                            .is_some_and(|m| m.path.with_extension("closed").exists())
                        && !matches!(
                            end_reason,
                            EndReason::ExplicitClose
                                | EndReason::DetachedTimeout
                                | EndReason::Deadline
                                | EndReason::AgentCompleted
                        )
                    {
                        end_reason = EndReason::Lost;
                        shutdown_interrupted = true;
                    }
                }
            }
        }
        if let Some(start) = closing {
            if start.elapsed() > grace_duration && !eof && exited.is_none() {
                terminate_group(master, child.id(), libc::SIGKILL);
                // Escaped descendants retaining a slave cannot keep our actor forever.
                let force_eof_after = if shutdown_interrupted {
                    grace_duration + Duration::from_millis(200)
                } else {
                    grace_duration + Duration::from_secs(2)
                };
                if start.elapsed() > force_eof_after {
                    eof = true;
                }
            }
        }
        let current_activity_revision = vt.activity().revision();
        if current_activity_revision != last_broadcast_revision {
            last_broadcast_revision = current_activity_revision;
            let was_sync_restore = vt.activity_mut().take_last_change_sync_restore();
            let snapshot = vt.activity().snapshot();
            if let Some(presentation) = managed.as_ref().and_then(|m| m.presentation.as_ref()) {
                if let Ok(mut current) = presentation.lock() {
                    *current = snapshot.clone();
                    presentation_revision = Some(current.revision);
                }
            }
            if !peers.is_empty() {
                let mut wire_snapshot = snapshot;
                wire_snapshot.sync_restore = was_sync_restore;
                let snapshot_bytes = serde_json::to_vec(&wire_snapshot)?;
                for peer in &mut peers {
                    if !close_after_flush.contains(&peer.id) {
                        peer.push(Frame::new(crate::activity::FRAME, seq, &snapshot_bytes));
                    }
                }
            }
        } else if presentation_revision != Some(current_activity_revision) {
            if let Some(presentation) = managed.as_ref().and_then(|m| m.presentation.as_ref()) {
                if let Ok(mut current) = presentation.lock() {
                    *current = vt.activity().snapshot();
                    presentation_revision = Some(current.revision);
                }
            }
        }
        for peer in &mut peers {
            if peer.flush().is_err() {
                peer.dead = true;
            }
        }
        let mut removed_peers = Vec::new();
        for peer in &mut peers {
            if close_after_flush.contains(&peer.id) && peer.queued == 0 {
                peer.dead = true;
            }
            if peer.dead {
                removed_peers.push(peer.id);
            }
        }
        for id in removed_peers {
            close_after_flush.remove(&id);
        }
        peers.retain(|p| !p.dead);
        lifetime.attached(peers.len(), Instant::now());
        if closing.is_none() && exited.is_none() {
            // A completed Agent may have exited and yielded its PTY to a new
            // command. Its old completion must not terminate that new job.
            if agent_done && completed_group != Some(unsafe { libc::tcgetpgrp(master) }) {
                agent_done = false;
                completed_group = None;
                lifetime.activity(false, Instant::now());
            }
            if agent_done && recovery_checked_at.elapsed() >= Duration::from_secs(5) {
                recovery_available = managed
                    .as_ref()
                    .and_then(|m| m.record.resume.as_ref())
                    .is_some_and(|r| r.store_exists());
                recovery_checked_at = Instant::now();
            }
            let can_resume = agent_done && recovery_available;
            if let Some(reason) = lifetime.reason(&policy, Instant::now(), unix_time(), can_resume)
            {
                end_reason = reason;
                if matches!(
                    reason,
                    EndReason::ExplicitClose
                        | EndReason::DetachedTimeout
                        | EndReason::Deadline
                        | EndReason::ProcessExited
                ) {
                    if let Some(m) = managed.as_ref() {
                        if record_slot_disposition(m, orphaned) == RecordSlotDisposition::Owned {
                            remove_snapshot_files(&m.path);
                        }
                    }
                }
                if let Some(m) = &mut managed {
                    if record_slot_disposition(m, orphaned) == RecordSlotDisposition::Owned {
                        m.record.ended = Some(reason);
                        if let Err(err) = m.record.save(&m.path) {
                            if !orphaned && err.kind() != io::ErrorKind::NotFound {
                                return Err(err);
                            }
                        }
                    }
                }
                terminate_group(master, child.id(), libc::SIGTERM);
                closing = Some(Instant::now());
            }
        }
        if local_mode
            && managed.is_some()
            && closing.is_none()
            && exited.is_none()
            && snapshot_schedule.should_flush(Instant::now())
        {
            flush_vt_snapshot(&vt, managed.as_ref(), &mut snapshot_schedule);
        }
        if exited.is_some() && closing.is_none() {
            closing = Some(Instant::now());
        }
        // Once the owned leader has been reaped, its numeric PID may be reused.
        // Finish draining instead of signaling any process by that stale ID.
        let eof_drain_limit = if shutdown_interrupted {
            Duration::from_millis(150)
        } else {
            Duration::from_secs(2)
        };
        if exited.is_some() && closing.is_some_and(|start| start.elapsed() > eof_drain_limit) {
            eof = true;
        }
        if writer.is_some_and(|id| !peers.iter().any(|p| p.id == id)) {
            writer = None;
            input.claim(false);
        } else if had_peer && peers.is_empty() && input.awaiting_writer {
            input.claim(false);
        }
        if let (Some(code), true) = (exited, eof) {
            if draining.is_none() {
                // Close and unlink the session socket and persist terminal end
                // state before notifying peers so a fast reattach attempt after
                // EXIT never connects to a dying listener.
                listener = None;
                socket_guard.remove_now();
                let _ = child.wait();
                if let Some(group) = &group {
                    group.finish()?;
                }
                if let Some(m) = &mut managed {
                    if m.path.with_extension("closed").exists() {
                        end_reason = EndReason::ExplicitClose;
                    } else if shutdown_signaled()
                        && !matches!(
                            end_reason,
                            EndReason::ExplicitClose
                                | EndReason::DetachedTimeout
                                | EndReason::Deadline
                                | EndReason::AgentCompleted
                        )
                    {
                        end_reason = EndReason::Lost;
                        shutdown_interrupted = true;
                    }
                    if record_slot_disposition(m, orphaned) == RecordSlotDisposition::Owned {
                        if end_reason == EndReason::Lost && local_mode {
                            if snapshot_schedule.is_dirty() || !snapshot_path(&m.path).exists() {
                                flush_vt_snapshot(&vt, Some(m), &mut snapshot_schedule);
                            }
                        } else if matches!(
                            end_reason,
                            EndReason::ExplicitClose
                                | EndReason::ProcessExited
                                | EndReason::DetachedTimeout
                                | EndReason::Deadline
                        ) {
                            remove_snapshot_files(&m.path);
                        }
                        m.record.pid = None;
                        m.record.ended = Some(end_reason);
                        if let Err(err) = m.record.save(&m.path) {
                            if !orphaned && err.kind() != io::ErrorKind::NotFound {
                                return Err(err);
                            }
                        }
                    }
                }
                let metadata = serde_json::to_vec(&serde_json::json!({
                    "cwd": last_cwd,
                    "foreground_pid": None::<u64>,
                    "tty_name": if local_mode { tty_name.as_deref() } else { None },
                    "password_input": false,
                    "runtime_ms": runtime_millis(started_at)
                }))?;
                for peer in &mut peers {
                    peer.push(Frame::new(b'M', seq, &metadata));
                    peer.push(Frame::new(EXIT, seq, format!("{code}").as_bytes()));
                }
                draining = Some(Instant::now());
            }
            let start = draining.as_ref().unwrap();
            let drain_limit = if shutdown_interrupted {
                Duration::from_millis(150)
            } else {
                Duration::from_secs(2)
            };
            if peers.iter().all(|p| p.queued == 0) || start.elapsed() > drain_limit {
                return Ok(());
            }
        }
        let mut descriptors = Vec::with_capacity(peers.len() + 4);
        if !eof {
            descriptors.push(libc::pollfd {
                fd: master,
                events: pty_poll_interests(eof, !input.is_empty()),
                revents: 0,
            });
        }
        if let Some(listener) = &listener {
            descriptors.push(libc::pollfd {
                fd: listener.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            });
        }
        descriptors.push(libc::pollfd {
            fd: events.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
        if let Some(wake) = &shutdown_wake {
            descriptors.push(wake.poll_fd());
        }
        for peer in &peers {
            let mut interests = libc::POLLIN;
            if peer_wants_write(peer) {
                interests |= libc::POLLOUT;
            }
            descriptors.push(libc::pollfd {
                fd: peer.socket.as_raw_fd(),
                events: interests,
                revents: 0,
            });
        }
        let mut poll_timeout_ms: libc::c_int = if shutdown_interrupted { 50 } else { 200 };
        if local_mode && managed.is_some() && closing.is_none() && exited.is_none() {
            if let Some(next_snapshot) = snapshot_schedule.next_deadline() {
                poll_timeout_ms =
                    poll_timeout_ms.min(deadline_poll_ms(Instant::now(), next_snapshot));
            }
        }
        let result = unsafe {
            libc::poll(
                descriptors.as_mut_ptr(),
                descriptors.len() as libc::nfds_t,
                poll_timeout_ms,
            )
        };
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_writer_delegates_queries_and_detached_host_answers_them_once() {
        let mut input = Box::new(ReplyBuffer::new(VecDeque::new(), true));
        let mut vt = Vt::with_reply_pixels(
            80,
            24,
            640,
            384,
            Some(reply),
            (&mut *input as *mut ReplyBuffer).cast(),
        )
        .unwrap();
        let mut output = crate::terminal_output::Relay::default();
        let visible = output.feed(
            &mut OutputScreen {
                vt: &mut vt,
                replies: &*input,
            },
            b"\x1b[6n",
        );
        assert_eq!(visible, b"\x1b[6n");
        assert!(input.is_empty());
        input.claim(true);
        input.claim(false);
        let visible = output.feed(
            &mut OutputScreen {
                vt: &mut vt,
                replies: &*input,
            },
            b"\x1b[6n",
        );
        assert!(visible.is_empty());
        assert_eq!(input.iter().copied().collect::<Vec<_>>(), b"\x1b[1;1R");
    }

    #[test]
    fn snapshot_and_filtered_output_share_the_same_partial_sequence_boundary() {
        let mut input = Box::new(ReplyBuffer::new(VecDeque::new(), false));
        let mut vt = Vt::with_reply_pixels(
            80,
            24,
            640,
            384,
            Some(reply),
            (&mut *input as *mut ReplyBuffer).cast(),
        )
        .unwrap();
        let mut output = crate::terminal_output::Relay::default();
        assert!(output
            .feed(
                &mut OutputScreen {
                    vt: &mut vt,
                    replies: &*input
                },
                b"\x1b[3"
            )
            .is_empty());
        let mut attached = Vt::new(80, 24).unwrap();
        attached.restore(&vt.snapshot().unwrap()).unwrap();
        let tail = output.feed(
            &mut OutputScreen {
                vt: &mut vt,
                replies: &*input,
            },
            b"1mRED\x1b[0m",
        );
        attached.write(&tail);
        assert_eq!(attached.text().unwrap(), vt.text().unwrap());
        assert!(attached.text().unwrap().contains("RED"));
    }

    #[test]
    fn resize_accepts_legacy_and_pixel_aware_payloads() {
        assert_eq!(
            resize_dimensions(&[0, 100, 0, 40]),
            Some((100, 40, 800, 640))
        );
        assert_eq!(
            resize_dimensions(&[0, 100, 0, 40, 0x07, 0x80, 0x03, 0x20]),
            Some((100, 40, 1920, 800))
        );
        assert_eq!(resize_dimensions(&[0, 100, 0, 40, 1]), None);
    }

    #[test]
    fn pending_pty_input_wakes_on_write_readiness_without_masking_output() {
        assert_ne!(pty_poll_interests(false, true) & libc::POLLOUT, 0);
        assert_ne!(pty_poll_interests(false, true) & libc::POLLIN, 0);
        assert_eq!(pty_poll_interests(true, true), 0);
    }

    #[test]
    fn oversized_snapshot_queues_error_without_a_partial_snapshot() {
        let (socket, _remote) = UnixStream::pair().unwrap();
        let mut peer = Peer::new(socket, 1).unwrap();
        let snapshot = vec![0; MAX_FRAME + 1];

        assert!(!queue_snapshot(&mut peer, 7, Ok(snapshot)));
        assert_eq!(peer.queue.len(), 1);
        let error = Frame::read(&mut &peer.queue.front().unwrap()[..]).unwrap();
        assert_eq!(error.kind, b'E');
        assert_eq!(error.seq, 7);
        assert!(error.data.starts_with(b"terminal snapshot exceeds"));
    }

    #[test]
    fn password_input_requires_canonical_mode_without_echo() {
        let _spawn = PTY_SPAWN.lock().unwrap();
        let mut master = -1;
        let mut slave = -1;
        let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut size,
                )
            },
            0
        );
        let mut settings = unsafe { std::mem::zeroed::<libc::termios>() };
        assert_eq!(unsafe { libc::tcgetattr(slave, &mut settings) }, 0);
        settings.c_lflag |= libc::ICANON;
        settings.c_lflag &= !libc::ECHO;
        assert_eq!(
            unsafe { libc::tcsetattr(slave, libc::TCSANOW, &settings) },
            0
        );
        assert!(password_input(master));
        settings.c_lflag &= !libc::ICANON;
        assert_eq!(
            unsafe { libc::tcsetattr(slave, libc::TCSANOW, &settings) },
            0
        );
        assert!(!password_input(master));
        unsafe {
            libc::close(master);
            libc::close(slave);
        }
    }

    #[test]
    fn pty_enables_utf8_input_mode() {
        let _spawn = PTY_SPAWN.lock().unwrap();
        let mut master = -1;
        let mut slave = -1;
        let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut size,
                )
            },
            0
        );
        enable_utf8_input(master).unwrap();
        let mut settings = unsafe { std::mem::zeroed::<libc::termios>() };
        assert_eq!(unsafe { libc::tcgetattr(slave, &mut settings) }, 0);
        assert_ne!(settings.c_iflag & libc::IUTF8, 0);
        unsafe {
            libc::close(master);
            libc::close(slave);
        }
    }

    #[test]
    fn runtime_duration_uses_elapsed_milliseconds() {
        let started = Instant::now();
        std::thread::sleep(Duration::from_millis(25));
        let elapsed = runtime_millis(started);
        assert!((20..1000).contains(&elapsed));
    }

    #[test]
    fn snapshot_persistence_enforces_mode_symlinks_size_and_closed_tombstone() {
        let dir = PathBuf::from(format!("/tmp/omg-snap-test-{}", &nonce().unwrap()[..8]));
        fs::create_dir_all(&dir).unwrap();
        let record_path = dir.join("11111111-1111-1111-1111-111111111111.json");

        let mut vt = Vt::new(80, 24).unwrap();
        vt.write(b"\x1b[?1049halt-mode-content\x1b[?1049lmain-screen-line\r\n");
        let encoded = encode_snapshot(&vt, None).unwrap();
        save_snapshot_atomic(&record_path, &encoded).unwrap();

        let snap = snapshot_path(&record_path);
        let mode = fs::symlink_metadata(&snap).unwrap().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let loaded = load_snapshot(&record_path, None).unwrap();
        let mut restored = Vt::new(80, 24).unwrap();
        restored.restore(&loaded).unwrap();
        restored.write(HYGIENE_RESET.as_bytes());
        assert!(restored.text().unwrap().contains("main-screen-line"));

        // Refuses symlinked snapshot reads cleanly.
        let outside = dir.join("outside.snapshot");
        fs::write(&outside, &encoded).unwrap();
        fs::remove_file(&snap).unwrap();
        std::os::unix::fs::symlink(&outside, &snap).unwrap();
        assert!(load_snapshot(&record_path, None).is_none());
        fs::remove_file(&snap).unwrap();

        // `.closed` tombstone prevents saving and removes stale snapshot.
        save_snapshot_atomic(&record_path, &encoded).unwrap();
        assert!(snap.exists());
        fs::write(record_path.with_extension("closed"), b"").unwrap();
        save_snapshot_atomic(&record_path, &encoded).unwrap();
        assert!(!snap.exists());

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn snapshot_schedule_backs_off_after_failures_and_never_clamps_poll_to_zero() {
        let t0 = Instant::now();
        let mut sched = SnapshotSchedule::new(t0);
        assert!(!sched.is_dirty());
        assert_eq!(sched.next_deadline(), None);
        assert!(!sched.should_flush(t0));

        sched.mark_dirty(t0);
        assert!(sched.is_dirty());
        assert!(!sched.should_flush(t0 + Duration::from_secs(2)));
        assert_eq!(
            deadline_poll_ms(t0 + Duration::from_secs(2), sched.next_deadline().unwrap()),
            1001
        );

        // Debounce reached at t0 + 3s, then save fails: must back off, NOT stay due at t0 + 3s.
        let t_fail1 = t0 + SNAPSHOT_DEBOUNCE;
        assert!(sched.should_flush(t_fail1));
        sched.record_failure(t_fail1);
        assert!(sched.is_dirty());
        assert!(!sched.should_flush(t_fail1));
        assert!(!sched.should_flush(t_fail1 + Duration::from_millis(2999)));
        assert!(
            deadline_poll_ms(t_fail1, sched.next_deadline().unwrap()) >= 3000,
            "first failure must schedule a >=3s retry instead of a 0ms poll spin"
        );

        // Exponential backoff: 3s -> 6s -> 12s -> 24s -> 30s (capped).
        let expected_backoffs = [6u64, 12, 24, 30, 30];
        let mut cursor = t_fail1 + Duration::from_secs(3);
        for secs in expected_backoffs {
            assert!(sched.should_flush(cursor));
            sched.record_failure(cursor);
            assert!(!sched.should_flush(cursor));
            let expected_deadline = cursor + Duration::from_secs(secs);
            assert_eq!(sched.next_deadline(), Some(expected_deadline));
            assert!(deadline_poll_ms(cursor, expected_deadline) >= (secs as i32) * 1000);
            cursor = expected_deadline;
        }

        // Recovery clears dirty state and resets failure counter.
        assert!(sched.should_flush(cursor));
        let rev = sched.output_dirty_rev;
        sched.record_persisted(rev, cursor);
        assert!(!sched.is_dirty());
        assert_eq!(sched.next_deadline(), None);
        assert_eq!(sched.consecutive_failures, 0);

        // Continuous output remains bounded by SNAPSHOT_MAX_INTERVAL (30s).
        let mut stream_now = cursor;
        for _ in 0..15 {
            stream_now += Duration::from_secs(2);
            sched.mark_dirty(stream_now);
        }
        assert!(
            sched.should_flush(cursor + SNAPSHOT_MAX_INTERVAL),
            "continuous output must still checkpoint at SNAPSHOT_MAX_INTERVAL"
        );
    }

    #[test]
    fn flush_vt_snapshot_backs_off_on_missing_or_blocked_target_and_recovers_when_writable() {
        let base = PathBuf::from(format!("/tmp/omg-snap-recover-{}", &nonce().unwrap()[..8]));
        let sessions = base.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::set_permissions(&base, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();

        let id = "22222222-2222-2222-2222-222222222222";
        let record_path = sessions.join(format!("{id}.json"));
        let mut record = Record::new(id, crate::lifecycle::Policy::default()).unwrap();
        record.save(&record_path).unwrap();

        let managed = ManagedSession {
            path: record_path.clone(),
            record,
            containment_root: None,
            initial_cwd: None,
            local_launch: None,
            presentation: None,
            resurrect: false,
            shutdown_wake: None,
        };
        let mut vt = Vt::new(80, 24).unwrap();
        vt.write(b"RECOVERED_AFTER_TRANSIENT_FAILURE\r\n");

        // 1. Missing sessions/ directory (ENOENT): backs off cleanly and keeps dirty tracking.
        fs::remove_dir_all(&sessions).unwrap();
        let mut schedule = SnapshotSchedule::new(Instant::now() - Duration::from_secs(10));
        schedule.mark_dirty(Instant::now() - Duration::from_secs(5));
        assert!(schedule.should_flush(Instant::now()));

        flush_vt_snapshot(&vt, Some(&managed), &mut schedule);
        assert!(
            schedule.is_dirty(),
            "dirty state must be preserved on ENOENT"
        );
        assert!(
            !schedule.should_flush(Instant::now()),
            "must not immediately re-trigger flush after ENOENT"
        );
        let poll_ms = deadline_poll_ms(Instant::now(), schedule.next_deadline().unwrap());
        assert!(
            poll_ms > 2000,
            "poll timeout after failed snapshot must back off (>2000ms), got {poll_ms}ms"
        );

        // 2. Recreate sessions/ but block the destination snapshot path with a directory (EISDIR).
        fs::create_dir_all(&sessions).unwrap();
        fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();
        let mut restored_record = managed.record.clone();
        restored_record.save(&record_path).unwrap();
        let snap = snapshot_path(&record_path);
        fs::create_dir_all(snap.join("blocker")).unwrap();

        flush_vt_snapshot(&vt, Some(&managed), &mut schedule);
        assert!(schedule.is_dirty());
        assert_eq!(schedule.consecutive_failures, 2);
        let poll_ms_2 = deadline_poll_ms(Instant::now(), schedule.next_deadline().unwrap());
        assert!(
            poll_ms_2 > 5000,
            "second consecutive failure must double backoff (>5000ms), got {poll_ms_2}ms"
        );

        // 3. Remove blocker -> next flush succeeds and clears dirty tracking.
        fs::remove_dir_all(&snap).unwrap();
        flush_vt_snapshot(&vt, Some(&managed), &mut schedule);
        assert!(
            !schedule.is_dirty(),
            "snapshot flush must clear dirty tracking once target is writable"
        );
        assert_eq!(schedule.consecutive_failures, 0);
        assert!(snap.is_file());

        let loaded = load_snapshot(&record_path, managed.record.snapshot_revision.as_deref())
            .expect("recovered snapshot must load");
        let mut restored = Vt::new(80, 24).unwrap();
        restored.restore(&loaded).unwrap();
        assert!(restored
            .text()
            .unwrap()
            .contains("RECOVERED_AFTER_TRANSIENT_FAILURE"));

        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn socket_guard_and_superseded_record_preserve_replacement_session_files() {
        let dir = PathBuf::from(format!("/tmp/omg-sock-guard-{}", &nonce().unwrap()[..8]));
        let sessions = dir.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();

        let sock_path = dir.join("test.sock");
        let listener_1 = UnixListener::bind(&sock_path).unwrap();
        let guard_1 = SocketGuard::new(sock_path.clone());
        drop(listener_1);
        fs::remove_file(&sock_path).unwrap();
        let _listener_2 = UnixListener::bind(&sock_path).unwrap();
        let id_2 = file_identity(&sock_path);
        drop(guard_1);
        assert_eq!(
            file_identity(&sock_path),
            id_2,
            "dropping stale SocketGuard must not unlink replacement socket"
        );

        let id = "33333333-3333-3333-3333-333333333333";
        let record_path = sessions.join(format!("{id}.json"));
        let stale_record = Record::new(id, crate::lifecycle::Policy::default()).unwrap();
        let mut newer_record = Record::new(id, crate::lifecycle::Policy::default()).unwrap();
        newer_record.save(&record_path).unwrap();

        let mut newer_vt = Vt::new(80, 24).unwrap();
        newer_vt.write(b"NEWER_GENERATION_SNAPSHOT\r\n");
        let newer_encoded =
            encode_snapshot(&newer_vt, newer_record.snapshot_revision.as_deref()).unwrap();
        save_snapshot_atomic(&record_path, &newer_encoded).unwrap();

        let stale_managed = ManagedSession {
            path: record_path.clone(),
            record: stale_record,
            containment_root: None,
            initial_cwd: None,
            local_launch: None,
            presentation: None,
            resurrect: false,
            shutdown_wake: None,
        };
        let mut stale_vt = Vt::new(80, 24).unwrap();
        stale_vt.write(b"STALE_GENERATION_SNAPSHOT\r\n");
        let mut schedule = SnapshotSchedule::new(Instant::now());
        schedule.mark_dirty(Instant::now() - Duration::from_secs(5));
        flush_vt_snapshot(&stale_vt, Some(&stale_managed), &mut schedule);
        assert!(!schedule.is_dirty());

        let loaded =
            load_snapshot(&record_path, newer_record.snapshot_revision.as_deref()).unwrap();
        let mut check_vt = Vt::new(80, 24).unwrap();
        check_vt.restore(&loaded).unwrap();
        let text = check_vt.text().unwrap();
        assert!(text.contains("NEWER_GENERATION_SNAPSHOT"));
        assert!(!text.contains("STALE_GENERATION_SNAPSHOT"));

        fs::remove_dir_all(&dir).unwrap();
    }
}
