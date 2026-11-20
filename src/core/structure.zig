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
