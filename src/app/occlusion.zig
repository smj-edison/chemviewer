//! Screen-space occlusion of atom labels by the (impostor) spheres in front
//! of them, computed on the CPU from each sphere's projected disc and depth.
//! A uniform screen grid keeps each query to the spheres nearby.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A sphere as seen on screen.
pub const Disc = struct {
    /// Projected centre, in window points.
    x: f32,
    y: f32,
    /// Projected radius, in window points.
    rpx: f32,
    /// View depth of the centre (distance along the viewing direction).
    z: f32,
    /// World radius.
    r: f32,
};

pub const Occluder = struct {
    discs: []const Disc,
    /// Window points per world unit at view depth 1 (= (h/2) / tan(fovy/2)).
    focal: f32,
    cell: f32,
    cols: usize,
    rows: usize,
    /// Cell k holds discs items[start[k]..start[k+1]].
    start: []u32,
    items: []u32,

    pub fn init(gpa: Allocator, discs: []const Disc, focal: f32, w: f32, h: f32) !Occluder {
        const cell: f32 = 32;
        const cols: usize = @max(1, @as(usize, @intFromFloat(@ceil(w / cell))));
        const rows: usize = @max(1, @as(usize, @intFromFloat(@ceil(h / cell))));
        const ncells = cols * rows;
        const start = try gpa.alloc(u32, ncells + 1);
        errdefer gpa.free(start);
        @memset(start, 0);
        const o: Occluder = .{ .discs = discs, .focal = focal, .cell = cell, .cols = cols, .rows = rows, .start = start, .items = &.{} };
        // Two passes: count, then fill (counting sort by cell).
        for (discs) |d| {
            var it = o.cellsOf(d);
            while (it.next()) |k| start[k + 1] += 1;
        }
        for (1..ncells + 1) |k| start[k] += start[k - 1];
        const items = try gpa.alloc(u32, start[ncells]);
        errdefer gpa.free(items);
        const fill = try gpa.dupe(u32, start[0..ncells]);
        defer gpa.free(fill);
        for (discs, 0..) |d, i| {
            var it = o.cellsOf(d);
            while (it.next()) |k| {
                items[fill[k]] = @intCast(i);
                fill[k] += 1;
            }
        }
        var r = o;
        r.items = items;
        return r;
    }

    pub fn deinit(o: *Occluder, gpa: Allocator) void {
        gpa.free(o.start);
        gpa.free(o.items);
    }

    const CellIter = struct {
        x0: usize,
        x1: usize,
        y1: usize,
        x: usize,
        y: usize,
        cols: usize,
        done: bool,

        fn next(it: *CellIter) ?usize {
            if (it.done) return null;
            const k = it.y * it.cols + it.x;
            if (it.x < it.x1) {
                it.x += 1;
            } else if (it.y < it.y1) {
                it.x = it.x0;
                it.y += 1;
            } else it.done = true;
            return k;
        }
    };

    fn clampCell(v: f32, n: usize) usize {
        if (!(v > 0)) return 0;
        const i: usize = @intFromFloat(@min(v, @as(f32, @floatFromInt(n - 1))));
        return i;
    }

    fn cellsOf(o: Occluder, d: Disc) CellIter {
        const x0 = clampCell((d.x - d.rpx) / o.cell, o.cols);
        const x1 = clampCell((d.x + d.rpx) / o.cell, o.cols);
        const y0 = clampCell((d.y - d.rpx) / o.cell, o.rows);
        const y1 = clampCell((d.y + d.rpx) / o.cell, o.rows);
        return .{ .x0 = x0, .x1 = x1, .y1 = y1, .x = x0, .y = y0, .cols = o.cols, .done = false };
    }

    /// Depth of disc `d`'s sphere surface at screen point (px, py), or null
    /// if the point is outside its disc.
    fn frontDepth(o: Occluder, d: Disc, px: f32, py: f32) ?f32 {
        const dx = px - d.x;
        const dy = py - d.y;
        const dist2 = dx * dx + dy * dy;
        if (dist2 >= d.rpx * d.rpx) return null;
        const off = @sqrt(dist2) * d.z / o.focal; // world offset from the centre line
        return d.z - @sqrt(@max(d.r * d.r - off * off, 0));
    }

    /// Is the label of disc `self` hidden at screen point (px, py)? The label
    /// sits on its own sphere's surface; any other sphere whose surface is in
    /// front of that point hides it.
    pub fn hidden(o: Occluder, self: u32, px: f32, py: f32) bool {
        const me = o.discs[self];
        const own = o.frontDepth(me, px, py) orelse me.z - me.r;
        const eps = 0.02 * me.r;
        if (px < 0 or py < 0) return false;
        const cx = clampCell(px / o.cell, o.cols);
        const cy = clampCell(py / o.cell, o.rows);
        const k = cy * o.cols + cx;
        for (o.items[o.start[k]..o.start[k + 1]]) |j| {
            if (j == self) continue;
            const front = o.frontDepth(o.discs[j], px, py) orelse continue;
            if (front < own - eps) return true;
        }
        return false;
    }
};

test "nearer spheres hide labels behind them, not the other way round" {
    const gpa = std.testing.allocator;
    // Focal 500 px: a 1 Å sphere at depth 10 projects to 50 px.
    const discs = [_]Disc{
        .{ .x = 100, .y = 100, .rpx = 50, .z = 10, .r = 1 }, // near, in front
        .{ .x = 110, .y = 100, .rpx = 40, .z = 12.5, .r = 1 }, // behind, mostly covered
        .{ .x = 400, .y = 300, .rpx = 50, .z = 10, .r = 1 }, // off to the side
    };
    var o = try Occluder.init(gpa, &discs, 500, 640, 480);
    defer o.deinit(gpa);
    try std.testing.expect(o.hidden(1, 110, 100)); // far label behind near sphere
    try std.testing.expect(!o.hidden(0, 100, 100)); // near label in front
    try std.testing.expect(!o.hidden(2, 400, 300)); // nothing in front
    // Near the edge of the near disc (48 px from its centre) it still hides
    // the far label; just outside it (51 px) the far label shows.
    try std.testing.expect(o.hidden(1, 148, 100));
    try std.testing.expect(!o.hidden(1, 151, 100));
}
