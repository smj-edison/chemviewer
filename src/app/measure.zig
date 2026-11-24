//! Atom selection UI: the measurement bar (distance / angle / dihedral with
//! editable values) and the viewport overlay (selection numbers and lines).
const std = @import("std");
const c = @import("c");
const cv = @import("chemviewer");
const ui = @import("ui.zig");
const App = @import("App.zig");
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

/// An editable number: applies on Enter. Returns the new value if submitted.
fn valueField(id: [:0]const u8, value: f64, fmt: [:0]const u8, width: f32) ?f64 {
    var v = value;
    c.igSetNextItemWidth(width);
    if (c.igInputDouble(id.ptr, &v, 0, 0, fmt.ptr, c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CharsScientific)) return v;
    return null;
}

fn modeSelector(app: *App, last_label: []const u8) void {
    c.igSameLine(0, c.igGetFontSize() * 1.5);
    c.igAlignTextToFramePadding();
    ui.textDisabled("move", .{});
    c.igSameLine(0, -1);
    var mode: c_int = @backingInt(app.edit_mode);
    _ = c.igRadioButton_IntPtr("both sides", &mode, @backingInt(geom.Mode.both));
    c.igSameLine(0, -1);
    var buf: [48]u8 = undefined;
    const lbl = ui.printZ(&buf, "{s} side", .{last_label}) catch "last side";
    _ = c.igRadioButton_IntPtr(lbl.ptr, &mode, @backingInt(geom.Mode.last));
    app.edit_mode = @fromBackingInt(@intCast(mode));
    ui.tooltip("Everything bonded to the moved atom, through the bonds that are drawn, moves with it (adjust with \"Hide below\" / \"Cut-off\"). Inside rings only the atom itself moves.");
}

/// One row: what is selected and its measurement, editable.
pub fn bar(app: *App) void {
    const d = app.doc orelse {
        c.igAlignTextToFramePadding();
        ui.textDisabled("No structure loaded", .{});
        return;
    };
    const f = d.shown orelse {
        c.igAlignTextToFramePadding();
        ui.textDisabled("loading...", .{});
        return;
    };
    const sel = app.selected();
    const fs = c.igGetFontSize();
    c.igAlignTextToFramePadding();
    var hint_buf: [160]u8 = undefined;
    if (app.dragHint(&hint_buf)) |hint| {
        ui.text("{s}", .{hint});
        return;
    }
    if (sel.len == 0) {
        ui.textDisabled("Click atoms to select; Ctrl+drag: lasso; Ctrl+A: molecule, then all. Alt+drag: move the selection, or a group around a single selected atom. Ctrl+C: copy XYZ.", .{});
        return;
    }
    if (sel.len > 4) {
        ui.text("{d} atoms selected", .{sel.len});
        c.igSameLine(0, fs);
        ui.textDisabled("Ctrl+C copies them as XYZ", .{});
        c.igSameLine(0, fs * 1.5);
        if (c.igSmallButton("Clear")) app.clearSelection();
        return;
    }
    var lb: [128]u8 = undefined;
    const labels = joinedLabels(&lb, f.numbers, sel);
    const p = f.positions;
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
            const dist = geom.distance(p, sel[0], sel[1]);
            if (valueField("##dist", dist, "%.5f", fs * 7)) |v| submitted = .{ .distance = v };
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
            const ang = geom.angle(p, sel[0], sel[1], sel[2]);
            if (angleFields("ang", ang)) |v| submitted = .{ .angle = v };
            var l2: [16]u8 = undefined;
            modeSelector(app, atomLabel(&l2, f.numbers, sel[2]));
        },
        else => {
            ui.text("Dihedral {s}", .{labels});
            c.igSameLine(0, -1);
            const dih = geom.dihedral(p, sel[0], sel[1], sel[2], sel[3]);
            if (angleFields("dih", dih)) |v| submitted = .{ .dihedral = v };
            var l2: [16]u8 = undefined;
            modeSelector(app, atomLabel(&l2, f.numbers, sel[2]));
        },
    }
    c.igSameLine(0, fs * 1.5);
    if (c.igSmallButton("Clear")) app.clearSelection();
    if (submitted) |edit| app.applyEdit(edit);
}

/// Degree and radian fields for the same angle; either can be edited. Returns
/// the new value in radians if submitted.
fn angleFields(comptime id: []const u8, rad: f64) ?f64 {
    const fs = c.igGetFontSize();
    const deg = std.math.radiansToDegrees(rad);
    var submitted: ?f64 = null;
    if (valueField("##" ++ id ++ "deg", deg, "%.3f", fs * 6.5)) |v| submitted = std.math.degreesToRadians(v);
    c.igSameLine(0, 4);
    ui.text("°", .{});
    c.igSameLine(0, fs);
    if (valueField("##" ++ id ++ "rad", rad, "%.6f", fs * 6.5)) |v| submitted = v;
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
    const pos = app.displayedPositions() orelse return;
    const proj = app.screenProjector();
    const dl = c.igGetBackgroundDrawList_Nil();
    const ac = app.style.theme.accent();
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
        c.ImDrawList_AddText_Vec2(dl, at, ui.rgba(1, 1, 1, 1), t.ptr, null);
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
    const pos = app.displayedPositions() orelse return;
    const f = app.doc.?.shown.?;
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
