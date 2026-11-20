//! Gaussian input (.gjf/.com) and output (.log/.out) readers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");
const structure = @import("../core/structure.zig");
const elements = @import("../core/elements.zig");
const Frame = structure.Frame;

pub const Error = error{ InvalidGaussianInput, UnsupportedZMatrix, NoGeometry, OutOfMemory };

/// Parse the Cartesian geometry of the first job in a Gaussian input file.
pub fn parseInput(gpa: Allocator, buf: []const u8) Error!Frame {
    var lines = text.Lines.init(buf);
    // Link0 (%...) and blank lines, then the route section starting with '#'.
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t");
        if (t.len > 0 and t[0] == '#') break;
    } else return error.InvalidGaussianInput;
    // Rest of the route section, up to a blank line.
    while (lines.next()) |l| if (text.isBlank(l)) break;
    // Title section, up to a blank line.
    var title: []const u8 = "";
    while (lines.next()) |l| {
        if (text.isBlank(l)) break;
        if (title.len == 0) title = std.mem.trim(u8, l, " \t");
    }
    // Charge / multiplicity (possibly several pairs for ONIOM/fragments).
    _ = lines.next() orelse return error.InvalidGaussianInput;

    var b: structure.FrameBuilder = .{};
    defer b.deinit(gpa);
    while (lines.next()) |l| {
        if (text.isBlank(l)) break;
        var toks: [8][]const u8 = undefined;
        var nt: usize = 0;
        var it = text.tokens(l);
        while (it.next()) |t| {
            if (nt == toks.len) break;
            toks[nt] = t;
            nt += 1;
        }
        // "C x y z" or "C flag x y z" (flag = freeze code, an integer).
        const xyz: []const []const u8 = switch (nt) {
            4 => toks[1..4],
            5 => if (isInt(toks[1])) toks[2..5] else return error.UnsupportedZMatrix,
            else => if (nt > 5 and isInt(toks[1])) toks[2..5] else return error.UnsupportedZMatrix,
        };
        var p: [3]f32 = undefined;
        for (xyz, 0..) |s, k| p[k] = @floatCast(text.parseFloat(s) catch return error.UnsupportedZMatrix);
        try b.append(gpa, elements.parseLabel(toks[0]) orelse 0, p);
    }
    if (b.len() == 0) return error.NoGeometry;
    var f = try b.finish(gpa);
    if (title.len > 0) f.comment = gpa.dupe(u8, title) catch |e| {
        f.deinit(gpa);
        return e;
    };
    return f;
}

fn isInt(s: []const u8) bool {
    _ = std.fmt.parseInt(i32, s, 10) catch return false;
    return true;
}

/// Parse every geometry in a Gaussian output file. Prefers "Input orientation"
/// (a consistent frame across steps) and falls back to "Standard orientation".
/// Each frame gets the most recent "SCF Done" (or external "Recovered energy")
/// printed after it.
pub fn parseOutput(gpa: Allocator, buf: []const u8) Error![]Frame {
    const has_input = std.mem.indexOf(u8, buf, "Input orientation:") != null or
        std.mem.indexOf(u8, buf, "Z-Matrix orientation:") != null;

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
        const is_geom = if (has_input)
            std.mem.eql(u8, t, "Input orientation:") or std.mem.eql(u8, t, "Z-Matrix orientation:")
        else
            std.mem.eql(u8, t, "Standard orientation:");
        if (is_geom) {
            // dashes, two header lines, dashes
            for (0..4) |_| _ = lines.next();
            b.clear();
            while (lines.next()) |row| {
                if (std.mem.indexOf(u8, row, "-----") != null) break;
                var toks: [8][]const u8 = undefined;
                var nt: usize = 0;
                var it = text.tokens(row);
                while (it.next()) |tok| {
                    if (nt == toks.len) break;
                    toks[nt] = tok;
                    nt += 1;
                }
                if (nt < 5) break;
                const z = std.fmt.parseInt(u8, toks[1], 10) catch 0;
                var p: [3]f32 = undefined;
                for (0..3) |k| p[k] = @floatCast(text.parseFloat(toks[nt - 3 + k]) catch 0);
                try b.append(gpa, if (z <= elements.max_z) z else 0, p);
            }
            if (b.len() > 0) try frames.append(gpa, try b.finish(gpa));
        } else if (std.mem.startsWith(u8, t, "SCF Done:") or std.mem.startsWith(u8, t, "Recovered energy=")) {
            // "Recovered energy=" is printed by external-program jobs (e.g. xTB).
            if (frames.items.len == 0) continue;
            if (std.mem.indexOfScalar(u8, t, '=')) |eq| {
                var it = text.tokens(t[eq + 1 ..]);
                if (it.next()) |v| {
                    frames.items[frames.items.len - 1].energy = text.parseFloat(v) catch null;
                }
            }
        }
    }
    if (frames.items.len == 0) return error.NoGeometry;
    return frames.toOwnedSlice(gpa);
}

test "gaussian input" {
    const gpa = std.testing.allocator;
    const src =
        \\%chk=water.chk
        \\%mem=1GB
        \\#p B3LYP/6-31G(d)
        \\ opt freq
        \\
        \\Water opt
        \\
        \\0 1
        \\O    0.000000   0.000000   0.117300
        \\H-H_  0   0.000000   0.757200  -0.469200
        \\H(Iso=2)    0.000000  -0.757200  -0.469200
        \\
        \\
    ;
    var f = try parseInput(gpa, src);
    defer f.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), f.len());
    try std.testing.expectEqualSlices(u8, &.{ 8, 1, 1 }, f.numbers);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7572), f.positions[1][1], 1e-6);
    try std.testing.expectEqualStrings("Water opt", f.comment);
}

test "gaussian z-matrix is rejected" {
    const src = "# hf\n\nt\n\n0 1\nO\nH 1 0.96\n\n";
    try std.testing.expectError(error.UnsupportedZMatrix, parseInput(std.testing.allocator, src));
}

test "gaussian output" {
    const gpa = std.testing.allocator;
    const src =
        \\                          Input orientation:
        \\ ---------------------------------------------------------------------
        \\ Center     Atomic      Atomic             Coordinates (Angstroms)
        \\ Number     Number       Type             X           Y           Z
        \\ ---------------------------------------------------------------------
        \\      1          8           0        0.000000    0.000000    0.117300
        \\      2          1           0        0.000000    0.757200   -0.469200
        \\ ---------------------------------------------------------------------
        \\                         Standard orientation:
        \\ ---------------------------------------------------------------------
        \\ Center     Atomic      Atomic             Coordinates (Angstroms)
        \\ Number     Number       Type             X           Y           Z
        \\ ---------------------------------------------------------------------
        \\      1          8           0        9.000000    0.000000    0.117300
        \\      2          1           0        9.000000    0.757200   -0.469200
        \\ ---------------------------------------------------------------------
        \\ SCF Done:  E(RB3LYP) =  -76.4089533     A.U. after   10 cycles
        \\                          Input orientation:
        \\ ---------------------------------------------------------------------
        \\ Center     Atomic      Atomic             Coordinates (Angstroms)
        \\ Number     Number       Type             X           Y           Z
        \\ ---------------------------------------------------------------------
        \\      1          8           0        0.000000    0.000000    0.120000
        \\      2          1           0        0.000000    0.760000   -0.470000
        \\ ---------------------------------------------------------------------
        \\ SCF Done:  E(RB3LYP) =  -76.4090000     A.U. after    6 cycles
    ;
    const frames = try parseOutput(gpa, src);
    defer {
        for (frames) |*f| f.deinit(gpa);
        gpa.free(frames);
    }
    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0), frames[0].positions[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -76.4089533), frames[0].energy.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -76.409), frames[1].energy.?, 1e-9);
}
