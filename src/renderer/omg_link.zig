//! OMG: derive Cmd link underlines from the current frame, never cached pixel
//! or viewport spans. Called under the terminal mutex after beginUpdate.
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const input = @import("../input.zig");
const Cache = @import("../omg_link_check.zig");
const Link = @import("link.zig").Link;

pub fn collect(
    alloc: std.mem.Allocator,
    cache_alloc: std.mem.Allocator,
    screen: *terminal.Screen,
    frame: *const terminal.RenderState,
    links: []const Link,
    cache: *Cache,
    mods: input.Mods,
) !terminal.RenderState.CellSet {
    var result: terminal.RenderState.CellSet = .empty;
    errdefer result.deinit(alloc);
    if (!mods.equal(input.ctrlOrSuper(.{}))) return result;
    const rows = frame.row_data.slice();
    const pins = rows.items(.pin);
    if (pins.len == 0) return result;
    const top = (screen.pages.pointFromPin(.screen, pins[0]) orelse return result).coord().y;
    var previous_end: ?terminal.Pin = null;
    for (pins) |pin| {
        if (previous_end) |end| {
            if (pin.eql(end) or pin.before(end)) continue;
        }
        // Use the same logical-line and byte-to-pin mapping as Cmd-click.
        // Filter prompt cells below rather than dropping output after a prompt.
        const line = screen.selectLine(.{ .pin = pin, .whitespace = null, .semantic_prompt_boundary = false }) orelse continue;
        previous_end = line.end();
        const text = try screen.selectionStringMap(alloc, .{ .sel = line, .trim = false });
        defer text.deinit(alloc);
        for (links) |link| {
            switch (link.highlight) {
                .always, .hover => {},
                .always_mods, .hover_mods => |required| if (!mods.equal(required)) continue,
            }
            var it = text.searchIterator(link.regex);
            while (try it.next()) |found| {
                var match = found;
                defer match.deinit();
                const sel = match.selection();
                const first = screen.pages.pointFromPin(.screen, sel.start()) orelse continue;
                const last = screen.pages.pointFromPin(.screen, sel.end()) orelse continue;
                if (last.coord().y < top or first.coord().y >= top + pins.len) continue;
                const value = try screen.selectionString(alloc, .{ .sel = sel, .trim = false });
                defer alloc.free(value);
                if (Cache.needsCheck(value)) {
                    const cwd = screen.omg_cwd_history.cwdAt(sel.start()) orelse "";
                    if (cache.get(cwd, value)) |status| {
                        if (status != .exists) continue;
                    } else {
                        _ = try cache.enqueue(cache_alloc, cwd, value);
                        continue;
                    }
                }
                const lo = first.coord();
                const hi = last.coord();
                const y0 = @max(lo.y, top);
                const y1 = @min(hi.y + 1, top + pins.len);
                for (y0..y1) |y| {
                    const row = y - top;
                    const cells = rows.items(.cells)[row].items(.raw);
                    const x0 = if (y == lo.y) lo.x else 0;
                    const x1 = @min(if (y == hi.y) @as(usize, hi.x) + 1 else cells.len, cells.len);
                    for (x0..x1) |x| {
                        if (cells[x].semantic_content == .prompt) continue;
                        try result.put(alloc, .{ .x = @intCast(x), .y = @intCast(row) }, {});
                    }
                }
            }
        }
    }
    // Explicit OSC8 links already carry their target; expose all visible cells.
    for (rows.items(.cells), 0..) |cells, y| {
        for (cells.items(.raw), 0..) |cell, x| {
            if (cell.hyperlink and cell.semantic_content != .prompt) {
                try result.put(alloc, .{ .x = @intCast(x), .y = @intCast(y) }, {});
            }
        }
    }
    return result;
}

test "OMG viewport links reveal multiple verified paths without hover and follow content" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);
    try t.setPwd("/repo");
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("a.md b.md missing.md\r\nplain\r\n");
    var config = try @import("link.zig").Set.fromConfig(alloc, &.{.{
        .regex = "[a-z]+\\.md",
        .action = .{ .open = {} },
        .highlight = .{ .hover_mods = input.ctrlOrSuper(.{}) },
    }});
    defer config.deinit(alloc);
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    for ([_][]const u8{ "a.md", "b.md" }) |name| {
        _ = try cache.putPending(alloc, "/repo", name);
        _ = cache.resolve("/repo", name, true);
    }
    var frame: terminal.RenderState = .empty;
    defer frame.deinit(alloc);
    try frame.update(alloc, &t);
    var set = try collect(alloc, alloc, t.screens.active, &frame, config.links, &cache, input.ctrlOrSuper(.{}));
    defer set.deinit(alloc);
    try std.testing.expect(set.contains(.{ .x = 0, .y = 0 }));
    try std.testing.expect(set.contains(.{ .x = 5, .y = 0 }));
    try std.testing.expect(!set.contains(.{ .x = 10, .y = 0 }));
    try std.testing.expect(cache.hasQueued());
    // Scroll the linked row off the live viewport without any mouse movement.
    stream.nextSlice("new\r\nmore\r\n");
    try frame.update(alloc, &t);
    var scrolled = try collect(alloc, alloc, t.screens.active, &frame, config.links, &cache, input.ctrlOrSuper(.{}));
    defer scrolled.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), scrolled.count());
    t.scrollViewport(.top);
    try frame.update(alloc, &t);
    var restored = try collect(alloc, alloc, t.screens.active, &frame, config.links, &cache, input.ctrlOrSuper(.{}));
    defer restored.deinit(alloc);
    try std.testing.expect(restored.contains(.{ .x = 0, .y = 0 }));
    // A reflow changes columns/rows without invalidating cached existence.
    // The cell map must be reconstructed, not copied from the previous frame.
    try t.resize(alloc, .{ .cols = 7, .rows = 6 });
    t.scrollViewport(.top);
    try frame.update(alloc, &t);
    var reflowed = try collect(alloc, alloc, t.screens.active, &frame, config.links, &cache, input.ctrlOrSuper(.{}));
    defer reflowed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 8), reflowed.count());
    var released = try collect(alloc, alloc, t.screens.active, &frame, config.links, &cache, .{});
    defer released.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), released.count());
}
