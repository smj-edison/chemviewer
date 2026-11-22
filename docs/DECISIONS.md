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
alpha-to-coverage when MSAA is available. The dark theme remains an option.
*Revised (kurzgesagt-style branch):* smooth (Blinn-Phong) shading is removed;
see D18.

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
On Wayland SDL serves clipboard data lazily, when another app asks for it.
On the user's compositor SDL 3.4 also cancels its own clipboard data right
after taking ownership (calling the cleanup callback) while it keeps serving
paste requests. So the copied text lives in a C-allocated buffer that is only
replaced by the next copy, and the cleanup callback deliberately does nothing.
Freeing on cleanup, or using `SDL_SetClipboardText` (whose internal copy is
freed the same way), pasted allocator garbage into other apps.

### D16 — Lasso on Ctrl+drag; Ctrl+A grows the selection
Left, right and middle drags are taken by the GaussView camera controls, so
the lasso is Ctrl + left drag (Ctrl+Shift removes). It selects by projected
atom centre, so hidden atoms behind others are included. Molecule selection
is Ctrl+A rather than double-click: it grows the selection to the whole
molecules of the selected atoms (via drawn, uncut bonds), and a second press
selects everything.

### D17 — Alt turns camera gestures into fragment gestures
As in GaussView, holding Alt applies the mouse to atoms instead of the camera:
left drag rotates, right drag twists, middle (or Shift + left/right) translates. The
moving group (`drag.chooseGroup`): grabbing a selected atom moves the whole
selection as one rigid body about its centre (a single selected atom brings its
molecule). With exactly one atom selected (the base), grabbing an unselected
atom moves everything reachable from it *without passing through* the base
(`geometry.beyond`), around the base. Otherwise the grabbed atom's molecule
moves about its centre. An earlier rule made the first selected atom the base
of any multi-selection. It was dropped because it left that atom behind when
moving a pasted (fully selected) fragment. Groups that bonds can't separate can
get an explicit pivot later if needed.
Blocking the base atom, instead of cutting the base–grabbed bond as the
coordinate edits do, makes grabbing *any* atom of a branch move the whole
branch. In rings the rest of the ring swings about the base, with distances to
the base preserved. With a base atom, the grabbed atom follows the cursor on
its sphere around the base, keeping to the hemisphere it started on.
Positions are recomputed from the drag-start snapshot every motion, so there
is no drift. The whole drag is one undo entry.

### D18 — Theme and style are independent; flat style
Display has two independent choices. The theme (light/dark) owns the
background, bond palette, accents and UI colours. The style (cel/flat) owns
shading, drop shadows, depth fade and atom size. Element colours are the same
everywhere: familiar hues (red O, blue N, green halogens, yellow S, orange P,
gold Au) with teal carbon, the hue CPK leaves free (in the Jmol/GaussView
scheme only noble gases and the 4d metals use it; here those get muted
colours). Their lightness is
spread so bonded pairs stay distinguishable under simulated colour-vision
deficiencies. The flat style, inspired
by Kurzgesagt's flat illustrations, draws solid-colour atoms with highlight
dots, no outlines, flat drop shadows and a depth fade toward the background. Smooth shading was
dropped: cel and flat cover what it offered. The light background is a
low-chroma blue-grey, and both bond palettes move monotonically away from the
background (see docs/BONDS.md and docs/style-refs/kurzgesagt/README.md).

### D19 — Colour shows the family; labels resolve look-alikes
No palette can give ~100 elements distinguishable colours: people tell apart
roughly a dozen at a glance, fewer with colour-vision deficiencies. Even
GaussView/Jmol's full table only encodes the family, with near-identical
neighbours (Ru/Rh, the lanthanides). So: the familiar elements and a few
catalysis metals (Cu, Ag, Pt, Au) get hand-picked colours; every other
element gets a muted colour for its family, so it can't pass for C, N or O.
Identity is then resolved per structure: if two elements present could be
mistaken for each other (worst-case OKLab distance below 0.07 across normal
vision and simulated protanopia, deuteranopia and tritanopia), the rarer
one's atoms get their element symbol drawn on them. A lone rare element is
not labelled (the inspector's element key names it), and H/C/N/O never
trigger labels against the everyday organic elements (unit-tested), so
labels stay rare and clutter stays low.

### D20 — Vulkan instead of OpenGL
OpenGL is deprecated on macOS and frozen everywhere; the renderer moved to
Vulkan 1.3 with vulkan-zig's generated bindings (D1's OpenGL part is
superseded). Choices that keep it small:
- **Bindings from a pinned registry.** vulkan-zig (its `zig-0.17-compat`
  branch) generates `vk.zig` from `vk.xml` in a pinned Vulkan-Headers
  package, whose C headers also build ImGui's Vulkan backend. Entry points
  come from SDL's loader (`SDL_Vulkan_GetVkGetInstanceProcAddr`), so nothing
  links libvulkan.
- **Vulkan 1.3 core features:** dynamic rendering (no render pass or
  framebuffer objects), synchronization2, and dynamic cull mode / depth
  writes, so one pipeline covers a shader's draw, outline and translucent
  variants that differ only in that state. Blend modes still need their own
  pipelines (none, alpha, multiply for flat shadows).
- **OpenGL conventions kept.** The camera still builds OpenGL projection
  matrices; vertex shaders remap clip z to [0, w], and the scene viewport has
  a negative height so NDC y points up and the winding (CCW front faces, the
  outline hulls' front-face culling) is unchanged. The backdrop cache is drawn
  with a normal viewport, so the blit samples it the same way up.
- **Frames in flight:** two. Uniforms and instance buffers are per frame
  slot; `upload` snapshots the scene and each slot copies it the next time it
  draws, so a frame still on the GPU never sees a half-written buffer. All
  buffers are host-visible (scenes are small next to what the GPU can read
  over the bus). Shared targets (MSAA colour, depth, backdrop cache) need no
  copies: barriers order frames on the one queue.
- **4x MSAA always**, resolved into the swapchain image at the end of the
  scene pass; ImGui draws in a second, single-sampled pass on top.
  Swapchain format is UNORM, as the shaders write sRGB-encoded colours (as
  they did into OpenGL's default framebuffer).
- **Shaders** are GLSL 450 files compiled to SPIR-V by `glslc` at build time
  and embedded. Compiling GLSL in Zig (glslang from source) would avoid the
  external tool but adds a large C++ build; shaderc ships with every Vulkan
  SDK and distribution.
- **ImGui's Vulkan backend** keeps C++ linkage (it overloads a function, which
  cimgui's `extern "C"` mode can't express) and is reached through a small C
  wrapper (`cshim/imgui_vulkan.cpp`) that takes raw handles.
- **Screenshots** copy the swapchain image to a host buffer; `--profile` uses
  timestamp queries, read back when a frame slot comes round again.

### D21 — Lock rotation moves the camera, not the atoms
"Lock rotation" keeps a structure's orientation steady across frames. The
frame's coordinates are left alone: picking, measuring, editing and saving
all keep working on the file's coordinates. Instead the camera follows each
frame's rigid motion. When the lock is switched on, the displayed frame
becomes the anchor. Each newly shown frame is superposed onto it (Horn, as
in diffing), and the camera turns by the motion between the frame it was
following and the new one (`Camera.followRigid`). Because every frame is
measured against the same anchor, a frame looks the same however you got to
it (scrubbing, stepping, playback), and the user's own rotations in between
are kept. The backdrop pattern gets the same correction, so the scene as a
whole stays still. A frame with different atoms restarts the lock there.

### D22 — Glass style: translucent atoms and bonds drawn in layers
A fourth style (experimental, `--glass`), inspired by Apple's "Liquid Glass":
atoms and bonds are tinted glass that refracts what is behind them, filtered
by their colour, with a bright rim on the lit side, a tinted glow opposite
it, a Fresnel sheen and slight dispersion (shaders/glass.glsl). Atoms are
1.2x larger so the refraction shows. Faint (alpha-blended) contacts stay as
they are and refract only the backdrop.
- **Refraction samples a copy of the scene.** A shader can't read the target
  it draws into, so before glass is drawn the MSAA scene is resolved into
  `Gpu.scene_copy` (`snapshotScene`: end the pass, resolve, resume with load
  ops). The backdrop cache is always kept for the same reason, holding the
  plain background when the pattern is off.
- **Layers instead of one snapshot per object.** Glass only needs what is
  behind it that it overlaps on screen. Every atom and bond is a screen-space
  capsule (an atom has zero length); on the CPU, going from far to near, each
  goes one layer above the farthest-placed capsules it overlaps (a grid of
  screen cells finds them; src/render/glass_layers.zig, unit-tested), so
  objects sharing a layer never overlap and one snapshot per layer is exact.
  This reruns only when the view or the scene changes. Bonds sort by their
  midpoint, so they usually fall between their two atoms; split into halves
  they would sort more finely, but the second half refracts the first one's
  open end, leaving a dark notch. The cap is 24 layers (a 77-atom complex
  needs about 22; deeper objects share the last layer and hide what they
  overlap); above 40000 objects there are two layers, bonds then atoms.
  Depth peeling or order-independent transparency would avoid the CPU sort
  but can't refract: they blend, they don't bend what is behind.
- **Cost.** Each snapshot resolves only the screen rectangle its layer
  covers, widened by how far refraction can reach, and while glass pauses the
  pass the resolve into the swapchain image happens once at the end instead
  of at every pause. That took a 22-layer frame from 8 ms to 1 ms at 1080p on
  an Intel Xe iGPU (cel: 0.25 ms). The MSAA colour and depth targets are no
  longer transient (lazily allocated memory on tilers), as glass stores and
  reloads them mid-frame; other styles still discard them after the resolve.

### D23 — Liquid glass: per-atom blobs from a smooth union
Glass's "Liquid" option (on by default; `--no-liquid` turns it off) makes
bonds flow into the atoms like drops of glass. Each atom is drawn as one
ray-marched blob (shaders/liquid.frag): the smooth union of its sphere, its
bonds as capsules and its bonded neighbours' spheres, with colours blended by
the same weights.
- **Seamless blobs.** A blob only draws surface on its side of each bond: a
  plane across the middle of the gap between the two spheres. The neighbour
  draws the rest from the same field, so the union of the blobs is one
  surface with no internal faces. Both sides must compute the same field near
  the plane, so the smooth union is the exponential one (log-sum-exp), which
  doesn't depend on the order primitives are combined in. The common
  polynomial smin does, and two blobs would disagree slightly at the seam.
  Each blob leaves out its neighbours' other bonds; their weight at the plane
  is about e^-6, far below a pixel.
- **Glass layers per blob.** Each blob is one object in the glass layering
  (D22), with its bounding sphere as its disc; there are no separate bond
  objects. Refraction fades out toward the ownership planes: the blob drawn
  second would otherwise refract its neighbour's glass right beside it and
  show a tinted seam.
- **Cost.** Rays are first tested analytically against every primitive,
  inflated by the most the union can swell it (k ln N), so the empty space
  between bonds in a blob's bounding circle costs nothing, and the march
  starts at the surface. That brought a 77-atom complex from 6 ms to 2.8 ms
  per frame at 1080p on an Intel Xe iGPU (non-liquid glass: 1 ms).
  Per-atom links (neighbour, bond radius and colour, plane) live in a storage
  buffer per frame slot (binding 3).
- **Limits.** Faint (alpha-blended) contacts stay as separate rods, so metal
  clusters drawn with weak contacts look like non-liquid glass.

