//! Read remote cwd and active SSH targets from the process owning this PTY.
use serde::{Deserialize, Serialize};
use std::{
    io,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct SshTarget {
    pub destination: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_cwd: Option<String>,
}

pub fn process_cwd(pid: i32) -> io::Result<PathBuf> {
    if pid <= 1 {
        return Err(io::Error::other("invalid process"));
    }
    #[cfg(target_os = "linux")]
    {
        std::fs::read_link(format!("/proc/{pid}/cwd"))
    }
    #[cfg(target_os = "macos")]
    {
        // proc_pidinfo(PROC_PIDVNODEPATHINFO) includes two vnode_info_path
        // structures. Use the system C shim to avoid reproducing SDK layout.
        unsafe extern "C" {
            fn omg_process_cwd(pid: i32, buf: *mut u8, len: usize) -> i32;
        }
        let mut bytes = vec![0u8; 4096];
        let count = unsafe { omg_process_cwd(pid, bytes.as_mut_ptr(), bytes.len()) };
        if count < 0 {
            return Err(io::Error::last_os_error());
        }
        bytes.truncate(count as usize);
        use std::os::unix::ffi::OsStringExt;
        Ok(std::ffi::OsString::from_vec(bytes).into())
    }
}

pub fn session_cwd(master: i32, leader: u32) -> Option<String> {
    let foreground = unsafe { libc::tcgetpgrp(master) };
    [foreground, leader as i32]
        .into_iter()
        .filter(|p| *p > 1)
        .find_map(|pid| {
            process_cwd(pid)
                .ok()
                .and_then(|p| p.into_os_string().into_string().ok())
        })
        .filter(|p| p.starts_with('/') && p.len() <= 4096 && !p.contains('\0'))
}

pub fn process_argv(pid: i32) -> Option<Vec<String>> {
    if pid <= 1 {
        return None;
    }
    #[cfg(target_os = "linux")]
    {
        let bytes = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
        let args = bytes
            .split(|b| *b == 0)
            .filter(|s| !s.is_empty())
            .map(|s| String::from_utf8_lossy(s).into_owned())
            .collect::<Vec<_>>();
        (!args.is_empty()).then_some(args)
    }
    #[cfg(target_os = "macos")]
    {
        unsafe extern "C" {
            fn omg_process_args(pid: i32, buf: *mut u8, len: usize) -> i32;
        }
        let mut buf = vec![0u8; 32 * 1024];
        let count = unsafe { omg_process_args(pid, buf.as_mut_ptr(), buf.len()) };
        if count < 4 {
            return None;
        }
        buf.truncate(count as usize);
        let argc = i32::from_ne_bytes(buf[0..4].try_into().ok()?) as usize;
        if argc == 0 || argc > 512 {
            return None;
        }
        let mut cursor = 4;
        while cursor < buf.len() && buf[cursor] != 0 {
            cursor += 1;
        }
        while cursor < buf.len() && buf[cursor] == 0 {
            cursor += 1;
        }
        let mut args = Vec::with_capacity(argc.min(64));
        for _ in 0..argc {
            if cursor >= buf.len() {
                break;
            }
            let start = cursor;
            while cursor < buf.len() && buf[cursor] != 0 {
                cursor += 1;
            }
            let arg = std::str::from_utf8(&buf[start..cursor]).ok()?;
            args.push(arg.to_owned());
            cursor += 1;
        }
        (!args.is_empty()).then_some(args)
    }
}

fn extract_cd_prefix(command: &str) -> Option<String> {
    let trimmed = command.trim();
    let rest = trimmed.strip_prefix("cd ")?;
    let (quoted, _) = rest.split_once(" && exec ")?;
    let quoted = quoted.trim();
    if quoted.len() >= 2 && quoted.starts_with('\'') && quoted.ends_with('\'') {
        Some(quoted[1..quoted.len() - 1].replace("'\\''", "'"))
    } else if !quoted.is_empty() {
        Some(quoted.to_owned())
    } else {
        None
    }
}

pub fn parse_ssh_args(args: &[String]) -> Option<SshTarget> {
    const FLAGS: &str = "46AaCfGgKkMNnqsTtVvXxYy";
    const VALUES: &str = "BbcDEeFIiJLlmOoPpQRSWw";
    const NON_INTERACTIVE: &str = "GNOQTVWfns";
    const FORWARD_OPTS: &str = "pFiJlo";

    let mut i = 0;
    let mut forced_tty = false;
    let mut options = Vec::new();
    while i < args.len() {
        let arg = &args[i];
        if arg == "--" {
            i += 1;
            break;
        }
        if !arg.starts_with('-') || arg == "-" {
            break;
        }
        let mut chars = arg[1..].chars();
        while let Some(c) = chars.next() {
            if NON_INTERACTIVE.contains(c) {
                return None;
            }
            if c == 't' {
                forced_tty = true;
            }
            if VALUES.contains(c) {
                let inline = chars.as_str();
                let value = if inline.is_empty() {
                    i += 1;
                    args.get(i)?.as_str()
                } else {
                    inline
                };
                if c == 'o' {
                    let lower = value.trim().to_ascii_lowercase();
                    if lower.starts_with("batchmode=yes")
                        || lower.starts_with("controlmaster=check")
                        || (lower.starts_with("remotecommand=")
                            && lower != "remotecommand=none")
                    {
                        return None;
                    }
                }
                if FORWARD_OPTS.contains(c) {
                    options.push(format!("-{c}"));
                    options.push(value.to_owned());
                }
                break;
            }
            if !FLAGS.contains(c) {
                return None;
            }
            if c == '4' || c == '6' {
                options.push(format!("-{c}"));
            }
        }
        i += 1;
    }
    let destination = args.get(i)?.trim();
    if destination.is_empty() || destination.starts_with('-') || destination.contains('\0') {
        return None;
    }
    let trailing = &args[i + 1..];
    let remote_cwd = if trailing.is_empty() {
        None
    } else if trailing.len() == 1 {
        if let Some(cwd) = extract_cd_prefix(&trailing[0]) {
            Some(cwd)
        } else if forced_tty {
            None
        } else {
            return None;
        }
    } else if forced_tty {
        None
    } else {
        return None;
    };
    Some(SshTarget {
        destination: destination.to_owned(),
        options,
        remote_cwd,
    })
}

pub fn parse_ssh_argv(argv: &[String]) -> Option<SshTarget> {
    let exe = Path::new(argv.first()?).file_name()?.to_str()?;
    match exe {
        "ssh" => parse_ssh_args(&argv[1..]),
        "omgd" => match argv.get(1).map(String::as_str) {
            Some("handoff") if argv.len() >= 4 => parse_ssh_args(&argv[3..]),
            Some("handoff-cwd") if argv.len() >= 5 => {
                let mut target = parse_ssh_args(&argv[4..])?;
                if target.remote_cwd.is_none() && !argv[3].is_empty() {
                    target.remote_cwd = Some(argv[3].clone());
                }
                Some(target)
            }
            _ => None,
        },
        "ghostty" if argv.get(1).map(String::as_str) == Some("+ssh") => {
            if let Some(pos) = argv[2..].iter().position(|a| a == "--") {
                parse_ssh_args(&argv[2 + pos + 1..])
            } else {
                let ssh_args = argv[2..]
                    .iter()
                    .filter(|a| !a.starts_with("--"))
                    .cloned()
                    .collect::<Vec<_>>();
                parse_ssh_args(&ssh_args)
            }
        }
        _ => None,
    }
}

fn group_pids(pgid: i32) -> Vec<i32> {
    if pgid <= 1 {
        return Vec::new();
    }
    #[cfg(target_os = "macos")]
    {
        unsafe extern "C" {
            fn omg_group_pids(pgid: i32, pids: *mut i32, capacity: usize) -> i32;
        }
        let mut pids = vec![0i32; 64];
        let count = unsafe { omg_group_pids(pgid, pids.as_mut_ptr(), pids.len()) };
        if count > 0 {
            pids.truncate(count as usize);
            pids.sort_unstable_by(|a, b| b.cmp(a));
            return pids;
        }
    }
    vec![pgid]
}

fn session_pids(leader: i32) -> Vec<i32> {
    if leader <= 1 {
        return Vec::new();
    }
    #[cfg(target_os = "macos")]
    {
        unsafe extern "C" {
            fn omg_session_pids(leader: i32, pids: *mut i32, capacity: usize) -> i32;
        }
        let mut pids = vec![0i32; 128];
        let count = unsafe { omg_session_pids(leader, pids.as_mut_ptr(), pids.len()) };
        if count > 0 {
            pids.truncate(count as usize);
            pids.sort_unstable_by(|a, b| b.cmp(a));
            return pids;
        }
    }
    #[cfg(target_os = "linux")]
    {
        if let Ok(entries) = std::fs::read_dir("/proc") {
            let mut pids = entries
                .flatten()
                .filter_map(|e| e.file_name().to_str()?.parse::<i32>().ok())
                .filter(|&pid| pid > 1 && unsafe { libc::getsid(pid) } == leader)
                .collect::<Vec<_>>();
            pids.sort_unstable_by(|a, b| b.cmp(a));
            return pids;
        }
    }
    vec![leader]
}

pub fn session_ssh(master: i32, leader: u32) -> Option<SshTarget> {
    let foreground = unsafe { libc::tcgetpgrp(master) };
    if foreground > 1 {
        for pid in group_pids(foreground) {
            if let Some(argv) = process_argv(pid) {
                if let Some(target) = parse_ssh_argv(&argv) {
                    return Some(target);
                }
            }
        }
    }
    leader_ssh(leader)
}

pub fn leader_ssh(leader: u32) -> Option<SshTarget> {
    let leader = leader as i32;
    if leader <= 1 {
        return None;
    }
    for pid in session_pids(leader) {
        if let Some(argv) = process_argv(pid) {
            if let Some(target) = parse_ssh_argv(&argv) {
                return Some(target);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_current_process_directory() {
        assert_eq!(
            super::process_cwd(std::process::id() as i32).unwrap(),
            std::env::current_dir().unwrap()
        );
    }

    #[test]
    fn parses_interactive_ssh_and_handoff_commands() {
        let plain = parse_ssh_argv(&["/usr/bin/ssh".into(), "devbox".into()]).unwrap();
        assert_eq!(plain.destination, "devbox");
        assert!(plain.options.is_empty());
        assert_eq!(plain.remote_cwd, None);

        let with_opts = parse_ssh_argv(&[
            "ssh".into(),
            "-p".into(),
            "2222".into(),
            "-J".into(),
            "bastion".into(),
            "ubuntu@10.0.0.8".into(),
        ])
        .unwrap();
        assert_eq!(with_opts.destination, "ubuntu@10.0.0.8");
        assert_eq!(with_opts.options, vec!["-p", "2222", "-J", "bastion"]);

        let remote_proj = parse_ssh_argv(&[
            "/usr/bin/ssh".into(),
            "-t".into(),
            "prod-api".into(),
            "cd '/srv/app' && exec ${SHELL:-/bin/sh} -l".into(),
        ])
        .unwrap();
        assert_eq!(remote_proj.destination, "prod-api");
        assert_eq!(remote_proj.remote_cwd.as_deref(), Some("/srv/app"));

        let handoff = parse_ssh_argv(&[
            "/Applications/OMG Dev.app/Contents/Resources/session-runtime/omgd".into(),
            "handoff-cwd".into(),
            "/usr/bin/ssh".into(),
            "/home/dev/repo".into(),
            "-p".into(),
            "2200".into(),
            "dev@host".into(),
        ])
        .unwrap();
        assert_eq!(handoff.destination, "dev@host");
        assert_eq!(handoff.options, vec!["-p", "2200"]);
        assert_eq!(handoff.remote_cwd.as_deref(), Some("/home/dev/repo"));

        assert!(parse_ssh_argv(&["ssh".into(), "-N".into(), "devbox".into()]).is_none());
        assert!(parse_ssh_argv(&[
            "ssh".into(),
            "-o".into(),
            "BatchMode=yes".into(),
            "devbox".into()
        ])
        .is_none());
        assert!(parse_ssh_argv(&["ssh".into(), "devbox".into(), "git status".into()]).is_none());
    }
}
