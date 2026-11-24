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
    /// Interpolated playback: the steps after `shown` and the ones either
    /// side of that segment, for a smooth curve (null until loaded).
    next: ?Frame = null,
    next_index: usize = 0,
    prev: ?Frame = null,
    prev_index: usize = 0,
    next2: ?Frame = null,
    next2_index: usize = 0,
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

/// "Lock rotation": the camera follows each new frame's rigid motion
/// relative to an anchor frame, so the structure keeps its orientation.
pub const RotationLock = struct {
    /// Displayed positions and elements of the frame shown when it started.
    anchor: []Vec3,
    numbers: []u8,
    /// Superposition of the frame the camera currently follows onto the anchor.
    current: cv.align_.Transform = .identity,
    /// That frame's index, and how far it was blended towards the next step.
    index: usize,
    blend: f32 = 0,

    fn deinit(l: *RotationLock, gpa: Allocator) void {
        gpa.free(l.anchor);
        gpa.free(l.numbers);
    }
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
/// Right-drag scrubbing on the timeline (null = not scrubbing): pixels moved
/// that don't add up to a whole frame yet.
fine_scrub: ?f32 = null,
/// Frame last scrubbed to by the current drag on the energy plot.
plot_drag: ?usize = null,
/// Keep the structure's orientation steady across frames (see RotationLock).
lock_rotation: bool = false,
rotation_lock: ?RotationLock = null,
last_advance: Io.Timestamp = .zero,
/// Interpolated playback: render at the display's frame rate, blending atom
/// positions between steps; pausing snaps to the nearest step.
interpolate: bool = false,
/// Fraction of the way from the shown step to the next (0 when not blending).
interp_t: f32 = 0,
/// Blended positions for the scene while interpolating.
interp_positions: std.ArrayList(Vec3) = .empty,

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
edit_mode: cv.geometry.Mode = .last,
/// The current atoms of every frame, and the undo history.
session: cv.edit.EditSession,
cut_bonds: CutSet = .empty,
/// Left-button press in the viewport, to tell clicks from drags.
press: ?struct { moved: f32 } = null,
/// Active lasso (Ctrl+left drag): outline in window points.
lasso_points: std.ArrayList(lasso.Point) = .empty,
lasso_active: bool = false,
/// Ctrl+Shift lasso removes from the selection instead of adding.
lasso_remove: bool = false,
/// Active Alt-drag of a fragment, and the edit it makes when released.
drag: ?drag_mod.Drag = null,
drag_edit: ?cv.edit.Transaction = null,
drag_button: u8 = 0,

pub const CutSet = cv.edit.CutSet;
pub const pairKey = cv.edit.pairKey;

pub fn init(io: Io, gpa: Allocator, window: *c.SDL_Window, gpu: *Gpu) !App {
    return .{ .io = io, .gpa = gpa, .window = window, .renderer = try Renderer.init(gpa, gpu), .session = .init(gpa) };
}

pub fn deinit(app: *App) void {
    app.deinitState();
    app.renderer.deinit();
}

/// Everything but the renderer.
fn deinitState(app: *App) void {
    app.closeDocument();
    app.session.deinit();
    app.selection.deinit(app.gpa);
    app.lasso_points.deinit(app.gpa);
    app.cut_bonds.deinit(app.gpa);
    app.interp_positions.deinit(app.gpa);
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

/// Also resets everything about the open file: edits, history, selection,
/// cuts, gestures in progress, playback and diff.
pub fn closeDocument(app: *App) void {
    app.endDrag(false);
    app.session.clear();
    app.clearSelection();
    app.cut_bonds.clearRetainingCapacity();
    app.press = null;
    app.lasso_active = false;
    app.lasso_points.clearRetainingCapacity();
    if (app.fine_scrub != null) app.endFineScrub();
    app.plot_drag = null;
    app.playing = false;
    app.interp_t = 0;
    app.clearDiff();
    var d = app.doc orelse return;
    d.stream.deinit();
    app.gpa.destroy(d.stream);
    d.source.deinit(app.io, app.gpa);
    app.gpa.destroy(d.source);
    if (d.shown) |*f| f.deinit(app.gpa);
    for ([_]*?Frame{ &d.next, &d.prev, &d.next2 }) |slot| if (slot.*) |*f| f.deinit(app.gpa);
    d.bonds.deinit(app.gpa);
    app.gpa.free(d.path);
    app.doc = null;
    app.dropRotationLock();
    app.scene_dirty = true;
}

pub fn openFile(app: *App, path: []const u8) void {
    app.endDrag(false);
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

    app.closeDocument();
    app.doc = .{ .path = owned_path, .format = opened.format, .source = src, .stream = stream };
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
    const d = app.doc orelse return;
    const f = d.shown orelse return;
    const text = try app.copyText();
    defer app.gpa.free(text);
    try setClipboardText(text);
    const n = if (app.selected().len == 0) f.len() else app.selected().len;
    app.setStatus("Copied {d} atom{s} as XYZ", .{ n, if (n == 1) "" else "s" });
}

/// What `copyXyz` copies. Owned by the caller.
fn copyText(app: *App) ![]u8 {
    const gpa = app.gpa;
    const d = app.doc orelse return error.NoDocument;
    const f = d.shown orelse return error.NoDocument;
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
    if (app.session.isEdited(d.shown_index)) try cw.writeAll(" edited=T");

    var out = if (whole) try f.clone(gpa) else try f.subset(gpa, sel);
    defer out.deinit(gpa);
    if (out.comment.len > 0) gpa.free(out.comment);
    out.comment = try gpa.dupe(u8, comment.written());

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try cv.formats.xyz.write(&text.writer, out);
    return text.toOwnedSlice();
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

/// Append `frag` to the shown frame (one geometry step). If it would overlap the
/// existing atoms, it is moved beside the structure (to the right on screen).
/// The new atoms become the selection.
fn appendFragment(app: *App, frag: Frame) !void {
    const gpa = app.gpa;
    var edit = try app.beginEdit();
    defer edit.deinit();
    const f = &app.doc.?.shown.?;
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
    const first: u32 = @intCast(f.len());
    const total: u32 = @intCast(first + frag.len());
    try app.selection.ensureTotalCapacity(gpa, frag.len());
    edit.replace(try f.concat(gpa, frag, offset));
    _ = try app.commitEdit(&edit, null);
    app.selection.clearRetainingCapacity();
    for (first..total) |i| app.selection.appendAssumeCapacity(@intCast(i));
    app.scene_dirty = true;
    // Re-frame if any pasted atom is off-screen.
    const sp = app.screenProjector();
    for (f.positions[first..]) |p| {
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

/// Start scrubbing one frame per pixel until the right button is released. The
/// pointer is hidden and captured meanwhile, so the screen edge doesn't stop it
/// (warping it around isn't possible on Wayland).
pub fn beginFineScrub(app: *App) void {
    if (app.doc == null) return;
    app.fine_scrub = 0;
    _ = c.SDL_SetWindowRelativeMouseMode(app.window, true);
}

fn endFineScrub(app: *App) void {
    app.fine_scrub = null;
    _ = c.SDL_SetWindowRelativeMouseMode(app.window, false);
}

fn fineScrubMotion(app: *App, dx: f32) void {
    const d = app.doc orelse return;
    const moved = app.fine_scrub.? + dx;
    const whole = @trunc(moved);
    app.fine_scrub = moved - whole;
    if (whole == 0) return;
    const last: i64 = @intCast(d.frameCount() - 1);
    const to = @as(i64, @intCast(d.current)) + @as(i64, @intFromFloat(whole));
    const index: usize = @intCast(std.math.clamp(to, 0, last));
    // Pushing on at either end isn't asking for that frame again.
    if (index != d.current) app.setFrame(index);
}

/// Go to a frame by hand, trying it again if it couldn't be read.
pub fn setFrame(app: *App, index: usize) void {
    const d = &(app.doc orelse return);
    d.stream.retry(@min(index, d.frameCount() - 1));
    app.moveTo(index);
}

/// `setFrame` from a key; held down at either end, it isn't asking again.
fn keyFrame(app: *App, index: usize, held: bool) void {
    const d = app.doc orelse return;
    if (held and @min(index, d.frameCount() - 1) == d.current) return;
    app.setFrame(index);
}

/// Go to a frame without retrying it.
pub fn moveTo(app: *App, index: usize) void {
    const d = &(app.doc orelse return);
    const to = @min(index, d.frameCount() - 1);
    if (to != d.current) app.endDrag(false);
    d.current = to;
    app.setInterp(0);
    // Ask the loader right away (the UI sets frames mid-frame, after update()).
    d.stream.request(d.current);
}

/// True when the displayed frame is the requested one, or that one can't be
/// read (the last good frame then stays on screen).
pub fn isSettled(app: *const App) bool {
    const d = app.doc orelse return true;
    if (d.shown != null and d.shown_index == d.current) return true;
    return d.stream.state(d.current) == .failed;
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
    app.pullFrame();
    app.reportFailures(d);
    app.updateNextFrame();
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
        app.followRotationLock();
        app.rebuildScene() catch |e| app.setStatus("Scene build failed: {t}", .{e});
    }
}

/// Shows the requested frame if it's ready.
fn pullFrame(app: *App) void {
    const d = &(app.doc orelse return);
    if (d.shown != null and d.shown_index == d.current) return;
    app.showFrame(d.current, app.takeFrame(d.current) orelse return);
}

/// Puts another frame on screen (takes ownership of its atoms).
fn showFrame(app: *App, index: usize, frame: Frame) void {
    const d = &app.doc.?;
    app.endDrag(false);
    if (d.shown) |*old| old.deinit(app.gpa);
    d.shown = frame;
    d.shown_index = index;
    app.dropInvalidSelection();
    app.bonds_dirty = true;
}

/// An owned copy of the current atoms of a frame, or null if it isn't ready.
fn takeFrame(app: *App, index: usize) ?Frame {
    const d = &(app.doc orelse return null);
    if (app.session.current(index)) |f| return f.clone(app.gpa) catch null;
    const got = d.stream.take(app.gpa, index) catch return null;
    return if (got == .ready) got.ready else null;
}

/// Names the frames that newly couldn't be read, in one message since the
/// status line only shows the latest.
fn reportFailures(app: *App, d: *Document) void {
    const first = d.stream.takeFailure() orelse return;
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var more: usize = 0;
    while (d.stream.takeFailure()) |f| {
        if (w.buffered().len + 24 > buf.len) {
            more += 1;
        } else w.print(", {d}", .{f.index + 1}) catch {};
    }
    const list = w.buffered();
    if (more > 0) return app.setStatus("Could not read frames {d}{s} and {d} more: {t}", .{ first.index + 1, list, more, first.err });
    app.setStatus("Could not read frame{s} {d}{s}: {t}", .{ if (list.len > 0) "s" else "", first.index + 1, list, first.err });
}

fn advancePlayback(app: *App) void {
    const d = &(app.doc orelse return);
    if (!app.playing) return;
    var head: cv.playback.Playhead = .{ .current = d.current, .t = app.interp_t, .last = app.last_advance };
    cv.playback.advance(&head, d.stream, .{
        .now = Io.Timestamp.now(app.io, .awake),
        .fps = app.fps,
        .loop = app.loop_playback,
        .interpolate = app.interpolate,
        .shown = if (d.shown != null) d.shown_index else null,
    });
    d.current = head.current;
    app.playing = head.playing;
    app.last_advance = head.last;
    app.setInterp(head.t);
}

fn setInterp(app: *App, t: f32) void {
    if (t != app.interp_t) app.scene_dirty = true;
    app.interp_t = t;
}

/// The step after the shown one is loaded and can be blended with it.
fn nextReady(app: *const App) bool {
    const d = app.doc orelse return false;
    const s = d.shown orelse return false;
    const nx = d.next orelse return false;
    return d.shown_index == d.current and d.next_index > d.current and
        nx.positions.len == s.positions.len and app.diff == null;
}

/// Keeps the frames around the current step loaded while interpolated
/// playback runs: `next` (required to blend) and `prev`/`next2` (shape the
/// curve; optional). Edits are applied, as for the shown frame.
fn updateNextFrame(app: *App) void {
    const d = &(app.doc orelse return);
    const on = app.interpolate and app.playing;
    const i = d.current;
    // Past frames that failed, so the curve bridges the gap.
    const next = if (on) d.stream.nextPlayable(i, false) else null;
    const next2 = if (next) |k| d.stream.nextPlayable(k, false) else null;
    app.keepFrame(&d.next, &d.next_index, next);
    app.keepFrame(&d.prev, &d.prev_index, if (next != null and i >= 1) d.stream.prevPlayable(i) else null);
    app.keepFrame(&d.next2, &d.next2_index, next2);
}

/// Makes `slot` hold frame `want` (taken from the stream's cache when
/// ready), or nothing.
fn keepFrame(app: *App, slot: *?Frame, index: *usize, want: ?usize) void {
    if (want) |w| if (slot.* != null and index.* == w) return;
    if (slot.*) |*f| f.deinit(app.gpa);
    slot.* = null;
    const w = want orelse return;
    slot.* = app.takeFrame(w) orelse return;
    index.* = w;
}

/// Positions to draw for the shown frame while interpolating: a monotone
/// cubic (Fritsch-Butland, per coordinate) through the steps either side.
/// It passes exactly through every real step and never overshoots: between
/// two steps each coordinate stays within their values, and where an atom
/// reverses it eases through the turn instead of snapping (linear blending
/// made every reversal a sharp bounce). Atoms that jump far between steps
/// (periodic wrap) snap instead of streaking across the box.
fn displayPositions(app: *App, f: Frame) []const Vec3 {
    const d = app.doc orelse return f.positions;
    if (app.interp_t <= 0 or !app.nextReady()) return f.positions;
    const nx = d.next.?;
    const len = f.positions.len;
    const pv: ?[]const Vec3 = if (d.prev) |p| (if (d.prev_index < d.current and p.positions.len == len) p.positions else null) else null;
    const n2: ?[]const Vec3 = if (d.next2) |p| (if (d.next2_index > d.next_index and p.positions.len == len) p.positions else null) else null;
    app.interp_positions.resize(app.gpa, len) catch return f.positions;
    const t = app.interp_t;
    const t2 = t * t;
    const t3 = t2 * t;
    const h00 = 2 * t3 - 3 * t2 + 1;
    const h10 = t3 - 2 * t2 + t;
    const h01 = -2 * t3 + 3 * t2;
    const h11 = t3 - t2;
    const jump = 2.5;
    for (app.interp_positions.items, 0..) |*o, k| {
        const p1 = f.positions[k];
        const p2 = nx.positions[k];
        if (cv.math.length(p2 - p1) > jump) {
            o.* = if (t < 0.5) p1 else p2;
            continue;
        }
        // Neighbours across a wrap don't shape the curve.
        const p0 = if (pv) |a| (if (cv.math.length(p1 - a[k]) > jump) p1 else a[k]) else p1;
        const p3 = if (n2) |a| (if (cv.math.length(a[k] - p2) > jump) p2 else a[k]) else p2;
        const m1 = slope(p1 - p0, p2 - p1);
        const m2 = slope(p2 - p1, p3 - p2);
        o.* = p1 * cv.math.splat(h00) + m1 * cv.math.splat(h10) + p2 * cv.math.splat(h01) + m2 * cv.math.splat(h11);
    }
    return app.interp_positions.items;
}

/// Tangent at a step from the secants either side, per coordinate: zero at a
/// turning point (or flat side), else their harmonic mean, which keeps the
/// curve within the neighbouring values.
fn slope(a: Vec3, b: Vec3) Vec3 {
    const zero: Vec3 = @splat(0);
    const ab = a * b;
    const same = ab > zero;
    // Guard the division where the sides disagree (masked out anyway).
    const sum = @select(f32, same, a + b, @as(Vec3, @splat(1)));
    return @select(f32, same, cv.math.splat(2) * ab / sum, zero);
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
    const d = app.doc orelse return r.upload();
    const f = d.shown orelse return r.upload();
    if (app.diff) |df| if (df.overlay and df.result != null) {
        _ = try r.addStructure(df.reference.positions, df.reference.numbers, df.ref_bonds.items, app.style, .{ .color = .{ 1.0, 0.25, 0.25 } }, null);
        const start = try r.addStructure(df.aligned.items, f.numbers, d.bonds.items, app.style, .{ .color = .{ 0.25, 1.0, 0.35 } }, &app.cut_bonds);
        r.highlight(start, app.selected());
        return r.upload();
    };
    const start = try r.addStructure(app.displayPositions(f), f.numbers, d.bonds.items, app.style, null, &app.cut_bonds);
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

// ------------------------------------------------------- rotation lock

pub fn setLockRotation(app: *App, on: bool) void {
    app.lock_rotation = on;
    app.dropRotationLock();
    if (on) app.followRotationLock();
}

fn dropRotationLock(app: *App) void {
    if (app.rotation_lock) |*l| l.deinit(app.gpa);
    app.rotation_lock = null;
}

/// Starts the lock at the shown frame, or, if the shown frame changed, turns
/// the camera by that frame's motion relative to the last one it followed
/// (both measured by superposing onto the anchor, so the view of a frame does
/// not depend on the path taken to it). Frames whose atoms don't match the
/// anchor's restart the lock there. Interpolated positions are followed too,
/// so the view turns evenly between steps instead of correcting at each one.
fn followRotationLock(app: *App) void {
    if (!app.lock_rotation) return;
    const d = app.doc orelse return;
    const f = d.shown orelse return;
    // What is drawn: blended between steps, or the plain step (aligned, when diffing).
    const blend = if (app.nextReady()) app.interp_t else 0;
    const pos = if (blend > 0) app.displayPositions(f) else app.displayedPositions() orelse return;
    if (app.rotation_lock) |*l| {
        if (l.index == d.shown_index and l.blend == blend) return;
        if (l.anchor.len == pos.len and std.mem.eql(u8, l.numbers, f.numbers)) {
            const next = cv.align_.superpose(l.anchor, pos, null).transform;
            // Frame-to-frame motion M = current⁻¹ ∘ next, with T(p) = R (p - from) + to:
            // M(p) = curᵀ next (p - next.from) + curᵀ (next.to - cur.to) + cur.from.
            const cur = l.current;
            var rot: cv.math.Mat3 = undefined;
            for (0..3) |row| for (0..3) |col| {
                var s: f64 = 0;
                for (0..3) |k| s += cur.rot[k][row] * next.rot[k][col];
                rot.m[col][row] = @floatCast(s);
            };
            const dt = next.to_center - cur.to_center;
            const to = cur.from_center + cv.math.Vec3d{
                cur.rot[0][0] * dt[0] + cur.rot[1][0] * dt[1] + cur.rot[2][0] * dt[2],
                cur.rot[0][1] * dt[0] + cur.rot[1][1] * dt[1] + cur.rot[2][1] * dt[2],
                cur.rot[0][2] * dt[0] + cur.rot[1][2] * dt[1] + cur.rot[2][2] * dt[2],
            };
            app.camera.followRigid(rot, @floatCast(next.from_center), @floatCast(to));
            l.current = next;
            l.index = d.shown_index;
            l.blend = blend;
            return;
        }
        app.dropRotationLock();
    }
    const anchor = app.gpa.dupe(Vec3, pos) catch return;
    const numbers = app.gpa.dupe(u8, f.numbers) catch {
        app.gpa.free(anchor);
        return;
    };
    app.rotation_lock = .{ .anchor = anchor, .numbers = numbers, .index = d.shown_index, .blend = blend };
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
        c.SDL_EVENT_WINDOW_FOCUS_LOST => if (app.fine_scrub != null) app.endFineScrub(),
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (app.fine_scrub != null) {
                if (ev.button.button == c.SDL_BUTTON_RIGHT) app.endFineScrub();
                return;
            }
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
            if (app.fine_scrub != null) {
                // Released before the UI frame that started the scrub.
                if ((ev.motion.state & c.SDL_BUTTON_RMASK) == 0) return app.endFineScrub();
                return app.fineScrubMotion(ev.motion.xrel);
            }
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
            const held = ev.key.repeat;
            switch (ev.key.key) {
                c.SDLK_ESCAPE => if (app.drag != null) app.endDrag(false) else app.clearSelection(),
                c.SDLK_DELETE, c.SDLK_BACKSPACE => app.deleteSelection(),
                c.SDLK_N => app.show_atom_numbers = !app.show_atom_numbers,
                c.SDLK_SPACE => app.togglePlay(),
                c.SDLK_RIGHT, c.SDLK_PERIOD => app.keyFrame(d.current + 1, held),
                c.SDLK_LEFT, c.SDLK_COMMA => app.keyFrame(d.current -| 1, held),
                c.SDLK_PAGEDOWN => app.keyFrame(d.current + @max(1, n / 20), held),
                c.SDLK_PAGEUP => app.keyFrame(d.current -| @max(1, n / 20), held),
                c.SDLK_HOME => app.keyFrame(0, held),
                c.SDLK_END => app.keyFrame(n - 1, held),
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
    app.endDrag(false);
    app.playing = !app.playing;
    app.last_advance = Io.Timestamp.now(app.io, .awake);
    // Pausing an interpolated playback stops on the nearest real step.
    if (!app.playing and app.interp_t > 0) {
        const next = if (app.interp_t >= 0.5) d.stream.nextPlayable(d.current, false) else null;
        app.moveTo(next orelse d.current);
    }
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
    if (app.selection.items.len == 0) return;
    app.selection.clearRetainingCapacity();
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
}

pub fn isCut(app: *const App, a: u32, b: u32) bool {
    return app.cut_bonds.contains(pairKey(a, b));
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

/// Positions as drawn (aligned onto the reference in diff overlay mode),
/// except for blending, which picking adds.
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
fn hitAt(app: *App, x: f32, y: f32) ?Hit {
    const d = app.doc orelse return null;
    const f = d.shown orelse return null;
    // Blending is off while diffing.
    const pos = if (app.nextReady()) app.displayPositions(f) else app.displayedPositions() orelse return null;
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
pub fn atomAt(app: *App, x: f32, y: f32) ?u32 {
    const h = app.hitAt(x, y) orelse return null;
    return switch (h.target) {
        .atom => |a| a,
        .bond => null,
    };
}

/// A click toggles the atom under the cursor, or clears the selection on
/// empty space. `clicks` is SDL's click count: bonds aren't selectable, and
/// their only action is a double click, which cuts or restores them. A double
/// click on an atom changes nothing beyond the first click.
pub fn clickAt(app: *App, x: f32, y: f32, clicks: u8) void {
    const h = app.hitAt(x, y) orelse return app.clearSelection();
    switch (h.target) {
        .atom => |atom| if (clicks < 2) app.toggleSelect(atom),
        .bond => |pair| if (clicks == 2) app.toggleCutPair(pair[0], pair[1]),
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
    if (app.diff) |df| if (df.overlay and df.result != null) return error.TurnOffDiffOverlayFirst;
    const h = app.hitAt(x, y) orelse return;
    const handle = switch (h.target) {
        .atom => |a| a,
        .bond => |pair| pair[1],
    };
    try app.startDrag(kind, handle);
}

fn startDrag(app: *App, kind: drag_mod.Kind, handle: u32) !void {
    const gpa = app.gpa;
    var edit = try app.beginEdit();
    errdefer edit.deinit();
    const f = edit.atoms;
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

    app.drag_edit = edit;
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
}

fn dragMotion(app: *App, x: f32, y: f32, dx: f32, dy: f32) void {
    const dr = &(app.drag orelse return);
    const edit = &app.drag_edit.?;
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
    dr.apply(edit.atoms.positions, axes[2]);
    app.showDragged(edit.atoms.positions);
}

/// Show the dragged frame with these positions. Whatever puts another frame on
/// screen, or changes this one, ends the drag first.
fn showDragged(app: *App, positions: []const Vec3) void {
    const d = &app.doc.?;
    std.debug.assert(d.shown_index == app.drag_edit.?.index);
    @memcpy(d.shown.?.positions, positions);
    app.bonds_dirty = true;
}

/// Finish (commit = true: keep as one geometry step) or cancel the drag.
fn endDrag(app: *App, commit: bool) void {
    var dr = app.drag orelse return;
    defer dr.deinit(app.gpa);
    var edit = app.drag_edit.?;
    defer edit.deinit();
    // Back as they were, unless committed below.
    for (dr.group, dr.start) |i, p| app.doc.?.shown.?.positions[i] = p;
    app.bonds_dirty = true;
    app.drag = null;
    app.drag_edit = null;
    if (commit and dr.moved) {
        if (app.commitEdit(&edit, null)) |changed| {
            if (changed) app.setStatus("Moved {d} atom{s} (Ctrl+Z undoes)", .{ dr.group.len, if (dr.group.len == 1) "" else "s" });
            return;
        } else |e| app.setStatus("Move failed: {t}", .{e});
    }
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
    const gpa = app.gpa;
    var tx = try app.beginEdit();
    defer tx.deinit();
    const sel = app.selected();
    var graph = try app.drawnGraph();
    defer graph.deinit(gpa);
    const p = tx.atoms.positions;
    switch (edit) {
        .distance => |v| if (sel.len == 2) try cv.geometry.setDistance(gpa, p, graph, sel[0], sel[1], v, app.edit_mode),
        .angle => |v| if (sel.len == 3) try cv.geometry.setAngle(gpa, p, graph, sel[0], sel[1], sel[2], v, app.edit_mode),
        .dihedral => |v| if (sel.len == 4) try cv.geometry.setDihedral(gpa, p, graph, sel[0], sel[1], sel[2], sel[3], v, app.edit_mode),
    }
    _ = try app.commitEdit(&tx, null);
}

/// Get ready to change the shown frame: abort a drag, and pause playback on
/// the nearest real step. With interpolation that may be the step after.
fn stopForEdit(app: *App) void {
    const d = &(app.doc orelse return);
    const dragged = app.drag != null;
    app.endDrag(false);
    const was_playing = app.playing;
    app.playing = false;
    if (was_playing) {
        if (app.interp_t >= 0.5 and app.nextReady()) {
            const next = d.next.?;
            d.next = null;
            app.moveTo(d.next_index);
            app.showFrame(d.next_index, next);
        } else if (d.shown != null) {
            // Not one that is still loading.
            app.moveTo(d.shown_index);
        }
    }
    // An edit needs the bonds of the atoms it starts from.
    if (dragged or was_playing) if (d.shown) |f| {
        cv.bonds.findInto(app.gpa, &d.bonds, f.positions, f.numbers, app.bond_params) catch {
            d.bonds.clearRetainingCapacity(); // `update` searches again
        };
        app.bonds_dirty = true;
    };
}

/// Every edit of the shown frame starts here.
fn beginEdit(app: *App) !cv.edit.Transaction {
    app.stopForEdit();
    const d = &(app.doc orelse return error.NoDocument);
    return app.session.begin(d.shown_index, d.shown orelse return error.NoDocument);
}

/// Commit an edit of the shown frame and show it. `cuts_before`: see
/// `Transaction.commit`. On error the frame is as it was.
fn commitEdit(app: *App, edit: *cv.edit.Transaction, cuts_before: ?CutSet) !bool {
    const d = &(app.doc orelse return error.NoDocument);
    std.debug.assert(d.shown_index == edit.index);
    // Nothing may fail after the commit.
    var show = try edit.atoms.clone(app.gpa);
    errdefer show.deinit(app.gpa);
    if (!try edit.commit(cuts_before)) {
        show.deinit(app.gpa);
        return false;
    }
    show.energy = app.session.current(edit.index).?.energy;
    app.showChanged(edit.index, show);
    return true;
}

/// Frame `index` now has the atoms in `frame` (takes ownership).
fn showChanged(app: *App, index: usize, frame: Frame) void {
    const d = &app.doc.?;
    // Cached steps for interpolation are stale.
    for ([_]*?Frame{ &d.next, &d.prev, &d.next2 }, [_]usize{ d.next_index, d.prev_index, d.next2_index }) |slot, i| {
        if (slot.* != null and i == index) {
            slot.*.?.deinit(app.gpa);
            slot.* = null;
        }
    }
    var new = frame;
    if (d.shown_index != index) return new.deinit(app.gpa);
    if (d.shown) |*old| old.deinit(app.gpa);
    d.shown = new;
    app.dropInvalidSelection();
    app.bonds_dirty = true;
}

/// Show a change made by undo or revert, with the cuts that go with it.
fn applyChange(app: *App, change: cv.edit.EditSession.Change) void {
    const d = &app.doc.?;
    if (change.cuts) |cs| {
        app.cut_bonds.deinit(app.gpa);
        app.cut_bonds = cs;
        app.scene_dirty = true;
    }
    if (app.takeFrame(change.index)) |f| {
        app.showChanged(change.index, f);
    } else if (d.shown_index == change.index) {
        // Out of memory: `update` tries again.
        if (d.shown) |*f| f.deinit(app.gpa);
        d.shown = null;
    }
}

/// Delete the selected atoms from the current frame (undoable).
pub fn deleteSelection(app: *App) void {
    app.deleteSelectionInner() catch |e| app.setStatus("Delete failed: {t}", .{e});
}

fn deleteSelectionInner(app: *App) !void {
    const gpa = app.gpa;
    if (app.selected().len == 0) return app.setStatus("Select atoms to delete", .{});
    var edit = try app.beginEdit();
    defer edit.deinit();
    const f = edit.atoms;
    const sel = app.selected();
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

    const n = sel.len;
    edit.replace(try f.without(gpa, remove));
    if (!try app.commitEdit(&edit, app.cut_bonds)) unreachable; // atoms were removed
    // The history now owns the old cuts.
    app.cut_bonds = new_cuts;
    app.selection.clearRetainingCapacity();
    app.scene_dirty = true;
    app.setStatus("Deleted {d} atom{s} (Ctrl+Z undoes)", .{ n, if (n == 1) "" else "s" });
}

pub fn undo(app: *App) void {
    const d = &(app.doc orelse return);
    app.endDrag(false);
    if (!app.session.canUndo()) return;
    app.stopForEdit();
    const change = app.session.undo().?;
    app.applyChange(change);
    if (d.current != change.index) app.setFrame(change.index);
    app.setStatus("Undid the last change to frame {d}", .{change.index + 1});
}

/// Make the shown frame its file frame again (one geometry step).
pub fn revertFrame(app: *App) void {
    const d = &(app.doc orelse return);
    app.stopForEdit();
    const change = app.session.revert(d.shown_index, app.cut_bonds) catch |e| return app.setStatus("Revert failed: {t}", .{e});
    app.applyChange(change orelse return);
    // The frame asked for may be another one that can't be read.
    app.moveTo(d.shown_index);
    app.setStatus("Reverted frame {d} to the file (Ctrl+Z undoes)", .{d.shown_index + 1});
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
        if (c.igMenuItem_Bool("Close", null, false, app.doc != null)) app.closeDocument();
        c.igSeparator();
        if (c.igMenuItem_Bool("Quit", "Ctrl+Q", false, true)) app.quit_requested = true;
        c.igEndMenu();
    }
    if (c.igBeginMenu("Edit", true)) {
        if (c.igMenuItem_Bool("Undo geometry edit", "Ctrl+Z", false, app.session.canUndo())) app.undo();
        const edited = if (app.doc) |d| app.session.isEdited(d.shown_index) else false;
        if (c.igMenuItem_Bool("Delete selected atoms", "Del", false, app.selection.items.len > 0)) app.deleteSelection();
        if (c.igMenuItem_Bool("Revert frame to file", null, false, edited)) app.revertFrame();
        c.igSeparator();
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
            ui.text("Frame {d} / {d}{s}", .{ d.shown_index + 1, d.frameCount(), if (app.session.isEdited(d.shown_index)) "  (edited)" else "" });
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
    var shading: c_int = @backingInt(app.style.shading);
    if (c.igRadioButton_IntPtr("Cel", &shading, 0)) app.scene_dirty = true;
    ui.tooltip("Toon bands with outlines.");
    c.igSameLine(0, -1);
    if (c.igRadioButton_IntPtr("Flat", &shading, 1)) app.scene_dirty = true;
    ui.tooltip("Inspired by Kurzgesagt's flat illustrations: solid colours, flat drop shadows, depth shown by fading into the background.");
    c.igSameLine(0, -1);
    if (c.igRadioButton_IntPtr("Aero", &shading, 2)) app.scene_dirty = true;
    ui.tooltip("Glossy, in the spirit of Frutiger Aero: glassy atoms with highlight caps, in front of a sky (or an aurora at night) with bubbles and lens flare.");
    c.igSameLine(0, -1);
    if (c.igRadioButton_IntPtr("Glass", &shading, 3)) app.scene_dirty = true;
    ui.tooltip("Experimental: liquid glass. Translucent tinted glass atoms and bonds that refract whatever is behind them, other glass included, with bright rims.");
    app.style.shading = @fromBackingInt(@intCast(shading));
    if (app.style.shading == .glass) {
        if (c.igCheckbox("Liquid", &app.style.liquid)) app.scene_dirty = true;
        ui.tooltip("Bonds flow into the atoms, like drops of liquid glass, instead of separate balls and sticks.");
    }
    if (app.style.shading == .flat) {
        _ = c.igCheckbox("Soft shadow + outline", &app.style.flat_pop);
        ui.tooltip("Experiment: blurred drop shadows and a thin dark outline, so the molecule stands out more.");
    }
    if (app.style.shading == .cel) {
        _ = c.igSliderFloat("Outline", &app.style.outline_px, 0, 4, "%.1f px", 0);
    }
    c.igAlignTextToFramePadding();
    ui.text("Background", .{});
    c.igSameLine(0, -1);
    if (c.igRadioButton_Bool("None", !app.style.background_pattern)) app.style.background_pattern = false;
    ui.tooltip("Plain solid colour.");
    c.igSameLine(0, -1);
    if (app.style.shading == .aero) {
        // Aero has its own scenery.
        if (c.igRadioButton_Bool("Sky", app.style.background_pattern)) app.style.background_pattern = true;
        ui.tooltip("Sky dome with bubbles (aurora night in the dark theme); turns with the camera.");
    } else {
        inline for (.{
            .{ "Space", .space, "Glowing bokeh, haze and sparkle stars, out of focus; turns with the camera." },
            .{ "Cells", .cells, "Blobs with membranes and nuclei, out of focus as if seen up close; turns with the camera." },
        }, 0..) |o, i| {
            if (i > 0) c.igSameLine(0, -1);
            if (c.igRadioButton_Bool(o[0], app.style.background_pattern and app.style.backdrop == o[1])) {
                app.style.background_pattern = true;
                app.style.backdrop = o[1];
            }
            ui.tooltip(o[2]);
        }
    }
    if (app.style.background_pattern) {
        _ = c.igSliderFloat("Background blur", &app.style.background_blur, 0, 2.5, "%.2f", 0);
        ui.tooltip("Depth of field: the molecule stays in focus and the backdrop blurs with distance. Zooming in blurs it more.");
    }
    if (c.igSliderFloat("Atom scale", &app.style.atom_scale, 0.2, 3.0, "%.2f", 0)) app.scene_dirty = true;
    if (c.igSliderFloat("Bond radius", &app.style.bond_radius, 0.03, 0.3, "%.2f Å", 0)) app.scene_dirty = true;
    if (c.igButton("Fit view (F)", ui.v2(0, 0))) app.fitCamera();

    if (c.igCollapsingHeader_TreeNodeFlags("Mouse & keys", 0)) ui.textWrapped("Left drag: rotate. Right drag: roll (left/right), zoom (up/down). Middle drag, or Shift + any drag: translate. Wheel: zoom. Space: play. Left/Right keys: step. Right drag on the timeline: scrub one frame per pixel. F: fit. Double-click a bond: cut / restore it.", .{});
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

// --------------------------------------------------------------- tests

/// An app with a file open, without a window or GPU: SDL ignores the window
/// and nothing is drawn.
const TestApp = struct {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    app: App,

    /// Three H atoms in a row per frame, with the frame number as energy.
    fn init(frames: usize) !TestApp {
        var t: TestApp = .{ .app = .{ .io = io, .gpa = gpa, .window = @ptrFromInt(64), .renderer = undefined, .session = .init(gpa) } };
        errdefer t.deinit();
        try t.open(frames);
        return t;
    }

    fn deinit(t: *TestApp) void {
        t.app.deinitState();
    }

    fn open(t: *TestApp, frames: usize) !void {
        var text: Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        for (0..frames) |i| try text.writer.print("3\nenergy={d}\nH 0 0 0\nH 0 0 1\nH 0 0 2\n", .{i});
        try t.openText(text.written());
    }

    fn openText(t: *TestApp, text: []const u8) !void {
        var opened = try cv.source.openBytes(gpa, text);
        errdefer opened.source.deinit(io, gpa);
        try t.app.install(opened, "test.xyz");
    }

    /// Goes to a frame and waits until it is shown.
    fn show(t: *TestApp, index: usize) !void {
        t.app.setFrame(index);
        try t.settle();
    }

    fn settle(t: *TestApp) !void {
        const d = &t.app.doc.?;
        for (0..2000) |_| {
            d.stream.request(d.current);
            t.app.pullFrame();
            if (d.shown != null and d.shown_index == d.current) return;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.TestTimeout;
    }

    fn setDistance(t: *TestApp, v: f64) void {
        t.app.selection.clearRetainingCapacity();
        t.app.toggleSelect(0);
        t.app.toggleSelect(1);
        t.app.applyEdit(.{ .distance = v });
    }

    /// Starts an Alt-drag of atom 1, as if it had been grabbed.
    fn startDrag(t: *TestApp) !void {
        try t.app.startDrag(.translate, 1);
    }

    /// A drag of atom 1 on the shown frame that has moved it.
    fn dragSome(t: *TestApp) !void {
        try t.startDrag();
        t.app.dragMotion(0, 0, 0.1, 0);
        try expect(t.app.doc.?.shown.?.positions[1][0] != 0);
    }

    /// No drag is going on, and it left nothing behind in frame 0.
    fn expectAborted(t: *TestApp) !void {
        try expect(t.app.drag == null);
        // The release that follows does nothing.
        t.app.endDrag(true);
        try expect(!t.app.session.isEdited(0));
        try expect(!t.app.session.canUndo());
        const d = &t.app.doc.?;
        if (d.shown_index == 0) try expectEqual(Vec3{ 0, 0, 1 }, d.shown.?.positions[1]);
    }

    /// Two steps apart in y, playing with interpolation at `at` between them.
    fn playBlend(t: *TestApp, at: f32) !void {
        try t.openText("2\n\nH 0 0 0\nH 10 0 0\n" ++ "2\n\nH 0 2 0\nH 10 2 0\n");
        try t.show(0);
        t.app.fitCamera();
        t.app.interpolate = true;
        t.app.playing = true;
        t.app.interp_t = at;
        for (0..2000) |_| {
            t.app.updateNextFrame();
            if (t.app.nextReady()) return;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.TestTimeout;
    }

    fn distance(t: *TestApp) f64 {
        return cv.geometry.distance(t.app.doc.?.shown.?.positions, 0, 1);
    }

    fn expectCopyEdited(t: *TestApp, want: bool) !void {
        const text = try t.app.copyText();
        defer gpa.free(text);
        try std.testing.expectEqual(want, std.mem.find(u8, text, "edited=T") != null);
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "undoing a frame's last edit makes it its file frame again" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(1);
    t.setDistance(1.5);
    t.setDistance(1.7);
    try expectEqual(null, t.app.doc.?.shown.?.energy);
    t.app.undo();
    try t.expectCopyEdited(true);
    t.app.undo();
    try t.settle();
    try expectEqual(1, t.distance());
    try expectEqual(1, t.app.doc.?.shown.?.energy);
    try t.expectCopyEdited(false);
}

test "revert can be undone, and leaves other frames' history alone" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    t.setDistance(1.5);
    try t.show(1);
    t.setDistance(1.7);
    t.app.revertFrame();
    try t.settle();
    try expectEqual(1, t.distance());
    try t.expectCopyEdited(false);
    t.app.undo();
    try t.settle();
    try std.testing.expectApproxEqAbs(1.7, t.distance(), 1e-5);
    try t.expectCopyEdited(true);
    t.app.undo(); // frame 2's edit
    t.app.undo(); // frame 1's, jumping there
    try t.settle();
    try expectEqual(0, t.app.doc.?.shown_index);
    try expectEqual(1, t.distance());
    try expectEqual(0, t.app.doc.?.shown.?.energy);
}

test "closing or opening a file resets everything about the old one" {
    for ([_]bool{ false, true }) |reopen| {
        var t: TestApp = try .init(2);
        defer t.deinit();
        try t.show(0);
        t.setDistance(1.5);
        t.app.toggleCutPair(0, 1);
        t.app.lasso_active = true;
        try t.startDrag();
        t.app.playing = true;
        t.app.interp_t = 0.5;
        if (reopen) try t.open(2) else t.app.closeDocument();
        try expectEqual(0, t.app.selection.items.len);
        try expectEqual(0, t.app.cut_bonds.count());
        try expect(!t.app.playing);
        try expectEqual(0, t.app.interp_t);
        try expect(!t.app.lasso_active);
        try expect(t.app.drag == null);
        if (!reopen) try t.open(2);
        try t.show(0);
        t.app.undo(); // nothing left to undo
        try expectEqual(1, t.distance());
        try t.expectCopyEdited(false);
    }
}

test "asking for another frame aborts a drag" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    try t.dragSome();
    t.app.setFrame(0); // already there
    try expect(t.app.drag != null);
    t.app.setFrame(1);
    try t.expectAborted();
    try t.settle();
    try expectEqual(1, t.distance());
}

test "a frame with fewer atoms arriving aborts a drag" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("3\n\nH 0 0 0\nH 0 0 1\nH 0 0 2\n" ++ "1\n\nH 5 5 5\n");
    try t.show(0);
    t.app.setFrame(1); // asked for, but frame 0 is still shown
    try t.dragSome();
    try t.settle();
    try t.expectAborted();
    t.app.dragMotion(0, 0, 0.1, 0);
    try expectEqual(1, t.app.doc.?.shown.?.len());
    try expectEqual(Vec3{ 5, 5, 5 }, t.app.doc.?.shown.?.positions[0]);
}

test "starting playback aborts a drag" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    try t.dragSome();
    t.app.togglePlay();
    try t.expectAborted();
    try expect(t.app.playing);
}

test "opening a file that can't be read aborts a drag" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    try t.dragSome();
    t.app.openFile("no/such/file.xyz");
    try t.expectAborted();
}

test "undo and revert abort a drag, then go ahead" {
    for ([_]bool{ false, true }) |revert| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.show(0);
        t.setDistance(1.5);
        try t.startDrag();
        t.app.dragMotion(0, 0, 0.1, 0);
        if (revert) t.app.revertFrame() else t.app.undo();
        try expect(t.app.drag == null);
        try expect(!t.app.session.isEdited(0));
        try expectEqual(1, t.distance());
        if (revert) t.app.undo();
        if (revert) t.app.undo();
        try t.expectAborted();
    }
}

test "undo with nothing to undo aborts a drag" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.show(0);
    try t.dragSome();
    t.app.undo();
    try t.expectAborted();
}

test "paste and delete abort a drag, then go ahead on the atoms as they were" {
    for ([_]bool{ false, true }) |delete| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.show(0);
        t.app.toggleSelect(2);
        try t.dragSome();
        if (delete) {
            t.app.deleteSelection();
        } else {
            var frag = try t.app.doc.?.shown.?.subset(TestApp.gpa, &.{0});
            defer frag.deinit(TestApp.gpa);
            try t.app.appendFragment(frag);
        }
        try expect(t.app.drag == null);
        const f = t.app.doc.?.shown.?;
        try expectEqual(@as(usize, if (delete) 2 else 4), f.len());
        try expectEqual(Vec3{ 0, 0, 1 }, f.positions[1]);
        t.app.undo();
        try t.expectAborted();
    }
}

test "closing aborts a drag" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.show(0);
    try t.dragSome();
    t.app.closeDocument();
    try expect(t.app.drag == null);
    try expect(!t.app.session.canUndo());
}

test "a completed drag is one geometry step, a cancelled one none" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.show(0);
    try t.dragSome();
    t.app.dragMotion(0, 0, 0.1, 0);
    t.app.endDrag(false);
    try t.expectAborted();
    try t.dragSome();
    t.app.dragMotion(0, 0, 0.1, 0);
    t.app.endDrag(true);
    try t.expectCopyEdited(true);
    try expectEqual(null, t.app.doc.?.shown.?.energy);
    t.app.undo();
    try t.expectAborted();
}

test "an edit during interpolated playback pauses it and applies to the nearest step" {
    const Kind = enum { drag, set, paste, delete };
    for ([_]Kind{ .drag, .set, .paste, .delete }) |kind| for ([_]f32{ 0.3, 0.7 }) |at| {
        errdefer std.debug.print("{t} at {d}\n", .{ kind, at });
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.playBlend(at);
        t.app.selection.clearRetainingCapacity();
        switch (kind) {
            .drag => {
                try t.startDrag();
                t.app.dragMotion(0, 0, 0.1, 0);
                t.app.endDrag(true);
            },
            .set => t.setDistance(5),
            .paste => {
                var frag = try t.app.doc.?.shown.?.subset(TestApp.gpa, &.{0});
                defer frag.deinit(TestApp.gpa);
                try t.app.appendFragment(frag);
            },
            .delete => {
                t.app.toggleSelect(1);
                t.app.deleteSelection();
            },
        }
        const want: usize = if (at < 0.5) 0 else 1;
        const d = &t.app.doc.?;
        try expect(!t.app.playing);
        try expectEqual(0, t.app.interp_t);
        try expectEqual(want, d.current);
        try expectEqual(want, d.shown_index);
        try expect(t.app.session.isEdited(want));
        try expect(!t.app.session.isEdited(1 - want));
        // Atom 0 is where that step has it (none of these move it).
        const y: f32 = if (want == 0) 0 else 2;
        try expectEqual(Vec3{ 0, y, 0 }, d.shown.?.positions[0]);
    };
}

test "an edit while playback waits for the next frame applies to the one on screen" {
    var t: TestApp = try .init(3);
    defer t.deinit();
    try t.show(0);
    t.app.playing = true;
    t.app.doc.?.current = 1; // not loaded yet
    t.setDistance(1.5);
    try expect(!t.app.playing);
    try expectEqual(0, t.app.doc.?.current);
    try expect(t.app.session.isEdited(0));
}

test "undo and revert during playback pause it" {
    for ([_]bool{ false, true }) |revert| {
        var t: TestApp = try .init(2);
        defer t.deinit();
        try t.show(1);
        t.setDistance(1.5);
        t.app.playing = true;
        t.app.interp_t = 0.2;
        if (revert) t.app.revertFrame() else t.app.undo();
        try expect(!t.app.playing);
        try expectEqual(0, t.app.interp_t);
        try expectEqual(1, t.app.doc.?.current);
        try expect(!t.app.session.isEdited(1));
    }
}

test "a drag grabs the atom that was drawn under the cursor" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlend(0.7);
    const p = t.app.displayPositions(t.app.doc.?.shown.?)[1];
    try expect(p[1] > 1 and p[1] < 1.9);
    const at = t.app.screenProjector().toScreen(p).?;
    t.app.beginDrag(.translate, at.x, at.y);
    try expectEqual(1, t.app.doc.?.shown_index);
    const hint = t.app.drag orelse return error.TestUnexpectedResult;
    try expectEqual(1, hint.handle);
}
