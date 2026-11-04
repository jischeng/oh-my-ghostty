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
}
impl Drop for Fixture {
    fn drop(&mut self) {
        for child in self.children.iter_mut().rev() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = fs::remove_dir_all(&self.dir);
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
