//! Packaging only: +ssh loads the same command integration as local panes.
//! Files live in the existing owner-only temporary SSH bootstrap directory;
//! no remote dotfiles, installation, or remote OMG executable are required.
const std = @import("std");

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
