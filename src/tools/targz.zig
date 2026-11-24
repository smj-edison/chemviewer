//! Build tool: `targz OUT.tar.gz NAME=FILE...` writes a gzipped tar archive.
//! Files in a `bin` directory are made executable. Used by
//! packaging/package.zig.
const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;

const max_file = 1 << 30;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.MissingArguments;

    var out: Io.Writer.Allocating = try .initCapacity(arena, 4096);
    const window = try arena.alloc(u8, flate.max_window_len);
    var gzip = try flate.Compress.init(&out.writer, window, .gzip, .best);
    var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };
    for (args[2..]) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.ExpectedNameEqualsFile;
        const name = arg[0..eq];
        const data = try Io.Dir.cwd().readFileAlloc(io, arg[eq + 1 ..], arena, .limited(max_file));
        const mode: u32 = if (std.mem.indexOf(u8, name, "/bin/") != null) 0o755 else 0o644;
        try tar.writeFileBytes(name, data, .{ .mode = mode });
    }
    try tar.finishPedantically();
    try gzip.finish();
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = out.written() });
}
