//! chemviewer entry point: window, Vulkan device, ImGui, and the main loop.
//!
//! Usage: chemviewer [FILE] [--frame N] [--diff-ref N]
//!                   [--screenshot OUT.png] [--size WxH] [--ui-scale X] [--no-ui] [--dark] [--flat] [--atom-numbers]
//!                   [--no-bg-pattern] [--backdrop cells|space] [--bg-blur K]
//!                   [--orbit DX,DY] [--zoom STEPS] [--pan DX,DY] [--profile FRAMES] [--profile-static]
//!                   [--select I,J[,K[,L]]] [--set VALUE] [--save OUT.xyz]
//!                   [--cut I,J]... [--add FRAGMENT_FILE]
//!
//! `--screenshot` renders once the requested frame is loaded, writes a PNG and
//! exits. It works headless with SDL_VIDEO_DRIVER=offscreen.
const std = @import("std");
const Io = std.Io;
const c = @import("c");
const Gpu = @import("render/Gpu.zig");
const App = @import("app/App.zig");

const Args = struct {
    file: ?[]const u8 = null,
    frame: ?usize = null,
    diff_ref: ?usize = null,
    screenshot: ?[]const u8 = null,
    width: c_int = 1400,
    height: c_int = 900,
    ui_scale: ?f32 = null,
    no_ui: bool = false,
    dark: bool = false,
    flat: bool = false,
    no_bg_pattern: bool = false,
    bg_blur: ?f32 = null,
    backdrop: ?[]const u8 = null,
    /// Camera pose for scripted screenshots, applied after loading:
    /// orbit by a mouse drag of (dx, dy) pixels, zoom by wheel steps, pan by pixels.
    orbit: ?[2]f32 = null,
    zoom: ?f32 = null,
    /// Render this many frames while orbiting, print GPU time per pass, exit.
    profile: ?u32 = null,
    /// With --profile: keep the camera still (measures cached redraws).
    profile_static: bool = false,
    pan: ?[2]f32 = null,
    atom_numbers: bool = false,
    /// Startup script: select atoms (1-based), set their distance (Å) or
    /// angle/dihedral (degrees), save the frame as XYZ.
    select: [4]u32 = undefined,
    select_len: usize = 0,
    set_value: ?f64 = null,
    save: ?[]const u8 = null,
    /// Bonds to cut before editing (1-based pairs).
    cuts: [8][2]u32 = undefined,
    cuts_len: usize = 0,
    /// Append this file's first frame as a fragment (like paste).
    add: ?[]const u8 = null,
};

fn parseArgs(argv: []const []const u8) !Args {
    var a: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const eql = std.mem.eql;
        if (eql(u8, arg, "--frame") or eql(u8, arg, "--diff-ref") or eql(u8, arg, "--screenshot") or eql(u8, arg, "--size") or eql(u8, arg, "--ui-scale") or
            eql(u8, arg, "--select") or eql(u8, arg, "--set") or eql(u8, arg, "--save") or
            eql(u8, arg, "--cut") or eql(u8, arg, "--add") or
            eql(u8, arg, "--orbit") or eql(u8, arg, "--zoom") or eql(u8, arg, "--pan") or
            eql(u8, arg, "--backdrop") or eql(u8, arg, "--bg-blur") or eql(u8, arg, "--profile"))
        {
            i += 1;
            if (i >= argv.len) return error.MissingArgumentValue;
            const v = argv[i];
            if (eql(u8, arg, "--orbit") or eql(u8, arg, "--pan")) {
                var it = std.mem.splitScalar(u8, v, ',');
                const xy: [2]f32 = .{
                    try std.fmt.parseFloat(f32, it.next() orelse return error.BadPose),
                    try std.fmt.parseFloat(f32, it.next() orelse return error.BadPose),
                };
                if (eql(u8, arg, "--orbit")) a.orbit = xy else a.pan = xy;
            } else if (eql(u8, arg, "--zoom")) {
                a.zoom = try std.fmt.parseFloat(f32, v);
            } else if (eql(u8, arg, "--profile")) {
                a.profile = try std.fmt.parseInt(u32, v, 10);
            } else if (eql(u8, arg, "--bg-blur")) {
                a.bg_blur = try std.fmt.parseFloat(f32, v);
            } else if (eql(u8, arg, "--backdrop")) {
                if (!eql(u8, v, "cells") and !eql(u8, v, "space")) return error.BadBackdrop;
                a.backdrop = v;
            } else if (eql(u8, arg, "--frame")) {
                a.frame = (try std.fmt.parseInt(usize, v, 10)) -| 1;
            } else if (eql(u8, arg, "--diff-ref")) {
                a.diff_ref = (try std.fmt.parseInt(usize, v, 10)) -| 1;
            } else if (eql(u8, arg, "--screenshot")) {
                a.screenshot = v;
            } else if (eql(u8, arg, "--select")) {
                var it = std.mem.tokenizeAny(u8, v, ", ");
                while (it.next()) |tok| {
                    if (a.select_len == a.select.len) return error.TooManyAtoms;
                    const n = try std.fmt.parseInt(u32, tok, 10);
                    if (n == 0) return error.AtomIndicesStartAtOne;
                    a.select[a.select_len] = n - 1;
                    a.select_len += 1;
                }
            } else if (eql(u8, arg, "--set")) {
                a.set_value = try std.fmt.parseFloat(f64, v);
            } else if (eql(u8, arg, "--save")) {
                a.save = v;
            } else if (eql(u8, arg, "--add")) {
                a.add = v;
            } else if (eql(u8, arg, "--cut")) {
                if (a.cuts_len == a.cuts.len) return error.TooManyCuts;
                var it = std.mem.tokenizeAny(u8, v, ", ");
                var pair: [2]u32 = undefined;
                for (&pair) |*x| {
                    const n = try std.fmt.parseInt(u32, it.next() orelse return error.CutNeedsTwoAtoms, 10);
                    if (n == 0) return error.AtomIndicesStartAtOne;
                    x.* = n - 1;
                }
                a.cuts[a.cuts_len] = pair;
                a.cuts_len += 1;
            } else if (eql(u8, arg, "--ui-scale")) {
                a.ui_scale = try std.fmt.parseFloat(f32, v);
            } else {
                var it = std.mem.splitScalar(u8, v, 'x');
                a.width = try std.fmt.parseInt(c_int, it.next() orelse return error.BadSize, 10);
                a.height = try std.fmt.parseInt(c_int, it.next() orelse return error.BadSize, 10);
            }
        } else if (eql(u8, arg, "--atom-numbers")) {
            a.atom_numbers = true;
        } else if (eql(u8, arg, "--dark")) {
            a.dark = true;
        } else if (eql(u8, arg, "--flat")) {
            a.flat = true;
        } else if (eql(u8, arg, "--no-bg-pattern")) {
            a.no_bg_pattern = true;
        } else if (eql(u8, arg, "--profile-static")) {
            a.profile_static = true;
        } else if (eql(u8, arg, "--no-ui")) {
            a.no_ui = true;
        } else if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
            return error.Help;
        } else {
            a.file = arg;
        }
    }
    return a;
}

fn sdlFail(what: []const u8) error{SdlError} {
    std.log.err("{s}: {s}", .{ what, c.SDL_GetError() });
    return error.SdlError;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = parseArgs(argv) catch |e| {
        std.debug.print(
            \\usage: chemviewer [FILE] [--frame N] [--diff-ref N] [--screenshot OUT.png] [--size WxH]
            \\                  [--ui-scale X] [--no-ui] [--dark] [--flat] [--atom-numbers]
            \\                  [--no-bg-pattern] [--backdrop cells|space] [--bg-blur K]
            \\                  [--orbit DX,DY] [--zoom STEPS] [--pan DX,DY] [--profile FRAMES] [--profile-static]
            \\                  [--select I,J[,K[,L]]] [--set VALUE] [--save OUT.xyz]
            \\                  [--cut I,J]... [--add FRAGMENT_FILE]
            \\
        , .{});
        if (e == error.Help) return;
        return e;
    };

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return sdlFail("SDL_Init");
    defer c.SDL_Quit();

    const win_flags = c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY |
        (if (args.screenshot != null or args.profile != null) c.SDL_WINDOW_HIDDEN else 0);
    const window = c.SDL_CreateWindow("chemviewer", args.width, args.height, win_flags) orelse
        return sdlFail("SDL_CreateWindow");
    defer c.SDL_DestroyWindow(window);
    const gpu = try Gpu.init(gpa, window);
    defer gpu.deinit();

    // ---- Dear ImGui
    c.cvImGuiCreateContext();
    defer c.cvImGuiDestroyContext();
    c.igStyleColorsDark(null);
    const style = c.igGetStyle();
    style.*.WindowRounding = 4;
    style.*.FrameRounding = 3;
    var ui_scale: UiScale = .{ .base = style.* };
    var applied_theme: ?@import("render/Renderer.zig").Theme = null;
    if (!c.ImGui_ImplSDL3_InitForVulkan(window)) return error.ImGuiInit;
    defer c.ImGui_ImplSDL3_Shutdown();
    if (!c.cvImGuiVulkanInit(&.{
        .api_version = @bitCast(Gpu.api_version),
        .get_instance_proc_addr = @constCast(gpu.getInstanceProcAddr()),
        .instance = @ptrCast(gpu.instance.handle),
        .physical_device = @ptrCast(gpu.pdev),
        .device = @ptrCast(gpu.dev.handle),
        .queue = @ptrCast(gpu.queue),
        .queue_family = gpu.queue_family,
        .image_count = gpu.imageCount(),
        .color_format = @intCast(@backingInt(gpu.surface_format.format)),
    })) return error.ImGuiInit;
    defer c.cvImGuiVulkanShutdown();
    // Runs first: nothing may be in flight when ImGui and the app free GPU objects.
    defer gpu.waitIdle();

    // ---- App
    var app = try App.init(io, gpa, window, gpu);
    defer app.deinit();
    if (args.ui_scale) |u| app.ui_scale = u;
    if (args.dark) app.style.theme = .dark;
    if (args.flat) app.style.shading = .flat;
    if (args.no_bg_pattern) app.style.background_pattern = false;
    if (args.bg_blur) |b| app.style.background_blur = b;
    if (args.backdrop) |b| app.style.backdrop = if (std.mem.eql(u8, b, "space")) .space else .cells;
    app.show_atom_numbers = args.atom_numbers;
    if (args.file) |f| app.openFile(f);

    var startup: Startup = .{ .args = args, .start = Io.Timestamp.now(io, .awake) };
    if (args.file != null) {
        if (args.diff_ref) |r| app.setFrame(r) else if (args.frame) |f| app.setFrame(f);
    }

    while (!app.quit_requested) {
        var ev: c.SDL_Event = undefined;
        const idle = !app.playing and app.isSettled() and startup.phase == .done;
        if (idle and c.SDL_WaitEventTimeout(&ev, 100)) handleEvent(&app, &ev);
        while (c.SDL_PollEvent(&ev)) handleEvent(&app, &ev);

        app.update();
        ui_scale.apply(window, app.ui_scale);
        if (applied_theme != app.style.theme) {
            applied_theme = app.style.theme;
            switch (app.style.theme) {
                .light => lightImGuiColors(),
                .dark => c.igStyleColorsDark(null),
            }
        }

        c.cvImGuiVulkanNewFrame();
        c.ImGui_ImplSDL3_NewFrame();
        c.igNewFrame();
        app.drawUi();
        c.igRender();

        // Nothing to draw into while minimized.
        const frame = try gpu.beginFrame() orelse continue;
        const w: c_int = @intCast(frame.extent.width);
        const h: c_int = @intCast(frame.extent.height);
        const aspect = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(@max(h, 1)));
        try app.renderer.draw(frame, .{
            .view = app.camera.view(),
            .proj = app.camera.projection(aspect, app.scene_radius),
            .width = w,
            .height = h,
            .fovy = app.camera.fovy,
            .pixel_density = @max(c.SDL_GetWindowPixelDensity(window), 1),
            .style = app.style,
            .bg_anchor = app.camera.bg_anchor,
            .bg_radius = app.camera.bg_radius,
        });
        gpu.beginUiPass(frame);
        if (!args.no_ui) c.cvImGuiVulkanRender(@ptrCast(frame.cmd.handle));
        gpu.endUiPass(frame);

        const action = try startup.step(&app, io, w, h);
        try gpu.endFrame(frame, action == .screenshot);
        switch (action) {
            .none => {},
            .exit => break,
            .screenshot => {
                try savePng(io, gpu, args.screenshot.?, frame.extent);
                break;
            },
        }
    }
}

/// Keeps ImGui's style and font scale in sync with the monitor's content
/// scale times the user's preference.
///
/// SDL's display scale = pixel density × content scale. The ImGui SDL3 backend
/// already handles pixel density (framebuffer scale, fonts rasterised at full
/// resolution), so only the content scale is applied here. On Wayland at 150%
/// with high-pixel-density windows, density is 1.5 and content scale is 1.0;
/// on Windows at 150%, density is 1.0 and content scale is 1.5.
const UiScale = struct {
    base: c.ImGuiStyle,
    current: f32 = 0,

    fn contentScale(window: *c.SDL_Window) f32 {
        const display = c.SDL_GetWindowDisplayScale(window);
        const density = c.SDL_GetWindowPixelDensity(window);
        if (display <= 0 or density <= 0) return 1;
        return display / density;
    }

    fn apply(u: *UiScale, window: *c.SDL_Window, user: f32) void {
        const s = std.math.clamp(contentScale(window) * user, 0.5, 4);
        if (@abs(s - u.current) < 1e-3) return;
        u.current = s;
        const style = c.igGetStyle();
        const colors = style.*.Colors; // theme colours are managed separately
        style.* = u.base;
        style.*.Colors = colors;
        c.ImGuiStyle_ScaleAllSizes(style, s);
        style.*.FontScaleDpi = s;
    }
};

fn handleEvent(app: *App, ev: *const c.SDL_Event) void {
    _ = c.ImGui_ImplSDL3_ProcessEvent(ev);
    // Shortcuts yield only while a text field is being edited.
    const typing = c.cvImGuiWantTextInput();
    // Clipboard / select-all keys also belong to any active widget (e.g. a
    // read-only field the user clicked to copy the energy): ImGui handles
    // Ctrl+C there, and handling it here too would overwrite its copy.
    const widget_active = typing or c.igIsAnyItemActive();
    if (ev.type == c.SDL_EVENT_KEY_DOWN and (ev.key.mod & c.SDL_KMOD_CTRL) != 0 and !typing) {
        switch (ev.key.key) {
            c.SDLK_C => if (!widget_active) return app.copyXyz(),
            c.SDLK_V => if (!widget_active) return app.pasteXyz((ev.key.mod & c.SDL_KMOD_SHIFT) != 0),
            c.SDLK_A => if (!widget_active) return app.expandSelection(),
            c.SDLK_O => return app.openDialog(),
            c.SDLK_S => return app.saveDialog(),
            c.SDLK_Z => return app.undo(),
            c.SDLK_Q => {
                app.quit_requested = true;
                return;
            },
            else => {},
        }
    }
    app.handleEvent(ev, c.cvImGuiWantCaptureMouse(), typing);
}

/// Startup script: optionally sets a diff reference, waits for the target
/// frame, applies --select / --set / --save, then (with --screenshot) lets the
/// UI settle for a few frames, saves a PNG and asks to exit.
const Startup = struct {
    args: Args,
    start: Io.Timestamp,
    phase: enum { reference, target, settle, done } = .reference,
    settle_frames: u32 = 0,

    const Action = enum { none, exit, screenshot };

    /// Called once per frame before it is submitted.
    fn step(s: *Startup, app: *App, io: Io, w: c_int, h: c_int) !Action {
        if (s.phase == .done) return .none;
        if (s.start.untilNow(io, .awake).toSeconds() > 30) {
            std.log.err("startup: timed out waiting for frame", .{});
            return error.Timeout;
        }
        if (app.doc == null) {
            if (s.args.file != null) return error.OpenFailed;
            s.phase = .settle;
        }
        switch (s.phase) {
            .reference => {
                if (s.args.diff_ref == null) {
                    s.phase = .target;
                } else if (app.isSettled()) {
                    app.setReference();
                    app.setFrame(s.args.frame orelse 0);
                    s.phase = .target;
                }
            },
            .target => if (app.isSettled()) {
                try s.script(app);
                s.phase = .settle;
            },
            .settle => {
                if (s.args.profile) |n| return if (s.profile(app, n, w, h)) .exit else .none;
                if (s.args.screenshot == null) {
                    s.phase = .done;
                    return .none;
                }
                // A few frames for ImGui windows to size themselves and the scene to rebuild.
                s.settle_frames += 1;
                if (s.settle_frames >= 4) return .screenshot;
            },
            .done => {},
        }
        return .none;
    }

    /// Orbits the camera a little every frame (so nothing can be cached) and
    /// reports the mean GPU time of the background pass and the rest.
    fn profile(s: *Startup, app: *App, n: u32, w: c_int, h: c_int) bool {
        const Renderer = @import("render/Renderer.zig");
        s.settle_frames += 1;
        if (s.settle_frames == 4) Renderer.Profile.begin(&app.renderer);
        if (s.settle_frames <= 4) return false;
        if (!s.args.profile_static) app.camera.orbit(4, 1);
        const prof = app.renderer.profile orelse return true; // no timestamps: logged
        if (prof.frames < n) return false;
        // The pool is freed with the renderer: this frame still writes to it.
        const ms = struct {
            fn f(ns: u64, frames: u32) f64 {
                return @as(f64, @floatFromInt(ns)) / 1e6 / @as(f64, @floatFromInt(frames));
            }
        }.f;
        const motif = if (app.style.background_pattern) @tagName(app.style.backdrop) else "none";
        std.debug.print("{d}x{d} {s}/{s}: background {d:.3} ms, scene {d:.3} ms ({d} frames)\n", .{
            w, h, @tagName(app.style.shading), motif, ms(prof.background_ns, prof.frames), ms(prof.scene_ns, prof.frames), prof.frames,
        });
        return true;
    }

    fn script(s: *Startup, app: *App) !void {
        if (s.args.orbit) |o| app.camera.orbit(o[0], o[1]);
        if (s.args.zoom) |z| app.camera.zoom(z);
        if (s.args.pan) |d| app.camera.pan(d[0], d[1], @floatFromInt(s.args.height));
        if (s.args.add) |path| try app.addFragmentFile(path);
        for (s.args.cuts[0..s.args.cuts_len]) |pair| app.toggleCutPair(pair[0], pair[1]);
        app.clearSelection();
        const sel = s.args.select[0..s.args.select_len];
        const n = app.doc.?.shown.?.len();
        for (sel) |i| {
            if (i >= n) return error.SelectedAtomOutOfRange;
            app.toggleSelect(i);
        }
        if (s.args.set_value) |v| switch (sel.len) {
            2 => app.applyEdit(.{ .distance = v }),
            3 => app.applyEdit(.{ .angle = std.math.degreesToRadians(v) }),
            4 => app.applyEdit(.{ .dihedral = std.math.degreesToRadians(v) }),
            else => return error.SetNeedsTwoToFourSelectedAtoms,
        };
        // Apply the edit (bonds, scene) before saving.
        app.update();
        if (s.args.save) |path| app.saveFrame(path);
    }
};

fn savePng(io: Io, gpu: *const Gpu, path: []const u8, extent: @import("vulkan").Extent2D) !void {
    const gpa = std.heap.c_allocator;
    const pixels = try gpu.capturedPixels(gpa, extent);
    defer gpa.free(pixels);
    const w: c_int = @intCast(extent.width);
    const h: c_int = @intCast(extent.height);
    const surface = c.SDL_CreateSurfaceFrom(w, h, c.SDL_PIXELFORMAT_RGBA32, pixels.ptr, w * 4) orelse
        return sdlFail("SDL_CreateSurfaceFrom");
    defer c.SDL_DestroySurface(surface);

    // Encode in memory with SDL, write the file through std.Io.
    const mem = c.SDL_IOFromDynamicMem() orelse return sdlFail("SDL_IOFromDynamicMem");
    defer _ = c.SDL_CloseIO(mem);
    if (!c.SDL_SavePNG_IO(surface, mem, false)) return sdlFail("SDL_SavePNG_IO");
    const size: usize = @intCast(c.SDL_TellIO(mem));
    const ptr: [*]const u8 = @ptrCast(c.SDL_GetPointerProperty(c.SDL_GetIOProperties(mem), c.SDL_PROP_IOSTREAM_DYNAMIC_MEMORY_POINTER, null) orelse
        return sdlFail("dynamic memory pointer"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = ptr[0..size] });
    std.log.info("wrote {s} ({d}x{d})", .{ path, w, h });
}

test {
    _ = @import("render/Camera.zig");
    _ = @import("app/lasso.zig");
    _ = @import("app/drag.zig");
    _ = @import("app/occlusion.zig");
}

/// Light ImGui colours on the blue-grey of the light theme, with violet and
/// pink accents. Dark text sits on every fill, so fills stay light tints.
fn lightImGuiColors() void {
    c.igStyleColorsLight(null);
    const col = &c.igGetStyle().*.Colors;
    const set = struct {
        fn f(cs: anytype, i: c_int, hex: u24, a: f32) void {
            cs[@intCast(i)] = .{
                .x = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
                .y = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
                .z = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
                .w = a,
            };
        }
    }.f;
    set(col, c.ImGuiCol_WindowBg, 0xF4F7FA, 0.96);
    set(col, c.ImGuiCol_PopupBg, 0xF4F7FA, 0.98);
    set(col, c.ImGuiCol_MenuBarBg, 0xE6ECF3, 1);
    set(col, c.ImGuiCol_TitleBg, 0xE6ECF3, 1);
    set(col, c.ImGuiCol_TitleBgActive, 0xD9D3FF, 1);
    set(col, c.ImGuiCol_Border, 0xC8D4E3, 0.8);
    set(col, c.ImGuiCol_FrameBg, 0xE3E9F1, 1);
    set(col, c.ImGuiCol_FrameBgHovered, 0xD6DFEA, 1);
    set(col, c.ImGuiCol_FrameBgActive, 0xC8D4E3, 1);
    set(col, c.ImGuiCol_Button, 0xD9D3FF, 1);
    set(col, c.ImGuiCol_ButtonHovered, 0xFFCFE2, 1);
    set(col, c.ImGuiCol_ButtonActive, 0xFFB0CF, 1);
    set(col, c.ImGuiCol_Header, 0xD9D3FF, 1);
    set(col, c.ImGuiCol_HeaderHovered, 0xFFCFE2, 1);
    set(col, c.ImGuiCol_HeaderActive, 0xFFB0CF, 1);
    set(col, c.ImGuiCol_CheckMark, 0x5540F0, 1);
    set(col, c.ImGuiCol_SliderGrab, 0x5540F0, 1);
    set(col, c.ImGuiCol_SliderGrabActive, 0xFF2E7E, 1);
    set(col, c.ImGuiCol_PlotLines, 0x5540F0, 1);
    set(col, c.ImGuiCol_PlotHistogram, 0xFF2E7E, 1);
    set(col, c.ImGuiCol_Text, 0x2A1F66, 1);
    set(col, c.ImGuiCol_TextDisabled, 0x8A7FB8, 1);
}
