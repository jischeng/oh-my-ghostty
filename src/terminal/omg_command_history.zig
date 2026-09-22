//! Bounded command records captured from OSC 133 input, never keyboard events.
const Self = @This();
const std = @import("std");
const PageList = @import("PageList.zig");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    id: u64,
    pin: *PageList.Pin,
    text: [:0]const u8,
    timestamp: i64,

    pub fn isValid(self: Entry) bool {
        if (self.pin.garbage) return false;
        // A clear/overwrite can erase cells without pruning their page.
        return self.pin.rowAndCell().cell.semantic_content == .input;
    }
};
entries: std.ArrayList(Entry) = .empty,
input: ?*PageList.Pin = null,
next_id: u64 = 1,

pub fn deinit(self: *Self, alloc: Allocator, pages: *PageList) void {
    if (self.input) |pin| pages.untrackPin(pin);
    for (self.entries.items) |entry| {
        pages.untrackPin(entry.pin);
        alloc.free(entry.text);
    }
    self.entries.deinit(alloc);
    // IDs must not be reused after terminal reset.
    self.* = .{ .next_id = self.next_id };
}

pub fn begin(self: *Self, pages: *PageList, cursor: PageList.Pin) !void {
    // A continuation prompt may send another B; retain the original input start.
    if (self.input) |pin| {
        if (!pin.garbage and pin.before(cursor) and
            cursor.rowAndCell().row.semantic_prompt == .prompt_continuation) return;
    }
    if (self.input) |pin| pages.untrackPin(pin);
    self.input = null;
    self.input = try pages.trackPin(cursor);
}

pub fn finish(self: *Self, alloc: Allocator, pages: *PageList, cursor: PageList.Pin, timestamp: i64) !void {
    const start = self.input orelse return;
    self.input = null;
    defer pages.untrackPin(start);
    if (start.garbage or !start.before(cursor)) return;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    var it = start.cellIterator(.right_down, cursor);
    var count: usize = 0;
    while (it.next()) |pin| {
        if (pin.eql(cursor)) break;
        count += 1;
        // Do not publish truncated commands as exact records.
        if (count > 16384 or text.items.len > 16384) return;
        const rac = pin.rowAndCell();
        if (pin.x == 0 and !pin.eql(start.*) and !rac.row.wrap_continuation) {
            try text.append(alloc, '\n');
        }
        if (rac.cell.semantic_content != .input) continue;
        switch (rac.cell.wide) {
            .spacer_head, .spacer_tail => continue,
            else => {},
        }
        var bytes: [4]u8 = undefined;
        const cp = rac.cell.codepoint();
        const len = std.unicode.utf8Encode(if (cp == 0) ' ' else cp, &bytes) catch continue;
        try text.appendSlice(alloc, bytes[0..len]);
        if (pin.grapheme(rac.cell)) |extra| for (extra) |value| {
            const n = std.unicode.utf8Encode(value, &bytes) catch continue;
            try text.appendSlice(alloc, bytes[0..n]);
        };
        if (text.items.len > 16384) return;
    }
    const trimmed = std.mem.trim(u8, text.items, " \t\r\n");
    if (trimmed.len == 0) return;
    const copy = try alloc.dupeZ(u8, trimmed);
    errdefer alloc.free(copy);
    const anchor = try pages.trackPin(start.*);
    errdefer pages.untrackPin(anchor);
    try self.entries.append(alloc, .{ .id = self.next_id, .pin = anchor, .text = copy, .timestamp = timestamp });
    self.next_id += 1;
    if (self.entries.items.len > 100) {
        const old = self.entries.orderedRemove(0);
        pages.untrackPin(old.pin);
        alloc.free(old.text);
    }
}

test "OMG command history preserves repeated executions and resets IDs" {
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 8 });
    defer t.deinit(alloc);
    for (0..2) |_| {
        try t.semanticPrompt(.init(.fresh_line_new_prompt));
        try t.printString("$ ");
        try t.semanticPrompt(.init(.end_prompt_start_input));
        try t.printString("ll");
        try t.semanticPrompt(.init(.end_input_start_output));
        try t.linefeed();
        t.carriageReturn();
    }
    const screen = t.screens.active;
    try std.testing.expectEqual(@as(usize, 2), screen.omg_command_history.entries.items.len);
    const first = screen.omg_command_history.entries.items[0];
    const second = screen.omg_command_history.entries.items[1];
    try std.testing.expectEqualStrings("ll", first.text);
    try std.testing.expect(first.timestamp > 0);
    try std.testing.expect(first.isValid());
    try std.testing.expectEqualStrings("ll", second.text);
    try std.testing.expect(first.id != second.id);
    try std.testing.expect(!first.pin.eql(second.pin.*));
    try t.resize(alloc, .{ .cols = 20, .rows = 8 });
    try std.testing.expect(!first.pin.garbage);
    const next = screen.omg_command_history.next_id;
    screen.reset();
    try std.testing.expectEqual(@as(usize, 0), screen.omg_command_history.entries.items.len);
    try std.testing.expectEqual(next, screen.omg_command_history.next_id);
}

test "OMG command history handles wrapping Unicode and missing integration" {
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 12, .rows = 8 });
    defer t.deinit(alloc);
    try t.printString("ordinary output");
    try t.semanticPrompt(.init(.end_input_start_output));
    try std.testing.expectEqual(@as(usize, 0), t.screens.active.omg_command_history.entries.items.len);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try t.printString("$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    const command = "echo 你好世界 abcdefghijklmnop";
    try t.printString(command);
    try t.semanticPrompt(.init(.end_input_start_output));
    try std.testing.expectEqualStrings(command, t.screens.active.omg_command_history.entries.items[0].text);
}

test "OMG command history rejects overwritten input anchors" {
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 8 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try t.printString("ll");
    try t.semanticPrompt(.init(.end_input_start_output));
    const entry = t.screens.active.omg_command_history.entries.items[0];
    t.carriageReturn();
    try t.printString("output replaces input");
    try std.testing.expect(!entry.isValid());
}

test "OMG command history bounds repeated records" {
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 8 });
    defer t.deinit(alloc);
    for (0..110) |_| {
        try t.semanticPrompt(.init(.fresh_line_new_prompt));
        try t.printString("$ ");
        try t.semanticPrompt(.init(.end_prompt_start_input));
        try t.printString("ll");
        try t.semanticPrompt(.init(.end_input_start_output));
        try t.linefeed();
        t.carriageReturn();
    }
    const entries = t.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 100), entries.len);
    try std.testing.expectEqual(@as(u64, 11), entries[0].id);
    try std.testing.expectEqual(@as(u64, 110), entries[99].id);
}
