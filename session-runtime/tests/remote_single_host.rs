use omg_session_runtime::{
    gc::{gc_remote_in, GcOptions},
    host,
    lifecycle::Policy,
    record::{nonce, SessionSummary},
    registry::OpenRequest,
    Frame, INPUT, OUTPUT, SNAPSHOT,
};
use std::{
    fs,
    io::{self, Read},
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

fn omgd_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_omgd"))
}

fn private_dir(path: &Path) {
    fs::create_dir_all(path).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

/// Create a versioned `omgd` directory with `revision`, `verified`, and `snapshot-revision`.
/// Uses a hardlink (or copy fallback) to the compiled `omgd` binary so `current_exe()`
/// resolves inside `versions/<rev>/omgd` (symlinks may be resolved by `current_exe()`).
fn install_version(versions_root: &Path, revision: &str, snapshot_revision: &str) -> PathBuf {
    let dir = versions_root.join(revision);
    private_dir(&dir);
    let target = dir.join("omgd");
    let src = omgd_bin();
    if fs::hard_link(&src, &target).is_err() {
        fs::copy(&src, &target).unwrap();
    }
    fs::set_permissions(&target, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(dir.join("revision"), format!("{revision}\n")).unwrap();
    fs::write(dir.join("verified"), format!("{revision}\n")).unwrap();
    fs::write(
        dir.join("snapshot-revision"),
        format!("{snapshot_revision}\n"),
    )
    .unwrap();
    target
}

fn host_ping(socket: &Path) -> io::Result<String> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    Frame::new(b'P', 0, &[]).send(&mut stream)?;
    let reply = Frame::read(&mut stream)?;
    assert_eq!(reply.kind, b'P');
    Ok(String::from_utf8_lossy(&reply.data).into_owned())
}

fn host_list(socket: &Path) -> io::Result<Vec<SessionSummary>> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    Frame::new(b'L', 0, &[]).send(&mut stream)?;
    let reply = Frame::read(&mut stream)?;
    if reply.kind != b'L' {
        return Err(io::Error::other(format!(
            "unexpected list reply kind={}: {}",
            reply.kind as char,
            String::from_utf8_lossy(&reply.data)
        )));
    }
    serde_json::from_slice(&reply.data).map_err(io::Error::other)
}

fn host_close_until_done(socket: &Path, id: &str, timeout: Duration) -> io::Result<()> {
    let deadline = Instant::now() + timeout;
    loop {
        let mut stream = UnixStream::connect(socket)?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(2)))?;
        Frame::new(b'K', 1, id.as_bytes()).send(&mut stream)?;
        let outer = Frame::read(&mut stream)?;
        if outer.kind == b'D' && outer.seq == 1 {
            let inner = Frame::read(&mut outer.data.as_slice())?;
            if inner.kind == b'K' && inner.data == b"closed" {
                return Ok(());
            }
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out waiting for session close",
            ));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn open_session_stream(
    socket: &Path,
    id: &str,
    create: bool,
) -> io::Result<(UnixStream, omg_session_runtime::Vt)> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let req = OpenRequest {
        id: id.to_owned(),
        policy: Policy::default(),
        create,
        cols: Some(80),
        rows: Some(24),
        ..Default::default()
    };
    Frame::new(b'C', 1, &serde_json::to_vec(&req)?).send(&mut stream)?;
    let mut vt = omg_session_runtime::Vt::new(80, 24)?;
    // Complete initial SNAPSHOT -> ACK -> CLAIM handshake.
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out waiting for initial SNAPSHOT",
            ));
        }
        let outer = Frame::read(&mut stream)?;
        if outer.kind == b'E' {
            return Err(io::Error::other(
                String::from_utf8_lossy(&outer.data).into_owned(),
            ));
        }
        if outer.kind == b'D' && outer.seq == 1 {
            let inner = Frame::read(&mut outer.data.as_slice())?;
            if inner.kind == SNAPSHOT {
                vt.restore(&inner.data)?;
                let ack = Frame::new(omg_session_runtime::ACK, inner.seq, &[]).encode();
                Frame::new(b'D', 1, &ack).send(&mut stream)?;
                let claim = Frame::new(omg_session_runtime::CLAIM, 0, b"takeover/1").encode();
                Frame::new(b'D', 1, &claim).send(&mut stream)?;
                break;
            }
        }
    }
    Ok((stream, vt))
}

fn send_session_input(stream: &mut UnixStream, bytes: &[u8]) -> io::Result<()> {
    let inner = Frame::new(INPUT, 0, bytes).encode();
    Frame::new(b'D', 1, &inner).send(stream)
}

fn read_until_contains(
    stream: &mut UnixStream,
    vt: &mut omg_session_runtime::Vt,
    needle: &str,
    timeout: Duration,
) -> io::Result<String> {
    if let Ok(text) = vt.text() {
        if text.contains(needle) {
            return Ok(text);
        }
    }
    let deadline = Instant::now() + timeout;
    let mut collected = String::new();
    stream.set_read_timeout(Some(Duration::from_millis(200)))?;
    while Instant::now() < deadline {
        match Frame::read(stream) {
            Ok(outer) if outer.kind == b'D' && outer.seq == 1 => {
                let inner = Frame::read(&mut outer.data.as_slice())?;
                match inner.kind {
                    SNAPSHOT => {
                        let _ = vt.restore(&inner.data);
                        let ack = Frame::new(omg_session_runtime::ACK, inner.seq, &[]).encode();
                        Frame::new(b'D', 1, &ack).send(stream)?;
                        if let Ok(text) = vt.text() {
                            collected.push_str(&text);
                        }
                    }
                    OUTPUT => {
                        vt.write(&inner.data);
                        collected.push_str(&String::from_utf8_lossy(&inner.data));
                    }
                    _ => {}
                }
                if collected.contains(needle) {
                    return Ok(collected);
                }
                if let Ok(text) = vt.text() {
                    if text.contains(needle) {
                        return Ok(text);
                    }
                }
            }
            Ok(outer) if outer.kind == b'E' => {
                return Err(io::Error::other(
                    String::from_utf8_lossy(&outer.data).into_owned(),
                ));
            }
            Ok(_) => {}
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("did not observe {needle:?} in output: {collected:?}"),
    ))
}

fn pid_alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn kill_pid(pid: u32) {
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGTERM);
    }
}

#[test]
fn remote_holder_spawn_upgrade_takeover_incompatible_guard_and_gc() {
    let base = PathBuf::from(format!("/tmp/omg-rh-{}", &nonce().unwrap()[..8]));
    let versions = base.join("versions");
    let run_root = base.join("run");
    let state_dir = run_root.join("s-aabbccddeeff");
    private_dir(&base);
    private_dir(&versions);
    private_dir(&run_root);
    private_dir(&state_dir);

    let snap_v1 = "7abe5365444c63ee8df6";
    let snap_incompat = "11111111111111111111";
    let bin_v1 = install_version(&versions, "rev-v1", snap_v1);
    let bin_v2 = install_version(&versions, "rev-v2", snap_v1);
    let bin_incompat = install_version(&versions, "rev-incompat", snap_incompat);

    // 1. Start rev-v1 in remote-holder mode via ensure-host.
    let status = Command::new(&bin_v1)
        .args(["ensure-host", "--remote-holder"])
        .arg(&state_dir)
        .env("SHELL", "/bin/sh")
        .status()
        .unwrap();
    assert!(status.success(), "rev-v1 ensure-host failed");

    let host_sock = state_dir.join("host.sock");
    let caps = host_ping(&host_sock).unwrap();
    assert!(caps.contains("remote-holder/1"), "caps={caps}");
    assert!(caps.contains("holder-presentation/1"), "caps={caps}");

    let id_v1 = host::query_host_identity(&host_sock).unwrap();
    assert_eq!(id_v1.mode, "remote-holder");
    assert_eq!(id_v1.revision, "rev-v1");
    assert_eq!(id_v1.snapshot_revision.as_deref(), Some(snap_v1));
    assert!(pid_alive(id_v1.pid));

    // 2. Open a remote session (spawns detached session-holder), set shell state, verify PTY I/O.
    let session_id = "11111111-2222-3333-4444-555555555555";
    let (mut s1, mut vt1) = open_session_stream(&host_sock, session_id, true).unwrap();
    send_session_input(
        &mut s1,
        b"OMG_PERSIST_VAR=SURVIVED_UPGRADE_99; export OMG_PERSIST_VAR; echo BEFORE_TAKEOVER_OK\n",
    )
    .unwrap();
    let out1 = read_until_contains(
        &mut s1,
        &mut vt1,
        "BEFORE_TAKEOVER_OK",
        Duration::from_secs(5),
    )
    .unwrap();
    assert!(out1.contains("BEFORE_TAKEOVER_OK"));
    drop(s1);

    let list_before = host_list(&host_sock).unwrap();
    let rec_before = list_before.iter().find(|s| s.id == session_id).unwrap();
    assert!(rec_before.ended.is_none());
    let orig_pid = rec_before.pid.expect("live session pid");
    let orig_gen = rec_before.generation.clone();

    // 3. Incompatible snapshot-revision MUST refuse takeover and preserve rev-v1 + session!
    let incompat_out = Command::new(&bin_incompat)
        .args(["ensure-host", "--remote-holder"])
        .arg(&state_dir)
        .env("SHELL", "/bin/sh")
        .output()
        .unwrap();
    assert!(
        !incompat_out.status.success(),
        "incompatible snapshot-revision should have failed takeover"
    );
    let id_after_incompat = host::query_host_identity(&host_sock).unwrap();
    assert_eq!(id_after_incompat.pid, id_v1.pid);
    assert_eq!(id_after_incompat.revision, "rev-v1");
    assert!(pid_alive(orig_pid));

    // 4. Concurrent compatible upgrade to rev-v2 (5 simultaneous ensure-host callers!).
    let mut children = Vec::new();
    for _ in 0..5 {
        children.push(
            Command::new(&bin_v2)
                .args(["ensure-host", "--remote-holder", "--force-takeover"])
                .arg(&state_dir)
                .env("SHELL", "/bin/sh")
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap(),
        );
    }
    for child in children {
        let out = child.wait_with_output().unwrap();
        assert!(
            out.status.success(),
            "concurrent rev-v2 ensure-host failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    let id_v2 = host::query_host_identity(&host_sock).unwrap();
    assert_eq!(id_v2.mode, "remote-holder");
    assert_eq!(id_v2.revision, "rev-v2");
    assert_ne!(
        id_v2.pid, id_v1.pid,
        "rev-v2 should have replaced rev-v1 host"
    );
    assert!(pid_alive(id_v2.pid));

    // Wait briefly for rev-v1 process to finish exiting.
    let wait_v1 = Instant::now() + Duration::from_secs(3);
    while pid_alive(id_v1.pid) && Instant::now() < wait_v1 {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(!pid_alive(id_v1.pid), "old rev-v1 host should have exited");

    // 5. Reattach to the SAME session through rev-v2 host and verify VT + PTY continuity!
    let (mut s2, mut vt2) = open_session_stream(&host_sock, session_id, false).unwrap();
    let snap_out = read_until_contains(
        &mut s2,
        &mut vt2,
        "BEFORE_TAKEOVER_OK",
        Duration::from_secs(5),
    )
    .unwrap();
    assert!(
        snap_out.contains("BEFORE_TAKEOVER_OK"),
        "VT snapshot lost across host upgrade"
    );
    send_session_input(&mut s2, b"echo AFTER=$OMG_PERSIST_VAR\n").unwrap();
    let live_out = read_until_contains(
        &mut s2,
        &mut vt2,
        "AFTER=SURVIVED_UPGRADE_99",
        Duration::from_secs(5),
    )
    .unwrap();
    assert!(live_out.contains("AFTER=SURVIVED_UPGRADE_99"));
    drop(s2);

    let list_after = host_list(&host_sock).unwrap();
    let rec_after = list_after.iter().find(|s| s.id == session_id).unwrap();
    assert_eq!(rec_after.pid, Some(orig_pid));
    assert_eq!(rec_after.generation, orig_gen);

    // 6. Verify GC while session-holder (spawned from rev-v1 binary!) is STILL LIVE:
    //    rev-v1 MUST NOT be deleted while its session-holder is running,
    //    rev-v2 (active) MUST NOT be deleted,
    //    rev-incompat (unused, dead) SHOULD be reaped when min_age_secs = 0!
    let gc_while_live = gc_remote_in(
        &versions,
        &run_root,
        &GcOptions {
            active_revision: Some("rev-v2".into()),
            active_state_dir: Some(state_dir.clone()),
            min_age_secs: 0,
            dry_run: false,
        },
    )
    .unwrap();
    assert!(
        versions.join("rev-v1").exists(),
        "rev-v1 still has a live session-holder and must not be reaped"
    );
    assert!(versions.join("rev-v2").exists());
    assert!(state_dir.exists());
    assert!(
        !versions.join("rev-incompat").exists(),
        "unused dead rev-incompat should be reaped: {gc_while_live:?}"
    );

    // 7. Close the session cleanly, then verify rev-v1 CAN now be safely reaped by GC!
    host_close_until_done(&host_sock, session_id, Duration::from_secs(10)).unwrap();
    // Wait briefly for rev-v1 session-holder to finish exiting.
    let wait_holder = Instant::now() + Duration::from_secs(3);
    while pid_alive(orig_pid) && Instant::now() < wait_holder {
        std::thread::sleep(Duration::from_millis(20));
    }
    // Give session-holder a moment to exit after child exits.
    std::thread::sleep(Duration::from_millis(150));

    let gc_after_close = gc_remote_in(
        &versions,
        &run_root,
        &GcOptions {
            active_revision: Some("rev-v2".into()),
            active_state_dir: Some(state_dir.clone()),
            min_age_secs: 0,
            dry_run: false,
        },
    )
    .unwrap();
    assert!(
        !versions.join("rev-v1").exists(),
        "rev-v1 should now be reaped after its session-holder exited: {gc_after_close:?}"
    );
    assert!(versions.join("rev-v2").exists());
    assert!(state_dir.exists());

    // Cleanup rev-v2 host daemon before removing temp dir.
    kill_pid(id_v2.pid);
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn ensure_host_remote_holder_never_kills_legacy_monolithic_host() {
    let base = PathBuf::from(format!("/tmp/omg-leg-{}", &nonce().unwrap()[..8]));
    let versions = base.join("versions");
    let legacy_state = base.join("run/abcdef123456");
    private_dir(&base);
    private_dir(&versions);
    private_dir(&legacy_state);

    let bin_legacy = install_version(&versions, "rev-legacy", "7abe5365444c63ee8df6");
    let bin_new = install_version(&versions, "rev-new", "7abe5365444c63ee8df6");

    // Start legacy monolithic host via plain `ensure-host`.
    let status = Command::new(&bin_legacy)
        .args(["ensure-host"])
        .arg(&legacy_state)
        .env("SHELL", "/bin/sh")
        .status()
        .unwrap();
    assert!(status.success());

    let host_sock = legacy_state.join("host.sock");
    let id_before = host::query_host_identity(&host_sock).unwrap();
    assert_eq!(id_before.mode, "remote");

    // Even if `ensure-host --remote-holder` is called on a legacy monolithic dir,
    // it MUST preserve the monolithic host untouched (never kill its in-process PTYs!).
    let status2 = Command::new(&bin_new)
        .args(["ensure-host", "--remote-holder", "--force-takeover"])
        .arg(&legacy_state)
        .env("SHELL", "/bin/sh")
        .status()
        .unwrap();
    assert!(status2.success());

    let id_after = host::query_host_identity(&host_sock).unwrap();
    assert_eq!(id_after.pid, id_before.pid);
    assert_eq!(id_after.mode, "remote");

    // Unused Read import guard check: ensure socket still serves pings.
    let mut s = UnixStream::connect(&host_sock).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    Frame::new(b'P', 0, &[]).send(&mut s).unwrap();
    let mut hdr = [0u8; 1];
    s.read_exact(&mut hdr).unwrap();
    assert_eq!(hdr[0], b'P');

    kill_pid(id_before.pid);
    let _ = fs::remove_dir_all(&base);
}
