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

/// Text that looks like a label but can be selected and copied (Ctrl+C):
/// a borderless read-only input field spanning the rest of the line.
pub fn selectableText(id: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = printZ(&buf, fmt, args) catch blk: {
        buf[buf.len - 1] = 0;
        break :blk buf[0 .. buf.len - 1 :0];
    };
    c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, 0);
    c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(0, c.igGetStyle().*.FramePadding.y));
    c.igSetNextItemWidth(-1);
    _ = c.igInputText(id.ptr, s.ptr, s.len + 1, c.ImGuiInputTextFlags_ReadOnly | c.ImGuiInputTextFlags_AutoSelectAll, null, null);
    c.igPopStyleVar(1);
    c.igPopStyleColor(1);
}

pub fn tooltip(s: [:0]const u8) void {
    if (c.igBeginItemTooltip()) {
        c.igPushTextWrapPos(c.igGetFontSize() * 25);
        c.igTextUnformatted(s.ptr, s.ptr + s.len);
        c.igPopTextWrapPos();
        c.igEndTooltip();
    }
}

/// A dot of a colour, on the line of framed widgets.
pub fn swatch(rgb: [3]f32, size: f32) void {
    const p = c.igGetCursorScreenPos();
    const h = c.igGetFrameHeight();
    const centre = v2(p.x + size / 2, p.y + h / 2);
    const dl = c.igGetWindowDrawList();
    c.ImDrawList_AddCircleFilled(dl, centre, size / 2, rgba(rgb[0], rgb[1], rgb[2], 1), 0);
    c.ImDrawList_AddCircle(dl, centre, size / 2, c.igGetColorU32_Col(c.ImGuiCol_Border, 1), 0, 1, 0);
    c.igDummy(v2(size, h));
}

/// A section that can be collapsed, starting as `open` says and keeping it up
/// to date. Whether to draw its contents.
pub fn section(label: [:0]const u8, open: *bool) bool {
    c.igSetNextItemOpen(open.*, c.ImGuiCond_Always);
    open.* = c.igCollapsingHeader_TreeNodeFlags(label.ptr, 0);
    return open.*;
}

/// A table row of the mouse and keys help.
pub fn helpRow(input: [:0]const u8, action: [:0]const u8) void {
    c.igTableNextRow(0, 0);
    _ = c.igTableNextColumn();
    c.igPushTextWrapPos(0);
    c.igTextUnformatted(input.ptr, input.ptr + input.len);
    c.igPopTextWrapPos();
    _ = c.igTableNextColumn();
    c.igPushTextWrapPos(0);
    c.igTextUnformatted(action.ptr, action.ptr + action.len);
    c.igPopTextWrapPos();
}

/// Put the next radio button or checkbox on the same line, if it fits.
pub fn sameLineIfFits(label: [:0]const u8) void {
    const style = c.igGetStyle();
    const width = c.igGetFrameHeight() + style.*.ItemInnerSpacing.x + c.igCalcTextSize(label.ptr, null, true, -1).x;
    c.igSameLine(0, -1);
    if (c.igGetContentRegionAvail().x < width) c.igNewLine();
}

pub fn rgba(r: f32, g: f32, b: f32, a: f32) u32 {
    return c.igGetColorU32_Vec4(.{ .x = r, .y = g, .z = b, .w = a });
}

/// Horizontal bar showing the bond-character gradient with 0..3 ticks,
/// sampled finely so the snap curve and OKLCh interpolation show as rendered.
pub fn gradientLegend(theme: Renderer.Theme, snap_strength: f32) void {
    const dl = c.igGetWindowDrawList();
    const p = c.igGetCursorScreenPos();
    const w = c.igGetContentRegionAvail().x;
    const h: f32 = c.igGetFontSize() * 0.9;
    const bg = theme.background();
    const palette = theme.palette();
    const segments = 96;
    var prev_col: u32 = 0;
    for (0..segments + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / segments;
        // Pre-blend alpha against the viewport background so it reads like the 3D view.
        const col = blend(Renderer.gradientColor(palette, t * 3, snap_strength), bg);
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
