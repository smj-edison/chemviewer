//! Internal-coordinate measurement and editing.
//!
//! Editing moves whole groups, Chemcraft-style: when atom B is moved
//! relative to atom A, everything reachable from B through the bond graph
//! without passing through A moves with it. If the groups can't be separated
//! (the measured atoms are in a ring), only the atom itself moves.
const std = @import("std");
const math = @import("math.zig");
const bonds_mod = @import("bonds.zig");
const Vec3 = math.Vec3;
const Vec3d = math.Vec3d;
const Allocator = std.mem.Allocator;

fn d3(v: Vec3) Vec3d {
    return @floatCast(v);
}

fn dot(a: Vec3d, b: Vec3d) f64 {
    return @reduce(.Add, a * b);
}

fn cross(a: Vec3d, b: Vec3d) Vec3d {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn norm(a: Vec3d) f64 {
    return @sqrt(dot(a, a));
}

pub fn distance(p: []const Vec3, a: u32, b: u32) f64 {
    return norm(d3(p[b]) - d3(p[a]));
}

/// Angle A-B-C in radians, [0, π].
pub fn angle(p: []const Vec3, a: u32, b: u32, c: u32) f64 {
    const u = d3(p[a]) - d3(p[b]);
    const v = d3(p[c]) - d3(p[b]);
    const cosv = dot(u, v) / @max(norm(u) * norm(v), 1e-300);
    return std.math.acos(std.math.clamp(cosv, -1, 1));
}

/// Dihedral A-B-C-D in radians, (-π, π], IUPAC sign convention.
pub fn dihedral(p: []const Vec3, a: u32, b: u32, c: u32, d: u32) f64 {
    const b1 = d3(p[b]) - d3(p[a]);
    const b2 = d3(p[c]) - d3(p[b]);
    const b3 = d3(p[d]) - d3(p[c]);
    const n1 = cross(b1, b2);
    const n2 = cross(b2, b3);
    return std.math.atan2(norm(b2) * dot(b1, n2), dot(n1, n2));
}

/// Adjacency lists over bonds whose character is at least `min_character`.
pub const Graph = struct {
    start: []u32,
    adj: []u32,

    pub fn init(gpa: Allocator, n: usize, bond_list: []const bonds_mod.Bond, min_character: f32) !Graph {
        const start = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(start);
        @memset(start, 0);
        var m: usize = 0;
        for (bond_list) |b| if (b.character >= min_character) {
            start[b.a + 1] += 1;
            start[b.b + 1] += 1;
            m += 2;
        };
        for (1..n + 1) |i| start[i] += start[i - 1];
        const adj = try gpa.alloc(u32, m);
        errdefer gpa.free(adj);
        const fill = try gpa.dupe(u32, start[0..n]);
        defer gpa.free(fill);
        for (bond_list) |b| if (b.character >= min_character) {
            adj[fill[b.a]] = b.b;
            fill[b.a] += 1;
            adj[fill[b.b]] = b.a;
            fill[b.b] += 1;
        };
        return .{ .start = start, .adj = adj };
    }

    pub fn deinit(g: *Graph, gpa: Allocator) void {
        gpa.free(g.start);
        gpa.free(g.adj);
    }

    pub fn neighbors(g: Graph, i: u32) []const u32 {
        return g.adj[g.start[i]..g.start[i + 1]];
    }

    pub fn atomCount(g: Graph) usize {
        return g.start.len - 1;
    }

    /// Atoms reachable from `from` when the edge `cut` (if it is a bond) is
    /// ignored. Returns null if any `forbidden` atom is reachable, i.e. the
    /// group can't be split off (ring, or same molecule). Caller owns result.
    pub fn side(g: Graph, gpa: Allocator, from: u32, cut: [2]u32, forbidden: []const u32) !?[]u32 {
        const n = g.atomCount();
        const seen = try gpa.alloc(bool, n);
        defer gpa.free(seen);
        @memset(seen, false);
        var out: std.ArrayList(u32) = .empty;
        errdefer out.deinit(gpa);
        seen[from] = true;
        try out.append(gpa, from);
        var head: usize = 0;
        while (head < out.items.len) : (head += 1) {
            const i = out.items[head];
            for (forbidden) |f| if (f == i) {
                out.deinit(gpa);
                return null;
            };
            for (g.neighbors(i)) |j| {
                const is_cut = (i == cut[0] and j == cut[1]) or (i == cut[1] and j == cut[0]);
                if (is_cut or seen[j]) continue;
                seen[j] = true;
                try out.append(gpa, j);
            }
        }
        return try out.toOwnedSlice(gpa);
    }
};

pub const Mode = enum(c_int) {
    /// Both groups move by half the change (the midpoint/centre stays put).
    both,
    /// Only the group of the last selected atom moves.
    last,
};

/// The group moving with `mover`: everything attached to it once the
/// mover–pivot bond is cut (if bonded), or its whole molecule (if not).
/// Falls back to the single atom if that group would include a `fixed` atom.
/// Caller owns the result.
fn group(g: Graph, gpa: Allocator, mover: u32, pivot: u32, fixed: []const u32) ![]u32 {
    if (try g.side(gpa, mover, .{ mover, pivot }, fixed)) |s| return s;
    const one = try gpa.alloc(u32, 1);
    one[0] = mover;
    return one;
}

fn overlap(a: []const u32, b: []const u32) bool {
    for (a) |x| for (b) |y| if (x == y) return true;
    return false;
}

fn translate(p: []Vec3, atoms: []const u32, t: Vec3d) void {
    for (atoms) |i| p[i] = @floatCast(d3(p[i]) + t);
}

/// Rotate `atoms` by `theta` (right-handed) about the axis through `origin`
/// with unit direction `axis` (Rodrigues).
fn rotate(p: []Vec3, atoms: []const u32, origin: Vec3d, axis: Vec3d, theta: f64) void {
    const c = @cos(theta);
    const s = @sin(theta);
    for (atoms) |i| {
        const v = d3(p[i]) - origin;
        const r = v * @as(Vec3d, @splat(c)) + cross(axis, v) * @as(Vec3d, @splat(s)) +
            axis * @as(Vec3d, @splat(dot(axis, v) * (1 - c)));
        p[i] = @floatCast(origin + r);
    }
}

/// Set |AB| to `target` Å, moving B's group (and A's, in `.both` mode).
pub fn setDistance(gpa: Allocator, p: []Vec3, g: Graph, a: u32, b: u32, target: f64, mode: Mode) !void {
    const u = d3(p[b]) - d3(p[a]);
    const len = norm(u);
    if (len < 1e-9 or target <= 0) return;
    const dir = u / @as(Vec3d, @splat(len));
    const delta = target - len;
    const gb = try group(g, gpa, b, a, &.{a});
    defer gpa.free(gb);
    if (mode == .last) return translate(p, gb, dir * @as(Vec3d, @splat(delta)));
    const ga = try group(g, gpa, a, b, &.{b});
    defer gpa.free(ga);
    if (overlap(ga, gb)) {
        translate(p, &.{b}, dir * @as(Vec3d, @splat(delta / 2)));
        translate(p, &.{a}, dir * @as(Vec3d, @splat(-delta / 2)));
        return;
    }
    translate(p, gb, dir * @as(Vec3d, @splat(delta / 2)));
    translate(p, ga, dir * @as(Vec3d, @splat(-delta / 2)));
}

fn anyPerpendicular(v: Vec3d) Vec3d {
    const t: Vec3d = if (@abs(v[0]) < 0.9) .{ 1, 0, 0 } else .{ 0, 1, 0 };
    const c = cross(v, t);
    return c / @as(Vec3d, @splat(norm(c)));
}

/// Set angle A-B-C to `target` radians by rotating C's group about B (and
/// A's group the other way in `.both` mode).
pub fn setAngle(gpa: Allocator, p: []Vec3, g: Graph, a: u32, b: u32, c: u32, target: f64, mode: Mode) !void {
    const vb = d3(p[b]);
    const u = d3(p[a]) - vb;
    const v = d3(p[c]) - vb;
    var n = cross(u, v);
    const nn = norm(n);
    n = if (nn > 1e-9) n / @as(Vec3d, @splat(nn)) else anyPerpendicular(u);
    const delta = target - angle(p, a, b, c);
    const gc = try group(g, gpa, c, b, &.{ a, b });
    defer gpa.free(gc);
    if (mode == .last) return rotate(p, gc, vb, n, delta);
    const ga = try group(g, gpa, a, b, &.{ b, c });
    defer gpa.free(ga);
    if (overlap(ga, gc)) {
        rotate(p, &.{c}, vb, n, delta / 2);
        rotate(p, &.{a}, vb, n, -delta / 2);
        return;
    }
    rotate(p, gc, vb, n, delta / 2);
    rotate(p, ga, vb, n, -delta / 2);
}

fn wrapAngle(x: f64) f64 {
    var y = @mod(x + std.math.pi, 2 * std.math.pi);
    if (y < 0) y += 2 * std.math.pi;
    return y - std.math.pi;
}

/// Set dihedral A-B-C-D to `target` radians by rotating about the B-C axis:
/// C's side moves (and B's side the other way in `.both` mode).
pub fn setDihedral(gpa: Allocator, p: []Vec3, g: Graph, a: u32, b: u32, c: u32, d: u32, target: f64, mode: Mode) !void {
    const vb = d3(p[b]);
    const axis_v = d3(p[c]) - vb;
    const l = norm(axis_v);
    if (l < 1e-9) return;
    const axis = axis_v / @as(Vec3d, @splat(l));
    // Right-handed rotation of the far side about B→C increases the IUPAC dihedral.
    const delta = wrapAngle(target - dihedral(p, a, b, c, d));
    // C's side of the B-C bond; if B-C is in a ring, just D's group (cut at C).
    const gc = (try g.side(gpa, c, .{ c, b }, &.{ a, b })) orelse try group(g, gpa, d, c, &.{ a, b, c });
    defer gpa.free(gc);
    if (mode == .last) return rotate(p, gc, vb, axis, delta);
    const gb = (try g.side(gpa, b, .{ b, c }, &.{ c, d })) orelse try group(g, gpa, a, b, &.{ b, c, d });
    defer gpa.free(gb);
    if (overlap(gb, gc)) {
        rotate(p, &.{d}, vb, axis, delta / 2);
        rotate(p, &.{a}, vb, axis, -delta / 2);
        return;
    }
    rotate(p, gc, vb, axis, delta / 2);
    rotate(p, gb, vb, axis, -delta / 2);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Butane-like chain 0-1-2-3 with an H on each end carbon.
fn chain() struct { p: [6]Vec3, nums: [6]u8 } {
    return .{
        .p = .{
            .{ 0, 0, 0 },         .{ 1.53, 0, 0 },    .{ 2.04, 1.44, 0 },
            .{ 3.57, 1.44, 0.3 }, .{ -0.4, -1.0, 0 }, .{ 4.0, 2.4, 0.5 },
        },
        .nums = .{ 6, 6, 6, 6, 1, 1 },
    };
}

fn graphOf(gpa: Allocator, p: []const Vec3, nums: []const u8) !Graph {
    const bl = try bonds_mod.find(gpa, p, nums, .{});
    defer gpa.free(bl);
    return Graph.init(gpa, p.len, bl, 0.6);
}

test "distance edit moves the whole group" {
    const gpa = testing.allocator;
    var c = chain();
    var g = try graphOf(gpa, &c.p, &c.nums);
    defer g.deinit(gpa);
    const h_before = c.p[5];
    const d_before = distance(&c.p, 2, 3);
    try setDistance(gpa, &c.p, g, 2, 3, 2.0, .last);
    try testing.expectApproxEqAbs(@as(f64, 2.0), distance(&c.p, 2, 3), 1e-5);
    // H on atom 3 moved by the same displacement; atoms 0-2 stayed.
    try testing.expectApproxEqAbs(@as(f64, 2.0 - d_before), distance(&.{ h_before, c.p[5] }, 0, 1), 1e-5);
    try testing.expectEqual(chain().p[0], c.p[0]);

    var c2 = chain();
    try setDistance(gpa, &c2.p, g, 1, 2, 1.8, .both);
    try testing.expectApproxEqAbs(@as(f64, 1.8), distance(&c2.p, 1, 2), 1e-5);
    try testing.expect(c2.p[0][0] < chain().p[0][0]); // left side moved left
}

test "angle edit, both modes" {
    const gpa = testing.allocator;
    var c = chain();
    var g = try graphOf(gpa, &c.p, &c.nums);
    defer g.deinit(gpa);
    const target = std.math.degreesToRadians(@as(f64, 120));
    try setAngle(gpa, &c.p, g, 0, 1, 2, target, .last);
    try testing.expectApproxEqAbs(target, angle(&c.p, 0, 1, 2), 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 1.53), distance(&c.p, 0, 1), 1e-4);
    var c2 = chain();
    try setAngle(gpa, &c2.p, g, 0, 1, 2, target, .both);
    try testing.expectApproxEqAbs(target, angle(&c2.p, 0, 1, 2), 1e-5);
}

test "dihedral edit hits the target with either sign" {
    const gpa = testing.allocator;
    for ([_]f64{ 60, -60, 180, -179, 0 }) |deg| for ([_]Mode{ .last, .both }) |mode| {
        var c = chain();
        var g = try graphOf(gpa, &c.p, &c.nums);
        defer g.deinit(gpa);
        const target = std.math.degreesToRadians(deg);
        try setDihedral(gpa, &c.p, g, 0, 1, 2, 3, target, mode);
        try testing.expectApproxEqAbs(@as(f64, 0), wrapAngle(dihedral(&c.p, 0, 1, 2, 3) - target), 1e-5);
        // Bond lengths are preserved by the rotation.
        try testing.expectApproxEqAbs(distance(&chain().p, 2, 3), distance(&c.p, 2, 3), 1e-4);
    };
}

test "ring falls back to moving the single atom" {
    const gpa = testing.allocator;
    // Cyclopropane-ish triangle: 0-1-2 all bonded.
    var p = [_]Vec3{ .{ 0, 0, 0 }, .{ 1.5, 0, 0 }, .{ 0.75, 1.3, 0 } };
    const nums = [_]u8{ 6, 6, 6 };
    var g = try graphOf(gpa, &p, &nums);
    defer g.deinit(gpa);
    try setDistance(gpa, &p, g, 0, 1, 1.7, .last);
    try testing.expectApproxEqAbs(@as(f64, 1.7), distance(&p, 0, 1), 1e-5);
    try testing.expectEqual(Vec3{ 0.75, 1.3, 0 }, p[2]);
}

test "non-bonded atoms in different molecules move whole molecules" {
    const gpa = testing.allocator;
    // Two H2 molecules side by side.
    var p = [_]Vec3{ .{ 0, 0, 0 }, .{ 0.74, 0, 0 }, .{ 0, 3, 0 }, .{ 0.74, 3, 0 } };
    const nums = [_]u8{ 1, 1, 1, 1 };
    var g = try graphOf(gpa, &p, &nums);
    defer g.deinit(gpa);
    try setDistance(gpa, &p, g, 0, 2, 4.0, .last);
    try testing.expectApproxEqAbs(@as(f64, 4.0), distance(&p, 0, 2), 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 0.74), distance(&p, 2, 3), 1e-5); // partner came along
}

test "dihedral sign convention" {
    // Standard check: A above, D rotated +90° about B→C (right-handed) gives +90°.
    const p = [_]Vec3{ .{ 0, 1, 0 }, .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 1 } };
    try testing.expectApproxEqAbs(@as(f64, 90), std.math.radiansToDegrees(dihedral(&p, 0, 1, 2, 3)), 1e-4);
}
