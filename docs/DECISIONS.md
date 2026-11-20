# Decisions log

Short records of choices that shape the code, newest last.

### D1 — SDL3 + OpenGL 3.3 + Dear ImGui (cimgui)
SDL3 handles windowing, input, the GL context and native file dialogs, all
through a plain C API. Dear ImGui is the de-facto immediate-mode GUI. It's C++,
but cimgui wraps it in a C ABI, and Zig's toolchain compiles the C++ without
trouble. The alternatives were raylib + raygui (simpler, but weaker UI widgets
and less rendering control) and Nuklear (pure C, but a less capable UI). Both
were rejected. OpenGL 3.3 is enough for instanced impostor rendering and
runs on Linux, Windows and (deprecated but working) macOS.

### D2 — Pinned C/C++ sources via `build.zig.zon`
cimgui and imgui are fetched by hash and compiled by `build.zig`: no system
package, no git submodules. cimgui is pinned to a commit whose generated bindings
match the pinned imgui commit (cimgui's `imgui` submodule pointer). To upgrade,
bump both together. SDL3 is currently a **system** library (`pkg-config sdl3`).
A Windows build will switch to a vendored SDL3 package.

### D3 — translate-c in the build graph
All C headers are included from `src/c.h` and translated once by
`b.addTranslateC`. Zig code imports the result as `@import("c")`.

### D4 — Core module is pure Zig
`src/root.zig` (module name `chemviewer`) contains formats, structure, bonds
and alignment. It has no C dependencies, so tests run fast and headless.

### D5 — All file access through `std.Io`
Files are opened with `Io.Dir.openFile`, read with `File.readPositionalAll` /
`File.Reader`, and concurrency uses `io.concurrent`, `Io.Queue`, `Io.Mutex` and
`Io.Event`. No `std.posix`, which keeps Windows reachable. Parsers take byte
slices or `*Io.Reader`, not files, so they're trivially testable.

### D6 — Positions are f32 in memory, f64 while parsing
Double precision matters for parsing and alignment math. For display and cache
footprint, f32 is plenty: a 10⁶-atom frame is 12 MB instead of 24 MB.
Alignment converts to f64 internally.

### D7 — ASE .traj = ULM v3 only
The modern ASE trajectory format is ULM (`- of Ulm` magic). The legacy
pickle-based `.traj` from ASE < 3.10 is not supported. Frame 0 carries
`numbers`, `pbc` and `cell`; later frames inherit them unless overridden.

### D8 — Stream requests use a "latest wins" slot, not a queue
`FrameStream` keeps one `wanted` index under an `Io.Mutex` and wakes the
worker with an `Io.Condition`. When scrubbing, only the newest position
matters, and a queue (`Io.Queue`) would pile up stale requests. The worker
serves, in order: the wanted frame, prefetch in the scrub direction, then a
background energy scan (`Source.loadEnergy` reads only metadata, e.g. a traj
item's JSON). Shutdown is `Future.cancel`: the worker's `Condition.wait` is
the cancelation point.
