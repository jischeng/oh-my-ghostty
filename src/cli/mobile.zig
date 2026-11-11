const std = @import("std");
const global = @import("../global.zig");
const args = @import("args.zig");

pub const Options = struct {};

fn bundledHelper(alloc: std.mem.Allocator, executable_dir: []const u8) ![]const u8 {
    return std.fs.path.resolve(alloc, &.{ executable_dir, "..", "Resources", "session-runtime", "omgd" });
}

/// Pair and manage OMG Mobile access for this machine's local sessions.
///
///   omg +mobile
///   omg +mobile pair
///   omg +mobile status
///   omg +mobile stop
///   omg +mobile revoke
///
/// Always exposes only this machine's local sessions, never registered SSH
/// Cloud hosts. On an SSH server, run `omg +mobile` or `omgd mobile` directly
/// on that server to pair it with OMG Mobile.
pub fn run(gpa: std.mem.Allocator) !u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const executable_dir = try std.process.executableDirPathAlloc(global.io(), alloc);
    const helper = try bundledHelper(alloc, executable_dir);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ helper, "mobile" });
    var iter = try args.argsIterator(alloc, global.args());
    defer iter.deinit();
    while (iter.next()) |arg| try argv.append(alloc, try alloc.dupe(u8, arg));
    var child = try std.process.spawn(global.io(), .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    return switch (try child.wait(global.io())) {
        .exited => |code| code,
        else => 1,
    };
}

test "mobile helper stays in executable bundle" {
    const alloc = std.testing.allocator;
    const path = try bundledHelper(alloc, "/Applications/OMG Dev.app/Contents/MacOS");
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/Applications/OMG Dev.app/Contents/Resources/session-runtime/omgd", path);
}
