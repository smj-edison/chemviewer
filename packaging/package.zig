//! Packaging for `zig build -Dpackage=portable|installer` (see build.zig).
//! Windows packages can be built on any system; macOS ones only on a Mac,
//! because SDL needs Apple's SDK. Output goes to the install prefix.
const std = @import("std");
const Compile = std.Build.Step.Compile;

pub const Kind = enum { none, portable, installer };

pub fn add(b: *std.Build, kind: Kind, version: []const u8, exe: *Compile, inspect: *Compile) void {
    if (kind == .none) return;
    const target = exe.rootModuleTarget();
    switch (target.os.tag) {
        .windows => windows(b, kind, b.fmt("chemviewer-{s}-windows-{t}", .{ version, target.cpu.arch }), version, exe, inspect),
        .macos => macos(b, kind, b.fmt("chemviewer-{s}-macos-{t}", .{ version, target.cpu.arch }), version, exe, inspect),
        else => b.getInstallStep().dependOn(&b.addFail("-Dpackage is for Windows and macOS; on Arch use packaging/aur").step),
    }
}

fn installOutput(b: *std.Build, file: std.Build.LazyPath, name: []const u8) void {
    b.getInstallStep().dependOn(&b.addInstallFile(file, name).step);
}

/// Portable zip, or a per-user NSIS installer (needs `makensis`).
fn windows(b: *std.Build, kind: Kind, name: []const u8, version: []const u8, exe: *Compile, inspect: *Compile) void {
    if (kind == .portable) {
        const tool = b.addExecutable(.{
            .name = "zip",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/zip.zig"),
                .target = b.graph.host,
                .optimize = .safe,
            }),
        });
        const run = b.addRunArtifact(tool);
        const zip_name = b.fmt("{s}.zip", .{name});
        const zip = run.addOutputFileArg(zip_name);
        run.addPrefixedFileArg(b.fmt("{s}/chemviewer.exe=", .{name}), exe.getEmittedBin());
        run.addPrefixedFileArg(b.fmt("{s}/chemviewer-inspect.exe=", .{name}), inspect.getEmittedBin());
        run.addPrefixedFileArg(b.fmt("{s}/README.md=", .{name}), b.path("README.md"));
        return installOutput(b, zip, zip_name);
    }
    const makensis = b.option([]const u8, "makensis", "Path to the NSIS compiler") orelse "makensis";
    const run = b.addSystemCommand(&.{ makensis, "-V2", "-NOCD" });
    run.addArg(b.fmt("-DVERSION={s}", .{version}));
    run.addPrefixedFileArg("-DEXE=", exe.getEmittedBin());
    run.addPrefixedFileArg("-DINSPECT=", inspect.getEmittedBin());
    run.addPrefixedFileArg("-DICON=", b.path("packaging/windows/chemviewer.ico"));
    const setup_name = b.fmt("{s}-setup.exe", .{name});
    const setup = run.addPrefixedOutputFileArg("-DOUT=", setup_name);
    run.addFileArg(b.path("packaging/windows/chemviewer.nsi"));
    installOutput(b, setup, setup_name);
}

/// chemviewer.app as a zip (portable) or a drag-to-Applications disk image.
fn macos(b: *std.Build, kind: Kind, name: []const u8, version: []const u8, exe: *Compile, inspect: *Compile) void {
    const moltenvk = b.lazyDependency("moltenvk", .{}) orelse return; // being fetched
    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg(b.path("packaging/macos/bundle.sh"));
    run.addArg(version);
    run.addFileArg(exe.getEmittedBin());
    run.addFileArg(inspect.getEmittedBin());
    run.addFileArg(b.path("packaging/macos/Info.plist"));
    run.addDirectoryArg(b.path("packaging/icons"));
    run.addFileArg(moltenvk.path("MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"));
    const file_name = b.fmt("{s}.{s}", .{ name, if (kind == .portable) "zip" else "dmg" });
    const out = run.addOutputFileArg(file_name);
    installOutput(b, out, file_name);
}
