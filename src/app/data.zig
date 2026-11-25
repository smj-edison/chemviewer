//! Data files attached to the open trajectory: attaching them, the panel with their
//! columns, and which columns have a lane on the timeline (lanes.zig draws them).
const std = @import("std");
const Io = std.Io;
const c = @import("c");
const cv = @import("chemviewer");
const ui = @import("ui.zig");
const App = @import("App.zig");
const Attached = cv.attached.Attached;
const Scale = cv.envelope.Scale;

pub const Lane = struct {
    source: *Attached,
    column: usize,
    /// Dots instead of steps.
    points: bool,
    /// Scale the user fitted (null = that of the whole series).
    fitted: ?Scale = null,
};

pub const State = struct {
    sources: std.ArrayList(*Attached) = .empty,
    /// From the top, under the energy.
    lanes: std.ArrayList(Lane) = .empty,
    show_energy: bool = true,
    show_panel: bool = false,
    /// Recognised files of a folder, to choose from. Owned paths.
    offered: std.ArrayList([]u8) = .empty,

    /// Paths from a file dialog, each ended by a 0.
    dialog_paths: [64 * 1024]u8 = undefined,
    dialog_len: usize = 0,
    dialog_ready: std.atomic.Value(bool) = .init(false),
    dialog_open: std.atomic.Value(bool) = .init(false),

    /// Back to nothing attached.
    pub fn clear(s: *State, gpa: std.mem.Allocator) void {
        for (s.sources.items) |a| a.deinit();
        s.sources.clearRetainingCapacity();
        s.lanes.clearRetainingCapacity();
        s.clearOffered(gpa);
        s.show_energy = true;
    }

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.clear(gpa);
        s.sources.deinit(gpa);
        s.lanes.deinit(gpa);
        s.offered.deinit(gpa);
    }

    fn clearOffered(s: *State, gpa: std.mem.Allocator) void {
        for (s.offered.items) |p| gpa.free(p);
        s.offered.clearRetainingCapacity();
    }

    /// Don't offer this file any more.
    fn withdraw(s: *State, app: *App, path: []const u8) void {
        var i = s.offered.items.len;
        while (i > 0) {
            i -= 1;
            const offer = s.offered.items[i];
            // `path` may be the offer itself.
            if (offer.ptr == path.ptr or !sameFile(app, offer, path)) continue;
            app.gpa.free(s.offered.orderedRemove(i));
        }
    }

    pub fn reading(s: *State) bool {
        for (s.sources.items) |a| {
            a.lock();
            defer a.unlock();
            if (a.state == .reading) return true;
        }
        return false;
    }

    pub fn laneOf(s: *const State, source: *const Attached, column: usize) ?usize {
        for (s.lanes.items, 0..) |l, i| if (l.source == source and l.column == column) return i;
        return null;
    }

    /// Give a column a lane, or take it away.
    pub fn toggleLane(s: *State, gpa: std.mem.Allocator, source: *Attached, column: usize) !void {
        if (s.laneOf(source, column)) |i| {
            _ = s.lanes.orderedRemove(i);
        } else {
            const points = std.ascii.startsWithIgnoreCase(std.fs.path.basename(source.path), "HILLS");
            try s.lanes.append(gpa, .{ .source = source, .column = column, .points = points });
        }
    }

    /// A lane for the first column of that name. False if there is none.
    pub fn addLane(s: *State, gpa: std.mem.Allocator, name: []const u8) !bool {
        for (s.sources.items) |a| for (a.table.columns, 0..) |col, k| {
            if (!std.mem.eql(u8, col.name, name)) continue;
            if (s.laneOf(a, k) == null) try s.toggleLane(gpa, a, k);
            return true;
        };
        return false;
    }

    pub fn detach(s: *State, i: usize) void {
        const a = s.sources.orderedRemove(i);
        var k = s.lanes.items.len;
        while (k > 0) {
            k -= 1;
            if (s.lanes.items[k].source == a) _ = s.lanes.orderedRemove(k);
        }
        a.deinit();
    }
};

// ------------------------------------------------------------ attaching

pub fn attach(app: *App, path: []const u8) void {
    const name = std.fs.path.basename(path);
    if (app.doc == null) return app.refuse("Open a trajectory first, then its data", .{});
    const s = &app.data;
    for (s.sources.items) |a| if (sameFile(app, a.path, path)) {
        s.withdraw(app, path);
        return app.refuse("{s} is attached already", .{name});
    };
    const a = Attached.start(app.io, app.gpa, path) catch |e| return switch (e) {
        error.NotATable => app.refuse("{s} isn't a table with named columns", .{name}),
        else => app.fail("Could not attach {s}: {t}", .{ name, e }),
    };
    s.sources.append(app.gpa, a) catch |e| {
        a.deinit();
        return app.fail("Could not attach {s}: {t}", .{ name, e });
    };
    s.withdraw(app, path);
    s.show_panel = true;
    app.inform("Attached {s}", .{name});
}

/// However the paths are written.
fn sameFile(app: *App, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const sa = Io.Dir.cwd().statFile(app.io, a, .{}) catch return false;
    const sb = Io.Dir.cwd().statFile(app.io, b, .{}) catch return false;
    return sa.inode == sb.inode and sa.size == sb.size and std.mem.eql(u8, std.fs.path.basename(a), std.fs.path.basename(b));
}

/// A file or folder was dropped on the window.
pub fn drop(app: *App, path: []const u8) void {
    if (offerFolder(app, path)) return;
    if (isData(app, path)) attach(app, path) else app.leaveToOpen(path);
}

/// Whether the file is data rather than a structure.
fn isData(app: *App, path: []const u8) bool {
    const buf = app.gpa.alloc(u8, 16 * 1024) catch return false;
    defer app.gpa.free(buf);
    const head = headOf(app, path, buf) orelse return false;
    return switch (cv.attached.likeness(app.gpa, head)) {
        .sure => true,
        .maybe => cv.source.detect(path, head) == null,
        .no => false,
    };
}

fn headOf(app: *App, path: []const u8, buf: []u8) ?[]u8 {
    const file = Io.Dir.cwd().openFile(app.io, path, .{}) catch return null;
    defer file.close(app.io);
    const got = file.readPositionalAll(app.io, buf, 0) catch return null;
    return buf[0..got];
}

/// Offer the data files in a folder. False if it isn't one.
fn offerFolder(app: *App, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(app.io, path, .{ .iterate = true }) catch return false;
    defer dir.close(app.io);
    if (app.doc == null) {
        app.refuse("Open a trajectory first, then its data", .{});
        return true;
    }
    const s = &app.data;
    s.clearOffered(app.gpa);
    findData(app, dir, path) catch |e| app.fail("Could not look through {s}: {t}", .{ std.fs.path.basename(path), e });
    if (s.offered.items.len == 0) {
        app.refuse("No data files in {s}", .{std.fs.path.basename(path)});
    } else s.show_panel = true;
    return true;
}

fn findData(app: *App, dir: Io.Dir, path: []const u8) !void {
    const s = &app.data;
    var it = dir.iterate();
    // Not a whole disk, if someone drops that.
    var left: usize = 500;
    while (try it.next(app.io)) |entry| {
        if (entry.kind == .directory) continue;
        left -= 1;
        if (left == 0) break;
        const full = try std.fs.path.join(app.gpa, &.{ path, entry.name });
        errdefer app.gpa.free(full);
        const attached = for (s.sources.items) |a| {
            if (sameFile(app, a.path, full)) break true;
        } else false;
        if (attached or !isData(app, full)) {
            app.gpa.free(full);
            continue;
        }
        try s.offered.append(app.gpa, full);
    }
    std.mem.sort([]u8, s.offered.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

pub fn fileDialog(app: *App) void {
    if (app.data.dialog_open.swap(true, .acq_rel)) return;
    c.SDL_ShowOpenFileDialog(dialogCallback, app, app.window, null, 0, null, true);
}

pub fn folderDialog(app: *App) void {
    if (app.data.dialog_open.swap(true, .acq_rel)) return;
    c.SDL_ShowOpenFolderDialog(dialogCallback, app, app.window, null, false);
}

fn dialogCallback(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) callconv(.c) void {
    _ = filter;
    const app: *App = @ptrCast(@alignCast(userdata));
    const s = &app.data;
    s.dialog_len = 0;
    if (filelist != null) {
        var i: usize = 0;
        while (filelist[i] != null) : (i += 1) {
            const p = std.mem.span(filelist[i]);
            if (s.dialog_len + p.len + 1 > s.dialog_paths.len) break;
            @memcpy(s.dialog_paths[s.dialog_len..][0..p.len], p);
            s.dialog_paths[s.dialog_len + p.len] = 0;
            s.dialog_len += p.len + 1;
        }
    }
    if (s.dialog_len > 0) s.dialog_ready.store(true, .release) else s.dialog_open.store(false, .release);
}

/// What a dialog answered. Call once per UI frame.
pub fn update(app: *App) void {
    const s = &app.data;
    if (!s.dialog_ready.load(.acquire)) return;
    var it = std.mem.tokenizeScalar(u8, s.dialog_paths[0..s.dialog_len], 0);
    while (it.next()) |path| if (!offerFolder(app, path)) attach(app, path);
    s.dialog_ready.store(false, .release);
    s.dialog_open.store(false, .release);
}

// ------------------------------------------------------------ panel

pub fn panel(app: *App, timeline_h: f32) void {
    const s = &app.data;
    const vp = c.igGetMainViewport();
    const fs = c.igGetFontSize();
    const cond = app.layoutCond();
    const h = fs * 24;
    c.igSetNextWindowPos(ui.v2(vp.*.Pos.x + vp.*.Size.x - fs * 28 - 8, vp.*.Pos.y + vp.*.Size.y - timeline_h - 8), cond, ui.v2(0, 1));
    c.igSetNextWindowSize(ui.v2(fs * 28, @min(h, vp.*.Size.y - timeline_h - 4 * fs)), cond);
    defer c.igEnd();
    if (!c.igBegin("Data", &s.show_panel, 0)) return;
    if (app.doc == null) return ui.textDisabled("Open a trajectory first, then its data.", .{});
    if (c.igButton("Attach files...", ui.v2(0, 0))) fileDialog(app);
    c.igSameLine(0, -1);
    if (c.igButton("Look in a folder...", ui.v2(0, 0))) folderDialog(app);

    if (s.offered.items.len > 0) offers(app);
    c.igSeparator();
    _ = c.igCheckbox("Energy (trajectory)", &s.show_energy);

    var remove: ?usize = null;
    for (s.sources.items, 0..) |a, i| {
        c.igPushID_Int(@intCast(i));
        defer c.igPopID();
        if (sourceTree(app, a)) remove = i;
    }
    if (remove) |i| s.detach(i);
}

fn offers(app: *App) void {
    const s = &app.data;
    c.igSeparator();
    ui.text("Found:", .{});
    var chosen: ?usize = null;
    for (s.offered.items, 0..) |path, i| {
        c.igPushID_Int(@intCast(i));
        defer c.igPopID();
        if (c.igSmallButton("Attach")) chosen = i;
        c.igSameLine(0, -1);
        ui.text("{s}", .{std.fs.path.basename(path)});
    }
    if (c.igSmallButton("Attach all")) {
        // Taken out first: attaching withdraws offers.
        while (s.offered.items.len > 0) {
            const path = s.offered.orderedRemove(0);
            defer app.gpa.free(path);
            attach(app, path);
        }
        return;
    }
    c.igSameLine(0, -1);
    if (c.igSmallButton("Dismiss")) return s.clearOffered(app.gpa);
    if (chosen) |i| {
        const path = s.offered.orderedRemove(i);
        defer app.gpa.free(path);
        attach(app, path);
    }
}

/// True to remove it.
fn sourceTree(app: *App, a: *Attached) bool {
    a.lock();
    defer a.unlock();
    var buf: [256]u8 = undefined;
    const label = ui.printZ(&buf, "{s}###source", .{std.fs.path.basename(a.path)}) catch return false;
    const open = c.igTreeNodeEx_Str(label.ptr, c.ImGuiTreeNodeFlags_DefaultOpen | c.ImGuiTreeNodeFlags_Framed | c.ImGuiTreeNodeFlags_AllowOverlap);
    // At the right end of the header.
    const button_w = c.igCalcTextSize("Remove", null, false, -1).x + 2 * c.igGetStyle().*.FramePadding.x;
    c.igSameLine(c.igGetWindowWidth() - button_w - c.igGetStyle().*.WindowPadding.x - c.igGetStyle().*.ScrollbarSize, 0);
    const remove = c.igSmallButton("Remove");
    if (!open) return remove;
    defer c.igTreePop();
    const t = &a.table;
    switch (a.state) {
        .reading => ui.textDisabled("{s}, reading: {d} %", .{ t.kind.label(), if (a.size > 0) a.read * 100 / a.size else 0 }),
        .done => ui.textDisabled("{s}, {d} rows", .{ t.kind.label(), t.rows }),
        .failed => |e| ui.textWrapped("{s}, {d} rows, then: {t}", .{ t.kind.label(), t.rows, e }),
    }
    if (t.skipped > 0) ui.textWrapped("{d} line{s} skipped: not rows, or cut short", .{ t.skipped, if (t.skipped == 1) "" else "s" });
    if (t.rewinds > 0) ui.textWrapped("Time went back {d} time{s}: later rows were kept", .{ t.rewinds, if (t.rewinds == 1) "" else "s" });
    const frames = app.doc.?.frameCount();
    const al = a.aligned(frames);
    var words: [64]u8 = undefined;
    ui.textWrapped("{s}{s}", .{ al.evidence(&words), if (al.confirmed) "" else " (unconfirmed)" });
    const after = al.rowsAfter(t.rows, frames);
    if (after > 0 and a.state != .reading) ui.textDisabled("{d} row{s} after the last frame", .{ after, if (after == 1) "" else "s" });

    for (t.columns, 0..) |col, k| if (col.group() == null) columnBox(app, a, k, col.name);
    // Groups, each where its first column is.
    for (t.columns, 0..) |col, k| {
        const g = col.group() orelse continue;
        const first = for (t.columns[0..k]) |other| {
            if (other.group()) |o| if (std.mem.eql(u8, o, g)) break false;
        } else true;
        if (!first) continue;
        const group_label = ui.printZ(&buf, "{s}", .{g}) catch continue;
        if (!c.igTreeNode_Str(group_label.ptr)) continue;
        defer c.igTreePop();
        for (t.columns[k..], k..) |member, m| {
            const mg = member.group() orelse continue;
            if (std.mem.eql(u8, mg, g)) columnBox(app, a, m, member.name[g.len + 1 ..]);
        }
    }
    return remove;
}

/// Call with the source locked.
fn columnBox(app: *App, a: *Attached, k: usize, name: []const u8) void {
    c.igPushID_Int(@intCast(k));
    defer c.igPopID();
    const s = &app.data;
    var buf: [256]u8 = undefined;
    const label = (if (a.table.columns[k].unit) |u| ui.printZ(&buf, "{s} ({s})", .{ name, u }) else ui.printZ(&buf, "{s}", .{name})) catch "?";
    var on = s.laneOf(a, k) != null;
    if (c.igCheckbox(label.ptr, &on)) s.toggleLane(app.gpa, a, k) catch |e| app.fail("Could not show {s}: {t}", .{ name, e });
    if (s.laneOf(a, k)) |i| {
        c.igSameLine(0, c.igGetFontSize());
        _ = c.igCheckbox("points", &s.lanes.items[i].points);
    }
}
