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

struct Fixture {
    children: Vec<Child>,
    dir: std::path::PathBuf,
    owned: Vec<(String, String)>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let host = self.dir.join("host.sock");
        let mut confirmed = true;
        for (id, generation) in &self.owned {
            let path = self.dir.join("sessions").join(format!("{id}.json"));
            if let Ok(record) = omg_session_runtime::record::Record::load(&path) {
                if record.generation == *generation && record.ended.is_none() {
                    if let Ok(mut socket) = UnixStream::connect(&host) {
                        let _ = Frame::new(b'K', 9, id.as_bytes()).send(&mut socket);
                    }
                }
            }
            let deadline = std::time::Instant::now() + Duration::from_secs(7);
            loop {
                let ended = omg_session_runtime::record::Record::load(&path).is_ok_and(|r| {
                    r.generation == *generation && r.ended.is_some() && r.pid.is_none()
                });
                if ended {
                    break;
                }
                if std::time::Instant::now() >= deadline {
                    confirmed = false;
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        for child in self.children.iter_mut().rev() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if confirmed {
            let _ = fs::remove_dir_all(&self.dir);
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
    let mut fixture = Fixture {
        children: vec![],
        dir,
        owned: vec![],
    };
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
    let mut fixture = Fixture {
        children: vec![],
        dir,
        owned: vec![],
    };
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
    assert_eq!(roster["agents"].as_array().unwrap().len(), 4);
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
    let mut fixture = Fixture {
        children: vec![],
        dir: run_dir.clone(),
        owned: vec![],
    };
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
