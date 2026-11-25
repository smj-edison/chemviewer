//! Where the rows of a table are among the frames of a trajectory. Proposed from how
//! many there are; see the spec for the better rules to come (energies, clocks).
const std = @import("std");

pub const Rule = enum {
    /// A whole number of frames per row, or rows per frame.
    whole,
    /// First row at the first frame, last at the last. Only a guess.
    equal_spans,
};

pub const Alignment = struct {
    rule: Rule,
    /// Frame of row 0.
    offset: f64 = 0,
    frames_per_row: f64,
    confirmed: bool = false,

    /// Of `rows` rows with `frames` frames.
    pub fn propose(rows: usize, frames: usize) Alignment {
        if (rows < 2 or frames < 2) return .{ .rule = .equal_spans, .frames_per_row = 1 };
        const k = @as(f64, @floatFromInt(frames - 1)) / @as(f64, @floatFromInt(rows - 1));
        // Runs that were stopped end a little before or after the other file.
        const per = if (k >= 1) @round(k) else 1 / @round(1 / k);
        if (@abs(k - per) <= 0.01 * per) return .{ .rule = .whole, .frames_per_row = per };
        return .{ .rule = .equal_spans, .frames_per_row = k };
    }

    pub fn frameOf(a: Alignment, row: usize) f64 {
        return a.offset + @as(f64, @floatFromInt(row)) * a.frames_per_row;
    }

    /// The last of `rows` rows at or before `frame`, or null before the first.
    pub fn rowAt(a: Alignment, frame: f64, rows: usize) ?usize {
        if (rows == 0 or frame < a.offset) return null;
        // Rows that are exactly at a frame aren't lost to rounding.
        const r = @floor((frame - a.offset) / a.frames_per_row + 1e-6);
        return @intFromFloat(@min(r, @as(f64, @floatFromInt(rows - 1))));
    }

    /// The first row at or after `frame`; `rows` if there is none.
    pub fn rowFrom(a: Alignment, frame: f64, rows: usize) usize {
        if (frame <= a.offset) return 0;
        const r = @ceil((frame - a.offset) / a.frames_per_row - 1e-6);
        return @intFromFloat(std.math.clamp(r, 0, @as(f64, @floatFromInt(rows))));
    }

    /// How many rows are after the last of `frames` frames.
    pub fn rowsAfter(a: Alignment, rows: usize, frames: usize) usize {
        if (frames == 0) return rows;
        return rows - a.rowFrom(@as(f64, @floatFromInt(frames - 1)) + 0.001, rows);
    }

    /// Why, in words.
    pub fn evidence(a: Alignment, buf: []u8) []const u8 {
        return switch (a.rule) {
            .whole => if (a.frames_per_row >= 1)
                std.fmt.bufPrint(buf, "{d} frame{s} per row", .{ a.frames_per_row, if (a.frames_per_row == 1) "" else "s" })
            else
                std.fmt.bufPrint(buf, "{d} rows per frame", .{@round(1 / a.frames_per_row)}),
            .equal_spans => std.fmt.bufPrint(buf, "same start and end as the trajectory", .{}),
        } catch "";
    }
};

const testing = std.testing;
const expectEqual = testing.expectEqual;

test "a whole number of frames per row is proposed, even if one file ends early" {
    const Case = struct { rows: usize, frames: usize, per: f64 };
    for ([_]Case{
        .{ .rows = 49_299, .frames = 492_963, .per = 10 }, // COLVAR
        .{ .rows = 49_296, .frames = 492_963, .per = 10 }, // md.log
        .{ .rows = 24_649, .frames = 492_963, .per = 20 }, // HILLS
        .{ .rows = 100, .frames = 100, .per = 1 },
        .{ .rows = 991, .frames = 100, .per = 0.1 },
        .{ .rows = 11, .frames = 101, .per = 10 },
    }) |case| {
        const a: Alignment = .propose(case.rows, case.frames);
        try expectEqual(.whole, a.rule);
        try expectEqual(case.per, a.frames_per_row);
        try testing.expect(!a.confirmed);
    }
}

test "otherwise equal spans, as a guess" {
    const a: Alignment = .propose(68, 101);
    try expectEqual(.equal_spans, a.rule);
    try testing.expectApproxEqAbs(100, a.frameOf(67), 1e-9);
    for ([_][2]usize{ .{ 0, 0 }, .{ 1, 100 }, .{ 100, 1 }, .{ 0, 5 } }) |c| {
        const b: Alignment = .propose(c[0], c[1]);
        try expectEqual(.equal_spans, b.rule);
        try testing.expect(b.frames_per_row > 0);
    }
}

test "rows floor: the last at or before a frame, none before the first" {
    const a: Alignment = .{ .rule = .whole, .offset = 20, .frames_per_row = 10 };
    try expectEqual(null, a.rowAt(19.9, 5));
    try expectEqual(0, a.rowAt(20, 5).?);
    try expectEqual(0, a.rowAt(29.9, 5).?);
    try expectEqual(1, a.rowAt(30, 5).?);
    try expectEqual(4, a.rowAt(1000, 5).?);
    try expectEqual(null, a.rowAt(1000, 0));
    try expectEqual(0, a.rowFrom(5, 5));
    try expectEqual(1, a.rowFrom(20.1, 5));
    try expectEqual(1, a.rowFrom(30, 5));
    try expectEqual(5, a.rowFrom(61, 5));
}

test "every row is found at its own frame" {
    for ([_]f64{ 10, 1, 0.1, 1.0 / 3.0, 9.9996 }) |per| {
        const a: Alignment = .{ .rule = .whole, .frames_per_row = per };
        for (0..1000) |row| {
            try expectEqual(row, a.rowAt(a.frameOf(row), 1000).?);
            try expectEqual(row, a.rowFrom(a.frameOf(row), 1000));
        }
    }
}

test "rows after the last frame are counted" {
    const a: Alignment = .propose(49_299, 492_963);
    try expectEqual(2, a.rowsAfter(49_299, 492_963));
    try expectEqual(0, a.rowsAfter(49_296, 492_963));
    try expectEqual(0, a.rowsAfter(0, 10));
}

test "the evidence in words" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("10 frames per row", Alignment.propose(11, 101).evidence(&buf));
    try testing.expectEqualStrings("1 frame per row", Alignment.propose(100, 100).evidence(&buf));
    try testing.expectEqualStrings("10 rows per frame", Alignment.propose(991, 100).evidence(&buf));
    try testing.expectEqualStrings("same start and end as the trajectory", Alignment.propose(68, 101).evidence(&buf));
}
