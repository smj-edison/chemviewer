//! ASE trajectory (.traj, ULM format v1-3) random-access reader.
//!
//! Layout (see ase/io/ulm.py):
//!   0   magic "- of Ulm" (or legacy "AFFormat")
//!   8   tag, 16 bytes ("ASE-Trajectory  ")
//!   24  version, nitems, offsets_pos   (3 × int64 LE)
//!   offsets_pos: nitems × int64, file offset of each item
//!   item: int64 length + JSON. Arrays stored in the file appear as
//!         "key.": {"ndarray": [shape, dtype, file_offset]}.
//!
//! ASE writes `numbers`, `pbc` and `cell` in frame 0 and only repeats them
//! when they change, so later frames inherit from the last frame that had them.
//! Opening is O(nitems) (just the offset table); each frame costs one small
//! JSON read plus one positional read of the positions array.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const structure = @import("../core/structure.zig");
const Frame = structure.Frame;
const Vec3 = @import("../core/math.zig").Vec3;
const json = std.json;

pub const Error = error{ InvalidTraj, UnsupportedDtype };

pub const Traj = struct {
    file: Io.File,
    offsets: []u64,
    /// Atomic numbers from frame 0, used when a frame doesn't carry its own.
    numbers: []u8,
    cell: ?[3]Vec3,

    pub fn open(io: Io, gpa: Allocator, file: Io.File) !Traj {
        var header: [48]u8 = undefined;
        if (try file.readPositionalAll(io, &header, 0) != header.len) return error.InvalidTraj;
        if (!std.mem.eql(u8, header[0..8], "- of Ulm") and !std.mem.eql(u8, header[0..8], "AFFormat"))
            return error.InvalidTraj;
        const nitems = std.mem.readInt(i64, header[32..40], .little);
        const pos0 = std.mem.readInt(i64, header[40..48], .little);
        if (nitems < 0 or pos0 < 0) return error.InvalidTraj;

        const n: usize = @intCast(nitems);
        const raw = try gpa.alloc(u8, n * 8);
        defer gpa.free(raw);
        if (try file.readPositionalAll(io, raw, @intCast(pos0)) != raw.len) return error.InvalidTraj;
        const offsets = try gpa.alloc(u64, n);
        errdefer gpa.free(offsets);
        for (offsets, 0..) |*o, i| {
            const v = std.mem.readInt(i64, raw[i * 8 ..][0..8], .little);
            if (v < 0) return error.InvalidTraj;
            o.* = @intCast(v);
        }

        var t: Traj = .{ .file = file, .offsets = offsets, .numbers = &.{}, .cell = null };
        if (n > 0) {
            var f0 = try t.loadFrameInner(io, gpa, 0, true);
            t.numbers = f0.numbers;
            f0.numbers = &.{};
            t.cell = f0.cell;
            f0.deinit(gpa);
        }
        return t;
    }

    pub fn deinit(t: *Traj, io: Io, gpa: Allocator) void {
        gpa.free(t.offsets);
        gpa.free(t.numbers);
        t.file.close(io);
    }

    pub fn frameCount(t: *const Traj) usize {
        return t.offsets.len;
    }

    /// Thread-safe: positional reads only, no shared mutable state.
    pub fn loadFrame(t: *const Traj, io: Io, gpa: Allocator, index: usize) !Frame {
        return t.loadFrameInner(io, gpa, index, false);
    }

    fn loadFrameInner(t: *const Traj, io: Io, gpa: Allocator, index: usize, first: bool) !Frame {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const off = t.offsets[index];
        var len_buf: [8]u8 = undefined;
        if (try t.file.readPositionalAll(io, &len_buf, off) != 8) return error.InvalidTraj;
        const len = std.mem.readInt(i64, &len_buf, .little);
        if (len <= 0 or len > 1 << 30) return error.InvalidTraj;
        const text = try arena.alloc(u8, @intCast(len));
        if (try t.file.readPositionalAll(io, text, off + 8) != text.len) return error.InvalidTraj;

        const root = json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch return error.InvalidTraj;
        if (root != .object) return error.InvalidTraj;
        const obj = root.object;
        const little = if (obj.get("_little_endian")) |v| v != .bool or v.bool else true;
        const ctx: ArrayCtx = .{ .io = io, .file = t.file, .arena = arena, .little = little };

        const pos_val = getKey(obj, "positions") orelse return error.InvalidTraj;
        const pos = try ctx.readF64(pos_val);
        if (pos.len % 3 != 0) return error.InvalidTraj;
        const natoms = pos.len / 3;

        var frame = try Frame.init(gpa, natoms);
        errdefer frame.deinit(gpa);
        for (frame.positions, 0..) |*p, i| p.* = .{
            @floatCast(pos[3 * i]),
            @floatCast(pos[3 * i + 1]),
            @floatCast(pos[3 * i + 2]),
        };

        if (getKey(obj, "numbers")) |nv| {
            const nums = try ctx.readF64(nv);
            if (nums.len != natoms) return error.InvalidTraj;
            for (frame.numbers, nums) |*z, v| z.* = std.math.lossyCast(u8, v);
        } else if (!first and t.numbers.len == natoms) {
            @memcpy(frame.numbers, t.numbers);
        } else return error.InvalidTraj;

        frame.cell = if (getKey(obj, "cell")) |cv| try parseCell(ctx, cv) else t.cell;

        if (getKey(obj, "calculator")) |calc| {
            if (calc == .object) {
                if (calc.object.get("energy")) |e| frame.energy = numberOf(e);
            }
        }
        return frame;
    }
};

/// Look up `key` or `key.` (ULM marks entries that reference file data with a trailing dot).
fn getKey(obj: json.ObjectMap, key: []const u8) ?json.Value {
    if (obj.get(key)) |v| return v;
    var buf: [64]u8 = undefined;
    const dotted = std.fmt.bufPrint(&buf, "{s}.", .{key}) catch return null;
    return obj.get(dotted);
}

fn numberOf(v: json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn parseCell(ctx: ArrayCtx, v: json.Value) !?[3]Vec3 {
    const c = try ctx.readF64(v);
    if (c.len != 9) return null;
    var cell: [3]Vec3 = undefined;
    var nonzero = false;
    for (0..3) |r| {
        cell[r] = .{ @floatCast(c[3 * r]), @floatCast(c[3 * r + 1]), @floatCast(c[3 * r + 2]) };
        for (0..3) |k| nonzero = nonzero or c[3 * r + k] != 0;
    }
    return if (nonzero) cell else null;
}

const ArrayCtx = struct {
    io: Io,
    file: Io.File,
    arena: Allocator,
    little: bool,

    /// Decode any array representation ASE uses into a flat f64 slice:
    /// nested JSON lists, inline {"__ndarray__": [shape, dtype, data]}, or
    /// file-backed {"ndarray": [shape, dtype, offset]}.
    fn readF64(ctx: ArrayCtx, v: json.Value) ![]f64 {
        switch (v) {
            .array => {
                var out: std.ArrayList(f64) = .empty;
                try flatten(ctx.arena, &out, v);
                return out.items;
            },
            .object => |o| {
                if (o.get("ndarray")) |nd| return ctx.readFileArray(nd);
                if (o.get("__ndarray__")) |nd| {
                    if (nd != .array or nd.array.items.len != 3) return error.InvalidTraj;
                    var out: std.ArrayList(f64) = .empty;
                    try flatten(ctx.arena, &out, nd.array.items[2]);
                    return out.items;
                }
                return error.InvalidTraj;
            },
            else => return error.InvalidTraj,
        }
    }

    fn readFileArray(ctx: ArrayCtx, nd: json.Value) ![]f64 {
        if (nd != .array or nd.array.items.len != 3) return error.InvalidTraj;
        const shape = nd.array.items[0];
        const dtype = nd.array.items[1];
        const offset = numberOf(nd.array.items[2]) orelse return error.InvalidTraj;
        if (shape != .array or dtype != .string) return error.InvalidTraj;
        var count: usize = 1;
        for (shape.array.items) |d| count *= @intFromFloat(numberOf(d) orelse return error.InvalidTraj);

        const Dtype = enum { float64, float32, int64, int32, int16, int8, uint8 };
        const dt = std.meta.stringToEnum(Dtype, dtype.string) orelse return error.UnsupportedDtype;
        const size: usize = switch (dt) {
            .float64, .int64 => 8,
            .float32, .int32 => 4,
            .int16 => 2,
            .int8, .uint8 => 1,
        };
        const raw = try ctx.arena.alloc(u8, count * size);
        if (try ctx.file.readPositionalAll(ctx.io, raw, @intFromFloat(offset)) != raw.len) return error.InvalidTraj;
        const endian: std.builtin.Endian = if (ctx.little) .little else .big;
        const out = try ctx.arena.alloc(f64, count);
        for (out, 0..) |*o, i| {
            const b = raw[i * size ..];
            o.* = switch (dt) {
                .float64 => @bitCast(std.mem.readInt(u64, b[0..8], endian)),
                .float32 => @as(f32, @bitCast(std.mem.readInt(u32, b[0..4], endian))),
                .int64 => @floatFromInt(std.mem.readInt(i64, b[0..8], endian)),
                .int32 => @floatFromInt(std.mem.readInt(i32, b[0..4], endian)),
                .int16 => @floatFromInt(std.mem.readInt(i16, b[0..2], endian)),
                .int8 => @floatFromInt(@as(i8, @bitCast(b[0]))),
                .uint8 => @floatFromInt(b[0]),
            };
        }
        return out;
    }
};

fn flatten(arena: Allocator, out: *std.ArrayList(f64), v: json.Value) !void {
    switch (v) {
        .array => |a| for (a.items) |item| try flatten(arena, out, item),
        else => try out.append(arena, numberOf(v) orelse return error.InvalidTraj),
    }
}

fn openFixture(tmp: *std.testing.TmpDir, comptime name: []const u8) !Io.File {
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = @embedFile("../testdata/" ++ name) });
    return tmp.dir.openFile(io, name, .{});
}

test "read ASE trajectory without calculator (expected values from ASE 3.29)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var t = try Traj.open(io, gpa, try openFixture(&tmp, "ethanol.traj"));
    defer t.deinit(io, gpa);
    try std.testing.expectEqual(@as(usize, 20), t.frameCount());
    var f = try t.loadFrame(io, gpa, 19);
    defer f.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 9), f.len());
    try std.testing.expectEqualSlices(u8, &.{ 6, 6, 8 }, f.numbers[0..3]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.096333135), f.positions[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.085671972), f.positions[1][2], 1e-6);
    try std.testing.expectEqual(@as(?[3]Vec3, null), f.cell);
    try std.testing.expectEqual(@as(?f64, null), f.energy);
}

test "read periodic ASE trajectory with calculator" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var t = try Traj.open(io, gpa, try openFixture(&tmp, "cu.traj"));
    defer t.deinit(io, gpa);
    try std.testing.expectEqual(@as(usize, 5), t.frameCount());
    var f = try t.loadFrame(io, gpa, 4);
    defer f.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 27), f.len());
    try std.testing.expectEqual(@as(u8, 29), f.numbers[26]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.832766), f.positions[1][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 5.4), f.cell.?[0][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.695731063651845), f.energy.?, 1e-12);
}
