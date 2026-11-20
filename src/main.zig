//! chemviewer entry point: window, GL context, ImGui, and the main loop.
//!
//! Usage: chemviewer [FILE] [--frame N] [--diff-ref N]
//!                   [--screenshot OUT.png] [--size WxH] [--ui-scale X]
//!
//! `--screenshot` renders once the requested frame is loaded, writes a PNG and
//! exits. It works headless with SDL_VIDEO_DRIVER=offscreen.
const std = @import("std");
const Io = std.Io;
const c = @import("c");
const gl = @import("render/gl.zig");
const App = @import("app/App.zig");

const Args = struct {
    file: ?[]const u8 = null,
    frame: ?usize = null,
    diff_ref: ?usize = null,
    screenshot: ?[]const u8 = null,
    width: c_int = 1400,
    height: c_int = 900,
    ui_scale: ?f32 = null,
};

fn parseArgs(argv: []const []const u8) !Args {
    var a: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const eql = std.mem.eql;
        if (eql(u8, arg, "--frame") or eql(u8, arg, "--diff-ref") or eql(u8, arg, "--screenshot") or eql(u8, arg, "--size") or eql(u8, arg, "--ui-scale")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgumentValue;
            const v = argv[i];
            if (eql(u8, arg, "--frame")) {
                a.frame = (try std.fmt.parseInt(usize, v, 10)) -| 1;
            } else if (eql(u8, arg, "--diff-ref")) {
                a.diff_ref = (try std.fmt.parseInt(usize, v, 10)) -| 1;
            } else if (eql(u8, arg, "--screenshot")) {
                a.screenshot = v;
            } else if (eql(u8, arg, "--ui-scale")) {
                a.ui_scale = try std.fmt.parseFloat(f32, v);
            } else {
                var it = std.mem.splitScalar(u8, v, 'x');
                a.width = try std.fmt.parseInt(c_int, it.next() orelse return error.BadSize, 10);
                a.height = try std.fmt.parseInt(c_int, it.next() orelse return error.BadSize, 10);
            }
        } else if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
            return error.Help;
        } else {
            a.file = arg;
        }
    }
    return a;
}

fn sdlGetProc(name: [*:0]const u8) ?*const anyopaque {
    return @ptrCast(c.SDL_GL_GetProcAddress(name));
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
            \\usage: chemviewer [FILE] [--frame N] [--diff-ref N] [--screenshot OUT.png] [--size WxH] [--ui-scale X]
            \\
        , .{});
        if (e == error.Help) return;
        return e;
    };

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return sdlFail("SDL_Init");
    defer c.SDL_Quit();

    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_MULTISAMPLEBUFFERS, 1);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_MULTISAMPLESAMPLES, 4);

    const win_flags = c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY |
        (if (args.screenshot != null) c.SDL_WINDOW_HIDDEN else 0);
    const window = c.SDL_CreateWindow("chemviewer", args.width, args.height, win_flags) orelse
        return sdlFail("SDL_CreateWindow");
    defer c.SDL_DestroyWindow(window);
    const gl_ctx = c.SDL_GL_CreateContext(window) orelse blk: {
        // Some drivers (and the offscreen backend) reject multisampling.
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_MULTISAMPLEBUFFERS, 0);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_MULTISAMPLESAMPLES, 0);
        break :blk c.SDL_GL_CreateContext(window) orelse return sdlFail("SDL_GL_CreateContext");
    };
    defer _ = c.SDL_GL_DestroyContext(gl_ctx);
    _ = c.SDL_GL_MakeCurrent(window, gl_ctx);
    _ = c.SDL_GL_SetSwapInterval(1);
    try gl.load(sdlGetProc);
    gl.f.Enable(gl.MULTISAMPLE);

    // ---- Dear ImGui
    c.cvImGuiCreateContext();
    defer c.cvImGuiDestroyContext();
    c.igStyleColorsDark(null);
    const style = c.igGetStyle();
    style.*.WindowRounding = 4;
    style.*.FrameRounding = 3;
    var ui_scale: UiScale = .{ .base = style.* };
    if (!c.ImGui_ImplSDL3_InitForOpenGL(window, gl_ctx)) return error.ImGuiInit;
    defer c.ImGui_ImplSDL3_Shutdown();
    if (!c.ImGui_ImplOpenGL3_Init("#version 330")) return error.ImGuiInit;
    defer c.ImGui_ImplOpenGL3_Shutdown();

    // ---- App
    var app = try App.init(io, gpa, window);
    defer app.deinit();
    if (args.ui_scale) |u| app.ui_scale = u;
    if (args.file) |f| app.openFile(f);

    var shot: Screenshot = .{ .args = args, .start = Io.Timestamp.now(io, .awake) };
    if (args.file != null) {
        if (args.diff_ref) |r| app.setFrame(r) else if (args.frame) |f| app.setFrame(f);
    }

    while (!app.quit_requested) {
        var ev: c.SDL_Event = undefined;
        const idle = !app.playing and app.isSettled() and args.screenshot == null;
        if (idle and c.SDL_WaitEventTimeout(&ev, 100)) handleEvent(&app, &ev);
        while (c.SDL_PollEvent(&ev)) handleEvent(&app, &ev);

        app.update();
        ui_scale.apply(window, app.ui_scale);

        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplSDL3_NewFrame();
        c.igNewFrame();
        app.drawUi();
        c.igRender();

        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(window, &w, &h);
        const aspect = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(@max(h, 1)));
        app.renderer.draw(app.camera.view(), app.camera.projection(aspect, app.scene_radius), w, h);
        c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());

        if (args.screenshot != null) {
            if (try shot.step(&app, io, w, h)) break;
        }
        _ = c.SDL_GL_SwapWindow(window);
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
        style.* = u.base;
        c.ImGuiStyle_ScaleAllSizes(style, s);
        style.*.FontScaleDpi = s;
    }
};

fn handleEvent(app: *App, ev: *const c.SDL_Event) void {
    _ = c.ImGui_ImplSDL3_ProcessEvent(ev);
    if (ev.type == c.SDL_EVENT_KEY_DOWN and (ev.key.mod & c.SDL_KMOD_CTRL) != 0) {
        switch (ev.key.key) {
            c.SDLK_O => return app.openDialog(),
            c.SDLK_Q => {
                app.quit_requested = true;
                return;
            },
            else => {},
        }
    }
    app.handleEvent(ev, c.cvImGuiWantCaptureMouse(), c.cvImGuiWantCaptureKeyboard());
}

/// Drives `--screenshot`: optionally sets a diff reference, waits for the
/// target frame, lets the UI settle for a few frames, then saves a PNG.
const Screenshot = struct {
    args: Args,
    start: Io.Timestamp,
    phase: enum { reference, target, settle } = .reference,
    settle_frames: u32 = 0,

    fn step(s: *Screenshot, app: *App, io: Io, w: c_int, h: c_int) !bool {
        if (s.start.untilNow(io, .awake).toSeconds() > 30) {
            std.log.err("screenshot: timed out waiting for frame", .{});
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
                s.phase = .settle;
            },
            .settle => {
                // A few frames for ImGui windows to size themselves and the scene to rebuild.
                s.settle_frames += 1;
                if (s.settle_frames >= 4) {
                    try savePng(io, s.args.screenshot.?, w, h);
                    return true;
                }
            },
        }
        return false;
    }
};

fn savePng(io: Io, path: []const u8, w: c_int, h: c_int) !void {
    const gpa = std.heap.c_allocator;
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    const pixels = try gpa.alloc(u8, uw * uh * 4);
    defer gpa.free(pixels);
    gl.f.PixelStorei(gl.PACK_ALIGNMENT, 1);
    gl.f.ReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels.ptr);
    // GL rows are bottom-up.
    const row = uw * 4;
    const tmp = try gpa.alloc(u8, row);
    defer gpa.free(tmp);
    for (0..uh / 2) |y| {
        const a = pixels[y * row ..][0..row];
        const b = pixels[(uh - 1 - y) * row ..][0..row];
        @memcpy(tmp, a);
        @memcpy(a, b);
        @memcpy(b, tmp);
    }
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
