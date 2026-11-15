//! One host daemon owns all session actors; transport connections multiplex
//! framed pane streams. Session workers are threads, never daemon subprocesses.
use crate::*;
use crate::{lifecycle::Policy, registry::Registry};
use std::{
    fs,
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        net::UnixListener,
    },
    path::Path,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
const MAX_STREAMS: usize = 64;
const MAX_LIST_ENTRIES: usize = 2048;
const MAX_LIST_BYTES: usize = 8 * 1024 * 1024;
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

fn serve_mode(directory: &Path, command: Vec<String>, local: bool) -> io::Result<()> {
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
            let _ = crate::registry::write_support_root_stamp(directory, &support);
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
        if active.fetch_add(1, std::sync::atomic::Ordering::SeqCst) >= 8 {
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
    let mut transport = Peer::new(socket, 0)?;
    let mut streams: std::collections::HashMap<u64, Peer> = Default::default();
    let mut last_heartbeat = Instant::now();
    loop {
        if last_heartbeat.elapsed() > Duration::from_secs(45) {
            return Err(io::Error::other("host connection lease expired"));
        }
        for f in transport.read()? {
            match f.kind {
                b'P' if f.seq == 0 => {
                    last_heartbeat = Instant::now();
                    let is_local = registry
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .is_local();
                    let capabilities = if is_local {
                        b"durable-close/1,strict-open/1,local-launch/1,local-resurrect/1,inline-viewer/1,agent-state/1,holder-presentation/1".as_slice()
                    } else {
                        b"durable-close/1,strict-open/1,inline-viewer/1,agent-state/1".as_slice()
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
                b'U' if f.seq != 0
                    && !streams.contains_key(&f.seq)
                    && streams.len() < MAX_STREAMS =>
                {
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
                            streams.insert(f.seq, Peer::new(s, f.seq)?);
                        }
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                }
                b'C' if f.seq != 0
                    && !streams.contains_key(&f.seq)
                    && streams.len() < MAX_STREAMS =>
                {
                    let request: crate::registry::OpenRequest = serde_json::from_slice(&f.data)?;
                    let result = Registry::open_unlocked(&registry, &request);
                    match result {
                        Ok(s) => {
                            streams.insert(f.seq, Peer::new(s, f.seq)?);
                        }
                        Err(e) => transport.push(Frame::new(b'E', f.seq, e.to_string().as_bytes())),
                    }
                }
                b'H' if f.seq != 0
                    && !streams.contains_key(&f.seq)
                    && streams.len() < MAX_STREAMS =>
                {
                    let result = std::str::from_utf8(&f.data)
                        .map_err(io::Error::other)
                        .and_then(|id| Registry::connect_unlocked(&registry, id, None, true));
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
        let mut descriptors = Vec::with_capacity(streams.len() + 1);
        descriptors.push(transport.poll_fd());
        for p in streams.values() {
            descriptors.push(p.poll_fd());
        }
        let timeout_ms = deadline_poll_ms(
            Instant::now(),
            last_heartbeat + Duration::from_secs(45) + Duration::from_nanos(1),
        );
        poll_fds(&mut descriptors, timeout_ms)?;
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
}
