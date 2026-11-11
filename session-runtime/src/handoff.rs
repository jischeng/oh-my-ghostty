//! Local CLI-to-pane handoff. Only conservative interactive SSH invocations
//! qualify; commands, forwarding and control operations retain system SSH.
use std::{
    env,
    io::{self, Write},
    time::Duration,
};
pub fn interactive(args: &[String]) -> bool {
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a == "--" {
            i += 1;
            break;
        }
        if !a.starts_with('-') {
            break;
        }
        let mut chars = a[1..].chars();
        while let Some(c) = chars.next() {
            if "p ilFJ".replace(' ', "").contains(c) {
                if chars.as_str().is_empty() {
                    i += 1;
                    if i >= args.len() {
                        return false;
                    }
                }
                break;
            }
            if !"46Avq".contains(c) {
                return false;
            }
        }
        i += 1;
    }
    i + 1 == args.len() && !args[i].is_empty() && !args[i].starts_with('-')
}
pub fn request(ssh: &str, args: &[String], remote_cwd: Option<&str>) -> io::Result<i32> {
    if !interactive(args) {
        return Err(io::Error::other("not an interactive native SSH request"));
    }
    if unsafe { libc::isatty(libc::STDIN_FILENO) } != 1
        || unsafe { libc::isatty(libc::STDOUT_FILENO) } != 1
    {
        return Err(io::Error::other(
            "native SSH requires an interactive terminal",
        ));
    }
    let token = env::var("OMG_SSH_HANDOFF_TOKEN").map_err(io::Error::other)?;
    let directory = env::var("OMG_SSH_HANDOFF_DIRECTORY").map_err(io::Error::other)?;
    if token.is_empty() || directory.is_empty() {
        return Err(io::Error::other(
            "native SSH is unavailable in this terminal",
        ));
    }
    let id = crate::record::nonce()?;
    let payload = serde_json::json!({"token":token,"ssh":ssh,"args":args,"cwd":env::current_dir()?,
                          "pid":std::process::id(),"viewer":"inline/1","remote_cwd":remote_cwd});
    use std::os::unix::fs::OpenOptionsExt;
    let path = std::path::Path::new(&directory).join(format!("{id}.json"));
    let mut file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&path)?;
    file.write_all(&serde_json::to_vec(&payload)?)?;
    file.sync_all()?;
    print!("\x1b]3008;start=omg-runtime-request-{id};type=app\x07");
    io::stdout().flush()?;
    // The GUI authorizes a connection; this foreground process remains the
    // viewer until remote exit, so the existing local shell naturally waits.
    let accepted = std::path::Path::new(&directory).join(format!("{id}.accepted"));
    let failed = std::path::Path::new(&directory).join(format!("{id}.failed"));
    let start = std::time::Instant::now();
    loop {
        if let Ok(message) = std::fs::read_to_string(&failed) {
            let _ = std::fs::remove_file(&failed);
            let _ = std::fs::remove_file(&path);
            let _ = std::fs::remove_file(&accepted);
            return Err(io::Error::other(format!("OMG native SSH: {message}")));
        }
        if accepted.exists() {
            let approval = read_private(&accepted)?;
            let _ = std::fs::remove_file(&accepted);
            let _ = std::fs::remove_file(&path);
            // Compatibility with an older GUI during an in-place app upgrade.
            if approval.is_empty() {
                return Ok(0);
            }
            if approval == b"passthrough" {
                return Ok(64);
            }
            let approval: Approval = serde_json::from_slice(&approval)?;
            let result = run_inline(&approval);
            crate::inline::forget_context(&approval.context);
            if result.is_err() {
                crate::inline::end_context(&approval.context, 255);
            }
            return result;
        }
        if !accepted.exists()
            && directory.contains("/session-runtime/bridges/")
            && start.elapsed() > Duration::from_millis(800)
        {
            let _ = std::fs::remove_file(&path);
            return headless_handoff(&id, &directory, ssh, args, remote_cwd);
        }
        if !accepted.exists() && start.elapsed() > Duration::from_secs(60) {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = std::fs::remove_file(path);
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "OMG native SSH handoff timed out",
    ))
}

fn headless_handoff(
    id: &str,
    directory: &str,
    ssh: &str,
    args: &[String],
    remote_cwd: Option<&str>,
) -> io::Result<i32> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let Some(target) = crate::location::parse_ssh_args(args) else {
        return Ok(64);
    };
    let mut cursor = Some(std::path::Path::new(directory));
    let mut runtime_dir = None;
    while let Some(dir) = cursor {
        if dir.file_name().and_then(|s| s.to_str()) == Some("session-runtime") {
            runtime_dir = Some(dir.to_path_buf());
            break;
        }
        cursor = dir.parent();
    }
    let Some(runtime_dir) = runtime_dir else {
        return Ok(64);
    };
    let endpoints_path = runtime_dir.join("endpoints.json");
    let Ok(bytes) = std::fs::read(&endpoints_path) else {
        return Ok(64);
    };
    let Ok(archive) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return Ok(64);
    };
    let matched = archive["endpoints"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|entry| {
            entry["descriptor"]["connection"]["destination"].as_str()
                == Some(target.destination.as_str())
        });
    let Some(entry) = matched else {
        return Ok(64);
    };
    let descriptor = &entry["descriptor"];
    let Some(revision) = descriptor["revision"].as_str() else {
        return Ok(64);
    };
    let bundle = runtime_dir.join("versions").join(revision);
    let helper = bundle.join("omgd");
    if !helper.is_file() {
        return Ok(64);
    }
    let policy: crate::lifecycle::Policy = serde_json::from_value(descriptor["policy"].clone())
        .unwrap_or_default();
    let uid = unsafe { libc::getuid() };
    let root = std::path::PathBuf::from(format!("/tmp/omg-inline-{uid}-{id}"));
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&root)?;
    let socket = root.join("relay.sock");
    let configuration = root.join("connection.json");
    let local_cwd = env::current_dir()?
        .to_string_lossy()
        .into_owned();
    let mut ssh_args = target.options.clone();
    ssh_args.push(target.destination.clone());
    let connection = crate::deploy::Connection {
        auto_install: true,
        transport: crate::deploy::TransportKind::Ssh,
        executable: if ssh.starts_with('/') {
            ssh.to_owned()
        } else {
            "/usr/bin/ssh".to_owned()
        },
        arguments: ssh_args,
        cwd: local_cwd.clone(),
        bundle,
        policy: policy.clone(),
        revision: Some(revision.to_owned()),
        local_state_directory: None,
        local_shell: Some("/bin/zsh".to_owned()),
        hooks: None,
        tty_authentication: true,
    };
    let mut cfg_file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&configuration)?;
    cfg_file.write_all(&serde_json::to_vec(&connection)?)?;
    cfg_file.sync_all()?;
    let pane_nonce = crate::record::nonce()?;
    let pane_id = format!(
        "{}-{}-{}-{}-{}",
        &pane_nonce[..8],
        &pane_nonce[8..12],
        &pane_nonce[12..16],
        &pane_nonce[16..20],
        &pane_nonce[20..]
    );
    let host_label = target
        .destination
        .rsplit('@')
        .next()
        .unwrap_or(&target.destination)
        .to_owned();
    let approval = Approval {
        helper,
        configuration,
        socket,
        open: serde_json::json!({
            "id": pane_id,
            "policy": policy,
            "create": true,
            "cwd": remote_cwd,
            "inline_viewer": true,
        }),
        context: crate::inline::Context {
            connection_id: format!("omg-ssh-inline-{id}"),
            target: host_label,
            local_cwd,
            active_record: None,
            owner_record: None,
        },
    };
    let result = run_inline(&approval);
    crate::inline::forget_context(&approval.context);
    if result.is_err() {
        crate::inline::end_context(&approval.context, 255);
    }
    result
}

pub(crate) fn read_private(path: &std::path::Path) -> io::Result<Vec<u8>> {
    read_private_limited(path, 65_536)
}

fn read_private_limited(path: &std::path::Path, maximum: u64) -> io::Result<Vec<u8>> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.len() > maximum
    {
        return Err(io::Error::other("invalid SSH handoff response"));
    }
    let mut data = Vec::new();
    file.take(maximum + 1).read_to_end(&mut data)?;
    if data.len() as u64 > maximum {
        return Err(io::Error::other("SSH handoff response too large"));
    }
    Ok(data)
}

#[derive(serde::Deserialize)]
struct Approval {
    helper: std::path::PathBuf,
    configuration: std::path::PathBuf,
    socket: std::path::PathBuf,
    open: serde_json::Value,
    context: crate::inline::Context,
}

struct RelayProcess {
    child: std::process::Child,
    diagnostics: std::sync::Arc<std::sync::Mutex<std::collections::VecDeque<u8>>>,
    reader: Option<std::thread::JoinHandle<()>>,
}
impl RelayProcess {
    fn new(mut child: std::process::Child) -> Self {
        use std::io::Read;
        let diagnostics =
            std::sync::Arc::new(std::sync::Mutex::new(std::collections::VecDeque::new()));
        let captured = diagnostics.clone();
        let reader = child.stderr.take().map(|mut stderr| {
            std::thread::spawn(move || {
                let mut bytes = [0; 4096];
                loop {
                    match stderr.read(&mut bytes) {
                        Ok(0) => break,
                        Ok(len) => {
                            let mut tail = captured.lock().unwrap_or_else(|e| e.into_inner());
                            let discard = (tail.len() + len).saturating_sub(16 * 1024);
                            tail.drain(..discard);
                            tail.extend(&bytes[..len]);
                        }
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                        Err(_) => break,
                    }
                }
            })
        });
        Self {
            child,
            diagnostics,
            reader,
        }
    }
    fn stop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
    fn failure(&mut self, message: &str) -> io::Error {
        self.stop();
        let bytes: Vec<_> = self
            .diagnostics
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .copied()
            .collect();
        let detail: String = String::from_utf8_lossy(&bytes)
            .chars()
            .take(2048)
            .map(|c| if c.is_control() { ' ' } else { c })
            .collect();
        io::Error::other(if detail.trim().is_empty() {
            message.to_owned()
        } else {
            format!("{message}: {}", detail.trim())
        })
    }
}
impl Drop for RelayProcess {
    fn drop(&mut self) {
        self.stop();
    }
}

struct RelayFiles<'a>(&'a Approval);
impl Drop for RelayFiles<'_> {
    fn drop(&mut self) {
        let approval = self.0;
        let Some(root) = approval.socket.parent() else {
            return;
        };
        if approval.configuration.parent() != Some(root)
            || approval.socket.file_name().and_then(|s| s.to_str()) != Some("relay.sock")
            || approval.configuration.file_name().and_then(|s| s.to_str())
                != Some("connection.json")
            || !root
                .file_name()
                .and_then(|s| s.to_str())
                .is_some_and(|s| s.starts_with("omg-inline-"))
        {
            return;
        }
        let _ = std::fs::remove_file(&approval.socket);
        let _ = std::fs::remove_file(&approval.configuration);
        let _ = std::fs::remove_dir(root);
    }
}

fn run_inline(approval: &Approval) -> io::Result<i32> {
    use std::process::{Command, Stdio};
    if !approval.helper.is_absolute()
        || !approval.configuration.is_absolute()
        || !approval.socket.is_absolute()
        || approval.socket.as_os_str().len() >= 104
    {
        return Err(io::Error::other("invalid inline SSH connection paths"));
    }
    // Validate before starting. Authentication inherits this controlling TTY,
    // while the framed protocol stays on pipes and the private relay socket.
    let _: crate::deploy::Connection = serde_json::from_slice(&read_private_limited(
        &approval.configuration,
        2 * 1024 * 1024,
    )?)?;
    let _files = RelayFiles(approval);
    let mut command = Command::new(&approval.helper);
    command
        .args([
            "connect",
            approval.socket.to_str().unwrap(),
            approval.configuration.to_str().unwrap(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    // These capabilities belong to the enclosing local PTY. In particular,
    // SSH SendEnv must not carry them into a remote account.
    for key in [
        "OMG_SSH_HANDOFF_HELPER",
        "OMG_SSH_HANDOFF_DIRECTORY",
        "OMG_SSH_HANDOFF_TOKEN",
        "OMG_RUNTIME_EVENT_SOCKET",
        "OMG_RUNTIME_EVENT_TOKEN",
        "OMG_SESSION_RUNTIME_DESCRIPTOR",
    ] {
        command.env_remove(key);
    }
    // Diagnostics must never be spliced into an unfinished remote VT sequence.
    // Keep a bounded tail for transport failures; authentication still uses /dev/tty.
    let mut relay = RelayProcess::new(command.spawn()?);
    let start = std::time::Instant::now();
    while !approval.socket.exists() {
        if relay.child.try_wait()?.is_some() {
            return Err(relay.failure("SSH relay ended before opening its connection"));
        }
        if start.elapsed() > Duration::from_secs(10) {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "SSH relay did not start",
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    match crate::inline::view(&approval.socket, approval.open.clone(), &approval.context) {
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::UnexpectedEof
                    | io::ErrorKind::BrokenPipe
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::NotConnected
            ) =>
        {
            Err(relay.failure("SSH transport ended"))
        }
        result => result,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn routes_only_interactive_shells() {
        for args in [vec!["host"], vec!["-p", "2222", "-J", "jump", "user@host"]] {
            assert!(interactive(
                &args.into_iter().map(String::from).collect::<Vec<_>>()
            ));
        }
        for args in [
            vec!["host", "ls"],
            vec!["-N", "host"],
            vec!["-L", "80:x:80", "host"],
            vec!["-T", "host"],
            vec!["-o", "RemoteCommand=ls", "host"],
        ] {
            assert!(!interactive(
                &args.into_iter().map(String::from).collect::<Vec<_>>()
            ));
        }
    }
}
