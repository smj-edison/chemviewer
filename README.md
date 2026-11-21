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
- **Measure and edit.** Click up to four atoms to get a distance, angle or
  dihedral in the bottom bar. Copy it, or type a new value (degrees or
  radians for angles): the attached group moves with it, Chemcraft-style.
  Edits are per frame, undoable, and can be saved as XYZ.
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

Other flags: `--no-ui` (molecule only, e.g. for figures), `--dark`,
`--ui-scale X`.

Scripted edits (atom numbers are 1-based; values in Å or degrees):

```sh
# stretch the C1–C2 distance to 1.8 Å and save the result
zig-out/bin/chemviewer mol.xyz --select 1,2 --set 1.8 --save stretched.xyz
# set a dihedral, then take a picture
zig-out/bin/chemviewer mol.xyz --select 3,1,2,6 --set 75 --screenshot dih.png
```

## Controls

| Input | Action |
|---|---|
| Left click | select / deselect atom (up to 4); click empty space to clear |
| Left drag | rotate |
| Right drag ← → | rotate about the viewing axis |
| Right drag ↑ ↓ | zoom (up = closer) |
| Middle drag / Shift + left drag | translate |
| Wheel | zoom |
| Space | play / pause |
| ← → keys or , . | previous / next frame |
| PgUp / PgDn | jump 5% |
| Home / End | first / last frame |
| F | fit to view |
| Esc | clear selection |
| Ctrl+Z | undo geometry edit |
| Ctrl+S | save current frame (with edits) as XYZ |
| Ctrl+O | open file (or drop a file on the window) |

## Layout

See [docs/PLAN.md](docs/PLAN.md) for the architecture and roadmap, and
[docs/DECISIONS.md](docs/DECISIONS.md) for why things are the way they are.
