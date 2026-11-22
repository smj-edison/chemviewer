//! Layer assignment for translucent glass (Renderer's glass style).
//!
//! Glass refracts a snapshot of the scene, so whatever a glass object shows
//! through it must already be drawn when the snapshot is taken. Objects are
//! drawn in layers, with a fresh snapshot before each. Every object is a
//! screen-space capsule (an atom is one with zero length, a bond half a
//! segment). Going from far to near, each goes one layer above the farthest-
//! placed objects it overlaps on screen, so objects sharing a layer never
//! overlap and one snapshot per layer is exact.
const std = @import("std");
const Allocator = std.mem.Allocator;

const V2 = @Vector(2, f32);

/// A screen-space capsule: segment `a`-`b` (pixels from the screen centre)
/// widened by `r`, at view depth `z`. `layer` is the output.
pub const Item = struct {
    a: V2,
    b: V2,
    r: f32,
    z: f32,
    /// The caller's index (into its atoms or bond halves).
    index: u32,
    bond: bool,
    layer: u32 = 0,
};

/// Grid cell size in pixels. Items are entered in every cell their bounding
/// box touches, so this only trades list length against entry count.
const cell = 48.0;
const none = std.math.maxInt(u32);

pub const Scratch = struct {
    heads: std.ArrayList(u32) = .empty,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { item: u32, next: u32 };

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.heads.deinit(gpa);
        s.entries.deinit(gpa);
    }
};

/// Far to near (sort order for `assign`).
pub fn farther(_: void, x: Item, y: Item) bool {
    return x.z > y.z;
}

/// Sets `layer` on `items`, which must be sorted far to near (`farther`).
/// `half_w`/`half_h`: the screen's half size in pixels; only overlaps on
/// screen count. Layers are capped at `max_layers - 1`.
pub fn assign(gpa: Allocator, s: *Scratch, items: []Item, half_w: f32, half_h: f32, max_layers: u32) !void {
    const gw: usize = @intFromFloat(@ceil(2 * half_w / cell) + 1);
    const gh: usize = @intFromFloat(@ceil(2 * half_h / cell) + 1);
    try s.heads.resize(gpa, gw * gh);
    @memset(s.heads.items, none);
    s.entries.clearRetainingCapacity();

    for (items, 0..) |*it, i| {
        it.layer = 0;
        const lo = @min(it.a, it.b) - @as(V2, @splat(it.r));
        const hi = @max(it.a, it.b) + @as(V2, @splat(it.r));
        // Off screen: it can't cover anything that is seen.
        if (hi[0] < -half_w or lo[0] > half_w or hi[1] < -half_h or lo[1] > half_h) continue;
        const x0 = cellIndex(lo[0], half_w, gw);
        const x1 = cellIndex(hi[0], half_w, gw);
        const y0 = cellIndex(lo[1], half_h, gh);
        const y1 = cellIndex(hi[1], half_h, gh);
        var layer: u32 = 0;
        for (y0..y1 + 1) |cy| for (x0..x1 + 1) |cx| {
            var e = s.heads.items[cy * gw + cx];
            while (e != none) : (e = s.entries.items[e].next) {
                const o = &items[s.entries.items[e].item];
                if (o.layer + 1 > layer and overlap(it.*, o.*)) layer = o.layer + 1;
            }
        };
        it.layer = @min(layer, max_layers - 1);
        for (y0..y1 + 1) |cy| for (x0..x1 + 1) |cx| {
            const h = &s.heads.items[cy * gw + cx];
            try s.entries.append(gpa, .{ .item = @intCast(i), .next = h.* });
            h.* = @intCast(s.entries.items.len - 1);
        };
    }
}

fn cellIndex(v: f32, half: f32, n: usize) usize {
    const c = @floor((v + half) / cell);
    return @intFromFloat(std.math.clamp(c, 0, @as(f32, @floatFromInt(n - 1))));
}

/// Whether two capsules overlap.
pub fn overlap(x: Item, y: Item) bool {
    const rr = x.r + y.r;
    if (segmentsCross(x.a, x.b, y.a, y.b)) return true;
    const d = @min(
        @min(pointSegment2(x.a, y.a, y.b), pointSegment2(x.b, y.a, y.b)),
        @min(pointSegment2(y.a, x.a, x.b), pointSegment2(y.b, x.a, x.b)),
    );
    return d < rr * rr;
}

/// Squared distance from `p` to segment `a`-`b`.
fn pointSegment2(p: V2, a: V2, b: V2) f32 {
    const ab = b - a;
    const len2 = @reduce(.Add, ab * ab);
    const t = if (len2 > 0) std.math.clamp(@reduce(.Add, (p - a) * ab) / len2, 0, 1) else 0;
    const d = a + ab * @as(V2, @splat(t)) - p;
    return @reduce(.Add, d * d);
}

fn cross(o: V2, a: V2, b: V2) f32 {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

/// Proper crossing of two segments (touching counts via the distances).
fn segmentsCross(a: V2, b: V2, c: V2, d: V2) bool {
    const d1 = cross(c, d, a);
    const d2 = cross(c, d, b);
    const d3 = cross(a, b, c);
    const d4 = cross(a, b, d);
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0));
}

fn disc(x: f32, y: f32, r: f32, z: f32) Item {
    return .{ .a = .{ x, y }, .b = .{ x, y }, .r = r, .z = z, .index = 0, .bond = false };
}

fn capsule(a: V2, b: V2, r: f32, z: f32) Item {
    return .{ .a = a, .b = b, .r = r, .z = z, .index = 0, .bond = true };
}

test "overlap: discs, capsules and crossings" {
    try std.testing.expect(overlap(disc(0, 0, 10, 1), disc(15, 0, 10, 1)));
    try std.testing.expect(!overlap(disc(0, 0, 10, 1), disc(25, 0, 10, 1)));
    // A long thin capsule passing next to a disc.
    try std.testing.expect(overlap(capsule(.{ -100, 12 }, .{ 100, 12 }, 3, 1), disc(0, 0, 10, 1)));
    try std.testing.expect(!overlap(capsule(.{ -100, 14 }, .{ 100, 14 }, 3, 1), disc(0, 0, 10, 1)));
    // Two thin capsules crossing in an X: endpoints far apart.
    try std.testing.expect(overlap(capsule(.{ -100, -100 }, .{ 100, 100 }, 1, 1), capsule(.{ -100, 100 }, .{ 100, -100 }, 1, 1)));
}

test "assign: overlapping items stack far to near, separate ones share a layer" {
    const gpa = std.testing.allocator;
    var s: Scratch = .{};
    defer s.deinit(gpa);
    var items = [_]Item{
        disc(0, 0, 20, 9), // far
        capsule(.{ 0, 0 }, .{ 60, 0 }, 5, 8), // bond half over it
        disc(60, 0, 20, 7), // atom at the bond's other end
        disc(-300, -200, 20, 6), // alone
        disc(1000, 0, 20, 5), // off screen
    };
    std.mem.sort(Item, &items, {}, farther);
    try assign(gpa, &s, &items, 400, 300, 16);
    try std.testing.expectEqual(@as(u32, 0), items[0].layer);
    try std.testing.expectEqual(@as(u32, 1), items[1].layer);
    try std.testing.expectEqual(@as(u32, 2), items[2].layer);
    try std.testing.expectEqual(@as(u32, 0), items[3].layer);
    try std.testing.expectEqual(@as(u32, 0), items[4].layer);
    // Capped.
    try assign(gpa, &s, &items, 400, 300, 2);
    try std.testing.expectEqual(@as(u32, 1), items[2].layer);
}
