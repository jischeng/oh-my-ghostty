//! Packaging only: +ssh loads the same command integration as local panes.
//! Files live in the existing owner-only temporary SSH bootstrap directory;
//! no remote dotfiles, installation, or remote OMG executable are required.
const std = @import("std");

pub const remote_omg = @embedFile("../shell-integration/omg/omg.py");

/// Install the unified remote OMG command before entering the user's shell.
/// Missing Python disables remote capabilities without blocking SSH login.
pub fn writeRemoteOMG(writer: *std.Io.Writer, session: []const u8) !void {
    try writer.writeAll("OMG_REMOTE_SESSION='");
    try writer.writeAll(session);
    try writer.writeAll("'; export OMG_REMOTE_SESSION\n");
    try writer.writeAll(
        \\if command -v python3 >/dev/null 2>&1; then
        \\  __omg_source=$(mktemp "${TMPDIR:-/tmp}/omg-runtime.XXXXXX")
        \\  if [ -n "$__omg_source" ]; then
        \\    chmod 600 "$__omg_source"
        \\    cat > "$__omg_source" <<'__OMG_REMOTE_SOURCE__'
        \\
    );
    try writer.writeAll(remote_omg);
    try writer.writeAll(
        \\
        \\__OMG_REMOTE_SOURCE__
        \\    OMG_REMOTE_COMMAND=$(python3 "$__omg_source" install "$OMG_REMOTE_SESSION") || unset OMG_REMOTE_COMMAND
        \\    rm -f -- "$__omg_source"
        \\    export OMG_REMOTE_COMMAND
        \\  fi
        \\fi
        \\
    );
}

pub const shell_remote_setup =
    \\if [ -n "${OMG_REMOTE_COMMAND-}" ]; then
    \\  __omg_editor=$(python3 "$OMG_REMOTE_COMMAND" session-start "$OMG_REMOTE_SESSION" "${VISUAL:-${EDITOR:-nano}}")
    \\  if [ -n "$__omg_editor" ]; then
    \\    VISUAL=$__omg_editor; EDITOR=$__omg_editor; export VISUAL EDITOR
    \\  fi
    \\  unset __omg_editor
    \\  if [ -n "${ZSH_VERSION-}" ]; then
    \\    __omg_remote_stop() { python3 "$OMG_REMOTE_COMMAND" session-end "$OMG_REMOTE_SESSION" >/dev/null 2>&1; }
    \\    zshexit_functions+=(__omg_remote_stop)
    \\  else
    \\    # Preserve any user EXIT trap and its exit status.
    \\    __omg_previous_exit=$(trap -p EXIT)
    \\    __omg_remote_stop() {
    \\      local result=$?
    \\      python3 "$OMG_REMOTE_COMMAND" session-end "$OMG_REMOTE_SESSION" >/dev/null 2>&1
    \\      trap - EXIT
    \\      if [ -n "$__omg_previous_exit" ]; then eval "$__omg_previous_exit"; exit "$result"; fi
    \\      return "$result"
    \\    }
    \\    trap __omg_remote_stop EXIT
    \\  fi
    \\fi
    \\
;

pub const fish_remote_setup =
    \\if set -q OMG_REMOTE_COMMAND; and test -n "$OMG_REMOTE_COMMAND"
    \\  set -l original nano
    \\  if set -q VISUAL; set original "$VISUAL"; else if set -q EDITOR; set original "$EDITOR"; end
    \\  set -l editor (python3 "$OMG_REMOTE_COMMAND" session-start "$OMG_REMOTE_SESSION" "$original")
    \\  if test $status -eq 0; and test -n "$editor"; set -gx VISUAL "$editor"; set -gx EDITOR "$editor"; end
    \\  function __omg_remote_stop --on-event fish_exit
    \\    python3 "$OMG_REMOTE_COMMAND" session-end "$OMG_REMOTE_SESSION" >/dev/null 2>&1
    \\  end
    \\end
    \\
;

pub const fish = @embedFile("../shell-integration/fish/ghostty-command-markers.fish");
pub const bash = @embedFile("../shell-integration/bash/ghostty.bash");
pub const bash_preexec = @embedFile("../shell-integration/bash/bash-preexec.sh");
pub const zsh = @embedFile("../shell-integration/zsh/ghostty-integration");

pub fn writeBashFiles(writer: *std.Io.Writer) !void {
    try writer.writeAll("cat > \"$__omg_dir/ghostty.bash\" <<'__OMG_BASH_INTEGRATION__'\n");
    try writer.writeAll(bash);
    try writer.writeAll("\n__OMG_BASH_INTEGRATION__\ncat > \"$__omg_dir/bash-preexec.sh\" <<'__OMG_BASH_PREEXEC__'\n");
    try writer.writeAll(bash_preexec);
    try writer.writeAll("\n__OMG_BASH_PREEXEC__\n");
}

pub fn writeZshFile(writer: *std.Io.Writer) !void {
    try writer.writeAll("cat > \"$__omg_dir/ghostty-integration\" <<'__OMG_ZSH_INTEGRATION__'\n");
    try writer.writeAll(zsh);
    try writer.writeAll("\n__OMG_ZSH_INTEGRATION__\n");
}

test "SSH shared shell integration uses the local sources" {
    const testing = std.testing;
    try testing.expect(std.mem.indexOf(u8, fish, "__ghostty_original_history_prompt\n") != null);
    try testing.expect(std.mem.indexOf(u8, bash, "PS2=") != null);
    try testing.expect(std.mem.indexOf(u8, bash, "PS0") != null);
    try testing.expect(std.mem.indexOf(u8, zsh, "k=s") != null);
    try testing.expect(std.mem.indexOf(u8, bash_preexec, "preexec_functions") != null);
}
