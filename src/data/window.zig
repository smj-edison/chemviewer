//! The part of the timeline's axis that is visible, in frames (0-based, with
//! fractions). It always lies within the trajectory and shows at least ten of
//! its frames, if there are as many.
const std = @import("std");

pub const Window = struct {
    lo: f64,
    hi: f64,

    /// Everything of `n` frames.
    pub fn all(n: usize) Window {
        return .{ .lo = 0, .hi = last(n) };
    }

    fn last(n: usize) f64 {
        return @floatFromInt(n -| 1);
    }

    pub fn span(w: Window) f64 {
        return w.hi - w.lo;
    }

    pub fn contains(w: Window, frame: usize) bool {
        return w.containsAt(@floatFromInt(frame));
    }

    pub fn containsAt(w: Window, f: f64) bool {
        return f >= w.lo and f <= w.hi;
    }

    pub fn isAll(w: Window, n: usize) bool {
        return w.lo <= 0 and w.hi >= last(n);
    }

    /// The least that always has ten frames in it, wherever it starts. Fewer
    /// say little.
    fn leastSpan(n: usize) f64 {
        return @min(10, last(n));
    }

    /// Whether there is anything to zoom in to.
    pub fn canZoom(n: usize) bool {
        return last(n) > leastSpan(n);
    }

    /// Within the trajectory; keeps the span where it can.
    fn fitted(w: Window, n: usize) Window {
        const end = last(n);
        const s = std.math.clamp(w.span(), leastSpan(n), end);
        const lo = std.math.clamp(w.lo, 0, end - s);
        return .{ .lo = lo, .hi = @min(lo + s, end) };
    }

    /// From `a` to `b`, in any order.
    pub fn between(a: f64, b: f64, n: usize) Window {
        return (Window{ .lo = @min(a, b), .hi = @max(a, b) }).fitted(n);
    }

    /// Show `factor` times less, with `at` staying where it is.
    pub fn zoomed(w: Window, at: f64, factor: f64, n: usize) Window {
        const end = last(n);
        const s = std.math.clamp(w.span() / factor, leastSpan(n), end);
        const t = if (w.span() > 0) std.math.clamp((at - w.lo) / w.span(), 0, 1) else 0.5;
        const lo = w.lo + t * w.span() - t * s;
        return (Window{ .lo = lo, .hi = lo + s }).fitted(n);
    }

    pub fn panned(w: Window, by: f64, n: usize) Window {
        return (Window{ .lo = w.lo + by, .hi = w.hi + by }).fitted(n);
    }

    /// The playhead went from `was` to `now`: keep it in view. While playing it
    /// runs to the middle, and from there the window moves steadily under it;
    /// not if the user has panned away from it. Otherwise the window moves only
    /// as far as needed, or to where the playhead jumped.
    pub fn following(w: Window, was: f64, now: f64, playing: bool, n: usize) Window {
        if (was == now) return w;
        const half = w.span() / 2;
        if (playing) {
            if (!w.containsAt(was)) return w;
            const jumped = now < was or now - was > half;
            if (jumped) return if (w.containsAt(now)) w else w.centred(now, n);
            const past = now - (w.lo + half);
            return if (past > 0) w.panned(@min(now - was, past), n) else w;
        }
        if (now > w.hi + half or now < w.lo - half) return w.centred(now, n);
        const margin = w.span() * 0.1;
        const over = now - (w.hi - margin);
        const under = (w.lo + margin) - now;
        if (now > was and over > 0) return w.panned(over, n);
        if (now < was and under > 0) return w.panned(-under, n);
        return w;
    }

    pub fn middle(w: Window) f64 {
        return (w.lo + w.hi) / 2;
    }

    pub fn centred(w: Window, at: f64, n: usize) Window {
        return w.panned(at - w.middle(), n);
    }

    /// Move one end; the other stays.
    pub fn withLo(w: Window, lo: f64, n: usize) Window {
        return .{ .lo = std.math.clamp(lo, 0, @max(w.hi - leastSpan(n), 0)), .hi = w.hi };
    }

    pub fn withHi(w: Window, hi: f64, n: usize) Window {
        return .{ .lo = w.lo, .hi = std.math.clamp(hi, @min(w.lo + leastSpan(n), last(n)), last(n)) };
    }

    /// How far it is zoomed in: 0 = everything, 1 = as far as it goes. Each
    /// step shows the same fraction less.
    pub fn zoomLevel(w: Window, n: usize) f64 {
        const most = last(n) / @max(leastSpan(n), 1);
        if (most <= 1) return 0;
        return std.math.clamp(@log(last(n) / @max(w.span(), leastSpan(n))) / @log(most), 0, 1);
    }

    /// Zoomed to that level around `at`.
    pub fn atLevel(w: Window, level: f64, at: f64, n: usize) Window {
        const most = last(n) / @max(leastSpan(n), 1);
        if (most <= 1) return all(n);
        const s = last(n) / @exp(std.math.clamp(level, 0, 1) * @log(most));
        return w.zoomed(at, w.span() / s, n);
    }

    /// What the wheel does over the axis, with the mouse at `at`: zooms, up
    /// being in, or with Shift or sideways pans.
    pub fn wheeled(w: Window, at: f64, wheel: Wheel, n: usize) Window {
        // Swipes are never quite straight: the larger part counts.
        const sideways = @abs(wheel.x) > @abs(wheel.y);
        if (wheel.shift or sideways) {
            if (wheel.ctrl) return w;
            const by: f64 = if (sideways) wheel.x else -wheel.y;
            return w.panned(0.1 * w.span() * by, n);
        }
        if (wheel.up == 0) return w;
        return w.zoomed(at, std.math.pow(f64, 1.25, wheel.up), n);
    }

    /// Dragged by `dx` pixels of `width`, so that it stays under the mouse.
    pub fn dragged(w: Window, dx: f32, width: f32, n: usize) Window {
        return w.panned(-@as(f64, dx) / @max(width - 1, 1) * w.span(), n);
    }

    /// Where frame `f` is on a stretch of `width` pixels from `x0`. The window's
    /// ends are in the middle of its first and last pixel.
    pub fn toX(w: Window, f: f64, x0: f32, width: f32) f32 {
        if (w.span() <= 0) return x0 + 0.5;
        return x0 + 0.5 + @as(f32, @floatCast((f - w.lo) / w.span())) * (width - 1);
    }

    /// The inverse of `toX`, within the window.
    pub fn fromX(w: Window, x: f32, x0: f32, width: f32) f64 {
        const t: f64 = std.math.clamp((x - x0 - 0.5) / @max(width - 1, 1), 0, 1);
        return w.lo + t * w.span();
    }

    /// The nearest frame in the window to x.
    pub fn frameAt(w: Window, x: f32, x0: f32, width: f32) usize {
        const f = @round(w.fromX(x, x0, width));
        const in = std.math.clamp(f, @ceil(w.lo), @max(@floor(w.hi), @ceil(w.lo)));
        return @intFromFloat(@max(in, 0));
    }

    /// The frames in the window, and those that lines going out of it lead to:
    /// [first, end).
    pub fn frames(w: Window, n: usize) [2]usize {
        const first: usize = @intFromFloat(@max(@floor(w.lo), 0));
        const end: usize = @intFromFloat(@max(@ceil(w.hi), 0));
        return .{ @min(first, n), @min(end + 1, n) };
    }
};

/// Wheel movement, as it scrolls: positive x is right, y is up.
pub const Wheel = struct {
    x: f32 = 0,
    y: f32 = 0,
    /// y by the hand: positive is up even if scrolling is set to be natural.
    up: f32 = 0,
    shift: bool = false,
    ctrl: bool = false,
};

/// The smallest 1, 2 or 5 times a power of ten that is at least `least`, and at
/// least 1: the step between labelled frames.
pub fn tickStep(least: f64) u64 {
    var p: u64 = 1;
    while (p < std.math.maxInt(u64) / 100) : (p *= 10) {
        for ([_]u64{ 1, 2, 5 }) |k| if (@as(f64, @floatFromInt(k * p)) >= least) return k * p;
    }
    return p;
}

const testing = std.testing;
const sizes = [_]usize{ 0, 1, 2, 3, 9, 10, 11, 12, 1000, 492_963, 500_000 };

fn expectSound(w: Window, n: usize) !void {
    const end: f64 = @floatFromInt(n -| 1);
    errdefer std.debug.print("n={d} {any}\n", .{ n, w });
    try testing.expect(w.lo >= 0 and w.hi <= end and w.lo <= w.hi);
    // Ten frames in it, wherever it starts.
    const seen = @floor(w.hi + 1e-6) - @ceil(w.lo - 1e-6) + 1;
    try testing.expect(seen >= @as(f64, @floatFromInt(@min(n, 10))));
}

test "whatever is done to a window, it stays within the trajectory and shows two frames" {
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    for (sizes) |n| {
        var w: Window = .all(n);
        try expectSound(w, n);
        const end: f64 = @floatFromInt(n);
        for (0..2000) |_| {
            const x = r.float(f64) * 1.4 * end - 0.2 * end;
            w = switch (r.uintLessThan(u8, 8)) {
                0 => w.zoomed(x, 1 + r.float(f64) * 3, n),
                1 => w.zoomed(x, 1 / (1 + r.float(f64) * 3), n),
                2 => w.panned(x - end / 2, n),
                3 => w.withLo(x, n),
                4 => w.withHi(x, n),
                5 => w.atLevel(r.float(f64) * 1.2 - 0.1, x, n),
                6 => w.following(r.float(f64) * end, r.float(f64) * end, r.boolean(), n),
                else => .between(x, r.float(f64) * end, n),
            };
            try expectSound(w, n);
            const at = w.frameAt(r.float(f32) * 1200 - 100, 0, 1000);
            try testing.expect(at <= n -| 1);
            const range = w.frames(n);
            try testing.expect(range[0] <= range[1] and range[1] <= n);
        }
    }
}

test "zooming keeps what is under the cursor there" {
    for ([_]usize{ 1000, 492_963 }) |n| {
        var w: Window = .all(n);
        const x: f32 = 300;
        const at = w.fromX(x, 10, 1000);
        while (w.span() > 20) {
            w = w.zoomed(at, 1.25, n);
            try testing.expectApproxEqAbs(x, w.toX(at, 10, 1000), 0.01);
        }
        // All the way in and out again.
        for (0..200) |_| w = w.zoomed(at, 1.25, n);
        try testing.expectApproxEqAbs(10, w.span(), 1e-6);
        for (0..200) |_| w = w.zoomed(at, 0.8, n);
        try testing.expect(w.isAll(n));
    }
}

test "panning keeps the span and stops at the ends" {
    const w: Window = .between(100, 200, 1000);
    try testing.expectEqual(Window{ .lo = 150, .hi = 250 }, w.panned(50, 1000));
    try testing.expectEqual(Window{ .lo = 0, .hi = 100 }, w.panned(-500, 1000));
    try testing.expectEqual(Window{ .lo = 899, .hi = 999 }, w.panned(5000, 1000));
}

test "the ends can be moved, but not through each other" {
    const w: Window = .between(100, 200, 1000);
    try testing.expectEqual(Window{ .lo = 50, .hi = 200 }, w.withLo(50, 1000));
    try testing.expectEqual(Window{ .lo = 190, .hi = 200 }, w.withLo(500, 1000));
    try testing.expectEqual(Window{ .lo = 100, .hi = 110 }, w.withHi(3, 1000));
    try testing.expectEqual(Window{ .lo = 100, .hi = 999 }, w.withHi(3000, 1000));
}

test "every frame is at its own pixel and found there once zoomed in enough" {
    const n = 492_963;
    const w: Window = .between(250_000, 250_200, n);
    for (250_000..250_201) |f| {
        const x = w.toX(@floatFromInt(f), 10, 1000);
        try testing.expectEqual(f, w.frameAt(x, 10, 1000));
    }
    try testing.expectEqual(250_000, w.frameAt(-50, 10, 1000));
    try testing.expectEqual(250_200, w.frameAt(5000, 10, 1000));
}

test "while playing, the playhead runs to the middle, and then the window moves steadily under it" {
    const n = 1000;
    var w: Window = .between(100, 200, n);
    var was: f64 = 100;
    var x = w.toX(was, 0, 1000);
    while (was < 999) {
        const now = @min(was + 0.37, 999);
        const next = w.following(was, now, true, n);
        const next_x = next.toX(now, 0, 1000);
        // It never jumps, neither the window nor the playhead on screen.
        try testing.expect(next.lo >= w.lo and next.lo - w.lo < 0.38);
        try testing.expect(next_x >= x - 0.01 and next_x - x < 3.8);
        try testing.expectApproxEqAbs(100, next.span(), 1e-6);
        if (now > 151 and next.hi < 999) try testing.expectApproxEqAbs(500, next_x, 5);
        w = next;
        was = now;
        x = next_x;
    }
    // At the end there is nothing left to scroll to, and it runs on.
    try testing.expectApproxEqAbs(999, w.hi, 1e-6);
    try testing.expectApproxEqAbs(999.5, x, 0.01);
}

test "the wheel zooms, pans with Shift or sideways, and never does both" {
    const n = 1000;
    const w: Window = .between(400, 600, n);
    const at = 450;
    // Up is in, whichever way scrolling is set.
    try testing.expect(w.wheeled(at, .{ .y = 1, .up = 1 }, n).span() < w.span());
    try testing.expect(w.wheeled(at, .{ .y = -1, .up = 1 }, n).span() < w.span());
    try testing.expect(w.wheeled(at, .{ .y = -1, .up = -1 }, n).span() > w.span());
    try testing.expect(w.wheeled(at, .{ .y = 1, .up = 1, .ctrl = true }, n).span() < w.span());
    const Case = struct { Wheel, f64 };
    for ([_]Case{
        .{ .{ .y = -1, .up = -1, .shift = true }, 20 }, // on with the wheel down
        .{ .{ .x = 1 }, 20 },
        .{ .{ .x = 1, .y = 0.2, .up = 0.2 }, 20 }, // a swipe that isn't straight
        .{ .{ .x = -1, .shift = true }, -20 },
        .{ .{ .x = 0.1, .y = -1, .up = -1, .shift = true }, 20 }, // drift doesn't count
        .{ .{ .x = -0.1, .y = -1, .up = -1, .shift = true }, 20 },
        .{ .{ .x = 1, .ctrl = true }, 0 },
        .{ .{}, 0 },
    }) |case| {
        const got = w.wheeled(at, case[0], n);
        try testing.expectApproxEqAbs(w.span(), got.span(), 1e-9);
        try testing.expectApproxEqAbs(w.lo + case[1], got.lo, 1e-9);
    }
    const drifting = w.wheeled(at, .{ .x = 0.3, .y = 1, .up = 1 }, n);
    try testing.expectApproxEqAbs(at, drifting.lo + 0.25 * drifting.span(), 1e-9);
}

test "a playhead past the middle stays at its place on screen" {
    const w: Window = .between(100, 200, 1000);
    const next = w.following(180, 181, true, 1000);
    try testing.expectEqual(Window{ .lo = 101, .hi = 201 }, next);
}

test "the playhead isn't followed when the user panned away while playing" {
    const w: Window = .between(100, 200, 1000);
    try testing.expectEqual(w, w.following(500, 501, true, 1000));
    try testing.expectEqual(w, w.following(99.5, 99.9, true, 1000));
    try testing.expect(w.following(99, 100, true, 1000).containsAt(100)); // it comes into view
    // A loop starts over, in view.
    const end: Window = .between(899, 999, 1000);
    try testing.expectEqual(Window{ .lo = 0, .hi = 100 }, end.following(999, 0, true, 1000));
}

test "steps at rest scroll only as far as needed, and jumps go there" {
    const w: Window = .between(100, 200, 1000);
    try testing.expectEqual(w, w.following(150, 151, false, 1000));
    try testing.expectEqual(w, w.following(500, 500, false, 1000)); // panned
    var at = w;
    for (150..400) |i| {
        const next = at.following(@floatFromInt(i), @floatFromInt(i + 1), false, 1000);
        try testing.expect(next.lo - at.lo <= 1);
        try testing.expect(next.contains(i + 1));
        at = next;
    }
    try testing.expect(at.contains(409)); // some of what comes next
    const far = w.following(150, 700, false, 1000);
    try testing.expectEqual(Window{ .lo = 650, .hi = 750 }, far);
}

test "a short trajectory can't be zoomed" {
    for (sizes) |n| try testing.expectEqual(n > 11, Window.canZoom(n));
    for ([_]usize{ 1, 5, 11 }) |n| {
        const w: Window = .all(n);
        try testing.expectEqual(w, w.zoomed(1, 5, n));
        try testing.expectEqual(w, w.atLevel(1, 1, n));
        try testing.expectEqual(0, w.zoomLevel(n));
    }
}

test "the zoom level goes from everything to ten frames, and back to the same window" {
    for ([_]usize{ 100, 1000, 492_963 }) |n| {
        const end: f64 = @floatFromInt(n - 1);
        try testing.expectApproxEqAbs(0, Window.all(n).zoomLevel(n), 1e-12);
        for ([_]f64{ 0, 0.25, 0.5, 0.9, 1 }) |level| {
            const w = Window.all(n).atLevel(level, end / 2, n);
            try testing.expectApproxEqAbs(level, w.zoomLevel(n), 1e-6);
        }
    }
    try testing.expectEqual(0, Window.all(1).zoomLevel(1));
}

test "ticks are round" {
    const Case = struct { f64, u64 };
    for ([_]Case{ .{ 0, 1 }, .{ 0.3, 1 }, .{ 1, 1 }, .{ 1.1, 2 }, .{ 3, 5 }, .{ 6, 10 }, .{ 11, 20 }, .{ 49_296, 50_000 }, .{ 50_001, 100_000 } }) |case|
        try testing.expectEqual(case[1], tickStep(case[0]));
}
