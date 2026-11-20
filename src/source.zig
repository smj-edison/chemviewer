//! Uniform "N frames, give me frame i" access over every supported format.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Frame = @import("core/structure.zig").Frame;
const xyz = @import("formats/xyz.zig");
const gaussian = @import("formats/gaussian.zig");
const orca = @import("formats/orca.zig");
const traj = @import("formats/traj.zig");

pub const Format = enum {
    xyz,
    gaussian_input,
    gaussian_output,
    orca_input,
    orca_output,
    ase_traj,

    pub fn label(f: Format) []const u8 {
        return switch (f) {
            .xyz => "XYZ",
            .gaussian_input => "Gaussian input",
            .gaussian_output => "Gaussian output",
            .orca_input => "ORCA input",
            .orca_output => "ORCA output",
            .ase_traj => "ASE trajectory",
        };
    }
};

/// XYZ files smaller than this are parsed fully (so energies from comment
/// lines are known up front); larger ones are indexed and streamed.
pub const xyz_stream_threshold: u64 = 32 << 20;

pub const Source = union(enum) {
    /// Fully parsed frames, owned.
    memory: []Frame,
    xyz: xyz.Indexed,
    traj: traj.Traj,

    pub fn frameCount(s: *const Source) usize {
        return switch (s.*) {
            .memory => |m| m.len,
            inline .xyz, .traj => |*x| x.frameCount(),
        };
    }

    /// Thread-safe. The caller owns the returned frame.
    pub fn loadFrame(s: *const Source, io: Io, gpa: Allocator, index: usize) !Frame {
        return switch (s.*) {
            .memory => |m| m[index].clone(gpa),
            inline .xyz, .traj => |*x| x.loadFrame(io, gpa, index),
        };
    }

    /// Just the energy of frame `index`, cheaper than a full load. Thread-safe.
    pub fn loadEnergy(s: *const Source, io: Io, gpa: Allocator, index: usize) !?f64 {
        return switch (s.*) {
            .memory => |m| m[index].energy,
            inline .xyz, .traj => |*x| x.loadEnergy(io, gpa, index),
        };
    }

    /// True if frames come from disk on demand (so loading may be slow).
    pub fn isStreamed(s: *const Source) bool {
        return s.* != .memory;
    }

    pub fn deinit(s: *Source, io: Io, gpa: Allocator) void {
        switch (s.*) {
            .memory => |m| {
                for (m) |*f| f.deinit(gpa);
                gpa.free(m);
            },
            inline .xyz, .traj => |*x| x.deinit(io, gpa),
        }
        s.* = undefined;
    }
};

pub const Opened = struct {
    source: Source,
    format: Format,
};

pub fn detect(path: []const u8, head: []const u8) ?Format {
    const ext = std.fs.path.extension(path);
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(ext, ".xyz") or eq(ext, ".extxyz")) return .xyz;
    if (eq(ext, ".traj")) return .ase_traj;
    if (eq(ext, ".gjf") or eq(ext, ".com") or eq(ext, ".gau")) return .gaussian_input;
    if (eq(ext, ".inp")) return .orca_input;
    // Ambiguous extensions: sniff the content.
    if (std.mem.startsWith(u8, head, "- of Ulm") or std.mem.startsWith(u8, head, "AFFormat")) return .ase_traj;
    if (std.mem.indexOf(u8, head, "O   R   C   A") != null) return .orca_output;
    if (std.mem.indexOf(u8, head, "Gaussian") != null or std.mem.indexOf(u8, head, "Entering Gaussian") != null)
        return .gaussian_output;
    if (eq(ext, ".log")) return .gaussian_output;
    if (eq(ext, ".out")) return .orca_output;
    // Last resort: does it start with an atom count?
    var it = std.mem.tokenizeAny(u8, head, " \t\r\n");
    if (it.next()) |tok| {
        _ = std.fmt.parseInt(u32, tok, 10) catch return null;
        return .xyz;
    }
    return null;
}

pub fn open(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8) !Opened {
    const file = try dir.openFile(io, path, .{});
    var file_owned = true;
    defer if (file_owned) file.close(io);

    var head_buf: [4096]u8 = undefined;
    const head = head_buf[0..try file.readPositionalAll(io, &head_buf, 0)];
    const format = detect(path, head) orelse return error.UnknownFormat;
    const size = try file.length(io);

    switch (format) {
        .ase_traj => {
            file_owned = false;
            errdefer file.close(io);
            return .{ .format = format, .source = .{ .traj = try traj.Traj.open(io, gpa, file) } };
        },
        .xyz => if (size > xyz_stream_threshold) {
            file_owned = false;
            errdefer file.close(io);
            return .{ .format = format, .source = .{ .xyz = try xyz.Indexed.open(io, gpa, file) } };
        },
        else => {},
    }

    // Everything else is read whole and parsed in memory.
    const buf = try gpa.alloc(u8, @intCast(size));
    defer gpa.free(buf);
    const got = try file.readPositionalAll(io, buf, 0);
    const bytes = buf[0..got];

    const frames: []Frame = switch (format) {
        .xyz => try xyz.parseAll(gpa, bytes),
        .gaussian_output => try gaussian.parseOutput(gpa, bytes),
        .orca_output => try orca.parseOutput(gpa, bytes),
        .gaussian_input => try single(gpa, try gaussian.parseInput(gpa, bytes)),
        .orca_input => switch (try orca.parseInput(gpa, bytes)) {
            .frame => |f| try single(gpa, f),
            .xyzfile => |rel| blk: {
                // Resolve relative to the input file's directory.
                const base = std.fs.path.dirname(path) orelse ".";
                const joined = try std.fs.path.join(gpa, &.{ base, rel });
                defer gpa.free(joined);
                const xyz_bytes = try dir.readFileAlloc(io, joined, gpa, .limited(1 << 32));
                defer gpa.free(xyz_bytes);
                break :blk try xyz.parseAll(gpa, xyz_bytes);
            },
        },
        .ase_traj => unreachable,
    };
    if (frames.len == 0) {
        gpa.free(frames);
        return error.NoGeometry;
    }
    return .{ .format = format, .source = .{ .memory = frames } };
}

fn single(gpa: Allocator, f: Frame) ![]Frame {
    const out = gpa.alloc(Frame, 1) catch |e| {
        var ff = f;
        ff.deinit(gpa);
        return e;
    };
    out[0] = f;
    return out;
}

test "detect formats" {
    try std.testing.expectEqual(Format.xyz, detect("a.XYZ", "").?);
    try std.testing.expectEqual(Format.orca_output, detect("a.out", "  * O   R   C   A *").?);
    try std.testing.expectEqual(Format.gaussian_output, detect("a.out", " Entering Gaussian System").?);
    try std.testing.expectEqual(Format.ase_traj, detect("noext", "- of UlmASE-Trajectory").?);
    try std.testing.expectEqual(Format.xyz, detect("noext", "  3\nwater\n").?);
}

test "indexed xyz matches whole-file parse" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Last line deliberately lacks a trailing newline.
    const data = "2\nf0\nH 0 0 0\nH 0 0 0.74\n\n2\nf1 energy=-1.5\nH 0 0 0\nH 0 0 0.80";
    try tmp.dir.writeFile(io, .{ .sub_path = "t.xyz", .data = data });
    const file = try tmp.dir.openFile(io, "t.xyz", .{});
    var idx = try xyz.Indexed.open(io, gpa, file);
    defer idx.deinit(io, gpa);
    try std.testing.expectEqual(@as(usize, 2), idx.frameCount());
    var f1 = try idx.loadFrame(io, gpa, 1);
    defer f1.deinit(gpa);
    try std.testing.expectApproxEqAbs(@as(f32, 0.80), f1.positions[1][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -1.5), f1.energy.?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1.5), (try idx.loadEnergy(io, gpa, 1)).?, 1e-9);
    try std.testing.expectEqual(@as(?f64, null), try idx.loadEnergy(io, gpa, 0));
}
