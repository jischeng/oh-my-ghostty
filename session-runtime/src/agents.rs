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
        aliases: &["claude-code", "claude_code"],
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

/// Canonicalizes a known agent identifier, executable name, or alias (such as
/// `"claude-code"` -> `"claude"` or `"agy"` -> `"antigravity"`), returning `None`
/// for unknown third-party `app` names so callers can preserve them verbatim.
pub fn canonicalize_app(raw: &str) -> Option<&'static str> {
    resolve(raw).map(|spec| spec.id)
}

pub fn is_shell_executable(raw: &str) -> bool {
    let trimmed = raw.trim();
    let base = trimmed
        .rsplit('/')
        .next()
        .unwrap_or(trimmed)
        .trim_start_matches('-');
    matches!(
        base,
        "sh" | "bash"
            | "zsh"
            | "fish"
            | "dash"
            | "ksh"
            | "mksh"
            | "oksh"
            | "tcsh"
            | "csh"
            | "nu"
            | "nushell"
            | "elvish"
            | "xonsh"
            | "pwsh"
    )
}

/// Resolves an executable path string (from `proc_pidpath`, `/proc/<pid>/exe`,
/// `argv[0]`, or a script entrypoint) to a known `AgentSpec`.
/// Recognizes standalone versioned Claude Code binaries (`.../claude/versions/<ver>`),
/// npm/bun `@anthropic-ai/claude-code` entrypoints, and direct executables/symlinks.
pub fn resolve_path_str(raw_path: &str) -> Option<&'static AgentSpec> {
    let trimmed = raw_path.trim();
    if trimmed.is_empty() {
        return None;
    }
    let segments: Vec<&str> = trimmed.split('/').filter(|s| !s.is_empty()).collect();
    let last = segments.last().copied()?.trim_start_matches('-');
    if last.is_empty() || is_shell_executable(last) || last.eq_ignore_ascii_case("login") {
        return None;
    }
    if let Some(spec) = resolve(last) {
        return Some(spec);
    }
    let n = segments.len();
    if n >= 3
        && segments[n - 2].eq_ignore_ascii_case("versions")
        && (segments[n - 3].eq_ignore_ascii_case("claude")
            || segments[n - 3].eq_ignore_ascii_case("claude-code"))
    {
        return resolve("claude");
    }
    if segments.windows(2).any(|w| {
        w[0].eq_ignore_ascii_case("@anthropic-ai") && w[1].eq_ignore_ascii_case("claude-code")
    }) {
        return resolve("claude");
    }
    None
}

pub fn resolve_executable_path(path: &Path) -> Option<&'static AgentSpec> {
    resolve_path_str(&path.to_string_lossy())
}

/// Resolves a process `argv` slice to a known `AgentSpec`, handling login-prefixed
/// `argv[0]` (`-claude`), `/usr/bin/env`, and JS/Python runtime wrappers while
/// strictly excluding shells (`/bin/sh -c ...`) and inline eval (`python3 -c ...`).
pub fn resolve_process_argv(argv: &[String]) -> Option<&'static AgentSpec> {
    let first = argv.first()?.trim();
    if first.is_empty() {
        return None;
    }
    let base0 = first
        .rsplit('/')
        .next()
        .unwrap_or(first)
        .trim_start_matches('-');
    if base0.is_empty() || is_shell_executable(base0) || base0.eq_ignore_ascii_case("login") {
        return None;
    }
    if let Some(spec) = resolve_path_str(first) {
        return Some(spec);
    }
    if base0.eq_ignore_ascii_case("env") {
        let mut idx = 1;
        while idx < argv.len() {
            let arg = argv[idx].as_str();
            if arg == "--" {
                idx += 1;
                break;
            }
            if matches!(arg, "-u" | "--unset" | "-C" | "--chdir") {
                idx += 2;
                continue;
            }
            if arg.starts_with('-') || arg.contains('=') {
                idx += 1;
                continue;
            }
            break;
        }
        return argv.get(idx..).and_then(resolve_process_argv);
    }
    let base0_lower = base0.to_ascii_lowercase();
    if matches!(
        base0_lower.as_str(),
        "node" | "nodejs" | "bun" | "deno" | "python" | "python3"
    ) || base0_lower.starts_with("python3.")
    {
        let mut idx = 1;
        while idx < argv.len() {
            let arg = argv[idx].as_str();
            if arg == "--" {
                return argv.get(idx + 1).and_then(|s| resolve_path_str(s));
            }
            if matches!(arg, "-e" | "--eval" | "-p" | "--print" | "-c" | "-m") {
                return None;
            }
            if matches!(
                arg,
                "-r" | "--require" | "--import" | "--loader" | "--conditions" | "--input-type"
            ) {
                idx += 2;
                continue;
            }
            if arg.starts_with('-') {
                idx += 1;
                continue;
            }
            return resolve_path_str(arg);
        }
    }
    None
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonicalize_app_maps_known_aliases_and_preserves_unknown_apps() {
        assert_eq!(canonicalize_app("claude-code"), Some("claude"));
        assert_eq!(canonicalize_app("CLAUDE-CODE"), Some("claude"));
        assert_eq!(canonicalize_app("claude_code"), Some("claude"));
        assert_eq!(canonicalize_app("claude"), Some("claude"));
        assert_eq!(canonicalize_app("agy"), Some("antigravity"));
        assert_eq!(canonicalize_app("jetski-cli"), Some("antigravity"));
        assert_eq!(canonicalize_app("openai-codex"), Some("codex"));
        assert_eq!(canonicalize_app("oh-my-pi"), Some("omp"));
        assert_eq!(canonicalize_app("qodercli"), Some("qoder"));
        assert_eq!(canonicalize_app("cargo"), None);
        assert_eq!(canonicalize_app("terraform"), None);
        assert_eq!(canonicalize_app("my-custom-tool"), None);
        assert_eq!(canonicalize_app(""), None);
    }

    #[test]
    fn executable_and_argv_detection_handles_versioned_claude_mach_o_and_rejects_shells() {
        let vec_str = |items: &[&str]| items.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();

        assert_eq!(
            resolve_executable_path(Path::new(
                "/Users/alice/.local/share/claude/versions/2.1.331"
            ))
            .map(|s| s.id),
            Some("claude")
        );
        assert_eq!(
            resolve_executable_path(Path::new("/opt/claude-code/versions/2.2.0-beta.1"))
                .map(|s| s.id),
            Some("claude")
        );
        assert_eq!(
            resolve_executable_path(Path::new("/Users/alice/.local/bin/claude")).map(|s| s.id),
            Some("claude")
        );
        assert_eq!(
            resolve_executable_path(Path::new("/Users/alice/.local/bin/agy")).map(|s| s.id),
            Some("antigravity")
        );
        assert!(resolve_executable_path(Path::new("/bin/sh")).is_none());
        assert!(resolve_executable_path(Path::new("/usr/bin/login")).is_none());
        assert!(resolve_executable_path(Path::new(
            "/Users/alice/.local/share/claude/versions/zsh"
        ))
        .is_none());

        assert_eq!(
            resolve_process_argv(&vec_str(&[
                "claude",
                "--dangerously-skip-permissions",
                "--resume",
                "b02999d0-9406-46f5-801e-d6f4bb34cd2f"
            ]))
            .map(|s| s.id),
            Some("claude")
        );
        assert_eq!(
            resolve_process_argv(&vec_str(&["-claude", "--continue"])).map(|s| s.id),
            Some("claude")
        );
        assert_eq!(
            resolve_process_argv(&vec_str(&[
                "/Users/alice/.local/share/claude/versions/2.1.331",
                "--resume",
                "abc"
            ]))
            .map(|s| s.id),
            Some("claude")
        );
        assert_eq!(
            resolve_process_argv(&vec_str(&[
                "/opt/homebrew/bin/node",
                "--no-warnings",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
            ]))
            .map(|s| s.id),
            Some("claude")
        );
        assert_eq!(
            resolve_process_argv(&vec_str(&[
                "/usr/bin/env",
                "-u",
                "CLAUDECODE",
                "FOO=1",
                "claude"
            ]))
            .map(|s| s.id),
            Some("claude")
        );

        // Hook shells and inline script eval must never be misclassified as agents.
        assert!(
            resolve_process_argv(&vec_str(&["/bin/sh", "-c", "omgd report claude working"]))
                .is_none()
        );
        assert!(resolve_process_argv(&vec_str(&["-/bin/zsh", "-l"])).is_none());
        assert!(resolve_process_argv(&vec_str(&["python3", "-c", "print('claude')"])).is_none());
        assert!(resolve_process_argv(&vec_str(&["node", "-e", "claude"])).is_none());
    }
}
