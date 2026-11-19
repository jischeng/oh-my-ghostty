use std::{
    env,
    io::{self, Read, Write},
    net::Shutdown,
    os::unix::net::UnixStream,
    path::Path,
    process::{Child, Command, Stdio},
    sync::Arc,
};
mod mobile;
mod session_cli;
fn copy(mut input: impl Read, mut output: impl Write) -> io::Result<()> {
    let mut buffer = [0; 65536];
    loop {
        let n = input.read(&mut buffer)?;
        if n == 0 {
            return Ok(());
        }
        output.write_all(&buffer[..n])?;
    }
}
fn finish_handoff(result: io::Result<i32>) -> ! {
    match result {
        Ok(code) => std::process::exit(
            if code < 0 {
                128i32.saturating_sub(code)
            } else {
                code
            }
            .clamp(0, 255),
        ),
        Err(error) => {
            eprintln!("ssh: {error}");
            std::process::exit(255);
        }
    }
}
fn bridge(path: &str) -> io::Result<()> {
    use std::os::fd::FromRawFd;
    let socket = UnixStream::connect(path)?;
    let input = socket.try_clone()?;
    std::thread::spawn(move || {
        let _ = copy(io::stdin().lock(), &input);
        let _ = input.shutdown(Shutdown::Write);
    });
    let fd = unsafe { libc::dup(libc::STDOUT_FILENO) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    copy(&socket, unsafe { std::fs::File::from_raw_fd(fd) })
}
struct TunnelGuard {
    child: Child,
    writer: Option<std::thread::JoinHandle<()>>,
    reader: Option<std::thread::JoinHandle<()>>,
    diagnostics: Option<std::thread::JoinHandle<()>>,
}
impl Drop for TunnelGuard {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
        if let Some(thread) = self.writer.take() {
            let _ = thread.join();
        }
        if let Some(thread) = self.reader.take() {
            let _ = thread.join();
        }
        if let Some(thread) = self.diagnostics.take() {
            let _ = thread.join();
        }
    }
}

fn tunnel(mut command: Command) -> io::Result<omg_session_runtime::client::RelayTransport> {
    tunnel_child(command.spawn()?)
}

fn tunnel_child(mut child: Child) -> io::Result<omg_session_runtime::client::RelayTransport> {
    let input = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("SSH stdin unavailable"))?;
    let output = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("SSH stdout unavailable"))?;
    let diagnostics = child.stderr.take();
    let (socket, pipe) = UnixStream::pair()?;
    let upload = pipe.try_clone()?;
    let writer = std::thread::spawn(move || {
        let _ = copy(&upload, input);
        let _ = upload.shutdown(Shutdown::Both);
    });
    let reader = std::thread::spawn(move || {
        let _ = copy(output, &pipe);
        let _ = pipe.shutdown(Shutdown::Both);
    });
    let diagnostics = diagnostics.map(|input| {
        std::thread::spawn(move || {
            let _ = io::copy(&mut input.take(64 * 1024), &mut io::stderr());
        })
    });
    Ok(omg_session_runtime::client::RelayTransport {
        socket,
        guard: Box::new(TunnelGuard {
            child,
            writer: Some(writer),
            reader: Some(reader),
            diagnostics,
        }),
    })
}

fn batch_mode(config: &mut omg_session_runtime::deploy::Connection, interactive: bool) {
    let value = format!("BatchMode={}", if interactive { "no" } else { "yes" });
    let mut replaced = false;
    let mut index = 0;
    while index < config.arguments.len() {
        if config.arguments[index].starts_with("BatchMode=") {
            config.arguments[index] = value.clone();
            replaced = true;
        } else if config.arguments[index] == "-o"
            && config
                .arguments
                .get(index + 1)
                .is_some_and(|option| option.starts_with("BatchMode="))
        {
            config.arguments[index + 1] = value.clone();
            replaced = true;
            index += 1;
        }
        index += 1;
    }
    if !replaced {
        config.arguments.splice(0..0, ["-o".to_string(), value]);
    }
}

fn relay_connector(
    config: omg_session_runtime::deploy::Connection,
) -> omg_session_runtime::client::Connector {
    use omg_session_runtime::deploy::TransportKind;
    match config.transport {
        TransportKind::Ssh => Arc::new(move |interactive| {
            let mut attempt = config.clone();
            batch_mode(&mut attempt, interactive);
            match omg_session_runtime::deploy::fast_connect(&attempt, interactive) {
                Ok(child) => tunnel_child(child),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    if !attempt.auto_install {
                        return Err(io::Error::new(
                            io::ErrorKind::PermissionDenied,
                            "Runtime is not installed. Enable automatic omgd installation in Remote Hosts.",
                        ));
                    }
                    let (binary, state) =
                        omg_session_runtime::deploy::prepare(&attempt, interactive)?;
                    tunnel(omg_session_runtime::deploy::command(
                        &attempt,
                        &binary,
                        &state,
                        interactive,
                    )?)
                }
                Err(error) => Err(error),
            }
        }),
        TransportKind::Local => {
            let root = config.local_state_directory.clone();
            let shell = config.local_shell.clone();
            let helper = config.bundle.join("omgd");
            Arc::new(move |_| {
                let root = root
                    .as_ref()
                    .ok_or_else(|| io::Error::other("local runtime state directory is missing"))?;
                if !root.is_absolute() || root.as_os_str().to_string_lossy().contains('\0') {
                    return Err(io::Error::other("invalid local runtime state directory"));
                }
                let shell = shell
                    .clone()
                    .or_else(|| env::var("SHELL").ok())
                    .unwrap_or_else(|| "/bin/sh".into());
                ensure_host_with(&root.to_string_lossy(), Some(&shell), &helper, true, None)?;
                let path = root.join("host.sock");
                if path.as_os_str().as_encoded_bytes().len() >= 104 {
                    return Err(io::Error::other("local runtime socket path is too long"));
                }
                Ok(omg_session_runtime::client::RelayTransport {
                    socket: UnixStream::connect(path)?,
                    guard: Box::new(()),
                })
            })
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum HostLaunchMode {
    LegacyRemote,
    RemoteHolder { force_takeover: bool },
    Local,
}

struct BootstrapLock(std::fs::File);

impl BootstrapLock {
    fn acquire(root: &Path) -> io::Result<Self> {
        use std::os::{
            fd::AsRawFd,
            unix::fs::{OpenOptionsExt, PermissionsExt},
        };
        let lock_path = root.join("bootstrap.lock");
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&lock_path)?;
        std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o600))?;
        loop {
            let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
            if rc == 0 {
                return Ok(Self(file));
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}

impl Drop for BootstrapLock {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

fn wait_for_socket_after_early_exit(socket: &Path) -> bool {
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(500);
    loop {
        if UnixStream::connect(socket).is_ok() {
            return true;
        }
        if std::time::Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

fn ensure_host_cli(args: &[String]) -> io::Result<()> {
    let mut remote_holder = false;
    let mut force_takeover = false;
    let mut directory: Option<&str> = None;
    for arg in args {
        match arg.as_str() {
            "--remote-holder" => remote_holder = true,
            "--force-takeover" => force_takeover = true,
            flag if flag.starts_with("--") => {
                return Err(io::Error::other(format!(
                    "unknown ensure-host flag: {flag}"
                )));
            }
            value => {
                if directory.is_some() {
                    return Err(io::Error::other(
                        "usage: omgd ensure-host [--remote-holder] [--force-takeover] DIRECTORY",
                    ));
                }
                directory = Some(value);
            }
        }
    }
    let directory = directory.ok_or_else(|| {
        io::Error::other("usage: omgd ensure-host [--remote-holder] [--force-takeover] DIRECTORY")
    })?;
    let mode = if remote_holder {
        HostLaunchMode::RemoteHolder { force_takeover }
    } else {
        HostLaunchMode::LegacyRemote
    };
    ensure_host_mode(directory, None, &env::current_exe()?, mode, None)
}

fn gc_remote_cli(args: &[String]) -> io::Result<()> {
    let mut options = omg_session_runtime::gc::GcOptions::default();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--active-revision" => {
                i += 1;
                let rev = args
                    .get(i)
                    .ok_or_else(|| io::Error::other("missing --active-revision value"))?;
                if !omg_session_runtime::valid_revision(rev) {
                    return Err(io::Error::other("invalid --active-revision value"));
                }
                options.active_revision = Some(rev.clone());
            }
            "--active-state-dir" => {
                i += 1;
                let dir = args
                    .get(i)
                    .ok_or_else(|| io::Error::other("missing --active-state-dir value"))?;
                let path = std::path::PathBuf::from(dir);
                if !path.is_absolute() {
                    return Err(io::Error::other("--active-state-dir must be absolute"));
                }
                options.active_state_dir = Some(path);
            }
            "--min-age-secs" => {
                i += 1;
                let raw = args
                    .get(i)
                    .ok_or_else(|| io::Error::other("missing --min-age-secs value"))?;
                options.min_age_secs = raw
                    .parse::<u64>()
                    .map_err(|_| io::Error::other("invalid --min-age-secs value"))?;
            }
            "--dry-run" => {
                options.dry_run = true;
            }
            flag => {
                return Err(io::Error::other(format!(
                    "unknown gc-remote option: {flag}"
                )));
            }
        }
        i += 1;
    }
    if options.active_revision.is_none() {
        options.active_revision = Some(omg_session_runtime::host::current_host_revision());
    }
    let _ = omg_session_runtime::gc::gc_remote_default(&options)?;
    Ok(())
}

fn wait_for_host_lock_release(root: &Path, timeout: std::time::Duration) -> io::Result<()> {
    use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
    let lock_path = root.join("host.lock");
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&lock_path)
        {
            Ok(file) => {
                let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
                if rc == 0 {
                    unsafe {
                        libc::flock(file.as_raw_fd(), libc::LOCK_UN);
                    }
                    return Ok(());
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error),
        }
        if std::time::Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out waiting for previous host to step down",
            ));
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

fn ensure_host_with(
    directory: &str,
    shell_override: Option<&str>,
    executable: &Path,
    local: bool,
    support_override: Option<&Path>,
) -> io::Result<()> {
    let mode = if local {
        HostLaunchMode::Local
    } else {
        HostLaunchMode::LegacyRemote
    };
    ensure_host_mode(
        directory,
        shell_override,
        executable,
        mode,
        support_override,
    )
}

fn ensure_host_mode(
    directory: &str,
    shell_override: Option<&str>,
    executable: &Path,
    mode: HostLaunchMode,
    support_override: Option<&Path>,
) -> io::Result<()> {
    use std::os::{unix::fs::PermissionsExt, unix::process::CommandExt};
    let local = mode == HostLaunchMode::Local;
    let root = Path::new(directory);
    std::fs::create_dir_all(root)?;
    std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700))?;
    let _bootstrap_lock = BootstrapLock::acquire(root)?;
    let inferred_support = if local {
        let current_exe = env::current_exe().ok();
        let sup = support_override
            .map(omg_session_runtime::registry::normalize_support_path)
            .or_else(omg_session_runtime::registry::infer_support_root_from_env)
            .or_else(|| {
                omg_session_runtime::registry::infer_support_root_from_exe(executable).map(|p| {
                    if current_exe.as_deref() == Some(executable) {
                        omg_session_runtime::registry::prefer_logical_home_path(&p)
                    } else {
                        p
                    }
                })
            })
            .or_else(|| omg_session_runtime::registry::read_support_root_stamp(root))
            .or_else(omg_session_runtime::registry::infer_support_root_from_env_or_exe);
        if let Some(ref s) = sup {
            let _ = omg_session_runtime::registry::write_support_root_stamp(root, s);
        }
        sup
    } else {
        None
    };
    if let Some(shell) = shell_override {
        let metadata = std::fs::metadata(shell)?;
        if !Path::new(shell).is_absolute()
            || metadata.is_dir()
            || metadata.permissions().mode() & 0o111 == 0
        {
            return Err(io::Error::other(
                "local shell must be an executable absolute path",
            ));
        }
    }
    let metadata = std::fs::metadata(executable)
        .map_err(|_| io::Error::other("pinned local runtime helper is unavailable"))?;
    if !executable.is_absolute() || metadata.is_dir() || metadata.permissions().mode() & 0o111 == 0
    {
        return Err(io::Error::other(
            "pinned local runtime helper is not executable",
        ));
    }
    let socket = root.join("host.sock");
    if UnixStream::connect(&socket).is_ok() {
        if let HostLaunchMode::RemoteHolder { force_takeover } = mode {
            match omg_session_runtime::host::query_host_identity(&socket) {
                Ok(running) => {
                    if running.mode != "remote-holder" {
                        return Ok(());
                    }
                    let my_revision =
                        omg_session_runtime::host::current_host_revision_for_exe(executable);
                    if running.revision == my_revision {
                        return Ok(());
                    }
                    let my_snapshot =
                        omg_session_runtime::host::current_snapshot_revision_for_exe(executable);
                    if !omg_session_runtime::host::snapshot_revisions_compatible(
                        running.snapshot_revision.as_deref(),
                        my_snapshot.as_deref(),
                    ) {
                        return Err(io::Error::other(
                            "incompatible snapshot-revision host running in state directory; refusing takeover",
                        ));
                    }
                    if !force_takeover {
                        let my_mtime = omg_session_runtime::host::binary_mtime_for_exe(executable);
                        if let (Some(running_mtime), Some(my_mtime)) =
                            (running.binary_mtime, my_mtime)
                        {
                            if running_mtime > my_mtime.saturating_add(1) {
                                return Ok(());
                            }
                        }
                    }
                    omg_session_runtime::host::request_host_takeover(
                        &socket,
                        &my_revision,
                        my_snapshot.as_deref(),
                    )?;
                    wait_for_host_lock_release(root, std::time::Duration::from_secs(5))?;
                }
                Err(_) => {
                    // Older host does not support identity/takeover frames; preserve it safely.
                    return Ok(());
                }
            }
        } else {
            return Ok(());
        }
    }
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("host.log"))?;
    let shell = shell_override
        .map(str::to_string)
        .or_else(|| env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/sh".into());
    match mode {
        HostLaunchMode::LegacyRemote => {
            if omg_session_runtime::supervision::start(root, &shell)? {
                for _ in 0..100 {
                    if UnixStream::connect(&socket).is_ok() {
                        return Ok(());
                    }
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                return Err(io::Error::other("supervised host failed to become ready"));
            }
        }
        HostLaunchMode::RemoteHolder { .. } => {
            if omg_session_runtime::supervision::start_remote_holder(root, &shell)? {
                for _ in 0..100 {
                    if UnixStream::connect(&socket).is_ok() {
                        return Ok(());
                    }
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                return Err(io::Error::other(
                    "supervised remote-holder host failed to become ready",
                ));
            }
        }
        HostLaunchMode::Local => {}
    }
    if local {
        // The relay runs inside the app; keep the persistent host out of the
        // app coalition so Cmd-Q fully quits the app. The current helper does
        // the detach so older pinned host revisions need not support it.
        let command = [
            executable.to_string_lossy().into_owned(),
            "host-local".into(),
            root.to_string_lossy().into_owned(),
            "--".into(),
            shell.clone(),
            "-l".into(),
        ];
        let mut extra_env = Vec::new();
        if let Some(sup_str) = inferred_support.as_deref().and_then(Path::to_str) {
            extra_env.push(("OMG_APP_SUPPORT", sup_str));
        }
        if let Some(pid) = omg_session_runtime::launchd::spawn_with_env(
            &env::current_exe()?,
            &command,
            &root.join("host.log"),
            &extra_env,
        )? {
            for _ in 0..100 {
                if UnixStream::connect(&socket).is_ok() {
                    return Ok(());
                }
                if unsafe { libc::kill(pid as libc::pid_t, 0) } != 0 {
                    if wait_for_socket_after_early_exit(&socket) {
                        return Ok(());
                    }
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            return Err(io::Error::other("detached host daemon failed to start"));
        }
    }
    eprintln!("runtime supervision unavailable; process-group cleanup only");
    let subcommand = match mode {
        HostLaunchMode::Local => "host-local",
        HostLaunchMode::RemoteHolder { .. } => "host-remote",
        HostLaunchMode::LegacyRemote => "host",
    };
    let mut c = Command::new(executable);
    c.arg(subcommand)
        .arg(root)
        .args(["--", &shell, "-l"])
        .stdin(Stdio::null())
        .stdout(Stdio::from(log.try_clone()?))
        .stderr(Stdio::from(log));
    if let Some(ref sup) = inferred_support {
        c.env("OMG_APP_SUPPORT", sup);
    }
    unsafe {
        c.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            libc::signal(libc::SIGHUP, libc::SIG_IGN);
            Ok(())
        });
    }
    let mut child = c.spawn()?;
    for _ in 0..100 {
        if UnixStream::connect(&socket).is_ok() {
            return Ok(());
        }
        if child.try_wait()?.is_some() {
            if wait_for_socket_after_early_exit(&socket) {
                return Ok(());
            }
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    Err(io::Error::other("host daemon failed to start"))
}
fn report_cli(args: &[String]) -> io::Result<()> {
    use omg_session_runtime::record::{nonce, AgentEvent, Resume};
    let mut positional: Vec<&str> = Vec::new();
    let mut conversation_flag: Option<&str> = None;
    let mut cwd_flag: Option<&str> = None;
    let mut context_id: Option<String> = None;
    let mut attention: Option<String> = None;
    let mut phase: Option<String> = None;
    let mut message: Option<String> = None;
    let mut tier: Option<String> = None;
    let mut event_kind: Option<String> = None;
    let mut owner_pid: Option<i32> = None;
    let mut target_session_id: Option<String> = env::var("OMG_REPORT_SESSION_ID")
        .ok()
        .filter(|s| !s.trim().is_empty());

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--id" | "--context-id" => {
                i += 1;
                context_id = Some(
                    args.get(i)
                        .ok_or_else(|| io::Error::other("missing --id value"))?
                        .clone(),
                );
            }
            "--conversation" => {
                i += 1;
                conversation_flag = Some(
                    args.get(i)
                        .ok_or_else(|| io::Error::other("missing --conversation value"))?,
                );
            }
            "--cwd" => {
                i += 1;
                cwd_flag = Some(
                    args.get(i)
                        .ok_or_else(|| io::Error::other("missing --cwd value"))?,
                );
            }
            "--attention" | "--kind" => {
                i += 1;
                attention = Some(
                    args.get(i)
                        .ok_or_else(|| io::Error::other("missing --attention value"))?
                        .clone(),
                );
            }
            "--phase" => {
                i += 1;
                phase = Some(
                    args.get(i)
                        .ok_or_else(|| io::Error::other("missing --phase value"))?
                        .clone(),
                );
            }
            "--message" => {
                i += 1;
                message = Some(
                    args.get(i)
                        .ok_or_else(|| io::Error::other("missing --message value"))?
                        .clone(),
                );
            }
            "--tier" => {
                i += 1;
                tier = Some(
                    args.get(i)
                        .ok_or_else(|| io::Error::other("missing --tier value"))?
                        .clone(),
                );
            }
            "--event" => {
                i += 1;
                event_kind = Some(
                    args.get(i)
                        .ok_or_else(|| io::Error::other("missing --event value"))?
                        .clone(),
                );
            }
            "--pid" => {
                i += 1;
                let raw = args
                    .get(i)
                    .ok_or_else(|| io::Error::other("missing --pid value"))?;
                owner_pid = Some(
                    raw.parse::<i32>()
                        .map_err(|_| io::Error::other("invalid --pid value"))?,
                );
            }
            "--session-id" => {
                i += 1;
                target_session_id = Some(
                    args.get(i)
                        .ok_or_else(|| io::Error::other("missing --session-id value"))?
                        .clone(),
                );
            }
            flag if flag.starts_with("--") => {
                return Err(io::Error::other(format!("unknown report flag: {flag}")));
            }
            value => positional.push(value),
        }
        i += 1;
    }

    if positional.len() < 2 || positional.len() > 4 {
        return Err(io::Error::other(
            "usage: omgd report <agent> <state> [<conversation> [<cwd>]] [--id ID] [--attention permission|question] [--phase foreground|background] [--message TEXT]",
        ));
    }
    let raw_agent = positional[0];
    let agent = omg_session_runtime::agents::normalize_id(raw_agent)
        .ok_or_else(|| io::Error::other("invalid agent identifier"))?;
    let state = positional[1];
    let conversation = conversation_flag
        .or_else(|| positional.get(2).copied())
        .unwrap_or("")
        .trim();
    let conversation = if conversation == "-" {
        ""
    } else {
        conversation
    };
    let fallback_cwd = env::current_dir()
        .ok()
        .and_then(|p| p.into_os_string().into_string().ok())
        .unwrap_or_else(|| "/".into());
    let cwd = cwd_flag
        .or_else(|| positional.get(3).copied())
        .filter(|s| !s.is_empty())
        .unwrap_or(&fallback_cwd);
    if !cwd.starts_with('/') || cwd.len() > 4096 || cwd.contains('\0') {
        return Err(io::Error::other("invalid working directory"));
    }

    let resume = if !conversation.is_empty() {
        let r = Resume {
            agent: agent.clone(),
            conversation_id: conversation.to_owned(),
            cwd: cwd.to_owned(),
        };
        r.validate()?;
        Some(r)
    } else {
        None
    };

    let path = env::var("OMG_RUNTIME_EVENT_SOCKET")
        .or_else(|_| env::var("OMG_AGENT_SOCK"))
        .map_err(io::Error::other)?;
    let event = AgentEvent {
        token: env::var("OMG_RUNTIME_EVENT_TOKEN").map_err(io::Error::other)?,
        generation: env::var("OMG_RUNTIME_GENERATION").map_err(io::Error::other)?,
        pid: unsafe { libc::getpid() },
        group: unsafe { libc::getpgrp() },
        state: state.to_owned(),
        resume,
        agent: Some(agent),
        cwd: Some(cwd.to_owned()),
        context_id,
        attention,
        phase,
        message,
        tier,
        event: event_kind,
        owner_pid,
        session_id: target_session_id,
    };
    use std::os::unix::fs::PermissionsExt;
    let suffix = nonce().unwrap_or_else(|_| "0".into());
    let local = Path::new(&path)
        .parent()
        .ok_or_else(|| io::Error::other("invalid event socket path"))?
        .join(format!(
            "r-{}-{}.s",
            std::process::id(),
            &suffix[..4.min(suffix.len())]
        ));
    let socket = std::os::unix::net::UnixDatagram::bind(&local)?;
    std::fs::set_permissions(&local, std::fs::Permissions::from_mode(0o600))?;
    let result = (|| {
        socket.set_read_timeout(Some(std::time::Duration::from_millis(750)))?;
        socket.connect(path)?;
        socket.send(&serde_json::to_vec(&event)?)?;
        let mut ack = [0; 2];
        socket.recv(&mut ack)?;
        if &ack != b"OK" {
            return Err(io::Error::other("hook rejected"));
        }
        Ok(())
    })();
    let _ = std::fs::remove_file(local);
    result
}
fn main() -> io::Result<()> {
    let a: Vec<String> = env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("sessions") => std::process::exit(session_cli::run(&a[2..])?.into()),
        Some("serve") if a.len() >= 5 && a[3] == "--" => {
            omg_session_runtime::server::serve(Path::new(&a[2]), &a[4..])
        }
        Some("host") if a.len() >= 5 && a[3] == "--" => {
            omg_session_runtime::host::serve(Path::new(&a[2]), a[4..].to_vec())
        }
        Some("host-remote") if a.len() >= 5 && a[3] == "--" => {
            omg_session_runtime::host::serve_remote_holder(Path::new(&a[2]), a[4..].to_vec())
        }
        Some("host-local") if a.len() >= 5 && a[3] == "--" => {
            omg_session_runtime::host::serve_local(Path::new(&a[2]), a[4..].to_vec())
        }
        Some("detach") if a.len() >= 5 && a[3] == "--" => {
            omg_session_runtime::launchd::detach(Path::new(&a[2]), &a[4..])
        }
        Some("session-holder") if a.len() == 2 => omg_session_runtime::holder::run_from_stdin(),
        Some("bridge") if a.len() == 3 => bridge(&a[2]),
        Some("mobile") => mobile::run(&a[2..]),
        Some("install-runtime") if a.len() == 3 => {
            let mut config = omg_session_runtime::deploy::load(Path::new(&a[2]))?;
            if config.transport != omg_session_runtime::deploy::TransportKind::Ssh {
                return Err(io::Error::other("installation requires an SSH host"));
            }
            config.auto_install = true;
            omg_session_runtime::deploy::prepare(&config, true).map(|_| ())
        }
        Some("connect") if a.len() == 4 => {
            let config = omg_session_runtime::deploy::load(Path::new(&a[3]))?;
            let interactive_first = config.transport
                == omg_session_runtime::deploy::TransportKind::Ssh
                && config.arguments.iter().any(|arg| arg == "BatchMode=no");
            omg_session_runtime::client::supervise(
                Path::new(&a[2]),
                relay_connector(config),
                interactive_first,
            )
        }
        Some("retry-local") if a.len() >= 3 => {
            let interactive = a.iter().skip(2).any(|arg| arg == "--interactive");
            let socket = a
                .iter()
                .skip(2)
                .find(|arg| arg.as_str() != "--interactive")
                .ok_or_else(|| io::Error::other("missing local socket"))?;
            omg_session_runtime::client::retry_local(Path::new(socket), interactive)
        }
        Some("close-local") if a.len() == 4 => {
            let mut socket = UnixStream::connect(&a[2])?;
            socket.set_read_timeout(Some(std::time::Duration::from_secs(15)))?;
            socket.set_write_timeout(Some(std::time::Duration::from_secs(2)))?;
            omg_session_runtime::Frame::new(b'K', 0, a[3].as_bytes()).send(&mut socket)?;
            let response = loop {
                let response = omg_session_runtime::Frame::read(&mut socket)?;
                if response.kind != b'T' {
                    break response;
                }
            };
            if response.kind == b'K' && response.data == b"closed" {
                Ok(())
            } else {
                Err(io::Error::other("remote close pending or unavailable"))
            }
        }
        Some("list-local") if a.len() == 3 => {
            let sessions = omg_session_runtime::client::list_local(Path::new(&a[2]))?;
            serde_json::to_writer(io::stdout().lock(), &sessions)?;
            println!();
            Ok(())
        }
        Some("exec-local") if a.len() == 5 => {
            let max_output_bytes = match a[3].parse::<usize>() {
                Ok(value) => value,
                Err(_) => {
                    std::process::exit(exec_exit_transport(&format!(
                        "invalid max-output-bytes: {}",
                        a[3]
                    )));
                }
            };
            std::process::exit(exec_local(Path::new(&a[2]), max_output_bytes, &a[4]));
        }
        Some("ensure-host") if a.len() >= 3 => ensure_host_cli(&a[2..]),
        Some("gc-remote") => gc_remote_cli(&a[2..]),
        Some("report") if a.len() >= 4 => report_cli(&a[2..]),
        Some("handoff-probe") if a.len() >= 4 => {
            let interactive = a.iter().skip(4).any(|arg| arg == "--interactive");
            session_cli::handoff_probe(Path::new(&a[2]), &a[3], interactive)
        }
        Some("handoff-close") if a.len() >= 4 => {
            let interactive = a.iter().skip(4).any(|arg| arg == "--interactive");
            let mut timeout_secs = 15u64;
            let mut idx = 4;
            while idx < a.len() {
                if a[idx] == "--timeout-secs" {
                    if let Some(raw) = a.get(idx + 1) {
                        timeout_secs = raw
                            .parse::<u64>()
                            .map_err(|_| io::Error::other("invalid --timeout-secs"))?;
                        idx += 2;
                        continue;
                    }
                }
                idx += 1;
            }
            session_cli::handoff_close(Path::new(&a[2]), &a[3], interactive, timeout_secs)
        }
        Some("handoff-check") if a.len() >= 3 => {
            if unsafe { libc::isatty(libc::STDIN_FILENO) } == 1
                && unsafe { libc::isatty(libc::STDOUT_FILENO) } == 1
                && omg_session_runtime::handoff::interactive(&a[2..])
            {
                Ok(())
            } else {
                std::process::exit(64)
            }
        }
        Some("handoff") if a.len() >= 4 => {
            finish_handoff(omg_session_runtime::handoff::request(&a[2], &a[3..], None))
        }
        Some("handoff-cwd") if a.len() >= 5 => finish_handoff(
            omg_session_runtime::handoff::request(&a[2], &a[4..], Some(&a[3])),
        ),
        Some("version") => {
            println!("omg-session-runtime/2 snapshot/1");
            Ok(())
        }
        _ => {
            eprintln!("usage: omgd sessions --help | mobile --help | host DIRECTORY -- SHELL... | host-local DIRECTORY -- SHELL... | session-holder | serve SOCKET -- COMMAND... | bridge SOCKET | install-runtime CONNECTION_JSON | connect LOCAL_SOCKET CONNECTION_JSON | retry-local SOCKET [--interactive] | close-local SOCKET UUID | list-local SOCKET | exec-local SOCKET MAX_OUTPUT_BYTES COMMAND");
            std::process::exit(2)
        }
    }
}

fn exec_exit_unsupported(reason: &str) -> i32 {
    let mut stderr = io::stderr().lock();
    let _ = writeln!(stderr, "\u{1e}OMG-EXEC-UNSUPPORTED\u{1f}\n{reason}");
    let _ = stderr.flush();
    253
}

fn exec_exit_limit() -> i32 {
    let mut stderr = io::stderr().lock();
    let _ = writeln!(stderr, "\u{1e}OMG-EXEC-LIMIT\u{1f}");
    let _ = stderr.flush();
    252
}

fn exec_exit_transport(reason: &str) -> i32 {
    let mut stderr = io::stderr().lock();
    let _ = writeln!(stderr, "\u{1e}OMG-EXEC-TRANSPORT\u{1f}\n{reason}");
    let _ = stderr.flush();
    255
}

fn enqueue_exec_frame(
    queue: &mut std::collections::VecDeque<Vec<u8>>,
    queued: &mut usize,
    frame: omg_session_runtime::Frame,
) {
    let encoded = frame.encode();
    *queued += encoded.len();
    queue.push_back(encoded);
}

fn decode_next_frame(buf: &mut Vec<u8>) -> io::Result<Option<omg_session_runtime::Frame>> {
    if buf.len() < 13 {
        return Ok(None);
    }
    let len = u32::from_be_bytes(buf[9..13].try_into().unwrap()) as usize;
    if len > omg_session_runtime::MAX_FRAME {
        return Err(io::Error::other("exec frame too large"));
    }
    if buf.len() < 13 + len {
        return Ok(None);
    }
    let frame = omg_session_runtime::Frame::read(&mut &buf[..13 + len])?;
    buf.drain(..13 + len);
    Ok(Some(frame))
}

fn exec_local(socket_path: &Path, max_output_bytes: usize, command: &str) -> i32 {
    use std::collections::VecDeque;
    use std::os::fd::AsRawFd;

    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    let mut stream = match UnixStream::connect(socket_path) {
        Ok(s) => s,
        Err(error) => return exec_exit_unsupported(&error.to_string()),
    };
    if let Err(error) = stream.set_nonblocking(true) {
        return exec_exit_transport(&error.to_string());
    }

    let open_payload = match serde_json::to_vec(&omg_session_runtime::host::ExecOpen {
        command: command.to_owned(),
        max_output_bytes,
    }) {
        Ok(bytes) => bytes,
        Err(error) => return exec_exit_transport(&error.to_string()),
    };
    if open_payload.len() > omg_session_runtime::MAX_FRAME {
        return exec_exit_transport("exec request too large");
    }

    let mut out_queue: VecDeque<Vec<u8>> = VecDeque::new();
    let mut out_offset = 0usize;
    let mut out_queued = 0usize;
    let mut write_closed = false;
    enqueue_exec_frame(
        &mut out_queue,
        &mut out_queued,
        omg_session_runtime::Frame::new(b'x', 0, &open_payload),
    );

    let mut in_buf = Vec::new();
    let mut stdin_eof = false;
    let mut stdin_buf = vec![0u8; 64 * 1024];
    let mut read_buf = vec![0u8; 64 * 1024];

    loop {
        while !write_closed {
            let Some(front) = out_queue.front() else {
                break;
            };
            match stream.write(&front[out_offset..]) {
                Ok(0) => {
                    write_closed = true;
                    stdin_eof = true;
                    out_queue.clear();
                    out_offset = 0;
                    out_queued = 0;
                    break;
                }
                Ok(n) => {
                    out_offset += n;
                    out_queued -= n;
                    if out_offset == front.len() {
                        out_queue.pop_front();
                        out_offset = 0;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    write_closed = true;
                    stdin_eof = true;
                    out_queue.clear();
                    out_offset = 0;
                    out_queued = 0;
                    break;
                }
            }
        }

        let mut stream_eof = false;
        let mut stream_err: Option<io::Error> = None;
        loop {
            match stream.read(&mut read_buf) {
                Ok(0) => stream_eof = true,
                Ok(n) => in_buf.extend_from_slice(&read_buf[..n]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => stream_err = Some(error),
            }

            loop {
                let frame = match decode_next_frame(&mut in_buf) {
                    Ok(Some(frame)) => frame,
                    Ok(None) => break,
                    Err(error) => {
                        let _ = io::stdout().flush();
                        let _ = io::stderr().flush();
                        return exec_exit_transport(&error.to_string());
                    }
                };
                match frame.kind {
                    b'T' => {}
                    b'P' if frame.seq == 0 => {}
                    b'o' => {
                        let mut stdout = io::stdout().lock();
                        if stdout.write_all(&frame.data).is_err() {
                            return 255;
                        }
                    }
                    b'e' => {
                        let mut stderr = io::stderr().lock();
                        if stderr.write_all(&frame.data).is_err() {
                            return 255;
                        }
                    }
                    b'x' => {
                        let _ = io::stdout().flush();
                        let _ = io::stderr().flush();
                        let status = std::str::from_utf8(&frame.data)
                            .ok()
                            .and_then(|s| s.trim().parse::<i32>().ok())
                            .map(|code| code.clamp(0, 255));
                        return match status {
                            Some(code) => code,
                            None => exec_exit_transport("invalid exec exit status"),
                        };
                    }
                    b'E' => {
                        let _ = io::stdout().flush();
                        let _ = io::stderr().flush();
                        let reason = String::from_utf8_lossy(&frame.data);
                        return match frame.data.as_slice() {
                            b"relay-offline" | b"exec-unsupported" => {
                                exec_exit_unsupported(&reason)
                            }
                            b"output-limit-exceeded" => exec_exit_limit(),
                            _ => exec_exit_transport(&reason),
                        };
                    }
                    _ => {
                        let _ = io::stdout().flush();
                        let _ = io::stderr().flush();
                        return exec_exit_transport("unexpected frame from exec stream");
                    }
                }
            }

            if stream_eof || stream_err.is_some() {
                break;
            }
        }

        let _ = io::stdout().flush();
        let _ = io::stderr().flush();

        if stream_eof {
            return exec_exit_transport("exec stream closed before completion");
        }
        if let Some(error) = stream_err {
            return exec_exit_transport(&error.to_string());
        }

        let mut pfds = Vec::with_capacity(2);
        let mut stream_events = libc::POLLIN;
        if !write_closed && out_queued > 0 {
            stream_events |= libc::POLLOUT;
        }
        pfds.push(libc::pollfd {
            fd: stream.as_raw_fd(),
            events: stream_events,
            revents: 0,
        });
        let poll_stdin = !stdin_eof && !write_closed && out_queued < 1024 * 1024;
        if poll_stdin {
            pfds.push(libc::pollfd {
                fd: libc::STDIN_FILENO,
                events: libc::POLLIN,
                revents: 0,
            });
        }

        let rc = unsafe { libc::poll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, -1) };
        if rc < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return exec_exit_transport(&error.to_string());
            }
            continue;
        }

        if poll_stdin {
            let revents = pfds[1].revents;
            if revents & libc::POLLNVAL != 0 {
                stdin_eof = true;
                enqueue_exec_frame(
                    &mut out_queue,
                    &mut out_queued,
                    omg_session_runtime::Frame::new(b'z', 0, &[]),
                );
            } else if revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
                let n = unsafe {
                    libc::read(
                        libc::STDIN_FILENO,
                        stdin_buf.as_mut_ptr().cast(),
                        stdin_buf.len(),
                    )
                };
                if n > 0 {
                    enqueue_exec_frame(
                        &mut out_queue,
                        &mut out_queued,
                        omg_session_runtime::Frame::new(b'i', 0, &stdin_buf[..n as usize]),
                    );
                } else if n == 0 {
                    stdin_eof = true;
                    enqueue_exec_frame(
                        &mut out_queue,
                        &mut out_queued,
                        omg_session_runtime::Frame::new(b'z', 0, &[]),
                    );
                } else {
                    let error = io::Error::last_os_error();
                    if !matches!(
                        error.kind(),
                        io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                    ) {
                        stdin_eof = true;
                        enqueue_exec_frame(
                            &mut out_queue,
                            &mut out_queued,
                            omg_session_runtime::Frame::new(b'z', 0, &[]),
                        );
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ensure_host_with;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn ensure_host_with_serializes_concurrent_cold_start_and_handles_early_exit() {
        let nonce = omg_session_runtime::record::nonce().unwrap();
        let base = std::env::temp_dir().join(format!("omg-bootstrap-{}", &nonce[..8]));
        let state = base.join("state");
        std::fs::create_dir_all(&base).unwrap();
        std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o700)).unwrap();

        let count_file = base.join("spawns");
        let helper = base.join("fake-helper.sh");
        let pid_file = base.join("listener.pid");
        // Spawn a Python listener that starts after 150ms while the launcher exits immediately,
        // exercising both bootstrap.lock serialization and early-exit socket polling!
        std::fs::write(
            &helper,
            format!(
                r#"#!/bin/sh
echo x >> {count:?}
python3 -c '
import os, socket, sys, time
root = sys.argv[1]
pid_path = sys.argv[2]
if os.fork() != 0:
    os._exit(0)
os.setsid()
open(pid_path, "w").write(str(os.getpid()))
time.sleep(0.15)
sock = socket.socket(socket.AF_UNIX)
sock.bind(os.path.join(root, "host.sock"))
sock.listen(16)
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    sock.settimeout(0.1)
    try:
        conn, _ = sock.accept()
        conn.close()
    except OSError:
        pass
' "$2" {pid_file:?}
"#,
                count = count_file,
                pid_file = pid_file,
            ),
        )
        .unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o700)).unwrap();

        let mut handles = Vec::new();
        for _ in 0..6 {
            let dir = state.to_string_lossy().into_owned();
            let exe = helper.clone();
            handles.push(std::thread::spawn(move || {
                ensure_host_with(&dir, Some("/bin/sh"), &exe, false, None)
            }));
        }
        for handle in handles {
            handle.join().unwrap().unwrap();
        }

        let lock_meta = std::fs::symlink_metadata(state.join("bootstrap.lock")).unwrap();
        assert_eq!(lock_meta.permissions().mode() & 0o777, 0o600);
        let spawn_count = std::fs::read_to_string(&count_file)
            .unwrap()
            .lines()
            .count();
        assert_eq!(
            spawn_count, 1,
            "bootstrap.lock must serialize concurrent cold-starts to a single spawn"
        );

        if let Ok(pid_str) = std::fs::read_to_string(&pid_file) {
            if let Ok(pid) = pid_str.trim().parse::<libc::pid_t>() {
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                }
            }
        }
        let _ = std::fs::remove_dir_all(&base);
    }
}
