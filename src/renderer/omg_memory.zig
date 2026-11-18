//! Release GPU frame resources for an occluded terminal. Immediate occlusion
//! trims spare swapchain buffers while preserving the front frame for fast tab
//! switching; sustained hibernation also evicts the front frame onto a 1x1
//! placeholder target so occluded surfaces retain minimal VRAM.
const std = @import("std");

pub fn trimInactive(renderer: anytype, io: std.Io) !void {
    try trim(renderer, io, true);
}

pub fn trimAll(renderer: anytype, io: std.Io) !void {
    try trim(renderer, io, false);
}

fn trim(renderer: anytype, io: std.Io, comptime preserve_front: bool) !void {
    renderer.draw_mutex.lockUncancelable(io);
    defer renderer.draw_mutex.unlock(io);
    if (!preserve_front and @hasField(@TypeOf(renderer.*), "visible")) {
        if (renderer.visible.load(.acquire)) return;
    }
    const chain = switch (@typeInfo(@TypeOf(renderer.swap_chain))) {
        .optional => &(renderer.swap_chain orelse return),
        else => brk: {
            if (renderer.swap_chain.defunct) return;
            break :brk &renderer.swap_chain;
        },
    };

    // GPU completion callbacks return these permits without taking draw_mutex.
    // Never replace buffers while a submitted frame may still reference them.
    for (chain.frames) |_| chain.frame_sema.waitUncancelable(io);
    defer for (chain.frames) |_| chain.frame_sema.post(io);

    for (&chain.frames, 0..) |*frame, index| {
        if (preserve_front and index == chain.frame_index) continue;
        if (frame.target.width <= 1 and frame.target.height <= 1) continue;
        const Frame = @TypeOf(frame.*);
        const replacement = try Frame.init(renderer.api, renderer.has_custom_shaders);
        if (!preserve_front and index == chain.frame_index) {
            const ApiField = @TypeOf(renderer.api);
            const Api = switch (@typeInfo(ApiField)) {
                .pointer => |p| p.child,
                else => ApiField,
            };
            if (@hasDecl(Api, "evictPresentedTarget")) {
                renderer.api.evictPresentedTarget(&frame.target, &replacement.target);
            }
        }
        frame.deinit();
        frame.* = replacement;
    }
    renderer.cells_rebuilt = true;
}

const Mock = struct {
    const Target = struct {
        width: usize = 100,
        height: usize = 100,
        evicted: bool = false,
    };
    const State = struct {
        bytes: usize = 300,
        fail: bool = false,
        evictions: usize = 0,
        last_replacement_width: usize = 0,

        pub fn evictPresentedTarget(self: *State, old_target: *Target, new_target: *const Target) void {
            old_target.evicted = true;
            self.evictions += 1;
            self.last_replacement_width = new_target.width;
        }
    };
    const Frame = struct {
        state: *State,
        target: Target = .{},
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
    visible: std.atomic.Value(bool) = .init(false),
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
    try std.testing.expectEqual(@as(usize, 0), state.evictions);
    try std.testing.expect(renderer.cells_rebuilt);
    try trimInactive(&renderer, std.testing.io);
    try std.testing.expectEqual(@as(usize, 102), state.bytes);
}

test "hibernated GPU trim evicts front frame only while hidden" {
    var state: Mock.State = .{};
    var renderer = Mock.init(&state);
    renderer.visible.store(true, .release);
    try trimAll(&renderer, std.testing.io);
    try std.testing.expectEqual(@as(usize, 300), state.bytes);
    try std.testing.expectEqual(@as(usize, 0), state.evictions);

    renderer.visible.store(false, .release);
    try trimInactive(&renderer, std.testing.io);
    try std.testing.expectEqual(@as(usize, 102), state.bytes);

    try trimAll(&renderer, std.testing.io);
    try std.testing.expectEqual(@as(usize, 3), state.bytes);
    try std.testing.expectEqual(@as(usize, 1), state.evictions);
    try std.testing.expectEqual(@as(usize, 1), state.last_replacement_width);
    try std.testing.expectEqual(@as(usize, 1), renderer.swap_chain.frames[1].target.width);

    // Repeating hibernation is a no-op once all swapchain frames are 1x1.
    try trimAll(&renderer, std.testing.io);
    try std.testing.expectEqual(@as(usize, 3), state.bytes);
    try std.testing.expectEqual(@as(usize, 1), state.evictions);
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
