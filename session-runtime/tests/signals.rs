use omg_session_runtime::*;
use std::{
    fs,
    os::unix::{fs::PermissionsExt, net::UnixStream, process::CommandExt},
    process::Command,
    time::{Duration, Instant},
};
#[test]
fn background_signal_dispositions_do_not_disable_ctrl_c() {
    let dir = std::env::temp_dir().join(format!("omg-signals-{}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let path = dir.join("s");
    let mut command = Command::new(env!("CARGO_BIN_EXE_omgd"));
    command.args([
        "serve",
        path.to_str().unwrap(),
        "--",
        "/bin/sh",
        "-c",
        "printf READY; exec sleep 60",
    ]);
    unsafe {
        command.pre_exec(|| {
            libc::signal(libc::SIGINT, libc::SIG_IGN);
            libc::signal(libc::SIGQUIT, libc::SIG_IGN);
            let mut mask = std::mem::zeroed();
            libc::sigemptyset(&mut mask);
            libc::sigaddset(&mut mask, libc::SIGINT);
            libc::sigprocmask(libc::SIG_BLOCK, &mask, std::ptr::null_mut());
            Ok(())
        });
    }
    let mut child = command.spawn().unwrap();
    let session_pid = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
    let session_pid_ref = session_pid.clone();
    let result = std::panic::catch_unwind(|| {
        let start = Instant::now();
        let mut socket = loop {
            match UnixStream::connect(&path) {
                Ok(s) => break s,
                Err(_) => {
                    assert!(start.elapsed() < Duration::from_secs(3));
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
        };
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let info = Frame::read(&mut socket).unwrap();
        assert_eq!(info.kind, INFO);
        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&info.data) {
            if let Some(pid) = val["pid"].as_u64() {
                session_pid_ref.store(pid as u32, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let snapshot = Frame::read(&mut socket).unwrap();
        assert_eq!(snapshot.kind, SNAPSHOT);
        Frame::new(ACK, snapshot.seq, &[])
            .send(&mut socket)
            .unwrap();
        Frame::new(CLAIM, 0, &[]).send(&mut socket).unwrap();
        loop {
            if Frame::read(&mut socket).unwrap().kind == CLAIM {
                break;
            }
        }
        Frame::new(INPUT, 0, b"\x03").send(&mut socket).unwrap();
        loop {
            if Frame::read(&mut socket).unwrap().kind == EXIT {
                break;
            }
        }
    });
    if matches!(child.try_wait(), Ok(None)) {
        unsafe {
            libc::kill(child.id() as i32, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_millis(300);
        while Instant::now() < deadline {
            if matches!(child.try_wait(), Ok(Some(_))) {
                break;
            }
            std::thread::sleep(Duration::from_millis(15));
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    let spid = session_pid.load(std::sync::atomic::Ordering::SeqCst);
    if spid > 1 {
        unsafe {
            libc::kill(-(spid as i32), libc::SIGKILL);
            libc::kill(spid as i32, libc::SIGKILL);
        }
    }
    let _ = fs::remove_dir_all(dir);
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}
