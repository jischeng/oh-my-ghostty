//! Wire adapter for Ghostty's already-resolved local command configuration.
const std = @import("std");
const renderer = @import("../../renderer.zig");

pub const max_initial_input = 10 * 1024 * 1024;
pub const max_runtime_scrollback_bytes = 4 * 1024 * 1024;

pub const ScrollbackLimits = struct {
    max_bytes: usize,
    max_lines: ?usize,
};

/// Session snapshots must stay within the current bounded snapshot transport.
/// Never raise a stricter Ghostty limit when deriving the runtime limit.
pub fn effectiveScrollbackLimits(configured_bytes: ?usize, configured_lines: ?usize) ScrollbackLimits {
    return .{
        .max_bytes = if (configured_bytes) |value|
            @min(value, max_runtime_scrollback_bytes)
        else
            max_runtime_scrollback_bytes,
        .max_lines = configured_lines,
    };
}

/// A daemon must inherit the caller's directory, not the broker's startup cwd.
/// Candidates are tried in order (configured/inherited pane directory, the
/// open request's directory, HOME). The GUI's own cwd is only a last resort:
/// a desktop launch starts at `/`, which must not leak into new shells.
pub fn workingDirectory(alloc: std.mem.Allocator, io: std.Io, candidates: []const ?[]const u8) ![:0]u8 {
    const inherited = try std.process.currentPathAlloc(io, alloc);
    errdefer alloc.free(inherited);
    for (candidates) |proposed| {
        const value = proposed orelse continue;
        if (value.len == 0) continue;
        const candidate = try std.fs.path.resolve(alloc, &.{ inherited, value });
        defer alloc.free(candidate);
        var directory = std.Io.Dir.cwd().openDir(io, candidate, .{}) catch continue;
        directory.close(io);
        const result = try alloc.dupeZ(u8, candidate);
        alloc.free(inherited);
        return result;
    }
    return inherited;
}

/// The directory Swift chose for this pane (source pane, launch directory or
/// home). Caller owns the result.
pub fn requestedWorkingDirectory(alloc: std.mem.Allocator, request: ?[]const u8) ?[]u8 {
    const bytes = request orelse return null;
    const parsed = std.json.parseFromSlice(OpenRequest, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const cwd = parsed.value.cwd orelse return null;
    return alloc.dupe(u8, cwd) catch null;
}

const OpenRequest = struct {
    id: []const u8,
    policy: std.json.Value,
    create: bool,
    cwd: ?[]const u8 = null,
    recreate_if_gone: ?bool = null,
};

pub fn createsSession(alloc: std.mem.Allocator, request: ?[]const u8) bool {
    const bytes = request orelse return false;
    const parsed = std.json.parseFromSlice(OpenRequest, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    return parsed.value.create;
}

pub fn isOpenRequest(alloc: std.mem.Allocator, request: ?[]const u8) bool {
    const bytes = request orelse return false;
    const parsed = std.json.parseFromSlice(OpenRequest, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return false;
    parsed.deinit();
    return true;
}

pub fn hasResurrectLaunch(alloc: std.mem.Allocator, request: ?[]const u8) bool {
    const bytes = request orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    return parsed.value.object.contains("resurrect_launch");
}

fn childEnvironmentKey(key: []const u8) bool {
    return !std.mem.startsWith(u8, key, "OMG_RUNTIME_") and
        !std.mem.eql(u8, key, "OMG_SESSION_RUNTIME_DESCRIPTOR") and
        !std.mem.eql(u8, key, "GHOSTTY_SURFACE_ID");
}

const Environment = struct {
    map: *const std.process.Environ.Map,

    pub fn jsonStringify(self: Environment, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        try writer.beginObject();
        var entries = self.map.iterator();
        while (entries.next()) |entry| {
            if (!childEnvironmentKey(entry.key_ptr.*)) continue;
            try writer.objectField(entry.key_ptr.*);
            try writer.write(entry.value_ptr.*);
        }
        try writer.endObject();
    }
};

pub fn prepare(
    alloc: std.mem.Allocator,
    request: []const u8,
    argv: []const [:0]const u8,
    environment: *const std.process.Environ.Map,
    cwd: ?[]const u8,
    grid: renderer.GridSize,
    screen: renderer.ScreenSize,
    configured_scrollback_bytes: ?usize,
    configured_scrollback_lines: ?usize,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(OpenRequest, alloc, request, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!parsed.value.create) return attachOnly(alloc, request);
    const scrollback = effectiveScrollbackLimits(configured_scrollback_bytes, configured_scrollback_lines);
    return std.json.Stringify.valueAlloc(alloc, .{
        .id = parsed.value.id,
        .policy = parsed.value.policy,
        .create = true,
        .cwd = cwd orelse parsed.value.cwd,
        .launch = .{
            .argv = argv,
            .env = Environment{ .map = environment },
            .cwd = cwd orelse parsed.value.cwd,
            .cols = grid.columns,
            .rows = grid.rows,
            .pixel_width = @min(screen.width, std.math.maxInt(u16)),
            .pixel_height = @min(screen.height, std.math.maxInt(u16)),
            .scrollback_max_bytes = scrollback.max_bytes,
            .scrollback_max_lines = scrollback.max_lines,
        },
    }, .{ .emit_null_optional_fields = false });
}

pub fn prepareResurrect(
    alloc: std.mem.Allocator,
    request: []const u8,
    argv: []const [:0]const u8,
    environment: *const std.process.Environ.Map,
    cwd: ?[]const u8,
    grid: renderer.GridSize,
    screen: renderer.ScreenSize,
    configured_scrollback_bytes: ?usize,
    configured_scrollback_lines: ?usize,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(OpenRequest, alloc, request, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.create) {
        return prepare(
            alloc,
            request,
            argv,
            environment,
            cwd,
            grid,
            screen,
            configured_scrollback_bytes,
            configured_scrollback_lines,
        );
    }
    const scrollback = effectiveScrollbackLimits(configured_scrollback_bytes, configured_scrollback_lines);
    return std.json.Stringify.valueAlloc(alloc, .{
        .id = parsed.value.id,
        .policy = parsed.value.policy,
        .create = false,
        .cwd = parsed.value.cwd,
        .recreate_if_gone = if (parsed.value.recreate_if_gone orelse false) true else null,
        .resurrect_launch = .{
            .argv = argv,
            .env = Environment{ .map = environment },
            .cwd = cwd orelse parsed.value.cwd,
            .cols = grid.columns,
            .rows = grid.rows,
            .pixel_width = @min(screen.width, std.math.maxInt(u16)),
            .pixel_height = @min(screen.height, std.math.maxInt(u16)),
            .scrollback_max_bytes = scrollback.max_bytes,
            .scrollback_max_lines = scrollback.max_lines,
        },
    }, .{ .emit_null_optional_fields = false });
}

/// Startup input is part of creation, never a replayable client input queue.
pub fn withInitialInput(
    alloc: std.mem.Allocator,
    request: []const u8,
    input: []const u8,
    grid: u32,
    pixels: u32,
) ![]u8 {
    if (input.len > max_initial_input) return error.InitialInputTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenRequest;
    const launch = parsed.value.object.getPtr("launch") orelse return error.MissingLocalLaunch;
    if (launch.* != .object) return error.InvalidOpenRequest;
    const arena = parsed.arena.allocator();
    try launch.object.put(arena, "cols", .{ .integer = grid >> 16 });
    try launch.object.put(arena, "rows", .{ .integer = grid & 0xffff });
    try launch.object.put(arena, "pixel_width", .{ .integer = pixels >> 16 });
    try launch.object.put(arena, "pixel_height", .{ .integer = pixels & 0xffff });
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(input.len));
    defer {
        std.crypto.secureZero(u8, encoded);
        alloc.free(encoded);
    }
    if (input.len > 0) {
        _ = std.base64.standard.Encoder.encode(encoded, input);
        try launch.object.put(arena, "input_base64", .{ .string = encoded });
    }
    return std.json.Stringify.valueAlloc(alloc, parsed.value, .{});
}

pub const ClientContext = struct {
    term: ?[]const u8 = null,
    colorterm: []const u8 = "truecolor",
    term_program: []const u8 = "ghostty",
    version: []const u8 = "",
    dark_scheme: ?bool = null,
    foreground: ?[3]u8 = null,
    background: ?[3]u8 = null,
    cursor: ?[3]u8 = null,
};

fn putRgbArray(
    arena: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    key: []const u8,
    rgb: [3]u8,
) !void {
    var arr = std.json.Array.init(arena);
    try arr.append(.{ .integer = rgb[0] });
    try arr.append(.{ .integer = rgb[1] });
    try arr.append(.{ .integer = rgb[2] });
    try obj.put(arena, key, .{ .array = arr });
}

/// Attach runtime client dimensions, identity, and theme colors to a remote
/// creation/recreate `OpenRequest` without disturbing attach-only payloads.
pub fn withRemoteClientContext(
    alloc: std.mem.Allocator,
    request: []const u8,
    grid: u32,
    pixels: u32,
    context: ?ClientContext,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, request, .{}) catch {
        return alloc.dupe(u8, request);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, request);

    const create = if (parsed.value.object.get("create")) |v| v == .bool and v.bool else false;
    const recreate = if (parsed.value.object.get("recreate_if_gone")) |v| v == .bool and v.bool else false;
    if (!create and !recreate) return alloc.dupe(u8, request);

    const arena = parsed.arena.allocator();
    const cols: u16 = @intCast(grid >> 16);
    const rows: u16 = @intCast(grid & 0xffff);
    const px_w: u16 = @intCast(pixels >> 16);
    const px_h: u16 = @intCast(pixels & 0xffff);
    if (cols > 0 and cols <= 500) try parsed.value.object.put(arena, "cols", .{ .integer = cols });
    if (rows > 0 and rows <= 300) try parsed.value.object.put(arena, "rows", .{ .integer = rows });
    if (px_w > 0) try parsed.value.object.put(arena, "pixel_width", .{ .integer = px_w });
    if (px_h > 0) try parsed.value.object.put(arena, "pixel_height", .{ .integer = px_h });

    if (context) |ctx| {
        if (ctx.term) |term| {
            if (term.len > 0 and term.len <= 128 and !parsed.value.object.contains("term")) {
                try parsed.value.object.put(arena, "term", .{ .string = term });
            }
        }
        if (ctx.colorterm.len > 0 and ctx.colorterm.len <= 128 and !parsed.value.object.contains("colorterm")) {
            try parsed.value.object.put(arena, "colorterm", .{ .string = ctx.colorterm });
        }
        if (ctx.term_program.len > 0 and ctx.term_program.len <= 128 and !parsed.value.object.contains("term_program")) {
            try parsed.value.object.put(arena, "term_program", .{ .string = ctx.term_program });
        }
        if (ctx.version.len > 0 and ctx.version.len <= 128 and !parsed.value.object.contains("term_program_version")) {
            try parsed.value.object.put(arena, "term_program_version", .{ .string = ctx.version });
        }
        if (ctx.dark_scheme) |dark| {
            if (!parsed.value.object.contains("color_scheme")) {
                try parsed.value.object.put(arena, "color_scheme", .{ .string = if (dark) "dark" else "light" });
            }
        }
        if (ctx.foreground) |fg| {
            if (!parsed.value.object.contains("foreground")) {
                try putRgbArray(arena, &parsed.value.object, "foreground", fg);
            }
        }
        if (ctx.background) |bg| {
            if (!parsed.value.object.contains("background")) {
                try putRgbArray(arena, &parsed.value.object, "background", bg);
            }
        }
        if (ctx.cursor) |cursor| {
            if (!parsed.value.object.contains("cursor")) {
                try putRgbArray(arena, &parsed.value.object, "cursor", cursor);
            }
        }
    }

    return std.json.Stringify.valueAlloc(alloc, parsed.value, .{});
}

pub fn attachOnly(alloc: std.mem.Allocator, request: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(OpenRequest, alloc, request, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return std.json.Stringify.valueAlloc(alloc, .{
        .id = parsed.value.id,
        .policy = parsed.value.policy,
        .create = false,
    }, .{});
}

test "local session launch preserves prepared shell environment without app routing" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("TERM", "xterm-ghostty");
    try env.put("GHOSTTY_RESOURCES_DIR", "/bundle/resources");
    try env.put("ZDOTDIR", "/bundle/shell-integration/zsh");
    try env.put("MY_SETTING", "space and Unicode \xe7\x95\x8c");
    try env.put("OMG_SSH_HANDOFF_TOKEN", "stable-session-capability");
    try env.put("OMG_QUICK_INPUT_BRIDGE", "/stable/editor");
    try env.put("OMG_RUNTIME_SOCKET", "/old-app/socket");
    try env.put("OMG_RUNTIME_LOCAL", "1");
    try env.put("OMG_SESSION_RUNTIME_DESCRIPTOR", "private-routing");
    try env.put("GHOSTTY_SURFACE_ID", "old-process-pointer");
    const request = try prepare(
        alloc,
        "{\"id\":\"pane\",\"policy\":{},\"create\":true}",
        &.{ "/usr/bin/login", "-flp", "user", "/bin/zsh", "-l" },
        &env,
        "/tmp/project",
        .{ .columns = 91, .rows = 35 },
        .{ .width = 728, .height = 560 },
        50_000_000,
        100,
    );
    defer alloc.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    const launch = parsed.value.object.get("launch").?.object;
    const child = launch.get("env").?.object;
    try std.testing.expectEqualStrings("/usr/bin/login", launch.get("argv").?.array.items[0].string);
    try std.testing.expectEqualStrings("/tmp/project", launch.get("cwd").?.string);
    try std.testing.expectEqual(@as(i64, 4 * 1024 * 1024), launch.get("scrollback_max_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 100), launch.get("scrollback_max_lines").?.integer);
    try std.testing.expectEqualStrings("xterm-ghostty", child.get("TERM").?.string);
    try std.testing.expectEqualStrings("/bundle/shell-integration/zsh", child.get("ZDOTDIR").?.string);
    try std.testing.expectEqualStrings("space and Unicode \xe7\x95\x8c", child.get("MY_SETTING").?.string);
    try std.testing.expect(child.contains("OMG_SSH_HANDOFF_TOKEN"));
    try std.testing.expect(child.contains("OMG_QUICK_INPUT_BRIDGE"));
    try std.testing.expect(!child.contains("OMG_RUNTIME_SOCKET"));
    try std.testing.expect(!child.contains("OMG_RUNTIME_LOCAL"));
    try std.testing.expect(!child.contains("OMG_SESSION_RUNTIME_DESCRIPTOR"));
    try std.testing.expect(!child.contains("GHOSTTY_SURFACE_ID"));
}

test "local session startup input belongs only to the original creation" {
    const alloc = std.testing.allocator;
    const initial = "{\"id\":\"pane\",\"policy\":{},\"create\":true,\"launch\":{\"argv\":[\"sh\"],\"env\":{\"SECRET\":\"value\"}}}";
    const request = try withInitialInput(alloc, initial, "echo once\n\x00", (100 << 16) | 30, (800 << 16) | 480);
    defer alloc.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    const launch = parsed.value.object.get("launch").?.object;
    try std.testing.expectEqual(@as(i64, 100), launch.get("cols").?.integer);
    try std.testing.expectEqual(@as(i64, 30), launch.get("rows").?.integer);
    const encoded = launch.get("input_base64").?.string;
    const decoded = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    defer alloc.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    try std.testing.expectEqualStrings("echo once\n\x00", decoded);
    const attached = try attachOnly(alloc, request);
    defer alloc.free(attached);
    try std.testing.expect(std.mem.indexOf(u8, attached, "launch") == null);
    try std.testing.expect(std.mem.indexOf(u8, attached, "SECRET") == null);
    try std.testing.expect(!createsSession(alloc, attached));
}

test "local session cwd fallback matches the launching process" {
    const alloc = std.testing.allocator;
    const inherited = try std.process.currentPathAlloc(std.testing.io, alloc);
    defer alloc.free(inherited);
    const fallback = try workingDirectory(alloc, std.testing.io, &.{"/nonexistent/omg-local-session-fixture"});
    defer alloc.free(fallback);
    try std.testing.expectEqualStrings(inherited, fallback);
    const relative = try workingDirectory(alloc, std.testing.io, &.{"."});
    defer alloc.free(relative);
    try std.testing.expectEqualStrings(inherited, relative);
}

test "local session cwd prefers later valid candidates over the process cwd" {
    const alloc = std.testing.allocator;
    const chosen = try workingDirectory(alloc, std.testing.io, &.{ null, "file:/host.local", "/nonexistent/omg-x", "/tmp" });
    defer alloc.free(chosen);
    try std.testing.expectEqualStrings("/tmp", chosen);
    const requested = requestedWorkingDirectory(alloc, "{\"id\":\"a\",\"policy\":{},\"create\":true,\"cwd\":\"/tmp\"}").?;
    defer alloc.free(requested);
    try std.testing.expectEqualStrings("/tmp", requested);
    try std.testing.expect(requestedWorkingDirectory(alloc, "{\"id\":\"a\",\"policy\":{},\"create\":true}") == null);
}

test "runtime scrollback preserves stricter Ghostty limits and clamps wider ones" {
    const unlimited = effectiveScrollbackLimits(null, null);
    try std.testing.expectEqual(@as(usize, max_runtime_scrollback_bytes), unlimited.max_bytes);
    try std.testing.expect(unlimited.max_lines == null);

    const disabled = effectiveScrollbackLimits(0, 0);
    try std.testing.expectEqual(@as(usize, 0), disabled.max_bytes);
    try std.testing.expectEqual(@as(?usize, 0), disabled.max_lines);

    const strict = effectiveScrollbackLimits(1024, 32);
    try std.testing.expectEqual(@as(usize, 1024), strict.max_bytes);
    try std.testing.expectEqual(@as(?usize, 32), strict.max_lines);

    const wider = effectiveScrollbackLimits(50_000_000, null);
    try std.testing.expectEqual(@as(usize, max_runtime_scrollback_bytes), wider.max_bytes);
    try std.testing.expect(wider.max_lines == null);
}

test "local session resurrect prepares resurrect_launch without input_base64 and attachOnly clears it" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("TERM", "xterm-ghostty");
    try env.put("OMG_RUNTIME_RESURRECT_CWD", "/tmp/saved-pane");
    try env.put("OMG_RUNTIME_SOCKET", "/tmp/runtime.sock");
    const request = try prepareResurrect(
        alloc,
        "{\"id\":\"pane\",\"policy\":{},\"create\":false}",
        &.{ "/usr/bin/login", "-flp", "user", "/bin/zsh", "-l" },
        &env,
        "/tmp/saved-pane",
        .{ .columns = 90, .rows = 30 },
        .{ .width = 720, .height = 480 },
        2048,
        50,
    );
    defer alloc.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("create").?.bool);
    try std.testing.expect(!parsed.value.object.contains("launch"));
    const resurrect = parsed.value.object.get("resurrect_launch").?.object;
    try std.testing.expectEqualStrings("/tmp/saved-pane", resurrect.get("cwd").?.string);
    try std.testing.expect(!resurrect.contains("input_base64"));
    try std.testing.expectEqual(@as(i64, 2048), resurrect.get("scrollback_max_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 50), resurrect.get("scrollback_max_lines").?.integer);
    const child_env = resurrect.get("env").?.object;
    try std.testing.expectEqualStrings("xterm-ghostty", child_env.get("TERM").?.string);
    try std.testing.expect(!child_env.contains("OMG_RUNTIME_RESURRECT_CWD"));
    try std.testing.expect(!child_env.contains("OMG_RUNTIME_SOCKET"));

    const attached = try attachOnly(alloc, request);
    defer alloc.free(attached);
    try std.testing.expect(std.mem.indexOf(u8, attached, "resurrect_launch") == null);
    try std.testing.expect(!createsSession(alloc, attached));
}

test "local session launch preserves recreate_if_gone in prepareResurrect and omits it in attachOnly" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("TERM", "xterm-ghostty");

    const with_recreate = try prepareResurrect(
        alloc,
        "{\"id\":\"pane\",\"policy\":{},\"create\":false,\"cwd\":\"/tmp/saved\",\"recreate_if_gone\":true}",
        &.{ "/bin/zsh", "-l" },
        &env,
        "/tmp/saved",
        .{ .columns = 80, .rows = 24 },
        .{ .width = 640, .height = 384 },
        null,
        null,
    );
    defer alloc.free(with_recreate);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, with_recreate, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("recreate_if_gone").?.bool);
    try std.testing.expectEqualStrings("/tmp/saved", parsed.value.object.get("cwd").?.string);

    const attached = try attachOnly(alloc, with_recreate);
    defer alloc.free(attached);
    try std.testing.expect(std.mem.indexOf(u8, attached, "recreate_if_gone") == null);

    const without_recreate = try prepareResurrect(
        alloc,
        "{\"id\":\"pane\",\"policy\":{},\"create\":false,\"recreate_if_gone\":false}",
        &.{ "/bin/zsh", "-l" },
        &env,
        "/tmp/saved",
        .{ .columns = 80, .rows = 24 },
        .{ .width = 640, .height = 384 },
        null,
        null,
    );
    defer alloc.free(without_recreate);
    try std.testing.expect(std.mem.indexOf(u8, without_recreate, "recreate_if_gone") == null);
}

test "remote client context enriches create and recreate requests only" {
    const alloc = std.testing.allocator;
    const grid = (@as(u32, 120) << 16) | 36;
    const pixels = (@as(u32, 1200) << 16) | 720;
    const ctx: ClientContext = .{
        .term = "xterm-ghostty",
        .version = "0.21.4-test",
        .dark_scheme = true,
        .foreground = .{ 0xff, 0xff, 0xff },
        .background = .{ 0x28, 0x2c, 0x34 },
        .cursor = .{ 0xff, 0xaa, 0x00 },
    };

    const created = try withRemoteClientContext(alloc, "{\"id\":\"pane\",\"policy\":{},\"create\":true}", grid, pixels, ctx);
    defer alloc.free(created);
    const parsed_created = try std.json.parseFromSlice(std.json.Value, alloc, created, .{});
    defer parsed_created.deinit();
    try std.testing.expectEqual(@as(i64, 120), parsed_created.value.object.get("cols").?.integer);
    try std.testing.expectEqual(@as(i64, 36), parsed_created.value.object.get("rows").?.integer);
    try std.testing.expectEqual(@as(i64, 1200), parsed_created.value.object.get("pixel_width").?.integer);
    try std.testing.expectEqual(@as(i64, 720), parsed_created.value.object.get("pixel_height").?.integer);
    try std.testing.expectEqualStrings("xterm-ghostty", parsed_created.value.object.get("term").?.string);
    try std.testing.expectEqualStrings("truecolor", parsed_created.value.object.get("colorterm").?.string);
    try std.testing.expectEqualStrings("ghostty", parsed_created.value.object.get("term_program").?.string);
    try std.testing.expectEqualStrings("0.21.4-test", parsed_created.value.object.get("term_program_version").?.string);
    try std.testing.expectEqualStrings("dark", parsed_created.value.object.get("color_scheme").?.string);

    const attached = try withRemoteClientContext(alloc, "{\"id\":\"pane\",\"policy\":{},\"create\":false}", grid, pixels, ctx);
    defer alloc.free(attached);
    try std.testing.expect(std.mem.indexOf(u8, attached, "cols") == null);
    try std.testing.expect(std.mem.indexOf(u8, attached, "term_program") == null);

    // Custom Ghostty config.term and light theme are preserved when request omits "term",
    // while an explicit request "term" continues to take precedence.
    const custom_ctx: ClientContext = .{
        .term = "screen-256color",
        .version = "1.3.2-test",
        .dark_scheme = false,
        .foreground = .{ 0x10, 0x10, 0x10 },
        .background = .{ 0xfa, 0xfa, 0xfa },
    };
    const custom = try withRemoteClientContext(alloc, "{\"id\":\"pane\",\"policy\":{},\"create\":true}", grid, pixels, custom_ctx);
    defer alloc.free(custom);
    const parsed_custom = try std.json.parseFromSlice(std.json.Value, alloc, custom, .{});
    defer parsed_custom.deinit();
    try std.testing.expectEqualStrings("screen-256color", parsed_custom.value.object.get("term").?.string);
    try std.testing.expectEqualStrings("light", parsed_custom.value.object.get("color_scheme").?.string);

    const preset = try withRemoteClientContext(
        alloc,
        "{\"id\":\"pane\",\"policy\":{},\"create\":true,\"term\":\"xterm-256color\"}",
        grid,
        pixels,
        custom_ctx,
    );
    defer alloc.free(preset);
    const parsed_preset = try std.json.parseFromSlice(std.json.Value, alloc, preset, .{});
    defer parsed_preset.deinit();
    try std.testing.expectEqualStrings("xterm-256color", parsed_preset.value.object.get("term").?.string);
}
