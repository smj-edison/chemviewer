//! What the app remembers between runs, as "key=value" lines. Only what differs
//! from the default is written, so better defaults reach everyone else.
const std = @import("std");
const Io = std.Io;
const bonds = @import("core/bonds.zig");

pub const Settings = struct {
    /// Inspector sections that are open.
    file_open: bool = true,
    bonds_open: bool = true,
    display_open: bool = true,

    ui_scale: f32 = 1,
    cutoff_factor: f32 = (bonds.Params{}).cutoff_factor,

    // Named as in `Renderer.Style`, with the same defaults.
    theme: enum { light, dark } = .light,
    shading: enum { cel, flat, aero, glass } = .cel,
    liquid: bool = true,
    outline_px: f32 = 2.0,
    atom_scale: f32 = 1.0,
    bond_radius: f32 = 0.11,
    bond_coloring: enum { gradient, element } = .gradient,
    min_character: f32 = 0.25,
    snap: f32 = 0.7,
    show_cell: bool = true,
    background_pattern: bool = true,
    backdrop: enum { cells, space } = .space,
    flat_pop: bool = false,
    background_blur: f32 = 0.6,

    /// As the sliders allow.
    const ranges = struct {
        const ui_scale = [2]f32{ 0.5, 2 };
        const cutoff_factor = [2]f32{ 1, 1.8 };
        const outline_px = [2]f32{ 0, 4 };
        const atom_scale = [2]f32{ 0.2, 3 };
        const bond_radius = [2]f32{ 0.03, 0.3 };
        const min_character = [2]f32{ 0, 3 };
        const snap = [2]f32{ 0, 1 };
        const background_blur = [2]f32{ 0, 2.5 };
    };

    /// Keys that are missing, unknown or unreadable are left at their defaults.
    pub fn parse(text: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            const eq = std.mem.findScalar(u8, line, '=') orelse continue;
            const value = line[eq + 1 ..];
            inline for (@typeInfo(Settings).@"struct".field_names) |name| {
                if (std.mem.eql(u8, line[0..eq], name)) {
                    const T = @FieldType(Settings, name);
                    if (T == bool) {
                        if (std.mem.eql(u8, value, "1")) @field(s, name) = true;
                        if (std.mem.eql(u8, value, "0")) @field(s, name) = false;
                    } else if (T == f32) {
                        const range = @field(ranges, name);
                        if (std.fmt.parseFloat(f32, value)) |v| {
                            if (v >= range[0] and v <= range[1]) @field(s, name) = v;
                        } else |_| {}
                    } else if (std.meta.stringToEnum(T, value)) |v| @field(s, name) = v;
                }
            }
        }
        return s;
    }

    pub fn write(s: Settings, w: *Io.Writer) Io.Writer.Error!void {
        const default: Settings = .{};
        inline for (@typeInfo(Settings).@"struct".field_names) |name| {
            const v = @field(s, name);
            if (v != @field(default, name)) switch (@TypeOf(v)) {
                bool => try w.print("{s}={d}\n", .{ name, @intFromBool(v) }),
                f32 => try w.print("{s}={d}\n", .{ name, v }),
                else => try w.print("{s}={t}\n", .{ name, v }),
            };
        }
    }
};

test "settings come back as they were written" {
    const s: Settings = .{ .bonds_open = false, .display_open = false, .theme = .dark, .shading = .glass, .snap = 0.123, .ui_scale = 1.5 };
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try s.write(&w);
    try std.testing.expectEqual(s, Settings.parse(w.buffered()));
}

test "defaults aren't written" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try (Settings{ .theme = .dark }).write(&w);
    try std.testing.expectEqualStrings("theme=dark\n", w.buffered());
}

test "settings that can't be read are left at their defaults" {
    try std.testing.expectEqual(Settings{}, Settings.parse(""));
    try std.testing.expectEqual(Settings{ .file_open = false }, Settings.parse("junk\nnew_key=3\r\nbonds_open=maybe\r\nfile_open=0"));
    try std.testing.expectEqual(Settings{}, Settings.parse("ui_scale=0\nsnap=nan\natom_scale=inf\ntheme=blue\nbond_radius=x\n"));
}
