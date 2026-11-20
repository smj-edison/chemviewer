//! Headless inspector: `zig build inspect -- FILE...`
//! Prints format, frame/atom counts, energies and load timings. Useful for
//! checking parsers against real files without opening the GUI.
const std = @import("std");
const Io = std.Io;
const cv = @import("chemviewer");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    for (args[1..]) |path| {
        const t0 = Io.Timestamp.now(io, .awake);
        var opened = cv.source.open(io, gpa, .cwd(), path) catch |e| {
            try out.print("{s}: error {t}\n", .{ path, e });
            continue;
        };
        defer opened.source.deinit(io, gpa);
        const t_open = t0.untilNow(io, .awake);
        const n = opened.source.frameCount();

        var first = try opened.source.loadFrame(io, gpa, 0);
        defer first.deinit(gpa);
        const t1 = Io.Timestamp.now(io, .awake);
        var last = try opened.source.loadFrame(io, gpa, n - 1);
        defer last.deinit(gpa);
        const t_last = t1.untilNow(io, .awake);

        const bonds = try cv.bonds.find(gpa, last.positions, last.numbers, .{});
        defer gpa.free(bonds);

        try out.print("{s}\n  format {s}{s}, {d} frames, {d} atoms, {d} candidate bonds (last frame)\n", .{
            path,                           opened.format.label(),
            if (opened.source.isStreamed()) " (streamed)" else "", n,
            last.len(),                     bonds.len,
        });
        try out.print("  open {f}, load last frame {f}\n", .{ t_open, t_last });
        if (first.energy) |e| try out.print("  E(first) = {d}\n", .{e});
        if (last.energy) |e| try out.print("  E(last)  = {d}\n", .{e});
        if (last.cell != null) try out.print("  periodic cell\n", .{});
        var counts: [256]u32 = @splat(0);
        for (last.numbers) |z| counts[z] += 1;
        try out.print("  composition:", .{});
        for (counts, 0..) |c, z| if (c > 0) try out.print(" {s}{d}", .{ cv.elements.symbol(@intCast(z)), c });
        try out.print("\n", .{});
    }
}
