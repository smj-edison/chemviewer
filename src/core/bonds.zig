//! Continuous bond-character detection. See docs/BONDS.md.
const std = @import("std");
const math = @import("math.zig");
const elements = @import("elements.zig");
const Vec3 = math.Vec3;
const Allocator = std.mem.Allocator;

pub const Bond = struct {
    a: u32,
    b: u32,
    /// Continuous bond character in [0, 3]: 1 = single length, 2 = double, 3 = triple.
    character: f32,
};

pub const Params = struct {
    /// A pair is considered when d < cutoff_factor * r_single(A,B).
    cutoff_factor: f32 = 1.50,
};

/// Reference bond lengths (Å) for one element pair, longest (single) first.
pub const PairRef = struct {
    /// r[0] = single, r[1] = double, r[2] = triple; `orders` says how many are valid.
    r: [3]f32,
    orders: u2,

    pub fn of(za: u8, zb: u8) PairRef {
        var ref: PairRef = .{ .r = .{ 0, 0, 0 }, .orders = 0 };
        var order: u2 = 1;
        while (true) : (order += 1) {
            const ra = elements.covalentRadius(za, order) orelse break;
            const rb = elements.covalentRadius(zb, order) orelse break;
            const r = ra + rb;
            // Require strictly decreasing lengths, otherwise the order adds no information.
            if (order > 1 and r >= ref.r[order - 2]) break;
            ref.r[order - 1] = r;
            ref.orders = order;
            if (order == 3) break;
        }
        if (overrideSingle(za, zb)) |r1| ref.r[0] = r1;
        if (ref.orders == 0) {
            ref.r[0] = 3.0; // Unknown elements: generic 1.5 Å radii.
            ref.orders = 1;
        }
        return ref;
    }
};

/// Pairs where the additive radii model is noticeably off.
fn overrideSingle(za: u8, zb: u8) ?f32 {
    if (za == 1 and zb == 1) return 0.74;
    return null;
}

/// Map an interatomic distance to bond character (see docs/BONDS.md).
/// Returns null if the pair is beyond the cutoff.
pub fn character(ref: PairRef, d: f32, params: Params) ?f32 {
    const r1 = ref.r[0];
    const rc = params.cutoff_factor * r1;
    if (d >= rc) return null;
    if (d >= r1) return (rc - d) / (rc - r1);
    var lo_order: f32 = 1;
    var i: usize = 1;
    while (i < ref.orders) : (i += 1) {
        const hi = ref.r[i - 1];
        const lo = ref.r[i];
        if (d >= lo) return lo_order + (hi - d) / (hi - lo);
        lo_order += 1;
    }
    return lo_order;
}

/// Precomputed pair table over the elements present in a frame.
/// Dense k×k table over the k distinct elements in the frame.
pub const PairTable = struct {
    /// Z → compact index (0xFF = absent).
    index: [256]u8,
    k: usize,
    refs: []PairRef,
    max_cutoff: f32,

    pub fn deinit(t: *PairTable, gpa: Allocator) void {
        gpa.free(t.refs);
    }

    pub fn build(gpa: Allocator, numbers: []const u8, params: Params) !PairTable {
        var index: [256]u8 = @splat(0xFF);
        var zs: [256]u8 = undefined;
        var k: usize = 0;
        for (numbers) |z| {
            if (index[z] == 0xFF) {
                index[z] = @intCast(k);
                zs[k] = z;
                k += 1;
            }
        }
        const refs = try gpa.alloc(PairRef, k * k);
        var max_cutoff: f32 = 0;
        for (0..k) |a| for (0..k) |b| {
            const ref = PairRef.of(zs[a], zs[b]);
            refs[a * k + b] = ref;
            max_cutoff = @max(max_cutoff, ref.r[0] * params.cutoff_factor);
        };
        return .{ .index = index, .k = k, .refs = refs, .max_cutoff = max_cutoff };
    }

    pub fn get(t: PairTable, za: u8, zb: u8) PairRef {
        return t.refs[@as(usize, t.index[za]) * t.k + t.index[zb]];
    }
};

/// Find every candidate bond in a frame using a uniform spatial hash.
/// Caller owns the returned slice.
pub fn find(
    gpa: Allocator,
    positions: []const Vec3,
    numbers: []const u8,
    params: Params,
) ![]Bond {
    var out: std.ArrayList(Bond) = .empty;
    errdefer out.deinit(gpa);
    try findInto(gpa, &out, positions, numbers, params);
    return out.toOwnedSlice(gpa);
}

pub fn findInto(
    gpa: Allocator,
    out: *std.ArrayList(Bond),
    positions: []const Vec3,
    numbers: []const u8,
    params: Params,
) !void {
    out.clearRetainingCapacity();
    const n = positions.len;
    if (n < 2) return;

    var table = try PairTable.build(gpa, numbers, params);
    defer table.deinit(gpa);
    const cell = @max(table.max_cutoff, 0.5);

    var lo: Vec3 = positions[0];
    var hi: Vec3 = positions[0];
    for (positions) |p| {
        lo = @min(lo, p);
        hi = @max(hi, p);
    }
    const ext = (hi - lo) / math.splat(cell);
    // Clamp grid dimensions so a few far-flung atoms can't explode memory.
    const max_dim: f32 = 1024;
    const dims = [3]u32{
        @intFromFloat(@min(@floor(ext[0]), max_dim) + 1),
        @intFromFloat(@min(@floor(ext[1]), max_dim) + 1),
        @intFromFloat(@min(@floor(ext[2]), max_dim) + 1),
    };
    const ncells: usize = @as(usize, dims[0]) * dims[1] * dims[2];

    // Counting sort of atoms into cells: `start[c]..start[c+1]` indexes `sorted`.
    const cell_of = try gpa.alloc(u32, n);
    defer gpa.free(cell_of);
    const start = try gpa.alloc(u32, ncells + 1);
    defer gpa.free(start);
    const sorted = try gpa.alloc(u32, n);
    defer gpa.free(sorted);
    @memset(start, 0);

    const Grid = struct {
        dims: [3]u32,
        fn coord(g: @This(), v: f32, axis: usize) u32 {
            const i: i64 = @intFromFloat(@floor(v));
            return @intCast(std.math.clamp(i, 0, @as(i64, g.dims[axis]) - 1));
        }
        fn index(g: @This(), x: u32, y: u32, z: u32) u32 {
            return (z * g.dims[1] + y) * g.dims[0] + x;
        }
    };
    const grid: Grid = .{ .dims = dims };

    for (positions, 0..) |p, i| {
        const g = (p - lo) / math.splat(cell);
        const c = grid.index(grid.coord(g[0], 0), grid.coord(g[1], 1), grid.coord(g[2], 2));
        cell_of[i] = c;
        start[c + 1] += 1;
    }
    for (1..ncells + 1) |c| start[c] += start[c - 1];
    {
        const fill = try gpa.dupe(u32, start[0..ncells]);
        defer gpa.free(fill);
        for (cell_of, 0..) |c, i| {
            sorted[fill[c]] = @intCast(i);
            fill[c] += 1;
        }
    }

    for (0..n) |i| {
        const c = cell_of[i];
        const cx = c % dims[0];
        const cy = (c / dims[0]) % dims[1];
        const cz = c / (dims[0] * dims[1]);
        const pi = positions[i];
        const zi = numbers[i];
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            const z = @as(i64, cz) + dz;
            if (z < 0 or z >= dims[2]) continue;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                const y = @as(i64, cy) + dy;
                if (y < 0 or y >= dims[1]) continue;
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const x = @as(i64, cx) + dx;
                    if (x < 0 or x >= dims[0]) continue;
                    const nc = grid.index(@intCast(x), @intCast(y), @intCast(z));
                    for (sorted[start[nc]..start[nc + 1]]) |j| {
                        if (j <= i) continue;
                        const d = math.length(positions[j] - pi);
                        const ref = table.get(zi, numbers[j]);
                        if (character(ref, d, params)) |ch| {
                            try out.append(gpa, .{ .a = @intCast(i), .b = j, .character = ch });
                        }
                    }
                }
            }
        }
    }
}

test "character is continuous and ordered for C-C" {
    const ref = PairRef.of(6, 6);
    try std.testing.expectEqual(@as(u2, 3), ref.orders);
    const p: Params = .{};
    try std.testing.expectApproxEqAbs(@as(f32, 1), character(ref, 1.50, p).?, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), character(ref, 1.34, p).?, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), character(ref, 1.20, p).?, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), character(ref, 1.00, p).?, 1e-5);
    // Benzene ~1.39 Å sits between single and double.
    const ar = character(ref, 1.39, p).?;
    try std.testing.expect(ar > 1.5 and ar < 1.8);
    try std.testing.expectEqual(@as(?f32, null), character(ref, 2.3, p));
    // Monotonic.
    var prev: f32 = 4;
    var d: f32 = 1.0;
    while (d < 2.24) : (d += 0.01) {
        const ch = character(ref, d, p).?;
        try std.testing.expect(ch <= prev + 1e-6);
        prev = ch;
    }
}

test "H only has single" {
    const ref = PairRef.of(1, 6);
    try std.testing.expectEqual(@as(u2, 1), ref.orders);
    try std.testing.expectApproxEqAbs(@as(f32, 1), character(ref, 0.9, .{}).?, 1e-6);
}

test "find bonds in ethylene-like geometry" {
    const gpa = std.testing.allocator;
    const pos = [_]Vec3{
        .{ 0, 0, 0 }, .{ 1.34, 0, 0 }, // C=C
        .{ -0.55, 0.93, 0 }, .{ -0.55, -0.93, 0 }, // H on C0
        .{ 10, 10, 10 }, // far-away He
    };
    const nums = [_]u8{ 6, 6, 1, 1, 2 };
    const bonds = try find(gpa, &pos, &nums, .{});
    defer gpa.free(bonds);
    var cc: ?f32 = null;
    for (bonds) |b| {
        if (b.a == 0 and b.b == 1) cc = b.character;
        try std.testing.expect(b.a != 4 and b.b != 4);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 2), cc.?, 1e-4);
    try std.testing.expectEqual(@as(usize, 3), bonds.len);
}
