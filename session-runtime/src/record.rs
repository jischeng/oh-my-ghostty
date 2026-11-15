//! Durable metadata is separate from current process/PTY state.
use crate::lifecycle::{unix_time, EndReason, Policy};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Resume {
    pub agent: String,
    pub conversation_id: String,
    pub cwd: String,
}
impl Resume {
    pub fn validate(&self) -> io::Result<()> {
        if crate::agents::resolve(&self.agent).is_none()
            || self.conversation_id.is_empty()
            || self.conversation_id.len() > 128
            || self.conversation_id.starts_with('-')
            || !self
                .conversation_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            || !self.cwd.starts_with('/')
            || self.cwd.len() > 4096
            || self.cwd.contains('\0')
        {
            return Err(io::Error::other("invalid Agent recovery descriptor"));
        }
        Ok(())
    }
    pub fn arguments(&self) -> io::Result<Vec<String>> {
        self.validate()?;
        let spec = crate::agents::resolve(&self.agent)
            .ok_or_else(|| io::Error::other("invalid Agent recovery descriptor"))?;
        if spec.resume_args.is_empty() {
            return Err(io::Error::other(
                "Agent does not support conversation recovery",
            ));
        }
        let mut argv = Vec::with_capacity(1 + spec.resume_args.len());
        argv.push(spec.command.to_owned());
        for arg in spec.resume_args {
            argv.push(arg.replace("{id}", &self.conversation_id));
        }
        Ok(argv)
    }
    /// Hooks alone don't prove the conversation has been flushed to disk.
    pub fn store_exists(&self) -> bool {
        self.store_exists_in_home(None)
    }

    pub fn store_exists_in_home(&self, home: Option<&Path>) -> bool {
        if self.validate().is_err() {
            return false;
        }
        let Some(spec) = crate::agents::resolve(&self.agent) else {
            return false;
        };
        let resolved_home;
        let home_dir = match home {
            Some(path) => path,
            None => {
                let Some(env_home) = std::env::var_os("HOME") else {
                    return false;
                };
                resolved_home = PathBuf::from(env_home);
                &resolved_home
            }
        };
        crate::agents::store_exists(spec, home_dir, &self.conversation_id)
    }
}

pub fn current_boot_time() -> Option<u64> {
    #[cfg(target_os = "macos")]
    {
        let mut mib = [libc::CTL_KERN, libc::KERN_BOOTTIME];
        let mut tv = libc::timeval {
            tv_sec: 0,
            tv_usec: 0,
        };
        let mut size = std::mem::size_of::<libc::timeval>();
        let rc = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                mib.len() as _,
                (&mut tv as *mut libc::timeval).cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        (rc == 0 && size == std::mem::size_of::<libc::timeval>() && tv.tv_sec > 0)
            .then_some(tv.tv_sec as u64)
    }
    #[cfg(target_os = "linux")]
    {
        let stat = fs::read_to_string("/proc/stat").ok()?;
        for line in stat.lines() {
            if let Some(rest) = line.strip_prefix("btime ") {
                if let Ok(value) = rest.trim().parse::<u64>() {
                    if value > 0 {
                        return Some(value);
                    }
                }
            }
        }
        None
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        None
    }
}

pub fn is_prior_boot(recorded: Option<u64>, current: Option<u64>) -> bool {
    match (recorded, current) {
        (Some(rec), Some(cur)) => cur > rec.saturating_add(5),
        _ => false,
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Record {
    pub version: u32,
    pub id: String,
    pub generation: String,
    pub created_at: u64,
    pub updated_at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<crate::location::SshTarget>,
    pub pid: Option<u32>,
    pub ended: Option<EndReason>,
    pub resume: Option<Resume>,
    pub policy: Policy,
    #[serde(default)]
    pub contained: bool,
    /// Authenticates broker adoption of a detached local session holder.
    #[serde(default)]
    pub holder_capability: Option<String>,
    #[serde(default)]
    pub inline_viewer: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub boot_time: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot_revision: Option<String>,
}
impl Record {
    pub fn new(id: &str, policy: Policy) -> io::Result<Self> {
        let now = unix_time();
        Ok(Self {
            version: 1,
            id: id.into(),
            generation: nonce()?,
            created_at: now,
            updated_at: now,
            cwd: None,
            ssh: None,
            pid: None,
            ended: None,
            resume: None,
            policy,
            contained: false,
            holder_capability: None,
            inline_viewer: false,
            boot_time: current_boot_time(),
            snapshot_revision: crate::current_snapshot_revision(),
        })
    }
    pub fn load(path: &Path) -> io::Result<Self> {
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        if file.metadata()?.len() > 64 * 1024 {
            return Err(io::Error::other("session record too large"));
        }
        let mut data = vec![];
        file.read_to_end(&mut data)?;
        let value: Self = serde_json::from_slice(&data)?;
        if value.version != 1 || !crate::host::valid_id(&value.id) {
            return Err(io::Error::other("invalid session record"));
        }
        value.policy.validate()?;
        if value
            .cwd
            .as_ref()
            .is_some_and(|cwd| !cwd.starts_with('/') || cwd.len() > 4096 || cwd.contains('\0'))
        {
            return Err(io::Error::other("invalid session working directory"));
        }
        if value.holder_capability.as_deref().is_some_and(|token| {
            token.len() != 32 || !token.bytes().all(|byte| byte.is_ascii_hexdigit())
        }) {
            return Err(io::Error::other("invalid local holder capability"));
        }
        if let Some(r) = &value.resume {
            r.validate()?;
        }
        Ok(value)
    }
    pub fn save(&mut self, path: &Path) -> io::Result<()> {
        self.updated_at = unix_time();
        let data = serde_json::to_vec(self)?;
        let temporary = path.with_extension(format!("{}.tmp", nonce()?));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(&data)?;
            file.sync_all()?;
            fs::rename(&temporary, path)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result
    }
}

/// Bounded, secret-free record projection for the on-demand session catalogue.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SessionSummary {
    pub id: String,
    pub generation: String,
    pub created_at: u64,
    pub updated_at: u64,
    pub pid: Option<u32>,
    pub ended: Option<EndReason>,
    pub resume: Option<Resume>,
    pub policy: Policy,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<crate::location::SshTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activity: Option<crate::activity::Snapshot>,
}

impl From<&Record> for SessionSummary {
    fn from(record: &Record) -> Self {
        Self {
            id: record.id.clone(),
            generation: record.generation.clone(),
            created_at: record.created_at,
            updated_at: record.updated_at,
            pid: record.pid,
            ended: record.ended,
            resume: record.resume.clone(),
            policy: record.policy.clone(),
            cwd: record
                .cwd
                .clone()
                .or_else(|| record.resume.as_ref().map(|resume| resume.cwd.clone())),
            ssh: record.ssh.clone().or_else(|| {
                if record.ended.is_none() {
                    record
                        .pid
                        .filter(|&p| p > 0)
                        .and_then(crate::location::leader_ssh)
                } else {
                    None
                }
            }),
            activity: None,
        }
    }
}

pub fn nonce() -> io::Result<String> {
    let mut b = [0u8; 16];
    File::open("/dev/urandom")?.read_exact(&mut b)?;
    Ok(b.iter().map(|v| format!("{v:02x}")).collect())
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AgentEvent {
    pub token: String,
    pub generation: String,
    pub pid: i32,
    pub group: i32,
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<Resume>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attention: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tier: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_pid: Option<i32>,
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_arguments_are_typed_and_never_shell_evaluated() {
        let mut r = Resume {
            agent: "codex".into(),
            conversation_id: "test-123".into(),
            cwd: "/tmp/project".into(),
        };
        assert_eq!(r.arguments().unwrap(), ["codex", "resume", "test-123"]);
        r.conversation_id = "x;touch /tmp/bad".into();
        assert!(r.arguments().is_err());
    }

    #[test]
    fn catalogue_summary_omits_private_holder_and_launch_data() {
        let mut record =
            Record::new("11111111-1111-1111-1111-111111111111", Policy::default()).unwrap();
        record.holder_capability = Some("0123456789abcdef0123456789abcdef".into());
        record.cwd = Some("/tmp/live".into());
        let value = serde_json::to_value(SessionSummary::from(&record)).unwrap();
        assert_eq!(value["cwd"], "/tmp/live");
        assert!(value.get("holder_capability").is_none());
        assert!(value.get("argv").is_none());
        assert!(value.get("env").is_none());
    }

    #[test]
    fn boot_time_detection_and_legacy_record_deserialization() {
        assert!(current_boot_time().is_some());
        assert!(!is_prior_boot(None, current_boot_time()));
        assert!(!is_prior_boot(Some(1_000), None));
        assert!(!is_prior_boot(Some(1_000), Some(1_000)));
        assert!(!is_prior_boot(Some(1_000), Some(1_005)));
        assert!(is_prior_boot(Some(1_000), Some(1_006)));

        let legacy_json = serde_json::json!({
            "version": 1,
            "id": "11111111-1111-1111-1111-111111111111",
            "generation": "gen-1",
            "created_at": 100,
            "updated_at": 200,
            "pid": null,
            "ended": "lost",
            "resume": null,
            "policy": {},
            "future_unknown_field": true
        });
        let record: Record = serde_json::from_value(legacy_json).unwrap();
        assert_eq!(record.boot_time, None);
        assert_eq!(record.snapshot_revision, None);
        assert_eq!(record.ended, Some(EndReason::Lost));
    }
}
