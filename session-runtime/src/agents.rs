//! Canonical registry of OMG-supported coding agents shared across daemon,
//! recovery, activity reduction, and mobile control planes.
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StoreKind {
    /// Recursively searches `<home>/<root>` (and optional additional roots) for `*{id}.jsonl`.
    Discover(&'static [&'static str]),
    /// Searches `<home>/<root>` up to bounded depth for `{id}{suffix}` (or `*_{id}{suffix}`).
    Pattern {
        root: &'static str,
        suffix: &'static str,
        wildcard_prefix: bool,
    },
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct NativeStatusCapabilities {
    /// Whether the agent natively emits OSC 7501 `state=blocked`
    /// (`kind=permission|question`) for attention prompts.
    pub osc7501_blocked: bool,
}

impl NativeStatusCapabilities {
    pub const NONE: Self = Self {
        osc7501_blocked: false,
    };
}

#[derive(Clone, Copy, Debug)]
pub struct AgentSpec {
    pub id: &'static str,
    pub display_name: &'static str,
    pub command: &'static str,
    pub vector_icon: &'static str,
    pub mobile_icon: &'static str,
    pub executables: &'static [&'static str],
    pub aliases: &'static [&'static str],
    pub resume_args: &'static [&'static str],
    pub store: Option<StoreKind>,
    pub native_status: NativeStatusCapabilities,
}

/// All 18 manifest-backed OMG agents plus `aider`.
pub const AGENTS: &[AgentSpec] = &[
    AgentSpec {
        id: "codex",
        display_name: "Codex",
        command: "codex",
        vector_icon: "codex",
        mobile_icon: "codex",
        executables: &["codex"],
        aliases: &["openai-codex"],
        resume_args: &["resume", "{id}"],
        store: Some(StoreKind::Discover(&[
            ".codex/sessions",
            ".codex/archived_sessions",
        ])),
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "claude",
        display_name: "Claude Code",
        command: "claude",
        vector_icon: "claude",
        mobile_icon: "claude",
        executables: &["claude"],
        aliases: &["claude-code"],
        resume_args: &["--resume", "{id}"],
        store: Some(StoreKind::Pattern {
            root: ".claude/projects",
            suffix: ".jsonl",
            wildcard_prefix: false,
        }),
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "pi",
        display_name: "Pi",
        command: "pi",
        vector_icon: "pi",
        mobile_icon: "pi-favicon",
        executables: &["pi"],
        aliases: &["pi-coding-agent"],
        resume_args: &["--session-id", "{id}"],
        store: Some(StoreKind::Pattern {
            root: ".pi/agent/sessions",
            suffix: ".jsonl",
            wildcard_prefix: true,
        }),
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "antigravity",
        display_name: "Antigravity",
        command: "agy",
        vector_icon: "antigravity",
        mobile_icon: "antigravity-favicon",
        executables: &["agy"],
        aliases: &["jetski", "jetski-cli", "antigravity-cli", "gemini"],
        resume_args: &["--conversation", "{id}"],
        store: Some(StoreKind::Pattern {
            root: ".gemini/antigravity-cli/conversations",
            suffix: ".db",
            wildcard_prefix: false,
        }),
        native_status: NativeStatusCapabilities {
            osc7501_blocked: true,
        },
    },
    AgentSpec {
        id: "opencode",
        display_name: "OpenCode",
        command: "opencode",
        vector_icon: "opencode",
        mobile_icon: "opencode-favicon",
        executables: &["opencode"],
        aliases: &[],
        resume_args: &["--session", "{id}"],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "cursor",
        display_name: "Cursor Agent",
        command: "cursor-agent",
        vector_icon: "cursor",
        mobile_icon: "cursor-favicon",
        executables: &["cursor-agent"],
        aliases: &[],
        resume_args: &[],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "copilot",
        display_name: "Copilot",
        command: "copilot",
        vector_icon: "copilot",
        mobile_icon: "copilot-favicon",
        executables: &["copilot"],
        aliases: &["github-copilot-cli", "gh-copilot"],
        resume_args: &[],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "droid",
        display_name: "Droid",
        command: "droid",
        vector_icon: "droid",
        mobile_icon: "droid-favicon",
        executables: &["droid"],
        aliases: &[],
        resume_args: &[],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "grok",
        display_name: "Grok",
        command: "grok",
        vector_icon: "grok",
        mobile_icon: "grok",
        executables: &["grok"],
        aliases: &[],
        resume_args: &["--resume", "{id}"],
        store: Some(StoreKind::Pattern {
            root: ".grok/sessions",
            suffix: "",
            wildcard_prefix: false,
        }),
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "qwen",
        display_name: "Qwen Code",
        command: "qwen",
        vector_icon: "qwen",
        mobile_icon: "qwen-favicon",
        executables: &["qwen"],
        aliases: &["qwen-code"],
        resume_args: &["--resume", "{id}"],
        store: Some(StoreKind::Pattern {
            root: ".qwen/tmp",
            suffix: ".jsonl",
            wildcard_prefix: false,
        }),
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "amp",
        display_name: "Amp",
        command: "amp",
        vector_icon: "amp",
        mobile_icon: "amp-favicon",
        executables: &["amp"],
        aliases: &[],
        resume_args: &[],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "cline",
        display_name: "Cline",
        command: "cline",
        vector_icon: "cline",
        mobile_icon: "cline-favicon",
        executables: &["cline"],
        aliases: &[],
        resume_args: &[],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "kimi",
        display_name: "Kimi",
        command: "kimi",
        vector_icon: "kimi",
        mobile_icon: "kimi-favicon",
        executables: &["kimi"],
        aliases: &["kimi-code"],
        resume_args: &[],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "hermes",
        display_name: "Hermes",
        command: "hermes",
        vector_icon: "hermes",
        mobile_icon: "hermes-favicon",
        executables: &["hermes"],
        aliases: &[],
        resume_args: &["--resume", "{id}"],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "crush",
        display_name: "Crush",
        command: "crush",
        vector_icon: "crush",
        mobile_icon: "crush-favicon",
        executables: &["crush"],
        aliases: &[],
        resume_args: &[],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "qoder",
        display_name: "Qoder CLI",
        command: "qodercli",
        vector_icon: "qoder",
        mobile_icon: "qoder",
        executables: &["qodercli", "qoder"],
        aliases: &[],
        resume_args: &["--resume", "{id}"],
        store: Some(StoreKind::Pattern {
            root: ".qoder/projects",
            suffix: ".jsonl",
            wildcard_prefix: false,
        }),
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "reasonix",
        display_name: "Reasonix",
        command: "reasonix",
        vector_icon: "reasonix",
        mobile_icon: "reasonix",
        executables: &["reasonix"],
        aliases: &[],
        resume_args: &["--resume", "{id}"],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "omp",
        display_name: "OMP",
        command: "omp",
        vector_icon: "omp",
        mobile_icon: "omp-favicon",
        executables: &["omp"],
        aliases: &["oh-my-pi"],
        resume_args: &["--resume={id}"],
        store: Some(StoreKind::Pattern {
            root: ".omp/agent/sessions",
            suffix: ".jsonl",
            wildcard_prefix: true,
        }),
        native_status: NativeStatusCapabilities::NONE,
    },
    AgentSpec {
        id: "aider",
        display_name: "Aider",
        command: "aider",
        vector_icon: "aider",
        mobile_icon: "aider",
        executables: &["aider"],
        aliases: &["aider-chat"],
        resume_args: &[],
        store: None,
        native_status: NativeStatusCapabilities::NONE,
    },
];

/// Returns whether the resolved agent natively emits OSC 7501 `state=blocked`
/// attention states.
pub fn native_supports_blocked(raw: &str) -> bool {
    resolve(raw).is_some_and(|spec| spec.native_status.osc7501_blocked)
}

/// Resolves a raw agent identifier, executable name, or alias to its canonical `AgentSpec`.
pub fn resolve(raw: &str) -> Option<&'static AgentSpec> {
    let normalized = raw.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        return None;
    }
    AGENTS.iter().find(|spec| {
        spec.id == normalized
            || spec.command == normalized
            || spec.executables.contains(&normalized.as_str())
            || spec.aliases.contains(&normalized.as_str())
    })
}

/// Normalizes an agent string to its canonical OMG `id` if recognized, or sanitized lowercase.
pub fn normalize_id(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(spec) = resolve(trimmed) {
        return Some(spec.id.to_owned());
    }
    let lowered = trimmed.to_ascii_lowercase();
    if lowered.len() <= 32
        && lowered
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    {
        Some(lowered)
    } else {
        None
    }
}

pub fn store_exists(spec: &AgentSpec, home: &Path, conversation_id: &str) -> bool {
    if spec.resume_args.is_empty() || conversation_id.is_empty() {
        return false;
    }
    match spec.store {
        Some(StoreKind::Discover(roots)) => {
            let needle = format!("{conversation_id}.jsonl");
            roots
                .iter()
                .any(|root| search_tree(&home.join(root), 0, &needle, true, false))
        }
        Some(StoreKind::Pattern {
            root,
            suffix,
            wildcard_prefix,
        }) => {
            let exact = format!("{conversation_id}{suffix}");
            let wildcard = wildcard_prefix.then(|| format!("_{conversation_id}{suffix}"));
            search_pattern(
                &home.join(root),
                0,
                &exact,
                wildcard.as_deref(),
                suffix.is_empty(),
            )
        }
        None => true,
    }
}

fn search_tree(
    dir: &Path,
    depth: usize,
    needle: &str,
    substring_jsonl: bool,
    allow_dir: bool,
) -> bool {
    if depth > 6 {
        return false;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    for entry in entries.flatten().take(4096) {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_symlink() {
            continue;
        }
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        if file_type.is_file() || (allow_dir && file_type.is_dir()) {
            let matched = if substring_jsonl {
                name.ends_with(".jsonl") && name.contains(needle)
            } else {
                name == needle
            };
            if matched && entry.metadata().is_ok_and(|m| m.is_dir() || m.len() > 0) {
                return true;
            }
        }
        if file_type.is_dir() && search_tree(&path, depth + 1, needle, substring_jsonl, allow_dir) {
            return true;
        }
    }
    false
}

fn search_pattern(
    dir: &Path,
    depth: usize,
    exact: &str,
    wildcard_suffix: Option<&str>,
    allow_dir: bool,
) -> bool {
    if depth > 6 {
        return false;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    for entry in entries.flatten().take(4096) {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_symlink() {
            continue;
        }
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        if (file_type.is_file() || (allow_dir && file_type.is_dir()))
            && (name == exact || wildcard_suffix.is_some_and(|w| name.ends_with(w)))
            && entry.metadata().is_ok_and(|m| m.is_dir() || m.len() > 0)
        {
            return true;
        }
        if file_type.is_dir() && search_pattern(&path, depth + 1, exact, wildcard_suffix, allow_dir)
        {
            return true;
        }
    }
    false
}
