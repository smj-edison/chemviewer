//! Draws atoms (sphere impostors), bonds (instanced cylinders) and cell edges.
//!
//! Usage per scene change: `clear`, then `addStructure` (once per layer,
//! e.g. twice for a diff overlay) and `addCell`, then `upload`. `draw`
//! records a frame (Vulkan, see `Gpu`) without rebuilding anything.
const std = @import("std");
const cv = @import("chemviewer");
const vk = @import("vulkan");
const Gpu = @import("Gpu.zig");
const glass_layers = @import("glass_layers.zig");
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
    /// Experimental: inspired by Apple's "Liquid Glass". Translucent tinted
    /// glass atoms and bonds that refract everything behind them (other
    /// glass, the backdrop; see `GlassLayers`), with bright rims; no outlines.
    glass,

    /// Shader lighting mode (`u_cel` in shaders/common.glsl).
    pub fn lightingMode(sh: Shading) c_int {
        return switch (sh) {
            .cel => 1,
            .flat => 2,
            .aero => 3,
            .glass => 4,
        };
    }
};

pub const Style = struct {
    theme: Theme = .light,
    shading: Shading = .cel,
    /// Glass only: bonds flow into the atoms (smooth union, ray-marched in
    /// shaders/liquid.frag) instead of separate spheres and rods.
    liquid: bool = true,
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
    backdrop: BackdropKind = .space,
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
        const k: f32 = switch (s.shading) {
            .cel, .aero => 1.0,
            .flat => 1.3,
            // Bigger droplets show more of the refraction.
            .glass => 1.2,
        };
        return cv.elements.displayRadius(z) * s.atom_scale * k;
    }

    /// Liquid glass: how far the smooth union between atoms and bonds
    /// reaches (the log-sum-exp scale in shaders/liquid.frag), Å.
    pub fn liquidK(s: Style) f32 {
        return 0.6 * s.bondRadius();
    }

    /// Whether atoms and bonds are drawn as liquid glass blobs.
    pub fn isLiquid(s: Style) bool {
        return s.shading == .glass and s.liquid;
    }

    /// Liquid glass: how much a bond of this (raw) character takes part in
    /// the blobs, 0..1. It starts at 0 where the bond first appears ("Hide
    /// below") and is 1 from single-bond character on, so a forming bond
    /// grows its liquid rod and neck smoothly as it strengthens, while its
    /// faint rod fades out (see `addStructure`).
    pub fn liquidWeight(s: Style, character: f32) f32 {
        const lo = cv.color.snap(s.min_character, s.snap);
        const x = cv.color.snap(character, s.snap);
        if (lo >= 1) return @floatFromInt(@intFromBool(x >= 1));
        const t = std.math.clamp((x - lo) / (1 - lo), 0, 1);
        return t * t * (3 - 2 * t);
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
/// Liquid glass blob (shaders/liquid.vert): an atom with its bonds.
const LiquidInstance = extern struct {
    center: [3]f32,
    radius: f32,
    color: [4]f32,
    /// Bounding sphere radius (around `center`) of the blob's surface.
    bound: f32,
    highlight: f32 = 0,
    /// The atom's bonds: `links[first..][0..count]`.
    first: u32,
    count: u32,
};
/// A bond's atoms (instance indices) and how much it takes part in liquid
/// glass (`Style.liquidWeight`).
const BondLink = struct { atoms: [2]u32, weight: f32 };
/// One side of a bond, for liquid glass (`Link` in shaders/liquid.frag).
const Link = extern struct {
    other: [3]f32,
    other_radius: f32,
    bond_color: [4]f32,
    other_color: [4]f32,
    bond_radius: f32,
    /// Distance from this atom, along the bond, to the plane where the
    /// neighbour's blob takes over.
    plane: f32,
    /// How strongly the bond blends with the atoms (`Style.liquidWeight`).
    weight: f32,
    pad: f32 = 0,
};

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
/// Glass atoms sorted into layers that each see the ones behind them.
glass: GlassLayers = .{},
/// Liquid glass blobs, rebuilt from the upload when it changes.
liquid: Liquid = .{},
/// `Gpu.scene_copy` view bound at binding 2 of `sets`.
copy_view: vk.ImageView = .null,

atoms: std.ArrayList(AtomInstance) = .empty,
/// Opaque bonds first, then translucent ones (drawn without depth writes).
bonds: std.ArrayList(BondInstance) = .empty,
translucent: std.ArrayList(BondInstance) = .empty,
/// Liquid glass: each bond's atoms and weight (parallel to `bonds` and
/// `translucent`).
bond_links: std.ArrayList(BondLink) = .empty,
translucent_links: std.ArrayList(BondLink) = .empty,
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
    r.bond_links.clearRetainingCapacity();
    r.translucent_links.clearRetainingCapacity();
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
        // Liquid glass: cut bonds stay out of the blobs.
        const is_cut = if (cut) |set| set.contains(key) else false;
        const link: BondLink = .{
            .atoms = .{ @intCast(start + b.a), @intCast(start + b.b) },
            .weight = if (is_cut) 0 else style.liquidWeight(b.character),
        };
        var inst: BondInstance = .{
            .a = positions[b.a],
            .b = positions[b.b],
            .radius = style.bondRadius() * radius_scale,
            .outline = outline,
            .color_a = ca,
            .color_b = cb,
        };
        if (ca[3] < 0.99) {
            // Liquid glass: the faint rod hands over to the blobs' liquid
            // one as the bond strengthens.
            if (style.isLiquid()) {
                inst.color_a[3] *= 1 - link.weight;
                inst.color_b[3] *= 1 - link.weight;
            }
            try r.translucent.append(r.gpa, inst);
            try r.translucent_links.append(r.gpa, link);
        } else {
            try r.bonds.append(r.gpa, inst);
            try r.bond_links.append(r.gpa, link);
        }
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
    up.bond_links.clearRetainingCapacity();
    try up.bond_links.appendSlice(r.gpa, r.bond_links.items);
    try up.bond_links.appendSlice(r.gpa, r.translucent_links.items);
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
    /// Glass refracts the scene copy (binding 2) instead of the backdrop.
    glass_scene: i32 = 0,
    /// Liquid glass: world units per pixel at unit depth, smooth-union scale.
    px_k: f32 = 0,
    liquid_k: f32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(FrameUniforms) == 400);
    std.debug.assert(@offsetOf(FrameUniforms, "bg") == 208);
}

const Pipelines = struct {
    sphere: vk.Pipeline,
    liquid: vk.Pipeline,
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
    /// Glass atoms and bonds in layer order (`GlassLayers`), and
    /// their stamp.
    glass_atoms: Gpu.Buffer = .{},
    glass_bonds: Gpu.Buffer = .{},
    glass_stamp: u64 = 0,
    /// Liquid blobs in layer order (stamped with `glass_stamp`), and the
    /// links they index (binding 3 of this slot's set).
    liquid: Gpu.Buffer = .{},
    links: Gpu.Buffer = .{},
    links_generation: u64 = 0,
    /// `links.buffer` as written to the descriptor set.
    links_bound: vk.Buffer = .null,

    fn deinit(s: *Slot, gpu: *const Gpu) void {
        s.uniforms.deinit(gpu);
        s.glass_atoms.deinit(gpu);
        s.glass_bonds.deinit(gpu);
        s.liquid.deinit(gpu);
        s.links.deinit(gpu);
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
    /// Liquid glass links of `bonds` (same order).
    bond_links: std.ArrayList(BondLink) = .empty,
    lines: std.ArrayList(LineVertex) = .empty,

    fn deinit(u: *Uploaded, gpa: Allocator) void {
        u.atoms.deinit(gpa);
        u.bond_links.deinit(gpa);
        u.bonds.deinit(gpa);
        u.lines.deinit(gpa);
    }
};

pub fn init(gpa: Allocator, gpu: *Gpu) !Renderer {
    const dev = gpu.dev;
    const set_layout = try dev.createDescriptorSetLayout(&.{
        .binding_count = 4,
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
            // The scene so far (`Gpu.scene_copy`), for glass atoms.
            .{
                .binding = 2,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 1,
                .stage_flags = .{ .fragment = true },
            },
            // Liquid glass links (per frame slot).
            .{
                .binding = 3,
                .descriptor_type = .storage_buffer,
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
        .pool_size_count = 3,
        .p_pool_sizes = &.{
            .{ .type = .uniform_buffer, .descriptor_count = n },
            .{ .type = .combined_image_sampler, .descriptor_count = 2 * n },
            .{ .type = .storage_buffer, .descriptor_count = n },
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
    r.glass.deinit(r.gpa);
    r.liquid.deinit(r.gpa);
    r.bond_links.deinit(r.gpa);
    r.translucent_links.deinit(r.gpa);
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
        .liquid_vs = try gpu.createShaderModule("liquid.vert.spv"),
        .liquid_fs = try gpu.createShaderModule("liquid.frag.spv"),
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
    const liquid_bindings = [_]vk.VertexInputBindingDescription{
        .{ .binding = 0, .stride = 8, .input_rate = .vertex },
        .{ .binding = 1, .stride = @sizeOf(LiquidInstance), .input_rate = .instance },
    };
    const liquid_attrs = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = 0 },
        .{ .location = 1, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(LiquidInstance, "center") },
        .{ .location = 2, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(LiquidInstance, "color") },
        .{ .location = 3, .binding = 1, .format = .r32g32_sfloat, .offset = @offsetOf(LiquidInstance, "bound") },
        .{ .location = 4, .binding = 1, .format = .r32g32_uint, .offset = @offsetOf(LiquidInstance, "first") },
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
        .liquid = try createPipeline(gpu, layout, .{
            .vert = mods.liquid_vs,
            .frag = mods.liquid_fs,
            .bindings = &liquid_bindings,
            .attributes = &liquid_attrs,
            .topology = .triangle_strip,
            .alpha_to_coverage = true,
        }),
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
    return r.fillAs(buf, bytes, .{ .vertex_buffer = true });
}

fn fillAs(r: *Renderer, buf: *Gpu.Buffer, bytes: []const u8, usage: vk.BufferUsageFlags) !void {
    if (buf.buffer == .null or buf.size < bytes.len) {
        buf.deinit(r.gpu);
        const size = @max(bytes.len + bytes.len / 2, 4096);
        buf.* = try r.gpu.createBuffer(size, usage, .{ .host_visible = true, .host_coherent = true });
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
    const glass = p.style.shading == .glass;
    const liquid = glass and p.style.liquid;
    if (liquid) try r.buildLiquid(p.style);
    if (glass) {
        try r.layerGlass(p, liquid);
        // Before the set is bound: it may update the slot's binding 3.
        try r.syncGlass(slot, frame.slot);
    }
    r.bindSceneCopy(frame);
    const res = r.bg_cache.resolution(p.width, p.height);
    const u = frameUniforms(p, res);
    slot.uniforms.write(0, std.mem.asBytes(&u));
    const set = r.sets[frame.slot];

    if (r.profile) |*prof| {
        prof.collect(gpu, frame.slot);
        cmd.resetQueryPool(prof.pool, @intCast(frame.slot * Profile.per_slot), Profile.per_slot);
        prof.stamp(frame, 0);
    }
    // Always kept, even without the pattern (it then holds the plain
    // background): glass refracts it, and the atom and bond shaders bind it
    // in every style.
    try r.updateBackground(frame, p, set);

    // Flat "soft shadow": the pass clears to white, the feathered shadow
    // factors go down first (MIN keeps the darkest, so overlaps darken once),
    // and the backdrop (or plain background) is multiplied over them.
    const soft = p.style.shading == .flat and p.style.flat_pop;
    gpu.beginScenePass(frame, if (soft) .{ 1, 1, 1 } else p.style.theme.background(), glass);
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

    // Glass atoms and bonds come last, after everything they can be seen
    // through (`drawGlass`).
    if (n_atoms > 0 and !glass) {
        cmd.bindPipeline(.graphics, r.pipes.sphere);
        cmd.bindVertexBuffers(0, &.{ r.quad.buffer, slot.atoms.buffer }, &.{ 0, 0 });
        r.push(cmd, .{ .outline_k = outline_k });
        cmd.draw(4, n_atoms, 0, 0);
    }
    if (n_opaque + n_translucent > 0) {
        cmd.bindVertexBuffers(0, &.{ r.cyl_vbo.buffer, slot.bonds.buffer }, &.{ 0, 0 });
        cmd.bindIndexBuffer(r.cyl_ibo.buffer, 0, .uint16);
    }
    if (n_opaque > 0 and !glass) {
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
    if (glass and n_atoms + n_opaque > 0) r.drawGlass(frame, p, slot, liquid);
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
        // Backdrop motif; aero has its own sky (2 = day, 3 = night). With
        // the pattern off the cache holds the plain background (4), which
        // only glass sees.
        .mode = if (!style.background_pattern) 4 else if (style.shading == .aero) (if (style.theme == .dark) 3 else 2) else @backingInt(style.backdrop),
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
        pattern: bool,
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

/// Points binding 2 at the current `Gpu.scene_copy` (recreated with the
/// swapchain, after a device wait) and gives a fresh one a valid layout.
/// Outside any pass.
fn bindSceneCopy(r: *Renderer, frame: Gpu.Frame) void {
    const gpu = r.gpu;
    if (gpu.scene_copy_fresh) {
        gpu.barriers(frame.cmd, &.{Gpu.imageBarrier(gpu.scene_copy.image, .{ .color = true }, .undefined, .shader_read_only_optimal, .{}, .{}, .{ .fragment_shader = true }, .{ .shader_sampled_read = true })});
        gpu.scene_copy_fresh = false;
    }
    if (r.copy_view == gpu.scene_copy.view) return;
    r.copy_view = gpu.scene_copy.view;
    for (r.sets) |s| gpu.dev.updateDescriptorSets(&.{.{
        .dst_set = s,
        .dst_binding = 2,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = &.{.{ .sampler = r.sampler, .image_view = r.copy_view, .image_layout = .shader_read_only_optimal }},
        .p_buffer_info = &.{},
        .p_texel_buffer_view = &.{},
    }}, null);
}

/// Glass, translucent: atoms and bonds refract whatever is behind them,
/// other glass included. The scene can only be sampled from a copy, so they
/// are drawn in layers with a snapshot before each (see glass_layers.zig).
/// A bond sorts by its midpoint, so it usually lands between its two atoms.
/// (Splitting bonds into halves sorts them more finely, but the second half
/// then refracts the first one's open end: a dark notch at the midpoint.)
/// Layers are capped (`max_layers`): beyond that, overlapping objects share
/// the last one and the nearer hides the farther.
const GlassLayers = struct {
    const max_layers = 24;
    /// Above this many objects (atoms plus bonds): two layers, bonds
    /// then atoms, so atoms still show the bonds through them.
    const max_items = 40000;

    /// Instances grouped by layer, farthest layer first. Liquid glass uses
    /// `liquid` (blobs) in place of `atoms` and has no separate bonds.
    atoms: std.ArrayList(AtomInstance) = .empty,
    bonds: std.ArrayList(BondInstance) = .empty,
    liquid: std.ArrayList(LiquidInstance) = .empty,
    /// End (exclusive) of each layer in `atoms` (or `liquid`) and `bonds`.
    atom_ends: [max_layers]u32 = undefined,
    bond_ends: [max_layers]u32 = undefined,
    /// Framebuffer area each layer's glass covers, plus how far its
    /// refraction reaches: only this much of the scene is copied for it.
    rects: [max_layers]vk.Rect2D = undefined,
    count: u32 = 0,
    /// Inputs of the last layering; null forces a new one.
    key: ?Key = null,
    /// Bumped when the instances change (frame slots compare it).
    stamp: u64 = 0,
    // Scratch.
    items: std.ArrayList(glass_layers.Item) = .empty,
    scratch: glass_layers.Scratch = .{},

    const Key = struct { view: [16]f32, width: i32, height: i32, fovy: f32, generation: u64, liquid: bool };

    fn deinit(g: *GlassLayers, gpa: Allocator) void {
        g.atoms.deinit(gpa);
        g.liquid.deinit(gpa);
        g.bonds.deinit(gpa);
        g.items.deinit(gpa);
        g.scratch.deinit(gpa);
    }
};

/// Re-sorts the glass atoms and bonds into layers if the view or the scene
/// changed.
/// With `liquid`, the objects are the liquid blobs (`r.liquid`, built
/// first), one per atom with its bonds.
fn layerGlass(r: *Renderer, p: DrawParams, liquid: bool) !void {
    const G = GlassLayers;
    const g = &r.glass;
    const key: G.Key = .{ .view = @bitCast(p.view.m), .width = p.width, .height = p.height, .fovy = p.fovy, .generation = r.generation, .liquid = liquid };
    if (g.key != null and std.meta.eql(g.key.?, key)) return;
    g.key = null;
    const gpa = r.gpa;
    const atoms = r.uploaded.atoms.items;
    const blobs = r.liquid.blobs.items;
    const bonds = if (liquid) &.{} else r.uploaded.bonds.items[0..r.uploaded.opaque_bonds];
    // Atoms or blobs: one per atom either way.
    const n_atoms = atoms.len;
    try g.atoms.resize(gpa, if (liquid) 0 else n_atoms);
    try g.liquid.resize(gpa, if (liquid) n_atoms else 0);
    try g.bonds.resize(gpa, bonds.len);
    g.stamp += 1;
    if (n_atoms + bonds.len > G.max_items) {
        if (liquid) @memcpy(g.liquid.items, blobs) else @memcpy(g.atoms.items, atoms);
        @memcpy(g.bonds.items, bonds);
        g.bond_ends[0] = @intCast(bonds.len);
        g.bond_ends[1] = @intCast(bonds.len);
        g.atom_ends[0] = 0;
        g.atom_ends[1] = @intCast(n_atoms);
        g.count = 2;
        const full: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = @intCast(@max(p.width, 1)), .height = @intCast(@max(p.height, 1)) } };
        g.rects[0] = full;
        g.rects[1] = full;
        g.key = key;
        return;
    }

    // Screen positions in pixels from the centre.
    const f = @as(f32, @floatFromInt(@max(p.height, 1))) / (2 * @tan(p.fovy / 2));
    const Proj = struct { xy: @Vector(2, f32), z: f32 };
    const project = struct {
        fn at(view: Mat4, pt: Vec3, scale: f32) Proj {
            const c = view.transformPoint(pt);
            const z = @max(-c[2], 1e-3);
            return .{ .xy = .{ c[0] / z * scale, c[1] / z * scale }, .z = z };
        }
    }.at;
    try g.items.resize(gpa, n_atoms + bonds.len);
    for (atoms, g.items.items[0..n_atoms], 0..) |at, *it, i| {
        const q = project(p.view, at.center, f);
        // A blob reaches out along its bonds; its depth is still the atom's.
        const rad = if (liquid) blobs[i].bound else at.radius;
        // Margin for the anti-aliased edge and the selection ring.
        it.* = .{ .a = q.xy, .b = q.xy, .r = rad / q.z * f + 4, .z = q.z, .index = @intCast(i), .bond = false };
    }
    for (bonds, g.items.items[n_atoms..], 0..) |h, *it, i| {
        // Sorted by its midpoint.
        const qa = project(p.view, h.a, f);
        const qb = project(p.view, h.b, f);
        it.* = .{ .a = qa.xy, .b = qb.xy, .r = h.radius / @min(qa.z, qb.z) * f + 2, .z = 0.5 * (qa.z + qb.z), .index = @intCast(i), .bond = true };
    }
    std.mem.sort(glass_layers.Item, g.items.items, {}, glass_layers.farther);
    const half_w = 0.5 * @as(f32, @floatFromInt(@max(p.width, 1)));
    const half_h = 0.5 * @as(f32, @floatFromInt(@max(p.height, 1)));
    try glass_layers.assign(gpa, &g.scratch, g.items.items, half_w, half_h, G.max_layers);

    // Counting sort by layer, atoms and bonds separately.
    var na: [G.max_layers]u32 = @splat(0);
    var nb: [G.max_layers]u32 = @splat(0);
    for (g.items.items) |it| {
        if (it.bond) nb[it.layer] += 1 else na[it.layer] += 1;
    }
    var sa: [G.max_layers]u32 = undefined;
    var sb: [G.max_layers]u32 = undefined;
    var ta: u32 = 0;
    var tb: u32 = 0;
    g.count = 0;
    for (0..G.max_layers) |l| {
        sa[l] = ta;
        sb[l] = tb;
        ta += na[l];
        tb += nb[l];
        g.atom_ends[l] = ta;
        g.bond_ends[l] = tb;
        if (na[l] + nb[l] > 0) g.count = @intCast(l + 1);
    }
    // Each layer's screen area: its items, widened by how far refraction
    // can shift what they show (up to about the reach in glass.glsl,
    // 2 * thickness + 0.4 Å, times the deflection at the rim).
    var lo: [G.max_layers]@Vector(2, f32) = @splat(@splat(std.math.inf(f32)));
    var hi: [G.max_layers]@Vector(2, f32) = @splat(@splat(-std.math.inf(f32)));
    for (g.items.items) |it| {
        const m: @Vector(2, f32) = @splat(3 * it.r + 0.6 * f / it.z + 8);
        lo[it.layer] = @min(lo[it.layer], @min(it.a, it.b) - m);
        hi[it.layer] = @max(hi[it.layer], @max(it.a, it.b) + m);
    }
    for (0..g.count) |l| {
        // Centred, y up to framebuffer pixels, y down.
        const x0 = std.math.clamp(lo[l][0] + half_w, 0, 2 * half_w);
        const x1 = std.math.clamp(hi[l][0] + half_w, 0, 2 * half_w);
        const y0 = std.math.clamp(half_h - hi[l][1], 0, 2 * half_h);
        const y1 = std.math.clamp(half_h - lo[l][1], 0, 2 * half_h);
        const ix: i32 = @intFromFloat(@floor(x0));
        const iy: i32 = @intFromFloat(@floor(y0));
        g.rects[l] = .{
            .offset = .{ .x = ix, .y = iy },
            .extent = .{
                .width = @intCast(@max(@as(i32, @intFromFloat(@ceil(x1))) - ix, 0)),
                .height = @intCast(@max(@as(i32, @intFromFloat(@ceil(y1))) - iy, 0)),
            },
        };
    }
    for (g.items.items) |it| {
        if (it.bond) {
            g.bonds.items[sb[it.layer]] = bonds[it.index];
            sb[it.layer] += 1;
        } else {
            if (liquid) g.liquid.items[sa[it.layer]] = blobs[it.index] else g.atoms.items[sa[it.layer]] = atoms[it.index];
            sa[it.layer] += 1;
        }
    }
    g.key = key;
}

fn clampRect(rc: vk.Rect2D, extent: vk.Extent2D) vk.Rect2D {
    const x: u32 = @min(@as(u32, @intCast(rc.offset.x)), extent.width);
    const y: u32 = @min(@as(u32, @intCast(rc.offset.y)), extent.height);
    return .{
        .offset = .{ .x = @intCast(x), .y = @intCast(y) },
        .extent = .{ .width = @min(rc.extent.width, extent.width - x), .height = @min(rc.extent.height, extent.height - y) },
    };
}

/// Copies the glass instances into this frame slot's buffers if they are
/// stale, and points the slot's binding 3 at its liquid links. Before the
/// slot's descriptor set is bound (it may update it).
fn syncGlass(r: *Renderer, slot: *Slot, slot_index: usize) !void {
    const g = &r.glass;
    if (slot.glass_stamp != g.stamp) {
        try r.fill(&slot.glass_atoms, std.mem.sliceAsBytes(g.atoms.items));
        try r.fill(&slot.glass_bonds, std.mem.sliceAsBytes(g.bonds.items));
        try r.fill(&slot.liquid, std.mem.sliceAsBytes(g.liquid.items));
        slot.glass_stamp = g.stamp;
    }
    if (slot.links.buffer == .null or slot.links_generation != r.liquid.generation) {
        try r.fillAs(&slot.links, std.mem.sliceAsBytes(r.liquid.links.items), .{ .storage_buffer = true });
        slot.links_generation = r.liquid.generation;
    }
    if (slot.links_bound != slot.links.buffer) {
        slot.links_bound = slot.links.buffer;
        r.gpu.dev.updateDescriptorSets(&.{.{
            .dst_set = r.sets[slot_index],
            .dst_binding = 3,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = &.{},
            .p_buffer_info = &.{.{ .buffer = slot.links.buffer, .offset = 0, .range = vk.WHOLE_SIZE }},
            .p_texel_buffer_view = &.{},
        }}, null);
    }
}

/// Draws the glass layers (see `GlassLayers`), snapshotting the scene
/// before each. Inside the scene pass.
fn drawGlass(r: *Renderer, frame: Gpu.Frame, p: DrawParams, slot: *Slot, liquid: bool) void {
    const g = &r.glass;
    const cmd = frame.cmd;
    // Push constants and bound state carry over between render pass instances.
    r.push(cmd, .{ .glass_scene = 1, .px_k = p.world_per_px, .liquid_k = p.style.liquidK() });
    var a0: u32 = 0;
    var b0: u32 = 0;
    for (g.atom_ends[0..g.count], g.bond_ends[0..g.count], g.rects[0..g.count]) |a1, b1, rect| {
        defer {
            a0 = a1;
            b0 = b1;
        }
        if (a1 == a0 and b1 == b0) continue;
        // The resize check in `layerGlass` keys on the size, but the
        // framebuffer can still lag the window by a frame.
        const area = clampRect(rect, frame.extent);
        // Entirely off screen: nothing it shows is seen.
        if (area.extent.width > 0 and area.extent.height > 0) r.gpu.snapshotScene(frame, area);
        if (a1 > a0) {
            cmd.bindPipeline(.graphics, if (liquid) r.pipes.liquid else r.pipes.sphere);
            cmd.bindVertexBuffers(0, &.{ r.quad.buffer, if (liquid) slot.liquid.buffer else slot.glass_atoms.buffer }, &.{ 0, 0 });
            cmd.draw(4, a1 - a0, 0, a0);
        }
        if (b1 > b0) {
            // Solid glass rods: back faces would show the inside of the tube
            // through its open ends.
            cmd.bindPipeline(.graphics, r.pipes.cylinder);
            cmd.bindVertexBuffers(0, &.{ r.cyl_vbo.buffer, slot.glass_bonds.buffer }, &.{ 0, 0 });
            cmd.bindIndexBuffer(r.cyl_ibo.buffer, 0, .uint16);
            cmd.setCullMode(.{ .back = true });
            cmd.drawIndexed(cylinder_segments * 6, b1 - b0, 0, 0, b0);
            cmd.setCullMode(.{});
        }
    }
}

/// Liquid glass: one blob per atom (its sphere, bonds and neighbours,
/// smoothly joined; shaders/liquid.frag) and, per atom, its links (one per
/// bond, `Link`). Depends only on the upload and the blend scale.
const Liquid = struct {
    blobs: std.ArrayList(LiquidInstance) = .empty,
    links: std.ArrayList(Link) = .empty,
    /// `Renderer.generation` and blend scale it was built for; bumped
    /// `generation` tells frame slots to copy the links again.
    built: ?struct { generation: u64, k: f32 } = null,
    generation: u64 = 0,
    // Scratch.
    counts: std.ArrayList(u32) = .empty,

    fn deinit(l: *Liquid, gpa: Allocator) void {
        l.blobs.deinit(gpa);
        l.links.deinit(gpa);
        l.counts.deinit(gpa);
    }
};

fn buildLiquid(r: *Renderer, style: Style) !void {
    const l = &r.liquid;
    const k = style.liquidK();
    if (l.built) |b| if (b.generation == r.generation and b.k == k) return;
    const gpa = r.gpa;
    const atoms = r.uploaded.atoms.items;
    // Opaque and faint bonds alike: faint ones fade in (`liquidWeight`).
    const bonds = r.uploaded.bonds.items;
    const bond_links = r.uploaded.bond_links.items;
    const min_weight = 1e-3;

    try l.counts.resize(gpa, atoms.len);
    @memset(l.counts.items, 0);
    for (bond_links) |bl| {
        if (bl.weight < min_weight) continue;
        l.counts.items[bl.atoms[0]] += 1;
        l.counts.items[bl.atoms[1]] += 1;
    }
    try l.blobs.resize(gpa, atoms.len);
    var first: u32 = 0;
    for (atoms, l.blobs.items, l.counts.items) |a, *blob, n| {
        blob.* = .{ .center = a.center, .radius = a.radius, .color = a.color, .bound = a.radius, .highlight = a.highlight, .first = first, .count = 0 };
        first += n;
    }
    try l.links.resize(gpa, first);
    // How far the blend reaches beyond a primitive: exp(-4) of a neighbour's
    // weight is about 2% of k in distance.
    const reach = 4 * k;
    for (bonds, bond_links) |bd, bl| {
        if (bl.weight < min_weight) continue;
        // The liquid rod grows in with the weight.
        const rod = bd.radius * bl.weight;
        for (0..2) |side| {
            const i = bl.atoms[side];
            const j = bl.atoms[1 - side];
            const a = atoms[i];
            const o = atoms[j];
            const len = math.length(@as(Vec3, o.center) - @as(Vec3, a.center));
            // Across the middle of the gap between the two spheres.
            const plane = std.math.clamp(0.5 * (len + a.radius - o.radius), 0.15 * len, 0.85 * len);
            const blob = &l.blobs.items[i];
            l.links.items[blob.first + blob.count] = .{
                .other = o.center,
                .other_radius = o.radius,
                .bond_color = if (side == 0) bd.color_a else bd.color_b,
                .other_color = o.color,
                .bond_radius = rod,
                .plane = plane,
                .weight = bl.weight,
            };
            blob.count += 1;
            // Bound: up to the plane, as wide as the rod or, if it reaches
            // past the plane, the neighbour's sphere.
            var lateral = rod + reach;
            const rest = len - plane;
            const ro = o.radius + reach;
            if (rest < ro) lateral = @max(lateral, @sqrt(ro * ro - rest * rest));
            blob.bound = @max(blob.bound, @sqrt(plane * plane + lateral * lateral));
        }
    }
    for (l.blobs.items) |*blob| blob.bound = @max(blob.bound, blob.radius + reach);
    l.built = .{ .generation = r.generation, .k = k };
    l.generation += 1;
}

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
        .pattern = p.style.background_pattern,
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
