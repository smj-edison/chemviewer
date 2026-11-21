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

### D9 — C shim for ImGui context / IO
translate-c demotes `struct ImGuiContext` to an opaque type (one of its fields
can't be translated) but still emits `[*c]ImGuiContext` pointers, which Zig
rejects. Any Zig reference to `igCreateContext`, `igGetIO`, or `ImGuiIO` fails to
compile. `src/cshim/imgui_shim.c` wraps the few calls we need
(`cvImGuiCreateContext`, `cvImGuiWantCaptureMouse`, …). The rest of the cimgui
API is used directly. Revisit when translate-c handles this.

### D10 — Headless screenshots for verification
`--screenshot` renders the requested frame (optionally with a diff reference)
and writes a PNG via SDL's encoder and `Io.Dir.writeFile`. With
`SDL_VIDEO_DRIVER=offscreen` this needs no display, so rendering can be
checked from CI or a sandbox.

### D11 — UI scale = content scale only
SDL's display scale is pixel density × content scale. The ImGui SDL3 backend
already handles pixel density (framebuffer scale, fonts rasterised at full
resolution), so the style and fonts are scaled by the content scale only, times
a user "UI scale" from the View menu. Scaling by the full display scale made
the UI 1.5× too large on Wayland at 150%. Panel sizes are in multiples of the
font size, and panels are re-placed when the scale changes.

### D12 — Perceptual bond palette (OKLCh) with snapping
Bond colours are interpolated in OKLCh, with lightness strictly increasing in
bond character, from the background (transparent) to bright triple bonds. A soft
staircase (`color.snap`) pulls colours toward whole bond orders without making
the mapping discrete. See docs/BONDS.md.

### D13 — Light theme and cel shading by default
The default look is a light theme with cel shading: three flat lighting bands
(anti-aliased with `fwidth`), no specular highlights, and dark outlines of
constant screen width. Sphere outlines are a slightly larger concentric sphere
ray-cast in the same impostor pass. Bond outlines are an "inverted hull"
(inflated cylinders, back faces only), weighted per bond by its character so
outlines fade in and out with forming and breaking bonds. Outline width is given in logical
pixels and multiplied by the pixel density. Sphere silhouettes use
alpha-to-coverage when MSAA is available. Smooth (Blinn-Phong) shading and
the dark theme remain options.

### D14 — Editing internal coordinates moves groups
Setting a distance, angle or dihedral moves the moving atom's whole group:
everything attached to it once the mover–pivot bond is cut. Connectivity is
exactly the set of *drawn* bonds (`Renderer.isDrawn`: "Hide below" and
"Cut-off"), minus bonds the user cut (X), so what moves together is what
looks connected. "Hide below"
defaults to 0.25 so near-invisible contacts don't tie groups together. If the two atoms aren't bonded, the mover's whole molecule
moves, so pulling two fragments apart is one edit. If the group can't be split
off (rings, or non-bonded atoms in the same molecule), only the atom moves.
"Both sides" applies half the change to each side. Dihedrals rotate about the
B–C axis. The logic lives in `core/geometry.zig` and is unit-tested against
known geometries.

Edits are stored per frame and replace the file's frame whenever it's shown.
The frame's energy is dropped, since it no longer describes the geometry. Undo
restores positions, and edited frames can be saved as XYZ (Ctrl+S). The same
path can be scripted from the CLI (`--select`, `--set`, `--save`), which is how
it's verified headlessly.

### D15 — XYZ is the clipboard format
Ctrl+C writes the selection (or the whole frame) as XYZ. The comment line
holds `key=value` provenance (`source=`, `frame=`, `atoms=` as 1-based ranges,
`frame_energy=` for partial copies, `edited=T`). The `energy=` key is written
only for whole frames, so it never misdescribes a fragment. Ctrl+V accepts
XYZ, bare `El x y z` lines (optionally with Gaussian freeze flags), or
Gaussian/ORCA inputs. By default it appends them to the current frame as a
fragment (an undoable edit that becomes the selection; moved beside the
structure if it would overlap). Ctrl+Shift+V opens them as a new structure.
Undo therefore snapshots whole frames, since a paste changes the atom count.
ImGui keyboard navigation is off, and app shortcuts yield only while a text
field is being edited (`WantTextInput`), so focusing a panel doesn't swallow them.
