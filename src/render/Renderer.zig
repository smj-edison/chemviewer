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

pub const Theme = enum(c_int) {
    light,
    dark,
    /// Experimental: flat, saturated "Kurzgesagt" look: solid pale
    /// background, single-colour atoms with highlight dots, flat drop
    /// shadows, depth shown by fading toward the background.
    kurzgesagt,

    pub fn palette(t: Theme) cv.color.Palette {
        return switch (t) {
            .light => cv.color.light_palette,
            .dark => cv.color.dark_palette,
            .kurzgesagt => cv.color.kurzgesagt_palette,
        };
    }

    pub fn isLight(t: Theme) bool {
        return t == .light;
    }

    pub fn background(t: Theme) [3]f32 {
        return t.palette().background;
    }

    pub fn outline(t: Theme) [3]f32 {
        return switch (t) {
            .light => .{ 0.10, 0.11, 0.13 },
            .dark => .{ 0.0, 0.0, 0.0 },
            .kurzgesagt => .{ 0.33, 0.25, 0.94 }, // unused: the flat theme has no outlines
        };
    }

    /// Element colour, adjusted per theme where the default would blend
    /// with bonds: carbon is lifted well above the single-bond grey.
    pub fn atomColor(t: Theme, z: u8) [3]f32 {
        if (t == .kurzgesagt) return kurzgesagtAtomColor(z);
        if (z == 6) return switch (t) {
            .light => .{ 0.71, 0.71, 0.72 }, // OKLab L ≈ 0.77 vs single bonds 0.50
            .dark => .{ 0.77, 0.77, 0.78 }, // OKLab L ≈ 0.82 vs single bonds 0.58
            .kurzgesagt => unreachable,
        };
        return cv.elements.colorRgb(z);
    }

    /// Selection accent (rings, labels, measurement lines).
    pub fn accent(t: Theme) [3]f32 {
        return switch (t) {
            .light => .{ 0.93, 0.45, 0.0 },
            .dark => .{ 1.0, 0.72, 0.2 },
            .kurzgesagt => .{ 0.33, 0.25, 0.94 }, // #5540F0 violet
        };
    }

    pub fn cellLine(t: Theme) [4]f32 {
        return switch (t) {
            .light => .{ 0.30, 0.32, 0.36, 1 },
            .dark => .{ 0.60, 0.60, 0.65, 1 },
            .kurzgesagt => .{ 0.33, 0.25, 0.94, 0.8 },
        };
    }

    /// Flat drop-shadow colour: a deeper, more saturated shade of the
    /// background, as in Kurzgesagt's silhouettes (OKLCh 0.865, 0.024, 255).
    pub fn shadow(t: Theme) [3]f32 {
        return switch (t) {
            .kurzgesagt => .{ 0.7858, 0.8304, 0.8886 }, // #C8D4E3
            else => t.background(),
        };
    }

    /// Shader lighting mode (`u_cel` in shaders.zig).
    pub fn lightingMode(t: Theme, shading: Shading) c_int {
        if (t == .kurzgesagt) return 2;
        return @intFromBool(shading == .cel);
    }
};

/// Flat, saturated element colours sampled from Kurzgesagt's molecule
/// illustrations (pink carbon, blue oxygen, cyan nitrogen, white hydrogen).
/// Others are picked to stay clear of the pale background; anything not
/// listed is its CPK hue made bright and saturated.
fn kurzgesagtAtomColor(z: u8) [3]f32 {
    const hex: ?u24 = switch (z) {
        1 => 0xFFFFFF, // H
        5 => 0xFF9A7A, // B: salmon
        6 => 0xFF2E7E, // C: hot pink
        7 => 0x02C8F0, // N: cyan
        8 => 0x5560F6, // O: periwinkle blue
        9 => 0x7BD84A, // F: lime
        14 => 0xC58A5A, // Si: clay
        15 => 0xFF7A1A, // P: orange
        16 => 0xE6E04A, // S: lemon (greener than gold)
        17 => 0x2FBF5F, // Cl: green
        35 => 0xA8325A, // Br: wine
        53 => 0x8A3FE0, // I: purple
        79 => 0xFFC21A, // Au: gold yellow, well apart from orange P
        else => null,
    };
    if (hex) |h| return .{
        @as(f32, @floatFromInt((h >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((h >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(h & 0xFF)) / 255.0,
    };
    var lch = cv.color.labToLch(cv.color.srgbToOklab(cv.elements.colorRgb(z)));
    lch.l = std.math.clamp(lch.l, 0.50, 0.75);
    lch.c = @max(lch.c * 1.5, 0.14);
    return cv.color.oklchToSrgb(lch);
}

pub const Shading = enum(c_int) {
    /// Flat lighting bands and outlines.
    cel,
    /// Smooth Blinn-Phong with highlights.
    smooth,
};

pub const Style = struct {
    theme: Theme = .light,
    shading: Shading = .cel,
    /// Outline width in screen pixels (logical; scaled by pixel density). 0 = none.
    outline_px: f32 = 2.0,
    atom_scale: f32 = 1.0,
    bond_radius: f32 = 0.11,
    bond_coloring: BondColoring = .gradient,
    /// Bonds with a character below this are not drawn (and don't connect
    /// groups when editing geometry).
    min_character: f32 = 0.25,
    /// How strongly bond character snaps toward whole bond orders before
    /// colouring (0 = linear, 1 = flat plateaus). See `cv.color.snap`.
    snap: f32 = 0.7,
    show_cell: bool = true,

    /// Drawn (and picked) atom radius. The flat theme uses chunkier atoms,
    /// like the overlapping discs in Kurzgesagt's molecules.
    pub fn atomRadius(s: Style, z: u8) f32 {
        const k: f32 = if (s.theme == .kurzgesagt) 1.3 else 1.0;
        return cv.elements.displayRadius(z) * s.atom_scale * k;
    }

    pub fn bondRadius(s: Style) f32 {
        const k: f32 = if (s.theme == .kurzgesagt) 1.3 else 1.0;
        return s.bond_radius * k;
    }
};

pub const Tint = struct {
    color: [3]f32,
    /// 0 = element colours, 1 = flat tint colour.
    amount: f32 = 0.65,
};

/// Bond colour from its character: the perceptual OKLCh palette in
/// `cv.color`, shaped by the snap curve. Returns sRGB + opacity.
pub fn gradientColor(palette: cv.color.Palette, character: f32, snap_strength: f32) [4]f32 {
    const bc = cv.color.bondColor(palette, character, snap_strength);
    return .{ bc.rgb[0], bc.rgb[1], bc.rgb[2], bc.alpha };
}

const AtomInstance = extern struct {
    center: [3]f32,
    radius: f32,
    color: [4]f32,
    /// > 0 for selected atoms: drawn with an accent ring.
    highlight: f32 = 0,
};
const BondInstance = extern struct {
    a: [3]f32,
    radius: f32,
    b: [3]f32,
    /// Outline weight 0..1: scales outline width and opacity (see `outlineWeight`).
    outline: f32,
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
/// Bounding sphere of the uploaded atoms (for the flat theme's depth fade).
bounds_center: Vec3 = .{ 0, 0, 0 },
bounds_radius: f32 = 1,
/// Bond to draw highlighted (key as in `App.pairKey`), set before building.
selected_bond: ?u64 = null,

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
    instanceAttrib(3, 1, @sizeOf(AtomInstance), @offsetOf(AtomInstance, "highlight"));

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

/// Whether a bond of this character is drawn with this style. Also defines
/// connectivity for selection and geometry edits.
pub fn isDrawn(style: Style, character: f32) bool {
    return character >= style.min_character and cv.color.snap(character, style.snap) >= 0.02;
}

/// How much outline a bond gets for its (snapped) character: none for
/// vanishing contacts, easing in so it is fully there by single-bond
/// character. Smooth, so forming/breaking bonds don't pop an outline on.
pub fn outlineWeight(snapped_character: f32) f32 {
    const t = std.math.clamp((snapped_character - 0.3) / (1.0 - 0.3), 0, 1);
    return t * t * (3 - 2 * t);
}

/// Mark atoms (indices relative to `start`, as returned by `addStructure`)
/// as selected.
pub fn highlight(r: *Renderer, start: usize, atoms: []const u32) void {
    for (atoms) |i| {
        if (start + i < r.atoms.items.len) r.atoms.items[start + i].highlight = 1;
    }
}

/// Queue one structure. `positions` may differ from the frame's own (e.g. aligned).
/// Returns the index of its first atom instance (for `highlight`).
pub fn addStructure(
    r: *Renderer,
    positions: []const Vec3,
    numbers: []const u8,
    bonds: []const Bond,
    style: Style,
    tint: ?Tint,
    /// Bonds cut by the user (keys from `App.pairKey`): drawn thin and red.
    cut: ?*const std.AutoHashMapUnmanaged(u64, void),
) !usize {
    const start = r.atoms.items.len;
    try r.atoms.ensureUnusedCapacity(r.gpa, positions.len);
    for (positions, numbers) |p, z| {
        const rgb = tinted(style.theme.atomColor(z), tint);
        r.atoms.appendAssumeCapacity(.{
            .center = p,
            .radius = style.atomRadius(z),
            .color = .{ rgb[0], rgb[1], rgb[2], 1 },
        });
    }
    for (bonds) |b| {
        if (!isDrawn(style, b.character)) continue;
        // Snapped character drives colour, opacity and thinning alike.
        const ch = cv.color.snap(b.character, style.snap);
        // Below single-bond character, thin the bond out as it fades.
        const thin = if (ch < 1) 0.35 + 0.65 * ch else 1.0;
        const outline = outlineWeight(ch);
        var ca: [4]f32 = undefined;
        var cb: [4]f32 = undefined;
        switch (style.bond_coloring) {
            .gradient => {
                const g = gradientColor(style.theme.palette(), b.character, style.snap);
                const rgb = tinted(.{ g[0], g[1], g[2] }, tint);
                ca = .{ rgb[0], rgb[1], rgb[2], g[3] };
                cb = ca;
            },
            .element => {
                const alpha = @min(ch, 1.0);
                const ra = tinted(style.theme.atomColor(numbers[b.a]), tint);
                const rb = tinted(style.theme.atomColor(numbers[b.b]), tint);
                ca = .{ ra[0], ra[1], ra[2], alpha };
                cb = .{ rb[0], rb[1], rb[2], alpha };
            },
        }
        var radius_scale = thin;
        const key = (@as(u64, @min(b.a, b.b)) << 32) | @max(b.a, b.b);
        if (cut) |set| if (set.contains(key)) {
            const red: [3]f32 = .{ 0.85, 0.15, 0.15 };
            ca = .{ red[0], red[1], red[2], @max(ca[3], 0.6) };
            cb = ca;
            radius_scale = thin * 0.45;
        };
        if (r.selected_bond == key) {
            // Selected bond: accent colour, a little thicker, fully opaque.
            const ac = style.theme.accent();
            ca = .{ ac[0], ac[1], ac[2], 1 };
            cb = ca;
            radius_scale = @max(radius_scale, 0.8) * 1.3;
        }
        const inst: BondInstance = .{
            .a = positions[b.a],
            .b = positions[b.b],
            .radius = style.bondRadius() * radius_scale,
            .outline = outline,
            .color_a = ca,
            .color_b = cb,
        };
        if (ca[3] < 0.99) try r.translucent.append(r.gpa, inst) else try r.bonds.append(r.gpa, inst);
    }
    return start;
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
    if (r.atoms.items.len > 0) {
        var lo: Vec3 = r.atoms.items[0].center;
        var hi: Vec3 = lo;
        for (r.atoms.items) |a| {
            lo = @min(lo, @as(Vec3, a.center));
            hi = @max(hi, @as(Vec3, a.center));
        }
        r.bounds_center = (lo + hi) * @as(Vec3, @splat(0.5));
        var rad: f32 = 0;
        for (r.atoms.items) |a| rad = @max(rad, math.length(@as(Vec3, a.center) - r.bounds_center) + a.radius);
        r.bounds_radius = @max(rad, 1);
    }

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

pub const DrawParams = struct {
    view: Mat4,
    proj: Mat4,
    /// Framebuffer size in pixels.
    width: i32,
    height: i32,
    /// Vertical field of view (radians), for converting pixels to world units.
    fovy: f32,
    /// Physical pixels per logical pixel (HiDPI).
    pixel_density: f32 = 1,
    style: Style,
    /// Filled in by `draw`: world units per framebuffer pixel at unit depth.
    world_per_px: f32 = 0,
    /// Filled in by `draw`: view-depth range of the scene (flat theme fade).
    fog_range: [2]f32 = .{ 0, 1 },
};

fn setCommon(prog: gl.Uint, p: DrawParams, outline_k: f32) void {
    const f = &gl.f;
    f.UseProgram(prog);
    f.UniformMatrix4fv(f.GetUniformLocation(prog, "u_view"), 1, gl.FALSE, @ptrCast(&p.view.m));
    f.UniformMatrix4fv(f.GetUniformLocation(prog, "u_proj"), 1, gl.FALSE, @ptrCast(&p.proj.m));
    f.Uniform1i(f.GetUniformLocation(prog, "u_cel"), p.style.theme.lightingMode(p.style.shading));
    f.Uniform1f(f.GetUniformLocation(prog, "u_outline_k"), outline_k);
    f.Uniform1i(f.GetUniformLocation(prog, "u_outline_pass"), 0);
    const oc = p.style.theme.outline();
    f.Uniform3f(f.GetUniformLocation(prog, "u_outline_color"), oc[0], oc[1], oc[2]);
    const ac = p.style.theme.accent();
    f.Uniform3f(f.GetUniformLocation(prog, "u_select_color"), ac[0], ac[1], ac[2]);
    f.Uniform1f(f.GetUniformLocation(prog, "u_select_k"), 3.5 * p.pixel_density * p.world_per_px);
    const bg = p.style.theme.background();
    f.Uniform3f(f.GetUniformLocation(prog, "u_fog_color"), bg[0], bg[1], bg[2]);
    f.Uniform2f(f.GetUniformLocation(prog, "u_fog_range"), p.fog_range[0], p.fog_range[1]);
    f.Uniform1f(f.GetUniformLocation(prog, "u_fog_amount"), 0.45);
    const sc = p.style.theme.shadow();
    f.Uniform3f(f.GetUniformLocation(prog, "u_shadow_color"), sc[0], sc[1], sc[2]);
    f.Uniform2f(f.GetUniformLocation(prog, "u_shadow_offset"), 0, 0);
    f.Uniform1f(f.GetUniformLocation(prog, "u_shadow_pass"), 0);
}

pub fn draw(r: *Renderer, params: DrawParams) void {
    const f = &gl.f;
    var p = params;
    p.world_per_px = 2 * @tan(p.fovy / 2) / @as(f32, @floatFromInt(@max(p.height, 1)));
    const center_depth = -(p.view.transformPoint(r.bounds_center))[2];
    p.fog_range = .{ center_depth - r.bounds_radius, center_depth + r.bounds_radius };
    const bg = p.style.theme.background();
    f.Viewport(0, 0, p.width, p.height);
    f.ClearColor(bg[0], bg[1], bg[2], 1);
    f.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    f.Enable(gl.DEPTH_TEST);
    f.DepthFunc(gl.LESS);
    f.DepthMask(gl.TRUE);
    f.Disable(gl.BLEND);
    f.Disable(gl.CULL_FACE);

    // Outline width in world units per unit of view depth (constant on screen).
    const outlines = p.style.theme.lightingMode(p.style.shading) == 1 and p.style.outline_px > 0;
    const outline_k: f32 = if (outlines) p.style.outline_px * p.pixel_density * p.world_per_px else 0;

    if (p.style.theme == .kurzgesagt) r.drawShadows(p);

    if (r.uploaded_atoms > 0) {
        setCommon(r.sphere_prog, p, outline_k);
        f.BindVertexArray(r.sphere_vao);
        // Smooth sphere silhouettes when multisampling is available.
        f.Enable(gl.SAMPLE_ALPHA_TO_COVERAGE);
        f.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(r.uploaded_atoms));
        f.Disable(gl.SAMPLE_ALPHA_TO_COVERAGE);
    }
    if (r.uploaded_opaque_bonds > 0) {
        setCommon(r.cylinder_prog, p, outline_k);
        f.BindVertexArray(r.cylinder_vao);
        f.DrawElementsInstanced(gl.TRIANGLES, r.cyl_index_count, gl.UNSIGNED_SHORT, null, @intCast(r.uploaded_opaque_bonds));
        if (outlines) {
            // Inverted hull: inflated cylinders, back faces only, flat outline colour.
            f.Uniform1i(f.GetUniformLocation(r.cylinder_prog, "u_outline_pass"), 1);
            f.Enable(gl.CULL_FACE);
            f.CullFace(gl.FRONT);
            f.DrawElementsInstanced(gl.TRIANGLES, r.cyl_index_count, gl.UNSIGNED_SHORT, null, @intCast(r.uploaded_opaque_bonds));
            f.Disable(gl.CULL_FACE);
        }
    }
    if (r.uploaded_lines > 0) {
        setCommon(r.line_prog, p, 0);
        f.BindVertexArray(r.line_vao);
        f.DrawArrays(gl.LINES, 0, @intCast(r.uploaded_lines));
    }
    if (r.uploaded_translucent_bonds > 0) {
        // Faded contacts, blended. Bodies write depth so their own (faint,
        // partial) outline hull only shows outside the silhouette; they are
        // drawn after everything opaque, so they never hide solid geometry.
        f.Enable(gl.BLEND);
        f.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        setCommon(r.cylinder_prog, p, outline_k);
        f.BindVertexArray(r.cylinder_vao);
        // Instance attributes start at the first translucent bond.
        const stride = @sizeOf(BondInstance);
        const base = r.uploaded_opaque_bonds * stride;
        f.BindBuffer(gl.ARRAY_BUFFER, r.bond_vbo);
        rebaseBondAttribs(base);
        const n: gl.Sizei = @intCast(r.uploaded_translucent_bonds);
        f.DrawElementsInstanced(gl.TRIANGLES, r.cyl_index_count, gl.UNSIGNED_SHORT, null, n);
        if (outlines) {
            f.DepthMask(gl.FALSE);
            f.Uniform1i(f.GetUniformLocation(r.cylinder_prog, "u_outline_pass"), 1);
            f.Enable(gl.CULL_FACE);
            f.CullFace(gl.FRONT);
            f.DrawElementsInstanced(gl.TRIANGLES, r.cyl_index_count, gl.UNSIGNED_SHORT, null, n);
            f.Disable(gl.CULL_FACE);
            f.DepthMask(gl.TRUE);
        }
        rebaseBondAttribs(0);
        f.Disable(gl.BLEND);
    }
    f.BindVertexArray(0);
}

/// Flat theme: every opaque atom and bond as a flat silhouette in a darker
/// shade of the background, offset down and to the right. Drawn first,
/// without depth, so the molecule covers its own shadow.
fn drawShadows(r: *Renderer, p: DrawParams) void {
    const f = &gl.f;
    const px = 6 * p.pixel_density;
    const off: [2]f32 = .{ 2 * px / @as(f32, @floatFromInt(@max(p.width, 1))), -2 * px / @as(f32, @floatFromInt(@max(p.height, 1))) };
    f.Disable(gl.DEPTH_TEST);
    f.DepthMask(gl.FALSE);
    if (r.uploaded_opaque_bonds > 0) {
        setCommon(r.cylinder_prog, p, 0);
        setShadow(r.cylinder_prog, off);
        f.BindVertexArray(r.cylinder_vao);
        f.DrawElementsInstanced(gl.TRIANGLES, r.cyl_index_count, gl.UNSIGNED_SHORT, null, @intCast(r.uploaded_opaque_bonds));
        setShadow(r.cylinder_prog, null);
    }
    if (r.uploaded_atoms > 0) {
        setCommon(r.sphere_prog, p, 0);
        setShadow(r.sphere_prog, off);
        f.BindVertexArray(r.sphere_vao);
        f.Enable(gl.BLEND);
        f.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        f.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(r.uploaded_atoms));
        f.Disable(gl.BLEND);
        setShadow(r.sphere_prog, null);
    }
    f.DepthMask(gl.TRUE);
    f.Enable(gl.DEPTH_TEST);
}

fn setShadow(prog: gl.Uint, offset: ?[2]f32) void {
    const f = &gl.f;
    const o = offset orelse .{ 0, 0 };
    f.Uniform2f(f.GetUniformLocation(prog, "u_shadow_offset"), o[0], o[1]);
    f.Uniform1f(f.GetUniformLocation(prog, "u_shadow_pass"), if (offset != null) 1 else 0);
}

fn rebaseBondAttribs(base: usize) void {
    const s = @sizeOf(BondInstance);
    instanceAttrib(1, 4, s, base + @offsetOf(BondInstance, "a"));
    instanceAttrib(2, 4, s, base + @offsetOf(BondInstance, "b"));
    instanceAttrib(3, 4, s, base + @offsetOf(BondInstance, "color_a"));
    instanceAttrib(4, 4, s, base + @offsetOf(BondInstance, "color_b"));
}
