import Foundation

/// Export-only. OMG never logs in or changes a remote account automatically.
/// The user reviews, transfers and explicitly runs this Python 3 installer.
enum RemoteShellHistoryInstaller {
    static let script = #"""
#!/usr/bin/env python3
"""Install opt-in OSC 133 command markers for a remote interactive Shell.

Review this file, transfer it to the intended SSH account, then run:
    python3 omg-shell-history.py install
    python3 omg-shell-history.py status
    python3 omg-shell-history.py uninstall
No SSH/network calls; no command history is read or uploaded.
"""
import os
from pathlib import Path
import shutil
import stat
import sys
import uuid

BEGIN = '# >>> OMG shell history (OSC 133) >>>'
END = '# <<< OMG shell history (OSC 133) <<<'
HOME = Path.home()
ROOT = HOME / '.config' / 'oh-my-ghostty' / 'shell-history'

SCRIPTS = {
    'fish': r'''# OMG: emit semantic boundaries from Fish's own prompt and preexec events.
status --is-interactive; or return
if set -q __omg_hist_enabled; return; end
set -g __omg_hist_enabled 1
function __omg_hist_setup --on-event fish_prompt
    functions -e __omg_hist_setup
    functions -q fish_prompt; or return
    functions -c fish_prompt __omg_hist_original_prompt
    function fish_prompt
        builtin printf '\e]133;A\a'
        __omg_hist_original_prompt
        builtin printf '\e]133;B\a'
    end
end
function __omg_hist_preexec --on-event fish_preexec
    if set -q argv[1]
        set -l encoded (string escape --style=url -- "$argv[1]")
        if test (string length -- "$encoded") -le 16384
            builtin printf '\e]133;C;cmdline_url=%s\a' "$encoded"
            return
        end
    end
    builtin printf '\e]133;C\a'
end
function __omg_hist_postexec --on-event fish_postexec
    builtin printf '\e]133;D;%s\a' "$status"
end
''',
    'zsh': r'''# OMG: integrate after the user's prompt/theme initialization.
[[ -o interactive && -z ${_OMG_HIST_ENABLED:-} ]] || return
 typeset -g _OMG_HIST_ENABLED=1
 typeset -g _OMG_HIST_EXECUTING=0
 typeset -ga precmd_functions preexec_functions
 _omg_hist_precmd() {
     local exit_code=$?
     if (( _OMG_HIST_EXECUTING )); then
         builtin print -rn -- $'\e]133;D;'"$exit_code"$'\a'
     fi
     _OMG_HIST_EXECUTING=0
     builtin print -rn -- $'\e]133;A\a'
     [[ $PROMPT == *$'\e]133;B'* ]] || PROMPT+=$'%{\e]133;B\a%}'
 }
 _omg_hist_preexec() {
     _OMG_HIST_EXECUTING=1
     builtin print -rn -- $'\e]133;C\a'
 }
 precmd_functions+=(_omg_hist_precmd)
 preexec_functions+=(_omg_hist_preexec)
''',
    'bash': r'''# OMG: integrate with interactive Bash after the user's prompt setup.
[[ $- == *i* && -z ${_OMG_HIST_ENABLED:-} ]] || return
if [[ $(trap -p DEBUG) ]]; then
    printf '%s\n' 'OMG: existing Bash DEBUG trap; skipped to avoid replacing it' >&2
    return
fi
_OMG_HIST_ENABLED=1
_OMG_HIST_EXECUTING=0
_omg_hist_prompt() {
    local exit_code=$?
    if [[ $_OMG_HIST_EXECUTING == 1 ]]; then
        builtin printf '\e]133;D;%s\a' "$exit_code"
    fi
    _OMG_HIST_EXECUTING=0
    builtin printf '\e]133;A\a'
    [[ $PS1 == *'133;B'* ]] || PS1=$PS1'\[\e]133;B\a\]'
}
_omg_hist_debug() {
    [[ $_OMG_HIST_EXECUTING == 1 || $BASH_COMMAND == _omg_hist_* ]] && return
    builtin printf '\e]133;C\a'
    _OMG_HIST_EXECUTING=1
}
if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
    PROMPT_COMMAND+=(_omg_hist_prompt)
elif [[ -z ${PROMPT_COMMAND:-} ]]; then
    PROMPT_COMMAND='_omg_hist_prompt'
else
    PROMPT_COMMAND="${PROMPT_COMMAND};_omg_hist_prompt"
fi
trap '_omg_hist_debug' DEBUG
''',
}

RC = {
    'fish': HOME / '.config' / 'fish' / 'config.fish',
    'zsh': HOME / '.zshrc',
    'bash': HOME / '.bashrc',
}


def check_parent(path):
    parent = path.parent
    while True:
        if parent.exists() and (parent.is_symlink() or not parent.is_dir()):
            raise RuntimeError('Refusing non-directory or symlink: ' + str(parent))
        if parent == HOME:
            break
        if parent == parent.parent:
            raise RuntimeError('Path is outside home: ' + str(path))
        parent = parent.parent
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)


def read_regular(path):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise RuntimeError('Refusing non-regular file: ' + str(path))
    if not path.exists():
        return ''
    if path.stat().st_size > 1024 * 1024:
        raise RuntimeError('Refusing oversized rc file: ' + str(path))
    return path.read_text(encoding='utf-8')


def write_atomic(path, contents, permissions):
    check_parent(path)
    temporary = path.with_name(path.name + '.omg-' + uuid.uuid4().hex)
    fd = os.open(temporary,
                 os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            output.write(contents)
        os.chmod(temporary, permissions)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def block(shell):
    extension = {'fish': 'fish', 'zsh': 'zsh', 'bash': 'bash'}[shell]
    source = ROOT / ('history.' + extension)
    if shell == 'fish':
        line = 'if test -r "$HOME/.config/oh-my-ghostty/shell-history/history.fish"; source "$HOME/.config/oh-my-ghostty/shell-history/history.fish"; end'
    else:
        line = '[ ! -r "$HOME/.config/oh-my-ghostty/shell-history/history.' + extension + '" ] || . "$HOME/.config/oh-my-ghostty/shell-history/history.' + extension + '"'
    return '\n'.join((BEGIN, line, END)) + '\n', source


def validate_rc(shell):
    path = RC[shell]
    before = read_regular(path)
    snippet, _ = block(shell)
    if BEGIN in before or END in before:
        if before.count(BEGIN) != 1 or before.count(END) != 1:
            raise RuntimeError('Ambiguous OMG marker in ' + str(path))
        first = before.index(BEGIN)
        last = before.index(END, first) + len(END)
        if before[first:last] != snippet.strip():
            raise RuntimeError('Modified OMG block in ' + str(path))
    return before


def update_rc(shell, installing):
    path = RC[shell]
    before = validate_rc(shell)
    snippet, _ = block(shell)
    if BEGIN in before:
        first = before.index(BEGIN)
        last = before.index(END, first) + len(END)
        if installing:
            return
        after = before[:first] + before[last:].lstrip('\n')
    else:
        if not installing:
            return
        after = before + ('' if not before or before.endswith('\n') else '\n') + snippet
    if after == before:
        return
    check_parent(path)
    if path.exists():
        backup = path.with_name(path.name + '.omg-backup-' + uuid.uuid4().hex)
        shutil.copy2(path, backup, follow_symlinks=False)
        os.chmod(backup, 0o600)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    write_atomic(path, after, mode)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ('install', 'uninstall', 'status'):
        print('Usage: python3 omg-shell-history.py install|uninstall|status', file=sys.stderr)
        return 2
    action = sys.argv[1]
    if action == 'status':
        for shell in ('fish', 'zsh', 'bash'):
            print(shell + ': ' + ('installed' if BEGIN in read_regular(RC[shell]) else 'not installed'))
        return 0
    # Validate every target before editing any rc file. Never overwrite a
    # snippet edited by the user, even if it bears OMG's filename.
    for shell in ('fish', 'zsh', 'bash'):
        validate_rc(shell)
        check_parent(RC[shell])
        if action == 'install':
            _, source = block(shell)
            check_parent(source)
            existing = read_regular(source)
            if source.exists() and existing != SCRIPTS[shell]:
                raise RuntimeError('Edited OMG snippet; review manually: ' + str(source))
    if action == 'install':
        for shell in ('fish', 'zsh', 'bash'):
            _, source = block(shell)
            if not source.exists():
                write_atomic(source, SCRIPTS[shell], 0o600)
            update_rc(shell, True)
    else:
        for shell in ('fish', 'zsh', 'bash'):
            update_rc(shell, False)
        # Deliberately retain snippet files so user edits are never deleted.
    print('OMG Shell history integration ' + action + ' complete. Open a new Shell to activate.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, UnicodeError, RuntimeError) as error:
        print('OMG installer: ' + str(error), file=sys.stderr)
        sys.exit(1)
"""#
}
