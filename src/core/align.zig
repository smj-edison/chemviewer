//! Optimal rigid superposition of two structures with known atom
//! correspondence (Horn 1987, closed-form quaternion solution).
const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Vec3d = math.Vec3d;

pub const Transform = struct {
    /// Row-major rotation in f64.
    rot: [3][3]f64,
    /// Applied as p' = rot * (p - from_center) + to_center.
    from_center: Vec3d,
    to_center: Vec3d,

    pub const identity: Transform = .{
        .rot = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } },
        .from_center = @splat(0),
        .to_center = @splat(0),
    };

    /// To tell transforms apart, also ones that aren't numbers.
    pub fn bits(t: Transform) [15]u64 {
        const from: [3]f64 = t.from_center;
        const to: [3]f64 = t.to_center;
        return @bitCast([5][3]f64{ t.rot[0], t.rot[1], t.rot[2], from, to });
    }

    /// Undoes `t`.
    pub fn inverse(t: Transform) Transform {
        var rot: [3][3]f64 = undefined;
        for (0..3) |i| for (0..3) |j| {
            rot[i][j] = t.rot[j][i];
        };
        return .{ .rot = rot, .from_center = t.to_center, .to_center = t.from_center };
    }

    pub fn apply(t: Transform, p: Vec3) Vec3 {
        const q: Vec3d = @as(Vec3d, @floatCast(p)) - t.from_center;
        const r: Vec3d = .{
            t.rot[0][0] * q[0] + t.rot[0][1] * q[1] + t.rot[0][2] * q[2],
            t.rot[1][0] * q[0] + t.rot[1][1] * q[1] + t.rot[1][2] * q[2],
            t.rot[2][0] * q[0] + t.rot[2][1] * q[1] + t.rot[2][2] * q[2],
        };
        return @floatCast(r + t.to_center);
    }
};

pub const Result = struct {
    /// Maps `mobile` onto `reference`.
    transform: Transform,
    rmsd: f64,
};

/// Find the rotation + translation minimising RMSD of `mobile` onto
/// `reference`. Both slices must have the same length and ordering.
/// `weights` (optional) weight each atom, e.g. by mass or a selection mask.
pub fn superpose(reference: []const Vec3, mobile: []const Vec3, weights: ?[]const f32) Result {
    std.debug.assert(reference.len == mobile.len);
    const n = reference.len;
    if (n == 0) return .{ .transform = .identity, .rmsd = 0 };

    var wsum: f64 = 0;
    var cp: Vec3d = @splat(0);
    var cq: Vec3d = @splat(0);
    for (0..n) |i| {
        const w: f64 = if (weights) |ws| ws[i] else 1;
        wsum += w;
        cp += @as(Vec3d, @splat(w)) * @as(Vec3d, @floatCast(reference[i]));
        cq += @as(Vec3d, @splat(w)) * @as(Vec3d, @floatCast(mobile[i]));
    }
    if (wsum == 0) return .{ .transform = .identity, .rmsd = 0 };
    cp /= @splat(wsum);
    cq /= @splat(wsum);

    // S[a][b] = Σ w q_a p_b  (q = mobile, p = reference), centred.
    var s: [3][3]f64 = std.mem.zeroes([3][3]f64);
    for (0..n) |i| {
        const w: f64 = if (weights) |ws| ws[i] else 1;
        const p: [3]f64 = @as(Vec3d, @floatCast(reference[i])) - cp;
        const q: [3]f64 = @as(Vec3d, @floatCast(mobile[i])) - cq;
        for (0..3) |a| for (0..3) |b| {
            s[a][b] += w * q[a] * p[b];
        };
    }
    const sxx = s[0][0];
    const sxy = s[0][1];
    const sxz = s[0][2];
    const syx = s[1][0];
    const syy = s[1][1];
    const syz = s[1][2];
    const szx = s[2][0];
    const szy = s[2][1];
    const szz = s[2][2];
    var nm: [4][4]f64 = .{
        .{ sxx + syy + szz, syz - szy, szx - sxz, sxy - syx },
        .{ syz - szy, sxx - syy - szz, sxy + syx, szx + sxz },
        .{ szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy },
        .{ sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz },
    };
    var vecs: [4][4]f64 = undefined;
    var vals: [4]f64 = undefined;
    jacobiEigen(4, &nm, &vals, &vecs);
    var best: usize = 0;
    for (1..4) |i| if (vals[i] > vals[best]) {
        best = i;
    };
    const w = vecs[0][best];
    const x = vecs[1][best];
    const y = vecs[2][best];
    const z = vecs[3][best];
    const rot: [3][3]f64 = .{
        .{ w * w + x * x - y * y - z * z, 2 * (x * y - w * z), 2 * (x * z + w * y) },
        .{ 2 * (x * y + w * z), w * w - x * x + y * y - z * z, 2 * (y * z - w * x) },
        .{ 2 * (x * z - w * y), 2 * (y * z + w * x), w * w - x * x - y * y + z * z },
    };
    const t: Transform = .{ .rot = rot, .from_center = cq, .to_center = cp };

    var sq: f64 = 0;
    for (0..n) |i| {
        const wi: f64 = if (weights) |ws| ws[i] else 1;
        const d: Vec3d = @floatCast(t.apply(mobile[i]) - reference[i]);
        sq += wi * @reduce(.Add, d * d);
    }
    return .{ .transform = t, .rmsd = @sqrt(sq / wsum) };
}

/// Cyclic Jacobi eigenvalue iteration for a small symmetric matrix.
/// On return `vals[i]` pairs with column `i` of `vecs`. `a` is destroyed.
fn jacobiEigen(comptime n: usize, a: *[n][n]f64, vals: *[n]f64, vecs: *[n][n]f64) void {
    for (0..n) |i| for (0..n) |j| {
        vecs[i][j] = if (i == j) 1 else 0;
    };
    var sweep: usize = 0;
    while (sweep < 64) : (sweep += 1) {
        var off: f64 = 0;
        for (0..n) |i| for (i + 1..n) |j| {
            off += a[i][j] * a[i][j];
        };
        if (off < 1e-22) break;
        for (0..n) |p| for (p + 1..n) |q| {
            if (@abs(a[p][q]) < 1e-300) continue;
            const theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
            const t = std.math.sign(theta) / (@abs(theta) + @sqrt(theta * theta + 1));
            const tt = if (theta == 0) 1.0 else t;
            const c = 1 / @sqrt(tt * tt + 1);
            const s = tt * c;
            for (0..n) |k| {
                const akp = a[k][p];
                const akq = a[k][q];
                a[k][p] = c * akp - s * akq;
                a[k][q] = s * akp + c * akq;
            }
            for (0..n) |k| {
                const apk = a[p][k];
                const aqk = a[q][k];
                a[p][k] = c * apk - s * aqk;
                a[q][k] = s * apk + c * aqk;
            }
            for (0..n) |k| {
                const vkp = vecs[k][p];
                const vkq = vecs[k][q];
                vecs[k][p] = c * vkp - s * vkq;
                vecs[k][q] = s * vkp + c * vkq;
            }
        };
    }
    for (0..n) |i| vals[i] = a[i][i];
}

test "recovers a known rigid transform" {
    const q = math.Quat.fromAxisAngle(.{ 0.3, -1, 0.5 }, 1.1);
    const ref = [_]Vec3{ .{ 0, 0, 0 }, .{ 1.5, 0, 0 }, .{ 0, 2, 0.3 }, .{ -1, 0.4, 1.7 }, .{ 0.2, -0.8, -0.6 } };
    var mob: [ref.len]Vec3 = undefined;
    for (ref, &mob) |p, *m| m.* = q.rotate(p) + Vec3{ 3, -2, 7 };
    const r = superpose(&ref, &mob, null);
    try std.testing.expect(r.rmsd < 1e-5);
    for (ref, mob) |p, m| {
        const d = math.length(r.transform.apply(m) - p);
        try std.testing.expect(d < 1e-4);
        try std.testing.expect(math.length(r.transform.inverse().apply(p) - m) < 1e-4);
    }
}

test "handles 180 degree rotation" {
    const q = math.Quat.fromAxisAngle(.{ 0, 0, 1 }, std.math.pi);
    const ref = [_]Vec3{ .{ 1, 0, 0 }, .{ 0, 2, 0 }, .{ 0, 0, 3 }, .{ 1, 1, 1 } };
    var mob: [ref.len]Vec3 = undefined;
    for (ref, &mob) |p, *m| m.* = q.rotate(p);
    try std.testing.expect(superpose(&ref, &mob, null).rmsd < 1e-5);
}
