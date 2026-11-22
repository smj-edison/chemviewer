const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
            "imgui/backends/imgui_impl_opengl3.cpp",
        },
        .flags = &.{
            "-DIMGUI_IMPL_API=extern \"C\"",
            "-DCIMGUI_USE_SDL3",
            "-DCIMGUI_USE_OPENGL3",
            "-fno-exceptions",
            "-fno-rtti",
        },
    });
    imgui_mod.addIncludePath(b.path("src/cshim"));
    imgui_mod.addCSourceFiles(.{ .root = b.path("src/cshim"), .files = &.{"imgui_shim.c"} });
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
        },
    });
    linkSdl(exe_mod, sdl_lib);
    exe_mod.linkLibrary(imgui_lib);

    const exe = b.addExecutable(.{ .name = "chemviewer", .root_module = exe_mod });
    b.installArtifact(exe);

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

fn linkSdl(mod: *std.Build.Module, sdl_lib: ?*std.Build.Step.Compile) void {
    if (sdl_lib) |lib| mod.linkLibrary(lib) else mod.linkSystemLibrary("SDL3", .{});
}
