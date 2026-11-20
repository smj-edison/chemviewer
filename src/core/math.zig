//! Small linear-algebra kit built on @Vector so it stays SIMD-friendly.
const std = @import("std");

pub const Vec3 = @Vector(3, f32);
pub const Vec3d = @Vector(3, f64);
pub const Vec4 = @Vector(4, f32);

pub fn vec3(x: f32, y: f32, z: f32) Vec3 {
    return .{ x, y, z };
}

pub fn splat(s: f32) Vec3 {
    return @splat(s);
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}

pub fn length2(a: Vec3) f32 {
    return dot(a, a);
}

pub fn normalize(a: Vec3) Vec3 {
    const l = length(a);
    return if (l > 0) a / splat(l) else a;
}

/// Column-major 4x4 matrix, `m[col][row]`, matching OpenGL's layout.
pub const Mat4 = struct {
    m: [4][4]f32,

    pub const identity: Mat4 = .{ .m = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                var s: f32 = 0;
                for (0..4) |k| s += a.m[k][row] * b.m[col][k];
                r.m[col][row] = s;
            }
        }
        return r;
    }

    pub fn transformPoint(a: Mat4, p: Vec3) Vec3 {
        var r: [4]f32 = undefined;
        for (0..4) |row| {
            r[row] = a.m[0][row] * p[0] + a.m[1][row] * p[1] + a.m[2][row] * p[2] + a.m[3][row];
        }
        return .{ r[0] / r[3], r[1] / r[3], r[2] / r[3] };
    }

    pub fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fovy_rad / 2.0);
        var r: Mat4 = .{ .m = std.mem.zeroes([4][4]f32) };
        r.m[0][0] = f / aspect;
        r.m[1][1] = f;
        r.m[2][2] = (far + near) / (near - far);
        r.m[2][3] = -1;
        r.m[3][2] = 2 * far * near / (near - far);
        return r;
    }

    pub fn orthographic(half_w: f32, half_h: f32, near: f32, far: f32) Mat4 {
        var r: Mat4 = .identity;
        r.m[0][0] = 1 / half_w;
        r.m[1][1] = 1 / half_h;
        r.m[2][2] = -2 / (far - near);
        r.m[3][2] = -(far + near) / (far - near);
        return r;
    }

    pub fn translation(t: Vec3) Mat4 {
        var r: Mat4 = .identity;
        r.m[3][0] = t[0];
        r.m[3][1] = t[1];
        r.m[3][2] = t[2];
        return r;
    }

    pub fn fromMat3(r3: Mat3) Mat4 {
        var r: Mat4 = .identity;
        for (0..3) |col| for (0..3) |row| {
            r.m[col][row] = r3.m[col][row];
        };
        return r;
    }
};

/// Column-major 3x3 matrix, `m[col][row]`.
pub const Mat3 = struct {
    m: [3][3]f32,

    pub const identity: Mat3 = .{ .m = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } } };

    pub fn mulVec(a: Mat3, v: Vec3) Vec3 {
        return .{
            a.m[0][0] * v[0] + a.m[1][0] * v[1] + a.m[2][0] * v[2],
            a.m[0][1] * v[0] + a.m[1][1] * v[1] + a.m[2][1] * v[2],
            a.m[0][2] * v[0] + a.m[1][2] * v[1] + a.m[2][2] * v[2],
        };
    }

    pub fn mul(a: Mat3, b: Mat3) Mat3 {
        var r: Mat3 = undefined;
        for (0..3) |col| for (0..3) |row| {
            var s: f32 = 0;
            for (0..3) |k| s += a.m[k][row] * b.m[col][k];
            r.m[col][row] = s;
        };
        return r;
    }

    pub fn transpose(a: Mat3) Mat3 {
        var r: Mat3 = undefined;
        for (0..3) |col| for (0..3) |row| {
            r.m[col][row] = a.m[row][col];
        };
        return r;
    }

    pub fn column(a: Mat3, i: usize) Vec3 {
        return .{ a.m[i][0], a.m[i][1], a.m[i][2] };
    }
};

/// Unit quaternion (x, y, z, w) for rotations.
pub const Quat = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity: Quat = .{};

    pub fn fromAxisAngle(axis: Vec3, angle: f32) Quat {
        const n = normalize(axis);
        const s = @sin(angle / 2);
        return .{ .x = n[0] * s, .y = n[1] * s, .z = n[2] * s, .w = @cos(angle / 2) };
    }

    pub fn mul(a: Quat, b: Quat) Quat {
        return .{
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        };
    }

    pub fn normalized(q: Quat) Quat {
        const l = @sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
        if (l == 0) return .identity;
        return .{ .x = q.x / l, .y = q.y / l, .z = q.z / l, .w = q.w / l };
    }

    pub fn toMat3(q: Quat) Mat3 {
        const x = q.x;
        const y = q.y;
        const z = q.z;
        const w = q.w;
        return .{ .m = .{
            .{ 1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w) },
            .{ 2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w) },
            .{ 2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y) },
        } };
    }

    pub fn rotate(q: Quat, v: Vec3) Vec3 {
        return q.toMat3().mulVec(v);
    }
};

test "quat rotation matches matrix" {
    const q = Quat.fromAxisAngle(vec3(0, 0, 1), std.math.pi / 2.0);
    const r = q.rotate(vec3(1, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0), r[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r[1], 1e-6);
}

test "mat4 mul identity" {
    const t = Mat4.translation(vec3(1, 2, 3));
    const p = Mat4.identity.mul(t).transformPoint(vec3(0, 0, 0));
    try std.testing.expectEqual(vec3(1, 2, 3), p);
}
