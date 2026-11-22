//! Draws atoms (sphere impostors), bonds (instanced cylinders) and cell edges.
//!
//! Usage per scene change: `clear`, then `addStructure` (once per layer,
//! e.g. twice for a diff overlay) and `addCell`, then `upload`. `draw`
//! records a frame (Vulkan, see `Gpu`) without rebuilding anything.
const std = @import("std");
const cv = @import("chemviewer");
const vk = @import("vulkan");
const Gpu = @import("Gpu.zig");
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

/// Light or dark: owns the background, bond palette, accents and outlines.
pub const Theme = enum(c_int) {
    light,
    dark,

    pub fn palette(t: Theme) cv.color.Palette {
        return switch (t) {
            .light => cv.color.light_palette,
            .dark => cv.color.dark_palette,
        };
    }

    pub fn background(t: Theme) [3]f32 {
        return t.palette().background;
    }

    pub fn outline(t: Theme) [3]f32 {
        return switch (t) {
            .light => .{ 0.10, 0.11, 0.13 },
            .dark => .{ 0.0, 0.0, 0.0 },
        };
    }

    /// Flat style's drop-shadow colour: a deeper shade of the background.
    pub fn shadow(t: Theme) [3]f32 {
        return switch (t) {
            .light => .{ 0.7858, 0.8304, 0.8886 }, // #C8D4E3, OKLCh (0.865, 0.024, 255)
            .dark => .{ 0.055, 0.058, 0.075 }, // OKLCh ≈ (0.17, 0.01, 265)
        };
    }

    /// Colours for the background pattern (shaders/background.frag), the
    /// same in both shadings. `ink` is the main tone and `deep` a stronger
    /// one (cell rims, nuclei); `light` sits on the other side of the
    /// background; `glow_a`/`glow_b` tint the space backdrop's bokeh and haze.
    pub fn backdrop(t: Theme) Backdrop {
        const hex = struct {
            fn f(h: u24) [3]f32 {
                return .{
                    @as(f32, @floatFromInt((h >> 16) & 0xFF)) / 255.0,
                    @as(f32, @floatFromInt((h >> 8) & 0xFF)) / 255.0,
                    @as(f32, @floatFromInt(h & 0xFF)) / 255.0,
                };
            }
        }.f;
        return switch (t) {
            .light => .{
                .ink = hex(0xC5D1E1),
                .deep = hex(0xAEBDD3),
                .light = hex(0xF3F6FA),
                .glow_a = hex(0xF6CFE2), // blush pink
                .glow_b = hex(0xCFCBF6), // lavender
            },
            .dark => .{
                .ink = hex(0x22252F),
                .deep = hex(0x2C3040),
                .light = hex(0xB8C0E0),
                .glow_a = hex(0x9A3A6E), // muted magenta
                .glow_b = hex(0x2F5E9E), // muted blue
            },
        };
    }

    /// Selection accent (rings, labels, measurement lines).
    pub fn accent(t: Theme) [3]f32 {
        return switch (t) {
            .light => .{ 0.93, 0.45, 0.0 },
            .dark => .{ 1.0, 0.72, 0.2 },
        };
    }

    pub fn cellLine(t: Theme) [4]f32 {
        return switch (t) {
            .light => .{ 0.30, 0.32, 0.36, 1 },
            .dark => .{ 0.60, 0.60, 0.65, 1 },
        };
    }
};

pub const Backdrop = struct {
    ink: [3]f32,
    deep: [3]f32,
    light: [3]f32,
    glow_a: [3]f32,
    glow_b: [3]f32,
};

/// Background motif (both shadings).
pub const BackdropKind = enum(c_int) {
    /// Out-of-focus cells: soft blobs with a membrane rim and a nucleus.
    cells,
    /// Out-of-focus space: glowing bokeh, faint nebula haze, sparkle stars.
    space,
};

/// How atoms and bonds are drawn; works with either theme.
pub const Shading = enum(c_int) {
    /// Toon bands with outlines.
    cel,
    /// Inspired by Kurzgesagt's flat illustrations: solid fills with
    /// highlight dots, no outlines, flat drop shadows, depth shown by fading
    /// toward the background, chunkier atoms.
    flat,
    /// In the spirit of Frutiger Aero (Vista/7-era gloss): glassy atoms with
    /// an Aqua-style highlight cap, rim light and specular glints, in front
    /// of a sky dome (or, in the dark theme, an aurora night) with bubbles.
    aero,

    /// Shader lighting mode (`u_cel` in shaders/common.glsl).
    pub fn lightingMode(sh: Shading) c_int {
        return switch (sh) {
            .cel => 1,
            .flat => 2,
            .aero => 3,
        };
    }
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
    /// Pattern behind the molecule that turns with the camera (see
    /// shaders/background.frag). Off gives the plain solid background.
    background_pattern: bool = true,
    /// Motif behind the molecule.
    backdrop: BackdropKind = .cells,
    /// Flat style experiment: soft (feathered) drop shadows plus a thin dark
    /// outline on atoms and bonds, so the molecule stands out more.
    flat_pop: bool = false,
    /// Depth-of-field strength for the background pattern (0 = sharp).
    background_blur: f32 = 0.6,

    /// Element colour: the same in every theme and style.
    pub fn atomColor(s: Style, z: u8) [3]f32 {
        _ = s;
        return cv.elements.displayColor(z);
    }

    /// Drawn (and picked) atom radius. Flat uses chunkier atoms, like the
    /// overlapping discs in Kurzgesagt's molecules.
    pub fn atomRadius(s: Style, z: u8) f32 {
        const k: f32 = if (s.shading == .flat) 1.3 else 1.0;
        return cv.elements.displayRadius(z) * s.atom_scale * k;
    }

    pub fn bondRadius(s: Style) f32 {
        const k: f32 = if (s.shading == .flat) 1.3 else 1.0;
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
gpu: *Gpu,
set_layout: vk.DescriptorSetLayout,
layout: vk.PipelineLayout,
pool: vk.DescriptorPool,
/// One per frame in flight: its uniforms and the backdrop cache.
sets: [Gpu.frames_in_flight]vk.DescriptorSet,
sampler: vk.Sampler,
pipes: Pipelines,
quad: Gpu.Buffer,
cyl_vbo: Gpu.Buffer,
cyl_ibo: Gpu.Buffer,
slots: [Gpu.frames_in_flight]Slot = @splat(.{}),
/// The backdrop, rendered at reduced resolution and only when its inputs
/// change (see `updateBackground`).
bg_cache: BackgroundCache = .{},

atoms: std.ArrayList(AtomInstance) = .empty,
/// Opaque bonds first, then translucent ones (drawn without depth writes).
bonds: std.ArrayList(BondInstance) = .empty,
translucent: std.ArrayList(BondInstance) = .empty,
lines: std.ArrayList(LineVertex) = .empty,
uploaded: Uploaded = .{},
/// Bumped by `upload`; frame slots compare it to their own copy.
generation: u64 = 1,
/// GPU timing of the background pass and the rest of `draw` (`--profile`).
profile: ?Profile = null,
/// Bounding sphere of the uploaded atoms (for the flat style's depth fade).
bounds_center: Vec3 = .{ 0, 0, 0 },
bounds_radius: f32 = 1,

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
        const rgb = tinted(style.atomColor(z), tint);
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
                const ra = tinted(style.atomColor(numbers[b.a]), tint);
                const rb = tinted(style.atomColor(numbers[b.b]), tint);
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

    // Snapshot: each frame slot copies it into its own buffers when it next
    // draws (`syncSlot`), so frames still in flight keep their data.
    const up = &r.uploaded;
    up.atoms.clearRetainingCapacity();
    try up.atoms.appendSlice(r.gpa, r.atoms.items);
    // Opaque bonds followed by translucent ones in a single buffer.
    up.bonds.clearRetainingCapacity();
    try up.bonds.appendSlice(r.gpa, r.bonds.items);
    try up.bonds.appendSlice(r.gpa, r.translucent.items);
    up.opaque_bonds = r.bonds.items.len;
    up.lines.clearRetainingCapacity();
    try up.lines.appendSlice(r.gpa, r.lines.items);
    r.generation += 1;
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
    /// View matrix of the background pattern (`Camera.bgView`); `view` if null.
    bg_view: ?Mat4 = null,
    /// Fixed anchor (pattern space) and scene radius for the background
    /// pattern (`Camera.bg_anchor` / `bg_radius`).
    bg_anchor: Vec3 = .{ 0, 0, 0 },
    bg_radius: f32 = 1,
    /// Filled in by `draw`: world units per framebuffer pixel at unit depth.
    world_per_px: f32 = 0,
    /// Filled in by `draw`: view-depth range of the scene (flat style fade).
    fog_range: [2]f32 = .{ 0, 1 },
};

/// Per-frame uniforms: `Frame` in shaders/common.glsl (std140).
const FrameUniforms = extern struct {
    view: [16]f32,
    proj: [16]f32,
    outline_color: [3]f32,
    fog_amount: f32,
    select_color: [3]f32,
    select_k: f32,
    fog_color: [3]f32,
    cel: i32,
    shadow_color: [3]f32,
    pad0: f32 = 0,
    fog_range: [2]f32,
    pad1: [2]f32 = .{ 0, 0 },
    bg: [3]f32,
    mode: i32,
    ink: [3]f32,
    radius: f32,
    deep: [3]f32,
    px: f32,
    light: [3]f32,
    coc_px: f32,
    glow_a: [3]f32,
    pad2: f32 = 0,
    glow_b: [3]f32,
    pad3: f32 = 0,
    anchor: [3]f32,
    pad4: f32 = 0,
    tan: [2]f32,
    pad5: [2]f32 = .{ 0, 0 },
    bg_view: [16]f32,
};

/// Per-draw push constants: `Draw` in shaders/common.glsl.
const Push = extern struct {
    shadow_offset: [2]f32 = .{ 0, 0 },
    shadow_pass: f32 = 0,
    outline_k: f32 = 0,
    outline_pass: i32 = 0,
    shadow_soft: i32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(FrameUniforms) == 400);
    std.debug.assert(@offsetOf(FrameUniforms, "bg") == 208);
}

const Pipelines = struct {
    sphere: vk.Pipeline,
    sphere_shadow: vk.Pipeline,
    sphere_shadow_soft: vk.Pipeline,
    cylinder_shadow_soft: vk.Pipeline,
    blit_multiply: vk.Pipeline,
    fill_multiply: vk.Pipeline,
    cylinder: vk.Pipeline,
    cylinder_blend: vk.Pipeline,
    cylinder_shadow: vk.Pipeline,
    line: vk.Pipeline,
    background: vk.Pipeline,
    blit: vk.Pipeline,
};

/// Resources one frame in flight owns. Rewritten only after its fence (in
/// `Gpu.beginFrame`) shows the GPU is done with them.
const Slot = struct {
    uniforms: Gpu.Buffer = .{},
    atoms: Gpu.Buffer = .{},
    bonds: Gpu.Buffer = .{},
    lines: Gpu.Buffer = .{},
    /// `Renderer.generation` of the instance data in the buffers.
    generation: u64 = 0,

    fn deinit(s: *Slot, gpu: *const Gpu) void {
        s.uniforms.deinit(gpu);
        s.atoms.deinit(gpu);
        s.bonds.deinit(gpu);
        s.lines.deinit(gpu);
    }
};

/// The instance data of the last `upload`.
const Uploaded = struct {
    atoms: std.ArrayList(AtomInstance) = .empty,
    bonds: std.ArrayList(BondInstance) = .empty,
    opaque_bonds: usize = 0,
    lines: std.ArrayList(LineVertex) = .empty,

    fn deinit(u: *Uploaded, gpa: Allocator) void {
        u.atoms.deinit(gpa);
        u.bonds.deinit(gpa);
        u.lines.deinit(gpa);
    }
};

pub fn init(gpa: Allocator, gpu: *Gpu) !Renderer {
    const dev = gpu.dev;
    const set_layout = try dev.createDescriptorSetLayout(&.{
        .binding_count = 2,
        .p_bindings = &.{
            .{
                .binding = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .vertex = true, .fragment = true },
            },
            .{
                .binding = 1,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 1,
                .stage_flags = .{ .fragment = true },
            },
        },
    }, null);
    const layout = try dev.createPipelineLayout(&.{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = &.{.{
            .stage_flags = .{ .vertex = true, .fragment = true },
            .offset = 0,
            .size = @sizeOf(Push),
        }},
    }, null);
    const n = Gpu.frames_in_flight;
    const pool = try dev.createDescriptorPool(&.{
        .max_sets = n,
        .pool_size_count = 2,
        .p_pool_sizes = &.{
            .{ .type = .uniform_buffer, .descriptor_count = n },
            .{ .type = .combined_image_sampler, .descriptor_count = n },
        },
    }, null);
    var sets: [n]vk.DescriptorSet = undefined;
    const set_layouts: [n]vk.DescriptorSetLayout = @splat(set_layout);
    try dev.allocateDescriptorSets(&.{
        .descriptor_pool = pool,
        .descriptor_set_count = n,
        .p_set_layouts = &set_layouts,
    }, &sets);

    var r: Renderer = .{
        .gpa = gpa,
        .gpu = gpu,
        .set_layout = set_layout,
        .layout = layout,
        .pool = pool,
        .sets = sets,
        .sampler = try dev.createSampler(&.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .float_opaque_black,
            .unnormalized_coordinates = .false,
        }, null),
        .pipes = try createPipelines(gpu, layout),
        .quad = undefined,
        .cyl_vbo = undefined,
        .cyl_ibo = undefined,
    };

    // --- spheres: one quad, expanded per instance
    const quad = [_]f32{ -1, -1, 1, -1, -1, 1, 1, 1 };
    r.quad = try gpu.createBufferWith(std.mem.asBytes(&quad), .{ .vertex_buffer = true });

    // --- cylinders: side wall mesh, per-instance endpoints/colors
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
    r.cyl_vbo = try gpu.createBufferWith(std.mem.asBytes(&verts), .{ .vertex_buffer = true });
    r.cyl_ibo = try gpu.createBufferWith(std.mem.asBytes(&idx), .{ .index_buffer = true });

    for (&r.slots, r.sets) |*s, set| {
        s.uniforms = try gpu.createBuffer(@sizeOf(FrameUniforms), .{ .uniform_buffer = true }, .{ .host_visible = true, .host_coherent = true });
        dev.updateDescriptorSets(&.{.{
            .dst_set = set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .uniform_buffer,
            .p_image_info = &.{},
            .p_buffer_info = &.{.{ .buffer = s.uniforms.buffer, .offset = 0, .range = @sizeOf(FrameUniforms) }},
            .p_texel_buffer_view = &.{},
        }}, null);
    }
    return r;
}

pub fn deinit(r: *Renderer) void {
    const gpu = r.gpu;
    const dev = gpu.dev;
    gpu.waitIdle();
    _ = Profile.end(r);
    inline for (@typeInfo(Pipelines).@"struct".field_names) |name| dev.destroyPipeline(@field(r.pipes, name), null);
    for (&r.slots) |*s| s.deinit(gpu);
    r.quad.deinit(gpu);
    r.cyl_vbo.deinit(gpu);
    r.cyl_ibo.deinit(gpu);
    r.bg_cache.image.deinit(gpu);
    dev.destroySampler(r.sampler, null);
    dev.destroyDescriptorPool(r.pool, null);
    dev.destroyPipelineLayout(r.layout, null);
    dev.destroyDescriptorSetLayout(r.set_layout, null);
    r.atoms.deinit(r.gpa);
    r.bonds.deinit(r.gpa);
    r.translucent.deinit(r.gpa);
    r.lines.deinit(r.gpa);
    r.uploaded.deinit(r.gpa);
}

const Blend = enum { none, alpha, multiply, min };

const PipelineDesc = struct {
    vert: vk.ShaderModule,
    frag: vk.ShaderModule,
    bindings: []const vk.VertexInputBindingDescription = &.{},
    attributes: []const vk.VertexInputAttributeDescription = &.{},
    topology: vk.PrimitiveTopology,
    blend: Blend = .none,
    alpha_to_coverage: bool = false,
    depth_test: bool = true,
    /// The backdrop cache (single-sampled half floats, no depth) instead of
    /// the scene targets.
    backdrop: bool = false,
};

const backdrop_format: vk.Format = .r16g16b16a16_sfloat;

fn createPipeline(gpu: *const Gpu, layout: vk.PipelineLayout, d: PipelineDesc) !vk.Pipeline {
    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex = true }, .module = d.vert, .p_name = "main" },
        .{ .stage = .{ .fragment = true }, .module = d.frag, .p_name = "main" },
    };
    const factors: [2]vk.BlendFactor = switch (d.blend) {
        .none => .{ .one, .zero },
        .alpha => .{ .src_alpha, .one_minus_src_alpha },
        // Shadows multiply what is behind them.
        .multiply => .{ .dst_color, .zero },
        // Soft shadow factors: keep the darkest, so overlaps darken once.
        .min => .{ .one, .one },
    };
    const op: vk.BlendOp = if (d.blend == .min) .min else .add;
    const attachment: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = .fromBool(d.blend != .none),
        .src_color_blend_factor = factors[0],
        .dst_color_blend_factor = factors[1],
        .color_blend_op = op,
        .src_alpha_blend_factor = factors[0],
        .dst_alpha_blend_factor = factors[1],
        .alpha_blend_op = op,
        .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
    };
    const dynamic = [_]vk.DynamicState{ .viewport, .scissor, .cull_mode, .depth_write_enable };
    const color_format = if (d.backdrop) backdrop_format else gpu.surface_format.format;
    const rendering: vk.PipelineRenderingCreateInfo = .{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&color_format),
        .depth_attachment_format = if (d.backdrop) .undefined else gpu.depth_format,
        .stencil_attachment_format = .undefined,
    };
    var pipeline: vk.Pipeline = undefined;
    _ = try gpu.dev.createGraphicsPipelines(.null, &.{.{
        .p_next = &rendering,
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &.{
            .vertex_binding_description_count = @intCast(d.bindings.len),
            .p_vertex_binding_descriptions = d.bindings.ptr,
            .vertex_attribute_description_count = @intCast(d.attributes.len),
            .p_vertex_attribute_descriptions = d.attributes.ptr,
        },
        .p_input_assembly_state = &.{ .topology = d.topology, .primitive_restart_enable = .false },
        .p_viewport_state = &.{ .viewport_count = 1, .scissor_count = 1 },
        .p_rasterization_state = &.{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            // Counter-clockwise front faces, as in OpenGL: the flipped
            // viewport keeps OpenGL's winding.
            .front_face = .counter_clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &.{
            .rasterization_samples = if (d.backdrop) .{ .@"1" = true } else Gpu.samples,
            .sample_shading_enable = .false,
            .min_sample_shading = 0,
            .alpha_to_coverage_enable = .fromBool(d.alpha_to_coverage),
            .alpha_to_one_enable = .false,
        },
        .p_depth_stencil_state = &.{
            .depth_test_enable = .fromBool(d.depth_test and !d.backdrop),
            .depth_write_enable = .fromBool(d.depth_test and !d.backdrop),
            .depth_compare_op = .less,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = std.mem.zeroes(vk.StencilOpState),
            .back = std.mem.zeroes(vk.StencilOpState),
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        },
        .p_color_blend_state = &.{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&attachment),
            .blend_constants = .{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &.{ .dynamic_state_count = dynamic.len, .p_dynamic_states = &dynamic },
        .layout = layout,
        .subpass = 0,
        .base_pipeline_index = -1,
    }}, null, @ptrCast(&pipeline));
    return pipeline;
}

fn createPipelines(gpu: *const Gpu, layout: vk.PipelineLayout) !Pipelines {
    const dev = gpu.dev;
    const mods = .{
        .sphere_vs = try gpu.createShaderModule("sphere.vert.spv"),
        .sphere_fs = try gpu.createShaderModule("sphere.frag.spv"),
        .cylinder_vs = try gpu.createShaderModule("cylinder.vert.spv"),
        .cylinder_fs = try gpu.createShaderModule("cylinder.frag.spv"),
        .line_vs = try gpu.createShaderModule("line.vert.spv"),
        .line_fs = try gpu.createShaderModule("line.frag.spv"),
        .fullscreen_vs = try gpu.createShaderModule("fullscreen.vert.spv"),
        .background_fs = try gpu.createShaderModule("background.frag.spv"),
        .blit_fs = try gpu.createShaderModule("blit.frag.spv"),
        .fill_fs = try gpu.createShaderModule("fill.frag.spv"),
    };
    defer inline for (@typeInfo(@TypeOf(mods)).@"struct".field_names) |name| dev.destroyShaderModule(@field(mods, name), null);

    const sphere_bindings = [_]vk.VertexInputBindingDescription{
        .{ .binding = 0, .stride = 8, .input_rate = .vertex },
        .{ .binding = 1, .stride = @sizeOf(AtomInstance), .input_rate = .instance },
    };
    const sphere_attrs = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = 0 },
        .{ .location = 1, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(AtomInstance, "center") },
        .{ .location = 2, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(AtomInstance, "color") },
        .{ .location = 3, .binding = 1, .format = .r32_sfloat, .offset = @offsetOf(AtomInstance, "highlight") },
    };
    const cyl_bindings = [_]vk.VertexInputBindingDescription{
        .{ .binding = 0, .stride = 12, .input_rate = .vertex },
        .{ .binding = 1, .stride = @sizeOf(BondInstance), .input_rate = .instance },
    };
    const cyl_attrs = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = 0 },
        .{ .location = 1, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(BondInstance, "a") },
        .{ .location = 2, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(BondInstance, "b") },
        .{ .location = 3, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(BondInstance, "color_a") },
        .{ .location = 4, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(BondInstance, "color_b") },
    };
    const line_bindings = [_]vk.VertexInputBindingDescription{
        .{ .binding = 0, .stride = @sizeOf(LineVertex), .input_rate = .vertex },
    };
    const line_attrs = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(LineVertex, "pos") },
        .{ .location = 1, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(LineVertex, "color") },
    };

    const sphere: PipelineDesc = .{
        .vert = mods.sphere_vs,
        .frag = mods.sphere_fs,
        .bindings = &sphere_bindings,
        .attributes = &sphere_attrs,
        .topology = .triangle_strip,
        // Smooth sphere silhouettes from the shader's edge coverage.
        .alpha_to_coverage = true,
    };
    const cylinder: PipelineDesc = .{
        .vert = mods.cylinder_vs,
        .frag = mods.cylinder_fs,
        .bindings = &cyl_bindings,
        .attributes = &cyl_attrs,
        .topology = .triangle_list,
    };
    var sphere_shadow = sphere;
    sphere_shadow.blend = .multiply;
    var cylinder_blend = cylinder;
    cylinder_blend.blend = .alpha;
    var cylinder_shadow = cylinder;
    cylinder_shadow.blend = .multiply;
    var sphere_shadow_soft = sphere;
    sphere_shadow_soft.blend = .min;
    sphere_shadow_soft.alpha_to_coverage = false;
    sphere_shadow_soft.depth_test = false;
    var cylinder_shadow_soft = cylinder;
    cylinder_shadow_soft.blend = .min;
    cylinder_shadow_soft.depth_test = false;
    const blit: PipelineDesc = .{
        .vert = mods.fullscreen_vs,
        .frag = mods.blit_fs,
        .topology = .triangle_list,
        .depth_test = false,
    };
    var blit_multiply = blit;
    blit_multiply.blend = .multiply;
    var fill_multiply = blit;
    fill_multiply.frag = mods.fill_fs;
    fill_multiply.blend = .multiply;

    return .{
        .sphere = try createPipeline(gpu, layout, sphere),
        .sphere_shadow = try createPipeline(gpu, layout, sphere_shadow),
        .sphere_shadow_soft = try createPipeline(gpu, layout, sphere_shadow_soft),
        .cylinder_shadow_soft = try createPipeline(gpu, layout, cylinder_shadow_soft),
        .blit_multiply = try createPipeline(gpu, layout, blit_multiply),
        .fill_multiply = try createPipeline(gpu, layout, fill_multiply),
        .cylinder = try createPipeline(gpu, layout, cylinder),
        .cylinder_blend = try createPipeline(gpu, layout, cylinder_blend),
        .cylinder_shadow = try createPipeline(gpu, layout, cylinder_shadow),
        .line = try createPipeline(gpu, layout, .{
            .vert = mods.line_vs,
            .frag = mods.line_fs,
            .bindings = &line_bindings,
            .attributes = &line_attrs,
            .topology = .line_list,
        }),
        .background = try createPipeline(gpu, layout, .{
            .vert = mods.fullscreen_vs,
            .frag = mods.background_fs,
            .topology = .triangle_list,
            .backdrop = true,
        }),
        .blit = try createPipeline(gpu, layout, blit),
    };
}

/// GPU time per pass from timestamp queries, read back once each frame
/// slot comes round again (only for measuring).
pub const Profile = struct {
    pool: vk.QueryPool = .null,
    /// Slots whose queries hold a frame's results.
    pending: [Gpu.frames_in_flight]bool = @splat(false),
    frames: u32 = 0,
    background_ns: u64 = 0,
    scene_ns: u64 = 0,

    const per_slot = 3;

    pub fn begin(r: *Renderer) void {
        if (!r.gpu.timestamps) {
            std.log.err("profile: this GPU queue has no timestamps", .{});
            return;
        }
        const pool = r.gpu.dev.createQueryPool(&.{
            .query_type = .timestamp,
            .query_count = per_slot * Gpu.frames_in_flight,
        }, null) catch |e| {
            std.log.err("profile: {t}", .{e});
            return;
        };
        r.profile = .{ .pool = pool };
    }

    pub fn end(r: *Renderer) ?Profile {
        const prof = r.profile orelse return null;
        r.gpu.waitIdle();
        r.gpu.dev.destroyQueryPool(prof.pool, null);
        r.profile = null;
        return prof;
    }

    /// Adds the results of the frame that last used `slot`.
    fn collect(prof: *Profile, gpu: *const Gpu, slot: usize) void {
        if (!prof.pending[slot]) return;
        prof.pending[slot] = false;
        var ts: [per_slot]u64 = undefined;
        _ = gpu.dev.getQueryPoolResults(prof.pool, @intCast(slot * per_slot), per_slot, @sizeOf(@TypeOf(ts)), &ts, @sizeOf(u64), .{ .@"64" = true, .wait = true }) catch return;
        const period: f64 = gpu.props.limits.timestamp_period;
        const ns = struct {
            fn f(a: u64, b: u64, p: f64) u64 {
                return @intFromFloat(@as(f64, @floatFromInt(b -% a)) * p);
            }
        }.f;
        prof.background_ns += ns(ts[0], ts[1], period);
        prof.scene_ns += ns(ts[1], ts[2], period);
        prof.frames += 1;
    }

    fn stamp(prof: *Profile, frame: Gpu.Frame, i: u32) void {
        frame.cmd.writeTimestamp2(.{ .all_commands = true }, prof.pool, @as(u32, @intCast(frame.slot * per_slot)) + i);
    }
};

/// Copies the last upload into this frame slot's instance buffers if they
/// hold an older one.
fn syncSlot(r: *Renderer, slot: *Slot) !void {
    if (slot.generation == r.generation) return;
    const up = &r.uploaded;
    try r.fill(&slot.atoms, std.mem.sliceAsBytes(up.atoms.items));
    try r.fill(&slot.bonds, std.mem.sliceAsBytes(up.bonds.items));
    try r.fill(&slot.lines, std.mem.sliceAsBytes(up.lines.items));
    slot.generation = r.generation;
}

fn fill(r: *Renderer, buf: *Gpu.Buffer, bytes: []const u8) !void {
    if (buf.buffer == .null or buf.size < bytes.len) {
        buf.deinit(r.gpu);
        const size = @max(bytes.len + bytes.len / 2, 4096);
        buf.* = try r.gpu.createBuffer(size, .{ .vertex_buffer = true }, .{ .host_visible = true, .host_coherent = true });
    }
    buf.write(0, bytes);
}

/// Records the backdrop and the scene into `frame`: the scene pass resolves
/// into the swapchain image (see `Gpu.beginScenePass`).
pub fn draw(r: *Renderer, frame: Gpu.Frame, params: DrawParams) !void {
    const gpu = r.gpu;
    const cmd = frame.cmd;
    var p = params;
    p.world_per_px = 2 * @tan(p.fovy / 2) / @as(f32, @floatFromInt(@max(p.height, 1)));
    const center_depth = -(p.view.transformPoint(r.bounds_center))[2];
    p.fog_range = .{ center_depth - r.bounds_radius, center_depth + r.bounds_radius };

    const slot = &r.slots[frame.slot];
    try r.syncSlot(slot);
    const res = r.bg_cache.resolution(p.width, p.height);
    const u = frameUniforms(p, res);
    slot.uniforms.write(0, std.mem.asBytes(&u));
    const set = r.sets[frame.slot];

    if (r.profile) |*prof| {
        prof.collect(gpu, frame.slot);
        cmd.resetQueryPool(prof.pool, @intCast(frame.slot * Profile.per_slot), Profile.per_slot);
        prof.stamp(frame, 0);
    }
    if (p.style.background_pattern) try r.updateBackground(frame, p, set);

    // Flat "soft shadow": the pass clears to white, the feathered shadow
    // factors go down first (MIN keeps the darkest, so overlaps darken once),
    // and the backdrop (or plain background) is multiplied over them.
    const soft = p.style.shading == .flat and p.style.flat_pop;
    gpu.beginScenePass(frame, if (soft) .{ 1, 1, 1 } else p.style.theme.background());
    const w: f32 = @floatFromInt(frame.extent.width);
    const h: f32 = @floatFromInt(frame.extent.height);
    // Flipped (negative height) so NDC y points up, as in OpenGL.
    cmd.setViewport(0, &.{.{ .x = 0, .y = h, .width = w, .height = -h, .min_depth = 0, .max_depth = 1 }});
    cmd.setScissor(0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = frame.extent }});
    cmd.setCullMode(.{});
    cmd.setDepthWriteEnable(.true);
    cmd.bindDescriptorSets(.graphics, r.layout, 0, &.{set}, null);

    if (soft) {
        r.drawShadows(frame, p, slot, true);
        cmd.bindPipeline(.graphics, if (p.style.background_pattern) r.pipes.blit_multiply else r.pipes.fill_multiply);
        r.push(cmd, .{});
        cmd.draw(3, 1, 0, 0);
    } else if (p.style.background_pattern) {
        cmd.bindPipeline(.graphics, r.pipes.blit);
        r.push(cmd, .{});
        cmd.draw(3, 1, 0, 0);
    }
    if (r.profile) |*prof| prof.stamp(frame, 1);

    // Outline width in world units per unit of view depth (constant on screen).
    // Soft-shadow flat also gets a thin outline so the molecule stands out.
    const outlines = (p.style.shading == .cel and p.style.outline_px > 0) or soft;
    const outline_px: f32 = if (soft) 1.2 else p.style.outline_px;
    const outline_k: f32 = if (outlines) outline_px * p.pixel_density * p.world_per_px else 0;
    const up = &r.uploaded;
    const n_atoms: u32 = @intCast(up.atoms.items.len);
    const n_opaque: u32 = @intCast(up.opaque_bonds);
    const n_translucent: u32 = @intCast(up.bonds.items.len - up.opaque_bonds);
    const n_lines: u32 = @intCast(up.lines.items.len);
    const cyl_count: u32 = cylinder_segments * 6;

    if (p.style.shading == .flat and !soft) r.drawShadows(frame, p, slot, false);

    if (n_atoms > 0) {
        cmd.bindPipeline(.graphics, r.pipes.sphere);
        cmd.bindVertexBuffers(0, &.{ r.quad.buffer, slot.atoms.buffer }, &.{ 0, 0 });
        r.push(cmd, .{ .outline_k = outline_k });
        cmd.draw(4, n_atoms, 0, 0);
    }
    if (n_opaque + n_translucent > 0) {
        cmd.bindVertexBuffers(0, &.{ r.cyl_vbo.buffer, slot.bonds.buffer }, &.{ 0, 0 });
        cmd.bindIndexBuffer(r.cyl_ibo.buffer, 0, .uint16);
    }
    if (n_opaque > 0) {
        cmd.bindPipeline(.graphics, r.pipes.cylinder);
        r.push(cmd, .{ .outline_k = outline_k });
        cmd.drawIndexed(cyl_count, n_opaque, 0, 0, 0);
        if (outlines) {
            // Inverted hull: inflated cylinders, back faces only, flat outline colour.
            r.push(cmd, .{ .outline_k = outline_k, .outline_pass = 1 });
            cmd.setCullMode(.{ .front = true });
            cmd.drawIndexed(cyl_count, n_opaque, 0, 0, 0);
            cmd.setCullMode(.{});
        }
    }
    if (n_lines > 0) {
        cmd.bindPipeline(.graphics, r.pipes.line);
        cmd.bindVertexBuffers(0, &.{slot.lines.buffer}, &.{0});
        r.push(cmd, .{});
        cmd.draw(n_lines, 1, 0, 0);
    }
    if (n_translucent > 0) {
        // Faded contacts, blended. Bodies write depth so their own (faint,
        // partial) outline hull only shows outside the silhouette; they are
        // drawn after everything opaque, so they never hide solid geometry.
        // Instances start after the opaque bonds.
        cmd.bindPipeline(.graphics, r.pipes.cylinder_blend);
        cmd.bindVertexBuffers(0, &.{ r.cyl_vbo.buffer, slot.bonds.buffer }, &.{ 0, 0 });
        r.push(cmd, .{ .outline_k = outline_k });
        cmd.drawIndexed(cyl_count, n_translucent, 0, 0, n_opaque);
        if (outlines) {
            cmd.setDepthWriteEnable(.false);
            r.push(cmd, .{ .outline_k = outline_k, .outline_pass = 1 });
            cmd.setCullMode(.{ .front = true });
            cmd.drawIndexed(cyl_count, n_translucent, 0, 0, n_opaque);
            cmd.setCullMode(.{});
            cmd.setDepthWriteEnable(.true);
        }
    }
    if (r.profile) |*prof| {
        prof.stamp(frame, 2);
        prof.pending[frame.slot] = true;
    }
    gpu.endScenePass(frame);
}

fn push(r: *const Renderer, cmd: vk.CommandBufferProxy, pc: Push) void {
    cmd.pushConstants(r.layout, .{ .vertex = true, .fragment = true }, 0, @sizeOf(Push), &pc);
}

fn frameUniforms(p: DrawParams, res: f32) FrameUniforms {
    const style = p.style;
    const bg = style.theme.background();
    // Shadows multiply what is behind them (see `drawShadows`): the factor
    // turns the plain background into exactly the theme's shadow colour.
    const sc: @Vector(3, f32) = style.theme.shadow();
    const ratio = sc / @max(@as(@Vector(3, f32), bg), @as(@Vector(3, f32), @splat(1e-3)));
    const bd = style.theme.backdrop();
    const t = @tan(p.fovy / 2);
    const aspect = @as(f32, @floatFromInt(p.width)) / @as(f32, @floatFromInt(@max(p.height, 1)));
    return .{
        .view = @bitCast(p.view.m),
        .proj = @bitCast(p.proj.m),
        .outline_color = style.theme.outline(),
        .fog_amount = 0.45,
        .select_color = style.theme.accent(),
        .select_k = 3.5 * p.pixel_density * p.world_per_px,
        .fog_color = bg,
        .cel = style.shading.lightingMode(),
        .shadow_color = ratio,
        .fog_range = p.fog_range,
        .bg = bg,
        // Backdrop motif; aero has its own sky (2 = day, 3 = night).
        .mode = if (style.shading == .aero) (if (style.theme == .dark) 3 else 2) else @backingInt(style.backdrop),
        .ink = bd.ink,
        .radius = p.bg_radius,
        .deep = bd.deep,
        // Backdrop target pixels are 1/res framebuffer pixels: anti-aliasing
        // widens with them, while the lens blur keeps the same size on screen.
        .px = p.world_per_px / res,
        .light = bd.light,
        // Circle of confusion at infinity, in target pixels (~36 logical px).
        .coc_px = 36 * p.pixel_density * style.background_blur * res,
        .glow_a = bd.glow_a,
        .glow_b = bd.glow_b,
        .anchor = p.bg_anchor,
        .tan = .{ t * aspect, t },
        .bg_view = @bitCast((p.bg_view orelse p.view).m),
    };
}

/// The backdrop is soft and depends only on the camera and style, so it is
/// rendered into an image at 1/`downscale` resolution, and only when one of
/// its inputs changes: playback, hovering and idle redraws just upsample it.
const BackgroundCache = struct {
    const downscale = 2;

    image: Gpu.Image = .{},
    width: u32 = 0,
    height: u32 = 0,
    /// Inputs of the last render; null forces a re-render.
    key: ?Key = null,

    const Key = struct {
        view: [16]f32,
        width: i32,
        height: i32,
        fovy: f32,
        pixel_density: f32,
        anchor: [3]f32,
        radius: f32,
        theme: Theme,
        backdrop: BackdropKind,
        aero: bool,
        blur: f32,
    };

    fn size(full: i32) u32 {
        return @intCast(@max(@divFloor(full + downscale - 1, downscale), 1));
    }

    /// Cache height over framebuffer height.
    fn resolution(c: *const BackgroundCache, w: i32, h: i32) f32 {
        _ = c;
        _ = w;
        return @as(f32, @floatFromInt(size(h))) / @as(f32, @floatFromInt(@max(h, 1)));
    }
};

/// Re-renders the backdrop cache if its inputs changed. Outside any pass.
fn updateBackground(r: *Renderer, frame: Gpu.Frame, p: DrawParams, set: vk.DescriptorSet) !void {
    const gpu = r.gpu;
    const cache = &r.bg_cache;
    const tw = BackgroundCache.size(p.width);
    const th = BackgroundCache.size(p.height);
    if (cache.image.image == .null or tw != cache.width or th != cache.height) {
        // Frames in flight may still sample the old image.
        gpu.waitIdle();
        cache.image.deinit(gpu);
        // Half floats keep the soft gradients smooth until the dithered blit.
        cache.image = try gpu.createImage(tw, th, backdrop_format, .{ .color_attachment = true, .sampled = true }, .{ .@"1" = true }, .{ .color = true });
        cache.width = tw;
        cache.height = th;
        cache.key = null;
        for (r.sets) |s| gpu.dev.updateDescriptorSets(&.{.{
            .dst_set = s,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = &.{.{ .sampler = r.sampler, .image_view = cache.image.view, .image_layout = .shader_read_only_optimal }},
            .p_buffer_info = &.{},
            .p_texel_buffer_view = &.{},
        }}, null);
    }
    const key: BackgroundCache.Key = .{
        .view = @bitCast((p.bg_view orelse p.view).m),
        .width = p.width,
        .height = p.height,
        .fovy = p.fovy,
        .pixel_density = p.pixel_density,
        .anchor = p.bg_anchor,
        .radius = p.bg_radius,
        .theme = p.style.theme,
        .backdrop = p.style.backdrop,
        .aero = p.style.shading == .aero,
        .blur = p.style.background_blur,
    };
    if (cache.key != null and std.meta.eql(cache.key.?, key)) return;
    cache.key = key;

    const cmd = frame.cmd;
    const img = cache.image.image;
    // Earlier frames' blits read it: wait for them, discard the contents.
    gpu.barriers(cmd, &.{Gpu.imageBarrier(img, .{ .color = true }, .undefined, .color_attachment_optimal, .{ .fragment_shader = true }, .{}, .{ .color_attachment_output = true }, .{ .color_attachment_write = true })});
    const color: vk.RenderingAttachmentInfo = .{
        .image_view = cache.image.view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = .dont_care,
        .store_op = .store,
        .clear_value = undefined,
    };
    const extent: vk.Extent2D = .{ .width = tw, .height = th };
    cmd.beginRendering(&.{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color),
    });
    // Not flipped: row 0 is NDC y = -1, which is where the blit samples it
    // (v = 0) from.
    cmd.setViewport(0, &.{.{ .x = 0, .y = 0, .width = @floatFromInt(tw), .height = @floatFromInt(th), .min_depth = 0, .max_depth = 1 }});
    cmd.setScissor(0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = extent }});
    cmd.setCullMode(.{});
    cmd.setDepthWriteEnable(.false);
    cmd.bindPipeline(.graphics, r.pipes.background);
    cmd.bindDescriptorSets(.graphics, r.layout, 0, &.{set}, null);
    r.push(cmd, .{});
    cmd.draw(3, 1, 0, 0);
    cmd.endRendering();
    gpu.barriers(cmd, &.{Gpu.imageBarrier(img, .{ .color = true }, .color_attachment_optimal, .shader_read_only_optimal, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{ .fragment_shader = true }, .{ .shader_sampled_read = true })});
}

/// Flat style: every opaque atom and bond as a flat silhouette, offset down
/// and to the right, drawn first so the molecule covers its own shadow.
/// Shadows multiply what is behind them, so they read over the backdrop
/// pattern too. Every shadow fragment is written at one fixed depth with
/// LESS, so overlapping silhouettes darken a pixel only once.
///
/// `soft`: feathered silhouettes about 1.5x larger, written as darkening
/// factors with a MIN blend before the backdrop is multiplied over them.
fn drawShadows(r: *Renderer, frame: Gpu.Frame, p: DrawParams, slot: *const Slot, soft: bool) void {
    const cmd = frame.cmd;
    const px = (if (soft) @as(f32, 9) else 6) * p.pixel_density;
    const pc: Push = .{
        .shadow_offset = .{ 2 * px / @as(f32, @floatFromInt(@max(p.width, 1))), -2 * px / @as(f32, @floatFromInt(@max(p.height, 1))) },
        .shadow_pass = 1,
        .shadow_soft = @intFromBool(soft),
    };
    const up = &r.uploaded;
    if (up.atoms.items.len > 0) {
        cmd.bindPipeline(.graphics, if (soft) r.pipes.sphere_shadow_soft else r.pipes.sphere_shadow);
        cmd.bindVertexBuffers(0, &.{ r.quad.buffer, slot.atoms.buffer }, &.{ 0, 0 });
        r.push(cmd, pc);
        cmd.draw(4, @intCast(up.atoms.items.len), 0, 0);
    }
    if (up.opaque_bonds > 0) {
        cmd.bindPipeline(.graphics, if (soft) r.pipes.cylinder_shadow_soft else r.pipes.cylinder_shadow);
        cmd.bindVertexBuffers(0, &.{ r.cyl_vbo.buffer, slot.bonds.buffer }, &.{ 0, 0 });
        cmd.bindIndexBuffer(r.cyl_ibo.buffer, 0, .uint16);
        r.push(cmd, pc);
        cmd.drawIndexed(cylinder_segments * 6, @intCast(up.opaque_bonds), 0, 0, 0);
    }
}
