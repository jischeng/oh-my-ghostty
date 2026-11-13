//! OMG: existence state for macOS Cmd-hover path candidates.
//!
//! Like VS Code's local link detector and iTerm2's semantic history, a regex
//! match is only a candidate. The host checks it against the source pane's
//! filesystem (local or SSH) and the answer is cached here, keyed by the
//! output cwd and the matched text. Only existing paths are underlined,
//! previewed, or opened. Settled entries live for a short TTL across Cmd taps
//! so immediate Cmd-clicks work without starving newly created/removed files.
const Cache = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Status = enum { queued, pending, exists, missing };

pub const Entry = struct {
    status: Status,
    updated_ms: i64 = 0,
};

/// Bound the metadata a single surface can accumulate while Cmd is held.
const max_entries = 256;

/// Short TTL for settled answers across Cmd presses so immediate Cmd+Click
/// does not discard recently verified links while still picking up filesystem
/// edits after a few seconds.
pub const ttl_ms: i64 = 3_000;

map: std.StringHashMapUnmanaged(Entry) = .empty,
/// Monotonic host clock observed on the latest Cmd press or answer.
clock_ms: i64 = 0,
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

/// Prune settled entries older than `ttl_ms` (and abandoned in-flight requests
/// older than `2 * ttl_ms`) while preserving fresh positive/negative answers
/// across quick Cmd taps.
pub fn pruneExpired(self: *Cache, alloc: Allocator, now_ms: i64) void {
    self.clock_ms = now_ms;
    var expired: [max_entries][]const u8 = undefined;
    var expired_len: usize = 0;
    var it = self.map.iterator();
    while (it.next()) |item| {
        const age = now_ms - item.value_ptr.updated_ms;
        const limit: i64 = switch (item.value_ptr.status) {
            .exists, .missing => ttl_ms,
            .queued, .pending => ttl_ms * 2,
        };
        if (age >= limit and expired_len < expired.len) {
            expired[expired_len] = item.key_ptr.*;
            expired_len += 1;
        }
    }
    if (expired_len == 0) return;
    for (expired[0..expired_len]) |key| {
        _ = self.map.remove(key);
        alloc.free(key);
    }
    self.revision +%= 1;
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
    const entry = self.map.get(key) orelse return null;
    return entry.status;
}

fn evictOldestSettled(self: *Cache, alloc: Allocator) bool {
    var victim_key: ?[]const u8 = null;
    var victim_ms: i64 = std.math.maxInt(i64);
    var it = self.map.iterator();
    while (it.next()) |item| {
        switch (item.value_ptr.status) {
            .exists, .missing => {
                if (victim_key == null or item.value_ptr.updated_ms < victim_ms) {
                    victim_key = item.key_ptr.*;
                    victim_ms = item.value_ptr.updated_ms;
                }
            },
            .queued, .pending => {},
        }
    }
    const key = victim_key orelse return false;
    _ = self.map.remove(key);
    alloc.free(key);
    return true;
}

/// Record a new pending request. Returns false if the candidate is too long
/// to track or already tracked; callers then treat it as missing/in-flight.
pub fn putPendingAt(self: *Cache, alloc: Allocator, cwd: []const u8, value: []const u8, now_ms: i64) Allocator.Error!bool {
    self.clock_ms = @max(self.clock_ms, now_ms);
    var buf: [8192]u8 = undefined;
    const key = keyFor(&buf, cwd, value) orelse return false;
    if (self.map.contains(key)) return false;
    // Never discard in-flight pending answers in the middle of a viewport scan,
    // but allow evicting an older settled answer if the cache is at capacity.
    if (self.map.count() >= max_entries and !self.evictOldestSettled(alloc)) return false;
    const owned = try alloc.dupe(u8, key);
    errdefer alloc.free(owned);
    try self.map.put(alloc, owned, .{ .status = .pending, .updated_ms = now_ms });
    return true;
}

pub fn putPending(self: *Cache, alloc: Allocator, cwd: []const u8, value: []const u8) Allocator.Error!bool {
    return self.putPendingAt(alloc, cwd, value, self.clock_ms);
}

/// Queue a renderer-discovered candidate for dispatch on the app thread.
pub fn enqueue(self: *Cache, alloc: Allocator, cwd: []const u8, value: []const u8) !bool {
    if (self.get(cwd, value) != null) return false;
    if (!try self.putPending(alloc, cwd, value)) return false;
    var buf: [8192]u8 = undefined;
    self.map.getPtr(keyFor(&buf, cwd, value).?).?.status = .queued;
    return true;
}

pub fn hasQueued(self: *const Cache) bool {
    var it = self.map.valueIterator();
    while (it.next()) |entry| if (entry.status == .queued) return true;
    return false;
}

/// Apply a host answer. Answers for entries cleared by a later eviction are
/// ignored; returns true if a queued/pending entry settled.
pub fn resolveAt(self: *Cache, cwd: []const u8, value: []const u8, exists: bool, now_ms: i64) bool {
    self.clock_ms = @max(self.clock_ms, now_ms);
    var buf: [8192]u8 = undefined;
    const key = keyFor(&buf, cwd, value) orelse return false;
    const entry = self.map.getPtr(key) orelse return false;
    if (entry.status != .pending and entry.status != .queued) return false;
    entry.status = if (exists) .exists else .missing;
    entry.updated_ms = now_ms;
    self.revision +%= 1;
    return true;
}

pub fn resolve(self: *Cache, cwd: []const u8, value: []const u8, exists: bool) bool {
    return self.resolveAt(cwd, value, exists, self.clock_ms);
}

/// Standalone root separators in prose/code aren't useful implicit links.
/// Explicit OSC8 links retain their author-provided target.
pub fn isBareRoot(value: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n'\"`"), "/");
}

test "OMG bare root is not an implicit link" {
    try std.testing.expect(isBareRoot("/"));
    try std.testing.expect(isBareRoot("'/'"));
    try std.testing.expect(isBareRoot("`/`"));
    try std.testing.expect(!isBareRoot("/home/user"));
}

/// True for filesystem candidates. Scheme URLs (other than file:) are opened
/// by their handler and never checked against a filesystem.
pub fn needsCheck(value: []const u8) bool {
    var path = value;
    if (path.len >= 2 and (path[0] == '\'' or path[0] == '"' or path[0] == '`') and path[path.len - 1] == path[0]) {
        path = path[1 .. path.len - 1];
    }
    if (std.ascii.startsWithIgnoreCase(path, "file:")) return true;
    const colon = std.mem.indexOfScalar(u8, path, ':') orelse return true;
    if (colon == 0 or !std.ascii.isAlphabetic(path[0])) return true;
    for (path[0..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '.' and c != '-') return true;
    }
    // `README.md:12:3` and `README.md:12-40` are paths with location suffixes, not schemes.
    for (path[colon + 1 ..]) |c| {
        if (!std.ascii.isDigit(c) and c != ':' and c != '-') return false;
    }
    return true;
}

test "OMG link check distinguishes paths from scheme URLs" {
    const testing = std.testing;
    try testing.expect(needsCheck("shell.nix"));
    try testing.expect(needsCheck("src/main.zig:12:3"));
    try testing.expect(needsCheck("src/main.zig:12-40"));
    try testing.expect(needsCheck("README.md:12"));
    try testing.expect(needsCheck("README.md:12-40"));
    try testing.expect(needsCheck("README.md#L12-L40"));
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

test "OMG link check cache preserves recent settled entries across Cmd taps and expires stale ones" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);

    try testing.expect(try cache.putPendingAt(alloc, "/repo", "README.md", 1_000));
    try testing.expect(cache.resolveAt("/repo", "README.md", true, 1_050));
    try testing.expect(try cache.putPendingAt(alloc, "/repo", "missing.md", 1_000));
    try testing.expect(cache.resolveAt("/repo", "missing.md", false, 1_050));
    try testing.expect(try cache.putPendingAt(alloc, "/repo", "inflight.md", 1_000));

    // A quick Cmd re-press within TTL preserves both settled and in-flight entries.
    cache.pruneExpired(alloc, 2_500);
    try testing.expectEqual(Status.exists, cache.get("/repo", "README.md").?);
    try testing.expectEqual(Status.missing, cache.get("/repo", "missing.md").?);
    try testing.expectEqual(Status.pending, cache.get("/repo", "inflight.md").?);

    // After TTL elapses, settled entries expire while recent in-flight still has slack.
    cache.pruneExpired(alloc, 1_050 + ttl_ms);
    try testing.expect(cache.get("/repo", "README.md") == null);
    try testing.expect(cache.get("/repo", "missing.md") == null);
    try testing.expectEqual(Status.pending, cache.get("/repo", "inflight.md").?);

    // Abandoned in-flight requests also expire after 2 * TTL.
    cache.pruneExpired(alloc, 1_000 + ttl_ms * 2);
    try testing.expect(cache.get("/repo", "inflight.md") == null);
}
