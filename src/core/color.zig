//! Perceptual colour: sRGB <-> OKLab / OKLCh (Björn Ottosson, 2020), plus the
//! bond-character palettes built in OKLCh so contrast with the background
//! rises with bond order. See docs/BONDS.md.
const std = @import("std");

pub const Rgb = [3]f32;

pub const Lab = struct { l: f32, a: f32, b: f32 };

/// Lightness (0..1), chroma (~0..0.37), hue in degrees.
pub const Lch = struct { l: f32, c: f32, h: f32 };

fn toLinear(x: f32) f32 {
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

fn toGamma(x: f32) f32 {
    return if (x <= 0.0031308) 12.92 * x else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
}

pub fn srgbToOklab(rgb: Rgb) Lab {
    const r = toLinear(rgb[0]);
    const g = toLinear(rgb[1]);
    const b = toLinear(rgb[2]);
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        .l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        .a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        .b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}

/// Linear-light RGB, possibly out of [0, 1] (out of gamut).
fn oklabToLinear(lab: Lab) Rgb {
    const l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b;
    const m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b;
    const s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b;
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;
    return .{
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    };
}

pub fn lchToLab(c: Lch) Lab {
    const h = std.math.degreesToRadians(c.h);
    return .{ .l = c.l, .a = c.c * @cos(h), .b = c.c * @sin(h) };
}

pub fn labToLch(lab: Lab) Lch {
    var h = std.math.radiansToDegrees(std.math.atan2(lab.b, lab.a));
    if (h < 0) h += 360;
    return .{ .l = lab.l, .c = @sqrt(lab.a * lab.a + lab.b * lab.b), .h = h };
}

fn inGamut(lin: Rgb) bool {
    const eps = 1e-4;
    for (lin) |x| if (x < -eps or x > 1 + eps) return false;
    return true;
}

/// OKLCh → sRGB. Out-of-gamut colours keep their lightness and hue and lose
/// chroma until they fit, so perceived lightness is preserved exactly.
pub fn oklchToSrgb(c: Lch) Rgb {
    var lch = c;
    lch.l = std.math.clamp(lch.l, 0, 1);
    var lin = oklabToLinear(lchToLab(lch));
    if (!inGamut(lin)) {
        var lo: f32 = 0;
        var hi: f32 = lch.c;
        for (0..24) |_| {
            const mid = (lo + hi) / 2;
            if (inGamut(oklabToLinear(lchToLab(.{ .l = lch.l, .c = mid, .h = lch.h })))) lo = mid else hi = mid;
        }
        lin = oklabToLinear(lchToLab(.{ .l = lch.l, .c = lo, .h = lch.h }));
    }
    var out: Rgb = undefined;
    for (lin, &out) |x, *o| o.* = toGamma(std.math.clamp(x, 0, 1));
    return out;
}

/// Interpolate in OKLCh, taking the short way around the hue circle.
pub fn mixLch(a: Lch, b: Lch, t: f32) Lch {
    var dh = b.h - a.h;
    if (dh > 180) dh -= 360;
    if (dh < -180) dh += 360;
    var h = a.h + dh * t;
    if (h < 0) h += 360;
    if (h >= 360) h -= 360;
    return .{ .l = a.l + (b.l - a.l) * t, .c = a.c + (b.c - a.c) * t, .h = h };
}

// ------------------------------------------------------- colour vision

pub const Vision = enum { normal, protanopia, deuteranopia, tritanopia };

/// Machado, Oliveira & Fernandes (2009) full-severity matrices, applied in
/// linear RGB.
const cvd_matrices = [_][3][3]f32{
    .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } },
    .{ .{ 0.152286, 1.052583, -0.204868 }, .{ 0.114503, 0.786281, 0.099216 }, .{ -0.003882, -0.048116, 1.051998 } },
    .{ .{ 0.367322, 0.860646, -0.227968 }, .{ 0.280085, 0.672501, 0.047413 }, .{ -0.011820, 0.042940, 0.968881 } },
    .{ .{ 1.255528, -0.076749, -0.178779 }, .{ -0.078411, 0.930809, 0.147602 }, .{ 0.004733, 0.691367, 0.303900 } },
};

/// How an sRGB colour looks with the given colour vision, as OKLab.
pub fn simulate(rgb: Rgb, vision: Vision) Lab {
    const m = cvd_matrices[@backingInt(vision)];
    const lin: Rgb = .{ toLinear(rgb[0]), toLinear(rgb[1]), toLinear(rgb[2]) };
    var out: Rgb = undefined;
    for (0..3) |i| {
        const v = m[i][0] * lin[0] + m[i][1] * lin[1] + m[i][2] * lin[2];
        out[i] = toGamma(std.math.clamp(v, 0, 1));
    }
    return srgbToOklab(out);
}

fn labDistance(a: Lab, b: Lab) f32 {
    const dl = a.l - b.l;
    const da = a.a - b.a;
    const db = a.b - b.b;
    return @sqrt(dl * dl + da * da + db * db);
}

/// Smallest OKLab distance between two colours across normal vision and
/// the three dichromacies: how alike they can look to anyone.
pub fn worstCaseDistance(a: Rgb, b: Rgb) f32 {
    var worst: f32 = std.math.inf(f32);
    for (std.enums.values(Vision)) |v| worst = @min(worst, labDistance(simulate(a, v), simulate(b, v)));
    return worst;
}

/// Below this worst-case OKLab distance, two flat-coloured atoms are easy
/// to mistake for each other at a glance.
pub const confusable_distance: f32 = 0.07;

pub fn confusable(a: Rgb, b: Rgb) bool {
    return worstCaseDistance(a, b) < confusable_distance;
}

// ------------------------------------------------------------------ bonds

/// Soft staircase: plateaus around whole bond orders, steeper in between.
/// `strength` 0 = linear, 1 = flat at integers (smoothstep per segment).
/// Monotonic and continuous for any strength in [0, 1].
pub fn snap(character: f32, strength: f32) f32 {
    const n = @floor(character);
    const x = character - n;
    const smooth = x * x * (3 - 2 * x);
    return n + x + (smooth - x) * std.math.clamp(strength, 0, 1);
}

pub const PaletteStop = struct { at: f32, lch: Lch };

/// A bond palette for one background. Stops are in OKLCh. Contrast against
/// the background (|L - L_bg|) strictly increases with bond character, and
/// the first stop sits on the background so weak contacts fade into it.
pub const Palette = struct {
    /// Viewport background (sRGB) the palette is designed against.
    background: Rgb,
    stops: []const PaletteStop,

    pub fn lch(p: Palette, s: f32) Lch {
        const stops = p.stops;
        if (s <= stops[0].at) return stops[0].lch;
        for (stops[1..], 1..) |stop, i| {
            if (s <= stop.at) {
                const prev = stops[i - 1];
                return mixLch(prev.lch, stop.lch, (s - prev.at) / (stop.at - prev.at));
            }
        }
        return stops[stops.len - 1].lch;
    }
};

// Both palettes follow the same rules:
// - the first stop is the background, and lightness moves monotonically
//   away from it up to triple, so the scale reads correctly in greyscale and
//   agrees with the opacity fade of weak contacts;
// - the move is front-loaded (a stop at 0.5), so thermally stretched bonds
//   just below single (C-H in MD frames) still stand clear of the background;
// - low chroma, so the atoms carry the colour, and no hues that atoms own
//   (teal C in the flat style, blue N, red O, gold Au, yellow S).
// Bonds go warm grey -> dusty plum -> deep indigo on light, and the mirror
// image, warm grey -> mauve -> pale lavender, on dark.

/// Light: a pale, low-chroma blue-grey; bonds darken with order.
pub const light_palette: Palette = .{
    .background = .{ 0.8762, 0.9065, 0.9390 }, // #DFE7EF, OKLCh (0.925, 0.014, 250)
    .stops = &.{
        .{ .at = 0.0, .lch = .{ .l = 0.925, .c = 0.014, .h = 250 } }, // = background
        .{ .at = 0.5, .lch = .{ .l = 0.72, .c = 0.020, .h = 60 } },
        .{ .at = 1.0, .lch = .{ .l = 0.58, .c = 0.035, .h = 60 } }, // single: warm grey
        .{ .at = 2.0, .lch = .{ .l = 0.44, .c = 0.090, .h = 330 } }, // double: dusty plum
        .{ .at = 3.0, .lch = .{ .l = 0.28, .c = 0.120, .h = 280 } }, // triple: deep indigo
    },
};

/// Dark: bonds lighten with order (= more contrast).
pub const dark_palette: Palette = .{
    .background = .{ 0.105, 0.11, 0.13 }, // OKLab L ≈ 0.228
    .stops = &.{
        .{ .at = 0.0, .lch = .{ .l = 0.228, .c = 0.010, .h = 265 } }, // = background
        .{ .at = 0.5, .lch = .{ .l = 0.43, .c = 0.018, .h = 60 } },
        .{ .at = 1.0, .lch = .{ .l = 0.57, .c = 0.032, .h = 60 } }, // single: warm grey
        .{ .at = 2.0, .lch = .{ .l = 0.73, .c = 0.080, .h = 330 } }, // double: mauve
        .{ .at = 3.0, .lch = .{ .l = 0.89, .c = 0.060, .h = 290 } }, // triple: pale lavender
    },
};

pub const BondColor = struct { rgb: Rgb, alpha: f32 };

/// Colour (sRGB) and opacity for a bond of the given (raw) character.
pub fn bondColor(palette: Palette, character: f32, snap_strength: f32) BondColor {
    const s = snap(std.math.clamp(character, 0, 3), snap_strength);
    // Below single-bond character, fade opacity out as well as contrast.
    const alpha: f32 = if (s >= 1) 1 else s;
    return .{ .rgb = oklchToSrgb(palette.lch(s)), .alpha = alpha };
}

test "oklab reference values" {
    const white = srgbToOklab(.{ 1, 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), white.l, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), white.a, 1e-3);
    // Pure sRGB red: L ≈ 0.628, a ≈ 0.225, b ≈ 0.126 (Ottosson).
    const red = srgbToOklab(.{ 1, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.628), red.l, 2e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.225), red.a, 2e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.126), red.b, 2e-3);
}

test "round trip and gamut mapping" {
    const c: Rgb = .{ 0.2, 0.6, 0.9 };
    const back = oklchToSrgb(labToLch(srgbToOklab(c)));
    for (c, back) |x, y| try std.testing.expectApproxEqAbs(x, y, 1e-3);
    // Very saturated request still comes back in gamut with the same lightness.
    const out = oklchToSrgb(.{ .l = 0.9, .c = 0.35, .h = 140 });
    for (out) |x| try std.testing.expect(x >= 0 and x <= 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), srgbToOklab(out).l, 2e-3);
}

test "snap is monotonic, continuous, and fixes integers" {
    for ([_]f32{ 0, 0.5, 0.7, 1 }) |k| {
        var prev: f32 = -1;
        var x: f32 = 0;
        while (x <= 3) : (x += 0.001) {
            const y = snap(x, k);
            try std.testing.expect(y >= prev - 1e-5);
            try std.testing.expect(@abs(y - prev) < 0.01 or prev < 0);
            prev = y;
        }
        try std.testing.expectApproxEqAbs(@as(f32, 2), snap(2, k), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 1.5), snap(1.5, k), 1e-6);
    }
    // Gentle plateau: near an integer the output moves slower than the input.
    try std.testing.expect(snap(1.05, 0.7) - 1 < 0.05);
}

test "bond palette contrast rises with bond character (both themes)" {
    for ([_]Palette{ light_palette, dark_palette }) |pal| {
        const bg_l = srgbToOklab(pal.background).l;
        // The first stop sits on the background.
        try std.testing.expectApproxEqAbs(bg_l, pal.stops[0].lch.l, 0.02);
        var prev: f32 = -1;
        var x: f32 = 0;
        while (x <= 3) : (x += 0.01) {
            const col = bondColor(pal, x, 0.7);
            const contrast = @abs(srgbToOklab(col.rgb).l - bg_l);
            try std.testing.expect(contrast >= prev - 2e-3);
            prev = contrast;
        }
        // Triple bonds stand well apart from the background.
        try std.testing.expect(prev > 0.6);
        try std.testing.expectEqual(@as(f32, 0), bondColor(pal, 0, 0.7).alpha);
    }
}

test "colour-vision simulation" {
    // Normal vision is the identity.
    const c: Rgb = .{ 0.2, 0.6, 0.9 };
    const n = simulate(c, .normal);
    const ref = srgbToOklab(c);
    try std.testing.expectApproxEqAbs(ref.l, n.l, 1e-4);
    // Red and green collapse under deuteranopia but not for normal vision.
    const red: Rgb = .{ 0.8, 0.35, 0.1 };
    const green: Rgb = .{ 0.45, 0.55, 0.1 };
    try std.testing.expect(labDistance(simulate(red, .normal), simulate(green, .normal)) > 0.1);
    try std.testing.expect(confusable(red, green));
    try std.testing.expect(!confusable(.{ 1, 1, 1 }, .{ 0, 0, 0 }));
}
