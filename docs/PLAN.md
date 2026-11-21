# chemviewer — Plan

A fast, opinionated molecular structure / trajectory viewer written in Zig.
This is the working plan; it's meant to change as the project evolves. Decisions
that are settled are recorded in [DECISIONS.md](DECISIONS.md).

## Goals

1. **Don't assume bonds.** Draw a link between every pair that *could* be bonded,
   coloured by a continuous "bond character" derived from the distance relative
   to the typical single/double/triple lengths *for that specific element pair*.
   See [BONDS.md](BONDS.md).
2. **Fast scrubbing.** There's a timeline at the bottom. Dragging it has to feel
   instant, even for large trajectories that don't fit in memory.
3. **Molecule diffing.** Find the best rigid transform to superimpose two
   structures, then show where they differ (reference tinted red, target tinted
   green, per-atom deviation readout).
4. **Portable I/O.** All file and concurrency work goes through `std.Io`
   (`Io.Dir`, `Io.File`, `io.concurrent`, `Io.Mutex`, `Io.Condition`, …) with no
   direct posix calls, so a Windows build stays possible.

## Non-goals (for now)

- Editing structures, building molecules, or running calculations.
- Volumetric data (cube files, orbitals). This might come later.
- Reading anything except geometry (and energy, where it's easy) from QM outputs.

## Stack

| Concern | Choice | Why |
|---|---|---|
| Language | Zig 0.17 | Requested. Core logic in Zig, C only at the edges. |
| Window / input / GL context / file dialogs | **SDL3** (system lib for now) | Common, mature, cross-platform, has native file dialogs (`SDL_ShowOpenFileDialog`). |
| Immediate-mode UI | **Dear ImGui** via **cimgui** (pinned, built from source by `build.zig`) | The standard immediate-mode GUI. cimgui gives it a C ABI, so Zig only ever sees C. |
| 3D rendering | **OpenGL 3.3 core**, with a small loader we write ourselves (`src/render/gl.zig`) | Works everywhere. Ray-cast impostors scale to 10⁵–10⁶ atoms. |
| C bindings | `b.addTranslateC` on `src/c.h` | `@cImport` is on its way out. Doing it in the build system is the 0.17 way. |

## Architecture

```
src/
  root.zig            "chemviewer" core module: no GUI, no C. Fully unit-tested.
  core/
    math.zig          Vec3 / Mat3 / Mat4 / Quat
    elements.zig      element table: symbols, colours, display radii, Pyykkö covalent radii (1/2/3)
    structure.zig     Frame (positions, atomic numbers, optional cell, energy, comment)
    bonds.zig         spatial-hash neighbour search + continuous bond character
    align.zig         optimal superposition (Horn quaternion), RMSD, per-atom deviation
  formats/
    text.zig          line iteration / float parsing shared by the text parsers
    xyz.zig           multi-frame XYZ (+ extended-XYZ Lattice/energy), Indexed random access
    gaussian.zig      .gjf/.com input, .log output (Input orientation, SCF/Recovered energies)
    orca.zig          .inp input (`* xyz`, `* xyzfile`), .out output (all geometries, energies)
    traj.zig          ASE .traj (ULM) reader, random access, no full load
  source.zig          format detection + Source union: "N frames, give me frame i"
  stream.zig          FrameStream: background loader, LRU cache, energy scan (io.concurrent)
  testdata/           small ASE-generated fixtures for the traj tests
  main.zig            GUI entry point: SDL + GL + ImGui setup, main loop, --screenshot
  app/
    App.zig           application state, document lifecycle, inspector + diff panels, input
    timeline.zig      bottom timeline (transport, frame slider, energy envelope plot)
    ui.zig            cimgui helpers (formatted text, gradient legend)
  render/
    gl.zig            GL 3.3 function loader (via SDL_GL_GetProcAddress)
    shaders.zig       GLSL sources
    Renderer.zig      atoms (sphere impostors), bonds (instanced cylinders), cell edges
    Camera.zig        orbit / pan / zoom, auto-fit
  cshim/              C helpers for ImGui calls translate-c can't express (see D9)
  tools/inspect.zig   headless summary tool (`zig build inspect -- FILE`)
```

The **core module** (`src/root.zig`) never touches C or the GPU. It can be tested
with `zig build test` and could be reused as a library, for example in a CLI
converter.

### Frame sources and streaming

Every file type implements the same interface:

```zig
Source {
    frameCount() usize
    loadFrame(io, gpa, index) !Frame   // thread-safe, positional reads only
}
```

- **In-memory** (Gaussian/ORCA outputs, small inputs): parse all frames up front.
- **XYZ, indexed**: one pass records the byte offset of every frame. Frames are
  parsed on demand with `File.readPositionalAll`, so a multi-GB XYZ costs
  O(frames) memory.
- **ASE .traj (ULM)**: the file already has an offset table, so opening it is
  O(1) and a frame is one JSON block plus one positional array read. Atomic
  numbers, cell and pbc come from frame 0 (ASE only rewrites them when they
  change), and later frames inherit them.

`FrameStream` sits on top of this. The UI thread asks for frame *i* and gets it
back immediately if it's cached. If it isn't, the request is placed in a
"latest wins" slot (D8) read by a worker started with `io.concurrent`. The UI keeps showing
the last frame it had until the new one arrives. When the playhead moves, the
worker prefetches nearby frames in the scrub direction, and an LRU bounded by
bytes (not frame count) evicts old ones. Scrubbing never blocks the render loop.

### Rendering

- Atoms are camera-facing quads. The fragment shader ray-casts a sphere, which
  gives exact per-pixel depth and normals. That means perfect spheres at any
  zoom, 4 vertices per atom, and one instanced draw call.
- Bonds are an instanced low-poly cylinder mesh, with per-instance endpoints,
  radius, and the two colours at its ends (half-bond colouring, or the gradient
  colour). The shader handles the gradient, so styles change without CPU work.
- Instance buffers are rebuilt only when the frame or style changes.
- Planned: impostor cylinders, SSAO / outlines for depth cues, picking via an ID
  buffer.

## Roadmap

### Phase 1 — Skeleton viewer (MVP)
- [x] Build: SDL3 + cimgui/imgui compiled from pinned sources, translate-c bindings
- [x] Core types, element table, math
- [x] XYZ (multi-frame, indexed), Gaussian in/out, ORCA in/out, ASE .traj readers, with tests
- [x] Continuous bond-character detection with per-pair Pyykkö reference lengths
- [x] Sphere impostors + instanced bond cylinders, arcball camera
- [x] Timeline with scrubbing, play/pause, speed, and an energy sparkline when energies are present
- [x] Background frame streaming + LRU cache
- [x] Open files from the CLI or the SDL file dialog
- [x] Diff MVP: superimpose two frames with the same atom ordering, red/green overlay, RMSD

### Phase 2 — Make it pleasant
- [ ] Interactive smoke test on a real display (so far only verified headless via `--screenshot`)
- [ ] Move bond search to the worker for big frames (27k atoms is fine on the UI thread; 10⁶ is not)
- [x] Atom picking: click to measure distance, angle, dihedral; edit them Chemcraft-style (group moves), undo, save XYZ
- [ ] Hover tooltip with atom info; measurement labels in the viewport
- [ ] Bond gradient editor (colour stops, cut-off, "show only ≥ single"), saved to a config file
- [ ] Representation presets: ball & stick, licorice, space-filling, wire
- [ ] Periodic cells: draw images, wrap atoms, bonds across boundaries (minimum image)
- [x] Outlines (cel shading), light/dark themes
- [ ] Depth cueing / SSAO
- [ ] Persist settings (window layout, style) via `Io.Dir` in the platform config dir
- [x] Drag-and-drop files (SDL drop events)

### Phase 3 — Diffing proper
- [ ] Diff two *files*, not just two frames of one file
- [ ] Unknown correspondence: element-constrained Hungarian assignment + iterative
      re-alignment (ICP-style), with symmetry and permutation handling
- [ ] Weighted / subset alignment (align on selection, e.g. backbone only)
- [ ] Deviation heat-map colouring; diff against a sliding reference frame in a trajectory

### Phase 4 — Scale
- [ ] Bond search on the worker thread for 10⁶ atoms; incremental neighbour lists across frames
- [ ] Impostor cylinders; GPU-side culling / LOD
- [ ] Memory-mapped XYZ (`File.createMemoryMap`) as an alternative to positional reads
- [ ] Windows build: a vendored SDL3 package instead of the system lib, then CI

### Later / ideas
- More formats: PDB/mmCIF, POSCAR/CONTCAR, extended XYZ properties, Gaussian Z-matrix, ORCA `.xyz` trajectories
- Vibrational modes from Gaussian/ORCA outputs (animated)
- Colour by property (forces, charges, per-atom energies from .traj calculator data)
- Export screenshots / movies
