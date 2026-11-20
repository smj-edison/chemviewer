//! ORCA input (.inp) and output (.out) readers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");
const structure = @import("../core/structure.zig");
const elements = @import("../core/elements.zig");
const Frame = structure.Frame;

pub const Error = error{ InvalidOrcaInput, UnsupportedInternalCoords, NoGeometry, OutOfMemory };

pub const Input = union(enum) {
    /// Geometry given inline with `* xyz charge mult`.
    frame: Frame,
    /// `* xyzfile charge mult path`: the caller must load `path` (relative to
    /// the input file's directory). The slice points into the input buffer.
    xyzfile: []const u8,
};

pub fn parseInput(gpa: Allocator, buf: []const u8) Error!Input {
    var lines = text.Lines.init(buf);
    while (lines.next()) |raw| {
        const l = stripComment(raw);
        const t = std.mem.trim(u8, l, " \t");
        if (t.len == 0 or t[0] != '*') continue;
        var it = text.tokens(t[1..]);
        const kind = it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(kind, "xyzfile")) {
            _ = it.next(); // charge
            _ = it.next(); // multiplicity
            return .{ .xyzfile = it.next() orelse return error.InvalidOrcaInput };
        }
        if (std.ascii.eqlIgnoreCase(kind, "int") or std.ascii.eqlIgnoreCase(kind, "gzmt") or
            std.ascii.eqlIgnoreCase(kind, "intfile") or std.ascii.eqlIgnoreCase(kind, "gzmtfile"))
            return error.UnsupportedInternalCoords;
        if (!std.ascii.eqlIgnoreCase(kind, "xyz")) continue;

        var b: structure.FrameBuilder = .{};
        defer b.deinit(gpa);
        while (lines.next()) |row_raw| {
            const row = std.mem.trim(u8, stripComment(row_raw), " \t");
            if (row.len == 0) continue;
            if (row[0] == '*') break;
            var rt = text.tokens(row);
            const label = rt.next().?;
            const p = text.parseVec3(&rt) catch return error.InvalidOrcaInput;
            try b.append(gpa, elements.parseLabel(label) orelse 0, p);
        }
        if (b.len() == 0) return error.NoGeometry;
        return .{ .frame = try b.finish(gpa) };
    }
    return error.NoGeometry;
}

fn stripComment(l: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, l, '#')) |i| l[0..i] else l;
}

/// Every "CARTESIAN COORDINATES (ANGSTROEM)" block, each paired with the
/// following "FINAL SINGLE POINT ENERGY".
pub fn parseOutput(gpa: Allocator, buf: []const u8) Error![]Frame {
    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |*f| f.deinit(gpa);
        frames.deinit(gpa);
    }
    var b: structure.FrameBuilder = .{};
    defer b.deinit(gpa);

    var lines = text.Lines.init(buf);
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t");
        if (std.mem.eql(u8, t, "CARTESIAN COORDINATES (ANGSTROEM)")) {
            _ = lines.next(); // dashes
            b.clear();
            while (lines.next()) |row| {
                if (text.isBlank(row)) break;
                var it = text.tokens(row);
                const label = it.next().?;
                const p = text.parseVec3(&it) catch break;
                try b.append(gpa, elements.parseLabel(label) orelse 0, p);
            }
            if (b.len() > 0) try frames.append(gpa, try b.finish(gpa));
        } else if (std.mem.startsWith(u8, t, "FINAL SINGLE POINT ENERGY")) {
            if (frames.items.len == 0) continue;
            var it = text.tokens(t["FINAL SINGLE POINT ENERGY".len..]);
            if (it.next()) |v| frames.items[frames.items.len - 1].energy = text.parseFloat(v) catch null;
        }
    }
    if (frames.items.len == 0) return error.NoGeometry;
    return frames.toOwnedSlice(gpa);
}

test "orca inline input" {
    const gpa = std.testing.allocator;
    const src =
        \\! B3LYP def2-SVP Opt  # comment
        \\%pal nprocs 4 end
        \\* xyz 0 1
        \\  O   0.0 0.0 0.1173
        \\  H   0.0 0.7572 -0.4692   # hydrogen
        \\  H:  0.0 -0.7572 -0.4692
        \\*
    ;
    var in = try parseInput(gpa, src);
    defer in.frame.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 8, 1, 1 }, in.frame.numbers);
}

test "orca xyzfile input" {
    const in = try parseInput(std.testing.allocator, "! HF\n*xyzfile 0 1 geom.xyz\n");
    try std.testing.expectEqualStrings("geom.xyz", in.xyzfile);
}

test "orca output" {
    const gpa = std.testing.allocator;
    const src =
        \\---------------------------------
        \\CARTESIAN COORDINATES (ANGSTROEM)
        \\---------------------------------
        \\  O      0.000000    0.000000    0.117300
        \\  H      0.000000    0.757200   -0.469200
        \\
        \\----------------------------
        \\CARTESIAN COORDINATES (A.U.)
        \\----------------------------
        \\FINAL SINGLE POINT ENERGY       -76.326662519
        \\CARTESIAN COORDINATES (ANGSTROEM)
        \\---------------------------------
        \\  O      0.000000    0.000000    0.120000
        \\  H      0.000000    0.760000   -0.470000
        \\
        \\FINAL SINGLE POINT ENERGY       -76.327000000
    ;
    const frames = try parseOutput(gpa, src);
    defer {
        for (frames) |*f| f.deinit(gpa);
        gpa.free(frames);
    }
    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectApproxEqAbs(@as(f64, -76.326662519), frames[0].energy.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.76), frames[1].positions[1][1], 1e-6);
}
