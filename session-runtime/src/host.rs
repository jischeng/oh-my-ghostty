//! One host daemon owns all session actors; transport connections multiplex
//! framed pane streams. Session workers are threads, never daemon subprocesses.
use crate::*;
use std::{
    collections::HashSet,
    fs,
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        net::UnixListener,
    },
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
const MAX_SESSIONS: usize = 64;
const MAX_STREAMS: usize = 64;
fn inner_frame(data: &[u8]) -> io::Result<Frame> {
    let mut input = data;
    let frame = Frame::read(&mut input)?;
    if !input.is_empty() {
        return Err(io::Error::other("trailing inner frame bytes"));
    }
    Ok(frame)
}
fn private(path: &Path) -> io::Result<()> {
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
struct Registry {
    root: PathBuf,
    ids: HashSet<String>,
    command: Vec<String>,
}
impl Registry {
    fn connect(&mut self, id: &str) -> io::Result<UnixStream> {
        if !valid_id(id) {
            return Err(io::Error::other("invalid identity"));
        }
        let path = self.root.join(format!("{id}.sock"));
        if !self.ids.contains(id) {
            if self.ids.len() >= MAX_SESSIONS {
                return Err(io::Error::other("session quota exceeded"));
            }
            // Mark before spawn. A daemon restart cannot silently resurrect a PID.
            fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(self.root.join(format!("{id}.created")))?;
            self.ids.insert(id.to_owned());
            let p = path.clone();
            let argv = self.command.clone();
            std::thread::Builder::new()
                .name(format!("session-{id}"))
                .spawn(move || {
                    if let Err(e) = crate::server::serve(&p, &argv) {
                        eprintln!("session {id}: {e}", id = p.display());
                    }
                })?;
            for _ in 0..100 {
                if path.exists() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        UnixStream::connect(path)
    }
}
/// Outer protocol: H(stream, UUID), D(stream, encoded inner frame), E(stream,error),
/// Q(stream) detach. Outer stream IDs are local to one transport connection.
pub fn serve(directory: &Path, command: Vec<String>) -> io::Result<()> {
    private(directory)?;
    let root = directory.join("sessions");
    fs::create_dir_all(&root)?;
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
    private(&root)?;
    let listener = UnixListener::bind(directory.join("host.sock"))?;
    fs::set_permissions(
        directory.join("host.sock"),
        fs::Permissions::from_mode(0o600),
    )?;
    let registry = Arc::new(Mutex::new(Registry {
        root,
        ids: HashSet::new(),
        command,
    }));
    let active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for conn in listener.incoming() {
        let socket = conn?;
        if active.fetch_add(1, std::sync::atomic::Ordering::SeqCst) >= 8 {
            active.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            continue;
        }
        let registry = registry.clone();
        let active = active.clone();
        std::thread::spawn(move || {
            let _ = host_connection(socket, registry);
            active.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        });
    }
    Ok(())
}
fn host_connection(socket: UnixStream, registry: Arc<Mutex<Registry>>) -> io::Result<()> {
    let mut transport = Peer::new(socket, 0)?;
    let mut streams: std::collections::HashMap<u64, Peer> = Default::default();
    loop {
        for f in transport.read()? {
            match f.kind {
                b'H' if f.seq != 0
                    && !streams.contains_key(&f.seq)
                    && streams.len() < MAX_STREAMS =>
                {
                    let result = std::str::from_utf8(&f.data)
                        .map_err(io::Error::other)
                        .and_then(|id| registry.lock().unwrap().connect(id));
                    match result {
                        Ok(s) => {
                            streams.insert(f.seq, Peer::new(s, f.seq)?);
                        }
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                }
                b'D' => {
                    if let Some(p) = streams.get_mut(&f.seq) {
                        let inner = inner_frame(&f.data)?;
                        p.push(inner);
                    }
                }
                b'Q' => {
                    streams.remove(&f.seq);
                }
                _ => return Err(io::Error::other("invalid multiplex frame")),
            }
        }
        for (&id, p) in &mut streams {
            match p.read() {
                Ok(frames) => {
                    for f in frames {
                        transport.push(Frame::new(b'D', id, &f.encode()));
                    }
                }
                Err(_) => p.dead = true,
            }
            if p.flush().is_err() {
                p.dead = true;
            }
            if p.dead {
                transport.push(Frame::new(b'Q', id, &[]));
            }
        }
        streams.retain(|_, p| !p.dead);
        transport.flush()?;
        if transport.dead {
            return Err(io::Error::other("transport backlog exceeded"));
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}
pub fn relay(local: &Path, socket: UnixStream) -> io::Result<()> {
    private(
        local
            .parent()
            .ok_or_else(|| io::Error::other("missing parent"))?,
    )?;
    let listener = UnixListener::bind(local)?;
    fs::set_permissions(local, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let mut transport = Peer::new(socket, 0)?;
    let mut peers: std::collections::HashMap<u64, (Peer, bool, bool)> = Default::default();
    let mut next = 1;
    loop {
        for _ in 0..8 {
            match listener.accept() {
                Ok((s, _)) => {
                    if peers.len() < MAX_STREAMS {
                        peers.insert(next, (Peer::new(s, next)?, false, false));
                        next += 1;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        for f in transport.read()? {
            if let Some((p, _, closing)) = peers.get_mut(&f.seq) {
                match f.kind {
                    b'D' => p.push(inner_frame(&f.data)?),
                    b'Q' | b'E' => {
                        if f.kind == b'E' {
                            eprintln!("session {}: {}", f.seq, String::from_utf8_lossy(&f.data));
                        }
                        // Drain already queued final output/Exit before closing.
                        *closing = true;
                    }
                    _ => return Err(io::Error::other("invalid multiplex response")),
                }
            }
        }
        for (&id, (p, opened, closing)) in &mut peers {
            let frames = if *closing { Ok(vec![]) } else { p.read() };
            match frames {
                Ok(frames) => {
                    for f in frames {
                        if !*opened {
                            if f.kind != b'H' || !std::str::from_utf8(&f.data).is_ok_and(valid_id) {
                                p.dead = true;
                                break;
                            }
                            transport.push(Frame::new(b'H', id, &f.data));
                            *opened = true;
                        } else {
                            transport.push(Frame::new(b'D', id, &f.encode()));
                        }
                    }
                }
                Err(_) => p.dead = true,
            }
            if p.flush().is_err() {
                p.dead = true;
            }
            if *closing && p.queued == 0 {
                p.dead = true;
            }
            if p.dead && *opened {
                transport.push(Frame::new(b'Q', id, &[]));
            }
        }
        peers.retain(|_, (p, _, _)| !p.dead);
        transport.flush()?;
        if transport.dead {
            return Err(io::Error::other("transport backlog exceeded"));
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}
