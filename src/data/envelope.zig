//! The lowest and highest value per pixel column of a stretch of frames, kept
//! until something it depends on changes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Window = @import("window.zig").Window;

/// What the height of a plot stands for.
pub const Scale = struct {
    lo: f64,
    hi: f64,

    /// Where `v` is: 0 at the bottom, 1 at the top, beyond them off the plot.
    pub fn height(s: Scale, v: f64) f32 {
        return if (s.hi > s.lo) @floatCast((v - s.lo) / (s.hi - s.lo)) else 0.5;
    }
};

pub const Envelope = struct {
    key: ?Key = null,
    /// Per column; min > max where no value is known.
    min: []f64 = &.{},
    max: []f64 = &.{},
    /// Over all columns.
    lo: f64 = std.math.inf(f64),
    hi: f64 = -std.math.inf(f64),

    pub const Key = struct {
        /// Counts whatever changes the values.
        values: u64,
        document: u64,
        n: usize,
        window: Window,
        cols: usize,
    };

    pub fn deinit(e: *Envelope, gpa: Allocator) void {
        gpa.free(e.min);
        gpa.free(e.max);
        e.* = .{};
    }

    /// Whether any value is.
    pub fn known(e: Envelope) bool {
        return e.lo <= e.hi;
    }

    pub fn scale(e: Envelope) ?Scale {
        return if (e.known()) .{ .lo = e.lo, .hi = e.hi } else null;
    }

    /// Out of memory, it is empty.
    pub fn update(e: *Envelope, gpa: Allocator, key: Key, values: anytype) void {
        if (e.key) |k| if (std.meta.eql(k, key)) return;
        if (e.min.len != key.cols) {
            e.deinit(gpa);
            const min = gpa.alloc(f64, key.cols) catch return;
            e.max = gpa.alloc(f64, key.cols) catch return gpa.free(min);
            e.min = min;
        }
        e.key = key;
        e.lo = std.math.inf(f64);
        e.hi = -std.math.inf(f64);
        @memset(e.min, std.math.inf(f64));
        @memset(e.max, -std.math.inf(f64));
        if (key.cols == 0) return;
        const w = key.window;
        const top: f64 = @floatFromInt(key.cols - 1);
        const range = w.frames(key.n);
        for (range[0]..range[1]) |i| {
            if (!w.contains(i)) continue;
            const v = values.energy(i) orelse continue;
            const t = if (w.span() > 0) (@as(f64, @floatFromInt(i)) - w.lo) / w.span() else 0;
            const col: usize = @intFromFloat(@floor(std.math.clamp(t, 0, 1) * top));
            e.min[col] = @min(e.min[col], v);
            e.max[col] = @max(e.max[col], v);
            e.lo = @min(e.lo, v);
            e.hi = @max(e.hi, v);
        }
    }
};

const testing = std.testing;

/// Frame 7k is unknown, the others are a zigzag with one spike.
const TestValues = struct {
    n: usize,
    asked: usize = 0,

    pub fn energy(t: *TestValues, i: usize) ?f64 {
        t.asked += 1;
        if (i == 1234) return 1000;
        if (i % 7 == 0) return null;
        return if (i % 2 == 0) 1 else -1;
    }
};

test "every known value in the window is within its column, and no other" {
    var prng: std.Random.DefaultPrng = .init(2);
    const r = prng.random();
    var e: Envelope = .{};
    defer e.deinit(testing.allocator);
    for (0..50) |round| {
        const n = 1 + r.uintLessThan(usize, 5000);
        var values: TestValues = .{ .n = n };
        const end: f64 = @floatFromInt(n);
        const w: Window = .between(r.float(f64) * end, r.float(f64) * end, n);
        const cols = 2 + r.uintLessThan(usize, 300);
        e.update(testing.allocator, .{ .values = round, .document = 0, .n = n, .window = w, .cols = cols }, &values);
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = -std.math.inf(f64);
        for (0..n) |i| if (w.contains(i)) if (values.energy(i)) |v| {
            lo = @min(lo, v);
            hi = @max(hi, v);
        };
        try testing.expectEqual(lo, e.lo);
        try testing.expectEqual(hi, e.hi);
        if (lo <= hi) {
            try testing.expectEqual(lo, std.mem.min(f64, e.min));
            try testing.expectEqual(hi, std.mem.max(f64, e.max));
        }
    }
}

test "a single spike among half a million frames is seen" {
    var e: Envelope = .{};
    defer e.deinit(testing.allocator);
    var values: TestValues = .{ .n = 500_000 };
    e.update(testing.allocator, .{ .values = 0, .document = 0, .n = values.n, .window = .all(values.n), .cols = 1000 }, &values);
    try testing.expectEqual(1000, e.max[2]);
    try testing.expectEqual(1, e.max[3]);
}

test "equal values are a flat line, and no values none" {
    const Flat = struct {
        pub fn energy(_: *@This(), i: usize) ?f64 {
            return if (i < 50) -7 else null;
        }
    };
    var flat: Flat = .{};
    var e: Envelope = .{};
    defer e.deinit(testing.allocator);
    e.update(testing.allocator, .{ .values = 0, .document = 0, .n = 100, .window = .between(10, 40, 100), .cols = 10 }, &flat);
    try testing.expect(e.known());
    try testing.expectEqual(0.5, e.scale().?.height(-7));
    e.update(testing.allocator, .{ .values = 0, .document = 0, .n = 100, .window = .between(60, 90, 100), .cols = 10 }, &flat);
    try testing.expect(!e.known());
    try testing.expectEqual(null, e.scale());
    const s: Scale = .{ .lo = -2, .hi = 2 };
    for ([_]f64{ -2, 0, 2, 6 }, [_]f32{ 0, 0.5, 1, 2 }) |v, want| try testing.expectEqual(want, s.height(v));
}

test "it is worked out again only when something changed" {
    var e: Envelope = .{};
    defer e.deinit(testing.allocator);
    var values: TestValues = .{ .n = 100 };
    var key: Envelope.Key = .{ .values = 0, .document = 0, .n = 100, .window = .all(100), .cols = 10 };
    e.update(testing.allocator, key, &values);
    const asked = values.asked;
    e.update(testing.allocator, key, &values);
    try testing.expectEqual(asked, values.asked);
    key.window = key.window.zoomed(50, 2, 100);
    e.update(testing.allocator, key, &values);
    try testing.expect(values.asked > asked);
}

test "out of memory it is empty, and works the next time" {
    var values: TestValues = .{ .n = 100 };
    const key: Envelope.Key = .{ .values = 0, .document = 0, .n = 100, .window = .all(100), .cols = 10 };
    for (0..2) |fail_index| {
        var e: Envelope = .{};
        defer e.deinit(testing.allocator);
        var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        e.update(failing.allocator(), key, &values);
        try testing.expectEqual(0, e.min.len);
        e.update(testing.allocator, key, &values);
        try testing.expectEqual(10, e.min.len);
        try testing.expectEqual(10, e.max.len);
    }
}
