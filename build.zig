const std = @import("std");
const package = @import("packaging/package.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // All options are declared before the early return below (while a lazy
    // dependency is fetched), or Zig would reject them as unknown there.
    const glslc = b.option([]const u8, "glslc", "Path to the glslc shader compiler") orelse "glslc";
    const package_kind = b.option(package.Kind, "package", "Also build a Windows/macOS package") orelse .none;
    const version = b.option([]const u8, "version", "Version shown in packages") orelse "0.0.0";
    const makensis = b.option([]const u8, "makensis", "Path to the NSIS compiler, for Windows installers") orelse "makensis";

    // SDL3: use the system package (pkg-config) by default, except on Windows
    // where none is usually installed; there it is built from source via the
    // castholm/SDL Zig package. Override with -Dsystem-sdl=true|false.
    const system_sdl = b.option(
        bool,
        "system-sdl",
        "Link the system SDL3 (default: true, except on Windows)",
    ) orelse (target.result.os.tag != .windows);
    const sdl_lib: ?*std.Build.Step.Compile = if (system_sdl) null else blk: {
        const sdl_dep = b.lazyDependency("sdl", .{ .target = target, .optimize = optimize }) orelse break :blk null;
        break :blk sdl_dep.artifact("SDL3");
    };
    if (!system_sdl and sdl_lib == null) return; // lazy dependency still being fetched

    // ---------------------------------------------------------------- core
    // Pure-Zig core: formats, structures, bonds, alignment. No C, no GPU.
    const core = b.addModule("chemviewer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ------------------------------------------------- Dear ImGui (cimgui)
    // cimgui expects `./imgui/...` next to its sources, so stage both pinned
    // packages into one generated directory with that layout.
    const imgui_dep = b.dependency("imgui", .{});
    const cimgui_dep = b.dependency("cimgui", .{});
    const staged = b.addWriteFiles();
    _ = staged.addCopyDirectory(imgui_dep.path(""), "imgui", .{
        .include_extensions = &.{ ".h", ".cpp" },
    });
    for ([_][]const u8{ "cimgui.h", "cimgui.cpp", "cimgui_impl.h", "cimgui_impl.cpp", "cimconfig.h" }) |f| {
        _ = staged.addCopyFile(cimgui_dep.path(f), f);
    }
    const imgui_root = staged.getDirectory();

    // Vulkan: headers (for ImGui's C++ backend) and the registry that
    // vulkan-zig generates its bindings from, pinned together.
    const vk_headers = b.dependency("vulkan_headers", .{});
    const vulkan = b.dependency("vulkan", .{
        .registry = vk_headers.path("registry/vk.xml"),
    }).module("vulkan-zig");

    const imgui_flags = [_][]const u8{
        "-DIMGUI_IMPL_API=extern \"C\"",
        "-DCIMGUI_USE_SDL3",
        "-fno-exceptions",
        "-fno-rtti",
    };
    const imgui_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    imgui_mod.addIncludePath(imgui_root);
    imgui_mod.addIncludePath(imgui_root.path(b, "imgui"));
    imgui_mod.addIncludePath(imgui_root.path(b, "imgui/backends"));
    imgui_mod.addCSourceFiles(.{
        .root = imgui_root,
        .files = &.{
            "cimgui.cpp",
            "cimgui_impl.cpp",
            "imgui/imgui.cpp",
            "imgui/imgui_demo.cpp",
            "imgui/imgui_draw.cpp",
            "imgui/imgui_tables.cpp",
            "imgui/imgui_widgets.cpp",
            "imgui/backends/imgui_impl_sdl3.cpp",
        },
        .flags = &imgui_flags,
    });
    imgui_mod.addIncludePath(vk_headers.path("include"));
    imgui_mod.addIncludePath(b.path("src/cshim"));
    imgui_mod.addCSourceFiles(.{ .root = b.path("src/cshim"), .files = &.{"imgui_shim.c"} });
    // The Vulkan backend keeps C++ linkage (it overloads a function); Zig
    // reaches it through the extern "C" wrappers in imgui_vulkan.cpp.
    const vulkan_flags = [_][]const u8{
        // Vulkan entry points come from SDL's loader at runtime, not by linking.
        "-DIMGUI_IMPL_VULKAN_NO_PROTOTYPES",
        "-fno-exceptions",
        "-fno-rtti",
    };
    imgui_mod.addCSourceFiles(.{ .root = imgui_root, .files = &.{"imgui/backends/imgui_impl_vulkan.cpp"}, .flags = &vulkan_flags });
    imgui_mod.addCSourceFiles(.{ .root = b.path("src/cshim"), .files = &.{"imgui_vulkan.cpp"}, .flags = &vulkan_flags });
    linkSdl(imgui_mod, sdl_lib);
    const imgui_lib = b.addLibrary(.{ .name = "cimgui", .root_module = imgui_mod });

    // ------------------------------------------------------- C bindings
    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c_translate.addIncludePath(imgui_root);
    c_translate.addIncludePath(b.path("src/cshim"));
    if (sdl_lib) |lib| c_translate.addIncludePath(lib.getEmittedIncludeTree()) else c_translate.linkSystemLibrary("SDL3", .{});
    const c_mod = c_translate.createModule();

    // ------------------------------------------------------- executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "chemviewer", .module = core },
            .{ .name = "c", .module = c_mod },
            .{ .name = "vulkan", .module = vulkan },
        },
    });
    linkSdl(exe_mod, sdl_lib);
    addShaders(b, exe_mod, glslc);
    exe_mod.linkLibrary(imgui_lib);

    const exe = b.addExecutable(.{ .name = "chemviewer", .root_module = exe_mod });
    if (target.result.os.tag == .windows) {
        exe_mod.addWin32ResourceFile(.{ .file = b.path("packaging/windows/chemviewer.rc") });
        // No console window, except in debug builds (for the log).
        if (optimize != .debug) exe.subsystem = .windows;
    }
    b.installArtifact(exe);

    // Desktop entry, file types and icons, for `zig build --prefix /usr`.
    if (target.result.os.tag == .linux) {
        b.installFile("packaging/chemviewer.desktop", "share/applications/chemviewer.desktop");
        b.installFile("packaging/chemviewer-mime.xml", "share/mime/packages/chemviewer.xml");
        for ([_][]const u8{ "16", "24", "32", "48", "64", "128", "256", "512" }) |n| {
            b.installFile(
                b.fmt("packaging/icons/{s}.png", .{n}),
                b.fmt("share/icons/hicolor/{s}x{s}/apps/chemviewer.png", .{ n, n }),
            );
        }
    }

    const run_step = b.step("run", "Run the viewer");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------- headless inspector
    const inspect = b.addExecutable(.{
        .name = "chemviewer-inspect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/inspect.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "chemviewer", .module = core }},
        }),
    });
    b.installArtifact(inspect);

    // -------------------------------------------------------- packages
    package.add(b, package_kind, version, makensis, exe, inspect);

    const inspect_run = b.addRunArtifact(inspect);
    inspect_run.addPassthruArgs();
    b.step("inspect", "Print a summary of structure files (headless)").dependOn(&inspect_run.step);

    // ------------------------------------------------------------ tests
    const test_step = b.step("test", "Run unit tests (headless)");
    const core_tests = b.addTest(.{ .root_module = core });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    // GUI-side math (camera, picking); links SDL/ImGui but needs no display.
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}

/// Compiles the GLSL in src/render/shaders to SPIR-V with glslc (from the
/// Vulkan SDK or the distribution's shaderc package). Each is importable as
/// e.g. `@embedFile("sphere.vert.spv")`.
fn addShaders(b: *std.Build, mod: *std.Build.Module, glslc: []const u8) void {
    const dir = "src/render/shaders";
    const includes = [_][]const u8{ "common.glsl", "lighting.glsl", "glass.glsl" };
    const stages = [_][]const u8{
        "sphere.vert",     "sphere.frag",
        "cylinder.vert",   "cylinder.frag",
        "line.vert",       "line.frag",
        "fullscreen.vert", "background.frag",
        "blit.frag",       "fill.frag",
        "liquid.vert",     "liquid.frag",
    };
    for (stages) |name| {
        const cmd = b.addSystemCommand(&.{ glslc, "--target-env=vulkan1.3", "-O" });
        cmd.addPrefixedDirectoryArg("-I", b.path(dir));
        for (includes) |inc| cmd.addFileInput(b.path(b.fmt("{s}/{s}", .{ dir, inc })));
        cmd.addArg("-o");
        const spv = cmd.addOutputFileArg(b.fmt("{s}.spv", .{name}));
        cmd.addFileArg(b.path(b.fmt("{s}/{s}", .{ dir, name })));
        mod.addAnonymousImport(b.fmt("{s}.spv", .{name}), .{ .root_source_file = spv });
    }
}

fn linkSdl(mod: *std.Build.Module, sdl_lib: ?*std.Build.Step.Compile) void {
    if (sdl_lib) |lib| mod.linkLibrary(lib) else mod.linkSystemLibrary("SDL3", .{});
}
