//! What the app remembers between runs, as "key=value" lines.
const std = @import("std");
const Io = std.Io;

pub const Settings = struct {
    /// Inspector sections that are open.
    file_open: bool = true,
    bonds_open: bool = true,
    display_open: bool = true,

    /// Keys that are missing, unknown or unreadable are left at their defaults.
    pub fn parse(text: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            const eq = std.mem.findScalar(u8, line, '=') orelse continue;
            inline for (@typeInfo(Settings).@"struct".field_names) |name| {
                if (std.mem.eql(u8, line[0..eq], name)) {
                    if (std.mem.eql(u8, line[eq + 1 ..], "1")) @field(s, name) = true;
                    if (std.mem.eql(u8, line[eq + 1 ..], "0")) @field(s, name) = false;
                }
            }
        }
        return s;
    }

    pub fn write(s: Settings, w: *Io.Writer) Io.Writer.Error!void {
        inline for (@typeInfo(Settings).@"struct".field_names) |name| {
            try w.print("{s}={d}\n", .{ name, @intFromBool(@field(s, name)) });
        }
    }
};

test "settings come back as they were written" {
    const s: Settings = .{ .bonds_open = false, .display_open = false };
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try s.write(&w);
    try std.testing.expectEqual(s, Settings.parse(w.buffered()));
}

test "settings that can't be read are left at their defaults" {
    try std.testing.expectEqual(Settings{}, Settings.parse(""));
    try std.testing.expectEqual(Settings{ .file_open = false }, Settings.parse("junk\nnew_key=3\r\nbonds_open=maybe\r\nfile_open=0"));
}
