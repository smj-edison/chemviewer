//! A diff: the current frame compared with a reference, which is lined up with
//! it by a placement used only for drawing (D26). Neither's atoms change.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Transform = @import("core/align.zig").Transform;
const BondedAtoms = @import("display.zig").BondedAtoms;
const Frame = @import("core/structure.zig").Frame;
const Numbering = @import("picks.zig").Numbering;
const math = @import("core/math.zig");
const Vec3 = math.Vec3;

pub const Diff = struct {
    /// The reference, as it was when it was set, and where its atoms came from.
    reference: BondedAtoms,
    origins: ?[]u32,
    /// Where the reference is drawn: its point p is at `placement.apply(p)`.
    placement: Transform = .identity,
    /// Whether the rotation was locked before the diff.
    was_locked: bool,
    overlay: bool = true,

    /// The displayed geometry (`changes`) and placement the rest is about
    /// (null = none yet).
    followed: ?u64 = null,
    /// Null if the current frame has other atoms than the reference.
    result: ?Result = null,
    /// The reference's atoms where they are drawn, and how far each of the
    /// current frame's is from its own.
    placed: std.ArrayList(Vec3) = .empty,
    deviations: std.ArrayList(f32) = .empty,

    pub const Result = struct {
        rmsd: f64,
        /// The atom with the largest deviation.
        worst: usize,
    };

    /// With a copy of these atoms as the reference.
    pub fn init(gpa: Allocator, index: usize, atoms: Frame, origins: ?[]const u32, was_locked: bool) !Diff {
        var frame = try atoms.clone(gpa);
        errdefer frame.deinit(gpa);
        const owned = if (origins) |o| try gpa.dupe(u32, o) else null;
        var d: Diff = .{ .reference = .{}, .origins = owned, .was_locked = was_locked };
        d.reference.show(gpa, index, frame);
        return d;
    }

    pub fn deinit(d: *Diff, gpa: Allocator) void {
        d.reference.deinit(gpa);
        if (d.origins) |o| gpa.free(o);
        d.placed.deinit(gpa);
        d.deviations.deinit(gpa);
        d.* = undefined;
    }

    pub fn numbering(d: *const Diff) Numbering {
        return .{ .numbers = d.reference.frame.?.numbers, .origins = d.origins };
    }

    pub fn place(d: *Diff, placement: Transform) void {
        d.placement = placement;
        d.followed = null;
    }

    /// Compare with these atoms. `changes` tells whether they are the ones it
    /// was last compared with. Out of memory, there is no result until the
    /// next time.
    pub fn update(d: *Diff, gpa: Allocator, positions: []const Vec3, current: Numbering, changes: u64) void {
        if (d.followed == changes) return;
        d.followed = null;
        d.result = null;
        if (d.numbering().eql(current)) {
            const ref = d.reference.frame.?.positions;
            d.placed.resize(gpa, ref.len) catch return;
            d.deviations.resize(gpa, ref.len) catch return;
            var result: Result = .{ .rmsd = 0, .worst = 0 };
            var sum: f64 = 0;
            for (ref, positions, d.placed.items, d.deviations.items, 0..) |r, p, *placed, *dev, i| {
                placed.* = d.placement.apply(r);
                dev.* = math.length(p - placed.*);
                sum += @as(f64, dev.*) * dev.*;
                if (dev.* > d.deviations.items[result.worst]) result.worst = i;
            }
            if (ref.len > 0) result.rmsd = @sqrt(sum / @as(f64, @floatFromInt(ref.len)));
            d.result = result;
        }
        d.followed = changes;
    }
};

// --------------------------------------------------------------- tests

const testing = std.testing;
const test_gpa = testing.allocator;
const superpose = @import("core/align.zig").superpose;

fn testFrame(x: f32) !Frame {
    const f: Frame = try .init(test_gpa, 3);
    f.positions[0] = .{ 0, 0, 0 };
    f.positions[1] = .{ x, 0, 0 };
    f.positions[2] = .{ 0, 2, 1 };
    @memcpy(f.numbers, &[_]u8{ 1, 6, 8 });
    return f;
}

const TestDiff = struct {
    d: Diff,
    current: Frame,

    fn init() !TestDiff {
        var ref = try testFrame(1);
        defer ref.deinit(test_gpa);
        return .{ .d = try .init(test_gpa, 4, ref, null, false), .current = try testFrame(1) };
    }

    fn deinit(t: *TestDiff) void {
        t.d.deinit(test_gpa);
        t.current.deinit(test_gpa);
    }

    fn update(t: *TestDiff, changes: u64) void {
        t.d.update(test_gpa, t.current.positions, .{ .numbers = t.current.numbers }, changes);
    }
};

test "deviations and RMSD are measured against the placement" {
    var t: TestDiff = try .init();
    defer t.deinit();
    t.update(1);
    try testing.expectEqual(0, t.d.result.?.rmsd);
    t.current.positions[1][0] = 4; // 3 from the reference's
    t.update(2);
    try testing.expectEqual(1, t.d.result.?.worst);
    try testing.expectEqual(3, t.d.deviations.items[1]);
    try testing.expectApproxEqAbs(@sqrt(3.0), t.d.result.?.rmsd, 1e-6);
    // Placed elsewhere, all are off by that too.
    var moved: Transform = .identity;
    moved.to_center = .{ 0, 0, 2 };
    t.d.place(moved);
    t.update(2);
    try testing.expectEqual(2, t.d.deviations.items[0]);
    try testing.expectEqual(Vec3{ 1, 0, 2 }, t.d.placed.items[1]);
    // The reference itself doesn't move.
    try testing.expectEqual(Vec3{ 1, 0, 0 }, t.d.reference.frame.?.positions[1]);
}

test "placed by superposing, RMSD and deviations are the superposition's" {
    var t: TestDiff = try .init();
    defer t.deinit();
    const q = math.Quat.fromAxisAngle(.{ 1, 2, 3 }, 0.8);
    t.current.positions[1][0] = 1.3;
    for (t.current.positions) |*p| p.* = q.rotate(p.*) + Vec3{ 5, 0, -1 };
    const want = superpose(t.d.reference.frame.?.positions, t.current.positions, null);
    t.d.place(want.transform.inverse());
    t.update(1);
    try testing.expectApproxEqAbs(want.rmsd, t.d.result.?.rmsd, 1e-5);
    for (t.d.reference.frame.?.positions, t.current.positions, t.d.deviations.items) |r, p, dev| {
        try testing.expectApproxEqAbs(math.length(want.transform.apply(p) - r), dev, 1e-5);
    }
}

test "other atoms can't be compared, until the same ones are back" {
    var t: TestDiff = try .init();
    defer t.deinit();
    t.d.update(test_gpa, t.current.positions[0..2], .{ .numbers = &.{ 1, 6 } }, 1);
    try testing.expect(t.d.result == null);
    t.d.update(test_gpa, t.current.positions, .{ .numbers = t.current.numbers, .origins = &.{ 0, 1, 7 } }, 2);
    try testing.expect(t.d.result == null);
    t.update(3);
    try testing.expect(t.d.result != null);
}

test "out of memory, it is compared the next time" {
    var t: TestDiff = try .init();
    defer t.deinit();
    for (0..2) |fail_index| {
        t.d.placed.clearAndFree(test_gpa);
        t.d.deviations.clearAndFree(test_gpa);
        t.d.followed = null;
        var failing: testing.FailingAllocator = .init(test_gpa, .{ .fail_index = fail_index });
        t.d.update(failing.allocator(), t.current.positions, .{ .numbers = t.current.numbers }, 1);
        try testing.expect(t.d.result == null);
        t.update(1);
        try testing.expect(t.d.result != null);
    }
    const run = struct {
        fn run(a: Allocator, f: Frame) !void {
            var d: Diff = try .init(a, 0, f, &.{ 0, 1, 2 }, true);
            d.deinit(a);
        }
    }.run;
    try testing.checkAllAllocationFailures(test_gpa, run, .{t.current});
}
