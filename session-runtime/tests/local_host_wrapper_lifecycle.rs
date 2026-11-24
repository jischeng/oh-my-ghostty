#![cfg(target_os = "macos")]

use omg_session_runtime::{
    host,
    lifecycle::Policy,
    location,
    record::{nonce, SessionSummary},
    registry::{LocalLaunchSpec, OpenRequest},
    Frame, INPUT, OUTPUT, SNAPSHOT,
};
use std::{
    collections::BTreeMap,
    fs,
    io::{self, Write},
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

fn omgd_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_omgd"))
}

fn private_dir(path: &Path) {
    fs::create_dir_all(path).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

struct TestCleanup {
    dirs: Vec<PathBuf>,
    pids: Vec<u32>,
    children: Vec<Child>,
}

impl TestCleanup {
    fn new(root: PathBuf) -> Self {
        Self {
            dirs: vec![root],
            pids: Vec::new(),
            children: Vec::new(),
        }
    }

    fn track_pid(&mut self, pid: u32) {
        if pid > 1 && !self.pids.contains(&pid) {
            self.pids.push(pid);
        }
    }

    fn track_child(&mut self, child: Child) {
        self.children.push(child);
    }
}

impl Drop for TestCleanup {
    fn drop(&mut self) {
        for child in &mut self.children {
            let _ = child.kill();
            let _ = child.wait();
        }
        for &pid in self.pids.iter().rev() {
            unsafe {
                libc::kill(pid as libc::pid_t, libc::SIGTERM);
            }
        }
        let deadline = Instant::now() + Duration::from_millis(600);
        while Instant::now() < deadline
            && self
                .pids
                .iter()
                .any(|&pid| unsafe { libc::kill(pid as libc::pid_t, 0) == 0 })
        {
            std::thread::sleep(Duration::from_millis(20));
        }
        for &pid in self.pids.iter().rev() {
            if unsafe { libc::kill(pid as libc::pid_t, 0) == 0 } {
                unsafe {
                    libc::kill(pid as libc::pid_t, libc::SIGKILL);
                }
            }
        }
        for dir in &self.dirs {
            let _ = fs::remove_dir_all(dir);
        }
    }
}

/// Compile a tiny native Mach-O wrapper executable implementing the exact
/// `+internal-runtime-host READY -- COMMAND...` contract of `SessionRuntimeHostLauncher.swift`
/// so XNU's `p_textvp`, `proc_pidpath`, VFS `rename`, `unlink`, and `(st_dev, st_ino)` behave
/// identically to `/Applications/OMG.app/Contents/MacOS/omg`.
fn compile_mock_wrapper_macho(out_exe: &Path, build_tag: &str) {
    let parent = out_exe.parent().unwrap();
    fs::create_dir_all(parent).unwrap();
    let src_path = parent.join(format!("wrapper_{build_tag}.c"));
    let c_source = format!(
        r#"#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <libproc.h>

extern char **environ;
const char *BUILD_TAG = "{build_tag}";

static void bootout_job(const char *label) {{
    if (!label || !*label) return;
    char target[512];
    snprintf(target, sizeof(target), "gui/%u/%s", (unsigned)getuid(), label);
    posix_spawn_file_actions_t fa;
    if (posix_spawn_file_actions_init(&fa) != 0) return;
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    char *argv[] = {{ "/bin/launchctl", "bootout", target, NULL }};
    pid_t pid = 0;
    if (posix_spawn(&pid, "/bin/launchctl", &fa, NULL, argv, environ) == 0) {{
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {{}}
    }}
    posix_spawn_file_actions_destroy(&fa);
}}

int main(int argc, char **argv) {{
    (void)BUILD_TAG;
    if (argc < 5 || strcmp(argv[1], "+internal-runtime-host") != 0 || strcmp(argv[3], "--") != 0) {{
        return 2;
    }}
    const char *ready_path = argv[2];
    const char *label_env = getenv("OMG_RUNTIME_HOST_LABEL");
    char saved_label[256] = {{0}};
    if (label_env) {{
        snprintf(saved_label, sizeof(saved_label), "%s", label_env);
    }}
    unsetenv("OMG_RUNTIME_HOST_LABEL");
    unsetenv("OMG_HOST_APP_BUNDLE");
    unsetenv("OMG_HOST_APP_BUNDLE_ID");

    char self_path[PROC_PIDPATHINFO_MAXSIZE] = {{0}};
    if (proc_pidpath(getpid(), self_path, sizeof(self_path)) > 0) {{
        struct stat st;
        if (stat(self_path, &st) == 0) {{
            char id_buf[128];
            snprintf(id_buf, sizeof(id_buf), "%d:%llu:%llu",
                     (int)getpid(),
                     (unsigned long long)st.st_dev,
                     (unsigned long long)st.st_ino);
            setenv("OMG_WRAPPER_IDENTITY", id_buf, 1);
            setenv("OMG_WRAPPER_EXECUTABLE", self_path, 1);
        }}
    }}

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) return 1;
    sigset_t empty_mask, def_sigs;
    sigemptyset(&empty_mask);
    posix_spawnattr_setsigmask(&attr, &empty_mask);
    sigemptyset(&def_sigs);
    sigaddset(&def_sigs, SIGTERM);
    sigaddset(&def_sigs, SIGINT);
    sigaddset(&def_sigs, SIGHUP);
    posix_spawnattr_setsigdefault(&attr, &def_sigs);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSID);
    signal(SIGHUP, SIG_IGN);

    pid_t child = 0;
    int rc = posix_spawnp(&child, argv[4], NULL, &attr, &argv[4], environ);
    posix_spawnattr_destroy(&attr);
    unsetenv("OMG_WRAPPER_IDENTITY");
    unsetenv("OMG_WRAPPER_EXECUTABLE");
    if (rc != 0) return 1;

    char tmp_path[1024];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", ready_path);
    int fd = open(tmp_path, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) {{
        kill(child, SIGTERM);
        return 1;
    }}
    char pid_str[64];
    int n = snprintf(pid_str, sizeof(pid_str), "%d", (int)child);
    if (write(fd, pid_str, (size_t)n) != n) {{
        close(fd);
        unlink(tmp_path);
        kill(child, SIGTERM);
        return 1;
    }}
    close(fd);
    if (rename(tmp_path, ready_path) != 0) {{
        unlink(tmp_path);
        kill(child, SIGTERM);
        return 1;
    }}

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {{
        if (errno != EINTR) break;
    }}
    if (saved_label[0]) {{
        bootout_job(saved_label);
    }}
    return 0;
}}
"#
    );
    fs::write(&src_path, c_source).unwrap();
    let cc = std::env::var("OMG_RUNTIME_CC").unwrap_or_else(|_| "/usr/bin/cc".into());
    let status = Command::new(cc)
        .args(["-O2", "-Wall", "-Werror", "-o"])
        .arg(out_exe)
        .arg(&src_path)
        .status()
        .expect("invoke C compiler for mock wrapper");
    assert!(status.success(), "failed compiling mock Mach-O wrapper");
    let _ = fs::remove_file(&src_path);
    fs::set_permissions(out_exe, fs::Permissions::from_mode(0o755)).unwrap();
}

fn create_mock_app_bundle(
    app_dir: &Path,
    bundle_id: &str,
    revision: &str,
    snapshot_revision: &str,
    build_tag: &str,
) -> (PathBuf, PathBuf) {
    let contents = app_dir.join("Contents");
    let macos = contents.join("MacOS");
    let runtime_dir = contents.join("Resources/session-runtime");
    fs::create_dir_all(&macos).unwrap();
    fs::create_dir_all(&runtime_dir).unwrap();
    fs::write(
        contents.join("Info.plist"),
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key>
    <string>{bundle_id}</string>
    <key>CFBundleExecutable</key>
    <string>omg</string>
</dict></plist>
"#
        ),
    )
    .unwrap();
    let wrapper_exe = macos.join("omg");
    compile_mock_wrapper_macho(&wrapper_exe, build_tag);

    let bundled_omgd = runtime_dir.join("omgd");
    fs::copy(omgd_bin(), &bundled_omgd).unwrap();
    fs::set_permissions(&bundled_omgd, fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(runtime_dir.join("revision"), format!("{revision}\n")).unwrap();
    fs::write(runtime_dir.join("verified"), format!("{revision}\n")).unwrap();
    fs::write(
        runtime_dir.join("snapshot-revision"),
        format!("{snapshot_revision}\n"),
    )
    .unwrap();
    (wrapper_exe, bundled_omgd)
}

fn install_version(versions_root: &Path, revision: &str, snapshot_revision: &str) -> PathBuf {
    let dir = versions_root.join(revision);
    private_dir(&dir);
    let target = dir.join("omgd");
    fs::copy(omgd_bin(), &target).unwrap();
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

fn pid_alive(pid: u32) -> bool {
    if pid <= 1 {
        return false;
    }
    location::process_bsdinfo(pid as i32).is_some_and(|info| !info.zombie)
}

fn wait_pid_dead(pid: u32, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if !pid_alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    !pid_alive(pid)
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

fn local_launch_spec(cwd: &Path, initial_input: Option<&[u8]>) -> LocalLaunchSpec {
    let mut env = BTreeMap::new();
    env.insert(
        "HOME".into(),
        std::env::var("HOME").unwrap_or_else(|_| cwd.to_string_lossy().into_owned()),
    );
    env.insert(
        "PATH".into(),
        std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin:/usr/sbin:/sbin".into()),
    );
    env.insert("TERM".into(), "xterm-256color".into());
    LocalLaunchSpec {
        argv: vec!["/bin/sh".into(), "-i".into()],
        env,
        cwd: Some(cwd.to_string_lossy().into_owned()),
        cols: 80,
        rows: 24,
        pixel_width: 640,
        pixel_height: 384,
        scrollback_max_bytes: None,
        scrollback_max_lines: None,
        input_base64: initial_input.map(|bytes| {
            use base64::Engine;
            base64::engine::general_purpose::STANDARD.encode(bytes)
        }),
    }
}

fn open_local_session_direct(
    host_sock: &Path,
    id: &str,
    create: bool,
    cwd: &Path,
) -> io::Result<(UnixStream, omg_session_runtime::Vt)> {
    let mut stream = UnixStream::connect(host_sock)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let req = OpenRequest {
        id: id.to_owned(),
        policy: Policy {
            terminate_grace_seconds: 1,
            ..Policy::default()
        },
        create,
        launch: create.then(|| local_launch_spec(cwd, None)),
        ..Default::default()
    };
    Frame::new(b'C', 1, &serde_json::to_vec(&req)?).send(&mut stream)?;
    let mut vt = omg_session_runtime::Vt::new(80, 24)?;
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

fn send_direct_input(stream: &mut UnixStream, bytes: &[u8]) -> io::Result<()> {
    let inner = Frame::new(INPUT, 0, bytes).encode();
    Frame::new(b'D', 1, &inner).send(stream)
}

fn read_direct_until(
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

#[test]
fn sparkle_rename_unlink_and_rm_rf_ditto_and_trash_guard_preserve_holders_and_heal_wrapper() {
    let tag = &nonce().unwrap()[..8];
    let raw_base = PathBuf::from(format!("/tmp/omg-lh-wrap-{tag}"));
    private_dir(&raw_base);
    let base = fs::canonicalize(&raw_base).unwrap();
    let mut cleanup = TestCleanup::new(base.clone());

    let support = base.join("Application Support/OMG Test");
    let state_dir = base.join("run/local-channel");
    let sparkle_cache = base.join("Caches/org.sparkle-project.Sparkle/Installation");
    let app_path = base.join("OMG Test.app");
    let staging_v2 = base.join("staged-v2/OMG Test.app");
    private_dir(&support);
    private_dir(&state_dir);
    fs::create_dir_all(&sparkle_cache).unwrap();

    let bundle_id = format!("com.jischeng.omg.test.{tag}");
    let snap = "59c5cc7b4d1fe408faf5";

    let (wrapper_v1, omgd_v1) =
        create_mock_app_bundle(&app_path, &bundle_id, "rev-v1", snap, "v1_build");
    let v1_dev_ino = location::file_dev_ino(&wrapper_v1).unwrap();

    // 1. Start v1 local host through `ensure-host --local` (uses launchd + `+internal-runtime-host`).
    let out1 = Command::new(&omgd_v1)
        .args(["ensure-host", "--local"])
        .arg(&state_dir)
        .env("OMG_HOST_APP_BUNDLE", &app_path)
        .env("OMG_HOST_APP_BUNDLE_ID", &bundle_id)
        .env("OMG_APP_SUPPORT", &support)
        .env("SHELL", "/bin/sh")
        .output()
        .unwrap();
    assert!(
        out1.status.success(),
        "v1 ensure-host --local failed: {}",
        String::from_utf8_lossy(&out1.stderr)
    );

    let host_sock = state_dir.join("host.sock");
    let id_v1 = host::query_host_identity(&host_sock).unwrap();
    cleanup.track_pid(id_v1.pid);
    if let Some(wpid) = id_v1.wrapper_pid {
        cleanup.track_pid(wpid);
    }
    assert_eq!(id_v1.mode, "local");
    assert_eq!(id_v1.revision, "rev-v1");
    assert_eq!(id_v1.wrapper_mode.as_deref(), Some("app-bundle"));
    let wpid_v1 = id_v1.wrapper_pid.expect("v1 wrapper_pid");
    assert_eq!(
        id_v1.wrapper_executable.as_deref(),
        Some(wrapper_v1.to_str().unwrap())
    );
    assert_eq!(
        (id_v1.wrapper_dev, id_v1.wrapper_ino),
        (Some(v1_dev_ino.0), Some(v1_dev_ino.1))
    );
    assert!(host::is_local_wrapper_healthy(&id_v1, true));
    // Verify `omgd` was staged into `<support>/session-runtime/versions/rev-v1/omgd`!
    assert!(support
        .join("session-runtime/versions/rev-v1/omgd")
        .is_file());

    // Open session S1 under v1 and persist an environment variable in its shell.
    let s1_id = "11111111-1111-4111-8111-aaaaaaaaaaaa";
    let (mut s1_stream, mut s1_vt) =
        open_local_session_direct(&host_sock, s1_id, true, &base).unwrap();
    send_direct_input(
        &mut s1_stream,
        b"OMG_SURVIVED_SPARKLE=YES_42; export OMG_SURVIVED_SPARKLE; echo S1_READY_V1\n",
    )
    .unwrap();
    read_direct_until(
        &mut s1_stream,
        &mut s1_vt,
        "S1_READY_V1",
        Duration::from_secs(5),
    )
    .unwrap();
    drop(s1_stream);

    let s1_before = host_list(&host_sock)
        .unwrap()
        .into_iter()
        .find(|s| s.id == s1_id)
        .unwrap();
    let s1_shell_pid = s1_before.pid.expect("s1 shell pid");
    cleanup.track_pid(s1_shell_pid);

    // 2. Simulate Sparkle update:
    //    Step 2a: Prepare v2 bundle, move v1 to Sparkle cache (`willInstallUpdateOnQuit` window),
    //             move v2 into place at `app_path`.
    create_mock_app_bundle(
        &staging_v2,
        &bundle_id,
        "rev-v2",
        snap,
        "v2_build_new_macho",
    );
    let moved_v1_app = sparkle_cache.join("OMG Test.app");
    fs::rename(&app_path, &moved_v1_app).unwrap();
    fs::rename(&staging_v2, &app_path).unwrap();

    // Even BEFORE Sparkle deletes its cache dir, `is_local_wrapper_healthy` MUST be false!
    assert!(
        !host::is_local_wrapper_healthy(&id_v1, true),
        "wrapper moved into Sparkle cache must immediately report unhealthy"
    );

    // Step 2b: Delete Sparkle staging cache (exact live PID 1743 state: ENOENT on proc_pidpath).
    fs::remove_dir_all(&moved_v1_app).unwrap();
    assert_eq!(
        location::process_path(wpid_v1 as i32),
        None,
        "unlinked Mach-O wrapper must yield ENOENT (None) from proc_pidpath"
    );
    assert!(!host::is_local_wrapper_healthy(&id_v1, true));

    // 3. Run v2 `ensure-host --local`: must step down v1 host + v1 wrapper, start v2 host + v2 wrapper,
    //    and adopt surviving S1 without dropping its PTY!
    let omgd_v2 = app_path.join("Contents/Resources/session-runtime/omgd");
    let wrapper_v2 = app_path.join("Contents/MacOS/omg");
    let v2_dev_ino = location::file_dev_ino(&wrapper_v2).unwrap();
    assert_ne!(v2_dev_ino, v1_dev_ino);

    let out2 = Command::new(&omgd_v2)
        .args(["ensure-host", "--local"])
        .arg(&state_dir)
        .env("OMG_HOST_APP_BUNDLE", &app_path)
        .env("OMG_HOST_APP_BUNDLE_ID", &bundle_id)
        .env("OMG_APP_SUPPORT", &support)
        .env("SHELL", "/bin/sh")
        .output()
        .unwrap();
    assert!(
        out2.status.success(),
        "v2 ensure-host --local failed: {}",
        String::from_utf8_lossy(&out2.stderr)
    );

    assert!(
        wait_pid_dead(id_v1.pid, Duration::from_secs(5)),
        "old v1 host-local must exit"
    );
    assert!(
        wait_pid_dead(wpid_v1, Duration::from_secs(5)),
        "old v1 +internal-runtime-host wrapper must reap child, bootout, and exit"
    );

    let id_v2 = host::query_host_identity(&host_sock).unwrap();
    cleanup.track_pid(id_v2.pid);
    let wpid_v2 = id_v2.wrapper_pid.expect("v2 wrapper_pid");
    cleanup.track_pid(wpid_v2);
    assert_eq!(id_v2.revision, "rev-v2");
    assert_ne!(id_v2.pid, id_v1.pid);
    assert_ne!(wpid_v2, wpid_v1);
    assert_eq!(
        (id_v2.wrapper_dev, id_v2.wrapper_ino),
        (Some(v2_dev_ino.0), Some(v2_dev_ino.1))
    );
    assert!(host::is_local_wrapper_healthy(&id_v2, true));

    // Verify S1 survived with the exact same shell PID and environment!
    assert!(pid_alive(s1_shell_pid));
    let (mut s1_re, mut s1_vt2) =
        open_local_session_direct(&host_sock, s1_id, false, &base).unwrap();
    send_direct_input(&mut s1_re, b"echo CHECK=$OMG_SURVIVED_SPARKLE\n").unwrap();
    read_direct_until(
        &mut s1_re,
        &mut s1_vt2,
        "CHECK=YES_42",
        Duration::from_secs(5),
    )
    .unwrap();
    drop(s1_re);

    // Verify a brand-new tab S2 opened after upgrade runs under v2!
    let s2_id = "22222222-2222-4222-8222-bbbbbbbbbbbb";
    let (mut s2_stream, mut s2_vt) =
        open_local_session_direct(&host_sock, s2_id, true, &base).unwrap();
    send_direct_input(&mut s2_stream, b"echo NEW_TAB_UNDER_V2_OK\n").unwrap();
    read_direct_until(
        &mut s2_stream,
        &mut s2_vt,
        "NEW_TAB_UNDER_V2_OK",
        Duration::from_secs(5),
    )
    .unwrap();
    drop(s2_stream);
    let s2_pid = host_list(&host_sock)
        .unwrap()
        .into_iter()
        .find(|s| s.id == s2_id)
        .and_then(|s| s.pid)
        .expect("s2 pid");
    cleanup.track_pid(s2_pid);

    // 4. Simulate `install-dev.sh` (`rm -rf` + fresh copy) WITH IDENTICAL `omgd` REVISION (`rev-v2`):
    //    `proc_pidpath(wpid_v2)` still caches `OMG Test.app/Contents/MacOS/omg`, so ONLY `(st_dev, st_ino)` catches this!
    let rebuild_staging = base.join("staged-v2-swift-only/OMG Test.app");
    create_mock_app_bundle(
        &rebuild_staging,
        &bundle_id,
        "rev-v2",
        snap,
        "v2_swift_only_rebuild_new_inode",
    );
    fs::remove_dir_all(&app_path).unwrap();
    // Copy into place (`rm -rf` + `ditto` equivalent).
    let ditto_status = Command::new("/usr/bin/ditto")
        .arg(&rebuild_staging)
        .arg(&app_path)
        .status()
        .unwrap();
    assert!(ditto_status.success());
    let _ = fs::remove_dir_all(&rebuild_staging);

    let rebuilt_dev_ino = location::file_dev_ino(&wrapper_v2).unwrap();
    assert_ne!(rebuilt_dev_ino, v2_dev_ino);
    assert!(
        !host::is_local_wrapper_healthy(&id_v2, true),
        "(st_dev, st_ino) check must detect rm -rf + ditto even with identical omgd revision"
    );

    let out3 = Command::new(&omgd_v2)
        .args(["ensure-host", "--local"])
        .arg(&state_dir)
        .env("OMG_HOST_APP_BUNDLE", &app_path)
        .env("OMG_HOST_APP_BUNDLE_ID", &bundle_id)
        .env("OMG_APP_SUPPORT", &support)
        .env("SHELL", "/bin/sh")
        .output()
        .unwrap();
    assert!(out3.status.success());
    assert!(wait_pid_dead(id_v2.pid, Duration::from_secs(5)));
    assert!(wait_pid_dead(wpid_v2, Duration::from_secs(5)));

    let id_v3 = host::query_host_identity(&host_sock).unwrap();
    cleanup.track_pid(id_v3.pid);
    let wpid_v3 = id_v3.wrapper_pid.expect("v3 wrapper_pid");
    cleanup.track_pid(wpid_v3);
    assert_eq!(id_v3.revision, "rev-v2");
    assert_ne!(id_v3.pid, id_v2.pid);
    assert_ne!(wpid_v3, wpid_v2);
    assert_eq!(
        (id_v3.wrapper_dev, id_v3.wrapper_ino),
        (Some(rebuilt_dev_ino.0), Some(rebuilt_dev_ino.1))
    );
    assert!(host::is_local_wrapper_healthy(&id_v3, true));
    assert!(pid_alive(s1_shell_pid));
    assert!(pid_alive(s2_pid));

    // 5. Trap 4 Guard: Drag `.app` to Trash (no replacement bundle on disk).
    //    `ensure-host --local` with same revision MUST NOT kill/restart `id_v3` in a loop!
    let staged_omgd_v2 = support.join("session-runtime/versions/rev-v2/omgd");
    fs::remove_dir_all(&app_path).unwrap();
    let out_trashed = Command::new(&staged_omgd_v2)
        .args(["ensure-host", "--local"])
        .arg(&state_dir)
        .env("OMG_HOST_APP_BUNDLE", &app_path)
        .env("OMG_HOST_APP_BUNDLE_ID", &bundle_id)
        .env("OMG_APP_SUPPORT", &support)
        .env("SHELL", "/bin/sh")
        .output()
        .unwrap();
    assert!(out_trashed.status.success());
    let id_after_trash = host::query_host_identity(&host_sock).unwrap();
    assert_eq!(
        id_after_trash.pid, id_v3.pid,
        "missing .app on disk must not trigger a fruitless stepdown loop"
    );

    host_close_until_done(&host_sock, s1_id, Duration::from_secs(10)).unwrap();
    host_close_until_done(&host_sock, s2_id, Duration::from_secs(10)).unwrap();
}

#[test]
fn legacy_v0_22_1_and_v0_23_2_local_hosts_step_down_via_verified_sigterm_preserving_holders() {
    for legacy_mode in ["v0_22_1", "v0_23_2"] {
        let tag = &nonce().unwrap()[..8];
        let raw_base = PathBuf::from(format!("/tmp/omg-leg-loc-{legacy_mode}-{tag}"));
        private_dir(&raw_base);
        let base = fs::canonicalize(&raw_base).unwrap();
        let mut cleanup = TestCleanup::new(base.clone());

        let support = base.join("Application Support/OMG Legacy");
        let versions = support.join("session-runtime/versions");
        let state_dir = base.join("run/legacy-channel");
        private_dir(&support);
        private_dir(&versions);
        private_dir(&state_dir);

        let snap = "59c5cc7b4d1fe408faf5";
        let bin_old = install_version(&versions, "rev-legacy", snap);
        let bin_new = install_version(&versions, "rev-fixed", snap);

        // Spawn legacy `host-local` directly with `OMG_TEST_LEGACY_HOST_MODE`.
        let legacy_child = Command::new(&bin_old)
            .args(["host-local"])
            .arg(&state_dir)
            .args(["--", "/bin/sh", "-i"])
            .env("OMG_TEST_LEGACY_HOST_MODE", legacy_mode)
            .env("OMG_APP_SUPPORT", &support)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let legacy_pid = legacy_child.id();
        cleanup.track_child(legacy_child);

        let host_sock = state_dir.join("host.sock");
        let wait_sock = Instant::now() + Duration::from_secs(5);
        while UnixStream::connect(&host_sock).is_err() && Instant::now() < wait_sock {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(UnixStream::connect(&host_sock).is_ok());

        // Confirm wire behavior matches the simulated historical release!
        if legacy_mode == "v0_22_1" {
            assert!(host::query_host_identity(&host_sock).is_err());
        } else {
            let id = host::query_host_identity(&host_sock).unwrap();
            assert_eq!(id.wrapper_mode, None);
            assert!(host::request_host_takeover(&host_sock, "rev-fixed", Some(snap)).is_err());
        }

        // Open a persistent local session under the legacy host.
        let sid = "33333333-3333-4333-8333-cccccccccccc";
        let (mut s_old, mut vt_old) =
            open_local_session_direct(&host_sock, sid, true, &base).unwrap();
        send_direct_input(
            &mut s_old,
            b"LEGACY_KEEP=ALIVE_777; export LEGACY_KEEP; echo LEGACY_READY\n",
        )
        .unwrap();
        read_direct_until(
            &mut s_old,
            &mut vt_old,
            "LEGACY_READY",
            Duration::from_secs(5),
        )
        .unwrap();
        drop(s_old);

        let shell_pid = host_list(&host_sock)
            .unwrap()
            .into_iter()
            .find(|s| s.id == sid)
            .and_then(|s| s.pid)
            .expect("legacy shell pid");
        cleanup.track_pid(shell_pid);

        // Run fixed `ensure-host --local --force-takeover`: must verify `host.lock` + `omgd host-local`,
        // SIGTERM only `legacy_pid`, boot `rev-fixed`, and adopt `sid` seamlessly!
        let out = Command::new(&bin_new)
            .args(["ensure-host", "--local", "--force-takeover"])
            .arg(&state_dir)
            .env("OMG_APP_SUPPORT", &support)
            .env("SHELL", "/bin/sh")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "legacy {legacy_mode} takeover failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );

        let id_new = host::query_host_identity(&host_sock).unwrap();
        cleanup.track_pid(id_new.pid);
        assert_eq!(id_new.revision, "rev-fixed");
        assert_ne!(id_new.pid, legacy_pid);
        assert!(pid_alive(shell_pid));

        let (mut s_new, mut vt_new) =
            open_local_session_direct(&host_sock, sid, false, &base).unwrap();
        send_direct_input(&mut s_new, b"echo AFTER_LEG=$LEGACY_KEEP\n").unwrap();
        read_direct_until(
            &mut s_new,
            &mut vt_new,
            "AFTER_LEG=ALIVE_777",
            Duration::from_secs(5),
        )
        .unwrap();
        drop(s_new);

        host_close_until_done(&host_sock, sid, Duration::from_secs(10)).unwrap();
    }
}

#[test]
fn connected_relay_transparently_rotates_when_host_local_self_steps_down_on_replaced_wrapper() {
    let tag = &nonce().unwrap()[..8];
    let raw_base = PathBuf::from(format!("/tmp/omg-relay-rot-{tag}"));
    private_dir(&raw_base);
    let base = fs::canonicalize(&raw_base).unwrap();
    let mut cleanup = TestCleanup::new(base.clone());

    let support = base.join("Application Support/OMG Relay");
    let state_dir = base.join("run/relay-channel");
    let app_path = base.join("OMG Relay.app");
    let staging_v2 = base.join("staged-v2/OMG Relay.app");
    private_dir(&support);
    private_dir(&state_dir);

    let bundle_id = format!("com.jischeng.omg.test.relay.{tag}");
    let snap = "59c5cc7b4d1fe408faf5";
    let (_, omgd_v1) = create_mock_app_bundle(&app_path, &bundle_id, "rev-r1", snap, "r1_build");
    let staged_r1 = install_version(&support.join("session-runtime/versions"), "rev-r1", snap);

    // Start persistent `omgd connect` relay (same architecture as `SessionRuntimeConnections.prepare`).
    let relay_sock = base.join("relay.sock");
    let relay_cfg = base.join("relay.json");
    let cfg_json = serde_json::json!({
        "transport": "local",
        "executable": "/usr/bin/ssh",
        "arguments": [],
        "cwd": base,
        "local_shell": "/bin/sh",
        "bundle": staged_r1.parent().unwrap(),
        "policy": Policy::default(),
        "revision": "rev-r1",
        "local_state_directory": state_dir,
    });
    fs::write(&relay_cfg, serde_json::to_vec(&cfg_json).unwrap()).unwrap();

    let relay_child = Command::new(&omgd_v1)
        .args(["connect"])
        .arg(&relay_sock)
        .arg(&relay_cfg)
        .env("OMG_HOST_APP_BUNDLE", &app_path)
        .env("OMG_HOST_APP_BUNDLE_ID", &bundle_id)
        .env("OMG_APP_SUPPORT", &support)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    cleanup.track_child(relay_child);

    let wait_relay = Instant::now() + Duration::from_secs(5);
    while UnixStream::connect(&relay_sock).is_err() && Instant::now() < wait_relay {
        std::thread::sleep(Duration::from_millis(20));
    }

    // Open Tab 1 through the relay so `omgd connect` is actively connected to `host-local`.
    let tab1_id = "44444444-4444-4444-8444-dddddddddddd";
    let mut peer1 = UnixStream::connect(&relay_sock).unwrap();
    peer1
        .set_read_timeout(Some(Duration::from_secs(8)))
        .unwrap();
    let open1 = OpenRequest {
        id: tab1_id.into(),
        policy: Policy::default(),
        create: true,
        launch: Some(local_launch_spec(&base, None)),
        ..Default::default()
    };
    Frame::new(b'H', 0, &serde_json::to_vec(&open1).unwrap())
        .send(&mut peer1)
        .unwrap();
    loop {
        let f = Frame::read(&mut peer1).unwrap();
        assert_ne!(f.kind, b'E', "tab1 open failed");
        if f.kind == SNAPSHOT {
            break;
        }
    }

    let host_sock = state_dir.join("host.sock");
    let id_before = host::query_host_identity(&host_sock).unwrap();
    let wpid_before = id_before.wrapper_pid.expect("initial wrapper pid");
    cleanup.track_pid(id_before.pid);
    cleanup.track_pid(wpid_before);

    // Now silently replace `OMG Relay.app` on disk WHILE `omgd connect` stays connected
    // (exact Sparkle `willInstallUpdateOnQuit` condition — Trap 3!).
    create_mock_app_bundle(&staging_v2, &bundle_id, "rev-r1", snap, "r2_silent_swap");
    let moved_cache = base.join("Caches/org.sparkle-project.Sparkle/Installation/OMG Relay.app");
    fs::create_dir_all(moved_cache.parent().unwrap()).unwrap();
    fs::rename(&app_path, &moved_cache).unwrap();
    fs::rename(&staging_v2, &app_path).unwrap();
    fs::remove_dir_all(&moved_cache).unwrap();

    // Immediately open Tab 2 (`create = true` + one-time `input_base64` marker) over the ALREADY-CONNECTED relay!
    let marker = base.join("tab2_post_swap_marker.txt");
    let tab2_id = "55555555-5555-4555-8555-eeeeeeeeeeee";
    let mut peer2 = UnixStream::connect(&relay_sock).unwrap();
    peer2
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let startup_cmd = format!("printf 'TAB2_OK\\n' > '{}'\n", marker.display());
    let open2 = OpenRequest {
        id: tab2_id.into(),
        policy: Policy::default(),
        create: true,
        launch: Some(local_launch_spec(&base, Some(startup_cmd.as_bytes()))),
        ..Default::default()
    };
    Frame::new(b'H', 0, &serde_json::to_vec(&open2).unwrap())
        .send(&mut peer2)
        .unwrap();
    loop {
        let f = Frame::read(&mut peer2).unwrap();
        assert_ne!(
            f.kind,
            b'E',
            "tab2 open after silent bundle swap must not fail: {}",
            String::from_utf8_lossy(&f.data)
        );
        if f.kind == SNAPSHOT {
            let mut payload = vec![0u8; 8];
            Frame::new(omg_session_runtime::ACK, f.seq, &payload)
                .send(&mut peer2)
                .ok();
            payload.clear();
            break;
        }
    }

    let wait_marker = Instant::now() + Duration::from_secs(5);
    while !marker.exists() && Instant::now() < wait_marker {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(fs::read_to_string(&marker).unwrap().trim(), "TAB2_OK");

    // Confirm `host-local` and `+internal-runtime-host` rotated to the new bundle on disk!
    assert!(wait_pid_dead(id_before.pid, Duration::from_secs(5)));
    assert!(wait_pid_dead(wpid_before, Duration::from_secs(5)));
    let id_after = host::query_host_identity(&host_sock).unwrap();
    let wpid_after = id_after.wrapper_pid.expect("rotated wrapper pid");
    cleanup.track_pid(id_after.pid);
    cleanup.track_pid(wpid_after);
    assert_ne!(id_after.pid, id_before.pid);
    assert_ne!(wpid_after, wpid_before);
    assert!(host::is_local_wrapper_healthy(&id_after, true));

    for sid in [tab1_id, tab2_id] {
        if let Some(pid) = host_list(&host_sock)
            .unwrap()
            .into_iter()
            .find(|s| s.id == sid)
            .and_then(|s| s.pid)
        {
            cleanup.track_pid(pid);
        }
        let _ = host_close_until_done(&host_sock, sid, Duration::from_secs(5));
    }
    let _ = peer1.write_all(&[]);
}

#[test]
fn background_mobile_gateway_rotates_when_app_bundle_or_revision_changes() {
    let tag = &nonce().unwrap()[..8];
    let raw_base = PathBuf::from(format!("/tmp/omg-mob-rot-{tag}"));
    private_dir(&raw_base);
    let base = fs::canonicalize(&raw_base).unwrap();
    let mut cleanup = TestCleanup::new(base.clone());

    let support = base.join("Application Support/OMG Mobile Test");
    let app_path = base.join("OMG Mobile.app");
    let staging_v2 = base.join("staged-v2/OMG Mobile.app");
    private_dir(&support);

    let bundle_id = format!("com.jischeng.omg.test.mobile.{tag}");
    let snap = "59c5cc7b4d1fe408faf5";
    let (_, omgd_v1) = create_mock_app_bundle(&app_path, &bundle_id, "rev-m1", snap, "m1_build");

    // Pick a free loopback port.
    let probe_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let listen_addr = probe_listener.local_addr().unwrap();
    drop(probe_listener);

    let start1 = Command::new(&omgd_v1)
        .args([
            "mobile",
            "start",
            "--listen",
            &listen_addr.to_string(),
            "--app-support",
        ])
        .arg(&support)
        .args(["--no-qr", "--json"])
        .env("OMG_HOST_APP_BUNDLE", &app_path)
        .env("OMG_HOST_APP_BUNDLE_ID", &bundle_id)
        .output()
        .unwrap();
    assert!(
        start1.status.success(),
        "mobile start v1 failed: {}",
        String::from_utf8_lossy(&start1.stderr)
    );

    let gw_json_path = support.join("mobile-gateway.json");
    let rec1: serde_json::Value =
        serde_json::from_slice(&fs::read(&gw_json_path).unwrap()).unwrap();
    let gw_pid1 = rec1["pid"].as_u64().unwrap() as u32;
    let gw_wpid1 = rec1["wrapper_pid"].as_u64().unwrap() as u32;
    cleanup.track_pid(gw_pid1);
    cleanup.track_pid(gw_wpid1);
    assert_eq!(rec1["revision"].as_str(), Some("rev-m1"));
    assert_eq!(rec1["wrapper_mode"].as_str(), Some("app-bundle"));

    // Calling `mobile start` again while healthy MUST reuse `gw_pid1`!
    let start_reuse = Command::new(&omgd_v1)
        .args([
            "mobile",
            "start",
            "--listen",
            &listen_addr.to_string(),
            "--app-support",
        ])
        .arg(&support)
        .args(["--no-qr", "--json"])
        .env("OMG_HOST_APP_BUNDLE", &app_path)
        .env("OMG_HOST_APP_BUNDLE_ID", &bundle_id)
        .output()
        .unwrap();
    assert!(start_reuse.status.success());
    let rec_reuse: serde_json::Value =
        serde_json::from_slice(&fs::read(&gw_json_path).unwrap()).unwrap();
    assert_eq!(rec_reuse["pid"].as_u64().unwrap() as u32, gw_pid1);

    // Replace `OMG Mobile.app` (Sparkle rename+unlink, even with same or new revision):
    create_mock_app_bundle(&staging_v2, &bundle_id, "rev-m1", snap, "m2_build");
    let moved = base.join("Caches/org.sparkle-project.Sparkle/Installation/OMG Mobile.app");
    fs::create_dir_all(moved.parent().unwrap()).unwrap();
    fs::rename(&app_path, &moved).unwrap();
    fs::rename(&staging_v2, &app_path).unwrap();
    fs::remove_dir_all(&moved).unwrap();

    let omgd_v2 = app_path.join("Contents/Resources/session-runtime/omgd");
    let start2 = Command::new(&omgd_v2)
        .args([
            "mobile",
            "start",
            "--listen",
            &listen_addr.to_string(),
            "--app-support",
        ])
        .arg(&support)
        .args(["--no-qr", "--json"])
        .env("OMG_HOST_APP_BUNDLE", &app_path)
        .env("OMG_HOST_APP_BUNDLE_ID", &bundle_id)
        .output()
        .unwrap();
    assert!(
        start2.status.success(),
        "mobile start after bundle swap failed: {}",
        String::from_utf8_lossy(&start2.stderr)
    );

    assert!(wait_pid_dead(gw_pid1, Duration::from_secs(5)));
    assert!(wait_pid_dead(gw_wpid1, Duration::from_secs(5)));

    let rec2: serde_json::Value =
        serde_json::from_slice(&fs::read(&gw_json_path).unwrap()).unwrap();
    let gw_pid2 = rec2["pid"].as_u64().unwrap() as u32;
    let gw_wpid2 = rec2["wrapper_pid"].as_u64().unwrap() as u32;
    cleanup.track_pid(gw_pid2);
    cleanup.track_pid(gw_wpid2);
    assert_ne!(gw_pid2, gw_pid1);
    assert_ne!(gw_wpid2, gw_wpid1);

    let _ = Command::new(&omgd_v2)
        .args(["mobile", "stop", "--app-support"])
        .arg(&support)
        .status();
}

#[test]
fn ensure_host_local_spawns_fresh_host_when_unlocked_host_lock_races_socket_shutdown() {
    use std::os::unix::net::UnixListener;

    let tag = &nonce().unwrap()[..8];
    let raw_base = PathBuf::from(format!("/tmp/omg-lh-race-{tag}"));
    private_dir(&raw_base);
    let base = fs::canonicalize(&raw_base).unwrap();
    let mut cleanup = TestCleanup::new(base.clone());

    let support = base.join("Application Support/OMG Race");
    let versions = support.join("session-runtime/versions");
    let state_dir = base.join("run/race-channel");
    private_dir(&support);
    private_dir(&versions);
    private_dir(&state_dir);

    let snap = "59c5cc7b4d1fe408faf5";
    let bin = install_version(&versions, "rev-race", snap);

    // Simulate the 1ms shutdown window of a real `host-local`: `host.lock` exists on disk
    // WITHOUT an active flock, while `host.sock` accepts the initial liveness probe and then
    // immediately closes/unlinks without serving any protocol frames.
    fs::write(state_dir.join("host.lock"), "999999\n").unwrap();
    let sock_path = state_dir.join("host.sock");
    let dying_listener = UnixListener::bind(&sock_path).unwrap();
    let dying_thread = std::thread::spawn(move || {
        if let Ok((conn, _)) = dying_listener.accept() {
            drop(conn);
        }
        drop(dying_listener);
    });

    let out = Command::new(&bin)
        .args(["ensure-host", "--local"])
        .arg(&state_dir)
        .env("OMG_APP_SUPPORT", &support)
        .env("SHELL", "/bin/sh")
        .output()
        .unwrap();
    let _ = dying_thread.join();
    assert!(
        out.status.success(),
        "ensure-host --local must recover from unlocked host.lock shutdown race: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let id = host::query_host_identity(&state_dir.join("host.sock"))
        .expect("fresh host-local must be running and serving host.sock");
    cleanup.track_pid(id.pid);
    assert_eq!(id.mode, "local");
    assert_eq!(id.revision, "rev-race");
}
