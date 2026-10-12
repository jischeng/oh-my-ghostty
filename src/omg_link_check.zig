//! OMG: existence state for macOS Cmd-hover path candidates.
//!
//! Like VS Code's local link detector and iTerm2's semantic history, a regex
//! match is only a candidate. The host checks it against the source pane's
//! filesystem (local or SSH) and the answer is cached here, keyed by the
//! output cwd and the matched text. Only existing paths are underlined,
//! previewed, or opened. The cache is cleared on each new Cmd press so files
//! created or removed since the last press are picked up.
const Cache = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Status = enum { queued, pending, exists, missing };

/// Bound the metadata a single surface can accumulate while Cmd is held.
const max_entries = 256;

map: std.StringHashMapUnmanaged(Status) = .empty,
/// Invalidates renderer matches only when answers/epochs change, not on reads.
revision: u64 = 0,

pub fn deinit(self: *Cache, alloc: Allocator) void {
    self.clear(alloc);
    self.map.deinit(alloc);
}

pub fn clear(self: *Cache, alloc: Allocator) void {
    self.revision +%= 1;
    var it = self.map.keyIterator();
    while (it.next()) |key| alloc.free(key.*);
    self.map.clearRetainingCapacity();
}

fn keyFor(buf: []u8, cwd: []const u8, value: []const u8) ?[]const u8 {
    if (cwd.len + 1 + value.len > buf.len) return null;
    @memcpy(buf[0..cwd.len], cwd);
    buf[cwd.len] = 0;
    @memcpy(buf[cwd.len + 1 ..][0..value.len], value);
    return buf[0 .. cwd.len + 1 + value.len];
}

/// Returns the cached status, or null if this candidate was never requested.
pub fn get(self: *const Cache, cwd: []const u8, value: []const u8) ?Status {
    var buf: [8192]u8 = undefined;
    const key = keyFor(&buf, cwd, value) orelse return .missing;
    return self.map.get(key);
}

/// Record a new pending request. Returns false if the candidate is too long
/// to track; callers then treat it as missing.
pub fn putPending(self: *Cache, alloc: Allocator, cwd: []const u8, value: []const u8) Allocator.Error!bool {
    var buf: [8192]u8 = undefined;
    const key = keyFor(&buf, cwd, value) orelse return false;
    if (self.map.contains(key)) return false;
    // Never clear in the middle of a viewport scan: that would repeatedly
    // discard pending answers and reissue the same requests.
    if (self.map.count() >= max_entries) return false;
    const owned = try alloc.dupe(u8, key);
    errdefer alloc.free(owned);
    try self.map.put(alloc, owned, .pending);
    return true;
}

/// Queue a renderer-discovered candidate for dispatch on the app thread.
pub fn enqueue(self: *Cache, alloc: Allocator, cwd: []const u8, value: []const u8) !bool {
    if (self.get(cwd, value) != null) return false;
    if (!try self.putPending(alloc, cwd, value)) return false;
    var buf: [8192]u8 = undefined;
    self.map.getPtr(keyFor(&buf, cwd, value).?).?.* = .queued;
    return true;
}

pub fn hasQueued(self: *const Cache) bool {
    var it = self.map.valueIterator();
    while (it.next()) |status| if (status.* == .queued) return true;
    return false;
}

/// Apply a host answer. Answers for entries cleared by a later Cmd press are
/// ignored; returns true if a pending entry changed.
pub fn resolve(self: *Cache, cwd: []const u8, value: []const u8, exists: bool) bool {
    var buf: [8192]u8 = undefined;
    const key = keyFor(&buf, cwd, value) orelse return false;
    const status = self.map.getPtr(key) orelse return false;
    if (status.* != .pending) return false;
    status.* = if (exists) .exists else .missing;
    self.revision +%= 1;
    return true;
}

/// True for filesystem candidates. Scheme URLs (other than file:) are opened
/// by their handler and never checked against a filesystem.
pub fn needsCheck(value: []const u8) bool {
    var path = value;
    if (path.len >= 2 and (path[0] == '\'' or path[0] == '"') and path[path.len - 1] == path[0]) {
        path = path[1 .. path.len - 1];
    }
    if (std.ascii.startsWithIgnoreCase(path, "file:")) return true;
    const colon = std.mem.indexOfScalar(u8, path, ':') orelse return true;
    if (colon == 0 or !std.ascii.isAlphabetic(path[0])) return true;
    for (path[0..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '.' and c != '-') return true;
    }
    // `README.md:12:3` is a path with a location suffix, not a scheme.
    for (path[colon + 1 ..]) |c| {
        if (!std.ascii.isDigit(c) and c != ':') return false;
    }
    return true;
}

test "OMG link check distinguishes paths from scheme URLs" {
    const testing = std.testing;
    try testing.expect(needsCheck("shell.nix"));
    try testing.expect(needsCheck("src/main.zig:12:3"));
    try testing.expect(needsCheck("README.md:12"));
    try testing.expect(needsCheck("/tmp/file"));
    try testing.expect(needsCheck("~/file"));
    try testing.expect(needsCheck("'App icon.icon'"));
    try testing.expect(needsCheck("file:///tmp/a"));
    try testing.expect(!needsCheck("https://example.com/a"));
    try testing.expect(!needsCheck("mailto:user@example.com"));
    try testing.expect(!needsCheck("'https://example.com'"));
}

test "OMG link check cache tracks pending answers per cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);

    try testing.expect(cache.get("/a", "x.md") == null);
    try testing.expect(try cache.putPending(alloc, "/a", "x.md"));
    try testing.expectEqual(Status.pending, cache.get("/a", "x.md").?);
    try testing.expect(cache.get("/b", "x.md") == null);

    try testing.expect(cache.resolve("/a", "x.md", true));
    try testing.expectEqual(Status.exists, cache.get("/a", "x.md").?);
    // A late duplicate answer does not flip a settled entry.
    try testing.expect(!cache.resolve("/a", "x.md", false));

    // Answers for cleared entries are ignored.
    cache.clear(alloc);
    try testing.expect(!cache.resolve("/a", "x.md", false));
    try testing.expect(cache.get("/a", "x.md") == null);
}

test "OMG link check cache stays bounded" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    var buf: [16]u8 = undefined;
    for (0..max_entries + 10) |i| {
        const value = try std.fmt.bufPrint(&buf, "f{d}", .{i});
        _ = try cache.putPending(alloc, "/a", value);
    }
    try testing.expect(cache.map.count() <= max_entries);
}
