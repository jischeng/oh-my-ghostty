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

pub const POSIX_INLINE_SYNC: &str = r#"if [ -n "${OMG_REMOTE_DRAFT_EDITOR:-}" ] && [ -x "$OMG_REMOTE_DRAFT_EDITOR" ]; then if [ -n "${VISUAL:-}" ] && [ "$VISUAL" != "$OMG_REMOTE_DRAFT_EDITOR" ]; then export OMG_REMOTE_ORIGINAL_EDITOR="$VISUAL"; elif [ -n "${EDITOR:-}" ] && [ "$EDITOR" != "$OMG_REMOTE_DRAFT_EDITOR" ]; then export OMG_REMOTE_ORIGINAL_EDITOR="$EDITOR"; fi; export VISUAL="$OMG_REMOTE_DRAFT_EDITOR" EDITOR="$OMG_REMOTE_DRAFT_EDITOR"; fi"#;

pub const FISH_INLINE_SYNC: &str = r#"if set -q OMG_REMOTE_DRAFT_EDITOR; and test -n "$OMG_REMOTE_DRAFT_EDITOR" -a -x "$OMG_REMOTE_DRAFT_EDITOR"; if set -q VISUAL; and test -n "$VISUAL" -a "$VISUAL" != "$OMG_REMOTE_DRAFT_EDITOR"; set -gx OMG_REMOTE_ORIGINAL_EDITOR "$VISUAL"; else if set -q EDITOR; and test -n "$EDITOR" -a "$EDITOR" != "$OMG_REMOTE_DRAFT_EDITOR"; set -gx OMG_REMOTE_ORIGINAL_EDITOR "$EDITOR"; end; set -gx VISUAL "$OMG_REMOTE_DRAFT_EDITOR"; set -gx EDITOR "$OMG_REMOTE_DRAFT_EDITOR"; end"#;

const ZSH_SYNC_BLOCK: &str = r#"    if [[ -n "${OMG_REMOTE_DRAFT_EDITOR:-}" && -x "$OMG_REMOTE_DRAFT_EDITOR" ]]; then
        if [[ -n "${VISUAL:-}" && "$VISUAL" != "$OMG_REMOTE_DRAFT_EDITOR" ]]; then
            'builtin' 'export' OMG_REMOTE_ORIGINAL_EDITOR="$VISUAL"
        elif [[ -n "${EDITOR:-}" && "$EDITOR" != "$OMG_REMOTE_DRAFT_EDITOR" ]]; then
            'builtin' 'export' OMG_REMOTE_ORIGINAL_EDITOR="$EDITOR"
        fi
        'builtin' 'export' VISUAL="$OMG_REMOTE_DRAFT_EDITOR" EDITOR="$OMG_REMOTE_DRAFT_EDITOR"
    fi"#;

fn zsh_stage_script(rc_filename: &str, rearm_condition: Option<&str>) -> String {
    let mut out = String::new();
    if rearm_condition.is_some() {
        out.push_str("'builtin' 'typeset' __omg_wrapper_zdotdir=\"${${(%):-%x}:A:h}\"\n");
    }
    out.push_str(
        r#"if [[ -n "${OMG_REMOTE_ORIG_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$OMG_REMOTE_ORIG_ZDOTDIR"
    'builtin' 'unset' 'OMG_REMOTE_ORIG_ZDOTDIR'
else
    'builtin' 'unset' 'ZDOTDIR'
fi
{
    'builtin' 'typeset' __omg_file=${ZDOTDIR-$HOME}""#,
    );
    out.push_str(rc_filename);
    out.push_str(
        r#""
    [[ ! -r "$__omg_file" ]] || 'builtin' 'source' '--' "$__omg_file"
} always {
    'builtin' 'unset' '__omg_file'
"#,
    );
    out.push_str(ZSH_SYNC_BLOCK);
    out.push('\n');
    if let Some(cond) = rearm_condition {
        out.push_str("    if [[ ");
        out.push_str(cond);
        out.push_str(
            r#" ]]; then
        if [[ -n "${ZDOTDIR+X}" ]]; then
            'builtin' 'export' OMG_REMOTE_ORIG_ZDOTDIR="$ZDOTDIR"
        fi
        'builtin' 'export' ZDOTDIR="$__omg_wrapper_zdotdir"
    fi
    'builtin' 'unset' '__omg_wrapper_zdotdir'
"#,
        );
    }
    out.push_str("}\n");
    out
}

const BASH_ENV_SCRIPT: &str = r#"if [[ -n "${OMG_REMOTE_BASH_INJECT:-}" ]]; then
    builtin unset ENV OMG_REMOTE_BASH_INJECT
    if [[ -n "${OMG_REMOTE_ORIG_BASH_ENV+X}" ]]; then
        builtin export ENV="$OMG_REMOTE_ORIG_BASH_ENV"
        builtin unset OMG_REMOTE_ORIG_BASH_ENV
    fi
    builtin set +o posix
    builtin shopt -u inherit_errexit 2>/dev/null
    if [[ -n "${OMG_REMOTE_BASH_RESET_HISTFILE:-}" ]]; then
        HISTFILE="$HOME/.bash_history"
        builtin unset OMG_REMOTE_BASH_RESET_HISTFILE
    fi
    if builtin shopt -q login_shell; then
        if [ -r /etc/profile ]; then
            builtin source "/etc/profile" || builtin true
        fi
        for __omg_rcfile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [ -r "$__omg_rcfile" ]; then
                builtin source "$__omg_rcfile" || builtin true
                break
            fi
        done
        builtin unset __omg_rcfile
    fi
    if [ -n "${OMG_REMOTE_DRAFT_EDITOR:-}" ] && [ -x "$OMG_REMOTE_DRAFT_EDITOR" ]; then
        if [ -n "${VISUAL:-}" ] && [ "$VISUAL" != "$OMG_REMOTE_DRAFT_EDITOR" ]; then
            export OMG_REMOTE_ORIGINAL_EDITOR="$VISUAL"
        elif [ -n "${EDITOR:-}" ] && [ "$EDITOR" != "$OMG_REMOTE_DRAFT_EDITOR" ]; then
            export OMG_REMOTE_ORIGINAL_EDITOR="$EDITOR"
        fi
        export VISUAL="$OMG_REMOTE_DRAFT_EDITOR" EDITOR="$OMG_REMOTE_DRAFT_EDITOR"
    fi
fi
"#;

const BASH_RC_SCRIPT: &str = r#"if [ -r /etc/profile ]; then
    builtin source "/etc/profile" || builtin true
fi
for __omg_rcfile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -r "$__omg_rcfile" ]; then
        builtin source "$__omg_rcfile" || builtin true
        break
    fi
done
builtin unset __omg_rcfile
if [ -n "${OMG_REMOTE_DRAFT_EDITOR:-}" ] && [ -x "$OMG_REMOTE_DRAFT_EDITOR" ]; then
    if [ -n "${VISUAL:-}" ] && [ "$VISUAL" != "$OMG_REMOTE_DRAFT_EDITOR" ]; then
        export OMG_REMOTE_ORIGINAL_EDITOR="$VISUAL"
    elif [ -n "${EDITOR:-}" ] && [ "$EDITOR" != "$OMG_REMOTE_DRAFT_EDITOR" ]; then
        export OMG_REMOTE_ORIGINAL_EDITOR="$EDITOR"
    fi
    export VISUAL="$OMG_REMOTE_DRAFT_EDITOR" EDITOR="$OMG_REMOTE_DRAFT_EDITOR"
fi
"#;

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

fn is_apple_system_bash(shell_path: &str) -> bool {
    cfg!(target_os = "macos") && matches!(shell_path, "/bin/bash" | "/private/bin/bash")
}

fn shell_basename(shell_path: &str) -> &str {
    Path::new(shell_path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
}

fn parse_login_shell_argv(argv: &[String]) -> Option<(&str, Option<usize>)> {
    let first = argv.first()?;
    let base = shell_basename(first);
    if argv.len() == 2 && matches!(argv[1].as_str(), "-l" | "--login") {
        return Some((base, None));
    }
    if argv.len() >= 4 && argv[argv.len() - 2] == "-c" {
        let flags = &argv[1..argv.len() - 2];
        let has_login = flags.iter().any(|f| matches!(f.as_str(), "-l" | "--login"));
        let all_supported = flags
            .iter()
            .all(|f| matches!(f.as_str(), "-l" | "--login" | "-i"));
        if has_login && all_supported {
            return Some((base, Some(argv.len() - 1)));
        }
    }
    None
}

fn prepend_inline_sync(shell_base: &str, script: &str) -> String {
    let sync = if shell_base == "fish" {
        FISH_INLINE_SYNC
    } else {
        POSIX_INLINE_SYNC
    };
    if script.starts_with(sync) {
        script.to_owned()
    } else {
        format!("{sync}; {script}")
    }
}

/// Builds a login-interactive shell `argv` (`[shell, "-l", "-i", "-c", script]`)
/// for remote Agent resume / initial-resume launches, preserving `VISUAL`/`EDITOR`
/// after user RC files run and across any fallback login shell after agent exit.
pub fn build_resume_argv(
    shell: &str,
    args: &[String],
    fallback_to_login_shell: bool,
) -> Vec<String> {
    let base = shell_basename(shell);
    let quoted_cmd = args.iter().map(|s| quote(s)).collect::<Vec<_>>().join(" ");
    let quoted_shell = quote(shell);
    let body = if !fallback_to_login_shell {
        format!("exec {quoted_cmd}")
    } else {
        match base {
            "zsh" => format!(
                "{quoted_cmd}; if [[ -n \"${{OMG_REMOTE_ZDOTDIR:-}}\" && -d \"$OMG_REMOTE_ZDOTDIR\" ]]; then if [[ -n \"${{ZDOTDIR+X}}\" && \"$ZDOTDIR\" != \"$OMG_REMOTE_ZDOTDIR\" ]]; then export OMG_REMOTE_ORIG_ZDOTDIR=\"$ZDOTDIR\"; fi; ZDOTDIR=\"$OMG_REMOTE_ZDOTDIR\" exec {quoted_shell} -l; fi; exec {quoted_shell} -l"
            ),
            "bash" if is_apple_system_bash(shell) => format!(
                "{quoted_cmd}; if [ -n \"${{OMG_REMOTE_BASH_RC_FILE:-}}\" ] && [ -r \"$OMG_REMOTE_BASH_RC_FILE\" ]; then exec {quoted_shell} --rcfile \"$OMG_REMOTE_BASH_RC_FILE\"; fi; exec {quoted_shell} -l"
            ),
            "bash" => format!(
                "{quoted_cmd}; if [ -n \"${{OMG_REMOTE_BASH_ENV_FILE:-}}\" ] && [ -r \"$OMG_REMOTE_BASH_ENV_FILE\" ]; then if [ -n \"${{ENV+x}}\" ] && [ \"${{ENV:-}}\" != \"$OMG_REMOTE_BASH_ENV_FILE\" ]; then export OMG_REMOTE_ORIG_BASH_ENV=\"$ENV\"; fi; case $(export -p) in *' HISTFILE='*|*'declare -x HISTFILE='*) ;; *) export OMG_REMOTE_BASH_RESET_HISTFILE=1 ;; esac; ENV=\"$OMG_REMOTE_BASH_ENV_FILE\" OMG_REMOTE_BASH_INJECT=1 exec {quoted_shell} --posix -l; fi; exec {quoted_shell} -l"
            ),
            "fish" => format!(
                "{quoted_cmd}; if set -q OMG_REMOTE_FISH_XDG_HOLD; and test -d \"$OMG_REMOTE_FISH_XDG_HOLD\"; set -gx OMG_REMOTE_FISH_XDG_DIR \"$OMG_REMOTE_FISH_XDG_HOLD\"; if set -q XDG_DATA_DIRS; set -gx XDG_DATA_DIRS \"$OMG_REMOTE_FISH_XDG_HOLD:$XDG_DATA_DIRS\"; else; set -gx XDG_DATA_DIRS \"$OMG_REMOTE_FISH_XDG_HOLD:/usr/local/share:/usr/share\"; end; end; exec {quoted_shell} -l"
            ),
            _ => format!("{quoted_cmd}; exec {quoted_shell} -l"),
        }
    };
    let script = prepend_inline_sync(base, &body);
    vec![
        shell.to_owned(),
        "-l".into(),
        "-i".into(),
        "-c".into(),
        script,
    ]
}

pub struct Bridge {
    pub editor: PathBuf,
    scope: PathBuf,
    generation: String,
}

impl Bridge {
    fn write_zsh_files(&self) -> io::Result<PathBuf> {
        let zdotdir = self.scope.join("zdotdir");
        directory(&zdotdir)?;
        write(
            &zdotdir.join(".zshenv"),
            zsh_stage_script(
                "/.zshenv",
                Some("-o 'rcs' && ( -o 'interactive' || -o 'login' )"),
            )
            .as_bytes(),
            0o600,
        )?;
        write(
            &zdotdir.join(".zprofile"),
            zsh_stage_script(
                "/.zprofile",
                Some("-o 'rcs' && ( -o 'interactive' || -o 'login' )"),
            )
            .as_bytes(),
            0o600,
        )?;
        write(
            &zdotdir.join(".zshrc"),
            zsh_stage_script("/.zshrc", Some("-o 'rcs' && -o 'login'")).as_bytes(),
            0o600,
        )?;
        write(
            &zdotdir.join(".zlogin"),
            zsh_stage_script("/.zlogin", None).as_bytes(),
            0o600,
        )?;
        Ok(zdotdir)
    }

    fn write_bash_file(&self, shell_path: &str) -> io::Result<PathBuf> {
        if is_apple_system_bash(shell_path) {
            let rc = self.scope.join("bash_rc");
            write(&rc, BASH_RC_SCRIPT.as_bytes(), 0o600)?;
            Ok(rc)
        } else {
            let env_file = self.scope.join("bash_env");
            write(&env_file, BASH_ENV_SCRIPT.as_bytes(), 0o600)?;
            Ok(env_file)
        }
    }

    fn write_fish_files(&self) -> io::Result<PathBuf> {
        let xdg_root = self.scope.join("fish_xdg");
        let fish_dir = xdg_root.join("fish");
        let conf_dir = fish_dir.join("vendor_conf.d");
        directory(&xdg_root)?;
        directory(&fish_dir)?;
        directory(&conf_dir)?;
        write(
            &conf_dir.join("omg-remote-draft.fish"),
            FISH_CONF_SCRIPT.as_bytes(),
            0o600,
        )?;
        Ok(xdg_root)
    }

    /// Returns the effective `argv` for spawning the remote session process,
    /// injecting Bash startup integration (`--posix` or `--rcfile` on Apple
    /// `/bin/bash`) and `-c` post-RC editor restoration when `argv` launches a
    /// login shell (`[shell, "-l"]` or `[shell, "-l", "-i", "-c", script]`).
    pub fn configure_argv(&self, argv: &[String]) -> Vec<String> {
        let Some((shell_base, dash_c_idx)) = parse_login_shell_argv(argv) else {
            return argv.to_vec();
        };
        let mut out = argv.to_vec();
        if let Some(idx) = dash_c_idx {
            if matches!(shell_base, "zsh" | "bash" | "fish" | "sh" | "dash" | "ksh") {
                out[idx] = prepend_inline_sync(shell_base, &out[idx]);
            }
        }
        if shell_base == "bash" {
            if let Ok(path) = self.write_bash_file(&argv[0]) {
                if is_apple_system_bash(&argv[0]) {
                    let mut rewritten = vec![
                        argv[0].clone(),
                        "--rcfile".into(),
                        path.to_string_lossy().into_owned(),
                    ];
                    for arg in &out[1..] {
                        if !matches!(arg.as_str(), "-l" | "--login") {
                            rewritten.push(arg.clone());
                        }
                    }
                    return rewritten;
                }
                let mut rewritten = Vec::with_capacity(out.len() + 1);
                rewritten.push(out[0].clone());
                rewritten.push("--posix".into());
                rewritten.extend_from_slice(&out[1..]);
                return rewritten;
            }
        }
        out
    }

    /// Configures `VISUAL`/`EDITOR` plus post-RC environment hooks for login
    /// shells (`[shell, "-l"]` and `[shell, "-l", "-i", "-c", script]`) so user
    /// dotfiles that export `EDITOR=vim` or overwrite `PROMPT_COMMAND` become
    /// the fallback editor rather than clobbering the Quick Input draft bridge.
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
        let Some((shell_base, _)) = parse_login_shell_argv(argv) else {
            return;
        };
        match shell_base {
            "zsh" => {
                if let Ok(zdotdir) = self.write_zsh_files() {
                    if let Some(orig) = std::env::var_os("ZDOTDIR").filter(|v| !v.is_empty()) {
                        command.env("OMG_REMOTE_ORIG_ZDOTDIR", orig);
                    } else {
                        command.env_remove("OMG_REMOTE_ORIG_ZDOTDIR");
                    }
                    command
                        .env("OMG_REMOTE_ZDOTDIR", &zdotdir)
                        .env("ZDOTDIR", zdotdir);
                }
            }
            "bash" => {
                if let Ok(path) = self.write_bash_file(&argv[0]) {
                    if is_apple_system_bash(&argv[0]) {
                        command.env("OMG_REMOTE_BASH_RC_FILE", path);
                    } else {
                        if let Some(orig_env) = std::env::var_os("ENV").filter(|v| !v.is_empty()) {
                            command.env("OMG_REMOTE_ORIG_BASH_ENV", orig_env);
                        } else {
                            command.env_remove("OMG_REMOTE_ORIG_BASH_ENV");
                        }
                        if std::env::var_os("HISTFILE").is_none() {
                            command.env("OMG_REMOTE_BASH_RESET_HISTFILE", "1");
                        } else {
                            command.env_remove("OMG_REMOTE_BASH_RESET_HISTFILE");
                        }
                        command
                            .env("OMG_REMOTE_BASH_ENV_FILE", &path)
                            .env("OMG_REMOTE_BASH_INJECT", "1")
                            .env("ENV", path);
                    }
                }
            }
            "fish" => {
                if let Ok(xdg_root) = self.write_fish_files() {
                    let base_xdg = std::env::var("XDG_DATA_DIRS")
                        .ok()
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
                    command
                        .env("OMG_REMOTE_FISH_XDG_HOLD", &xdg_root)
                        .env("OMG_REMOTE_FISH_XDG_DIR", &xdg_root)
                        .env(
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lifecycle::Policy;

    #[test]
    fn build_resume_argv_and_configure_argv_cover_login_and_dash_c_shells() {
        let dir = PathBuf::from(format!("/tmp/omg-rtest-{}", &nonce().unwrap()[..8]));
        directory(&dir).unwrap();
        let record =
            Record::new("11111111-1111-1111-1111-111111111111", Policy::default()).unwrap();
        let bridge = prepare(&dir, &record, "/dev/ttys000", "vim").unwrap();

        let args = vec!["agy".to_owned(), "--resume".into(), "conv-1".into()];
        let zsh_resume = build_resume_argv("/bin/zsh", &args, false);
        assert_eq!(&zsh_resume[..4], ["/bin/zsh", "-l", "-i", "-c"]);
        assert!(zsh_resume[4].starts_with(POSIX_INLINE_SYNC));
        assert!(zsh_resume[4].ends_with("exec 'agy' '--resume' 'conv-1'"));

        let fish_initial = build_resume_argv("/opt/homebrew/bin/fish", &args, true);
        assert_eq!(
            &fish_initial[..4],
            ["/opt/homebrew/bin/fish", "-l", "-i", "-c"]
        );
        assert!(fish_initial[4].starts_with(FISH_INLINE_SYNC));
        assert!(fish_initial[4].contains("OMG_REMOTE_FISH_XDG_HOLD"));

        // GNU bash path inserts `--posix` before `-l` for both plain login and `-l -i -c`.
        let gnu_plain = bridge.configure_argv(&["/usr/local/bin/bash".into(), "-l".into()]);
        assert_eq!(gnu_plain, ["/usr/local/bin/bash", "--posix", "-l"]);

        let gnu_resume =
            bridge.configure_argv(&build_resume_argv("/usr/local/bin/bash", &args, true));
        assert_eq!(
            &gnu_resume[..5],
            ["/usr/local/bin/bash", "--posix", "-l", "-i", "-c"]
        );
        assert!(gnu_resume[5].starts_with(POSIX_INLINE_SYNC));

        // Non-login direct commands are untouched.
        let direct = vec!["/usr/bin/python3".to_owned(), "agent.py".into()];
        assert_eq!(bridge.configure_argv(&direct), direct);

        drop(bridge);
        let _ = fs::remove_dir_all(&dir);
    }
}
