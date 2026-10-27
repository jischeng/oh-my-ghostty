//! Read remote cwd from the process actually owning this PTY. No client paths.
use std::{io, path::PathBuf};
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
#[cfg(test)]
mod tests {
    #[test]
    fn reads_current_process_directory() {
        assert_eq!(
            super::process_cwd(std::process::id() as i32).unwrap(),
            std::env::current_dir().unwrap()
        );
    }
}
