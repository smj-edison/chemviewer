//! A data file being read in the background. What has been read can be used meanwhile,
//! between `lock` and `unlock`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Table = @import("table.zig").Table;
const Pyramid = @import("pyramid.zig").Pyramid;
const Alignment = @import("align.zig").Alignment;

pub const State = union(enum) { reading, done, failed: anyerror };

pub const Attached = struct {
    io: Io,
    gpa: Allocator,
    path: []u8,
    file: Io.File,
    size: u64,
    worker: ?Io.Future(Io.Cancelable!void) = null,

    mutex: Io.Mutex = .init,
    /// Guarded by `mutex`.
    table: Table,
    state: State = .reading,
    /// Bytes behind us.
    read: u64 = 0,

    /// Used only by the UI, one per column.
    pyramids: []Pyramid,
    /// The user's, or confirmed (null = as proposed).
    alignment: ?Alignment = null,

    const chunk = 64 * 1024;

    /// Fails at once if the file isn't a table.
    pub fn start(io: Io, gpa: Allocator, path: []const u8) !*Attached {
        const file = try Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        var table = try readHeader(io, gpa, file);
        errdefer table.deinit();
        const size = try file.length(io);
        const own_path = try gpa.dupe(u8, path);
        errdefer gpa.free(own_path);
        const pyramids = try gpa.alloc(Pyramid, table.columns.len);
        errdefer gpa.free(pyramids);
        @memset(pyramids, .{});
        const a = try gpa.create(Attached);
        errdefer gpa.destroy(a);
        a.* = .{ .io = io, .gpa = gpa, .path = own_path, .file = file, .size = size, .table = table, .pyramids = pyramids };
        a.worker = try io.concurrent(run, .{a});
        return a;
    }

    pub fn deinit(a: *Attached) void {
        if (a.worker) |*w| w.cancel(a.io) catch {};
        a.file.close(a.io);
        for (a.pyramids) |*p| p.deinit(a.gpa);
        a.gpa.free(a.pyramids);
        a.table.deinit();
        a.gpa.free(a.path);
        a.gpa.destroy(a);
    }

    pub fn lock(a: *Attached) void {
        a.mutex.lockUncancelable(a.io);
    }

    pub fn unlock(a: *Attached) void {
        a.mutex.unlock(a.io);
    }

    /// Call locked. While it is being read, from how many rows there will be.
    pub fn aligned(a: *const Attached, frames: usize) Alignment {
        if (a.alignment) |x| return x;
        return .propose(a.expectedRows(), frames);
    }

    /// Call locked.
    fn expectedRows(a: *const Attached) usize {
        if (a.state != .reading or a.read == 0 or a.read >= a.size) return a.table.rows;
        const part = @as(f64, @floatFromInt(a.size)) / @as(f64, @floatFromInt(a.read));
        return @intFromFloat(@as(f64, @floatFromInt(a.table.rows)) * part);
    }

    /// Call locked. The pyramid of a column, up to date.
    pub fn pyramid(a: *Attached, column: usize) *const Pyramid {
        const p = &a.pyramids[column];
        p.update(a.gpa, a.table.columns[column].values.items, a.table.rewinds);
        return p;
    }

    fn readHeader(io: Io, gpa: Allocator, file: Io.File) !Table {
        const buf = try gpa.alloc(u8, chunk);
        defer gpa.free(buf);
        const got = try file.readPositionalAll(io, buf, 0);
        return Table.init(gpa, headerOf(buf[0..got]) orelse return error.NotATable);
    }

    fn run(a: *Attached) Io.Cancelable!void {
        a.readAll() catch |e| {
            if (e == error.Canceled) return error.Canceled;
            a.lock();
            defer a.unlock();
            a.state = .{ .failed = e };
            return;
        };
        a.lock();
        defer a.unlock();
        a.state = if (a.table.rows == 0 and a.table.skipped > 0) .{ .failed = error.NotATable } else .done;
    }

    fn readAll(a: *Attached) !void {
        const io = a.io;
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(a.gpa);
        var pos: u64 = 0;
        var in_header = true;
        while (true) {
            try pending.ensureUnusedCapacity(a.gpa, chunk);
            const room = pending.unusedCapacitySlice()[0..chunk];
            const got = try a.file.readPositionalAll(io, room, pos);
            pending.items.len += got;
            pos += got;
            // Whole lines only; the rest waits for more.
            const end = if (std.mem.findScalarLast(u8, pending.items, '\n')) |i| i + 1 else 0;
            {
                a.lock();
                defer a.unlock();
                var lines = std.mem.splitScalar(u8, pending.items[0..end -| 1], '\n');
                if (end > 0) while (lines.next()) |line| {
                    if (in_header) {
                        in_header = isBlank(line);
                        continue;
                    }
                    try a.table.add(line);
                };
                a.read = pos;
                if (got < chunk and !in_header) a.table.addUnfinished(pending.items[end..]);
            }
            if (got < chunk) return;
            pending.replaceRangeAssumeCapacity(0, end, "");
            try io.checkCancel();
        }
    }
};

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r\n").len == 0;
}

/// The first line that isn't blank of a text file that starts like this.
fn headerOf(head: []const u8) ?[]const u8 {
    if (std.mem.findScalar(u8, head, 0) != null) return null;
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |line| {
        // One that isn't over yet isn't known.
        if (lines.peek() == null and head.len >= Attached.chunk) return null;
        if (!isBlank(line)) return line;
    }
    return null;
}

/// How sure it is that a file which starts like this is data.
pub const Likeness = enum { no, maybe, sure };

pub fn likeness(gpa: Allocator, head: []const u8) Likeness {
    const header = headerOf(head) orelse return .no;
    var t = Table.init(gpa, header) catch return .no;
    defer t.deinit();
    if (t.kind != .generic) return .sure;
    // Words are a header only if numbers follow.
    const rest = head[@intFromPtr(header.ptr) - @intFromPtr(head.ptr) + header.len ..];
    var lines = std.mem.splitScalar(u8, rest, '\n');
    while (lines.next()) |line| {
        t.add(line) catch return .no;
        if (t.rows > 0) return .maybe;
        if (t.skipped > 0) return .no;
    }
    return .no;
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const TestFile = struct {
    tmp: testing.TmpDir,
    buf: [128]u8 = undefined,

    fn init(text: []const u8) !TestFile {
        const tmp = testing.tmpDir(.{});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "data", .data = text });
        return .{ .tmp = tmp };
    }

    fn path(f: *TestFile) ![]const u8 {
        return std.fmt.bufPrint(&f.buf, ".zig-cache/tmp/{s}/data", .{&f.tmp.sub_path});
    }
};

fn settle(a: *Attached) !State {
    for (0..5000) |_| {
        a.lock();
        const state = a.state;
        a.unlock();
        if (state != .reading) return state;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestTimeout;
}

test "a long file is read whole, whatever its chunks cut through" {
    const gpa = testing.allocator;
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try text.writer.writeAll("\r\n#! FIELDS time cv metad.bias\r\n");
    const n = 30_000;
    for (0..n) |i| try text.writer.print(" {d}.000000 {d} 0.5\r\n", .{ i * 50, i });
    var f: TestFile = try .init(text.written());
    defer f.tmp.cleanup();
    const a = try Attached.start(testing.io, gpa, try f.path());
    defer a.deinit();
    try expectEqual(.done, try settle(a));
    try expectEqual(n, a.table.rows);
    try expectEqual(0, a.table.skipped);
    for (a.table.column("cv").?.values.items, 0..) |v, i| try expectEqual(@as(f64, @floatFromInt(i)), v);
    try expectEqual(@as(f64, n - 1), a.pyramid(1).range(a.table.columns[1].values.items, 0, n).hi);
    try expectEqual(10, a.aligned(10 * n).frames_per_row);
}

test "a file can be dropped while it is being read" {
    const gpa = testing.allocator;
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try text.writer.writeAll("a b\n");
    for (0..100_000) |i| try text.writer.print("{d} 1\n", .{i});
    var f: TestFile = try .init(text.written());
    defer f.tmp.cleanup();
    for (0..5) |_| (try Attached.start(testing.io, gpa, try f.path())).deinit();
}

test "files that aren't tables fail at once, or when no row is one" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "", "1 2 3\n4 5 6\n", "a b\x00\n" }) |text| {
        var f: TestFile = try .init(text);
        defer f.tmp.cleanup();
        try testing.expectError(error.NotATable, Attached.start(testing.io, gpa, try f.path()));
    }
    try testing.expectError(error.FileNotFound, Attached.start(testing.io, gpa, "no/such/file"));
    var prose: TestFile = try .init("Some words here.\nAnd some more.\n");
    defer prose.tmp.cleanup();
    const a = try Attached.start(testing.io, gpa, try prose.path());
    defer a.deinit();
    try expectEqual(State{ .failed = error.NotATable }, try settle(a));
}

test "other fields halfway end it, and what was read stays" {
    var f: TestFile = try .init("#! FIELDS time x\n0 1\n#! FIELDS time y\n1 2\n");
    defer f.tmp.cleanup();
    const a = try Attached.start(testing.io, testing.allocator, try f.path());
    defer a.deinit();
    try expectEqual(State{ .failed = error.FieldsChanged }, try settle(a));
    try expectEqual(1, a.table.rows);
}

test "only a header, and a header without a line break" {
    for ([_][]const u8{ "a b\n", "a b" }) |text| {
        var f: TestFile = try .init(text);
        defer f.tmp.cleanup();
        const a = try Attached.start(testing.io, testing.allocator, try f.path());
        defer a.deinit();
        try expectEqual(.done, try settle(a));
        try expectEqual(0, a.table.rows);
        try expectEqual(0, a.table.skipped);
    }
}

test "what looks like data" {
    const gpa = testing.allocator;
    try expectEqual(.sure, likeness(gpa, "#! FIELDS time x\n"));
    try expectEqual(.sure, likeness(gpa, "Time[ps] Etot[eV]\n"));
    try expectEqual(.maybe, likeness(gpa, "step,energy\n1,2\n"));
    try expectEqual(.no, likeness(gpa, "3\nwater\nO 0 0 0\n"));
    try expectEqual(.no, likeness(gpa, "#!/usr/bin/env python\n# coding: utf-8\nimport os\n"));
    try expectEqual(.no, likeness(gpa, "just words\n"));
    try expectEqual(.no, likeness(gpa, "- of Ulm\x00\x00"));
}

test "running out of memory while starting leaves nothing behind" {
    var f: TestFile = try .init("a b\n1 2\n");
    defer f.tmp.cleanup();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        const a = Attached.start(testing.io, failing.allocator(), try f.path()) catch |e| {
            try expectEqual(error.OutOfMemory, e);
            continue;
        };
        const state = try settle(a);
        a.deinit();
        if (state == .done) break;
        try expectEqual(State{ .failed = error.OutOfMemory }, state);
    }
    try expect(fail_index > 3);
}
