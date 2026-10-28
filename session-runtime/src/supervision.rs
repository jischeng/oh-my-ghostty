//! Optional systemd user supervision: one service per runtime directory, never
//! one service/process per session. Its cgroup owns every session subgroup.
use std::{
    io,
    path::Path,
    process::{Command, Stdio},
};

pub fn start(root: &Path, shell: &str) -> io::Result<bool> {
    if !cfg!(target_os = "linux") || !Path::new("/sys/fs/cgroup/cgroup.controllers").exists() {
        return Ok(false);
    }
    let system = unsafe { libc::geteuid() } == 0;
    let available = Command::new("systemctl")
        .args(if system {
            vec!["show", "--property=Version"]
        } else {
            vec!["--user", "show-environment"]
        })
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    if !available {
        return Ok(false);
    }
    // A user manager without linger may stop on final SSH logout. Do not
    // silently weaken detached-session lifetime or change system login policy.
    let linger = Command::new("loginctl")
        .args([
            "show-user",
            &unsafe { libc::geteuid() }.to_string(),
            "--property=Linger",
            "--value",
        ])
        .output()
        .is_ok_and(|out| out.status.success() && out.stdout == b"yes\n");
    if !system && !linger {
        return Ok(false);
    }
    use sha2::{Digest, Sha256};
    let identity = format!("{:x}", Sha256::digest(root.as_os_str().as_encoded_bytes()));
    let unit = format!("omg-runtime-{}.service", &identity[..24]);
    let mut launch = Command::new("systemd-run");
    if !system {
        launch.arg("--user");
    } else if let Ok(context) = std::fs::read_to_string("/proc/self/attr/current") {
        // Preserve the authenticated root login's existing SELinux domain.
        // Do not relabel user files, disable enforcement or install policy.
        let context = context.trim_matches(|c: char| c == '\0' || c.is_whitespace());
        if context.contains(':') && !context.contains('\n') {
            launch.arg(format!("--property=SELinuxContext={context}"));
        }
    }
    let status = launch
        .args([
            "--quiet",
            "--collect",
            "--unit",
            &unit,
            "--property=Type=exec",
            "--property=Delegate=yes",
            "--property=KillMode=control-group",
            "--property=TimeoutStopSec=10s",
            "--property=SendSIGKILL=yes",
            "--property=Restart=no",
            "--setenv=OMG_RUNTIME_SUPERVISED=1",
        ])
        .arg(format!(
            "--working-directory={}",
            std::env::var("HOME").unwrap_or_else(|_| "/".into())
        ))
        .arg(format!(
            "--setenv=HOME={}",
            std::env::var("HOME").unwrap_or_default()
        ))
        .arg(format!(
            "--setenv=PATH={}",
            std::env::var("PATH").unwrap_or_default()
        ))
        .arg(format!("--setenv=SHELL={shell}"))
        .arg("--")
        // Enter the login SELinux domain via a system-labelled executable;
        // arguments stay positional, never interpolated into shell source.
        .args(["/bin/sh", "-c", "exec \"$@\"", "omg-runtime"])
        .arg(std::env::current_exe()?)
        .arg("host")
        .arg(root)
        .args(["--", shell, "-l"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .status()?;
    if !status.success() {
        // A concurrent launcher may already have started this unit. Do not
        // escape supervision by silently starting a second unmanaged host.
        let mut check = Command::new("systemctl");
        if !system {
            check.arg("--user");
        }
        let active = check.args(["is-active", "--quiet", &unit]).status()?;
        if !active.success() {
            return Err(io::Error::other("cannot start supervised runtime"));
        }
    }
    Ok(true)
}
