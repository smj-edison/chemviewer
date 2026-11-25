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
const timeline_mod = @import("timeline.zig");
const plot_mod = @import("plot.zig");
const measure = @import("measure.zig");
const lasso = @import("lasso.zig");
const drag_mod = @import("drag.zig");
const messages_mod = @import("messages.zig");
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
    /// What is on screen (its frame may lag `current` while that loads).
    display: cv.display.DisplayedGeometry = .{},
    needs_fit: bool = true,

    pub fn frameCount(d: *const Document) usize {
        return d.stream.frameCount();
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
diff: ?cv.diff.Diff = null,

playing: bool = false,
fps: f32 = 15,
loop_playback: bool = true,
/// Right-drag scrubbing on the timeline (null = not scrubbing): pixels moved
/// that don't add up to a whole frame yet.
fine_scrub: ?f32 = null,
/// Frame last scrubbed to by the current drag on the energy plot.
plot_drag: ?usize = null,
timeline: plot_mod.State = .{},
/// Keep the structure's orientation steady across frames (see `cv.lock`).
lock_rotation: bool = false,
rotation_lock: ?cv.lock.RotationLock = null,
/// What the lock followed last (null = nothing).
lock_followed: ?LockFollowed = null,
last_advance: Io.Timestamp = .zero,
/// Interpolated playback: render at the display's frame rate, blending atom
/// positions between steps; pausing goes back to the step played from.
interpolate: bool = false,
/// Fraction of the way from the shown step to the next (0 when not blending).
interp_t: f32 = 0,
/// What the scene was last built from (null = build it again).
scene_key: ?SceneKey = null,
/// Counted to tell documents and diffs apart.
documents_opened: u64 = 0,
diffs_started: u64 = 0,
scene_radius: f32 = 10,
show_inspector: bool = true,
show_diff: bool = false,
show_atom_numbers: bool = false,
/// Element symbols on atoms whose colour another present element shares.
show_element_labels: bool = true,
/// User multiplier on top of the monitor's content scale (View menu).
ui_scale: f32 = 1.0,
/// What the View menu slider shows while it is dragged.
ui_scale_edit: ?f32 = null,
settings: cv.settings.Settings = .{},
/// Changed, but not saved yet.
settings_changed: bool = false,
/// The last attempt to save them failed.
settings_unsaved: bool = false,
/// The looks when `rememberLooks` was last there.
looks_seen: ?cv.settings.Settings = null,
/// Where they are kept (null = nowhere).
settings_path: ?[]u8 = null,
/// Font size the panel layout was last placed for; when it changes the
/// panels are re-placed so they scale with the UI.
layout_font_size: f32 = 0,
quit_requested: bool = false,

messages: messages_mod.Messages = .{},
/// What the mouse is on in the view.
hover: ?Target = null,
/// What `hoverGroup` found last, and for what.
hover_group: []u32 = &.{},
hover_key: ?HoverKey = null,
/// When an edit switched Lock rotation off (see `seconds`).
unlocked_at: ?f64 = null,
show_help: bool = false,

/// Path delivered by the (possibly off-thread) SDL file dialog callback.
dialog_path: [4096]u8 = undefined,
dialog_ready: std.atomic.Value(bool) = .init(false),
save_path: [4096]u8 = undefined,
save_ready: std.atomic.Value(bool) = .init(false),
save_dialog_open: std.atomic.Value(bool) = .init(false),
/// What the save dialog was opened for.
save_what: struct { what: cv.saving.What, document: u64 } = .{ .what = .all, .document = 0 },
saving: ?*cv.saving.Saving = null,
/// What the user is being asked about (see `leave`).
leaving: ?Leaving = null,

/// The selection and cuts of the shown frame.
picks: cv.picks.Picks = .{},
edit_mode: cv.geometry.Mode = .last,
/// The current atoms of every frame, and the undo history.
session: cv.edit.EditSession,
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
/// Button of an aborted drag; moving does nothing until it is let go.
aborted_button: ?u8 = null,

/// What was drawn: the displayed geometry, how far blended.
const LockFollowed = struct { changes: u64, blend: f32, held: u64 };
const pairKey = cv.picks.pairKey;

pub fn init(io: Io, gpa: Allocator, window: *c.SDL_Window, gpu: *Gpu) !App {
    return .{ .io = io, .gpa = gpa, .window = window, .renderer = try Renderer.init(gpa, gpu), .session = .init(gpa) };
}

pub fn deinit(app: *App) void {
    app.deinitState();
    app.renderer.deinit();
}

/// Everything but the renderer.
fn deinitState(app: *App) void {
    if (app.settings_changed or app.settings_unsaved) app.saveSettings();
    if (app.settings_path) |p| app.gpa.free(p);
    app.setHoverGroup(null, &.{});
    app.timeline.deinit(app.gpa);
    app.closeDocument();
    app.session.deinit();
    app.picks.deinit(app.gpa);
    app.lasso_points.deinit(app.gpa);
}

/// Say what was done.
pub fn inform(app: *App, comptime fmt: []const u8, args: anytype) void {
    app.say(.info, fmt, args);
}

/// Say why what the user asked for isn't possible.
pub fn refuse(app: *App, comptime fmt: []const u8, args: anytype) void {
    app.say(.refusal, fmt, args);
}

/// Say what went wrong.
pub fn fail(app: *App, comptime fmt: []const u8, args: anytype) void {
    app.say(.failure, fmt, args);
}

fn say(app: *App, kind: messages_mod.Kind, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    app.messages.add(kind, app.seconds(), s);
    std.log.info("{s}", .{s});
}

/// The time, for messages.
pub fn seconds(app: *const App) f64 {
    return @as(f64, @floatFromInt(Io.Timestamp.now(app.io, .awake).nanoseconds)) / std.time.ns_per_s;
}

// ------------------------------------------------------------ documents

/// Also resets everything about the open file: edits, history, selection,
/// cuts, gestures in progress, playback and diff.
pub fn closeDocument(app: *App) void {
    app.stopSaving();
    app.endDrag(false);
    app.session.clear();
    app.picks.clear(app.gpa);
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
    d.display.deinit(app.gpa);
    app.gpa.free(d.path);
    app.doc = null;
    app.unlockRotation();
}

pub fn openFile(app: *App, path: []const u8) void {
    app.endDrag(false);
    app.openFileInner(path) catch |e| {
        app.fail("Could not open {s}: {t}", .{ std.fs.path.basename(path), e });
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
    app.documents_opened += 1;
    app.doc = .{ .path = owned_path, .format = opened.format, .source = src, .stream = stream };
    app.inform("Opened {s} ({s}, {d} frame{s})", .{
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
    app.copyXyzInner() catch |e| app.fail("Copy failed: {t}", .{e});
}

fn copyXyzInner(app: *App) !void {
    const d = app.doc orelse return;
    const f = d.display.real.frame orelse return;
    const text = try app.copyText();
    defer app.gpa.free(text);
    try setClipboardText(text);
    const n = if (app.selected().len == 0) f.len() else app.selected().len;
    app.inform("Copied {d} atom{s} as XYZ", .{ n, if (n == 1) "" else "s" });
}

/// What `copyXyz` copies. Owned by the caller.
fn copyText(app: *App) ![]u8 {
    const gpa = app.gpa;
    const d = app.doc orelse return error.NoDocument;
    const f = d.display.real.frame orelse return error.NoDocument;
    const sel = app.selected();
    const whole = sel.len == 0 or sel.len == f.len();

    var comment: std.Io.Writer.Allocating = .init(gpa);
    defer comment.deinit();
    const cw = &comment.writer;
    try cw.print("chemviewer source=\"{s}\" frame={d}/{d}", .{ std.fs.path.basename(d.path), d.display.real.index + 1, d.frameCount() });
    if (!whole) {
        try cw.writeAll(" atoms=\"");
        try cv.formats.xyz.writeAtomRanges(cw, sel);
        try cw.writeAll("\"");
        if (f.energy) |e| try cw.print(" frame_energy={d}", .{e});
    }
    if (app.session.isEdited(d.display.real.index)) try cw.writeAll(" edited=T");

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
    app.endDrag(false);
    app.pasteXyzInner(as_new) catch |e| app.refuse("Nothing pasteable on the clipboard ({t})", .{e});
}

fn pasteXyzInner(app: *App, as_new: bool) !void {
    if (!c.SDL_HasClipboardText()) return error.Empty;
    const raw = c.SDL_GetClipboardText() orelse return error.Empty;
    defer c.SDL_free(raw);
    const text = std.mem.span(raw);
    var opened = try cv.source.openBytes(app.gpa, text);
    errdefer opened.source.deinit(app.io, app.gpa);
    const has_frame = if (app.doc) |d| d.display.real.frame != null else false;
    if (!as_new and has_frame) {
        defer opened.source.deinit(app.io, app.gpa);
        return app.appendFragment(opened.source.memory[0]);
    }
    try app.install(opened, "clipboard.xyz");
    app.inform("Pasted {d} atom{s} from the clipboard", .{
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
    const f = &app.doc.?.display.real.frame.?;
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
    const pasted = try gpa.alloc(u32, frag.len());
    defer gpa.free(pasted);
    for (pasted, first..) |*atom, i| atom.* = @intCast(i);
    try edit.append(frag, offset);
    if (!try app.commitRenumbering(&edit, pasted)) return app.refuse("No atoms to paste", .{});
    // Re-frame if any pasted atom is off-screen. The background stays put in
    // the world, so it doesn't turn if frames were followed before.
    const sp = app.screenProjector();
    for (f.positions[first..]) |p| {
        if (sp.toScreen(p)) |q| if (q.x >= 0 and q.y >= 0 and q.x <= sp.w and q.y <= sp.h) continue;
        if (app.boundingSphere()) |s| app.camera.reframe(s.center, s.radius);
        break;
    }
    app.inform("Pasted {d} atom{s} as a fragment{s}", .{
        frag.len(), if (frag.len() == 1) "" else "s", if (offset[0] != 0 or offset[1] != 0 or offset[2] != 0) " (moved beside the structure)" else "",
    });
}

/// Append the first frame of a file as a fragment (File > Add fragment).
pub fn addFragmentFile(app: *App, path: []const u8) !void {
    app.endDrag(false);
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
    if (to != d.current and to != d.display.real.index) app.endDrag(false);
    d.current = to;
    app.interp_t = 0;
    // Ask the loader right away (the UI sets frames mid-frame, after update()).
    d.stream.request(d.current);
}

/// True when the displayed frame is the requested one, or that one can't be
/// read (the last good frame then stays on screen).
pub fn isSettled(app: *const App) bool {
    const d = app.doc orelse return true;
    if (d.display.real.frame != null and d.display.real.index == d.current) return true;
    return d.stream.state(d.current) == .failed;
}

/// Pull the requested frame from the stream when it's ready. Call once per UI frame.
pub fn update(app: *App) void {
    if (app.dialog_ready.load(.acquire)) {
        const p = std.mem.sliceTo(&app.dialog_path, 0);
        var copy: [4096]u8 = undefined;
        @memcpy(copy[0..p.len], p);
        app.dialog_ready.store(false, .release);
        app.leaveToOpen(copy[0..p.len]);
    }
    if (app.save_ready.load(.acquire)) {
        const p = std.mem.sliceTo(&app.save_path, 0);
        var copy: [4096]u8 = undefined;
        @memcpy(copy[0..p.len], p);
        app.save_ready.store(false, .release);
        app.save_dialog_open.store(false, .release);
        // Another file may have been opened meanwhile.
        if (app.save_what.document == app.documents_opened) app.startSaving(app.save_what.what, copy[0..p.len]);
    }
    app.saveSome(0.01);

    const d = &(app.doc orelse return);
    app.advancePlayback();
    d.stream.request(d.current);
    app.pullFrame();
    app.reportFailures(d);
    app.updateNextFrame();
    app.refresh();
}

/// The frames of a diff overlay: told apart with any colour vision, and not
/// the red of cut bonds and oxygen.
pub const reference_color: [3]f32 = .{ 1.0, 0.50, 0.0 };
pub const current_color: [3]f32 = .{ 0.10, 0.45, 1.0 };

/// Everything the scene is drawn from. It is built again when this differs.
const SceneKey = struct {
    document: u64 = 0,
    changes: u64 = 0,
    blend: f32 = 0,
    /// Counts the steps held, during a blend.
    held: u64 = 0,
    picks: u64,
    style: Renderer.Style,
    bond_params: cv.bonds.Params,
    /// A diff overlay, and the placement of its reference.
    overlay: ?struct { diff: u64, placement: [15]u64 } = null,
};

fn sceneKey(app: *const App) SceneKey {
    var key: SceneKey = .{ .picks = app.picks.hash(), .style = app.style, .bond_params = app.bond_params };
    // Only matter when drawing it.
    const any: Renderer.Style = .{};
    key.style.outline_px = any.outline_px;
    key.style.flat_pop = any.flat_pop;
    key.style.background_pattern = any.background_pattern;
    key.style.background_blur = any.background_blur;
    key.style.backdrop = any.backdrop;
    const d = app.doc orelse return key;
    key.document = app.documents_opened;
    key.changes = d.display.real.changes;
    key.blend = app.blendTime();
    if (key.blend > 0) key.held = d.display.held_changes;
    if (app.drawnReference() != null)
        key.overlay = .{ .diff = app.diffs_started, .placement = app.diff.?.placement.bits() };
    return key;
}

/// Bring the scene in line with everything else. Part of `update`; call it
/// again after `drawUi`, so that what the UI changed is never drawn half (a
/// moved camera with the old scene).
pub fn refresh(app: *App) void {
    app.updateDiff();
    if (app.doc) |*d| if (d.needs_fit and d.display.real.frame != null) {
        d.needs_fit = false;
        app.fitCamera();
    };
    app.followRotationLock();
    const key = app.sceneKey();
    if (std.meta.eql(app.scene_key, @as(?SceneKey, key))) return;
    app.scene_key = key;
    app.rebuildScene() catch |e| {
        app.scene_key = null; // try again
        app.fail("Scene build failed: {t}", .{e});
    };
}

/// Shows the requested frame if it's ready.
fn pullFrame(app: *App) void {
    const d = &(app.doc orelse return);
    if (d.display.real.frame != null and d.display.real.index == d.current) return;
    app.showFrame(d.current, app.takeFrame(d.current) orelse return);
}

/// Puts another frame on screen (takes ownership of its atoms).
fn showFrame(app: *App, index: usize, frame: Frame) void {
    const d = &app.doc.?;
    app.endDrag(false);
    d.display.real.show(app.gpa, index, frame);
    app.followDisplay();
}

/// An owned copy of the current atoms of a frame, or null if it isn't ready.
fn takeFrame(app: *App, index: usize) ?Frame {
    const d = &(app.doc orelse return null);
    if (app.session.current(index)) |f| return f.clone(app.gpa) catch null;
    const got = d.stream.take(app.gpa, index) catch return null;
    return if (got == .ready) got.ready else null;
}

/// Names the frames that newly couldn't be read, in one message since only
/// a few fit.
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
    if (more > 0) return app.fail("Could not read frames {d}{s} and {d} more: {t}", .{ first.index + 1, list, more, first.err });
    app.fail("Could not read frame{s} {d}{s}: {t}", .{ if (list.len > 0) "s" else "", first.index + 1, list, first.err });
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
        .shown = if (d.display.real.frame != null) d.display.real.index else null,
    });
    d.current = head.current;
    app.playing = head.playing;
    app.last_advance = head.last;
    app.interp_t = head.t;
}

/// The step after the shown one is loaded and can be blended with it.
fn nextReady(app: *const App) bool {
    const d = app.doc orelse return false;
    const next = d.display.next orelse return false;
    return d.display.real.frame != null and d.display.real.index == d.current and next.index > d.current and
        app.diff == null and app.numberedAsShown(next);
}

/// Whether atom numbers mean the same atoms in `step` as in the shown frame.
fn numberedAsShown(app: *const App, step: cv.display.DisplayedGeometry.Step) bool {
    const real = app.doc.?.display.real;
    return app.numberingOf(real.index, real.frame.?).eql(app.numberingOf(step.index, step.atoms));
}

/// How the atoms of frame `index`, currently `frame`, are numbered.
fn numberingOf(app: *const App, index: usize, frame: Frame) cv.picks.Numbering {
    return .{ .numbers = frame.numbers, .origins = app.session.origins(index) };
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
    app.keepFrame(.next, next);
    app.keepFrame(.prev, if (next != null and i >= 1) d.stream.prevPlayable(i) else null);
    app.keepFrame(.next2, next2);
}

/// Makes `slot` hold frame `want` (taken from the stream's cache when
/// ready), or nothing.
fn keepFrame(app: *App, slot: cv.display.DisplayedGeometry.Slot, want: ?usize) void {
    const g = &app.doc.?.display;
    if (g.holds(slot, want)) return;
    const atoms = if (want) |w| app.takeFrame(w) else null;
    g.keep(app.gpa, slot, if (atoms) |a| .{ .index = want.?, .atoms = a } else null);
}

/// How far the drawn atoms are from the shown step to the next.
pub fn blendTime(app: *const App) f32 {
    return if (app.nextReady()) app.interp_t else 0;
}

pub fn fitCamera(app: *App) void {
    const s = app.boundingSphere() orelse return;
    app.camera.fit(s.center, s.radius);
}

/// Sphere around everything drawn of the shown frame; also sets `scene_radius`.
fn boundingSphere(app: *App) ?struct { center: Vec3, radius: f32 } {
    const d = app.doc orelse return null;
    const f = d.display.real.frame orelse return null;
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
    const reference: []const Vec3 = app.drawnReference() orelse &.{};
    for (reference) |p| {
        b.min = @min(b.min, p);
        b.max = @max(b.max, p);
    }
    const center = (b.min + b.max) * cv.math.splat(0.5);
    // Bounding sphere around the box centre: farthest atom plus its display radius.
    var radius: f32 = 0;
    for (f.positions, f.numbers) |p, z| {
        radius = @max(radius, cv.math.length(p - center) + app.style.atomRadius(z));
    }
    if (reference.len > 0) for (reference, app.diff.?.numbering().numbers) |p, z| {
        radius = @max(radius, cv.math.length(p - center) + app.style.atomRadius(z));
    };
    if (app.style.show_cell) if (f.cell) |_| {
        radius = @max(radius, cv.math.length(b.max - b.min) * 0.5);
    };
    app.scene_radius = radius;
    return .{ .center = center, .radius = radius };
}

fn rebuildScene(app: *App) !void {
    const r = &app.renderer;
    r.clear();
    const d = app.doc orelse return r.upload();
    const f = d.display.real.frame orelse return r.upload();
    if (app.drawnReference()) |reference| {
        const df = &app.diff.?;
        // Unlocked, it may be far off; don't clip it.
        for (reference) |p| app.scene_radius = @max(app.scene_radius, cv.math.length(p - app.camera.target));
        _ = try r.addStructure(reference, df.numbering().numbers, app.bondsOf(&df.reference), app.style, .{ .color = reference_color }, null);
        const start = try r.addStructure(app.drawnPositions().?, f.numbers, app.bonds(), app.style, .{ .color = current_color }, &app.picks.cuts);
        r.highlight(start, app.selected());
        return r.upload();
    }
    const start = try r.addStructure(app.drawnPositions().?, f.numbers, app.bonds(), app.style, null, &app.picks.cuts);
    r.highlight(start, app.selected());
    if (app.style.show_cell) if (f.cell) |cell| try r.addCell(cell, app.style.theme.cellLine());
    try r.upload();
}

// ------------------------------------------------------------ diff

pub fn setReference(app: *App) void {
    const d = app.doc orelse return;
    const f = d.display.real.frame orelse return;
    const index = d.display.real.index;
    const was_locked = if (app.diff) |df| df.was_locked else app.lock_rotation;
    const new = cv.diff.Diff.init(app.gpa, index, f, app.session.origins(index), was_locked) catch |e|
        return app.fail("Can't set the reference: {t}", .{e});
    if (app.diff) |*old| old.deinit(app.gpa);
    app.diff = new;
    app.diffs_started += 1;
    app.show_diff = true;
    app.setLockRotation(true);
    app.updateDiff();
}

pub fn clearDiff(app: *App) void {
    var df = app.diff orelse return;
    app.diff = null;
    // Without the diff, the lock starts again at the current frame.
    app.setLockRotation(df.was_locked);
    df.deinit(app.gpa);
}

/// Where the reference's atoms are drawn, if they are.
fn drawnReference(app: *const App) ?[]const Vec3 {
    const df = app.diff orelse return null;
    return if (df.overlay and df.result != null) df.placed.items else null;
}

/// Show the reference and the current frame at their file positions.
pub fn resetPlacement(app: *App) void {
    const df = &(app.diff orelse return);
    app.unlockRotation();
    df.place(.identity);
    app.updateDiff();
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
    app.lock_followed = null;
}

/// A geometry edit unlocks. That only stops the updates, so nothing jumps.
fn unlockRotation(app: *App) void {
    if (app.lock_rotation) app.unlocked_at = app.seconds();
    app.lock_rotation = false;
    app.dropRotationLock();
}

/// Starts the lock at what is drawn, or, if that changed, turns the camera by
/// its motion. Blends are followed too, so the view turns evenly between steps
/// instead of correcting at each one. Atoms that don't match the anchor's
/// restart the lock there. While diffing the anchor is the reference: its
/// placement moves with the camera, so on screen it stays still, and other
/// atoms leave both as they are.
fn followRotationLock(app: *App) void {
    if (!app.lock_rotation) return;
    const d = app.doc orelse return;
    const f = d.display.real.frame orelse return;
    const t = app.blendTime();
    const now: LockFollowed = .{ .changes = d.display.real.changes, .blend = t, .held = if (t > 0) d.display.held_changes else 0 };
    if (app.rotation_lock != null and std.meta.eql(app.lock_followed, now)) return;
    const pos = app.drawnPositions() orelse return;
    const numbering = app.numberingOf(d.display.real.index, f);
    if (app.diff) |*df| if (app.rotation_lock == null) {
        // On from where the reference is now.
        app.rotation_lock = cv.lock.RotationLock.init(app.gpa, df.reference.frame.?.positions, df.numbering()) catch return;
        app.rotation_lock.?.current = df.placement.inverse();
    };
    if (app.rotation_lock) |*l| {
        if (l.follow(pos, numbering)) |m| {
            app.camera.followRigid(m.rot, m.from, m.to);
            app.lock_followed = now;
            if (app.diff) |*df| {
                df.place(l.current.inverse());
                app.updateDiff();
            }
            return;
        }
        if (app.diff != null) {
            app.lock_followed = now;
            return;
        }
        app.dropRotationLock();
    }
    app.rotation_lock = cv.lock.RotationLock.init(app.gpa, pos, numbering) catch return;
    app.lock_followed = now;
}

fn updateDiff(app: *App) void {
    const df = &(app.diff orelse return);
    const d = app.doc orelse return;
    const f = d.display.real.frame orelse return;
    df.update(app.gpa, f.positions, app.numberingOf(d.display.real.index, f), d.display.real.changes);
}

// ------------------------------------------------------------ input

pub fn handleEvent(app: *App, ev: *const c.SDL_Event, want_mouse: bool, want_keyboard: bool) void {
    switch (ev.type) {
        c.SDL_EVENT_QUIT => app.leave(.quit),
        c.SDL_EVENT_DROP_FILE => if (ev.drop.data) |p| app.leaveToOpen(std.mem.span(p)),
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (app.aborted_button == ev.button.button) app.aborted_button = null;
            if (want_mouse) return;
            const mods0 = c.SDL_GetModState();
            if ((mods0 & c.SDL_KMOD_ALT) != 0 and app.drag == null) {
                return app.altPress(ev.button.button, (mods0 & c.SDL_KMOD_SHIFT) != 0, ev.button.x, ev.button.y);
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
            if (app.aborted_button == ev.button.button) {
                app.aborted_button = null;
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
            if (app.aborted_button) |button| {
                const held = @as(u32, 1) << @intCast(button -| 1);
                if ((ev.motion.state & held) != 0 and app.drag == null) return;
                // Let go where it wasn't seen.
                if ((ev.motion.state & held) == 0) app.aborted_button = null;
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
        c.SDL_EVENT_MOUSE_WHEEL => {
            // Zooming goes by the hand: up is in, natural scrolling or not.
            const up = if (ev.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -ev.wheel.y else ev.wheel.y;
            if (!want_mouse) return app.camera.zoom(up);
            app.timeline.wheel.x += ev.wheel.x;
            app.timeline.wheel.y += ev.wheel.y;
            app.timeline.wheel.up += up;
        },
        c.SDL_EVENT_KEY_DOWN => {
            if (app.leaving != null) {
                if (ev.key.key == c.SDLK_ESCAPE) app.leaveEsc();
                return;
            }
            if (want_keyboard) return;
            // A drag, which is in the hand, comes first.
            if (ev.key.key == c.SDLK_ESCAPE and app.saving != null and app.drag == null) {
                app.stopSaving();
                return app.inform("Stopped saving", .{});
            }
            const d = &(app.doc orelse return);
            const n = d.frameCount();
            const held = ev.key.repeat;
            switch (ev.key.key) {
                c.SDLK_ESCAPE => if (app.drag != null) app.endDrag(false) else app.deselect(),
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
                c.SDLK_Z => if ((ev.key.mod & c.SDL_KMOD_CTRL) == 0) {
                    app.timeline.window = .all(n);
                },
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
    // Pausing an interpolated playback floors (D24).
    if (!app.playing and app.interp_t > 0) app.moveTo(d.current);
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
    return app.picks.selection.items;
}

pub fn clearSelection(app: *App) void {
    if (app.picks.selection.items.len == 0) return;
    app.picks.selection.clearRetainingCapacity();
}

/// Clear the selection by hand.
pub fn deselect(app: *App) void {
    var before = app.beginGesture() orelse return;
    defer app.endGesture(&before);
    app.clearSelection();
}

/// Cut or restore a bond by hand.
fn cutBond(app: *App, a: u32, b: u32) void {
    var before = app.beginGesture() orelse return;
    defer app.endGesture(&before);
    app.toggleCutPair(a, b);
}

/// Everything the user does to the selection or cuts by hand is between
/// `beginGesture` and `endGesture`, which makes one selection step of it.
fn beginGesture(app: *App) ?cv.picks.Snapshot {
    return app.picks.snapshot(app.gpa) catch |e| {
        app.fail("Can't change the selection: {t}", .{e});
        return null;
    };
}

fn endGesture(app: *App, before: *cv.picks.Snapshot) void {
    defer before.deinit(app.gpa);
    app.session.recordSelection(&app.picks, before.*) catch |e| {
        app.picks.restoreSnapshot(before);
        app.fail("Can't change the selection: {t}", .{e});
    };
}

fn isSelected(app: *const App, atom: u32) ?usize {
    return std.mem.indexOfScalar(u32, app.picks.selection.items, atom);
}

/// Click on an atom: add it to the selection, or remove it if already selected.
pub fn toggleSelect(app: *App, atom: u32) void {
    if (app.isSelected(atom)) |k| {
        _ = app.picks.selection.orderedRemove(k);
    } else {
        app.picks.selection.append(app.gpa, atom) catch return;
    }
}

pub fn isCut(app: *const App, a: u32, b: u32) bool {
    return app.picks.cuts.contains(pairKey(a, b));
}

/// Cut (or restore) the bond between atoms `a` and `b`.
pub fn toggleCutPair(app: *App, a: u32, b: u32) void {
    const key = pairKey(a, b);
    if (app.picks.cuts.remove(key)) {
        app.inform("Restored bond", .{});
    } else {
        app.picks.cuts.put(app.gpa, key, {}) catch return;
        app.inform("Cut bond: ignored when moving groups and selecting molecules", .{});
    }
}

pub fn restoreCuts(app: *App) void {
    var before = app.beginGesture() orelse return;
    defer app.endGesture(&before);
    app.picks.cuts.clearRetainingCapacity();
}

fn selectAll(app: *App) void {
    const d = app.doc orelse return;
    const f = d.display.real.frame orelse return;
    app.picks.selection.clearRetainingCapacity();
    app.picks.selection.ensureTotalCapacity(app.gpa, f.len()) catch return;
    for (0..f.len()) |i| app.picks.selection.appendAssumeCapacity(@intCast(i));
}

/// Ctrl+A: grow the selection to the whole molecules of the selected atoms;
/// if that adds nothing (or nothing is selected), select everything.
pub fn expandSelection(app: *App) void {
    const d = app.doc orelse return;
    const f = d.display.real.frame orelse return;
    var step = app.beginGesture() orelse return;
    defer app.endGesture(&step);
    if (app.picks.selection.items.len == 0) return app.selectAll();
    const gpa = app.gpa;
    var graph = app.drawnGraph() catch |e| return app.fail("Bond search failed: {t}", .{e});
    defer graph.deinit(gpa);
    const mask = gpa.alloc(bool, f.len()) catch return;
    defer gpa.free(mask);
    @memset(mask, false);
    for (app.picks.selection.items) |i| mask[i] = true;
    const before = app.picks.selection.items.len;
    // BFS from the current selection; new atoms are appended in visit order.
    var head: usize = 0;
    while (head < app.picks.selection.items.len) : (head += 1) {
        for (graph.neighbors(app.picks.selection.items[head])) |j| if (!mask[j]) {
            mask[j] = true;
            app.picks.selection.append(gpa, j) catch return;
        };
    }
    if (app.picks.selection.items.len == before) return app.selectAll();
    app.inform("Selected {d} atoms (whole molecules); Ctrl+A again selects all", .{app.picks.selection.items.len});
}

/// Add (or, with Ctrl+Shift, remove) every atom whose projection lies
/// inside the lasso, including atoms hidden behind others.
fn applyLasso(app: *App) void {
    const pts = app.lasso_points.items;
    defer app.lasso_points.clearRetainingCapacity();
    if (pts.len < 3) return;
    var before = app.beginGesture() orelse return;
    defer app.endGesture(&before);
    const pos = app.drawnPositions() orelse return;
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
        while (i < app.picks.selection.items.len) {
            if (mask[app.picks.selection.items[i]]) {
                _ = app.picks.selection.orderedRemove(i);
                changed += 1;
            } else i += 1;
        }
    } else {
        for (app.picks.selection.items) |i| mask[i] = false; // already selected
        for (mask, 0..) |m, i| if (m) {
            app.picks.selection.append(gpa, @intCast(i)) catch return;
            changed += 1;
        };
    }
    app.inform("{s} {d} atom{s} ({d} selected)", .{
        if (app.lasso_remove) "Deselected" else "Selected", changed, if (changed == 1) "" else "s", app.picks.selection.items.len,
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

/// Bonds between the shown atoms. Out of memory, none, saying so.
fn bonds(app: *App) []const cv.bonds.Bond {
    const d = &(app.doc orelse return &.{});
    return app.bondsOf(&d.display.real);
}

fn bondsOf(app: *App, atoms: *cv.display.BondedAtoms) []const cv.bonds.Bond {
    return atoms.bonds(app.gpa, app.bond_params) catch |e| {
        app.fail("Bond search failed: {t}", .{e});
        app.scene_key = null; // drawn without; try again
        return &.{};
    };
}

/// Connectivity used for moving groups and selecting molecules: exactly the
/// bonds that are drawn, so what moves together is what looks connected,
/// minus the bonds the user cut.
fn drawnGraph(app: *App) !cv.geometry.Graph {
    const d = &(app.doc orelse return error.NoDocument);
    const f = d.display.real.frame orelse return error.NoDocument;
    var drawn: std.ArrayList(cv.bonds.Bond) = .empty;
    defer drawn.deinit(app.gpa);
    for (try d.display.real.bonds(app.gpa, app.bond_params)) |b| {
        if (Renderer.isDrawn(app.style, b.character) and !app.isCut(b.a, b.b)) try drawn.append(app.gpa, b);
    }
    return cv.geometry.Graph.init(app.gpa, f.len(), drawn.items, 0);
}

/// Where the drawn atoms are: between steps during a blend. Everything the user sees or points at uses it;
/// edits, saving and copying use `display.real`. Valid until something changes.
pub fn drawnPositions(app: *App) ?[]const Vec3 {
    const d = &(app.doc orelse return null);
    if (d.display.real.frame == null) return null;
    const t = app.blendTime();
    return d.display.positions(app.gpa, t, .{
        .prev = if (d.display.prev) |s| app.numberedAsShown(s) else false,
        .next2 = if (d.display.next2) |s| app.numberedAsShown(s) else false,
    });
}

/// The value of the internal coordinate that is selected, as drawn.
pub fn measured(app: *App) ?Edit {
    const p = app.drawnPositions() orelse return null;
    const sel = app.selected();
    return switch (sel.len) {
        2 => .{ .distance = cv.geometry.distance(p, sel[0], sel[1]) },
        3 => .{ .angle = cv.geometry.angle(p, sel[0], sel[1], sel[2]) },
        4 => .{ .dihedral = cv.geometry.dihedral(p, sel[0], sel[1], sel[2], sel[3]) },
        else => null,
    };
}

fn windowSize(app: *const App) [2]f32 {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(app.window, &w, &h);
    return .{ @floatFromInt(@max(w, 1)), @floatFromInt(@max(h, 1)) };
}

const Target = union(enum) { atom: u32, bond: [2]u32 };
const Hit = struct { t: f32, target: Target };

/// The nearest atom or drawn bond under window point (x, y), if any.
fn hitAt(app: *App, x: f32, y: f32) ?Hit {
    const d = app.doc orelse return null;
    const f = d.display.real.frame orelse return null;
    const pos = app.drawnPositions() orelse return null;
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
    for (app.bonds()) |bd| {
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

/// A click toggles the atom under the cursor, or clears the selection on
/// empty space. `clicks` is SDL's click count: bonds aren't selectable, and
/// their only action is a double click, which cuts or restores them. A double
/// click on an atom changes nothing beyond the first click.
pub fn clickAt(app: *App, x: f32, y: f32, clicks: u8) void {
    const h = app.hitAt(x, y) orelse return app.deselect();
    switch (h.target) {
        .atom => |atom| if (clicks < 2) {
            var before = app.beginGesture() orelse return;
            defer app.endGesture(&before);
            app.toggleSelect(atom);
        },
        .bond => |pair| if (clicks == 2) app.cutBond(pair[0], pair[1]),
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

pub fn bondCharacter(app: *App, a: u32, b: u32) ?f32 {
    for (app.bonds()) |bd| {
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
    app.beginDragInner(kind, x, y) catch |e| {
        // Dragging on doesn't turn the camera instead.
        app.aborted_button = app.drag_button;
        switch (e) {
            error.NotAnAtom => app.refuse("Drag an atom, not a bond", .{}),
            error.NotSelected => app.refuse("Drag one of the selected atoms to move the selection", .{}),
            error.NeedsOneBase => app.refuse("To twist, select a single atom and drag another: its branch turns about the line between them", .{}),
            else => app.fail("Can't move that: {t}", .{e}),
        }
    };
}

fn beginDragInner(app: *App, kind: drag_mod.Kind, x: f32, y: f32) !void {
    const h = app.hitAt(x, y) orelse return;
    const handle = switch (h.target) {
        .atom => |a| a,
        .bond => return error.NotAnAtom,
    };
    try app.startDrag(kind, handle);
}

/// A mouse button went down with Alt held.
fn altPress(app: *App, sdl_button: u8, shift: bool, x: f32, y: f32) void {
    const button: drag_mod.Button = switch (sdl_button) {
        c.SDL_BUTTON_LEFT => .left,
        c.SDL_BUTTON_MIDDLE => .middle,
        c.SDL_BUTTON_RIGHT => .right,
        else => return,
    };
    app.drag_button = sdl_button;
    const kind = drag_mod.gesture(button, shift) orelse {
        app.aborted_button = sdl_button;
        return app.refuse("With Alt, Shift only goes with the left button: it rotates", .{});
    };
    app.beginDrag(kind, x, y);
}

fn startDrag(app: *App, kind: drag_mod.Kind, handle: u32) !void {
    const gpa = app.gpa;
    // A refused gesture doesn't pause playback.
    try drag_mod.check(kind, app.selected(), handle);
    var edit = try app.beginEdit();
    errdefer edit.deinit();
    const f = edit.atoms;
    var graph = try app.drawnGraph();
    defer graph.deinit(gpa);
    const choice = try drag_mod.chooseGroup(gpa, graph, kind, app.selected(), handle);
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

    edit.what = switch (kind) {
        .translate => .move,
        .twist => .twist,
        .rotate => .rotate,
    };
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
    app.unlockRotation();
    dr.apply(edit.atoms.positions, axes[2]);
    app.showDragged(edit.atoms);
}

/// Show the dragged frame with the positions of these atoms. Whatever puts
/// another frame on screen, or changes this one, ends the drag first.
fn showDragged(app: *App, atoms: Frame) void {
    const d = &app.doc.?;
    std.debug.assert(d.display.real.index == app.drag_edit.?.index);
    d.display.real.move(atoms.positions);
}

/// Finish (commit = true: keep as one geometry step) or cancel the drag.
fn endDrag(app: *App, commit: bool) void {
    var dr = app.drag orelse return;
    defer dr.deinit(app.gpa);
    var edit = app.drag_edit.?;
    defer edit.deinit();
    // Back as they were, unless committed below.
    if (dr.moved) app.showDragged(edit.before());
    app.drag = null;
    app.drag_edit = null;
    if (!commit) app.aborted_button = app.drag_button;
    if (commit and dr.moved) {
        // Whether it changed anything is seen, and isn't said (D17).
        _ = app.commitEdit(&edit) catch |e| return app.fail("Move failed: {t}", .{e});
    }
}

/// Shown in the measurement bar while dragging.
pub fn dragHint(app: *const App, buf: []u8) ?[]const u8 {
    const dr = app.drag orelse return null;
    const f = app.doc.?.display.real.frame.?;
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
    app.applyEditInner(edit) catch |e| app.fail("Edit failed: {t}", .{e});
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
    if (!try app.commitEdit(&tx)) app.refuse("Nothing to change", .{});
}

/// Get ready to change or save the shown frame: abort a drag, and pause playback on
/// the step it plays from.
fn stopForEdit(app: *App) void {
    const d = &(app.doc orelse return);
    app.endDrag(false);
    const was_playing = app.playing;
    app.playing = false;
    // Never a step that is still loading.
    if (was_playing and d.display.real.frame != null) app.moveTo(d.display.real.index);
    // The edit may unlock, and the frame it is on should be in place by then.
    app.followRotationLock();
}

/// Every transaction on the shown frame starts here.
fn beginEdit(app: *App) !cv.edit.Transaction {
    app.stopForEdit();
    const d = &(app.doc orelse return error.NoDocument);
    return app.session.begin(d.display.real.index, d.display.real.frame orelse return error.NoDocument);
}

/// Commit an edit of the shown frame and show it. On error the frame is as it
/// was.
fn commitEdit(app: *App, edit: *cv.edit.Transaction) !bool {
    return app.commitKeeping(edit, null);
}

/// `commitEdit` of an edit that renumbers atoms, and then selects `selection`.
fn commitRenumbering(app: *App, edit: *cv.edit.Transaction, selection: []const u32) !bool {
    try app.picks.selection.ensureTotalCapacity(app.gpa, selection.len);
    var kept: ?cv.picks.Kept = if (app.session.selection_steps) try app.picks.keep(app.gpa, selection) else null;
    errdefer if (kept) |*k| k.deinit(app.gpa);
    if (!try app.commitKeeping(edit, kept)) {
        if (kept) |*k| k.deinit(app.gpa);
        return false;
    }
    app.picks.selection.clearRetainingCapacity();
    app.picks.selection.appendSliceAssumeCapacity(selection);
    return true;
}

fn commitKeeping(app: *App, edit: *cv.edit.Transaction, kept: ?cv.picks.Kept) !bool {
    const d = &(app.doc orelse return error.NoDocument);
    std.debug.assert(d.display.real.index == edit.index);
    // Nothing may fail after the commit.
    try edit.dropEnergy();
    var show = try edit.atoms.clone(app.gpa);
    errdefer show.deinit(app.gpa);
    if (!try edit.commitKeeping(kept)) {
        show.deinit(app.gpa);
        return false;
    }
    app.unlockRotation();
    app.showChanged(edit.index, show);
    return true;
}

/// Frame `index` now has the atoms in `frame` (takes ownership).
fn showChanged(app: *App, index: usize, frame: Frame) void {
    const d = &app.doc.?;
    d.display.forget(app.gpa, index);
    var new = frame;
    if (d.display.real.index != index) return new.deinit(app.gpa);
    d.display.real.show(app.gpa, index, new);
    app.followDisplay();
}

/// What has atom numbers in it follows the shown frame at once: the picks, and
/// the diff.
fn followDisplay(app: *App) void {
    const d = &app.doc.?;
    app.picks.follow(app.gpa, d.display.real.index, app.numberingOf(d.display.real.index, d.display.real.frame.?));
    app.updateDiff();
}

/// Show a change made to frame `index` by undo, redo or revert.
fn showSessionChange(app: *App, index: usize) void {
    const d = &app.doc.?;
    if (app.takeFrame(index)) |f| {
        app.showChanged(index, f);
    } else if (d.display.real.index == index) {
        // Out of memory: `update` tries again.
        d.display.real.hide(app.gpa);
    }
}

/// Delete the selected atoms from the current frame (undoable).
pub fn deleteSelection(app: *App) void {
    app.deleteSelectionInner() catch |e| app.fail("Delete failed: {t}", .{e});
}

fn deleteSelectionInner(app: *App) !void {
    const gpa = app.gpa;
    app.endDrag(false);
    if (app.selected().len == 0) return app.refuse("Select atoms to delete", .{});
    var edit = try app.beginEdit();
    defer edit.deinit();
    const sel = app.selected();
    const n = sel.len;
    if (n >= edit.atoms.len()) return app.refuse("Can't delete every atom", .{});

    const remove = try gpa.alloc(bool, edit.atoms.len());
    defer gpa.free(remove);
    @memset(remove, false);
    for (sel) |i| remove[i] = true;
    try edit.delete(remove);
    if (!try app.commitRenumbering(&edit, &.{})) unreachable; // atoms were removed
    app.inform("Deleted {d} atom{s} (Ctrl+Z undoes)", .{ n, if (n == 1) "" else "s" });
}

pub fn undo(app: *App) void {
    app.endDrag(false);
    const crossed = app.session.undo(&app.picks) catch |e| return app.fail("Undo failed: {t}", .{e});
    switch (crossed orelse return) {
        .selection => app.inform("Undid a change of selection or cuts", .{}),
        .geometry => |g| {
            app.jumpToChange(g.index, g.kept, g.side);
            app.inform("Undid the last change to frame {d}", .{g.index + 1});
        },
    }
}

pub fn redo(app: *App) void {
    app.endDrag(false);
    const crossed = app.session.redo(&app.picks) catch |e| return app.fail("Redo failed: {t}", .{e});
    switch (crossed orelse return) {
        .selection => app.inform("Redid a change of selection or cuts", .{}),
        .geometry => |g| {
            app.jumpToChange(g.index, g.kept, g.side);
            app.inform("Redid the change to frame {d}", .{g.index + 1});
        },
    }
}

/// Show what undo or redo did to frame `index`, going there, and the picks
/// that go with it.
fn jumpToChange(app: *App, index: usize, kept: ?cv.picks.Kept, side: cv.picks.Side) void {
    const d = &app.doc.?;
    app.playing = false;
    if (d.display.real.index == index) {
        // In place, as it was, before it changes and unlocks.
        app.interp_t = 0;
        app.followRotationLock();
        app.unlockRotation();
    }
    app.showSessionChange(index);
    if (d.current != index) app.setFrame(index) else app.interp_t = 0;
    app.pullFrame(); // the session has its atoms
    app.followRotationLock(); // if it is another frame
    app.unlockRotation();
    if (d.display.real.frame == null or d.display.real.index != index) return;
    if (kept) |k| app.picks.restore(app.gpa, k, side);
}

pub fn canUndo(app: *const App) bool {
    return app.session.canUndo(&app.picks);
}

pub fn canRedo(app: *const App) bool {
    return app.session.canRedo(&app.picks);
}

pub const HistoryKey = enum { undo, redo };

/// Which of undo and redo a key pressed with Ctrl means.
pub fn historyKey(key: c.SDL_Keycode, mod: c.SDL_Keymod) ?HistoryKey {
    return switch (key) {
        c.SDLK_Z => if ((mod & c.SDL_KMOD_SHIFT) != 0) .redo else .undo,
        c.SDLK_Y => .redo,
        else => null,
    };
}

/// Make the shown frame its file frame again (one geometry step).
pub fn revertFrame(app: *App) void {
    const d = &(app.doc orelse return);
    app.endDrag(false);
    if (!app.session.isEdited(d.display.real.index)) return;
    app.playing = false;
    app.revertShown() catch |e| return app.fail("Revert failed: {t}", .{e});
    app.interp_t = 0;
    app.followRotationLock();
    app.unlockRotation();
    app.showSessionChange(d.display.real.index);
    // The frame asked for may be another one that can't be read.
    app.moveTo(d.display.real.index);
    app.inform("Reverted frame {d} to the file (Ctrl+Z undoes)", .{d.display.real.index + 1});
}

/// The shown frame, which is edited, to its file frame in the session.
fn revertShown(app: *App) !void {
    const index = app.doc.?.display.real.index;
    const renumbers = app.session.origins(index) != null;
    var kept: ?cv.picks.Kept = if (renumbers and app.session.selection_steps) try app.picks.keep(app.gpa, null) else null;
    errdefer if (kept) |*k| k.deinit(app.gpa);
    if (!try app.session.revert(index, kept)) unreachable; // it is edited
}

/// Save the shown frame.
pub fn saveDialog(app: *App) void {
    // So that the frame the dialog names is the one that is saved.
    app.stopForEdit();
    const d = app.doc orelse return;
    if (d.display.real.frame == null) return;
    app.saveDialogFor(.{ .frame = d.display.real.index });
}

fn saveDialogFor(app: *App, what: cv.saving.What) void {
    const d = app.doc orelse return;
    app.endDrag(false);
    if (app.saving != null) return app.refuse("Already saving; Esc stops it", .{});
    // One dialog at a time: its answer is for `save_what`.
    if (app.save_dialog_open.swap(true, .acq_rel)) return app.refuse("A save dialog is already open", .{});
    app.save_what = .{ .what = what, .document = app.documents_opened };
    const filters = [_]c.SDL_DialogFileFilter{.{ .name = "XYZ", .pattern = "xyz" }};
    // Suggest <name>_frameN.xyz next to the source file.
    var buf: [4096]u8 = undefined;
    const stem = std.fs.path.stem(d.path);
    const dir = std.fs.path.dirname(d.path) orelse ".";
    const suggestion = switch (what) {
        .frame => |i| ui.printZ(&buf, "{s}/{s}_frame{d}.xyz", .{ dir, stem, i + 1 }),
        .unsaved => ui.printZ(&buf, "{s}/{s}_edited.xyz", .{ dir, stem }),
        .all => ui.printZ(&buf, "{s}/{s}_all.xyz", .{ dir, stem }),
    } catch null;
    c.SDL_ShowSaveFileDialog(saveCallback, app, app.window, &filters, filters.len, if (suggestion) |s| s.ptr else null);
}

fn saveCallback(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) callconv(.c) void {
    _ = filter;
    const app: *App = @ptrCast(@alignCast(userdata));
    // Cancelled, or no answer that can be used. Otherwise it counts as open
    // until `update` has taken the answer.
    if (filelist == null or filelist[0] == null) return app.save_dialog_open.store(false, .release);
    const p = std.mem.span(filelist[0]);
    if (p.len >= app.save_path.len) return app.save_dialog_open.store(false, .release);
    @memcpy(app.save_path[0..p.len], p);
    app.save_path[p.len] = 0;
    app.save_ready.store(true, .release);
}

/// Write the shown frame (including edits) as XYZ, all at once.
pub fn saveFrame(app: *App, path: []const u8) void {
    const d = app.doc orelse return;
    app.startSaving(.{ .frame = d.display.real.index }, path);
    while (app.saving != null) app.saveSome(1);
}

fn startSaving(app: *App, what: cv.saving.What, path: []const u8) void {
    const d = app.doc orelse return;
    if (app.saving != null) return app.refuse("Already saving; Esc stops it", .{});
    app.saving = cv.saving.Saving.start(app.gpa, app.io, d.source, &app.session, what, path) catch |e|
        return app.fail("Could not save {s}: {t}", .{ std.fs.path.basename(path), e });
}

/// Give up on what is being saved. The edits in it stay unsaved.
fn stopSaving(app: *App) void {
    const s = app.saving orelse return;
    s.deinit();
    app.saving = null;
}

/// Go on saving, for at least a frame and about `budget` seconds.
fn saveSome(app: *App, budget: f64) void {
    const s = app.saving orelse return;
    const until = app.seconds() + budget;
    while (true) {
        const name = std.fs.path.basename(s.path);
        const done = s.step() catch |e| {
            app.fail("Could not save {s}: {t}", .{ name, e });
            app.leaving = null; // it may have been waiting for this
            return app.stopSaving();
        };
        if (done) {
            if (s.skipped > 0) {
                app.fail("Saved {s} without {d} unreadable frame{s}", .{ name, s.skipped, if (s.skipped == 1) "" else "s" });
            } else app.inform("Saved {s}", .{name});
            return app.stopSaving();
        }
        if (app.seconds() >= until) return;
    }
}

/// Shown in the bar while saving takes more than a moment.
pub fn savingHint(app: *const App, buf: []u8) ?[]const u8 {
    const s = app.saving orelse return null;
    return std.fmt.bufPrint(buf, "Saving {d} of {d} frames  (Esc stops)", .{ s.next, s.total }) catch null;
}

// ------------------------------------------------------------ leaving

/// Something that discards the edits of the open file.
pub const Leaving = union(enum) {
    quit,
    close,
    /// Opens that file.
    open: struct { buf: [4096]u8, len: usize },
    /// Pastes as a new structure.
    paste,
};

/// Do that, after asking if there are unsaved edits or a save isn't finished.
/// While a question is up, the last one asked for counts.
pub fn leave(app: *App, to: Leaving) void {
    app.endDrag(false);
    app.leaving = to;
    if (!app.session.anyUnsaved() and app.saving == null) app.leaveNow();
}

pub fn leaveToOpen(app: *App, path: []const u8) void {
    var to: Leaving = .{ .open = .{ .buf = undefined, .len = path.len } };
    if (path.len > to.open.buf.len) return app.fail("Could not open {s}: the path is too long", .{std.fs.path.basename(path)});
    @memcpy(to.open.buf[0..path.len], path);
    app.leave(to);
}

/// Esc while the question is up: stops a save if there is one, else cancels.
fn leaveEsc(app: *App) void {
    if (app.saving != null) {
        app.stopSaving();
        // With nothing left to ask, going on would look like leaving by Esc.
        if (app.session.anyUnsaved()) return;
    }
    app.leaving = null;
}

/// Without asking.
fn leaveNow(app: *App) void {
    const to = app.leaving orelse return;
    app.leaving = null;
    switch (to) {
        .quit => app.quit_requested = true,
        .close => app.closeDocument(),
        .open => |path| app.openFile(path.buf[0..path.len]),
        .paste => app.pasteXyz(true),
    }
}

/// The question, in the middle: everything else would discard the edits.
fn leaveQuestion(app: *App) void {
    const title = "Not saved yet";
    const open = c.igIsPopupOpen_Str(title, 0);
    if (app.leaving == null and !open) return;
    if (!open) _ = c.igOpenPopup_Str(title, 0);
    const vp = c.igGetMainViewport();
    c.igSetNextWindowPos(ui.v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), c.ImGuiCond_Always, ui.v2(0.5, 0.5));
    if (!c.igBeginPopupModal(title, null, c.ImGuiWindowFlags_AlwaysAutoResize | c.ImGuiWindowFlags_NoSavedSettings)) return;
    defer c.igEndPopup();
    // Cancelled with Esc.
    if (app.leaving == null) return c.igCloseCurrentPopup();
    const list = app.session.unsaved(app.gpa) catch return;
    defer app.gpa.free(list);
    // All saved meanwhile: go on.
    if (list.len == 0 and app.saving == null) {
        c.igCloseCurrentPopup();
        return app.leaveNow();
    }
    const fs = c.igGetFontSize();
    var buf: [96]u8 = undefined;
    if (list.len > 0) {
        ui.text("{d} frame{s} with edits that aren't saved", .{ list.len, if (list.len == 1) "" else "s" });
        const rows: f32 = @floatFromInt(@min(list.len, 8));
        if (c.igBeginChild_Str("##unsaved", ui.v2(fs * 24, rows * c.igGetFrameHeightWithSpacing() + fs), c.ImGuiChildFlags_Borders, 0)) {
            for (list) |index| {
                c.igPushID_Int(@intCast(index));
                defer c.igPopID();
                c.igAlignTextToFramePadding();
                ui.text("Frame {d}", .{index + 1});
                c.igSameLine(fs * 9, 0);
                if (c.igSmallButton("Save as...")) app.saveDialogFor(.{ .frame = index });
            }
        }
        c.igEndChild();
        if (list.len > 1) {
            const label = ui.printZ(&buf, "Save the {d} edited frames...###edited", .{list.len}) catch "Save the edited frames...###edited";
            if (c.igButton(label.ptr, ui.v2(0, 0))) app.saveDialogFor(.unsaved);
            ui.tooltip("Only these frames, in one file.");
        }
        if (app.doc.?.frameCount() > 1) {
            if (list.len > 1) c.igSameLine(0, -1);
            if (c.igButton("Save the whole trajectory...", ui.v2(0, 0))) app.saveDialogFor(.all);
            ui.tooltip("Every frame of the file, with the edits, in one file.");
        }
    }
    if (app.savingHint(&buf)) |hint| ui.text("{s}", .{hint});
    // Problems are said here, too: the bar may be out of sight.
    if (app.messages.current(app.seconds())) |m| if (m.kind != .info) ui.textWrapped("{s}", .{m.text()});
    const discard: [:0]const u8 = if (list.len == 0) "Stop saving" else if (list.len > 1) "Discard all" else "Discard";
    if (c.igButton(discard.ptr, ui.v2(0, 0))) {
        c.igCloseCurrentPopup();
        return app.leaveNow();
    }
    c.igSameLine(0, -1);
    if (c.igButton("Cancel", ui.v2(0, 0))) {
        c.igCloseCurrentPopup();
        app.leaving = null;
    }
}

// ------------------------------------------------------------ UI

/// Window placement condition: re-place panels when the UI scale changes.
fn layoutCond(app: *App) c_int {
    return if (c.igGetFontSize() != app.layout_font_size) c.ImGuiCond_Always else c.ImGuiCond_FirstUseEver;
}

pub fn drawUi(app: *App) void {
    defer app.layout_font_size = c.igGetFontSize();
    app.updateHover();
    measure.atomLabels(app);
    measure.overlay(app);
    measure.hoverOutline(app);
    app.drawLasso();
    app.menuBar();
    const timeline_h = timeline_mod.height();
    timeline_mod.draw(app, timeline_h);
    app.timeline.wheel = .{};
    if (app.show_inspector) app.inspector(timeline_h);
    if (app.show_diff) app.diffPanel();
    if (app.show_help) app.helpWindow();
    if (app.doc == null) app.emptyView(timeline_h);
    app.leaveQuestion();
    app.rememberLooks(c.igIsAnyItemActive());
}

/// "Undo move (frame 12)", with an id that doesn't change with it.
fn historyLabel(buf: []u8, comptime verb: []const u8, step: ?cv.edit.EditSession.Upcoming) [*:0]const u8 {
    const label = switch (step orelse return verb ++ "###" ++ verb) {
        .geometry => |g| ui.printZ(buf, verb ++ " {t} (frame {d})###" ++ verb, .{ g.what, g.index + 1 }),
        .selection => return verb ++ " selection or cut###" ++ verb,
    } catch return verb ++ "###" ++ verb;
    return label.ptr;
}

fn menuBar(app: *App) void {
    if (!c.igBeginMainMenuBar()) return;
    defer c.igEndMainMenuBar();
    if (c.igBeginMenu("File", true)) {
        if (c.igMenuItem_Bool("Open...", "Ctrl+O", false, true)) app.openDialog();
        const has_frame = app.doc != null and app.doc.?.display.real.frame != null;
        if (c.igMenuItem_Bool("Save frame as XYZ...", "Ctrl+S", false, has_frame)) app.saveDialog();
        if (c.igMenuItem_Bool("Save edited frames as XYZ...", null, false, app.session.anyUnsaved())) app.saveDialogFor(.unsaved);
        ui.tooltip("Only the frames with edits that aren't saved yet, in one file.");
        if (c.igMenuItem_Bool("Save trajectory as XYZ...", null, false, has_frame and app.doc.?.frameCount() > 1)) app.saveDialogFor(.all);
        ui.tooltip("Every frame, with its edits.");
        if (c.igMenuItem_Bool("Close", null, false, app.doc != null)) app.leave(.close);
        c.igSeparator();
        if (c.igMenuItem_Bool("Quit", "Ctrl+Q", false, true)) app.leave(.quit);
        c.igEndMenu();
    }
    if (c.igBeginMenu("Edit", true)) {
        var label_buf: [64]u8 = undefined;
        const undo_step = app.session.upcoming(&app.picks, .before);
        if (c.igMenuItem_Bool(historyLabel(&label_buf, "Undo", undo_step), "Ctrl+Z", false, undo_step != null)) app.undo();
        const redo_step = app.session.upcoming(&app.picks, .after);
        if (c.igMenuItem_Bool(historyLabel(&label_buf, "Redo", redo_step), "Ctrl+Shift+Z", false, redo_step != null)) app.redo();
        const edited = if (app.doc) |d| app.session.isEdited(d.display.real.index) else false;
        if (c.igMenuItem_Bool("Delete selected atoms", "Del", false, app.picks.selection.items.len > 0)) app.deleteSelection();
        if (c.igMenuItem_Bool("Revert frame to file", null, false, edited)) app.revertFrame();
        c.igSeparator();
        if (c.igMenuItem_Bool("Restore all cut bonds", null, false, app.picks.cuts.count() > 0)) app.restoreCuts();
        c.igSeparator();
        if (c.igMenuItem_Bool("Copy as XYZ", "Ctrl+C", false, app.doc != null)) app.copyXyz();
        if (c.igMenuItem_Bool("Paste XYZ as fragment", "Ctrl+V", false, true)) app.pasteXyz(false);
        if (c.igMenuItem_Bool("Paste XYZ as new structure", "Ctrl+Shift+V", false, true)) app.leave(.paste);
        c.igSeparator();
        if (c.igMenuItem_Bool("Select molecule / all", "Ctrl+A", false, app.doc != null)) app.expandSelection();
        if (c.igMenuItem_Bool("Clear selection", "Esc", false, app.picks.selection.items.len > 0)) app.deselect();
        c.igEndMenu();
    }
    if (c.igBeginMenu("View", true)) {
        _ = c.igMenuItem_BoolPtr("Inspector", null, &app.show_inspector, true);
        _ = c.igMenuItem_BoolPtr("Diff", null, &app.show_diff, true);
        const has_cell = if (app.doc) |d| (if (d.display.real.frame) |f| f.cell != null else false) else false;
        _ = c.igMenuItem_BoolPtr("Unit cell box", null, &app.style.show_cell, has_cell);
        if (c.igIsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) {
            const why: [:0]const u8 = if (has_cell) "Draw the periodic box that repeats to fill space." else "This frame has no unit cell.";
            _ = c.igSetTooltip("%s", why.ptr);
        }
        _ = c.igMenuItem_BoolPtr("Atom numbers", "N", &app.show_atom_numbers, true);
        _ = c.igMenuItem_BoolPtr("Element labels", null, &app.show_element_labels, true);
        ui.tooltip("Show element symbols on atoms whose colour could be mistaken for another element in the structure (the rarer of the two).");
        if (c.igMenuItem_Bool("Fit to view", "F", false, app.doc != null)) app.fitCamera();
        c.igSeparator();
        c.igSetNextItemWidth(c.igGetFontSize() * 8);
        // Applied when let go: the slider would move away under the pointer.
        var scale = app.ui_scale_edit orelse app.ui_scale;
        _ = c.igSliderFloat("UI scale", &scale, 0.5, 2.0, "%.2fx", c.ImGuiSliderFlags_AlwaysClamp);
        ui.tooltip("Applied when you let go. Ctrl+click to type a number.");
        if (c.igIsItemActive()) {
            app.ui_scale_edit = scale;
        } else if (app.ui_scale_edit != null) {
            app.ui_scale = scale;
            app.ui_scale_edit = null;
        }
        c.igEndMenu();
    }
    if (c.igBeginMenu("Help", true)) {
        _ = c.igMenuItem_BoolPtr("Mouse & keys", "F1", &app.show_help, true);
        c.igEndMenu();
    }
}

/// What the mouse is on: nothing while it does something else.
fn updateHover(app: *App) void {
    app.hover = null;
    if (app.playing or app.drag != null or app.lasso_active or app.doc == null) return;
    if (c.cvImGuiWantCaptureMouse() or c.igIsAnyMouseDown()) return;
    const at = c.igGetMousePos();
    const ws = app.windowSize();
    if (at.x < 0 or at.y < 0 or at.x >= ws[0] or at.y >= ws[1]) return;
    const h = app.hitAt(at.x, at.y) orelse return;
    app.hover = h.target;
    c.igSetMouseCursor(c.ImGuiMouseCursor_Hand);
}

/// The atoms an Alt-drag of the atom under the mouse would move. Empty if it
/// would be refused, or without memory. Valid until the next call.
pub fn hoverGroup(app: *App) []const u32 {
    const handle = switch (app.hover orelse return &.{}) {
        .atom => |a| a,
        .bond => return &.{},
    };
    const key: HoverKey = .{ .handle = handle, .scene = app.sceneKey() };
    if (app.hover_key) |k| if (std.meta.eql(k, key)) return app.hover_group;
    var graph = app.drawnGraph() catch return &.{};
    defer graph.deinit(app.gpa);
    const choice = drag_mod.chooseGroup(app.gpa, graph, .translate, app.selected(), handle) catch |e| {
        if (e == error.OutOfMemory) return &.{};
        app.setHoverGroup(key, &.{});
        return &.{};
    };
    app.setHoverGroup(key, choice.group);
    return app.hover_group;
}

const HoverKey = struct { handle: u32, scene: SceneKey };

fn setHoverGroup(app: *App, key: ?HoverKey, group: []u32) void {
    app.gpa.free(app.hover_group);
    app.hover_group = group;
    app.hover_key = key;
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

    const before = app.settings;
    if (app.doc) |d| {
        if (ui.section("File", &app.settings.file_open)) app.fileSection(d);
    } else {
        ui.textDisabled("No file open", .{});
    }
    if (ui.section("Bonds", &app.settings.bonds_open)) app.bondsSection();
    if (ui.section("Display", &app.settings.display_open)) app.displaySection();
    if (!std.meta.eql(before, app.settings)) app.saveSettings();
}

fn fileSection(app: *App, d: Document) void {
    {
        ui.selectableText("##path", "{s}", .{std.fs.path.basename(d.path)});
        ui.textDisabled("{s}{s}", .{ d.format.label(), if (d.source.isStreamed()) ", streamed" else "" });
        if (d.display.real.frame) |f| {
            ui.text("Frame {d} / {d}{s}", .{ d.display.real.index + 1, d.frameCount(), if (app.session.isEdited(d.display.real.index)) "  (edited)" else "" });
            var drawn: usize = 0;
            for (app.bonds()) |b| drawn += @intFromBool(Renderer.isDrawn(app.style, b.character));
            ui.text("{d} atoms, {d} bonds", .{ f.len(), drawn });
            if (f.energy) |e| {
                c.igAlignTextToFramePadding();
                ui.text("E =", .{});
                c.igSameLine(0, -1);
                ui.selectableText("##energy", "{d}", .{e});
            }
            if (f.comment.len > 0) ui.selectableText("##comment", "{s}", .{f.comment});
            app.composition(f);
        } else ui.textDisabled("loading...", .{});
    }
}

fn bondsSection(app: *App) void {
    var coloring: c_int = @backingInt(app.style.bond_coloring);
    _ = c.igRadioButton_IntPtr("Character gradient", &coloring, 0);
    c.igSameLine(0, -1);
    _ = c.igRadioButton_IntPtr("Element", &coloring, 1);
    app.style.bond_coloring = @fromBackingInt(@intCast(coloring));
    ui.gradientLegend(app.style.theme, app.style.snap);
    _ = c.igSliderFloat("Colour steps", &app.style.snap, 0, 1, "%.2f", 0);
    ui.tooltip("How strongly colours settle on whole bond orders. 0 = linear in bond character, 1 = flat plateaus at single/double/triple.");
    _ = c.igSliderFloat("Longest bond", &app.bond_params.cutoff_factor, 1.0, 1.8, "%.2f x single", 0);
    ui.tooltip("Pairs closer than this multiple of their single-bond length are bonded.");
    _ = c.igSliderFloat("Hide weaker", &app.style.min_character, 0, 3, "%.2f", 0);
    ui.tooltip("Hide bonds whose character is below this value (1 = single). Only drawn bonds connect atoms when moving groups or selecting molecules.");
    if (c.igButton("Reset to defaults##bonds", ui.v2(0, 0))) app.resetLooks(&.{ "bond_coloring", "snap", "cutoff_factor", "min_character" });
}

fn displaySection(app: *App) void {
    var theme: c_int = @backingInt(app.style.theme);
    _ = c.igRadioButton_IntPtr("Light", &theme, 0);
    c.igSameLine(0, -1);
    _ = c.igRadioButton_IntPtr("Dark", &theme, 1);
    app.style.theme = @fromBackingInt(@intCast(theme));
    inline for (.{
        .{ "Cel", Renderer.Shading.cel, false, "Toon bands with outlines." },
        .{ "Flat", .flat, false, "Inspired by Kurzgesagt's flat illustrations: solid colours, flat drop shadows, depth shown by fading into the background." },
        .{ "Flat+", .flat, true, "Flat, with blurred drop shadows and a thin dark outline, so the molecule stands out more." },
        .{ "Aero", .aero, false, "Glossy, in the spirit of Frutiger Aero: glassy atoms with highlight caps." },
        .{ "Glass", .glass, false, "Experimental: liquid glass. Translucent tinted glass atoms and bonds that refract whatever is behind them, other glass included, with bright rims." },
    }, 0..) |o, i| {
        if (i > 0) ui.sameLineIfFits(o[0]);
        const plus = app.style.shading == .flat and app.style.flat_pop;
        if (c.igRadioButton_Bool(o[0], app.style.shading == o[1] and plus == o[2])) {
            app.style.shading = o[1];
            app.style.flat_pop = o[2];
        }
        ui.tooltip(o[3]);
    }
    if (app.style.shading == .glass) {
        _ = c.igCheckbox("Liquid", &app.style.liquid);
        ui.tooltip("Bonds flow into the atoms, like drops of liquid glass, instead of separate balls and sticks.");
    }
    if (app.style.shading == .cel) {
        _ = c.igSliderFloat("Outline", &app.style.outline_px, 0, 4, "%.1f px", 0);
    }
    c.igAlignTextToFramePadding();
    ui.text("Background", .{});
    c.igSameLine(0, -1);
    if (c.igRadioButton_Bool("None", !app.style.background_pattern)) app.style.background_pattern = false;
    ui.tooltip("Plain solid colour.");
    inline for (.{
        .{ "Space", .space, "Glowing bokeh, haze and sparkle stars, out of focus; turns with the camera." },
        .{ "Cells", .cells, "Blobs with membranes and nuclei, out of focus as if seen up close; turns with the camera." },
    }) |o| {
        c.igSameLine(0, -1);
        if (c.igRadioButton_Bool(o[0], app.style.background_pattern and app.style.backdrop == o[1])) {
            app.style.background_pattern = true;
            app.style.backdrop = o[1];
        }
        ui.tooltip(o[2]);
    }
    if (app.style.background_pattern) {
        _ = c.igSliderFloat("Background blur", &app.style.background_blur, 0, 2.5, "%.2f", 0);
        ui.tooltip("Depth of field: the molecule stays in focus and the backdrop blurs with distance. Zooming in blurs it more.");
    }
    _ = c.igSliderFloat("Atom scale", &app.style.atom_scale, 0.2, 3.0, "%.2f", 0);
    _ = c.igSliderFloat("Bond radius", &app.style.bond_radius, 0.03, 0.3, "%.2f Å", 0);
    if (c.igButton("Fit to view (F)", ui.v2(0, 0))) app.fitCamera();
    c.igSameLine(0, -1);
    if (c.igButton("Reset to defaults##display", ui.v2(0, 0))) app.resetLooks(&.{
        "theme",              "shading",  "liquid",   "outline_px",      "atom_scale", "bond_radius",
        "background_pattern", "backdrop", "flat_pop", "background_blur",
    });
}

const help = .{
    .{ "Camera", .{
        .{ "Left drag", "rotate" },
        .{ "Right drag left/right", "rotate about the viewing axis" },
        .{ "Right drag up/down", "zoom (up = closer)" },
        .{ "Middle drag, or Shift + left or right drag", "translate" },
        .{ "Wheel", "zoom" },
        .{ "F", "fit to view" },
    } },
    .{ "Selecting", .{
        .{ "Left click", "select / deselect an atom; empty space: clear selection" },
        .{ "Ctrl + left drag", "lasso: add atoms inside (including hidden ones)" },
        .{ "Ctrl + Shift + left drag", "lasso: remove atoms inside" },
        .{ "Ctrl+A", "grow selection to whole molecules; again: select all" },
        .{ "Esc", "cancel a fragment drag, else clear selection" },
        .{ "N", "show / hide atom numbers" },
    } },
    .{ "Editing", .{
        .{ "Alt + left drag", "move the selection; with one base atom selected, the branch beyond it; with nothing selected, a molecule" },
        .{ "Alt + right drag", "twist the branch about the line from the base to the grabbed atom" },
        .{ "Alt + middle drag, or Alt + Shift + left drag", "rotate about the base, else about the centre" },
        .{ "Double-click a bond", "cut / restore it (until you leave the frame)" },
        .{ "Delete / Backspace", "delete the selected atoms" },
        .{ "Ctrl+Z", "undo the last edit, selection or cut" },
        .{ "Ctrl+Shift+Z / Ctrl+Y", "redo" },
    } },
    .{ "Timeline", .{
        .{ "Space", "play / pause" },
        .{ "Left / Right, or , .", "previous / next frame" },
        .{ "PgUp / PgDn", "jump 5%" },
        .{ "Home / End", "first / last frame" },
        .{ "Right drag on the timeline", "scrub one frame per pixel" },
        .{ "Wheel on the timeline", "zoom at the mouse" },
        .{ "Shift + wheel, or middle drag, on the timeline", "pan" },
        .{ "Z", "show every frame on the timeline" },
    } },
    .{ "Files", .{
        .{ "Ctrl+C", "copy selection (or whole frame) as XYZ" },
        .{ "Ctrl+V", "paste as a fragment into the current structure" },
        .{ "Ctrl+Shift+V", "paste as a new structure" },
        .{ "Ctrl+S", "save current frame (with edits) as XYZ" },
        .{ "Ctrl+O", "open file (or drop a file on the window)" },
    } },
};

fn helpWindow(app: *App) void {
    const vp = c.igGetMainViewport();
    const fs = c.igGetFontSize();
    const cond = app.layoutCond();
    c.igSetNextWindowPos(ui.v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), cond, ui.v2(0.5, 0.5));
    c.igSetNextWindowSize(ui.v2(@min(fs * 45, vp.*.Size.x - fs), @min(fs * 45, vp.*.Size.y - 4 * fs)), cond);
    defer c.igEnd();
    if (c.igBegin("Mouse & keys", &app.show_help, 0)) mouseAndKeys();
}

/// What to do when no file is open, in the middle of the view.
fn emptyView(app: *App, timeline_h: f32) void {
    const vp = c.igGetMainViewport();
    c.igSetNextWindowPos(ui.v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + (vp.*.Size.y - timeline_h) / 2), c.ImGuiCond_Always, ui.v2(0.5, 0.5));
    const flags = c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_AlwaysAutoResize |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoFocusOnAppearing | c.ImGuiWindowFlags_NoBringToFrontOnFocus;
    defer c.igEnd();
    if (!c.igBegin("##empty", null, flags)) return;
    if (c.igButton("Open...", ui.v2(0, 0))) app.openDialog();
    c.igSameLine(0, -1);
    c.igAlignTextToFramePadding();
    ui.text("or drop a file here", .{});
}

fn mouseAndKeys() void {
    inline for (help) |group| {
        c.igSeparatorText(group[0]);
        if (c.igBeginTable("##" ++ group[0], 2, c.ImGuiTableFlags_RowBg | c.ImGuiTableFlags_SizingStretchProp, ui.v2(0, 0), 0)) {
            c.igTableSetupColumn("input", c.ImGuiTableColumnFlags_WidthStretch, 0.42, 0);
            c.igTableSetupColumn("action", c.ImGuiTableColumnFlags_WidthStretch, 0.58, 0);
            inline for (group[1]) |row| ui.helpRow(row[0], row[1]);
            c.igEndTable();
        }
    }
}

/// Use, and from now on save, the settings kept in `dir`.
pub fn loadSettings(app: *App, dir: []const u8) void {
    app.settings_path = std.fs.path.join(app.gpa, &.{ dir, "settings" }) catch return;
    var buf: [4096]u8 = undefined;
    const text = Io.Dir.cwd().readFile(app.io, app.settings_path.?, &buf) catch return;
    app.settings = .parse(text);
    app.applyLooks(app.settings);
}

/// Copy the remembered looks to where they are used.
fn applyLooks(app: *App, s: cv.settings.Settings) void {
    inline for (@typeInfo(cv.settings.Settings).@"struct".field_names) |name| {
        if (@hasField(Renderer.Style, name)) @field(app.style, name) = styleValue(name, @field(s, name));
    }
    app.bond_params.cutoff_factor = s.cutoff_factor;
    app.ui_scale = s.ui_scale;
}

fn styleValue(comptime name: []const u8, v: anytype) @FieldType(Renderer.Style, name) {
    return convert(@FieldType(Renderer.Style, name), v);
}

/// `v` as a `T`, which has the same values. Enums are matched by name.
fn convert(comptime T: type, v: anytype) T {
    if (@typeInfo(T) != .@"enum") return v;
    return switch (v) {
        // A value that only one of them has doesn't compile.
        inline else => |tag| @field(T, @tagName(tag)),
    };
}

/// The looks in use now.
fn looks(app: *const App) cv.settings.Settings {
    var s: cv.settings.Settings = .{};
    inline for (@typeInfo(cv.settings.Settings).@"struct".field_names) |name| {
        if (@hasField(Renderer.Style, name)) {
            @field(s, name) = convert(@FieldType(cv.settings.Settings, name), @field(app.style, name));
        }
    }
    s.cutoff_factor = app.bond_params.cutoff_factor;
    s.ui_scale = app.ui_scale;
    return s;
}

/// Remember the looks the user changed. What the command line set for this
/// run isn't a change. Saved once nothing is `held` any more (a slider).
fn rememberLooks(app: *App, held: bool) void {
    const now = app.looks();
    defer app.looks_seen = now;
    const seen = app.looks_seen orelse return;
    inline for (@typeInfo(cv.settings.Settings).@"struct".field_names) |name| {
        if (@field(now, name) != @field(seen, name)) {
            @field(app.settings, name) = @field(now, name);
            app.settings_changed = true;
        }
    }
    if (app.settings_changed and !held) {
        app.settings_changed = false;
        app.saveSettings();
    }
}

/// The named looks as they were at first.
fn resetLooks(app: *App, comptime names: []const []const u8) void {
    var s = app.looks();
    const default: cv.settings.Settings = .{};
    inline for (names) |name| @field(s, name) = @field(default, name);
    app.applyLooks(s);
}

fn saveSettings(app: *App) void {
    const path = app.settings_path orelse return;
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    app.settings.write(&w) catch return;
    if (Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = w.buffered() })) {
        app.settings_unsaved = false;
    } else |e| {
        // Tried again with the next change, and at the end.
        app.settings_unsaved = true;
        app.fail("Could not save settings: {t}", .{e});
    }
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
    const swatch = fs * 0.75;
    const right = c.igGetCursorScreenPos().x + c.igGetContentRegionAvail().x;
    for (order[0..n], 0..) |z, i| {
        var buf: [24]u8 = undefined;
        const t = ui.printZ(&buf, "{d} {s}", .{ counts[z], cv.elements.symbol(z) }) catch continue;
        const w = swatch + fs * 0.3 + c.igCalcTextSize(t.ptr, null, false, -1).x;
        if (i > 0) {
            c.igSameLine(0, fs * 0.8);
            if (c.igGetCursorScreenPos().x + w > right) c.igNewLine();
        }
        c.igAlignTextToFramePadding();
        ui.swatch(cv.elements.displayColor(z), swatch);
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

    if (app.doc == null) {
        ui.textDisabled("Open a file first.", .{});
        return;
    }
    ui.textWrapped("Line up a reference frame with the current one (same atoms, same order).", .{});
    if (c.igButton("Use current frame as reference", ui.v2(-1, 0))) app.setReference();
    const df = &(app.diff orelse return);
    ui.text("Reference: frame {d}", .{df.reference.index + 1});
    c.igSameLine(0, -1);
    if (c.igSmallButton("Clear")) {
        app.clearDiff();
        return;
    }
    if (c.igSmallButton("Jump to reference")) app.setFrame(df.reference.index);
    _ = c.igCheckbox("Overlay", &df.overlay);
    inline for (.{ .{ "reference", reference_color }, .{ "current", current_color } }) |o| {
        c.igSameLine(0, fs);
        ui.swatch(o[1], fs * 0.75);
        c.igSameLine(0, fs * 0.3);
        ui.text(o[0], .{});
    }
    if (c.igSmallButton("Show file positions")) app.resetPlacement();
    ui.tooltip("Show both frames at their file positions, and switch Lock rotation off. Lock rotation lines them up again.");
    const res = df.result orelse {
        if (df.followed == null) ui.textWrapped("Out of memory.", .{}) else ui.textWrapped("Current frame has different atoms than the reference, or numbers them differently, so they can't be compared.", .{});
        return;
    };
    c.igSeparator();
    ui.text("RMSD  {d:.4} Å", .{res.rmsd});
    if (df.deviations.items.len > 0) {
        const i = res.worst;
        const z = df.numbering().numbers[i];
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
        // Whatever the constant says; some tests switch it off.
        t.app.session.selection_steps = true;
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
            if (d.display.real.frame != null and d.display.real.index == d.current) return;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.TestTimeout;
    }

    fn setDistance(t: *TestApp, v: f64) void {
        t.app.picks.selection.clearRetainingCapacity();
        t.app.toggleSelect(0);
        t.app.toggleSelect(1);
        t.app.applyEdit(.{ .distance = v });
    }

    fn select(t: *TestApp, atoms: []const u32) void {
        t.app.clearSelection();
        for (atoms) |a| t.app.toggleSelect(a);
    }

    fn deleteAtom(t: *TestApp, atom: u32) !void {
        const n = t.app.doc.?.display.real.frame.?.len();
        t.select(&.{atom});
        t.app.deleteSelection();
        try expectEqual(n - 1, t.app.doc.?.display.real.frame.?.len());
    }

    fn pasteAtom(t: *TestApp) !void {
        var frag = try t.app.doc.?.display.real.frame.?.subset(gpa, &.{0});
        defer frag.deinit(gpa);
        try t.app.appendFragment(frag);
    }

    /// Whether groups and molecules go through the bond between `a` and `b`.
    fn expectBonded(t: *TestApp, a: u32, b: u32, want: bool) !void {
        var graph = try t.app.drawnGraph();
        defer graph.deinit(gpa);
        try expectEqual(want, std.mem.findScalar(u32, graph.neighbors(a), b) != null);
    }

    fn expectSelected(t: *TestApp, want: []const u32) !void {
        try std.testing.expectEqualSlices(u32, want, t.app.selected());
    }

    fn expectCuts(t: *TestApp, want: []const [2]u32) !void {
        try expectEqual(want.len, t.app.picks.cuts.count());
        for (want) |w| try expect(t.app.isCut(w[0], w[1]));
    }

    /// `frames` frames of three H atoms, far enough apart to click on.
    fn openRow(t: *TestApp, frames: usize) !void {
        var text: Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        for (0..frames) |_| try text.writer.writeAll("3\n\nH 0 0 0\nH 3 0 0\nH 6 0 0\n");
        try t.openText(text.written());
        try t.show(0);
        t.app.fitCamera();
    }

    fn click(t: *TestApp, atom: u32) !void {
        const at = t.app.screenProjector().toScreen(t.app.doc.?.display.real.frame.?.positions[atom]).?;
        const was = t.app.selected().len;
        t.app.clickAt(at.x, at.y, 1);
        try expect(t.app.selected().len != was);
    }

    /// A lasso around everything, or around nothing.
    fn lassoAll(t: *TestApp, everything: bool) !void {
        const x: f32 = if (everything) -10 else 100;
        const corners = [_]lasso.Point{ .{ .x = x, .y = -10 }, .{ .x = x + 20, .y = -10 }, .{ .x = x + 20, .y = 10 }, .{ .x = x, .y = 10 } };
        t.app.lasso_points.clearRetainingCapacity();
        try t.app.lasso_points.appendSlice(gpa, &corners);
        t.app.applyLasso();
    }

    fn esc(t: *TestApp) void {
        var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
        ev.type = c.SDL_EVENT_KEY_DOWN;
        ev.key.key = c.SDLK_ESCAPE;
        t.app.handleEvent(&ev, false, false);
    }

    /// Starts an Alt-drag of atom 1, as if it had been grabbed.
    fn startDrag(t: *TestApp) !void {
        try t.app.startDrag(.translate, 1);
    }

    /// A drag of atom 1 on the shown frame that has moved it.
    fn dragSome(t: *TestApp) !void {
        try t.startDrag();
        t.app.dragMotion(0, 0, 0.1, 0);
        try expect(t.app.doc.?.display.real.frame.?.positions[1][0] != 0);
    }

    /// No drag is going on, and it left nothing behind in frame 0.
    fn expectAborted(t: *TestApp) !void {
        try expect(t.app.drag == null);
        // The release that follows does nothing.
        t.app.endDrag(true);
        try expect(!t.app.session.isEdited(0));
        try expect(!t.app.canUndo());
        const d = &t.app.doc.?;
        if (d.display.real.index == 0) try expectEqual(Vec3{ 0, 0, 1 }, d.display.real.frame.?.positions[1]);
    }

    /// Two steps apart in y, playing with interpolation at `at` between them.
    fn playBlend(t: *TestApp, at: f32) !void {
        try t.playBlendOf("2\n\nH 0 0 0\nH 10 0 0\n" ++ "2\n\nH 0 2 0\nH 10 2 0\n", at);
    }

    fn playBlendOf(t: *TestApp, text: []const u8, at: f32) !void {
        try t.openText(text);
        try t.show(0);
        t.app.fitCamera();
        t.app.interpolate = true;
        t.app.playing = true;
        t.app.interp_t = at;
        try t.waitForNext();
    }

    /// Waits until the shown step can be blended with the next one.
    fn waitForNext(t: *TestApp) !void {
        for (0..2000) |_| {
            t.app.updateNextFrame();
            if (t.app.nextReady()) return;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.TestTimeout;
    }

    fn distance(t: *TestApp) f64 {
        return cv.geometry.distance(t.app.doc.?.display.real.frame.?.positions, 0, 1);
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
    try expectEqual(null, t.app.doc.?.display.real.frame.?.energy);
    t.app.undo();
    try t.expectCopyEdited(true);
    t.app.undo();
    try t.settle();
    try expectEqual(1, t.distance());
    try expectEqual(1, t.app.doc.?.display.real.frame.?.energy);
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
    try expectEqual(0, t.app.doc.?.display.real.index);
    try expectEqual(1, t.distance());
    try expectEqual(0, t.app.doc.?.display.real.frame.?.energy);
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
        try expectEqual(0, t.app.picks.selection.items.len);
        try expectEqual(0, t.app.picks.cuts.count());
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

test "cuts end when the frame is left, and don't come back" {
    const Way = enum { step, playback, undo };
    for ([_]Way{ .step, .playback, .undo }) |way| {
        errdefer std.debug.print("by {t}\n", .{way});
        var t: TestApp = try .init(2);
        defer t.deinit();
        try t.show(1);
        t.setDistance(1.5); // for undo to go back to
        try t.show(0);
        t.app.toggleCutPair(0, 1);
        switch (way) {
            .step => t.app.setFrame(1),
            .playback => t.app.doc.?.current = 1, // as `advancePlayback` does
            .undo => t.app.undo(),
        }
        try t.settle();
        try t.expectCuts(&.{});
        try t.show(0);
        try t.expectCuts(&.{});
    }
}

test "pausing a blend stays on the frame and keeps its cuts" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlend(0.7);
    t.app.toggleCutPair(0, 1);
    t.app.togglePlay();
    try t.expectCuts(&.{.{ 0, 1 }});
}

test "cuts stay while the frame is shown, whatever is edited" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    t.app.toggleCutPair(1, 2);
    t.setDistance(1.5);
    t.setDistance(1.7);
    try t.expectCuts(&.{.{ 1, 2 }});
    t.app.toggleCutPair(0, 1);
    t.app.undo();
    t.app.revertFrame();
    t.app.undo();
    try t.expectCuts(&.{ .{ 1, 2 }, .{ 0, 1 } });
}

test "the selection carries over between frames with the same numbering" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    t.setDistance(1.5); // edited, but numbered as in the file
    try t.show(1);
    try t.expectSelected(&.{ 0, 1 });
    try t.show(0);
    try t.expectSelected(&.{ 0, 1 });
}

test "the selection is cleared between frames with different numberings" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    // Same numbers of atoms, but other elements.
    try t.openText("3\n\nH 0 0 0\nH 0 0 1\nO 0 0 2\n" ++ "3\n\nO 0 0 0\nH 0 0 1\nH 0 0 2\n");
    try t.show(0);
    t.app.toggleSelect(0);
    try t.show(1);
    try t.expectSelected(&.{});
}

test "moving to or from a frame with deleted or pasted atoms clears the selection" {
    const Edits = enum { delete, paste, replace };
    for ([_]Edits{ .delete, .paste, .replace }) |edits| {
        errdefer std.debug.print("{t}\n", .{edits});
        var t: TestApp = try .init(2);
        defer t.deinit();
        try t.show(0);
        // Replacing an H by an H looks like the file's atoms, but isn't.
        if (edits != .paste) try t.deleteAtom(0);
        if (edits != .delete) try t.pasteAtom();
        t.select(&.{0});
        try t.show(1);
        try t.expectSelected(&.{});
        t.select(&.{0});
        try t.show(0);
        try t.expectSelected(&.{});
    }
}

test "deleting what was pasted gives the file's numbering back" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    try t.pasteAtom();
    try t.deleteAtom(3);
    t.select(&.{1});
    try t.show(1);
    try t.expectSelected(&.{1});
}

test "undo to another frame keeps the selection if the numbering is the same" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(1);
    t.setDistance(1.5);
    try t.show(0);
    t.select(&.{2});
    t.app.undo();
    try t.settle();
    try expectEqual(1, t.app.doc.?.display.real.index);
    try t.expectSelected(&.{2});
}

test "steps with different numberings aren't blended, so an edit stays on the shown one" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("2\n\nO 0 0 0\nH 0 0 1\n" ++ "2\n\nH 0 0 0\nO 0 0 1\n");
    try t.show(0);
    t.app.interpolate = true;
    t.app.playing = true;
    t.app.interp_t = 0.7;
    const d = &t.app.doc.?;
    for (0..2000) |_| {
        t.app.updateNextFrame();
        if (d.display.next != null) break;
        try TestApp.io.sleep(.fromMilliseconds(1), .awake);
    }
    try expect(d.display.next != null);
    try expect(!t.app.nextReady());
    t.setDistance(1.5);
    try expect(t.app.session.isEdited(0));
    try t.expectSelected(&.{ 0, 1 });
}

test "a typed value right after adding a fragment moves what is attached in it" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.show(0);
    var water = try cv.source.openBytes(TestApp.gpa, "3\n\nO 0 0 0\nH 0.96 0 0\nH -0.24 0.93 0\n");
    defer water.source.deinit(TestApp.io, TestApp.gpa);
    try t.app.appendFragment(water.source.memory[0]);
    t.select(&.{ 4, 3 });
    t.app.applyEdit(.{ .distance = 1.5 });
    const p = t.app.doc.?.display.real.frame.?.positions;
    try std.testing.expectApproxEqAbs(1.5, cv.geometry.distance(p, 4, 3), 1e-4);
    try std.testing.expectApproxEqAbs(0.9605, cv.geometry.distance(p, 3, 5), 1e-3);
}

test "bonds follow edits, drags, undo, redo, revert and the cut-off at once" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("2\n\nH 0 0 0\nH 0.74 0 0\n");
    try t.show(0);
    try t.expectBonded(0, 1, true);
    t.setDistance(3);
    try t.expectBonded(0, 1, false);
    t.app.undo();
    try t.expectBonded(0, 1, true);
    t.app.redo();
    try t.expectBonded(0, 1, false);
    t.app.revertFrame();
    try t.expectBonded(0, 1, true);

    t.app.clearSelection();
    t.app.toggleSelect(0); // the base: only atom 1 is dragged
    t.app.toggleCutPair(0, 1);
    try t.app.startDrag(.translate, 1);
    t.app.restoreCuts();
    t.app.dragMotion(0, 0, 50, 0);
    try t.expectBonded(0, 1, false);
    t.app.endDrag(false);
    try t.expectBonded(0, 1, true);

    t.app.bond_params.cutoff_factor = 1;
    try t.expectBonded(0, 1, false);
}

test "a delete followed at once by a click, Ctrl+A or an edit uses the new bonds" {
    const Next = enum { click, ctrl_a, set };
    for ([_]Next{ .click, .ctrl_a, .set }) |next| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.openText("5\n\nO 9 0 0\nH 0 0 0\nH 0.74 0 0\nH 1.48 0 0\nO 0 9 0\n");
        try t.show(0);
        t.app.fitCamera();
        try t.expectBonded(2, 3, true);
        try t.deleteAtom(0);
        switch (next) {
            .click => try t.click(0),
            .ctrl_a => {
                t.select(&.{0});
                t.app.expandSelection();
                try t.expectSelected(&.{ 0, 1, 2 }); // not the far one
            },
            .set => {
                t.setDistance(1);
                try std.testing.expectApproxEqAbs(1.74, t.app.doc.?.display.real.frame.?.positions[2][0], 1e-4);
            },
        }
    }
}

test "a delete followed at once by a click in a diff overlay" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(1);
    t.app.setReference();
    try t.deleteAtom(0);
    try t.click(1);
    try t.expectSelected(&.{1});
    t.app.undo(); // the click
    t.app.undo();
    try t.click(2);
}

test "an edit fails, changing nothing, if its bonds can't be found" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("2\n\nH 0 0 0\nH 0.74 0 0\n");
    try t.show(0);
    var failing: std.testing.FailingAllocator = .init(TestApp.gpa, .{ .fail_index = 0 });
    t.select(&.{ 0, 1 });
    t.app.gpa = failing.allocator();
    t.app.applyEdit(.{ .distance = 2 });
    t.app.gpa = TestApp.gpa;
    try expect(!t.app.session.isEdited(0));
    try expect(!t.app.canUndo());
    try std.testing.expectApproxEqAbs(0.74, t.distance(), 1e-6);
    try t.expectSelected(&.{ 0, 1 });
    t.app.applyEdit(.{ .distance = 2 });
    try expect(t.app.session.isEdited(0));
}

test "a drag that never moved, redraws and cuts don't search for bonds again" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("2\n\nH 0 0 0\nH 0.74 0 0\n");
    try t.show(0);
    t.app.setReference();
    const d = &t.app.doc.?;
    const ref = &t.app.diff.?.reference;
    try expectEqual(1, t.app.bonds().len);
    try expectEqual(1, (try ref.bonds(TestApp.gpa, t.app.bond_params)).len);
    t.app.diff.?.overlay = false;
    const changes = d.display.real.changes;
    try t.startDrag();
    t.app.endDrag(true);
    try t.startDrag();
    t.app.endDrag(false);
    t.app.toggleCutPair(0, 1);
    try expectEqual(changes, d.display.real.changes);
    // A search would need memory.
    var failing: std.testing.FailingAllocator = .init(TestApp.gpa, .{ .fail_index = 0 });
    t.app.gpa = failing.allocator();
    defer t.app.gpa = TestApp.gpa;
    for (0..2) |_| try expectEqual(1, t.app.bonds().len);
    for (0..2) |_| try expectEqual(1, (try ref.bonds(t.app.gpa, t.app.bond_params)).len);
}

test "a cut changes what a typed value moves" {
    for ([_]bool{ false, true }) |cut| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.openText("3\n\nH 0 0 0\nH 0.74 0 0\nH 1.48 0 0\n");
        try t.show(0);
        const d = &t.app.doc.?;
        if (cut) t.app.toggleCutPair(1, 2);
        t.setDistance(1);
        const x: f32 = if (cut) 1.48 else 1.74;
        try std.testing.expectApproxEqAbs(x, d.display.real.frame.?.positions[2][0], 1e-4);
    }
}

test "delete translates cuts and its undo translates them and the selection back" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    t.app.session.selection_steps = false;
    try t.openText("5\n\nH 0 0 0\nH 0 0 1\nH 0 0 2\nH 0 0 3\nH 0 0 4\n");
    try t.show(0);
    t.app.toggleCutPair(0, 1);
    t.app.toggleCutPair(2, 3);
    try t.deleteAtom(1);
    try t.expectCuts(&.{.{ 1, 2 }}); // was 2-3
    t.app.toggleCutPair(2, 3); // was 3-4
    t.select(&.{ 3, 0 });
    t.app.undo();
    // Back where they were; the cut on the deleted atom stays gone.
    try t.expectCuts(&.{ .{ 2, 3 }, .{ 3, 4 } });
    try t.expectSelected(&.{ 4, 0 });
}

test "a selection on deleted atoms stays gone when that is undone" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    t.app.session.selection_steps = false;
    try t.show(0);
    try t.deleteAtom(1);
    try t.expectSelected(&.{});
    t.app.undo();
    try t.expectSelected(&.{});
}

test "revert translates cuts and selection, even past the undo limit" {
    for ([_]bool{ false, true }) |past| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.show(0);
        try t.deleteAtom(0);
        if (past) for (0..cv.edit.max_steps) |i| t.setDistance(2 + 0.01 * @as(f64, @floatFromInt(i)));
        t.app.toggleCutPair(0, 1);
        t.select(&.{1});
        t.app.revertFrame();
        try t.expectCuts(&.{.{ 1, 2 }});
        try t.expectSelected(&.{2});
        t.app.undo();
        try t.expectCuts(&.{.{ 0, 1 }});
        try t.expectSelected(&.{1});
    }
}

test "undoing a paste drops cuts and selection on the pasted atoms only" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    t.app.session.selection_steps = false;
    try t.show(0);
    t.app.toggleCutPair(0, 1);
    try t.pasteAtom();
    try t.expectSelected(&.{3});
    t.app.toggleCutPair(2, 3);
    t.app.toggleSelect(1);
    t.app.undo();
    try t.expectCuts(&.{.{ 0, 1 }});
    try t.expectSelected(&.{1});
}

test "redo restores each kind of edit exactly, and the edited state" {
    const Kind = enum { set, drag, paste, delete, revert };
    for ([_]Kind{ .set, .drag, .paste, .delete, .revert }) |kind| {
        errdefer std.debug.print("{t}\n", .{kind});
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.show(0);
        if (kind == .revert) t.setDistance(1.9);
        switch (kind) {
            .set => t.setDistance(1.5),
            .drag => {
                try t.dragSome();
                t.app.endDrag(true);
            },
            .paste => try t.pasteAtom(),
            .delete => try t.deleteAtom(1),
            .revert => t.app.revertFrame(),
        }
        const d = &t.app.doc.?;
        var after = try d.display.real.frame.?.clone(TestApp.gpa);
        defer after.deinit(TestApp.gpa);
        const origins: ?[]u32 = if (t.app.session.origins(0)) |o| try TestApp.gpa.dupe(u32, o) else null;
        defer if (origins) |o| TestApp.gpa.free(o);
        for (0..2) |_| {
            t.app.undo();
            try t.expectCopyEdited(kind == .revert);
            t.app.redo();
            try t.expectCopyEdited(kind != .revert);
            try std.testing.expectEqualSlices(Vec3, after.positions, d.display.real.frame.?.positions);
            try std.testing.expectEqualSlices(u8, after.numbers, d.display.real.frame.?.numbers);
            try expectEqual(after.energy, d.display.real.frame.?.energy);
            try std.testing.expectEqualDeep(@as(?[]const u32, origins), t.app.session.origins(0));
        }
    }
}

test "redo jumps to the frame it changed and translates cuts and selection" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    t.app.session.selection_steps = false;
    try t.show(1);
    try t.deleteAtom(0);
    t.app.undo();
    t.app.toggleCutPair(1, 2);
    t.select(&.{ 0, 2 });
    t.app.redo();
    try t.expectCuts(&.{.{ 0, 1 }});
    try t.expectSelected(&.{1});

    t.app.undo();
    try t.show(0);
    t.app.redo();
    try t.settle();
    try expectEqual(1, t.app.doc.?.display.real.index);
    try expectEqual(2, t.app.doc.?.display.real.frame.?.len());
}

test "redo aborts a drag and pauses playback" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    try t.dragSome();
    t.app.redo(); // nothing to redo
    try t.expectAborted();
    t.setDistance(1.5);
    t.app.undo();
    try t.dragSome();
    t.app.playing = true;
    t.app.interp_t = 0.2;
    t.app.redo();
    try expect(t.app.drag == null);
    try expect(!t.app.playing);
    try expectEqual(0, t.app.interp_t);
    try std.testing.expectApproxEqAbs(1.5, t.distance(), 1e-5);
}

test "a cancelled drag keeps what can be redone, a completed one doesn't" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.show(0);
    t.setDistance(1.5);
    t.app.undo();
    try t.dragSome();
    t.app.endDrag(false);
    try expect(t.app.canRedo());
    try t.dragSome();
    t.app.endDrag(true);
    try expect(!t.app.canRedo());
}

test "undo and redo keys" {
    try expectEqual(.undo, historyKey(c.SDLK_Z, c.SDL_KMOD_LCTRL));
    try expectEqual(.redo, historyKey(c.SDLK_Z, c.SDL_KMOD_LCTRL | c.SDL_KMOD_RSHIFT));
    try expectEqual(.redo, historyKey(c.SDLK_Y, c.SDL_KMOD_RCTRL));
    try expectEqual(null, historyKey(c.SDLK_X, c.SDL_KMOD_LCTRL));
}

test "each click, lasso, Ctrl+A and clear is one step" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(1);
    try t.click(2);
    try t.click(0);
    try t.click(2); // deselects it
    try t.lassoAll(true);
    t.esc();
    t.app.expandSelection();
    t.app.clickAt(100, 100, 1); // empty space
    const states = [_][]const u32{ &.{}, &.{2}, &.{ 2, 0 }, &.{0}, &.{ 0, 1, 2 }, &.{}, &.{ 0, 1, 2 }, &.{} };
    for (0..2) |_| {
        var i = states.len;
        while (i > 0) {
            i -= 1;
            try t.expectSelected(states[i]);
            t.app.undo();
        }
        try t.expectSelected(&.{});
        for (states) |state| {
            try t.expectSelected(state);
            t.app.redo();
        }
    }
    try expect(!t.app.session.isEdited(0));
    try t.expectCopyEdited(false);
}

test "cutting, restoring and restoring all cuts are one step each" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.show(0);
    t.app.cutBond(0, 1);
    t.app.cutBond(1, 2);
    t.app.cutBond(0, 1); // restores it
    t.app.cutBond(0, 1);
    t.app.restoreCuts();
    t.app.undo();
    try t.expectCuts(&.{ .{ 0, 1 }, .{ 1, 2 } });
    t.app.undo();
    try t.expectCuts(&.{.{ 1, 2 }});
    t.app.undo();
    try t.expectCuts(&.{ .{ 0, 1 }, .{ 1, 2 } });
    t.app.redo();
    t.app.redo();
    t.app.redo();
    try t.expectCuts(&.{});
    try expect(!t.app.session.isEdited(0));
}

test "gestures that change nothing, frame changes, playback and the camera aren't steps" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(2);
    try t.click(1);
    try t.lassoAll(false);
    t.app.restoreCuts();
    try t.show(1);
    t.app.togglePlay();
    t.app.togglePlay();
    t.app.camera.orbit(10, 5);
    t.app.fitCamera();
    try t.show(0);
    t.app.undo();
    try t.expectSelected(&.{});
    t.esc();
    t.app.redo();
    try t.expectSelected(&.{1});
}

test "paste and delete are one step that restores the selection and cuts" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(1);
    try t.click(2);
    try t.click(1);
    t.app.cutBond(1, 2);
    t.app.cutBond(0, 1);
    t.app.deleteSelection();
    try t.expectCuts(&.{});
    t.app.undo();
    try t.expectSelected(&.{ 2, 1 });
    try t.expectCuts(&.{ .{ 1, 2 }, .{ 0, 1 } });
    t.app.redo();
    try t.expectSelected(&.{});
    try t.expectCuts(&.{});
    t.app.undo();

    try t.pasteAtom();
    try t.expectSelected(&.{3});
    t.app.undo();
    try t.expectSelected(&.{ 2, 1 });
    try t.expectCuts(&.{ .{ 1, 2 }, .{ 0, 1 } });
    t.app.redo();
    try t.expectSelected(&.{3});
    try t.expectCuts(&.{ .{ 1, 2 }, .{ 0, 1 } });
}

test "undoing a delete made before its frame was left restores the selection only" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(2);
    try t.click(1);
    t.app.cutBond(0, 1);
    t.app.deleteSelection();
    try t.show(1);
    t.app.undo();
    try t.settle();
    try expectEqual(0, t.app.doc.?.display.real.index);
    try t.expectSelected(&.{1});
    try t.expectCuts(&.{});
}

test "selection steps stay on the frame and don't pause playback, geometry steps jump" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(2);
    t.setDistance(4);
    t.app.clearSelection();
    try t.click(2);
    try t.show(1);
    try t.click(1);
    t.app.playing = true;
    t.app.undo();
    try t.expectSelected(&.{2});
    t.app.undo();
    try t.expectSelected(&.{});
    try expectEqual(1, t.app.doc.?.current);
    try expect(t.app.playing);
    t.app.undo();
    try t.settle();
    try expectEqual(0, t.app.doc.?.display.real.index);
    try expect(!t.app.playing);
}

test "steps that no longer apply are skipped" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("2\n\nH 0 0 0\nH 3 0 0\n" ++ "2\n\nO 0 0 0\nH 3 0 0\n");
    try t.show(0);
    t.app.fitCamera();
    try t.click(1);
    t.app.cutBond(0, 1);
    try t.show(1); // other numbering; the cut ends
    try t.click(0);
    t.app.undo();
    try t.expectSelected(&.{});
    t.app.undo(); // nothing applies here
    try t.expectSelected(&.{});
    try expect(!t.app.canUndo());
    try t.show(0);
    try t.expectCuts(&.{});
    try expect(!t.app.canUndo()); // nothing selected any more, as before the click
    // Nothing is lost: what applies can still be redone.
    t.app.redo();
    try t.expectCuts(&.{});
    try t.click(1);
    t.app.undo();
    try t.expectSelected(&.{});
}

test "a step that was skipped gives way to one that has an effect" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(2);
    try t.click(1);
    t.app.cutBond(0, 1);
    try t.show(1);
    t.app.undo(); // past the cut
    try t.expectSelected(&.{});
    try expectEqual(1, t.app.doc.?.display.real.index);
    t.app.redo();
    try t.expectSelected(&.{1});
    try expect(!t.app.canRedo()); // the cut ended
}

test "a hundred geometry steps and a thousand in total" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(1);
    // Enough to drop the oldest, kept apart from geometry steps.
    for (0..cv.edit.max_total + 50) |_| try t.click(0);
    for (0..cv.edit.max_steps + 1) |i| {
        t.setDistance(4 + 0.01 * @as(f64, @floatFromInt(i)));
        t.app.clearSelection();
    }
    var n: usize = 0;
    while (t.app.session.isEdited(0)) : (n += 1) {
        if (n == cv.edit.max_steps) break;
        t.app.undo();
    }
    // The first geometry step is gone, so it stays edited; the rest are selection steps.
    try expectEqual(cv.edit.max_steps, n);
    try std.testing.expectApproxEqAbs(4, t.distance(), 1e-5);
    while (t.app.canUndo()) : (n += 1) t.app.undo();
    try expectEqual(cv.edit.max_total, n);
    try expect(t.app.session.isEdited(0));
}

test "the oldest selection steps go before any geometry step" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(1);
    t.setDistance(4);
    t.app.clearSelection();
    for (0..cv.edit.max_total + 5) |_| try t.click(0);
    var n: usize = 0;
    while (t.app.canUndo()) : (n += 1) t.app.undo();
    try expectEqual(cv.edit.max_total, n);
    try expect(!t.app.session.isEdited(0));
}

test "undoing a revert restores the selection and cuts it dropped" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(1);
    try t.pasteAtom();
    try t.click(0);
    t.app.cutBond(2, 3);
    t.app.revertFrame();
    try t.expectSelected(&.{0});
    try t.expectCuts(&.{});
    t.app.undo();
    try t.expectSelected(&.{ 3, 0 });
    try t.expectCuts(&.{.{ 2, 3 }});
    t.app.redo();
    try t.expectSelected(&.{0});
    try t.expectCuts(&.{});
}

test "steps skipped on the way to a geometry step can be redone" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("3\n\nH 0 0 0\nH 3 0 0\nH 6 0 0\n" ++ "3\n\nO 0 0 0\nH 3 0 0\nH 6 0 0\n");
    try t.show(0);
    t.app.fitCamera();
    t.setDistance(4);
    t.app.clearSelection();
    try t.click(2);
    try t.show(1);
    t.app.undo(); // past the click
    try t.settle();
    try expect(!t.app.session.isEdited(0));
    try t.expectSelected(&.{});
    t.app.redo();
    try expect(t.app.session.isEdited(0));
    t.app.redo();
    try t.expectSelected(&.{2});
}

test "a gesture that can't be recorded changes nothing" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openRow(1);
    try t.click(2);
    t.app.cutBond(0, 1);
    var failing: std.testing.FailingAllocator = .init(TestApp.gpa, .{ .fail_index = 0 });
    for ([_]bool{ false, true }) |record| {
        const gpa = if (record) &t.app.session.gpa else &t.app.gpa;
        gpa.* = failing.allocator();
        t.app.deselect();
        t.app.cutBond(0, 1);
        t.app.restoreCuts();
        gpa.* = TestApp.gpa;
        try t.expectSelected(&.{2});
        try t.expectCuts(&.{.{ 0, 1 }});
    }
    t.app.undo();
    try t.expectCuts(&.{}); // the last one that was recorded
}

test "a delete or paste that fails changes nothing" {
    for ([_]bool{ false, true }) |paste| for ([_]bool{ false, true }) |in_session| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var t: TestApp = try .init(1);
            defer t.deinit();
            try t.openRow(1);
            try t.click(2);
            t.app.cutBond(0, 1);
            var frag = try t.app.doc.?.display.real.frame.?.subset(TestApp.gpa, &.{0});
            defer frag.deinit(TestApp.gpa);
            var failing: std.testing.FailingAllocator = .init(TestApp.gpa, .{ .fail_index = fail_index });
            const gpa = if (in_session) &t.app.session.gpa else &t.app.gpa;
            gpa.* = failing.allocator();
            if (paste) t.app.appendFragment(frag) catch {} else t.app.deleteSelection();
            gpa.* = TestApp.gpa;
            if (t.app.session.isEdited(0)) break;
            try expectEqual(3, t.app.doc.?.display.real.frame.?.len());
            try t.expectSelected(&.{2});
            try t.expectCuts(&.{.{ 0, 1 }});
        }
        try expect(fail_index > 0);
    };
}

test "with selection steps off, only geometry is undone" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    t.app.session.selection_steps = false;
    try t.openRow(1);
    t.setDistance(4);
    t.app.clearSelection();
    try t.click(2);
    t.app.cutBond(1, 2);
    t.app.undo();
    try t.expectSelected(&.{2});
    try t.expectCuts(&.{.{ 1, 2 }});
    try expect(!t.app.session.isEdited(0));
    try t.click(0); // doesn't clear what can be redone
    t.app.redo();
    try expect(t.app.session.isEdited(0));
    try expect(!t.app.canRedo());
    t.app.deleteSelection();
    t.app.undo();
    try t.expectSelected(&.{});
    try t.expectCuts(&.{});
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
    try expectEqual(1, t.app.doc.?.display.real.frame.?.len());
    try expectEqual(Vec3{ 5, 5, 5 }, t.app.doc.?.display.real.frame.?.positions[0]);
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
            var frag = try t.app.doc.?.display.real.frame.?.subset(TestApp.gpa, &.{0});
            defer frag.deinit(TestApp.gpa);
            try t.app.appendFragment(frag);
        }
        try expect(t.app.drag == null);
        const f = t.app.doc.?.display.real.frame.?;
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
    try expect(!t.app.canUndo());
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
    try expectEqual(null, t.app.doc.?.display.real.frame.?.energy);
    t.app.undo();
    try t.expectAborted();
}

test "an edit during interpolated playback pauses it and applies to the step it plays from" {
    const Kind = enum { drag, set, paste, delete };
    for ([_]Kind{ .drag, .set, .paste, .delete }) |kind| for ([_]f32{ 0.3, 0.7 }) |at| {
        errdefer std.debug.print("{t} at {d}\n", .{ kind, at });
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.playBlend(at);
        t.app.picks.selection.clearRetainingCapacity();
        switch (kind) {
            .drag => {
                try t.startDrag();
                t.app.dragMotion(0, 0, 0.1, 0);
                t.app.endDrag(true);
            },
            .set => t.setDistance(5),
            .paste => {
                var frag = try t.app.doc.?.display.real.frame.?.subset(TestApp.gpa, &.{0});
                defer frag.deinit(TestApp.gpa);
                try t.app.appendFragment(frag);
            },
            .delete => {
                t.app.toggleSelect(1);
                t.app.deleteSelection();
            },
        }
        const d = &t.app.doc.?;
        try expect(!t.app.playing);
        try expectEqual(0, t.app.interp_t);
        try expectEqual(0, d.current);
        try expectEqual(0, d.display.real.index);
        try expect(t.app.session.isEdited(0));
        try expect(!t.app.session.isEdited(1));
        // Atom 0 is where that step has it (none of these move it).
        try expectEqual(Vec3{ 0, 0, 0 }, d.display.real.frame.?.positions[0]);
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

test "revert during a blend reverts the frame it is offered for" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlend(0);
    t.setDistance(5);
    t.app.playing = true;
    t.app.interp_t = 0.7;
    for (0..2000) |_| {
        t.app.updateNextFrame();
        if (t.app.nextReady()) break;
        try TestApp.io.sleep(.fromMilliseconds(1), .awake);
    }
    try expect(t.app.nextReady());
    t.app.revertFrame();
    try expect(!t.app.session.isEdited(0));
    try expectEqual(0, t.app.doc.?.current);
    try expectEqual(0, t.app.interp_t);
    try expect(!t.app.playing);
}

test "pausing floors, however near the next step is, and playing goes on from there" {
    for ([_]f32{ 0.3, 0.7, 0.99 }) |at| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.playBlend(at);
        t.app.togglePlay();
        try expectEqual(0, t.app.doc.?.current);
        try expectEqual(0, t.app.doc.?.display.real.index);
        try expectEqual(0, t.app.interp_t);
        try expectEqual(0, t.app.drawnPositions().?[0][1]);
        t.app.togglePlay();
        try expectEqual(0, t.app.doc.?.current);
        try expectEqual(0, t.app.interp_t);
    }
}

test "the timeline's window: a new file's, following, and pans that hold" {
    const Window = cv.window.Window;
    var t: TestApp = try .init(100);
    defer t.deinit();
    const s = &t.app.timeline;
    s.initial = .{ 20, 30 };
    try t.show(0);
    s.follow(&t.app, &t.app.doc.?);
    try expectEqual(Window{ .lo = 20, .hi = 30 }, s.window);
    // Steps and jumps bring the playhead into view; scrubbing doesn't scroll.
    try t.show(60);
    s.follow(&t.app, &t.app.doc.?);
    try expect(s.window.contains(60));
    t.app.plot_drag = 64;
    const held = s.window;
    try t.show(64);
    s.follow(&t.app, &t.app.doc.?);
    try expectEqual(held, s.window);
    t.app.plot_drag = null;
    // Panned away while playing between two frames, then paused.
    t.app.interpolate = true;
    t.app.playing = true;
    t.app.interp_t = 0.7;
    try t.waitForNext();
    s.follow(&t.app, &t.app.doc.?);
    s.window = .between(0, 10, 100);
    t.app.togglePlay();
    s.follow(&t.app, &t.app.doc.?);
    try expectEqual(Window{ .lo = 0, .hi = 10 }, s.window);
    // Another file has its own.
    try t.open(50);
    try t.show(0);
    s.follow(&t.app, &t.app.doc.?);
    try expectEqual(Window.all(50), s.window);
}

test "saving during a blend saves the step it plays from" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlend(0.7);
    t.app.stopForEdit(); // as `saveDialog` does
    try expectEqual(0, t.app.doc.?.display.real.index);
    try expectEqual(0, t.app.doc.?.current);
}

test "an edit during a blend uses the bonds of the step it plays from" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlendOf("3\n\nH 0 0 0\nH 0.74 0 0\nH 2.7 0 0\n" ++ "3\n\nH 0 0 0\nH 2 0 0\nH 2.74 0 0\n", 0.7);
    t.setDistance(3);
    // Atom 2 is bonded to atom 1 in the next step only, and stays.
    try std.testing.expectApproxEqAbs(2.7, t.app.doc.?.display.real.frame.?.positions[2][0], 1e-4);
}

test "delete with nothing selected and pasting as new abort a drag" {
    for ([_]bool{ false, true }) |delete| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.show(0);
        try t.dragSome();
        if (delete) {
            t.app.deleteSelection();
            try t.expectAborted();
        } else {
            try t.open(1);
            try expect(t.app.drag == null);
        }
    }
}

test "paste with nothing on the clipboard and a missing fragment file abort a drag" {
    for ([_]bool{ false, true }) |file| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.show(0);
        try t.dragSome();
        if (file) try std.testing.expectError(error.FileNotFound, t.app.addFragmentFile("no/such/file.xyz")) else t.app.pasteXyz(false);
        try t.expectAborted();
    }
}

test "Esc cancels a drag" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.show(0);
    try t.dragSome();
    var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_KEY_DOWN;
    ev.key.key = c.SDLK_ESCAPE;
    t.app.handleEvent(&ev, false, false);
    try t.expectAborted();
}

test "going back to the shown frame before another arrives keeps the drag" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    t.app.setFrame(1);
    try t.dragSome();
    t.app.setFrame(0);
    try expect(t.app.drag != null);
}

test "a drag that can't start or be committed leaves the frame as it was" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.show(0);
    var failing: std.testing.FailingAllocator = .init(TestApp.gpa, .{ .fail_index = 0 });
    t.app.gpa = failing.allocator();
    const started = t.app.startDrag(.translate, 1);
    t.app.gpa = TestApp.gpa;
    try std.testing.expectError(error.OutOfMemory, started);
    try t.expectAborted();

    try t.dragSome();
    t.app.gpa = failing.allocator();
    t.app.endDrag(true);
    t.app.gpa = TestApp.gpa;
    try t.expectAborted();
}

test "during a blend, the drawn atoms are between the steps, and the bonds the base step's" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    // Bonded in the first step only.
    try t.playBlendOf("2\n\nH 0 0 0\nH 0.74 0 0\n" ++ "2\n\nH 0 0 0\nH 2.74 0 0\n", 0.7);
    const p = t.app.drawnPositions().?;
    try expect(p[1][0] > 2 and p[1][0] < 2.6);
    try expectEqual(1, t.app.bonds().len);
    t.app.interp_t = 0;
    try expectEqual(0.74, t.app.drawnPositions().?[1][0]);
}

test "the lasso selects atoms where they are drawn during a blend" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlend(0.7);
    const p = t.app.drawnPositions().?[1];
    const real = t.app.doc.?.display.real.frame.?.positions[1];
    const sp = t.app.screenProjector();
    for ([_]Vec3{ real, p }, [_]usize{ 0, 1 }) |around, want| {
        const at = sp.toScreen(around).?;
        const r = 0.01;
        const corners = [_]lasso.Point{ .{ .x = at.x - r, .y = at.y - r }, .{ .x = at.x + r, .y = at.y - r }, .{ .x = at.x + r, .y = at.y + r }, .{ .x = at.x - r, .y = at.y + r } };
        t.app.clearSelection();
        t.app.lasso_points.clearRetainingCapacity();
        try t.app.lasso_points.appendSlice(TestApp.gpa, &corners);
        t.app.applyLasso();
        try expectEqual(want, t.app.selected().len);
    }
}

test "a click during a blend hits what is drawn, not the real step" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlend(0.7);
    const p = t.app.drawnPositions().?[1];
    const sp = t.app.screenProjector();
    const real = sp.toScreen(t.app.doc.?.display.real.frame.?.positions[1]).?;
    t.app.clickAt(real.x, real.y, 1);
    try t.expectSelected(&.{});
    const drawn = sp.toScreen(p).?;
    t.app.clickAt(drawn.x, drawn.y, 1);
    try t.expectSelected(&.{1});
}

test "steps with other atoms don't shape a blend, even if they look alike" {
    for ([_]bool{ false, true }) |replaced| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        const file = "2\n\nH 0 0 0\nH 5 1 0\n" ++ "2\n\nH 0 0 0\nH 5 0 0\n" ++ "2\n\nH 0 0 0\nH 5 1 0\n";
        try t.openText(file);
        try t.show(0);
        if (replaced) {
            // The same elements as before, but atom 1 is another one.
            try t.deleteAtom(1);
            var frag = try t.app.doc.?.display.real.frame.?.subset(TestApp.gpa, &.{0});
            defer frag.deinit(TestApp.gpa);
            frag.positions[0] = .{ 5, -1, 0 };
            try t.app.appendFragment(frag);
        }
        t.app.interpolate = true;
        t.app.playing = true;
        t.app.interp_t = 0.25;
        t.app.doc.?.current = 1;
        try t.settle();
        for (0..2000) |_| {
            t.app.updateNextFrame();
            if (t.app.nextReady() and t.app.doc.?.display.prev != null) break;
            try TestApp.io.sleep(.fromMilliseconds(1), .awake);
        }
        // Flat at frame 1: it is a turn (1, 0, 1), or has no neighbour. The
        // pasted atom (-1, 0, 1) would make it start rising.
        const y = t.app.drawnPositions().?[1][1];
        try std.testing.expectApproxEqAbs(0.15625, y, 1e-4);
    }
}

test "measured values during a blend are those of what is drawn" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlendOf("2\n\nH 0 0 0\nH 3 0 0\n" ++ "2\n\nH 0 0 0\nH 5 0 0\n", 0.5);
    t.select(&.{ 0, 1 });
    const value = t.app.measured().?.distance;
    try expect(value > 3.5 and value < 4.5);
    t.app.togglePlay();
    try std.testing.expectApproxEqAbs(3, t.app.measured().?.distance, 1e-6);
}

test "copying during a blend takes the real step being played from" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlendOf("2\n\nH 0 0 0\nH 3 0 0\n" ++ "2\n\nH 0 0 0\nH 5 0 0\n", 0.7);
    try expect(t.app.drawnPositions().?[1][0] != 3);
    const text = try t.app.copyText();
    defer TestApp.gpa.free(text);
    try expect(std.mem.find(u8, text, "frame=1/2") != null);
    try expect(std.mem.find(u8, text, "3.00000000") != null);
}

test "a diff isn't blended" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlend(0.7);
    t.app.setReference();
    t.app.diff.?.overlay = false;
    try expectEqual(t.app.doc.?.display.real.frame.?.positions[1], t.app.drawnPositions().?[1]);
}

/// Five atoms, turned by `angle` about z and moved, as frame text.
fn turnedFrame(buf: []u8, angle: f32) []const u8 {
    const atoms = [_]Vec3{ .{ 0, 0, 0 }, .{ 3, 0, 0 }, .{ 0, 4, 1 }, .{ -3, 1, 2 }, .{ 1, -3, -2 } };
    const q = cv.math.Quat.fromAxisAngle(.{ 0, 0, 1 }, angle);
    var w: Io.Writer = .fixed(buf);
    w.writeAll("5\n\n") catch unreachable;
    for (atoms) |a| {
        const p = q.rotate(a) + Vec3{ angle, -2 * angle, 0 };
        w.print("H {d:.6} {d:.6} {d:.6}\n", .{ p[0], p[1], p[2] }) catch unreachable;
    }
    return w.buffered();
}

/// Frames turning by 0.2 each, the first one shown and locked.
fn lockedTest(frames: usize) !TestApp {
    var t: TestApp = try .init(1);
    errdefer t.deinit();
    var text: Io.Writer.Allocating = .init(TestApp.gpa);
    defer text.deinit();
    var buf: [512]u8 = undefined;
    for (0..frames) |i| try text.writer.writeAll(turnedFrame(&buf, 0.2 * @as(f32, @floatFromInt(i))));
    try t.openText(text.written());
    try t.show(0);
    t.app.fitCamera();
    return t;
}

/// The drawn atoms and a point of the background, in view space.
fn onScreen(t: *TestApp) [6]Vec3 {
    var out: [6]Vec3 = undefined;
    const p = t.app.drawnPositions().?;
    for (out[0..5], p[0..5]) |*o, q| o.* = t.app.camera.view().transformPoint(q);
    out[5] = t.app.camera.bgView().transformPoint(.{ 1, 2, 3 });
    return out;
}

fn expectOnScreen(t: *TestApp, want: [6]Vec3) !void {
    for (want, onScreen(t)) |a, b| try expect(cv.math.length(a - b) < 2e-3);
}

test "while locked, molecule and background stay still on screen, by any path" {
    var t = try lockedTest(6);
    defer t.deinit();
    t.app.setLockRotation(true);
    const first = onScreen(&t);
    for ([_]usize{ 1, 2, 5, 3, 0, 4, 1 }) |i| {
        try t.show(i);
        t.app.followRotationLock();
        try expectOnScreen(&t, first);
    }
    // The user's own rotations are kept.
    t.app.camera.orbit(30, 12);
    const turned = onScreen(&t);
    for ([_]usize{ 4, 0 }) |i| {
        try t.show(i);
        t.app.followRotationLock();
        try expectOnScreen(&t, turned);
    }
}

test "while locked, a blend stays still on screen" {
    var t = try lockedTest(2);
    defer t.deinit();
    t.app.setLockRotation(true);
    const first = onScreen(&t);
    t.app.interpolate = true;
    t.app.playing = true;
    try t.waitForNext();
    for ([_]f32{ 0.3, 0.8, 0.5 }) |at| {
        t.app.interp_t = at;
        t.app.followRotationLock();
        // A straight blend of a turn shrinks it a little.
        for (first[0..5], onScreen(&t)[0..5]) |a, b| try expect(cv.math.length(a - b) < 0.1);
        try expect(cv.math.length(first[5] - onScreen(&t)[5]) < 2e-3);
    }
}

test "each geometry edit unlocks, without moving view or background" {
    const Kind = enum { drag, set, paste, delete, undo, redo, revert };
    for (std.enums.values(Kind)) |kind| {
        errdefer std.debug.print("{t}\n", .{kind});
        var t = try lockedTest(3);
        defer t.deinit();
        try t.show(2);
        if (kind == .undo or kind == .redo or kind == .revert) t.setDistance(3.5);
        if (kind == .redo) t.app.undo();
        try t.show(0);
        t.app.setLockRotation(true);
        try t.show(2);
        t.app.followRotationLock();
        const view = t.app.camera;
        switch (kind) {
            .drag => {
                try t.startDrag();
                try expect(t.app.lock_rotation); // not moved yet
                t.app.dragMotion(0, 0, 0.1, 0);
                try expect(!t.app.lock_rotation);
                t.app.endDrag(true);
            },
            .set => t.setDistance(3.5),
            .paste => {
                t.app.scene_radius = 1000;
                try t.pasteAtom();
            },
            .delete => try t.deleteAtom(1),
            .undo => t.app.undo(),
            .redo => t.app.redo(),
            .revert => t.app.revertFrame(),
        }
        try expect(!t.app.lock_rotation);
        t.app.followRotationLock();
        // Pasting may zoom out to show the fragment, but doesn't turn.
        if (kind != .paste) try std.testing.expectEqualDeep(view, t.app.camera);
        try std.testing.expectEqualDeep(view.rotation, t.app.camera.rotation);
        try std.testing.expectEqualDeep(view.bg_rotation, t.app.camera.bg_rotation);
        if (kind != .undo) t.app.undo() else t.app.redo();
        try expect(!t.app.lock_rotation);
        const after = t.app.camera;
        try t.show(1);
        t.app.followRotationLock();
        try std.testing.expectEqualDeep(after, t.app.camera);
    }
}

test "undo, redo and revert during a blend or of another frame follow it before unlocking" {
    const Kind = enum { undo, redo, revert, undo_elsewhere };
    for (std.enums.values(Kind)) |kind| {
        errdefer std.debug.print("{t}\n", .{kind});
        var t = try lockedTest(3);
        defer t.deinit();
        const edited: usize = if (kind == .undo_elsewhere) 2 else 1;
        try t.show(edited);
        t.setDistance(3.5); // moves atom 1 only
        if (kind == .redo) t.app.undo();
        try t.show(0);
        t.app.setLockRotation(true);
        const first = onScreen(&t);
        try t.show(1);
        t.app.followRotationLock();
        t.app.interpolate = true;
        t.app.playing = true;
        t.app.interp_t = 0.4;
        try t.waitForNext();
        t.app.followRotationLock();
        switch (kind) {
            .undo, .undo_elsewhere => t.app.undo(),
            .redo => t.app.redo(),
            .revert => t.app.revertFrame(),
        }
        try expect(!t.app.lock_rotation);
        try expectEqual(edited, t.app.doc.?.display.real.index);
        // Atom 1 pulls the fit a little.
        const now = onScreen(&t);
        for ([_]usize{ 0, 2, 3, 4 }) |i| try expect(cv.math.length(first[i] - now[i]) < 0.3);
        try expect(cv.math.length(first[5] - now[5]) < 2e-3);
    }
}

test "pasting out of sight re-frames without turning the background" {
    var t = try lockedTest(3);
    defer t.deinit();
    t.app.setLockRotation(true);
    try t.show(2);
    t.app.followRotationLock();
    const before = t.app.camera;
    var frag = try t.app.doc.?.display.real.frame.?.subset(TestApp.gpa, &.{0});
    defer frag.deinit(TestApp.gpa);
    frag.positions[0] = .{ 500, 500, 0 };
    try t.app.appendFragment(frag);
    try expect(t.app.camera.distance > before.distance);
    try std.testing.expectEqualDeep(before.bg_rotation, t.app.camera.bg_rotation);
    try std.testing.expectEqualDeep(before.bg_offset, t.app.camera.bg_offset);
}

test "the lock is off for a file that is opened" {
    var t = try lockedTest(2);
    defer t.deinit();
    t.app.setLockRotation(true);
    try t.open(2);
    try expect(!t.app.lock_rotation);
}

test "in a diff overlay the current structure is drawn at its own coordinates" {
    var t = try lockedTest(3);
    defer t.deinit();
    t.app.setReference();
    try t.show(2);
    t.app.followRotationLock();
    for (t.app.doc.?.display.real.frame.?.positions, t.app.drawnPositions().?) |p, q| try expectEqual(p, q);
}

test "starting a diff locks, and ending it restores the lock" {
    for ([_]bool{ false, true }) |before| {
        var t = try lockedTest(3);
        defer t.deinit();
        t.app.setLockRotation(before);
        t.app.setReference();
        try expect(t.app.lock_rotation);
        t.app.setReference(); // again
        t.app.clearDiff();
        try expectEqual(before, t.app.lock_rotation);
    }
}

/// The reference as drawn and a point of the background, in view space.
fn referenceOnScreen(t: *TestApp) [6]Vec3 {
    var out = onScreen(t);
    for (out[0..5], t.app.diff.?.placed.items) |*o, p| o.* = t.app.camera.view().transformPoint(p);
    return out;
}

fn expectReference(t: *TestApp, want: [6]Vec3) !void {
    for (want, referenceOnScreen(t)) |a, b| try expect(cv.math.length(a - b) < 2e-3);
}

test "while locked, a diff's reference and background stay still on screen, and the frames line up" {
    var t = try lockedTest(6);
    defer t.deinit();
    try t.show(2);
    t.app.setReference();
    const first = referenceOnScreen(&t);
    for ([_]usize{ 1, 5, 0, 2, 4 }) |i| {
        try t.show(i);
        t.app.followRotationLock();
        try expectReference(&t, first);
        try expect(t.app.diff.?.result.?.rmsd < 1e-4);
        try expectOnScreen(&t, first); // turned frames are the same shape
    }
    // Neither's atoms were moved to do it.
    var file = try t.app.doc.?.source.loadFrame(TestApp.io, TestApp.gpa, 2);
    defer file.deinit(TestApp.gpa);
    try std.testing.expectEqualSlices(Vec3, file.positions, t.app.diff.?.reference.frame.?.positions);
    var current = try t.app.doc.?.source.loadFrame(TestApp.io, TestApp.gpa, 4);
    defer current.deinit(TestApp.gpa);
    try std.testing.expectEqualSlices(Vec3, current.positions, t.app.doc.?.display.real.frame.?.positions);
}

test "an edit in a diff unlocks, with the reference in place and deviations live" {
    var t = try lockedTest(3);
    defer t.deinit();
    t.app.setReference();
    try t.show(2);
    t.app.followRotationLock();
    const before = referenceOnScreen(&t);
    try t.app.startDrag(.translate, 4);
    t.app.dragMotion(0, 0, 0.1, 0);
    t.app.updateDiff();
    const df = &t.app.diff.?;
    try expectEqual(4, df.result.?.worst);
    const halfway = df.deviations.items[4];
    try expect(halfway > 0.01);
    t.app.dragMotion(0, 0, 0.1, 0);
    t.app.updateDiff();
    try std.testing.expectApproxEqAbs(2 * halfway, df.deviations.items[4], 1e-2);
    t.app.endDrag(true);
    t.app.followRotationLock();
    try expectReference(&t, before);
    for (df.deviations.items[0..4]) |dev| try expect(dev < 1e-3);

    // Unlocked, another frame keeps the placement, and nothing turns.
    const view = t.app.camera;
    const placement = df.placement;
    try t.show(1);
    t.app.followRotationLock();
    try std.testing.expectEqualDeep(view, t.app.camera);
    try std.testing.expectEqualDeep(placement, t.app.diff.?.placement);
    try expect(t.app.diff.?.result.?.rmsd > 0.1);

    // Locking refits, without moving the reference on screen.
    t.app.setLockRotation(true);
    try expect(t.app.diff.?.result.?.rmsd < 1e-4);
    try expectReference(&t, before);
}

test "resetting a diff shows both frames at their file positions" {
    var t = try lockedTest(3);
    defer t.deinit();
    t.app.setReference();
    try t.show(2);
    t.app.followRotationLock();
    const view = t.app.camera;
    t.app.resetPlacement();
    try expect(!t.app.lock_rotation);
    try std.testing.expectEqualDeep(view, t.app.camera);
    const df = &t.app.diff.?;
    try std.testing.expectEqualSlices(Vec3, df.reference.frame.?.positions, df.placed.items);
    try expect(df.result.?.rmsd > 0.1);
    // And lines up again.
    const reset = referenceOnScreen(&t);
    t.app.setLockRotation(true);
    try expect(t.app.diff.?.result.?.rmsd < 1e-4);
    try expectReference(&t, reset);
}

test "a frame with other atoms leaves a diff's placement and view as they are" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    var buf: [2][512]u8 = undefined;
    const text = try std.mem.concat(TestApp.gpa, u8, &.{ turnedFrame(&buf[0], 0), "2\n\nO 0 0 0\nO 0 0 5\n", turnedFrame(&buf[1], 0.4) });
    defer TestApp.gpa.free(text);
    try t.openText(text);
    try t.show(0);
    t.app.setReference();
    const first = referenceOnScreen(&t);
    const view = t.app.camera;
    try t.show(1);
    t.app.followRotationLock();
    try expect(t.app.diff.?.result == null);
    try std.testing.expectEqualDeep(view, t.app.camera);
    try t.show(2);
    t.app.followRotationLock();
    try expectReference(&t, first);
}

test "ending a diff that was unlocked by an edit moves nothing" {
    for ([_]bool{ false, true }) |before| {
        var t = try lockedTest(3);
        defer t.deinit();
        t.app.setLockRotation(before);
        t.app.setReference();
        try t.show(2);
        t.app.followRotationLock();
        t.setDistance(3.5);
        const view = t.app.camera;
        t.app.clearDiff();
        t.app.followRotationLock();
        try std.testing.expectEqualDeep(view, t.app.camera);
        try expectEqual(before, t.app.lock_rotation);
    }
}

test "ending a diff locks again at the frame shown then, not the next one" {
    var t = try lockedTest(3);
    defer t.deinit();
    t.app.setLockRotation(true);
    t.app.setReference();
    const before = onScreen(&t);
    t.app.clearDiff();
    try t.show(2); // arrives before the next update
    t.app.followRotationLock();
    try expectOnScreen(&t, before);
}

test "a reference that can't be set leaves the diff as it was" {
    var t = try lockedTest(3);
    defer t.deinit();
    t.app.setLockRotation(true);
    t.app.setReference();
    try t.show(2);
    t.app.followRotationLock();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(TestApp.gpa, .{ .fail_index = fail_index });
        t.app.gpa = failing.allocator();
        t.app.setReference();
        t.app.gpa = TestApp.gpa;
        if (t.app.diff.?.reference.index == 2) break;
        try expectEqual(0, t.app.diff.?.reference.index);
        try expect(t.app.lock_rotation);
        try expect(t.app.rotation_lock != null);
    }
    try expect(fail_index > 0);
    t.app.clearDiff();
    try expect(t.app.lock_rotation); // as before the first one
}

test "fitting a diff overlay includes the reference" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("3\n\nH 0 0 0\nH 3 0 0\nH 0 4 0\n" ++ "3\n\nH 50 0 0\nH 53 0 0\nH 50 4 0\n");
    try t.show(0);
    t.app.setReference();
    try t.show(1);
    t.app.resetPlacement();
    t.app.fitCamera();
    try expect(t.app.scene_radius > 25);
    t.app.diff.?.overlay = false;
    t.app.fitCamera();
    try expect(t.app.scene_radius < 10);
}

test "whatever changes what is drawn makes a new scene, and nothing else does" {
    const run = struct {
        fn run(t: *TestApp, what: usize) !bool {
            const app = &t.app;
            switch (what) {
                0 => t.select(&.{0}),
                1 => t.select(&.{1}),
                2 => app.toggleCutPair(0, 1),
                3 => app.toggleCutPair(1, 2),
                4 => app.restoreCuts(),
                5 => t.setDistance(4),
                6 => app.undo(),
                7 => app.redo(),
                8 => app.revertFrame(),
                9 => try t.pasteAtom(),
                10 => try t.deleteAtom(0),
                11 => try t.dragSome(),
                12 => app.endDrag(false),
                13 => {
                    app.revertFrame();
                    try t.show(1);
                },
                14 => app.style.shading = .flat,
                15 => app.style.theme = .dark,
                16 => app.style.show_cell = false,
                17 => app.style.atom_scale = 2,
                18 => app.bond_params.cutoff_factor = 1.25,
                19 => {
                    try t.show(0);
                    app.setReference();
                },
                20 => app.diff.?.overlay = false,
                21 => app.diff.?.overlay = true,
                22 => app.diff.?.place(.{ .rot = cv.align_.Transform.identity.rot, .from_center = @splat(0), .to_center = @splat(1) }),
                // The same frame again, but another diff.
                23 => app.setReference(),
                24 => app.clearDiff(),
                25 => {
                    app.interpolate = true;
                    app.playing = true;
                    app.interp_t = 0.3;
                    try t.waitForNext();
                },
                26 => app.interp_t = 0.4,
                27 => app.closeDocument(),
                28 => try t.open(2),
                29 => try t.show(0),
                else => return false,
            }
            return true;
        }
    }.run;
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    var what: usize = 0;
    var key = t.app.sceneKey();
    while (try run(&t, what)) : (what += 1) {
        errdefer std.debug.print("change {d}\n", .{what});
        const now = t.app.sceneKey();
        try expect(!std.meta.eql(key, now));
        // Looking, redrawing and doing nothing isn't a change.
        t.app.camera.orbit(3, 4);
        t.app.updateDiff();
        if (t.app.doc != null) t.app.updateNextFrame();
        _ = t.app.drawnPositions();
        _ = t.app.bonds();
        key = t.app.sceneKey();
        try std.testing.expectEqualDeep(now, key);
    }
}

test "what is only drawn differently doesn't make a new scene" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    t.app.setReference();
    t.app.diff.?.overlay = false;
    const key = t.app.sceneKey();
    const s = &t.app.style;
    s.background_blur = 2;
    s.background_pattern = false;
    s.backdrop = .cells;
    s.outline_px = 3;
    s.flat_pop = true;
    t.app.diff.?.place(.{ .rot = cv.align_.Transform.identity.rot, .from_center = @splat(0), .to_center = @splat(1) });
    try expect(std.meta.eql(key, t.app.sceneKey()));
}

test "a scene with a coordinate that isn't a number is built once" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("3\n\nH 0 0 0\nH nan 0 0\nH 0 4 0\n" ++ "3\n\nH 0 0 0\nH nan 0 0\nH 0 5 0\n");
    try t.show(0);
    t.app.setReference();
    try t.show(1);
    t.app.followRotationLock();
    try expect(std.meta.eql(t.app.sceneKey(), t.app.sceneKey()));
}

test "a scene drawn without bonds, for want of memory, is built again" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("2\n\nH 0 0 0\nH 0.74 0 0\n");
    try t.show(0);
    t.app.scene_key = t.app.sceneKey();
    var failing: std.testing.FailingAllocator = .init(TestApp.gpa, .{ .fail_index = 0 });
    t.app.gpa = failing.allocator();
    try expectEqual(0, t.app.bonds().len);
    t.app.gpa = TestApp.gpa;
    try expect(t.app.scene_key == null);
}

test "while locked, a blend that gets another shape is followed" {
    var t = try lockedTest(4);
    defer t.deinit();
    try t.show(1);
    t.app.setLockRotation(true);
    t.app.interpolate = true;
    t.app.playing = true;
    t.app.interp_t = 0.4;
    try t.waitForNext();
    const d = &t.app.doc.?;
    d.display.keep(TestApp.gpa, .prev, null);
    d.display.keep(TestApp.gpa, .next2, null);
    t.app.followRotationLock();
    const before = t.app.camera;
    // One atom's curve changes a lot with a neighbour on it.
    var prev = try d.source.loadFrame(TestApp.io, TestApp.gpa, 0);
    prev.positions[1] += Vec3{ 0, 1.5, 0 };
    d.display.keep(TestApp.gpa, .prev, .{ .index = 0, .atoms = prev });
    t.app.followRotationLock();
    try expect(!std.meta.eql(before, t.app.camera));
}

/// A mouse event with the left button down, or going down or up.
fn leftButton(t: *TestApp, kind: enum { move, up }, down: bool) void {
    var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    switch (kind) {
        .move => {
            ev.type = c.SDL_EVENT_MOUSE_MOTION;
            ev.motion.xrel = 20;
            ev.motion.yrel = 10;
            if (down) ev.motion.state = c.SDL_BUTTON_LMASK;
        },
        .up => {
            ev.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
            ev.button.button = c.SDL_BUTTON_LEFT;
        },
    }
    t.app.handleEvent(&ev, false, false);
}

test "after a drag is aborted, the held button doesn't turn the camera" {
    // It is let go where the app sees it, or not.
    for ([_]bool{ false, true }) |seen| {
        var t: TestApp = try .init(2);
        defer t.deinit();
        try t.show(0);
        t.app.drag_button = c.SDL_BUTTON_LEFT;
        try t.dragSome();
        t.esc();
        const view = t.app.camera;
        leftButton(&t, .move, true);
        leftButton(&t, .move, true);
        try std.testing.expectEqualDeep(view, t.app.camera);
        if (seen) leftButton(&t, .up, false) else leftButton(&t, .move, false);
        leftButton(&t, .move, true); // pressed again
        try expect(!std.meta.eql(view, t.app.camera));
    }
}

test "after a completed drag, the button turns the camera as usual" {
    var t: TestApp = try .init(2);
    defer t.deinit();
    try t.show(0);
    t.app.drag_button = c.SDL_BUTTON_LEFT;
    try t.dragSome();
    leftButton(&t, .up, false);
    try expect(t.app.drag == null);
    const view = t.app.camera;
    leftButton(&t, .move, true);
    try expect(!std.meta.eql(view, t.app.camera));
}

test "a refused Alt-drag says so and does nothing, not even turn the camera" {
    const Case = struct { sel: []const u32, button: u8, shift: bool = false };
    for ([_]Case{
        .{ .sel = &.{ 0, 2 }, .button = c.SDL_BUTTON_LEFT },
        .{ .sel = &.{ 0, 2 }, .button = c.SDL_BUTTON_MIDDLE },
        .{ .sel = &.{ 0, 2 }, .button = c.SDL_BUTTON_RIGHT },
        .{ .sel = &.{ 0, 1 }, .button = c.SDL_BUTTON_RIGHT },
        .{ .sel = &.{1}, .button = c.SDL_BUTTON_RIGHT },
        .{ .sel = &.{}, .button = c.SDL_BUTTON_RIGHT },
        // Not gestures.
        .{ .sel = &.{1}, .button = c.SDL_BUTTON_RIGHT, .shift = true },
        .{ .sel = &.{1}, .button = c.SDL_BUTTON_MIDDLE, .shift = true },
    }) |case| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.openRow(2);
        t.select(case.sel);
        t.app.messages = .{};
        t.app.playing = true;
        const at = t.app.screenProjector().toScreen(t.app.drawnPositions().?[1]).?;
        t.app.altPress(case.button, case.shift, at.x, at.y);
        try expect(t.app.drag == null);
        try expect(t.app.playing);
        try expectEqual(case.button, t.app.aborted_button.?);
        try expectEqual(.refusal, t.app.messages.last.?.kind);
    }
}

test "the looks remembered by default are the defaults, and come back when applied" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try std.testing.expectEqualDeep(cv.settings.Settings{}, t.app.looks());
    const s: cv.settings.Settings = .{ .theme = .dark, .shading = .aero, .backdrop = .cells, .snap = 0.2, .cutoff_factor = 1.3, .ui_scale = 1.25 };
    t.app.applyLooks(s);
    try std.testing.expectEqualDeep(s, t.app.looks());
    t.app.resetLooks(&.{ "snap", "cutoff_factor" });
    try expectEqual(.dark, t.app.style.theme);
    try expectEqual((Renderer.Style{}).snap, t.app.style.snap);
    try expectEqual((cv.bonds.Params{}).cutoff_factor, t.app.bond_params.cutoff_factor);
}

test "leaving asks only about unsaved edits, and cancelling keeps them" {
    for ([_]std.meta.Tag(Leaving){ .quit, .close }) |tag| {
        const to: Leaving = if (tag == .quit) .quit else .close;
        var t: TestApp = try .init(2);
        defer t.deinit();
        try t.show(0);
        t.setDistance(3);
        t.app.leave(to);
        try expect(t.app.leaving != null);
        try expect(!t.app.quit_requested);
        try expect(t.app.session.isEdited(0));
        t.esc();
        try expect(t.app.leaving == null);
        try expect(t.app.session.isEdited(0));
        // Nothing but Esc reaches the app while it asks.
        t.app.leave(to);
        var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
        ev.type = c.SDL_EVENT_KEY_DOWN;
        ev.key.key = c.SDLK_DELETE;
        t.app.handleEvent(&ev, false, false);
        try expectEqual(3, t.app.doc.?.display.real.frame.?.len());
        t.esc();
        // Undone, there is nothing to ask about.
        t.app.undo();
        t.app.leave(to);
        try expect(t.app.leaving == null);
        try expect(if (to == .quit) t.app.quit_requested else t.app.doc == null);
    }
}

test "leaving waits for a save; Esc stops the save and stays" {
    for ([_]bool{ false, true }) |edited| {
        var t: TestApp = try .init(3);
        defer t.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/out.xyz", .{&tmp.sub_path});
        try t.show(0);
        if (edited) t.setDistance(3);
        t.app.startSaving(.all, path);
        t.app.leave(.quit);
        try expect(t.app.leaving != null and !t.app.quit_requested);
        t.esc();
        try expect(t.app.saving == null);
        try expect(!t.app.quit_requested);
        // Still asking, if there is something to ask.
        try expectEqual(edited, t.app.leaving != null);
    }
}

test "Esc during a drag cancels the drag, and a save goes on" {
    var t: TestApp = try .init(3);
    defer t.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/out.xyz", .{&tmp.sub_path});
    try t.show(0);
    t.app.startSaving(.all, path);
    try t.dragSome();
    t.esc();
    try t.expectAborted();
    try expect(t.app.saving != null);
    // A second save doesn't end the first.
    const first = t.app.saving.?;
    t.app.startSaving(.{ .frame = 0 }, "other.xyz");
    try expectEqual(first, t.app.saving.?);
    t.esc();
    try expect(t.app.saving == null);
}

test "a save that fails keeps the app from leaving" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.show(0);
    t.app.startSaving(.unsaved, ".zig-cache/nothing-unsaved.xyz");
    t.app.leave(.quit);
    t.app.saveSome(1);
    try expect(t.app.leaving == null);
    try expect(!t.app.quit_requested);
    try expectEqual(.failure, t.app.messages.last.?.kind);
}

test "only looks the user changes are remembered, and a failed save is tried again" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    t.app.loadSettings(dir);
    t.app.style.theme = .dark; // as by the command line
    t.app.rememberLooks(false);
    t.app.style.snap = 0.2;
    t.app.rememberLooks(true);
    try expect(t.app.settings_changed); // a slider is held
    t.app.rememberLooks(false);
    try expect(!t.app.settings_changed);
    try expectEqual(0.2, t.app.settings.snap);
    try expectEqual(.light, t.app.settings.theme);
    var text_buf: [256]u8 = undefined;
    const text = try tmp.dir.readFile(TestApp.io, "settings", &text_buf);
    try expectEqual(t.app.settings, cv.settings.Settings.parse(text));

    TestApp.gpa.free(t.app.settings_path.?);
    t.app.settings_path = try TestApp.gpa.dupe(u8, "no/such/dir/settings");
    t.app.style.snap = 0.3;
    t.app.rememberLooks(false);
    try expect(t.app.settings_unsaved);
    try expectEqual(.failure, t.app.messages.last.?.kind);
    TestApp.gpa.free(t.app.settings_path.?);
    t.app.settings_path = try std.fs.path.join(TestApp.gpa, &.{ dir, "settings" });
    t.app.style.snap = 0.4;
    t.app.rememberLooks(false);
    try expect(!t.app.settings_unsaved);
}

test "the atoms an Alt-drag would move follow the selection and the frame" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.openText("3\n\nC 0 0 0\nC 1.5 0 0\nC 3 0 0\n");
    try t.show(0);
    t.app.hover = .{ .atom = 2 };
    try expectEqual(3, t.app.hoverGroup().len);
    t.select(&.{1});
    try std.testing.expectEqualSlices(u32, &.{2}, t.app.hoverGroup());
    t.select(&.{ 0, 1 });
    try expectEqual(0, t.app.hoverGroup().len); // refused
    t.app.clearSelection();
    t.app.toggleCutPair(1, 2);
    try expectEqual(1, t.app.hoverGroup().len);
    t.app.hover = .{ .bond = .{ 0, 1 } };
    try expectEqual(0, t.app.hoverGroup().len);
    t.app.hover = null;
    try expectEqual(0, t.app.hoverGroup().len);
}

test "discarding edits leaves; a file that can't be opened keeps them" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.show(0);
    t.setDistance(3);
    t.app.leaveToOpen("no/such/file.xyz");
    try expect(t.app.leaving != null);
    t.app.leaveNow();
    try expect(t.app.leaving == null);
    try expect(t.app.session.isEdited(0));
    t.app.leave(.close);
    t.app.leaveNow();
    try expect(t.app.doc == null);
}

test "a frame that was saved isn't asked about, and one that couldn't be is" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/out.xyz", .{&tmp.sub_path});
    try t.show(0);
    t.setDistance(3);
    t.app.saveFrame("no/such/dir/out.xyz");
    try expectEqual(.failure, t.app.messages.last.?.kind);
    try expect(t.app.session.anyUnsaved());
    t.app.saveFrame(path);
    try expectEqual(.info, t.app.messages.last.?.kind);
    try expect(!t.app.session.anyUnsaved());
    t.app.leave(.quit);
    try expect(t.app.quit_requested);
}

test "Alt-dragging a bond is refused" {
    for ([_][]const u32{ &.{}, &.{0}, &.{ 0, 1 } }) |sel| {
        for ([_]u8{ c.SDL_BUTTON_LEFT, c.SDL_BUTTON_MIDDLE, c.SDL_BUTTON_RIGHT }) |button| {
            var t: TestApp = try .init(1);
            defer t.deinit();
            try t.openText("2\n\nC 0 0 0\nC 1.5 0 0\n");
            try t.show(0);
            t.app.fitCamera();
            t.select(sel);
            t.app.messages = .{};
            const at = t.app.screenProjector().toScreen(.{ 0.75, 0, 0 }).?;
            t.app.altPress(button, false, at.x, at.y);
            try expect(t.app.drag == null);
            try expectEqual(button, t.app.aborted_button.?);
            try std.testing.expectEqualStrings("Drag an atom, not a bond", t.app.messages.last.?.text());
        }
    }
}

test "the buttons of an Alt-drag, and what moves" {
    const Case = struct { sel: []const u32, button: u8, shift: bool = false, kind: drag_mod.Kind, pivot: ?u32 = null };
    for ([_]Case{
        .{ .sel = &.{}, .button = c.SDL_BUTTON_LEFT, .kind = .translate },
        .{ .sel = &.{ 0, 1 }, .button = c.SDL_BUTTON_LEFT, .kind = .translate },
        .{ .sel = &.{ 0, 1 }, .button = c.SDL_BUTTON_MIDDLE, .kind = .rotate },
        .{ .sel = &.{0}, .button = c.SDL_BUTTON_LEFT, .kind = .translate, .pivot = 0 },
        .{ .sel = &.{0}, .button = c.SDL_BUTTON_RIGHT, .kind = .twist, .pivot = 0 },
        .{ .sel = &.{0}, .button = c.SDL_BUTTON_LEFT, .shift = true, .kind = .rotate, .pivot = 0 },
        .{ .sel = &.{1}, .button = c.SDL_BUTTON_MIDDLE, .kind = .rotate, .pivot = 1 },
    }) |case| {
        var t: TestApp = try .init(1);
        defer t.deinit();
        try t.openRow(1);
        t.select(case.sel);
        const at = t.app.screenProjector().toScreen(t.app.drawnPositions().?[1]).?;
        t.app.altPress(case.button, case.shift, at.x, at.y);
        const drag = t.app.drag orelse return error.TestUnexpectedResult;
        try expectEqual(1, drag.handle);
        try expectEqual(case.kind, drag.kind);
        try expectEqual(case.pivot, drag.pivot);
        try expectEqual(@as(usize, if (case.sel.len == 2) 2 else 1), drag.group.len);
    }
}

test "Alt-drag works in a diff overlay" {
    var t = try lockedTest(3);
    defer t.deinit();
    t.app.setReference();
    try t.show(1);
    t.app.followRotationLock();
    const at = t.app.screenProjector().toScreen(t.app.drawnPositions().?[4]).?;
    t.app.beginDrag(.translate, at.x, at.y);
    try expectEqual(4, (t.app.drag orelse return error.TestUnexpectedResult).handle);
    t.app.dragMotion(0, 0, 0.1, 0);
    try expect(!t.app.lock_rotation);
    t.app.endDrag(true);
    try expect(t.app.session.isEdited(1));
}

test "a long way round brings back the same view" {
    var t = try lockedTest(8);
    defer t.deinit();
    t.app.setLockRotation(true);
    const first = onScreen(&t);
    for (0..1000) |_| for (0..8) |i| {
        t.app.moveTo(i);
        try t.settle();
        t.app.followRotationLock();
    };
    for (first, onScreen(&t)) |a, b| try expect(cv.math.length(a - b) < 0.02);
}

test "an edit that changes nothing, a click and a selection step keep the lock" {
    var t = try lockedTest(1);
    defer t.deinit();
    t.app.setLockRotation(true);
    const d = t.distance();
    t.setDistance(d);
    t.app.deselect();
    t.app.undo();
    try t.startDrag();
    t.app.endDrag(true);
    try expect(t.app.lock_rotation);
}

test "an edit during a blend turns back to the step it plays from before unlocking" {
    var t = try lockedTest(2);
    defer t.deinit();
    t.app.setLockRotation(true);
    const first = onScreen(&t);
    t.app.interpolate = true;
    t.app.playing = true;
    t.app.interp_t = 0.7;
    try t.waitForNext();
    t.app.followRotationLock();
    t.setDistance(3.5); // moves atom 1
    try expectEqual(0, t.app.doc.?.display.real.index);
    try expect(!t.app.lock_rotation);
    const now = onScreen(&t);
    for ([_]usize{ 0, 2, 3, 4, 5 }) |i| try expect(cv.math.length(first[i] - now[i]) < 2e-3);
}

test "locking by hand refits from the current frame" {
    var t = try lockedTest(3);
    defer t.deinit();
    t.app.setLockRotation(true);
    t.setDistance(3.5);
    try t.show(1);
    t.app.setLockRotation(true);
    const here = onScreen(&t);
    try t.show(2);
    t.app.followRotationLock();
    try expectOnScreen(&t, here);
}

test "a frame with other atoms restarts the lock there" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    var buf: [3][512]u8 = undefined;
    var other = std.mem.zeroes([512]u8);
    const last = turnedFrame(&buf[2], 0.9);
    @memcpy(other[0..last.len], last);
    const text = try std.mem.concat(TestApp.gpa, u8, &.{ turnedFrame(&buf[0], 0), "2\n\nO 0 0 0\nO 0 0 5\n", turnedFrame(&buf[1], 0.4), other[0..last.len] });
    defer TestApp.gpa.free(text);
    try t.openText(text);
    try t.show(0);
    t.app.setLockRotation(true);
    const view = t.app.camera;
    try t.show(1);
    t.app.followRotationLock();
    try std.testing.expectEqualDeep(view, t.app.camera);
    try t.show(2); // again
    t.app.followRotationLock();
    try std.testing.expectEqualDeep(view, t.app.camera);
    const here = onScreen(&t);
    try t.show(3);
    t.app.followRotationLock();
    try expectOnScreen(&t, here);
}

test "a drag grabs the atom that was drawn under the cursor" {
    var t: TestApp = try .init(1);
    defer t.deinit();
    try t.playBlend(0.7);
    const p = t.app.drawnPositions().?[1];
    try expect(p[1] > 1 and p[1] < 1.9);
    const at = t.app.screenProjector().toScreen(p).?;
    t.app.beginDrag(.translate, at.x, at.y);
    try expectEqual(0, t.app.doc.?.display.real.index);
    const drag = t.app.drag orelse return error.TestUnexpectedResult;
    try expectEqual(1, drag.handle);
}
