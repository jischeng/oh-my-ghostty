//! Release spare GPU frame resources for an occluded terminal. The most recent
//! frame remains intact, so returning to a tab can immediately show its image.
const std = @import("std");

pub fn trimInactive(renderer: anytype, io: std.Io) !void {
    renderer.draw_mutex.lockUncancelable(io);
    defer renderer.draw_mutex.unlock(io);
    const chain = &renderer.swap_chain;
    if (chain.defunct) return;

    // GPU completion callbacks return these permits without taking draw_mutex.
    // Never replace buffers while a submitted frame may still reference them.
    for (chain.frames) |_| chain.frame_sema.waitUncancelable(io);
    defer for (chain.frames) |_| chain.frame_sema.post(io);

    for (&chain.frames, 0..) |*frame, index| {
        if (index == chain.frame_index) continue;
        if (frame.target.width <= 1 and frame.target.height <= 1) continue;
        const Frame = @TypeOf(frame.*);
        const replacement = try Frame.init(renderer.api, renderer.has_custom_shaders);
        frame.deinit();
        frame.* = replacement;
    }
    renderer.cells_rebuilt = true;
}

const Mock = struct {
    const State = struct { bytes: usize = 300, fail: bool = false };
    const Frame = struct {
        state: *State,
        target: struct { width: usize = 100, height: usize = 100 } = .{},
        bytes: usize = 100,
        pub fn init(state: *State, _: bool) !Frame {
            if (state.fail) return error.OutOfMemory;
            state.bytes += 1;
            return .{ .state = state, .target = .{ .width = 1, .height = 1 }, .bytes = 1 };
        }
        pub fn deinit(self: *Frame) void {
            self.state.bytes -= self.bytes;
        }
    };
    draw_mutex: std.Io.Mutex = .init,
    api: *State,
    has_custom_shaders: bool = false,
    cells_rebuilt: bool = false,
    swap_chain: struct {
        frames: [3]Frame,
        frame_index: usize = 1,
        frame_sema: std.Io.Semaphore = .{ .permits = 3 },
        defunct: bool = false,
    },
    fn init(state: *State) Mock {
        return .{ .api = state, .swap_chain = .{ .frames = .{ .{ .state = state }, .{ .state = state }, .{ .state = state } } } };
    }
};

test "idle GPU trim preserves front frame and can repeat" {
    var state: Mock.State = .{};
    var renderer = Mock.init(&state);
    try trimInactive(&renderer, std.testing.io);
    try std.testing.expectEqual(@as(usize, 102), state.bytes);
    try std.testing.expectEqual(@as(usize, 100), renderer.swap_chain.frames[1].target.width);
    try std.testing.expect(renderer.cells_rebuilt);
    try trimInactive(&renderer, std.testing.io);
    try std.testing.expectEqual(@as(usize, 102), state.bytes);
}

test "idle GPU trim failure preserves resources and semaphore" {
    var state: Mock.State = .{ .fail = true };
    var renderer = Mock.init(&state);
    try std.testing.expectError(error.OutOfMemory, trimInactive(&renderer, std.testing.io));
    try std.testing.expectEqual(@as(usize, 300), state.bytes);
    state.fail = false;
    try trimInactive(&renderer, std.testing.io);
    try std.testing.expectEqual(@as(usize, 102), state.bytes);
}
