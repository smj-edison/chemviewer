//! Free-form lasso selection in window coordinates.
const std = @import("std");

pub const Point = struct { x: f32, y: f32 };

/// Even-odd rule point-in-polygon test. The polygon is implicitly closed.
pub fn contains(poly: []const Point, p: Point) bool {
    if (poly.len < 3) return false;
    var inside = false;
    var j = poly.len - 1;
    for (poly, 0..) |a, i| {
        const b = poly[j];
        if ((a.y > p.y) != (b.y > p.y)) {
            const x_cross = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y);
            if (p.x < x_cross) inside = !inside;
        }
        j = i;
    }
    return inside;
}

test "point in polygon, including concave shapes" {
    // A "C" shape opening to the right.
    const c_shape = [_]Point{
        .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 2 },  .{ .x = 2, .y = 2 },
        .{ .x = 2, .y = 8 }, .{ .x = 10, .y = 8 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 },
    };
    try std.testing.expect(contains(&c_shape, .{ .x = 1, .y = 5 })); // spine
    try std.testing.expect(contains(&c_shape, .{ .x = 8, .y = 1 })); // top arm
    try std.testing.expect(!contains(&c_shape, .{ .x = 6, .y = 5 })); // the gap
    try std.testing.expect(!contains(&c_shape, .{ .x = 12, .y = 5 })); // outside
    try std.testing.expect(!contains(c_shape[0..2], .{ .x = 1, .y = 0 })); // degenerate
}
