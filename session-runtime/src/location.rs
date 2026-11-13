//! Read remote cwd and active SSH targets from the process owning this PTY.
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    io,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex, OnceLock,
    },
    time::{Duration, Instant},
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
                        || (lower.starts_with("remotecommand=") && lower != "remotecommand=none")
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
        "ghostty" | "omg" if argv.get(1).map(String::as_str) == Some("+ssh") => {
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

static SESSION_PIDS_SCANS: AtomicUsize = AtomicUsize::new(0);

#[cfg(test)]
fn session_pids_scan_count() -> usize {
    SESSION_PIDS_SCANS.load(Ordering::SeqCst)
}

fn tty_foreground_pgid(pid: i32) -> Option<i32> {
    if pid <= 1 {
        return None;
    }
    #[cfg(target_os = "macos")]
    {
        unsafe extern "C" {
            fn omg_tty_foreground_pgid(pid: i32) -> i32;
        }
        let pgid = unsafe { omg_tty_foreground_pgid(pid) };
        (pgid > 1).then_some(pgid)
    }
    #[cfg(target_os = "linux")]
    {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let rest = stat.get(stat.rfind(')')? + 1..)?.trim_start();
        let mut fields = rest.split_whitespace();
        let tty_nr: i32 = fields.nth(4)?.parse().ok()?;
        let tpgid: i32 = fields.next()?.parse().ok()?;
        (tty_nr != 0 && tpgid > 1).then_some(tpgid)
    }
}

fn session_pids(leader: i32) -> Vec<i32> {
    if leader <= 1 {
        return Vec::new();
    }
    SESSION_PIDS_SCANS.fetch_add(1, Ordering::SeqCst);
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

const SSH_CACHE_REFRESH: Duration = Duration::from_secs(2);
const MAX_SSH_CACHE_ENTRIES: usize = 512;

#[derive(Clone)]
struct CachedSshState {
    fg_pgid: i32,
    session_scanned: bool,
    checked_at: Instant,
    target: Option<SshTarget>,
}

static SSH_STATE_CACHE: OnceLock<Mutex<HashMap<u32, CachedSshState>>> = OnceLock::new();

fn ssh_state_cache() -> &'static Mutex<HashMap<u32, CachedSshState>> {
    SSH_STATE_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn group_ssh_target(pgid: i32) -> Option<SshTarget> {
    for pid in group_pids(pgid) {
        if let Some(argv) = process_argv(pid) {
            if let Some(target) = parse_ssh_argv(&argv) {
                return Some(target);
            }
        }
    }
    None
}

fn session_ssh_for_group(leader: u32, fg_pgid: i32) -> Option<SshTarget> {
    let leader_pid = leader as i32;
    if leader_pid <= 1 || fg_pgid <= 1 {
        return None;
    }

    let previous = {
        let cache = ssh_state_cache().lock().unwrap();
        cache
            .get(&leader)
            .filter(|entry| entry.fg_pgid == fg_pgid)
            .cloned()
    };
    let refresh = if fg_pgid == leader_pid {
        Duration::from_secs(1)
    } else {
        SSH_CACHE_REFRESH
    };
    if let Some(entry) = &previous {
        if entry.checked_at.elapsed() < refresh {
            return entry.target.clone();
        }
    }

    // When the session leader itself owns the foreground process group (e.g. an
    // idle login shell with no foreground job, or a direct `ssh` leader), there
    // cannot be an interactive foreground `ssh` child in another group. Check
    // only the leader's own argv in O(1) and never scan `PROC_ALL_PIDS`.
    let (session_scanned, target) = if fg_pgid == leader_pid {
        (
            true,
            process_argv(leader_pid).as_deref().and_then(parse_ssh_argv),
        )
    } else {
        let mut scanned = previous.as_ref().is_some_and(|e| e.session_scanned);
        let mut found_target = group_ssh_target(fg_pgid);
        if found_target.is_none() && !scanned {
            scanned = true;
            for pid in session_pids(leader_pid) {
                if let Some(argv) = process_argv(pid) {
                    if let Some(found) = parse_ssh_argv(&argv) {
                        found_target = Some(found);
                        break;
                    }
                }
            }
        }
        (scanned, found_target)
    };

    let mut cache = ssh_state_cache().lock().unwrap();
    if cache.len() >= MAX_SSH_CACHE_ENTRIES && !cache.contains_key(&leader) {
        cache.retain(|_, entry| entry.checked_at.elapsed() < Duration::from_secs(60));
        if cache.len() >= MAX_SSH_CACHE_ENTRIES {
            cache.clear();
        }
    }
    cache.insert(
        leader,
        CachedSshState {
            fg_pgid,
            session_scanned,
            checked_at: Instant::now(),
            target: target.clone(),
        },
    );
    target
}

pub fn session_ssh(master: i32, leader: u32) -> Option<SshTarget> {
    let foreground = unsafe { libc::tcgetpgrp(master) };
    session_ssh_for_group(leader, foreground)
}

pub fn leader_ssh(leader: u32) -> Option<SshTarget> {
    let leader_pid = leader as i32;
    if leader_pid <= 1 {
        return None;
    }
    let fg_pgid = tty_foreground_pgid(leader_pid)?;
    session_ssh_for_group(leader, fg_pgid)
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

        let omg_ssh = parse_ssh_argv(&[
            "/Applications/OMG Dev.app/Contents/MacOS/omg".into(),
            "+ssh".into(),
            "--".into(),
            "cloud".into(),
        ])
        .unwrap();
        assert_eq!(omg_ssh.destination, "cloud");

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

    #[test]
    fn session_and_leader_ssh_avoid_proc_all_pids_for_foreground_shell_and_cache_jobs() {
        // Invalid or non-foreground groups return None without any session scan.
        let before_invalid = session_pids_scan_count();
        assert!(session_ssh_for_group(0, 0).is_none());
        assert!(session_ssh_for_group(std::process::id(), -1).is_none());
        assert!(session_ssh_for_group(std::process::id(), std::process::id() as i32).is_none());
        assert_eq!(session_pids_scan_count(), before_invalid);

        // Spawn a real PTY session leader with an interactive shell and verify
        // steady-state polling performs zero PROC_ALL_PIDS scans.
        let mut master: libc::c_int = -1;
        let mut slave: libc::c_int = -1;
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            },
            0
        );
        use std::os::{fd::FromRawFd, unix::process::CommandExt};
        let slave_file = unsafe { std::fs::File::from_raw_fd(slave) };
        let mut cmd = std::process::Command::new("/bin/sh");
        cmd.arg("-c")
            .arg("sleep 5")
            .stdin(slave_file.try_clone().unwrap())
            .stdout(slave_file.try_clone().unwrap())
            .stderr(slave_file);
        unsafe {
            cmd.pre_exec(|| {
                if libc::setsid() < 0 || libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child = cmd.spawn().unwrap();
        let leader = child.id();

        // Wait briefly for setsid + TIOCSCTTY in child.
        for _ in 0..50 {
            if unsafe { libc::tcgetpgrp(master) } == leader as i32 {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(unsafe { libc::tcgetpgrp(master) }, leader as i32);
        assert_eq!(tty_foreground_pgid(leader as i32), Some(leader as i32));

        let scans_before_shell = session_pids_scan_count();
        for _ in 0..10 {
            assert!(session_ssh(master, leader).is_none());
            assert!(leader_ssh(leader).is_none());
        }
        assert_eq!(session_pids_scan_count(), scans_before_shell);

        // Simulate a distinct foreground job group (`fg_pgid != leader`): at most
        // one fallback scan happens on the first miss, and zero on subsequent polls.
        let distinct_pgid = std::process::id() as i32;
        if distinct_pgid != leader as i32 {
            let scans_before_job = session_pids_scan_count();
            assert!(session_ssh_for_group(leader, distinct_pgid).is_none());
            let scans_after_first = session_pids_scan_count();
            assert!(scans_after_first - scans_before_job <= 1);
            for _ in 0..10 {
                assert!(session_ssh_for_group(leader, distinct_pgid).is_none());
            }
            assert_eq!(session_pids_scan_count(), scans_after_first);
        }

        let _ = child.kill();
        let _ = child.wait();
        unsafe {
            libc::close(master);
        }
    }
}
