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
/// printed after it. IRC jobs are put in reaction-coordinate order (see
/// `Irc`): reverse endpoint, TS, forward endpoint.
pub fn parseOutput(gpa: Allocator, buf: []const u8) Error![]Frame {
    const has_input = std.mem.indexOf(u8, buf, "Input orientation:") != null or
        std.mem.indexOf(u8, buf, "Z-Matrix orientation:") != null;

    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |*f| f.deinit(gpa);
        frames.deinit(gpa);
    }
    var irc: Irc = .{};
    defer irc.points.deinit(gpa);
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
        } else if (std.mem.startsWith(u8, t, "Point Number:")) {
            try irc.point(gpa, t, frames.items.len);
        } else if (std.mem.startsWith(u8, t, "Calculation of REVERSE path")) {
            irc.reverse = true;
        } else if (std.mem.startsWith(u8, t, "Entering Link 1 ")) {
            try irc.finishJob(gpa, &frames);
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
    try irc.finishJob(gpa, &frames);
    if (frames.items.len == 0) return error.NoGeometry;
    return frames.toOwnedSlice(gpa);
}

/// Reorders the frames of an IRC job. Gaussian prints the TS, then the forward
/// path, then starts again from the TS for the reverse path; the convention
/// (and Gaussian's own summary table) is reverse endpoint, TS, forward endpoint.
/// Each geometry that became a point on the path is followed by "Point Number:".
const Irc = struct {
    const Point = struct {
        frame: usize,
        path: i32,
        /// Signed position along the path: 0 = TS, negative = reverse.
        pos: i32,

        fn lessThan(_: void, a: Point, b: Point) bool {
            return a.pos < b.pos;
        }
    };

    /// First frame of the current job.
    job_start: usize = 0,
    /// A reverse path was calculated. It is path 2, or path 1 if it's the only one.
    reverse: bool = false,
    points: std.ArrayList(Point) = .empty,

    /// "Point Number:  31          Path Number:   2" after `n_frames` frames.
    fn point(irc: *Irc, gpa: Allocator, line: []const u8, n_frames: usize) !void {
        if (n_frames <= irc.job_start) return;
        var it = text.tokens(line);
        var nums: [2]i32 = undefined;
        var k: usize = 0;
        while (it.next()) |tok| {
            const v = std.fmt.parseInt(i32, tok, 10) catch continue;
            if (k < 2) nums[k] = v;
            k += 1;
        }
        if (k != 2) return;
        const frame = n_frames - 1;
        // One point per geometry.
        if (irc.points.items.len > 0 and irc.points.items[irc.points.items.len - 1].frame == frame) return;
        try irc.points.append(gpa, .{ .frame = frame, .path = nums[1], .pos = nums[0] });
    }

    /// Sort the current job's points and drop its other geometries
    /// (unconverged corrector steps, and the endpoint printed again at the end).
    fn finishJob(irc: *Irc, gpa: Allocator, frames: *std.ArrayList(Frame)) !void {
        const pts = irc.points.items;
        if (pts.len > 0) {
            var two_paths = false;
            for (pts) |p| two_paths = two_paths or p.path == 2;
            for (pts) |*p| {
                if (p.path == 2 or (irc.reverse and !two_paths)) p.pos = -p.pos;
            }
            std.mem.sort(Point, pts, {}, Point.lessThan);

            const job = frames.items[irc.job_start..];
            const old = try gpa.dupe(Frame, job);
            defer gpa.free(old);
            const keep = try gpa.alloc(bool, old.len);
            defer gpa.free(keep);
            @memset(keep, false);
            for (pts, 0..) |p, i| {
                job[i] = old[p.frame - irc.job_start];
                keep[p.frame - irc.job_start] = true;
            }
            for (old, keep) |*f, k| if (!k) f.deinit(gpa);
            frames.shrinkRetainingCapacity(irc.job_start + pts.len);
        }
        irc.points.clearRetainingCapacity();
        irc.reverse = false;
        irc.job_start = frames.items.len;
    }
};

test "gaussian IRC is in reaction-coordinate order" {
    const gpa = std.testing.allocator;
    const Step = struct { x: []const u8, after: []const u8 };
    const ts: Step = .{ .x = "0.0", .after = " SCF Done:  E(R) =  -1.0 A.U.\n Point Number:   0          Path Number:   1\n" };
    const f1: Step = .{ .x = "1.0", .after = " SCF Done:  E(R) =  -1.1 A.U.\n Point Number:   1          Path Number:   1\n" };
    const f2: Step = .{ .x = "2.0", .after = " Point Number:   2          Path Number:   1\n Calculation of FORWARD path complete.\n" };
    const r1: Step = .{ .x = "-1.0", .after = " Point Number:   1          Path Number:   2\n" };
    const r2: Step = .{ .x = "-2.0", .after = " Point Number:   2          Path Number:   2\n Calculation of REVERSE path complete.\n" };
    const b1: Step = .{ .x = "-1.0", .after = " Point Number:   1          Path Number:   1\n Calculation of REVERSE path complete.\n" };
    const extra: Step = .{ .x = "9.0", .after = "" };
    const opt: Step = .{ .x = "7.0", .after = " Entering Link 1 = l1.exe PID= 1.\n" };
    const Case = struct { steps: []const Step, xs: []const f32 };
    const cases = [_]Case{
        .{ .steps = &.{ ts, f1, f2, r1, r2, extra }, .xs = &.{ -2, -1, 0, 1, 2 } },
        // Still running, with a rejected corrector step before f1.
        .{ .steps = &.{ ts, extra, f1, f2, r1, extra }, .xs = &.{ -1, 0, 1, 2 } },
        .{ .steps = &.{ ts, f1, f2 }, .xs = &.{ 0, 1, 2 } },
        // Reverse direction only: printed as path 1.
        .{ .steps = &.{ ts, b1 }, .xs = &.{ -1, 0 } },
        // Another job before the IRC keeps its frames.
        .{ .steps = &.{ extra, opt, ts, f1, r1 }, .xs = &.{ 9, 7, -1, 0, 1 } },
    };
    for (cases) |cs| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        for (cs.steps) |s| {
            try src.appendSlice(gpa, " Input orientation:\n ---\n h\n h\n ---\n 1 8 0 ");
            try src.appendSlice(gpa, s.x);
            try src.appendSlice(gpa, " 0.0 0.0\n -----\n");
            try src.appendSlice(gpa, s.after);
        }
        const frames = try parseOutput(gpa, src.items);
        defer {
            for (frames) |*f| f.deinit(gpa);
            gpa.free(frames);
        }
        try std.testing.expectEqual(cs.xs.len, frames.len);
        for (cs.xs, frames) |x, f| {
            try std.testing.expectEqual(x, f.positions[0][0]);
            if (x == 1) try std.testing.expectEqual(@as(?f64, -1.1), f.energy);
        }
    }
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
