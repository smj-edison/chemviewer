//! Build tool: `zip OUT.zip NAME=FILE...` writes a deflated zip archive.
//! Used by packaging/package.zig, so packaging needs no zip program.
const std = @import("std");
const Io = std.Io;
const zip = std.zip;
const flate = std.compress.flate;

const max_file = 1 << 30;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.MissingArguments;

    var out: Io.Writer.Allocating = .init(arena);
    var directory: Io.Writer.Allocating = .init(arena);
    for (args[2..]) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.ExpectedNameEqualsFile;
        const data = try Io.Dir.cwd().readFileAlloc(io, arg[eq + 1 ..], arena, .limited(max_file));
        try addFile(arena, &out, &directory.writer, arg[0..eq], data);
    }
    const count: u16 = @intCast(args.len - 2);
    const dir_offset: u32 = @intCast(out.written().len);
    try out.writer.writeAll(directory.written());
    try out.writer.writeStruct(zip.EndRecord{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = count,
        .record_count_total = count,
        .central_directory_size = @intCast(directory.written().len),
        .central_directory_offset = dir_offset,
        .comment_len = 0,
    }, .little);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = out.written() });
}

fn addFile(gpa: std.mem.Allocator, out: *Io.Writer.Allocating, directory: *Io.Writer, name: []const u8, data: []const u8) !void {
    var packed_data: Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    const window = try gpa.alloc(u8, flate.max_window_len);
    var deflate = try flate.Compress.init(&packed_data.writer, window, .raw, .best);
    try deflate.writer.writeAll(data);
    try deflate.finish();

    const offset: u32 = @intCast(out.written().len);
    const crc = std.hash.Crc32.hash(data);
    const local: zip.LocalFileHeader = .{
        .signature = zip.local_file_header_sig,
        .version_needed_to_extract = 20,
        .flags = @bitCast(@as(u16, 0)),
        .compression_method = .deflate,
        // A fixed date (1980-01-01) keeps the archive reproducible.
        .last_modification_time = 0,
        .last_modification_date = 0x21,
        .crc32 = crc,
        .compressed_size = @intCast(packed_data.written().len),
        .uncompressed_size = @intCast(data.len),
        .filename_len = @intCast(name.len),
        .extra_len = 0,
    };
    try out.writer.writeStruct(local, .little);
    try out.writer.writeAll(name);
    try out.writer.writeAll(packed_data.written());

    try directory.writeStruct(zip.CentralDirectoryFileHeader{
        .signature = zip.central_file_header_sig,
        .version_made_by = 20,
        .version_needed_to_extract = local.version_needed_to_extract,
        .flags = local.flags,
        .compression_method = local.compression_method,
        .last_modification_time = local.last_modification_time,
        .last_modification_date = local.last_modification_date,
        .crc32 = crc,
        .compressed_size = local.compressed_size,
        .uncompressed_size = local.uncompressed_size,
        .filename_len = local.filename_len,
        .extra_len = 0,
        .comment_len = 0,
        .disk_number = 0,
        .internal_file_attributes = 0,
        .external_file_attributes = 0,
        .local_file_header_offset = offset,
    }, .little);
    try directory.writeAll(name);
}
