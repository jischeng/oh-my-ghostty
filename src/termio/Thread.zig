//! Represents the "writer" thread for terminal IO. The reader side is
//! handled by the Termio struct itself and dependent on the underlying
//! implementation (i.e. if its a pty, manual, etc.).
//!
//! The writer thread does handle writing bytes to the pty but also handles
//! different events such as starting synchronized output, changing some
//! modes (like linefeed), etc. The goal is to offload as much from the
//! reader thread as possible since it is the hot path in parsing VT
//! sequences and updating terminal state.
//!
//! This thread state can only be used by one thread at a time.
pub const Thread = @This();

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const termio = @import("../termio.zig");
const renderer = @import("../renderer.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.io_thread);

/// This stores the information that is coalesced.
const Coalesce = struct {
    /// Ordinary resizes retain the upstream cadence. Interactive visual-only
    /// resizes use a shorter cadence so they can follow a 60/120 Hz pointer
    /// without making PTY resize notifications more frequent.
    const resize_ms = 25;
    const live_resize_ms = 8;

    const Resize = struct {
        size: renderer.Size,
        notify_child: bool,
    };

    resize: ?Resize = null,
};

/// The number of milliseconds before we reset the synchronized output flag
/// if the running program hasn't already.
const sync_reset_ms = 1000;

/// The number of milliseconds between each movement during selection scrolling.
const selection_scroll_ms = 15;

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the thread. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// The completion to use for the wakeup async handle that is present
/// on the termio.Writer.
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// This is used for timer-based selection scrolling.
scroll: xev.Timer,
scroll_c: xev.Completion = .{},
scroll_active: bool = false,

/// This is used to coalesce resize events.
coalesce: xev.Timer,
coalesce_c: xev.Completion = .{},
coalesce_cancel_c: xev.Completion = .{},
coalesce_data: Coalesce = .{},

/// This timer is used to reset synchronized output modes so that
/// the terminal doesn't freeze with a bad actor.
sync_reset: xev.Timer,
sync_reset_c: xev.Completion = .{},
sync_reset_cancel_c: xev.Completion = .{},

flags: packed struct {
    /// This is set to true only when an abnormal exit is detected. It
    /// tells our mailbox system to drain and ignore all messages.
    drain: bool = false,

    /// True if linefeed mode is enabled. This is duplicated here so that the
    /// write thread doesn't need to grab a lock to check this on every write.
    linefeed_mode: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,
} = .{},

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // This timer is used for selection scrolling.
    var scroll_h = try xev.Timer.init();
    errdefer scroll_h.deinit();

    // This timer is used to coalesce resize events.
    var coalesce_h = try xev.Timer.init();
    errdefer coalesce_h.deinit();

    // This timer is used to reset synchronized output modes.
    var sync_reset_h = try xev.Timer.init();
    errdefer sync_reset_h.deinit();

    return Thread{
        .alloc = alloc,
        .loop = loop,
        .stop = stop_h,
        .scroll = scroll_h,
        .coalesce = coalesce_h,
        .sync_reset = sync_reset_h,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.scroll.deinit();
    self.coalesce.deinit();
    self.sync_reset.deinit();
    self.stop.deinit();
    self.loop.deinit();
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread, io: *termio.Termio) void {
    // Call child function so we can use errors...
    self.threadMain_(io) catch |err| {
        log.warn("error in io thread err={}", .{err});

        // Use an arena to simplify memory management below
        var arena = ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // If there is an error, we replace our terminal screen with
        // the error message. It might be better in the future to send
        // the error to the surface thread and let the apprt deal with it
        // in some way but this works for now. Without this, the user would
        // just see a blank terminal window.
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        const t = io.renderer_state.terminal;

        // Hide the cursor
        t.modes.set(.cursor_visible, false);

        // This is weird but just ensures that no matter what our underlying
        // implementation we have the errors below. For example, Windows doesn't
        // have "OpenptyFailed".
        const Err = @TypeOf(err) || error{
            OpenptyFailed,
            InputNotFound,
            InputFailed,
        };

        switch (@as(Err, @errorCast(err))) {
            error.OpenptyFailed => {
                const str =
                    \\Your system cannot allocate any more pty devices.
                    \\
                    \\Ghostty requires a pty device to launch a new terminal.
                    \\This error is usually due to having too many terminal
                    \\windows open or having another program that is using too
                    \\many pty devices.
                    \\
                    \\Please free up some pty devices and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            error.InputNotFound,
            error.InputFailed,
            => {
                const str =
                    \\A configured `input` path was not found, was not readable,
                    \\was too large, or the underlying pty failed to accept
                    \\the write.
                    \\
                    \\Ghostty can't continue since it can't guarantee that
                    \\initial terminal state will be as desired. Please review
                    \\the value of `input` in your configuration file and
                    \\ensure that all the path values exist and are readable.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            else => {
                const str = alloc.print(
                    \\error starting IO thread: {}
                    \\
                    \\The underlying shell or command was unable to be started.
                    \\This error is usually due to exhausting a system resource.
                    \\If this looks like a bug, please report it.
                    \\
                    \\This terminal is non-functional. Please close it and try again.
                ,
                    .{err},
                ) catch
                    \\Out of memory. This terminal is non-functional. Please close it and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },
        }
    };

    // If our loop is not stopped, then we need to keep running so that
    // messages are drained and we can wait for the surface to send a stop
    // message.
    if (!self.loop.stopped()) {
        log.warn("abrupt io thread exit detected, starting xev to drain mailbox", .{});
        defer log.debug("io thread fully exiting after abnormal failure", .{});
        self.flags.drain = true;
        self.loop.run(.until_done) catch |err| {
            log.err("failed to start xev loop for draining err={}", .{err});
        };
    }
}

fn threadMain_(self: *Thread, io: *termio.Termio) !void {
    defer log.debug("IO thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.target.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"io".*);
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .io,
        .surface = io.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Get the mailbox. This must be an SPSC mailbox for threading.
    const mailbox = switch (io.mailbox) {
        .spsc => |*v| v,
        // else => return error.TermioUnsupportedMailbox,
    };

    // This is the data sent to xev callbacks. We want a pointer to both
    // ourselves and the thread data so we can thread that through (pun intended).
    var cb: CallbackData = .{ .self = self, .io = io };

    // Run our thread start/end callbacks. This allows the implementation
    // to hook into the event loop as needed. The thread data is created
    // on the stack here so that it has a stable pointer throughout the
    // lifetime of the thread.
    try io.threadEnter(self, &cb.data);
    defer cb.data.deinit();
    defer io.threadExit(&cb.data);

    // Start the async handlers.
    mailbox.wakeup.wait(&self.loop, &self.wakeup_c, CallbackData, &cb, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, CallbackData, &cb, stopCallback);

    // Run
    log.debug("starting IO thread", .{});
    defer log.debug("starting IO thread shutdown", .{});
    try self.loop.run(.until_done);
}

/// This is the data passed to xev callbacks on the thread.
const CallbackData = struct {
    self: *Thread,
    io: *termio.Termio,
    data: termio.Termio.ThreadData = undefined,
};

/// Drain the mailbox, handling all the messages in our terminal implementation.
fn drainMailbox(
    self: *Thread,
    cb: *CallbackData,
) !void {
    // We assert when starting the thread that this is the state
    const mailbox = cb.io.mailbox.spsc.queue;
    const io = cb.io;
    const data = &cb.data;

    // If we're draining, we just drain the mailbox and return.
    if (self.flags.drain) {
        while (mailbox.pop(global.io())) |msg| msg.deinit();
        return;
    }

    // This holds the mailbox lock for the duration of the drain. The
    // expectation is that all our message handlers will be non-blocking
    // ENOUGH to not mess up throughput on producers.
    var redraw: bool = false;
    while (mailbox.pop(global.io())) |message| {
        // If we have a message we always redraw
        redraw = true;

        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .color_scheme_report => |v| try io.colorSchemeReport(data, v.force),
            .visibility_report => |v| try io.visibilityReport(
                data,
                v.visible,
                v.force,
            ),
            .crash => @panic("crash request, crashing intentionally"),
            .change_config => |config| {
                defer config.alloc.destroy(config.ptr);
                try io.changeConfig(data, config.ptr);
            },
            .inspector => |v| self.flags.has_inspector = v,
            .resize => |v| self.handleResize(cb, v, true),
            .resize_live => |v| self.handleResize(cb, v, false),
            .resize_commit => |v| try self.commitResize(cb, v),
            .size_report => |v| try io.sizeReport(data, v),
            .clear_screen => |v| try io.clearScreen(data, v.history),
            .scroll_viewport => |v| io.scrollViewport(v),
            .selection_scroll => |v| {
                if (v) {
                    self.startScrollTimer(cb);
                } else {
                    self.stopScrollTimer();
                }
            },
            .jump_to_prompt => |v| try io.jumpToPrompt(v),
            .kitty_clipboard_grant_read => |v| {
                defer v.alloc.free(v.pw);
                try io.kittyClipboardGrant(v.pw, .read);
            },
            .kitty_clipboard_grant_write => |v| {
                defer v.alloc.free(v.pw);
                try io.kittyClipboardGrant(v.pw, .write);
            },
            .start_synchronized_output => self.startSynchronizedOutput(cb),
            .linefeed_mode => |v| self.flags.linefeed_mode = v,
            .focused => |v| try io.focusGained(data, v),
            .write_small => |v| {
                self.flushCoalescedChildResizeBeforeWrite(cb);
                try io.queueWrite(
                    data,
                    v.data[0..v.len],
                    self.flags.linefeed_mode,
                );
            },
            .write_stable => |v| {
                self.flushCoalescedChildResizeBeforeWrite(cb);
                try io.queueWrite(
                    data,
                    v,
                    self.flags.linefeed_mode,
                );
            },
            .write_alloc => |v| {
                defer v.alloc.free(v.data);
                self.flushCoalescedChildResizeBeforeWrite(cb);
                try io.queueWrite(
                    data,
                    v.data,
                    self.flags.linefeed_mode,
                );
            },
            .protocol_reply => |v| {
                self.flushCoalescedChildResizeBeforeWrite(cb);
                try io.queueProtocolReply(data, v);
            },
            .omg_session_write => |v| {
                defer v.data.deinit();
                self.flushCoalescedChildResizeBeforeWrite(cb);
                if (io.backend == .omg_session) {
                    io.backend.omg_session.queueWriteGeneration(
                        v.generation,
                        v.data.slice(),
                        self.flags.linefeed_mode,
                    ) catch |err| switch (err) {
                        error.SessionNotReady, error.Disconnected, error.InitialInputTooLarge, error.FrameTooLarge => {},
                        error.OutOfMemory => return err,
                    };
                }
            },
        }
    }

    if (self.coalesce_c.state() != .active) {
        if (self.coalesce_data.resize) |v| {
            self.coalesce_data.resize = null;
            if (v.notify_child) {
                io.resize(data, v.size) catch |err| {
                    log.warn("error during resize err={}", .{err});
                };
            } else {
                io.resizeVisual(v.size, false) catch |err| {
                    log.warn("error during live resize err={}", .{err});
                };
            }
            self.coalesce.reset(
                &self.loop,
                &self.coalesce_c,
                &self.coalesce_cancel_c,
                if (v.notify_child) Coalesce.resize_ms else Coalesce.live_resize_ms,
                CallbackData,
                cb,
                coalesceCallback,
            );
        }
    }

    // Trigger a redraw after we've drained so we don't waste cyces
    // messaging a redraw.
    if (redraw) {
        try io.renderer_wakeup.notify();
    }
}

fn flushCoalescedChildResizeBeforeWrite(
    self: *Thread,
    cb: *CallbackData,
) void {
    const v = self.coalesce_data.resize orelse return;
    if (!v.notify_child) return;
    self.coalesce_data.resize = null;
    cb.io.resize(&cb.data, v.size) catch |err| {
        log.warn("error during resize err={}", .{err});
    };
    self.coalesce.reset(
        &self.loop,
        &self.coalesce_c,
        &self.coalesce_cancel_c,
        Coalesce.resize_ms,
        CallbackData,
        cb,
        coalesceCallback,
    );
}

fn syncResetTimeoutMs(post_resize: *const termio.StreamHandler.PostResizeState) u64 {
    if (!post_resize.active or !post_resize.held_sync_output) {
        return sync_reset_ms;
    }
    if (post_resize.deadline == null and post_resize.hard_deadline == null) {
        return 1;
    }
    const now = std.Io.Timestamp.now(global.io(), .awake);
    var cap_ms: u64 = std.math.maxInt(u64);
    if (post_resize.deadline) |dl| {
        const rem_ms = now.durationTo(dl).toMilliseconds();
        if (rem_ms <= 0) return 1;
        cap_ms = @min(cap_ms, @as(u64, @intCast(rem_ms)));
    }
    if (post_resize.hard_deadline) |hd| {
        const rem_ms = now.durationTo(hd).toMilliseconds();
        if (rem_ms <= 0) return 1;
        cap_ms = @min(cap_ms, @as(u64, @intCast(rem_ms)));
    }
    return @max(@as(u64, 1), cap_ms);
}

fn syncResetTimeoutForHandler(handler: *const termio.StreamHandler) u64 {
    if (handler.post_resize.active and handler.post_resize.held_sync_output) {
        return syncResetTimeoutMs(&handler.post_resize);
    }
    if (handler.tui_wipe_hold.active and handler.tui_wipe_hold.held_sync_output) {
        const dl = handler.tui_wipe_hold.deadline orelse return 1;
        const now = std.Io.Timestamp.now(global.io(), .awake);
        const rem_ms = now.durationTo(dl).toMilliseconds();
        if (rem_ms <= 0) return 1;
        return @max(
            @as(u64, 1),
            @min(@as(u64, @intCast(rem_ms)), termio.StreamHandler.TuiWipeHoldState.hold_limit_ms),
        );
    }
    if (handler.sync_output_started_at) |started| {
        const now = std.Io.Timestamp.now(global.io(), .awake);
        const elapsed_ms = started.durationTo(now).toMilliseconds();
        const max_ms: i64 = @intCast(termio.StreamHandler.sync_active_max_ms);
        if (elapsed_ms >= max_ms) return 1;
        const rem_ms: u64 = if (elapsed_ms <= 0)
            termio.StreamHandler.sync_active_max_ms
        else
            @intCast(max_ms - elapsed_ms);
        return @max(@as(u64, 1), @min(sync_reset_ms, rem_ms));
    }
    return sync_reset_ms;
}

fn startSynchronizedOutput(self: *Thread, cb: *CallbackData) void {
    const timeout_ms: u64 = timeout: {
        cb.io.renderer_state.mutex.lockUncancelable(global.io());
        defer cb.io.renderer_state.mutex.unlock(global.io());
        break :timeout syncResetTimeoutForHandler(&cb.io.terminal_stream.handler);
    };
    self.sync_reset.reset(
        &self.loop,
        &self.sync_reset_c,
        &self.sync_reset_cancel_c,
        timeout_ms,
        CallbackData,
        cb,
        syncResetCallback,
    );
}

fn handleResize(
    self: *Thread,
    _: *CallbackData,
    size: renderer.Size,
    notify_child: bool,
) void {
    // Never let a later visual-only resize weaken a pending ordinary resize.
    // The latest geometry still wins.
    const pending_notify = if (self.coalesce_data.resize) |v|
        v.notify_child
    else
        false;
    self.coalesce_data.resize = .{
        .size = size,
        .notify_child = notify_child or pending_notify,
    };
}

fn commitResize(
    self: *Thread,
    cb: *CallbackData,
    size: renderer.Size,
) !void {
    // A mouse-up/transition-end can race the short visual coalescing timer.
    // Supersede its pending value, apply the exact final model geometry, then
    // publish only that geometry to the child.
    self.coalesce_data.resize = null;
    try cb.io.resizeVisual(size, false);
    try cb.io.commitResize(&cb.data, size);
}

fn syncResetCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => return .disarm,
        else => {
            log.warn("error during sync reset callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    cb.io.resetSynchronizedOutput();
    return .disarm;
}

fn coalesceCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during coalesce callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;

    if (cb.self.coalesce_data.resize) |v| {
        cb.self.coalesce_data.resize = null;
        if (v.notify_child) {
            cb.io.resize(&cb.data, v.size) catch |err| {
                log.warn("error during resize err={}", .{err});
            };
        } else {
            cb.io.resizeVisual(v.size, false) catch |err| {
                log.warn("error during live resize err={}", .{err});
            };
        }
    }

    return .disarm;
}

fn wakeupCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const cb = cb_ orelse return .rearm;
    cb.self.drainMailbox(cb) catch |err|
        log.err("error draining mailbox err={}", .{err});

    return .rearm;
}

fn stopCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    cb_.?.self.loop.stop();
    return .disarm;
}

fn startScrollTimer(self: *Thread, cb: *CallbackData) void {
    self.scroll_active = true;

    switch (self.scroll_c.state()) {
        // If it is already active, e.g. startScrollTimer is called multiple
        // times, then we just return. We can't simply check `scroll_active`
        // because its possible that `stopScrollTimer` was called but there
        // was no loop tick between then and now to halt out completion.
        .active => return,

        // If the completion is not active then we need to start it.
        .dead => self.scroll.run(
            &self.loop,
            &self.scroll_c,
            selection_scroll_ms,
            CallbackData,
            cb,
            selectionScrollCallback,
        ),
    }
}

fn stopScrollTimer(self: *Thread) void {
    // This will stop the scrolling on the next iteration.
    self.scroll_active = false;
}

fn selectionScrollCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during selection scroll callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    const self = cb.self;

    // Send the tick to the main surface
    _ = cb.io.surface_mailbox.push(
        .{ .selection_scroll_tick = self.scroll_active },
        .{ .instant = {} },
    );

    if (self.scroll_active) self.scroll.run(
        &self.loop,
        &self.scroll_c,
        selection_scroll_ms,
        CallbackData,
        cb,
        selectionScrollCallback,
    );

    return .disarm;
}

test "Thread: syncResetTimeoutMs uses bounded hold deadlines only when held_sync_output is active" {
    const testing = std.testing;
    const now = std.Io.Timestamp.now(testing.io, .awake);

    var inactive: termio.StreamHandler.PostResizeState = .{};
    try testing.expectEqual(sync_reset_ms, syncResetTimeoutMs(&inactive));

    // In scroll-restore tail window (`held_sync_output == false`), normal sync reset applies.
    var tail: termio.StreamHandler.PostResizeState = .{
        .active = true,
        .held_sync_output = false,
        .scroll_deadline = now.addDuration(.fromMilliseconds(900)),
    };
    try testing.expectEqual(sync_reset_ms, syncResetTimeoutMs(&tail));

    // When held, timeout is capped by `deadline`, `hard_deadline`, and `hard_limit_ms`.
    var held: termio.StreamHandler.PostResizeState = .{
        .active = true,
        .held_sync_output = true,
        .deadline = now.addDuration(.fromMilliseconds(320)),
        .hard_deadline = now.addDuration(.fromMilliseconds(420)),
        .scroll_deadline = now.addDuration(.fromMilliseconds(900)),
    };
    const held_timeout = syncResetTimeoutMs(&held);
    try testing.expect(held_timeout >= 1 and held_timeout <= 320);

    // Expired or missing deadlines resolve to 1ms immediate unfreeze.
    held.hard_deadline = now.addDuration(.fromMilliseconds(-5));
    try testing.expectEqual(@as(u64, 1), syncResetTimeoutMs(&held));

    var missing_deadlines: termio.StreamHandler.PostResizeState = .{
        .active = true,
        .held_sync_output = true,
    };
    try testing.expectEqual(@as(u64, 1), syncResetTimeoutMs(&missing_deadlines));
}

test "Thread: syncResetTimeoutForHandler handles remote post_resize, tui_wipe_hold, and active sync cap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const now = std.Io.Timestamp.now(testing.io, .awake);

    var term = try @import("../terminal/main.zig").Terminal.init(testing.io, alloc, .{
        .cols = 40,
        .rows = 10,
    });
    defer term.deinit(alloc);
    var mutex: std.Io.Mutex = .init;
    var renderer_state: renderer.State = .{
        .mutex = &mutex,
        .terminal = &term,
    };
    var size: renderer.Size = .{
        .screen = .{ .width = 400, .height = 200 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };
    var termio_mailbox = try termio.Mailbox.initSPSC(alloc);
    defer termio_mailbox.deinit(alloc);
    var renderer_mailbox: renderer.Thread.Mailbox = .{};
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();

    var handler: termio.StreamHandler = .{
        .alloc = alloc,
        .remote_session = true,
        .remote_ssh_session = true,
        .size = &size,
        .terminal = &term,
        .termio_mailbox = &termio_mailbox,
        .surface_mailbox = undefined,
        .renderer_state = &renderer_state,
        .renderer_mailbox = &renderer_mailbox,
        .renderer_wakeup = wakeup,
        .enquiry_response = "",
        .osc_color_report_format = .none,
        .clipboard_write = .deny,
    };
    defer handler.deinit();

    // 1. Remote `post_resize` hold allows deadlines > 420ms (up to 1800ms / 2400ms).
    handler.post_resize = .{
        .active = true,
        .held_sync_output = true,
        .deadline = now.addDuration(.fromMilliseconds(1800)),
        .hard_deadline = now.addDuration(.fromMilliseconds(2400)),
        .scroll_deadline = now.addDuration(.fromMilliseconds(3200)),
    };
    const remote_timeout = syncResetTimeoutForHandler(&handler);
    try testing.expect(remote_timeout > 420 and remote_timeout <= 1800);
    handler.post_resize = .{};

    // 2. Non-resize `tui_wipe_hold` uses `hold_limit_ms` (<= 2500ms) and resolves expired/missing to 1ms.
    handler.tui_wipe_hold = .{
        .active = true,
        .held_sync_output = true,
        .deadline = now.addDuration(.fromMilliseconds(2500)),
    };
    const wipe_timeout = syncResetTimeoutForHandler(&handler);
    try testing.expect(wipe_timeout >= 1 and wipe_timeout <= termio.StreamHandler.TuiWipeHoldState.hold_limit_ms);
    try testing.expect(wipe_timeout > sync_reset_ms);

    handler.tui_wipe_hold.deadline = now.addDuration(.fromMilliseconds(-5));
    try testing.expectEqual(@as(u64, 1), syncResetTimeoutForHandler(&handler));

    handler.tui_wipe_hold.deadline = null;
    try testing.expectEqual(@as(u64, 1), syncResetTimeoutForHandler(&handler));
    handler.tui_wipe_hold = .{};

    // 3. Active genuine DEC 2026 uses `sync_reset_ms` initially, then caps at `sync_active_max_ms` (15s).
    handler.sync_output_started_at = now.addDuration(.fromMilliseconds(-100));
    try testing.expectEqual(sync_reset_ms, syncResetTimeoutForHandler(&handler));

    handler.sync_output_started_at = now.addDuration(.fromMilliseconds(-14_750));
    const tail_cap = syncResetTimeoutForHandler(&handler);
    try testing.expect(tail_cap >= 1 and tail_cap <= 250);

    handler.sync_output_started_at = now.addDuration(.fromMilliseconds(-15_010));
    try testing.expectEqual(@as(u64, 1), syncResetTimeoutForHandler(&handler));
}

test "Thread: drainMailbox preserves Resize-then-Write and Write-then-Resize PTY ordering" {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .ios) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    const alloc = testing.allocator;
    const configpkg = @import("../config.zig");
    const ptypkg = @import("../pty.zig");
    const posix = std.posix;

    var cfg = try configpkg.Config.default(alloc);
    defer cfg.deinit();

    const env: std.process.Environ.Map = .init(alloc);
    var exec_backend = try termio.Exec.init(alloc, .{
        .env = env,
        .resources_dir = null,
        .term = "xterm-256color",
        .rt_pre_exec_info = .init(&cfg),
        .rt_post_fork_info = .init(&cfg),
    });

    const pty = try ptypkg.Pty.open(.{
        .ws_row = 20,
        .ws_col = 40,
        .ws_xpixel = 400,
        .ws_ypixel = 400,
    });
    defer _ = posix.system.close(pty.slave);
    exec_backend.subprocess.pty = pty;

    var term = try @import("../terminal/main.zig").Terminal.init(testing.io, alloc, .{
        .cols = 40,
        .rows = 20,
    });
    var mutex: std.Io.Mutex = .init;
    var renderer_state: renderer.State = .{
        .mutex = &mutex,
        .terminal = &term,
    };
    var renderer_mailbox: renderer.Thread.Mailbox = .{};
    const wakeup = try xev.Async.init();
    const mailbox = try termio.Mailbox.initSPSC(alloc);

    var io: termio.Termio = .{
        .alloc = alloc,
        .backend = .{ .exec = exec_backend },
        .config = undefined,
        .terminal = term,
        .renderer_state = &renderer_state,
        .renderer_wakeup = wakeup,
        .renderer_mailbox = &renderer_mailbox,
        .surface_mailbox = undefined,
        .size = .{
            .screen = .{ .width = 400, .height = 400 },
            .cell = .{ .width = 10, .height = 20 },
            .padding = .{},
        },
        .mailbox = mailbox,
        .terminal_stream = undefined,
    };
    io.renderer_state.terminal = &io.terminal;
    io.terminal_stream = .init(.{
        .allocator = alloc,
        .handler = .{
            .alloc = alloc,
            .size = &io.size,
            .terminal = &io.terminal,
            .termio_mailbox = &io.mailbox,
            .surface_mailbox = undefined,
            .renderer_state = io.renderer_state,
            .renderer_mailbox = io.renderer_mailbox,
            .renderer_wakeup = io.renderer_wakeup,
            .enquiry_response = "",
            .osc_color_report_format = .none,
            .clipboard_write = .deny,
        },
    });
    defer {
        if (io.backend.exec.subprocess.pty) |*owned| {
            owned.deinit();
            io.backend.exec.subprocess.pty = null;
        }
        io.backend.deinit();
        io.terminal_stream.deinit();
        io.renderer_wakeup.deinit();
        io.terminal.deinit(alloc);
        io.mailbox.deinit(alloc);
    }

    var thread = try Thread.init(alloc);
    defer thread.deinit();

    const stream = xev.Stream.initFd(pty.master);
    const termios_timer = try xev.Timer.init();
    const pipe = try internal_os.pipe();
    defer _ = posix.system.close(pipe[0]);

    var cb: CallbackData = .{
        .self = &thread,
        .io = &io,
        .data = .{
            .alloc = alloc,
            .loop = &thread.loop,
            .renderer_state = &renderer_state,
            .surface_mailbox = undefined,
            .mailbox = &io.mailbox,
            .backend = .{ .exec = .{
                .subprocess = &io.backend.exec.subprocess,
                .io = &io,
                .start = .now(testing.io, .awake),
                .write_stream = stream,
                .process = null,
                .read_thread = undefined,
                .read_thread_pipe = pipe[1],
                .read_thread_fd = pty.master,
                .termios_timer = termios_timer,
                .termios_timer_running = false,
            } },
        },
    };
    defer cb.data.deinit();

    // 1. Resize queued BEFORE write in the same mailbox batch applies TIOCSWINSZ
    //    before the write is flushed.
    const size_a: renderer.Size = .{
        .screen = .{ .width = 500, .height = 480 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };
    io.mailbox.send(.{ .resize = size_a }, null);
    io.mailbox.send(try termio.Message.writeReq(alloc, @as([]const u8, "after-resize\n")), null);
    try thread.drainMailbox(&cb);

    const ws_after_first_drain = try io.backend.exec.subprocess.pty.?.getSize();
    try testing.expectEqual(@as(u16, 50), ws_after_first_drain.ws_col);
    try testing.expectEqual(@as(u16, 24), ws_after_first_drain.ws_row);

    // Flush the queued write and let the coalesce timer finish.
    try thread.loop.run(.until_done);
    var read_buf: [128]u8 = undefined;
    const n1 = try posix.read(pty.slave, &read_buf);
    try testing.expectEqualStrings("after-resize\n", read_buf[0..n1]);

    // 2. Write queued BEFORE resize in the same mailbox batch defers TIOCSWINSZ
    //    until the write has been written to the PTY master fd.
    const size_b: renderer.Size = .{
        .screen = .{ .width = 600, .height = 600 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };
    io.mailbox.send(try termio.Message.writeReq(alloc, @as([]const u8, "before-resize\n")), null);
    io.mailbox.send(.{ .resize = size_b }, null);
    try thread.drainMailbox(&cb);

    // Immediately after drainMailbox (before xev flushes write_queue), PTY size is still size_a!
    const ws_before_write_flush = try io.backend.exec.subprocess.pty.?.getSize();
    try testing.expectEqual(@as(u16, 50), ws_before_write_flush.ws_col);
    try testing.expectEqual(@as(u16, 24), ws_before_write_flush.ws_row);

    // Once the write flushes on the next loop tick, TIOCSWINSZ updates to size_b!
    try thread.loop.run(.once);
    const ws_after_write_flush = try io.backend.exec.subprocess.pty.?.getSize();
    try testing.expectEqual(@as(u16, 60), ws_after_write_flush.ws_col);
    try testing.expectEqual(@as(u16, 30), ws_after_write_flush.ws_row);
    const n2 = try posix.read(pty.slave, &read_buf);
    try testing.expectEqualStrings("before-resize\n", read_buf[0..n2]);

    // 3. Even while `coalesce_c` is ALREADY `.active` (from step 2's 25ms coalesce timer),
    //    a new child resize followed by a write MUST still flush TIOCSWINSZ before the write!
    try testing.expectEqual(.active, thread.coalesce_c.state());
    const size_c: renderer.Size = .{
        .screen = .{ .width = 720, .height = 560 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };
    io.mailbox.send(.{ .resize = size_c }, null);
    io.mailbox.send(try termio.Message.writeReq(alloc, @as([]const u8, "inside-active-coalesce\n")), null);
    try thread.drainMailbox(&cb);

    const ws_during_active_coalesce = try io.backend.exec.subprocess.pty.?.getSize();
    try testing.expectEqual(@as(u16, 72), ws_during_active_coalesce.ws_col);
    try testing.expectEqual(@as(u16, 28), ws_during_active_coalesce.ws_row);

    // Let queued write and reset coalesce timer finish cleanly before teardown.
    try thread.loop.run(.until_done);
    const n3 = try posix.read(pty.slave, &read_buf);
    try testing.expectEqualStrings("inside-active-coalesce\n", read_buf[0..n3]);
}
