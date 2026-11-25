//! Lowest and highest of any stretch of a series at little cost: those of every 16
//! values, of every 16 of these, and so on. Only full blocks are kept, so adding
//! values never changes what is there.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Of no finite value: lo > hi.
pub const Range = struct {
    lo: f64 = std.math.inf(f64),
    hi: f64 = -std.math.inf(f64),

    pub fn add(r: *Range, v: f64) void {
        if (!std.math.isFinite(v)) return;
        r.lo = @min(r.lo, v);
        r.hi = @max(r.hi, v);
    }

    fn join(r: *Range, other: Range) void {
        r.lo = @min(r.lo, other.lo);
        r.hi = @max(r.hi, other.hi);
    }

    pub fn known(r: Range) bool {
        return r.lo <= r.hi;
    }
};

pub const Pyramid = struct {
    const block = 16;
    const depth = 7;

    levels: [depth]std.ArrayList(Range) = @splat(.empty),
    /// `Table.rewinds` of the values it is for.
    rewinds: usize = 0,

    pub fn deinit(p: *Pyramid, gpa: Allocator) void {
        for (&p.levels) |*l| l.deinit(gpa);
        p.* = undefined;
    }

    /// Bring it up to `values`, which only got longer unless `rewinds` changed.
    /// Out of memory it is incomplete, and `range` only slower.
    pub fn update(p: *Pyramid, gpa: Allocator, values: []const f64, rewinds: usize) void {
        if (rewinds != p.rewinds) {
            for (&p.levels) |*l| l.clearRetainingCapacity();
            p.rewinds = rewinds;
        }
        const first = &p.levels[0];
        while ((first.items.len + 1) * block <= values.len) {
            var r: Range = .{};
            for (values[first.items.len * block ..][0..block]) |v| r.add(v);
            first.append(gpa, r) catch return;
        }
        for (p.levels[0 .. depth - 1], p.levels[1..]) |*lower, *l| {
            while ((l.items.len + 1) * block <= lower.items.len) {
                var r: Range = .{};
                for (lower.items[l.items.len * block ..][0..block]) |x| r.join(x);
                l.append(gpa, r) catch return;
            }
        }
    }

    /// Of `values[a..b]`.
    pub fn range(p: *const Pyramid, values: []const f64, a: usize, b: usize) Range {
        var r: Range = .{};
        var i = a;
        while (i < b) {
            // The largest block that starts here and fits.
            var size: usize = 1;
            var found: ?Range = null;
            for (&p.levels) |*l| {
                const s = size * block;
                if (i % s != 0 or i + s > b or i / s >= l.items.len) break;
                size = s;
                found = l.items[i / s];
            }
            if (found) |x| r.join(x) else r.add(values[i]);
            i += size;
        }
        return r;
    }
};

const testing = std.testing;

fn slow(values: []const f64) Range {
    var r: Range = .{};
    for (values) |v| r.add(v);
    return r;
}

test "any stretch is as if every value had been looked at, while values are added" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(3);
    const r = prng.random();
    var values: std.ArrayList(f64) = .empty;
    defer values.deinit(gpa);
    var p: Pyramid = .{};
    defer p.deinit(gpa);
    var rewinds: usize = 0;
    for (0..200) |round| {
        for (0..r.uintLessThan(usize, 700)) |_| try values.append(gpa, switch (r.uintLessThan(u8, 20)) {
            0 => std.math.nan(f64),
            1 => std.math.inf(f64),
            else => r.floatNorm(f64),
        });
        if (round % 50 == 49) {
            values.shrinkRetainingCapacity(r.uintLessThan(usize, values.items.len + 1));
            rewinds += 1;
        }
        p.update(gpa, values.items, rewinds);
        for (0..20) |_| {
            const x = r.uintLessThan(usize, values.items.len + 1);
            const y = r.uintLessThan(usize, values.items.len + 1);
            const a = @min(x, y);
            const b = @max(x, y);
            try testing.expectEqual(slow(values.items[a..b]), p.range(values.items, a, b));
        }
    }
    try testing.expectEqual(slow(values.items), p.range(values.items, 0, values.items.len));
}

test "nothing finite is no range" {
    var p: Pyramid = .{};
    defer p.deinit(testing.allocator);
    const values: [40]f64 = @splat(std.math.nan(f64));
    p.update(testing.allocator, &values, 0);
    try testing.expect(!p.range(&values, 0, 40).known());
    try testing.expect(!p.range(&.{}, 0, 0).known());
}

test "out of memory it still answers, and catches up" {
    var values: [5000]f64 = undefined;
    for (&values, 0..) |*v, i| v.* = @floatFromInt((i * 7919) % 5000);
    for (0..4) |fail_index| {
        var p: Pyramid = .{};
        defer p.deinit(testing.allocator);
        var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        p.update(failing.allocator(), &values, 0);
        try testing.expectEqual(slow(values[3..4321]), p.range(&values, 3, 4321));
        p.update(testing.allocator, &values, 0);
        try testing.expectEqual(5000 / 16, p.levels[0].items.len);
        try testing.expectEqual(slow(values[3..4321]), p.range(&values, 3, 4321));
    }
}
