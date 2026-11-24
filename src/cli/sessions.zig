const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const args = @import("args.zig");

pub const Options = struct {};

const HostAppBundle = struct {
    bundle_path: []const u8,
    bundle_id: []const u8,
};

fn bundledHelper(alloc: std.mem.Allocator, executable_dir: []const u8) ![]const u8 {
    return std.fs.path.resolve(alloc, &.{ executable_dir, "..", "Resources", "session-runtime", "omgd" });
}

fn isValidOMGHostBundleID(bundle_id: []const u8) bool {
    const prefix = "com.jischeng.omg";
    if (!std.mem.startsWith(u8, bundle_id, prefix)) return false;
    if (bundle_id.len > prefix.len and bundle_id[prefix.len] != '.') return false;
    for (bundle_id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_') return false;
    }
    return true;
}

fn extractXMLPlistBundleID(raw: []const u8) ?[]const u8 {
    const key_needle = "<key>CFBundleIdentifier</key>";
    const key_idx = std.mem.indexOf(u8, raw, key_needle) orelse return null;
    const after_key = raw[key_idx + key_needle.len ..];
    const open_str = "<string>";
    const start_idx = std.mem.indexOf(u8, after_key, open_str) orelse return null;
    const value_start = after_key[start_idx + open_str.len ..];
    const end_idx = std.mem.indexOf(u8, value_start, "</string>") orelse return null;
    const trimmed = std.mem.trim(u8, value_start[0..end_idx], " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn detectHostAppBundle(io: std.Io, alloc: std.mem.Allocator, executable_dir: []const u8) ?HostAppBundle {
    if (comptime builtin.target.os.tag != .macos) return null;
    if (!std.mem.eql(u8, std.fs.path.basename(executable_dir), "MacOS")) return null;
    const contents_dir = std.fs.path.dirname(executable_dir) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(contents_dir), "Contents")) return null;
    const app_dir = std.fs.path.dirname(contents_dir) orelse return null;
    if (!std.mem.endsWith(u8, app_dir, ".app")) return null;

    const info_plist = std.fs.path.join(alloc, &.{ contents_dir, "Info.plist" }) catch return null;
    const plist_bytes = blk: {
        const file = std.Io.Dir.openFileAbsolute(io, info_plist, .{}) catch return null;
        defer file.close(io);
        var reader = file.reader(io, &.{});
        break :blk reader.interface.allocRemaining(alloc, .limited(256 * 1024)) catch return null;
    };

    const bundle_id = extractXMLPlistBundleID(plist_bytes) orelse blk: {
        const res = std.process.run(alloc, io, .{
            .argv = &.{ "/usr/bin/plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", info_plist },
        }) catch return null;
        if (res.term != .exited or res.term.exited != 0) return null;
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (trimmed.len == 0) return null;
        break :blk trimmed;
    };

    if (!isValidOMGHostBundleID(bundle_id)) return null;
    return .{
        .bundle_path = app_dir,
        .bundle_id = bundle_id,
    };
}

fn populateHostBundleEnv(
    io: std.Io,
    alloc: std.mem.Allocator,
    executable_dir: []const u8,
    env_map: *std.process.Environ.Map,
) !void {
    if (detectHostAppBundle(io, alloc, executable_dir)) |host| {
        try env_map.put("OMG_HOST_APP_BUNDLE", host.bundle_path);
        try env_map.put("OMG_HOST_APP_BUNDLE_ID", host.bundle_id);
    }
}

/// Manage OMG's saved local and SSH sessions without opening a terminal.
///
///   omg +sessions list
///   omg +sessions list --local --json
///   omg +sessions close --all --yes
///
/// Release and Dev use separate catalogues. Run `omg +sessions --help`
/// for filtering and channel options. Closing requires explicit --yes.
pub fn run(gpa: std.mem.Allocator) !u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A shell can inherit another app's GHOSTTY_RESOURCES_DIR. Management must
    // stay in the invoking executable's channel, especially for bulk close.
    const executable_dir = try std.process.executableDirPathAlloc(global.io(), alloc);
    const helper = try bundledHelper(alloc, executable_dir);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ helper, "sessions" });
    var iter = try args.argsIterator(alloc, global.args());
    defer iter.deinit();
    while (iter.next()) |arg| try argv.append(alloc, try alloc.dupe(u8, arg));
    var env_map = try global.environMap();
    defer env_map.deinit();
    try populateHostBundleEnv(global.io(), alloc, executable_dir, &env_map);
    var child = try std.process.spawn(global.io(), .{
        .argv = argv.items,
        .environ_map = &env_map,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    return switch (try child.wait(global.io())) {
        .exited => |code| code,
        else => 1,
    };
}

test "sessions helper stays in executable bundle" {
    const alloc = std.testing.allocator;
    const path = try bundledHelper(alloc, "/Applications/OMG Dev.app/Contents/MacOS");
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/Applications/OMG Dev.app/Contents/Resources/session-runtime/omgd", path);
}

test "sessions populateHostBundleEnv records enclosing OMG bundle metadata" {
    if (comptime builtin.target.os.tag != .macos) return;
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);

    try tmp.dir.createDirPath(testing.io, "OMG Sessions Test.app/Contents/MacOS");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "OMG Sessions Test.app/Contents/Info.plist",
        .data = "<plist><dict><key>CFBundleIdentifier</key><string>com.jischeng.omg.debug</string></dict></plist>",
    });
    const omg_exe_dir = try std.fs.path.join(alloc, &.{ root, "OMG Sessions Test.app", "Contents", "MacOS" });
    var env_map = std.process.Environ.Map.init(alloc);
    try populateHostBundleEnv(testing.io, alloc, omg_exe_dir, &env_map);
    try testing.expectEqualStrings(
        try std.fs.path.join(alloc, &.{ root, "OMG Sessions Test.app" }),
        env_map.get("OMG_HOST_APP_BUNDLE").?,
    );
    try testing.expectEqualStrings("com.jischeng.omg.debug", env_map.get("OMG_HOST_APP_BUNDLE_ID").?);

    try tmp.dir.createDirPath(testing.io, "Foreign.app/Contents/MacOS");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "Foreign.app/Contents/Info.plist",
        .data = "<plist><dict><key>CFBundleIdentifier</key><string>com.example.foreign</string></dict></plist>",
    });
    const foreign_exe_dir = try std.fs.path.join(alloc, &.{ root, "Foreign.app", "Contents", "MacOS" });
    var foreign_env = std.process.Environ.Map.init(alloc);
    try populateHostBundleEnv(testing.io, alloc, foreign_exe_dir, &foreign_env);
    try testing.expect(foreign_env.get("OMG_HOST_APP_BUNDLE") == null);
    try testing.expect(foreign_env.get("OMG_HOST_APP_BUNDLE_ID") == null);
}
