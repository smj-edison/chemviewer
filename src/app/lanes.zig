//! Draws the lanes of attached data under the energy, on the same axis.
const std = @import("std");
const c = @import("c");
const cv = @import("chemviewer");
const ui = @import("ui.zig");
const App = @import("App.zig");
const plot = @import("plot.zig");
const Lane = @import("data.zig").Lane;
const Scale = cv.envelope.Scale;

/// Told apart with any colour vision (after Okabe and Ito), on light and dark.
fn color(app: *const App, i: usize) u32 {
    const light = [_][3]f32{ .{ 0.75, 0.30, 0.0 }, .{ 0.0, 0.50, 0.36 }, .{ 0.65, 0.30, 0.52 }, .{ 0.0, 0.36, 0.60 }, .{ 0.50, 0.42, 0.0 } };
    const dark = [_][3]f32{ .{ 0.95, 0.60, 0.25 }, .{ 0.15, 0.78, 0.60 }, .{ 0.88, 0.60, 0.76 }, .{ 0.40, 0.72, 0.95 }, .{ 0.92, 0.86, 0.35 } };
    const rgb = (if (app.style.theme == .light) light else dark)[i % light.len];
    return ui.rgba(rgb[0], rgb[1], rgb[2], 1);
}

/// What is in view, as a scale. Null if nothing is known there.
pub fn scaleInView(app: *App, lane: Lane) ?Scale {
    const a = lane.source;
    a.lock();
    defer a.unlock();
    const al = a.aligned(app.doc.?.frameCount());
    const w = app.timeline.window;
    const first = al.rowAt(w.lo, a.table.rows) orelse 0;
    const end = al.rowFrom(w.hi, a.table.rows);
    const r = a.pyramid(lane.column).range(a.table.columns[lane.column].values.items, first, @max(end, first));
    return if (r.known()) .{ .lo = r.lo, .hi = r.hi } else null;
}

/// The value at `frame`: that of the last row at or before it.
pub fn valueAt(app: *App, lane: Lane, frame: f64) ?f64 {
    const a = lane.source;
    a.lock();
    defer a.unlock();
    const row = a.aligned(app.doc.?.frameCount()).rowAt(frame, a.table.rows) orelse return null;
    return a.table.columns[lane.column].values.items[row];
}

pub fn draw(app: *App, dl: *c.ImDrawList, i: usize, axis: plot.Axis, top: f32, h: f32, head: f64) void {
    const lane = app.data.lanes.items[i];
    const a = lane.source;
    a.lock();
    defer a.unlock();
    const n = app.doc.?.frameCount();
    const t = &a.table;
    const col = t.columns[lane.column];
    const values = col.values.items;
    const pyramid = a.pyramid(lane.column);
    const al = a.aligned(n);
    const whole = pyramid.range(values, 0, t.rows);
    const label_col = c.igGetColorU32_Col(c.ImGuiCol_TextDisabled, 1);
    c.ImDrawList_AddLine(dl, ui.v2(axis.x0, top), ui.v2(axis.x0 + axis.width, top), c.igGetColorU32_Col(c.ImGuiCol_Border, 1), 1, 0);

    var buf: [256]u8 = undefined;
    const name = std.fs.path.basename(a.path);
    var words: [64]u8 = undefined;
    const doubt = if (al.confirmed) "" else al.evidence(&words);
    if (whole.known()) {
        const scale: Scale = lane.fitted orelse .{ .lo = whole.lo, .hi = whole.hi };
        c.ImDrawList_PushClipRect(dl, ui.v2(axis.x0 - 4, top), ui.v2(axis.x0 + axis.width + 4, top + h), true);
        curve(dl, lane, values, pyramid, al, scale, axis, n, top, h, color(app, i));
        c.ImDrawList_PopClipRect(dl);
        const label = ui.printZ(&buf, "{s}: {s}{s}{s}{s}  {d:.4} to {d:.4}{s}  {s}{s}", .{
            name,                                       col.name,
            if (col.unit != null) " (" else "",         col.unit orelse "",
            if (col.unit != null) ")" else "",          scale.lo,
            scale.hi,                                   if (lane.fitted != null) ", fitted" else "",
            if (doubt.len > 0) "unconfirmed: " else "", doubt,
        }) catch "";
        ui.plotLabel(dl, axis.x0 + 6, top + 3, label_col, label);
    } else {
        const label = ui.printZ(&buf, "{s}: {s}  {s}", .{ name, col.name, if (a.state == .reading) "reading..." else "no values" }) catch "";
        ui.plotLabel(dl, axis.x0 + 6, top + 3, label_col, label);
    }

    // At the playhead, at the right end.
    const value = if (al.rowAt(head, t.rows)) |row| ui.printZ(&buf, "{d:.6}", .{values[row]}) catch "" else "-";
    const size = c.igCalcTextSize(value.ptr, null, false, -1);
    ui.plotLabel(dl, axis.x0 + axis.width - size.x - 4, top + 3, c.igGetColorU32_Col(c.ImGuiCol_Text, 1), value);
}

/// Steps, each value until the next row, or dots. With more rows than pixel columns,
/// the lowest and highest per column.
fn curve(dl: *c.ImDrawList, lane: Lane, values: []const f64, pyramid: *const cv.pyramid.Pyramid, al: cv.alignment.Alignment, scale: Scale, axis: plot.Axis, n: usize, top: f32, h: f32, col: u32) void {
    const rows = values.len;
    const first = al.rowAt(axis.window.lo, rows) orelse 0;
    const end = @min(al.rowFrom(axis.window.hi, rows) + 1, rows);
    if (end <= first) return;
    const last: f64 = @floatFromInt(n -| 1);
    if (end - first <= @as(usize, @intFromFloat(@max(axis.width, 1)))) {
        const roomy = axis.width / @as(f32, @floatFromInt(end - first)) > 8;
        var prev_y: ?f32 = null;
        for (first..end) |row| {
            const frame = al.frameOf(row);
            if (frame > last + 1e-6) break;
            const v = values[row];
            if (!std.math.isFinite(v)) {
                prev_y = null;
                continue;
            }
            const x = axis.window.toX(frame, axis.x0, axis.width);
            const y = plot.yOf(v, scale, top, h, 4);
            if (!lane.points) {
                if (prev_y) |p| c.ImDrawList_AddLine(dl, ui.v2(x, p), ui.v2(x, y), col, 1, 0);
                const until = @min(al.frameOf(row + 1), last);
                c.ImDrawList_AddLine(dl, ui.v2(x, y), ui.v2(axis.window.toX(until, axis.x0, axis.width), y), col, 1, 0);
            }
            if (lane.points or roomy) c.ImDrawList_AddCircleFilled(dl, ui.v2(x, y), 2, col, 0);
            prev_y = y;
        }
        return;
    }
    var prev: ?[2]f32 = null;
    var row = first;
    for (0..@intFromFloat(axis.width)) |k| {
        const x = axis.x0 + @as(f32, @floatFromInt(k)) + 0.5;
        const next = al.rowFrom(axis.window.fromX(x + 0.5, axis.x0, axis.width), rows);
        defer row = @max(row, next);
        if (next <= row) continue;
        const r = pyramid.range(values, row, next);
        if (!r.known()) {
            prev = null;
            continue;
        }
        const ya = plot.yOf(r.hi, scale, top, h, 4);
        const yb = plot.yOf(r.lo, scale, top, h, 4);
        if (lane.points) {
            c.ImDrawList_AddCircleFilled(dl, ui.v2(x, ya), 1.5, col, 0);
            c.ImDrawList_AddCircleFilled(dl, ui.v2(x, yb), 1.5, col, 0);
            continue;
        }
        const from = if (prev) |p| @min(ya, p[1]) else ya;
        const to = if (prev) |p| @max(yb, p[0]) else yb;
        c.ImDrawList_AddLine(dl, ui.v2(x, from), ui.v2(x, to + 1), col, 1, 0);
        prev = .{ ya, yb };
    }
}
