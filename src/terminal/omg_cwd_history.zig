//! Cwd transitions anchored to existing page-list tracked pins. This stores one
//! entry per cwd change, not per output row, and never guesses from recent paths.
const Self = @This();
const std = @import("std");
const PageList = @import("PageList.zig");
const Allocator = std.mem.Allocator;

const Entry = struct { pin: *PageList.Pin, cwd: []const u8 };
const max_entries = 1024;
const max_cwd_bytes = 4096;
entries: std.ArrayList(Entry) = .empty,

pub fn deinit(self: *Self, alloc: Allocator, pages: *PageList) void {
    for (self.entries.items) |entry| {
        pages.untrackPin(entry.pin);
        alloc.free(entry.cwd);
    }
    self.entries.deinit(alloc);
    self.* = .{};
}

fn remove(self: *Self, alloc: Allocator, pages: *PageList, index: usize) void {
    const entry = self.entries.orderedRemove(index);
    pages.untrackPin(entry.pin);
    alloc.free(entry.cwd);
}

pub fn record(self: *Self, alloc: Allocator, pages: *PageList, cursor: PageList.Pin, cwd: []const u8) !void {
    // Pruned scrollback pins collapse onto the same top-left position. Keep the
    // latest transition there, which is the cwd for the remaining output.
    var i: usize = 0;
    while (i + 1 < self.entries.items.len) {
        if (self.entries.items[i].pin.eql(self.entries.items[i + 1].pin.*)) {
            self.remove(alloc, pages, i);
        } else i += 1;
    }
    // OSC7 normally arrives at a prompt's start. Preserve its precise pin so
    // wrapped lines and resize reflow retain the correct output boundary.
    while (self.entries.items.len > 0) {
        const last = self.entries.items[self.entries.items.len - 1];
        if (last.pin.before(cursor)) break;
        self.remove(alloc, pages, self.entries.items.len - 1);
    }
    const value = if (cwd.len <= max_cwd_bytes) cwd else "";
    if (self.entries.items.len > 0 and
        std.mem.eql(u8, self.entries.items[self.entries.items.len - 1].cwd, value)) return;

    const copy = try alloc.dupe(u8, value);
    errdefer alloc.free(copy);
    const pin = try pages.trackPin(cursor);
    errdefer pages.untrackPin(pin);
    try self.entries.append(alloc, .{ .pin = pin, .cwd = copy });
    // An older click before the first retained anchor returns unknown, never
    // the current cwd. Also cap each path so terminal output cannot grow this
    // metadata without bound (at most 1024 paths of 4096 bytes).
    if (self.entries.items.len > max_entries) self.remove(alloc, pages, 0);
}

pub fn cwdAt(self: *const Self, pin: PageList.Pin) ?[]const u8 {
    var i = self.entries.items.len;
    while (i > 0) {
        i -= 1;
        const entry = self.entries.items[i];
        if (entry.pin.eql(pin) or entry.pin.before(pin)) return entry.cwd;
    }
    return null;
}

test "OMG cwd history follows output through scroll reflow and reset" {
    if (@import("builtin").target.os.tag != .macos) return error.SkipZigTest;
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 4 });
    defer t.deinit(alloc);
    const screen = t.screens.active;

    try t.printString("before OSC7");
    const unknown = try screen.pages.trackPin(screen.cursor.page_pin.*);
    defer screen.pages.untrackPin(unknown);
    try t.linefeed();
    t.carriageReturn();
    try t.setPwd("/parent");
    const parent = try screen.pages.trackPin(screen.cursor.page_pin.*);
    defer screen.pages.untrackPin(parent);
    try t.printString("README.md");
    try t.linefeed();
    t.carriageReturn();
    try t.setPwd("/parent/child");
    const child = try screen.pages.trackPin(screen.cursor.page_pin.*);
    defer screen.pages.untrackPin(child);
    try t.printString("README.md");
    for (0..12) |_| {
        try t.linefeed();
        t.carriageReturn();
        try t.printString("output long enough to wrap on resize");
    }
    try t.resize(alloc, .{ .cols = 15, .rows = 4 });
    try std.testing.expectEqualStrings("/parent", screen.omg_cwd_history.cwdAt(parent.*).?);
    try std.testing.expectEqualStrings("/parent/child", screen.omg_cwd_history.cwdAt(child.*).?);
    try std.testing.expect(screen.omg_cwd_history.cwdAt(unknown.*) == null);
    try std.testing.expectEqual(@as(usize, 2), screen.omg_cwd_history.entries.items.len);
    screen.reset();
    try std.testing.expect(screen.omg_cwd_history.cwdAt(screen.cursor.page_pin.*) == null);
}

test "OMG cwd history bounds retained transitions without guessing old cwd" {
    if (@import("builtin").target.os.tag != .macos) return error.SkipZigTest;
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 10, .rows = 4 });
    defer t.deinit(alloc);
    const screen = t.screens.active;
    const oldest = try screen.pages.trackPin(screen.cursor.page_pin.*);
    defer screen.pages.untrackPin(oldest);
    for (0..max_entries + 2) |i| {
        try t.setPwd(if (i % 2 == 0) "/a" else "/b");
        try t.printString("file");
        try t.linefeed();
        t.carriageReturn();
    }
    try std.testing.expectEqual(@as(usize, max_entries), screen.omg_cwd_history.entries.items.len);
    try std.testing.expect(screen.omg_cwd_history.cwdAt(oldest.*) == null);
    try std.testing.expectEqualStrings("/b", screen.omg_cwd_history.cwdAt(screen.cursor.page_pin.*).?);
}
