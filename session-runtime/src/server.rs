use crate::*;
use std::{
    ffi::c_void,
    fs::{self, File},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            fs::{MetadataExt, PermissionsExt},
            net::UnixListener,
            process::CommandExt,
        },
    },
    path::Path,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
extern "C" fn reply(context: *mut c_void, data: *const u8, len: usize) {
    let queue = unsafe { &mut *(context as *mut VecDeque<u8>) };
    if queue.len() + len <= 1024 * 1024 {
        queue.extend(unsafe { std::slice::from_raw_parts(data, len) });
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
    let listener = UnixListener::bind(path)?;
    let _guard = SocketGuard(path.to_owned());
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
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
    let mut command = Command::new(&argv[0]);
    command
        .args(&argv[1..])
        .env("TERM", "xterm-256color")
        .stdin(Stdio::from(slave.try_clone()?))
        .stdout(Stdio::from(slave.try_clone()?))
        .stderr(Stdio::from(slave));
    unsafe {
        command.pre_exec(|| {
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
    // Command retains its configured Stdio descriptors after spawn. Release
    // the parent's slave handles so child exit produces EOF on the master.
    drop(command);
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
    let id = format!("{}-{}", std::process::id(), child.id());
    let mut exited = None;
    let mut eof = false;
    let mut closing = None;
    let mut draining = None;
    loop {
        // A bounded accept batch cannot starve PTY processing.
        for _ in 0..8 {
            match listener.accept() {
                Ok((socket, _)) => {
                    if peers.len() >= 16 {
                        continue;
                    }
                    let mut peer = Peer::new(socket, next_id)?;
                    next_id += 1;
                    let info = serde_json::json!({"version":1,"session_id":id,"pid":child.id(),"attachment":peer.id,"cols":size.ws_col,"rows":size.ws_row,"experimental":true});
                    peer.push(Frame::new(INFO, seq, info.to_string().as_bytes()));
                    match vt.snapshot() {
                        Ok(bytes) if bytes.len() <= MAX_FRAME => {
                            peer.push(Frame::new(SNAPSHOT, seq, &bytes));
                            peer.ack = Some(seq);
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
                        unsafe {
                            libc::kill(-(child.id() as i32), libc::SIGTERM);
                        }
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
        if exited.is_none() {
            if let Some(status) = child.try_wait()? {
                exited = Some(status.code().unwrap_or(-1));
            }
        }
        if let Some(start) = closing {
            if start.elapsed() > Duration::from_secs(2) && exited.is_none() {
                unsafe {
                    libc::kill(-(child.id() as i32), libc::SIGKILL);
                }
            }
        }
        for peer in &mut peers {
            if peer.flush().is_err() {
                peer.dead = true;
            }
        }
        peers.retain(|p| !p.dead);
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
