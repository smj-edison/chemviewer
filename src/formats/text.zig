//! Small helpers shared by the text-format parsers.
const std = @import("std");

/// Iterates lines of a buffer, stripping a trailing '\r'. Tracks byte offsets
/// so callers can record where frames start.
pub const Lines = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Lines {
        return .{ .buf = buf };
    }

    pub fn next(it: *Lines) ?[]const u8 {
        if (it.pos >= it.buf.len) return null;
        const rest = it.buf[it.pos..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |i| rest[0..i] else rest;
        it.pos += if (nl) |i| i + 1 else rest.len;
        return std.mem.trimEnd(u8, line, "\r");
    }

    pub fn peek(it: *Lines) ?[]const u8 {
        const save = it.pos;
        defer it.pos = save;
        return it.next();
    }
};

pub fn tokens(line: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, line, " \t\r,");
}

pub fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

/// Parse a float, accepting Fortran-style 'D' exponents.
pub fn parseFloat(s: []const u8) !f64 {
    if (std.mem.indexOfAny(u8, s, "dD")) |i| {
        var tmp: [64]u8 = undefined;
        if (s.len > tmp.len) return error.InvalidCharacter;
        @memcpy(tmp[0..s.len], s);
        tmp[i] = 'e';
        return std.fmt.parseFloat(f64, tmp[0..s.len]);
    }
    return std.fmt.parseFloat(f64, s);
}

/// Parse three consecutive tokens as a position.
pub fn parseVec3(it: *std.mem.TokenIterator(u8, .any)) !@Vector(3, f32) {
    const x = try parseFloat(it.next() orelse return error.MissingCoordinate);
    const y = try parseFloat(it.next() orelse return error.MissingCoordinate);
    const z = try parseFloat(it.next() orelse return error.MissingCoordinate);
    return .{ @floatCast(x), @floatCast(y), @floatCast(z) };
}

pub fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

test "lines and floats" {
    var it = Lines.init("a\r\nb\n\nc");
    try std.testing.expectEqualStrings("a", it.next().?);
    try std.testing.expectEqualStrings("b", it.next().?);
    try std.testing.expectEqualStrings("", it.next().?);
    try std.testing.expectEqualStrings("c", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
    try std.testing.expectApproxEqAbs(@as(f64, 1.5e-3), try parseFloat("1.5D-03"), 1e-12);
}
