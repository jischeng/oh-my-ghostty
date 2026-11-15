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
    let _ = daemon;
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
    let _ = daemon;
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
