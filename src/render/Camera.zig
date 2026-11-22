//! Orbit camera: rotate around a target, pan, dolly-zoom.
const std = @import("std");
const cv = @import("chemviewer");
const math = cv.math;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Quat = math.Quat;

const Camera = @This();

target: Vec3 = .{ 0, 0, 0 },
distance: f32 = 20,
rotation: Quat = .identity,
fovy: f32 = std.math.degreesToRadians(35.0),
/// Fixed world anchor and size for the background pattern, set on `fit` so
/// the pattern does not drift as frames or edits change the scene bounds.
bg_anchor: Vec3 = .{ 0, 0, 0 },
bg_radius: f32 = 1,

pub fn view(c: Camera) Mat4 {
    return Mat4.translation(.{ 0, 0, -c.distance })
        .mul(Mat4.fromMat3(c.rotation.toMat3()))
        .mul(Mat4.translation(-c.target));
}

pub fn projection(c: Camera, aspect: f32, scene_radius: f32) Mat4 {
    const near = @max(0.05, c.distance - scene_radius * 2 - 5);
    const far = c.distance + scene_radius * 2 + 50;
    return Mat4.perspective(c.fovy, aspect, near, far);
}

/// Rotate by a mouse drag of (dx, dy) pixels, about the screen axes.
pub fn orbit(c: *Camera, dx: f32, dy: f32) void {
    const k = 0.008;
    const qx = Quat.fromAxisAngle(.{ 1, 0, 0 }, dy * k);
    const qy = Quat.fromAxisAngle(.{ 0, 1, 0 }, dx * k);
    c.rotation = qy.mul(qx).mul(c.rotation).normalized();
}

/// Rotate about the viewing axis; dragging right turns the scene clockwise.
pub fn roll(c: *Camera, dx: f32) void {
    const q = Quat.fromAxisAngle(.{ 0, 0, 1 }, -dx * 0.008);
    c.rotation = q.mul(c.rotation).normalized();
}

/// Zoom from a vertical drag: dragging up moves closer.
pub fn dragZoom(c: *Camera, dy: f32) void {
    c.distance *= @exp(dy * 0.006);
    c.distance = std.math.clamp(c.distance, 0.5, 1e5);
}

/// Pan by a drag of (dx, dy) pixels given the viewport height.
pub fn pan(c: *Camera, dx: f32, dy: f32, viewport_h: f32) void {
    const world_per_px = 2 * c.distance * @tan(c.fovy / 2) / @max(viewport_h, 1);
    // Screen axes expressed in world space = rows of the rotation matrix.
    const r = c.rotation.toMat3().transpose();
    const right = r.column(0);
    const up = r.column(1);
    c.target -= right * math.splat(dx * world_per_px);
    c.target += up * math.splat(dy * world_per_px);
}

pub fn zoom(c: *Camera, wheel: f32) void {
    c.distance *= std.math.pow(f32, 0.88, wheel);
    c.distance = std.math.clamp(c.distance, 0.5, 1e5);
}

/// Center on a bounding sphere and back off so it fills the view.
pub fn fit(c: *Camera, center: Vec3, radius: f32) void {
    c.target = center;
    c.distance = @max(radius, 1.0) / @sin(c.fovy / 2) * 1.12;
    c.bg_anchor = center;
    c.bg_radius = @max(radius, 1.0);
}

pub const Ray = struct { origin: Vec3, dir: Vec3 };

/// World-space ray through a point given in normalised device coordinates
/// (x, y in [-1, 1], y up). Inverse of `view`: w = Rᵀ(v + (0,0,d)) + target.
pub fn ray(c: Camera, x_ndc: f32, y_ndc: f32, aspect: f32) Ray {
    const t = @tan(c.fovy / 2);
    const dir_view = math.normalize(.{ x_ndc * t * aspect, y_ndc * t, -1 });
    const rt = c.rotation.toMat3().transpose();
    return .{
        .origin = rt.mulVec(.{ 0, 0, c.distance }) + c.target,
        .dir = rt.mulVec(dir_view),
    };
}

test "pick ray passes through projected points" {
    var cam: Camera = .{ .target = .{ 1, -2, 0.5 }, .distance = 15 };
    cam.orbit(140, -60);
    cam.roll(35);
    const aspect: f32 = 1.6;
    const vp = cam.projection(aspect, 10).mul(cam.view());
    const points = [_]Vec3{ .{ 0, 0, 0 }, .{ 3, 1, -2 }, .{ -4, 2.5, 1 } };
    for (points) |p| {
        // Project to NDC.
        var clip: [4]f32 = undefined;
        for (0..4) |row| clip[row] = vp.m[0][row] * p[0] + vp.m[1][row] * p[1] + vp.m[2][row] * p[2] + vp.m[3][row];
        const r = cam.ray(clip[0] / clip[3], clip[1] / clip[3], aspect);
        // Distance from p to the ray.
        const t = math.dot(p - r.origin, r.dir);
        const closest = r.origin + r.dir * math.splat(t);
        try std.testing.expect(math.length(closest - p) < 1e-3);
        try std.testing.expect(t > 0);
    }
}
