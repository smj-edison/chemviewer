//! Application state and the immediate-mode UI built on top of it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("c");
const cv = @import("chemviewer");
const Renderer = @import("../render/Renderer.zig");
const Camera = @import("../render/Camera.zig");
const ui = @import("ui.zig");
const timeline = @import("timeline.zig");
const Frame = cv.Frame;
const Vec3 = cv.math.Vec3;

const App = @This();

/// A loaded file: its source, its background stream and what's on screen.
pub const Document = struct {
    path: []u8,
    format: cv.source.Format,
    /// Heap-allocated so the stream's worker can hold stable pointers.
    source: *cv.source.Source,
    stream: *cv.stream.FrameStream,
    /// Frame the user asked for (timeline position).
    current: usize = 0,
    /// Frame currently displayed (may lag `current` while it loads).
    shown: ?Frame = null,
    shown_index: usize = 0,
    bonds: std.ArrayList(cv.bonds.Bond) = .empty,
    needs_fit: bool = true,

    pub fn frameCount(d: *const Document) usize {
        return d.stream.frameCount();
    }
};

pub const Diff = struct {
    reference: Frame,
    ref_index: usize,
    ref_bonds: std.ArrayList(cv.bonds.Bond) = .empty,
    /// Current frame superposed onto the reference (null if incompatible).
    result: ?cv.align_.Result = null,
    aligned: std.ArrayList(Vec3) = .empty,
    deviations: std.ArrayList(f32) = .empty,
    max_dev_atom: usize = 0,
    incompatible: bool = false,
    overlay: bool = true,
};

io: Io,
gpa: Allocator,
window: *c.SDL_Window,
renderer: Renderer,
camera: Camera = .{},
style: Renderer.Style = .{},
bond_params: cv.bonds.Params = .{},
doc: ?Document = null,
diff: ?Diff = null,

playing: bool = false,
fps: f32 = 15,
loop_playback: bool = true,
last_advance: Io.Timestamp = .zero,

scene_dirty: bool = true,
bonds_dirty: bool = false,
scene_radius: f32 = 10,
show_inspector: bool = true,
show_diff: bool = false,
show_demo: bool = false,
quit_requested: bool = false,

status_buf: [512]u8 = undefined,
status_len: usize = 0,

/// Path delivered by the (possibly off-thread) SDL file dialog callback.
dialog_path: [4096]u8 = undefined,
dialog_ready: std.atomic.Value(bool) = .init(false),

pub fn init(io: Io, gpa: Allocator, window: *c.SDL_Window) !App {
    return .{ .io = io, .gpa = gpa, .window = window, .renderer = try Renderer.init(gpa) };
}

pub fn deinit(app: *App) void {
    app.clearDiff();
    app.closeDocument();
    app.renderer.deinit();
}

pub fn setStatus(app: *App, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&app.status_buf, fmt, args) catch app.status_buf[0..];
    app.status_len = s.len;
    std.log.info("{s}", .{s});
}

pub fn status(app: *const App) []const u8 {
    return app.status_buf[0..app.status_len];
}

// ------------------------------------------------------------ documents

pub fn closeDocument(app: *App) void {
    var d = app.doc orelse return;
    d.stream.deinit();
    app.gpa.destroy(d.stream);
    d.source.deinit(app.io, app.gpa);
    app.gpa.destroy(d.source);
    if (d.shown) |*f| f.deinit(app.gpa);
    d.bonds.deinit(app.gpa);
    app.gpa.free(d.path);
    app.doc = null;
    app.scene_dirty = true;
}

pub fn openFile(app: *App, path: []const u8) void {
    app.openFileInner(path) catch |e| {
        app.setStatus("Could not open {s}: {t}", .{ std.fs.path.basename(path), e });
    };
}

fn openFileInner(app: *App, path: []const u8) !void {
    const gpa = app.gpa;
    const src = try gpa.create(cv.source.Source);
    errdefer gpa.destroy(src);
    const opened = try cv.source.open(app.io, gpa, .cwd(), path);
    src.* = opened.source;
    errdefer src.deinit(app.io, gpa);
    if (src.frameCount() == 0) return error.NoFrames;

    const stream = try gpa.create(cv.stream.FrameStream);
    errdefer gpa.destroy(stream);
    stream.* = try cv.stream.FrameStream.init(app.io, gpa, src, .{});
    errdefer stream.deinit();
    try stream.start();
    const owned_path = try gpa.dupe(u8, path);

    app.clearDiff();
    app.closeDocument();
    app.doc = .{ .path = owned_path, .format = opened.format, .source = src, .stream = stream };
    app.playing = false;
    app.setStatus("Opened {s} ({s}, {d} frame{s})", .{
        std.fs.path.basename(path),             opened.format.label(), src.frameCount(),
        if (src.frameCount() == 1) "" else "s",
    });
    var title_buf: [512]u8 = undefined;
    const title = ui.printZ(&title_buf, "chemviewer — {s}", .{std.fs.path.basename(path)}) catch "chemviewer";
    _ = c.SDL_SetWindowTitle(app.window, title.ptr);
}

pub fn setFrame(app: *App, index: usize) void {
    const d = &(app.doc orelse return);
    d.current = @min(index, d.frameCount() - 1);
}

/// True when the displayed frame is the requested one.
pub fn isSettled(app: *const App) bool {
    const d = app.doc orelse return true;
    return d.shown != null and d.shown_index == d.current;
}

/// Pull the requested frame from the stream when it's ready. Call once per UI frame.
pub fn update(app: *App) void {
    if (app.dialog_ready.load(.acquire)) {
        const p = std.mem.sliceTo(&app.dialog_path, 0);
        var copy: [4096]u8 = undefined;
        @memcpy(copy[0..p.len], p);
        app.dialog_ready.store(false, .release);
        app.openFile(copy[0..p.len]);
    }

    const d = &(app.doc orelse return);
    app.advancePlayback();
    d.stream.request(d.current);
    if (d.shown == null or d.shown_index != d.current) {
        const got = d.stream.take(app.gpa, d.current) catch null;
        if (got) |frame| {
            if (d.shown) |*old| old.deinit(app.gpa);
            d.shown = frame;
            d.shown_index = d.current;
            app.bonds_dirty = true;
        } else if (d.stream.lastError()) |e| {
            app.setStatus("Failed to load frame {d}: {t}", .{ d.current + 1, e });
        }
    }
    if (app.bonds_dirty) {
        app.bonds_dirty = false;
        if (d.shown) |f| {
            cv.bonds.findInto(app.gpa, &d.bonds, f.positions, f.numbers, app.bond_params) catch |e| {
                app.setStatus("Bond search failed: {t}", .{e});
            };
            if (app.diff) |*df| {
                cv.bonds.findInto(app.gpa, &df.ref_bonds, df.reference.positions, df.reference.numbers, app.bond_params) catch {};
            }
            app.updateDiff();
            if (d.needs_fit) {
                d.needs_fit = false;
                app.fitCamera();
            }
            app.scene_dirty = true;
        }
    }
    if (app.scene_dirty) {
        app.scene_dirty = false;
        app.rebuildScene() catch |e| app.setStatus("Scene build failed: {t}", .{e});
    }
}

fn advancePlayback(app: *App) void {
    const d = &(app.doc orelse return);
    if (!app.playing) return;
    const now = Io.Timestamp.now(app.io, .awake);
    const period_ns: i96 = @intFromFloat(1e9 / @max(app.fps, 0.1));
    if (app.last_advance.durationTo(now).nanoseconds < period_ns) return;
    // Don't run ahead of the loader: wait until the current frame is on screen.
    if (d.shown_index != d.current) return;
    app.last_advance = now;
    if (d.current + 1 < d.frameCount()) {
        d.current += 1;
    } else if (app.loop_playback) {
        d.current = 0;
    } else {
        app.playing = false;
    }
}

pub fn fitCamera(app: *App) void {
    const d = app.doc orelse return;
    const f = d.shown orelse return;
    var b = f.bounds();
    if (app.style.show_cell) if (f.cell) |cell| {
        for (0..8) |i| {
            var corner: Vec3 = @splat(0);
            for (0..3) |k| if (i & (@as(usize, 1) << @intCast(k)) != 0) {
                corner += cell[k];
            };
            b.min = @min(b.min, corner);
            b.max = @max(b.max, corner);
        }
    };
    const center = (b.min + b.max) * cv.math.splat(0.5);
    const radius = cv.math.length(b.max - b.min) * 0.5 + 1.5;
    app.scene_radius = radius;
    app.camera.fit(center, radius);
}

fn rebuildScene(app: *App) !void {
    const r = &app.renderer;
    r.clear();
    const d = app.doc orelse return r.upload();
    const f = d.shown orelse return r.upload();
    if (app.diff) |df| if (df.overlay and df.result != null) {
        try r.addStructure(df.reference.positions, df.reference.numbers, df.ref_bonds.items, app.style, .{ .color = .{ 1.0, 0.25, 0.25 } });
        try r.addStructure(df.aligned.items, f.numbers, d.bonds.items, app.style, .{ .color = .{ 0.25, 1.0, 0.35 } });
        return r.upload();
    };
    try r.addStructure(f.positions, f.numbers, d.bonds.items, app.style, null);
    if (app.style.show_cell) if (f.cell) |cell| try r.addCell(cell, .{ 0.6, 0.6, 0.65, 1 });
    try r.upload();
}

// ------------------------------------------------------------ diff

pub fn setReference(app: *App) void {
    const d = app.doc orelse return;
    const f = d.shown orelse return;
    app.clearDiff();
    const ref = f.clone(app.gpa) catch return;
    app.diff = .{ .reference = ref, .ref_index = d.shown_index };
    app.show_diff = true;
    app.bonds_dirty = true;
}

pub fn clearDiff(app: *App) void {
    var df = app.diff orelse return;
    df.reference.deinit(app.gpa);
    df.ref_bonds.deinit(app.gpa);
    df.aligned.deinit(app.gpa);
    df.deviations.deinit(app.gpa);
    app.diff = null;
    app.scene_dirty = true;
}

fn updateDiff(app: *App) void {
    const df = &(app.diff orelse return);
    const d = app.doc orelse return;
    const f = d.shown orelse return;
    df.result = null;
    df.incompatible = f.len() != df.reference.len() or !std.mem.eql(u8, f.numbers, df.reference.numbers);
    if (df.incompatible) return;
    const res = cv.align_.superpose(df.reference.positions, f.positions, null);
    df.aligned.resize(app.gpa, f.len()) catch return;
    df.deviations.resize(app.gpa, f.len()) catch return;
    df.max_dev_atom = 0;
    for (f.positions, df.aligned.items, df.deviations.items, df.reference.positions, 0..) |p, *a, *dev, rp, i| {
        a.* = res.transform.apply(p);
        dev.* = cv.math.length(a.* - rp);
        if (dev.* > df.deviations.items[df.max_dev_atom]) df.max_dev_atom = i;
    }
    df.result = res;
}

// ------------------------------------------------------------ input

pub fn handleEvent(app: *App, ev: *const c.SDL_Event, want_mouse: bool, want_keyboard: bool) void {
    switch (ev.type) {
        c.SDL_EVENT_QUIT => app.quit_requested = true,
        c.SDL_EVENT_DROP_FILE => if (ev.drop.data) |p| app.openFile(std.mem.span(p)),
        c.SDL_EVENT_MOUSE_MOTION => {
            if (want_mouse) return;
            const m = ev.motion;
            const shift = (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0;
            const left = (m.state & c.SDL_BUTTON_LMASK) != 0;
            const pan = (m.state & (c.SDL_BUTTON_RMASK | c.SDL_BUTTON_MMASK)) != 0 or (left and shift);
            if (pan) {
                var h: c_int = 0;
                _ = c.SDL_GetWindowSize(app.window, null, &h);
                app.camera.pan(m.xrel, m.yrel, @floatFromInt(h));
            } else if (left) {
                app.camera.orbit(m.xrel, m.yrel);
            }
        },
        c.SDL_EVENT_MOUSE_WHEEL => if (!want_mouse) app.camera.zoom(ev.wheel.y),
        c.SDL_EVENT_KEY_DOWN => {
            if (want_keyboard) return;
            const d = &(app.doc orelse return);
            const n = d.frameCount();
            switch (ev.key.key) {
                c.SDLK_SPACE => app.togglePlay(),
                c.SDLK_RIGHT, c.SDLK_PERIOD => app.setFrame(d.current + 1),
                c.SDLK_LEFT, c.SDLK_COMMA => app.setFrame(d.current -| 1),
                c.SDLK_PAGEDOWN => app.setFrame(d.current + @max(1, n / 20)),
                c.SDLK_PAGEUP => app.setFrame(d.current -| @max(1, n / 20)),
                c.SDLK_HOME => app.setFrame(0),
                c.SDLK_END => app.setFrame(n - 1),
                c.SDLK_F => app.fitCamera(),
                else => {},
            }
        },
        else => {},
    }
}

pub fn togglePlay(app: *App) void {
    const d = app.doc orelse return;
    if (d.frameCount() < 2) return;
    app.playing = !app.playing;
    app.last_advance = Io.Timestamp.now(app.io, .awake);
}

pub fn openDialog(app: *App) void {
    const filters = [_]c.SDL_DialogFileFilter{
        .{ .name = "Structures", .pattern = "xyz;extxyz;traj;gjf;com;log;out;inp" },
        .{ .name = "All files", .pattern = "*" },
    };
    c.SDL_ShowOpenFileDialog(dialogCallback, app, app.window, &filters, filters.len, null, false);
}

fn dialogCallback(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) callconv(.c) void {
    _ = filter;
    const app: *App = @ptrCast(@alignCast(userdata));
    if (filelist == null or filelist[0] == null) return;
    const p = std.mem.span(filelist[0]);
    if (p.len >= app.dialog_path.len) return;
    @memcpy(app.dialog_path[0..p.len], p);
    app.dialog_path[p.len] = 0;
    app.dialog_ready.store(true, .release);
}

// ------------------------------------------------------------ UI

pub fn drawUi(app: *App) void {
    app.menuBar();
    const timeline_h = timeline.height();
    timeline.draw(app, timeline_h);
    if (app.show_inspector) app.inspector(timeline_h);
    if (app.show_diff) app.diffPanel();
    if (app.show_demo) c.igShowDemoWindow(&app.show_demo);
}

fn menuBar(app: *App) void {
    if (!c.igBeginMainMenuBar()) return;
    defer c.igEndMainMenuBar();
    if (c.igBeginMenu("File", true)) {
        if (c.igMenuItem_Bool("Open...", "Ctrl+O", false, true)) app.openDialog();
        if (c.igMenuItem_Bool("Close", null, false, app.doc != null)) {
            app.clearDiff();
            app.closeDocument();
        }
        c.igSeparator();
        if (c.igMenuItem_Bool("Quit", "Ctrl+Q", false, true)) app.quit_requested = true;
        c.igEndMenu();
    }
    if (c.igBeginMenu("View", true)) {
        _ = c.igMenuItem_BoolPtr("Inspector", null, &app.show_inspector, true);
        _ = c.igMenuItem_BoolPtr("Diff", null, &app.show_diff, true);
        if (c.igMenuItem_BoolPtr("Unit cell", null, &app.style.show_cell, true)) app.scene_dirty = true;
        if (c.igMenuItem_Bool("Fit to view", "F", false, app.doc != null)) app.fitCamera();
        c.igSeparator();
        _ = c.igMenuItem_BoolPtr("ImGui demo", null, &app.show_demo, true);
        c.igEndMenu();
    }
    if (app.status_len > 0) {
        c.igSameLine(0, 24);
        ui.textDisabled("{s}", .{app.status()});
    }
}

fn inspector(app: *App, timeline_h: f32) void {
    const vp = c.igGetMainViewport();
    const w: f32 = 300;
    // WorkPos only accounts for the menu bar from the next frame on, so offset explicitly.
    const top = vp.*.Pos.y + c.igGetFrameHeight() + 8;
    c.igSetNextWindowPos(ui.v2(vp.*.WorkPos.x + 8, top), c.ImGuiCond_FirstUseEver, ui.v2(0, 0));
    c.igSetNextWindowSize(ui.v2(w, @max(200, vp.*.Size.y - (top - vp.*.Pos.y) - timeline_h - 8)), c.ImGuiCond_FirstUseEver);
    defer c.igEnd();
    if (!c.igBegin("Inspector", &app.show_inspector, 0)) return;
    c.igPushItemWidth(c.igGetContentRegionAvail().x * 0.55);
    defer c.igPopItemWidth();

    if (app.doc) |d| {
        c.igSeparatorText("File");
        ui.textWrapped("{s}", .{std.fs.path.basename(d.path)});
        ui.textDisabled("{s}{s}", .{ d.format.label(), if (d.source.isStreamed()) ", streamed" else "" });
        if (d.shown) |f| {
            ui.text("Frame {d} / {d}", .{ d.shown_index + 1, d.frameCount() });
            ui.text("{d} atoms, {d} links", .{ f.len(), d.bonds.items.len });
            if (f.energy) |e| ui.text("E = {d:.8}", .{e});
            if (f.comment.len > 0) ui.textWrapped("{s}", .{f.comment[0..@min(f.comment.len, 200)]});
            app.composition(f);
        } else ui.textDisabled("loading...", .{});
    } else {
        ui.textWrapped("No file open. Use File > Open, drop a file on the window, or pass a path on the command line.", .{});
    }

    c.igSeparatorText("Bonds");
    var coloring: c_int = @backingInt(app.style.bond_coloring);
    if (c.igRadioButton_IntPtr("Character gradient", &coloring, 0)) app.scene_dirty = true;
    c.igSameLine(0, -1);
    if (c.igRadioButton_IntPtr("Element", &coloring, 1)) app.scene_dirty = true;
    app.style.bond_coloring = @fromBackingInt(@intCast(coloring));
    ui.gradientLegend(app.style.snap);
    if (c.igSliderFloat("Snap", &app.style.snap, 0, 1, "%.2f", 0)) app.scene_dirty = true;
    ui.tooltip("How strongly colours settle on whole bond orders. 0 = linear in bond character, 1 = flat plateaus at single/double/triple.");
    if (c.igSliderFloat("Cut-off x r1", &app.bond_params.cutoff_factor, 1.0, 1.8, "%.2f", 0)) app.bonds_dirty = true;
    ui.tooltip("Pairs closer than this multiple of their single-bond length get a link.");
    if (c.igSliderFloat("Hide below", &app.style.min_character, 0, 3, "%.2f", 0)) app.scene_dirty = true;
    ui.tooltip("Hide links whose bond character is below this value (1 = single).");

    c.igSeparatorText("Display");
    if (c.igSliderFloat("Atom scale", &app.style.atom_scale, 0.2, 3.0, "%.2f", 0)) app.scene_dirty = true;
    if (c.igSliderFloat("Bond radius", &app.style.bond_radius, 0.03, 0.3, "%.2f Å", 0)) app.scene_dirty = true;
    if (c.igButton("Fit view (F)", ui.v2(0, 0))) app.fitCamera();

    c.igSeparatorText("Controls");
    ui.textWrapped("Left drag: rotate. Right or Shift+drag: pan. Wheel: zoom. Space: play. Left/Right: step. F: fit.", .{});
}

fn composition(app: *App, f: Frame) void {
    _ = app;
    var counts: [256]u32 = @splat(0);
    for (f.numbers) |z| counts[z] += 1;
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // Hill order: C, H, then alphabetical.
    const order_first = [_]u8{ 6, 1 };
    for (order_first) |z| if (counts[z] > 0) {
        w.print("{s}{d} ", .{ cv.elements.symbol(z), counts[z] }) catch {};
        counts[z] = 0;
    };
    var syms: [256]u8 = undefined;
    var ns: usize = 0;
    for (counts, 0..) |n, z| if (n > 0) {
        syms[ns] = @intCast(z);
        ns += 1;
    };
    std.mem.sort(u8, syms[0..ns], {}, struct {
        fn lt(_: void, a: u8, b: u8) bool {
            return std.mem.lessThan(u8, cv.elements.symbol(a), cv.elements.symbol(b));
        }
    }.lt);
    for (syms[0..ns]) |z| w.print("{s}{d} ", .{ cv.elements.symbol(z), counts[z] }) catch {};
    ui.textWrapped("{s}", .{w.buffered()});
}

fn diffPanel(app: *App) void {
    const vp = c.igGetMainViewport();
    c.igSetNextWindowPos(ui.v2(vp.*.WorkPos.x + vp.*.WorkSize.x - 328, vp.*.Pos.y + c.igGetFrameHeight() + 8), c.ImGuiCond_FirstUseEver, ui.v2(0, 0));
    c.igSetNextWindowSize(ui.v2(320, 0), c.ImGuiCond_FirstUseEver);
    defer c.igEnd();
    if (!c.igBegin("Diff", &app.show_diff, 0)) return;

    const d = app.doc orelse {
        ui.textDisabled("Open a file first.", .{});
        return;
    };
    ui.textWrapped("Superimpose the current frame onto a reference frame (same atoms, same order).", .{});
    if (c.igButton("Use current frame as reference", ui.v2(-1, 0))) app.setReference();
    const df = &(app.diff orelse return);
    ui.text("Reference: frame {d}", .{df.ref_index + 1});
    c.igSameLine(0, -1);
    if (c.igSmallButton("Clear")) {
        app.clearDiff();
        return;
    }
    if (c.igSmallButton("Jump to reference")) app.setFrame(df.ref_index);
    if (c.igCheckbox("Overlay (reference red, current green)", &df.overlay)) app.scene_dirty = true;
    if (df.incompatible) {
        ui.textWrapped("Current frame has different atoms than the reference. Matching without a known correspondence is planned (Phase 3).", .{});
        return;
    }
    const res = df.result orelse return;
    c.igSeparator();
    ui.text("RMSD  {d:.4} Å", .{res.rmsd});
    if (df.deviations.items.len > 0) {
        const i = df.max_dev_atom;
        const z = d.shown.?.numbers[i];
        ui.text("Max   {d:.4} Å  ({s}{d})", .{ df.deviations.items[i], cv.elements.symbol(z), i + 1 });
    }
}
