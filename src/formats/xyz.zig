//! XYZ and extended-XYZ reader.
//!
//! Small files are parsed whole (`parseAll`). Large files are opened as an
//! `Indexed` source: one streaming pass records each frame's byte offset, and
//! frames are parsed on demand with positional reads.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const text = @import("text.zig");
const structure = @import("../core/structure.zig");
const elements = @import("../core/elements.zig");
const Frame = structure.Frame;
const Vec3 = @import("../core/math.zig").Vec3;

pub const Error = error{ InvalidXyz, OutOfMemory };

pub const Parsed = struct { frame: Frame, end: usize };

/// Parse one frame starting at the beginning of `buf`. Returns null at EOF
/// (only whitespace remaining).
pub fn parseFrame(gpa: Allocator, buf: []const u8) Error!?Parsed {
    var lines = text.Lines.init(buf);
    const count_line = while (lines.next()) |l| {
        if (!text.isBlank(l)) break l;
    } else return null;
    var count_tok = text.tokens(count_line);
    const n = std.fmt.parseInt(usize, count_tok.next().?, 10) catch return error.InvalidXyz;
    const comment = lines.next() orelse return error.InvalidXyz;

    var frame = try Frame.init(gpa, n);
    errdefer frame.deinit(gpa);
    for (0..n) |i| {
        const line = lines.next() orelse return error.InvalidXyz;
        var it = text.tokens(line);
        const label = it.next() orelse return error.InvalidXyz;
        frame.numbers[i] = elements.parseLabel(label) orelse 0;
        frame.positions[i] = text.parseVec3(&it) catch return error.InvalidXyz;
    }
    const meta = parseComment(comment);
    frame.cell = meta.cell;
    frame.energy = meta.energy;
    const trimmed = std.mem.trim(u8, comment, " \t");
    if (trimmed.len > 0) frame.comment = try gpa.dupe(u8, trimmed);
    return .{ .frame = frame, .end = lines.pos };
}

pub fn parseAll(gpa: Allocator, buf: []const u8) Error![]Frame {
    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |*f| f.deinit(gpa);
        frames.deinit(gpa);
    }
    var pos: usize = 0;
    while (try parseFrame(gpa, buf[pos..])) |p| {
        try frames.append(gpa, p.frame);
        pos += p.end;
    }
    return frames.toOwnedSlice(gpa);
}

/// Lenient parse for pasted text: proper (multi-frame) XYZ if possible,
/// otherwise every line that looks like `Label x y z [...]` as one frame
/// (e.g. a coordinate block copied out of a Gaussian/ORCA input or a paper).
pub fn parseLoose(gpa: Allocator, buf: []const u8) Error![]Frame {
    if (parseAll(gpa, buf)) |frames| {
        if (frames.len > 0) return frames;
        gpa.free(frames);
    } else |e| switch (e) {
        error.OutOfMemory => return e,
        error.InvalidXyz => {},
    }
    var b: structure.FrameBuilder = .{};
    defer b.deinit(gpa);
    var lines = text.Lines.init(buf);
    while (lines.next()) |l| {
        var it = text.tokens(l);
        const label = it.next() orelse continue;
        const z = elements.parseLabel(label) orelse continue;
        // Gaussian freeze flags ("C 0 x y z") have 4 numbers after the label.
        var nums: [4]f64 = undefined;
        var n: usize = 0;
        while (it.next()) |tok| {
            if (n == nums.len) break;
            nums[n] = text.parseFloat(tok) catch break;
            n += 1;
        }
        const xyz = switch (n) {
            3 => nums[0..3],
            4 => nums[1..4],
            else => continue,
        };
        try b.append(gpa, z, .{ @floatCast(xyz[0]), @floatCast(xyz[1]), @floatCast(xyz[2]) });
    }
    if (b.len() == 0) return error.InvalidXyz;
    const frames = try gpa.alloc(Frame, 1);
    errdefer gpa.free(frames);
    frames[0] = try b.finish(gpa);
    return frames;
}

/// Write one frame as XYZ (extended-XYZ Lattice/energy keys when present).
pub fn write(w: *Io.Writer, frame: Frame) Io.Writer.Error!void {
    try w.print("{d}\n", .{frame.len()});
    if (frame.cell) |cell| {
        try w.print("Lattice=\"", .{});
        for (cell, 0..) |v, i| {
            if (i > 0) try w.writeByte(' ');
            try w.print("{d:.8} {d:.8} {d:.8}", .{ v[0], v[1], v[2] });
        }
        try w.print("\" Properties=species:S:1:pos:R:3 ", .{});
    }
    if (frame.energy) |e| try w.print("energy={d} ", .{e});
    // Keep the comment on one line.
    for (frame.comment) |ch| try w.writeByte(if (ch == '\n' or ch == '\r') ' ' else ch);
    try w.writeByte('\n');
    for (frame.positions, frame.numbers) |p, z| {
        try w.print("{s:<2} {d:>15.8} {d:>15.8} {d:>15.8}\n", .{ elements.symbol(z), p[0], p[1], p[2] });
    }
}

pub const CommentMeta = struct { cell: ?[3]Vec3 = null, energy: ?f64 = null };

/// Extract metadata from the comment line. Understands extended-XYZ
/// `Lattice="..."` and `energy=...`, and ORCA trajectory comments
/// (`... E -76.123`).
pub fn parseComment(comment: []const u8) CommentMeta {
    var meta: CommentMeta = .{};
    if (findKey(comment, "lattice=")) |rest| {
        const inner = if (rest.len > 0 and rest[0] == '"')
            rest[1..(std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse rest.len)]
        else
            rest;
        var it = text.tokens(inner);
        var cell: [3]Vec3 = undefined;
        var ok = true;
        for (0..3) |r| {
            cell[r] = text.parseVec3(&it) catch {
                ok = false;
                break;
            };
        }
        if (ok) meta.cell = cell;
    }
    if (findKey(comment, "energy=")) |rest| {
        var it = text.tokens(rest);
        if (it.next()) |tok| meta.energy = text.parseFloat(std.mem.trim(u8, tok, "\"")) catch null;
    } else {
        // ORCA: "Coordinates from ORCA-job foo E -76.329"
        var it = text.tokens(comment);
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "E")) {
                if (it.next()) |v| meta.energy = text.parseFloat(v) catch null;
                break;
            }
        }
    }
    return meta;
}

fn findKey(s: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len <= s.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(s[i..][0..key.len], key)) {
            if (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t') return s[i + key.len ..];
        }
    }
    return null;
}

/// Random-access XYZ reader. Keeps the file open and only an offset table in memory.
pub const Indexed = struct {
    file: Io.File,
    /// Frame `i` occupies bytes `offsets[i]..offsets[i+1]`.
    offsets: []u64,

    pub fn open(io: Io, gpa: Allocator, file: Io.File) !Indexed {
        var offsets: std.ArrayList(u64) = .empty;
        errdefer offsets.deinit(gpa);

        var buf: [1 << 16]u8 = undefined;
        var fr = file.reader(io, &buf);
        const r = &fr.interface;
        var pos: u64 = 0;
        scan: while (true) {
            // Count line (skip blank lines between frames).
            const frame_start = pos;
            const count_line = while (true) {
                const line = (r.takeDelimiter('\n') catch |e| switch (e) {
                    error.StreamTooLong => return error.InvalidXyz,
                    else => return fr.err orelse e,
                }) orelse break :scan;
                pos += line.len + 1;
                if (!text.isBlank(line)) break line;
            };
            var it = text.tokens(count_line);
            const n = std.fmt.parseInt(u64, it.next().?, 10) catch return error.InvalidXyz;
            // Comment + n atom lines.
            for (0..n + 1) |i| {
                const skipped = r.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    // Last line of the file without a trailing newline.
                    error.EndOfStream => if (i == n) {
                        try offsets.append(gpa, frame_start);
                        break :scan;
                    } else return error.InvalidXyz,
                    else => return fr.err orelse e,
                };
                pos += skipped;
            }
            try offsets.append(gpa, frame_start);
        }
        try offsets.append(gpa, @max(pos, try file.length(io)));
        return .{ .file = file, .offsets = try offsets.toOwnedSlice(gpa) };
    }

    pub fn deinit(x: *Indexed, io: Io, gpa: Allocator) void {
        gpa.free(x.offsets);
        x.file.close(io);
    }

    pub fn frameCount(x: *const Indexed) usize {
        return x.offsets.len - 1;
    }

    /// Energy from the comment line only. Thread-safe.
    pub fn loadEnergy(x: *const Indexed, io: Io, gpa: Allocator, index: usize) !?f64 {
        _ = gpa;
        var buf: [4096]u8 = undefined;
        const start = x.offsets[index];
        const len: usize = @intCast(@min(buf.len, x.offsets[index + 1] - start));
        const got = try x.file.readPositionalAll(io, buf[0..len], start);
        var lines = text.Lines.init(buf[0..got]);
        while (lines.next()) |l| if (!text.isBlank(l)) break; // count line
        return parseComment(lines.next() orelse return null).energy;
    }

    /// Thread-safe: uses positional reads only.
    pub fn loadFrame(x: *const Indexed, io: Io, gpa: Allocator, index: usize) !Frame {
        const start = x.offsets[index];
        const len: usize = @intCast(x.offsets[index + 1] - start);
        const buf = try gpa.alloc(u8, len);
        defer gpa.free(buf);
        const got = try x.file.readPositionalAll(io, buf, start);
        const parsed = try parseFrame(gpa, buf[0..got]) orelse return error.InvalidXyz;
        return parsed.frame;
    }
};

test "parse multi-frame xyz" {
    const gpa = std.testing.allocator;
    const src =
        \\3
        \\water energy=-76.4
        \\O 0 0 0
        \\H 0.76 0.58 0
        \\H -0.76 0.58 0
        \\
        \\2
        \\Lattice="10 0 0 0 10 0 0 0 10" Properties=species:S:1:pos:R:3
        \\6 0 0 0
        \\8 1.2 0 0
        \\
    ;
    const frames = try parseAll(gpa, src);
    defer {
        for (frames) |*f| f.deinit(gpa);
        gpa.free(frames);
    }
    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqual(@as(u8, 8), frames[0].numbers[0]);
    try std.testing.expectApproxEqAbs(@as(f64, -76.4), frames[0].energy.?, 1e-9);
    try std.testing.expectEqual(@as(u8, 6), frames[1].numbers[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 10), frames[1].cell.?[2][2], 1e-6);
}

test "write then read back" {
    const gpa = std.testing.allocator;
    var f = try Frame.init(gpa, 2);
    defer f.deinit(gpa);
    f.positions[0] = .{ 0, 0, 0.1173 };
    f.positions[1] = .{ -1.25, 0.7572, -0.4692 };
    f.numbers[0] = 8;
    f.numbers[1] = 17;
    f.cell = .{ .{ 10, 0, 0 }, .{ 0, 10, 0 }, .{ 0, 0, 10 } };
    f.energy = -76.5;
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try write(&w, f);
    const frames = try parseAll(gpa, w.buffered());
    defer {
        for (frames) |*g| g.deinit(gpa);
        gpa.free(frames);
    }
    try std.testing.expectEqualSlices(u8, f.numbers, frames[0].numbers);
    try std.testing.expectApproxEqAbs(@as(f32, -1.25), frames[0].positions[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -76.5), frames[0].energy.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 10), frames[0].cell.?[1][1], 1e-6);
}

test "loose parse of bare coordinates" {
    const gpa = std.testing.allocator;
    const src =
        \\ C                 -0.49367557    0.04662441   -0.28549818
        \\ some prose line that should be ignored
        \\ H   0   0.5 0.6 0.7
        \\Au 2.36 -0.27 -0.0076
        \\
    ;
    const frames = try parseLoose(gpa, src);
    defer {
        for (frames) |*f| f.deinit(gpa);
        gpa.free(frames);
    }
    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualSlices(u8, &.{ 6, 1, 79 }, frames[0].numbers);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), frames[0].positions[1][1], 1e-6);
    try std.testing.expectError(error.InvalidXyz, parseLoose(gpa, "hello world\n"));
}

test "orca trajectory comment" {
    const m = parseComment("Coordinates from ORCA-job input E -76.329871");
    try std.testing.expectApproxEqAbs(@as(f64, -76.329871), m.energy.?, 1e-9);
}
