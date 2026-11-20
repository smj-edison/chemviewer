# chemviewer

A fast molecular structure and trajectory viewer written in Zig, with SDL3,
OpenGL 3.3 and Dear ImGui (via cimgui) doing the heavy lifting.

- **No bond guessing.** Every pair that *could* be bonded gets a link,
  coloured by a continuous bond character (0 → single → double → triple)
  based on per-pair Pyykkö reference lengths. See [docs/BONDS.md](docs/BONDS.md).
- **Instant scrubbing.** A timeline with an energy plot you can click or drag.
  Large trajectories are streamed from disk with background prefetch.
- **Diffing.** Superimpose the current frame onto a reference frame
  (Horn/Kabsch), with a red/green overlay, RMSD and max deviation.
- **Formats:** XYZ / extended XYZ, Gaussian input (`.gjf`/`.com`) and output
  (`.log`), ORCA input (`.inp`) and output (`.out`), ASE trajectories (`.traj`).

## Build & run

Requires Zig 0.17 and SDL3 (system package, found via pkg-config). Dear ImGui
and cimgui are fetched and compiled automatically.

```sh
zig build run -- path/to/file.log              # open a file
zig build -Doptimize=ReleaseFast               # optimised build → zig-out/bin/
zig build test                                 # core unit tests (headless)
zig build inspect -- file1.xyz file2.traj      # headless summary of files
```

Headless rendering (for CI or quick checks):

```sh
SDL_VIDEO_DRIVER=offscreen zig-out/bin/chemviewer traj.traj \
    --frame 120 --diff-ref 1 --screenshot out.png --size 1400x900
```

## Controls

| Input | Action |
|---|---|
| Left drag | rotate |
| Right drag / Shift + left drag | pan |
| Wheel | zoom |
| Space | play / pause |
| ← → or , . | previous / next frame |
| PgUp / PgDn | jump 5% |
| Home / End | first / last frame |
| F | fit to view |
| Ctrl+O | open file (or drop a file on the window) |

## Layout

See [docs/PLAN.md](docs/PLAN.md) for the architecture and roadmap, and
[docs/DECISIONS.md](docs/DECISIONS.md) for why things are the way they are.
