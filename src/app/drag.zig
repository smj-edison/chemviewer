//! Alt-drag fragment manipulation (GaussView-style): the usual mouse
//! gestures, but applied to a group of atoms instead of the camera.
//!
//!   Alt + left drag        rotate: the grabbed atom follows the cursor on a
//!                          sphere around the base atom (or a trackball
//!                          rotation about the group centre if there is no base)
//!   Alt + right drag       twist about the base→grabbed axis (or the view axis)
//!   Alt + middle drag,     translate in the view plane
//!   Alt + Shift + left
//!
//! Positions are always recomputed from the snapshot taken when the drag
//! started, so there is no drift.
const std = @import("std");
const cv = @import("chemviewer");
const math = cv.math;
const Vec3 = math.Vec3;
const Quat = math.Quat;
const Allocator = std.mem.Allocator;

pub const Kind = enum { rotate, twist, translate };

pub const Drag = struct {
    kind: Kind,
    /// Base atom the group rotates around (null: rotate about the group centre).
    pivot: ?u32,
    /// The atom that was grabbed.
    handle: u32,
    /// Atoms being moved, and their positions when the drag started.
    group: []u32,
    start: []Vec3,
    /// Rotation centre: the pivot, or the group's centroid.
    center: Vec3,
    /// Grabbed atom relative to the centre at drag start.
    v0: Vec3,
    /// For sphere-follow: keep the grabbed atom on the hemisphere it started on.
    near_side: bool,

    rotation: Quat = .identity,
    twist: f32 = 0,
    offset: Vec3 = .{ 0, 0, 0 },
    moved: bool = false,

    pub fn deinit(d: *Drag, gpa: Allocator) void {
        gpa.free(d.group);
        gpa.free(d.start);
    }

    /// Write the dragged positions of the group into `positions`.
    pub fn apply(d: Drag, positions: []Vec3, view_axis: Vec3) void {
        const twist_axis = if (d.pivot != null and math.length2(d.v0) > 1e-12) math.normalize(d.v0) else view_axis;
        const tq = Quat.fromAxisAngle(twist_axis, d.twist);
        for (d.group, d.start) |i, p| {
            const rel = p - d.center;
            const r = d.rotation.mul(tq).rotate(rel);
            positions[i] = d.center + r + d.offset;
        }
    }
};

/// Point where the cursor ray meets the sphere (center, radius) on the chosen
/// side; if the ray misses, the sphere point closest to the ray.
pub fn spherePoint(origin: Vec3, dir: Vec3, center: Vec3, radius: f32, near_side: bool) Vec3 {
    const oc = origin - center;
    const b = math.dot(oc, dir);
    const disc = b * b - (math.dot(oc, oc) - radius * radius);
    if (disc >= 0) {
        const s = @sqrt(disc);
        const t = if (near_side) -b - s else -b + s;
        return origin + dir * math.splat(t);
    }
    const closest = origin + dir * math.splat(-b);
    return center + math.normalize(closest - center) * math.splat(radius);
}

test "sphere-follow puts the grabbed atom under the cursor" {
    // Camera at z = 10 looking down -z; pivot at origin; atom at (1.5, 0, 0).
    const origin: Vec3 = .{ 0, 0, 10 };
    const center: Vec3 = .{ 0, 0, 0 };
    const v0: Vec3 = .{ 1.5, 0, 0 };
    // Aim the cursor at a point that lies on the sphere: (0, 1.2, 0.9).
    const target: Vec3 = .{ 0, 1.2, 0.9 };
    const dir = math.normalize(target - origin);
    const p = spherePoint(origin, dir, center, 1.5, true);
    try std.testing.expect(math.length(p - target) < 1e-4);

    const gpa = std.testing.allocator;
    var d: Drag = .{
        .kind = .rotate,
        .pivot = 0,
        .handle = 1,
        .group = try gpa.dupe(u32, &.{ 1, 2 }),
        .start = try gpa.dupe(Vec3, &.{ v0, .{ 2.5, 0, 0 } }),
        .center = center,
        .v0 = v0,
        .near_side = true,
    };
    defer d.deinit(gpa);
    d.rotation = Quat.fromTo(v0, p - center);
    var pos = [_]Vec3{ center, v0, .{ 2.5, 0, 0 } };
    d.apply(&pos, .{ 0, 0, 1 });
    try std.testing.expect(math.length(pos[1] - target) < 1e-4);
    // The rest of the group moved rigidly: distances to the grabbed atom kept.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), math.length(pos[2] - pos[1]), 1e-4);
    try std.testing.expectEqual(center, pos[0]); // pivot untouched
}

test "twist keeps the axis atoms fixed" {
    const gpa = std.testing.allocator;
    const v0: Vec3 = .{ 1.5, 0, 0 };
    var d: Drag = .{
        .kind = .twist,
        .pivot = 0,
        .handle = 1,
        .group = try gpa.dupe(u32, &.{ 1, 2 }),
        .start = try gpa.dupe(Vec3, &.{ v0, .{ 2.0, 1.0, 0 } }),
        .center = .{ 0, 0, 0 },
        .v0 = v0,
        .near_side = true,
    };
    defer d.deinit(gpa);
    d.twist = std.math.pi / 2.0;
    var pos = [_]Vec3{ .{ 0, 0, 0 }, v0, .{ 2.0, 1.0, 0 } };
    d.apply(&pos, .{ 0, 0, 1 });
    try std.testing.expect(math.length(pos[1] - v0) < 1e-5); // on the axis
    try std.testing.expect(@abs(pos[2][1]) < 1e-5 and @abs(@abs(pos[2][2]) - 1.0) < 1e-5);
}
