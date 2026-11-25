//! The part of the timeline's axis that is visible, in frames (0-based, with
//! fractions). It always lies within the trajectory and shows at least two of
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
        const f: f64 = @floatFromInt(frame);
        return f >= w.lo and f <= w.hi;
    }

    pub fn isAll(w: Window, n: usize) bool {
        return w.lo <= 0 and w.hi >= last(n);
    }

    /// Within the trajectory; keeps the span where it can.
    fn fitted(w: Window, n: usize) Window {
        const end = last(n);
        const s = std.math.clamp(w.span(), @min(1, end), end);
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
        const s = std.math.clamp(w.span() / factor, @min(1, end), end);
        const t = if (w.span() > 0) std.math.clamp((at - w.lo) / w.span(), 0, 1) else 0.5;
        const lo = w.lo + t * w.span() - t * s;
        return (Window{ .lo = lo, .hi = lo + s }).fitted(n);
    }

    pub fn panned(w: Window, by: f64, n: usize) Window {
        return (Window{ .lo = w.lo + by, .hi = w.hi + by }).fitted(n);
    }

    /// The playhead went from frame `was` to `now`: keep it in view. While
    /// playing, not if the user has panned away from it.
    pub fn following(w: Window, was: usize, now: usize, playing: bool, n: usize) Window {
        if (was == now or (playing and !w.contains(was))) return w;
        return w.revealing(now, n);
    }

    /// Move one end; the other stays.
    pub fn withLo(w: Window, lo: f64, n: usize) Window {
        return .{ .lo = std.math.clamp(lo, 0, @max(w.hi - @min(1, last(n)), 0)), .hi = w.hi };
    }

    pub fn withHi(w: Window, hi: f64, n: usize) Window {
        return .{ .lo = w.lo, .hi = std.math.clamp(hi, @min(w.lo + @min(1, last(n)), last(n)), last(n)) };
    }

    /// Moved so that `frame` is in it, a tenth from the end it came in by.
    pub fn revealing(w: Window, frame: usize, n: usize) Window {
        if (w.contains(frame)) return w;
        const f: f64 = @floatFromInt(frame);
        const margin = w.span() * 0.1;
        // Going on to the right, most of what comes next is in view.
        const lo = if (f > w.hi) f - margin else f - w.span() + margin;
        return (Window{ .lo = lo, .hi = lo + w.span() }).fitted(n);
    }

    /// How far it is zoomed in: 0 = everything, 1 = two frames. Each step
    /// shows the same fraction less.
    pub fn zoomLevel(w: Window, n: usize) f64 {
        const end = last(n);
        if (end <= 1) return 0;
        return std.math.clamp(@log(end / @max(w.span(), 1)) / @log(end), 0, 1);
    }

    /// Zoomed to that level around `at`.
    pub fn atLevel(w: Window, level: f64, at: f64, n: usize) Window {
        const end = last(n);
        if (end <= 1) return all(n);
        const s = end / @exp(std.math.clamp(level, 0, 1) * @log(end));
        return w.zoomed(at, w.span() / s, n);
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

    /// The frames in the window, and one more on either side for lines that go
    /// out of it: [first, end).
    pub fn frames(w: Window, n: usize) [2]usize {
        const first: usize = @intFromFloat(@max(@floor(w.lo), 0));
        const end: usize = @intFromFloat(@max(@ceil(w.hi), 0));
        return .{ @min(first, n), @min(end + 1, n) };
    }
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
const sizes = [_]usize{ 0, 1, 2, 3, 10, 1000, 492_963, 500_000 };

fn expectSound(w: Window, n: usize) !void {
    const end: f64 = @floatFromInt(n -| 1);
    errdefer std.debug.print("n={d} {any}\n", .{ n, w });
    try testing.expect(w.lo >= 0 and w.hi <= end and w.lo <= w.hi);
    try testing.expect(w.span() >= @min(1, end) - 1e-6);
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
                6 => w.revealing(if (n == 0) 0 else r.uintLessThan(usize, n), n),
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
        try testing.expectApproxEqAbs(1, w.span(), 1e-6);
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
    try testing.expectEqual(Window{ .lo = 199, .hi = 200 }, w.withLo(500, 1000));
    try testing.expectEqual(Window{ .lo = 100, .hi = 101 }, w.withHi(3, 1000));
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

test "a frame that is revealed is in view, with most of what comes next" {
    const w: Window = .between(100, 200, 1000);
    try testing.expectEqual(w, w.revealing(200, 1000));
    const on = w.revealing(201, 1000);
    try testing.expect(on.contains(201) and on.contains(280) and on.span() == 100);
    const back = w.revealing(99, 1000);
    try testing.expect(back.contains(99) and back.contains(20) and back.span() == 100);
    try testing.expectEqual(Window{ .lo = 899, .hi = 999 }, w.revealing(999, 1000));
}

test "the playhead is followed, unless the user panned away while playing" {
    const w: Window = .between(100, 200, 1000);
    try testing.expectEqual(w, w.following(150, 151, true, 1000));
    try testing.expect(w.following(200, 201, true, 1000).contains(201));
    try testing.expectEqual(w, w.following(500, 501, true, 1000)); // panned away
    try testing.expect(w.following(99, 100, true, 1000).contains(100)); // it comes into view
    try testing.expect(w.following(500, 501, false, 1000).contains(501)); // a key
    try testing.expectEqual(w, w.following(500, 500, false, 1000)); // panned, at rest
}

test "the zoom level goes from everything to two frames, and back to the same window" {
    for ([_]usize{ 10, 1000, 492_963 }) |n| {
        const end: f64 = @floatFromInt(n - 1);
        try testing.expectEqual(0, Window.all(n).zoomLevel(n));
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
