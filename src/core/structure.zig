//! A single structure (one frame of a trajectory).
const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Allocator = std.mem.Allocator;

pub const Frame = struct {
    /// Cartesian positions in Ångström.
    positions: []Vec3,
    /// Atomic numbers (0 = dummy / unknown).
    numbers: []u8,
    /// Lattice vectors as rows (a, b, c) in Å, if periodic.
    cell: ?[3]Vec3 = null,
    /// Total energy in the file's native unit (Hartree for QM codes, eV for ASE).
    energy: ?f64 = null,
    /// Free-form comment (XYZ line 2, Gaussian title, ...). Owned.
    comment: []const u8 = "",

    pub fn init(gpa: Allocator, n: usize) !Frame {
        const positions = try gpa.alloc(Vec3, n);
        errdefer gpa.free(positions);
        const numbers = try gpa.alloc(u8, n);
        return .{ .positions = positions, .numbers = numbers };
    }

    pub fn deinit(f: *Frame, gpa: Allocator) void {
        gpa.free(f.positions);
        gpa.free(f.numbers);
        if (f.comment.len > 0) gpa.free(f.comment);
        f.* = undefined;
    }

    pub fn clone(f: Frame, gpa: Allocator) !Frame {
        var r = try Frame.init(gpa, f.len());
        errdefer r.deinit(gpa);
        @memcpy(r.positions, f.positions);
        @memcpy(r.numbers, f.numbers);
        r.cell = f.cell;
        r.energy = f.energy;
        r.comment = if (f.comment.len > 0) try gpa.dupe(u8, f.comment) else "";
        return r;
    }

    /// A new frame with just the given atoms (in the given order). The cell
    /// is kept, the energy is not (it belongs to the whole frame).
    pub fn subset(f: Frame, gpa: Allocator, atoms: []const u32) !Frame {
        var r = try Frame.init(gpa, atoms.len);
        for (atoms, 0..) |a, i| {
            r.positions[i] = f.positions[a];
            r.numbers[i] = f.numbers[a];
        }
        r.cell = f.cell;
        return r;
    }

    /// A new frame with `extra`'s atoms appended (shifted by `offset`).
    /// Cell and comment come from `f`; the energy is dropped.
    pub fn concat(f: Frame, gpa: Allocator, extra: Frame, offset: Vec3) !Frame {
        const n = f.len();
        var r = try Frame.init(gpa, n + extra.len());
        errdefer r.deinit(gpa);
        @memcpy(r.positions[0..n], f.positions);
        @memcpy(r.numbers[0..n], f.numbers);
        for (r.positions[n..], extra.positions) |*d, p| d.* = p + offset;
        @memcpy(r.numbers[n..], extra.numbers);
        r.cell = f.cell;
        r.comment = if (f.comment.len > 0) try gpa.dupe(u8, f.comment) else "";
        return r;
    }

    /// Smallest distance between any atom of `a` and any atom of `b`.
    pub fn minDistance(a: Frame, b: Frame) f32 {
        var best: f32 = std.math.inf(f32);
        for (a.positions) |p| for (b.positions) |q| {
            best = @min(best, math.length2(p - q));
        };
        return @sqrt(best);
    }

    pub fn len(f: Frame) usize {
        return f.positions.len;
    }

    /// Approximate heap footprint, used by the frame cache's byte budget.
    pub fn byteSize(f: Frame) usize {
        return f.positions.len * @sizeOf(Vec3) + f.numbers.len + f.comment.len + @sizeOf(Frame);
    }

    pub const Bounds = struct { min: Vec3, max: Vec3 };

    pub fn bounds(f: Frame) Bounds {
        if (f.positions.len == 0) return .{ .min = @splat(0), .max = @splat(0) };
        var lo: Vec3 = f.positions[0];
        var hi: Vec3 = f.positions[0];
        for (f.positions[1..]) |p| {
            lo = @min(lo, p);
            hi = @max(hi, p);
        }
        return .{ .min = lo, .max = hi };
    }

    pub fn centroid(f: Frame) Vec3 {
        if (f.positions.len == 0) return @splat(0);
        var s: math.Vec3d = @splat(0);
        for (f.positions) |p| s += @floatCast(p);
        return @floatCast(s / @as(math.Vec3d, @splat(@floatFromInt(f.positions.len))));
    }
};

/// Growable list of atoms used by parsers before the count is known.
pub const FrameBuilder = struct {
    positions: std.ArrayList(Vec3) = .empty,
    numbers: std.ArrayList(u8) = .empty,

    pub fn append(b: *FrameBuilder, gpa: Allocator, z: u8, p: Vec3) !void {
        try b.positions.append(gpa, p);
        try b.numbers.append(gpa, z);
    }

    pub fn len(b: FrameBuilder) usize {
        return b.positions.items.len;
    }

    /// Transfers ownership to a Frame and resets the builder.
    pub fn finish(b: *FrameBuilder, gpa: Allocator) !Frame {
        const positions = try b.positions.toOwnedSlice(gpa);
        errdefer gpa.free(positions);
        const numbers = try b.numbers.toOwnedSlice(gpa);
        return .{ .positions = positions, .numbers = numbers };
    }

    pub fn deinit(b: *FrameBuilder, gpa: Allocator) void {
        b.positions.deinit(gpa);
        b.numbers.deinit(gpa);
    }

    pub fn clear(b: *FrameBuilder) void {
        b.positions.clearRetainingCapacity();
        b.numbers.clearRetainingCapacity();
    }
};

test "subset" {
    const gpa = std.testing.allocator;
    var f = try Frame.init(gpa, 3);
    defer f.deinit(gpa);
    for (f.positions, 0..) |*p, i| p.* = @splat(@floatFromInt(i));
    @memcpy(f.numbers, &[_]u8{ 1, 6, 8 });
    f.energy = -1;
    var s = try f.subset(gpa, &.{ 2, 0 });
    defer s.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 8, 1 }, s.numbers);
    try std.testing.expectEqual(@as(f32, 2), s.positions[0][0]);
    try std.testing.expectEqual(@as(?f64, null), s.energy);
}

test "concat" {
    const gpa = std.testing.allocator;
    var a = try Frame.init(gpa, 1);
    defer a.deinit(gpa);
    a.positions[0] = .{ 0, 0, 0 };
    a.numbers[0] = 6;
    a.energy = -1;
    var b = try Frame.init(gpa, 2);
    defer b.deinit(gpa);
    b.positions[0] = .{ 1, 0, 0 };
    b.positions[1] = .{ 2, 0, 0 };
    @memcpy(b.numbers, &[_]u8{ 1, 8 });
    var c = try a.concat(gpa, b, .{ 0, 5, 0 });
    defer c.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 6, 1, 8 }, c.numbers);
    try std.testing.expectEqual(math.Vec3{ 2, 5, 0 }, c.positions[2]);
    try std.testing.expectEqual(@as(?f64, null), c.energy);
    try std.testing.expectApproxEqAbs(@as(f32, 1), a.minDistance(b), 1e-6);
}
