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
fn relay(local: &str, host: &str, remote: &str) -> io::Result<()> {
    if host.starts_with('-')
        || remote.is_empty()
        || !remote
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"/._-".contains(&b))
    {
        return Err(io::Error::other("invalid endpoint"));
    }
    let command = format!("{remote}/omg-sessiond bridge {remote}/host.sock");
    let mut ssh = Command::new("/usr/bin/ssh")
        .args([
            "-T",
            "-o",
            "BatchMode=yes",
            "-o",
            "ServerAliveInterval=10",
            "-o",
            "ServerAliveCountMax=2",
            "--",
            host,
            &command,
        ])
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
    let result = omg_session_runtime::host::relay(Path::new(local), socket);
    let _ = ssh.kill();
    let _ = ssh.wait();
    let _ = writer.join();
    let _ = reader.join();
    let _ = std::fs::remove_file(local);
    result
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
        Some("ssh-relay") if a.len() == 5 => relay(&a[2], &a[3], &a[4]),
        _ => {
            eprintln!("usage: omg-sessiond host DIRECTORY -- SHELL... | serve SOCKET -- COMMAND... | bridge SOCKET | ssh-relay LOCAL_SOCKET HOST REMOTE_DIRECTORY");
            std::process::exit(2)
        }
    }
}
