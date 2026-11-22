//! Alt-drag fragment manipulation (GaussView-style): the usual mouse
//! gestures, but applied to a group of atoms instead of the camera.
//!
//!   Alt + left drag        rotate: the grabbed atom follows the cursor on a
//!                          sphere around the base atom (or a trackball
//!                          rotation about the group centre if there is no base)
//!   Alt + right drag       twist about the base→grabbed axis (or the view axis)
//!   Alt + middle drag,     translate in the view plane
//!   Alt + Shift + left/right
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

pub const Choice = struct {
    /// Atoms to move (owned by the caller).
    group: []u32,
    /// Atom to rotate around; null = rotate about the group's centre.
    pivot: ?u32,
};

/// Decide what an Alt-drag on `handle` moves:
///   - grabbing a selected atom moves the whole selection as one rigid body
///     about its centre (a single selected atom brings its molecule);
///   - with exactly one atom selected (the base), grabbing an unselected atom
///     moves the branch reachable from it without passing through the base
///     (`geometry.beyond`), around the base;
///   - otherwise the grabbed atom's molecule moves about its centre.
/// Grabbing something selected never leaves part of the selection behind
/// (e.g. after a paste, which selects the pasted atoms).
pub fn chooseGroup(gpa: Allocator, graph: cv.geometry.Graph, sel: []const u32, handle: u32) !Choice {
    if (std.mem.indexOfScalar(u32, sel, handle) != null) {
        if (sel.len == 1) return .{ .group = try molecule(gpa, graph, handle), .pivot = null };
        return .{ .group = try gpa.dupe(u32, sel), .pivot = null };
    }
    if (sel.len == 1) return .{ .group = try cv.geometry.beyond(graph, gpa, handle, sel[0]), .pivot = sel[0] };
    return .{ .group = try molecule(gpa, graph, handle), .pivot = null };
}

fn molecule(gpa: Allocator, graph: cv.geometry.Graph, atom: u32) ![]u32 {
    return (try graph.side(gpa, atom, .{ atom, atom }, &.{})) orelse try gpa.dupe(u32, &.{atom});
}

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

test "what an Alt-drag moves" {
    const gpa = std.testing.allocator;
    // Two molecules: chain 0-1-2-3-4 (carbons 1.5 Å apart along x) and a
    // separate C-C pair 5-6 far away.
    var pos: [7]Vec3 = undefined;
    for (pos[0..5], 0..) |*p, i| p.* = .{ 1.5 * @as(f32, @floatFromInt(i)), 0, 0 };
    pos[5] = .{ 0, 20, 0 };
    pos[6] = .{ 1.5, 20, 0 };
    const nums = [_]u8{ 6, 6, 6, 6, 6, 6, 6 };
    const bl = try cv.bonds.find(gpa, &pos, &nums, .{});
    defer gpa.free(bl);
    var g = try cv.geometry.Graph.init(gpa, pos.len, bl, 0.6);
    defer g.deinit(gpa);

    const Case = struct { sel: []const u32, handle: u32, group: []const u32, pivot: ?u32 };
    const cases = [_]Case{
        // One atom selected (the base), grab an unselected atom: branch beyond the base.
        .{ .sel = &.{1}, .handle = 3, .group = &.{ 2, 3, 4 }, .pivot = 1 },
        // Base in another molecule: that whole molecule orbits the base.
        .{ .sel = &.{1}, .handle = 6, .group = &.{ 5, 6 }, .pivot = 1 },
        // Grab a selected atom of a multi-selection (e.g. a paste): all of it, about its centre.
        .{ .sel = &.{ 5, 6 }, .handle = 5, .group = &.{ 5, 6 }, .pivot = null },
        .{ .sel = &.{ 1, 3, 4 }, .handle = 3, .group = &.{ 1, 3, 4 }, .pivot = null },
        // Grab the single selected atom: its molecule about its centre.
        .{ .sel = &.{2}, .handle = 2, .group = &.{ 0, 1, 2, 3, 4 }, .pivot = null },
        // Grab an unselected atom with several selected: its molecule.
        .{ .sel = &.{ 0, 1 }, .handle = 6, .group = &.{ 5, 6 }, .pivot = null },
        // Nothing selected: the whole molecule about its centre.
        .{ .sel = &.{}, .handle = 2, .group = &.{ 0, 1, 2, 3, 4 }, .pivot = null },
    };
    for (cases) |cs| {
        const ch = try chooseGroup(gpa, g, cs.sel, cs.handle);
        defer gpa.free(ch.group);
        std.mem.sort(u32, ch.group, {}, std.sort.asc(u32));
        try std.testing.expectEqualSlices(u32, cs.group, ch.group);
        try std.testing.expectEqual(cs.pivot, ch.pivot);
    }
}
