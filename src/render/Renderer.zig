//! Draws atoms (sphere impostors), bonds (instanced cylinders) and cell edges.
//!
//! Usage per scene change: `clear`, then `addStructure` (once per layer,
//! e.g. twice for a diff overlay) and `addCell`, then `upload`. `draw` can be
//! called every frame without rebuilding anything.
const std = @import("std");
const cv = @import("chemviewer");
const gl = @import("gl.zig");
const shaders = @import("shaders.zig");
const math = cv.math;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Bond = cv.bonds.Bond;
const Allocator = std.mem.Allocator;

const Renderer = @This();

pub const BondColoring = enum(c_int) {
    /// Colour from the continuous bond character (docs/BONDS.md).
    gradient,
    /// Each half takes its atom's element colour; character shown by radius only.
    element,
};

pub const Style = struct {
    atom_scale: f32 = 1.0,
    bond_radius: f32 = 0.11,
    bond_coloring: BondColoring = .gradient,
    /// Bonds with a character below this are not drawn.
    min_character: f32 = 0.0,
    /// How strongly bond character snaps toward whole bond orders before
    /// colouring (0 = linear, 1 = flat plateaus). See `cv.color.snap`.
    snap: f32 = 0.7,
    show_cell: bool = true,
};

pub const Tint = struct {
    color: [3]f32,
    /// 0 = element colours, 1 = flat tint colour.
    amount: f32 = 0.65,
};

/// Bond colour from its character: the perceptual OKLCh palette in
/// `cv.color`, shaped by the snap curve. Returns sRGB + opacity.
pub fn gradientColor(character: f32, snap_strength: f32) [4]f32 {
    const bc = cv.color.bondColor(character, snap_strength);
    return .{ bc.rgb[0], bc.rgb[1], bc.rgb[2], bc.alpha };
}

const AtomInstance = extern struct { center: [3]f32, radius: f32, color: [4]f32 };
const BondInstance = extern struct {
    a: [3]f32,
    radius: f32,
    b: [3]f32,
    _pad: f32 = 0,
    color_a: [4]f32,
    color_b: [4]f32,
};
const LineVertex = extern struct { pos: [3]f32, color: [4]f32 };

const cylinder_segments = 16;

gpa: Allocator,
sphere_prog: gl.Uint,
cylinder_prog: gl.Uint,
line_prog: gl.Uint,
sphere_vao: gl.Uint = 0,
cylinder_vao: gl.Uint = 0,
line_vao: gl.Uint = 0,
quad_vbo: gl.Uint = 0,
cyl_vbo: gl.Uint = 0,
cyl_ibo: gl.Uint = 0,
atom_vbo: gl.Uint = 0,
bond_vbo: gl.Uint = 0,
line_vbo: gl.Uint = 0,
cyl_index_count: gl.Sizei = 0,

atoms: std.ArrayList(AtomInstance) = .empty,
/// Opaque bonds first, then translucent ones (drawn without depth writes).
bonds: std.ArrayList(BondInstance) = .empty,
translucent: std.ArrayList(BondInstance) = .empty,
lines: std.ArrayList(LineVertex) = .empty,
uploaded_atoms: usize = 0,
uploaded_opaque_bonds: usize = 0,
uploaded_translucent_bonds: usize = 0,
uploaded_lines: usize = 0,

pub fn init(gpa: Allocator) !Renderer {
    var r: Renderer = .{
        .gpa = gpa,
        .sphere_prog = try gl.compileProgram(shaders.sphere_vs, shaders.sphere_fs),
        .cylinder_prog = try gl.compileProgram(shaders.cylinder_vs, shaders.cylinder_fs),
        .line_prog = try gl.compileProgram(shaders.line_vs, shaders.line_fs),
    };
    const f = &gl.f;
    var vaos: [3]gl.Uint = undefined;
    f.GenVertexArrays(3, &vaos);
    r.sphere_vao = vaos[0];
    r.cylinder_vao = vaos[1];
    r.line_vao = vaos[2];
    var bufs: [6]gl.Uint = undefined;
    f.GenBuffers(6, &bufs);
    r.quad_vbo = bufs[0];
    r.cyl_vbo = bufs[1];
    r.cyl_ibo = bufs[2];
    r.atom_vbo = bufs[3];
    r.bond_vbo = bufs[4];
    r.line_vbo = bufs[5];

    // --- spheres: one quad, per-instance center/radius/color
    f.BindVertexArray(r.sphere_vao);
    const quad = [_]f32{ -1, -1, 1, -1, -1, 1, 1, 1 };
    f.BindBuffer(gl.ARRAY_BUFFER, r.quad_vbo);
    f.BufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, gl.STATIC_DRAW);
    f.EnableVertexAttribArray(0);
    f.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 8, null);
    f.BindBuffer(gl.ARRAY_BUFFER, r.atom_vbo);
    instanceAttrib(1, 4, @sizeOf(AtomInstance), @offsetOf(AtomInstance, "center"));
    instanceAttrib(2, 4, @sizeOf(AtomInstance), @offsetOf(AtomInstance, "color"));

    // --- cylinders: side wall mesh, per-instance endpoints/colors
    f.BindVertexArray(r.cylinder_vao);
    var verts: [cylinder_segments * 2][3]f32 = undefined;
    var idx: [cylinder_segments * 6]u16 = undefined;
    for (0..cylinder_segments) |i| {
        const th = @as(f32, @floatFromInt(i)) / cylinder_segments * 2 * std.math.pi;
        verts[2 * i] = .{ @cos(th), @sin(th), 0 };
        verts[2 * i + 1] = .{ @cos(th), @sin(th), 1 };
        const a: u16 = @intCast(2 * i);
        const b: u16 = @intCast(2 * ((i + 1) % cylinder_segments));
        idx[6 * i ..][0..6].* = .{ a, b, a + 1, a + 1, b, b + 1 };
    }
    r.cyl_index_count = idx.len;
    f.BindBuffer(gl.ARRAY_BUFFER, r.cyl_vbo);
    f.BufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.STATIC_DRAW);
    f.EnableVertexAttribArray(0);
    f.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 12, null);
    f.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.cyl_ibo);
    f.BufferData(gl.ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(idx)), &idx, gl.STATIC_DRAW);
    f.BindBuffer(gl.ARRAY_BUFFER, r.bond_vbo);
    instanceAttrib(1, 4, @sizeOf(BondInstance), @offsetOf(BondInstance, "a"));
    instanceAttrib(2, 4, @sizeOf(BondInstance), @offsetOf(BondInstance, "b"));
    instanceAttrib(3, 4, @sizeOf(BondInstance), @offsetOf(BondInstance, "color_a"));
    instanceAttrib(4, 4, @sizeOf(BondInstance), @offsetOf(BondInstance, "color_b"));

    // --- lines
    f.BindVertexArray(r.line_vao);
    f.BindBuffer(gl.ARRAY_BUFFER, r.line_vbo);
    f.EnableVertexAttribArray(0);
    f.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(LineVertex), null);
    f.EnableVertexAttribArray(1);
    f.VertexAttribPointer(1, 4, gl.FLOAT, gl.FALSE, @sizeOf(LineVertex), @ptrFromInt(@offsetOf(LineVertex, "color")));
    f.BindVertexArray(0);
    return r;
}

fn instanceAttrib(loc: gl.Uint, n: gl.Int, stride: usize, offset: usize) void {
    gl.f.EnableVertexAttribArray(loc);
    gl.f.VertexAttribPointer(loc, n, gl.FLOAT, gl.FALSE, @intCast(stride), @ptrFromInt(offset));
    gl.f.VertexAttribDivisor(loc, 1);
}

pub fn deinit(r: *Renderer) void {
    const f = &gl.f;
    const vaos = [_]gl.Uint{ r.sphere_vao, r.cylinder_vao, r.line_vao };
    f.DeleteVertexArrays(vaos.len, &vaos);
    const bufs = [_]gl.Uint{ r.quad_vbo, r.cyl_vbo, r.cyl_ibo, r.atom_vbo, r.bond_vbo, r.line_vbo };
    f.DeleteBuffers(bufs.len, &bufs);
    f.DeleteProgram(r.sphere_prog);
    f.DeleteProgram(r.cylinder_prog);
    f.DeleteProgram(r.line_prog);
    r.atoms.deinit(r.gpa);
    r.bonds.deinit(r.gpa);
    r.translucent.deinit(r.gpa);
    r.lines.deinit(r.gpa);
}

pub fn clear(r: *Renderer) void {
    r.atoms.clearRetainingCapacity();
    r.bonds.clearRetainingCapacity();
    r.translucent.clearRetainingCapacity();
    r.lines.clearRetainingCapacity();
}

fn tinted(rgb: [3]f32, tint: ?Tint) [3]f32 {
    const t = tint orelse return rgb;
    var out: [3]f32 = undefined;
    for (0..3) |k| out[k] = rgb[k] + (t.color[k] - rgb[k]) * t.amount;
    return out;
}

/// Queue one structure. `positions` may differ from the frame's own (e.g. aligned).
pub fn addStructure(
    r: *Renderer,
    positions: []const Vec3,
    numbers: []const u8,
    bonds: []const Bond,
    style: Style,
    tint: ?Tint,
) !void {
    try r.atoms.ensureUnusedCapacity(r.gpa, positions.len);
    for (positions, numbers) |p, z| {
        const rgb = tinted(cv.elements.colorRgb(z), tint);
        r.atoms.appendAssumeCapacity(.{
            .center = p,
            .radius = cv.elements.displayRadius(z) * style.atom_scale,
            .color = .{ rgb[0], rgb[1], rgb[2], 1 },
        });
    }
    for (bonds) |b| {
        if (b.character < style.min_character) continue;
        if (cv.color.snap(b.character, style.snap) < 0.02) continue; // invisible anyway
        // Snapped character drives colour, opacity and thinning alike.
        const ch = cv.color.snap(b.character, style.snap);
        // Below single-bond character, thin the bond out as it fades.
        const thin = if (ch < 1) 0.35 + 0.65 * ch else 1.0;
        var ca: [4]f32 = undefined;
        var cb: [4]f32 = undefined;
        switch (style.bond_coloring) {
            .gradient => {
                const g = gradientColor(b.character, style.snap);
                const rgb = tinted(.{ g[0], g[1], g[2] }, tint);
                ca = .{ rgb[0], rgb[1], rgb[2], g[3] };
                cb = ca;
            },
            .element => {
                const alpha = @min(ch, 1.0);
                const ra = tinted(cv.elements.colorRgb(numbers[b.a]), tint);
                const rb = tinted(cv.elements.colorRgb(numbers[b.b]), tint);
                ca = .{ ra[0], ra[1], ra[2], alpha };
                cb = .{ rb[0], rb[1], rb[2], alpha };
            },
        }
        const inst: BondInstance = .{
            .a = positions[b.a],
            .b = positions[b.b],
            .radius = style.bond_radius * thin,
            .color_a = ca,
            .color_b = cb,
        };
        if (ca[3] < 0.99) try r.translucent.append(r.gpa, inst) else try r.bonds.append(r.gpa, inst);
    }
}

pub fn addCell(r: *Renderer, cell: [3]Vec3, rgba: [4]f32) !void {
    const o: Vec3 = .{ 0, 0, 0 };
    const a = cell[0];
    const b = cell[1];
    const c = cell[2];
    const corners = [_]Vec3{ o, a, b, c, a + b, a + c, b + c, a + b + c };
    const edges = [_][2]u8{
        .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 }, .{ 1, 4 }, .{ 1, 5 }, .{ 2, 4 },
        .{ 2, 6 }, .{ 3, 5 }, .{ 3, 6 }, .{ 4, 7 }, .{ 5, 7 }, .{ 6, 7 },
    };
    for (edges) |e| {
        try r.lines.append(r.gpa, .{ .pos = corners[e[0]], .color = rgba });
        try r.lines.append(r.gpa, .{ .pos = corners[e[1]], .color = rgba });
    }
}

pub fn upload(r: *Renderer) !void {
    const f = &gl.f;
    f.BindBuffer(gl.ARRAY_BUFFER, r.atom_vbo);
    f.BufferData(gl.ARRAY_BUFFER, @intCast(r.atoms.items.len * @sizeOf(AtomInstance)), r.atoms.items.ptr, gl.DYNAMIC_DRAW);
    r.uploaded_atoms = r.atoms.items.len;

    // Opaque bonds followed by translucent ones in a single buffer.
    r.uploaded_opaque_bonds = r.bonds.items.len;
    r.uploaded_translucent_bonds = r.translucent.items.len;
    try r.bonds.appendSlice(r.gpa, r.translucent.items);
    f.BindBuffer(gl.ARRAY_BUFFER, r.bond_vbo);
    f.BufferData(gl.ARRAY_BUFFER, @intCast(r.bonds.items.len * @sizeOf(BondInstance)), r.bonds.items.ptr, gl.DYNAMIC_DRAW);
    r.bonds.shrinkRetainingCapacity(r.uploaded_opaque_bonds);

    f.BindBuffer(gl.ARRAY_BUFFER, r.line_vbo);
    f.BufferData(gl.ARRAY_BUFFER, @intCast(r.lines.items.len * @sizeOf(LineVertex)), r.lines.items.ptr, gl.DYNAMIC_DRAW);
    r.uploaded_lines = r.lines.items.len;
}

fn setMatrices(prog: gl.Uint, view: Mat4, proj: Mat4) void {
    gl.f.UseProgram(prog);
    gl.f.UniformMatrix4fv(gl.f.GetUniformLocation(prog, "u_view"), 1, gl.FALSE, @ptrCast(&view.m));
    gl.f.UniformMatrix4fv(gl.f.GetUniformLocation(prog, "u_proj"), 1, gl.FALSE, @ptrCast(&proj.m));
}

pub const background = [3]f32{ 0.105, 0.11, 0.13 };

pub fn draw(r: *Renderer, view: Mat4, proj: Mat4, width: i32, height: i32) void {
    const f = &gl.f;
    f.Viewport(0, 0, width, height);
    f.ClearColor(background[0], background[1], background[2], 1);
    f.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    f.Enable(gl.DEPTH_TEST);
    f.DepthFunc(gl.LESS);
    f.DepthMask(gl.TRUE);
    f.Disable(gl.BLEND);
    f.Disable(gl.CULL_FACE);

    if (r.uploaded_atoms > 0) {
        setMatrices(r.sphere_prog, view, proj);
        f.BindVertexArray(r.sphere_vao);
        f.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(r.uploaded_atoms));
    }
    setMatrices(r.cylinder_prog, view, proj);
    f.BindVertexArray(r.cylinder_vao);
    if (r.uploaded_opaque_bonds > 0) {
        f.DrawElementsInstanced(gl.TRIANGLES, r.cyl_index_count, gl.UNSIGNED_SHORT, null, @intCast(r.uploaded_opaque_bonds));
    }
    if (r.uploaded_lines > 0) {
        setMatrices(r.line_prog, view, proj);
        f.BindVertexArray(r.line_vao);
        f.DrawArrays(gl.LINES, 0, @intCast(r.uploaded_lines));
    }
    if (r.uploaded_translucent_bonds > 0) {
        // Faded contacts: blended, no depth writes, so they never hide anything.
        f.Enable(gl.BLEND);
        f.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        f.DepthMask(gl.FALSE);
        setMatrices(r.cylinder_prog, view, proj);
        f.BindVertexArray(r.cylinder_vao);
        // Instance attributes start at the first translucent bond.
        const stride = @sizeOf(BondInstance);
        const base = r.uploaded_opaque_bonds * stride;
        f.BindBuffer(gl.ARRAY_BUFFER, r.bond_vbo);
        rebaseBondAttribs(base);
        f.DrawElementsInstanced(gl.TRIANGLES, r.cyl_index_count, gl.UNSIGNED_SHORT, null, @intCast(r.uploaded_translucent_bonds));
        rebaseBondAttribs(0);
        f.DepthMask(gl.TRUE);
        f.Disable(gl.BLEND);
    }
    f.BindVertexArray(0);
}

fn rebaseBondAttribs(base: usize) void {
    const s = @sizeOf(BondInstance);
    instanceAttrib(1, 4, s, base + @offsetOf(BondInstance, "a"));
    instanceAttrib(2, 4, s, base + @offsetOf(BondInstance, "b"));
    instanceAttrib(3, 4, s, base + @offsetOf(BondInstance, "color_a"));
    instanceAttrib(4, 4, s, base + @offsetOf(BondInstance, "color_b"));
}
