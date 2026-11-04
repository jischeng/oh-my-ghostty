use omg_session_runtime::*;
use std::{
    fs,
    os::unix::{fs::PermissionsExt, net::UnixStream},
    process::{Child, Command},
    time::{Duration, Instant},
};
struct Daemon {
    child: Child,
    dir: std::path::PathBuf,
}
impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}
fn start() -> Daemon {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "omg-rt-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    fs::create_dir(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    // Raw mode gives byte-exact replies; the child increments while detached.
    let script="import os,tty,select,time\ntty.setraw(0)\nn=0\nwhile True:\n n+=1\n os.write(1, ('\\x1b[2J\\x1b[Htick:%d pid:%d' % (n,os.getpid())).encode())\n ready,_,_=select.select([0],[],[],0.04)\n if ready:\n  data=os.read(0,1024)\n  if b'q' in data: break\n  if b'?' in data:\n   time.sleep(0.15)\n   os.write(1,b'\\x1b[6n')\n   ready,_,_=select.select([0],[],[],1)\n   if ready and b'R' in os.read(0,128):\n    open(os.environ['REPORT'],'w').write('query answered')\n";
    let child = Command::new(env!("CARGO_BIN_EXE_omgd"))
        .args([
            "serve",
            dir.join("s").to_str().unwrap(),
            "--",
            "python3",
            "-u",
            "-c",
            script,
        ])
        .env("REPORT", dir.join("reply"))
        .spawn()
        .unwrap();
    Daemon { child, dir }
}
fn until(socket: &mut UnixStream, kind: u8) -> Frame {
    loop {
        let frame = Frame::read(socket).unwrap();
        if frame.kind == kind {
            return frame;
        }
    }
}

#[test]
fn explicit_takeover_keeps_both_viewers_and_discards_late_old_writer_input() {
    let mut daemon = start();
    let (mut mac, _, info, _) = attach(&daemon);
    assert_eq!(info["writer_transfer"], true);
    Frame::new(CLAIM, 0, &[]).send(&mut mac).unwrap();
    until(&mut mac, CLAIM);
    let (mut phone, _, phone_info, _) = attach(&daemon);
    assert_eq!(info["pid"], phone_info["pid"]);
    Frame::new(CLAIM, 0, &[]).send(&mut phone).unwrap();
    until(&mut phone, b'B');
    Frame::new(CLAIM, 0, b"takeover/1")
        .send(&mut phone)
        .unwrap();
    until(&mut phone, CLAIM);
    assert_eq!(until(&mut mac, b'B').data, b"writer transferred");
    // The old writer had a quit key and resize in flight. Neither may affect
    // the session, and it must remain attached as an observer.
    Frame::new(INPUT, 0, b"q").send(&mut mac).unwrap();
    Frame::new(RESIZE, 0, &[0, 1, 0, 1]).send(&mut mac).unwrap();
    Frame::new(CLOSE, 0, &[]).send(&mut mac).unwrap();
    until(&mut mac, OUTPUT);
    assert!(daemon.child.try_wait().unwrap().is_none());
    Frame::new(RESIZE, 0, &[0, 60, 0, 20])
        .send(&mut phone)
        .unwrap();
    assert_eq!(until(&mut mac, RESIZE).data, [0, 60, 0, 20]);
    Frame::new(CLAIM, 0, b"takeover/1").send(&mut mac).unwrap();
    until(&mut mac, CLAIM);
    until(&mut phone, b'B');
    until(&mut phone, OUTPUT);
    Frame::new(INPUT, 0, b"q").send(&mut mac).unwrap();
    until(&mut mac, EXIT);
}
fn attach(d: &Daemon) -> (UnixStream, Vt, serde_json::Value, u64) {
    let start = Instant::now();
    let mut socket = loop {
        match UnixStream::connect(d.dir.join("s")) {
            Ok(s) => break s,
            Err(_) if start.elapsed() < Duration::from_secs(3) => {
                std::thread::sleep(Duration::from_millis(10))
            }
            Err(e) => panic!("{e}"),
        }
    };
    socket
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let info = Frame::read(&mut socket).unwrap();
    assert_eq!(info.kind, INFO);
    let info: serde_json::Value = serde_json::from_slice(&info.data).unwrap();
    let frame = Frame::read(&mut socket).unwrap();
    assert_eq!(frame.kind, SNAPSHOT);
    let mut vt = Vt::new(80, 24).unwrap();
    vt.restore(&frame.data).unwrap();
    Frame::new(ACK, frame.seq, &[]).send(&mut socket).unwrap();
    (socket, vt, info, frame.seq)
}
fn output(socket: &mut UnixStream, vt: &mut Vt, seq: &mut u64) {
    loop {
        let f = Frame::read(socket).unwrap();
        if f.kind == OUTPUT {
            assert_eq!(f.seq, *seq + f.data.len() as u64);
            *seq = f.seq;
            vt.write(&f.data);
            break;
        }
    }
}
#[test]
fn detach_preserves_pid_live_barrier_queries_and_resize() {
    let mut d = start();
    let (mut s, mut vt, info, mut seq) = attach(&d);
    output(&mut s, &mut vt, &mut seq);
    assert!(vt.text().unwrap().contains("tick:"));
    Frame::new(CLAIM, 0, &[]).send(&mut s).unwrap();
    // The child asks DSR after receiving '?'; detach immediately, so only daemon can answer.
    Frame::new(INPUT, 0, b"?").send(&mut s).unwrap();
    std::thread::sleep(Duration::from_millis(30));
    drop(s);
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(
        fs::read_to_string(d.dir.join("reply")).unwrap(),
        "query answered"
    );
    let (mut s, mut restored, again, mut after) = attach(&d);
    assert_eq!(info["pid"], again["pid"]);
    assert_eq!(info["session_id"], again["session_id"]);
    assert!(after > seq);
    assert!(restored.text().unwrap().contains("tick:"));
    output(&mut s, &mut restored, &mut after);
    Frame::new(CLAIM, 0, &[]).send(&mut s).unwrap();
    Frame::new(RESIZE, 0, &[0, 100, 0, 30])
        .send(&mut s)
        .unwrap();
    loop {
        let f = Frame::read(&mut s).unwrap();
        if f.kind == RESIZE {
            assert_eq!(f.data, [0, 100, 0, 30]);
            break;
        }
    }
    drop(s);
    std::thread::sleep(Duration::from_millis(30));
    let (mut s, _, info, _) = attach(&d);
    assert_eq!(info["cols"], 100);
    assert_eq!(info["rows"], 30);
    Frame::new(CLAIM, 0, &[]).send(&mut s).unwrap();
    // Wait for writer grant before opening another observer.
    loop {
        if Frame::read(&mut s).unwrap().kind == CLAIM {
            break;
        }
    }
    let (mut observer, mut observed, _, mut observed_seq) = attach(&d);
    Frame::new(CLAIM, 0, &[]).send(&mut observer).unwrap();
    loop {
        if Frame::read(&mut observer).unwrap().kind == b'B' {
            break;
        }
    }
    // Busy writer leaves the observer connected and receiving live output.
    // Frames consumed above may include output, so verify liveness directly.
    loop {
        if Frame::read(&mut observer).unwrap().kind == OUTPUT {
            break;
        }
    }
    let _ = (&mut observed, &mut observed_seq);
    drop(observer);
    Frame::new(INPUT, 0, b"q").send(&mut s).unwrap();
    loop {
        if Frame::read(&mut s).unwrap().kind == EXIT {
            break;
        }
    }
    let start = Instant::now();
    while d.child.try_wait().unwrap().is_none() {
        assert!(start.elapsed() < Duration::from_secs(3));
        std::thread::sleep(Duration::from_millis(10));
    }
}
#[test]
fn native_snapshot_restores_parser_continuation_and_alternate_screen() {
    for prefix in [
        b"\x1b[?1049h\x1b[31".as_slice(),
        b"hello \xe4\xb8",
        b"\x1b]2;unfinished",
    ] {
        let mut a = Vt::new(80, 24).unwrap();
        a.write(prefix);
        let snapshot = a.snapshot().unwrap();
        let mut b = Vt::new(80, 24).unwrap();
        b.restore(&snapshot).unwrap();
        let tail: &[u8] = if prefix.ends_with(b"31") {
            b"mRED\x1b[0m".as_slice()
        } else if prefix.ends_with(b"\xb8") {
            b"\xad!"
        } else {
            b" title\x07DONE"
        };
        a.write(tail);
        b.write(tail);
        assert_eq!(a.text().unwrap(), b.text().unwrap());
        assert_eq!(a.snapshot().unwrap(), b.snapshot().unwrap());
        let mut truncated = snapshot.clone();
        truncated.pop();
        assert!(b.restore(&truncated).is_err());
    }
}
#[test]
fn oversized_frames_rejected_before_allocation() {
    let mut data = vec![OUTPUT];
    data.extend(0u64.to_be_bytes());
    data.extend(((MAX_FRAME + 1) as u32).to_be_bytes());
    assert!(Frame::read(&mut &data[..]).is_err());
}
#[test]
fn private_socket_directory_required() {
    let dir = std::env::temp_dir().join(format!("omg-public-{}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(omg_session_runtime::server::serve(&dir.join("s"), &["true".into()]).is_err());
    fs::remove_dir(dir).unwrap();
}
