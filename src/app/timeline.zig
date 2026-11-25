//! The timeline docked at the bottom: the bar, transport controls, a frame number
//! and the plot (plot.zig).
const std = @import("std");
const c = @import("c");
const ui = @import("ui.zig");
const App = @import("App.zig");
const measure = @import("measure.zig");
const plot = @import("plot.zig");

pub fn height() f32 {
    const style = c.igGetStyle();
    return 2 * c.igGetFrameHeightWithSpacing() + plot.height() + style.*.WindowPadding.y * 2 + style.*.ItemSpacing.y;
}

pub fn draw(app: *App, h: f32) void {
    const vp = c.igGetMainViewport();
    c.igSetNextWindowPos(ui.v2(vp.*.WorkPos.x, vp.*.WorkPos.y + vp.*.WorkSize.y - h), c.ImGuiCond_Always, ui.v2(0, 0));
    c.igSetNextWindowSize(ui.v2(vp.*.WorkSize.x, h), c.ImGuiCond_Always);
    const flags = c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoBringToFrontOnFocus;
    defer c.igEnd();
    if (!c.igBegin("##timeline", null, flags)) return;
    measure.bar(app);

    const d = &(app.doc orelse return);
    const n = d.frameCount();

    // Transport controls, greyed out when there is nothing to step through.
    c.igBeginDisabled(n < 2);
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

    // Frame number: type one and press Enter to go there, or select and copy it.
    c.igAlignTextToFramePadding();
    ui.text("frame", .{});
    c.igSameLine(0, -1);
    c.igSetNextItemWidth(c.igGetFontSize() * 4.5);
    var cur: c_int = @intCast(d.current + 1);
    if (c.igInputInt("##frame", &cur, 0, 0, c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_AutoSelectAll)) {
        app.setFrame(@intCast(std.math.clamp(cur, 1, @as(c_int, @intCast(@max(n, 1)))) - 1));
    }
    ui.tooltip("Type a frame number and press Enter.");
    c.igSameLine(0, -1);
    ui.text("/ {d}", .{n});
    c.igSameLine(0, -1);
    c.igSetNextItemWidth(c.igGetFontSize() * 10);
    _ = c.igSliderFloat("##fps", &app.fps, 1, 240, "%.0f fps", c.ImGuiSliderFlags_Logarithmic);
    c.igSameLine(0, -1);
    _ = c.igCheckbox("Loop", &app.loop_playback);
    c.igSameLine(0, -1);
    if (c.igCheckbox("Interpolate", &app.interpolate) and !app.interpolate) app.moveTo(d.current);
    ui.tooltip("Play smoothly at the screen's frame rate: atoms follow a smooth curve through every real step (never overshooting between steps); the fps sets steps per second. Pausing or editing goes back to the step it was playing from.");
    c.igSameLine(0, -1);
    var lock = app.lock_rotation;
    const at = c.igGetCursorScreenPos();
    if (app.unlocked_at) |t| {
        // It changed by itself: a tint that fades.
        const left: f32 = @floatCast(1 - (app.seconds() - t) / 2);
        if (left > 0) {
            const ac = app.style.theme.accent();
            const w = c.igGetFrameHeight() + c.igGetStyle().*.ItemInnerSpacing.x + c.igCalcTextSize("Lock rotation", null, false, -1).x;
            c.ImDrawList_AddRectFilled(c.igGetWindowDrawList(), ui.v2(at.x - 2, at.y), ui.v2(at.x + w + 2, at.y + c.igGetFrameHeight()), ui.rgba(ac[0], ac[1], ac[2], 0.3 * left), 3, 0);
        } else app.unlocked_at = null;
    }
    if (c.igCheckbox("Lock rotation", &lock)) app.setLockRotation(lock);
    ui.tooltip("Turn the view with each frame so the structure keeps its orientation: every frame is superposed onto the frame shown when this was switched on, or onto the reference of a diff. Your own rotations still apply. Editing the structure switches it off.");
    c.igEndDisabled();

    plot.draw(app, d);
}
