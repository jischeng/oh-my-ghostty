//! OMG (macOS): underline exactly the hovered link the surface confirmed.
//!
//! The renderer would otherwise re-run every link regex and underline any
//! match containing the mouse, including overlong or unverified candidates.
//! The surface already chose and existence-checked one span, so draw that.
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const State = @import("State.zig");

/// Add every cell from `range.start` to `range.end` (row-major, inclusive)
/// that lies within a `cols` x `rows` viewport.
pub fn addRange(
    alloc: Allocator,
    set: *terminal.RenderState.CellSet,
    range: State.Mouse.OmgLinkRange,
    cols: usize,
    rows: usize,
) Allocator.Error!void {
    if (cols == 0) return;
    var y: usize = range.start.y;
    const last_y: usize = @min(range.end.y, rows -| 1);
    while (y <= last_y) : (y += 1) {
        const first_x: usize = if (y == range.start.y) range.start.x else 0;
        const end_x: usize = if (y == range.end.y) @min(range.end.x, cols - 1) else cols - 1;
        var x = first_x;
        while (x <= end_x) : (x += 1) {
            try set.put(alloc, .{ .x = @intCast(x), .y = @intCast(y) }, {});
        }
    }
}

test "OMG renderer underlines a wrapped confirmed link span" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var set: terminal.RenderState.CellSet = .empty;
    defer set.deinit(alloc);
    try addRange(alloc, &set, .{ .start = .{ .x = 3, .y = 0 }, .end = .{ .x = 1, .y = 1 } }, 5, 3);
    try testing.expectEqual(@as(usize, 4), set.count());
    try testing.expect(set.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(set.contains(.{ .x = 4, .y = 0 }));
    try testing.expect(set.contains(.{ .x = 0, .y = 1 }));
    try testing.expect(set.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!set.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!set.contains(.{ .x = 2, .y = 1 }));
}
