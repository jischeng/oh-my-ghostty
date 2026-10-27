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
        if !matches!(self.agent.as_str(), "codex" | "claude" | "pi")
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
        Ok(match self.agent.as_str() {
            "codex" => vec![
                "codex".into(),
                "resume".into(),
                self.conversation_id.clone(),
            ],
            "claude" => vec![
                "claude".into(),
                "--resume".into(),
                self.conversation_id.clone(),
            ],
            "pi" => vec![
                "pi".into(),
                "--session-id".into(),
                self.conversation_id.clone(),
            ],
            _ => unreachable!(),
        })
    }
    /// Hooks alone don't prove the conversation has been flushed to disk.
    pub fn store_exists(&self) -> bool {
        if self.validate().is_err() {
            return false;
        }
        let Some(home) = std::env::var_os("HOME") else {
            return false;
        };
        let root = PathBuf::from(home).join(match self.agent.as_str() {
            "codex" => ".codex/sessions",
            "claude" => ".claude/projects",
            "pi" => ".pi/agent/sessions",
            _ => return false,
        });
        let mut stack = vec![(root, 0)];
        let mut checked = 0;
        while let Some((dir, depth)) = stack.pop() {
            let Ok(entries) = fs::read_dir(dir) else {
                continue;
            };
            for entry in entries.flatten() {
                checked += 1;
                if checked > 10000 {
                    return false;
                }
                let Ok(kind) = entry.file_type() else {
                    continue;
                };
                if kind.is_dir() && depth < 5 {
                    stack.push((entry.path(), depth + 1));
                }
                if kind.is_file() {
                    let name = entry.file_name();
                    let name = name.to_string_lossy();
                    let suffix = match self.agent.as_str() {
                        "claude" => format!("{}.jsonl", self.conversation_id),
                        "pi" => format!("_{}.jsonl", self.conversation_id),
                        _ => format!("-{}.jsonl", self.conversation_id),
                    };
                    let matches = if self.agent == "claude" {
                        name == suffix
                    } else {
                        name.ends_with(&suffix)
                    };
                    if matches && entry.metadata().is_ok_and(|m| m.len() > 0) {
                        return true;
                    }
                }
            }
        }
        false
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Record {
    pub version: u32,
    pub id: String,
    pub generation: String,
    pub created_at: u64,
    pub updated_at: u64,
    pub pid: Option<u32>,
    pub ended: Option<EndReason>,
    pub resume: Option<Resume>,
    pub policy: Policy,
}
impl Record {
    pub fn new(id: &str, policy: Policy) -> io::Result<Self> {
        Ok(Self {
            version: 1,
            id: id.into(),
            generation: nonce()?,
            created_at: unix_time(),
            updated_at: unix_time(),
            pid: None,
            ended: None,
            resume: None,
            policy,
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
pub fn nonce() -> io::Result<String> {
    let mut b = [0u8; 16];
    File::open("/dev/urandom")?.read_exact(&mut b)?;
    Ok(b.iter().map(|v| format!("{v:02x}")).collect())
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AgentEvent {
    pub token: String,
    pub generation: String,
    pub pid: i32,
    pub group: i32,
    pub state: String,
    pub resume: Resume,
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
}
