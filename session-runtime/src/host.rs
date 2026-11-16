//! One host daemon owns all session actors; transport connections multiplex
//! framed pane streams. Session workers are threads, never daemon subprocesses.
use crate::*;
use crate::{lifecycle::Policy, registry::Registry};
use std::{
    collections::VecDeque,
    fs,
    io::{Read, Write},
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::Path,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
const MAX_STREAMS: usize = 512;
const MAX_EXEC_STREAMS: usize = 32;
const MAX_EXEC_COMMAND_BYTES: usize = 256 * 1024;
const MAX_EXEC_OUTPUT_BYTES: usize = 64 * 1024 * 1024;
const MAX_EXEC_STDIN_BUFFER: usize = 32 * 1024 * 1024;
const EXEC_PIPE_CHUNK_BYTES: usize = 32 * 1024;
const MAX_LIST_ENTRIES: usize = 2048;
const MAX_LIST_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ExecOpen {
    pub command: String,
    pub max_output_bytes: usize,
}

struct ActiveExecGuard(Arc<AtomicUsize>);

impl Drop for ActiveExecGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

struct StreamEntry {
    peer: Peer,
    is_exec: bool,
    write_closed: bool,
}
struct HostLock(fs::File);
impl HostLock {
    fn acquire(directory: &Path) -> io::Result<Self> {
        use std::{
            io::Write,
            os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
        };
        let mut file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(directory.join("host.lock"))?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::other("host daemon already running"));
        }
        let _ = file.set_len(0);
        let _ = file.write_all(format!("{}\n", std::process::id()).as_bytes());
        let _ = file.flush();
        Ok(Self(file))
    }
}
impl Drop for HostLock {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
pub(crate) fn inner_frame(data: &[u8]) -> io::Result<Frame> {
    let mut input = data;
    let frame = Frame::read(&mut input)?;
    if !input.is_empty() {
        return Err(io::Error::other("trailing inner frame bytes"));
    }
    Ok(frame)
}
pub(crate) fn private(path: &Path) -> io::Result<()> {
    let m = fs::symlink_metadata(path)?;
    if !m.is_dir() || m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o077 != 0 {
        return Err(io::Error::other(
            "directory must be private and owned by current user",
        ));
    }
    Ok(())
}
pub fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
/// Outer protocol: H(stream, UUID), D(stream, encoded inner frame), E(stream,error),
/// Q(stream) detach. Outer stream IDs are local to one transport connection.
pub fn serve(directory: &Path, command: Vec<String>) -> io::Result<()> {
    serve_mode(directory, command, false)
}

pub fn serve_local(directory: &Path, command: Vec<String>) -> io::Result<()> {
    serve_mode(directory, command, true)
}

fn raise_nofile_limit() {
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } == 0 {
        let desired = 4096 as libc::rlim_t;
        let target = if limit.rlim_max == libc::RLIM_INFINITY {
            desired
        } else {
            desired.min(limit.rlim_max)
        };
        if limit.rlim_cur < target {
            limit.rlim_cur = target;
            unsafe {
                libc::setrlimit(libc::RLIMIT_NOFILE, &limit);
            }
        }
    }
}

fn serve_mode(directory: &Path, command: Vec<String>, local: bool) -> io::Result<()> {
    raise_nofile_limit();
    private(directory)?;
    let policy_path = directory.join("policy.json");
    let policy: Policy = if policy_path.exists() {
        serde_json::from_slice(&fs::read(&policy_path)?)?
    } else {
        Policy::default()
    };
    policy.validate()?;
    let _lock = HostLock::acquire(directory)?;
    if local {
        if let Some(support) = crate::registry::infer_support_root_from_env_or_exe() {
            let preserve_existing = crate::registry::read_support_root_stamp(directory)
                .is_some_and(|existing| crate::registry::same_canonical_path(&existing, &support));
            if !preserve_existing {
                let _ = crate::registry::write_support_root_stamp(directory, &support);
            }
        }
    }
    let _ = fs::remove_file(directory.join("host.sock"));
    let root = directory.join("sessions");
    fs::create_dir_all(&root)?;
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
    private(&root)?;
    let listener = UnixListener::bind(directory.join("host.sock"))?;
    fs::set_permissions(
        directory.join("host.sock"),
        fs::Permissions::from_mode(0o600),
    )?;
    listener.set_nonblocking(true)?;
    let wake = WakePipe::new()?;
    let mut initial = if local {
        Registry::new_local(root, command, policy.clone())
    } else {
        Registry::new(root, command, policy.clone())
    };
    initial.set_wakeup(wake.clone());
    if !local {
        initial.set_containment_root(crate::containment::host_root()?);
    }
    initial.maintenance();
    let registry = Arc::new(Mutex::new(initial));
    let active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let mut idle_since = Instant::now();
    loop {
        wake.drain();
        Registry::maintenance_unlocked(&registry, false);
        if !directory.join("sessions").exists()
            && active.load(std::sync::atomic::Ordering::SeqCst) == 0
        {
            return Ok(());
        }
        let timeout_ms = {
            let state = registry.lock().unwrap_or_else(|p| p.into_inner());
            if !state.is_empty() || active.load(std::sync::atomic::Ordering::SeqCst) > 0 {
                idle_since = Instant::now();
                30_000
            } else if idle_since.elapsed() > Duration::from_secs(policy.host_idle_seconds) {
                let _ = fs::remove_file(directory.join("host.sock"));
                return Ok(());
            } else {
                let deadline = idle_since
                    + Duration::from_secs(policy.host_idle_seconds)
                    + Duration::from_nanos(1);
                deadline_poll_ms(Instant::now(), deadline).min(30_000)
            }
        };
        let socket = match listener.accept() {
            Ok((s, _)) => s,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                use std::os::fd::AsRawFd;
                let mut descriptors = [
                    libc::pollfd {
                        fd: listener.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    },
                    wake.poll_fd(),
                ];
                poll_fds(&mut descriptors, timeout_ms)?;
                continue;
            }
            Err(e) => return Err(e),
        };
        if active.fetch_add(1, std::sync::atomic::Ordering::SeqCst) >= 64 {
            active.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            continue;
        }
        let registry = registry.clone();
        let active = active.clone();
        let wake = wake.clone();
        std::thread::spawn(move || {
            struct ActiveGuard {
                active: Arc<std::sync::atomic::AtomicUsize>,
                wake: WakePipe,
            }
            impl Drop for ActiveGuard {
                fn drop(&mut self) {
                    self.active
                        .fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                    self.wake.notify();
                }
            }
            let _guard = ActiveGuard { active, wake };
            let _ = host_connection(socket, registry);
        });
    }
}
fn host_connection(socket: UnixStream, registry: Arc<Mutex<Registry>>) -> io::Result<()> {
    host_connection_with_limit(socket, registry, MAX_STREAMS)
}

fn host_connection_with_limit(
    socket: UnixStream,
    registry: Arc<Mutex<Registry>>,
    max_streams: usize,
) -> io::Result<()> {
    let mut transport = Peer::new(socket, 0)?;
    let mut streams: std::collections::HashMap<u64, StreamEntry> = Default::default();
    let active_execs = Arc::new(AtomicUsize::new(0));
    let mut last_heartbeat = Instant::now();
    loop {
        if last_heartbeat.elapsed() > Duration::from_secs(45) {
            return Err(io::Error::other("host connection lease expired"));
        }
        for f in transport.read()? {
            last_heartbeat = Instant::now();
            match f.kind {
                b'P' if f.seq == 0 => {
                    let is_local = registry
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .is_local();
                    let capabilities = if is_local {
                        b"durable-close/1,strict-open/1,local-launch/1,local-resurrect/1,inline-viewer/1,agent-state/1,holder-presentation/1,recreate-if-gone/1,exec/1".as_slice()
                    } else {
                        b"durable-close/1,strict-open/1,inline-viewer/1,agent-state/1,recreate-if-gone/1,exec/1".as_slice()
                    };
                    transport.push(Frame::new(b'P', 0, capabilities));
                }
                b'K' if f.seq != 0 => {
                    let result = std::str::from_utf8(&f.data)
                        .map_err(io::Error::other)
                        .and_then(|id| Registry::close_unlocked(&registry, id));
                    match result {
                        Ok(done) => transport.push(Frame::new(
                            b'D',
                            f.seq,
                            &Frame::new(b'K', 0, if done { b"closed" } else { b"pending" })
                                .encode(),
                        )),
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                }
                b'L' if f.seq == 0 && f.data.is_empty() => {
                    let response = (|| {
                        let summary = Registry::catalogue_summaries_unlocked(&registry)?;
                        if summary.len() > MAX_LIST_ENTRIES {
                            return Err(io::Error::other("session catalogue exceeds entry limit"));
                        }
                        let bytes = serde_json::to_vec(&summary)?;
                        if bytes.len() > MAX_LIST_BYTES {
                            return Err(io::Error::other("session catalogue exceeds size limit"));
                        }
                        Ok(bytes)
                    })();
                    match response {
                        Ok(bytes) => transport.push(Frame::new(b'L', 0, &bytes)),
                        Err(error) => {
                            transport.push(Frame::new(b'E', 0, error.to_string().as_bytes()))
                        }
                    }
                }
                b'L' if f.seq == 0 => {
                    transport.push(Frame::new(b'E', 0, b"invalid catalogue request"));
                }
                b'U' | b'C' | b'H' | b'x'
                    if f.seq != 0
                        && (streams.contains_key(&f.seq) || streams.len() >= max_streams) =>
                {
                    transport.push(Frame::new(b'E', f.seq, b"host stream limit reached"));
                    let _ = transport.flush();
                }
                b'U' if f.seq != 0 => {
                    #[derive(serde::Deserialize)]
                    struct Request {
                        id: String,
                        generation: String,
                    }
                    let req: Request = serde_json::from_slice(&f.data)?;
                    match Registry::connect_unlocked(
                        &registry,
                        &req.id,
                        Some(&req.generation),
                        false,
                    ) {
                        Ok(s) => {
                            streams.insert(
                                f.seq,
                                StreamEntry {
                                    peer: Peer::new(s, f.seq)?,
                                    is_exec: false,
                                    write_closed: false,
                                },
                            );
                        }
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                    let _ = transport.flush();
                }
                b'C' if f.seq != 0 => {
                    let request: crate::registry::OpenRequest = serde_json::from_slice(&f.data)?;
                    let result = Registry::open_unlocked(&registry, &request);
                    match result {
                        Ok(s) => {
                            streams.insert(
                                f.seq,
                                StreamEntry {
                                    peer: Peer::new(s, f.seq)?,
                                    is_exec: false,
                                    write_closed: false,
                                },
                            );
                        }
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                    let _ = transport.flush();
                }
                b'H' if f.seq != 0 => {
                    let result = std::str::from_utf8(&f.data)
                        .map_err(io::Error::other)
                        .and_then(|id| Registry::connect_unlocked(&registry, id, None, true));
                    match result {
                        Ok(s) => {
                            streams.insert(
                                f.seq,
                                StreamEntry {
                                    peer: Peer::new(s, f.seq)?,
                                    is_exec: false,
                                    write_closed: false,
                                },
                            );
                        }
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                    let _ = transport.flush();
                }
                b'x' if f.seq != 0 => {
                    if active_execs.fetch_add(1, Ordering::SeqCst) >= MAX_EXEC_STREAMS {
                        active_execs.fetch_sub(1, Ordering::SeqCst);
                        transport.push(Frame::new(
                            b'E',
                            f.seq,
                            b"too many concurrent exec requests",
                        ));
                        let _ = transport.flush();
                        continue;
                    }
                    let guard = ActiveExecGuard(active_execs.clone());
                    let Ok(mut req) = serde_json::from_slice::<ExecOpen>(&f.data) else {
                        transport.push(Frame::new(b'E', f.seq, b"invalid exec request"));
                        let _ = transport.flush();
                        continue;
                    };
                    if req.command.is_empty()
                        || req.command.len() > MAX_EXEC_COMMAND_BYTES
                        || req.command.contains('\0')
                    {
                        transport.push(Frame::new(b'E', f.seq, b"invalid exec command"));
                        let _ = transport.flush();
                        continue;
                    }
                    req.max_output_bytes = req.max_output_bytes.clamp(1, MAX_EXEC_OUTPUT_BYTES);
                    let pair = UnixStream::pair().and_then(|(host_side, worker_side)| {
                        Ok((Peer::new(host_side, f.seq)?, worker_side))
                    });
                    match pair {
                        Ok((host_peer, worker_side)) => {
                            match std::thread::Builder::new()
                                .name("omg-exec".into())
                                .spawn(move || run_exec_worker(worker_side, req, guard))
                            {
                                Ok(_) => {
                                    streams.insert(
                                        f.seq,
                                        StreamEntry {
                                            peer: host_peer,
                                            is_exec: true,
                                            write_closed: false,
                                        },
                                    );
                                }
                                Err(error) => {
                                    transport.push(Frame::new(
                                        b'E',
                                        f.seq,
                                        format!("exec worker spawn failed: {error}").as_bytes(),
                                    ));
                                    let _ = transport.flush();
                                }
                            }
                        }
                        Err(error) => {
                            transport.push(Frame::new(
                                b'E',
                                f.seq,
                                format!("exec stream setup failed: {error}").as_bytes(),
                            ));
                            let _ = transport.flush();
                        }
                    }
                }
                b'D' => {
                    if let Some(entry) = streams.get_mut(&f.seq) {
                        let inner = inner_frame(&f.data)?;
                        if !entry.write_closed {
                            entry.peer.push(inner);
                        }
                    }
                }
                b'Q' => {
                    streams.remove(&f.seq);
                }
                _ => return Err(io::Error::other("invalid multiplex frame")),
            }
        }
        for (&id, entry) in &mut streams {
            if transport.queued_bytes() < crate::MAX_QUEUE / 2 {
                let max_reads = if entry.is_exec { 64 } else { 1 };
                for _ in 0..max_reads {
                    let prev_incoming = entry.peer.incoming.len();
                    match entry.peer.read() {
                        Ok(frames) => {
                            let got_frames = !frames.is_empty();
                            for f in frames {
                                transport.push(Frame::new(b'D', id, &f.encode()));
                            }
                            if transport.queued_bytes() >= crate::MAX_QUEUE / 2
                                || (!got_frames && entry.peer.incoming.len() == prev_incoming)
                            {
                                break;
                            }
                        }
                        Err(_) => {
                            entry.peer.dead = true;
                            break;
                        }
                    }
                }
            }
            if !entry.write_closed && entry.peer.flush().is_err() {
                if entry.is_exec {
                    entry.write_closed = true;
                    entry.peer.discard_queued_output();
                } else {
                    entry.peer.dead = true;
                }
            }
            if entry.peer.dead {
                transport.push(Frame::new(b'Q', id, &[]));
            }
        }
        streams.retain(|_, entry| !entry.peer.dead);
        transport.flush()?;
        if transport.dead {
            return Err(io::Error::other("transport backlog exceeded"));
        }
        let allow_stream_read = transport.queued_bytes() < crate::MAX_QUEUE / 2;
        let mut descriptors = Vec::with_capacity(streams.len() + 1);
        descriptors.push(transport.poll_fd());
        for entry in streams.values() {
            let mut pfd = entry.peer.poll_fd();
            if !allow_stream_read {
                pfd.events &= !libc::POLLIN;
            }
            if entry.write_closed {
                pfd.events &= !libc::POLLOUT;
            }
            if pfd.events != 0 {
                descriptors.push(pfd);
            }
        }
        let timeout_ms = deadline_poll_ms(
            Instant::now(),
            last_heartbeat + Duration::from_secs(45) + Duration::from_nanos(1),
        );
        poll_fds(&mut descriptors, timeout_ms)?;
    }
}

fn set_nonblocking_fd(fd: std::os::fd::RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn kill_and_reap(pgid: libc::pid_t, child: &mut std::process::Child) {
    unsafe {
        libc::kill(-pgid, libc::SIGKILL);
    }
    let _ = child.wait();
}

fn flush_peer_blocking(worker: &mut Peer) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !worker.dead && worker.queued_bytes() > 0 {
        if worker.flush().is_err() || worker.queued_bytes() == 0 {
            break;
        }
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        use std::os::fd::AsRawFd;
        let mut pfd = [libc::pollfd {
            fd: worker.socket.as_raw_fd(),
            events: libc::POLLOUT,
            revents: 0,
        }];
        let timeout = deadline_poll_ms(now, deadline);
        if poll_fds(&mut pfd, timeout).is_err() {
            break;
        }
        if pfd[0].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            let _ = worker.flush();
            break;
        }
    }
}

enum PipeRead {
    Ok,
    Eof,
    LimitExceeded,
}

fn drain_child_pipe<R: Read>(
    pipe: &mut R,
    frame_kind: u8,
    worker: &mut Peer,
    total_output_bytes: &mut usize,
    max_output_bytes: usize,
    buf: &mut [u8],
) -> PipeRead {
    while worker.queued_bytes() < crate::MAX_QUEUE / 2 {
        match pipe.read(buf) {
            Ok(0) => return PipeRead::Eof,
            Ok(n) => {
                *total_output_bytes = total_output_bytes.saturating_add(n);
                if *total_output_bytes > max_output_bytes {
                    return PipeRead::LimitExceeded;
                }
                worker.push(Frame::new(frame_kind, 0, &buf[..n]));
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return PipeRead::Ok,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return PipeRead::Eof,
        }
    }
    PipeRead::Ok
}

fn run_exec_worker(worker_side: UnixStream, req: ExecOpen, _guard: ActiveExecGuard) {
    use std::os::{
        fd::AsRawFd,
        unix::process::{CommandExt, ExitStatusExt},
    };
    let Ok(mut worker) = Peer::new(worker_side, 0) else {
        return;
    };
    let mut cmd = std::process::Command::new("/bin/sh");
    cmd.arg("-c")
        .arg(&req.command)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .process_group(0);
    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(error) => {
            worker.push(Frame::new(
                b'E',
                0,
                format!("exec spawn failed: {error}").as_bytes(),
            ));
            flush_peer_blocking(&mut worker);
            return;
        }
    };
    let pgid = child.id() as libc::pid_t;
    let mut child_stdin = child.stdin.take();
    let mut child_stdout = child.stdout.take();
    let mut child_stderr = child.stderr.take();
    if let Some(stdin) = &child_stdin {
        if let Err(error) = set_nonblocking_fd(stdin.as_raw_fd()) {
            kill_and_reap(pgid, &mut child);
            worker.push(Frame::new(b'E', 0, error.to_string().as_bytes()));
            flush_peer_blocking(&mut worker);
            return;
        }
    }
    if let Some(stdout) = &child_stdout {
        if let Err(error) = set_nonblocking_fd(stdout.as_raw_fd()) {
            kill_and_reap(pgid, &mut child);
            worker.push(Frame::new(b'E', 0, error.to_string().as_bytes()));
            flush_peer_blocking(&mut worker);
            return;
        }
    }
    if let Some(stderr) = &child_stderr {
        if let Err(error) = set_nonblocking_fd(stderr.as_raw_fd()) {
            kill_and_reap(pgid, &mut child);
            worker.push(Frame::new(b'E', 0, error.to_string().as_bytes()));
            flush_peer_blocking(&mut worker);
            return;
        }
    }

    let mut stdin_buf: VecDeque<u8> = VecDeque::new();
    let mut stdin_eof = false;
    let mut total_output_bytes: usize = 0;
    let mut out_chunk = [0u8; EXEC_PIPE_CHUNK_BYTES];
    let mut wait_backoff_ms: libc::c_int = 1;

    loop {
        match worker.read() {
            Ok(frames) => {
                for frame in frames {
                    match frame.kind {
                        b'i' if !stdin_eof && child_stdin.is_some() => {
                            if stdin_buf.len().saturating_add(frame.data.len())
                                > MAX_EXEC_STDIN_BUFFER
                            {
                                kill_and_reap(pgid, &mut child);
                                worker.push(Frame::new(
                                    b'E',
                                    0,
                                    b"exec stdin buffer limit exceeded",
                                ));
                                flush_peer_blocking(&mut worker);
                                return;
                            }
                            stdin_buf.extend(frame.data);
                        }
                        b'z' => {
                            stdin_eof = true;
                        }
                        _ => {}
                    }
                }
            }
            Err(_) => {
                kill_and_reap(pgid, &mut child);
                return;
            }
        }

        while let Some(stdin) = child_stdin.as_mut() {
            if stdin_buf.is_empty() {
                break;
            }
            let (head, _) = stdin_buf.as_slices();
            match stdin.write(head) {
                Ok(0) => {
                    child_stdin = None;
                    stdin_buf.clear();
                    break;
                }
                Ok(n) => {
                    stdin_buf.drain(..n);
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    child_stdin = None;
                    stdin_buf.clear();
                    break;
                }
            }
        }
        if stdin_eof && stdin_buf.is_empty() {
            child_stdin = None;
        }

        if let Some(stdout) = child_stdout.as_mut() {
            match drain_child_pipe(
                stdout,
                b'o',
                &mut worker,
                &mut total_output_bytes,
                req.max_output_bytes,
                &mut out_chunk,
            ) {
                PipeRead::Ok => {}
                PipeRead::Eof => child_stdout = None,
                PipeRead::LimitExceeded => {
                    kill_and_reap(pgid, &mut child);
                    worker.push(Frame::new(b'E', 0, b"output-limit-exceeded"));
                    flush_peer_blocking(&mut worker);
                    return;
                }
            }
        }
        if let Some(stderr) = child_stderr.as_mut() {
            match drain_child_pipe(
                stderr,
                b'e',
                &mut worker,
                &mut total_output_bytes,
                req.max_output_bytes,
                &mut out_chunk,
            ) {
                PipeRead::Ok => {}
                PipeRead::Eof => child_stderr = None,
                PipeRead::LimitExceeded => {
                    kill_and_reap(pgid, &mut child);
                    worker.push(Frame::new(b'E', 0, b"output-limit-exceeded"));
                    flush_peer_blocking(&mut worker);
                    return;
                }
            }
        }

        if worker.flush().is_err() || worker.dead {
            kill_and_reap(pgid, &mut child);
            return;
        }

        if child_stdout.is_none() && child_stderr.is_none() {
            match child.try_wait() {
                Ok(Some(status)) => {
                    let exit_code = status
                        .code()
                        .or_else(|| status.signal().map(|sig| 128i32.saturating_add(sig)))
                        .unwrap_or(1)
                        .clamp(0, 255);
                    worker.push(Frame::new(b'x', 0, exit_code.to_string().as_bytes()));
                    flush_peer_blocking(&mut worker);
                    return;
                }
                Ok(None) => {}
                Err(error) => {
                    kill_and_reap(pgid, &mut child);
                    worker.push(Frame::new(b'E', 0, error.to_string().as_bytes()));
                    flush_peer_blocking(&mut worker);
                    return;
                }
            }
        }

        let mut descriptors = Vec::with_capacity(4);
        descriptors.push(worker.poll_fd());
        if let Some(stdin) = &child_stdin {
            if !stdin_buf.is_empty() {
                descriptors.push(libc::pollfd {
                    fd: stdin.as_raw_fd(),
                    events: libc::POLLOUT,
                    revents: 0,
                });
            }
        }
        if worker.queued_bytes() < crate::MAX_QUEUE / 2 {
            if let Some(stdout) = &child_stdout {
                descriptors.push(libc::pollfd {
                    fd: stdout.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                });
            }
            if let Some(stderr) = &child_stderr {
                descriptors.push(libc::pollfd {
                    fd: stderr.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                });
            }
        }
        let timeout_ms = if child_stdout.is_none() && child_stderr.is_none() {
            let current = wait_backoff_ms;
            wait_backoff_ms = (wait_backoff_ms * 2).min(25);
            current
        } else {
            -1
        };
        if poll_fds(&mut descriptors, timeout_ms).is_err() {
            kill_and_reap(pgid, &mut child);
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_connection_wakes_on_socket_activity_without_busy_polling() {
        let nonce = crate::record::nonce().unwrap();
        let root = std::env::temp_dir().join(format!("omg-host-poll-{}", &nonce[..8]));
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();

        let registry = Arc::new(Mutex::new(Registry::new_local(
            sessions,
            vec!["/bin/sh".into()],
            Policy::default(),
        )));
        let (server_sock, mut client_sock) = UnixStream::pair().unwrap();
        client_sock
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let handle = std::thread::spawn(move || host_connection(server_sock, registry));

        std::thread::sleep(Duration::from_millis(20));
        let started = Instant::now();
        Frame::new(b'P', 0, &[]).send(&mut client_sock).unwrap();
        let reply = Frame::read(&mut client_sock).unwrap();
        assert_eq!(reply.kind, b'P');
        assert!(started.elapsed() < Duration::from_millis(250));

        drop(client_sock);
        let _ = handle.join().unwrap();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn host_connection_heartbeat_is_not_blocked_by_concurrent_stalled_holder_probe() {
        let nonce = crate::record::nonce().unwrap();
        let root = std::env::temp_dir().join(format!("omg-host-lockfree-{}", &nonce[..8]));
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();

        let stalled_id = "abababab-abab-abab-abab-abababababab";
        let mut rec = crate::record::Record::new(stalled_id, Policy::default()).unwrap();
        rec.pid = Some(99_999);
        rec.holder_capability = Some("cap-stalled".into());
        rec.save(&sessions.join(format!("{stalled_id}.json")))
            .unwrap();

        use sha2::{Digest, Sha256};
        let key = format!("{:x}", Sha256::digest(stalled_id.as_bytes()));
        let ctl_path = root.join(format!("{}.ctl", &key[..16]));
        let ctl_listener = UnixListener::bind(&ctl_path).unwrap();
        ctl_listener.set_nonblocking(true).unwrap();
        let stop_ctl = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop_ctl_thread = stop_ctl.clone();
        let held_accept = std::thread::spawn(move || {
            let mut held = Vec::new();
            let deadline = Instant::now() + Duration::from_millis(700);
            while !stop_ctl_thread.load(std::sync::atomic::Ordering::SeqCst)
                && Instant::now() < deadline
            {
                if let Ok((accepted, _)) = ctl_listener.accept() {
                    held.push(accepted);
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            drop(held);
        });

        let registry = Arc::new(Mutex::new(Registry::new_local(
            sessions,
            vec!["/bin/sh".into()],
            Policy::default(),
        )));

        let (srv1, mut cli1) = UnixStream::pair().unwrap();
        let (srv2, mut cli2) = UnixStream::pair().unwrap();
        cli1.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        cli2.set_read_timeout(Some(Duration::from_secs(1))).unwrap();

        let reg1 = registry.clone();
        let h1 = std::thread::spawn(move || host_connection(srv1, reg1));
        let h2 = std::thread::spawn(move || host_connection(srv2, registry));

        let attach = serde_json::to_vec(&serde_json::json!({
            "id": stalled_id,
            "generation": rec.generation,
        }))
        .unwrap();
        Frame::new(b'U', 1, &attach).send(&mut cli1).unwrap();
        // Give `h1` 40ms to enter `probe_with_timeout` on `ctl_listener`.
        std::thread::sleep(Duration::from_millis(40));

        let ping_started = Instant::now();
        Frame::new(b'P', 0, &[]).send(&mut cli2).unwrap();
        let reply = Frame::read(&mut cli2).unwrap();
        let ping_elapsed = ping_started.elapsed();
        assert_eq!(reply.kind, b'P');
        assert!(
            ping_elapsed < Duration::from_millis(250),
            "heartbeat blocked behind stalled holder probe: {ping_elapsed:?}"
        );

        let attach_reply = Frame::read(&mut cli1).unwrap();
        assert_eq!(attach_reply.kind, b'E');

        stop_ctl.store(true, std::sync::atomic::Ordering::SeqCst);
        drop(cli1);
        drop(cli2);
        let _ = held_accept.join();
        let _ = h1.join();
        let _ = h2.join();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn host_connection_advertises_recreate_if_gone_and_rejects_stream_limit_without_killing_transport(
    ) {
        let nonce = crate::record::nonce().unwrap();
        let root = std::env::temp_dir().join(format!("omg-host-limit-{}", &nonce[..8]));
        let remote_sessions = root.join("remote/sessions");
        let local_sessions = root.join("local/sessions");
        fs::create_dir_all(&remote_sessions).unwrap();
        fs::create_dir_all(&local_sessions).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(root.join("remote"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&remote_sessions, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(root.join("local"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&local_sessions, fs::Permissions::from_mode(0o700)).unwrap();

        let local_reg = Arc::new(Mutex::new(Registry::new_local(
            local_sessions,
            vec!["/bin/sh".into()],
            Policy::default(),
        )));
        let (local_srv, mut local_cli) = UnixStream::pair().unwrap();
        local_cli
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let local_handle = std::thread::spawn(move || host_connection(local_srv, local_reg));
        Frame::new(b'P', 0, &[]).send(&mut local_cli).unwrap();
        let local_caps = Frame::read(&mut local_cli).unwrap();
        assert_eq!(local_caps.kind, b'P');
        let local_caps_str = String::from_utf8_lossy(&local_caps.data);
        assert!(local_caps_str.contains("recreate-if-gone/1"));
        assert!(local_caps_str.split(',').any(|c| c == "exec/1"));
        drop(local_cli);
        let _ = local_handle.join();

        let remote_reg = Arc::new(Mutex::new(Registry::new(
            remote_sessions,
            vec!["/bin/sh".into(), "-i".into()],
            Policy::default(),
        )));
        let (srv, mut cli) = UnixStream::pair().unwrap();
        cli.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let handle = std::thread::spawn(move || host_connection_with_limit(srv, remote_reg, 1));

        Frame::new(b'P', 0, &[]).send(&mut cli).unwrap();
        let caps = Frame::read(&mut cli).unwrap();
        assert_eq!(caps.kind, b'P');
        let caps_str = String::from_utf8_lossy(&caps.data);
        assert!(caps_str.contains("recreate-if-gone/1"));
        assert!(caps_str.split(',').any(|c| c == "exec/1"));

        let id1 = "11111111-1111-4111-8111-111111111111";
        let id2 = "22222222-2222-4222-8222-222222222222";
        Frame::new(b'H', 10, id1.as_bytes()).send(&mut cli).unwrap();
        loop {
            let f = Frame::read(&mut cli).unwrap();
            if f.kind == b'D' && f.seq == 10 {
                let inner = inner_frame(&f.data).unwrap();
                if inner.kind == SNAPSHOT {
                    Frame::new(b'D', 10, &Frame::new(ACK, inner.seq, &[]).encode())
                        .send(&mut cli)
                        .unwrap();
                    break;
                }
            }
        }

        // Duplicate seq 10 must return b'E' without breaking the transport.
        Frame::new(b'H', 10, id2.as_bytes()).send(&mut cli).unwrap();
        let dup_err = loop {
            let f = Frame::read(&mut cli).unwrap();
            if f.kind == b'E' && f.seq == 10 {
                break f;
            }
        };
        assert_eq!(dup_err.data, b"host stream limit reached");

        // Reaching max_streams (1) on seq 11 must return b'E' without breaking stream 10.
        Frame::new(b'H', 11, id2.as_bytes()).send(&mut cli).unwrap();
        let limit_err = loop {
            let f = Frame::read(&mut cli).unwrap();
            if f.kind == b'E' && f.seq == 11 {
                break f;
            }
        };
        assert_eq!(limit_err.data, b"host stream limit reached");

        // Reaching max_streams (1) on exec seq 13 must also return b'E'.
        let exec_payload = serde_json::to_vec(&ExecOpen {
            command: "echo ok".into(),
            max_output_bytes: 1024,
        })
        .unwrap();
        Frame::new(b'x', 13, &exec_payload).send(&mut cli).unwrap();
        let exec_limit_err = loop {
            let f = Frame::read(&mut cli).unwrap();
            if f.kind == b'E' && f.seq == 13 {
                break f;
            }
        };
        assert_eq!(exec_limit_err.data, b"host stream limit reached");

        // Stream 10 and transport heartbeat remain completely healthy.
        Frame::new(b'P', 0, &[]).send(&mut cli).unwrap();
        let pong = loop {
            let f = Frame::read(&mut cli).unwrap();
            if f.kind == b'P' {
                break f;
            }
        };
        assert_eq!(pong.seq, 0);

        for _ in 0..20 {
            Frame::new(b'K', 12, id1.as_bytes()).send(&mut cli).unwrap();
            let reply = loop {
                let f = Frame::read(&mut cli).unwrap();
                if f.kind == b'D' && f.seq == 12 {
                    break inner_frame(&f.data).unwrap();
                }
            };
            if reply.kind == b'K' && reply.data == b"closed" {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        drop(cli);
        let _ = handle.join();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn host_exec_validates_payload_and_enforces_max_exec_streams() {
        raise_nofile_limit();
        let nonce = crate::record::nonce().unwrap();
        let root = std::env::temp_dir().join(format!("omg-host-exec-cap-{}", &nonce[..8]));
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();

        let registry = Arc::new(Mutex::new(Registry::new_local(
            sessions,
            vec!["/bin/sh".into()],
            Policy::default(),
        )));
        let (srv, mut cli) = UnixStream::pair().unwrap();
        cli.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let handle = std::thread::spawn(move || host_connection(srv, registry));

        // Empty command and oversized command must fail with b'E' without breaking transport.
        for (seq, cmd) in [
            (1u64, String::new()),
            (2u64, "a\0b".into()),
            (3u64, "x".repeat(MAX_EXEC_COMMAND_BYTES + 1)),
        ] {
            let payload = serde_json::to_vec(&ExecOpen {
                command: cmd,
                max_output_bytes: 1024,
            })
            .unwrap();
            Frame::new(b'x', seq, &payload).send(&mut cli).unwrap();
            let err = Frame::read(&mut cli).unwrap();
            assert_eq!(err.kind, b'E');
            assert_eq!(err.seq, seq);
        }

        // Open MAX_EXEC_STREAMS (32) sleeping commands; 33rd must be rejected.
        let sleep_payload = serde_json::to_vec(&ExecOpen {
            command: "sleep 30".into(),
            max_output_bytes: 1024,
        })
        .unwrap();
        for seq in 100..100 + MAX_EXEC_STREAMS as u64 {
            Frame::new(b'x', seq, &sleep_payload)
                .send(&mut cli)
                .unwrap();
        }
        // Wait for worker threads to be active by sending a ping after all opens, or check 33rd.
        Frame::new(b'x', 200, &sleep_payload)
            .send(&mut cli)
            .unwrap();
        let overflow = loop {
            let f = Frame::read(&mut cli).unwrap();
            if f.seq == 200 {
                break f;
            }
        };
        assert_eq!(
            overflow.kind,
            b'E',
            "expected outer b'E', got {} with payload {:?}",
            overflow.kind as char,
            String::from_utf8_lossy(&overflow.data)
        );
        assert_eq!(overflow.data, b"too many concurrent exec requests");

        // Cancel all 32 active streams and verify a new exec succeeds afterwards.
        for seq in 100..100 + MAX_EXEC_STREAMS as u64 {
            Frame::new(b'Q', seq, &[]).send(&mut cli).unwrap();
        }
        let ok_payload = serde_json::to_vec(&ExecOpen {
            command: "printf 'reclaimed'".into(),
            max_output_bytes: 1024,
        })
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut seq_try = 300u64;
        let reclaimed_ok = loop {
            Frame::new(b'x', seq_try, &ok_payload)
                .send(&mut cli)
                .unwrap();
            let mut got_output = Vec::new();
            let mut got_exit = None;
            let mut got_busy = false;
            loop {
                let f = Frame::read(&mut cli).unwrap();
                if f.seq != seq_try {
                    continue;
                }
                match f.kind {
                    b'E' if f.data == b"too many concurrent exec requests" => {
                        got_busy = true;
                        break;
                    }
                    b'D' => {
                        let inner = inner_frame(&f.data).unwrap();
                        if inner.kind == b'o' {
                            got_output.extend_from_slice(&inner.data);
                        } else if inner.kind == b'x' {
                            got_exit = Some(inner.data);
                        }
                    }
                    b'Q' => break,
                    other => panic!("unexpected frame kind {other}"),
                }
            }
            if !got_busy {
                assert_eq!(got_output, b"reclaimed");
                assert_eq!(got_exit.as_deref(), Some(b"0".as_slice()));
                break true;
            }
            assert!(Instant::now() < deadline);
            seq_try += 1;
            std::thread::sleep(Duration::from_millis(20));
        };
        assert!(reclaimed_ok);

        drop(cli);
        let _ = handle.join();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn host_exec_handles_unconsumed_large_stdin_before_fast_exit_and_kills_pgid_on_cancel() {
        let nonce = crate::record::nonce().unwrap();
        let root = std::env::temp_dir().join(format!("omg-host-exec-pgid-{}", &nonce[..8]));
        let sessions = root.join("sessions");
        fs::create_dir_all(&sessions).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700)).unwrap();

        let registry = Arc::new(Mutex::new(Registry::new_local(
            sessions,
            vec!["/bin/sh".into()],
            Policy::default(),
        )));
        let (srv, mut cli) = UnixStream::pair().unwrap();
        cli.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let handle = std::thread::spawn(move || host_connection(srv, registry));

        // 1) Fast exit with 32 KiB output while unconsumed stdin is in flight must deliver b'o' and b'x'.
        let fast_payload = serde_json::to_vec(&ExecOpen {
            command: "python3 -c 'import sys; sys.stdout.buffer.write(b\"A\" * 32768)'".into(),
            max_output_bytes: 64 * 1024,
        })
        .unwrap();
        Frame::new(b'x', 1, &fast_payload).send(&mut cli).unwrap();
        let big_in = vec![b'Z'; 64 * 1024];
        for _ in 0..4 {
            Frame::new(b'D', 1, &Frame::new(b'i', 0, &big_in).encode())
                .send(&mut cli)
                .unwrap();
        }
        let mut out = Vec::new();
        let mut exit = None;
        loop {
            let f = Frame::read(&mut cli).unwrap();
            assert_eq!(f.seq, 1);
            match f.kind {
                b'D' => {
                    let inner = inner_frame(&f.data).unwrap();
                    match inner.kind {
                        b'o' => out.extend_from_slice(&inner.data),
                        b'x' => exit = Some(inner.data),
                        other => panic!("unexpected inner frame {other}"),
                    }
                }
                b'Q' => break,
                other => panic!("unexpected outer frame {other}"),
            }
        }
        assert_eq!(out.len(), 32768);
        assert_eq!(exit.as_deref(), Some(b"0".as_slice()));

        // 2) Cancel mid-flight kills child and grandchild in process group.
        let pid_file = root.join("grandchild.pid");
        let cancel_payload = serde_json::to_vec(&ExecOpen {
            command: format!("sleep 30 & echo $! > '{}'; wait", pid_file.display()),
            max_output_bytes: 4096,
        })
        .unwrap();
        Frame::new(b'x', 2, &cancel_payload).send(&mut cli).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        let child_pid = loop {
            if let Ok(text) = fs::read_to_string(&pid_file) {
                if let Ok(pid) = text.trim().parse::<libc::pid_t>() {
                    break pid;
                }
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(15));
        };
        Frame::new(b'Q', 2, &[]).send(&mut cli).unwrap();
        let kill_deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < kill_deadline {
            if unsafe { libc::kill(child_pid, 0) } != 0 {
                break;
            }
            std::thread::sleep(Duration::from_millis(15));
        }
        assert_ne!(
            unsafe { libc::kill(child_pid, 0) },
            0,
            "grandchild {child_pid} should be killed with its process group"
        );

        drop(cli);
        let _ = handle.join();
        let _ = fs::remove_dir_all(root);
    }
}
