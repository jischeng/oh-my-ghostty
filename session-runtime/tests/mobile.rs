use omg_session_runtime::{Frame, Vt};
use std::{
    fs,
    io::{BufRead, BufReader},
    net::TcpStream,
    os::unix::{fs::PermissionsExt, net::UnixStream},
    process::{Child, Command, Stdio},
    sync::mpsc,
    time::Duration,
};
use tokio_tungstenite::tungstenite::{self, client::IntoClientRequest, http::HeaderValue, Message};

use sha2::{Digest, Sha256};

fn pid_is_gone(pid: u32) -> bool {
    if pid <= 1 {
        return true;
    }
    let rc = unsafe { libc::kill(pid as i32, 0) };
    rc != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

fn wait_pid_gone(pid: u32, timeout: Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        if pid_is_gone(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    pid_is_gone(pid)
}

fn ctl_peer_pid(ctl_path: &std::path::Path) -> Option<u32> {
    use std::os::fd::AsRawFd;
    let probe = UnixStream::connect(ctl_path).ok()?;
    #[cfg(target_os = "macos")]
    {
        let mut peer_pid: libc::pid_t = 0;
        let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(
                probe.as_raw_fd(),
                0,
                libc::LOCAL_PEERPID,
                (&mut peer_pid as *mut libc::pid_t).cast(),
                &mut len,
            )
        };
        if rc == 0 && peer_pid > 1 {
            return Some(peer_pid as u32);
        }
        None
    }
    #[cfg(target_os = "linux")]
    {
        let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
        let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(
                probe.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                (&mut cred as *mut libc::ucred).cast(),
                &mut len,
            )
        };
        if rc == 0 && cred.pid > 1 {
            return Some(cred.pid as u32);
        }
        None
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = probe;
        None
    }
}

fn session_socket_for_id(state_dir: &std::path::Path, id: &str) -> std::path::PathBuf {
    let hash: String = Sha256::digest(id.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    state_dir.join(format!("{}.sock", &hash[..16]))
}

struct Fixture {
    children: Vec<Child>,
    dir: std::path::PathBuf,
    cleanup_dirs: Vec<std::path::PathBuf>,
    mobile_state_dirs: Vec<std::path::PathBuf>,
    owned: Vec<(String, String)>,
}

impl Fixture {
    fn new(dir: std::path::PathBuf) -> Self {
        Self {
            children: vec![],
            dir,
            cleanup_dirs: vec![],
            mobile_state_dirs: vec![],
            owned: vec![],
        }
    }

    fn stop_mobile_gateways(&self) {
        for state_dir in &self.mobile_state_dirs {
            let record_path = state_dir.join("mobile-gateway.json");
            let gateway_pid = fs::read(&record_path)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
                .and_then(|val| val["pid"].as_u64())
                .map(|pid| pid as u32);
            let _ = Command::new(env!("CARGO_BIN_EXE_omgd"))
                .args(["mobile", "stop", "--state-dir"])
                .arg(state_dir)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            if let Some(pid) = gateway_pid.filter(|&p| p > 1) {
                if !wait_pid_gone(pid, Duration::from_millis(500)) {
                    unsafe {
                        libc::kill(pid as i32, libc::SIGTERM);
                    }
                    if !wait_pid_gone(pid, Duration::from_secs(1)) {
                        unsafe {
                            libc::kill(pid as i32, libc::SIGKILL);
                        }
                        let _ = wait_pid_gone(pid, Duration::from_secs(1));
                    }
                }
            }
        }
    }

    fn drain_state_dir_sessions(state_dir: &std::path::Path) -> bool {
        let sessions_dir = state_dir.join("sessions");
        let host_sock = state_dir.join("host.sock");
        let mut holder_pids = std::collections::BTreeSet::new();
        let mut session_pids = std::collections::BTreeSet::new();
        let mut session_ids = std::collections::BTreeSet::new();

        if let Ok(entries) = fs::read_dir(state_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("ctl") {
                    if let Some(pid) = ctl_peer_pid(&path) {
                        holder_pids.insert(pid);
                    }
                }
            }
        }

        if let Ok(entries) = fs::read_dir(&sessions_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("json") {
                    continue;
                }
                if let Ok(record) = omg_session_runtime::record::Record::load(&path) {
                    session_ids.insert(record.id.clone());
                    if let Some(pid) = record.pid.filter(|&p| p > 1) {
                        session_pids.insert(pid);
                    }
                    let sock = session_socket_for_id(state_dir, &record.id);
                    if let Some(cap) = record.holder_capability.as_deref() {
                        if let Ok(view) = omg_session_runtime::holder::probe_with_timeout(
                            &sock,
                            &record.id,
                            &record.generation,
                            cap,
                            Duration::from_millis(250),
                        ) {
                            if view.holder_pid > 1 {
                                holder_pids.insert(view.holder_pid);
                            }
                            if let Some(spid) = view.session_pid.filter(|&p| p > 1) {
                                session_pids.insert(spid);
                            }
                        }
                    }
                    let ctl = omg_session_runtime::holder::control_path(&sock);
                    if let Some(pid) = ctl_peer_pid(&ctl) {
                        holder_pids.insert(pid);
                    }
                    if record.ended.is_none() {
                        let _ = fs::write(sessions_dir.join(format!("{}.closed", record.id)), b"");
                        if let Ok(mut socket) = UnixStream::connect(&host_sock) {
                            let _ = Frame::new(b'K', 9, record.id.as_bytes()).send(&mut socket);
                        }
                    }
                }
            }
        }

        // Wait up to 7s for graceful `.closed` shutdown of all holders and PTY leaders
        // (covers `Policy::default().terminate_grace_seconds == 5` for login shells)
        // BEFORE removing any directory entries.
        let deadline = std::time::Instant::now() + Duration::from_secs(7);
        while std::time::Instant::now() < deadline {
            let records_done = session_ids.iter().all(|id| {
                let path = sessions_dir.join(format!("{id}.json"));
                let sock = session_socket_for_id(state_dir, id);
                let ctl = omg_session_runtime::holder::control_path(&sock);
                if let Ok(rec) = omg_session_runtime::record::Record::load(&path) {
                    if let Some(pid) = rec.pid.filter(|&p| p > 1) {
                        session_pids.insert(pid);
                    }
                    rec.ended.is_some() && rec.pid.is_none() && !ctl.exists()
                } else {
                    !ctl.exists()
                }
            });
            let holders_done = holder_pids.iter().copied().all(pid_is_gone);
            let sessions_done = session_pids.iter().copied().all(pid_is_gone);
            if records_done && holders_done && sessions_done {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }

        // Escalate deterministically so even wedged test daemons never leak on the host.
        for &hpid in &holder_pids {
            if !pid_is_gone(hpid) {
                unsafe {
                    libc::kill(hpid as i32, libc::SIGTERM);
                }
            }
        }
        for &spid in &session_pids {
            if !pid_is_gone(spid) {
                unsafe {
                    libc::kill(-(spid as i32), libc::SIGTERM);
                    libc::kill(spid as i32, libc::SIGTERM);
                }
            }
        }
        let term_deadline = std::time::Instant::now() + Duration::from_secs(1);
        while std::time::Instant::now() < term_deadline {
            if holder_pids.iter().copied().all(pid_is_gone)
                && session_pids.iter().copied().all(pid_is_gone)
            {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }

        for &hpid in &holder_pids {
            if !pid_is_gone(hpid) {
                unsafe {
                    libc::kill(hpid as i32, libc::SIGKILL);
                }
            }
        }
        for &spid in &session_pids {
            if !pid_is_gone(spid) {
                unsafe {
                    libc::kill(-(spid as i32), libc::SIGKILL);
                    libc::kill(spid as i32, libc::SIGKILL);
                }
            }
        }
        let kill_deadline = std::time::Instant::now() + Duration::from_secs(2);
        while std::time::Instant::now() < kill_deadline {
            if holder_pids.iter().copied().all(pid_is_gone)
                && session_pids.iter().copied().all(pid_is_gone)
            {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        holder_pids.iter().copied().all(pid_is_gone)
            && session_pids.iter().copied().all(pid_is_gone)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop_mobile_gateways();
        for (id, _) in &self.owned {
            let _ = fs::write(self.dir.join("sessions").join(format!("{id}.closed")), b"");
        }
        // Stop foreground gateway and `host-local` broker children first so:
        // 1) no in-flight broker request can spawn a new holder mid-teardown, and
        // 2) `setsid()` `session-holder` children of `host-local` are reparented to PID 1
        //    and reaped immediately on exit instead of lingering as un-reaped zombies.
        for child in self.children.iter_mut().rev() {
            if matches!(child.try_wait(), Ok(None)) {
                unsafe {
                    libc::kill(child.id() as i32, libc::SIGTERM);
                }
                let deadline = std::time::Instant::now() + Duration::from_secs(2);
                while std::time::Instant::now() < deadline {
                    if matches!(child.try_wait(), Ok(Some(_))) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
            let _ = child.kill();
            let _ = child.wait();
        }
        let mut state_dirs = vec![self.dir.clone()];
        for root in std::iter::once(&self.dir).chain(self.cleanup_dirs.iter()) {
            if root != &self.dir {
                state_dirs.push(root.clone());
            }
            for run_parent in [root.join(".omg/run"), root.join("home/.omg/run")] {
                if let Ok(entries) = fs::read_dir(&run_parent) {
                    for entry in entries.flatten() {
                        let p = entry.path();
                        if p.is_dir() {
                            state_dirs.push(p);
                        }
                    }
                }
            }
        }
        for state_dir in &state_dirs {
            let mut broker_pid = ctl_peer_pid(&state_dir.join("host.sock"));
            if broker_pid.is_none() {
                let lock_path = state_dir.join("host.lock");
                if let Ok(file) = fs::OpenOptions::new().read(true).open(&lock_path) {
                    use std::os::fd::AsRawFd;
                    let locked =
                        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) }
                            != 0;
                    if !locked {
                        unsafe {
                            libc::flock(file.as_raw_fd(), libc::LOCK_UN);
                        }
                    } else if let Ok(text) = fs::read_to_string(&lock_path) {
                        broker_pid = text.trim().parse::<u32>().ok().filter(|&p| p > 1);
                    }
                }
            }
            if let Some(pid) = broker_pid.filter(|&p| p > 1) {
                unsafe {
                    libc::kill(pid as i32, libc::SIGTERM);
                }
                if !wait_pid_gone(pid, Duration::from_secs(2)) {
                    unsafe {
                        libc::kill(pid as i32, libc::SIGKILL);
                    }
                    let _ = wait_pid_gone(pid, Duration::from_secs(1));
                }
            }
        }
        let mut all_stopped = true;
        for state_dir in &state_dirs {
            all_stopped &= Self::drain_state_dir_sessions(state_dir);
        }
        if all_stopped {
            let _ = fs::remove_dir_all(&self.dir);
            for extra in &self.cleanup_dirs {
                let _ = fs::remove_dir_all(extra);
            }
        } else {
            eprintln!(
                "Unconfirmed test-holder cleanup; retained {}",
                self.dir.display()
            );
        }
    }
}
type Ws = tungstenite::WebSocket<TcpStream>;
fn connect(address: &str, path: &str, token: &str) -> Result<Ws, tungstenite::Error> {
    let mut request = format!("ws://{address}{path}").into_client_request()?;
    request.headers_mut().insert(
        "sec-websocket-protocol",
        HeaderValue::from_str(&format!("omg.{token}")).unwrap(),
    );
    let socket = TcpStream::connect(address).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    Ok(tungstenite::client(request, socket)
        .map_err(|e| match e {
            tungstenite::HandshakeError::Failure(e) => e,
            _ => panic!("blocking handshake interrupted"),
        })?
        .0)
}
fn send(ws: &mut Ws, frame: Frame) {
    ws.send(Message::Binary(frame.encode().into())).unwrap();
}
fn receive(ws: &mut Ws, pending: &mut Vec<u8>, kind: u8) -> Frame {
    loop {
        while pending.len() >= 13 {
            let len = u32::from_be_bytes(pending[9..13].try_into().unwrap()) as usize;
            if pending.len() < len + 13 {
                break;
            }
            let bytes: Vec<_> = pending.drain(..len + 13).collect();
            let frame = Frame::read(&mut bytes.as_slice()).unwrap();
            if frame.kind == kind {
                return frame;
            }
        }
        match ws.read().unwrap() {
            Message::Binary(bytes) => pending.extend_from_slice(&bytes),
            Message::Ping(_) => ws.flush().unwrap(),
            _ => {}
        }
    }
}

#[test]
fn lan_gateway_authenticates_and_restores_same_session_across_reconnect() {
    let dir = std::env::temp_dir().join(format!("omg-mobile-{}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let mut fixture = Fixture::new(dir);
    let host = fixture.dir.join("host.sock");
    fixture.children.push(
        Command::new(env!("CARGO_BIN_EXE_omgd"))
            .args(["host", fixture.dir.to_str().unwrap(), "--", "/bin/sh", "-i"])
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let mut control = (0..300)
        .find_map(|_| {
            UnixStream::connect(&host).ok().or_else(|| {
                std::thread::sleep(Duration::from_millis(10));
                None
            })
        })
        .unwrap();
    control
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let id = "12345678-1234-1234-1234-123456789abc";
    let request = serde_json::json!({"id": id, "policy": {}, "create": true});
    Frame::new(b'C', 1, &serde_json::to_vec(&request).unwrap())
        .send(&mut control)
        .unwrap();
    let mut generation = String::new();
    loop {
        let frame = Frame::read(&mut control).unwrap();
        if frame.kind != b'D' {
            panic!("create failed: {:?}", frame);
        }
        let inner = Frame::read(&mut frame.data.as_slice()).unwrap();
        if inner.kind == b'J' {
            let info: serde_json::Value = serde_json::from_slice(&inner.data).unwrap();
            generation = info["generation"].as_str().unwrap().into();
        }
        if inner.kind == b'S' {
            Frame::new(b'D', 1, &Frame::new(b'A', inner.seq, &[]).encode())
                .send(&mut control)
                .unwrap();
            break;
        }
    }
    let key = fixture.dir.join("pair.token");
    let mut gateway = Command::new(env!("CARGO_BIN_EXE_omgd"))
        .args([
            "mobile",
            "--listen",
            "127.0.0.1:0",
            "--socket",
            host.to_str().unwrap(),
            "--token-file",
            key.to_str().unwrap(),
        ])
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stderr = gateway.stderr.take().unwrap();
    fixture.children.push(gateway);
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if let Some(value) = line.strip_prefix("OMG mobile listening on ws://") {
                let _ = tx.send(value.trim_end_matches("/catalogue").to_string());
                break;
            }
        }
    });
    let address = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let token = fs::read_to_string(key).unwrap();
    assert!(connect(&address, "/catalogue", "wrong").is_err());
    let mut catalogue = connect(&address, "/catalogue", token.trim()).unwrap();
    let text = catalogue.read().unwrap().into_text().unwrap();
    let catalogue: serde_json::Value = serde_json::from_str(&text).unwrap();
    let endpoint = catalogue["endpoints"][0]["id"].as_str().unwrap();
    let mut pid = None;
    for round in 0..2 {
        let mut ws = connect(&address, &format!("/ws/{endpoint}"), token.trim()).unwrap();
        let mut pending = Vec::new();
        send(&mut ws, Frame::new(b'P', 0, &[]));
        send(&mut ws, Frame::new(b'L', 0, &[]));
        let list: serde_json::Value =
            serde_json::from_slice(&receive(&mut ws, &mut pending, b'L').data).unwrap();
        assert_eq!(list[0]["id"], id);
        assert_eq!(list[0]["generation"], generation);
        if let Some(pid) = &pid {
            assert_eq!(&list[0]["pid"], pid);
        } else {
            pid = Some(list[0]["pid"].clone());
        }
        send(
            &mut ws,
            Frame::new(
                b'U',
                1,
                &serde_json::to_vec(&serde_json::json!({"id": id, "generation": generation}))
                    .unwrap(),
            ),
        );
        let snapshot = loop {
            let frame = receive(&mut ws, &mut pending, b'D');
            let inner = Frame::read(&mut frame.data.as_slice()).unwrap();
            if inner.kind == b'S' {
                break inner;
            }
        };
        let mut vt = Vt::new(80, 24).unwrap();
        vt.restore(&snapshot.data).unwrap();
        send(
            &mut ws,
            Frame::new(b'D', 1, &Frame::new(b'A', snapshot.seq, &[]).encode()),
        );
        if round == 0 {
            send(
                &mut ws,
                Frame::new(b'D', 1, &Frame::new(b'W', 0, b"takeover/1").encode()),
            );
            loop {
                let event = receive(&mut ws, &mut pending, b'D');
                if Frame::read(&mut event.data.as_slice()).unwrap().kind == b'W' {
                    break;
                }
            }
            // Octal literals keep command echo from satisfying the output assertion.
            send(
                &mut ws,
                Frame::new(
                    b'D',
                    1,
                    &Frame::new(
                        b'I',
                        0,
                        b"printf '\\115\\117\\102\\111\\114\\105\\137\\114\\111\\116\\113\\n'\r",
                    )
                    .encode(),
                ),
            );
            let mut output = Vec::new();
            while !output
                .windows(b"MOBILE_LINK".len())
                .any(|v| v == b"MOBILE_LINK")
            {
                let event = receive(&mut ws, &mut pending, b'D');
                let event = Frame::read(&mut event.data.as_slice()).unwrap();
                if event.kind == b'O' {
                    output.extend(event.data);
                }
                assert!(output.len() < 64 * 1024);
            }
        } else {
            assert!(vt.text().unwrap().contains("MOBILE_LINK"));
        }
        ws.close(None).unwrap();
    }
    // Explicit cleanup is a session close, not a side effect of dropping either viewer.
    Frame::new(b'K', 2, id.as_bytes())
        .send(&mut control)
        .unwrap();
}

fn json_reply(ws: &mut Ws, kind: &str) -> serde_json::Value {
    for _ in 0..100 {
        match ws.read().unwrap() {
            Message::Text(text) => {
                let value: serde_json::Value = serde_json::from_str(&text).unwrap();
                if value["t"] == kind {
                    return value;
                }
            }
            Message::Ping(_) => ws.flush().unwrap(),
            _ => {}
        }
    }
    panic!("missing control reply {kind}")
}

#[test]
fn full_ui_control_projects_roster_without_taking_input_and_serves_real_files() {
    let dir = std::path::PathBuf::from("/tmp").join(format!(
        "omg-mc-{}",
        &omg_session_runtime::record::nonce().unwrap()[..12]
    ));
    fs::create_dir(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let project = dir.join("project");
    fs::create_dir(&project).unwrap();
    fs::write(project.join("README.md"), "# Fixture\n").unwrap();
    assert!(Command::new("git")
        .args(["init", "-q"])
        .arg(&project)
        .status()
        .unwrap()
        .success());
    let mut fixture = Fixture::new(dir);
    let binary = env!("CARGO_BIN_EXE_omgd");
    fixture.children.push(
        Command::new(binary)
            .args(["host-local"])
            .arg(&fixture.dir)
            .args(["--", "/bin/sh"])
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let host = fixture.dir.join("host.sock");
    let mut desktop = (0..300)
        .find_map(|_| {
            UnixStream::connect(&host).ok().or_else(|| {
                std::thread::sleep(Duration::from_millis(10));
                None
            })
        })
        .unwrap();
    desktop
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let id = "12345678-1234-4234-a234-123456789abc";
    let request = serde_json::json!({"id":id,"create":true,"policy":{},"launch":{
        "argv":["/bin/sh","-i"],"env":{"HOME":fixture.dir,"PATH":"/usr/bin:/bin","SHELL":"/bin/sh"},
        "cwd":project,"cols":100,"rows":30,"pixel_width":0,"pixel_height":0,
    }});
    Frame::new(b'C', 1, &serde_json::to_vec(&request).unwrap())
        .send(&mut desktop)
        .unwrap();
    let mut generation = String::new();
    let mut pid = 0;
    loop {
        let outer = Frame::read(&mut desktop).unwrap();
        assert_eq!(outer.kind, b'D');
        let inner = Frame::read(&mut outer.data.as_slice()).unwrap();
        if inner.kind == b'J' {
            let info: serde_json::Value = serde_json::from_slice(&inner.data).unwrap();
            generation = info["generation"].as_str().unwrap().into();
            pid = info["pid"].as_u64().unwrap();
        }
        if inner.kind == b'S' {
            Frame::new(b'D', 1, &Frame::new(b'A', inner.seq, &[]).encode())
                .send(&mut desktop)
                .unwrap();
            Frame::new(b'D', 1, &Frame::new(b'W', 0, &[]).encode())
                .send(&mut desktop)
                .unwrap();
            break;
        }
    }
    fixture.owned.push((id.into(), generation.clone()));
    while Frame::read(&mut desktop)
        .map(|f| Frame::read(&mut f.data.as_slice()).unwrap().kind != b'W')
        .unwrap()
    {}
    let key = fixture.dir.join("pair.token");
    let mut gateway = Command::new(binary)
        .args(["mobile", "--listen", "127.0.0.1:0", "--socket"])
        .arg(&host)
        .arg("--token-file")
        .arg(&key)
        .env("HOME", &fixture.dir)
        .env("SHELL", "/bin/sh")
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stderr = gateway.stderr.take().unwrap();
    fixture.children.push(gateway);
    let (send_address, address) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if let Some(value) = line.strip_prefix("OMG mobile listening on ws://") {
                let _ = send_address.send(value.trim_end_matches("/catalogue").to_owned());
            }
        }
    });
    let address = address.recv_timeout(Duration::from_secs(5)).unwrap();
    let token = fs::read_to_string(&key).unwrap();
    assert!(connect(&address, "/control", "wrong").is_err());
    let mut phone = connect(&address, "/control", token.trim()).unwrap();
    let roster = json_reply(&mut phone, "roster");
    assert_eq!(roster["wire"], 2);
    assert_eq!(
        roster["agents"].as_array().unwrap().len(),
        omg_session_runtime::agents::AGENTS.len()
    );
    for required in [
        "codex",
        "claude",
        "pi",
        "antigravity",
        "opencode",
        "cursor",
        "copilot",
        "droid",
        "grok",
        "qwen",
        "amp",
        "cline",
        "kimi",
        "hermes",
        "crush",
        "qoder",
        "reasonix",
        "omp",
        "aider",
    ] {
        assert!(
            roster["agents"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["id"] == required),
            "roster missing agent {required}"
        );
    }
    let folder = roster["projects"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["kind"] == "folder")
        .unwrap();
    let project_id = folder["id"].as_str().unwrap().to_owned();
    let route = folder["sessions"][0]["id"].as_str().unwrap().to_owned();
    assert!(route.ends_with(&format!("/{id}/{generation}")));
    Frame::new(
        b'D',
        1,
        &Frame::new(
            b'I',
            0,
            b"printf '\\033]7501;state=blocked:app=claude:id=fixture:kind=permission\\007'\r",
        )
        .encode(),
    )
    .send(&mut desktop)
    .unwrap();
    loop {
        let roster = json_reply(&mut phone, "roster");
        if roster["projects"].as_array().unwrap().iter().any(|p| {
            p["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["id"] == route && s["status"] == "needsAttention")
        }) {
            break;
        }
    }
    let summary = omg_session_runtime::client::list_local(&host)
        .unwrap()
        .into_iter()
        .find(|s| s.id == id)
        .unwrap();
    assert_eq!(summary.pid.map(u64::from), Some(pid));
    let send = |phone: &mut Ws, value: serde_json::Value| {
        phone.send(Message::Text(value.to_string().into())).unwrap();
    };
    // Viewing a blocked session must not pre-acknowledge a subsequent completion revision.
    send(
        &mut phone,
        serde_json::json!({"t":"acknowledge","session":route}),
    );
    std::thread::sleep(Duration::from_millis(80));
    Frame::new(
        b'D',
        1,
        &Frame::new(
            b'I',
            0,
            b"printf '\\033]7501;state=clear:id=fixture\\007\\033]3008;start=omg-agent-pi-42;type=app;omg_agent=pi;omg_scope=local;omg_state=done\\007'\r",
        )
        .encode(),
    )
    .send(&mut desktop)
    .unwrap();
    loop {
        let roster = json_reply(&mut phone, "roster");
        if roster["projects"].as_array().unwrap().iter().any(|p| {
            p["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["id"] == route && s["agent"] == "pi" && s["status"] == "done")
        }) {
            break;
        }
    }
    send(
        &mut phone,
        serde_json::json!({"t":"acknowledge","session":route}),
    );
    loop {
        let roster = json_reply(&mut phone, "roster");
        if roster["projects"].as_array().unwrap().iter().any(|p| {
            p["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["id"] == route && s["agent"] == "pi" && s["status"] == "idle")
        }) {
            break;
        }
    }
    send(
        &mut phone,
        serde_json::json!({"t":"listFiles","project":project_id,"path":""}),
    );
    let listing = json_reply(&mut phone, "fileList");
    assert!(listing["entries"]
        .as_array()
        .unwrap()
        .iter()
        .any(|f| f["name"] == "README.md" && f["changed"] == true));
    send(
        &mut phone,
        serde_json::json!({"t":"readFile","project":project_id,"path":"README.md","dark":false}),
    );
    let file = json_reply(&mut phone, "file");
    assert_eq!(file["size"], 10);
    send(
        &mut phone,
        serde_json::json!({"t":"writeFile","project":project_id,"path":"README.md",
        "baseMtime":file["mtime"],"data":"IyBFZGl0ZWQK"}),
    );
    assert!(json_reply(&mut phone, "written")["mtime"].as_u64().unwrap() > 0);
    assert_eq!(fs::read(project.join("README.md")).unwrap(), b"# Edited\n");
    send(
        &mut phone,
        serde_json::json!({"t":"readDiff","project":project_id,"path":"README.md","status":"U"}),
    );
    assert!(json_reply(&mut phone, "diff")["text"]
        .as_str()
        .unwrap()
        .contains("+# Edited"));
    // The catalogue read and holder probes did not revoke the desktop writer.
    Frame::new(b'D', 1, &Frame::new(b'I', 0, b"printf '\\104\\105\\123\\113\\124\\117\\120\\137\\123\\124\\111\\114\\114\\137\\127\\122\\111\\124\\105\\123\\n'\r").encode())
        .send(&mut desktop).unwrap();
    let mut output = Vec::new();
    while !output
        .windows(b"DESKTOP_STILL_WRITES".len())
        .any(|b| b == b"DESKTOP_STILL_WRITES")
    {
        let outer = Frame::read(&mut desktop).unwrap();
        if outer.kind == b'D' {
            let frame = Frame::read(&mut outer.data.as_slice()).unwrap();
            assert_ne!(frame.kind, b'B');
            if frame.kind == b'O' {
                output.extend(frame.data);
            }
        }
    }
    Frame::new(
        b'D',
        1,
        &Frame::new(
            b'I',
            0,
            b"printf '\\033]3008;start=omg-ssh-remote;type=remote;targethost=cloud;cwd=/srv/mapping-platform\\007'\r",
        )
        .encode(),
    )
    .send(&mut desktop)
    .unwrap();
    loop {
        let roster = json_reply(&mut phone, "roster");
        if roster["projects"].as_array().unwrap().iter().any(|p| {
            p["kind"] == "folder"
                && p["name"] == "cloud · mapping-platform"
                && p["deviceAlias"] == "cloud"
                && p["sessions"].as_array().unwrap().iter().any(|s| {
                    s["id"] == route
                        && s["remoteHost"] == "cloud"
                        && s["remotePath"] == "/srv/mapping-platform"
                })
        }) {
            break;
        }
    }
    send(&mut phone, serde_json::json!({"t":"startTerminal"}));
    let started = json_reply(&mut phone, "started");
    let parts = started["session"]
        .as_str()
        .unwrap()
        .split('/')
        .collect::<Vec<_>>();
    assert_eq!(parts.len(), 3);
    fixture.owned.push((parts[1].into(), parts[2].into()));
    assert_ne!(parts[1], id);
    send(
        &mut phone,
        serde_json::json!({"t":"stop","session":format!("{}/{}/{}",parts[0],parts[1],"0".repeat(32))}),
    );
    assert!(json_reply(&mut phone, "error")["message"]
        .as_str()
        .unwrap()
        .contains("generation"));
    assert!(omg_session_runtime::client::list_local(&host)
        .unwrap()
        .iter()
        .any(|s| s.id == parts[1] && s.ended.is_none()));
}

#[test]
fn cli_pair_status_revoke_and_stop_manage_standalone_or_ssh_gateway() {
    let base = std::path::PathBuf::from("/tmp").join(format!(
        "omg-mcli-{}",
        &omg_session_runtime::record::nonce().unwrap()[..12]
    ));
    let run_dir = base.join(".omg/run/sshhost01");
    fs::create_dir_all(&run_dir).unwrap();
    fs::set_permissions(&base, fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(base.join(".omg"), fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(base.join(".omg/run"), fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(&run_dir, fs::Permissions::from_mode(0o700)).unwrap();
    let state_dir = base.join(".omg/mobile");
    let mut fixture = Fixture::new(run_dir.clone());
    fixture.cleanup_dirs.push(base.clone());
    fixture.mobile_state_dirs.push(state_dir.clone());
    let binary = env!("CARGO_BIN_EXE_omgd");
    fixture.children.push(
        Command::new(binary)
            .args(["host"])
            .arg(&run_dir)
            .args(["--", "/bin/sh", "-i"])
            .env("HOME", &base)
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let host = run_dir.join("host.sock");
    let _ = (0..300)
        .find_map(|_| {
            UnixStream::connect(&host).ok().or_else(|| {
                std::thread::sleep(Duration::from_millis(10));
                None
            })
        })
        .unwrap();

    let pair_out = Command::new(binary)
        .args(["mobile", "pair", "--listen", "127.0.0.1:0", "--state-dir"])
        .arg(&state_dir)
        .env("HOME", &base)
        .output()
        .unwrap();
    assert!(
        pair_out.status.success(),
        "pair failed: {}",
        String::from_utf8_lossy(&pair_out.stderr)
    );
    let stdout = String::from_utf8_lossy(&pair_out.stdout);
    assert!(stdout.contains('█'));
    let invite_line = stdout
        .lines()
        .find_map(|line| line.strip_prefix("Pairing URL:  "))
        .unwrap();
    let (ws_url, token1) = invite_line
        .strip_prefix("omg://device?url=ws://")
        .unwrap()
        .split_once("&token=")
        .unwrap();

    let status_out = Command::new(binary)
        .args(["mobile", "status", "--json", "--state-dir"])
        .arg(&state_dir)
        .env("HOME", &base)
        .output()
        .unwrap();
    assert!(status_out.status.success());
    let status_json: serde_json::Value = serde_json::from_slice(&status_out.stdout).unwrap();
    assert_eq!(status_json["running"], true);
    assert_eq!(status_json["listen"], ws_url);
    assert_eq!(status_json["endpoints"].as_array().unwrap().len(), 1);

    let mut phone = connect(ws_url, "/control", token1).unwrap();
    let roster = json_reply(&mut phone, "roster");
    assert_eq!(roster["wire"], 2);
    phone
        .send(Message::Text(
            serde_json::json!({"t":"hosts"}).to_string().into(),
        ))
        .unwrap();
    let hosts = json_reply(&mut phone, "hosts");
    assert_eq!(
        hosts["hosts"],
        serde_json::json!([{"id": "local", "name": "Local Machine"}])
    );
    phone.close(None).unwrap();

    let revoke_out = Command::new(binary)
        .args([
            "mobile",
            "revoke",
            "--no-qr",
            "--json",
            "--listen",
            "127.0.0.1:0",
            "--state-dir",
        ])
        .arg(&state_dir)
        .env("HOME", &base)
        .output()
        .unwrap();
    assert!(revoke_out.status.success());
    let revoke_json: serde_json::Value = serde_json::from_slice(&revoke_out.stdout).unwrap();
    let new_listen = revoke_json["listen"].as_str().unwrap();
    let new_invite = revoke_json["invite_url"].as_str().unwrap();
    let (_, token2) = new_invite.split_once("&token=").unwrap();
    assert_ne!(token1, token2);
    assert!(connect(new_listen, "/control", token1).is_err());
    let mut phone2 = connect(new_listen, "/control", token2).unwrap();
    assert_eq!(json_reply(&mut phone2, "roster")["wire"], 2);
    phone2.close(None).unwrap();

    let stop_out = Command::new(binary)
        .args(["mobile", "stop", "--state-dir"])
        .arg(&state_dir)
        .env("HOME", &base)
        .output()
        .unwrap();
    assert!(stop_out.status.success());
    let after_stop = Command::new(binary)
        .args(["mobile", "status", "--json", "--state-dir"])
        .arg(&state_dir)
        .env("HOME", &base)
        .output()
        .unwrap();
    let after_json: serde_json::Value = serde_json::from_slice(&after_stop.stdout).unwrap();
    assert_eq!(after_json["running"], false);
    drop(fixture);
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn post_reboot_lost_local_session_appears_in_roster_and_resurrects_on_ws_attach() {
    let dir = std::env::temp_dir().join(format!("omg-mobile-lost-{}", std::process::id()));
    let sessions_dir = dir.join("sessions");
    fs::create_dir_all(&sessions_dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(&sessions_dir, fs::Permissions::from_mode(0o700)).unwrap();
    let mut fixture = Fixture::new(dir.clone());

    // Simulate a persisted local session lost across reboot: ended = "lost", pid = null, dead socket
    let id = "77777777-8888-9999-aaaa-bbbbbbbbbbbb";
    let mut rec = omg_session_runtime::record::Record::new(
        id,
        omg_session_runtime::lifecycle::Policy::default(),
    )
    .unwrap();
    let old_gen = rec.generation.clone();
    rec.ended = Some(omg_session_runtime::lifecycle::EndReason::Lost);
    rec.cwd = Some("/tmp".into());
    rec.save(&sessions_dir.join(format!("{id}.json"))).unwrap();

    let host_sock = dir.join("host.sock");
    fixture.children.push(
        Command::new(env!("CARGO_BIN_EXE_omgd"))
            .args(["host-local"])
            .arg(&fixture.dir)
            .args(["--", "/bin/sh"])
            .env("HOME", &fixture.dir)
            .env("SHELL", "/bin/sh")
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    );
    assert!((0..300).any(|_| {
        if host_sock.exists() && UnixStream::connect(&host_sock).is_ok() {
            true
        } else {
            std::thread::sleep(Duration::from_millis(10));
            false
        }
    }));

    let key = dir.join("pair.token");
    let mut gateway = Command::new(env!("CARGO_BIN_EXE_omgd"))
        .args(["mobile", "--listen", "127.0.0.1:0", "--socket"])
        .arg(&host_sock)
        .arg("--token-file")
        .arg(&key)
        .arg("--no-qr")
        .env("HOME", &fixture.dir)
        .env("SHELL", "/bin/sh")
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stderr = gateway.stderr.take().unwrap();
    fixture.children.push(gateway);
    let (send_address, recv_address) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if let Some(value) = line.strip_prefix("OMG mobile listening on ws://") {
                let _ = send_address.send(value.trim_end_matches("/catalogue").to_owned());
            }
        }
    });
    let addr = recv_address.recv_timeout(Duration::from_secs(5)).unwrap();
    let token_raw = fs::read_to_string(&key).unwrap();
    let token = token_raw.trim();

    let mut ctrl = connect(&addr, "/control", token).unwrap();
    let roster = json_reply(&mut ctrl, "roster");
    let sessions: Vec<&serde_json::Value> = roster["projects"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|p| p["sessions"].as_array().unwrap().iter())
        .collect();
    let paused_row = sessions
        .iter()
        .find(|s| {
            s["id"]
                .as_str()
                .is_some_and(|sid| sid.ends_with(&format!("/{id}/{old_gen}")))
        })
        .expect("Lost session visible in /control roster");
    assert_eq!(paused_row["paused"], true);
    let route = paused_row["id"].as_str().unwrap().to_owned();
    let ep_id = route.split('/').next().unwrap();
    ctrl.close(None).unwrap();

    let mut ws = connect(&addr, &format!("/ws/{ep_id}"), token).unwrap();
    ws.send(Message::Binary(Frame::new(b'L', 0, &[]).encode().into()))
        .unwrap();
    let mut pending = Vec::new();
    let catalog = receive(&mut ws, &mut pending, b'L');
    let list: Vec<serde_json::Value> = serde_json::from_slice(&catalog.data).unwrap();
    assert_eq!(list[0]["id"], id);
    assert_eq!(list[0]["ended"], "lost");

    let open = serde_json::json!({"id": id, "generation": old_gen, "replay": false});
    ws.send(Message::Binary(
        Frame::new(b'U', 1, &serde_json::to_vec(&open).unwrap())
            .encode()
            .into(),
    ))
    .unwrap();
    let mut rotated_gen = String::new();
    let mut resurrected_session_pid = 0u32;
    loop {
        let wrapped = receive(&mut ws, &mut pending, b'D');
        let inner = Frame::read(&mut wrapped.data.as_slice()).unwrap();
        if inner.kind == b'J' {
            let meta: serde_json::Value = serde_json::from_slice(&inner.data).unwrap();
            rotated_gen = meta["generation"].as_str().unwrap().to_owned();
            resurrected_session_pid = meta["pid"].as_u64().unwrap() as u32;
        }
        if inner.kind == b'S' {
            break;
        }
    }
    assert!(!rotated_gen.is_empty());
    assert_ne!(rotated_gen, old_gen);
    assert!(resurrected_session_pid > 1);
    fixture.owned.push((id.into(), rotated_gen.clone()));

    let live_record =
        omg_session_runtime::record::Record::load(&sessions_dir.join(format!("{id}.json")))
            .unwrap();
    let sock = session_socket_for_id(&dir, id);
    let holder_status = omg_session_runtime::holder::probe(
        &sock,
        id,
        &rotated_gen,
        live_record.holder_capability.as_deref().unwrap(),
    )
    .unwrap();
    let holder_pid = holder_status.holder_pid;
    assert!(holder_pid > 1);
    assert_eq!(holder_status.session_pid, Some(resurrected_session_pid));

    ws.close(None).unwrap();

    // Poll confirmed close until both the PTY leader and detached session-holder exit cleanly.
    let close_deadline = std::time::Instant::now() + Duration::from_secs(6);
    loop {
        let mut host_ctrl = UnixStream::connect(&host_sock).unwrap();
        Frame::new(b'K', 1, id.as_bytes())
            .send(&mut host_ctrl)
            .unwrap();
        let outer = Frame::read(&mut host_ctrl).unwrap();
        assert_eq!(outer.kind, b'D');
        let inner = Frame::read(&mut outer.data.as_slice()).unwrap();
        assert_eq!(inner.kind, b'K');
        if inner.data == b"closed" {
            break;
        }
        assert!(
            std::time::Instant::now() < close_deadline,
            "resurrected session did not confirm close within deadline"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(
        wait_pid_gone(holder_pid, Duration::from_secs(3)),
        "resurrected session-holder PID {holder_pid} must exit before directory cleanup"
    );
    assert!(
        wait_pid_gone(resurrected_session_pid, Duration::from_secs(3)),
        "resurrected shell PID {resurrected_session_pid} must exit before directory cleanup"
    );
    drop(fixture);
    assert!(!dir.exists());
    assert!(pid_is_gone(holder_pid));
    assert!(pid_is_gone(resurrected_session_pid));
}

#[test]
fn dropping_fixture_with_resurrected_holder_without_explicit_close_leaves_zero_orphans() {
    let dir = std::env::temp_dir().join(format!(
        "omg-mobile-drop-{}",
        &omg_session_runtime::record::nonce().unwrap()[..12]
    ));
    let sessions_dir = dir.join("sessions");
    fs::create_dir_all(&sessions_dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(&sessions_dir, fs::Permissions::from_mode(0o700)).unwrap();

    let id = "77777777-8888-9999-aaaa-cccccccccccc";
    let mut rec = omg_session_runtime::record::Record::new(
        id,
        omg_session_runtime::lifecycle::Policy::default(),
    )
    .unwrap();
    let old_gen = rec.generation.clone();
    rec.ended = Some(omg_session_runtime::lifecycle::EndReason::Lost);
    rec.cwd = Some("/tmp".into());
    rec.save(&sessions_dir.join(format!("{id}.json"))).unwrap();

    let (holder_pid, session_pid) = {
        let mut fixture = Fixture::new(dir.clone());
        let host_sock = dir.join("host.sock");
        fixture.children.push(
            Command::new(env!("CARGO_BIN_EXE_omgd"))
                .args(["host-local"])
                .arg(&fixture.dir)
                .args(["--", "/bin/sh"])
                .env("HOME", &fixture.dir)
                .env("SHELL", "/bin/sh")
                .stdout(Stdio::null())
                .spawn()
                .unwrap(),
        );
        assert!((0..300).any(|_| {
            if host_sock.exists() && UnixStream::connect(&host_sock).is_ok() {
                true
            } else {
                std::thread::sleep(Duration::from_millis(10));
                false
            }
        }));

        let key = dir.join("pair.token");
        let mut gateway = Command::new(env!("CARGO_BIN_EXE_omgd"))
            .args(["mobile", "--listen", "127.0.0.1:0", "--socket"])
            .arg(&host_sock)
            .arg("--token-file")
            .arg(&key)
            .arg("--no-qr")
            .env("HOME", &fixture.dir)
            .env("SHELL", "/bin/sh")
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let stderr = gateway.stderr.take().unwrap();
        fixture.children.push(gateway);
        let (send_address, recv_address) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                if let Some(value) = line.strip_prefix("OMG mobile listening on ws://") {
                    let _ = send_address.send(value.trim_end_matches("/catalogue").to_owned());
                }
            }
        });
        let addr = recv_address.recv_timeout(Duration::from_secs(5)).unwrap();
        let token_raw = fs::read_to_string(&key).unwrap();
        let token = token_raw.trim();

        let mut cat_ws = connect(&addr, "/catalogue", token).unwrap();
        let cat_msg = match cat_ws.read().unwrap() {
            Message::Text(text) => serde_json::from_str::<serde_json::Value>(&text).unwrap(),
            other => panic!("unexpected catalogue message: {other:?}"),
        };
        let ep_id = cat_msg["endpoints"][0]["id"].as_str().unwrap().to_owned();
        let _ = cat_ws.close(None);

        let mut ws = connect(&addr, &format!("/ws/{ep_id}"), token).unwrap();
        let open = serde_json::json!({"id": id, "generation": old_gen, "replay": false});
        ws.send(Message::Binary(
            Frame::new(b'U', 1, &serde_json::to_vec(&open).unwrap())
                .encode()
                .into(),
        ))
        .unwrap();
        let mut pending = Vec::new();
        let mut rotated_gen = String::new();
        let mut spid = 0u32;
        loop {
            let wrapped = receive(&mut ws, &mut pending, b'D');
            let inner = Frame::read(&mut wrapped.data.as_slice()).unwrap();
            if inner.kind == b'J' {
                let meta: serde_json::Value = serde_json::from_slice(&inner.data).unwrap();
                rotated_gen = meta["generation"].as_str().unwrap().to_owned();
                spid = meta["pid"].as_u64().unwrap() as u32;
            }
            if inner.kind == b'S' {
                break;
            }
        }
        let live_record =
            omg_session_runtime::record::Record::load(&sessions_dir.join(format!("{id}.json")))
                .unwrap();
        let sock = session_socket_for_id(&dir, id);
        let holder_status = omg_session_runtime::holder::probe(
            &sock,
            id,
            &rotated_gen,
            live_record.holder_capability.as_deref().unwrap(),
        )
        .unwrap();
        let _ = ws.close(None);
        // Intentionally do NOT add to `fixture.owned` and do NOT send `b'K'`!
        // Dropping `fixture` here simulates an assertion panic or abrupt teardown.
        (holder_status.holder_pid, spid)
    };

    assert!(
        !dir.exists(),
        "Fixture::drop must remove temp runtime dir after confirming holder exit"
    );
    assert!(
        pid_is_gone(holder_pid),
        "detached session-holder {holder_pid} must be terminated and reaped by Fixture::drop"
    );
    assert!(
        pid_is_gone(session_pid),
        "resurrected PTY leader {session_pid} must be terminated by Fixture::drop"
    );
}

#[test]
fn idle_exited_broker_paused_session_auto_starts_host_local_and_watermarked_ack_preserves_newer_activity(
) {
    let base = std::path::PathBuf::from("/tmp").join(format!(
        "omg-ma-{}",
        &omg_session_runtime::record::nonce().unwrap()[..10]
    ));
    let support = base.join("OMG Dev");
    let rev = env!("CARGO_PKG_VERSION");
    let key_input = format!("{}\0{rev}", support.display());
    let key_hex: String = Sha256::digest(key_input.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let runtime_root = base.join(".omg/run").join(&key_hex[..20]);
    let sessions_dir = runtime_root.join("sessions");
    fs::create_dir_all(&sessions_dir).unwrap();
    fs::create_dir_all(support.join("session-runtime")).unwrap();
    for p in [
        &base,
        &base.join(".omg"),
        &base.join(".omg/run"),
        &runtime_root,
        &sessions_dir,
    ] {
        fs::set_permissions(p, fs::Permissions::from_mode(0o700)).unwrap();
    }
    fs::write(
        support.join("session-runtime/endpoints.json"),
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "endpoints": [{"descriptor": {"revision": rev}}]
        }))
        .unwrap(),
    )
    .unwrap();

    // Persist a post-reboot / idle-exited `Lost` session WITHOUT starting `host-local`!
    let paused_id = "88888888-9999-aaaa-bbbb-cccccccccccc";
    let mut paused_rec = omg_session_runtime::record::Record::new(
        paused_id,
        omg_session_runtime::lifecycle::Policy::default(),
    )
    .unwrap();
    let paused_gen = paused_rec.generation.clone();
    paused_rec.ended = Some(omg_session_runtime::lifecycle::EndReason::Lost);
    paused_rec.cwd = Some("/tmp".into());
    paused_rec
        .save(&sessions_dir.join(format!("{paused_id}.json")))
        .unwrap();
    fs::write(sessions_dir.join(format!("{paused_id}.snapshot")), b"SNAP").unwrap();
    assert!(!runtime_root.join("host.sock").exists());

    let mut fixture = Fixture::new(runtime_root.clone());
    fixture.cleanup_dirs.push(base.clone());

    let token_path = base.join("pair.token");
    let mut gateway = Command::new(env!("CARGO_BIN_EXE_omgd"))
        .args(["mobile", "--listen", "127.0.0.1:0", "--app-support"])
        .arg(format!("{}/", support.display()))
        .arg("--token-file")
        .arg(&token_path)
        .arg("--no-qr")
        .env("HOME", &base)
        .env("SHELL", "/bin/sh")
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stderr = gateway.stderr.take().unwrap();
    fixture.children.push(gateway);
    let (send_address, recv_address) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if let Some(value) = line.strip_prefix("OMG mobile listening on ws://") {
                let _ = send_address.send(value.trim_end_matches("/catalogue").to_owned());
            }
        }
    });
    let addr = recv_address.recv_timeout(Duration::from_secs(8)).unwrap();
    let token_raw = fs::read_to_string(&token_path).unwrap();
    let token = token_raw.trim();

    // `mobile_targets` must auto-start `host-local` for `runtime_root` and expose the paused session!
    let mut ctrl = connect(&addr, "/control", token).unwrap();
    let roster = json_reply(&mut ctrl, "roster");
    assert!(
        runtime_root.join("host.sock").exists(),
        "mobile_targets must start host-local when recoverable paused sessions exist"
    );
    let all_rows: Vec<&serde_json::Value> = roster["projects"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|p| p["sessions"].as_array().unwrap().iter())
        .collect();
    assert!(
        all_rows.iter().any(|s| {
            s["id"]
                .as_str()
                .is_some_and(|sid| sid.ends_with(&format!("/{paused_id}/{paused_gen}")))
                && s["paused"] == true
        }),
        "paused session must appear in /control roster without pre-spawned host-local"
    );

    // Start a live terminal session and verify watermarked `acknowledge` (`maxRevision: 0`)
    // does NOT wipe a newer `done` state!
    ctrl.send(Message::Text(
        serde_json::json!({"t": "startTerminal"}).to_string().into(),
    ))
    .unwrap();
    let started = json_reply(&mut ctrl, "started");
    let live_route = started["session"].as_str().unwrap().to_owned();
    let parts: Vec<&str> = live_route.split('/').collect();
    let ep_id = parts[0];
    let live_id = parts[1].to_owned();
    let live_gen = parts[2].to_owned();
    fixture.owned.push((live_id.clone(), live_gen.clone()));

    let mut ws = connect(&addr, &format!("/ws/{ep_id}"), token).unwrap();
    let open = serde_json::json!({"id": live_id, "generation": live_gen, "replay": false});
    ws.send(Message::Binary(
        Frame::new(b'U', 1, &serde_json::to_vec(&open).unwrap())
            .encode()
            .into(),
    ))
    .unwrap();
    let mut pending = Vec::new();
    loop {
        let wrapped = receive(&mut ws, &mut pending, b'D');
        let inner = Frame::read(&mut wrapped.data.as_slice()).unwrap();
        if inner.kind == b'S' {
            ws.send(Message::Binary(
                Frame::new(b'D', 1, &Frame::new(b'A', inner.seq, &[]).encode())
                    .encode()
                    .into(),
            ))
            .unwrap();
            ws.send(Message::Binary(
                Frame::new(b'D', 1, &Frame::new(b'W', 0, &[]).encode())
                    .encode()
                    .into(),
            ))
            .unwrap();
        } else if inner.kind == b'W' {
            break;
        }
    }
    ws.send(Message::Binary(
        Frame::new(
            b'D',
            1,
            &Frame::new(
                b'I',
                0,
                b"printf '\\033]7501;state=done:app=pi:id=fixture\\007'\r",
            )
            .encode(),
        )
        .encode()
        .into(),
    ))
    .unwrap();

    loop {
        let r = json_reply(&mut ctrl, "roster");
        if r["projects"].as_array().unwrap().iter().any(|p| {
            p["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["id"] == live_route && s["status"] == "done")
        }) {
            break;
        }
    }

    // Acknowledge with stale watermark `maxRevision: 0` -> newer `done` (revision >= 1) is preserved!
    ctrl.send(Message::Text(
        serde_json::json!({"t": "acknowledge", "session": live_route, "maxRevision": 0})
            .to_string()
            .into(),
    ))
    .unwrap();
    std::thread::sleep(Duration::from_millis(150));
    let summaries =
        omg_session_runtime::client::list_local(&runtime_root.join("host.sock")).unwrap();
    let live_summary = summaries.iter().find(|s| s.id == live_id).unwrap();
    assert_eq!(
        live_summary
            .activity
            .as_ref()
            .and_then(|a| a.presentation())
            .map(|p| p.state),
        Some("done"),
        "stale maxRevision: 0 must not wipe newer done presentation"
    );
    // Now acknowledge without a stale cap -> `done` transitions to `idle`!
    ctrl.send(Message::Text(
        serde_json::json!({"t": "acknowledge", "session": live_route})
            .to_string()
            .into(),
    ))
    .unwrap();
    loop {
        let r = json_reply(&mut ctrl, "roster");
        if r["projects"].as_array().unwrap().iter().any(|p| {
            p["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["id"] == live_route && s["status"] == "idle")
        }) {
            break;
        }
    }

    let _ = ws.close(None);
    let _ = ctrl.close(None);

    // `omgd sessions close --all --yes --local` must also close local `Lost` sessions
    // cleanly (`ended -> ExplicitClose` and `.snapshot` deleted).
    let close_all = Command::new(env!("CARGO_BIN_EXE_omgd"))
        .args([
            "sessions",
            "close",
            "--all",
            "--yes",
            "--local",
            "--app-support",
        ])
        .arg(format!("{}/./", support.display()))
        .env("HOME", &base)
        .env("SHELL", "/bin/sh")
        .output()
        .unwrap();
    assert!(
        close_all.status.success(),
        "sessions close --all failed: stdout={} stderr={}",
        String::from_utf8_lossy(&close_all.stdout),
        String::from_utf8_lossy(&close_all.stderr)
    );
    assert_eq!(
        omg_session_runtime::record::Record::load(&sessions_dir.join(format!("{paused_id}.json")))
            .unwrap()
            .ended,
        Some(omg_session_runtime::lifecycle::EndReason::ExplicitClose)
    );
    assert!(!sessions_dir.join(format!("{paused_id}.snapshot")).exists());

    drop(fixture);
    assert!(!base.exists());
}
