//! Packaging for `zig build -Dpackage=portable|installer` (see build.zig).
//! Linux and Windows packages can be built on any system; macOS ones only on a Mac,
//! because SDL needs Apple's SDK. Output goes to the install prefix.
const std = @import("std");
const Compile = std.Build.Step.Compile;

pub const Kind = enum { none, portable, installer };

pub fn add(b: *std.Build, kind: Kind, version: []const u8, makensis: []const u8, exe: *Compile, inspect: *Compile) void {
    if (kind == .none) return;
    const target = exe.rootModuleTarget();
    switch (target.os.tag) {
        .windows => windows(b, kind, b.fmt("chemviewer-{s}-windows-{t}", .{ version, target.cpu.arch }), version, makensis, exe, inspect),
        .macos => macos(b, kind, b.fmt("chemviewer-{s}-macos-{t}", .{ version, target.cpu.arch }), version, exe, inspect),
        .linux => linux(b, kind, b.fmt("chemviewer-{s}-linux-{t}", .{ version, target.cpu.arch }), exe, inspect),
        else => b.getInstallStep().dependOn(&b.addFail("-Dpackage is for Linux, Windows and macOS").step),
    }
}

fn installOutput(b: *std.Build, file: std.Build.LazyPath, name: []const u8) void {
    b.getInstallStep().dependOn(&b.addInstallFile(file, name).step);
}

/// Runs a build tool from src/tools on the host.
fn runTool(b: *std.Build, name: []const u8) *std.Build.Step.Run {
    return b.addRunArtifact(b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/tools/{s}.zig", .{name})),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    }));
}

/// A .tar.gz laid out like an installed copy, so it runs in place or can be
/// unpacked into ~/.local. Build with -Dsystem-sdl=false and an old glibc
/// target to need nothing but glibc and a Vulkan driver. (A musl build could
/// not load the driver or the Wayland/X11 libraries.)
fn linux(b: *std.Build, kind: Kind, name: []const u8, exe: *Compile, inspect: *Compile) void {
    if (kind == .installer) {
        return b.getInstallStep().dependOn(&b.addFail("no Linux installer; on Arch use packaging/aur").step);
    }
    const run = runTool(b, "targz");
    const file_name = b.fmt("{s}.tar.gz", .{name});
    const out = run.addOutputFileArg(file_name);
    run.addPrefixedFileArg(b.fmt("{s}/bin/chemviewer=", .{name}), exe.getEmittedBin());
    run.addPrefixedFileArg(b.fmt("{s}/bin/chemviewer-inspect=", .{name}), inspect.getEmittedBin());
    for (linux_files) |f| run.addPrefixedFileArg(b.fmt("{s}/{s}=", .{ name, f[1] }), b.path(f[0]));
    installOutput(b, out, file_name);
}

/// Desktop entry, file types and icons: source and path under the prefix.
pub const linux_files = blk: {
    var files: [10][2][]const u8 = undefined;
    files[0] = .{ "packaging/chemviewer.desktop", "share/applications/chemviewer.desktop" };
    files[1] = .{ "packaging/chemviewer-mime.xml", "share/mime/packages/chemviewer.xml" };
    for ([_][]const u8{ "16", "24", "32", "48", "64", "128", "256", "512" }, 2..) |n, i| {
        files[i] = .{ "packaging/icons/" ++ n ++ ".png", "share/icons/hicolor/" ++ n ++ "x" ++ n ++ "/apps/chemviewer.png" };
    }
    break :blk files;
};

/// Portable zip, or a per-user NSIS installer (needs `makensis`).
fn windows(b: *std.Build, kind: Kind, name: []const u8, version: []const u8, makensis: []const u8, exe: *Compile, inspect: *Compile) void {
    if (kind == .portable) {
        const run = runTool(b, "zip");
        const zip_name = b.fmt("{s}.zip", .{name});
        const zip = run.addOutputFileArg(zip_name);
        run.addPrefixedFileArg(b.fmt("{s}/chemviewer.exe=", .{name}), exe.getEmittedBin());
        run.addPrefixedFileArg(b.fmt("{s}/chemviewer-inspect.exe=", .{name}), inspect.getEmittedBin());
        run.addPrefixedFileArg(b.fmt("{s}/README.md=", .{name}), b.path("README.md"));
        return installOutput(b, zip, zip_name);
    }
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
