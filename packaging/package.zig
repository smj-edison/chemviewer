//! Packaging for `zig build -Dpackage=local|installer` (see build.zig).
//! Linux and Windows packages can be built on any system; macOS ones only on a Mac,
//! because SDL needs Apple's SDK. Output goes to the install prefix, as
//! chemviewer-VERSION-OS-ARCH-local* or -installer*.
const std = @import("std");
const Compile = std.Build.Step.Compile;

const notices = "packaging/THIRD-PARTY-NOTICES.txt";

/// `local` runs from wherever it is put; `installer` installs.
pub const Kind = enum { none, local, installer };

pub fn add(b: *std.Build, kind: Kind, version: []const u8, makensis: []const u8, exe: *Compile, inspect: *Compile) void {
    if (kind == .none) return;
    const target = exe.rootModuleTarget();
    const name = b.fmt("chemviewer-{s}-{t}-{t}-{t}", .{ version, target.os.tag, target.cpu.arch, kind });
    switch (target.os.tag) {
        .linux => linux(b, kind, name, exe, inspect),
        .windows => windows(b, kind, name, version, makensis, exe, inspect),
        .macos => macos(b, kind, name, version, exe, inspect),
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

/// The program by itself, or a .tar.gz with the desktop entry, icons, file
/// types and an install script. Build with -Dsystem-sdl=false and an old glibc
/// target to need nothing but glibc and a Vulkan driver. (A musl build could
/// not load the driver or the Wayland/X11 libraries.)
fn linux(b: *std.Build, kind: Kind, name: []const u8, exe: *Compile, inspect: *Compile) void {
    if (kind == .local) return installOutput(b, exe.getEmittedBin(), name);
    const run = runTool(b, "targz");
    const file_name = b.fmt("{s}.tar.gz", .{name});
    const out = run.addOutputFileArg(file_name);
    run.addPrefixedFileArg(b.fmt("{s}/install.sh=", .{name}), b.path("packaging/linux-install.sh"));
    run.addPrefixedFileArg(b.fmt("{s}/bin/chemviewer=", .{name}), exe.getEmittedBin());
    run.addPrefixedFileArg(b.fmt("{s}/bin/chemviewer-inspect=", .{name}), inspect.getEmittedBin());
    for (linux_files) |f| run.addPrefixedFileArg(b.fmt("{s}/{s}=", .{ name, f[1] }), b.path(f[0]));
    installOutput(b, out, file_name);
}

/// Desktop entry, file types, licenses and icons: source and path under the prefix.
pub const linux_files = blk: {
    var files: [12][2][]const u8 = undefined;
    files[0] = .{ "packaging/chemviewer.desktop", "share/applications/chemviewer.desktop" };
    files[1] = .{ "packaging/chemviewer-mime.xml", "share/mime/packages/chemviewer.xml" };
    files[2] = .{ "LICENSE", "share/licenses/chemviewer/LICENSE" };
    files[3] = .{ notices, "share/licenses/chemviewer/THIRD-PARTY-NOTICES.txt" };
    for ([_][]const u8{ "16", "24", "32", "48", "64", "128", "256", "512" }, 4..) |n, i| {
        files[i] = .{ "packaging/icons/" ++ n ++ ".png", "share/icons/hicolor/" ++ n ++ "x" ++ n ++ "/apps/chemviewer.png" };
    }
    break :blk files;
};

/// The program by itself, or a per-user NSIS installer (needs `makensis`).
fn windows(b: *std.Build, kind: Kind, name: []const u8, version: []const u8, makensis: []const u8, exe: *Compile, inspect: *Compile) void {
    const file_name = b.fmt("{s}.exe", .{name});
    if (kind == .local) return installOutput(b, exe.getEmittedBin(), file_name);
    const run = b.addSystemCommand(&.{ makensis, "-V2", "-NOCD" });
    run.addArg(b.fmt("-DVERSION={s}", .{version}));
    run.addPrefixedFileArg("-DEXE=", exe.getEmittedBin());
    run.addPrefixedFileArg("-DINSPECT=", inspect.getEmittedBin());
    run.addPrefixedFileArg("-DLICENSE=", b.path("LICENSE"));
    run.addPrefixedFileArg("-DNOTICES=", b.path(notices));
    run.addPrefixedFileArg("-DICON=", b.path("packaging/windows/chemviewer.ico"));
    const setup = run.addPrefixedOutputFileArg("-DOUT=", file_name);
    run.addFileArg(b.path("packaging/windows/chemviewer.nsi"));
    installOutput(b, setup, file_name);
}

/// chemviewer.app in a zip (an app is a folder, with MoltenVK inside), or a
/// drag-to-Applications disk image.
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
    run.addFileArg(b.path("LICENSE"));
    run.addFileArg(b.path(notices));
    const file_name = b.fmt("{s}.{s}", .{ name, if (kind == .local) "zip" else "dmg" });
    const out = run.addOutputFileArg(file_name);
    installOutput(b, out, file_name);
}
