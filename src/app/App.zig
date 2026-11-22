//! Application state and the immediate-mode UI built on top of it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("c");
const cv = @import("chemviewer");
const Renderer = @import("../render/Renderer.zig");
const Gpu = @import("../render/Gpu.zig");
const Camera = @import("../render/Camera.zig");
const ui = @import("ui.zig");
const timeline = @import("timeline.zig");
const measure = @import("measure.zig");
const lasso = @import("lasso.zig");
const drag_mod = @import("drag.zig");
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
show_atom_numbers: bool = false,
/// Element symbols on atoms whose colour another present element shares.
show_element_labels: bool = true,
/// User multiplier on top of the monitor's content scale (View menu).
ui_scale: f32 = 1.0,
/// Font size the panel layout was last placed for; when it changes the
/// panels are re-placed so they scale with the UI.
layout_font_size: f32 = 0,
quit_requested: bool = false,

status_buf: [512]u8 = undefined,
status_len: usize = 0,

/// Path delivered by the (possibly off-thread) SDL file dialog callback.
dialog_path: [4096]u8 = undefined,
dialog_ready: std.atomic.Value(bool) = .init(false),
save_path: [4096]u8 = undefined,
save_ready: std.atomic.Value(bool) = .init(false),

/// Selected atoms in click order (indices into the frame). The first four
/// define the measurement; any number can be copied as XYZ.
selection: std.ArrayList(u32) = .empty,
/// A clicked bond (independent of the atom selection): highlighted, shown in
/// the bar, and the target of X / the cut checkbox.
selected_bond: ?[2]u32 = null,
edit_mode: cv.geometry.Mode = .last,
/// Edited geometries by frame index; they replace the file's frames.
edits: std.AutoHashMapUnmanaged(usize, Frame) = .empty,
undo_stack: std.ArrayList(Undo) = .empty,
cut_bonds: CutSet = .empty,
/// Left-button press in the viewport, to tell clicks from drags.
press: ?struct { moved: f32 } = null,
/// Active lasso (Ctrl+left drag): outline in window points.
lasso_points: std.ArrayList(lasso.Point) = .empty,
lasso_active: bool = false,
/// Ctrl+Shift lasso removes from the selection instead of adding.
lasso_remove: bool = false,
/// Active Alt-drag of a fragment, and the frame before it started (for undo).
drag: ?drag_mod.Drag = null,
drag_before: ?Frame = null,
drag_button: u8 = 0,

/// Edits are undone by restoring the positions of the edited frame.
/// Undo restores a whole frame snapshot (pastes change the atom count).
const Undo = struct {
    index: usize,
    frame: Frame,
    /// Cut bonds before the edit, for edits that renumber atoms (delete).
    cuts: ?CutSet = null,

    fn deinit(u: *Undo, gpa: Allocator) void {
        u.frame.deinit(gpa);
        if (u.cuts) |*cs| cs.deinit(gpa);
    }
};

/// Bonds the user cut: drawn, but ignored as connections (key = pairKey).
pub const CutSet = std.AutoHashMapUnmanaged(u64, void);

const max_undo = 100;

pub fn init(io: Io, gpa: Allocator, window: *c.SDL_Window, gpu: *Gpu) !App {
    return .{ .io = io, .gpa = gpa, .window = window, .renderer = try Renderer.init(gpa, gpu) };
}

pub fn deinit(app: *App) void {
    app.clearEdits();
    app.edits.deinit(app.gpa);
    app.undo_stack.deinit(app.gpa);
    app.selection.deinit(app.gpa);
    app.lasso_points.deinit(app.gpa);
    app.endDrag(false);
    app.cut_bonds.deinit(app.gpa);
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
    var opened = try cv.source.open(app.io, app.gpa, .cwd(), path);
    errdefer opened.source.deinit(app.io, app.gpa);
    try app.install(opened, path);
}

/// Make `opened` the current document (takes ownership of its source).
/// `path` is used for display and save suggestions.
fn install(app: *App, opened: cv.source.Opened, path: []const u8) !void {
    const gpa = app.gpa;
    if (opened.source.frameCount() == 0) return error.NoFrames;
    const src = try gpa.create(cv.source.Source);
    errdefer gpa.destroy(src);
    src.* = opened.source;

    const stream = try gpa.create(cv.stream.FrameStream);
    errdefer gpa.destroy(stream);
    stream.* = try cv.stream.FrameStream.init(app.io, gpa, src, .{});
    errdefer stream.deinit();
    try stream.start();
    const owned_path = try gpa.dupe(u8, path);

    app.clearDiff();
    app.closeDocument();
    app.clearEdits();
    app.clearSelection();
    app.cut_bonds.clearRetainingCapacity();
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

// ------------------------------------------------------------ clipboard

/// Copy the selected atoms (or the whole frame if nothing is selected) to
/// the clipboard as XYZ, with provenance in the comment line.
pub fn copyXyz(app: *App) void {
    app.copyXyzInner() catch |e| app.setStatus("Copy failed: {t}", .{e});
}

fn copyXyzInner(app: *App) !void {
    const gpa = app.gpa;
    const d = app.doc orelse return;
    const f = d.shown orelse return;
    const sel = app.selected();
    const whole = sel.len == 0 or sel.len == f.len();

    var comment: std.Io.Writer.Allocating = .init(gpa);
    defer comment.deinit();
    const cw = &comment.writer;
    try cw.print("chemviewer source=\"{s}\" frame={d}/{d}", .{ std.fs.path.basename(d.path), d.shown_index + 1, d.frameCount() });
    if (!whole) {
        try cw.writeAll(" atoms=\"");
        try cv.formats.xyz.writeAtomRanges(cw, sel);
        try cw.writeAll("\"");
        if (f.energy) |e| try cw.print(" frame_energy={d}", .{e});
    }
    if (app.edits.contains(d.shown_index)) try cw.writeAll(" edited=T");

    var out = if (whole) try f.clone(gpa) else try f.subset(gpa, sel);
    defer out.deinit(gpa);
    if (out.comment.len > 0) gpa.free(out.comment);
    out.comment = try gpa.dupe(u8, comment.written());

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try cv.formats.xyz.write(&text.writer, out);
    try setClipboardText(text.written());
    app.setStatus("Copied {d} atom{s} as XYZ", .{ out.len(), if (out.len() == 1) "" else "s" });
}

/// The most recently copied text. Kept alive until the next copy replaces
/// it; the last one is reclaimed by the OS at exit.
///
/// Why not free it in SDL's cleanup callback: on Wayland, SDL serves
/// clipboard data lazily (when another app pastes), and on the user's
/// compositor SDL 3.4 cancels its own clipboard data (calling cleanup) right
/// after taking ownership while still answering paste requests with the
/// freed pointer, so other apps pasted allocator garbage. Both
/// SDL_SetClipboardText and a cleanup-freed buffer failed that way
/// (confirmed with `wl-paste | od -c`).
var clipboard_blob: ?[]u8 = null;

/// Offer `bytes` as text on the clipboard.
fn setClipboardText(bytes: []const u8) !void {
    const S = struct {
        fn provide(userdata: ?*anyopaque, mime_type: [*c]const u8, size: [*c]usize) callconv(.c) ?*const anyopaque {
            _ = mime_type; // every offered type is the same UTF-8 text
            _ = userdata;
            const blob = clipboard_blob orelse {
                size.* = 0;
                return null;
            };
            size.* = blob.len;
            return blob.ptr;
        }

        fn cleanup(userdata: ?*anyopaque) callconv(.c) void {
            _ = userdata; // see `clipboard_blob`: never free here
        }
    };
    const copy = try std.heap.c_allocator.dupe(u8, bytes);
    const old = clipboard_blob;
    clipboard_blob = copy;
    // Same text types SDL_SetClipboardText offers.
    const mime_types = [_][*:0]const u8{ "text/plain;charset=utf-8", "text/plain", "TEXT", "UTF8_STRING", "STRING" };
    if (!c.SDL_SetClipboardData(S.provide, S.cleanup, null, @ptrCast(&mime_types), mime_types.len)) {
        clipboard_blob = old;
        std.heap.c_allocator.free(copy);
        return error.ClipboardUnavailable;
    }
    // The new data is offered; the previous text can no longer be requested.
    if (old) |o| std.heap.c_allocator.free(o);
}

/// Paste the clipboard (XYZ, bare coordinates, or a Gaussian/ORCA input)
/// into the current frame as a new fragment; with nothing open, or with
/// `as_new`, open it as a new structure instead.
pub fn pasteXyz(app: *App, as_new: bool) void {
    app.pasteXyzInner(as_new) catch |e| app.setStatus("Nothing pasteable on the clipboard ({t})", .{e});
}

fn pasteXyzInner(app: *App, as_new: bool) !void {
    if (!c.SDL_HasClipboardText()) return error.Empty;
    const raw = c.SDL_GetClipboardText() orelse return error.Empty;
    defer c.SDL_free(raw);
    const text = std.mem.span(raw);
    var opened = try cv.source.openBytes(app.gpa, text);
    errdefer opened.source.deinit(app.io, app.gpa);
    const has_frame = if (app.doc) |d| d.shown != null else false;
    if (!as_new and has_frame) {
        defer opened.source.deinit(app.io, app.gpa);
        return app.appendFragment(opened.source.memory[0]);
    }
    try app.install(opened, "clipboard.xyz");
    app.setStatus("Pasted {d} atom{s} from the clipboard", .{
        opened.source.memory[0].len(), if (opened.source.memory[0].len() == 1) "" else "s",
    });
}

/// Append `frag` to the shown frame (undoable). If it would overlap the
/// existing atoms, it is moved beside the structure (to the right on screen).
/// The new atoms become the selection.
fn appendFragment(app: *App, frag: Frame) !void {
    const gpa = app.gpa;
    const d = &(app.doc orelse return);
    const f = &(d.shown orelse return);
    var offset: Vec3 = @splat(0);
    if (f.len() > 0 and frag.len() > 0 and f.len() * frag.len() <= 50_000_000 and f.minDistance(frag) < 1.0) {
        const ca = f.centroid();
        const cb = frag.centroid();
        var ra: f32 = 0;
        for (f.positions) |p| ra = @max(ra, cv.math.length(p - ca));
        var rb: f32 = 0;
        for (frag.positions) |p| rb = @max(rb, cv.math.length(p - cb));
        const right = app.camera.rotation.toMat3().transpose().column(0);
        offset = ca + right * cv.math.splat(ra + rb + 2.5) - cb;
    }
    var before = try f.clone(gpa);
    errdefer before.deinit(gpa);
    const combined = try f.concat(gpa, frag, offset);
    const first: u32 = @intCast(f.len());
    f.deinit(gpa);
    f.* = combined;
    try app.commitEdit(before);
    app.selection.clearRetainingCapacity();
    for (first..combined.len()) |i| try app.selection.append(gpa, @intCast(i));
    app.scene_dirty = true;
    // Re-frame if any pasted atom is off-screen.
    const sp = app.screenProjector();
    for (combined.positions[first..]) |p| {
        const q = sp.toScreen(p) orelse {
            app.fitCamera();
            break;
        };
        if (q.x < 0 or q.y < 0 or q.x > sp.w or q.y > sp.h) {
            app.fitCamera();
            break;
        }
    }
    app.setStatus("Pasted {d} atom{s} as a fragment{s}", .{
        frag.len(), if (frag.len() == 1) "" else "s", if (offset[0] != 0 or offset[1] != 0 or offset[2] != 0) " (moved beside the structure)" else "",
    });
}

/// Append the first frame of a file as a fragment (File > Add fragment).
pub fn addFragmentFile(app: *App, path: []const u8) !void {
    var opened = try cv.source.open(app.io, app.gpa, .cwd(), path);
    defer opened.source.deinit(app.io, app.gpa);
    var frag = try opened.source.loadFrame(app.io, app.gpa, 0);
    defer frag.deinit(app.gpa);
    try app.appendFragment(frag);
}

pub fn setFrame(app: *App, index: usize) void {
    const d = &(app.doc orelse return);
    d.current = @min(index, d.frameCount() - 1);
    // Ask the loader right away (the UI sets frames mid-frame, after update()).
    d.stream.request(d.current);
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
    if (app.save_ready.load(.acquire)) {
        const p = std.mem.sliceTo(&app.save_path, 0);
        var copy: [4096]u8 = undefined;
        @memcpy(copy[0..p.len], p);
        app.save_ready.store(false, .release);
        app.saveFrame(copy[0..p.len]);
    }

    const d = &(app.doc orelse return);
    app.advancePlayback();
    d.stream.request(d.current);
    if (d.shown == null or d.shown_index != d.current) {
        const got = d.stream.take(app.gpa, d.current) catch null;
        if (got) |loaded| {
            var frame = loaded;
            // Edited frames replace what's in the file.
            if (app.edits.get(d.current)) |e| {
                if (e.clone(app.gpa)) |copy| {
                    frame.deinit(app.gpa);
                    frame = copy;
                } else |_| {}
            }
            if (d.shown) |*old| old.deinit(app.gpa);
            d.shown = frame;
            app.dropInvalidSelection();
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
    // Bounding sphere around the box centre: farthest atom plus its display radius.
    var radius: f32 = 0;
    for (f.positions, f.numbers) |p, z| {
        radius = @max(radius, cv.math.length(p - center) + app.style.atomRadius(z));
    }
    if (app.style.show_cell) if (f.cell) |_| {
        radius = @max(radius, cv.math.length(b.max - b.min) * 0.5);
    };
    app.scene_radius = radius;
    app.camera.fit(center, radius);
}

fn rebuildScene(app: *App) !void {
    const r = &app.renderer;
    r.clear();
    r.selected_bond = if (app.selected_bond) |b| pairKey(b[0], b[1]) else null;
    const d = app.doc orelse return r.upload();
    const f = d.shown orelse return r.upload();
    if (app.diff) |df| if (df.overlay and df.result != null) {
        _ = try r.addStructure(df.reference.positions, df.reference.numbers, df.ref_bonds.items, app.style, .{ .color = .{ 1.0, 0.25, 0.25 } }, null);
        const start = try r.addStructure(df.aligned.items, f.numbers, d.bonds.items, app.style, .{ .color = .{ 0.25, 1.0, 0.35 } }, &app.cut_bonds);
        r.highlight(start, app.selected());
        return r.upload();
    };
    const start = try r.addStructure(f.positions, f.numbers, d.bonds.items, app.style, null, &app.cut_bonds);
    r.highlight(start, app.selected());
    if (app.style.show_cell) if (f.cell) |cell| try r.addCell(cell, app.style.theme.cellLine());
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
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (want_mouse) return;
            const mods0 = c.SDL_GetModState();
            if ((mods0 & c.SDL_KMOD_ALT) != 0 and app.drag == null) {
                // Shift with any button translates, as for the camera.
                const shift0 = (mods0 & c.SDL_KMOD_SHIFT) != 0;
                const kind: drag_mod.Kind = switch (ev.button.button) {
                    c.SDL_BUTTON_LEFT => if (shift0) .translate else .rotate,
                    c.SDL_BUTTON_MIDDLE => .translate,
                    c.SDL_BUTTON_RIGHT => if (shift0) .translate else .twist,
                    else => return,
                };
                app.drag_button = ev.button.button;
                app.beginDrag(kind, ev.button.x, ev.button.y);
                return;
            }
            if (ev.button.button != c.SDL_BUTTON_LEFT) return;
            app.press = .{ .moved = 0 };
            const mods = c.SDL_GetModState();
            if ((mods & c.SDL_KMOD_CTRL) != 0) {
                app.lasso_active = true;
                app.lasso_remove = (mods & c.SDL_KMOD_SHIFT) != 0;
                app.lasso_points.clearRetainingCapacity();
                app.lasso_points.append(app.gpa, .{ .x = ev.button.x, .y = ev.button.y }) catch {};
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (app.drag != null) {
                if (ev.button.button == app.drag_button) app.endDrag(true);
                return;
            }
            if (ev.button.button != c.SDL_BUTTON_LEFT) return;
            const pr = app.press orelse return;
            app.press = null;
            const was_lasso = app.lasso_active;
            app.lasso_active = false;
            // A click (not a drag) picks an atom or bond.
            if (pr.moved < 5) {
                if (!want_mouse) app.clickAt(ev.button.x, ev.button.y, ev.button.clicks);
            } else if (was_lasso) {
                app.applyLasso();
            }
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            if (app.drag != null) return app.dragMotion(ev.motion.x, ev.motion.y, ev.motion.xrel, ev.motion.yrel);
            if (app.press) |*pr| pr.moved += @abs(ev.motion.xrel) + @abs(ev.motion.yrel);
            if (app.lasso_active) {
                const pts = app.lasso_points.items;
                const last = pts[pts.len - 1];
                const dx = ev.motion.x - last.x;
                const dy = ev.motion.y - last.y;
                if (dx * dx + dy * dy >= 9) app.lasso_points.append(app.gpa, .{ .x = ev.motion.x, .y = ev.motion.y }) catch {};
                return; // no camera movement while lassoing
            }
            if (want_mouse) return;
            const m = ev.motion;
            // GaussView-style: left = rotate, right = roll (horizontal) and
            // zoom (vertical), middle or Shift + any button = translate.
            const shift = (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0;
            const left = (m.state & c.SDL_BUTTON_LMASK) != 0;
            const right = (m.state & c.SDL_BUTTON_RMASK) != 0;
            const middle = (m.state & c.SDL_BUTTON_MMASK) != 0;
            if (middle or (shift and (left or right))) {
                var h: c_int = 0;
                _ = c.SDL_GetWindowSize(app.window, null, &h);
                app.camera.pan(m.xrel, m.yrel, @floatFromInt(h));
            } else if (left) {
                app.camera.orbit(m.xrel, m.yrel);
            } else if (right) {
                app.camera.roll(m.xrel);
                app.camera.dragZoom(m.yrel);
            }
        },
        c.SDL_EVENT_MOUSE_WHEEL => if (!want_mouse) app.camera.zoom(ev.wheel.y),
        c.SDL_EVENT_KEY_DOWN => {
            if (want_keyboard) return;
            const d = &(app.doc orelse return);
            const n = d.frameCount();
            switch (ev.key.key) {
                c.SDLK_ESCAPE => if (app.drag != null) app.endDrag(false) else app.clearSelection(),
                c.SDLK_X => app.toggleCut(),
                c.SDLK_DELETE, c.SDLK_BACKSPACE => app.deleteSelection(),
                c.SDLK_N => app.show_atom_numbers = !app.show_atom_numbers,
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

// ------------------------------------------------------------ selection

pub fn selected(app: *const App) []const u32 {
    return app.selection.items;
}

pub fn clearSelection(app: *App) void {
    if (app.selection.items.len == 0 and app.selected_bond == null) return;
    app.selection.clearRetainingCapacity();
    app.selected_bond = null;
    app.scene_dirty = true;
}

fn isSelected(app: *const App, atom: u32) ?usize {
    return std.mem.indexOfScalar(u32, app.selection.items, atom);
}

/// Click on an atom: add it to the selection, or remove it if already selected.
pub fn toggleSelect(app: *App, atom: u32) void {
    if (app.isSelected(atom)) |k| {
        _ = app.selection.orderedRemove(k);
    } else {
        app.selection.append(app.gpa, atom) catch return;
    }
    app.scene_dirty = true;
}

/// Drop selected indices that don't exist in the shown frame.
fn dropInvalidSelection(app: *App) void {
    const d = app.doc orelse return;
    const n = if (d.shown) |f| f.len() else return;
    var i: usize = 0;
    while (i < app.selection.items.len) {
        if (app.selection.items[i] >= n) {
            _ = app.selection.orderedRemove(i);
            app.scene_dirty = true;
        } else i += 1;
    }
    if (app.selected_bond) |b| if (b[0] >= n or b[1] >= n) {
        app.selected_bond = null;
    };
}

pub fn pairKey(a: u32, b: u32) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

pub fn isCut(app: *const App, a: u32, b: u32) bool {
    return app.cut_bonds.contains(pairKey(a, b));
}

/// Cut (or restore) the bond between the two selected atoms.
/// Cut (or restore) the selected bond, or else the bond between the two
/// selected atoms.
pub fn toggleCut(app: *App) void {
    const sel = app.selected();
    const pair: [2]u32 = if (app.selected_bond) |b| b else if (sel.len == 2) .{ sel[0], sel[1] } else {
        app.setStatus("Click a bond (or select its two atoms) to cut it", .{});
        return;
    };
    app.toggleCutPair(pair[0], pair[1]);
}

/// Cut (or restore) the bond between atoms `a` and `b`.
pub fn toggleCutPair(app: *App, a: u32, b: u32) void {
    const key = pairKey(a, b);
    if (app.cut_bonds.remove(key)) {
        app.setStatus("Restored bond", .{});
    } else {
        app.cut_bonds.put(app.gpa, key, {}) catch return;
        app.setStatus("Cut bond: ignored when moving groups and selecting molecules", .{});
    }
    app.scene_dirty = true;
}

pub fn restoreCuts(app: *App) void {
    app.cut_bonds.clearRetainingCapacity();
    app.scene_dirty = true;
}

pub fn selectAll(app: *App) void {
    const d = app.doc orelse return;
    const f = d.shown orelse return;
    app.selection.clearRetainingCapacity();
    app.selection.ensureTotalCapacity(app.gpa, f.len()) catch return;
    for (0..f.len()) |i| app.selection.appendAssumeCapacity(@intCast(i));
    app.scene_dirty = true;
}

/// Ctrl+A: grow the selection to the whole molecules of the selected atoms;
/// if that adds nothing (or nothing is selected), select everything.
pub fn expandSelection(app: *App) void {
    const d = app.doc orelse return;
    const f = d.shown orelse return;
    if (app.selection.items.len == 0) return app.selectAll();
    const gpa = app.gpa;
    var graph = app.drawnGraph() catch return;
    defer graph.deinit(gpa);
    const mask = gpa.alloc(bool, f.len()) catch return;
    defer gpa.free(mask);
    @memset(mask, false);
    for (app.selection.items) |i| mask[i] = true;
    const before = app.selection.items.len;
    // BFS from the current selection; new atoms are appended in visit order.
    var head: usize = 0;
    while (head < app.selection.items.len) : (head += 1) {
        for (graph.neighbors(app.selection.items[head])) |j| if (!mask[j]) {
            mask[j] = true;
            app.selection.append(gpa, j) catch return;
        };
    }
    if (app.selection.items.len == before) return app.selectAll();
    app.scene_dirty = true;
    app.setStatus("Selected {d} atoms (whole molecules); Ctrl+A again selects all", .{app.selection.items.len});
}

/// Add (or, with Ctrl+Shift, remove) every atom whose projection lies
/// inside the lasso, including atoms hidden behind others.
fn applyLasso(app: *App) void {
    const pts = app.lasso_points.items;
    defer app.lasso_points.clearRetainingCapacity();
    if (pts.len < 3) return;
    const pos = app.displayedPositions() orelse return;
    const sp = app.screenProjector();
    const gpa = app.gpa;
    const mask = gpa.alloc(bool, pos.len) catch return;
    defer gpa.free(mask);
    @memset(mask, false);
    for (pos, 0..) |p, i| {
        const q = sp.toScreen(p) orelse continue;
        mask[i] = lasso.contains(pts, .{ .x = q.x, .y = q.y });
    }
    var changed: usize = 0;
    if (app.lasso_remove) {
        var i: usize = 0;
        while (i < app.selection.items.len) {
            if (mask[app.selection.items[i]]) {
                _ = app.selection.orderedRemove(i);
                changed += 1;
            } else i += 1;
        }
    } else {
        for (app.selection.items) |i| mask[i] = false; // already selected
        for (mask, 0..) |m, i| if (m) {
            app.selection.append(gpa, @intCast(i)) catch return;
            changed += 1;
        };
    }
    app.scene_dirty = true;
    app.setStatus("{s} {d} atom{s} ({d} selected)", .{
        if (app.lasso_remove) "Deselected" else "Selected", changed, if (changed == 1) "" else "s", app.selection.items.len,
    });
}

/// Draw the lasso outline while dragging.
pub fn drawLasso(app: *App) void {
    if (!app.lasso_active or app.lasso_points.items.len < 2) return;
    const dl = c.igGetForegroundDrawList_Nil();
    const ac = app.style.theme.accent();
    const pts: [*]const c.ImVec2_c = @ptrCast(app.lasso_points.items.ptr);
    const n: c_int = @intCast(app.lasso_points.items.len);
    if (n >= 3) c.ImDrawList_AddConcavePolyFilled(dl, pts, n, ui.rgba(ac[0], ac[1], ac[2], 0.12));
    c.ImDrawList_AddPolyline(dl, pts, n, ui.rgba(ac[0], ac[1], ac[2], 0.9), 1.5, c.ImDrawFlags_Closed);
}

/// Connectivity used for moving groups and selecting molecules: exactly the
/// bonds that are drawn, so what moves together is what looks connected,
/// minus the bonds the user cut.
pub fn drawnGraph(app: *const App) !cv.geometry.Graph {
    const d = app.doc orelse return error.NoDocument;
    const f = d.shown orelse return error.NoDocument;
    var drawn: std.ArrayList(cv.bonds.Bond) = .empty;
    defer drawn.deinit(app.gpa);
    for (d.bonds.items) |b| {
        if (Renderer.isDrawn(app.style, b.character) and !app.isCut(b.a, b.b)) try drawn.append(app.gpa, b);
    }
    return cv.geometry.Graph.init(app.gpa, f.len(), drawn.items, 0);
}

/// Positions as drawn (aligned onto the reference in diff overlay mode).
pub fn displayedPositions(app: *const App) ?[]const Vec3 {
    const d = app.doc orelse return null;
    const f = d.shown orelse return null;
    if (app.diff) |df| if (df.overlay and df.result != null) return df.aligned.items;
    return f.positions;
}

fn windowSize(app: *const App) [2]f32 {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(app.window, &w, &h);
    return .{ @floatFromInt(@max(w, 1)), @floatFromInt(@max(h, 1)) };
}

const Hit = struct { t: f32, target: union(enum) { atom: u32, bond: [2]u32 } };

/// The nearest atom or drawn bond under window point (x, y), if any.
fn hitAt(app: *const App, x: f32, y: f32) ?Hit {
    const pos = app.displayedPositions() orelse return null;
    const d = app.doc.?;
    const f = d.shown.?;
    const ws = app.windowSize();
    const r = app.camera.ray(2 * x / ws[0] - 1, 1 - 2 * y / ws[1], ws[0] / ws[1]);
    var best: ?Hit = null;
    for (pos, f.numbers, 0..) |p, z, i| {
        const rad = app.style.atomRadius(z) * 1.1;
        const oc = r.origin - p;
        const b = cv.math.dot(oc, r.dir);
        const disc = b * b - (cv.math.dot(oc, oc) - rad * rad);
        if (disc < 0) continue;
        const t = -b - @sqrt(disc);
        if (t > 0 and (best == null or t < best.?.t)) best = .{ .t = t, .target = .{ .atom = @intCast(i) } };
    }
    // Bonds: closest approach between the ray and the bond segment.
    const grab = @max(app.style.bondRadius() * 1.6, 0.12);
    for (d.bonds.items) |bd| {
        if (!Renderer.isDrawn(app.style, bd.character)) continue;
        const p0 = pos[bd.a];
        const e = pos[bd.b] - p0;
        const w0 = r.origin - p0;
        const bb = cv.math.dot(r.dir, e);
        const cc = cv.math.dot(e, e);
        const dd = cv.math.dot(r.dir, w0);
        const ee = cv.math.dot(e, w0);
        const denom = cc - bb * bb; // |dir| = 1
        if (denom < 1e-9) continue;
        const u = std.math.clamp((ee - bb * dd) / denom, 0, 1);
        const s = cv.math.dot(r.dir, p0 + e * cv.math.splat(u) - r.origin);
        if (s <= 0) continue;
        const gap = cv.math.length(r.origin + r.dir * cv.math.splat(s) - (p0 + e * cv.math.splat(u)));
        if (gap < grab and (best == null or s < best.?.t)) best = .{ .t = s, .target = .{ .bond = .{ bd.a, bd.b } } };
    }
    return best;
}

/// The atom under window point (x, y), if any.
pub fn atomAt(app: *const App, x: f32, y: f32) ?u32 {
    const h = app.hitAt(x, y) orelse return null;
    return switch (h.target) {
        .atom => |a| a,
        .bond => null,
    };
}

/// A click toggles the atom under the cursor, selects a bond's two atoms,
/// or clears the selection on empty space.
/// `clicks` is SDL's click count. A click on a bond selects just the bond
/// (atoms unchanged); a double click toggles its cut. A double click on an
/// atom changes nothing beyond the first click.
pub fn clickAt(app: *App, x: f32, y: f32, clicks: u8) void {
    const h = app.hitAt(x, y) orelse return app.clearSelection();
    switch (h.target) {
        .atom => |atom| if (clicks < 2) app.toggleSelect(atom),
        .bond => |pair| {
            // Bonds are selected on their own; the atom selection is untouched.
            const same = if (app.selected_bond) |b| pairKey(b[0], b[1]) == pairKey(pair[0], pair[1]) else false;
            if (clicks >= 2) {
                app.selected_bond = pair;
                app.toggleCut();
            } else {
                app.selected_bond = if (same) null else pair;
            }
            app.scene_dirty = true;
        },
    }
}

/// Maps world positions to window points for overlays.
pub const ScreenProjector = struct {
    m: cv.math.Mat4,
    w: f32,
    h: f32,
    /// Logical pixels per ImGui unit (for line thickness).
    scale: f32 = 1,

    pub fn toScreen(sp: ScreenProjector, p: Vec3) ?c.ImVec2_c {
        var clip: [4]f32 = undefined;
        for (0..4) |row| clip[row] = sp.m.m[0][row] * p[0] + sp.m.m[1][row] * p[1] + sp.m.m[2][row] * p[2] + sp.m.m[3][row];
        if (clip[3] <= 1e-6) return null;
        return .{ .x = (clip[0] / clip[3] + 1) * 0.5 * sp.w, .y = (1 - clip[1] / clip[3]) * 0.5 * sp.h };
    }
};

pub fn screenProjector(app: *const App) ScreenProjector {
    const ws = app.windowSize();
    const proj = app.camera.projection(ws[0] / ws[1], app.scene_radius);
    return .{ .m = proj.mul(app.camera.view()), .w = ws[0], .h = ws[1] };
}

pub fn bondCharacter(app: *const App, a: u32, b: u32) ?f32 {
    const d = app.doc orelse return null;
    for (d.bonds.items) |bd| {
        if ((bd.a == a and bd.b == b) or (bd.a == b and bd.b == a)) return bd.character;
    }
    return null;
}

// ------------------------------------------------------------ fragment dragging

/// Camera axes in world space: right, up, and towards the viewer.
pub fn cameraAxes(app: *const App) [3]Vec3 {
    const rt = app.camera.rotation.toMat3().transpose();
    return .{ rt.column(0), rt.column(1), rt.column(2) };
}

/// Start an Alt-drag on the atom under (x, y). See drag.zig for the gestures.
fn beginDrag(app: *App, kind: drag_mod.Kind, x: f32, y: f32) void {
    app.beginDragInner(kind, x, y) catch |e| app.setStatus("Can't move that: {t}", .{e});
}

fn beginDragInner(app: *App, kind: drag_mod.Kind, x: f32, y: f32) !void {
    const gpa = app.gpa;
    const d = &(app.doc orelse return);
    const f = &(d.shown orelse return);
    if (app.diff) |df| if (df.overlay and df.result != null) return error.TurnOffDiffOverlayFirst;
    const h = app.hitAt(x, y) orelse return;
    const handle = switch (h.target) {
        .atom => |a| a,
        .bond => |pair| pair[1],
    };

    var graph = try app.drawnGraph();
    defer graph.deinit(gpa);
    const choice = try drag_mod.chooseGroup(gpa, graph, app.selected(), handle);
    const pivot = choice.pivot;
    const group = choice.group;
    errdefer gpa.free(group);
    const start = try gpa.alloc(Vec3, group.len);
    errdefer gpa.free(start);
    var centroid: Vec3 = @splat(0);
    for (group, start) |i, *p| {
        p.* = f.positions[i];
        centroid += p.*;
    }
    centroid /= cv.math.splat(@floatFromInt(group.len));
    const center = if (pivot) |pv| f.positions[pv] else centroid;
    const v0 = f.positions[handle] - center;
    const axes = app.cameraAxes();

    var before = try f.clone(gpa);
    errdefer before.deinit(gpa);
    app.drag = .{
        .kind = kind,
        .pivot = pivot,
        .handle = handle,
        .group = group,
        .start = start,
        .center = center,
        .v0 = v0,
        .near_side = cv.math.dot(v0, axes[2]) >= 0,
    };
    app.drag_before = before;
}

fn dragMotion(app: *App, x: f32, y: f32, dx: f32, dy: f32) void {
    const dr = &(app.drag orelse return);
    const d = &(app.doc orelse return);
    const f = &(d.shown orelse return);
    const axes = app.cameraAxes();
    const ws = app.windowSize();
    switch (dr.kind) {
        .rotate => if (dr.pivot != null and cv.math.length2(dr.v0) > 1e-8) {
            // The grabbed atom follows the cursor on its sphere around the base atom.
            const r = app.camera.ray(2 * x / ws[0] - 1, 1 - 2 * y / ws[1], ws[0] / ws[1]);
            const p = drag_mod.spherePoint(r.origin, r.dir, dr.center, cv.math.length(dr.v0), dr.near_side);
            dr.rotation = cv.math.Quat.fromTo(dr.v0, p - dr.center);
        } else {
            // Trackball about the group centre, same feel as rotating the view.
            const k = 0.008;
            const q = cv.math.Quat.fromAxisAngle(axes[1], dx * k).mul(cv.math.Quat.fromAxisAngle(axes[0], dy * k));
            dr.rotation = q.mul(dr.rotation).normalized();
        },
        .twist => dr.twist -= dx * 0.008,
        .translate => {
            const r = app.camera.ray(0, 0, ws[0] / ws[1]);
            const depth = @max(cv.math.dot(dr.center + dr.offset - r.origin, r.dir), 0.1);
            const wpp = 2 * @tan(app.camera.fovy / 2) * depth / ws[1];
            dr.offset += axes[0] * cv.math.splat(dx * wpp) - axes[1] * cv.math.splat(dy * wpp);
        },
    }
    dr.moved = true;
    dr.apply(f.positions, axes[2]);
    app.bonds_dirty = true;
}

/// Finish (commit = true: keep as an undoable edit) or cancel the drag.
fn endDrag(app: *App, commit: bool) void {
    var dr = app.drag orelse return;
    app.drag = null;
    defer dr.deinit(app.gpa);
    var before = app.drag_before.?;
    app.drag_before = null;
    const d = &(app.doc orelse return before.deinit(app.gpa));
    const f = &(d.shown orelse return before.deinit(app.gpa));
    if (commit and dr.moved) {
        f.energy = null;
        app.commitEdit(before) catch before.deinit(app.gpa);
        app.setStatus("Moved {d} atom{s} (Ctrl+Z undoes)", .{ dr.group.len, if (dr.group.len == 1) "" else "s" });
        return;
    }
    // Cancel: restore the snapshot.
    for (dr.group, dr.start) |i, p| f.positions[i] = p;
    before.deinit(app.gpa);
    app.bonds_dirty = true;
}

/// Shown in the measurement bar while dragging.
pub fn dragHint(app: *const App, buf: []u8) ?[]const u8 {
    const dr = app.drag orelse return null;
    const f = app.doc.?.shown.?;
    const verb = switch (dr.kind) {
        .rotate => "Rotating",
        .twist => "Twisting",
        .translate => "Moving",
    };
    const n = dr.group.len;
    if (dr.pivot) |pv| return std.fmt.bufPrint(buf, "{s} {d} atom{s} about {s}{d}  (release to apply, Esc cancels)", .{
        verb, n, if (n == 1) "" else "s", cv.elements.symbol(f.numbers[pv]), pv + 1,
    }) catch null;
    return std.fmt.bufPrint(buf, "{s} {d} atom{s}  (release to apply, Esc cancels)", .{ verb, n, if (n == 1) "" else "s" }) catch null;
}

// ------------------------------------------------------------ editing

pub const Edit = union(enum) {
    /// Å
    distance: f64,
    /// radians
    angle: f64,
    /// radians
    dihedral: f64,
};

/// Change the selected internal coordinate of the current frame.
pub fn applyEdit(app: *App, edit: Edit) void {
    app.applyEditInner(edit) catch |e| app.setStatus("Edit failed: {t}", .{e});
}

fn applyEditInner(app: *App, edit: Edit) !void {
    const d = &(app.doc orelse return);
    const f = &(d.shown orelse return);
    const sel = app.selected();
    const gpa = app.gpa;
    var graph = try app.drawnGraph();
    defer graph.deinit(gpa);

    var before = try f.clone(gpa);
    errdefer before.deinit(gpa);
    const p = f.positions;
    switch (edit) {
        .distance => |v| if (sel.len == 2) try cv.geometry.setDistance(gpa, p, graph, sel[0], sel[1], v, app.edit_mode),
        .angle => |v| if (sel.len == 3) try cv.geometry.setAngle(gpa, p, graph, sel[0], sel[1], sel[2], v, app.edit_mode),
        .dihedral => |v| if (sel.len == 4) try cv.geometry.setDihedral(gpa, p, graph, sel[0], sel[1], sel[2], sel[3], v, app.edit_mode),
    }
    if (std.mem.eql(u8, std.mem.sliceAsBytes(before.positions), std.mem.sliceAsBytes(p))) {
        before.deinit(gpa);
        return;
    }
    // The file's energy no longer describes this geometry.
    f.energy = null;
    try app.commitEdit(before);
}

/// Record `before` for undo and store the shown frame as an edit.
fn commitEdit(app: *App, before: Frame) !void {
    return app.commitEditWithCuts(before, null);
}

/// Like `commitEdit`, also remembering the cut bonds from before the edit.
/// On success the undo stack owns `before` and `cuts_before`; on error the
/// caller still owns them (every fallible step happens before the transfer).
fn commitEditWithCuts(app: *App, before: Frame, cuts_before: ?CutSet) !void {
    const d = &(app.doc orelse return error.NoDocument);
    const f = d.shown orelse return error.NoDocument;
    try app.undo_stack.ensureUnusedCapacity(app.gpa, 1);
    try app.storeEdit(d.shown_index, f);
    if (app.undo_stack.items.len >= max_undo) {
        var old = app.undo_stack.orderedRemove(0);
        old.deinit(app.gpa);
    }
    app.undo_stack.appendAssumeCapacity(.{ .index = d.shown_index, .frame = before, .cuts = cuts_before });
    app.bonds_dirty = true;
}

/// Delete the selected atoms from the current frame (undoable).
pub fn deleteSelection(app: *App) void {
    app.deleteSelectionInner() catch |e| app.setStatus("Delete failed: {t}", .{e});
}

fn deleteSelectionInner(app: *App) !void {
    if (app.drag != null) return;
    const gpa = app.gpa;
    const d = &(app.doc orelse return);
    const f = &(d.shown orelse return);
    const sel = app.selected();
    if (sel.len == 0) return app.setStatus("Select atoms to delete", .{});
    if (sel.len >= f.len()) return app.setStatus("Can't delete every atom", .{});

    const remove = try gpa.alloc(bool, f.len());
    defer gpa.free(remove);
    @memset(remove, false);
    for (sel) |i| remove[i] = true;
    // Old index -> new index (maxInt = deleted), to renumber cut bonds.
    const new_index = try gpa.alloc(u32, f.len());
    defer gpa.free(new_index);
    var next: u32 = 0;
    for (remove, new_index) |rm, *ni| {
        ni.* = if (rm) std.math.maxInt(u32) else next;
        if (!rm) next += 1;
    }
    var new_cuts: CutSet = .empty;
    errdefer new_cuts.deinit(gpa);
    var it = app.cut_bonds.keyIterator();
    while (it.next()) |key| {
        const a: u32 = @intCast(key.* >> 32);
        const b: u32 = @truncate(key.*);
        if (a >= new_index.len or b >= new_index.len) continue;
        const na = new_index[a];
        const nb = new_index[b];
        if (na == std.math.maxInt(u32) or nb == std.math.maxInt(u32)) continue;
        try new_cuts.put(gpa, pairKey(na, nb), {});
    }

    var before = try f.clone(gpa);
    errdefer before.deinit(gpa);
    var after = try f.without(gpa, remove);
    const n = sel.len;
    // Swap in the new frame; roll back if the commit fails.
    var old = f.*;
    f.* = after;
    app.commitEditWithCuts(before, app.cut_bonds) catch |e| {
        f.* = old;
        after.deinit(gpa);
        return e;
    };
    // Success: the undo entry now owns `before` and the old cut set.
    old.deinit(gpa);
    app.cut_bonds = new_cuts;
    app.selection.clearRetainingCapacity();
    app.selected_bond = null;
    app.scene_dirty = true;
    app.setStatus("Deleted {d} atom{s} (Ctrl+Z undoes)", .{ n, if (n == 1) "" else "s" });
}

fn storeEdit(app: *App, index: usize, f: Frame) !void {
    const copy = try f.clone(app.gpa);
    const gop = try app.edits.getOrPut(app.gpa, index);
    if (gop.found_existing) gop.value_ptr.deinit(app.gpa);
    gop.value_ptr.* = copy;
}

pub fn undo(app: *App) void {
    var u = app.undo_stack.pop() orelse return;
    defer u.deinit(app.gpa);
    const d = &(app.doc orelse return);
    if (u.cuts) |cs| {
        app.cut_bonds.deinit(app.gpa);
        app.cut_bonds = cs;
        u.cuts = null;
        app.scene_dirty = true;
    }
    app.storeEdit(u.index, u.frame) catch return;
    if (d.shown_index == u.index) {
        if (d.shown) |*f| f.deinit(app.gpa);
        d.shown = u.frame.clone(app.gpa) catch null;
        app.dropInvalidSelection();
        app.bonds_dirty = true;
    }
    if (d.current != u.index) app.setFrame(u.index);
    app.setStatus("Undid edit on frame {d}", .{u.index + 1});
}

/// Drop the edits of the shown frame and reload it from the file.
pub fn revertFrame(app: *App) void {
    const d = &(app.doc orelse return);
    if (app.edits.fetchRemove(d.shown_index)) |kv| {
        var f = kv.value;
        f.deinit(app.gpa);
    }
    // Drop undo entries for this frame, and force a reload. If an edit
    // renumbered atoms, go back to the cut bonds from before the first one.
    var i: usize = 0;
    var restored_cuts = false;
    while (i < app.undo_stack.items.len) {
        if (app.undo_stack.items[i].index == d.shown_index) {
            var old = app.undo_stack.orderedRemove(i);
            if (!restored_cuts) if (old.cuts) |cs| {
                app.cut_bonds.deinit(app.gpa);
                app.cut_bonds = cs;
                old.cuts = null;
                restored_cuts = true;
            };
            old.deinit(app.gpa);
        } else i += 1;
    }
    if (d.shown) |*f| f.deinit(app.gpa);
    d.shown = null;
}

fn clearEdits(app: *App) void {
    var it = app.edits.valueIterator();
    while (it.next()) |f| f.deinit(app.gpa);
    app.edits.clearRetainingCapacity();
    for (app.undo_stack.items) |*u| u.deinit(app.gpa);
    app.undo_stack.clearRetainingCapacity();
}

pub fn saveDialog(app: *App) void {
    const d = app.doc orelse return;
    if (d.shown == null) return;
    const filters = [_]c.SDL_DialogFileFilter{.{ .name = "XYZ", .pattern = "xyz" }};
    // Suggest <name>_frameN.xyz next to the source file.
    var buf: [4096]u8 = undefined;
    const stem = std.fs.path.stem(d.path);
    const dir = std.fs.path.dirname(d.path) orelse ".";
    const suggestion = ui.printZ(&buf, "{s}/{s}_frame{d}.xyz", .{ dir, stem, d.shown_index + 1 }) catch null;
    c.SDL_ShowSaveFileDialog(saveCallback, app, app.window, &filters, filters.len, if (suggestion) |s| s.ptr else null);
}

fn saveCallback(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) callconv(.c) void {
    _ = filter;
    const app: *App = @ptrCast(@alignCast(userdata));
    if (filelist == null or filelist[0] == null) return;
    const p = std.mem.span(filelist[0]);
    if (p.len >= app.save_path.len) return;
    @memcpy(app.save_path[0..p.len], p);
    app.save_path[p.len] = 0;
    app.save_ready.store(true, .release);
}

/// Write the shown frame (including edits) as XYZ, through std.Io.
pub fn saveFrame(app: *App, path: []const u8) void {
    app.saveFrameInner(path) catch |e| {
        app.setStatus("Could not save {s}: {t}", .{ std.fs.path.basename(path), e });
        return;
    };
    app.setStatus("Saved {s}", .{std.fs.path.basename(path)});
}

fn saveFrameInner(app: *App, path: []const u8) !void {
    const d = app.doc orelse return error.NothingToSave;
    const f = d.shown orelse return error.NothingToSave;
    const file = try Io.Dir.cwd().createFile(app.io, path, .{});
    defer file.close(app.io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(app.io, &buf);
    try cv.formats.xyz.write(&fw.interface, f);
    try fw.interface.flush();
}

// ------------------------------------------------------------ UI

/// Window placement condition: re-place panels when the UI scale changes.
fn layoutCond(app: *App) c_int {
    return if (c.igGetFontSize() != app.layout_font_size) c.ImGuiCond_Always else c.ImGuiCond_FirstUseEver;
}

pub fn drawUi(app: *App) void {
    defer app.layout_font_size = c.igGetFontSize();
    measure.atomLabels(app);
    measure.overlay(app);
    app.drawLasso();
    app.menuBar();
    const timeline_h = timeline.height();
    timeline.draw(app, timeline_h);
    if (app.show_inspector) app.inspector(timeline_h);
    if (app.show_diff) app.diffPanel();
}

fn menuBar(app: *App) void {
    if (!c.igBeginMainMenuBar()) return;
    defer c.igEndMainMenuBar();
    if (c.igBeginMenu("File", true)) {
        if (c.igMenuItem_Bool("Open...", "Ctrl+O", false, true)) app.openDialog();
        const has_frame = app.doc != null and app.doc.?.shown != null;
        if (c.igMenuItem_Bool("Save frame as XYZ...", "Ctrl+S", false, has_frame)) app.saveDialog();
        if (c.igMenuItem_Bool("Close", null, false, app.doc != null)) {
            app.clearDiff();
            app.closeDocument();
        }
        c.igSeparator();
        if (c.igMenuItem_Bool("Quit", "Ctrl+Q", false, true)) app.quit_requested = true;
        c.igEndMenu();
    }
    if (c.igBeginMenu("Edit", true)) {
        if (c.igMenuItem_Bool("Undo geometry edit", "Ctrl+Z", false, app.undo_stack.items.len > 0)) app.undo();
        const edited = if (app.doc) |d| app.edits.contains(d.shown_index) else false;
        if (c.igMenuItem_Bool("Delete selected atoms", "Del", false, app.selection.items.len > 0)) app.deleteSelection();
        if (c.igMenuItem_Bool("Revert frame to file", null, false, edited)) app.revertFrame();
        c.igSeparator();
        if (c.igMenuItem_Bool("Cut / restore selected bond", "X", false, app.selected_bond != null or app.selection.items.len == 2)) app.toggleCut();
        if (c.igMenuItem_Bool("Restore all cut bonds", null, false, app.cut_bonds.count() > 0)) app.restoreCuts();
        c.igSeparator();
        if (c.igMenuItem_Bool("Copy as XYZ", "Ctrl+C", false, app.doc != null)) app.copyXyz();
        if (c.igMenuItem_Bool("Paste XYZ as fragment", "Ctrl+V", false, true)) app.pasteXyz(false);
        if (c.igMenuItem_Bool("Paste XYZ as new structure", "Ctrl+Shift+V", false, true)) app.pasteXyz(true);
        c.igSeparator();
        if (c.igMenuItem_Bool("Select molecule / all", "Ctrl+A", false, app.doc != null)) app.expandSelection();
        if (c.igMenuItem_Bool("Clear selection", "Esc", false, app.selection.items.len > 0)) app.clearSelection();
        c.igEndMenu();
    }
    if (c.igBeginMenu("View", true)) {
        _ = c.igMenuItem_BoolPtr("Inspector", null, &app.show_inspector, true);
        _ = c.igMenuItem_BoolPtr("Diff", null, &app.show_diff, true);
        if (c.igMenuItem_BoolPtr("Unit cell", null, &app.style.show_cell, true)) app.scene_dirty = true;
        _ = c.igMenuItem_BoolPtr("Atom numbers", "N", &app.show_atom_numbers, true);
        _ = c.igMenuItem_BoolPtr("Element labels", null, &app.show_element_labels, true);
        ui.tooltip("Show element symbols on atoms whose colour could be mistaken for another element in the structure (the rarer of the two).");
        if (c.igMenuItem_Bool("Fit to view", "F", false, app.doc != null)) app.fitCamera();
        c.igSeparator();
        c.igSetNextItemWidth(c.igGetFontSize() * 8);
        _ = c.igSliderFloat("UI scale", &app.ui_scale, 0.5, 2.0, "%.2fx", 0);
        c.igEndMenu();
    }
    if (app.status_len > 0) {
        c.igSameLine(0, 24);
        ui.textDisabled("{s}", .{app.status()});
    }
}

fn inspector(app: *App, timeline_h: f32) void {
    const vp = c.igGetMainViewport();
    const w: f32 = c.igGetFontSize() * 23;
    const cond = app.layoutCond();
    // WorkPos only accounts for the menu bar from the next frame on, so offset explicitly.
    const top = vp.*.Pos.y + c.igGetFrameHeight() + 8;
    c.igSetNextWindowPos(ui.v2(vp.*.WorkPos.x + 8, top), cond, ui.v2(0, 0));
    c.igSetNextWindowSize(ui.v2(w, @max(200, vp.*.Size.y - (top - vp.*.Pos.y) - timeline_h - 8)), cond);
    defer c.igEnd();
    if (!c.igBegin("Inspector", &app.show_inspector, 0)) return;
    c.igPushItemWidth(c.igGetContentRegionAvail().x * 0.55);
    defer c.igPopItemWidth();

    if (app.doc) |d| {
        c.igSeparatorText("File");
        ui.selectableText("##path", "{s}", .{std.fs.path.basename(d.path)});
        ui.textDisabled("{s}{s}", .{ d.format.label(), if (d.source.isStreamed()) ", streamed" else "" });
        if (d.shown) |f| {
            ui.text("Frame {d} / {d}{s}", .{ d.shown_index + 1, d.frameCount(), if (app.edits.contains(d.shown_index)) "  (edited)" else "" });
            ui.text("{d} atoms, {d} links", .{ f.len(), d.bonds.items.len });
            if (f.energy) |e| {
                c.igAlignTextToFramePadding();
                ui.text("E =", .{});
                c.igSameLine(0, -1);
                ui.selectableText("##energy", "{d}", .{e});
            }
            if (f.comment.len > 0) ui.selectableText("##comment", "{s}", .{f.comment});
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
    ui.gradientLegend(app.style.theme, app.style.snap);
    if (c.igSliderFloat("Snap", &app.style.snap, 0, 1, "%.2f", 0)) app.scene_dirty = true;
    ui.tooltip("How strongly colours settle on whole bond orders. 0 = linear in bond character, 1 = flat plateaus at single/double/triple.");
    if (c.igSliderFloat("Cut-off x r1", &app.bond_params.cutoff_factor, 1.0, 1.8, "%.2f", 0)) app.bonds_dirty = true;
    ui.tooltip("Pairs closer than this multiple of their single-bond length get a link.");
    if (c.igSliderFloat("Hide below", &app.style.min_character, 0, 3, "%.2f", 0)) app.scene_dirty = true;
    ui.tooltip("Hide links whose bond character is below this value (1 = single). Only drawn links connect atoms when moving groups or selecting molecules.");

    c.igSeparatorText("Display");
    var theme: c_int = @backingInt(app.style.theme);
    if (c.igRadioButton_IntPtr("Light", &theme, 0)) app.scene_dirty = true;
    c.igSameLine(0, -1);
    if (c.igRadioButton_IntPtr("Dark", &theme, 1)) app.scene_dirty = true;
    app.style.theme = @fromBackingInt(@intCast(theme));
    c.igSameLine(0, c.igGetFontSize() * 1.5);
    var shading: c_int = @backingInt(app.style.shading);
    if (c.igRadioButton_IntPtr("Cel", &shading, 0)) app.scene_dirty = true;
    ui.tooltip("Toon bands with outlines.");
    c.igSameLine(0, -1);
    if (c.igRadioButton_IntPtr("Flat", &shading, 1)) app.scene_dirty = true;
    ui.tooltip("Inspired by Kurzgesagt's flat illustrations: solid colours, flat drop shadows, depth shown by fading into the background.");
    app.style.shading = @fromBackingInt(@intCast(shading));
    if (app.style.shading == .cel) {
        _ = c.igSliderFloat("Outline", &app.style.outline_px, 0, 4, "%.1f px", 0);
    }
    _ = c.igCheckbox("Background pattern", &app.style.background_pattern);
    ui.tooltip("Pattern behind the molecule that turns with the camera.");
    if (app.style.background_pattern) {
        c.igSameLine(0, -1);
        var kind: c_int = @backingInt(app.style.backdrop);
        _ = c.igRadioButton_IntPtr("Cells", &kind, 0);
        c.igSameLine(0, -1);
        _ = c.igRadioButton_IntPtr("Space", &kind, 1);
        ui.tooltip("Backdrop motif, out of focus as if seen up close: cells (blobs with membranes and nuclei) or space (glowing bokeh, haze, sparkle stars).");
        app.style.backdrop = @fromBackingInt(@intCast(kind));
        _ = c.igSliderFloat("Background blur", &app.style.background_blur, 0, 2.5, "%.2f", 0);
        ui.tooltip("Depth of field: the molecule stays in focus and the backdrop blurs with distance. Zooming in blurs it more.");
    }
    if (c.igSliderFloat("Atom scale", &app.style.atom_scale, 0.2, 3.0, "%.2f", 0)) app.scene_dirty = true;
    if (c.igSliderFloat("Bond radius", &app.style.bond_radius, 0.03, 0.3, "%.2f Å", 0)) app.scene_dirty = true;
    if (c.igButton("Fit view (F)", ui.v2(0, 0))) app.fitCamera();

    if (c.igCollapsingHeader_TreeNodeFlags("Mouse & keys", 0)) ui.textWrapped("Left drag: rotate. Right drag: roll (left/right), zoom (up/down). Middle drag, or Shift + any drag: translate. Wheel: zoom. Space: play. Left/Right keys: step. F: fit.", .{});
}

/// Element key: a colour swatch and count per element present, in Hill
/// order (C, H, then alphabetical). Wraps to the panel width.
fn composition(app: *App, f: Frame) void {
    _ = app;
    var counts: [256]u32 = @splat(0);
    for (f.numbers) |z| counts[z] += 1;
    var order: [256]u8 = undefined;
    var n: usize = 0;
    for ([_]u8{ 6, 1 }) |z| if (counts[z] > 0) {
        order[n] = z;
        n += 1;
    };
    const first = n;
    for (counts, 0..) |k, z| if (k > 0 and z != 6 and z != 1) {
        order[n] = @intCast(z);
        n += 1;
    };
    std.mem.sort(u8, order[first..n], {}, struct {
        fn lt(_: void, a: u8, b: u8) bool {
            return std.mem.lessThan(u8, cv.elements.symbol(a), cv.elements.symbol(b));
        }
    }.lt);

    const fs = c.igGetFontSize();
    const dl = c.igGetWindowDrawList();
    const swatch = fs * 0.75;
    const right = c.igGetCursorScreenPos().x + c.igGetContentRegionAvail().x;
    const outline = c.igGetColorU32_Col(c.ImGuiCol_Border, 1);
    for (order[0..n], 0..) |z, i| {
        var buf: [24]u8 = undefined;
        const t = ui.printZ(&buf, "{s}{d}", .{ cv.elements.symbol(z), counts[z] }) catch continue;
        const w = swatch + fs * 0.3 + c.igCalcTextSize(t.ptr, null, false, -1).x;
        if (i > 0) {
            c.igSameLine(0, fs * 0.8);
            if (c.igGetCursorScreenPos().x + w > right) c.igNewLine();
        }
        c.igAlignTextToFramePadding();
        const p = c.igGetCursorScreenPos();
        const rgb = cv.elements.displayColor(z);
        const centre = ui.v2(p.x + swatch / 2, p.y + c.igGetFrameHeight() / 2);
        c.ImDrawList_AddCircleFilled(dl, centre, swatch / 2, ui.rgba(rgb[0], rgb[1], rgb[2], 1), 0);
        c.ImDrawList_AddCircle(dl, centre, swatch / 2, outline, 0, 1, 0);
        c.igDummy(ui.v2(swatch, c.igGetFrameHeight()));
        c.igSameLine(0, fs * 0.3);
        ui.text("{s}", .{t});
    }
}

fn diffPanel(app: *App) void {
    const vp = c.igGetMainViewport();
    const fs = c.igGetFontSize();
    const cond = app.layoutCond();
    c.igSetNextWindowPos(ui.v2(vp.*.WorkPos.x + vp.*.WorkSize.x - fs * 25 - 8, vp.*.Pos.y + c.igGetFrameHeight() + 8), cond, ui.v2(0, 0));
    c.igSetNextWindowSize(ui.v2(fs * 25, 0), cond);
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
