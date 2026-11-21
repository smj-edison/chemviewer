//! Atom selection UI: the measurement bar (distance / angle / dihedral with
//! editable values) and the viewport overlay (selection numbers and lines).
const std = @import("std");
const c = @import("c");
const cv = @import("chemviewer");
const ui = @import("ui.zig");
const App = @import("App.zig");
const geom = cv.geometry;

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

/// Small -/+ nudge buttons. Shift = 10x step. Returns the signed delta.
fn nudge(id: [:0]const u8, step: f64) ?f64 {
    const big = (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0;
    const s = if (big) step * 10 else step;
    c.igPushID_Str(id.ptr);
    defer c.igPopID();
    var out: ?f64 = null;
    c.igSameLine(0, 2);
    if (c.igSmallButton("-")) out = -s;
    ui.tooltip("Decrease (Shift: 10x)");
    c.igSameLine(0, 2);
    if (c.igSmallButton("+")) out = s;
    ui.tooltip("Increase (Shift: 10x)");
    return out;
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
    if (sel.len == 0) {
        ui.textDisabled("Click atoms to select; Ctrl+drag: lasso (Ctrl+Shift: remove); Ctrl+A: molecule, then all. 2 = distance, 3 = angle, 4 = dihedral. Ctrl+C: copy XYZ.", .{});
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
    switch (sel.len) {
        1 => {
            const v = p[sel[0]];
            ui.text("{s}   x {d:.5}   y {d:.5}   z {d:.5} Å", .{ labels, v[0], v[1], v[2] });
        },
        2 => {
            ui.text("Distance {s}", .{labels});
            c.igSameLine(0, -1);
            const dist = geom.distance(p, sel[0], sel[1]);
            if (valueField("##dist", dist, "%.5f", fs * 7)) |v| app.applyEdit(.{ .distance = v });
            c.igSameLine(0, 4);
            ui.text("Å", .{});
            if (nudge("dist", 0.01)) |dv| app.applyEdit(.{ .distance = dist + dv });
            if (app.bondCharacter(sel[0], sel[1])) |ch| {
                c.igSameLine(0, fs);
                ui.textDisabled("bond character {d:.2}", .{ch});
                c.igSameLine(0, fs);
                var cut = app.isCut(sel[0], sel[1]);
                if (c.igCheckbox("cut (X)", &cut)) app.toggleCut();
                ui.tooltip("A cut bond is still drawn (thin, red) but is ignored when finding what moves together and when double-click selects a molecule.");
            }
            var l2: [16]u8 = undefined;
            modeSelector(app, atomLabel(&l2, f.numbers, sel[1]));
        },
        3 => {
            ui.text("Angle {s}", .{labels});
            c.igSameLine(0, -1);
            const ang = geom.angle(p, sel[0], sel[1], sel[2]);
            angleFields(app, "ang", ang, .angle);
            var l2: [16]u8 = undefined;
            modeSelector(app, atomLabel(&l2, f.numbers, sel[2]));
        },
        else => {
            ui.text("Dihedral {s}", .{labels});
            c.igSameLine(0, -1);
            const dih = geom.dihedral(p, sel[0], sel[1], sel[2], sel[3]);
            angleFields(app, "dih", dih, .dihedral);
            var l2: [16]u8 = undefined;
            modeSelector(app, atomLabel(&l2, f.numbers, sel[2]));
        },
    }
    c.igSameLine(0, fs * 1.5);
    if (c.igSmallButton("Clear")) app.clearSelection();
}

const AngleKind = enum { angle, dihedral };

/// Degree and radian fields for the same angle; either can be edited.
fn angleFields(app: *App, comptime id: []const u8, rad: f64, kind: AngleKind) void {
    const fs = c.igGetFontSize();
    const deg = std.math.radiansToDegrees(rad);
    const submit = struct {
        fn f(a: *App, k: AngleKind, r: f64) void {
            a.applyEdit(switch (k) {
                .angle => .{ .angle = r },
                .dihedral => .{ .dihedral = r },
            });
        }
    }.f;
    if (valueField("##" ++ id ++ "deg", deg, "%.3f", fs * 6.5)) |v| submit(app, kind, std.math.degreesToRadians(v));
    c.igSameLine(0, 4);
    ui.text("°", .{});
    if (nudge(id ++ "n", 1)) |dv| submit(app, kind, std.math.degreesToRadians(deg + dv));
    c.igSameLine(0, fs);
    if (valueField("##" ++ id ++ "rad", rad, "%.6f", fs * 6.5)) |v| submit(app, kind, v);
    c.igSameLine(0, 4);
    ui.text("rad", .{});
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
