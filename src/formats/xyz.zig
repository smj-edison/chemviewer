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

test "orca trajectory comment" {
    const m = parseComment("Coordinates from ORCA-job input E -76.329871");
    try std.testing.expectApproxEqAbs(@as(f64, -76.329871), m.energy.?, 1e-9);
}
