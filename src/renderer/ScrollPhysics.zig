//! Continuous scroll position in row units.
//!
//! `position == 0` is the top of scrollback. `position == max_offset` is
//! pinned to the active bottom. Motion stays inside `[0, max_offset]`.
//!
//! Host scrollback only. Live PTY output while pinned snaps with no cap.
//! Alternate-screen and mouse reporting must not call these methods.

const std = @import("std");

const ScrollPhysics = @This();

/// Continuous offset into the scrollable range (rows from top of history).
position: f64 = 0,
/// Rows per second.
velocity: f64 = 0,
/// When true, stick to the bottom as new output arrives.
pinned_to_bottom: bool = true,

friction: f64 = 2,
/// Keybind impulse (`scroll_page_lines` and similar) → velocity scale.
impulse_scale: f64 = 4,
/// Decay for the active coast. Wheel and page use 3× `friction`;
/// key impulse uses `friction`.
coast_friction: f64 = 2,
/// Page-key coast. Settle snaps to a whole row so floor() is not 1 off.
page_coast: bool = false,
/// Discrete-wheel coast. Skips `visualCap`.
mouse_coast: bool = false,
/// Starting visual cap (rows/frame). Grows with `run_time` until unrestricted.
/// Key and jump seeks only; mouse/trackpad coasts ignore it.
max_rows_per_frame: f64 = 1.0,
/// Seconds for the cap to double. ~1.4s to pass 64 rows/frame.
accel_halflife: f64 = 0.2,

settle_pos: f64 = 0.02,
settle_vel: f64 = 0.05,
/// Absolute row offset to chase (`jump`). Same accelerating cap as
/// `seekExtreme`; null = not chasing a point.
seek_target: ?f64 = null,
/// Chase the live bottom until we arrive (`scroll_to_bottom`).
seek_follows_bottom: bool = false,
/// Chase the top of history until we arrive (`scroll_to_top`).
seek_follows_top: bool = false,
/// Seconds of continuous scrollback motion. Zero after a real stop.
run_time: f64 = 0,

/// Integer row for the PageList viewport (clamped into range).
pub fn integerRow(self: *const ScrollPhysics, max_offset: f64) u64 {
    const max_o = @max(0, max_offset);
    if (self.position <= 0) return 0;
    if (self.position >= max_o) return @intFromFloat(@floor(max_o));
    return @intFromFloat(@floor(self.position));
}

/// Fractional part in [0, 1). Pixel shift: `y += visualOffsetRows * cell_height`.
pub fn visualOffsetRows(self: *const ScrollPhysics, max_offset: f64) f64 {
    const max_o = @max(0, max_offset);
    const p = std.math.clamp(self.position, 0, max_o);
    const frac = p - @floor(p);
    return -frac;
}

/// Wheel impulse. Not visual-capped. Coasts about `delta_rows` at page
/// friction (3×). Positive `delta_rows` moves toward older history.
pub fn applyMouseImpulse(self: *ScrollPhysics, delta_rows: f64) void {
    self.impulse(delta_rows, true);
}

/// Trackpad/precision pan. Moves the viewport by `delta_rows` this event
/// (finger-down and OS momentum). Does not add our own coast.
pub fn applyMousePan(self: *ScrollPhysics, delta_rows: f64) void {
    if (@abs(delta_rows) < 1e-9) return;
    self.resetAccelIfChase();
    self.seek_target = null;
    self.seek_follows_bottom = false;
    self.seek_follows_top = false;
    self.pinned_to_bottom = false;
    self.page_coast = false;
    self.mouse_coast = true;
    self.position -= delta_rows;
    self.velocity = 0;
}

/// Keybind impulse (`scroll_page_lines` and similar). Visual-capped.
pub fn applyImpulse(self: *ScrollPhysics, delta_rows: f64) void {
    self.impulse(delta_rows, false);
}

fn impulse(self: *ScrollPhysics, delta_rows: f64, mouse: bool) void {
    if (@abs(delta_rows) < 1e-9) return;
    self.resetAccelIfChase();
    self.seek_target = null;
    self.seek_follows_bottom = false;
    self.seek_follows_top = false;
    self.pinned_to_bottom = false;
    self.page_coast = false;
    self.mouse_coast = mouse;
    // +impulse → older history → lower position → negative velocity.
    if (mouse) {
        self.coast_friction = @max(self.friction, 0.05) * 3;
        self.velocity -= delta_rows * self.coast_friction;
    } else {
        self.coast_friction = @max(self.friction, 0.05);
        self.velocity -= delta_rows * self.impulse_scale;
    }
}

/// Stop coasting. Keeps the current offset and pin state.
pub fn brake(self: *ScrollPhysics) void {
    self.velocity = 0;
    self.page_coast = false;
    self.clearAccel();
}

/// Page Up/Down: coast one viewport minus a row. `direction` +1 = older,
/// −1 = toward bottom. Key-repeat stacks another kick on velocity.
pub fn applyPageImpulse(
    self: *ScrollPhysics,
    direction: f64,
    viewport_rows: f64,
) void {
    if (@abs(direction) < 1e-9) return;
    self.resetAccelIfChase();
    self.seek_target = null;
    self.seek_follows_bottom = false;
    self.seek_follows_top = false;
    self.pinned_to_bottom = false;
    self.page_coast = true;
    self.mouse_coast = false;
    self.coast_friction = @max(self.friction, 0.05) * 3;
    const vp = @max(1, viewport_rows - 1);
    self.velocity -= direction * vp * self.coast_friction;
    self.run_time = @max(self.run_time, 1.5);
}

/// Coast to the top (`direction` +1) or bottom (−1). Always reaches the extreme.
pub fn seekExtreme(self: *ScrollPhysics, direction: f64) void {
    if (@abs(direction) < 1e-9) return;
    self.resetAccelIfChase();
    self.seek_target = null;
    self.page_coast = false;
    self.mouse_coast = false;
    self.pinned_to_bottom = false;
    self.seek_follows_top = direction > 0;
    self.seek_follows_bottom = direction < 0;
}

/// Jump to top of scrollback.
pub fn pinTop(self: *ScrollPhysics) void {
    self.seek_target = null;
    self.seek_follows_bottom = false;
    self.seek_follows_top = false;
    self.page_coast = false;
    self.clearAccel();
    self.position = 0;
    self.velocity = 0;
    self.pinned_to_bottom = false;
}

/// Jump to bottom and pin.
pub fn pinBottom(self: *ScrollPhysics, max_offset: f64) void {
    const max_o = @max(0, max_offset);
    self.seek_target = null;
    self.seek_follows_bottom = false;
    self.seek_follows_top = false;
    self.page_coast = false;
    self.clearAccel();
    self.position = max_o;
    self.velocity = 0;
    self.pinned_to_bottom = true;
}

/// Coast to an absolute offset. Same accelerating visual cap as `seekExtreme`.
pub fn smoothTo(self: *ScrollPhysics, offset: f64, max_offset: f64) void {
    const max_o = @max(0, max_offset);
    const goal = std.math.clamp(offset, 0, max_o);
    self.resetAccelIfChase();
    self.pinned_to_bottom = false;
    self.page_coast = false;
    self.mouse_coast = false;
    self.seek_follows_bottom = false;
    self.seek_follows_top = false;
    if (@abs(goal - self.position) < 0.35) {
        self.seek_target = null;
        self.position = goal;
        self.velocity = 0;
        if (@abs(goal - max_o) < self.settle_pos) {
            self.pinBottom(max_o);
        }
        return;
    }
    self.seek_target = goal;
}

/// Drop the oldest `n` history rows (scrollback cap trim).
/// The same lines stay on screen; their index in the remaining buffer
/// is smaller. Does not pin.
pub fn trimTop(self: *ScrollPhysics, n: f64) void {
    if (n <= 0) return;
    self.position = @max(0, self.position - n);
    if (self.seek_target) |target| {
        self.seek_target = @max(0, target - n);
    }
}

/// When pinned, live output sticks to the bottom with no speed cap.
pub fn followBottomIfPinned(self: *ScrollPhysics, max_offset: f64) void {
    if (!self.pinned_to_bottom) return;
    const max_o = @max(0, max_offset);
    self.position = max_o;
    self.velocity = 0;
}

/// Integrate one frame. Returns true if still moving (needs redraw).
pub fn step(self: *ScrollPhysics, dt_raw: f64, max_offset: f64) bool {
    const max_o = @max(0, max_offset);
    const dt = std.math.clamp(dt_raw, 0, 0.05);

    if (self.pinned_to_bottom) {
        self.seek_target = null;
        self.seek_follows_bottom = false;
        self.seek_follows_top = false;
        self.position = max_o;
        self.velocity = 0;
        self.clearAccel();
        return false;
    }

    if (self.seek_follows_top) {
        if (self.position <= self.settle_pos) {
            self.position = 0;
            self.velocity = 0;
            self.seek_follows_top = false;
            self.clearAccel();
            return false;
        }
        self.velocity = -self.position / @max(dt, 1.0 / 240.0);
    } else if (self.seek_follows_bottom) {
        if (self.position >= max_o - self.settle_pos) {
            self.pinBottom(max_o);
            return false;
        }
        const remaining = max_o - self.position;
        self.velocity = remaining / @max(dt, 1.0 / 240.0);
    } else if (self.seek_target) |target| {
        const goal = std.math.clamp(target, 0, max_o);
        const remaining = goal - self.position;
        if (@abs(remaining) <= self.settle_pos) {
            self.position = goal;
            self.velocity = 0;
            self.seek_target = null;
            self.clearAccel();
            if (@abs(self.position - max_o) < self.settle_pos) {
                self.pinBottom(max_o);
            }
            return false;
        }
        self.velocity = remaining / @max(dt, 1.0 / 240.0);
    }

    const seeking = self.seek_follows_bottom or self.seek_follows_top or self.seek_target != null;
    // A coalesced wakeup can tick with dt ≈ 0. Do not treat that as settled.
    if (dt <= 0) return self.stillMoving();

    const max_delta = self.visualCap();
    if (!seeking and @abs(self.velocity) < self.settle_vel) {
        // Apply first so a sub-cell nudge off the prompt is not re-pinned.
        const toward_history = self.velocity < 0;
        self.finishCoast(max_o, toward_history);
        return false;
    }
    const uncapped = if (seeking) self.velocity * dt else self.coastDisplacement(dt);
    const delta = if (seeking or !self.mouse_coast)
        std.math.clamp(uncapped, -max_delta, max_delta)
    else
        uncapped;
    self.run_time += dt;
    self.position += delta;
    if (self.clampToRange(max_o)) {
        self.velocity = 0;
        self.page_coast = false;
        self.seek_follows_top = false;
        self.seek_target = null;
        if (self.pinned_to_bottom) {
            self.clearAccel();
            return false;
        }
    } else if (!seeking) {
        self.velocity *= @exp(-self.coast_friction * dt);
        if (@abs(self.velocity) < self.settle_vel) {
            self.finishCoast(max_o, self.velocity < 0);
        }
    }

    if (self.stillMoving()) return true;
    self.clearAccel();
    return false;
}

/// Exact ∫ v e^{-μt} dt over this frame (exponential coast, not Euler).
fn coastDisplacement(self: *const ScrollPhysics, dt: f64) f64 {
    const mu = self.coast_friction;
    if (mu <= 1e-12) return self.velocity * dt;
    const decay = @exp(-mu * dt);
    return self.velocity * (1.0 - decay) / mu;
}

fn finishCoast(self: *ScrollPhysics, max_o: f64, toward_history: bool) void {
    if (self.page_coast) {
        self.position = @round(self.position);
        self.page_coast = false;
    }
    self.velocity = 0;
    self.clearAccel();
    if (self.position <= 0) {
        self.position = 0;
    } else if (self.position >= max_o - self.settle_pos and !toward_history) {
        self.pinBottom(max_o);
    }
}

fn stillMoving(self: *const ScrollPhysics) bool {
    return @abs(self.velocity) > self.settle_vel or
        self.seek_follows_bottom or
        self.seek_follows_top or
        self.seek_target != null;
}

/// Rows allowed this frame: 1 at t=0, doubles every `accel_halflife`.
/// Used for key and jump seeks, not mouse/trackpad coasts.
fn visualCap(self: *const ScrollPhysics) f64 {
    const start = @max(self.max_rows_per_frame, 0.05);
    const t = @max(self.run_time, 0);
    const h = @max(self.accel_halflife, 0.05);
    return start * std.math.pow(f64, 2.0, t / h);
}

/// Sync continuous position from the grid after an external change.
/// Pin only when the viewport is actually at the live bottom. A leftover
/// `pinned_to_bottom` must not jump a history view to the prompt.
pub fn syncFromScrollbar(
    self: *ScrollPhysics,
    offset: f64,
    max_offset: f64,
    force_pin_if_active: bool,
) void {
    const max_o = @max(0, max_offset);
    if (force_pin_if_active) {
        self.pinBottom(max_o);
        return;
    }
    // Don't fight an active chase with hard snaps from scrollbar growth.
    if (self.seek_target != null) return;
    self.snapTo(offset, max_o);
}

/// Instantly adopt an absolute offset (scrollbar thumb). Cancels seeks.
pub fn snapTo(self: *ScrollPhysics, offset: f64, max_offset: f64) void {
    const max_o = @max(0, max_offset);
    const goal = std.math.clamp(offset, 0, max_o);
    self.seek_target = null;
    self.seek_follows_bottom = false;
    self.seek_follows_top = false;
    self.page_coast = false;
    self.mouse_coast = false;
    self.clearAccel();
    if (@abs(goal - max_o) < self.settle_pos) {
        self.pinBottom(max_o);
        return;
    }
    self.pinned_to_bottom = false;
    self.position = goal;
    self.velocity = 0;
}

/// Returns true if an edge was hit.
fn clampToRange(self: *ScrollPhysics, max_o: f64) bool {
    if (self.position <= 0) {
        self.position = 0;
        return true;
    }
    // A short first frame from the prompt must not re-pin a history fling.
    if (self.position >= max_o - self.settle_pos and self.velocity >= 0) {
        self.pinBottom(max_o);
        return true;
    }
    if (self.position > max_o) self.position = max_o;
    return false;
}

fn clearAccel(self: *ScrollPhysics) void {
    self.run_time = 0;
}

/// Restart the cap for a new gesture (chase, pin), not a continued fling
/// or a retargeted chase (find next while already seeking).
fn resetAccelIfChase(self: *ScrollPhysics) void {
    if (self.seek_follows_bottom or self.seek_follows_top or self.pinned_to_bottom) {
        self.clearAccel();
        self.velocity = 0;
    }
}

test "ScrollPhysics applyPageImpulse coasts about one viewport" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(400);
    p.applyPageImpulse(1, 20);
    var n: usize = 0;
    while (n < 300 and p.step(1.0 / 60.0, 400)) : (n += 1) {}
    try testing.expectEqual(@as(f64, 381), p.position);
    try testing.expectEqual(@as(u64, 381), p.integerRow(400));
}

test "ScrollPhysics applyPageImpulse up then down returns" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(400);
    p.applyPageImpulse(1, 20);
    var n: usize = 0;
    while (n < 300 and p.step(1.0 / 60.0, 400)) : (n += 1) {}
    try testing.expectEqual(@as(f64, 381), p.position);
    p.applyPageImpulse(-1, 20);
    n = 0;
    while (n < 300 and p.step(1.0 / 60.0, 400)) : (n += 1) {}
    try testing.expect(p.pinned_to_bottom);
    try testing.expectEqual(@as(f64, 400), p.position);
}

test "ScrollPhysics applyPageImpulse repeat adds another viewport" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(400);
    p.applyPageImpulse(1, 20);
    _ = p.step(1.0 / 60.0, 400);
    p.applyPageImpulse(1, 20);
    var n: usize = 0;
    while (n < 120 and p.step(1.0 / 60.0, 400)) : (n += 1) {}
    try testing.expectEqual(@as(f64, 362), p.position);
}

test "ScrollPhysics applyPageImpulse survives a zero-dt tick" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(400);
    p.applyPageImpulse(1, 20);
    try testing.expect(p.step(0, 400));
    try testing.expect(!p.pinned_to_bottom);
    try testing.expect(p.velocity != 0);
    try testing.expectEqual(@as(f64, 400), p.position);
}

test "ScrollPhysics applyPageImpulse survives a sub-ms tick from bottom" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(400);
    p.applyPageImpulse(1, 20);
    try testing.expect(p.step(0.0001, 400));
    try testing.expect(!p.pinned_to_bottom);
    try testing.expect(p.velocity != 0);
}

test "ScrollPhysics applyMousePan follows delta" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(400);
    p.applyMousePan(10);
    try testing.expect(!p.pinned_to_bottom);
    try testing.expectEqual(@as(f64, 390), p.position);
    try testing.expectEqual(@as(f64, 0), p.velocity);
    try testing.expect(p.step(1.0 / 60.0, 400) == false);
    try testing.expectEqual(@as(f64, 390), p.position);
}

test "ScrollPhysics mouse impulse coasts about the delta" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(500);
    p.applyMouseImpulse(8);
    var n: usize = 0;
    while (n < 400 and p.step(1.0 / 60.0, 500)) : (n += 1) {}
    try testing.expectApproxEqAbs(@as(f64, 492), p.position, 0.25);
    try testing.expect(!p.pinned_to_bottom);
}

test "ScrollPhysics mouse impulse is not visual-capped" {
    const testing = std.testing;

    var mouse: ScrollPhysics = .{};
    mouse.pinBottom(400);
    mouse.applyMouseImpulse(100);
    try testing.expect(mouse.step(1.0 / 60.0, 400));
    const mouse_moved = 400 - mouse.position;

    var key: ScrollPhysics = .{};
    key.pinBottom(400);
    key.applyImpulse(100);
    try testing.expect(key.step(1.0 / 60.0, 400));
    const key_moved = 400 - key.position;

    try testing.expect(mouse_moved > key_moved);
    try testing.expect(key_moved <= 1.0 + 1e-9);
    try testing.expect(mouse_moved > 1);
}

test "ScrollPhysics applyImpulse unpins from bottom" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(100);
    p.applyImpulse(0.02);
    try testing.expect(!p.pinned_to_bottom);
    var n: usize = 0;
    while (n < 300 and p.step(1.0 / 60.0, 100)) : (n += 1) {}
    try testing.expect(!p.pinned_to_bottom);
    try testing.expect(p.position < 100);
}

test "ScrollPhysics brake zeros velocity without pinning" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(100);
    p.applyImpulse(2);
    try testing.expect(p.step(1.0 / 60.0, 100));
    try testing.expect(!p.pinned_to_bottom);
    try testing.expect(p.velocity != 0);
    const pos = p.position;
    p.brake();
    try testing.expectEqual(@as(f64, 0), p.velocity);
    try testing.expectEqual(pos, p.position);
    try testing.expect(!p.pinned_to_bottom);
    try testing.expect(!p.step(1.0 / 60.0, 100));
    try testing.expectEqual(pos, p.position);
    try testing.expect(!p.pinned_to_bottom);
}

test "ScrollPhysics seekExtreme reaches bottom" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinTop();
    p.seekExtreme(-1);
    try testing.expect(p.seek_follows_bottom);
    var n: usize = 0;
    while (n < 120 and p.step(1.0 / 60.0, 80)) : (n += 1) {}
    try testing.expect(p.pinned_to_bottom);
    try testing.expectEqual(@as(f64, 80), p.position);
}

test "ScrollPhysics step stays in range" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinTop();
    for (0..8) |_| p.applyPageImpulse(1, 20);
    for (0..60) |_| {
        _ = p.step(1.0 / 60.0, 50);
        try testing.expect(p.position >= 0);
        try testing.expect(p.position <= 50);
    }
    p.pinBottom(50);
    for (0..8) |_| p.applyPageImpulse(-1, 20);
    for (0..60) |_| {
        _ = p.step(1.0 / 60.0, 50);
        try testing.expect(p.position >= 0);
        try testing.expect(p.position <= 50);
    }
}

test "ScrollPhysics seekExtreme reaches top" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(80);
    p.seekExtreme(1);
    var n: usize = 0;
    while (n < 120 and p.step(1.0 / 60.0, 80)) : (n += 1) {}
    try testing.expect(!p.pinned_to_bottom);
    try testing.expectEqual(@as(f64, 0), p.position);
}

test "ScrollPhysics visualOffsetRows is negated fraction" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinned_to_bottom = false;
    p.position = 10.25;
    try testing.expectEqual(@as(u64, 10), p.integerRow(100));
    try testing.expectEqual(@as(f64, -0.25), p.visualOffsetRows(100));
}

test "ScrollPhysics smoothTo settles mid-history unpinned" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(100);
    p.smoothTo(50, 100);
    var n: usize = 0;
    while (n < 240 and p.step(1.0 / 60.0, 100)) : (n += 1) {}
    try testing.expect(!p.pinned_to_bottom);
    try testing.expectEqual(@as(f64, 50), p.position);
}

test "ScrollPhysics trimTop past position stays at top" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinned_to_bottom = false;
    p.position = 50;
    p.trimTop(60);
    try testing.expect(!p.pinned_to_bottom);
    try testing.expectEqual(@as(f64, 0), p.position);
    _ = p.step(1.0 / 60.0, 40);
    try testing.expect(!p.pinned_to_bottom);
    try testing.expectEqual(@as(f64, 0), p.position);
}

test "ScrollPhysics trimTop shifts seek target" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinned_to_bottom = false;
    p.position = 80;
    p.smoothTo(50, 100);
    p.trimTop(10);
    try testing.expectEqual(@as(f64, 70), p.position);
    try testing.expectEqual(@as(f64, 40), p.seek_target.?);
}

test "ScrollPhysics syncFromScrollbar history does not pin" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    try testing.expect(p.pinned_to_bottom);
    p.syncFromScrollbar(20, 100, false);
    try testing.expect(!p.pinned_to_bottom);
    try testing.expectEqual(@as(f64, 20), p.position);
}

test "ScrollPhysics syncFromScrollbar bottom pins" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinTop();
    p.syncFromScrollbar(80, 80, true);
    try testing.expect(p.pinned_to_bottom);
    try testing.expectEqual(@as(f64, 80), p.position);
}

test "ScrollPhysics snapTo cancels seek" {
    const testing = std.testing;

    var p: ScrollPhysics = .{};
    p.pinBottom(100);
    p.smoothTo(0, 100);
    p.snapTo(20, 100);
    try testing.expect(!p.pinned_to_bottom);
    try testing.expect(p.seek_target == null);
    try testing.expectEqual(@as(f64, 20), p.position);
}
