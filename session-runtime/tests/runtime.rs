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
        let sessions_dir = self.dir.join("sessions");
        let _ = fs::set_permissions(&sessions_dir, fs::Permissions::from_mode(0o700));
        let mut session_pids = Vec::new();
        if let Ok(entries) = fs::read_dir(&sessions_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("json") {
                    if let Ok(rec) = record::Record::load(&path) {
                        if let Some(pid) = rec.pid.filter(|&p| p > 1) {
                            session_pids.push(pid);
                        }
                        if rec.ended.is_none() {
                            let _ = fs::write(sessions_dir.join(format!("{}.closed", rec.id)), b"");
                        }
                    }
                }
            }
        }
        if matches!(self.child.try_wait(), Ok(None)) {
            unsafe {
                libc::kill(self.child.id() as i32, libc::SIGTERM);
            }
            let deadline = Instant::now() + Duration::from_millis(300);
            while Instant::now() < deadline {
                if matches!(self.child.try_wait(), Ok(Some(_))) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(15));
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        for spid in session_pids {
            unsafe {
                libc::kill(-(spid as i32), libc::SIGKILL);
                libc::kill(spid as i32, libc::SIGKILL);
            }
        }
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

fn connect_session(path: &std::path::Path) -> (UnixStream, serde_json::Value, activity::Snapshot) {
    let start = Instant::now();
    let mut socket = loop {
        match UnixStream::connect(path) {
            Ok(s) => break s,
            Err(_) if start.elapsed() < Duration::from_secs(3) => {
                std::thread::sleep(Duration::from_millis(10))
            }
            Err(e) => panic!("{e}"),
        }
    };
    socket
        .set_read_timeout(Some(Duration::from_secs(4)))
        .unwrap();
    let info = Frame::read(&mut socket).unwrap();
    assert_eq!(info.kind, INFO);
    let info: serde_json::Value = serde_json::from_slice(&info.data).unwrap();
    let snap = Frame::read(&mut socket).unwrap();
    assert_eq!(snap.kind, SNAPSHOT);
    let act = Frame::read(&mut socket).unwrap();
    assert_eq!(act.kind, activity::FRAME);
    assert_eq!(act.seq, snap.seq);
    let initial = activity::Snapshot::decode(&act.data).unwrap();
    Frame::new(ACK, snap.seq, &[]).send(&mut socket).unwrap();
    (socket, info, initial)
}

fn next_activity(socket: &mut UnixStream, label: &str) -> activity::Snapshot {
    loop {
        let frame = Frame::read(socket).unwrap_or_else(|e| panic!("next_activity({label}): {e}"));
        if frame.kind == activity::FRAME {
            return activity::Snapshot::decode(&frame.data).unwrap();
        }
    }
}

#[test]
fn child_fg_pgid_report_env_injection_mouse_safe_ack_and_live_fences() {
    let dir = std::path::PathBuf::from("/tmp")
        .join(format!("omg-rta-{}", &record::nonce().unwrap()[..8]));
    fs::create_dir(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let sock_path = dir.join("s.sock");
    let env_out = dir.join("env.json");
    let bin = env!("CARGO_BIN_EXE_omgd");

    // Interactive Python harness simulating a shell + child foreground job PGID + SIGINT-catching REPL + crashing agent.
    let script = r#"
import json, os, select, signal, subprocess, sys, tty

tty.setraw(0)
signal.signal(signal.SIGTTOU, signal.SIG_IGN)
env_keys = ["OMG_SESSION_ID", "OMG_AGENT_SOCK", "OMG_RUNTIME_EVENT_SOCKET", "OMG_RUNTIME_EVENT_TOKEN", "AGY_CLI_OSC7501"]
with open(os.environ["ENV_OUT"], "w") as fp:
    json.dump({k: os.environ.get(k) for k in env_keys}, fp)
os.write(1, b"READY\n")

shell_pgid = os.getpgrp()
buf = b""
while True:
    r, _, _ = select.select([0], [], [], 0.05)
    if not r:
        continue
    chunk = os.read(0, 1024)
    if not chunk:
        break
    if b"\x03" in chunk:
        # Simulate REPL catching SIGINT without exiting!
        os.write(1, b"^C\n")
        chunk = chunk.replace(b"\x03", b"")
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        cmd = line.strip().decode("utf-8", "ignore")
        if cmd == "CHILD_REPORT":
            pid = os.fork()
            if pid == 0:
                os.setpgid(0, 0)
                os.tcsetpgrp(0, os.getpgrp())
                rc = subprocess.call([
                    os.environ["OMG_BIN"], "report",
                    "opencode", "working", "conv-77", os.environ["WORK_DIR"],
                    "--message", "Indexing workspace"
                ])
                if rc != 0:
                    os._exit(rc)
                # Stay alive briefly until told or let parent restore shell foreground
                select.select([0], [], [], 0.35)
                os._exit(0)
            else:
                try:
                    os.setpgid(pid, pid)
                except OSError:
                    pass
                os.waitpid(pid, 0)
                os.tcsetpgrp(0, shell_pgid)
        elif cmd == "REPORT_DONE":
            subprocess.check_call([
                os.environ["OMG_BIN"], "report",
                "opencode", "done", "conv-77", os.environ["WORK_DIR"],
                "--message", "Finished indexing"
            ])
        elif cmd == "REPORT_WORKING":
            subprocess.check_call([
                os.environ["OMG_BIN"], "report",
                "claude", "working", "conv-88", os.environ["WORK_DIR"]
            ])
        elif cmd == "PROMPT_FENCE":
            os.tcsetpgrp(0, shell_pgid)
            os.write(1, b"\x1b]133;A\x07$ ")
        elif cmd == "CRASH_AGENT":
            pid = os.fork()
            if pid == 0:
                os.setpgid(0, 0)
                os.tcsetpgrp(0, os.getpgrp())
                subprocess.check_call([
                    os.environ["OMG_BIN"], "report",
                    "codex", "working", "conv-99", os.environ["WORK_DIR"]
                ])
                os.kill(os.getpid(), signal.SIGKILL)
            else:
                try:
                    os.setpgid(pid, pid)
                except OSError:
                    pass
                os.waitpid(pid, 0)
                os.tcsetpgrp(0, shell_pgid)
        elif cmd == "QUIT":
            sys.exit(0)
"#;

    let child = Command::new(bin)
        .args([
            "serve",
            sock_path.to_str().unwrap(),
            "--",
            "python3",
            "-u",
            "-c",
            script,
        ])
        .env("ENV_OUT", &env_out)
        .env("OMG_BIN", bin)
        .env("WORK_DIR", &dir)
        .spawn()
        .unwrap();
    let daemon = Daemon {
        child,
        dir: dir.clone(),
    };

    let (mut client, info, _) = connect_session(&sock_path);
    assert_eq!(info["activity_acknowledge"], true);
    Frame::new(CLAIM, 0, &[]).send(&mut client).unwrap();
    until(&mut client, CLAIM);

    // Wait for env.json to be written and verify universal env injection.
    let start = Instant::now();
    while !env_out.exists() {
        assert!(start.elapsed() < Duration::from_secs(3));
        std::thread::sleep(Duration::from_millis(10));
    }
    let injected: serde_json::Value = serde_json::from_slice(&fs::read(&env_out).unwrap()).unwrap();
    assert_eq!(injected["OMG_SESSION_ID"], info["session_id"]);
    assert_eq!(injected["AGY_CLI_OSC7501"], "on");
    assert!(injected["OMG_AGENT_SOCK"]
        .as_str()
        .is_some_and(|s| s.ends_with(".evt")));
    assert_eq!(
        injected["OMG_AGENT_SOCK"],
        injected["OMG_RUNTIME_EVENT_SOCKET"]
    );

    // 1. Child foreground PGID calling `omgd report` succeeds and broadcasts live `G`.
    Frame::new(INPUT, 0, b"CHILD_REPORT\n")
        .send(&mut client)
        .unwrap();
    let snap_working = next_activity(&mut client, "step1_child_report");
    let pres = snap_working.presentation().expect("working presentation");
    assert_eq!(pres.agent, "opencode");
    assert_eq!(pres.state, "working");
    assert_eq!(pres.message, "Indexing workspace");

    // 2. Report `done`, then send mouse motion, focus events, and bracketed-paste `\x03` on `I`:
    //    NONE of them may wipe `done`!
    Frame::new(INPUT, 0, b"REPORT_DONE\n")
        .send(&mut client)
        .unwrap();
    let snap_done = loop {
        let s = next_activity(&mut client, "step2_report_done");
        if s.presentation().is_some_and(|p| p.state == "done") {
            break s;
        }
    };
    assert_eq!(
        snap_done.presentation().unwrap().message,
        "Finished indexing"
    );

    Frame::new(
        INPUT,
        0,
        b"\x1b[<35;20;10M\x1b[I\x1b[O\x1b[200~\x03\x1b[201~\n",
    )
    .send(&mut client)
    .unwrap();
    std::thread::sleep(Duration::from_millis(120));
    let (_, _, reattached_snap) = connect_session(&sock_path);
    assert_eq!(
        reattached_snap.presentation().map(|p| p.state),
        Some("done"),
        "mouse/focus/paste input frames must NEVER wipe done!"
    );

    // Explicit `C` (`ACKNOWLEDGE`) transitions `done -> idle` and broadcasts live `G`.
    Frame::new(ACKNOWLEDGE, 0, &snap_done.revision.to_be_bytes())
        .send(&mut client)
        .unwrap();
    let snap_acked = next_activity(&mut client, "step2_ack");
    assert_eq!(
        snap_acked.presentation().map(|p| p.state),
        Some("idle"),
        "explicit C acknowledge must transition done -> idle"
    );

    // 3. REPL catches SIGINT (`0x03` Ctrl+C) without exiting -> Interrupt Fence transitions `working -> idle` and broadcasts `G`.
    Frame::new(INPUT, 0, b"REPORT_WORKING\n")
        .send(&mut client)
        .unwrap();
    loop {
        let s = next_activity(&mut client, "step3_working");
        if s.presentation()
            .is_some_and(|p| p.agent == "claude" && p.state == "working")
        {
            break;
        }
    }
    Frame::new(INPUT, 0, b"\x03").send(&mut client).unwrap();
    let snap_interrupted = next_activity(&mut client, "step3_ctrl_c");
    assert_eq!(
        snap_interrupted.presentation().map(|p| p.state),
        Some("idle"),
        "Ctrl+C interrupt fence must clear stuck working on SIGINT-catching REPL"
    );

    // 4. Shell Prompt Return Fence (`OSC 133;A`) clears lingering `working` when foreground is shell.
    Frame::new(INPUT, 0, b"REPORT_WORKING\n")
        .send(&mut client)
        .unwrap();
    loop {
        let s = next_activity(&mut client, "step4_working");
        if s.presentation()
            .is_some_and(|p| p.agent == "claude" && p.state == "working")
        {
            break;
        }
    }
    Frame::new(INPUT, 0, b"PROMPT_FENCE\n")
        .send(&mut client)
        .unwrap();
    let snap_prompt = loop {
        let s = next_activity(&mut client, "step4_prompt_fence");
        if s.presentation().is_some_and(|p| p.state == "idle") {
            break s;
        }
    };
    assert_eq!(snap_prompt.presentation().unwrap().state, "idle");

    // 5. Crashed `working` child process transitions to `error` via process-liveness prune and broadcasts `G`!
    Frame::new(INPUT, 0, b"CRASH_AGENT\n")
        .send(&mut client)
        .unwrap();
    let snap_crashed = loop {
        let s = next_activity(&mut client, "step5_crash_agent");
        if s.presentation()
            .is_some_and(|p| p.agent == "codex" && p.state == "error")
        {
            break s;
        }
    };
    assert_eq!(snap_crashed.presentation().unwrap().state, "error");

    // 6. Verify `inline_bytes_with_mode` backward-compatible `mode=restore` vs `mode=live`.
    let restore_bytes = snap_crashed.inline_bytes_with_mode("restore");
    let live_bytes = snap_crashed.inline_bytes_with_mode("live");
    assert!(restore_bytes
        .windows(
            b"start=omg-agent-sync;mode=restore\x07\x1b]3008;start=omg-agent-sync;begin\x07".len()
        )
        .any(|w| w
            == b"start=omg-agent-sync;mode=restore\x07\x1b]3008;start=omg-agent-sync;begin\x07"));
    assert!(live_bytes
        .windows(
            b"start=omg-agent-sync;mode=live\x07\x1b]3008;start=omg-agent-sync;begin\x07".len()
        )
        .any(
            |w| w == b"start=omg-agent-sync;mode=live\x07\x1b]3008;start=omg-agent-sync;begin\x07"
        ));

    let mut outer_vt = Vt::new(80, 24).unwrap();
    outer_vt.write(&restore_bytes);
    assert!(outer_vt.activity_mut().take_last_change_sync_restore());
    outer_vt.write(&live_bytes);
    assert!(!outer_vt.activity_mut().take_last_change_sync_restore());

    Frame::new(INPUT, 0, b"QUIT\n").send(&mut client).unwrap();
    drop(client);
    drop(daemon);
}

#[test]
fn exec_leader_and_detached_daemon_hooks_avoid_false_error_and_sync_restore_broadcasts_g() {
    struct DirGuard(std::path::PathBuf);
    impl Drop for DirGuard {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let dir = std::path::PathBuf::from("/tmp")
        .join(format!("omg-rt2-{}", &record::nonce().unwrap()[..8]));
    fs::create_dir(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let _guard = DirGuard(dir.clone());
    let sock_path = dir.join("s.sock");
    let ready_file = dir.join("ready");
    let bin = env!("CARGO_BIN_EXE_omgd");

    // Here `python3` IS the `exec`-launched `session_leader` (`fg_pgid == session_leader`).
    let script = dir.join("exec_agent.py");
    fs::write(
        &script,
        format!(
            r#"import os, pathlib, signal, subprocess, sys

bin_path = {bin:?}
ready_path = {ready_file:?}
daemon_proc = None
pathlib.Path(ready_path).write_text("ok")

while True:
    line = sys.stdin.readline()
    if not line:
        break
    cmd = line.strip()
    if cmd == "EPHEMERAL_HOOK":
        subprocess.run(
            ["/bin/sh", "-c", f'"{{bin_path}}" report claude working conv-e /tmp --message "Hook turn"'],
            preexec_fn=lambda: os.setpgid(0, 0),
            check=True,
        )
    elif cmd == "START_DAEMON":
        daemon_code = (
            "import subprocess, time\n"
            f'subprocess.run(["/bin/sh", "-c", \'"{{bin_path}}" report opencode working conv-d /tmp --message "Daemon turn"\'], check=True)\n'
            "time.sleep(30)\n"
        )
        daemon_proc = subprocess.Popen(
            [sys.executable, "-c", daemon_code],
            start_new_session=True,
        )
    elif cmd == "KILL_DAEMON":
        if daemon_proc is not None:
            os.kill(daemon_proc.pid, signal.SIGKILL)
            daemon_proc.wait()
            daemon_proc = None
    elif cmd == "EMIT_SYNC_RESTORE":
        sys.stdout.write(
            "\x1b]3008;start=omg-agent-sync;mode=restore\x07"
            "\x1b]3008;start=omg-agent-sync;begin\x07"
            "\x1b]3008;start=omg-agent-pi-77;type=app;omg_agent=pi;omg_scope=remote;omg_state=done;message=RemoteDone\x07"
            "\x1b]3008;start=omg-agent-sync;end\x07"
        )
        sys.stdout.flush()
    elif cmd == "QUIT":
        if daemon_proc is not None:
            try:
                os.kill(daemon_proc.pid, signal.SIGKILL)
            except OSError:
                pass
        break
"#
        ),
    )
    .unwrap();

    let command = vec![
        "python3".to_owned(),
        "-u".to_owned(),
        script.to_str().unwrap().to_owned(),
    ];
    let sock_clone = sock_path.clone();
    let daemon = std::thread::spawn(move || server::serve(&sock_clone, &command));

    for _ in 0..100 {
        if sock_path.exists() && ready_file.exists() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let (mut client, _, _) = connect_session(&sock_path);
    Frame::new(CLAIM, 0, &[]).send(&mut client).unwrap();
    until(&mut client, CLAIM);

    // 1. Ephemeral `setpgid(0, 0)` hook inside an `exec`-launched session must bind to
    //    `session_leader` and stay `working` past the 500ms prune tick (no false `error`!).
    Frame::new(INPUT, 0, b"EPHEMERAL_HOOK\n")
        .send(&mut client)
        .unwrap();
    let snap_hook = next_activity(&mut client, "ephemeral_hook_working");
    assert_eq!(snap_hook.presentation().unwrap().agent, "claude");
    assert_eq!(snap_hook.presentation().unwrap().state, "working");
    std::thread::sleep(Duration::from_millis(650));
    let (_, _, check1) = connect_session(&sock_path);
    assert_eq!(
        check1.presentation().map(|p| p.state),
        Some("working"),
        "ephemeral hook exit in exec-launched session must NOT trigger false crash error!"
    );
    // Clear Step 1's `claude: working` via Kitty CSI u `Ctrl+C` (`\x1b[99;5u`) live over `'I'`!
    Frame::new(INPUT, 0, b"\x1b[99;5u\n")
        .send(&mut client)
        .unwrap();
    let snap_kitty_int = next_activity(&mut client, "kitty_ctrl_c");
    assert_eq!(snap_kitty_int.presentation().map(|p| p.state), Some("idle"));

    // 2. Detached `setsid()` daemon running `/bin/sh -c "omgd report ..."` binds to the
    //    long-lived daemon PID rather than `/bin/sh`, staying `working` past 650ms, and
    //    transitions to `error` ONLY when the daemon itself crashes!
    Frame::new(INPUT, 0, b"START_DAEMON\n")
        .send(&mut client)
        .unwrap();
    let snap_daemon = loop {
        let s = next_activity(&mut client, "daemon_working");
        if s.presentation()
            .is_some_and(|p| p.agent == "opencode" && p.state == "working")
        {
            break s;
        }
    };
    assert_eq!(snap_daemon.presentation().unwrap().state, "working");
    std::thread::sleep(Duration::from_millis(650));
    let (_, _, check2) = connect_session(&sock_path);
    assert_eq!(
        check2.presentation().map(|p| (p.agent, p.state)),
        Some(("opencode".to_owned(), "working")),
        "exiting /bin/sh wrapper of detached daemon must NOT trigger false crash error!"
    );

    Frame::new(INPUT, 0, b"KILL_DAEMON\n")
        .send(&mut client)
        .unwrap();
    let snap_daemon_crashed = loop {
        let s = next_activity(&mut client, "daemon_crashed");
        if s.presentation()
            .is_some_and(|p| p.agent == "opencode" && p.state == "error")
        {
            break s;
        }
    };
    assert_eq!(snap_daemon_crashed.presentation().unwrap().state, "error");

    // 3. Inline SSH `mode=restore` written to PTY ALWAYS broadcasts `'G'` to attached peers
    //    with `sync_restore == true` (unblocking attached iOS viewers while preserving Desktop restore mode)!
    Frame::new(INPUT, 0, b"EMIT_SYNC_RESTORE\n")
        .send(&mut client)
        .unwrap();
    let snap_sync = loop {
        let s = next_activity(&mut client, "sync_restore_broadcast");
        if s.presentation()
            .is_some_and(|p| p.agent == "pi" && p.state == "done")
        {
            break s;
        }
    };
    assert!(
        snap_sync.sync_restore,
        "G broadcast from inline SSH mode=restore must carry sync_restore=true"
    );

    Frame::new(INPUT, 0, b"QUIT\n").send(&mut client).unwrap();
    drop(client);
    let _ = daemon.join();
}

#[test]
fn user_keystroke_resets_agent_done_reaper_without_wiping_done_badge() {
    struct DirGuard(std::path::PathBuf);
    impl Drop for DirGuard {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let bin = env!("CARGO_BIN_EXE_omgd");
    let run_case = |input_frame: &[u8]| -> Option<lifecycle::EndReason> {
        let dir = std::path::PathBuf::from("/tmp")
            .join(format!("omg-rt3-{}", &record::nonce().unwrap()[..8]));
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let _guard = DirGuard(dir.clone());
        let sock_path = dir.join("s.sock");
        let rec_path = dir.join("rec.json");

        let policy = lifecycle::Policy {
            close_on_agent_done: true,
            agent_done_grace_seconds: 0,
            terminate_grace_seconds: 1,
            ..lifecycle::Policy::default()
        };
        let mut session_rec =
            record::Record::new("11111111-2222-3333-4444-555555555555", policy).unwrap();
        session_rec.save(&rec_path).unwrap();

        let script = dir.join("reaper_agent.py");
        fs::write(
            &script,
            format!(
                r#"import subprocess, sys
while True:
    line = sys.stdin.readline()
    if not line or "READY" in line:
        break
subprocess.run([{bin:?}, "report", "hermes", "done", "conv-reaper", "/tmp", "--message", "Done"], check=True)
while True:
    line = sys.stdin.readline()
    if not line or "QUIT" in line:
        break
"#
            ),
        )
        .unwrap();

        let argv = vec![
            "python3".to_owned(),
            "-u".to_owned(),
            script.to_str().unwrap().to_owned(),
        ];
        let sock_clone = sock_path.clone();
        let rec_clone = rec_path.clone();
        let daemon = std::thread::spawn(move || {
            server::serve_managed(
                &sock_clone,
                argv,
                Some(server::ManagedSession {
                    path: rec_clone,
                    record: session_rec,
                    containment_root: None,
                    initial_cwd: None,
                    local_launch: None,
                    remote_launch: None,
                    presentation: None,
                    resurrect: false,
                    shutdown_wake: None,
                }),
            )
        });

        for _ in 0..100 {
            if sock_path.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }

        {
            let (mut client, _, _initial_snap) = connect_session(&sock_path);
            Frame::new(CLAIM, 0, &[]).send(&mut client).unwrap();
            until(&mut client, CLAIM);
            Frame::new(INPUT, 0, b"READY\n").send(&mut client).unwrap();
            loop {
                let s = next_activity(&mut client, "reaper_done");
                if s.presentation().is_some_and(|p| p.state == "done") {
                    break;
                }
            }
            Frame::new(INPUT, 0, input_frame).send(&mut client).unwrap();
            std::thread::sleep(Duration::from_millis(80));
        } // `client` drops -> session is detached!

        std::thread::sleep(Duration::from_millis(650));
        let loaded = record::Record::load(&rec_path).unwrap();
        if loaded.ended.is_none() {
            let (mut client2, _, reattached) = connect_session(&sock_path);
            assert_eq!(
                reattached.presentation().map(|p| p.state),
                Some("done"),
                "user keystroke must reset close_on_agent_done reaper while preserving UI done badge"
            );
            Frame::new(CLAIM, 0, &[]).send(&mut client2).unwrap();
            until(&mut client2, CLAIM);
            Frame::new(INPUT, 0, b"QUIT\n").send(&mut client2).unwrap();
        }
        let _ = daemon.join();
        record::Record::load(&rec_path).unwrap().ended
    };

    // Control: mouse motion + focus events do NOT reset `agent_done`, so session reaps as `AgentCompleted`.
    assert_eq!(
        run_case(b"\x1b[<35;10;20M\x1b[I"),
        Some(lifecycle::EndReason::AgentCompleted)
    );
    // Fix: Kitty CSI u keystroke (`\x1b[121u`) resets `agent_done` without wiping `done` badge!
    assert_eq!(
        run_case(b"\x1b[121u"),
        Some(lifecycle::EndReason::ProcessExited)
    );
}

#[test]
fn eighteen_plus_agent_recovery_descriptors_validate_and_format_arguments() {
    let cases = [
        ("codex", "c-1", vec!["codex", "resume", "c-1"]),
        ("claude", "c-2", vec!["claude", "--resume", "c-2"]),
        ("pi", "c-3", vec!["pi", "--session-id", "c-3"]),
        ("antigravity", "c-4", vec!["agy", "--conversation", "c-4"]),
        ("agy", "c-4", vec!["agy", "--conversation", "c-4"]),
        ("opencode", "c-5", vec!["opencode", "--session", "c-5"]),
        ("grok", "c-6", vec!["grok", "--resume", "c-6"]),
        ("qwen", "c-7", vec!["qwen", "--resume", "c-7"]),
        ("hermes", "c-8", vec!["hermes", "--resume", "c-8"]),
        ("qoder", "c-9", vec!["qodercli", "--resume", "c-9"]),
        ("reasonix", "c-10", vec!["reasonix", "--resume", "c-10"]),
        ("omp", "c-11", vec!["omp", "--resume=c-11"]),
    ];
    for (agent, conv, expected) in cases {
        let r = record::Resume {
            agent: agent.into(),
            conversation_id: conv.into(),
            cwd: "/tmp".into(),
        };
        r.validate().unwrap();
        assert_eq!(r.arguments().unwrap(), expected);
    }
    // Agents without CLI session-id flags still validate in the unified registry without failing Resume::validate.
    for non_resumable in [
        "cursor", "copilot", "droid", "amp", "cline", "kimi", "crush", "aider",
    ] {
        let r = record::Resume {
            agent: non_resumable.into(),
            conversation_id: "conv-x".into(),
            cwd: "/tmp".into(),
        };
        r.validate().unwrap();
        assert!(r.arguments().is_err());
    }
}

#[test]
fn login_wrapper_shell_child_osc133a_fence_and_agent_child_crash_detection() {
    struct DirGuard(std::path::PathBuf);
    impl Drop for DirGuard {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let dir = std::path::PathBuf::from("/tmp")
        .join(format!("omg-login-{}", &record::nonce().unwrap()[..8]));
    fs::create_dir(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let _guard = DirGuard(dir.clone());

    let sock_path = dir.join("s.sock");
    let rec_path = dir.join("rec.json");
    let shell_pid_file = dir.join("shell.pid");
    let agent_pid_file = dir.join("agent.pid");
    let login_script = dir.join("login_sim.py");
    let agent_script = dir.join("agent_job.py");
    let bin = env!("CARGO_BIN_EXE_omgd");

    fs::write(
        &login_script,
        format!(
            r#"import os, signal, sys

signal.signal(signal.SIGTTOU, signal.SIG_IGN)
signal.signal(signal.SIGTTIN, signal.SIG_IGN)

shell_bin = "/bin/zsh" if os.path.exists("/bin/zsh") else ("/bin/bash" if os.path.exists("/bin/bash") else "/bin/sh")
if shell_bin.endswith("zsh"):
    shell_argv = ["-" + shell_bin, "-f", "-i"]
elif shell_bin.endswith("bash"):
    shell_argv = ["-" + shell_bin, "--norc", "--noprofile", "-i"]
else:
    shell_argv = ["-" + shell_bin, "-m", "-i"]

pid = os.fork()
if pid == 0:
    os.setpgid(0, 0)
    try:
        os.tcsetpgrp(0, os.getpid())
    except OSError:
        pass
    signal.signal(signal.SIGTTOU, signal.SIG_DFL)
    signal.signal(signal.SIGTTIN, signal.SIG_DFL)
    env = dict(os.environ)
    env["PS1"] = "PROMPT> "
    os.execve(shell_bin, shell_argv, env)

try:
    os.setpgid(pid, pid)
except OSError:
    pass
with open({shell_pid:?}, "w") as f:
    f.write(str(pid))
_, status = os.waitpid(pid, 0)
sys.exit(0)
"#,
            shell_pid = shell_pid_file.to_str().unwrap(),
        ),
    )
    .unwrap();

    fs::write(
        &agent_script,
        format!(
            r#"import os, subprocess, time
with open({agent_pid:?}, "w") as f:
    f.write(f"{{os.getpid()}} {{os.getpgrp()}}")
subprocess.run(
    [{bin:?}, "report", "claude", "working", "conv-login", "/tmp", "--message", "Running"],
    check=True,
)
while True:
    time.sleep(0.2)
"#,
            agent_pid = agent_pid_file.to_str().unwrap(),
            bin = bin,
        ),
    )
    .unwrap();

    let mut session_rec = record::Record::new(
        "22222222-3333-4444-5555-666666666666",
        lifecycle::Policy::default(),
    )
    .unwrap();
    session_rec.save(&rec_path).unwrap();

    let argv = vec![
        "python3".to_owned(),
        "-c".to_owned(),
        format!(
            "import os, sys; os.execvp(sys.executable, ['login', '-u', {:?}])",
            login_script.to_str().unwrap()
        ),
    ];
    let sock_clone = sock_path.clone();
    let rec_clone = rec_path.clone();
    let daemon = std::thread::spawn(move || {
        server::serve_managed(
            &sock_clone,
            argv,
            Some(server::ManagedSession {
                path: rec_clone,
                record: session_rec,
                containment_root: None,
                initial_cwd: None,
                local_launch: None,
                remote_launch: None,
                presentation: None,
                resurrect: false,
                shutdown_wake: None,
            }),
        )
    });

    for _ in 0..100 {
        if sock_path.exists()
            && shell_pid_file.exists()
            && record::Record::load(&rec_path)
                .ok()
                .and_then(|r| r.pid)
                .is_some()
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let shell_pgid: i32 = fs::read_to_string(&shell_pid_file)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    let leader_pid = record::Record::load(&rec_path).unwrap().pid.unwrap() as i32;
    assert_ne!(shell_pgid, leader_pid);

    let (mut client, _, _) = connect_session(&sock_path);
    Frame::new(CLAIM, 0, &[]).send(&mut client).unwrap();
    until(&mut client, CLAIM);
    // Let the interactive child shell settle as foreground TPGID.
    std::thread::sleep(Duration::from_millis(150));

    // (a.1) Stuck `working` emitted in the login shell's own PGID resets to `idle` on `OSC 133;A`.
    Frame::new(
        INPUT,
        0,
        b"printf '\\033]7501;state=working:app=claude:id=osc133-turn\\007'\n",
    )
    .send(&mut client)
    .unwrap();
    loop {
        let snap = next_activity(&mut client, "login_osc133_working");
        if snap.presentation().is_some_and(|p| p.state == "working") {
            break;
        }
    }
    Frame::new(INPUT, 0, b"printf '\\033]133;A;cl=line\\007'\n")
        .send(&mut client)
        .unwrap();
    loop {
        let snap = next_activity(&mut client, "login_osc133_reset_working");
        if snap.presentation().is_none_or(|p| p.state == "idle") {
            break;
        }
    }

    // (a.2) Stuck `needsAttention` at the login shell PGID also resets to `idle` on `OSC 133;A`.
    Frame::new(
        INPUT,
        0,
        b"printf '\\033]7501;state=blocked:app=claude:id=osc133-perm:kind=permission\\007'\n",
    )
    .send(&mut client)
    .unwrap();
    loop {
        let snap = next_activity(&mut client, "login_osc133_blocked");
        if snap
            .presentation()
            .is_some_and(|p| p.state == "needsAttention")
        {
            break;
        }
    }
    Frame::new(INPUT, 0, b"printf '\\033]133;A;cl=line\\007'\n")
        .send(&mut client)
        .unwrap();
    loop {
        let snap = next_activity(&mut client, "login_osc133_reset_blocked");
        if snap.presentation().is_none_or(|p| p.state == "idle") {
            break;
        }
    }

    // (b) Agent child job spawned by the login shell binds `r.owner` to the agent child PGID
    // (neither `login` nor the intermediate shell), so `SIGKILL` of the agent child marks `error`.
    let launch_cmd = format!("python3 -u {}\n", agent_script.display());
    Frame::new(INPUT, 0, launch_cmd.as_bytes())
        .send(&mut client)
        .unwrap();
    let working_snap = loop {
        let snap = next_activity(&mut client, "login_agent_child_working");
        if snap
            .presentation()
            .is_some_and(|p| p.agent == "claude" && p.state == "working")
        {
            break snap;
        }
    };
    let ids_raw = fs::read_to_string(&agent_pid_file).unwrap();
    let mut parts = ids_raw.split_whitespace();
    let _agent_pid: i32 = parts.next().unwrap().parse().unwrap();
    let agent_pgid: i32 = parts.next().unwrap().parse().unwrap();
    assert_ne!(agent_pgid, leader_pid);
    assert_ne!(agent_pgid, shell_pgid);
    let expected_record_id = format!("omg-agent-claude-{agent_pgid}");
    assert!(
        working_snap
            .records
            .iter()
            .any(|r| r.id == expected_record_id),
        "expected owner bound to agent child PGID ({expected_record_id}), got {:?}",
        working_snap.records
    );

    unsafe {
        libc::kill(-agent_pgid, libc::SIGKILL);
    }
    loop {
        let snap = next_activity(&mut client, "login_agent_child_sigkill_error");
        if snap
            .presentation()
            .is_some_and(|p| p.agent == "claude" && p.state == "error")
        {
            break;
        }
    }

    Frame::new(INPUT, 0, b"exit\n").send(&mut client).unwrap();
    let _ = daemon.join();
}

#[cfg(target_os = "macos")]
fn pid_cpu_nanos(pid: u32) -> Option<u64> {
    let mut info: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
    let rc = unsafe {
        libc::proc_pid_rusage(
            pid as libc::c_int,
            libc::RUSAGE_INFO_V2,
            (&mut info as *mut libc::rusage_info_v2).cast(),
        )
    };
    (rc == 0).then_some(info.ri_user_time.saturating_add(info.ri_system_time))
}

#[cfg(target_os = "linux")]
fn pid_cpu_nanos(pid: u32) -> Option<u64> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after = stat.rsplit_once(") ")?.1;
    let mut fields = after.split_whitespace();
    let utime: u64 = fields.nth(11)?.parse().ok()?;
    let stime: u64 = fields.next()?.parse().ok()?;
    let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as u64;
    Some(utime.saturating_add(stime).saturating_mul(1_000_000_000) / ticks)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn pid_cpu_nanos(_pid: u32) -> Option<u64> {
    None
}

fn pid_gone(pid: u32) -> bool {
    if pid <= 1 {
        return true;
    }
    let rc = unsafe { libc::kill(pid as i32, 0) };
    rc != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

#[test]
fn local_holder_snapshot_failure_backs_off_without_cpu_spin_and_recovers_plus_orphaned_dir_exits() {
    use sha2::{Digest, Sha256};
    let dir = std::path::PathBuf::from("/tmp").join(format!(
        "omg-holder-snap-{}",
        &record::nonce().unwrap()[..10]
    ));
    let sessions_dir = dir.join("sessions");
    fs::create_dir_all(&sessions_dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(&sessions_dir, fs::Permissions::from_mode(0o700)).unwrap();

    let host_child = Command::new(env!("CARGO_BIN_EXE_omgd"))
        .args(["host-local", dir.to_str().unwrap(), "--", "/bin/sh"])
        .env("HOME", &dir)
        .env("SHELL", "/bin/sh")
        .stdout(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let mut daemon = Daemon {
        child: host_child,
        dir: dir.clone(),
    };
    let host_sock = dir.join("host.sock");
    for _ in 0..300 {
        if host_sock.exists() && UnixStream::connect(&host_sock).is_ok() {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    let id = "12121212-3434-5656-7878-909090909090";
    let mut env_map: std::collections::BTreeMap<String, String> = std::collections::BTreeMap::new();
    env_map.insert("HOME".into(), dir.to_string_lossy().into_owned());
    env_map.insert("PATH".into(), "/usr/bin:/bin".into());
    env_map.insert("SHELL".into(), "/bin/sh".into());
    env_map.insert("TERM".into(), "xterm-256color".into());
    let req = serde_json::json!({
        "id": id,
        "policy": lifecycle::Policy::default(),
        "create": true,
        "cwd": "/tmp",
        "launch": {
            "argv": ["/bin/sh", "-i"],
            "env": env_map,
            "cwd": "/tmp",
            "cols": 80,
            "rows": 24,
            "pixel_width": 640,
            "pixel_height": 384,
        }
    });

    let mut client = UnixStream::connect(&host_sock).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(8)))
        .unwrap();
    Frame::new(b'C', 1, &serde_json::to_vec(&req).unwrap())
        .send(&mut client)
        .unwrap();

    let mut session_pid = 0u32;
    let mut generation = String::new();
    loop {
        let outer = Frame::read(&mut client).unwrap();
        assert_eq!(outer.kind, b'D');
        let inner = Frame::read(&mut outer.data.as_slice()).unwrap();
        match inner.kind {
            INFO => {
                let meta: serde_json::Value = serde_json::from_slice(&inner.data).unwrap();
                session_pid = meta["pid"].as_u64().unwrap() as u32;
                generation = meta["generation"].as_str().unwrap().to_owned();
            }
            SNAPSHOT => {
                Frame::new(b'D', 1, &Frame::new(ACK, inner.seq, &[]).encode())
                    .send(&mut client)
                    .unwrap();
                Frame::new(b'D', 1, &Frame::new(CLAIM, 0, &[]).encode())
                    .send(&mut client)
                    .unwrap();
            }
            CLAIM => break,
            _ => {}
        }
    }

    let rec_path = sessions_dir.join(format!("{id}.json"));
    let loaded_rec = record::Record::load(&rec_path).unwrap();
    let sock_hash: String = Sha256::digest(id.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let session_sock = dir.join(format!("{}.sock", &sock_hash[..16]));
    let holder_status = holder::probe(
        &session_sock,
        id,
        &generation,
        loaded_rec.holder_capability.as_deref().unwrap(),
    )
    .unwrap();
    let holder_pid = holder_status.holder_pid;
    assert!(holder_pid > 1);
    assert!(session_pid > 1);

    // Block snapshot target with a non-empty directory so save_snapshot_atomic fails deterministically.
    let snap_file = server::snapshot_path(&rec_path);
    fs::create_dir_all(snap_file.join("blocker")).unwrap();

    Frame::new(
        b'D',
        1,
        &Frame::new(INPUT, 0, b"printf 'LIVE_BACKOFF_RECOVER_OK\\n'\n").encode(),
    )
    .send(&mut client)
    .unwrap();
    let mut output = Vec::new();
    let out_deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < out_deadline {
        let outer = Frame::read(&mut client).unwrap();
        if outer.kind == b'D' {
            let inner = Frame::read(&mut outer.data.as_slice()).unwrap();
            if inner.kind == OUTPUT {
                output.extend_from_slice(&inner.data);
                if output
                    .windows(b"LIVE_BACKOFF_RECOVER_OK".len())
                    .any(|w| w == b"LIVE_BACKOFF_RECOVER_OK")
                {
                    break;
                }
            }
        }
    }
    drop(client);

    // Wait 3.8s: crosses the 3s SNAPSHOT_DEBOUNCE (triggering the failed snapshot save) and sits
    // for 0.8s inside the backoff window, where the old code spun at ~75% CPU (~600ms CPU in 0.8s).
    let cpu_before = pid_cpu_nanos(holder_pid);
    std::thread::sleep(Duration::from_millis(3800));
    if let (Some(before), Some(after)) = (cpu_before, pid_cpu_nanos(holder_pid)) {
        let delta_ms = after.saturating_sub(before) / 1_000_000;
        assert!(
            delta_ms < 250,
            "holder burned {delta_ms}ms CPU during 3.8s snapshot failure window (poll(0) spin regression)"
        );
    }

    // Unblock snapshot target -> retry after backoff writes the snapshot cleanly.
    fs::remove_dir_all(&snap_file).unwrap();
    let recover_deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < recover_deadline {
        if snap_file.is_file() {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(
        snap_file.is_file(),
        "holder must recover and persist VT snapshot after path becomes writable"
    );
    let snap_bytes =
        server::load_snapshot(&rec_path, loaded_rec.snapshot_revision.as_deref()).unwrap();
    let mut restored = Vt::new(80, 24).unwrap();
    restored.restore(&snap_bytes).unwrap();
    assert!(restored.text().unwrap().contains("LIVE_BACKOFF_RECOVER_OK"));

    // Now stop broker and delete the runtime directory out from under the detached holder:
    // the orphaned holder must detect its missing bound socket and exit cleanly without spinning.
    let _ = daemon.child.kill();
    let _ = daemon.child.wait();
    fs::remove_dir_all(&dir).unwrap();

    let orphan_deadline = Instant::now() + Duration::from_secs(4);
    while Instant::now() < orphan_deadline {
        if pid_gone(holder_pid) && pid_gone(session_pid) {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(
        pid_gone(holder_pid),
        "orphaned session-holder {holder_pid} must self-terminate when its runtime dir is deleted"
    );
    assert!(
        pid_gone(session_pid),
        "orphaned PTY leader {session_pid} must terminate with its session-holder"
    );
}

#[test]
fn detached_hermes_hook_rejects_cross_pane_bleed_and_unwritable_resume_save_keeps_session_alive() {
    use sha2::{Digest, Sha256};
    let dir = std::path::PathBuf::from("/tmp").join(format!(
        "omg-hermes-guard-{}",
        &record::nonce().unwrap()[..10]
    ));
    let sessions_dir = dir.join("sessions");
    let hermes_home = dir.join("hermes");
    fs::create_dir_all(&sessions_dir).unwrap();
    fs::create_dir_all(hermes_home.join("terminal-sessions")).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(&sessions_dir, fs::Permissions::from_mode(0o700)).unwrap();

    let host_child = Command::new(env!("CARGO_BIN_EXE_omgd"))
        .args(["host-local", dir.to_str().unwrap(), "--", "/bin/sh"])
        .env("HOME", &dir)
        .env("SHELL", "/bin/sh")
        .stdout(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let _daemon = Daemon {
        child: host_child,
        dir: dir.clone(),
    };
    let host_sock = dir.join("host.sock");
    for _ in 0..300 {
        if host_sock.exists() && UnixStream::connect(&host_sock).is_ok() {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    let id = "56565656-7878-9090-abab-cdcdcdcdcdcd";
    let mut env_map: std::collections::BTreeMap<String, String> = std::collections::BTreeMap::new();
    env_map.insert("HOME".into(), dir.to_string_lossy().into_owned());
    env_map.insert(
        "HERMES_HOME".into(),
        hermes_home.to_string_lossy().into_owned(),
    );
    env_map.insert("PATH".into(), "/usr/bin:/bin".into());
    env_map.insert("SHELL".into(), "/bin/sh".into());
    env_map.insert("TERM".into(), "xterm-256color".into());
    let req = serde_json::json!({
        "id": id,
        "policy": lifecycle::Policy::default(),
        "create": true,
        "cwd": "/tmp",
        "launch": {
            "argv": ["/bin/sh", "-i"],
            "env": env_map,
            "cwd": "/tmp",
            "cols": 80,
            "rows": 24,
            "pixel_width": 640,
            "pixel_height": 384,
        }
    });

    let mut client = UnixStream::connect(&host_sock).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(8)))
        .unwrap();
    Frame::new(b'C', 1, &serde_json::to_vec(&req).unwrap())
        .send(&mut client)
        .unwrap();

    loop {
        let outer = Frame::read(&mut client).unwrap();
        assert_eq!(outer.kind, b'D');
        let inner = Frame::read(&mut outer.data.as_slice()).unwrap();
        match inner.kind {
            SNAPSHOT => {
                Frame::new(b'D', 1, &Frame::new(ACK, inner.seq, &[]).encode())
                    .send(&mut client)
                    .unwrap();
                Frame::new(b'D', 1, &Frame::new(CLAIM, 0, &[]).encode())
                    .send(&mut client)
                    .unwrap();
            }
            CLAIM => break,
            _ => {}
        }
    }

    // Print tty path and OMG_RUNTIME_EVENT_* from inside the PTY session so we can test a detached daemon hook.
    let env_probe = dir.join("pane_env.txt");
    let cmd_str = format!(
        "printf '%s\\n%s\\n%s\\n%s\\n' \"$(tty)\" \"$OMG_RUNTIME_EVENT_SOCKET\" \"$OMG_RUNTIME_EVENT_TOKEN\" \"$OMG_RUNTIME_GENERATION\" > '{}' && printf 'ENV_%s_OK\\n' READY\r",
        env_probe.display()
    );
    Frame::new(b'D', 1, &Frame::new(INPUT, 0, cmd_str.as_bytes()).encode())
        .send(&mut client)
        .unwrap();
    let mut output = Vec::new();
    while !output
        .windows(b"ENV_READY_OK".len())
        .any(|w| w == b"ENV_READY_OK")
    {
        let outer = Frame::read(&mut client).unwrap();
        if outer.kind == b'D' {
            let inner = Frame::read(&mut outer.data.as_slice()).unwrap();
            if inner.kind == OUTPUT {
                output.extend(inner.data);
            }
        }
    }
    let lines: Vec<String> = fs::read_to_string(&env_probe)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    let tty_path = &lines[0];
    let evt_sock = &lines[1];
    let evt_token = &lines[2];
    let evt_gen = &lines[3];
    let sanitized_tty: String = tty_path
        .trim_start_matches('/')
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '-'
            }
        })
        .collect();

    // 1) Detached Hermes gateway daemon (spawned outside the PTY session via `setsid`) reporting
    //    conversation `conv-pane-b` WITHOUT matching breadcrumb on Pane A's TTY MUST be rejected!
    use std::os::unix::process::CommandExt;
    let mut bleed_cmd = Command::new(env!("CARGO_BIN_EXE_omgd"));
    bleed_cmd
        .args(["report", "hermes", "working", "conv-pane-b", "/tmp"])
        .env("OMG_RUNTIME_EVENT_SOCKET", evt_sock)
        .env("OMG_RUNTIME_EVENT_TOKEN", evt_token)
        .env("OMG_RUNTIME_GENERATION", evt_gen)
        .env_remove("OMG_REPORT_SESSION_ID")
        .env("HERMES_HOME", &hermes_home);
    unsafe {
        bleed_cmd.pre_exec(|| {
            let _ = libc::setsid();
            Ok(())
        });
    }
    let bleed_status = bleed_cmd.status().unwrap();
    assert!(
        !bleed_status.success(),
        "detached Hermes gateway event for another pane's conversation must be rejected"
    );
    let rec_path = sessions_dir.join(format!("{id}.json"));
    assert!(record::Record::load(&rec_path).unwrap().resume.is_none());

    // 2) Explicit mismatched `--session-id` is also rejected even for non-Hermes events.
    let bad_sid_status = Command::new(env!("CARGO_BIN_EXE_omgd"))
        .args([
            "report",
            "opencode",
            "working",
            "conv-opencode-1",
            "/tmp",
            "--session-id",
            "00000000-0000-0000-0000-000000000000",
        ])
        .env("OMG_RUNTIME_EVENT_SOCKET", evt_sock)
        .env("OMG_RUNTIME_EVENT_TOKEN", evt_token)
        .env("OMG_RUNTIME_GENERATION", evt_gen)
        .status()
        .unwrap();
    assert!(!bad_sid_status.success());

    // 3) Write matching Hermes TTY breadcrumb for `conv-pane-a` -> detached Hermes hook succeeds!
    fs::write(
        hermes_home
            .join("terminal-sessions")
            .join(format!("tty-{sanitized_tty}")),
        br#"{"session_id":"conv-pane-a"}"#,
    )
    .unwrap();
    let mut ok_cmd = Command::new(env!("CARGO_BIN_EXE_omgd"));
    ok_cmd
        .args(["report", "hermes", "working", "conv-pane-a", "/tmp"])
        .env("OMG_RUNTIME_EVENT_SOCKET", evt_sock)
        .env("OMG_RUNTIME_EVENT_TOKEN", evt_token)
        .env("OMG_RUNTIME_GENERATION", evt_gen)
        .env_remove("OMG_REPORT_SESSION_ID")
        .env("HERMES_HOME", &hermes_home);
    unsafe {
        ok_cmd.pre_exec(|| {
            let _ = libc::setsid();
            Ok(())
        });
    }
    assert!(ok_cmd.status().unwrap().success());
    assert_eq!(
        record::Record::load(&rec_path)
            .unwrap()
            .resume
            .as_ref()
            .map(|r| r.conversation_id.as_str()),
        Some("conv-pane-a")
    );

    // 4) Make `sessions/` unwritable (`0o500`) and send an `AgentEvent` `done` with a new `resume`:
    //    `Record.save` failure must NOT kill the live PTY session!
    fs::write(
        hermes_home
            .join("terminal-sessions")
            .join(format!("tty-{sanitized_tty}")),
        br#"{"session_id":"conv-pane-a-2"}"#,
    )
    .unwrap();
    fs::set_permissions(&sessions_dir, fs::Permissions::from_mode(0o500)).unwrap();
    let mut unwritable_cmd = Command::new(env!("CARGO_BIN_EXE_omgd"));
    unwritable_cmd
        .args(["report", "hermes", "done", "conv-pane-a-2", "/tmp"])
        .env("OMG_RUNTIME_EVENT_SOCKET", evt_sock)
        .env("OMG_RUNTIME_EVENT_TOKEN", evt_token)
        .env("OMG_RUNTIME_GENERATION", evt_gen)
        .env_remove("OMG_REPORT_SESSION_ID")
        .env("HERMES_HOME", &hermes_home);
    unsafe {
        unwritable_cmd.pre_exec(|| {
            let _ = libc::setsid();
            Ok(())
        });
    }
    assert!(unwritable_cmd.status().unwrap().success());
    Frame::new(
        b'D',
        1,
        &Frame::new(INPUT, 0, b"printf 'STILL_ALIVE_%s_ERR\\n' AFTER_SAVE\r").encode(),
    )
    .send(&mut client)
    .unwrap();
    while !output
        .windows(b"STILL_ALIVE_AFTER_SAVE_ERR".len())
        .any(|w| w == b"STILL_ALIVE_AFTER_SAVE_ERR")
    {
        let outer = Frame::read(&mut client).unwrap();
        if outer.kind == b'D' {
            let inner = Frame::read(&mut outer.data.as_slice()).unwrap();
            if inner.kind == OUTPUT {
                output.extend(inner.data);
            }
        }
    }
    fs::set_permissions(&sessions_dir, fs::Permissions::from_mode(0o700)).unwrap();

    // Cleanly close the session before `Daemon::drop` cleans up.
    let sock_hash: String = Sha256::digest(id.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let ctl_path = dir.join(format!("{}.ctl", &sock_hash[..16]));
    let close_deadline = Instant::now() + Duration::from_secs(6);
    loop {
        let mut ctrl = UnixStream::connect(&host_sock).unwrap();
        Frame::new(b'K', 1, id.as_bytes()).send(&mut ctrl).unwrap();
        let outer = Frame::read(&mut ctrl).unwrap();
        let inner = Frame::read(&mut outer.data.as_slice()).unwrap();
        if inner.data == b"closed" && !ctl_path.exists() {
            break;
        }
        assert!(Instant::now() < close_deadline);
        std::thread::sleep(Duration::from_millis(25));
    }
}

struct ExecRelayHarness {
    dir: std::path::PathBuf,
    relay_sock: std::path::PathBuf,
    host: Option<Child>,
    relay: Child,
}

impl ExecRelayHarness {
    fn stop_child(child: &mut Child) {
        if matches!(child.try_wait(), Ok(None)) {
            unsafe {
                libc::kill(child.id() as i32, libc::SIGTERM);
            }
            let deadline = Instant::now() + Duration::from_millis(400);
            while Instant::now() < deadline {
                if matches!(child.try_wait(), Ok(Some(_))) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(15));
            }
            let _ = child.kill();
        }
        let _ = child.wait();
    }
}

impl Drop for ExecRelayHarness {
    fn drop(&mut self) {
        Self::stop_child(&mut self.relay);
        if let Some(mut host) = self.host.take() {
            Self::stop_child(&mut host);
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn write_fake_ssh_bridge(
    dir: &std::path::Path,
    target_sock: &std::path::Path,
) -> std::path::PathBuf {
    let bin = env!("CARGO_BIN_EXE_omgd");
    let script = dir.join("fake-ssh.sh");
    let body = format!(
        "#!/bin/sh\nprintf R\nexec '{}' bridge '{}'\n",
        bin.replace('\'', "'\\''"),
        target_sock.to_string_lossy().replace('\'', "'\\''"),
    );
    fs::write(&script, body).unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
    script
}

fn write_ssh_connection_json(
    dir: &std::path::Path,
    ssh_script: &std::path::Path,
) -> std::path::PathBuf {
    let config = serde_json::json!({
        "auto_install": false,
        "transport": "ssh",
        "executable": ssh_script,
        "arguments": ["fake-host"],
        "cwd": dir,
        "bundle": dir,
        "policy": lifecycle::Policy::default(),
        "revision": "exec-test",
    });
    let config_path = dir.join("conn.json");
    fs::write(&config_path, serde_json::to_vec(&config).unwrap()).unwrap();
    fs::set_permissions(&config_path, fs::Permissions::from_mode(0o600)).unwrap();
    config_path
}

fn start_exec_relay_harness(with_real_host: bool) -> (ExecRelayHarness, std::path::PathBuf) {
    let bin = env!("CARGO_BIN_EXE_omgd");
    let dir = std::path::PathBuf::from("/tmp")
        .join(format!("omg-exec-e2e-{}", &record::nonce().unwrap()[..8]));
    let host_dir = dir.join("h");
    fs::create_dir_all(&host_dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(&host_dir, fs::Permissions::from_mode(0o700)).unwrap();

    let host_sock = host_dir.join("host.sock");
    let host = if with_real_host {
        let child = Command::new(bin)
            .args(["host", host_dir.to_str().unwrap(), "--", "/bin/sh"])
            .env("HOME", &dir)
            .env("SHELL", "/bin/sh")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(4);
        while Instant::now() < deadline {
            if host_sock.exists() && UnixStream::connect(&host_sock).is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(15));
        }
        assert!(host_sock.exists(), "host.sock did not become ready");
        Some(child)
    } else {
        None
    };

    let ssh_script = write_fake_ssh_bridge(&dir, &host_sock);
    let config_path = write_ssh_connection_json(&dir, &ssh_script);
    let relay_sock = dir.join("r.sock");
    let relay = Command::new(bin)
        .args([
            "connect",
            relay_sock.to_str().unwrap(),
            config_path.to_str().unwrap(),
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(4);
    while Instant::now() < deadline {
        if relay_sock.exists() && UnixStream::connect(&relay_sock).is_ok() {
            if with_real_host {
                let status = Command::new(bin)
                    .args(["list-local", relay_sock.to_str().unwrap()])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status()
                    .unwrap();
                if status.success() {
                    break;
                }
            } else {
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(15));
    }

    (
        ExecRelayHarness {
            dir,
            relay_sock,
            host,
            relay,
        },
        host_sock,
    )
}

#[test]
fn exec_local_end_to_end_binary_stdin_stdout_exit_codes_limits_and_cancellation() {
    use std::io::Write;
    let bin = env!("CARGO_BIN_EXE_omgd");
    let (harness, _) = start_exec_relay_harness(true);

    // 1) Binary NUL-containing stdout + large 256 KiB stdin round-trip.
    let mut payload = Vec::with_capacity(256 * 1024);
    for i in 0..(256 * 1024) {
        payload.push(match i % 5 {
            0 => 0u8,
            1 => 0xffu8,
            _ => (i & 0x7f) as u8,
        });
    }
    let mut child = Command::new(bin)
        .args([
            "exec-local",
            harness.relay_sock.to_str().unwrap(),
            "1048576",
            "cat",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let expected = payload.clone();
    let writer = std::thread::spawn(move || {
        stdin.write_all(&payload).unwrap();
    });
    let output = child.wait_with_output().unwrap();
    writer.join().unwrap();
    assert_eq!(output.status.code(), Some(0));
    assert_eq!(output.stdout, expected);
    assert!(output.stderr.is_empty());

    // 2) Fast remote exit does NOT hang even when local stdin pipe stays open without EOF.
    let mut fast_child = Command::new(bin)
        .args([
            "exec-local",
            harness.relay_sock.to_str().unwrap(),
            "65536",
            "printf 'fast-ok\\n'",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let _held_stdin = fast_child.stdin.take().unwrap();
    let started = Instant::now();
    let fast_out = fast_child.wait_with_output().unwrap();
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "exec-local hung waiting for open stdin"
    );
    assert_eq!(fast_out.status.code(), Some(0));
    assert_eq!(fast_out.stdout, b"fast-ok\n");

    // 3) Nonzero exit codes (including 252 and 253 without sentinels) & stderr preservation.
    for code in [17, 252, 253] {
        let out = Command::new(bin)
            .args([
                "exec-local",
                harness.relay_sock.to_str().unwrap(),
                "65536",
                &format!("printf 'out-{code}\\n'; printf 'err-{code}\\n' >&2; exit {code}"),
            ])
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(code));
        assert_eq!(out.stdout, format!("out-{code}\n").as_bytes());
        assert_eq!(out.stderr, format!("err-{code}\n").as_bytes());
    }

    // 4) max_output_bytes exceeded (both stdout-only and combined stdout+stderr) -> exit 252 + \x1eOMG-EXEC-LIMIT\x1f sentinel.
    for cmd in [
        "python3 -c 'import sys; sys.stdout.buffer.write(b\"x\" * 4096)'",
        "python3 -c 'import sys; sys.stdout.buffer.write(b\"a\" * 600); sys.stderr.buffer.write(b\"b\" * 600)'",
    ] {
        let limit_out = Command::new(bin)
            .args([
                "exec-local",
                harness.relay_sock.to_str().unwrap(),
                "1024",
                cmd,
            ])
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        assert_eq!(limit_out.status.code(), Some(252));
        let limit_stderr = String::from_utf8_lossy(&limit_out.stderr);
        assert!(
            limit_stderr.contains("\u{1e}OMG-EXEC-LIMIT\u{1f}"),
            "unexpected limit stderr: {limit_stderr:?}"
        );
    }

    // 4b) Early fd close (`exec 1>&- 2>&-`) still waits for real exit status, and SIGPIPE works in shell pipelines.
    let early_close = Command::new(bin)
        .args([
            "exec-local",
            harness.relay_sock.to_str().unwrap(),
            "4096",
            "exec 1>&- 2>&-; sleep 0.05; exit 9",
        ])
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert_eq!(early_close.status.code(), Some(9));

    let sigpipe_out = Command::new(bin)
        .args([
            "exec-local",
            harness.relay_sock.to_str().unwrap(),
            "4096",
            "yes hi | head -n 1",
        ])
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert_eq!(sigpipe_out.status.code(), Some(0));
    assert_eq!(sigpipe_out.stdout, b"hi\n");

    // 5) Client kill mid-exec kills remote process group cleanly (no orphan sleep).
    let pid_file = harness.dir.join("orphan-check.pid");
    let mut kill_child = Command::new(bin)
        .args([
            "exec-local",
            harness.relay_sock.to_str().unwrap(),
            "65536",
            &format!("sleep 30 & echo $! > '{}'; wait", pid_file.display()),
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    let remote_pid = loop {
        if let Ok(text) = fs::read_to_string(&pid_file) {
            if let Ok(pid) = text.trim().parse::<libc::pid_t>() {
                break pid;
            }
        }
        assert!(Instant::now() < deadline, "remote child did not record pid");
        std::thread::sleep(Duration::from_millis(15));
    };
    kill_child.kill().unwrap();
    let _ = kill_child.wait();
    let kill_deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < kill_deadline {
        if unsafe { libc::kill(remote_pid, 0) } != 0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(15));
    }
    assert_ne!(
        unsafe { libc::kill(remote_pid, 0) },
        0,
        "remote grandchild {remote_pid} survived client kill"
    );
}

#[test]
fn exec_local_handles_offline_socket_legacy_remote_without_exec_and_mid_exec_drop() {
    use std::os::unix::net::UnixListener;
    let bin = env!("CARGO_BIN_EXE_omgd");

    // 1) Offline / missing relay socket -> exit 253 + OMG-EXEC-UNSUPPORTED.
    let missing_sock = std::path::PathBuf::from("/tmp").join(format!(
        "omg-missing-exec-{}.sock",
        &record::nonce().unwrap()[..8]
    ));
    let offline_out = Command::new(bin)
        .args([
            "exec-local",
            missing_sock.to_str().unwrap(),
            "4096",
            "echo hi",
        ])
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert_eq!(offline_out.status.code(), Some(253));
    let offline_err = String::from_utf8_lossy(&offline_out.stderr);
    assert!(
        offline_err.starts_with("\u{1e}OMG-EXEC-UNSUPPORTED\u{1f}\n"),
        "unexpected offline stderr: {offline_err:?}"
    );

    // 2) Remote host advertising capabilities WITHOUT exec/1 -> exit 253 + OMG-EXEC-UNSUPPORTED.
    let (harness, legacy_host_sock) = start_exec_relay_harness(false);
    let listener = UnixListener::bind(&legacy_host_sock).unwrap();
    let stop_legacy = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stop_legacy_srv = stop_legacy.clone();
    let legacy_srv = std::thread::spawn(move || {
        listener.set_nonblocking(true).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut conn = loop {
            match listener.accept() {
                Ok((s, _)) => break s,
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(_) => return,
            }
        };
        conn.set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        let caps =
            b"durable-close/1,strict-open/1,inline-viewer/1,agent-state/1,recreate-if-gone/1";
        let _ = Frame::new(b'P', 0, caps).send(&mut conn);
        while !stop_legacy_srv.load(std::sync::atomic::Ordering::SeqCst) {
            match Frame::read(&mut conn) {
                Ok(f) if f.kind == b'P' => {
                    let _ = Frame::new(b'P', 0, caps).send(&mut conn);
                }
                Ok(f) if f.kind == b'L' => {
                    let _ = Frame::new(b'L', 0, b"[]").send(&mut conn);
                }
                Ok(_) => {}
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(_) => break,
            }
        }
    });

    // Wait until relay is online with legacy capabilities (list-local succeeds).
    let list_deadline = Instant::now() + Duration::from_secs(4);
    while Instant::now() < list_deadline {
        if Command::new(bin)
            .args(["list-local", harness.relay_sock.to_str().unwrap()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success()
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    let legacy_out = Command::new(bin)
        .args([
            "exec-local",
            harness.relay_sock.to_str().unwrap(),
            "4096",
            "echo hi",
        ])
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert_eq!(legacy_out.status.code(), Some(253));
    let legacy_err = String::from_utf8_lossy(&legacy_out.stderr);
    assert!(
        legacy_err.starts_with("\u{1e}OMG-EXEC-UNSUPPORTED\u{1f}\n"),
        "unexpected legacy stderr: {legacy_err:?}"
    );
    stop_legacy.store(true, std::sync::atomic::Ordering::SeqCst);
    let _ = legacy_srv.join();
    drop(harness);

    // 3) Tunnel drop mid-exec -> exit 255 + OMG-EXEC-TRANSPORT.
    let (mut drop_harness, _) = start_exec_relay_harness(true);
    let started_flag = drop_harness.dir.join("started");
    let drop_child = Command::new(bin)
        .args([
            "exec-local",
            drop_harness.relay_sock.to_str().unwrap(),
            "4096",
            &format!("touch '{}'; sleep 30", started_flag.display()),
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let start_deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < start_deadline && !started_flag.exists() {
        std::thread::sleep(Duration::from_millis(15));
    }
    assert!(started_flag.exists());
    if let Some(mut host) = drop_harness.host.take() {
        ExecRelayHarness::stop_child(&mut host);
    }
    let drop_out = drop_child.wait_with_output().unwrap();
    assert_eq!(drop_out.status.code(), Some(255));
    let drop_err = String::from_utf8_lossy(&drop_out.stderr);
    assert!(
        drop_err.starts_with("\u{1e}OMG-EXEC-TRANSPORT\u{1f}\n"),
        "unexpected drop stderr: {drop_err:?}"
    );
}
