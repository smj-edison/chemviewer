//! Thin helpers over cimgui: Zig formatting for text, small widgets.
const std = @import("std");
const c = @import("c");
const Renderer = @import("../render/Renderer.zig");

pub fn v2(x: f32, y: f32) c.ImVec2_c {
    return .{ .x = x, .y = y };
}

pub fn printZ(buf: []u8, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0);
}

threadlocal var fmt_buf: [2048]u8 = undefined;

fn fmtZ(comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return printZ(&fmt_buf, fmt, args) catch blk: {
        fmt_buf[fmt_buf.len - 1] = 0;
        break :blk fmt_buf[0 .. fmt_buf.len - 1 :0];
    };
}

pub fn text(comptime fmt: []const u8, args: anytype) void {
    const s = fmtZ(fmt, args);
    c.igTextUnformatted(s.ptr, s.ptr + s.len);
}

pub fn textDisabled(comptime fmt: []const u8, args: anytype) void {
    c.igTextDisabled("%s", fmtZ(fmt, args).ptr);
}

pub fn textWrapped(comptime fmt: []const u8, args: anytype) void {
    c.igTextWrapped("%s", fmtZ(fmt, args).ptr);
}

pub fn tooltip(s: [:0]const u8) void {
    if (c.igBeginItemTooltip()) {
        c.igPushTextWrapPos(c.igGetFontSize() * 25);
        c.igTextUnformatted(s.ptr, s.ptr + s.len);
        c.igPopTextWrapPos();
        c.igEndTooltip();
    }
}

pub fn rgba(r: f32, g: f32, b: f32, a: f32) u32 {
    return c.igGetColorU32_Vec4(.{ .x = r, .y = g, .z = b, .w = a });
}

/// Horizontal bar showing the bond-character gradient with 0..3 ticks,
/// sampled finely so the snap curve and OKLCh interpolation show as rendered.
pub fn gradientLegend(snap_strength: f32) void {
    const dl = c.igGetWindowDrawList();
    const p = c.igGetCursorScreenPos();
    const w = c.igGetContentRegionAvail().x;
    const h: f32 = c.igGetFontSize() * 0.9;
    const bg = Renderer.background;
    const segments = 96;
    var prev_col: u32 = 0;
    for (0..segments + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / segments;
        // Pre-blend alpha against the viewport background so it reads like the 3D view.
        const col = blend(Renderer.gradientColor(t * 3, snap_strength), bg);
        if (i > 0) {
            const x0 = p.x + (t - 1.0 / @as(f32, segments)) * w;
            c.ImDrawList_AddRectFilledMultiColor(dl, v2(x0, p.y), v2(p.x + t * w + 0.5, p.y + h), prev_col, col, col, prev_col);
        }
        prev_col = col;
    }
    const labels = [_][:0]const u8{ "0", "single", "double", "triple" };
    const tcol = c.igGetColorU32_Col(c.ImGuiCol_TextDisabled, 1);
    for (labels, 0..) |l, i| {
        const fi: f32 = @floatFromInt(i);
        const tw = c.igCalcTextSize(l.ptr, null, false, -1).x;
        const x = std.math.clamp(p.x + fi / 3 * w - tw / 2, p.x, p.x + w - tw);
        c.ImDrawList_AddText_Vec2(dl, v2(x, p.y + h + 2), tcol, l.ptr, null);
    }
    c.igDummy(v2(w, h + c.igGetFontSize() + 4));
}

fn blend(col: [4]f32, bg: [3]f32) u32 {
    const a = col[3];
    return rgba(
        col[0] * a + bg[0] * (1 - a),
        col[1] * a + bg[1] * (1 - a),
        col[2] * a + bg[2] * (1 - a),
        1,
    );
}
