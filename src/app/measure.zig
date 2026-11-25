//! Atom selection UI: the measurement bar (distance / angle / dihedral with
//! editable values) and the viewport overlay (selection numbers and lines).
const std = @import("std");
const c = @import("c");
const cv = @import("chemviewer");
const ui = @import("ui.zig");
const App = @import("App.zig");
const drag = @import("drag.zig");
const messages = @import("messages.zig");
const plot = @import("plot.zig");
const geom = cv.geometry;
const occlusion = @import("occlusion.zig");

/// "C12" style label (1-based index, as in most QM programs).
fn atomLabel(buf: []u8, numbers: []const u8, i: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ cv.elements.symbol(numbers[i]), i + 1 }) catch "?";
}

fn joinedLabels(buf: []u8, numbers: []const u8, sel: []const u32) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (sel, 0..) |i, k| {
        if (k > 0) w.writeAll("-") catch {};
        var lb: [16]u8 = undefined;
        w.writeAll(atomLabel(&lb, numbers, i)) catch {};
    }
    return w.buffered();
}

/// What the field being edited (there is only one) held when it was clicked.
var clicked_text: [64]u8 = undefined;
var clicked_len: usize = 0;

/// An editable number: applies on Enter. Returns the new value if one was
/// typed. The text is as it was when clicked, so an untouched one is rounded,
/// and during playback old: Enter doesn't apply it.
fn valueField(id: [:0]const u8, value: f64, comptime fmt: []const u8, width: f32) ?f64 {
    var buf: [64]u8 = undefined;
    const shown = ui.printZ(&buf, fmt, .{value}) catch return null;
    var before: [64]u8 = undefined;
    @memcpy(before[0..shown.len], shown);
    const shown_len = shown.len;
    c.igSetNextItemWidth(width);
    const flags = c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CharsScientific | c.ImGuiInputTextFlags_AutoSelectAll;
    const entered = c.igInputText(id.ptr, &buf, buf.len, flags, null, null);
    if (c.igIsItemActivated()) {
        clicked_text = before;
        clicked_len = shown_len;
    }
    if (!entered) return null;
    return typedValue(clicked_text[0..clicked_len], std.mem.sliceTo(&buf, 0));
}

/// The number in `text`, or null if it isn't one or is still what it was.
fn typedValue(before: []const u8, text: []const u8) ?f64 {
    if (std.mem.eql(u8, before, text)) return null;
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " ")) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

test "only a number that was typed is applied" {
    const Case = struct { []const u8, []const u8, ?f64 };
    for ([_]Case{
        .{ "1.54000", "1.54000", null },
        .{ "1.54000", "1.54", 1.54 }, // exactly that, not what was rounded to it
        .{ "1.54000", " 2 ", 2 },
        .{ "1.54000", "1.", 1 },
        .{ "109.500", "-1e2", -100 },
        .{ "109.500", "+90", 90 },
        .{ "109.500", "", null },
        .{ "109.500", "1.2.3", null },
        .{ "109.500", "2*3", null },
        .{ "109.500", "1e999", null },
    }) |case| try std.testing.expectEqual(case[2], typedValue(case[0], case[1]));
}

fn modeSelector(app: *App, last_label: []const u8) void {
    c.igSameLine(0, c.igGetFontSize() * 1.5);
    c.igAlignTextToFramePadding();
    ui.textDisabled("typing a value moves", .{});
    c.igSameLine(0, -1);
    var mode: c_int = @backingInt(app.edit_mode);
    _ = c.igRadioButton_IntPtr("both sides", &mode, @backingInt(geom.Mode.both));
    c.igSameLine(0, -1);
    var buf: [48]u8 = undefined;
    const lbl = ui.printZ(&buf, "{s} side", .{last_label}) catch "last side";
    _ = c.igRadioButton_IntPtr(lbl.ptr, &mode, @backingInt(geom.Mode.last));
    app.edit_mode = @fromBackingInt(@intCast(mode));
    ui.tooltip("Everything bonded to the moved atom, through the bonds that are drawn, moves with it (adjust with \"Hide weaker\" / \"Longest bond\"). Inside rings only the atom itself moves.");
}

/// One row: what is selected and its measurement, editable.
pub fn bar(app: *App) void {
    const sel = app.selected();
    const fs = c.igGetFontSize();
    c.igAlignTextToFramePadding();
    // The room differs between selections.
    if (hinted_len != sel.len) {
        short_hint = null;
        cramped_message = null;
        cramped_hint = null;
    }
    hinted_len = sel.len;
    row_width = c.igGetContentRegionAvail().x;
    if (app.messages.current(app.seconds())) |m| {
        // Not under the mouse, or while a value is typed.
        const in_use = c.igIsAnyItemActive() or c.igIsWindowHovered(0);
        if (cramped_message == m.at and !in_use) {
            messageText(app, m);
            if (app.doc) |d| if (d.display.real.frame) |f| gestureHint(app, f.numbers, false);
            return;
        }
    }
    const d = app.doc orelse {
        ui.textDisabled("No file open", .{});
        _ = messageAfterRow(app);
        return;
    };
    const f = d.display.real.frame orelse {
        ui.textDisabled("loading...", .{});
        _ = messageAfterRow(app);
        return;
    };
    var hint_buf: [160]u8 = undefined;
    if (app.dragHint(&hint_buf)) |hint| {
        ui.text("{s}", .{hint});
        rowTail(app, f.numbers);
        return;
    }
    if (app.savingHint(&hint_buf)) |hint| {
        ui.text("{s}", .{hint});
        rowTail(app, f.numbers);
        return;
    }
    if (hintReplacesRow()) return gestureHint(app, f.numbers, true);
    if (mouseHintReplacesRow(app)) |hint| return ui.textDisabled("{s}", .{hint});
    if (sel.len == 0) {
        ui.textDisabled("Click atoms to select; Ctrl+drag: lasso; Ctrl+A: molecule, then all.", .{});
        rowTail(app, f.numbers);
        return;
    }
    if (sel.len > 4) {
        ui.text("{d} atoms selected", .{sel.len});
        c.igSameLine(0, fs);
        ui.textDisabled("Ctrl+C copies them as XYZ", .{});
        c.igSameLine(0, fs * 1.5);
        const clear = c.igSmallButton("Clear");
        rowTail(app, f.numbers);
        if (clear) app.deselect();
        return;
    }
    var lb: [128]u8 = undefined;
    const labels = joinedLabels(&lb, f.numbers, sel);
    const p = app.drawnPositions() orelse return;
    const value = app.measured();
    // Applied last: an edit replaces the frame and may change the selection.
    var submitted: ?App.Edit = null;
    switch (sel.len) {
        1 => {
            const v = p[sel[0]];
            ui.text("{s}   x {d:.5}   y {d:.5}   z {d:.5} Å", .{ labels, v[0], v[1], v[2] });
        },
        2 => {
            ui.text("Distance {s}", .{labels});
            c.igSameLine(0, -1);
            if (valueField("##dist", value.?.distance, "{d:.5}", fs * 7)) |v| submitted = .{ .distance = v };
            c.igSameLine(0, 4);
            ui.text("Å", .{});
            if (app.bondCharacter(sel[0], sel[1])) |ch| {
                c.igSameLine(0, fs);
                ui.textDisabled("bond character {d:.2}", .{ch});
            }
            var l2: [16]u8 = undefined;
            modeSelector(app, atomLabel(&l2, f.numbers, sel[1]));
        },
        3 => {
            ui.text("Angle {s}", .{labels});
            c.igSameLine(0, -1);
            if (angleFields("ang", value.?.angle)) |v| submitted = .{ .angle = v };
            var l2: [16]u8 = undefined;
            modeSelector(app, atomLabel(&l2, f.numbers, sel[2]));
        },
        else => {
            ui.text("Dihedral {s}", .{labels});
            c.igSameLine(0, -1);
            if (angleFields("dih", value.?.dihedral)) |v| submitted = .{ .dihedral = v };
            var l2: [16]u8 = undefined;
            modeSelector(app, atomLabel(&l2, f.numbers, sel[2]));
        },
    }
    c.igSameLine(0, fs * 1.5);
    const clear = c.igSmallButton("Clear");
    rowTail(app, f.numbers);
    if (clear) app.deselect();
    if (submitted) |edit| app.applyEdit(edit);
}

/// The end of the row: a message while there is one, and what the mouse can do
/// here.
fn rowTail(app: *App, numbers: []const u8) void {
    _ = messageAfterRow(app);
    if (mouseHint(app)) |hint| {
        short_hint = null;
        c.igSameLine(0, c.igGetFontSize() * 1.5);
        c.igAlignTextToFramePadding();
        const fits = c.igGetContentRegionAvail().x >= c.igCalcTextSize(hint.ptr, null, false, -1).x;
        // With a message in the row it isn't known whether it would fit.
        if (app.messages.current(app.seconds()) == null) cramped_hint = if (fits) null else .{ .text = hint, .width = row_width };
        ui.textDisabled("{s}", .{hint});
        return;
    }
    gestureHint(app, numbers, false);
}

/// The mouse hint that didn't fit after the row, and how wide that was.
var cramped_hint: ?struct { text: [:0]const u8, width: f32 } = null;

/// The mouse hint, if it takes the row's place: there was no room for it, and
/// nothing else in the row is wanted. Dragging on the timeline keeps it up.
fn mouseHintReplacesRow(app: *const App) ?[:0]const u8 {
    const cramped = cramped_hint orelse return null;
    if (cramped.width != c.igGetContentRegionAvail().x) return null;
    if (app.messages.current(app.seconds()) != null) return null;
    const on_timeline = app.plot_drag != null or app.timeline.grab != null;
    if (c.igIsAnyItemActive() and !on_timeline) return null;
    const hint = mouseHint(app) orelse return null;
    return if (hint.ptr == cramped.text.ptr) hint else null;
}

/// What the mouse can do on the timeline it is on, or what a double-click on
/// the bond under it does. With Alt held, bonds aren't used.
fn mouseHint(app: *const App) ?[:0]const u8 {
    if (app.timeline.hovered) return plot.hint;
    if ((c.SDL_GetModState() & c.SDL_KMOD_ALT) != 0) return null;
    return switch (app.hover orelse return null) {
        .atom => null,
        .bond => |pair| if (app.isCut(pair[0], pair[1])) "Double-click: restore bond" else "Double-click: cut bond",
    };
}

/// The message that didn't fit after the row (when it was given).
var cramped_message: ?f64 = null;

/// Whether there was one. If it doesn't fit, it takes the row's place next.
fn messageAfterRow(app: *App) bool {
    const m = app.messages.current(app.seconds()) orelse return false;
    // Where the short hint would be isn't known now.
    short_hint = null;
    c.igSameLine(0, c.igGetFontSize() * 1.5);
    c.igAlignTextToFramePadding();
    const text = m.text();
    const mark: f32 = if (m.kind == .info) 0 else c.igGetFontSize() * 1.4;
    const width = mark + c.igCalcTextSize(text.ptr, text.ptr + text.len, false, -1).x;
    if (c.igGetContentRegionAvail().x < width) cramped_message = m.at;
    messageText(app, m);
    return true;
}

/// Problems have a mark, not only a colour.
fn messageText(app: *App, m: *const messages.Message) void {
    const fs = c.igGetFontSize();
    c.igPushStyleVar_Float(c.ImGuiStyleVar_Alpha, @max(m.opacity(app.seconds()), 0.01));
    defer c.igPopStyleVar(1);
    if (m.kind != .info) {
        const light = app.style.theme == .light;
        const col = if (m.kind == .refusal)
            (if (light) ui.rgba(0.60, 0.36, 0.0, 1) else ui.rgba(1.0, 0.75, 0.25, 1))
        else
            (if (light) ui.rgba(0.75, 0.10, 0.10, 1) else ui.rgba(1.0, 0.50, 0.45, 1));
        const p = c.igGetCursorScreenPos();
        const at = ui.v2(p.x + fs * 0.5, p.y + c.igGetFrameHeight() / 2);
        const dl = c.igGetWindowDrawList();
        c.ImDrawList_AddCircleFilled(dl, at, fs * 0.5, col, 0);
        const sign: [:0]const u8 = if (m.kind == .failure) "x" else "!";
        const size = c.igCalcTextSize(sign.ptr, null, false, -1);
        c.ImDrawList_AddText_Vec2(dl, ui.v2(at.x - size.x / 2, at.y - size.y / 2), if (light) ui.rgba(1, 1, 1, 1) else ui.rgba(0, 0, 0, 1), sign.ptr, null);
        c.igDummy(ui.v2(fs, c.igGetFrameHeight()));
        c.igSameLine(0, fs * 0.4);
        c.igAlignTextToFramePadding();
    }
    ui.text("{s}", .{m.text()});
}

/// What a click or Alt-drag would act on, outlined over the 3D view.
pub fn hoverOutline(app: *App) void {
    const hover = app.hover orelse return;
    const pos = app.drawnPositions() orelse return;
    const f = app.doc.?.display.real.frame.?;
    const proj = app.screenProjector();
    const ac = app.style.theme.accent();
    const col = ui.rgba(ac[0], ac[1], ac[2], 0.6);
    const alt = (c.SDL_GetModState() & c.SDL_KMOD_ALT) != 0;
    switch (hover) {
        .atom => |a| {
            if (!alt) return atomCircle(app, proj, pos[a], f.numbers[a], col);
            const group = app.hoverGroup();
            // Beyond this it is a blur, and slow.
            for (group[0..@min(group.len, 2000)]) |i| {
                if (i < pos.len) atomCircle(app, proj, pos[i], f.numbers[i], col);
            }
        },
        .bond => |pair| {
            if (alt) return; // only atoms are dragged
            const a = pos[pair[0]];
            const b = pos[pair[1]];
            const eye = app.camera.ray(0, 0, 1).origin;
            const axis = cv.math.normalize(b - a);
            const side = cv.math.cross(axis, eye - a);
            if (cv.math.length2(side) < 1e-8) return;
            const out = cv.math.normalize(side) * cv.math.splat(app.style.bondRadius() * 1.15);
            const from = a + axis * cv.math.splat(app.style.atomRadius(f.numbers[pair[0]]) * 0.95);
            const to = b - axis * cv.math.splat(app.style.atomRadius(f.numbers[pair[1]]) * 0.95);
            if (cv.math.dot(to - from, axis) <= 0) return;
            var pts: [4]c.ImVec2_c = undefined;
            for ([_]cv.math.Vec3{ from + out, to + out, to - out, from - out }, &pts) |p, *q| q.* = proj.toScreen(p) orelse return;
            c.ImDrawList_AddPolyline(c.igGetBackgroundDrawList_Nil(), &pts, pts.len, col, 2, c.ImDrawFlags_Closed);
        },
    }
}

fn atomCircle(app: *App, proj: App.ScreenProjector, p: cv.math.Vec3, z: u8, col: u32) void {
    const eye = app.camera.ray(0, 0, 1).origin;
    const depth = cv.math.dot(eye - p, app.cameraAxes()[2]);
    const at = proj.toScreen(p) orelse return;
    if (depth < 1e-3) return;
    const focal = (proj.h / 2) / @tan(app.camera.fovy / 2);
    const r = app.style.atomRadius(z) * focal / depth;
    c.ImDrawList_AddCircle(c.igGetBackgroundDrawList_Nil(), at, r + 2, col, 0, 2, 0);
}

/// Where the hint was drawn shortened (null = it fitted), and for how many
/// selected atoms.
var short_hint: ?[2]c.ImVec2_c = null;
var hinted_len: usize = 0;
/// How wide the whole row is.
var row_width: f32 = 0;

/// Whether the hint takes the row's place: it had no room after it, and Alt
/// is held or the mouse is on its short form. Not while a value is typed or
/// a button pressed.
fn hintReplacesRow() bool {
    const at = short_hint orelse return false;
    if (c.igIsAnyItemActive()) return false;
    if ((c.SDL_GetModState() & c.SDL_KMOD_ALT) != 0) return true;
    return c.igIsWindowHovered(0) and c.igIsMouseHoveringRect(at[0], at[1], true);
}

/// What an Alt-drag does with this selection, after the rest of the row (or
/// `alone` on it): brighter while Alt is held, with the gesture going on
/// marked. Shortened if there is no room.
fn gestureHint(app: *App, numbers: []const u8, alone: bool) void {
    // The next frame has the same room; keep where the mouse is expected.
    if (!alone) short_hint = null;
    const sel = app.selected();
    var base_buf: [16]u8 = undefined;
    var about_buf: [48]u8 = undefined;
    const Piece = struct { kind: drag.Kind, text: [:0]const u8 };
    var pieces: [3]Piece = undefined;
    var n: usize = 0;
    // The base itself takes everything connected with it.
    const grabbed: ?u32 = if (app.drag) |d| d.handle else if (app.hover) |h| switch (h) {
        .atom => |a| a,
        .bond => null,
    } else null;
    const on_base = sel.len == 1 and grabbed == sel[0];
    pieces[n] = .{ .kind = .translate, .text = switch (sel.len) {
        0 => "left: move molecule",
        1 => if (on_base) "left: move molecule" else "left: move branch",
        else => "left: move selection",
    } };
    n += 1;
    if (sel.len == 1 and !on_base) {
        pieces[n] = .{ .kind = .twist, .text = "right: twist branch" };
        n += 1;
    }
    pieces[n] = .{ .kind = .rotate, .text = switch (sel.len) {
        0 => "middle or Shift+left: rotate molecule",
        1 => ui.printZ(&about_buf, "middle or Shift+left: rotate about {s}", .{atomLabel(&base_buf, numbers, sel[0])}) catch return,
        else => "middle or Shift+left: rotate selection",
    } };
    n += 1;

    const mods = c.SDL_GetModState();
    const alt = (mods & c.SDL_KMOD_ALT) != 0;
    const shift = (mods & c.SDL_KMOD_SHIFT) != 0;
    const going_on: ?drag.Kind = if (app.drag) |d| d.kind else null;

    const fs = c.igGetFontSize();
    const gap = fs * 0.9;
    const lead: [:0]const u8 = "Alt + drag";
    var width = c.igCalcTextSize(lead.ptr, null, false, -1).x;
    for (pieces[0..n]) |p| width += gap + c.igCalcTextSize(p.text.ptr, null, false, -1).x;
    if (!alone) {
        c.igSameLine(0, fs * 1.5);
        c.igAlignTextToFramePadding();
        if (c.igGetContentRegionAvail().x < width) {
            const kind = going_on orelse {
                ui.textDisabled("Alt + drag (?)", .{});
                short_hint = .{ c.igGetItemRectMin(), c.igGetItemRectMax() };
                return;
            };
            // Just the gesture going on.
            for (pieces[0..n]) |p| if (p.kind == kind) markedText(app, p.text);
            return;
        }
    }
    if (alt) ui.text("{s}", .{lead}) else ui.textDisabled("{s}", .{lead});
    for (pieces[0..n]) |p| {
        c.igSameLine(0, gap);
        if (going_on == p.kind) {
            markedText(app, p.text);
        } else if (going_on == null and alt and (!shift or p.kind == .rotate)) {
            ui.text("{s}", .{p.text});
        } else {
            ui.textDisabled("{s}", .{p.text});
        }
    }
}

/// Text with a muted tint of the accent behind it.
fn markedText(app: *const App, text: [:0]const u8) void {
    const ac = app.style.theme.accent();
    const at = c.igGetCursorScreenPos();
    const size = c.igCalcTextSize(text.ptr, null, false, -1);
    const y = at.y + c.igGetStyle().*.FramePadding.y;
    c.ImDrawList_AddRectFilled(c.igGetWindowDrawList(), ui.v2(at.x - 4, y - 1), ui.v2(at.x + size.x + 4, y + size.y + 1), ui.rgba(ac[0], ac[1], ac[2], 0.22), 3, 0);
    ui.text("{s}", .{text});
}

/// Degree and radian fields for the same angle; either can be edited. Returns
/// the new value in radians if submitted.
fn angleFields(comptime id: []const u8, rad: f64) ?f64 {
    const fs = c.igGetFontSize();
    const deg = std.math.radiansToDegrees(rad);
    var submitted: ?f64 = null;
    if (valueField("##" ++ id ++ "deg", deg, "{d:.3}", fs * 6.5)) |v| submitted = std.math.degreesToRadians(v);
    c.igSameLine(0, 4);
    ui.text("°", .{});
    c.igSameLine(0, fs);
    if (valueField("##" ++ id ++ "rad", rad, "{d:.6}", fs * 6.5)) |v| submitted = v;
    c.igSameLine(0, 4);
    ui.text("rad", .{});
    return submitted;
}

/// Selection numbers next to atoms and lines joining them, drawn over the
/// 3D view (under the UI windows).
pub fn overlay(app: *App) void {
    const sel = app.selected();
    // Rings come from the renderer; numbers and the path only make sense for measurements.
    if (sel.len == 0 or sel.len > 4) return;
    const pos = app.drawnPositions() orelse return;
    const proj = app.screenProjector();
    const dl = c.igGetBackgroundDrawList_Nil();
    const ac = app.style.theme.accent();
    const oa = app.style.theme.onAccent();
    const col = ui.rgba(ac[0], ac[1], ac[2], 1);
    const fs = c.igGetFontSize();
    var prev: ?c.ImVec2_c = null;
    for (sel) |i| {
        const s = proj.toScreen(pos[i]) orelse {
            prev = null;
            continue;
        };
        if (prev) |pv| dashedLine(dl, pv, s, col, 1.5 * proj.scale);
        prev = s;
    }
    for (sel, 0..) |i, k| {
        const s = proj.toScreen(pos[i]) orelse continue;
        var buf: [8]u8 = undefined;
        const t = ui.printZ(&buf, "{d}", .{k + 1}) catch continue;
        const at = ui.v2(s.x + fs * 0.6, s.y - fs * 1.4);
        c.ImDrawList_AddCircleFilled(dl, ui.v2(at.x + fs * 0.3, at.y + fs * 0.5), fs * 0.7, col, 0);
        c.ImDrawList_AddText_Vec2(dl, at, ui.rgba(oa[0], oa[1], oa[2], 1), t.ptr, null);
    }
}

/// Labels drawn over atoms:
/// - 1-based atom numbers on every atom (View > Atom numbers, N);
/// - element symbols on atoms whose colour could be mistaken for another
///   element present (View > Element labels; `cv.elements.ambiguousElements`).
/// With both, a labelled atom reads "Pd12". Labels are hidden by spheres in
/// front of them: five sample points per label are tested against nearer
/// spheres, and the visible fraction sets the label's opacity, so partly
/// covered labels fade instead of popping. Drawn back to front; skipped
/// above 5000 labels.
pub fn atomLabels(app: *App) void {
    atomLabelsInner(app) catch {};
}

fn atomLabelsInner(app: *App) !void {
    const pos = app.drawnPositions() orelse return;
    const f = app.doc.?.display.real.frame.?;
    const numbers = app.show_atom_numbers;
    var ambiguous: [cv.elements.max_z + 1]bool = @splat(false);
    var any_ambiguous = false;
    if (app.show_element_labels) {
        var counts: [cv.elements.max_z + 1]u32 = @splat(0);
        for (f.numbers) |z| counts[@min(z, cv.elements.max_z)] += 1;
        ambiguous = cv.elements.ambiguousElements(&counts);
        for (ambiguous) |b| any_ambiguous = any_ambiguous or b;
    }
    if (!numbers and !any_ambiguous) return;
    const max_labels = 5000;
    const gpa = app.gpa;
    const proj = app.screenProjector();
    const axes = app.cameraAxes();
    const forward = -axes[2];
    const eye = app.camera.ray(0, 0, 1).origin;
    const focal = (proj.h / 2) / @tan(app.camera.fovy / 2);

    // Every atom's projected disc (also the occluders), indexed like `pos`.
    const discs = try gpa.alloc(occlusion.Disc, pos.len);
    defer gpa.free(discs);
    for (pos, f.numbers, discs) |p, z, *d| {
        const depth = cv.math.dot(p - eye, forward);
        const r = app.style.atomRadius(z);
        const q = proj.toScreen(p) orelse {
            d.* = .{ .x = -1e9, .y = -1e9, .rpx = 0, .z = depth, .r = r };
            continue;
        };
        d.* = .{ .x = q.x, .y = q.y, .rpx = if (depth > 1e-3) r * focal / depth else 0, .z = depth, .r = r };
    }
    var occ = try occlusion.Occluder.init(gpa, discs, focal, proj.w, proj.h);
    defer occ.deinit(gpa);

    const Label = struct { i: u32, depth: f32 };
    var labels: std.ArrayList(Label) = .empty;
    defer labels.deinit(gpa);
    for (discs, f.numbers, 0..) |d, z, i| {
        if (!numbers and !ambiguous[@min(z, cv.elements.max_z)]) continue;
        if (d.rpx <= 0 or d.x < 0 or d.y < 0 or d.x > proj.w or d.y > proj.h) continue;
        try labels.append(gpa, .{ .i = @intCast(i), .depth = d.z });
    }
    if (labels.items.len > max_labels) return;
    std.mem.sort(Label, labels.items, {}, struct {
        fn farFirst(_: void, a: Label, b: Label) bool {
            return a.depth > b.depth;
        }
    }.farFirst);

    const dl = c.igGetBackgroundDrawList_Nil();
    const light = app.style.theme == .light;
    for (labels.items) |l| {
        const d = discs[l.i];
        var buf: [16]u8 = undefined;
        const z = f.numbers[l.i];
        const sym = if (ambiguous[@min(z, cv.elements.max_z)]) cv.elements.symbol(z) else "";
        const t = (if (numbers)
            ui.printZ(&buf, "{s}{d}", .{ sym, l.i + 1 })
        else
            ui.printZ(&buf, "{s}", .{sym})) catch continue;
        const size = c.igCalcTextSize(t.ptr, null, false, -1);
        // Centre plus four points inside the label box.
        const hx = size.x * 0.35;
        const hy = size.y * 0.3;
        const samples = [_][2]f32{ .{ 0, 0 }, .{ -hx, -hy }, .{ hx, -hy }, .{ -hx, hy }, .{ hx, hy } };
        var visible: f32 = 0;
        for (samples) |o| {
            if (!occ.hidden(l.i, d.x + o[0], d.y + o[1])) visible += 1;
        }
        const alpha = visible / samples.len;
        if (alpha <= 0) continue;
        const fg = if (light) ui.rgba(0.05, 0.05, 0.08, alpha) else ui.rgba(1, 1, 1, alpha);
        const halo = if (light) ui.rgba(1, 1, 1, 0.85 * alpha) else ui.rgba(0, 0, 0, 0.85 * alpha);
        const at = ui.v2(d.x - size.x / 2, d.y - size.y / 2);
        // A 1-px halo keeps numbers readable on any atom colour.
        for ([_][2]f32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |o| {
            c.ImDrawList_AddText_Vec2(dl, ui.v2(at.x + o[0], at.y + o[1]), halo, t.ptr, null);
        }
        c.ImDrawList_AddText_Vec2(dl, at, fg, t.ptr, null);
    }
}

fn dashedLine(dl: *c.ImDrawList, a: c.ImVec2_c, b: c.ImVec2_c, col: u32, thickness: f32) void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    const dash: f32 = 6;
    var t: f32 = 0;
    while (t < len) : (t += dash * 2) {
        const t1 = @min(t + dash, len);
        c.ImDrawList_AddLine(dl, ui.v2(a.x + dx * t / len, a.y + dy * t / len), ui.v2(a.x + dx * t1 / len, a.y + dy * t1 / len), col, thickness, 0);
    }
}
