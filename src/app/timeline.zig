//! The timeline docked at the bottom: transport controls, a frame slider and
//! an energy plot you can click or drag to scrub.
const std = @import("std");
const c = @import("c");
const ui = @import("ui.zig");
const App = @import("App.zig");
const measure = @import("measure.zig");

/// Energy plot height, in multiples of the font size.
fn plotHeight() f32 {
    return c.igGetFontSize() * 4.3;
}

pub fn height() f32 {
    const style = c.igGetStyle();
    return 2 * c.igGetFrameHeightWithSpacing() + plotHeight() + style.*.WindowPadding.y * 2 + style.*.ItemSpacing.y;
}

pub fn draw(app: *App, h: f32) void {
    const vp = c.igGetMainViewport();
    c.igSetNextWindowPos(ui.v2(vp.*.WorkPos.x, vp.*.WorkPos.y + vp.*.WorkSize.y - h), c.ImGuiCond_Always, ui.v2(0, 0));
    c.igSetNextWindowSize(ui.v2(vp.*.WorkSize.x, h), c.ImGuiCond_Always);
    const flags = c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoBringToFrontOnFocus;
    defer c.igEnd();
    if (!c.igBegin("##timeline", null, flags)) return;
    measure.bar(app);

    const d = &(app.doc orelse {
        ui.textDisabled("No trajectory loaded", .{});
        return;
    });
    const n = d.frameCount();

    // Transport controls.
    if (c.igButton("|<", ui.v2(0, 0))) app.setFrame(0);
    c.igSameLine(0, -1);
    if (c.igButton("<", ui.v2(0, 0))) app.setFrame(d.current -| 1);
    c.igSameLine(0, -1);
    if (c.igButton(if (app.playing) "Pause" else " Play", ui.v2(c.igGetFontSize() * 4.6, 0))) app.togglePlay();
    c.igSameLine(0, -1);
    if (c.igButton(">", ui.v2(0, 0))) app.setFrame(d.current + 1);
    c.igSameLine(0, -1);
    if (c.igButton(">|", ui.v2(0, 0))) app.setFrame(n - 1);
    c.igSameLine(0, -1);

    // Frame slider fills the space left of the playback options.
    const right_w: f32 = c.igGetFontSize() * 29;
    c.igSetNextItemWidth(@max(80, c.igGetContentRegionAvail().x - right_w));
    var cur: c_int = @intCast(d.current + 1);
    var fmt_buf: [64]u8 = undefined;
    const fmt = ui.printZ(&fmt_buf, "frame %d / {d}", .{n}) catch "%d";
    if (c.igSliderInt("##frame", &cur, 1, @intCast(@max(n, 1)), fmt.ptr, c.ImGuiSliderFlags_AlwaysClamp)) {
        app.setFrame(@intCast(cur - 1));
    }
    c.igSameLine(0, -1);
    c.igSetNextItemWidth(c.igGetFontSize() * 10);
    _ = c.igSliderFloat("##fps", &app.fps, 1, 240, "%.0f fps", c.ImGuiSliderFlags_Logarithmic);
    c.igSameLine(0, -1);
    _ = c.igCheckbox("Loop", &app.loop_playback);
    c.igSameLine(0, -1);
    if (c.igCheckbox("Interpolate", &app.interpolate) and !app.interpolate) app.setFrame(d.current);
    ui.tooltip("Play smoothly at the screen's frame rate: atoms follow a smooth curve through every real step (never overshooting between steps); the fps sets steps per second. Pausing stops on the nearest real step.");
    c.igSameLine(0, -1);
    var lock = app.lock_rotation;
    if (c.igCheckbox("Lock rotation", &lock)) app.setLockRotation(lock);
    ui.tooltip("Turn the view with each frame so the structure keeps its orientation: every frame is superposed onto the frame shown when this was switched on, as in the diff panel. Your own rotations still apply.");

    energyPlot(app, d);
}

fn energyPlot(app: *App, d: *App.Document) void {
    const n = d.frameCount();
    const dl = c.igGetWindowDrawList();
    const p0 = c.igGetCursorScreenPos();
    const w = c.igGetContentRegionAvail().x;
    const h = plotHeight();
    const p1 = ui.v2(p0.x + w, p0.y + h);
    _ = c.igInvisibleButton("##energy", ui.v2(w, h), 0);
    const hovered = c.igIsItemHovered(0);
    if (c.igIsItemActive() and n > 0) {
        const mx = c.igGetMousePos().x;
        const t = std.math.clamp((mx - p0.x) / w, 0, 1);
        app.setFrame(@intFromFloat(@round(t * @as(f32, @floatFromInt(n - 1)))));
    }

    const light = app.style.theme == .light;
    const accent = if (light) ui.rgba(0.12, 0.35, 0.80, 0.95) else ui.rgba(0.45, 0.75, 1.0, 0.9);
    const label_col = c.igGetColorU32_Col(c.ImGuiCol_Text, 0.55);
    c.ImDrawList_AddRectFilled(dl, p0, p1, c.igGetColorU32_Col(c.ImGuiCol_FrameBg, 1), 3, 0);

    // Min/max envelope of known energies per pixel column.
    const scanned = if (d.source.isStreamed()) d.stream.energiesScanned() else n;
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    var known: usize = 0;
    for (0..n) |i| if (d.stream.energy(i)) |e| {
        lo = @min(lo, e);
        hi = @max(hi, e);
        known += 1;
    };
    const cols: usize = @max(1, @as(usize, @intFromFloat(w)));
    if (known >= 2 and hi > lo) {
        const line_col = accent;
        const pad: f32 = 4;
        var prev: ?c.ImVec2_c = null;
        for (0..cols) |col| {
            const a = col * n / cols;
            const b = @max(a + 1, (col + 1) * n / cols);
            var cmin: f64 = std.math.inf(f64);
            var cmax: f64 = -std.math.inf(f64);
            for (a..@min(b, n)) |i| if (d.stream.energy(i)) |e| {
                cmin = @min(cmin, e);
                cmax = @max(cmax, e);
            };
            if (cmin > cmax) {
                prev = null;
                continue;
            }
            const x = p0.x + @as(f32, @floatFromInt(col)) + 0.5;
            const y_of = struct {
                fn f(e: f64, l: f64, hh: f64, top: f32, height_: f32, pd: f32) f32 {
                    const t: f32 = @floatCast((e - l) / (hh - l));
                    return top + pd + (1 - t) * (height_ - 2 * pd);
                }
            }.f;
            const ya = y_of(cmax, lo, hi, p0.y, h, pad);
            const yb = y_of(cmin, lo, hi, p0.y, h, pad);
            c.ImDrawList_AddLine(dl, ui.v2(x, ya), ui.v2(x, yb + 1), line_col, 1, 0);
            const mid = ui.v2(x, (ya + yb) / 2);
            if (prev) |pv| c.ImDrawList_AddLine(dl, pv, mid, line_col, 1, 0);
            prev = mid;
        }
        var buf: [96]u8 = undefined;
        const label = ui.printZ(&buf, "E  {d:.6} to {d:.6}  (range {e:.3})", .{ lo, hi, hi - lo }) catch "";
        c.ImDrawList_AddText_Vec2(dl, ui.v2(p0.x + 6, p0.y + 3), label_col, label.ptr, null);
    } else {
        const msg: [:0]const u8 = if (scanned < n) "scanning energies..." else "no energies in this file";
        c.ImDrawList_AddText_Vec2(dl, ui.v2(p0.x + 6, p0.y + 3), label_col, msg.ptr, null);
    }

    // Diff reference marker and playhead.
    if (n > 1) {
        const xf = struct {
            fn f(i: usize, nn: usize, x0: f32, ww: f32) f32 {
                return x0 + @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(nn - 1)) * (ww - 1) + 0.5;
            }
        }.f;
        if (app.diff) |df| {
            const x = xf(df.ref_index, n, p0.x, w);
            c.ImDrawList_AddLine(dl, ui.v2(x, p0.y), ui.v2(x, p1.y), ui.rgba(0.90, 0.20, 0.20, 0.9), 2, 0);
        }
        const x = xf(d.current, n, p0.x, w);
        c.ImDrawList_AddLine(dl, ui.v2(x, p0.y), ui.v2(x, p1.y), if (light) ui.rgba(0.85, 0.45, 0.0, 1) else ui.rgba(1, 0.85, 0.3, 1), 2, 0);
        if (scanned < n) {
            // Thin progress bar for the background energy scan.
            const t = @as(f32, @floatFromInt(scanned)) / @as(f32, @floatFromInt(n));
            c.ImDrawList_AddLine(dl, ui.v2(p0.x, p1.y - 1), ui.v2(p0.x + t * w, p1.y - 1), accent, 2, 0);
        }
    }
    if (hovered and n > 0) {
        const mx = c.igGetMousePos().x;
        const t = std.math.clamp((mx - p0.x) / w, 0, 1);
        const i: usize = @intFromFloat(@round(t * @as(f32, @floatFromInt(n - 1))));
        if (c.igBeginTooltip()) {
            if (d.stream.energy(i)) |e| ui.text("frame {d}: E = {d:.8}", .{ i + 1, e }) else ui.text("frame {d}", .{i + 1});
            c.igEndTooltip();
        }
    }
}
