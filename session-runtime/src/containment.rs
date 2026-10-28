//! Linux session ownership beneath a systemd-delegated host service.
//! No PID scans: setsid/double-fork retain membership. Other Unix hosts use
//! the existing process-group cleanup and must not claim cgroup guarantees.
use std::{
    fs, io,
    path::{Path, PathBuf},
};

pub fn host_root() -> io::Result<Option<PathBuf>> {
    if !cfg!(target_os = "linux") || std::env::var_os("OMG_RUNTIME_SUPERVISED").is_none() {
        return Ok(None);
    }
    let membership = fs::read_to_string("/proc/self/cgroup")?;
    let relative = membership
        .lines()
        .find_map(|s| s.strip_prefix("0::"))
        .ok_or_else(|| io::Error::other("supervised runtime requires cgroup v2"))?;
    let current = Path::new("/sys/fs/cgroup").join(relative.trim_start_matches('/'));
    let root = if current.file_name().is_some_and(|n| n == "manager") {
        current.parent().unwrap().to_owned()
    } else {
        let manager = current.join("manager");
        fs::create_dir_all(&manager)?;
        fs::write(manager.join("cgroup.procs"), std::process::id().to_string())?;
        current
    };
    Ok(Some(root))
}

pub struct Group {
    path: PathBuf,
}
impl Group {
    pub fn create(root: &Path, generation: &str) -> io::Result<Self> {
        if generation.is_empty() || !generation.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(io::Error::other("invalid containment generation"));
        }
        let path = root.join(format!("session-{generation}"));
        fs::create_dir(&path)?;
        if !path.join("cgroup.kill").exists() {
            let _ = fs::remove_dir(&path);
            return Err(io::Error::other("kernel does not support cgroup.kill"));
        }
        Ok(Self { path })
    }
    pub fn finish_generation(root: &Path, generation: &str) -> io::Result<()> {
        if generation.is_empty() || !generation.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(io::Error::other("invalid containment generation"));
        }
        let path = root.join(format!("session-{generation}"));
        if !path.exists() {
            return Ok(());
        }
        Self { path }.finish()
    }
    pub fn membership(&self) -> io::Result<fs::File> {
        fs::OpenOptions::new()
            .write(true)
            .open(self.path.join("cgroup.procs"))
    }
    pub fn finish(&self) -> io::Result<()> {
        fs::write(self.path.join("cgroup.kill"), "1")?;
        let start = std::time::Instant::now();
        loop {
            let events = fs::read_to_string(self.path.join("cgroup.events"))?;
            if events.lines().any(|s| s == "populated 0") {
                return Ok(());
            }
            if start.elapsed() > std::time::Duration::from_secs(5) {
                return Err(io::Error::other(
                    "session cgroup still populated after kill",
                ));
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }
}
impl Drop for Group {
    fn drop(&mut self) {
        // Also runs on worker errors/panic. Host SIGKILL is covered by systemd's
        // KillMode=control-group; Drop alone is not a crash supervisor.
        let _ = fs::write(self.path.join("cgroup.kill"), "1");
        let _ = fs::remove_dir(&self.path);
    }
}
