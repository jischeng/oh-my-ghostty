use std::{
    env,
    io::{self, Read, Write},
    net::Shutdown,
    os::unix::net::UnixStream,
    path::Path,
    process::{Command, Stdio},
};
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
fn relay_command(local: &str, mut command: Command, lease: bool) -> io::Result<()> {
    let mut ssh = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;
    let (socket, pipe) = UnixStream::pair()?;
    let upload = pipe.try_clone()?;
    let input = ssh.stdin.take().unwrap();
    let output = ssh.stdout.take().unwrap();
    let writer = std::thread::spawn(move || {
        let _ = copy(&upload, input);
        let _ = upload.shutdown(Shutdown::Both);
    });
    let reader = std::thread::spawn(move || {
        let _ = copy(output, &pipe);
        let _ = pipe.shutdown(Shutdown::Both);
    });
    let result = omg_session_runtime::host::relay(Path::new(local), socket, lease);
    let _ = ssh.kill();
    let _ = ssh.wait();
    let _ = writer.join();
    let _ = reader.join();
    let _ = std::fs::remove_file(local);
    result
}
fn ensure_host(directory: &str) -> io::Result<()> {
    use std::os::unix::{fs::PermissionsExt, process::CommandExt};
    let root = Path::new(directory);
    std::fs::create_dir_all(root)?;
    std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700))?;
    let socket = root.join("host.sock");
    if UnixStream::connect(&socket).is_ok() {
        return Ok(());
    }
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("host.log"))?;
    let shell = env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
    let mut c = Command::new(env::current_exe()?);
    c.arg("host")
        .arg(root)
        .args(["--", &shell, "-l"])
        .stdin(Stdio::null())
        .stdout(Stdio::from(log.try_clone()?))
        .stderr(Stdio::from(log));
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
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    Err(io::Error::other("host daemon failed to start"))
}
fn report(agent: &str, state: &str, conversation: &str, cwd: &str) -> io::Result<()> {
    use omg_session_runtime::record::{AgentEvent, Resume};
    let path = env::var("OMG_RUNTIME_EVENT_SOCKET").map_err(io::Error::other)?;
    let event = AgentEvent {
        token: env::var("OMG_RUNTIME_EVENT_TOKEN").map_err(io::Error::other)?,
        generation: env::var("OMG_RUNTIME_GENERATION").map_err(io::Error::other)?,
        pid: unsafe { libc::getpid() },
        group: unsafe { libc::getpgrp() },
        state: state.into(),
        resume: Resume {
            agent: agent.into(),
            conversation_id: conversation.into(),
            cwd: cwd.into(),
        },
    };
    event.resume.validate()?;
    use std::os::unix::fs::PermissionsExt;
    let local = Path::new(&path)
        .parent()
        .unwrap()
        .join(format!("r-{}.sock", std::process::id()));
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
fn show_error(local: &str, error: &dyn std::fmt::Display) -> io::Result<()> {
    // Give native surfaces a framed, bounded failure instead of a blank pane.
    let listener = std::os::unix::net::UnixListener::bind(local)?;
    listener.set_nonblocking(true)?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    while std::time::Instant::now() < deadline {
        match listener.accept() {
            Ok((mut s, _)) => {
                s.set_read_timeout(Some(std::time::Duration::from_secs(2)))?;
                s.set_write_timeout(Some(std::time::Duration::from_secs(2)))?;
                let _ = omg_session_runtime::Frame::read(&mut s);
                let _ = omg_session_runtime::Frame::new(b'E', 0, error.to_string().as_bytes())
                    .send(&mut s);
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(std::time::Duration::from_millis(20))
            }
            Err(e) => return Err(e),
        }
    }
    let _ = std::fs::remove_file(local);
    Ok(())
}
fn main() -> io::Result<()> {
    let a: Vec<String> = env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("serve") if a.len() >= 5 && a[3] == "--" => {
            omg_session_runtime::server::serve(Path::new(&a[2]), &a[4..])
        }
        Some("host") if a.len() >= 5 && a[3] == "--" => {
            omg_session_runtime::host::serve(Path::new(&a[2]), a[4..].to_vec())
        }
        Some("bridge") if a.len() == 3 => bridge(&a[2]),
        Some("connect") if a.len() == 4 => {
            let config = omg_session_runtime::deploy::load(Path::new(&a[3]))?;
            let (binary, state) = match omg_session_runtime::deploy::prepare(&config) {
                Ok(result) => result,
                Err(error) => {
                    let _ = show_error(&a[2], &error);
                    return Err(error);
                }
            };
            relay_command(
                &a[2],
                omg_session_runtime::deploy::command(&config, &binary, &state)?,
                true,
            )
        }
        Some("ensure-host") if a.len() == 3 => ensure_host(&a[2]),
        Some("report") if a.len() == 6 => report(&a[2], &a[3], &a[4], &a[5]),
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
        Some("handoff") if a.len() >= 4 => omg_session_runtime::handoff::request(&a[2], &a[3..]),
        Some("version") => {
            println!("omg-session-runtime/2 snapshot/1");
            Ok(())
        }
        _ => {
            eprintln!("usage: omgd host DIRECTORY -- SHELL... | serve SOCKET -- COMMAND... | bridge SOCKET | connect LOCAL_SOCKET CONNECTION_JSON");
            std::process::exit(2)
        }
    }
}
