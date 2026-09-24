//! Host-only, bounded VT export of the visible screen and scrollback.
//! Surviving OSC 133 command ranges are marked from tracked pins, not text search.
const std = @import("std");
const Terminal = @import("Terminal.zig");
const Selection = @import("Selection.zig");
const fmt = @import("formatter.zig");
const string_encoding = @import("../os/string_encoding.zig");

pub const KeyResolver = struct {
    userdata: ?*anyopaque,
    callback: *const fn (?*anyopaque, u64) callconv(.c) ?[*:0]const u8,
};

pub fn capture(alloc: std.mem.Allocator, t: *const Terminal, max_bytes: usize) !?[]u8 {
    return captureWithKeys(alloc, t, max_bytes, null);
}

pub fn captureWithKeys(
    alloc: std.mem.Allocator,
    t: *const Terminal,
    max_bytes: usize,
    resolver: ?KeyResolver,
) !?[]u8 {
    if (t.screens.active_key != .primary) return null;
    const screen = t.screens.active;
    const bottom = screen.pages.getBottomRight(.screen) orelse return null;
    const top = screen.pages.getTopLeft(.history);

    if (max_bytes == 0) return null;
    const formatted_buffer = try alloc.alloc(u8, max_bytes);
    defer alloc.free(formatted_buffer);
    var formatted = std.Io.Writer.fixed(formatted_buffer);
    var points: fmt.PinMap.Map = .empty;
    defer points.deinit(alloc);
    var formatter: fmt.ScreenFormatter = .init(screen, .{
        .emit = .vt,
        .unwrap = true,
        .trim = false,
        .trim_styled_row_tail = true,
        // Do not bake OSC 10/11 or the old palette into a restored theme.
    });
    formatter.content = .{ .selection = Selection.init(top, bottom, false) };
    formatter.pin_map = .{ .alloc = alloc, .map = &points };
    formatter.format(&formatted) catch return null;
    const bytes = formatted.buffered();
    if (bytes.len == 0 or bytes.len > max_bytes or points.count() != bytes.len) return null;

    const output_buffer = try alloc.alloc(u8, max_bytes);
    defer alloc.free(output_buffer);
    var output = std.Io.Writer.fixed(output_buffer);
    var copied: usize = 0;
    for (screen.omg_command_history.entries.items) |entry| {
        if (!entry.isValid()) continue;
        var start: ?usize = null;
        var end: ?usize = null;
        for (copied..points.count()) |i| {
            const pin = points.get(i) orelse return null;
            if (start == null) {
                if (pin.eql(entry.pin.*)) start = i;
                continue;
            }
            if (!pin.before(entry.end_pin.*) and
                !(entry.end_inclusive and pin.eql(entry.end_pin.*)))
            {
                end = i;
                break;
            }
        }
        const first = start orelse return null;
        const last = end orelse bytes.len;
        if (last <= first) return null;
        output.writeAll(bytes[copied..first]) catch return null;
        const key: ?[]const u8 = if (resolver) |r| key: {
            const raw = r.callback(r.userdata, entry.id) orelse break :key null;
            const value = std.mem.span(raw);
            if (value.len == 0 or value.len > 256 or !std.ascii.isAlphanumeric(value[0])) break :key null;
            for (value) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != ':') break :key null;
            }
            break :key value;
        } else null;
        if (key) |value| {
            output.writeAll("\x1b]133;B;aid=omg:") catch return null;
            output.writeAll(value) catch return null;
            output.writeByte(0x07) catch return null;
        } else {
            output.writeAll("\x1b]133;B\x07") catch return null;
        }
        output.writeAll(bytes[first..last]) catch return null;
        output.writeAll("\x1b]133;C;cmdline_url=") catch return null;
        string_encoding.urlPercentEncode(&output, entry.text) catch return null;
        output.writeAll("\x07") catch return null;
        copied = last;
    }
    output.writeAll(bytes[copied..]) catch return null;
    const result = output.buffered();
    if (result.len > max_bytes) return null;
    return try alloc.dupe(u8, result);
}

test "OMG scrollback VT export retains output without baking theme colors" {
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 12, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("first line");
    try t.linefeed();
    t.carriageReturn();
    try t.printString("second line");
    const snapshot = (try capture(alloc, &t, 64 * 1024)).?;
    defer alloc.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "second line") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\x1b]10;") == null);
    try std.testing.expect((try capture(alloc, &t, 1)) == null);
}

test "OMG scrollback VT export drops styled blank prompt tails but keeps command anchors" {
    const alloc = std.testing.allocator;
    var source = try Terminal.init(std.testing.io, alloc, .{ .cols = 30, .rows = 5 });
    defer source.deinit(alloc);
    var input = source.vtStream();
    defer input.deinit();
    input.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07ll\x1b]133;C\x07");
    // Simulate a powerline prompt redraw leaving a colored region past ll.
    input.nextSlice("\x1b[45m          \x1b[0m\r\n\x1b[45m      \x1b[0m");
    const bytes = (try capture(alloc, &source, 64 * 1024)).?;
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "          ") == null);
    var restored = try Terminal.init(std.testing.io, alloc, .{ .cols = 30, .rows = 5 });
    defer restored.deinit(alloc);
    var stream = restored.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    const entries = restored.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("ll", entries[0].text);
    try std.testing.expect(entries[0].isValid());
}

test "OMG scrollback VT replay keeps repeated command occurrences distinct" {
    const alloc = std.testing.allocator;
    var source = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 8 });
    defer source.deinit(alloc);
    for (0..2) |_| {
        try source.semanticPrompt(.init(.fresh_line_new_prompt));
        try source.printString("$ ");
        try source.semanticPrompt(.init(.end_prompt_start_input));
        try source.printString("ll");
        try source.semanticPrompt(.init(.end_input_start_output));
        try source.linefeed();
        source.carriageReturn();
    }
    const resolver: KeyResolver = .{
        .userdata = null,
        .callback = struct {
            fn key(_: ?*anyopaque, id: u64) callconv(.c) ?[*:0]const u8 {
                return switch (id) {
                    1 => "original-first",
                    2 => "original-second",
                    else => null,
                };
            }
        }.key,
    };
    const bytes = (try captureWithKeys(alloc, &source, 64 * 1024, resolver)).?;
    defer alloc.free(bytes);
    var restored = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 8 });
    defer restored.deinit(alloc);
    var stream = restored.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    // Shell integration replays a divider and draws a fresh prompt after cat.
    stream.nextSlice("\x1b[0m\r\n--- Restored ---\r\n\x1b]133;A\x07$ \x1b]133;B\x07");
    const entries = restored.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("ll", entries[0].text);
    try std.testing.expectEqualStrings("ll", entries[1].text);
    try std.testing.expect(entries[0].id != entries[1].id);
    try std.testing.expectEqualStrings("original-first", entries[0].replay_key.?);
    try std.testing.expectEqualStrings("original-second", entries[1].replay_key.?);
    try std.testing.expect(!entries[0].pin.eql(entries[1].pin.*));
    try std.testing.expect(entries[0].isValid());
    try std.testing.expect(entries[1].isValid());
    stream.nextSlice("\r\n\x1b]133;A\x07$ \x1b]133;B\x07pwd\x1b]133;C\x07");
    const after_new_command = restored.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 3), after_new_command.len);
    try std.testing.expectEqualStrings("pwd", after_new_command[2].text);
    try std.testing.expect(after_new_command[2].replay_key == null);
    try std.testing.expect(after_new_command[0].isValid());
    try std.testing.expect(after_new_command[1].isValid());
    const first_pin = after_new_command[0].pin.*;
    restored.screens.active.scroll(.{ .pin = first_pin });
    const location = restored.screens.active.pages.pointFromPin(.viewport, first_pin).?;
    try std.testing.expect(location.viewport.y < restored.screens.active.pages.rows);
}

test "OMG scrollback VT export refuses malformed occurrence markers" {
    const alloc = std.testing.allocator;
    var source = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 8 });
    defer source.deinit(alloc);
    try source.semanticPrompt(.init(.fresh_line_new_prompt));
    try source.printString("$ ");
    try source.semanticPrompt(.init(.end_prompt_start_input));
    try source.printString("ll");
    try source.semanticPrompt(.init(.end_input_start_output));
    const resolver: KeyResolver = .{
        .userdata = null,
        .callback = struct {
            fn key(_: ?*anyopaque, _: u64) callconv(.c) ?[*:0]const u8 {
                return "bad;injected-id";
            }
        }.key,
    };
    const bytes = (try captureWithKeys(alloc, &source, 64 * 1024, resolver)).?;
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "aid=omg:") == null);
    var restored = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 8 });
    defer restored.deinit(alloc);
    var stream = restored.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    const entries = restored.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("ll", entries[0].text);
    try std.testing.expect(entries[0].replay_key == null);
}

test "OMG scrollback VT replay keeps Fish command metadata after a prompt redraw" {
    const alloc = std.testing.allocator;
    var source = try Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 8 });
    defer source.deinit(alloc);
    try source.semanticPrompt(.init(.fresh_line_new_prompt));
    try source.printString("$ ");
    try source.semanticPrompt(.init(.end_prompt_start_input));
    try source.printString("starship ~/work main 19:50 > ll");
    var output: @import("osc/parsers/semantic_prompt.zig").Command = .init(.end_input_start_output);
    output.options_unvalidated = "cmdline_url=ll";
    try source.semanticPrompt(output);
    const bytes = (try capture(alloc, &source, 64 * 1024)).?;
    defer alloc.free(bytes);
    var restored = try Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 8 });
    defer restored.deinit(alloc);
    var stream = restored.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    const entries = restored.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("ll", entries[0].text);
    try std.testing.expect(entries[0].isValid());
    try std.testing.expect(entries[0].pin.x > 2);
}

test "OMG scrollback VT replay preserves a wrapped Unicode command" {
    const alloc = std.testing.allocator;
    var source = try Terminal.init(std.testing.io, alloc, .{ .cols = 12, .rows = 8 });
    defer source.deinit(alloc);
    try source.semanticPrompt(.init(.fresh_line_new_prompt));
    try source.printString("$ ");
    try source.semanticPrompt(.init(.end_prompt_start_input));
    const command = "echo 你好世界 abcdefghijklmnop";
    try source.printString(command);
    try source.semanticPrompt(.init(.end_input_start_output));
    const bytes = (try capture(alloc, &source, 64 * 1024)).?;
    defer alloc.free(bytes);
    var restored = try Terminal.init(std.testing.io, alloc, .{ .cols = 12, .rows = 8 });
    defer restored.deinit(alloc);
    var stream = restored.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    const entries = restored.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings(command, entries[0].text);
    try std.testing.expect(entries[0].isValid());
}
