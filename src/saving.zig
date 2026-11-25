//! Saving frames, with their edits, as one XYZ file. Frame by frame, so that a
//! long trajectory doesn't hold up the UI. The file appears, or replaces the one
//! that was there, only once all of it is written.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Frame = @import("core/structure.zig").Frame;
const EditSession = @import("edit.zig").EditSession;
const Source = @import("source.zig").Source;
const xyz = @import("formats/xyz.zig");

pub const What = union(enum) {
    frame: usize,
    /// The frames with unsaved edits.
    unsaved,
    /// The whole trajectory.
    all,
};

pub const Saving = struct {
    gpa: Allocator,
    io: Io,
    source: *const Source,
    session: *EditSession,
    path: []u8,
    atomic: Io.File.Atomic,
    buf: [64 * 1024]u8,
    writer: Io.File.Writer,
    /// Which frames (null = all of them).
    list: ?[]usize,
    /// How many of them are behind us, out of `total`.
    next: usize = 0,
    total: usize,
    /// Frames that couldn't be read, and so aren't in the file.
    skipped: usize = 0,
    /// Edited frames as they were written.
    written: std.ArrayList(Written) = .empty,

    const Written = struct { index: usize, hash: u64 };

    /// Until `deinit`, the source and session stay where they are.
    pub fn start(gpa: Allocator, io: Io, source: *const Source, session: *EditSession, what: What, path: []const u8) !*Saving {
        const s = try gpa.create(Saving);
        errdefer gpa.destroy(s);
        const own_path = try gpa.dupe(u8, path);
        errdefer gpa.free(own_path);
        const list: ?[]usize = switch (what) {
            .frame => |i| try gpa.dupe(usize, &.{i}),
            .unsaved => try session.unsaved(gpa),
            .all => null,
        };
        errdefer if (list) |l| gpa.free(l);
        const atomic = try Io.Dir.cwd().createFileAtomic(io, own_path, .{ .replace = true });
        s.* = .{
            .gpa = gpa,
            .io = io,
            .source = source,
            .session = session,
            .path = own_path,
            .atomic = atomic,
            .buf = undefined,
            .writer = undefined,
            .list = list,
            .total = if (list) |l| l.len else source.frameCount(),
        };
        s.writer = s.atomic.file.writer(io, &s.buf);
        return s;
    }

    /// Without having finished, nothing is left of the file.
    pub fn deinit(s: *Saving) void {
        s.atomic.deinit(s.io);
        s.written.deinit(s.gpa);
        if (s.list) |l| s.gpa.free(l);
        s.gpa.free(s.path);
        s.gpa.destroy(s);
    }

    /// Write one more frame. True once the file is complete and in place.
    pub fn step(s: *Saving) !bool {
        if (s.next < s.total) {
            const index = if (s.list) |l| l[s.next] else s.next;
            try s.writeFrame(index);
            s.next += 1;
        }
        if (s.next < s.total) return false;
        if (s.skipped == s.total) return error.NothingToSave;
        try s.writer.interface.flush();
        try s.atomic.replace(s.io);
        for (s.written.items) |w| s.session.markSaved(w.index, w.hash);
        return true;
    }

    fn writeFrame(s: *Saving, index: usize) !void {
        if (s.session.current(index)) |f| {
            if (s.session.isEdited(index)) try s.written.append(s.gpa, .{ .index = index, .hash = EditSession.contentHash(f) });
            return xyz.write(&s.writer.interface, f);
        }
        var f = s.source.loadFrame(s.io, s.gpa, index) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                s.skipped += 1;
                return;
            },
        };
        defer f.deinit(s.gpa);
        try xyz.write(&s.writer.interface, f);
    }
};

const testing = std.testing;

const TestSaving = struct {
    tmp: testing.TmpDir,
    source: Source,
    session: EditSession,
    path: []u8,

    fn init() !TestSaving {
        const frames = try xyz.parseAll(testing.allocator, "1\na\nH 0 0 0\n1\nb\nH 1 0 0\n1\nc\nH 2 0 0\n");
        const tmp = testing.tmpDir(.{});
        return .{
            .tmp = tmp,
            .source = .{ .memory = frames },
            .session = .init(testing.allocator),
            .path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/out.xyz", .{&tmp.sub_path}),
        };
    }

    fn deinit(t: *TestSaving) void {
        t.session.deinit();
        t.source.deinit(testing.io, testing.allocator);
        testing.allocator.free(t.path);
        t.tmp.cleanup();
    }

    fn edit(t: *TestSaving, index: usize, x: f32) !void {
        var tx = try t.session.begin(index, t.source.memory[index]);
        defer tx.deinit();
        tx.atoms.positions[0][0] = x;
        try testing.expect(try tx.commit());
    }

    fn start(t: *TestSaving, what: What) !*Saving {
        return Saving.start(testing.allocator, testing.io, &t.source, &t.session, what, t.path);
    }

    fn save(t: *TestSaving, what: What) !void {
        const s = try t.start(what);
        defer s.deinit();
        while (!try s.step()) {}
    }

    /// The file has frames with these x.
    fn expectSaved(t: *TestSaving, want: []const f32) !void {
        const text = try Io.Dir.cwd().readFileAlloc(testing.io, t.path, testing.allocator, .unlimited);
        defer testing.allocator.free(text);
        const frames = try xyz.parseAll(testing.allocator, text);
        defer {
            for (frames) |*f| f.deinit(testing.allocator);
            testing.allocator.free(frames);
        }
        try testing.expectEqual(want.len, frames.len);
        for (want, frames) |x, f| try testing.expectEqual(x, f.positions[0][0]);
    }

    fn expectUnsaved(t: *TestSaving, want: []const usize) !void {
        const list = try t.session.unsaved(testing.allocator);
        defer testing.allocator.free(list);
        try testing.expectEqualSlices(usize, want, list);
    }
};

test "saving one frame, the unsaved ones, or all" {
    var t: TestSaving = try .init();
    defer t.deinit();
    try t.edit(2, 7);
    try t.edit(0, 5);
    try t.expectUnsaved(&.{ 0, 2 });
    try t.save(.{ .frame = 1 });
    try t.expectSaved(&.{1});
    try t.expectUnsaved(&.{ 0, 2 });
    try t.save(.{ .frame = 2 });
    try t.expectSaved(&.{7});
    try t.expectUnsaved(&.{0});
    try t.edit(2, 8);
    try t.expectUnsaved(&.{ 0, 2 });
    try t.save(.unsaved);
    try t.expectSaved(&.{ 5, 8 });
    try t.expectUnsaved(&.{});
    try t.edit(1, 9);
    try t.save(.all);
    try t.expectSaved(&.{ 5, 9, 8 });
    try t.expectUnsaved(&.{});
}

test "undoing back to what was saved is saved, and beyond it isn't an edit" {
    var t: TestSaving = try .init();
    defer t.deinit();
    var p: @import("picks.zig").Picks = .{};
    try t.edit(0, 5);
    try t.save(.unsaved);
    try t.edit(0, 6);
    try t.expectUnsaved(&.{0});
    _ = try t.session.undo(&p);
    try t.expectUnsaved(&.{});
    _ = try t.session.undo(&p);
    try t.expectUnsaved(&.{});
}

test "a save that isn't finished leaves the old file, and the edits unsaved" {
    var t: TestSaving = try .init();
    defer t.deinit();
    try t.save(.all);
    try t.edit(0, 5);
    const s = try t.start(.all);
    try testing.expect(!try s.step());
    s.deinit();
    try t.expectSaved(&.{ 0, 1, 2 });
    try t.expectUnsaved(&.{0});
    const path = t.path;
    t.path = try testing.allocator.dupe(u8, "no/such/dir/out.xyz");
    defer {
        testing.allocator.free(t.path);
        t.path = path;
    }
    try testing.expectError(error.FileNotFound, t.start(.all));
    try t.expectUnsaved(&.{0});
}

test "frames that can't be read are left out, unless there are no others" {
    var t: TestSaving = try .init();
    defer t.deinit();
    var dir_buf: [128]u8 = undefined;
    const from = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}/in.xyz", .{&t.tmp.sub_path});
    // The middle one has a word for a coordinate.
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = from, .data = "1\na\nH 0 0 0\n1\nb\nH x 0 0\n1\nc\nH 2 0 0\n" });
    const file = try Io.Dir.cwd().openFile(testing.io, from, .{});
    t.source.deinit(testing.io, testing.allocator);
    t.source = .{ .memory = &.{} };
    t.source = .{ .xyz = try xyz.Indexed.open(testing.io, testing.allocator, file) };
    const s = try t.start(.all);
    defer s.deinit();
    while (!try s.step()) {}
    try testing.expectEqual(1, s.skipped);
    try t.expectSaved(&.{ 0, 2 });
    // The file that is there stays.
    try testing.expectError(error.NothingToSave, t.save(.{ .frame = 1 }));
    try t.expectSaved(&.{ 0, 2 });
}

test "nothing unsaved is nothing to save" {
    var t: TestSaving = try .init();
    defer t.deinit();
    try testing.expectError(error.NothingToSave, t.save(.unsaved));
}

test "running out of memory leaves the old file, and the edits unsaved" {
    var t: TestSaving = try .init();
    defer t.deinit();
    try t.save(.all);
    try t.edit(0, 5);
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        const s = Saving.start(failing.allocator(), testing.io, &t.source, &t.session, .all, t.path) catch |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            continue;
        };
        defer s.deinit();
        const failed = while (true) {
            const done = s.step() catch break true;
            if (done) break false;
        };
        if (!failed) break;
        try t.expectSaved(&.{ 0, 1, 2 });
        try t.expectUnsaved(&.{0});
    }
    try testing.expect(fail_index > 0);
    try t.expectSaved(&.{ 5, 1, 2 });
}

test "an edit made while saving is still unsaved" {
    var t: TestSaving = try .init();
    defer t.deinit();
    try t.edit(0, 5);
    const s = try t.start(.all);
    defer s.deinit();
    try testing.expect(!try s.step());
    try t.edit(0, 6);
    while (!try s.step()) {}
    try t.expectSaved(&.{ 5, 1, 2 });
    try t.expectUnsaved(&.{0});
}
