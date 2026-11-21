const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");

pub const Options = struct {};

/// Open files in the OMG editor of the pane this command runs in.
///
///   omg +edit README.md
///   omg +edit src/main.zig:42:7
///   omg +edit --split right notes.txt
///   EDITOR="omg +edit --wait" git commit
///
/// The running OMG app opens the file; a path may end in `:line[:column]`.
/// A file that does not exist yet is created empty.
///
/// Flags:
///
///   * `--split <right|down|left|up>`: Open in a new split.
///
///   * `--tab`: Open in a new tab.
///
///   * `--current`: Open over the current pane.
///
///   * `--wait`: Return once the file is closed in the editor.
///
/// Without a placement flag OMG follows its editor "open files in" setting.
/// The macOS app handles this action itself, over its local control socket;
/// an argument that starts with `+` cannot be used as a path.
pub fn run(_: Allocator) !u8 {
    return unsupported("+edit");
}

/// The macOS app intercepts control actions before the shared CLI runs, so
/// this is reached only by a build without that app.
pub fn unsupported(action: []const u8) !u8 {
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buf);
    const stderr = &stderr_writer.interface;
    try stderr.print("{s} needs the OMG macOS app.\n", .{action});
    try stderr.flush();
    return 1;
}
