//! The rotation lock: keeps frames oriented like an anchor by saying how the
//! view must move with each of them (D21, D26). It never moves atoms.
const std = @import("std");
const Allocator = std.mem.Allocator;
const align_ = @import("core/align.zig");
const math = @import("core/math.zig");
const Vec3 = math.Vec3;
const Numbering = @import("picks.zig").Numbering;

/// What was at `rot * (p - from) + to` is now at p.
pub const Motion = struct { rot: math.Mat3, from: Vec3, to: Vec3 };

pub const RotationLock = struct {
    /// The drawn positions it started at, and their numbering.
    anchor: []Vec3,
    numbers: []u8,
    origins: ?[]u32,
    /// Superposition of what was followed last onto the anchor.
    current: align_.Transform = .identity,

    /// Start with these positions as the anchor.
    pub fn init(gpa: Allocator, positions: []const Vec3, numbering: Numbering) !RotationLock {
        const anchor = try gpa.dupe(Vec3, positions);
        errdefer gpa.free(anchor);
        const numbers = try gpa.dupe(u8, numbering.numbers);
        errdefer gpa.free(numbers);
        const origins = if (numbering.origins) |o| try gpa.dupe(u32, o) else null;
        return .{ .anchor = anchor, .numbers = numbers, .origins = origins };
    }

    pub fn deinit(l: *RotationLock, gpa: Allocator) void {
        gpa.free(l.anchor);
        gpa.free(l.numbers);
        if (l.origins) |o| gpa.free(o);
        l.* = undefined;
    }

    /// How these positions moved from the ones followed last, or null if they
    /// aren't the anchor's atoms. Both are superposed onto the anchor, so the
    /// view of a frame doesn't depend on the path taken to it.
    pub fn follow(l: *RotationLock, positions: []const Vec3, numbering: Numbering) ?Motion {
        const anchored: Numbering = .{ .numbers = l.numbers, .origins = l.origins };
        if (!anchored.eql(numbering)) return null;
        const next = align_.superpose(l.anchor, positions, null).transform;
        const motion = between(l.current, next);
        l.current = next;
        return motion;
    }

    /// M = current⁻¹ ∘ next. With T(p) = R (p - from) + to:
    /// M(p) = curᵀ next (p - next.from) + curᵀ (next.to - cur.to) + cur.from.
    fn between(cur: align_.Transform, next: align_.Transform) Motion {
        var rot: math.Mat3 = undefined;
        for (0..3) |row| for (0..3) |col| {
            var s: f64 = 0;
            for (0..3) |k| s += cur.rot[k][row] * next.rot[k][col];
            rot.m[col][row] = @floatCast(s);
        };
        const dt = next.to_center - cur.to_center;
        const to = cur.from_center + math.Vec3d{
            cur.rot[0][0] * dt[0] + cur.rot[1][0] * dt[1] + cur.rot[2][0] * dt[2],
            cur.rot[0][1] * dt[0] + cur.rot[1][1] * dt[1] + cur.rot[2][1] * dt[2],
            cur.rot[0][2] * dt[0] + cur.rot[1][2] * dt[1] + cur.rot[2][2] * dt[2],
        };
        return .{ .rot = rot, .from = @floatCast(next.from_center), .to = @floatCast(to) };
    }
};

// --------------------------------------------------------------- tests

const testing = std.testing;
const test_gpa = testing.allocator;

const test_atoms = [_]Vec3{ .{ 0, 0, 0 }, .{ 3, 0, 0 }, .{ 0, 4, 1 }, .{ -3, 1, 2 } };
const test_numbering: Numbering = .{ .numbers = &.{ 1, 6, 7, 8 } };

fn turned(angle: f32) [4]Vec3 {
    const q = math.Quat.fromAxisAngle(.{ 0.2, -1, 0.5 }, angle);
    var out: [4]Vec3 = undefined;
    for (&out, test_atoms) |*o, p| o.* = q.rotate(p) + Vec3{ angle, 2, -angle };
    return out;
}

test "a motion maps each atom to where it was before" {
    var l: RotationLock = try .init(test_gpa, &turned(0), test_numbering);
    defer l.deinit(test_gpa);
    var before = turned(0);
    for ([_]f32{ 0.4, 2.5, -1, 0 }) |angle| {
        const now = turned(angle);
        const m = l.follow(&now, test_numbering).?;
        for (before, now) |b, p| try testing.expect(math.length(m.rot.mulVec(p - m.from) + m.to - b) < 1e-4);
        before = now;
    }
}

test "other atoms aren't followed" {
    var l: RotationLock = try .init(test_gpa, &turned(0), test_numbering);
    defer l.deinit(test_gpa);
    const now = turned(1);
    try testing.expect(l.follow(&now, .{ .numbers = &.{ 1, 6, 7, 7 } }) == null);
    try testing.expect(l.follow(now[0..3], .{ .numbers = &.{ 1, 6, 7 } }) == null);
    try testing.expect(l.follow(&now, .{ .numbers = &.{ 1, 6, 7, 8 }, .origins = &.{ 0, 1, 2, 9 } }) == null);
    // It goes on from where it was.
    const before = turned(0);
    const m = l.follow(&now, test_numbering).?;
    for (before, now) |b, p| try testing.expect(math.length(m.rot.mulVec(p - m.from) + m.to - b) < 1e-4);
}

test "starting is all or nothing" {
    const run = struct {
        fn run(a: Allocator) !void {
            var l: RotationLock = try .init(a, &turned(0), .{ .numbers = &.{ 1, 6, 7, 8 }, .origins = &.{ 0, 1, 2, 9 } });
            l.deinit(a);
        }
    }.run;
    try testing.checkAllAllocationFailures(test_gpa, run, .{});
}
