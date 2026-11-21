//! Bounded command records captured from OSC 133 input, never keyboard events.
const Self = @This();
const std = @import("std");
const PageList = @import("PageList.zig");
const Selection = @import("Selection.zig");
const page = @import("page.zig");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    id: u64,
    pin: *PageList.Pin,
    end_pin: *PageList.Pin,
    end_inclusive: bool,
    text: [:0]const u8,
    /// Owner-validated occurrence ID from a restored VT snapshot.
    replay_key: ?[:0]const u8 = null,
    timestamp: i64,
    /// Exit status reported by `OSC 133;D`; null while running, or when the
    /// shell ended the command without reporting one.
    exit_code: ?u8 = null,
    /// Wall time between `OSC 133;C` and `OSC 133;D`; null while running.
    duration_ms: ?u64 = null,
    superseded: bool = false,

    pub fn isValid(self: Entry) bool {
        if (self.superseded or self.pin.garbage or self.end_pin.garbage) return false;
        // A clear/overwrite can erase cells without pruning their page.
        return self.pin.rowAndCell().cell.semantic_content == .input;
    }
};
entries: std.ArrayList(Entry) = .empty,
input: ?*PageList.Pin = null,
input_key: ?[:0]const u8 = null,
/// The entry whose output is in progress, awaiting `OSC 133;D`.
running: ?Running = null,
next_id: u64 = 1,

pub const Running = struct {
    id: u64,
    started_ms: i64,
};

pub fn deinit(self: *Self, alloc: Allocator, pages: *PageList) void {
    if (self.input) |pin| pages.untrackPin(pin);
    if (self.input_key) |key| alloc.free(key);
    for (self.entries.items) |entry| {
        pages.untrackPin(entry.pin);
        pages.untrackPin(entry.end_pin);
        alloc.free(entry.text);
        if (entry.replay_key) |key| alloc.free(key);
    }
    self.entries.deinit(alloc);
    // IDs must not be reused after terminal reset.
    self.* = .{ .next_id = self.next_id };
}

pub fn begin(self: *Self, alloc: Allocator, pages: *PageList, cursor: PageList.Pin, aid: ?[]const u8) !void {
    // A new input at a reused coordinate is a new occurrence, even if it has
    // identical text and the cells are once again marked as `.input`.
    for (self.entries.items) |*entry| {
        if (entry.pin.eql(cursor)) entry.superseded = true;
    }
    // A continuation prompt may send another B; retain the original input start.
    if (self.input) |pin| {
        if (!pin.garbage and pin.before(cursor) and
            cursor.rowAndCell().row.semantic_prompt == .prompt_continuation) return;
    }
    if (self.input) |pin| pages.untrackPin(pin);
    if (self.input_key) |key| alloc.free(key);
    self.input = null;
    self.input_key = null;
    const replay_key: ?[:0]const u8 = if (aid) |value| key: {
        const prefix = "omg:";
        if (!std.mem.startsWith(u8, value, prefix)) break :key null;
        const id = value[prefix.len..];
        if (id.len == 0 or id.len > 256 or !std.ascii.isAlphanumeric(id[0])) break :key null;
        for (id) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != ':') break :key null;
        }
        break :key try alloc.dupeSentinel(u8, id, 0);
    } else null;
    errdefer if (replay_key) |key| alloc.free(key);
    self.input = try pages.trackPin(cursor);
    self.input_key = replay_key;
}

pub fn finish(self: *Self, alloc: Allocator, pages: *PageList, cursor: PageList.Pin, pending_wrap: bool, reported_text: ?[]const u8, now_ms: i64) !void {
    // A later `D` must never complete an earlier execution, including when
    // this input turns out to be empty or unrecordable.
    self.running = null;
    const timestamp = @divFloor(now_ms, std.time.ms_per_s);
    const start = self.input orelse return;
    self.input = null;
    var replay_key = self.input_key;
    self.input_key = null;
    defer {
        pages.untrackPin(start);
        if (replay_key) |key| alloc.free(key);
    }
    if (start.garbage or !(start.before(cursor) or (pending_wrap and start.eql(cursor)))) return;
    for (self.entries.items) |*entry| {
        if (!entry.pin.garbage and
            (entry.pin.eql(start.*) or start.before(entry.pin.*)) and
            (entry.pin.before(cursor) or (pending_wrap and entry.pin.eql(cursor))))
        {
            entry.superseded = true;
        }
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    const reported = if (reported_text) |value| reported: {
        const cleaned = std.mem.trim(u8, value, " \t\r\n");
        if (cleaned.len == 0 or cleaned.len > 16384 or
            !std.unicode.utf8ValidateSlice(cleaned) or
            std.mem.indexOfScalar(u8, cleaned, 0) != null) break :reported null;
        break :reported cleaned;
    } else null;
    var positions: std.ArrayList(PageList.Pin) = .empty;
    defer positions.deinit(alloc);
    var it = start.cellIterator(.right_down, cursor);
    var count: usize = 0;
    var overflow = false;
    while (it.next()) |pin| {
        // With delayed wrapping, the cursor is still on the last printed cell.
        if (pin.eql(cursor) and !pending_wrap) break;
        count += 1;
        if (count > 16384 or text.items.len > 16384) {
            if (reported == null) return; // Never publish truncated input as exact text.
            overflow = true;
            break;
        }
        const rac = pin.rowAndCell();
        if (pin.x == 0 and !pin.eql(start.*) and !rac.row.wrap_continuation) {
            try text.append(alloc, '\n');
            try positions.append(alloc, pin);
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
        try positions.appendNTimes(alloc, pin, len);
        if (pin.grapheme(rac.cell)) |extra| for (extra) |value| {
            const n = std.unicode.utf8Encode(value, &bytes) catch continue;
            try text.appendSlice(alloc, bytes[0..n]);
            try positions.appendNTimes(alloc, pin, n);
        };
        if (text.items.len > 16384) {
            if (reported == null) return;
            overflow = true;
            break;
        }
    }
    const trimmed = reported orelse std.mem.trim(u8, text.items, " \t\r\n");
    if (trimmed.len == 0) return;
    const copy = try alloc.dupeSentinel(u8, trimmed, 0);
    errdefer alloc.free(copy);
    // Fish's submitted command identifies a suffix of this single OSC 133
    // input region, even when Starship redrew prompt decoration after B.
    // This is bounded to this execution; it never searches the scrollback.
    const position = position: {
        if (reported) |command| {
            if (!overflow and std.mem.endsWith(u8, text.items, command)) {
                const index = text.items.len - command.len;
                if (index < positions.items.len) {
                    const candidate = positions.items[index];
                    if (candidate.rowAndCell().cell.semantic_content == .input) {
                        break :position candidate;
                    }
                }
            }
        }
        break :position start.*;
    };
    const anchor = try pages.trackPin(position);
    errdefer pages.untrackPin(anchor);
    const end_anchor = try pages.trackPin(cursor);
    errdefer pages.untrackPin(end_anchor);
    try self.entries.append(alloc, .{
        .id = self.next_id,
        .pin = anchor,
        .end_pin = end_anchor,
        .end_inclusive = pending_wrap,
        .text = copy,
        .replay_key = replay_key,
        .timestamp = timestamp,
    });
    replay_key = null; // Ownership transferred to the recorded entry.
    self.running = .{ .id = self.next_id, .started_ms = now_ms };
    self.next_id += 1;
    if (self.entries.items.len > 100) {
        const old = self.entries.orderedRemove(0);
        pages.untrackPin(old.pin);
        pages.untrackPin(old.end_pin);
        alloc.free(old.text);
        if (old.replay_key) |key| alloc.free(key);
    }
}

/// Records the outcome of the execution started by the last `finish`.
/// A `D` without a preceding recorded command (an empty prompt, a redraw,
/// or a second `D`) changes nothing.
pub fn complete(self: *Self, exit_code: ?u8, now_ms: i64) void {
    const running = self.running orelse return;
    self.running = null;
    for (self.entries.items) |*entry| {
        if (entry.id != running.id) continue;
        entry.exit_code = exit_code;
        entry.duration_ms = @intCast(@max(0, now_ms - running.started_ms));
        return;
    }
}

fn sameRow(a: PageList.Pin, b: PageList.Pin) bool {
    return a.node == b.node and a.y == b.y;
}

/// Returns the untracked output selection for a recorded command execution.
/// Pass `id == 0` to select the output of the most recent valid command.
/// Returns `null` if the command does not exist, is invalid, or produced no
/// non-whitespace/text output cells.
pub fn outputSelection(self: *const Self, pages: *const PageList, id: u64) ?Selection {
    const items = self.entries.items;
    const entry_index: usize = blk: {
        if (id == 0) {
            var idx = items.len;
            while (idx > 0) {
                idx -= 1;
                if (items[idx].isValid()) break :blk idx;
            }
            return null;
        }
        for (items, 0..) |entry, idx| {
            if (entry.id == id and entry.isValid()) break :blk idx;
        }
        return null;
    };

    const entry = items[entry_index];
    const bottom = pages.getBottomRight(.screen) orelse return null;
    var limit = bottom;
    for (items[entry_index + 1 ..]) |later| {
        if (later.pin.garbage) continue;
        if (entry.pin.before(later.pin.*)) {
            limit = later.pin.*;
            break;
        }
    }

    var start: PageList.Pin = undefined;
    var end: PageList.Pin = undefined;
    var found = false;
    var passed_input = !entry.end_inclusive;

    var it = entry.end_pin.cellIterator(.right_down, limit);
    while (it.next()) |pin| {
        if (!limit.eql(bottom) and pin.eql(limit)) break;

        if (!passed_input) {
            passed_input = true;
            continue;
        }

        const rac = pin.rowAndCell();
        if (!sameRow(pin, entry.end_pin.*) and !sameRow(pin, entry.pin.*) and rac.row.semantic_prompt != .none) {
            break;
        }

        switch (rac.cell.semantic_content) {
            .prompt => break,
            .input => {
                if (pin.eql(entry.end_pin.*)) continue;
                break;
            },
            .output => {
                if (!rac.cell.hasText()) continue;
                if (!found) {
                    start = pin;
                    end = pin;
                    found = true;
                } else {
                    end = pin;
                }
            },
        }
    }

    if (!found) return null;
    return Selection.init(start, end, false);
}

/// Reconstructs bounded `OSC 133` command history entries (and any active
/// unsubmitted input anchor) from a decoded VT snapshot's semantic cells.
/// Preserves timestamps and replay keys from `previous` when matching tail
/// occurrences exist during an in-process session restore.
pub fn rebuildFromSemanticPages(
    self: *Self,
    alloc: Allocator,
    pages: *PageList,
    cursor_pin: PageList.Pin,
    cursor_semantic_content: page.Cell.SemanticContent,
    previous: ?*const Self,
    fallback_timestamp: i64,
) !void {
    self.deinit(alloc, pages);
    if (previous) |prev| {
        if (prev.next_id > self.next_id) self.next_id = prev.next_id;
    }

    const Candidate = struct {
        start: PageList.Pin,
        end: PageList.Pin,
        end_inclusive: bool,
        text: [:0]u8,
        followed_by_output_or_prompt: bool = false,
    };

    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |item| alloc.free(item.text);
        candidates.deinit(alloc);
    }

    if (pages.getBottomRight(.screen)) |bottom| {
        const top = pages.getTopLeft(.screen);
        var current_start: ?PageList.Pin = null;
        var current_last_input: PageList.Pin = undefined;
        var pending_end: ?PageList.Pin = null;
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(alloc);
        var overflow = false;
        // The live path anchors a command at its `OSC 133;B`. A snapshot only
        // keeps cell marks, and text printed while the cursor was still in
        // input state carries the same mark: a job notice at an idle prompt,
        // or a banner written after a restore. Such a run starts on a row of
        // its own, so only input that begins at a prompt is a command. A
        // prompt whose last line is empty looks the same in cells and is not
        // rebuilt either; the host still shows its saved record, read-only.
        var row_has_prompt_cell = false;
        var unanchored_run = false;

        const commitCurrent = struct {
            fn call(
                alloc_: Allocator,
                list: *std.ArrayList(Candidate),
                buf: *std.ArrayList(u8),
                start_opt: *?PageList.Pin,
                pending_end_opt: *?PageList.Pin,
                overflow_flag: *bool,
                end_pin: PageList.Pin,
                end_inclusive: bool,
                followed: bool,
            ) !void {
                const start_pin = start_opt.* orelse return;
                defer {
                    start_opt.* = null;
                    pending_end_opt.* = null;
                    buf.clearRetainingCapacity();
                    overflow_flag.* = false;
                }
                if (overflow_flag.*) return;
                const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
                if (trimmed.len == 0) return;
                const copy = try alloc_.dupeSentinel(u8, trimmed, 0);
                errdefer alloc_.free(copy);
                try list.append(alloc_, .{
                    .start = start_pin,
                    .end = end_pin,
                    .end_inclusive = end_inclusive,
                    .text = copy,
                    .followed_by_output_or_prompt = followed,
                });
            }
        }.call;

        var it = top.cellIterator(.right_down, bottom);
        while (it.next()) |pin| {
            const rac = pin.rowAndCell();

            if (pin.x == 0) {
                row_has_prompt_cell = false;
                if (rac.row.semantic_prompt == .prompt) unanchored_run = false;
            }

            if (current_start != null and pin.x == 0 and !rac.row.wrap_continuation) {
                if (rac.row.semantic_prompt == .prompt) {
                    try commitCurrent(
                        alloc,
                        &candidates,
                        &text_buf,
                        &current_start,
                        &pending_end,
                        &overflow,
                        pending_end orelse current_last_input,
                        pending_end == null,
                        true,
                    );
                } else if (pending_end != null and rac.row.semantic_prompt != .prompt_continuation) {
                    try commitCurrent(
                        alloc,
                        &candidates,
                        &text_buf,
                        &current_start,
                        &pending_end,
                        &overflow,
                        pending_end.?,
                        false,
                        rac.cell.semantic_content == .prompt or (rac.cell.semantic_content == .output and rac.cell.hasText()),
                    );
                }
            }

            switch (rac.cell.semantic_content) {
                .input => {
                    if (current_start == null) {
                        if (unanchored_run) continue;
                        if (rac.row.semantic_prompt != .prompt and !row_has_prompt_cell) {
                            unanchored_run = true;
                            continue;
                        }
                        current_start = pin;
                        pending_end = null;
                        text_buf.clearRetainingCapacity();
                        overflow = false;
                    } else if (pending_end != null) {
                        pending_end = null;
                    }

                    if (!overflow) {
                        if (pin.x == 0 and !pin.eql(current_start.?) and !rac.row.wrap_continuation) {
                            try text_buf.append(alloc, '\n');
                        }
                        switch (rac.cell.wide) {
                            .spacer_head, .spacer_tail => {},
                            else => {
                                var bytes: [4]u8 = undefined;
                                const cp = rac.cell.codepoint();
                                if (std.unicode.utf8Encode(if (cp == 0) ' ' else cp, &bytes)) |len| {
                                    try text_buf.appendSlice(alloc, bytes[0..len]);
                                    if (pin.grapheme(rac.cell)) |extra| for (extra) |value| {
                                        if (std.unicode.utf8Encode(value, &bytes)) |n| {
                                            try text_buf.appendSlice(alloc, bytes[0..n]);
                                        } else |_| {}
                                    };
                                } else |_| {}
                            },
                        }
                        if (text_buf.items.len > 16384) overflow = true;
                    }
                    current_last_input = pin;
                },
                .prompt => {
                    row_has_prompt_cell = true;
                    unanchored_run = false;
                    if (current_start != null) {
                        if (rac.row.semantic_prompt == .prompt_continuation) {
                            pending_end = null;
                        } else {
                            try commitCurrent(
                                alloc,
                                &candidates,
                                &text_buf,
                                &current_start,
                                &pending_end,
                                &overflow,
                                pending_end orelse pin,
                                false,
                                true,
                            );
                        }
                    } else if (candidates.items.len > 0) {
                        candidates.items[candidates.items.len - 1].followed_by_output_or_prompt = true;
                    }
                },
                .output => {
                    if (rac.cell.hasText()) unanchored_run = false;
                    if (current_start != null) {
                        if (rac.cell.hasText()) {
                            try commitCurrent(
                                alloc,
                                &candidates,
                                &text_buf,
                                &current_start,
                                &pending_end,
                                &overflow,
                                pending_end orelse pin,
                                false,
                                true,
                            );
                        } else if (pending_end == null) {
                            pending_end = pin;
                        }
                    } else if (rac.cell.hasText() and candidates.items.len > 0) {
                        candidates.items[candidates.items.len - 1].followed_by_output_or_prompt = true;
                    }
                },
            }
        }

        if (current_start != null) {
            try commitCurrent(
                alloc,
                &candidates,
                &text_buf,
                &current_start,
                &pending_end,
                &overflow,
                pending_end orelse current_last_input,
                pending_end == null,
                false,
            );
        }
    }

    // If the cursor is currently in `.input` state, an unsubmitted command at the
    // active prompt must remain `self.input` rather than appearing as executed.
    var active_input_pin: ?PageList.Pin = if (cursor_semantic_content == .input) cursor_pin else null;
    if (cursor_semantic_content == .input and candidates.items.len > 0) {
        const last = candidates.items[candidates.items.len - 1];
        if (!last.followed_by_output_or_prompt and (last.start.before(cursor_pin) or last.start.eql(cursor_pin))) {
            active_input_pin = last.start;
            const popped = candidates.pop().?;
            alloc.free(popped.text);
        }
    }

    const slice = if (candidates.items.len > 100)
        candidates.items[candidates.items.len - 100 ..]
    else
        candidates.items;

    // Match previous valid entries from the tail when commands align so IDs,
    // timestamps, and replay keys survive in-process snapshot restores.
    var prev_valid: std.ArrayList(Entry) = .empty;
    defer prev_valid.deinit(alloc);
    if (previous) |prev| {
        for (prev.entries.items) |entry| {
            if (!entry.superseded) try prev_valid.append(alloc, entry);
        }
    }

    const matched_tail: usize = blk: {
        var count: usize = 0;
        while (count < slice.len and count < prev_valid.items.len) {
            const cand = slice[slice.len - 1 - count];
            const prev_entry = prev_valid.items[prev_valid.items.len - 1 - count];
            if (!std.mem.eql(u8, cand.text, prev_entry.text)) break;
            count += 1;
        }
        break :blk count;
    };

    const unmatched_len = slice.len - matched_tail;
    for (slice, 0..) |cand, idx| {
        const anchor = try pages.trackPin(cand.start);
        errdefer pages.untrackPin(anchor);
        const end_anchor = try pages.trackPin(cand.end);
        errdefer pages.untrackPin(end_anchor);
        const copy = try alloc.dupeSentinel(u8, cand.text, 0);
        errdefer alloc.free(copy);

        if (idx >= unmatched_len) {
            const prev_idx = prev_valid.items.len - matched_tail + (idx - unmatched_len);
            const prev_entry = prev_valid.items[prev_idx];
            const replay_copy: ?[:0]const u8 = if (prev_entry.replay_key) |k|
                try alloc.dupeSentinel(u8, k, 0)
            else
                null;
            errdefer if (replay_copy) |k| alloc.free(k);
            const id = prev_entry.id;
            if (id >= self.next_id) self.next_id = id + 1;
            try self.entries.append(alloc, .{
                .id = id,
                .pin = anchor,
                .end_pin = end_anchor,
                .end_inclusive = cand.end_inclusive,
                .text = copy,
                .replay_key = replay_copy,
                .timestamp = prev_entry.timestamp,
                .exit_code = prev_entry.exit_code,
                .duration_ms = prev_entry.duration_ms,
            });
        } else {
            const id = self.next_id;
            self.next_id += 1;
            try self.entries.append(alloc, .{
                .id = id,
                .pin = anchor,
                .end_pin = end_anchor,
                .end_inclusive = cand.end_inclusive,
                .text = copy,
                .timestamp = fallback_timestamp,
            });
        }
    }

    if (active_input_pin) |pin| {
        self.input = try pages.trackPin(pin);
    }

    // A restore in the middle of a command keeps waiting for its `D`.
    if (previous) |prev| {
        if (prev.running) |running| {
            for (self.entries.items) |entry| {
                if (entry.id == running.id) self.running = running;
            }
        }
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

test "OMG command history records exit status and duration for its own execution only" {
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 12 });
    defer t.deinit(alloc);
    const history = &t.screens.active.omg_command_history;

    // A `D` before any command is ignored.
    history.complete(7, 1_000);
    try std.testing.expectEqual(@as(usize, 0), history.entries.items.len);

    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try t.printString("$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try t.printString("false");
    try t.semanticPrompt(.init(.end_input_start_output));
    try t.linefeed();
    t.carriageReturn();
    try std.testing.expect(history.running != null);
    try std.testing.expectEqual(@as(?u8, null), history.entries.items[0].exit_code);
    try std.testing.expectEqual(@as(?u64, null), history.entries.items[0].duration_ms);

    const started = history.running.?.started_ms;
    history.complete(1, started + 2_500);
    try std.testing.expectEqual(@as(?u8, 1), history.entries.items[0].exit_code);
    try std.testing.expectEqual(@as(?u64, 2_500), history.entries.items[0].duration_ms);

    // A repeated `D`, as after an empty prompt, never rewrites the outcome.
    history.complete(0, started + 9_000);
    try std.testing.expectEqual(@as(?u8, 1), history.entries.items[0].exit_code);
    try std.testing.expectEqual(@as(?u64, 2_500), history.entries.items[0].duration_ms);

    // An empty submission clears the pending execution instead of letting
    // its `D` complete the previous command.
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try t.printString("$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try t.printString("true");
    try t.semanticPrompt(.init(.end_input_start_output));
    try t.linefeed();
    t.carriageReturn();
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try t.printString("$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try t.semanticPrompt(.init(.end_input_start_output));
    try std.testing.expectEqual(@as(?Running, null), history.running);
    history.complete(3, started + 20_000);
    try std.testing.expectEqual(@as(usize, 2), history.entries.items.len);
    try std.testing.expectEqual(@as(?u8, null), history.entries.items[1].exit_code);

    // The terminal completes the running command from `OSC 133;D`, and a
    // clock that moves backwards never produces a negative duration.
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try t.printString("$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try t.printString("sleep 1");
    try t.semanticPrompt(.init(.end_input_start_output));
    try t.linefeed();
    t.carriageReturn();
    history.running.?.started_ms += 60_000;
    try t.semanticPrompt(.init(.end_command));
    try std.testing.expectEqual(@as(?Running, null), history.running);
    try std.testing.expectEqual(@as(?u8, null), history.entries.items[2].exit_code);
    try std.testing.expectEqual(@as(?u64, 0), history.entries.items[2].duration_ms);
}

test "OMG command history trusts a bounded Fish command line over a late prompt redraw" {
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 12 });
    defer t.deinit(alloc);
    for (0..4) |index| {
        try t.semanticPrompt(.init(.fresh_line_new_prompt));
        try t.printString("$ ");
        try t.semanticPrompt(.init(.end_prompt_start_input));
        if (index == 0) try t.printString("starship ~/very/long/path main 19:50 > ");
        try t.printString("ll");
        var output: @import("osc/parsers/semantic_prompt.zig").Command = .init(.end_input_start_output);
        output.options_unvalidated = "cmdline_url=ll";
        try t.semanticPrompt(output);
        try t.linefeed();
        t.carriageReturn();
    }
    const entries = t.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    for (entries, 0..) |entry, index| {
        try std.testing.expectEqualStrings("ll", entry.text);
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), entry.id);
        try std.testing.expect(entry.isValid());
    }
    // The first B happened before Starship redrew the prompt. The Shell's
    // reported command places the anchor at the actual input, not `$ `.
    try std.testing.expect(entries[0].pin.x > 2);
}

test "OMG command history parses four Fish OSC 133 executions with late Starship redraw" {
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 12 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    for (0..4) |index| {
        const prompt = if (index == 0) "starship ~/work main 19:50 > " else "";
        stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07");
        stream.nextSlice(prompt);
        stream.nextSlice("ll\x1b]133;C;cmdline_url=ll\x07\r\n");
    }
    const entries = t.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    for (entries) |entry| {
        try std.testing.expectEqualStrings("ll", entry.text);
        try std.testing.expect(entry.isValid());
    }
    try std.testing.expect(entries[0].pin.x > 2);
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

test "OMG command history rejects reused input coordinates" {
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 8 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try t.printString("ll");
    try t.semanticPrompt(.init(.end_input_start_output));
    t.carriageReturn();
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try t.printString("ll");
    try t.semanticPrompt(.init(.end_input_start_output));
    const entries = t.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(!entries[0].isValid());
    try std.testing.expect(entries[1].isValid());
    try std.testing.expect(entries[0].id != entries[1].id);
}

test "OMG command history from real SSH Fish 3.1 PTY output" {
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 120, .rows = 32 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(@embedFile("testdata/omg-shell/remote-fish.vt"));
    const records = t.screens.active.omg_command_history.entries.items;
    const commands = [_][]const u8{ "ll", "ll", "ll", "ll", "false", "false | true", "printf \"%s\\n\" \"one\ntwo\"" };
    try std.testing.expectEqual(commands.len, records.len);
    for (records, commands, 0..) |entry, text, index| {
        try std.testing.expectEqualStrings(text, entry.text);
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), entry.id);
        if (index < 4) try std.testing.expect(entry.isValid());
    }
}

test "OMG command history includes the final cell before delayed wrap" {
    const Terminal = @import("Terminal.zig");
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 4, .rows = 8 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try t.printString("abcd");
    try std.testing.expect(t.screens.active.cursor.pending_wrap);
    try t.semanticPrompt(.init(.end_input_start_output));
    try std.testing.expectEqualStrings("abcd", t.screens.active.omg_command_history.entries.items[0].text);
}

test "OMG command history extracts command output across shells and blank middle lines" {
    const Terminal = @import("Terminal.zig");
    const Formatter = @import("formatter.zig").ScreenFormatter;
    const alloc = std.testing.allocator;
    var t = try Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 16 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07printf 'first\\n\\nthird\\n'\x1b]133;C\x07\r\nfirst\r\n\r\nthird\r\n");
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07true\x1b]133;C\x07\r\n");
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07echo fish-line\r\n\x1b]133;C;cmdline_url=echo%20fish-line\x07fish-line\r\n\x1b]133;A\x07$ \x1b]133;B\x07");

    const screen = t.screens.active;
    const entries = screen.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 3), entries.len);

    // Specific command ID with blank internal line.
    const first_sel = screen.omg_command_history.outputSelection(&screen.pages, entries[0].id).?;
    var first_out: std.Io.Writer.Allocating = .init(alloc);
    defer first_out.deinit();
    var fmt1: Formatter = .init(screen, .{ .emit = .plain, .trim = true });
    fmt1.content = .{ .selection = first_sel };
    try fmt1.format(&first_out.writer);
    try std.testing.expectEqualStrings("first\n\nthird", first_out.written());

    // Command with zero output returns null.
    try std.testing.expect(screen.omg_command_history.outputSelection(&screen.pages, entries[1].id) == null);

    // `id == 0` selects the latest valid command's output (including Fish col-0 C).
    const latest_sel = screen.omg_command_history.outputSelection(&screen.pages, 0).?;
    var latest_out: std.Io.Writer.Allocating = .init(alloc);
    defer latest_out.deinit();
    var fmt3: Formatter = .init(screen, .{ .emit = .plain, .trim = true });
    fmt3.content = .{ .selection = latest_sel };
    try fmt3.format(&latest_out.writer);
    try std.testing.expectEqualStrings("fish-line", latest_out.written());
}

test "OMG command history rebuilds executed commands and active input from VT snapshot" {
    const Terminal = @import("Terminal.zig");
    const snapshot = @import("snapshot/main.zig");
    const Formatter = @import("formatter.zig").ScreenFormatter;
    const alloc = std.testing.allocator;

    var origin = try Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 12 });
    defer origin.deinit(alloc);
    var stream = origin.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07pwd\x1b]133;C\x07\r\n/Users/test/project\r\n");
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07ls -1\x1b]133;C\x07\r\nREADME.md\r\nsrc\r\n");
    // Leave an unsubmitted partial input at the active prompt before snapshotting!
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07git st");
    origin.screens.active.omg_command_history.entries.items[0].timestamp = 1700000100;
    origin.screens.active.omg_command_history.entries.items[1].timestamp = 1700000200;

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try snapshot.encode(alloc, &encoded.writer, &origin, .{ .continuation = .ground });

    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoded_state = try snapshot.decodeExact(alloc, std.testing.io, &reader, .{ .max_continuation_bytes = 0 });
    defer decoded_state.deinit(alloc);
    var restored = decoded_state.toOwned();
    defer restored.deinit(alloc);

    const restored_screen = restored.screens.get(.primary).?;
    try restored_screen.omg_command_history.rebuildFromSemanticPages(
        restored_screen.alloc,
        &restored_screen.pages,
        restored_screen.cursor.page_pin.*,
        restored_screen.cursor.semantic_content,
        &origin.screens.active.omg_command_history,
        1700000999,
    );

    const entries = restored_screen.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("pwd", entries[0].text);
    try std.testing.expectEqual(@as(i64, 1700000100), entries[0].timestamp);
    try std.testing.expectEqualStrings("ls -1", entries[1].text);
    try std.testing.expectEqual(@as(i64, 1700000200), entries[1].timestamp);
    try std.testing.expect(entries[0].isValid());
    try std.testing.expect(entries[1].isValid());

    const sel = restored_screen.omg_command_history.outputSelection(&restored_screen.pages, 0).?;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var fmt: Formatter = .init(restored_screen, .{ .emit = .plain, .trim = true });
    fmt.content = .{ .selection = sel };
    try fmt.format(&out.writer);
    try std.testing.expectEqualStrings("README.md\nsrc", out.written());

    // Completing the partial command after reattach records `git status`!
    var restored_stream = restored.vtStream();
    defer restored_stream.deinit();
    restored_stream.nextSlice("atus\x1b]133;C\x07\r\nOn branch main\r\n");
    try std.testing.expectEqual(@as(usize, 3), restored_screen.omg_command_history.entries.items.len);
    try std.testing.expectEqualStrings("git status", restored_screen.omg_command_history.entries.items[2].text);
}

test "OMG command history rebuild ignores input-marked text that does not begin at a prompt" {
    const Terminal = @import("Terminal.zig");
    const snapshot = @import("snapshot/main.zig");
    const alloc = std.testing.allocator;

    var origin = try Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 24 });
    defer origin.deinit(alloc);
    var stream = origin.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07pwd\x1b]133;C\x07\r\n/home/test\r\n");
    // An idle prompt, then the shell reports a finished background job. The
    // notice is printed while the cursor is still in input state.
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07");
    stream.nextSlice("\r\n[3]  + 2845666 done       { command -v tool &> /dev/null && tool \r\nupgrade }\r\n");
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07ls\x1b]133;C\x07\r\nREADME.md\r\n");
    // A second prompt line that carries its own prompt text still anchors
    // the input that follows it.
    stream.nextSlice("\x1b]133;A\x07~/project\r\n> \x1b]133;B\x07make\x1b]133;C\x07\r\nok\r\n");
    // A restore leaves the last prompt in input state; the banner and the
    // new shell's greeting are written before any new prompt marker.
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07");
    stream.nextSlice("\r\n  ------  Session resurrected after system restart  ------\r\n");
    stream.nextSlice("Last login: Sat Nov 21 08:21:03 on ttys001\r\n");
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07echo hi\x1b]133;C\x07\r\nhi\r\n");
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07git st");

    // The live path is anchored by the markers themselves.
    const live = origin.screens.active.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 4), live.len);

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try snapshot.encode(alloc, &encoded.writer, &origin, .{ .continuation = .ground });
    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoded_state = try snapshot.decodeExact(alloc, std.testing.io, &reader, .{ .max_continuation_bytes = 0 });
    defer decoded_state.deinit(alloc);
    var restored = decoded_state.toOwned();
    defer restored.deinit(alloc);

    const screen = restored.screens.get(.primary).?;
    try screen.omg_command_history.rebuildFromSemanticPages(
        screen.alloc,
        &screen.pages,
        screen.cursor.page_pin.*,
        screen.cursor.semantic_content,
        null,
        1700000999,
    );

    const entries = screen.omg_command_history.entries.items;
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("pwd", entries[0].text);
    try std.testing.expectEqualStrings("ls", entries[1].text);
    try std.testing.expectEqualStrings("make", entries[2].text);
    try std.testing.expectEqualStrings("echo hi", entries[3].text);

    // The unsubmitted input at the live prompt is still the active input.
    var restored_stream = restored.vtStream();
    defer restored_stream.deinit();
    restored_stream.nextSlice("atus\x1b]133;C\x07\r\nOn branch main\r\n");
    try std.testing.expectEqual(@as(usize, 5), screen.omg_command_history.entries.items.len);
    try std.testing.expectEqualStrings("git status", screen.omg_command_history.entries.items[4].text);
}
