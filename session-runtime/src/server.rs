use crate::*;
use crate::{
    lifecycle::{unix_time, EndReason, Lifetime},
    record::{nonce, AgentEvent, Record},
};
use std::{
    ffi::c_void,
    fs::{self, File},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            fs::{MetadataExt, PermissionsExt},
            net::{UnixDatagram, UnixListener},
            process::CommandExt,
        },
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
static PTY_SPAWN: std::sync::Mutex<()> = std::sync::Mutex::new(());
extern "C" fn reply(context: *mut c_void, data: *const u8, len: usize) {
    let queue = unsafe { &mut *(context as *mut VecDeque<u8>) };
    if queue.len() + len <= 1024 * 1024 {
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
struct SocketGuard(std::path::PathBuf);
impl Drop for SocketGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
/// Prototype intentionally has one session, created explicitly at daemon startup.
/// Disconnect never touches the PTY; only Close or child exit ends the session.
pub fn serve(path: &Path, argv: &[String]) -> io::Result<()> {
    serve_managed(path, argv, None)
}

pub struct ManagedSession {
    pub path: PathBuf,
    pub record: Record,
    pub containment_root: Option<PathBuf>,
}

pub fn serve_managed(
    path: &Path,
    argv: &[String],
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
    let _event_guard = SocketGuard(event_path.clone());
    fs::set_permissions(&event_path, fs::Permissions::from_mode(0o600))?;
    events.set_nonblocking(true)?;
    let listener = UnixListener::bind(path)?;
    let _guard = SocketGuard(path.to_owned());
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    // openpty cannot atomically set CLOEXEC. Serialize every session spawn
    // across that small window so another shell cannot inherit these FDs.
    let spawn_guard = PTY_SPAWN
        .lock()
        .map_err(|_| io::Error::other("PTY spawn lock poisoned"))?;
    let mut master = -1;
    let mut slave = -1;
    let mut size = libc::winsize {
        ws_row: 24,
        ws_col: 80,
        ws_xpixel: 640,
        ws_ypixel: 384,
    };
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
    let mut command = Command::new(&argv[0]);
    command
        .args(&argv[1..])
        .env("TERM", "xterm-256color")
        .env("OMG_RUNTIME_EVENT_SOCKET", &event_path)
        .env("OMG_RUNTIME_EVENT_TOKEN", &token)
        .env(
            "OMG_RUNTIME_GENERATION",
            managed
                .as_ref()
                .map(|m| m.record.generation.as_str())
                .unwrap_or(&token),
        )
        .env("OMG_RUNTIME_BIN", std::env::current_exe()?)
        .env("OMG_RUNTIME_REMOTE", "1")
        .stdin(Stdio::from(slave.try_clone()?))
        .stdout(Stdio::from(slave.try_clone()?))
        .stderr(Stdio::from(slave));
    if let Some(resume) = managed.as_ref().and_then(|m| m.record.resume.as_ref()) {
        command.current_dir(&resume.cwd);
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
    drop(membership);
    if let Some(m) = &mut managed {
        m.record.pid = Some(child.id());
        m.record.ended = None;
        m.record.save(&m.path)?;
    }
    // Command retains its configured Stdio descriptors after spawn. Release
    // the parent's slave handles so child exit produces EOF on the master.
    drop(command);
    drop(spawn_guard);
    if unsafe { libc::fcntl(master, libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::last_os_error());
    }
    let mut input = Box::new(VecDeque::<u8>::new());
    let mut vt = Vt::with_reply(
        80,
        24,
        Some(reply),
        (&mut *input as *mut VecDeque<u8>).cast(),
    )?;
    let mut peers: Vec<Peer> = vec![];
    let mut next_id = 1;
    let mut writer = None;
    let mut seq = 0u64;
    let id = managed
        .as_ref()
        .map(|m| m.record.id.clone())
        .unwrap_or_else(|| format!("{}-{}", std::process::id(), child.id()));
    let generation = managed
        .as_ref()
        .map(|m| m.record.generation.clone())
        .unwrap_or_else(|| token.clone());
    let mut lifetime = Lifetime::new(Instant::now());
    let mut end_reason = EndReason::ProcessExited;
    let mut agent_done = false;
    let mut completed_group = None;
    let mut recovery_checked_at = Instant::now() - Duration::from_secs(5);
    let mut recovery_available = false;
    let mut exited = None;
    let mut eof = false;
    let mut closing = None;
    let mut draining = None;
    let mut last_cwd = crate::location::session_cwd(master, child.id());
    let mut cwd_checked = Instant::now();
    loop {
        if closing.is_none()
            && managed
                .as_ref()
                .is_some_and(|m| m.path.with_extension("closed").exists())
        {
            end_reason = EndReason::ExplicitClose;
            terminate_group(master, child.id(), libc::SIGTERM);
            closing = Some(Instant::now());
        }
        if exited.is_none() && cwd_checked.elapsed() >= Duration::from_millis(500) {
            let cwd = crate::location::session_cwd(master, child.id());
            if cwd != last_cwd {
                last_cwd = cwd;
                let metadata = serde_json::to_vec(&serde_json::json!({"cwd":last_cwd}))?;
                for peer in &mut peers {
                    peer.push(Frame::new(b'M', seq, &metadata));
                }
            }
            cwd_checked = Instant::now();
        }
        // Hooks use an inherited per-session capability, never terminal text.
        let mut event_bytes = [0u8; 16384];
        for _ in 0..16 {
            match events.recv_from(&mut event_bytes) {
                Ok((n, source)) => {
                    if let Ok(event) = serde_json::from_slice::<AgentEvent>(&event_bytes[..n]) {
                        if event.token == token
                            && event.generation == generation
                            && event.resume.validate().is_ok()
                            && event.pid > 1
                            && event.group > 1
                            && unsafe { libc::getpgid(event.pid) } == event.group
                            && unsafe { libc::getsid(event.pid) } == child.id() as i32
                            && unsafe { libc::tcgetpgrp(master) } == event.group
                        {
                            if let Some(m) = &mut managed {
                                if matches!(
                                    event.state.as_str(),
                                    "working"
                                        | "idle"
                                        | "done"
                                        | "needsAttention"
                                        | "error"
                                        | "end"
                                ) {
                                    m.record.resume = Some(event.resume);
                                    // Persist first: a completion must never destroy its own recovery data.
                                    m.record.save(&m.path)?;
                                    agent_done = event.state == "done";
                                    completed_group = agent_done.then_some(event.group);
                                    recovery_checked_at = Instant::now() - Duration::from_secs(5);
                                    lifetime.activity(agent_done, Instant::now());
                                    if let Some(path) = source.as_pathname() {
                                        let _ = events.send_to(b"OK", path);
                                    }
                                }
                            }
                        }
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        // A bounded accept batch cannot starve PTY processing.
        for _ in 0..8 {
            match listener.accept() {
                Ok((socket, _)) => {
                    if peers.len() >= 16 {
                        continue;
                    }
                    let mut peer = Peer::new(socket, next_id)?;
                    next_id += 1;
                    let info = serde_json::json!({"version":1,"session_id":id,"pid":child.id(),"attachment":peer.id,"cols":size.ws_col,"rows":size.ws_row,"generation":generation,"detached_ttl_seconds":policy.detached_ttl_seconds,"experimental":true});
                    peer.push(Frame::new(INFO, seq, info.to_string().as_bytes()));
                    match vt.snapshot() {
                        Ok(bytes) if bytes.len() <= MAX_FRAME => {
                            peer.push(Frame::new(SNAPSHOT, seq, &bytes));
                            peer.ack = Some(seq);
                            peer.push(Frame::new(
                                b'M',
                                seq,
                                &serde_json::to_vec(&serde_json::json!({"cwd":last_cwd}))?,
                            ));
                        }
                        _ => {
                            continue;
                        }
                    }
                    if let Some(code) = exited {
                        peer.push(Frame::new(EXIT, seq, format!("{code}").as_bytes()));
                    }
                    peers.push(peer);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        let mut resizes = Vec::new();
        for peer in &mut peers {
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
                    CLAIM if writer.is_none() || writer == Some(peer.id) => {
                        writer = Some(peer.id);
                        peer.push(Frame::new(CLAIM, seq, &[]));
                    }
                    CLAIM => peer.push(Frame::new(b'B', seq, b"writer occupied")),
                    INPUT if writer == Some(peer.id) && exited.is_none() => {
                        agent_done = false;
                        completed_group = None;
                        lifetime.activity(false, Instant::now());
                        if input.len() + f.data.len() > 1024 * 1024 {
                            peer.dead = true;
                        } else {
                            input.extend(f.data);
                        }
                    }
                    RESIZE if writer == Some(peer.id) && f.data.len() == 4 => {
                        let cols = u16::from_be_bytes(f.data[..2].try_into().unwrap());
                        let rows = u16::from_be_bytes(f.data[2..].try_into().unwrap());
                        if cols == 0 || rows == 0 || cols > 500 || rows > 300 {
                            peer.dead = true;
                            continue;
                        }
                        size.ws_col = cols;
                        size.ws_row = rows;
                        size.ws_xpixel = cols * 8;
                        size.ws_ypixel = rows * 16;
                        vt.resize(cols, rows)?;
                        if unsafe { libc::ioctl(pty.as_raw_fd(), libc::TIOCSWINSZ, &size) } < 0 {
                            return Err(io::Error::last_os_error());
                        }
                        resizes.push(f.data);
                    }
                    CLOSE if writer == Some(peer.id) && closing.is_none() => {
                        end_reason = EndReason::ExplicitClose;
                        terminate_group(master, child.id(), libc::SIGTERM);
                        closing = Some(Instant::now());
                    }
                    _ => {
                        peer.dead = true;
                    }
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
                    input.drain(..n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => {
                    input.clear();
                }
            }
        }
        // Never gate this read on the number or speed of attachments.
        if !eof {
            let mut bytes = [0; 65536];
            match pty.read(&mut bytes) {
                Ok(0) => eof = true,
                Ok(n) => {
                    vt.write(&bytes[..n]);
                    seq += n as u64;
                    for peer in &mut peers {
                        peer.push(Frame::new(OUTPUT, seq, &bytes[..n]));
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
        let may_reap = closing.is_none_or(|start: Instant| {
            start.elapsed() > Duration::from_secs(policy.terminate_grace_seconds)
        });
        if exited.is_none() && may_reap {
            if closing.is_some() {
                terminate_group(master, child.id(), libc::SIGKILL);
            }
            if let Some(status) = child.try_wait()? {
                exited = Some(status.code().unwrap_or(-1));
            }
        }
        if let Some(start) = closing {
            if start.elapsed() > Duration::from_secs(policy.terminate_grace_seconds)
                && !eof
                && exited.is_none()
            {
                terminate_group(master, child.id(), libc::SIGKILL);
                // Escaped descendants retaining a slave cannot keep our actor forever.
                if start.elapsed() > Duration::from_secs(policy.terminate_grace_seconds + 2) {
                    eof = true;
                }
            }
        }
        for peer in &mut peers {
            if peer.flush().is_err() {
                peer.dead = true;
            }
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
                if let Some(m) = &mut managed {
                    m.record.ended = Some(reason);
                    m.record.save(&m.path)?;
                }
                terminate_group(master, child.id(), libc::SIGTERM);
                closing = Some(Instant::now());
            }
        }
        if exited.is_some() && closing.is_none() {
            closing = Some(Instant::now());
        }
        // Once the owned leader has been reaped, its numeric PID may be reused.
        // Finish draining instead of signaling any process by that stale ID.
        if exited.is_some() && closing.is_some_and(|start| start.elapsed() > Duration::from_secs(2))
        {
            eof = true;
        }
        if writer.is_some_and(|id| !peers.iter().any(|p| p.id == id)) {
            writer = None;
        }
        if let (Some(code), true) = (exited, eof) {
            let start = draining.get_or_insert_with(|| {
                for peer in &mut peers {
                    peer.push(Frame::new(EXIT, seq, format!("{code}").as_bytes()));
                }
                Instant::now()
            });
            if peers.iter().all(|p| p.queued == 0) || start.elapsed() > Duration::from_secs(2) {
                let _ = child.wait();
                if let Some(group) = &group {
                    group.finish()?;
                }
                if let Some(m) = &mut managed {
                    m.record.pid = None;
                    m.record.ended = Some(end_reason);
                    m.record.save(&m.path)?;
                }
                return Ok(());
            }
        }
        let mut pollfd = libc::pollfd {
            fd: master,
            events: if eof { 0 } else { libc::POLLIN },
            revents: 0,
        };
        unsafe {
            libc::poll(&mut pollfd, 1, 5);
        }
    }
}
