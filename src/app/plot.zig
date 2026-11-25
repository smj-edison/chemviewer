//! The timeline's plot: energies over the visible window of frames, the playhead
//! and marks, the strip under it that shows where the window is, and the zoom
//! controls. Everything that takes a modifier key also works on the strip.
const std = @import("std");
const c = @import("c");
const cv = @import("chemviewer");
const ui = @import("ui.zig");
const App = @import("App.zig");
const lanes = @import("lanes.zig");
const Window = cv.window.Window;
const Envelope = cv.envelope.Envelope;
const Scale = cv.envelope.Scale;
const Ticks = cv.envelope.Ticks;

pub const State = struct {
    window: Window = .{ .lo = 0, .hi = 0 },
    /// Whose window it is (`App.documents_opened`).
    document: u64 = 0,
    /// Window of the next file that is opened, in frames.
    initial: ?[2]f64 = null,
    /// Where the playhead was, to follow it.
    last_head: f64 = 0,
    was_playing: bool = false,
    /// Middle button pan: where the mouse was.
    pan_x: ?f32 = null,
    /// What of the strip is being dragged, where the mouse was, and how far
    /// from it that is.
    grab: ?struct { part: Part, x: f32, off: f32 } = null,
    /// The mouse was on the plot or the strip.
    hovered: bool = false,
    /// Wheel movement over the UI since the last frame.
    wheel: cv.window.Wheel = .{},
    plot_env: Envelope = .{},
    /// Of the whole trajectory.
    strip_env: Envelope = .{},
    /// The energy scale the user fitted (null = that of the whole trajectory).
    fitted: ?Scale = null,

    const Part = enum { lo, hi, window };

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.plot_env.deinit(gpa);
        s.strip_env.deinit(gpa);
    }

    /// The energy scale changes only when the user fits it, so that a height
    /// always means the same.
    fn scale(s: *const State) ?Scale {
        if (s.fitted) |f| return f;
        // The strip is drawn later; it may still be another file's.
        const of_run = if (s.strip_env.key) |k| k.document == s.document else false;
        return if (of_run) s.strip_env.scale() else s.plot_env.scale();
    }

    /// Keep the playhead in view. A new file starts with everything in view, or
    /// `initial`.
    pub fn follow(s: *State, app: *const App, d: *const App.Document) void {
        const n = d.frameCount();
        if (s.document != app.documents_opened) {
            s.document = app.documents_opened;
            s.window = if (s.initial) |r| .between(r[0], r[1], n) else .all(n);
            s.initial = null;
            s.fitted = null;
            s.pan_x = null;
            s.grab = null;
        } else if (app.plot_drag == null and s.grab == null) {
            // Not while dragging: it would run away under the mouse. Pausing
            // moves the playhead too, as part of playing.
            s.window = s.window.following(s.last_head, playhead(app, d), app.playing or s.was_playing, n);
        }
        s.was_playing = app.playing;
        s.last_head = playhead(app, d);
    }
};

/// Where the playhead is, in frames: between two while a blend plays, which
/// aren't next to each other if one that can't be read is between them.
fn playhead(app: *const App, d: *const App.Document) f64 {
    const from: f64 = @floatFromInt(d.current);
    const t: f64 = if (app.playing) app.blendTime() else 0;
    const next = d.display.next orelse return from;
    return if (t > 0) from + t * (@as(f64, @floatFromInt(next.index)) - from) else from;
}

/// Show every frame, and every value.
pub fn showAll(app: *App, n: usize) void {
    app.timeline.window = .all(n);
    resetScales(app);
}

fn resetScales(app: *App) void {
    app.timeline.fitted = null;
    for (app.data.lanes.items) |*l| l.fitted = null;
}

fn isFitted(app: *const App) bool {
    if (app.timeline.fitted != null) return true;
    for (app.data.lanes.items) |l| if (l.fitted != null) return true;
    return false;
}

pub const hint: [:0]const u8 = "drag: scrub   right drag: finely   Ctrl+wheel: zoom   Shift+wheel or middle drag: pan   Z: show all";

/// The energy and the lanes.
fn plotCount(app: *const App) usize {
    return @max(@intFromBool(app.data.show_energy) + app.data.lanes.items.len, 1);
}

/// Of each of them.
fn plotHeight() f32 {
    return c.igGetFontSize() * 4.3;
}

/// Of all of them together.
fn plotsHeight(app: *const App) f32 {
    return plotHeight() * @as(f32, @floatFromInt(plotCount(app)));
}

/// Of the part of them that is in view; the rest is scrolled to.
fn viewHeight(app: *const App) f32 {
    const most = @max(c.igGetMainViewport().*.Size.y * 0.5, plotHeight());
    return @min(plotsHeight(app), most);
}

fn markSize() f32 {
    return c.igGetFontSize() * 0.4;
}

/// Marks and frame numbers under the plots.
fn axisHeight() f32 {
    return c.igGetFontSize() * 1.2 + 2.5 * markSize();
}

pub fn height(app: *const App) f32 {
    return viewHeight(app) + axisHeight() + c.igGetStyle().*.ItemSpacing.y + c.igGetFrameHeight();
}

/// How many values fit along a plot's axis.
fn tickCount() usize {
    return @intFromFloat(@max(plotHeight() / (c.igGetFontSize() * 1.4), 2));
}

fn ticksWidth(scale: Scale) f32 {
    const t: Ticks = .of(scale, tickCount());
    var widest: f32 = 0;
    for (0..t.count) |i| {
        var buf: [64]u8 = undefined;
        const s = t.print(&buf, i) catch continue;
        widest = @max(widest, c.igCalcTextSize(s.ptr, null, false, -1).x);
    }
    return widest;
}

/// Room left of the plots for their values.
fn gutter(app: *App) f32 {
    var widest: f32 = 0;
    if (app.data.show_energy) if (app.timeline.scale()) |s| {
        widest = ticksWidth(s);
    };
    for (app.data.lanes.items) |l| if (lanes.scaleOf(l)) |s| {
        widest = @max(widest, ticksWidth(s));
    };
    // In steps, so that it seldom moves.
    const fs = c.igGetFontSize();
    return @ceil((widest + 0.8 * fs) / fs) * fs;
}

/// Round values left of a plot, and faint lines across it.
pub fn valueAxis(dl: *c.ImDrawList, scale: Scale, axis: Axis, top: f32, h: f32) void {
    const fs = c.igGetFontSize();
    const t: Ticks = .of(scale, tickCount());
    const col = c.igGetColorU32_Col(c.ImGuiCol_TextDisabled, 1);
    const line = c.igGetColorU32_Col(c.ImGuiCol_Border, 0.7);
    for (0..t.count) |i| {
        var buf: [64]u8 = undefined;
        const s = t.print(&buf, i) catch continue;
        const y = yOf(t.value(i), scale, top, h, 4);
        c.ImDrawList_AddLine(dl, ui.v2(axis.x0 - 0.3 * fs, y), ui.v2(axis.x0 + axis.width, y), line, 1, 0);
        const size = c.igCalcTextSize(s.ptr, null, false, -1);
        const ty = std.math.clamp(y - size.y / 2, top, @max(top + h - size.y, top));
        c.ImDrawList_AddText_Vec2(dl, ui.v2(axis.x0 - 0.5 * fs - size.x, ty), col, s.ptr, null);
    }
}

/// Where the frames are on screen.
pub const Axis = struct {
    window: Window,
    x0: f32,
    width: f32,

    fn x(a: Axis, frame: usize) f32 {
        return a.window.toX(@floatFromInt(frame), a.x0, a.width);
    }

    fn frameAt(a: Axis, px: f32) usize {
        return a.window.frameAt(px, a.x0, a.width);
    }
};

const Mark = cv.edit.EditSession.Mark;

/// The mark within `reach` of x, the nearest one. Many frames can share a pixel,
/// so only this gets to an edited frame for sure.
fn markAt(marks: []const Mark, x: f32, reach: f32, axis: Axis) ?Mark {
    var best: ?Mark = null;
    var best_d = reach;
    for (marks) |m| {
        if (!axis.window.contains(m.index)) continue;
        const dist = @abs(axis.x(m.index) - x);
        if (dist < best_d or (best == null and dist == best_d)) {
            best = m;
            best_d = dist;
        }
    }
    return best;
}

test "the mouse gets to the mark it is on, however many frames share a pixel" {
    const marks = [_]Mark{ .{ .index = 0, .unsaved = true }, .{ .index = 250_123, .unsaved = true }, .{ .index = 250_125, .unsaved = true }, .{ .index = 499_999, .unsaved = false } };
    const n = 500_000;
    const axis: Axis = .{ .window = .all(n), .x0 = 10, .width = 1000 };
    const x = axis.x(250_123);
    try std.testing.expectEqual(250_123, markAt(marks[0..2], x + 4, 5, axis).?.index);
    try std.testing.expectEqual(null, markAt(&marks, x + 6, 5, axis));
    try std.testing.expectEqual(0, markAt(&marks, 8, 5, axis).?.index);
    try std.testing.expectEqual(499_999, markAt(&marks, 1010, 5, axis).?.index);
    try std.testing.expectEqual(null, markAt(&.{}, x, 5, axis));
    // Zoomed in, ones that shared a pixel are apart, and others out of reach.
    const near: Axis = .{ .window = .between(250_100, 250_150, n), .x0 = 10, .width = 1000 };
    try std.testing.expectEqual(250_123, markAt(&marks, near.x(250_123), 5, near).?.index);
    try std.testing.expectEqual(250_125, markAt(&marks, near.x(250_125), 5, near).?.index);
    try std.testing.expectEqual(null, markAt(&marks, 10, 5, near));
    // A single frame.
    const one: Axis = .{ .window = .all(1), .x0 = 10, .width = 1000 };
    try std.testing.expectEqual(0, markAt(marks[0..1], 10.5, 5, one).?.index);
}

pub fn draw(app: *App, d: *App.Document) void {
    const s = &app.timeline;
    s.follow(app, d);
    s.hovered = false;
    plot(app, d);
    strip(app, d);
}

/// The wheel over an item whose axis this is.
fn wheel(s: *State, axis: Axis, n: usize) void {
    const mods = c.SDL_GetModState();
    var moved = s.wheel;
    moved.ctrl = (mods & c.SDL_KMOD_CTRL) != 0;
    moved.shift = (mods & c.SDL_KMOD_SHIFT) != 0;
    s.window = s.window.wheeled(axis.window.fromX(c.igGetMousePos().x, axis.x0, axis.width), moved, n);
}

fn plot(app: *App, d: *App.Document) void {
    const s = &app.timeline;
    const n = d.frameCount();
    const marks = app.session.marks(app.gpa) catch &.{};
    defer app.gpa.free(marks);
    const fs = c.igGetFontSize();
    const outer0 = c.igGetCursorScreenPos();
    const outer_w = @max(c.igGetContentRegionAvail().x, 1);
    const h = plotHeight();
    const all_h = plotsHeight(app);
    const view_h = viewHeight(app);
    const bar_w = if (all_h > view_h + 0.5) c.igGetStyle().*.ScrollbarSize else 0;
    // The frames keep off the edges, so that the first and last can be seen.
    const inset = fs * 0.4;
    const left = outer0.x + gutter(app) + inset;
    const w = @max(outer_w - (left - outer0.x) - inset - bar_w, 1);
    const outer1 = ui.v2(outer0.x + outer_w, outer0.y + view_h + axisHeight());
    const outer_dl = c.igGetWindowDrawList();
    c.ImDrawList_AddRectFilled(outer_dl, outer0, outer1, c.igGetColorU32_Col(c.ImGuiCol_FrameBg, 1), 3, 0);

    // The frame axis, which stays in view, then the plots, which scroll.
    const axis_top = outer0.y + view_h;
    c.igSetCursorScreenPos(ui.v2(outer0.x, axis_top));
    _ = c.igInvisibleButton("##axis", ui.v2(outer_w, axisHeight()), 0);
    const on_axis = c.igIsItemHovered(0);
    const axis_active = c.igIsItemActive();
    c.igSetCursorScreenPos(outer0);
    c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, 0);
    defer c.igPopStyleColor(1);
    _ = c.igBeginChild_Str("##plots", ui.v2(outer_w, view_h), 0, 0);
    const dl = c.igGetWindowDrawList();
    const p0 = ui.v2(left, c.igGetCursorScreenPos().y);
    const p1 = ui.v2(p0.x + w, p0.y + all_h);
    // The value boxes are on it.
    c.igSetNextItemAllowOverlap();
    _ = c.igInvisibleButton("##values", ui.v2(outer_w - bar_w, all_h), 0);
    const hovered = c.igIsItemHovered(0) or on_axis;
    const active = c.igIsItemActive() or axis_active;
    const mouse = c.igGetMousePos();

    // Pan and zoom first, so that everything below is drawn where it ends up.
    if (hovered) {
        s.hovered = true;
        wheel(s, .{ .window = s.window, .x0 = p0.x, .width = w }, n);
        if (c.igIsMouseClicked_Bool(c.ImGuiMouseButton_Middle, false)) s.pan_x = mouse.x;
        if (c.igIsMouseClicked_Bool(c.ImGuiMouseButton_Right, false)) app.beginFineScrub();
    }
    if (s.pan_x) |x| {
        if (c.igIsMouseDown_Nil(c.ImGuiMouseButton_Middle)) {
            s.window = s.window.dragged(mouse.x - x, w, n);
            s.pan_x = mouse.x;
        } else s.pan_x = null;
    }
    const axis: Axis = .{ .window = s.window, .x0 = p0.x, .width = w };

    // Marks of edited frames are at the top of the axis.
    const mark_size = markSize();
    const in_marks = mouse.y >= axis_top and mouse.y <= axis_top + 2.5 * mark_size;
    const pointed: ?Mark = if (in_marks) markAt(marks, mouse.x, mark_size + 2, axis) else null;
    if (active and n > 0) {
        // Holding the button still isn't asking for the frame again (playback
        // may have moved on from it meanwhile).
        const i = if (pointed) |m| m.index else axis.frameAt(mouse.x);
        if (app.plot_drag == i) app.moveTo(i) else app.setFrame(i);
        app.plot_drag = i;
    } else {
        app.plot_drag = null;
    }

    const light = app.style.theme == .light;
    const accent = lineColor(app);
    const label_col = c.igGetColorU32_Col(c.ImGuiCol_TextDisabled, 1);
    const scanned = d.stream.energiesScanned();
    const cols: usize = @intFromFloat(@max(w, 2));
    const env = &s.plot_env;
    env.update(app.gpa, .{ .values = scanned, .document = app.documents_opened, .n = n, .window = s.window, .cols = cols }, d.stream);
    const unit = d.format.energyUnit();
    const head = playhead(app, d);
    const lanes_top = if (app.data.show_energy) p0.y + h else p0.y;
    for (0..app.data.lanes.items.len) |i| lanes.draw(app, dl, i, axis, lanes_top + h * @as(f32, @floatFromInt(i)), h, head);
    if (!app.data.show_energy) {
        if (app.data.lanes.items.len == 0) c.ImDrawList_AddText_Vec2(dl, ui.v2(p0.x + 6, p0.y + 3), label_col, "nothing shown (see Data)", null);
    } else if (s.scale()) |scale| {
        valueAxis(dl, scale, axis, p0.y, h);
        c.ImDrawList_PushClipRect(dl, ui.v2(p0.x - inset, p0.y), ui.v2(p1.x + inset, p0.y + h), true);
        curve(dl, d, env, scale, axis, p0.y, h, 4, accent);
        c.ImDrawList_PopClipRect(dl);
        var buf: [64]u8 = undefined;
        const of = if (s.fitted != null) "  fitted" else "";
        // The energy at the playhead is the file's; an edited frame has none.
        const stale = if (app.session.isEdited(d.current)) "  stale: this frame is edited" else "";
        const label = (if (unit) |u| ui.printZ(&buf, "E ({s}){s}{s}", .{ u, of, stale }) else ui.printZ(&buf, "E{s}{s}", .{ of, stale })) catch "";
        ui.valueBox("##energy", p1.x - 4, p0.y + 2, d.stream.energy(d.current));
        ui.plotLabel(dl, p0.x + 6, p0.y + 3, label_col, label);
    } else {
        const msg: [:0]const u8 = if (scanned < n) "scanning energies..." else "no energies in this file";
        c.ImDrawList_AddText_Vec2(dl, ui.v2(p0.x + 6, p0.y + 3), label_col, msg.ptr, null);
    }

    // Diff reference marker and playhead.
    if (n > 1) {
        if (app.diff) |df| if (s.window.contains(df.reference.index)) {
            const x = axis.x(df.reference.index);
            const rc = App.reference_color;
            c.ImDrawList_AddLine(dl, ui.v2(x, p0.y), ui.v2(x, p1.y), ui.rgba(rc[0], rc[1], rc[2], 1), 2, 0);
            const label_w = c.igCalcTextSize("ref", null, false, -1).x;
            const label_x = if (x + label_w + 8 > p1.x) x - label_w - 4 else x + 4;
            c.ImDrawList_AddText_Vec2(dl, ui.v2(label_x, outer0.y + view_h - fs - 2), c.igGetColorU32_Col(c.ImGuiCol_Text, 1), "ref", null);
        };
        if (s.window.containsAt(head)) {
            const x = s.window.toX(head, axis.x0, axis.width);
            c.ImDrawList_AddLine(dl, ui.v2(x, p0.y), ui.v2(x, p1.y), headColor(app, light), 2, 0);
        }
    }
    c.igEndChild();

    ticks(outer_dl, axis, n, axis_top + 2.5 * mark_size, label_col);
    const mark_col = c.igGetColorU32_Col(c.ImGuiCol_Text, 1);
    for (marks) |m| {
        if (!s.window.contains(m.index)) continue;
        const x = axis.x(m.index);
        const base = axis_top + 2.2 * mark_size;
        const top = ui.v2(x, base - 2 * mark_size);
        const base_l = ui.v2(x - mark_size, base);
        const base_r = ui.v2(x + mark_size, base);
        // Hollow once saved.
        if (m.unsaved) {
            c.ImDrawList_AddTriangleFilled(outer_dl, top, base_l, base_r, mark_col);
        } else c.ImDrawList_AddTriangle(outer_dl, top, base_l, base_r, mark_col, 1.5, 0);
    }
    // On to what is below, wherever the items above left off.
    c.igSetCursorScreenPos(ui.v2(outer0.x, outer1.y + c.igGetStyle().*.ItemSpacing.y));
    if (hovered and n > 0 and s.pan_x == null) {
        // Scrubbing finely, the mouse stays and the playhead moves.
        const i = if (app.fine_scrub != null) d.current else if (pointed) |m| m.index else axis.frameAt(mouse.x);
        if (c.igBeginTooltip()) {
            if (d.stream.energy(i)) |e| ui.text("frame {d}: E = {d:.8} {s}", .{ i + 1, e, unit orelse "" }) else ui.text("frame {d}", .{i + 1});
            for (app.data.lanes.items) |lane| {
                const name = lane.source.table.columns[lane.column].name;
                if (lanes.valueAt(app, lane, @floatFromInt(i))) |v| ui.text("{s} = {d:.8}", .{ name, v }) else ui.text("{s} = -", .{name});
            }
            for (marks) |m| if (m.index == i) ui.text("{s}", .{if (m.unsaved) "edited, not saved" else "edited, saved"});
            c.igEndTooltip();
        }
    }
}

fn lineColor(app: *const App) u32 {
    return if (app.style.theme == .light) ui.rgba(0.12, 0.35, 0.80, 0.95) else ui.rgba(0.45, 0.75, 1.0, 0.9);
}

/// In a diff, the colour of the current frame.
fn headColor(app: *const App, light: bool) u32 {
    const cc = App.current_color;
    if (app.diff != null) return ui.rgba(cc[0], cc[1], cc[2], 1);
    return if (light) ui.rgba(0.85, 0.45, 0.0, 1) else ui.rgba(1, 0.85, 0.3, 1);
}

/// Steps: each frame's value until the next frame, as it is read. With more
/// frames than pixel columns, a min/max envelope per column.
fn curve(dl: *c.ImDrawList, d: *App.Document, env: *const Envelope, scale: Scale, axis: Axis, top: f32, h: f32, pad: f32, col: u32) void {
    const range = axis.window.frames(d.frameCount());
    if (range[1] - range[0] <= env.min.len) {
        // Where the last step ended.
        var prev_y: ?f32 = null;
        for (range[0]..range[1]) |i| {
            const e = d.stream.energy(i) orelse {
                prev_y = null;
                continue;
            };
            const x = axis.x(i);
            const y = yOf(e, scale, top, h, pad);
            if (prev_y) |p| c.ImDrawList_AddLine(dl, ui.v2(x, p), ui.v2(x, y), col, 1, 0);
            if (i + 1 < d.frameCount()) c.ImDrawList_AddLine(dl, ui.v2(x, y), ui.v2(axis.x(i + 1), y), col, 1, 0);
            // Single frames, once there is room for them.
            if (axis.window.span() * 8 < axis.width) c.ImDrawList_AddCircleFilled(dl, ui.v2(x, y), 2, col, 0);
            prev_y = y;
        }
        return;
    }
    // Top and bottom of the column before.
    var prev: ?[2]f32 = null;
    for (env.min, env.max, 0..) |lo, hi, k| {
        if (lo > hi) {
            prev = null;
            continue;
        }
        const x = axis.x0 + @as(f32, @floatFromInt(k)) + 0.5;
        const ya = yOf(hi, scale, top, h, pad);
        const yb = yOf(lo, scale, top, h, pad);
        // Up or down to where the column before ended, so that there are no gaps.
        const from = if (prev) |p| @min(ya, p[1]) else ya;
        const to = if (prev) |p| @max(yb, p[0]) else yb;
        c.ImDrawList_AddLine(dl, ui.v2(x, from), ui.v2(x, to + 1), col, 1, 0);
        prev = .{ ya, yb };
    }
}

pub fn yOf(e: f64, scale: Scale, top: f32, h: f32, pad: f32) f32 {
    return top + pad + (1 - scale.height(e)) * (h - 2 * pad);
}

/// Frame numbers (1-based) at round places.
fn ticks(dl: *c.ImDrawList, axis: Axis, n: usize, y: f32, col: u32) void {
    if (n == 0) return;
    const fs = c.igGetFontSize();
    var buf: [32]u8 = undefined;
    const widest = ui.printZ(&buf, "{d}", .{n}) catch return;
    const room = c.igCalcTextSize(widest.ptr, null, false, -1).x + 2 * fs;
    const step = cv.window.tickStep(axis.window.span() * room / axis.width);
    const first: u64 = @intFromFloat(@ceil(axis.window.lo) + 1);
    var number = @max((first + step - 1) / step * step, 1);
    while (number <= n) : (number += step) {
        const i: usize = @intCast(number - 1);
        if (!axis.window.contains(i)) break;
        const x = axis.x(i);
        c.ImDrawList_AddLine(dl, ui.v2(x, y), ui.v2(x, y + fs * 0.25), col, 1, 0);
        const label = ui.printZ(&buf, "{d}", .{number}) catch return;
        const lw = c.igCalcTextSize(label.ptr, null, false, -1).x;
        const lx = std.math.clamp(x - lw / 2, axis.x0, @max(axis.x0 + axis.width - lw, axis.x0));
        c.ImDrawList_AddText_Vec2(dl, ui.v2(lx, y + fs * 0.2), col, label.ptr, null);
    }
}

/// The whole trajectory with the window in it, and the zoom controls.
fn strip(app: *App, d: *App.Document) void {
    const s = &app.timeline;
    const n = d.frameCount();
    const fs = c.igGetFontSize();
    const style = c.igGetStyle();
    c.igBeginDisabled(!Window.canZoom(n));
    defer c.igEndDisabled();
    const slider_w = fs * 9;
    const inset = fs * 0.4;
    const outer0 = c.igGetCursorScreenPos();
    const fit_w = c.igCalcTextSize("Reset scales", null, false, -1).x + 2 * style.*.FramePadding.x;
    const outer_w = @max(c.igGetContentRegionAvail().x - slider_w - fit_w - 2 * style.*.ItemSpacing.x, fs * 4);
    const h = c.igGetFrameHeight();
    const outer1 = ui.v2(outer0.x + outer_w, outer0.y + h);
    _ = c.igInvisibleButton("##strip", ui.v2(outer_w, h), 0);
    const hovered = c.igIsItemHovered(0);
    const mouse = c.igGetMousePos();
    const whole: Axis = .{ .window = .all(n), .x0 = outer0.x + inset, .width = @max(outer_w - 2 * inset, 1) };
    // At least wide enough to see and grab.
    var x_lo = whole.window.toX(s.window.lo, whole.x0, whole.width);
    var x_hi = whole.window.toX(s.window.hi, whole.x0, whole.width);
    const missing = 6 - (x_hi - x_lo);
    if (missing > 0) {
        x_lo -= missing / 2;
        x_hi += missing / 2;
    }
    const reach = fs * 0.4;
    const part: ?State.Part = if (@abs(mouse.x - x_lo) <= reach and mouse.x < x_lo + 2)
        .lo
    else if (@abs(mouse.x - x_hi) <= reach and mouse.x > x_hi - 2)
        .hi
    else if (mouse.x > x_lo and mouse.x < x_hi)
        .window
    else
        null;
    if (hovered) {
        s.hovered = true;
        wheel(s, whole, n);
        if (part == .lo or part == .hi) c.igSetMouseCursor(c.ImGuiMouseCursor_ResizeEW);
        if (c.igIsItemActivated()) {
            // Beside the window, it comes to the mouse.
            if (part == null) {
                s.window = s.window.centred(whole.window.fromX(mouse.x, whole.x0, whole.width), n);
            }
            const grabbed = part orelse .window;
            // Where that really is: it is drawn wider if it is narrow.
            const edge_x = whole.window.toX(if (grabbed == .hi) s.window.hi else s.window.lo, whole.x0, whole.width);
            s.grab = .{ .part = grabbed, .x = mouse.x, .off = mouse.x - edge_x };
        }
    }
    if (s.grab) |*g| {
        if (!c.igIsItemActive()) {
            s.grab = null;
        } else if (mouse.x != g.x) {
            const at = whole.window.fromX(mouse.x - g.off, whole.x0, whole.width);
            s.window = switch (g.part) {
                .lo => s.window.withLo(at, n),
                .hi => s.window.withHi(at, n),
                .window => s.window.panned(at - s.window.lo, n),
            };
            g.x = mouse.x;
        }
    }

    const dl = c.igGetWindowDrawList();
    const light = app.style.theme == .light;
    c.ImDrawList_AddRectFilled(dl, outer0, outer1, c.igGetColorU32_Col(c.ImGuiCol_FrameBg, 1), 3, 0);
    c.ImDrawList_PushClipRect(dl, outer0, outer1, true);
    const env = &s.strip_env;
    env.update(app.gpa, .{ .values = d.stream.energiesScanned(), .document = app.documents_opened, .n = n, .window = whole.window, .cols = @intFromFloat(@max(whole.width, 2)) }, d.stream);
    if (env.scale()) |scale| curve(dl, d, env, scale, whole, outer0.y, h, 3, lineColor(app));
    const cover = c.igGetColorU32_Col(c.ImGuiCol_WindowBg, 0.65);
    c.ImDrawList_AddRectFilled(dl, outer0, ui.v2(x_lo, outer1.y), cover, 0, 0);
    c.ImDrawList_AddRectFilled(dl, ui.v2(x_hi, outer0.y), outer1, cover, 0, 0);
    if (n > 1) {
        const x = whole.x(d.current);
        c.ImDrawList_AddLine(dl, ui.v2(x, outer0.y), ui.v2(x, outer1.y), headColor(app, light), 2, 0);
    }
    const edge = c.igGetColorU32_Col(c.ImGuiCol_Text, 0.8);
    c.ImDrawList_AddRect(dl, ui.v2(x_lo, outer0.y + 1), ui.v2(x_hi, outer1.y - 1), edge, 2, 1, 0);
    // Handles, to be seen as such.
    for ([_]f32{ x_lo, x_hi }) |x| c.ImDrawList_AddLine(dl, ui.v2(x, outer0.y + h * 0.25), ui.v2(x, outer0.y + h * 0.75), edge, 3, 0);
    c.ImDrawList_PopClipRect(dl);
    if (hovered and s.grab == null) ui.tooltip("The whole trajectory. Drag the box to pan, its ends to zoom.");

    c.igSameLine(0, -1);
    c.igSetNextItemWidth(slider_w);
    var level: f32 = @floatCast(s.window.zoomLevel(n));
    if (c.igSliderFloat("##zoom", &level, 0, 1, "zoom", c.ImGuiSliderFlags_NoInput)) {
        // Around the playhead if it is in view.
        const current: f64 = @floatFromInt(d.current);
        const at = if (s.window.contains(d.current)) current else s.window.middle();
        s.window = s.window.atLevel(level, at, n);
    }
    ui.tooltip("Zoom in around the playhead, or the middle if it is out of view.");
    c.igSameLine(0, -1);
    if (!isFitted(app)) {
        if (c.igButton("Fit scales##scale", ui.v2(fit_w, 0))) {
            s.fitted = s.plot_env.scale();
            for (app.data.lanes.items) |*l| l.fitted = lanes.scaleInView(app, l.*);
        }
        ui.tooltip("Fit every plot's scale to what is in view now. They stay so until you reset them.");
    } else {
        if (c.igButton("Reset scales##scale", ui.v2(fit_w, 0))) resetScales(app);
        ui.tooltip("Back to the scales of the whole trajectory.");
    }
}
