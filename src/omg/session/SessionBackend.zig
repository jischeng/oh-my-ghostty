//! Experimental native daemon transport. No local PTY or attach subprocess.
const Self = @This();
const std = @import("std");
const global = @import("../../global.zig");
const HostIO = @import("../../omg_session_host.zig").HostIO;
const terminal = @import("../../terminal/main.zig");
const renderer = @import("../../renderer.zig");
const apprt = @import("../../apprt.zig");
const ProcessInfo = @import("../../pty.zig").ProcessInfo;
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("sys/time.h");
    @cInclude("errno.h");
});
alloc: std.mem.Allocator,
path: [:0]u8,
pane_id: ?[]u8 = null,
fd: c_int = -1,
write_mutex: std.Io.Mutex = .init,
ready: std.atomic.Value(bool) = .init(false),
stopping: std.atomic.Value(bool) = .init(false),
close_requested: std.atomic.Value(bool) = .init(false),
requested_size: std.atomic.Value(u32) = .init((80 << 16) | 24),

pub fn init(alloc: std.mem.Allocator, path: []const u8, pane_id: ?[]const u8) !Self {
    const owned_path = try alloc.dupeZ(u8, path);
    errdefer alloc.free(owned_path);
    return .{ .alloc = alloc, .path = owned_path, .pane_id = if (pane_id) |id| try alloc.dupe(u8, id) else null };
}
pub fn deinit(self: *Self) void {
    self.alloc.free(self.path);
    if (self.pane_id) |id| self.alloc.free(id);
}
pub fn initTerminal(_: *Self, _: *terminal.Terminal) void {}
pub const ThreadData = struct {
    thread: std.Thread,
    pub fn deinit(_: *ThreadData, _: std.mem.Allocator) void {}
};
pub fn threadEnter(self: *Self, _: std.mem.Allocator, io: *HostIO, td: *HostIO.ThreadData) !void {
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    if (self.path.len >= address.sun_path.len) return error.SocketPathTooLong;
    address.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..self.path.len], self.path);
    self.fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (self.fd < 0) return error.SocketFailed;
    errdefer {
        _ = c.close(self.fd);
        self.fd = -1;
    }
    if (@hasDecl(c, "SO_NOSIGPIPE")) {
        var enabled: c_int = 1;
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_NOSIGPIPE, &enabled, @sizeOf(c_int));
    }
    var timeout = c.struct_timeval{ .tv_sec = 1, .tv_usec = 0 };
    _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &timeout, @sizeOf(@TypeOf(timeout)));
    const grid = io.size.grid();
    self.requested_size.store((@as(u32, grid.columns) << 16) | grid.rows, .release);
    td.backend = .{ .omg_session = .{ .thread = try std.Thread.spawn(.{}, reader, .{ self, io }) } };
}
pub fn threadExit(self: *Self, td: *HostIO.ThreadData) void {
    self.stopping.store(true, .release);
    _ = c.shutdown(self.fd, c.SHUT_RDWR);
    td.backend.omg_session.thread.join();
    _ = c.close(self.fd);
    self.fd = -1;
}
pub fn closeSession(self: *Self) void {
    self.close_requested.store(true, .release);
    if (self.ready.load(.acquire)) self.send('K', 0, &.{}) catch {};
}
pub fn focusGained(_: *Self, _: *HostIO.ThreadData, _: bool) !void {}
pub fn resize(self: *Self, grid: renderer.GridSize, _: renderer.ScreenSize) !void {
    self.requested_size.store((@as(u32, grid.columns) << 16) | grid.rows, .release);
    if (!self.ready.load(.acquire)) return;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], grid.columns, .big);
    std.mem.writeInt(u16, bytes[2..4], grid.rows, .big);
    try self.send('R', 0, &bytes);
}
pub fn queueWrite(self: *Self, _: std.mem.Allocator, _: *HostIO.ThreadData, data: []const u8, _: bool) !void {
    if (!self.ready.load(.acquire)) return error.SessionNotReady;
    try self.send('I', 0, data);
}
pub fn getProcessInfo(_: *Self, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return null;
}
fn send(self: *Self, kind: u8, seq: u64, data: []const u8) !void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    // A partially written frame cannot be retried on this connection.
    errdefer {
        self.ready.store(false, .release);
        _ = c.shutdown(self.fd, c.SHUT_RDWR);
    }
    var header: [13]u8 = undefined;
    header[0] = kind;
    std.mem.writeInt(u64, header[1..9], seq, .big);
    std.mem.writeInt(u32, header[9..13], @intCast(data.len), .big);
    for ([_][]const u8{ &header, data }) |part| {
        var offset: usize = 0;
        while (offset < part.len) {
            const n = c.send(self.fd, part.ptr + offset, part.len - offset, 0);
            if (n <= 0) return error.Disconnected;
            offset += @intCast(n);
        }
    }
}
fn readExact(self: *Self, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.read(self.fd, bytes.ptr + offset, bytes.len - offset);
        if (n <= 0) return error.Disconnected;
        offset += @intCast(n);
    }
}
fn reader(self: *Self, io: *HostIO) void {
    defer {
        self.ready.store(false, .release);
        _ = c.shutdown(self.fd, c.SHUT_RDWR);
    }
    self.readLoop(io) catch |err| {
        std.log.warn("OMG session disconnected: {s}", .{@errorName(err)});
        if (!self.stopping.load(.acquire)) {
            const signal = apprt.surface.Message.ContextSignal.init(self.alloc, .{
                .action = .start,
                .id = "omg-runtime-disconnected",
                .metadata = "",
            }) catch return;
            _ = io.surface_mailbox.push(.{ .context_signal = signal }, .{ .forever = {} });
        }
    };
}
fn readLoop(self: *Self, io: *HostIO) !void {
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..self.path.len], self.path);
    // Deployment may upload the runtime before publishing the local socket.
    // This runs on the dedicated reader, never the AppKit thread.
    var attempts: usize = 0;
    while (c.connect(self.fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) {
        if (self.stopping.load(.acquire)) return error.Disconnected;
        attempts += 1;
        if (attempts >= 600) return error.ConnectFailed;
        _ = c.usleep(100_000);
    }
    if (self.pane_id) |id| try self.send('H', 0, id);
    var sequence: ?u64 = null;
    while (true) {
        var h: [13]u8 = undefined;
        try self.readExact(&h);
        const seq = std.mem.readInt(u64, h[1..9], .big);
        const len = std.mem.readInt(u32, h[9..13], .big);
        if (len > 16 * 1024 * 1024) return error.FrameTooLarge;
        const bytes = try self.alloc.alloc(u8, len);
        defer self.alloc.free(bytes);
        try self.readExact(bytes);
        switch (h[0]) {
            'J' => {
                const Metadata = struct { version: u32 };
                const metadata = try std.json.parseFromSlice(Metadata, self.alloc, bytes, .{ .ignore_unknown_fields = true });
                defer metadata.deinit();
                if (metadata.value.version != 1) return error.UnsupportedProtocol;
            },
            'S' => {
                try self.restore(io, bytes);
                sequence = seq;
                try self.send('A', seq, &.{});
                try self.send('W', 0, &.{});
            },
            'O' => {
                const previous = sequence orelse return error.MissingSnapshot;
                if (seq != previous + len) return error.OutputGap;
                io.processOutput(bytes);
                sequence = seq;
            },
            'W' => {
                self.ready.store(true, .release);
                if (self.close_requested.load(.acquire)) {
                    try self.send('K', 0, &.{});
                    continue;
                }
                var dimensions: [4]u8 = undefined;
                std.mem.writeInt(u32, &dimensions, self.requested_size.load(.acquire), .big);
                try self.send('R', 0, &dimensions);
            },
            'R' => {
                if (bytes.len != 4) return error.InvalidResize;
                io.renderer_state.mutex.lockUncancelable(global.io());
                defer io.renderer_state.mutex.unlock(global.io());
                try io.terminal.resize(self.alloc, .{ .cols = std.mem.readInt(u16, bytes[0..2], .big), .rows = std.mem.readInt(u16, bytes[2..4], .big) });
                try io.renderer_wakeup.notify();
            },
            'M' => {
                const Metadata = struct { cwd: ?[]const u8 = null };
                const metadata = try std.json.parseFromSlice(Metadata, self.alloc, bytes, .{});
                defer metadata.deinit();
                const path = metadata.value.cwd orelse "";
                if (path.len > 4096 or (path.len > 0 and path[0] != '/') or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidMetadata;
                const Message = @import("../../apprt.zig").surface.Message;
                const req = try Message.WriteReq.init(self.alloc, path);
                _ = io.surface_mailbox.push(.{ .pwd_change = req }, .{ .forever = {} });
            },
            'B' => {}, // Writer is occupied; remain attached as an observer.
            'E' => {
                io.processOutput("\r\n[OMG Session] ");
                // Error text is presentation only, never interpret it as VT.
                for (bytes) |byte| {
                    if (byte >= 0x20 and byte != 0x7f) io.processOutput(&.{byte});
                }
                io.processOutput("\r\n");
                return;
            },
            'X' => {
                const code = std.fmt.parseInt(i32, bytes, 10) catch -1;
                _ = io.surface_mailbox.push(.{ .child_exited = .{
                    .exit_code = if (code < 0) 1 else @intCast(code),
                    .runtime_ms = 1,
                } }, .{ .forever = {} });
                return;
            },
            else => return error.InvalidFrame,
        }
    }
}
fn restore(self: *Self, io: *HostIO, bytes: []const u8) !void {
    var input: std.Io.Reader = .fixed(bytes);
    var decoded = try terminal.snapshot.decodeExact(self.alloc, global.io(), &input, .{ .max_continuation_bytes = 1024 * 1024 });
    defer decoded.deinit(self.alloc);
    io.renderer_state.mutex.lockUncancelable(global.io());
    defer io.renderer_state.mutex.unlock(global.io());
    var handler = io.terminal_stream.handler;
    // Reset parser-owned allocations while retaining host routing pointers.
    handler.apc = .{};
    handler.dcs = .{};
    io.terminal_stream.deinit();
    io.terminal.deinit(self.alloc);
    io.terminal = decoded.toOwned();
    io.terminal_stream = .init(.{ .allocator = self.alloc, .handler = handler });
    switch (decoded.continuation) {
        .ground => {},
        .bytes => |continuation| io.terminal_stream.nextSlice(continuation),
    }
    try io.renderer_wakeup.notify();
}
