//! The same explicit-request editor bridge used by ordinary OMG SSH, scoped
//! to a persistent runtime session rather than to a transient SSH connection.
use crate::{
    deploy::quote,
    lifecycle::unix_time,
    record::{nonce, Record},
};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

const SOURCE: &str = include_str!("../../src/shell-integration/omg/omg.py");

const ZSH_ENV_SCRIPT: &str = r#"if [[ -n "${OMG_REMOTE_ORIG_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$OMG_REMOTE_ORIG_ZDOTDIR"
    'builtin' 'unset' 'OMG_REMOTE_ORIG_ZDOTDIR'
else
    'builtin' 'unset' 'ZDOTDIR'
fi
{
    'builtin' 'typeset' __omg_zshenv=${ZDOTDIR-$HOME}"/.zshenv"
    [[ ! -r "$__omg_zshenv" ]] || 'builtin' 'source' '--' "$__omg_zshenv"
} always {
    'builtin' 'unset' '__omg_zshenv'
    if [[ -o 'interactive' ]]; then
        __omg_remote_draft_precmd() {
            'builtin' 'emulate' '-L' 'zsh'
            precmd_functions=(${precmd_functions:#__omg_remote_draft_precmd})
            'builtin' 'unfunction' '__omg_remote_draft_precmd' 2>/dev/null || true
            if [[ -n "${OMG_REMOTE_DRAFT_EDITOR:-}" && -x "$OMG_REMOTE_DRAFT_EDITOR" ]]; then
                if [[ -n "${VISUAL:-}" && "$VISUAL" != "$OMG_REMOTE_DRAFT_EDITOR" ]]; then
                    'builtin' 'export' OMG_REMOTE_ORIGINAL_EDITOR="$VISUAL"
                elif [[ -n "${EDITOR:-}" && "$EDITOR" != "$OMG_REMOTE_DRAFT_EDITOR" ]]; then
                    'builtin' 'export' OMG_REMOTE_ORIGINAL_EDITOR="$EDITOR"
                fi
                'builtin' 'export' VISUAL="$OMG_REMOTE_DRAFT_EDITOR" EDITOR="$OMG_REMOTE_DRAFT_EDITOR"
            fi
        }
        'builtin' 'typeset' '-ga' 'precmd_functions'
        precmd_functions+=(__omg_remote_draft_precmd)
    fi
}
"#;

const BASH_PROMPT_SYNC: &str = r#"if [ -z "${__omg_draft_synced:-}" ]; then __omg_draft_synced=1; if [ -n "${OMG_REMOTE_DRAFT_EDITOR:-}" ] && [ -x "$OMG_REMOTE_DRAFT_EDITOR" ]; then if [ -n "${VISUAL:-}" ] && [ "$VISUAL" != "$OMG_REMOTE_DRAFT_EDITOR" ]; then export OMG_REMOTE_ORIGINAL_EDITOR="$VISUAL"; elif [ -n "${EDITOR:-}" ] && [ "$EDITOR" != "$OMG_REMOTE_DRAFT_EDITOR" ]; then export OMG_REMOTE_ORIGINAL_EDITOR="$EDITOR"; fi; export VISUAL="$OMG_REMOTE_DRAFT_EDITOR" EDITOR="$OMG_REMOTE_DRAFT_EDITOR"; fi; fi"#;

const FISH_CONF_SCRIPT: &str = r#"if set -q OMG_REMOTE_FISH_XDG_DIR
    if set -q XDG_DATA_DIRS
        set --local --path __omg_xdg_dirs "$XDG_DATA_DIRS"
        if set --local __omg_idx (contains --index "$OMG_REMOTE_FISH_XDG_DIR" $__omg_xdg_dirs)
            set --erase --local __omg_xdg_dirs[$__omg_idx]
        end
        if set -q __omg_xdg_dirs[1]
            set --global --export --unpath XDG_DATA_DIRS "$__omg_xdg_dirs"
        else
            set --erase --global XDG_DATA_DIRS
        end
    end
    set --erase OMG_REMOTE_FISH_XDG_DIR
end
if status --is-interactive
    function __omg_remote_draft_init --on-event fish_prompt
        functions -e __omg_remote_draft_init
        if set -q OMG_REMOTE_DRAFT_EDITOR; and test -n "$OMG_REMOTE_DRAFT_EDITOR" -a -x "$OMG_REMOTE_DRAFT_EDITOR"
            if set -q VISUAL; and test -n "$VISUAL" -a "$VISUAL" != "$OMG_REMOTE_DRAFT_EDITOR"
                set -gx OMG_REMOTE_ORIGINAL_EDITOR "$VISUAL"
            else if set -q EDITOR; and test -n "$EDITOR" -a "$EDITOR" != "$OMG_REMOTE_DRAFT_EDITOR"
                set -gx OMG_REMOTE_ORIGINAL_EDITOR "$EDITOR"
            end
            set -gx VISUAL "$OMG_REMOTE_DRAFT_EDITOR"
            set -gx EDITOR "$OMG_REMOTE_DRAFT_EDITOR"
        end
    end
end
"#;

fn directory(path: &Path) -> io::Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    crate::host::private(path)
}

fn write(path: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    let temporary = path.with_extension(nonce()?);
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&temporary)?;
        file.write_all(bytes)?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

pub struct Bridge {
    pub editor: PathBuf,
    scope: PathBuf,
    generation: String,
}

impl Bridge {
    /// Configures `VISUAL`/`EDITOR` plus post-RC hooks for interactive login
    /// shells (`zsh -l`, `bash -l`, `fish -l`) so user dotfiles that export
    /// `EDITOR=vim` become the fallback editor rather than clobbering the
    /// Quick Input draft bridge, without altering `argv`.
    pub fn configure_command(
        &self,
        command: &mut std::process::Command,
        argv: &[String],
        original: &str,
    ) {
        command
            .env("OMG_REMOTE_DRAFT_EDITOR", &self.editor)
            .env("OMG_REMOTE_ORIGINAL_EDITOR", original)
            .env("VISUAL", &self.editor)
            .env("EDITOR", &self.editor);
        if argv.len() != 2 || argv[1] != "-l" {
            return;
        }
        let shell_base = Path::new(&argv[0])
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        match shell_base {
            "zsh" => {
                let zdotdir = self.scope.join("zdotdir");
                if directory(&zdotdir).is_ok()
                    && write(&zdotdir.join(".zshenv"), ZSH_ENV_SCRIPT.as_bytes(), 0o600).is_ok()
                {
                    if let Some(orig) = std::env::var_os("ZDOTDIR").filter(|v| !v.is_empty()) {
                        command.env("OMG_REMOTE_ORIG_ZDOTDIR", orig);
                    } else {
                        command.env_remove("OMG_REMOTE_ORIG_ZDOTDIR");
                    }
                    command.env("ZDOTDIR", zdotdir);
                }
            }
            "bash" => {
                let prompt_cmd = match std::env::var("PROMPT_COMMAND")
                    .ok()
                    .filter(|s| !s.trim().is_empty())
                {
                    Some(existing) => format!("{BASH_PROMPT_SYNC}; {existing}"),
                    None => BASH_PROMPT_SYNC.to_owned(),
                };
                command.env("PROMPT_COMMAND", prompt_cmd);
            }
            "fish" => {
                let xdg_root = self.scope.join("fish_xdg");
                let fish_dir = xdg_root.join("fish");
                let conf_dir = fish_dir.join("vendor_conf.d");
                if directory(&xdg_root).is_ok()
                    && directory(&fish_dir).is_ok()
                    && directory(&conf_dir).is_ok()
                    && write(
                        &conf_dir.join("omg-remote-draft.fish"),
                        FISH_CONF_SCRIPT.as_bytes(),
                        0o600,
                    )
                    .is_ok()
                {
                    let base_xdg = std::env::var("XDG_DATA_DIRS")
                        .ok()
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
                    command.env("OMG_REMOTE_FISH_XDG_DIR", &xdg_root).env(
                        "XDG_DATA_DIRS",
                        format!("{}:{base_xdg}", xdg_root.display()),
                    );
                }
            }
            _ => {}
        }
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let current = fs::read(self.scope.join("session.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
        if current
            .as_ref()
            .and_then(|value| value["runtime_generation"].as_str())
            == Some(self.generation.as_str())
        {
            let _ = fs::remove_dir_all(&self.scope);
        }
    }
}

pub fn prepare(state: &Path, record: &Record, tty: &str, original: &str) -> io::Result<Bridge> {
    crate::host::private(state)?;
    let python = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .chain(
            ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
                .into_iter()
                .map(PathBuf::from),
        )
        .map(|directory| directory.join("python3"))
        .find(|path| {
            fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
        .and_then(|path| path.canonicalize().ok())
        .ok_or_else(|| io::Error::other("Python 3 is unavailable for the remote editor bridge"))?;
    let root = state.join("draft");
    directory(&root)?;
    let sessions = root.join("sessions");
    directory(&sessions)?;
    let session = format!("omg-runtime-{}", record.id.to_ascii_lowercase());
    let key = format!("{:x}", Sha256::digest(session.as_bytes()));
    let scope = sessions.join(key);
    directory(&scope)?;
    write(&root.join("omg"), SOURCE.as_bytes(), 0o700)?;
    write(
        &scope.join("session.json"),
        &serde_json::to_vec(&serde_json::json!({
            "protocol": 1, "editor": original, "created": unix_time(), "tty": tty,
            "runtime_id": record.id, "runtime_generation": record.generation,
        }))?,
        0o600,
    )?;
    let launcher = format!(
        "#!/bin/sh\nexec env OMG_REMOTE_ROOT={} {} {} editor {} \"$@\"\n",
        quote(&root.to_string_lossy()),
        quote(&python.to_string_lossy()),
        quote(&root.join("omg").to_string_lossy()),
        quote(&session)
    );
    let editor = scope.join("editor");
    write(&editor, launcher.as_bytes(), 0o700)?;
    Ok(Bridge {
        editor,
        scope,
        generation: record.generation.clone(),
    })
}
