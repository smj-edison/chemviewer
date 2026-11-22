//! Periodic table data used for display and bond detection.
//!
//! Covalent radii (pm) are Pyykkö's additive radii for single (2009),
//! double (2009) and triple (2005) bonds; 0 means "no value" (that bond order
//! is not considered for the element). See docs/BONDS.md.
//! TODO: verify the d/f-block and triple-bond entries against the original
//! papers; they were transcribed without the tables at hand.
const std = @import("std");
const colour = @import("color.zig");

pub const max_z = 118;

pub const Element = struct {
    symbol: []const u8,
    /// Pyykkö covalent radii in pm for bond orders 1, 2, 3 (0 = unavailable).
    r: [3]u16,
    /// Jmol-style display colour, 0xRRGGBB.
    color: u24,
};

const symbols = [_][]const u8{
    "X",  "H",  "He", "Li", "Be", "B",  "C",  "N",  "O",  "F",  "Ne", "Na", "Mg", "Al", "Si", "P",  "S",
    "Cl", "Ar", "K",  "Ca", "Sc", "Ti", "V",  "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Ga", "Ge", "As",
    "Se", "Br", "Kr", "Rb", "Sr", "Y",  "Zr", "Nb", "Mo", "Tc", "Ru", "Rh", "Pd", "Ag", "Cd", "In", "Sn",
    "Sb", "Te", "I",  "Xe", "Cs", "Ba", "La", "Ce", "Pr", "Nd", "Pm", "Sm", "Eu", "Gd", "Tb", "Dy", "Ho",
    "Er", "Tm", "Yb", "Lu", "Hf", "Ta", "W",  "Re", "Os", "Ir", "Pt", "Au", "Hg", "Tl", "Pb", "Bi", "Po",
    "At", "Rn", "Fr", "Ra", "Ac", "Th", "Pa", "U",  "Np", "Pu", "Am", "Cm", "Bk", "Cf", "Es", "Fm", "Md",
    "No", "Lr", "Rf", "Db", "Sg", "Bh", "Hs", "Mt", "Ds", "Rg", "Cn", "Nh", "Fl", "Mc", "Lv", "Ts", "Og",
};

comptime {
    std.debug.assert(symbols.len == max_z + 1);
}

/// (single, double, triple) in pm, indexed by Z. Elements past the end of this
/// table fall back to a generic 150 pm single radius.
const radii = [_][3]u16{
    .{ 0, 0, 0 }, // X (dummy)
    .{ 32, 0, 0 }, .{ 46, 0, 0 }, .{ 133, 124, 0 }, .{ 102, 90, 85 }, .{ 85, 78, 73 }, // H He Li Be B
    .{ 75, 67, 60 }, .{ 71, 60, 54 }, .{ 63, 57, 53 }, .{ 64, 59, 53 }, .{ 67, 96, 0 }, // C N O F Ne
    .{ 155, 160, 0 }, .{ 139, 132, 127 }, .{ 126, 113, 111 }, .{ 116, 107, 102 }, .{ 111, 102, 94 }, // Na Mg Al Si P
    .{ 103, 94, 95 }, .{ 99, 95, 93 }, .{ 96, 107, 96 }, .{ 196, 193, 0 }, .{ 171, 147, 133 }, // S Cl Ar K Ca
    .{ 148, 116, 114 }, .{ 136, 117, 108 }, .{ 134, 112, 106 }, .{ 122, 111, 103 }, .{ 119, 105, 103 }, // Sc Ti V Cr Mn
    .{ 116, 109, 102 }, .{ 111, 103, 96 }, .{ 110, 101, 101 }, .{ 112, 115, 120 }, .{ 118, 120, 0 }, // Fe Co Ni Cu Zn
    .{ 124, 117, 121 }, .{ 121, 111, 114 }, .{ 121, 114, 106 }, .{ 116, 107, 107 }, .{ 114, 109, 110 }, // Ga Ge As Se Br
    .{ 117, 121, 108 }, .{ 210, 202, 0 }, .{ 185, 157, 139 }, .{ 163, 130, 124 }, .{ 154, 127, 121 }, // Kr Rb Sr Y Zr
    .{ 147, 125, 116 }, .{ 138, 121, 113 }, .{ 128, 120, 110 }, .{ 125, 114, 103 }, .{ 125, 110, 106 }, // Nb Mo Tc Ru Rh
    .{ 120, 117, 112 }, .{ 128, 139, 137 }, .{ 136, 144, 0 }, .{ 142, 136, 146 }, .{ 140, 130, 132 }, // Pd Ag Cd In Sn
    .{ 140, 133, 127 }, .{ 136, 128, 121 }, .{ 133, 129, 125 }, .{ 131, 135, 122 }, .{ 232, 209, 0 }, // Sb Te I Xe Cs
    .{ 196, 161, 149 }, .{ 180, 139, 139 }, .{ 163, 137, 131 }, .{ 176, 138, 128 }, .{ 174, 137, 0 }, // Ba La Ce Pr Nd
    .{ 173, 135, 0 }, .{ 172, 134, 0 }, .{ 168, 134, 0 }, .{ 169, 135, 132 }, .{ 168, 135, 0 }, // Pm Sm Eu Gd Tb
    .{ 167, 133, 0 }, .{ 166, 133, 0 }, .{ 165, 133, 0 }, .{ 164, 131, 0 }, .{ 170, 129, 0 }, // Dy Ho Er Tm Yb
    .{ 162, 131, 131 }, .{ 152, 128, 122 }, .{ 146, 126, 119 }, .{ 137, 120, 115 }, .{ 131, 119, 110 }, // Lu Hf Ta W Re
    .{ 129, 116, 109 }, .{ 122, 115, 107 }, .{ 123, 112, 110 }, .{ 124, 121, 123 }, .{ 133, 142, 0 }, // Os Ir Pt Au Hg
    .{ 144, 142, 150 }, .{ 144, 135, 137 }, .{ 151, 141, 135 }, .{ 145, 135, 129 }, .{ 147, 138, 138 }, // Tl Pb Bi Po At
    .{ 142, 145, 133 }, .{ 223, 218, 0 }, .{ 201, 173, 159 }, .{ 186, 153, 140 }, .{ 175, 143, 136 }, // Rn Fr Ra Ac Th
    .{ 169, 138, 129 }, .{ 170, 134, 118 }, .{ 171, 136, 116 }, .{ 172, 135, 0 }, .{ 166, 135, 0 }, // Pa U Np Pu Am
    .{ 166, 136, 0 }, // Cm
};

const colors = [_]u24{
    0xFF1493, // X
    0xFFFFFF, 0xD9FFFF, 0xCC80FF, 0xC2FF00, 0xFFB5B5, 0x909090, 0x3050F8, 0xFF0D0D, 0x90E050, 0xB3E3F5, // H..Ne
    0xAB5CF2, 0x8AFF00, 0xBFA6A6, 0xF0C8A0, 0xFF8000, 0xFFFF30, 0x1FF01F, 0x80D1E3, // Na..Ar
    0x8F40D4, 0x3DFF00, 0xE6E6E6, 0xBFC2C7, 0xA6A6AB, 0x8A99C7, 0x9C7AC7, 0xE06633, 0xF090A0, 0x50D050, // K..Ni
    0xC88033, 0x7D80B0, 0xC28F8F, 0x668F8F, 0xBD80E3, 0xFFA100, 0xA62929, 0x5CB8D1, // Cu..Kr
    0x702EB0, 0x00FF00, 0x94FFFF, 0x94E0E0, 0x73C2C9, 0x54B5B5, 0x3B9E9E, 0x248F8F, 0x0A7D8C, 0x006985, // Rb..Pd
    0xC0C0C0, 0xFFD98F, 0xA67573, 0x668080, 0x9E63B5, 0xD47A00, 0x940094, 0x429EB0, // Ag..Xe
    0x57178F, 0x00C900, 0x70D4FF, 0xFFFFC7, 0xD9FFC7, 0xC7FFC7, 0xA3FFC7, 0x8FFFC7, 0x61FFC7, 0x45FFC7, // Cs..Gd
    0x30FFC7, 0x1FFFC7, 0x00FF9C, 0x00E675, 0x00D452, 0x00BF38, 0x00AB24, 0x4DC2FF, 0x4DA6FF, 0x2194D6, // Tb..W
    0x267DAB, 0x266696, 0x175487, 0xD0D0E0, 0xFFD123, 0xB8B8D0, 0xA6544D, 0x575961, 0x9E4FB5, 0xAB5C00, // Re..Po
    0x754F45, 0x428296, 0x420066, 0x007D00, 0x70ABFA, 0x00BAFF, 0x00A1FF, 0x008FFF, 0x0080FF, 0x006BFF, // At..Pu
    0x545CF2, 0x785CE3, // Am Cm
};

const default_color: u24 = 0xEB00FF;

pub fn symbol(z: u8) []const u8 {
    return if (z <= max_z) symbols[z] else "?";
}

/// Jmol/CPK colour (0xRRGGBB). The viewer draws `displayColor` instead;
/// this is the reference table it falls back on.
pub fn color(z: u8) u24 {
    return if (z < colors.len) colors[z] else default_color;
}

pub fn colorRgb(z: u8) [3]f32 {
    const c = color(z);
    return .{
        @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(c & 0xFF)) / 255.0,
    };
}

// ------------------------------------------------------- display colours

/// Hand-picked colours: the elements chemists know by colour, plus metals
/// common in catalysis that have a recognisable metal colour. Lightness is
/// spread so bonded pairs stay apart under simulated colour-vision
/// deficiencies (see `colour.worstCaseDistance`).
fn namedColor(z: u8) ?u24 {
    return switch (z) {
        1 => 0xFFFFFF, // H
        5 => 0xFF9A7A, // B: salmon
        6 => 0x009092, // C: teal, OKLCh L 0.59
        7 => 0x373EC1, // N: blue, L 0.45
        8 => 0xC21A15, // O: red, L 0.52
        9 => 0x75BD45, // F: green, L 0.73
        14 => 0xC58A5A, // Si: clay
        15 => 0xED6019, // P: orange, L 0.66
        16 => 0xD0CE27, // S: yellow, L 0.83
        17 => 0x4DCD73, // Cl: green, L 0.76
        29 => 0xB06A3B, // Cu: copper
        35 => 0x9B3351, // Br: wine, L 0.48
        47 => 0xBFC3CC, // Ag: silver
        53 => 0x9A5BD6, // I: violet, L 0.58; lighter than N so they part under red-green CVD
        78 => 0xD6D3CB, // Pt: platinum
        79 => 0xDB9F00, // Au: gold, L 0.74
        else => null,
    };
}

fn hexRgb(h: u24) [3]f32 {
    return .{
        @as(f32, @floatFromInt((h >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((h >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(h & 0xFF)) / 255.0,
    };
}

/// Period (1..7) of an element.
fn period(z: u8) u8 {
    const starts = [_]u8{ 1, 3, 11, 19, 37, 55, 87 };
    var p: u8 = 0;
    for (starts) |s| {
        if (z >= s) p += 1;
    }
    return @max(p, 1);
}

/// Display colour (sRGB) used in every theme and style.
///
/// Named elements have their own colour. Everything else gets a muted
/// colour for its family, following GaussView/Jmol's family hues (violet
/// alkali metals, olive alkaline earths, grey-blue transition metals by
/// period, pale sage lanthanides, mauve actinides), so the family is
/// recognisable but no rare element can pass for C, N or O. Elements that
/// share a family colour are told apart by labels where it matters (see
/// `ambiguousElements`).
pub fn displayColor(z: u8) [3]f32 {
    if (namedColor(z)) |h| return hexRgb(h);
    const Lch = colour.Lch;
    const p: f32 = @floatFromInt(period(z));
    const lch: Lch = switch (z) {
        2, 10, 18, 36, 54, 86, 118 => .{ .l = 0.86, .c = 0.035, .h = 200 }, // noble gases
        3, 11, 19, 37, 55, 87 => .{ .l = 0.84 - 0.06 * p, .c = 0.10, .h = 305 }, // alkali
        4, 12, 20, 38, 56, 88 => .{ .l = 0.86 - 0.06 * p, .c = 0.08, .h = 105 }, // alkaline earth
        21...28, 30 => .{ .l = 0.70, .c = 0.020, .h = 250 }, // 3d metals
        39...46, 48 => .{ .l = 0.71, .c = 0.040, .h = 285 }, // 4d metals
        72...77 => .{ .l = 0.54, .c = 0.070, .h = 265 }, // 5d metals
        80 => .{ .l = 0.76, .c = 0.010, .h = 250 }, // Hg
        104...112 => .{ .l = 0.46, .c = 0.070, .h = 265 }, // 6d metals
        57...71 => .{ .l = 0.80, .c = 0.050, .h = 150 }, // lanthanides
        89...103 => .{ .l = 0.60, .c = 0.070, .h = 330 }, // actinides
        0 => .{ .l = 0.60, .c = 0.0, .h = 0 }, // dummy atom
        else => blk: {
            // Remaining p-block metals and metalloids: their CPK hue, muted.
            var c = colour.labToLch(colour.srgbToOklab(colorRgb(z)));
            c.l = std.math.clamp(c.l, 0.50, 0.78);
            c.c = @min(c.c, 0.07);
            break :blk c;
        },
    };
    return colour.oklchToSrgb(lch);
}

/// Which elements need a text label in a structure with these per-element
/// atom counts (indexed by Z). Two present elements whose display colours
/// can look alike (`colour.confusable`, including under colour-vision
/// deficiencies) are ambiguous; the one with fewer atoms is labelled, or
/// both when the counts are equal. A lone rare element is never labelled:
/// its colour alone can't be mistaken for anything else in the structure.
pub fn ambiguousElements(counts: *const [max_z + 1]u32) [max_z + 1]bool {
    var out: [max_z + 1]bool = @splat(false);
    var present: [max_z + 1]u8 = undefined;
    var colors_: [max_z + 1][3]f32 = undefined;
    var n: usize = 0;
    for (counts, 0..) |k, z| if (k > 0) {
        present[n] = @intCast(z);
        colors_[n] = displayColor(@intCast(z));
        n += 1;
    };
    for (0..n) |i| for (i + 1..n) |j| {
        if (!colour.confusable(colors_[i], colors_[j])) continue;
        const a = present[i];
        const b = present[j];
        if (counts[a] <= counts[b]) out[a] = true;
        if (counts[b] <= counts[a]) out[b] = true;
    };
    return out;
}

/// Covalent radius in Ångström for bond order 1..3, or null if unavailable.
pub fn covalentRadius(z: u8, order: u2) ?f32 {
    std.debug.assert(order >= 1);
    const r: u16 = if (z < radii.len) radii[z][order - 1] else if (order == 1) 150 else 0;
    if (r == 0) return null;
    return @as(f32, @floatFromInt(r)) / 100.0;
}

/// Radius used for ball-and-stick atoms (Å).
pub fn displayRadius(z: u8) f32 {
    const r1 = covalentRadius(z, 1) orelse 0.7;
    return @max(0.2, r1 * 0.38);
}

/// Parse an element label as found in QM/XYZ files: "C", "c", "Cl", "CL",
/// "C1", "C12", "Fe2+", "6", "H-H_1" ... Returns null if unrecognised.
pub fn parseLabel(label: []const u8) ?u8 {
    if (label.len == 0) return null;
    if (std.ascii.isDigit(label[0])) {
        var end: usize = 0;
        while (end < label.len and std.ascii.isDigit(label[end])) end += 1;
        const z = std.fmt.parseInt(u8, label[0..end], 10) catch return null;
        return if (z <= max_z) z else null;
    }
    if (!std.ascii.isAlphabetic(label[0])) return null;
    const first = std.ascii.toUpper(label[0]);
    // Try two-letter symbol first.
    if (label.len >= 2 and std.ascii.isAlphabetic(label[1])) {
        const second = std.ascii.toLower(label[1]);
        if (lookup(&.{ first, second })) |z| return z;
    }
    return lookup(&.{first});
}

fn lookup(sym: []const u8) ?u8 {
    for (symbols, 0..) |s, z| {
        if (std.mem.eql(u8, s, sym)) return @intCast(z);
    }
    return null;
}

test "parse labels" {
    const t = std.testing;
    try t.expectEqual(@as(?u8, 6), parseLabel("C"));
    try t.expectEqual(@as(?u8, 6), parseLabel("c"));
    try t.expectEqual(@as(?u8, 17), parseLabel("Cl"));
    try t.expectEqual(@as(?u8, 17), parseLabel("CL"));
    try t.expectEqual(@as(?u8, 6), parseLabel("C12"));
    try t.expectEqual(@as(?u8, 26), parseLabel("Fe2+"));
    try t.expectEqual(@as(?u8, 8), parseLabel("8"));
    try t.expectEqual(@as(?u8, 1), parseLabel("H-H_1"));
    try t.expectEqual(@as(?u8, null), parseLabel("*"));
}

test "table sizes" {
    try std.testing.expectEqual(@as(usize, 97), radii.len);
    try std.testing.expectEqual(@as(usize, 97), colors.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), covalentRadius(6, 1).?, 1e-6);
    try std.testing.expectEqual(@as(?f32, null), covalentRadius(1, 2));
}

test "labels only for look-alike elements, on the rarer one" {
    var counts: [max_z + 1]u32 = @splat(0);
    counts[1] = 30;
    counts[6] = 20;
    counts[8] = 4;
    counts[46] = 1; // Pd
    // A lone Pd among organic elements: nothing is ambiguous.
    var out = ambiguousElements(&counts);
    for (out) |b| try std.testing.expect(!b);
    // Pd and Ru share the 4d colour: both labelled (equal counts).
    counts[44] = 1;
    out = ambiguousElements(&counts);
    try std.testing.expect(out[46] and out[44]);
    try std.testing.expect(!out[1] and !out[6] and !out[8]);
    // With more Ru than Pd, only Pd is labelled.
    counts[44] = 3;
    out = ambiguousElements(&counts);
    try std.testing.expect(out[46] and !out[44]);
}

test "everyday organic elements never need labels" {
    // H, C, N, O must stay distinct from each other and from the other
    // common organic elements, or most structures would sprout labels.
    const anchors = [_]u8{ 1, 6, 7, 8 };
    const others = [_]u8{ 1, 6, 7, 8, 9, 15, 16, 17, 35, 53, 79 };
    for (anchors) |a| for (others) |b| {
        if (a == b) continue;
        if (colour.confusable(displayColor(a), displayColor(b))) {
            std.debug.print("confusable: {s}-{s}\n", .{ symbol(a), symbol(b) });
            return error.TestUnexpectedResult;
        }
    };
}
