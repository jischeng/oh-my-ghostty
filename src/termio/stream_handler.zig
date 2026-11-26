const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const terminal = @import("../terminal/main.zig");
const terminfo = @import("../terminfo/main.zig");
const posix = std.posix;

const log = std.log.scoped(.io_handler);

/// This is used as the handler for the terminal.Stream type. This is
/// stateful and is expected to live for the entire lifetime of the terminal.
/// It is NOT VALID to stop a stream handler, create a new one, and use that
/// unless all of the member fields are copied.
pub const StreamHandler = struct {
    alloc: Allocator,
    /// The daemon owns terminal query replies for native session surfaces.
    remote_session: bool = false,

    /// True when backed by a remote `SessionBackend` SSH session.
    remote_ssh_session: bool = false,

    /// True while inside an OSC 3008 `type=remote` SSH context on a local PTY.
    in_remote_ssh_context: bool = false,
    size: *renderer.Size,
    terminal: *terminal.Terminal,

    /// Mailbox for data to the termio thread.
    termio_mailbox: *termio.Mailbox,

    /// Mailbox for the surface.
    surface_mailbox: apprt.surface.Mailbox,

    /// The shared render state
    renderer_state: *renderer.State,

    /// The mailbox for notifying the renderer of things.
    renderer_mailbox: *renderer.Thread.Mailbox,

    /// A handle to wake up the renderer. This hints to the renderer that
    /// a repaint should happen.
    renderer_wakeup: xev.Async,

    /// The response to use for ENQ requests. The memory is owned by
    /// whoever owns StreamHandler.
    enquiry_response: []const u8,

    /// The color reporting format for OSC requests.
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,

    /// The clipboard write access configuration.
    clipboard_write: configpkg.ClipboardAccess,

    /// Maximum total decoded bytes per Kitty clipboard protocol
    /// (OSC 5522) write transaction; exceeding it aborts with EFBIG.
    clipboard_write_limit: usize = 64 * 1024 * 1024,

    /// Whether DECRQCRA may report the checksum of an area of the screen,
    /// and XTCHECKSUM may change how it's calculated.
    xt_checksum_report: bool = false,

    //---------------------------------------------------------------
    // Internal state

    /// The APC command handler maintains the APC state. APC is like
    /// CSI or OSC, but it is a private escape sequence that is used
    /// to send commands to the terminal emulator. This is used by
    /// the kitty graphics protocol.
    apc: terminal.apc.Handler = .{},

    /// The DCS handler maintains DCS state. DCS is like CSI or OSC,
    /// but requires more stateful parsing. This is used by functionality
    /// such as XTGETTCAP.
    dcs: terminal.dcs.Handler = .{},

    /// The tmux control mode viewer state.
    tmux_viewer: if (tmux_enabled) ?*terminal.tmux.Viewer else void = if (tmux_enabled) null else {},

    /// Session password grants for the Kitty clipboard protocol.
    /// Requests carrying a granted password skip the permission prompt.
    kitty_clipboard_grants: terminal.kitty.clipboard.Grants = .{},

    /// The in-flight Kitty clipboard protocol (OSC 5522) write
    /// transaction, if any.
    kitty_clipboard_write: ?*terminal.kitty.clipboard.WriteState = null,

    /// This is set to true when a message was written to the termio
    /// mailbox. This can be used by callers to determine if they need
    /// to wake up the termio thread.
    termio_messaged: bool = false,

    /// This is set to true when we've seen a title escape sequence. We use
    /// this to determine if we need to default the window title.
    seen_title: bool = false,

    /// Set once the running program enables DEC mode 2026 (`synchronized_output`)
    /// on the current screen, and cleared on full reset or shell semantic prompt.
    seen_synchronized_output: bool = false,

    /// Timestamps tracking active DEC 2026 renewal across multi-second SSH writes.
    sync_output_started_at: ?std.Io.Timestamp = null,
    sync_output_last_renewed_at: ?std.Io.Timestamp = null,

    /// Coalesces intermediate post-resize screen wipes (`CSI J`, `CSI 2 J`,
    /// `CSI 3 J`) and restores a scrolled-up primary-screen viewport after a
    /// TUI reprints its history on `SIGWINCH`.
    post_resize: PostResizeState = .{},

    /// Coalesces non-resize TUI two-phase blank wipes (`Ctrl+O`) inside DEC 2026.
    tui_wipe_hold: TuiWipeHoldState = .{},

    /// Maximum byte budget for unknown OSC sequences forwarded via `osc_unknown`
    /// (used for OSC 26 / TAP). Sequences exceeding this limit arrive with
    /// `truncated = true` and are dropped.
    pub const osc_unknown_max_bytes: usize = 4096;

    /// Maximum duration an unbroken active DEC 2026 frame can remain frozen
    /// while PTY output continues arriving.
    pub const sync_active_max_ms: u64 = 15_000;

    /// Minimum interval between active DEC 2026 timer renewals on streaming output.
    pub const sync_renew_interval_ms: u64 = 250;

    pub const PostResizeState = struct {
        /// Short bounded safety window from the latest resize (or completed
        /// redraw cycle) during which an immediate blank-wipe (`CSI J` /
        /// `CSI 2 J` / `CSI 3 J` leaving only 0-4 top lines) is coalesced
        /// across a two-phase TUI resize redraw.
        pub const idle_window_ms = 320;

        /// Hard cap from the latest resize so post-resize blank-wipe hold
        /// never freezes rendering past 420ms.
        pub const hard_limit_ms = 420;

        /// Tail window during which `scroll_save` remains armed (without
        /// holding `synchronized_output`) so a TUI whose history reprint
        /// arrives 250-800ms after `SIGWINCH` still restores scrollback.
        pub const scroll_restore_ms = 900;

        /// Extended coalescing windows for remote SSH sessions where Phase 2
        /// redraws arrive over slow/high-RTT links.
        pub const remote_idle_window_ms = 1800;
        pub const remote_hard_limit_ms = 2400;
        pub const remote_scroll_restore_ms = 3200;

        pub const ScrollSave = struct {
            offset: usize,
            total: usize,
            len: usize,
            distance_from_bottom: usize,
        };

        active: bool = false,
        deadline: ?std.Io.Timestamp = null,
        hard_deadline: ?std.Io.Timestamp = null,
        scroll_deadline: ?std.Io.Timestamp = null,
        had_scrollback: bool = false,
        pre_cursor_y: terminal.size.CellCountInt = 0,
        saw_erase_below: bool = false,
        saw_full_clear: bool = false,
        held_sync_output: bool = false,
        scroll_save: ?ScrollSave = null,

        pub fn captureScrollSave(screen: *terminal.Screen) ?ScrollSave {
            if (screen.viewportIsBottom()) return null;
            const sb = screen.pages.scrollbar();
            const max_offset = sb.total -| sb.len;
            if (max_offset == 0) return null;
            return .{
                .offset = sb.offset,
                .total = sb.total,
                .len = sb.len,
                .distance_from_bottom = max_offset -| sb.offset,
            };
        }
    };

    pub const TuiWipeHoldState = struct {
        /// Bounded safety cap for holding across a non-resize Phase 1 TUI
        /// full-screen wipe inside DEC 2026 before Phase 2 reprints history.
        pub const hold_limit_ms: u64 = 2500;

        active: bool = false,
        deadline: ?std.Io.Timestamp = null,
        had_substantial_content: bool = false,
        saw_full_clear: bool = false,
        saw_erase_below: bool = false,
        held_sync_output: bool = false,
    };

    pub const Stream = terminal.Stream(StreamHandler);

    /// True if we have tmux control mode built in.
    pub const tmux_enabled = terminal.options.tmux_control_mode;

    pub fn deinit(self: *StreamHandler) void {
        self.apc.deinit();
        self.dcs.deinit();
        self.kittyClipboardWriteAbort();
        self.kitty_clipboard_grants.deinit(self.alloc);
        if (comptime tmux_enabled) tmux: {
            const viewer = self.tmux_viewer orelse break :tmux;
            viewer.deinit();
            self.alloc.destroy(viewer);
            self.tmux_viewer = null;
        }
    }

    /// This queues a render operation with the renderer thread. The render
    /// isn't guaranteed to happen immediately but it will happen as soon as
    /// practical.
    pub inline fn queueRender(self: *StreamHandler) !void {
        try self.renderer_wakeup.notify();
    }

    /// Change the configuration for this handler.
    pub fn changeConfig(self: *StreamHandler, config: *termio.DerivedConfig) void {
        self.osc_color_report_format = config.osc_color_report_format;
        self.clipboard_write = config.clipboard_write;
        self.clipboard_write_limit = config.clipboard_write_limit;
        self.enquiry_response = config.enquiry_response;
        self.xt_checksum_report = config.xt_checksum_report;
        self.terminal.setDefaultCursorStyle(config.cursor_style);
        self.terminal.setDefaultCursorBlink(config.cursor_blink);
        self.terminal.setDefaultXtChecksum(config.xt_checksum_extension);

        // The config could have changed any of our colors, but the mode
        // 2031 report is sent by Termio.changeConfig. This runs on the io
        // thread, which is the only reader of the termio mailbox, so
        // sending to it here would deadlock if the mailbox were full.
    }

    inline fn surfaceMessageWriter(
        self: *StreamHandler,
        msg: apprt.surface.Message,
    ) void {
        if (comptime apprt.runtime == apprt.none) return;
        // See messageWriter which has similar logic and explains why
        // we may have to do this.
        if (self.surface_mailbox.push(msg, .{ .instant = {} }) == 0) {
            self.renderer_state.mutex.unlock(global.io());
            defer self.renderer_state.mutex.lockUncancelable(global.io());
            _ = self.surface_mailbox.push(msg, .{ .forever = {} });
        }
    }

    inline fn messageWriter(self: *StreamHandler, msg: termio.Message) void {
        if (self.remote_session) switch (msg) {
            .write_small, .write_stable, .write_alloc, .size_report, .color_scheme_report, .visibility_report => {
                msg.deinit();
                return;
            },
            else => {},
        };
        self.termio_mailbox.send(msg, self.renderer_state.mutex);
        self.termio_messaged = true;
    }

    /// Send a renderer message and unlock the renderer state mutex
    /// if necessary to ensure we don't deadlock.
    ///
    /// This assumes the renderer state mutex is locked.
    inline fn rendererMessageWriter(
        self: *StreamHandler,
        msg: renderer.Message,
    ) void {
        // See termio.Mailbox.send for more details on how this works.

        // Try instant first. If it works then we can return.
        if (self.renderer_mailbox.push(msg, .{ .instant = {} }) > 0) {
            return;
        }

        // Instant would have blocked. Release the renderer mutex,
        // wake up the renderer to allow it to process the message,
        // and then try again.
        self.renderer_state.mutex.unlock(global.io());
        defer self.renderer_state.mutex.lockUncancelable(global.io());
        self.renderer_wakeup.notify() catch |err| {
            // This is an EXTREMELY unlikely case. We still don't return
            // and attempt to send the message because its most likely
            // that everything is fine, but log in case a freeze happens.
            log.warn(
                "failed to notify renderer, may deadlock err={}",
                .{err},
            );
        };
        _ = self.renderer_mailbox.push(msg, .{ .forever = {} });
    }

    pub fn vt(
        self: *StreamHandler,
        comptime action: Stream.Action.Tag,
        value: Stream.Action.Value(action),
    ) void {
        self.vtFallible(action, value) catch |err| vtFailed(action, err);
    }

    /// The stream's hook for runs it knows are printable ASCII.
    pub fn vtPrintAscii(self: *StreamHandler, bytes: []const u8) void {
        self.terminal.printSliceAscii(bytes) catch |err| vtFailed(.print_slice, err);
    }

    /// This is noinline to keep failure handling and logging out of the
    /// hot VT action path.
    noinline fn vtFailed(action: Stream.Action.Tag, err: anyerror) void {
        @branchHint(.cold);
        log.warn("error handling VT action action={} err={}", .{ action, err });
    }

    inline fn vtFallible(
        self: *StreamHandler,
        comptime action: Stream.Action.Tag,
        value: Stream.Action.Value(action),
    ) !void {
        // The branch hints here are based on real world data
        // which indicates that the most common actions are:
        //
        // 1. print
        // 2. set_attributes
        // 3. carriage_return
        // 4. line_feed
        // 5. cursor_pos
        //
        // Together, these 5 actions make up nearly 98% of
        // all actions encountered in real world scenarios.
        //
        // ref: https://github.com/qwerasd205/asciinema-stats
        switch (action) {
            .print => {
                @branchHint(.likely);
                try self.terminal.print(value.cp);
            },
            .print_slice => {
                @branchHint(.likely);
                try self.terminal.printSlice(value.cps);
            },
            .print_repeat => try self.terminal.printRepeat(value),
            .bell => self.bell(),
            .backspace => self.terminal.backspace(),
            .horizontal_tab => self.horizontalTab(value),
            .horizontal_tab_back => self.horizontalTabBack(value),
            .linefeed => {
                @branchHint(.likely);
                try self.linefeed();
            },
            .carriage_return => {
                @branchHint(.likely);
                self.terminal.carriageReturn();
            },
            .enquiry => try self.enquiry(),
            .invoke_charset => self.terminal.invokeCharset(value.bank, value.charset, value.locking),
            .cursor_up => self.terminal.cursorUp(value.value),
            .cursor_down => self.terminal.cursorDown(value.value),
            .cursor_left => self.terminal.cursorLeft(value.value),
            .cursor_right => self.terminal.cursorRight(value.value),
            .cursor_pos => {
                @branchHint(.likely);
                self.terminal.setCursorPos(value.row, value.col);
            },
            .cursor_col => self.terminal.setCursorCol(value.value),
            .cursor_row => self.terminal.setCursorRow(value.value),
            .cursor_col_relative => self.terminal.cursorColRelative(value.value),
            .cursor_row_relative => self.terminal.cursorRowRelative(value.value),
            .cursor_style => self.terminal.setCursorStyle(value),
            .erase_display_below => {
                self.noteEraseDisplay(.below);
                self.terminal.eraseDisplay(.below, value);
            },
            .erase_display_above => self.terminal.eraseDisplay(.above, value),
            .erase_display_complete => {
                self.noteEraseDisplay(.complete);
                self.terminal.scrollViewport(.{ .bottom = {} });
                if (self.terminal.screens.active_key == .primary and
                    !(self.post_resize.active and self.post_resize.scroll_save != null))
                {
                    self.renderer_state.scroll.pinBottom(0);
                }
                self.terminal.eraseDisplay(.complete, value);
            },
            .erase_display_scrollback => {
                self.noteEraseDisplay(.scrollback);
                self.terminal.eraseDisplay(.scrollback, value);
            },
            .erase_display_scroll_complete => {
                self.noteEraseDisplay(.scroll_complete);
                self.terminal.eraseDisplay(.scroll_complete, value);
            },
            .erase_line_right => self.terminal.eraseLine(.right, value),
            .erase_line_left => self.terminal.eraseLine(.left, value),
            .erase_line_complete => self.terminal.eraseLine(.complete, value),
            .erase_line_right_unless_pending_wrap => self.terminal.eraseLine(.right_unless_pending_wrap, value),
            .delete_chars => self.terminal.deleteChars(value),
            .erase_chars => self.terminal.eraseChars(value),
            .insert_lines => self.terminal.insertLines(value),
            .insert_blanks => self.terminal.insertBlanks(value),
            .insert_columns => self.terminal.insertColumns(value),
            .delete_columns => self.terminal.deleteColumns(value),
            .delete_lines => self.terminal.deleteLines(value),
            .scroll_up => try self.terminal.scrollUp(value),
            .scroll_down => self.terminal.scrollDown(value),
            .tab_clear_current => self.terminal.tabClear(.current),
            .tab_clear_all => self.terminal.tabClear(.all),
            .tab_set => self.terminal.tabSet(),
            .tab_reset => self.terminal.tabReset(),
            .index => try self.index(),
            .next_line => try self.nextLine(),
            .reverse_index => try self.reverseIndex(),
            .back_index => self.terminal.backIndex(),
            .forward_index => self.terminal.forwardIndex(),
            .full_reset => try self.fullReset(),
            .soft_reset => self.terminal.softReset(),
            .set_mode => try self.setMode(value.mode, true),
            .reset_mode => try self.setMode(value.mode, false),
            .save_mode => self.terminal.modes.save(value.mode),
            .restore_mode => {
                // For restore mode we have to restore but if we set it, we
                // always have to call setMode because setting some modes have
                // side effects and we want to make sure we process those.
                const v = self.terminal.modes.restore(value.mode);
                try self.setMode(value.mode, v);
            },
            .request_mode => try self.requestMode(value.mode),
            .request_mode_unknown => try self.requestModeUnknown(value.mode, value.ansi),
            .top_and_bottom_margin => self.terminal.setTopAndBottomMargin(value.top_left, value.bottom_right),
            .left_and_right_margin => self.terminal.setLeftAndRightMargin(value.top_left, value.bottom_right),
            .left_and_right_margin_ambiguous => {
                if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                    self.terminal.setLeftAndRightMargin(0, 0);
                } else {
                    self.terminal.saveCursor();
                }
            },
            .save_cursor => try self.saveCursor(),
            .restore_cursor => try self.restoreCursor(),
            .modify_key_format => try self.setModifyKeyFormat(value),
            .protected_mode_off => self.terminal.setProtectedMode(.off),
            .protected_mode_iso => self.terminal.setProtectedMode(.iso),
            .protected_mode_dec => self.terminal.setProtectedMode(.dec),
            .mouse_shift_capture => self.terminal.flags.mouse_shift_capture = if (value) .true else .false,
            .xt_checksum_extension => if (self.xt_checksum_report) {
                self.terminal.flags.xt_checksum = value.flags;
            },
            .request_xt_checksum => self.reportXtChecksum(value),
            .size_report => self.sendSizeReport(value),
            .resize_window => self.surfaceMessageWriter(.{ .resize_window = value }),
            .xtversion => try self.reportXtversion(),
            .device_attributes => try self.deviceAttributes(value),
            .device_status => try self.deviceStatusReport(value.request),
            .kitty_keyboard_query => try self.queryKittyKeyboard(),
            .kitty_keyboard_push => {
                log.debug("pushing kitty keyboard mode: {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.push(value.flags);
            },
            .kitty_keyboard_pop => {
                log.debug("popping kitty keyboard mode n={}", .{value});
                self.terminal.screens.active.kitty_keyboard.pop(@intCast(value));
            },
            .kitty_keyboard_set => {
                log.debug("setting kitty keyboard mode: set {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.set, value.flags);
            },
            .kitty_keyboard_set_or => {
                log.debug("setting kitty keyboard mode: or {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.@"or", value.flags);
            },
            .kitty_keyboard_set_not => {
                log.debug("setting kitty keyboard mode: not {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.not, value.flags);
            },
            .kitty_color_report => try self.kittyColorReport(value),
            .color_operation => try self.colorOperation(value.op, &value.requests, value.terminator),
            .end_hyperlink => try self.endHyperlink(),
            .active_status_display => self.terminal.status_display = value,
            .decaln => try self.decaln(),
            .window_title => try self.windowTitle(value.title),
            .report_pwd => try self.reportPwd(value.url),
            .context_signal => try self.contextSignal(value),
            .show_desktop_notification => try self.showDesktopNotification(value.title, value.body),
            .progress_report => self.progressReport(value),
            .start_hyperlink => try self.startHyperlink(value.uri, value.id),
            .clipboard_contents => try self.clipboardContents(value.kind, value.data),
            .semantic_prompt => try self.semanticPrompt(value),
            .mouse_shape => try self.setMouseShape(value),
            .mouse_shape_reset => try self.setMouseShape(
                if (self.terminal.flags.mouse_event != .none) .default else .text,
            ),
            .configure_charset => self.configureCharset(value.slot, value.charset),
            .set_attributes => {
                @branchHint(.likely);
                self.terminal.setAttributes(value.parser()) catch |err| {
                    @branchHint(.cold);
                    log.warn("error setting attributes: {}", .{err});
                };
            },
            .dcs_hook => try self.dcsHook(value),
            .dcs_put => try self.dcsPut(value),
            .dcs_unhook => try self.dcsUnhook(),
            .apc_start => self.apc.start(),
            .apc_end => try self.apcEnd(),
            .apc_put => self.apc.feed(self.alloc, value),
            .apc_put_slice => self.apc.feedSlice(self.alloc, value.bytes),
            .kitty_clipboard => try self.kittyClipboard(value),
            .program_status => switch (value) {
                .query => |terminator| try self.contextSignal(.{
                    .action = .start,
                    .id = "omg-program-status-query",
                    .metadata = terminator.string(),
                }),
                .report => |report| try self.contextSignal(.{
                    .action = .start,
                    .id = "omg-program-status",
                    .metadata = report.data,
                }),
            },

            .osc_unknown => try self.oscUnknown(value),

            // Unimplemented
            .title_push,
            .title_pop,
            .kitty_dnd,
            => {},
        }
    }

    pub inline fn dcsHook(self: *StreamHandler, dcs: terminal.DCS) !void {
        var cmd = self.dcs.hook(self.alloc, dcs) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    pub inline fn dcsPut(self: *StreamHandler, byte: u8) !void {
        var cmd = self.dcs.put(byte) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    pub inline fn dcsUnhook(self: *StreamHandler) !void {
        var cmd = self.dcs.unhook() orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsCommand(self: *StreamHandler, cmd: *terminal.dcs.Command) !void {
        // log.warn("DCS command: {}", .{cmd});
        switch (cmd.*) {
            .tmux => |tmux| tmux: {
                // If tmux control mode is disabled at the build level,
                // then this whole block shouldn't be analyzed.
                if (comptime !tmux_enabled) break :tmux;
                log.info("tmux control mode event cmd={f}", .{tmux});

                switch (tmux) {
                    .enter => {
                        // Setup our viewer state
                        assert(self.tmux_viewer == null);
                        const viewer = try self.alloc.create(terminal.tmux.Viewer);
                        errdefer self.alloc.destroy(viewer);
                        viewer.* = try .init(global.io(), self.alloc);
                        errdefer viewer.deinit();
                        self.tmux_viewer = viewer;
                        break :tmux;
                    },

                    .exit => {
                        // Free our viewer state if we have one
                        if (self.tmux_viewer) |viewer| {
                            viewer.deinit();
                            self.alloc.destroy(viewer);
                            self.tmux_viewer = null;
                        }

                        // And always break since we assert below
                        // that we're not handling an exit command.
                        break :tmux;
                    },

                    else => {},
                }

                assert(tmux != .enter);
                assert(tmux != .exit);

                const viewer = self.tmux_viewer orelse {
                    // This can only really happen if we failed to
                    // initialize the viewer on enter.
                    log.info(
                        "received tmux control mode command without viewer: {f}",
                        .{tmux},
                    );

                    break :tmux;
                };

                for (viewer.next(.{ .tmux = tmux })) |action| {
                    log.info("tmux viewer action={f}", .{action});
                    switch (action) {
                        .exit => {
                            // We ignore this because we will fully exit when
                            // our DCS connection ends. We may want to handle
                            // this in the future to notify our GUI we're
                            // disconnected though.
                        },

                        .command => |command| {
                            assert(command.len > 0);
                            assert(command[command.len - 1] == '\n');
                            self.messageWriter(try termio.Message.writeReq(
                                self.alloc,
                                command,
                            ));
                        },

                        .windows => {
                            // TODO
                        },

                        .active_window => {
                            // TODO: notify the GUI that tmux's current
                            // window changed.
                        },
                    }
                }
            },

            .xtgettcap => |*gettcap| {
                const map = comptime terminfo.ghostty.xtgettcapMap();
                while (gettcap.next()) |key| {
                    const response = map.get(key) orelse continue;
                    self.messageWriter(.{ .write_stable = response });
                }
            },

            .decrqss => |decrqss| {
                var response: [terminal.dcs.Command.DECRQSS.max_response_bytes]u8 = undefined;
                const encoded = try decrqss.encode(self.terminal, &response);
                const msg = try termio.Message.writeReq(
                    self.alloc,
                    encoded,
                );
                self.messageWriter(msg);
            },
        }
    }

    pub fn apcEnd(self: *StreamHandler) !void {
        var result = self.apc.end() orelse return;
        defer result.deinit(self.alloc);

        // log.warn("APC command: {}", .{result});
        switch (result) {
            .unknown => return,
            .kitty => |*kitty_cmd| {
                if (self.terminal.kittyGraphics(global.io(), self.alloc, kitty_cmd)) |resp| {
                    var buf: [1024]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    try resp.encode(&writer);
                    const final = writer.buffered();
                    if (final.len > 2) {
                        log.debug("kitty graphics response: {x}", .{final});
                        self.messageWriter(try termio.Message.writeReq(self.alloc, final));
                    }
                }
            },

            .glyph => |*glyph_req| {
                const resp = self.terminal.glyphProtocol(self.alloc, glyph_req);
                switch (glyph_req.*) {
                    .register, .clear => try self.queueRender(),
                    .support, .query => {},
                }

                if (resp) |r| {
                    var buf: [terminal.apc.glyph.Response.max_wire_bytes]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    try r.formatWire(&writer);
                    const final = writer.buffered();
                    log.debug("glyph protocol response: {x}", .{final});
                    self.messageWriter(try termio.Message.writeReq(self.alloc, final));
                }
            },
        }
    }

    inline fn bell(self: *StreamHandler) void {
        self.surfaceMessageWriter(.ring_bell);
    }

    inline fn horizontalTab(self: *StreamHandler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTab();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }

    inline fn horizontalTabBack(self: *StreamHandler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTabBack();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }

    inline fn linefeed(self: *StreamHandler) !void {
        // Small optimization: call index instead of linefeed because they're
        // identical and this avoids one layer of function call overhead.
        try self.terminal.index();
    }

    pub inline fn reverseIndex(self: *StreamHandler) !void {
        self.terminal.reverseIndex();
    }

    pub inline fn index(self: *StreamHandler) !void {
        try self.terminal.index();
    }

    pub inline fn nextLine(self: *StreamHandler) !void {
        try self.terminal.index();
        self.terminal.carriageReturn();
    }

    pub fn setModifyKeyFormat(self: *StreamHandler, format: terminal.ModifyKeyFormat) !void {
        self.terminal.flags.modify_other_keys_2 = false;
        switch (format) {
            .other_keys_numeric => self.terminal.flags.modify_other_keys_2 = true,
            else => {},
        }
    }

    fn requestMode(self: *StreamHandler, mode: terminal.Mode) !void {
        self.sendModeReport(self.terminal.modes.getReport(.fromMode(mode)));
    }

    fn requestModeUnknown(self: *StreamHandler, mode_raw: u16, ansi: bool) !void {
        self.sendModeReport(self.terminal.modes.getReport(.{ .value = mode_raw, .ansi = ansi }));
    }

    fn reportXtChecksum(self: *StreamHandler, req: terminal.xt_checksum.Request) void {
        if (!self.xt_checksum_report) return;
        var data: termio.Message.WriteReq.Small.Array = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        terminal.xt_checksum.encode(
            &writer,
            req.id,
            self.terminal.rectXtChecksum(req),
        ) catch |err| {
            log.err("error encoding checksum report err={}", .{err});
            return;
        };
        self.messageWriter(.{ .write_small = .{
            .data = data,
            .len = @intCast(writer.buffered().len),
        } });
    }

    fn sendModeReport(self: *StreamHandler, report: terminal.modes.Report) void {
        var data: termio.Message.WriteReq.Small.Array = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        report.encode(&writer) catch |err| {
            log.err("error encoding mode report err={}", .{err});
            return;
        };
        self.messageWriter(.{ .write_small = .{
            .data = data,
            .len = @intCast(writer.buffered().len),
        } });
    }

    pub fn setMode(self: *StreamHandler, mode: terminal.Mode, enabled: bool) !void {
        // Note: this function doesn't need to grab the render state or
        // terminal locks because it is only called from process() which
        // grabs the lock.

        // If we are setting cursor blinking, we ignore it if we have
        // a default cursor blink setting set. This is a really weird
        // behavior so this comment will go deep into trying to explain it.
        //
        // There are two ways to set cursor blinks: DECSCUSR (CSI _ q)
        // and DEC mode 12. DECSCUSR is the modern approach and has a
        // way to revert to the "default" (as defined by the terminal)
        // cursor style and blink by doing "CSI 0 q". DEC mode 12 controls
        // blinking and is either on or off and has no way to set a
        // default. DEC mode 12 is also the more antiquated approach.
        //
        // The problem is that if the user specifies a desired default
        // cursor blink with `cursor-style-blink`, the moment a running
        // program uses DEC mode 12, the cursor blink can never be reset
        // to the default without an explicit DECSCUSR. But if a program
        // is using mode 12, it is by definition not using DECSCUSR.
        // This makes for somewhat annoying interactions where a poorly
        // (or legacy) behaved program will stop blinking, and it simply
        // never restarts.
        //
        // To get around this, we have a special case where if the user
        // specifies some explicit default cursor blink desire, we ignore
        // DEC mode 12. We allow DECSCUSR to still set the cursor blink
        // because programs using DECSCUSR usually are well behaved and
        // reset the cursor blink to the default when they exit.
        //
        // To be extra safe, users can also add a manual `CSI 0 q` to
        // their shell config when they render prompts to ensure the
        // cursor is exactly as they request.
        if (mode == .cursor_blinking and
            self.terminal.cursor.default_blink != null)
        {
            return;
        }

        // We first always set the raw mode on our mode state (except
        // synchronized_output, which manages transitions and hold state in
        // setSynchronizedOutput).
        if (mode != .synchronized_output) {
            self.terminal.modes.set(mode, enabled);
        }

        // And then some modes require additional processing.
        switch (mode) {
            // Just noting here that autorepeat has no effect on
            // the terminal. xterm ignores this mode and so do we.
            // We know about just so that we don't log that it is
            // an unknown mode.
            .autorepeat => {},

            // Schedule a render since we changed colors
            .reverse_colors => self.terminal.flags.dirty.reverse_colors = true,

            // Origin resets cursor pos. This is called whether or not
            // we're enabling or disabling origin mode and whether or
            // not the value changed.
            .origin => self.terminal.setCursorPos(1, 1),

            .enable_left_and_right_margin => if (!enabled) {
                // When we disable left/right margin mode we need to
                // reset the left/right margins.
                self.terminal.scrolling_region.left = 0;
                self.terminal.scrolling_region.right = self.terminal.cols - 1;
            },

            .alt_screen_legacy => {
                if (enabled) {
                    self.cancelPostResize();
                    self.cancelTuiWipeHold();
                }
                try self.terminal.switchScreenMode(.@"47", enabled);
            },

            .alt_screen => {
                if (enabled) {
                    self.cancelPostResize();
                    self.cancelTuiWipeHold();
                }
                try self.terminal.switchScreenMode(.@"1047", enabled);
            },

            .alt_screen_save_cursor_clear_enter => {
                if (enabled) {
                    self.cancelPostResize();
                    self.cancelTuiWipeHold();
                }
                try self.terminal.switchScreenMode(.@"1049", enabled);
            },

            // Mode 1048 is xterm's conditional save cursor depending
            // on if alt screen is enabled or not (at the terminal emulator
            // level). Alt screen is always enabled for us so this just
            // does a save/restore cursor.
            .save_cursor => {
                if (enabled) {
                    self.terminal.saveCursor();
                } else {
                    self.terminal.restoreCursor();
                }
            },

            // Force resize back to the window size
            .enable_mode_3 => {
                const grid_size = self.size.grid();
                self.terminal.resize(
                    self.alloc,
                    .{
                        .cols = grid_size.columns,
                        .rows = grid_size.rows,
                    },
                ) catch |err| {
                    log.err("error updating terminal size: {}", .{err});
                };
            },

            .@"132_column" => try self.terminal.deccolm(
                self.alloc,
                if (enabled) .@"132_cols" else .@"80_cols",
            ),

            // We need to start a timer to prevent the emulator being hung
            // forever.
            .synchronized_output => self.setSynchronizedOutput(enabled),

            // BubbleTea v2 (`googleCursedRenderer`, used by `agy`) wraps its
            // screen redraws and `writePrepend` history reprints in
            // `\x1b[?25l` .. `\x1b[?25h` instead of DEC mode 2026.
            .cursor_visible => if (enabled) self.notePostResizeCursorVisible(),

            .linefeed => {
                self.messageWriter(.{ .linefeed_mode = enabled });
            },

            .in_band_size_reports => if (enabled) self.messageWriter(.{
                .size_report = .mode_2048,
            }),

            .report_visibility => if (enabled) self.messageWriter(.{
                .visibility_report = .{
                    .visible = self.terminal.flags.visible,
                    .force = true,
                },
            }),

            .focus_event => if (enabled) self.messageWriter(.{
                .focused = self.terminal.flags.focused,
            }),

            .mouse_event_x10 => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .x10;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_normal => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .normal;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_button => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .button;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_any => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .any;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },

            .mouse_format_utf8 => self.terminal.flags.mouse_format = if (enabled) .utf8 else .x10,
            .mouse_format_sgr => self.terminal.flags.mouse_format = if (enabled) .sgr else .x10,
            .mouse_format_urxvt => self.terminal.flags.mouse_format = if (enabled) .urxvt else .x10,
            .mouse_format_sgr_pixels => self.terminal.flags.mouse_format = if (enabled) .sgr_pixels else .x10,

            else => {},
        }
    }

    inline fn startHyperlink(self: *StreamHandler, uri: []const u8, id: ?[]const u8) !void {
        try self.terminal.screens.active.startHyperlink(uri, id);
    }

    pub inline fn endHyperlink(self: *StreamHandler) !void {
        self.terminal.screens.active.endHyperlink();
    }

    pub fn deviceAttributes(
        self: *StreamHandler,
        req: terminal.DeviceAttributeReq,
    ) !void {
        // For the below, we quack as a VT220. We don't quack as
        // a 420 because we don't support DCS sequences.
        switch (req) {
            .primary => self.messageWriter(.{
                // 62 = Level 2 conformance
                // 22 = Color text
                // 52 = Clipboard access
                .write_stable = if (self.clipboard_write != .deny)
                    "\x1B[?62;22;52c"
                else
                    "\x1B[?62;22c",
            }),

            .secondary => self.messageWriter(.{
                .write_stable = "\x1B[>1;10;0c",
            }),

            else => log.warn("unimplemented device attributes req: {}", .{req}),
        }
    }

    /// The cursor position for a CPR/DECXCPR report, honoring origin mode
    /// (relative to the scrolling region when DECOM is set).
    fn cursorReportPos(self: *StreamHandler) struct { x: usize, y: usize } {
        return if (self.terminal.modes.get(.origin)) .{
            .x = self.terminal.screens.active.cursor.x -| self.terminal.scrolling_region.left,
            .y = self.terminal.screens.active.cursor.y -| self.terminal.scrolling_region.top,
        } else .{
            .x = self.terminal.screens.active.cursor.x,
            .y = self.terminal.screens.active.cursor.y,
        };
    }

    pub fn deviceStatusReport(
        self: *StreamHandler,
        req: terminal.device_status.Request,
    ) !void {
        switch (req) {
            .operating_status => self.messageWriter(.{ .write_stable = "\x1B[0n" }),

            .cursor_position => {
                const pos = self.cursorReportPos();

                // Response always is at least 4 chars, so this leaves the
                // remainder for the row/column as base-10 numbers. This
                // will support a very large terminal.
                var msg: termio.Message = .{ .write_small = .{} };
                const resp = try std.mem.print(&msg.write_small.data, "\x1B[{};{}R", .{
                    pos.y + 1,
                    pos.x + 1,
                });
                msg.write_small.len = @intCast(resp.len);

                self.messageWriter(msg);
            },

            // DECXCPR: extended cursor position adds a page number. Ghostty has
            // no page memory, so the page is always 1.
            .cursor_position_extended => {
                const pos = self.cursorReportPos();

                var msg: termio.Message = .{ .write_small = .{} };
                const resp = try std.mem.print(&msg.write_small.data, "\x1B[?{};{};1R", .{
                    pos.y + 1,
                    pos.x + 1,
                });
                msg.write_small.len = @intCast(resp.len);

                self.messageWriter(msg);
            },

            .color_scheme => self.messageWriter(.{ .color_scheme_report = .{ .force = true } }),

            .visibility => self.messageWriter(.{ .visibility_report = .{
                .visible = self.terminal.flags.visible,
                .force = true,
            } }),
        }
    }

    pub inline fn decaln(self: *StreamHandler) !void {
        try self.terminal.decaln();
    }

    pub inline fn saveCursor(self: *StreamHandler) !void {
        self.terminal.saveCursor();
    }

    pub inline fn restoreCursor(self: *StreamHandler) !void {
        self.terminal.restoreCursor();
    }

    pub fn enquiry(self: *StreamHandler) !void {
        log.debug("sending enquiry response={s}", .{self.enquiry_response});
        self.messageWriter(try termio.Message.writeReq(self.alloc, self.enquiry_response));
    }

    fn configureCharset(
        self: *StreamHandler,
        slot: terminal.CharsetSlot,
        set: terminal.Charset,
    ) void {
        self.terminal.configureCharset(slot, set);
    }

    pub fn fullReset(
        self: *StreamHandler,
    ) !void {
        self.seen_synchronized_output = false;
        self.sync_output_started_at = null;
        self.sync_output_last_renewed_at = null;
        self.in_remote_ssh_context = false;
        self.cancelPostResize();
        self.cancelTuiWipeHold();
        self.terminal.fullReset();
        try self.setMouseShape(.text);

        // Full reset clears Kitty clipboard session grants.
        self.kitty_clipboard_grants.deinit(self.alloc);
        self.kitty_clipboard_grants = .{};

        // Reset resets our palette so we report it for mode 2031.
        self.messageWriter(.{ .color_scheme_report = .{ .force = false } });

        // Clear the progress bar
        self.progressReport(.{ .state = .remove });
    }

    /// Record a Kitty clipboard protocol session grant so future
    /// requests with this password skip the permission prompt.
    pub fn kittyClipboardGrant(
        self: *StreamHandler,
        pw: []const u8,
        dir: terminal.kitty.clipboard.Grants.Direction,
    ) error{OutOfMemory}!void {
        try self.kitty_clipboard_grants.grant(self.alloc, pw, dir, false);
    }

    pub fn queryKittyKeyboard(self: *StreamHandler) !void {
        log.debug("querying kitty keyboard mode", .{});
        var data: termio.Message.WriteReq.Small.Array = undefined;
        const resp = try std.mem.print(&data, "\x1b[?{}u", .{
            self.terminal.screens.active.kitty_keyboard.current().int(),
        });

        self.messageWriter(.{
            .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            },
        });
    }

    pub fn reportXtversion(
        self: *StreamHandler,
    ) !void {
        log.debug("reporting XTVERSION: ghostty {s}", .{build_config.version_string});
        var buf: [288]u8 = undefined;
        const resp = try std.mem.print(
            &buf,
            "\x1BP>|{s} {s}\x1B\\",
            .{
                "ghostty",
                build_config.version_string,
            },
        );
        const msg = try termio.Message.writeReq(self.alloc, resp);
        self.messageWriter(msg);
    }

    //-------------------------------------------------------------------------
    // OSC

    fn windowTitle(self: *StreamHandler, title: []const u8) !void {
        var buf: [256]u8 = undefined;
        if (title.len >= buf.len) {
            log.warn("change title requested larger than our buffer size, ignoring", .{});
            return;
        }

        // Set the title on the terminal state. We ignore any errors since
        // we can continue to operate just fine without it.
        self.terminal.setTitle(title) catch |err| {
            log.warn("error setting title in terminal state: {}", .{err});
        };

        @memcpy(buf[0..title.len], title);
        buf[title.len] = 0;

        // Special handling for the empty title. We treat the empty title
        // as resetting to as if we never saw a title. Other terminals
        // behave this way too (e.g. iTerm2).
        if (title.len == 0) {
            // If we have a pwd then we set the title as the pwd else
            // we just set it to blank.
            if (self.terminal.getPwd()) |pwd| pwd: {
                if (pwd.len >= buf.len) break :pwd;
                @memcpy(buf[0..pwd.len], pwd);
                buf[pwd.len] = 0;
            }

            self.surfaceMessageWriter(.{ .set_title = buf });
            self.seen_title = false;
            return;
        }

        self.seen_title = true;
        self.surfaceMessageWriter(.{ .set_title = buf });
    }

    inline fn setMouseShape(
        self: *StreamHandler,
        shape: terminal.MouseShape,
    ) !void {
        // Avoid changing the shape if it is already set to avoid excess
        // cross-thread messaging.
        if (self.terminal.mouse_shape == shape) return;

        self.terminal.mouse_shape = shape;
        self.surfaceMessageWriter(.{ .set_mouse_shape = shape });
    }

    fn clipboardContents(self: *StreamHandler, kind: u8, data: []const u8) !void {
        // Note: we ignore the "kind" field and always use the standard clipboard.
        // iTerm also appears to do this but other terminals seem to only allow
        // certain. Let's investigate more.

        const clipboard_type: apprt.Clipboard = switch (kind) {
            'c' => .standard,
            's' => .selection,
            'p' => .primary,
            else => .standard,
        };

        // Get clipboard contents
        if (data.len == 1 and data[0] == '?') {
            self.surfaceMessageWriter(.{ .clipboard_read = clipboard_type });
            return;
        }

        // Write clipboard contents
        self.surfaceMessageWriter(.{
            .clipboard_write = .{
                .req = try apprt.surface.Message.WriteReq.init(
                    self.alloc,
                    data,
                ),
                .clipboard_type = clipboard_type,
            },
        });
    }

    /// Handle one Kitty clipboard protocol (OSC 5522) packet.
    fn kittyClipboard(
        self: *StreamHandler,
        v: terminal.osc.Command.KittyClipboardProtocol,
    ) error{ OutOfMemory, WriteFailed }!void {
        const kitty_clipboard = terminal.kitty.clipboard;

        // Decode and validate the metadata. Malformed structure drops
        // the packet without a response. Invalid decoded text on a write
        // data or alias packet aborts an in-flight transaction.
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const meta = (kitty_clipboard.Metadata.parse(
            arena.allocator(),
            v.metadata,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidValue => {
                const state = self.kitty_clipboard_write orelse return;
                switch (kitty_clipboard.Metadata.operation(v.metadata) orelse return) {
                    .wdata, .walias => try self.kittyClipboardWriteFinish(
                        state,
                        .EINVAL,
                        v.terminator,
                    ),
                    .read, .write => {},
                }
                return;
            },
        }) orelse return;

        switch (meta.op) {
            .read => try self.kittyClipboardRead(
                &meta,
                v.payload orelse "",
                v.terminator,
            ),

            .write => try self.kittyClipboardWriteBegin(
                &meta,
                v.terminator,
            ),

            .wdata => try self.kittyClipboardWriteData(
                &meta,
                v.payload orelse "",
                v.terminator,
            ),

            .walias => try self.kittyClipboardWriteAlias(
                &meta,
                v.payload orelse "",
                v.terminator,
            ),
        }
    }

    fn kittyClipboardRead(
        self: *StreamHandler,
        meta: *const terminal.kitty.clipboard.Metadata,
        payload: []const u8,
        terminator: terminal.osc.Terminator,
    ) !void {
        const kitty_clipboard = terminal.kitty.clipboard;

        // Everything about the request, including the request struct
        // itself, lives in a single arena that crosses to the surface
        // thread, which owns it from the moment the message is sent.
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // The payload is the requested MIME list. A read request with
        // an undecodable payload is dropped without any response,
        // matching kitty.
        const decoded = kitty_clipboard.Payload.init(
            alloc,
            payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => {
                arena.deinit();
                return;
            },
        };
        if (!decoded.isValidUtf8()) {
            arena.deinit();
            return;
        }

        // The targets type ('.') asks for the listing of available
        // types rather than data. Requested types beyond the cap are
        // dropped and simply never served, which is how the protocol
        // reports an unavailable type anyway.
        var mimes_buf: [kitty_clipboard.max_read_mimes][]const u8 = undefined;
        var mimes_len: usize = 0;
        var list = false;
        var it = decoded.mimeIterator();
        while (it.next()) |mime| {
            if (std.mem.eql(u8, mime, kitty_clipboard.targets_mime)) {
                list = true;
                continue;
            }
            if (mimes_len == mimes_buf.len) continue;
            mimes_buf[mimes_len] = mime;
            mimes_len += 1;
        }

        // Per the spec a password without a name is no password. A
        // stored session grant for it lets the surface skip its
        // permission prompt.
        const pw: []const u8 = if (meta.name.len > 0) meta.pw else "";
        const granted = self.kittyClipboardReadGranted(pw, mimes_len);

        const req = try alloc.create(apprt.ClipboardRequest.KittyRead);
        const mimes = try alloc.alloc([:0]const u8, mimes_len);
        for (mimes_buf[0..mimes_len], mimes) |src, *dst| {
            dst.* = try alloc.dupeSentinel(u8, src, 0);
        }
        const id = try alloc.dupe(u8, meta.id);
        const pw_owned = try alloc.dupe(u8, pw);
        const name_owned = try alloc.dupeSentinel(u8, meta.name, 0);
        req.* = .{
            // The arena must be copied in last so it tracks every
            // allocation above.
            .arena = arena,
            .location = switch (meta.loc) {
                .primary => .primary,
                else => .standard,
            },
            .mimes = mimes,
            .list = list,
            .id = id,
            .pw = pw_owned,
            .name = name_owned,
            .granted = granted,
            .terminator = terminator,
        };

        self.surfaceMessageWriter(.{ .kitty_clipboard_read = req });
    }

    /// Whether a session grant covers a read request, consuming
    /// one-time grants. A prompt-exempt request never consults the
    /// grants: consuming a one-time paste password on a listing would
    /// burn the grant before the follow-up data read.
    fn kittyClipboardReadGranted(
        self: *StreamHandler,
        pw: []const u8,
        mimes_len: usize,
    ) bool {
        if (terminal.kitty.clipboard.readPromptExempt(mimes_len)) return false;
        return self.kitty_clipboard_grants.use(self.alloc, pw, .read);
    }

    /// Begin a Kitty clipboard write transaction (type=write).
    fn kittyClipboardWriteBegin(
        self: *StreamHandler,
        meta: *const terminal.kitty.clipboard.Metadata,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        // A new write silently replaces any in-flight transaction.
        self.kittyClipboardWriteAbort();

        // A write denied by policy can never succeed, so fail the
        // transaction up front instead of spooling data we'd only
        // throw away. Later wdata packets are ignored.
        if (self.clipboard_write == .deny) {
            log.info("application attempted to write clipboard, but 'clipboard-write' is set to deny", .{});
            try self.kittyClipboardWriteStatus(
                .EPERM,
                meta.id,
                terminator,
            );
            return;
        }

        const state = try self.alloc.create(terminal.kitty.clipboard.WriteState);
        errdefer self.alloc.destroy(state);
        state.* = try .init(self.alloc, meta, .{
            .max_size = self.clipboard_write_limit,
        });
        self.kitty_clipboard_write = state;
    }

    /// Accumulate one wdata chunk, or commit the transaction when the
    /// chunk carries no MIME type.
    fn kittyClipboardWriteData(
        self: *StreamHandler,
        meta: *const terminal.kitty.clipboard.Metadata,
        payload: []const u8,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        // Data without a transaction is silently ignored, matching
        // kitty.
        const state = self.kitty_clipboard_write orelse return;

        // A wdata packet without a MIME type commits the transaction.
        if (meta.mime.len == 0) return self.kittyClipboardWriteCommit(
            state,
            terminator,
        );

        state.data(
            self.alloc,
            meta,
            payload,
        ) catch |err| switch (err) {
            // Failing to spool matches kitty's EIO for a failed buffer write.
            error.OutOfMemory => {
                try self.kittyClipboardWriteFinish(
                    state,
                    .EIO,
                    terminator,
                );
                return error.OutOfMemory;
            },

            // Data over the write limit aborts the transaction and is
            // reported to the client.
            error.TooLarge => try self.kittyClipboardWriteFinish(
                state,
                .EFBIG,
                terminator,
            ),

            // An invalid base64 payload stream aborts the transaction.
            error.Invalid => try self.kittyClipboardWriteFinish(
                state,
                .EINVAL,
                terminator,
            ),
        };
    }

    /// Register aliases from a walias packet.
    fn kittyClipboardWriteAlias(
        self: *StreamHandler,
        meta: *const terminal.kitty.clipboard.Metadata,
        payload: []const u8,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        // Aliases without a transaction are silently ignored. Once a
        // transaction exists, a missing target MIME type is invalid and
        // aborts the transaction.
        const state = self.kitty_clipboard_write orelse return;
        if (meta.mime.len == 0) return self.kittyClipboardWriteFinish(
            state,
            .EINVAL,
            terminator,
        );

        state.alias(
            self.alloc,
            meta,
            payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                try self.kittyClipboardWriteFinish(
                    state,
                    .EIO,
                    terminator,
                );
                return error.OutOfMemory;
            },

            // An undecodable alias payload aborts the transaction.
            error.Invalid => try self.kittyClipboardWriteFinish(
                state,
                .EINVAL,
                terminator,
            ),
        };
    }

    /// Commit the transaction: resolve the final contents and forward
    /// them to the surface thread, which owns policy, any permission
    /// prompt, the clipboard write itself, and the final reply.
    fn kittyClipboardWriteCommit(
        self: *StreamHandler,
        state: *terminal.kitty.clipboard.WriteState,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        self.kittyClipboardWriteSend(
            state,
            terminator,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                try self.kittyClipboardWriteFinish(
                    state,
                    .EIO,
                    terminator,
                );
                return error.OutOfMemory;
            },

            // The last MIME type's payload stream was not correctly
            // padded, which aborts the transaction.
            error.Invalid => return try self.kittyClipboardWriteFinish(
                state,
                .EINVAL,
                terminator,
            ),
        };

        // The transaction is complete; the surface owns the reply.
        self.kittyClipboardWriteAbort();
    }

    fn kittyClipboardWriteSend(
        self: *StreamHandler,
        state: *terminal.kitty.clipboard.WriteState,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, Invalid }!void {
        const committed = try state.commit(self.alloc);
        defer committed.deinit(self.alloc);

        // Per the spec a password without a name is no password. A
        // stored session grant for it lets the surface skip its
        // permission prompt.
        const pw: []const u8 = if (committed.name.len > 0) committed.pw else "";
        const granted = self.kitty_clipboard_grants.use(self.alloc, pw, .write);

        // Everything about the request, including the request struct
        // itself, lives in a single arena that crosses to the surface
        // thread, which owns it from the moment the message is sent.
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const req = try alloc.create(apprt.ClipboardRequest.KittyWrite);
        const contents = try alloc.alloc(
            apprt.ClipboardContent,
            committed.contents.len,
        );
        for (committed.contents, contents) |src, *dst| dst.* = .{
            .mime = try alloc.dupeSentinel(u8, src.mime, 0),
            .data = try alloc.dupeSentinel(u8, src.data, 0),
        };
        const id = try alloc.dupe(u8, committed.id);
        const pw_owned = try alloc.dupe(u8, pw);
        const name_owned = try alloc.dupeSentinel(u8, committed.name, 0);
        req.* = .{
            // The arena must be copied in last so it tracks every
            // allocation above.
            .arena = arena,
            .location = switch (committed.loc) {
                .primary => .primary,
                else => .standard,
            },
            .contents = contents,
            .id = id,
            .pw = pw_owned,
            .name = name_owned,
            .granted = granted,
            .terminator = terminator,
        };

        self.surfaceMessageWriter(.{ .kitty_clipboard_write = req });
    }

    /// Answer the write transaction with its final status and drop it.
    /// The id echoed is the one from the transaction's opening write
    /// packet, matching kitty.
    fn kittyClipboardWriteFinish(
        self: *StreamHandler,
        state: *const terminal.kitty.clipboard.WriteState,
        status: terminal.kitty.clipboard.Status,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        defer self.kittyClipboardWriteAbort();
        try self.kittyClipboardWriteStatus(status, state.id, terminator);
    }

    /// Reply to a write transaction with a single status packet.
    fn kittyClipboardWriteStatus(
        self: *StreamHandler,
        status: terminal.kitty.clipboard.Status,
        id: []const u8,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        var stream: std.Io.Writer.Allocating = .init(self.alloc);
        defer stream.deinit();
        try (terminal.kitty.clipboard.Response{
            .op = .write,
            .status = status,
            .id = id,
            .terminator = terminator,
        }).encode(&stream.writer);
        self.messageWriter(.{ .write_alloc = .{
            .alloc = self.alloc,
            .data = try stream.toOwnedSlice(),
        } });
    }

    /// Drop any in-flight write transaction without responding.
    fn kittyClipboardWriteAbort(self: *StreamHandler) void {
        if (self.kitty_clipboard_write) |state| {
            state.deinit(self.alloc);
            self.alloc.destroy(state);
            self.kitty_clipboard_write = null;
        }
    }

    fn semanticPrompt(
        self: *StreamHandler,
        cmd: Stream.Action.SemanticPrompt,
    ) !void {
        switch (cmd.action) {
            .end_input_start_output => {
                // Commit the semantic record before notifying the UI thread.
                try self.terminal.semanticPrompt(cmd);
                self.surfaceMessageWriter(.start_command);
                return;
            },

            .end_command => {
                self.seen_synchronized_output = false;
                self.cancelPostResize();
                self.cancelTuiWipeHold();
                // The specification seems to not specify the type but
                // other terminals accept 32-bits, but exit codes are really
                // bytes, so we just do our best here.
                const code: u8 = code: {
                    const raw: i32 = cmd.readOption(.exit_code) orelse 0;
                    break :code std.math.cast(u8, raw) orelse 1;
                };

                self.surfaceMessageWriter(.{ .stop_command = code });
            },

            .fresh_line_new_prompt,
            .prompt_start,
            => {
                self.seen_synchronized_output = false;
                self.cancelPostResize();
                self.cancelTuiWipeHold();
            },

            // Handled by Terminal, no special handling by us
            .end_prompt_start_input,
            .end_prompt_start_input_terminate_eol,
            .fresh_line,
            .new_command,
            => {},
        }

        // We do this last so failures are still processed correctly
        // above.
        try self.terminal.semanticPrompt(cmd);
    }

    fn queueProgramStatusQueryReply(
        self: *StreamHandler,
        signal: terminal.osc.context_signal.Command,
    ) bool {
        if (!std.mem.eql(u8, signal.id, "omg-program-status-query")) return false;
        if (std.mem.eql(u8, signal.metadata, "\x07")) {
            self.messageWriter(.{ .protocol_reply = "\x1b]7501;" ++ terminal.osc.program_status.query_reply ++ "\x07" });
        } else {
            self.messageWriter(.{ .protocol_reply = "\x1b]7501;" ++ terminal.osc.program_status.query_reply ++ "\x1b\\" });
        }
        return true;
    }

    /// Extract a bounded OSC 26 (Terminal Agent Protocol / TAP) payload from
    /// an unknown OSC sequence. Truncated, oversized, empty, or non-OSC-26
    /// sequences are dropped.
    fn osc26Payload(unknown: terminal.osc.Command.Unknown) ?[]const u8 {
        if (unknown.truncated) return null;
        if (unknown.content.len > osc_unknown_max_bytes) return null;
        if (!std.mem.startsWith(u8, unknown.content, "26;")) return null;
        const payload = unknown.content["26;".len..];
        if (payload.len == 0) return null;
        return payload;
    }

    fn oscUnknown(
        self: *StreamHandler,
        unknown: terminal.osc.Command.Unknown,
    ) !void {
        if (osc26Payload(unknown)) |payload| {
            try self.contextSignal(.{
                .action = .start,
                .id = "omg-osc26",
                .metadata = payload,
            });
        }
    }

    fn contextSignal(
        self: *StreamHandler,
        signal: terminal.osc.context_signal.Command,
    ) !void {
        if (self.queueProgramStatusQueryReply(signal)) return;
        switch (signal.action) {
            .start => {
                if (!std.mem.eql(u8, signal.id, "omg-osc26") and
                    !std.mem.eql(u8, signal.id, "omg-program-status") and
                    std.mem.indexOf(u8, signal.metadata, "type=remote") != null)
                {
                    self.in_remote_ssh_context = true;
                }
            },
            .end => {
                if (!std.mem.startsWith(u8, signal.id, "omg-inline-") and
                    !std.mem.startsWith(u8, signal.id, "omg-agent-") and
                    !std.mem.eql(u8, signal.id, "omg-runtime-state"))
                {
                    self.in_remote_ssh_context = false;
                }
            },
        }
        const message = apprt.surface.Message.ContextSignal.init(
            self.alloc,
            signal,
        ) catch |err| {
            log.warn("failed to allocate OSC 3008 context signal: {}", .{err});
            return;
        };
        self.surfaceMessageWriter(.{ .context_signal = message });
    }

    fn reportPwd(self: *StreamHandler, url: []const u8) !void {
        // Special handling for the empty URL. We treat the empty URL
        // as resetting the pwd as if we never saw a pwd. I can't find any
        // other terminal that does this but it seems like a reasonable
        // behavior that enables some useful features. For example, the macOS
        // proxy icon can be hidden when a program reports it doesn't know
        // the pwd rather than showing a stale pwd.
        if (url.len == 0) {
            // Blank value can never fail because no allocs happen.
            self.terminal.setPwd("") catch unreachable;

            // If we haven't seen a title, we're using the pwd as our title.
            // Set it to blank which will reset our title behavior.
            if (!self.seen_title) {
                try self.windowTitle("");
                assert(!self.seen_title);
            }

            // Report the change.
            self.surfaceMessageWriter(.{ .pwd_change = .{ .stable = "" } });
            return;
        }

        if (builtin.target.os.tag == .windows) {
            log.warn("reportPwd unimplemented on windows", .{});
            return;
        }

        // Attempt to parse this file-style URI using options appropriate
        // for this OSC 7 context (e.g. kitty-shell-cwd expects the full,
        // unencoded path).
        const uri: std.Uri = internal_os.uri.parse(url, .{
            .mac_address = comptime builtin.target.os.tag != .macos,
            .raw_path = std.mem.startsWith(u8, url, "kitty-shell-cwd://"),
        }) catch |e| {
            log.warn("invalid url in OSC 7: {}", .{e});
            return;
        };

        if (!std.mem.eql(u8, "file", uri.scheme) and
            !std.mem.eql(u8, "kitty-shell-cwd", uri.scheme))
        {
            log.warn("OSC 7 scheme must be file or kitty-shell-cwd, got: {s}", .{uri.scheme});
            return;
        }

        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = osc7Host(uri, &host_buffer) catch |err| switch (err) {
            error.UriMissingHost => {
                log.warn("OSC 7 uri must contain a hostname: {}", .{err});
                return;
            },
            error.NameTooLong => {
                log.warn("failed to get full hostname for OSC 7 validation: {}", .{err});
                return;
            },
        };

        // OSC 7 is a little sketchy because anyone can send any value from
        // any host (such an SSH session). The best practice terminals follow
        // is to valid the hostname to be local.
        const host_valid = internal_os.hostname.isLocal(host) catch |err| switch (err) {
            error.PermissionDenied,
            error.Unexpected,
            => {
                log.warn("failed to get hostname for OSC 7 validation: {}", .{err});
                return;
            },
        };
        if (!host_valid and !self.remote_session) {
            log.warn("OSC 7 host ({s}) must be local", .{host});
            return;
        }

        // We need the raw path, which might require unescaping. We try to
        // avoid making any heap allocations by using the stack first.
        var arena_alloc: std.heap.ArenaAllocator = .init(self.alloc);
        var stack_alloc_buf: [1024]u8 = undefined;
        var stack_alloc: std.heap.BufferFirstAllocator = .init(&stack_alloc_buf, arena_alloc.allocator());
        defer arena_alloc.deinit();
        const path = try uri.path.toRawMaybeAlloc(stack_alloc.allocator());

        log.debug("terminal pwd: {s}", .{path});
        try self.terminal.setPwd(path);

        // Report it to the surface. If creating our write request fails
        // then we just ignore it.
        if (apprt.surface.Message.WriteReq.init(self.alloc, path)) |req| {
            self.surfaceMessageWriter(.{ .pwd_change = req });
        } else |err| {
            log.warn("error notifying surface of pwd change err={}", .{err});
        }

        // If we haven't seen a title, use our pwd as the title.
        if (!self.seen_title) {
            try self.windowTitle(path);
            self.seen_title = false;
        }
    }

    fn colorOperation(
        self: *StreamHandler,
        op: terminal.osc.color.Operation,
        requests: *const terminal.osc.color.List,
        terminator: terminal.osc.Terminator,
    ) !void {
        // We'll need op one day if we ever implement reporting special colors.
        _ = op;

        // return early if there is nothing to do
        if (requests.count() == 0) return;

        var buffer: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buffer);
        const alloc = fba.allocator();

        var response: std.Io.Writer.Allocating = .init(alloc);

        var it = requests.constIterator(0);
        while (it.next()) |req| {
            switch (req.*) {
                .set => |set| {
                    switch (set.target) {
                        .palette => |i| {
                            self.terminal.flags.dirty.palette = true;
                            self.terminal.colors.palette.set(i, set.color);
                        },
                        .dynamic => |dynamic| switch (dynamic) {
                            .foreground => self.terminal.colors.foreground.set(set.color),
                            .background => self.terminal.colors.background.set(set.color),
                            .cursor => self.terminal.colors.cursor.set(set.color),
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => log.info("setting dynamic color {s} not implemented", .{
                                @tagName(dynamic),
                            }),
                        },
                        .special => log.info("setting special colors not implemented", .{}),
                    }

                    // Notify the surface of the color change
                    self.surfaceMessageWriter(.{ .color_change = .{
                        .target = set.target,
                        .color = set.color,
                    } });
                },

                .reset => |target| switch (target) {
                    .palette => |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(i);

                        self.surfaceMessageWriter(.{
                            .color_change = .{
                                .target = target,
                                .color = self.terminal.colors.palette.current[i],
                            },
                        });
                    },
                    .dynamic => |dynamic| switch (dynamic) {
                        .foreground => {
                            self.terminal.colors.foreground.reset();

                            if (self.terminal.colors.foreground.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .background => {
                            self.terminal.colors.background.reset();

                            if (self.terminal.colors.background.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .cursor => {
                            self.terminal.colors.cursor.reset();

                            if (self.terminal.colors.cursor.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .pointer_foreground,
                        .pointer_background,
                        .tektronix_foreground,
                        .tektronix_background,
                        .highlight_background,
                        .tektronix_cursor,
                        .highlight_foreground,
                        => log.warn("resetting dynamic color {s} not implemented", .{
                            @tagName(dynamic),
                        }),
                    },
                    .special => log.info("resetting special colors not implemented", .{}),
                },

                .reset_palette => {
                    const mask = &self.terminal.colors.palette.mask;
                    var mask_it = mask.iterator(.{});
                    while (mask_it.next()) |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(@intCast(i));
                        self.surfaceMessageWriter(.{
                            .color_change = .{
                                .target = .{ .palette = @intCast(i) },
                                .color = self.terminal.colors.palette.current[i],
                            },
                        });
                    }
                    mask.* = .empty;
                },

                .reset_special => log.warn(
                    "resetting all special colors not implemented",
                    .{},
                ),

                .query => |kind| report: {
                    if (self.osc_color_report_format == .none) break :report;

                    const color = switch (kind) {
                        .palette => |i| self.terminal.colors.palette.current[i],
                        .dynamic => |dynamic| switch (dynamic) {
                            .foreground => self.terminal.colors.foreground.get().?,
                            .background => self.terminal.colors.background.get().?,
                            .cursor => self.terminal.colors.cursor.get() orelse
                                self.terminal.colors.foreground.get().?,
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => {
                                log.info(
                                    "reporting dynamic color {s} not implemented",
                                    .{@tagName(dynamic)},
                                );
                                break :report;
                            },
                        },
                        .special => {
                            log.info("reporting special colors not implemented", .{});
                            break :report;
                        },
                    };

                    switch (self.osc_color_report_format) {
                        .@"16-bit" => switch (kind) {
                            .palette => |i| try response.writer.print(
                                "\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
                                .{
                                    i,
                                    @as(u16, color.r) * 257,
                                    @as(u16, color.g) * 257,
                                    @as(u16, color.b) * 257,
                                },
                            ),
                            .dynamic => |dynamic| try response.writer.print(
                                "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
                                .{
                                    @backingInt(dynamic),
                                    @as(u16, color.r) * 257,
                                    @as(u16, color.g) * 257,
                                    @as(u16, color.b) * 257,
                                },
                            ),
                            .special => unreachable,
                        },

                        .@"8-bit" => switch (kind) {
                            .palette => |i| try response.writer.print(
                                "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                                .{
                                    i,
                                    @as(u16, color.r),
                                    @as(u16, color.g),
                                    @as(u16, color.b),
                                },
                            ),
                            .dynamic => |dynamic| try response.writer.print(
                                "\x1b]{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                                .{
                                    @backingInt(dynamic),
                                    @as(u16, color.r),
                                    @as(u16, color.g),
                                    @as(u16, color.b),
                                },
                            ),
                            .special => unreachable,
                        },

                        .none => unreachable,
                    }

                    try response.writer.writeAll(terminator.string());
                },
            }
        }

        if (response.writer.end > 0) {
            // If any of the operations were reports, finalize the report
            // string and send it to the terminal.
            const msg = try termio.Message.writeReq(self.alloc, response.writer.buffered());
            self.messageWriter(msg);
        }
    }

    fn showDesktopNotification(
        self: *StreamHandler,
        title: []const u8,
        body: []const u8,
    ) !void {
        self.surfaceMessageWriter(.{
            .desktop_notification = .init(title, body),
        });
    }

    /// Send a report to the pty.
    pub fn sendSizeReport(self: *StreamHandler, style: terminal.SizeReportStyle) void {
        switch (style) {
            .csi_14_t => self.messageWriter(.{ .size_report = .csi_14_t }),
            .csi_16_t => self.messageWriter(.{ .size_report = .csi_16_t }),
            .csi_18_t => self.messageWriter(.{ .size_report = .csi_18_t }),
            .csi_19_t => self.messageWriter(.{ .size_report = .csi_19_t }),
            .csi_21_t => self.surfaceMessageWriter(.{ .report_title = .csi_21_t }),
        }
    }

    fn kittyColorReport(
        self: *StreamHandler,
        request: terminal.kitty.color.OSC,
    ) !void {
        var stream: std.Io.Writer.Allocating = .init(self.alloc);
        defer stream.deinit();
        const writer = &stream.writer;

        for (request.list.items) |item| {
            switch (item) {
                .query => |key| {
                    // If the writer buffer is empty, we need to write our prefix
                    if (stream.written().len == 0) try writer.writeAll("\x1b]21");

                    const color: terminal.color.RGB = switch (key) {
                        .palette => |palette| self.terminal.colors.palette.current[palette],
                        .special => |special| switch (special) {
                            .foreground => self.terminal.colors.foreground.get(),
                            .background => self.terminal.colors.background.get(),
                            .cursor => self.terminal.colors.cursor.get(),
                            else => {
                                log.warn("ignoring unsupported kitty color protocol key: {f}", .{key});
                                continue;
                            },
                        },
                    } orelse {
                        try writer.print(";{f}=", .{key});
                        continue;
                    };

                    try writer.print(
                        ";{f}=rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                        .{ key, color.r, color.g, color.b },
                    );
                },
                .set => |v| switch (v.key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.set(palette, v.color);
                    },

                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.set(v.color),
                        .background => self.terminal.colors.background.set(v.color),
                        .cursor => self.terminal.colors.cursor.set(v.color),
                        else => {
                            log.warn(
                                "ignoring unsupported kitty color protocol key: {f}",
                                .{v.key},
                            );
                            continue;
                        },
                    },
                },
                .reset => |key| switch (key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(palette);
                    },

                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.reset(),
                        .background => self.terminal.colors.background.reset(),
                        .cursor => self.terminal.colors.cursor.reset(),
                        else => {
                            log.warn(
                                "ignoring unsupported kitty color protocol key: {f}",
                                .{key},
                            );
                            continue;
                        },
                    },
                },
            }
        }

        // If we had any writes to our buffer, we queue them now
        if (stream.written().len > 0) {
            try writer.writeAll(request.terminator.string());
            self.messageWriter(.{
                .write_alloc = .{
                    .alloc = self.alloc,
                    .data = try stream.toOwnedSlice(),
                },
            });
        }

        // Note: we don't have to do a queueRender here because every
        // processed stream will queue a render once it is done processing
        // the read() syscall.
    }

    /// Display a GUI progress report.
    fn progressReport(self: *StreamHandler, report: terminal.osc.Command.ProgressReport) void {
        self.surfaceMessageWriter(.{ .progress_report = report });
    }

    pub fn isRemoteSshSession(self: *const StreamHandler) bool {
        return self.remote_ssh_session or self.in_remote_ssh_context;
    }

    fn postResizeIdleWindowMs(self: *const StreamHandler) i64 {
        return if (self.isRemoteSshSession())
            PostResizeState.remote_idle_window_ms
        else
            PostResizeState.idle_window_ms;
    }

    fn postResizeHardLimitMs(self: *const StreamHandler) i64 {
        return if (self.isRemoteSshSession())
            PostResizeState.remote_hard_limit_ms
        else
            PostResizeState.hard_limit_ms;
    }

    fn postResizeScrollRestoreMs(self: *const StreamHandler) i64 {
        return if (self.isRemoteSshSession())
            PostResizeState.remote_scroll_restore_ms
        else
            PostResizeState.scroll_restore_ms;
    }

    fn screenHasSubstantialContent(screen: *const terminal.Screen) bool {
        if (screen.pages.total_rows > screen.pages.rows or screen.cursor.y >= 4) return true;
        var populated_rows: usize = 0;
        var y: terminal.size.CellCountInt = 0;
        while (y < screen.pages.rows) : (y += 1) {
            const pin = screen.pages.pin(.{ .active = .{ .y = y } }) orelse continue;
            const page = pin.node.page();
            const rac = pin.rowAndCell();
            for (rac.row.cells.ptr(page.memory)[0..page.size.cols]) |cell| {
                if (!cell.isEmpty()) {
                    populated_rows += 1;
                    if (populated_rows >= 4) return true;
                    break;
                }
            }
        }
        return false;
    }

    fn screenIsNearlyBlankWipe(screen: *const terminal.Screen) bool {
        if (screen.pages.total_rows > screen.pages.rows or screen.cursor.y > 3) return false;
        var y: terminal.size.CellCountInt = 4;
        while (y < screen.pages.rows) : (y += 1) {
            const pin = screen.pages.pin(.{ .active = .{ .y = y } }) orelse continue;
            const page = pin.node.page();
            const rac = pin.rowAndCell();
            for (rac.row.cells.ptr(page.memory)[0..page.size.cols]) |cell| {
                if (!cell.isEmpty()) return false;
            }
        }
        return true;
    }

    pub fn setSynchronizedOutput(self: *StreamHandler, enabled: bool) void {
        if (enabled) {
            const now = std.Io.Timestamp.now(global.io(), .awake);
            const already_genuine_sync = self.terminal.modes.get(.synchronized_output) and
                !self.post_resize.held_sync_output and
                !self.tui_wipe_hold.held_sync_output;
            self.terminal.modes.set(.synchronized_output, true);
            self.seen_synchronized_output = true;
            self.post_resize.held_sync_output = false;
            self.tui_wipe_hold.held_sync_output = false;
            self.tui_wipe_hold.deadline = null;
            if (!already_genuine_sync) {
                self.sync_output_started_at = now;
                self.sync_output_last_renewed_at = now;
            }
            self.messageWriter(.{ .start_synchronized_output = {} });
            return;
        }

        self.sync_output_started_at = null;
        self.sync_output_last_renewed_at = null;

        if (self.shouldHoldPostResizeBlankWipe()) {
            const now = std.Io.Timestamp.now(global.io(), .awake);
            self.holdPostResizeSyncOutput(now);
            return;
        }

        if (!self.postResizeIsActive() and self.shouldHoldTuiBlankWipe()) {
            const now = std.Io.Timestamp.now(global.io(), .awake);
            self.holdTuiWipeSyncOutput(now);
            return;
        }

        self.terminal.modes.set(.synchronized_output, false);
        self.post_resize.held_sync_output = false;
        if (self.postResizeIsActive() and
            (self.post_resize.saw_full_clear or self.post_resize.saw_erase_below))
        {
            self.completePostResizeCycle();
        } else if (self.tui_wipe_hold.active) {
            self.completeTuiWipeCycle();
        }
    }

    /// Renew the writer-thread synchronized-output safety timer during long
    /// multi-chunk DEC 2026 frames (such as `agy` history reprints over SSH)
    /// while bounding total uninterrupted freeze duration to `sync_active_max_ms`.
    pub fn noteActiveSynchronizedOutput(self: *StreamHandler, now: std.Io.Timestamp) void {
        if (!self.terminal.modes.get(.synchronized_output) or
            self.post_resize.held_sync_output or
            self.tui_wipe_hold.held_sync_output)
        {
            return;
        }
        const started = self.sync_output_started_at orelse {
            self.sync_output_started_at = now;
            self.sync_output_last_renewed_at = now;
            return;
        };
        if (started.durationTo(now).toMilliseconds() >= @as(i64, @intCast(sync_active_max_ms))) {
            return;
        }
        if (self.sync_output_last_renewed_at) |last| {
            if (last.durationTo(now).toMilliseconds() < @as(i64, @intCast(sync_renew_interval_ms))) {
                return;
            }
        }
        self.sync_output_last_renewed_at = now;
        self.messageWriter(.{ .start_synchronized_output = {} });
    }

    pub fn notePostResizeCursorVisible(self: *StreamHandler) void {
        self.terminal.modes.set(.cursor_visible, true);
        if (!self.postResizeIsActive()) {
            if (self.tui_wipe_hold.active and
                self.tui_wipe_hold.held_sync_output and
                !self.shouldHoldTuiBlankWipe())
            {
                self.terminal.modes.set(.synchronized_output, false);
                self.completeTuiWipeCycle();
            }
            return;
        }
        if (!self.post_resize.saw_full_clear and !self.post_resize.saw_erase_below) return;

        if (self.shouldHoldPostResizeBlankWipe()) {
            const now = std.Io.Timestamp.now(global.io(), .awake);
            self.holdPostResizeSyncOutput(now);
            return;
        }

        if (self.post_resize.held_sync_output) {
            self.terminal.modes.set(.synchronized_output, false);
            self.post_resize.held_sync_output = false;
        }
        if (!self.terminal.modes.get(.synchronized_output)) {
            self.completePostResizeCycle();
        }
    }

    pub fn noteTerminalResize(
        self: *StreamHandler,
        was_scrolled_up: bool,
        pre_sb: terminal.PageList.Scrollbar,
        pre_cursor_y: terminal.size.CellCountInt,
    ) void {
        if (self.terminal.screens.active_key != .primary) {
            self.cancelPostResize();
            self.cancelTuiWipeHold();
            return;
        }

        _ = self.postResizeIsActive();
        _ = self.tuiWipeHoldIsActive();

        const now = std.Io.Timestamp.now(global.io(), .awake);
        const deadline = now.addDuration(.fromMilliseconds(self.postResizeIdleWindowMs()));
        const hard_deadline = now.addDuration(.fromMilliseconds(self.postResizeHardLimitMs()));
        const scroll_deadline = now.addDuration(.fromMilliseconds(self.postResizeScrollRestoreMs()));
        const existing_save = if (self.post_resize.active) self.post_resize.scroll_save else null;
        const existing_had_sb = if (self.post_resize.active) self.post_resize.had_scrollback else false;
        const existing_pre_cursor_y: terminal.size.CellCountInt = if (self.post_resize.active)
            self.post_resize.pre_cursor_y
        else
            0;
        const tui_active = self.tui_wipe_hold.active;
        const tui_had_content = tui_active and self.tui_wipe_hold.had_substantial_content;
        const tui_held_sync = tui_active and self.tui_wipe_hold.held_sync_output;
        const existing_saw_erase = (if (self.post_resize.active) self.post_resize.saw_erase_below else false) or
            (tui_active and self.tui_wipe_hold.saw_erase_below);
        const existing_saw_clear = (if (self.post_resize.active) self.post_resize.saw_full_clear else false) or
            (tui_active and self.tui_wipe_hold.saw_full_clear);
        const existing_held_sync = (if (self.post_resize.active) self.post_resize.held_sync_output else false) or
            tui_held_sync;
        if (tui_active) {
            self.tui_wipe_hold = .{};
        }

        const max_pre = pre_sb.total -| pre_sb.len;
        const new_save: ?PostResizeState.ScrollSave = if (existing_save) |s|
            s
        else if (was_scrolled_up and max_pre > 0) .{
            .offset = pre_sb.offset,
            .total = pre_sb.total,
            .len = pre_sb.len,
            .distance_from_bottom = max_pre -| pre_sb.offset,
        } else null;

        self.post_resize = .{
            .active = true,
            .deadline = deadline,
            .hard_deadline = hard_deadline,
            .scroll_deadline = scroll_deadline,
            .had_scrollback = existing_had_sb or (pre_sb.total > pre_sb.len) or tui_had_content,
            .pre_cursor_y = @max(existing_pre_cursor_y, pre_cursor_y),
            .saw_erase_below = existing_saw_erase,
            .saw_full_clear = existing_saw_clear,
            .held_sync_output = existing_held_sync,
            .scroll_save = new_save,
        };

        if (existing_held_sync) {
            self.holdPostResizeSyncOutput(now);
        }
    }

    /// Refresh the bounded post-resize windows at the exact moment `SIGWINCH` is
    /// sent to the child PTY after live-resize coalescing completes.
    pub fn noteChildResizeCommitted(self: *StreamHandler) void {
        if (!self.post_resize.active) return;
        if (self.terminal.screens.active_key != .primary) {
            self.cancelPostResize();
            return;
        }

        const now = std.Io.Timestamp.now(global.io(), .awake);
        self.post_resize.deadline = now.addDuration(.fromMilliseconds(self.postResizeIdleWindowMs()));
        self.post_resize.hard_deadline = now.addDuration(.fromMilliseconds(self.postResizeHardLimitMs()));
        self.post_resize.scroll_deadline = now.addDuration(.fromMilliseconds(self.postResizeScrollRestoreMs()));
        if (self.post_resize.held_sync_output and self.terminal.modes.get(.synchronized_output)) {
            self.messageWriter(.{ .start_synchronized_output = {} });
        }
    }

    /// Update saved post-resize scroll state when the user explicitly scrolls
    /// the primary viewport while rendering is unfrozen.
    pub fn noteUserScrollViewport(self: *StreamHandler) void {
        if (!self.post_resize.active) return;
        if (self.terminal.screens.active_key != .primary) return;
        if (self.terminal.modes.get(.synchronized_output)) return;
        self.post_resize.scroll_save = PostResizeState.captureScrollSave(self.terminal.screens.active);
        if (self.post_resize.scroll_save == null and !self.postResizeHoldIsActive()) {
            self.post_resize = .{};
        }
    }

    fn postResizeHoldExpired(self: *const StreamHandler, now: std.Io.Timestamp) bool {
        if (self.post_resize.hard_deadline) |hd| {
            if (now.durationTo(hd).toNanoseconds() <= 0) return true;
        } else {
            return true;
        }
        if (self.post_resize.deadline) |dl| {
            if (now.durationTo(dl).toNanoseconds() <= 0) return true;
        } else {
            return true;
        }
        return false;
    }

    fn postResizeScrollExpired(self: *const StreamHandler, now: std.Io.Timestamp) bool {
        if (self.post_resize.scroll_deadline) |sd| {
            return now.durationTo(sd).toNanoseconds() <= 0;
        }
        return true;
    }

    /// Returns true while the bounded blank-wipe hold window (`<= 420ms`) is active.
    pub fn postResizeHoldIsActive(self: *StreamHandler) bool {
        if (!self.post_resize.active) return false;
        if (self.terminal.screens.active_key != .primary) {
            self.cancelPostResize();
            return false;
        }
        const now = std.Io.Timestamp.now(global.io(), .awake);
        if (self.post_resize.hard_deadline == null and
            self.post_resize.deadline == null and
            !self.post_resize.held_sync_output)
        {
            if (self.postResizeScrollExpired(now)) {
                self.finishPostResize();
            }
            return false;
        }
        if (self.postResizeHoldExpired(now)) {
            self.finishPostResizeHold();
            return false;
        }
        return true;
    }

    /// Returns true while either the blank-wipe hold window or the scroll-restore
    /// tail window (`<= 900ms`) is active on the primary screen.
    pub fn postResizeIsActive(self: *StreamHandler) bool {
        if (!self.post_resize.active) return false;
        if (self.terminal.screens.active_key != .primary) {
            self.cancelPostResize();
            return false;
        }
        const now = std.Io.Timestamp.now(global.io(), .awake);
        if (self.postResizeScrollExpired(now)) {
            self.finishPostResize();
            return false;
        }
        if ((self.post_resize.hard_deadline != null or
            self.post_resize.deadline != null or
            self.post_resize.held_sync_output) and
            self.postResizeHoldExpired(now))
        {
            self.finishPostResizeHold();
        }
        return self.post_resize.active;
    }

    pub fn shouldHoldPostResizeBlankWipe(self: *StreamHandler) bool {
        if (!self.postResizeHoldIsActive()) return false;
        if (!self.post_resize.saw_full_clear and !self.post_resize.saw_erase_below) return false;

        const had_substantial_content = self.post_resize.had_scrollback or
            self.post_resize.pre_cursor_y >= 4;
        if (!had_substantial_content) return false;

        return screenIsNearlyBlankWipe(self.terminal.screens.active);
    }

    fn isLikelyPostResizeTuiWipe(self: *const StreamHandler) bool {
        return self.seen_synchronized_output or
            self.terminal.modes.get(.synchronized_output) or
            !self.terminal.modes.get(.cursor_visible) or
            self.post_resize.held_sync_output or
            self.post_resize.saw_erase_below or
            self.post_resize.saw_full_clear or
            self.terminal.flags.mouse_event != .none or
            self.terminal.modes.get(.focus_event) or
            self.terminal.screens.active.kitty_keyboard.current().int() != 0;
    }

    fn holdPostResizeSyncOutput(self: *StreamHandler, now: std.Io.Timestamp) void {
        self.terminal.modes.set(.synchronized_output, true);
        self.post_resize.held_sync_output = true;
        const candidate = now.addDuration(.fromMilliseconds(self.postResizeIdleWindowMs()));
        self.post_resize.deadline = if (self.post_resize.hard_deadline) |hd|
            if (candidate.durationTo(hd).toNanoseconds() < 0) hd else candidate
        else
            candidate;
        self.messageWriter(.{ .start_synchronized_output = {} });
    }

    fn tuiWipeHoldExpired(self: *const StreamHandler, now: std.Io.Timestamp) bool {
        const dl = self.tui_wipe_hold.deadline orelse return false;
        return now.durationTo(dl).toNanoseconds() <= 0;
    }

    pub fn tuiWipeHoldIsActive(self: *StreamHandler) bool {
        if (!self.tui_wipe_hold.active) return false;
        if (self.terminal.screens.active_key != .primary) {
            self.cancelTuiWipeHold();
            return false;
        }
        const now = std.Io.Timestamp.now(global.io(), .awake);
        if (self.tuiWipeHoldExpired(now)) {
            self.finishTuiWipeHold();
            return false;
        }
        return true;
    }

    pub fn shouldHoldTuiBlankWipe(self: *StreamHandler) bool {
        if (!self.tuiWipeHoldIsActive()) return false;
        if (!self.tui_wipe_hold.saw_full_clear and !self.tui_wipe_hold.saw_erase_below) return false;
        if (!self.tui_wipe_hold.had_substantial_content) return false;
        return screenIsNearlyBlankWipe(self.terminal.screens.active);
    }

    fn holdTuiWipeSyncOutput(self: *StreamHandler, now: std.Io.Timestamp) void {
        self.terminal.modes.set(.synchronized_output, true);
        self.tui_wipe_hold.held_sync_output = true;
        if (self.tui_wipe_hold.deadline == null) {
            self.tui_wipe_hold.deadline = now.addDuration(
                .fromMilliseconds(@intCast(TuiWipeHoldState.hold_limit_ms)),
            );
        }
        self.messageWriter(.{ .start_synchronized_output = {} });
    }

    fn pinBottomOnTuiFullClear(self: *StreamHandler) void {
        if (!self.tui_wipe_hold.saw_full_clear or self.terminal.screens.active_key != .primary) return;
        const fresh = self.terminal.screens.active.pages.scrollbar();
        const max_fresh = fresh.total -| fresh.len;
        self.terminal.scrollViewport(.{ .bottom = {} });
        self.renderer_state.scroll.pinBottom(@floatFromInt(max_fresh));
        self.renderer_state.terminal_generation +%= 1;
    }

    fn completeTuiWipeCycle(self: *StreamHandler) void {
        if (!self.tui_wipe_hold.active) return;
        self.pinBottomOnTuiFullClear();
        self.tui_wipe_hold = .{};
    }

    pub fn cancelTuiWipeHold(self: *StreamHandler) void {
        if (!self.tui_wipe_hold.active) return;
        if (self.tui_wipe_hold.held_sync_output) {
            self.terminal.modes.set(.synchronized_output, false);
        }
        self.tui_wipe_hold = .{};
    }

    pub fn finishTuiWipeHold(self: *StreamHandler) void {
        if (!self.tui_wipe_hold.active) return;
        self.pinBottomOnTuiFullClear();
        if (self.tui_wipe_hold.held_sync_output) {
            self.terminal.modes.set(.synchronized_output, false);
        }
        self.tui_wipe_hold = .{};
    }

    fn noteEraseDisplay(self: *StreamHandler, mode: terminal.EraseDisplay) void {
        if (self.postResizeIsActive()) {
            if (!self.isLikelyPostResizeTuiWipe()) return;
            const hold_active = self.postResizeHoldIsActive();
            const now = std.Io.Timestamp.now(global.io(), .awake);
            switch (mode) {
                .below => {
                    const sync_active = self.terminal.modes.get(.synchronized_output);
                    const full_screen_wipe = (self.post_resize.had_scrollback or
                        self.post_resize.pre_cursor_y >= 4 or
                        screenHasSubstantialContent(self.terminal.screens.active)) and
                        self.terminal.screens.active.cursor.y <= 3;
                    if (sync_active or full_screen_wipe) {
                        self.post_resize.saw_erase_below = true;
                        if (hold_active and !sync_active) {
                            self.holdPostResizeSyncOutput(now);
                        }
                    }
                },
                .complete, .scrollback, .scroll_complete => {
                    self.post_resize.saw_full_clear = true;
                    if (hold_active and !self.terminal.modes.get(.synchronized_output)) {
                        self.holdPostResizeSyncOutput(now);
                    }
                },
                .above => {},
            }
            return;
        }

        if (self.terminal.screens.active_key != .primary) return;
        _ = self.tuiWipeHoldIsActive();
        // Never hold bare `clear` / `Ctrl+L` outside DEC 2026.
        if (!self.terminal.modes.get(.synchronized_output)) return;

        const substantial = self.tui_wipe_hold.had_substantial_content or
            screenHasSubstantialContent(self.terminal.screens.active);
        if (!substantial) return;

        switch (mode) {
            .complete, .scrollback, .scroll_complete => {
                self.tui_wipe_hold.active = true;
                self.tui_wipe_hold.had_substantial_content = true;
                self.tui_wipe_hold.saw_full_clear = true;
            },
            .below => {
                if (self.terminal.screens.active.cursor.y <= 3) {
                    self.tui_wipe_hold.active = true;
                    self.tui_wipe_hold.had_substantial_content = true;
                    self.tui_wipe_hold.saw_erase_below = true;
                }
            },
            .above => {},
        }
    }

    pub fn restorePostResizeScroll(self: *StreamHandler) void {
        if (!self.post_resize.active) return;
        if (self.terminal.screens.active_key != .primary) return;

        const fresh = self.terminal.screens.active.pages.scrollbar();
        const max_fresh = fresh.total -| fresh.len;
        if (self.post_resize.scroll_save) |saved| {
            if (max_fresh == 0) return;
            var target: usize = if (fresh.total == saved.total)
                @min(saved.offset, max_fresh)
            else
                @min(
                    (saved.offset * fresh.total + (saved.total / 2)) / @max(@as(usize, 1), saved.total),
                    max_fresh,
                );
            if (target >= max_fresh and saved.distance_from_bottom > 0) {
                const scaled_dist = if (fresh.total == saved.total)
                    saved.distance_from_bottom
                else
                    @max(
                        @as(usize, 1),
                        (saved.distance_from_bottom * fresh.total + (saved.total / 2)) / @max(@as(usize, 1), saved.total),
                    );
                target = max_fresh -| @min(scaled_dist, max_fresh);
            }
            self.terminal.scrollViewport(.{ .row = target });
            self.renderer_state.scroll.snapTo(
                @floatFromInt(target),
                @floatFromInt(max_fresh),
            );
            self.renderer_state.terminal_generation +%= 1;
        } else if (self.post_resize.saw_full_clear) {
            self.terminal.scrollViewport(.{ .bottom = {} });
            self.renderer_state.scroll.pinBottom(@floatFromInt(max_fresh));
            self.renderer_state.terminal_generation +%= 1;
        }
    }

    fn completePostResizeCycle(self: *StreamHandler) void {
        const fresh_before = self.terminal.screens.active.pages.scrollbar();
        const max_fresh = fresh_before.total -| fresh_before.len;
        self.restorePostResizeScroll();
        if (self.post_resize.scroll_save == null or max_fresh > 0) {
            self.post_resize.saw_erase_below = false;
            self.post_resize.saw_full_clear = false;
        }
        self.post_resize.held_sync_output = false;

        const now = std.Io.Timestamp.now(global.io(), .awake);
        if (!self.postResizeHoldExpired(now)) {
            const hd = self.post_resize.hard_deadline.?;
            const candidate = now.addDuration(.fromMilliseconds(self.postResizeIdleWindowMs()));
            self.post_resize.deadline = if (candidate.durationTo(hd).toNanoseconds() < 0)
                hd
            else
                candidate;
            return;
        }

        self.post_resize.deadline = null;
        self.post_resize.hard_deadline = null;
        if (self.post_resize.scroll_save != null and !self.postResizeScrollExpired(now)) {
            return;
        }
        self.post_resize = .{};
    }

    pub fn cancelPostResize(self: *StreamHandler) void {
        if (!self.post_resize.active) return;
        if (self.post_resize.held_sync_output) {
            self.terminal.modes.set(.synchronized_output, false);
        }
        self.post_resize = .{};
    }

    /// Release the blank-wipe sync hold while retaining `scroll_save` for the
    /// bounded scrollback restoration tail window (`scroll_restore_ms`).
    pub fn finishPostResizeHold(self: *StreamHandler) void {
        if (!self.post_resize.active) return;
        if (self.post_resize.saw_full_clear or self.post_resize.saw_erase_below) {
            self.restorePostResizeScroll();
        }
        if (self.post_resize.held_sync_output) {
            self.terminal.modes.set(.synchronized_output, false);
        }
        self.post_resize.held_sync_output = false;
        self.post_resize.deadline = null;
        self.post_resize.hard_deadline = null;

        const now = std.Io.Timestamp.now(global.io(), .awake);
        if (self.post_resize.scroll_save != null and !self.postResizeScrollExpired(now)) {
            return;
        }
        self.post_resize = .{};
    }

    pub fn finishPostResize(self: *StreamHandler) void {
        if (!self.post_resize.active) return;
        if (self.post_resize.saw_full_clear or self.post_resize.saw_erase_below) {
            self.restorePostResizeScroll();
        }
        if (self.post_resize.held_sync_output) {
            self.terminal.modes.set(.synchronized_output, false);
        }
        self.post_resize = .{};
    }
};

test "StreamHandler: post-resize relies on genuine DEC 2026 without cursor_y <= 3 freeze hijacking" {
    const testing = std.testing;
    const alloc = testing.allocator;

    comptime {
        std.debug.assert(StreamHandler.PostResizeState.idle_window_ms <= 350);
        std.debug.assert(StreamHandler.PostResizeState.hard_limit_ms <= 450);
        std.debug.assert(StreamHandler.PostResizeState.scroll_restore_ms <= 1000);
    }

    var t = try terminal.Terminal.init(testing.io, alloc, .{
        .cols = 40,
        .rows = 10,
    });
    defer t.deinit(alloc);

    var mutex: std.Io.Mutex = .init;
    var renderer_state: renderer.State = .{
        .mutex = &mutex,
        .terminal = &t,
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

    var handler: StreamHandler = .{
        .alloc = alloc,
        .remote_session = true,
        .size = &size,
        .terminal = &t,
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

    var s = t.vtStream();
    defer s.deinit();

    // Populate 30 lines of output wrapped in mode 2026, then park cursor at row 8.
    handler.setSynchronizedOutput(true);
    for (0..30) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.mem.print(&buf, "history-{d:0>2}\r\n", .{i});
        s.nextSlice(line);
    }
    s.nextSlice("footer-line\x1b[8;1H");
    handler.setSynchronizedOutput(false);
    try testing.expect(handler.seen_synchronized_output);

    // Scroll up into history (offset = 6).
    t.scrollViewport(.{ .row = 6 });
    try testing.expect(!t.screens.active.viewportIsBottom());
    const pre_sb = t.screens.active.pages.scrollbar();
    try testing.expectEqual(@as(usize, 6), pre_sb.offset);

    // Simulate resize (10 -> 8 rows) while scrolled up.
    const pre_cursor_y = t.screens.active.cursor.y;
    try t.resize(alloc, .{ .cols = 40, .rows = 8, .force_pull_scrollback = true });
    handler.noteTerminalResize(true, pre_sb, pre_cursor_y);

    // 1) Genuine DECSET 2026 partial redraw ending with cursor at row 1 (`cursor_y <= 3`)
    // MUST release `synchronized_output` immediately on DECRST 2026 — never hijacked!
    handler.setSynchronizedOutput(true);
    s.nextSlice("\r\x1b[7A");
    handler.noteEraseDisplay(.below);
    s.nextSlice("\x1b[J> prompt\r\nstatus");
    try testing.expect(t.screens.active.cursor.y <= 3);
    handler.setSynchronizedOutput(false);
    try testing.expect(!t.modes.get(.synchronized_output));
    try testing.expect(!handler.post_resize.held_sync_output);

    // 2) Full wipe arriving immediately before `<Static>` history reprint coalesces
    // briefly within `<= 150ms` and releases cleanly once DECRST 2026 arrives.
    handler.noteEraseDisplay(.complete);
    s.nextSlice("\x1b[2J");
    handler.noteEraseDisplay(.scrollback);
    s.nextSlice("\x1b[3J\x1b[H");
    try testing.expect(t.modes.get(.synchronized_output));
    try testing.expect(handler.post_resize.saw_full_clear);

    handler.setSynchronizedOutput(true);
    for (0..30) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.mem.print(&buf, "history-{d:0>2}\r\n", .{i});
        s.nextSlice(line);
    }
    s.nextSlice("footer-line\x1b[6;1H");
    handler.setSynchronizedOutput(false);

    try testing.expect(!t.modes.get(.synchronized_output));
    try testing.expect(!handler.post_resize.held_sync_output);
    try testing.expect(!handler.post_resize.saw_full_clear);
    try testing.expect(!t.screens.active.viewportIsBottom());
    try testing.expectEqual(@as(usize, 6), t.screens.active.pages.scrollbar().offset);
    try testing.expect(!renderer_state.scroll.pinned_to_bottom);
}

test "StreamHandler: partial CSI J does not freeze outside mode 2026 and full wipe releases on cursor show" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(testing.io, alloc, .{
        .cols = 40,
        .rows = 10,
    });
    defer t.deinit(alloc);

    var mutex: std.Io.Mutex = .init;
    var renderer_state: renderer.State = .{
        .mutex = &mutex,
        .terminal = &t,
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

    var handler: StreamHandler = .{
        .alloc = alloc,
        .remote_session = true,
        .size = &size,
        .terminal = &t,
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

    var s = t.vtStream();
    defer s.deinit();

    t.modes.set(.cursor_visible, false);
    for (0..30) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.mem.print(&buf, "history-{d:0>2}\r\n", .{i});
        s.nextSlice(line);
    }
    s.nextSlice("prompt-top\r\nprompt-input\r\nprompt-bottom\r\n? for shortcuts\x1b[2A\x1b[2C");
    handler.notePostResizeCursorVisible();

    t.scrollViewport(.{ .row = 8 });
    const pre_sb = t.screens.active.pages.scrollbar();
    try testing.expectEqual(@as(usize, 8), pre_sb.offset);

    const pre_cursor_y = t.screens.active.cursor.y;
    try t.resize(alloc, .{ .cols = 25, .rows = 10 });
    handler.noteTerminalResize(true, pre_sb, pre_cursor_y);

    // Partial bottom-area `\x1b[J` (`cursor.y >= 4`) outside mode 2026 must NOT
    // synthetically freeze `synchronized_output`.
    t.modes.set(.cursor_visible, false);
    s.nextSlice("\r\x1b[2A");
    try testing.expect(t.screens.active.cursor.y >= 4);
    handler.noteEraseDisplay(.below);
    s.nextSlice("\x1b[J? for shortcuts\r\x1b[m");
    try testing.expect(!t.modes.get(.synchronized_output));
    try testing.expect(!handler.post_resize.held_sync_output);

    // Full `\x1b[2J\x1b[3J` wipe coalesces within the bounded `<= 420ms` window and
    // releases immediately on `\x1b[?25h` once scrollback is repopulated — even when `cursor.y <= 3`!
    handler.noteEraseDisplay(.complete);
    t.scrollViewport(.{ .bottom = {} });
    s.nextSlice("\x1b[2J");
    handler.noteEraseDisplay(.scrollback);
    s.nextSlice("\x1b[3J\x1b[H");
    try testing.expect(t.modes.get(.synchronized_output));
    try testing.expect(handler.post_resize.saw_full_clear);

    for (0..30) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.mem.print(&buf, "\r\x1b[Khistory-{d:0>2}\r\n", .{i});
        s.nextSlice(line);
    }
    s.nextSlice("prompt-top\r\nprompt-input\r\nprompt-bottom\r\n? for shortcuts\x1b[1;1H");
    try testing.expectEqual(@as(terminal.size.CellCountInt, 0), t.screens.active.cursor.y);
    handler.notePostResizeCursorVisible();

    try testing.expect(!t.modes.get(.synchronized_output));
    try testing.expect(!handler.post_resize.held_sync_output);
    try testing.expect(!handler.post_resize.saw_full_clear);
    try testing.expectEqual(@as(usize, 8), t.screens.active.pages.scrollbar().offset);
}

test "StreamHandler: post-resize hold is bounded to <= 420ms, scroll_restore_ms <= 900ms, and preserves scroll_save across back-to-back resizes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(testing.io, alloc, .{
        .cols = 40,
        .rows = 12,
    });
    defer t.deinit(alloc);

    var mutex: std.Io.Mutex = .init;
    var renderer_state: renderer.State = .{
        .mutex = &mutex,
        .terminal = &t,
    };
    var size: renderer.Size = .{
        .screen = .{ .width = 400, .height = 240 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };
    var termio_mailbox = try termio.Mailbox.initSPSC(alloc);
    defer termio_mailbox.deinit(alloc);
    var renderer_mailbox: renderer.Thread.Mailbox = .{};
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();

    var handler: StreamHandler = .{
        .alloc = alloc,
        .remote_session = true,
        .size = &size,
        .terminal = &t,
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

    var s = t.vtStream();
    defer s.deinit();

    t.modes.set(.cursor_visible, false);
    for (0..20) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.mem.print(&buf, "history-{d:0>2}\r\n", .{i});
        s.nextSlice(line);
    }
    s.nextSlice("prompt-top\r\nprompt-input\r\nprompt-bottom\r\n? for shortcuts\x1b[2A\x1b[2C");
    handler.notePostResizeCursorVisible();

    // User scrolls up to offset = 5.
    t.scrollViewport(.{ .row = 5 });
    const pre_sb1 = t.screens.active.pages.scrollbar();
    const pre_cy1 = t.screens.active.cursor.y;

    try t.resize(alloc, .{ .cols = 40, .rows = 8, .force_pull_scrollback = true });
    handler.noteTerminalResize(true, pre_sb1, pre_cy1);
    handler.noteChildResizeCommitted();

    // Full wipe arrives within `<= 420ms`, then Resize #2 arrives before completion.
    t.modes.set(.cursor_visible, false);
    handler.noteEraseDisplay(.complete);
    t.scrollViewport(.{ .bottom = {} });
    s.nextSlice("\x1b[2J");
    handler.noteEraseDisplay(.scrollback);
    s.nextSlice("\x1b[3J\x1b[H");
    try testing.expect(t.modes.get(.synchronized_output));
    try testing.expect(handler.post_resize.held_sync_output);

    const pre_sb2 = t.screens.active.pages.scrollbar();
    const pre_cy2 = t.screens.active.cursor.y;
    try t.resize(alloc, .{ .cols = 40, .rows = 10, .force_pull_scrollback = true });
    handler.noteTerminalResize(false, pre_sb2, pre_cy2);
    try testing.expect(t.modes.get(.synchronized_output));
    try testing.expectEqual(@as(usize, 5), handler.post_resize.scroll_save.?.offset);

    for (0..20) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.mem.print(&buf, "\r\x1b[Khistory-{d:0>2}\r\n", .{i});
        s.nextSlice(line);
    }
    s.nextSlice("prompt-top\r\nprompt-input\r\nprompt-bottom\r\n? for shortcuts\x1b[2A\x1b[2C");
    handler.notePostResizeCursorVisible();
    try testing.expect(!t.modes.get(.synchronized_output));
    try testing.expectEqual(@as(usize, 5), t.screens.active.pages.scrollbar().offset);

    // Simulating >420ms elapsed releases held sync output immediately while keeping
    // `scroll_save` alive inside the 900ms scroll-restore tail window; >900ms clears all state.
    t.modes.set(.cursor_visible, false);
    handler.noteEraseDisplay(.complete);
    try testing.expect(t.modes.get(.synchronized_output));
    handler.post_resize.hard_deadline = std.Io.Timestamp.now(testing.io, .awake).addDuration(.fromMilliseconds(-1));
    try testing.expect(!handler.postResizeHoldIsActive());
    try testing.expect(!t.modes.get(.synchronized_output));
    try testing.expect(!handler.post_resize.held_sync_output);
    try testing.expect(handler.postResizeIsActive());
    try testing.expectEqual(@as(usize, 5), handler.post_resize.scroll_save.?.offset);

    handler.post_resize.scroll_deadline = std.Io.Timestamp.now(testing.io, .awake).addDuration(.fromMilliseconds(-1));
    try testing.expect(!handler.postResizeIsActive());
    try testing.expect(!handler.post_resize.active);

    // Bare shell `/usr/bin/clear` (cursor visible, no mode 2026 / TUI modes) must NOT freeze:
    handler.seen_synchronized_output = false;
    t.modes.set(.cursor_visible, true);
    const bare_sb = t.screens.active.pages.scrollbar();
    handler.noteTerminalResize(false, bare_sb, t.screens.active.cursor.y);
    handler.noteEraseDisplay(.complete);
    try testing.expect(!t.modes.get(.synchronized_output));
}

const PostResizeTestHarness = struct {
    terminal: terminal.Terminal,
    mutex: std.Io.Mutex,
    renderer_state: renderer.State,
    size: renderer.Size,
    termio_mailbox: termio.Mailbox,
    renderer_mailbox: renderer.Thread.Mailbox,
    wakeup: xev.Async,
    stream: StreamHandler.Stream,

    fn init(
        self: *PostResizeTestHarness,
        alloc: Allocator,
        cols: terminal.size.CellCountInt,
        rows: terminal.size.CellCountInt,
    ) !void {
        self.terminal = try terminal.Terminal.init(std.testing.io, alloc, .{
            .cols = cols,
            .rows = rows,
        });
        errdefer self.terminal.deinit(alloc);

        self.mutex = .init;
        self.renderer_state = .{
            .mutex = &self.mutex,
            .terminal = &self.terminal,
        };
        self.size = .{
            .screen = .{ .width = @as(u32, cols) * 10, .height = @as(u32, rows) * 20 },
            .cell = .{ .width = 10, .height = 20 },
            .padding = .{},
        };
        self.termio_mailbox = try termio.Mailbox.initSPSC(alloc);
        errdefer self.termio_mailbox.deinit(alloc);
        self.renderer_mailbox = .{};
        self.wakeup = try xev.Async.init();
        errdefer self.wakeup.deinit();

        self.stream = .init(.{
            .allocator = alloc,
            .handler = .{
                .alloc = alloc,
                .remote_session = true,
                .size = &self.size,
                .terminal = &self.terminal,
                .termio_mailbox = &self.termio_mailbox,
                .surface_mailbox = undefined,
                .renderer_state = &self.renderer_state,
                .renderer_mailbox = &self.renderer_mailbox,
                .renderer_wakeup = self.wakeup,
                .enquiry_response = "",
                .osc_color_report_format = .none,
                .clipboard_write = .deny,
            },
        });
    }

    fn deinit(self: *PostResizeTestHarness, alloc: Allocator) void {
        self.stream.deinit();
        self.wakeup.deinit();
        self.termio_mailbox.deinit(alloc);
        self.terminal.deinit(alloc);
    }

    fn handler(self: *PostResizeTestHarness) *StreamHandler {
        return &self.stream.handler;
    }

    fn resize(
        self: *PostResizeTestHarness,
        alloc: Allocator,
        cols: terminal.size.CellCountInt,
        rows: terminal.size.CellCountInt,
        pull_scrollback: bool,
    ) !void {
        const was_scrolled_up = !self.terminal.screens.active.viewportIsBottom();
        const pre_sb = self.terminal.screens.active.pages.scrollbar();
        const pre_cursor_y = self.terminal.screens.active.cursor.y;
        try self.terminal.resize(alloc, .{
            .cols = cols,
            .rows = rows,
            .force_pull_scrollback = pull_scrollback,
        });
        self.stream.handler.noteTerminalResize(was_scrolled_up, pre_sb, pre_cursor_y);
        self.stream.handler.noteChildResizeCommitted();
    }

    fn rewindDeadlinesMs(self: *PostResizeTestHarness, delta_ms: i64) void {
        const post_resize = &self.stream.handler.post_resize;
        const offset = std.Io.Duration.fromMilliseconds(-delta_ms);
        if (post_resize.deadline) |dl| post_resize.deadline = dl.addDuration(offset);
        if (post_resize.hard_deadline) |hd| post_resize.hard_deadline = hd.addDuration(offset);
        if (post_resize.scroll_deadline) |sd| post_resize.scroll_deadline = sd.addDuration(offset);
    }

    fn writeLines(self: *PostResizeTestHarness, count: usize) !void {
        for (0..count) |i| {
            var buf: [32]u8 = undefined;
            const line = try std.mem.print(&buf, "history-{d:0>2}\r\n", .{i});
            self.stream.nextSlice(line);
        }
    }
};

test "StreamHandler: octo two-phase SIGWINCH redraw holds Phase 1 blank wipe and restores scrollback on Phase 2" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env: PostResizeTestHarness = undefined;
    try env.init(alloc, 40, 10);
    defer env.deinit(alloc);

    // Populate 80 lines wrapped in DEC 2026 and scroll up to offset = 20.
    env.stream.nextSlice("\x1b[?2026h");
    try env.writeLines(80);
    env.stream.nextSlice("prompt-line\r\n? for shortcuts\x1b[?2026l");
    try testing.expect(env.handler().seen_synchronized_output);

    env.terminal.scrollViewport(.{ .row = 20 });
    try testing.expect(!env.terminal.screens.active.viewportIsBottom());
    try testing.expectEqual(@as(usize, 20), env.terminal.screens.active.pages.scrollbar().offset);

    // SIGWINCH resize (40x10 -> 40x8).
    try env.resize(alloc, 40, 8, true);

    // Phase 1 (+10ms): clear scrollback + 1 header line inside DEC 2026.
    // Must keep holding `synchronized_output` across Phase 1's DECRST 2026
    // and MUST NOT drop `scroll_save` on the empty intermediate screen.
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts   octo\x1b[?2026l");
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    try testing.expect(env.handler().post_resize.held_sync_output);
    try testing.expect(env.handler().post_resize.scroll_save != null);
    try testing.expectEqual(@as(usize, 20), env.handler().post_resize.scroll_save.?.offset);

    // Phase 2 (+250ms, still inside 320/420ms hold window): reprints 80 lines + DECRST 2026.
    env.rewindDeadlinesMs(250);
    try testing.expect(env.handler().postResizeHoldIsActive());
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H");
    try env.writeLines(80);
    env.stream.nextSlice("prompt-line\r\n? for shortcuts\x1b[?2026l");

    // Releases `synchronized_output` immediately (0ms extra wait) and restores offset = 20.
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().post_resize.held_sync_output);
    try testing.expect(!env.terminal.screens.active.viewportIsBottom());
    try testing.expectEqual(@as(usize, 20), env.terminal.screens.active.pages.scrollbar().offset);
    try testing.expect(!env.renderer_state.scroll.pinned_to_bottom);

    // Also verify `pre_cursor_y` preservation holds a single-screen (no scrollback) wipe
    // when `pre_cursor_y >= 4` and releases once Phase 2 populates past row 3.
    env.handler().cancelPostResize();
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H");
    try env.writeLines(6);
    env.stream.nextSlice("prompt\x1b[?2026l");
    try testing.expect(env.terminal.screens.active.cursor.y >= 4);
    try env.resize(alloc, 40, 10, true);
    env.stream.nextSlice("\x1b[?2026h\x1b[H\x1b[J? for shortcuts   octo\x1b[?2026l");
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    try testing.expect(env.handler().post_resize.held_sync_output);

    // Second back-to-back resize while wiped at row 0 must retain `@max(pre_cursor_y, 0) >= 4`.
    try env.resize(alloc, 42, 10, true);
    try testing.expect(env.handler().post_resize.pre_cursor_y >= 4);
    env.stream.nextSlice("\x1b[?2026h\x1b[H\x1b[J");
    try env.writeLines(6);
    env.stream.nextSlice("prompt\x1b[?2026l");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().post_resize.held_sync_output);
}

test "StreamHandler: standalone CSI H CSI J wipe without DEC 2026 holds until full reprint and cursor show" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env: PostResizeTestHarness = undefined;
    try env.init(alloc, 40, 10);
    defer env.deinit(alloc);

    env.stream.nextSlice("\x1b[?25l");
    try env.writeLines(40);
    env.stream.nextSlice("prompt-top\r\n? for shortcuts\x1b[?25h");

    env.terminal.scrollViewport(.{ .row = 10 });
    try testing.expectEqual(@as(usize, 10), env.terminal.screens.active.pages.scrollbar().offset);

    try env.resize(alloc, 30, 10, false);

    // Standalone `\x1b[H\x1b[J? for shortcuts\r` without DEC 2026 holds sync output.
    env.stream.nextSlice("\x1b[?25l\x1b[H\x1b[J? for shortcuts\r");
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    try testing.expect(env.handler().post_resize.held_sync_output);
    try testing.expect(env.handler().post_resize.saw_erase_below);

    // Even if `\x1b[3J` cleared scrollback and `\x1b[?25h` toggled on the 1-line wipe,
    // `shouldHoldPostResizeBlankWipe` keeps holding until full content arrives.
    env.stream.nextSlice("\x1b[3J\x1b[H\x1b[J? for shortcuts\r\x1b[?25h");
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    try testing.expect(env.handler().post_resize.held_sync_output);

    // Full reprint + `\x1b[?25h` immediately releases sync output and restores scroll offset.
    env.stream.nextSlice("\x1b[?25l\x1b[H");
    try env.writeLines(40);
    env.stream.nextSlice("prompt-top\r\n? for shortcuts\x1b[?25h");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().post_resize.held_sync_output);
    try testing.expectEqual(@as(usize, 10), env.terminal.screens.active.pages.scrollbar().offset);
}

test "StreamHandler: late history reprint at +600ms restores scroll_save without holding sync output past 420ms" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env: PostResizeTestHarness = undefined;
    try env.init(alloc, 40, 10);
    defer env.deinit(alloc);

    env.stream.nextSlice("\x1b[?2026h");
    try env.writeLines(80);
    env.stream.nextSlice("prompt\r\n? for shortcuts\x1b[?2026l");
    env.terminal.scrollViewport(.{ .row = 20 });

    try env.resize(alloc, 40, 8, true);

    // Phase 1 holds sync output and saves scroll offset = 20.
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts   octo\x1b[?2026l");
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    try testing.expect(env.handler().post_resize.held_sync_output);

    // Simulate +421ms elapsed (past 420ms hold cap, still inside 900ms scroll_restore_ms):
    // `held_sync_output` and `synchronized_output` release (no freeze) while `scroll_save` remains armed.
    env.rewindDeadlinesMs(421);
    try testing.expect(!env.handler().postResizeHoldIsActive());
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().post_resize.held_sync_output);
    try testing.expect(env.handler().postResizeIsActive());
    try testing.expect(env.handler().post_resize.scroll_save != null);

    // Simulate +600ms total elapsed (~300ms remaining on `scroll_deadline`).
    env.rewindDeadlinesMs(180);
    try testing.expect(env.handler().postResizeIsActive());

    // Phase 2 arrives at +600ms: must NOT re-hold sync output past 420ms, AND must restore offset = 20.
    env.stream.nextSlice("\x1b[?25l\x1b[2J\x1b[3J\x1b[H");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().post_resize.held_sync_output);
    try env.writeLines(80);
    env.stream.nextSlice("prompt\r\n? for shortcuts\x1b[?25h");

    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.terminal.screens.active.viewportIsBottom());
    try testing.expectEqual(@as(usize, 20), env.terminal.screens.active.pages.scrollbar().offset);

    // Also verify `finishPostResizeHold` (timer path at 420ms) releases hold while preserving `scroll_save`.
    try env.resize(alloc, 40, 10, true);
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    env.handler().finishPostResizeHold();
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().post_resize.held_sync_output);
    try testing.expect(env.handler().postResizeIsActive());
    try testing.expect(env.handler().post_resize.scroll_save != null);

    // Past 900ms `scroll_deadline`, `postResizeIsActive` expires and clears all state.
    env.rewindDeadlinesMs(950);
    try testing.expect(!env.handler().postResizeIsActive());
    try testing.expect(!env.handler().post_resize.active);
}

test "StreamHandler: immediate unfreeze on OSC 133 semanticPrompt, alt-screen switch, or hard_deadline expiry" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env: PostResizeTestHarness = undefined;
    try env.init(alloc, 40, 10);
    defer env.deinit(alloc);

    env.stream.nextSlice("\x1b[?2026h");
    try env.writeLines(40);
    env.stream.nextSlice("prompt\x1b[?2026l");

    // 1) OSC 133 semanticPrompt (`prompt_start`) immediately unfreezes held sync output.
    try env.resize(alloc, 40, 8, true);
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    try testing.expect(env.handler().post_resize.held_sync_output);

    env.stream.nextSlice("\x1b]133;A\x07");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().post_resize.held_sync_output);
    try testing.expect(!env.handler().post_resize.active);

    // 2) Alt-screen switch (`CSI ? 1049 h`) immediately unfreezes held sync output.
    env.stream.nextSlice("\x1b[?2026h");
    try env.writeLines(40);
    env.stream.nextSlice("prompt\x1b[?2026l");
    try env.resize(alloc, 40, 10, true);
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    try testing.expect(env.terminal.modes.get(.synchronized_output));

    env.stream.nextSlice("\x1b[?1049h");
    try testing.expectEqual(.alternate, env.terminal.screens.active_key);
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().post_resize.held_sync_output);
    try testing.expect(!env.handler().post_resize.active);

    // 3) `hard_deadline` expiry immediately unfreezes held sync output.
    env.stream.nextSlice("\x1b[?1049l\x1b[?2026h");
    try env.writeLines(40);
    env.stream.nextSlice("prompt\x1b[?2026l");
    try env.resize(alloc, 40, 8, true);
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    try testing.expect(env.terminal.modes.get(.synchronized_output));

    env.handler().post_resize.hard_deadline = std.Io.Timestamp.now(testing.io, .awake).addDuration(.fromMilliseconds(-1));
    try testing.expect(!env.handler().postResizeHoldIsActive());
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().post_resize.held_sync_output);
    try testing.expect(!env.handler().post_resize.active);
}

test "StreamHandler: omg-program-status-query emits protocol_reply even in remote_session" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{ .cols = 40, .rows = 10 });
    defer t.deinit(alloc);

    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(global.io());
    defer mutex.unlock(global.io());

    var renderer_state: renderer.State = .{
        .mutex = &mutex,
        .terminal = &t,
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

    var handler: StreamHandler = .{
        .alloc = alloc,
        .remote_session = true,
        .size = &size,
        .terminal = &t,
        .termio_mailbox = &termio_mailbox,
        .surface_mailbox = undefined,
        .renderer_state = &renderer_state,
        .renderer_mailbox = &renderer_mailbox,
        .renderer_wakeup = wakeup,
        .enquiry_response = "ignored",
        .osc_color_report_format = .none,
        .clipboard_write = .deny,
    };
    defer handler.deinit();

    // Normal ENQ write_stable is suppressed in `remote_session`, whereas an
    // unanswered `\e]7501;?` forwarded from a preserved holder or inline session
    // queues `.protocol_reply` with matching BEL / ST terminators.
    try handler.enquiry();
    try testing.expect(handler.queueProgramStatusQueryReply(.{
        .action = .start,
        .id = "omg-program-status-query",
        .metadata = "\x07",
    }));
    try testing.expect(handler.queueProgramStatusQueryReply(.{
        .action = .start,
        .id = "omg-program-status-query",
        .metadata = "\x1b\\",
    }));

    const first = termio_mailbox.spsc.queue.pop(global.io()).?;
    try testing.expectEqualStrings(
        "\x1b]7501;" ++ terminal.osc.program_status.query_reply ++ "\x07",
        first.protocol_reply,
    );
    const second = termio_mailbox.spsc.queue.pop(global.io()).?;
    try testing.expectEqualStrings(
        "\x1b]7501;" ++ terminal.osc.program_status.query_reply ++ "\x1b\\",
        second.protocol_reply,
    );
    try testing.expect(termio_mailbox.spsc.queue.pop(global.io()) == null);
}

test "StreamHandler: non-resize Ctrl+O wipe holds Phase 1 across 1500ms, releases Phase 2, and pins bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env: PostResizeTestHarness = undefined;
    try env.init(alloc, 40, 10);
    defer env.deinit(alloc);

    // Populate 80 lines inside DEC 2026 so screen has substantial scrollback.
    env.stream.nextSlice("\x1b[?2026h");
    try env.writeLines(80);
    env.stream.nextSlice("prompt-line\r\n? for shortcuts\x1b[?2026l");
    try testing.expect(env.terminal.screens.active.pages.total_rows > env.terminal.screens.active.pages.rows);

    // Simulate user scrolled up in scrollback (`pinned_to_bottom == false`).
    env.terminal.scrollViewport(.{ .row = 15 });
    env.renderer_state.scroll.snapTo(15, @floatFromInt(env.terminal.screens.active.pages.scrollbar().total -| 10));
    try testing.expect(!env.terminal.screens.active.viewportIsBottom());
    try testing.expect(!env.renderer_state.scroll.pinned_to_bottom);

    // Phase 1 Ctrl+O wipe inside DEC 2026 clears screen+scrollback and leaves 1 banner line.
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts   agy\x1b[?2026l");
    try testing.expect(env.renderer_state.scroll.pinned_to_bottom);
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    try testing.expect(env.handler().tui_wipe_hold.active);
    try testing.expect(env.handler().tui_wipe_hold.held_sync_output);
    try testing.expect(env.handler().tui_wipe_hold.saw_full_clear);
    try testing.expect(env.handler().tui_wipe_hold.deadline != null);

    // Simulate +1500ms elapsed (still inside 2500ms hold_limit_ms): stays frozen without blank flash.
    env.handler().tui_wipe_hold.deadline = env.handler().tui_wipe_hold.deadline.?.addDuration(.fromMilliseconds(-1500));
    try testing.expect(env.handler().tuiWipeHoldIsActive());
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    try testing.expect(env.handler().shouldHoldTuiBlankWipe());

    // Phase 2 arrives (+1500ms) with expanded 80-line history and DECRST 2026:
    // immediately unfreezes, pins bottom to `max_fresh`, and clears `tui_wipe_hold`.
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H");
    try testing.expect(!env.handler().tui_wipe_hold.held_sync_output);
    try testing.expect(env.handler().tui_wipe_hold.deadline == null);
    try env.writeLines(80);
    env.stream.nextSlice("prompt-line\r\n? for shortcuts\x1b[?2026l");

    const sb = env.terminal.screens.active.pages.scrollbar();
    const max_fresh: f64 = @floatFromInt(sb.total -| sb.len);
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().tui_wipe_hold.active);
    try testing.expect(env.terminal.screens.active.viewportIsBottom());
    try testing.expect(env.renderer_state.scroll.pinned_to_bottom);
    try testing.expectEqual(max_fresh, env.renderer_state.scroll.position);

    // Also verify Phase 2 completing via `\x1b[?25h` (cursor_visible) releases held `tui_wipe_hold`.
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    try testing.expect(env.handler().tui_wipe_hold.held_sync_output);
    env.stream.nextSlice("\x1b[?25l\x1b[H");
    try env.writeLines(40);
    env.stream.nextSlice("prompt\x1b[?25h");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().tui_wipe_hold.active);
    try testing.expect(env.renderer_state.scroll.pinned_to_bottom);
}

test "StreamHandler: tui_wipe_hold false-positive guards, immediate unfreeze, and resize fold" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env: PostResizeTestHarness = undefined;
    try env.init(alloc, 40, 10);
    defer env.deinit(alloc);

    // Guard 1: Initial nearly empty screen (< 4 rows, no scrollback) MUST NOT hold inside DEC 2026.
    env.stream.nextSlice("line0\r\nline1\x1b[?2026h\x1b[2J\x1b[3J\x1b[Hheader\x1b[?2026l");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().tui_wipe_hold.active);

    // Populate substantial content with DEC 2026 so `seen_synchronized_output` is true.
    env.stream.nextSlice("\x1b[?2026h");
    try env.writeLines(40);
    env.stream.nextSlice("prompt\x1b[?2026l");
    try testing.expect(env.handler().seen_synchronized_output);

    // Guard 2: Bare `clear` / `Ctrl+L` OUTSIDE DEC 2026 MUST NEVER freeze.
    env.stream.nextSlice("\x1b[3J\x1b[H\x1b[2J");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().tui_wipe_hold.active);

    // Guard 3: Incremental `CSI J` below cursor row 3 (`cursor.y >= 4`) inside DEC 2026 MUST NOT arm.
    try env.writeLines(6);
    try testing.expect(env.terminal.screens.active.cursor.y >= 4);
    env.stream.nextSlice("\x1b[?2026h\x1b[Jstatus\x1b[?2026l");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().tui_wipe_hold.active);

    // Guard 4: Same-frame wipe + reprint >= 4 populated rows (no scrollback, cursor.y <= 3) releases immediately.
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H");
    try env.writeLines(6);
    env.stream.nextSlice("\x1b[1;1H\x1b[?2026l");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().tui_wipe_hold.active);

    // Unfreeze 1: OSC 133;A (`prompt_start`) immediately unfreezes held `tui_wipe_hold`.
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    try testing.expect(env.handler().tui_wipe_hold.held_sync_output);
    env.stream.nextSlice("\x1b]133;A\x07");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().tui_wipe_hold.active);

    // Unfreeze 2: Alt-screen switch (`CSI ? 1049 h`) immediately unfreezes held `tui_wipe_hold`.
    env.stream.nextSlice("\x1b[?2026h");
    try env.writeLines(20);
    env.stream.nextSlice("\x1b[?2026l\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    env.stream.nextSlice("\x1b[?1049h");
    try testing.expectEqual(.alternate, env.terminal.screens.active_key);
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().tui_wipe_hold.active);

    // Unfreeze 3: `tui_wipe_hold.deadline` expiry (> 2500ms) releases cleanly.
    env.stream.nextSlice("\x1b[?1049l\x1b[?2026h");
    try env.writeLines(20);
    env.stream.nextSlice("\x1b[?2026l\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    try testing.expect(env.terminal.modes.get(.synchronized_output));
    env.handler().tui_wipe_hold.deadline = std.Io.Timestamp.now(testing.io, .awake).addDuration(.fromMilliseconds(-1));
    try testing.expect(!env.handler().tuiWipeHoldIsActive());
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(!env.handler().tui_wipe_hold.active);

    // Resize arriving during held `tui_wipe_hold` folds substantial content & held sync into `post_resize`.
    env.stream.nextSlice("\x1b[?2026h");
    try env.writeLines(20);
    env.stream.nextSlice("\x1b[?2026l\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    try testing.expect(env.handler().tui_wipe_hold.held_sync_output);
    try env.resize(alloc, 42, 10, true);
    try testing.expect(!env.handler().tui_wipe_hold.active);
    try testing.expect(env.handler().post_resize.active);
    try testing.expect(env.handler().post_resize.had_scrollback);
    try testing.expect(env.handler().post_resize.held_sync_output);
    try testing.expect(env.handler().post_resize.saw_full_clear);
    try testing.expect(env.terminal.modes.get(.synchronized_output));

    // Phase 2 after folded resize releases and pins bottom; also verify `erase_display_complete`
    // preserves `!pinned_to_bottom` when `post_resize.scroll_save != null`.
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H");
    try env.writeLines(30);
    env.stream.nextSlice("\x1b[?2026l");
    try testing.expect(!env.terminal.modes.get(.synchronized_output));

    env.terminal.scrollViewport(.{ .row = 5 });
    env.renderer_state.scroll.snapTo(5, 20);
    try env.resize(alloc, 40, 10, true);
    try testing.expect(env.handler().post_resize.scroll_save != null);
    env.stream.nextSlice("\x1b[2J");
    try testing.expect(!env.renderer_state.scroll.pinned_to_bottom);
}

test "StreamHandler: OSC 3008 type=remote and remote_ssh_session extend post-resize windows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env: PostResizeTestHarness = undefined;
    try env.init(alloc, 40, 10);
    defer env.deinit(alloc);

    try testing.expect(!env.handler().isRemoteSshSession());

    // Entering OSC 3008 `type=remote` activates extended remote SSH resize windows.
    env.stream.nextSlice("\x1b]3008;start=omg-ssh-1;type=remote;targethost=cloud\x07");
    try testing.expect(env.handler().in_remote_ssh_context);
    try testing.expect(env.handler().isRemoteSshSession());

    // Nested omg-agent / omg-inline / omg-runtime-state end signals must NOT clear remote SSH context.
    env.stream.nextSlice("\x1b]3008;start=omg-agent-antigravity-7;type=app\x07");
    env.stream.nextSlice("\x1b]3008;end=omg-agent-antigravity-7\x07");
    env.stream.nextSlice("\x1b]3008;end=omg-inline-1\x07");
    env.stream.nextSlice("\x1b]3008;end=omg-runtime-state\x07");
    try testing.expect(env.handler().in_remote_ssh_context);

    // Populate 60 lines, scroll up to offset = 18, resize, and hold Phase 1 wipe.
    env.stream.nextSlice("\x1b[?2026h");
    try env.writeLines(60);
    env.stream.nextSlice("prompt\x1b[?2026l");
    env.terminal.scrollViewport(.{ .row = 18 });
    try env.resize(alloc, 40, 8, true);
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    try testing.expect(env.handler().post_resize.held_sync_output);

    // At +1500ms (past local 320/420ms, inside remote 1800/2400ms), hold MUST remain active.
    env.rewindDeadlinesMs(1500);
    try testing.expect(env.handler().postResizeHoldIsActive());
    try testing.expect(env.terminal.modes.get(.synchronized_output));

    // At +2500ms total (past 2400ms remote_hard_limit_ms, inside 3200ms remote_scroll_restore_ms):
    // hold releases while `scroll_save` remains armed and restores offset = 18 on Phase 2.
    env.rewindDeadlinesMs(1000);
    try testing.expect(!env.handler().postResizeHoldIsActive());
    try testing.expect(!env.terminal.modes.get(.synchronized_output));
    try testing.expect(env.handler().postResizeIsActive());
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H");
    try env.writeLines(60);
    env.stream.nextSlice("prompt\x1b[?2026l");
    try testing.expectEqual(@as(usize, 18), env.terminal.screens.active.pages.scrollbar().offset);

    // At +3500ms total, `postResizeIsActive()` expires.
    env.rewindDeadlinesMs(3500);
    try testing.expect(!env.handler().postResizeIsActive());

    // Closing the outer SSH context signal clears `in_remote_ssh_context`.
    env.stream.nextSlice("\x1b]3008;end=omg-ssh-1;exit=success;status=0\x07");
    try testing.expect(!env.handler().in_remote_ssh_context);
    try testing.expect(!env.handler().isRemoteSshSession());

    // `fullReset` also clears `in_remote_ssh_context`, while `remote_ssh_session` keeps remote windows.
    env.stream.nextSlice("\x1b]3008;start=omg-ssh-2;type=remote;targethost=cloud\x07");
    try testing.expect(env.handler().in_remote_ssh_context);
    try env.handler().fullReset();
    try testing.expect(!env.handler().in_remote_ssh_context);

    env.handler().remote_ssh_session = true;
    try testing.expect(env.handler().isRemoteSshSession());
    try env.resize(alloc, 40, 10, true);
    env.stream.nextSlice("\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    env.rewindDeadlinesMs(1500);
    try testing.expect(env.handler().postResizeHoldIsActive());
}

test "StreamHandler: noteActiveSynchronizedOutput renews every 250ms and caps at 15s" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env: PostResizeTestHarness = undefined;
    try env.init(alloc, 40, 10);
    defer env.deinit(alloc);

    // Opening DEC 2026 sets both timestamps and emits one `.start_synchronized_output`.
    env.stream.nextSlice("\x1b[?2026h");
    try testing.expect(env.handler().sync_output_started_at != null);
    try testing.expect(env.handler().sync_output_last_renewed_at != null);
    try testing.expectEqual(@as(?termio.Message, .{ .start_synchronized_output = {} }), env.termio_mailbox.spsc.queue.pop(global.io()));
    try testing.expect(env.termio_mailbox.spsc.queue.pop(global.io()) == null);

    const t0 = env.handler().sync_output_started_at.?;

    // < 250ms elapsed does not renew.
    env.handler().noteActiveSynchronizedOutput(t0.addDuration(.fromMilliseconds(200)));
    try testing.expect(env.termio_mailbox.spsc.queue.pop(global.io()) == null);

    // >= 250ms elapsed emits renewal and advances `sync_output_last_renewed_at`.
    const t1 = t0.addDuration(.fromMilliseconds(260));
    env.handler().noteActiveSynchronizedOutput(t1);
    try testing.expectEqual(@as(?termio.Message, .{ .start_synchronized_output = {} }), env.termio_mailbox.spsc.queue.pop(global.io()));
    try testing.expect(env.termio_mailbox.spsc.queue.pop(global.io()) == null);
    try testing.expectEqual(t1.nanoseconds, env.handler().sync_output_last_renewed_at.?.nanoseconds);

    // Redundant DECSET 2026 while already genuinely active MUST NOT reset `sync_output_started_at`.
    env.stream.nextSlice("\x1b[?2026h");
    try testing.expectEqual(t0.nanoseconds, env.handler().sync_output_started_at.?.nanoseconds);
    _ = env.termio_mailbox.spsc.queue.pop(global.io());

    // >= `sync_active_max_ms` (15_000ms) stops renewing.
    env.handler().noteActiveSynchronizedOutput(t0.addDuration(.fromMilliseconds(StreamHandler.sync_active_max_ms)));
    try testing.expect(env.termio_mailbox.spsc.queue.pop(global.io()) == null);

    // Closing DEC 2026 clears timestamps.
    env.stream.nextSlice("\x1b[?2026l");
    try testing.expect(env.handler().sync_output_started_at == null);
    try testing.expect(env.handler().sync_output_last_renewed_at == null);

    // While `tui_wipe_hold.held_sync_output` is active, `noteActiveSynchronizedOutput` must not renew.
    env.stream.nextSlice("\x1b[?2026h");
    try env.writeLines(30);
    env.stream.nextSlice("\x1b[?2026l\x1b[?2026h\x1b[2J\x1b[3J\x1b[H? for shortcuts\x1b[?2026l");
    while (env.termio_mailbox.spsc.queue.pop(global.io())) |msg| msg.deinit();
    try testing.expect(env.handler().tui_wipe_hold.held_sync_output);
    env.handler().noteActiveSynchronizedOutput(std.Io.Timestamp.now(testing.io, .awake).addDuration(.fromMilliseconds(500)));
    try testing.expect(env.termio_mailbox.spsc.queue.pop(global.io()) == null);

    // `fullReset` clears timestamps as well.
    env.stream.nextSlice("\x1b[?2026h");
    try env.handler().fullReset();
    try testing.expect(env.handler().sync_output_started_at == null);
    try testing.expect(env.handler().sync_output_last_renewed_at == null);
}

/// Returns the raw (percent-decoded) host of an OSC 7 URI.
///
/// This deliberately does not check that the host is a valid RFC 1123
/// hostname. The host only has to match the local hostname (see
/// `internal_os.hostname.isLocal`), and local hostnames are often not
/// valid RFC 1123 hostnames: macOS allows names like "Foo's MacBook Pro",
/// some systems use underscores, and some report a MAC address.
fn osc7Host(
    uri: std.Uri,
    buffer: *[std.Io.net.HostName.max_len]u8,
) error{ UriMissingHost, NameTooLong }![]const u8 {
    const component = uri.host orelse return error.UriMissingHost;
    return component.toRaw(buffer) catch |err| switch (err) {
        error.NoSpaceLeft => error.NameTooLong,
    };
}

test "osc7Host accepts hostnames that are not RFC 1123" {
    const testing = std.testing;

    const Case = struct {
        url: []const u8,
        host: []const u8,
        mac_address: bool = false,
    };
    const cases = [_]Case{
        .{ .url = "kitty-shell-cwd://Foo MacBook Pro/tmp", .host = "Foo MacBook Pro" },
        .{ .url = "file://Foo's MacBook Pro/tmp", .host = "Foo's MacBook Pro" },
        .{ .url = "file://my_host/tmp", .host = "my_host" },
        .{ .url = "file://h%C3%B6st/tmp", .host = "höst" },
        .{ .url = "file://example.com/tmp", .host = "example.com" },
        .{
            .url = "file://12:34:56:78:90:aa/tmp",
            .host = "12:34:56:78:90:aa",
            .mac_address = true,
        },
    };

    for (cases) |case| {
        const uri = try internal_os.uri.parse(case.url, .{
            .mac_address = case.mac_address,
            .raw_path = std.mem.startsWith(u8, case.url, "kitty-shell-cwd://"),
        });
        var buf: [std.Io.net.HostName.max_len]u8 = undefined;
        try testing.expectEqualStrings(case.host, try osc7Host(uri, &buf));
    }
}

test "osc7Host requires a host" {
    const testing = std.testing;

    const uri = try internal_os.uri.parse("file:///tmp", .{});
    var buf: [std.Io.net.HostName.max_len]u8 = undefined;
    try testing.expectError(error.UriMissingHost, osc7Host(uri, &buf));
}

test "kitty clipboard read: targets-only never consumes a one-time grant" {
    const testing = std.testing;

    var handler: StreamHandler = undefined;
    handler.alloc = testing.allocator;
    handler.kitty_clipboard_grants = .{};
    defer handler.kitty_clipboard_grants.deinit(testing.allocator);
    try handler.kitty_clipboard_grants.grant(testing.allocator, "otp", .read, true);

    // A listing request must not burn the one-time paste password...
    try testing.expect(!handler.kittyClipboardReadGranted("otp", 0));
    // ...so the follow-up data read is still granted, exactly once.
    try testing.expect(handler.kittyClipboardReadGranted("otp", 1));
    try testing.expect(!handler.kittyClipboardReadGranted("otp", 1));
}

test "kitty clipboard write: oversized text replies EFBIG" {
    const testing = std.testing;

    var mailbox = try termio.Mailbox.initSPSC(testing.allocator);
    defer mailbox.deinit(testing.allocator);

    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(global.io());
    defer mutex.unlock(global.io());

    var renderer_state: renderer.State = .{
        .mutex = &mutex,
        .terminal = undefined,
    };
    var handler: StreamHandler = undefined;
    handler.alloc = testing.allocator;
    handler.termio_mailbox = &mailbox;
    handler.renderer_state = &renderer_state;
    handler.clipboard_write = .allow;
    handler.clipboard_write_limit = 4;
    handler.kitty_clipboard_write = null;
    defer handler.kittyClipboardWriteAbort();

    const begin: terminal.kitty.clipboard.Metadata = .{
        .op = .write,
        .id = "macos",
    };
    try handler.kittyClipboardWriteBegin(&begin, .st);
    const state = handler.kitty_clipboard_write.?;
    try state.data(
        testing.allocator,
        &.{ .op = .wdata, .mime = "text/plain" },
        "SGVsbA==", // "Hell"
    );
    try testing.expectError(error.TooLarge, state.data(
        testing.allocator,
        &.{ .op = .wdata, .mime = "text/plain" },
        "bw==", // "o"
    ));
    try handler.kittyClipboardWriteFinish(state, .EFBIG, .st);
    try testing.expect(handler.kitty_clipboard_write == null);

    const response = mailbox.spsc.queue.pop(global.io());
    try testing.expect(response != null);
    const msg = response.?;
    defer msg.deinit();
    switch (msg) {
        .write_alloc => |v| try testing.expectEqualStrings(
            "\x1B]5522;type=write:status=EFBIG:id=macos\x1B\\",
            v.data,
        ),
        else => try testing.expect(false),
    }

    // Teardown leaves no transaction that could be committed and
    // forwarded to the macOS clipboard path.
    try testing.expect(mailbox.spsc.queue.pop(global.io()) == null);
}

test "tmux active_window notification is handled" {
    if (comptime !StreamHandler.tmux_enabled) return error.SkipZigTest;

    const testing = std.testing;

    var mailbox = try termio.Mailbox.initSPSC(testing.allocator);
    defer mailbox.deinit(testing.allocator);

    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(global.io());
    defer mutex.unlock(global.io());

    var renderer_state: renderer.State = .{
        .mutex = &mutex,
        .terminal = undefined,
    };
    var handler: StreamHandler = undefined;
    handler.alloc = testing.allocator;
    handler.termio_mailbox = &mailbox;
    handler.renderer_state = &renderer_state;
    handler.termio_messaged = false;
    handler.tmux_viewer = null;
    defer if (handler.tmux_viewer) |viewer| {
        viewer.deinit();
        testing.allocator.destroy(viewer);
        handler.tmux_viewer = null;
    };

    var enter_cmd: terminal.dcs.Command = .{ .tmux = .enter };
    try handler.dcsCommand(&enter_cmd);
    try testing.expect(handler.tmux_viewer != null);

    var startup: terminal.dcs.Command = .{ .tmux = .{ .block_end = "" } };
    try handler.dcsCommand(&startup);

    var session: terminal.dcs.Command = .{ .tmux = .{
        .session_changed = .{ .id = 7, .name = "main" },
    } };
    try handler.dcsCommand(&session);
    try testing.expect(handler.termio_messaged);
    if (mailbox.spsc.queue.pop(global.io())) |msg| msg.deinit();

    // %session-window-changed for our session reaches the active_window
    // arm. That arm does not write to the PTY.
    handler.termio_messaged = false;
    var changed: terminal.dcs.Command = .{ .tmux = .{
        .session_window_changed = .{ .session_id = 7, .window_id = 3 },
    } };
    try handler.dcsCommand(&changed);
    try testing.expect(!handler.termio_messaged);
    try testing.expect(mailbox.spsc.queue.pop(global.io()) == null);
    try testing.expect(handler.tmux_viewer != null);

    // Other sessions and pane changes must not write either.
    var other: terminal.dcs.Command = .{ .tmux = .{
        .session_window_changed = .{ .session_id = 99, .window_id = 1 },
    } };
    try handler.dcsCommand(&other);
    var pane: terminal.dcs.Command = .{ .tmux = .{
        .window_pane_changed = .{ .window_id = 3, .pane_id = 1 },
    } };
    try handler.dcsCommand(&pane);
    try testing.expect(!handler.termio_messaged);
    try testing.expect(mailbox.spsc.queue.pop(global.io()) == null);
}

test "StreamHandler: osc26Payload filters OSC 26, truncation, and unknown OSCs" {
    const testing = std.testing;

    try testing.expectEqualStrings(
        "CodeAgent=Claude;Status=running",
        StreamHandler.osc26Payload(.{
            .content = "26;CodeAgent=Claude;Status=running",
            .truncated = false,
            .terminator = .bel,
        }).?,
    );

    // Truncated OSC 26 payloads must be dropped.
    try testing.expect(StreamHandler.osc26Payload(.{
        .content = "26;CodeAgent=Claude;Status=running",
        .truncated = true,
        .terminator = .bel,
    }) == null);

    // Empty OSC 26 payloads must be dropped.
    try testing.expect(StreamHandler.osc26Payload(.{
        .content = "26;",
        .truncated = false,
        .terminator = .bel,
    }) == null);

    // Non-matching unknown OSC sequences (including prefix traps) are ignored.
    try testing.expect(StreamHandler.osc26Payload(.{
        .content = "260;CodeAgent=Claude;Status=running",
        .truncated = false,
        .terminator = .bel,
    }) == null);
    try testing.expect(StreamHandler.osc26Payload(.{
        .content = "88;cmd=claude",
        .truncated = false,
        .terminator = .st,
    }) == null);
    try testing.expect(StreamHandler.osc26Payload(.{
        .content = "7400;status=busy",
        .truncated = false,
        .terminator = .bel,
    }) == null);
}

test "StreamHandler: terminal.Stream osc_unknown_max_bytes forwards OSC 26 and drops oversized/other" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Recorder = struct {
        forwarded: std.ArrayList([]u8) = .empty,
        alloc: Allocator,

        pub fn deinit(self: *@This()) void {
            for (self.forwarded.items) |item| self.alloc.free(item);
            self.forwarded.deinit(self.alloc);
        }

        pub fn vt(
            self: *@This(),
            comptime action: terminal.StreamAction.Tag,
            value: terminal.StreamAction.Value(action),
        ) void {
            switch (action) {
                .osc_unknown => {
                    if (StreamHandler.osc26Payload(value)) |payload| {
                        const copy = self.alloc.dupe(u8, payload) catch unreachable;
                        self.forwarded.append(self.alloc, copy) catch unreachable;
                    }
                },
                else => {},
            }
        }
    };

    var stream: terminal.Stream(Recorder) = .init(.{
        .allocator = alloc,
        .handler = .{ .alloc = alloc },
        .osc_unknown_max_bytes = StreamHandler.osc_unknown_max_bytes,
    });
    defer stream.deinit();

    // Valid BEL and ST terminated OSC 26 sequences are forwarded.
    stream.nextSlice("\x1b]26;CodeAgent=Claude;Status=running;SessionId=sess_1\x07");
    stream.nextSlice("\x1b]26;CodeAgent=Codex;Status=idle\x1b\\");

    // Non-OSC-26 unknown sequence is ignored.
    stream.nextSlice("\x1b]7400;status=busy\x07");

    // Oversized (> 4096 bytes) OSC 26 sequence is marked truncated and dropped.
    const oversized_len = StreamHandler.osc_unknown_max_bytes + 32;
    const oversized = try alloc.alloc(u8, oversized_len);
    defer alloc.free(oversized);
    @memset(oversized, 'a');
    stream.nextSlice("\x1b]26;CodeAgent=Claude;Status=running;Title=");
    stream.nextSlice(oversized);
    stream.nextSlice("\x07");

    try testing.expectEqual(@as(usize, 2), stream.handler.forwarded.items.len);
    try testing.expectEqualStrings(
        "CodeAgent=Claude;Status=running;SessionId=sess_1",
        stream.handler.forwarded.items[0],
    );
    try testing.expectEqualStrings(
        "CodeAgent=Codex;Status=idle",
        stream.handler.forwarded.items[1],
    );

    // StreamHandler.vt(.osc_unknown, ...) ignores truncated and non-26 payloads
    // without dispatching to surface_mailbox.
    var handler: StreamHandler = undefined;
    handler.surface_mailbox = undefined;
    handler.vt(.osc_unknown, .{
        .content = "26;CodeAgent=Claude;Status=running",
        .truncated = true,
        .terminator = .bel,
    });
    handler.vt(.osc_unknown, .{
        .content = "7400;status=busy",
        .truncated = false,
        .terminator = .bel,
    });
}
