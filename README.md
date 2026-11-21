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
- **Measure and edit.** Click two to four atoms to get a distance, angle or
  dihedral in the bottom bar. Type a new value (degrees or radians for
  angles) and the attached group moves with it, Chemcraft-style. Edits are per
  frame, undoable, and can be saved as XYZ.
- **XYZ clipboard.** Ctrl+C copies the selected atoms (or the whole frame) as
  XYZ, with the source in the comment line. Ctrl+V pastes XYZ, bare
  `El x y z` lines, or a Gaussian/ORCA input into the current structure as a
  new fragment (Ctrl+Shift+V opens it as a new structure instead).
- **Drag fragments (GaussView-style Alt).** Select a base atom, then Alt+drag
  any atom past it: that branch swings around the base atom, with the grabbed
  atom following the cursor. Alt+right drag twists it about the base→grabbed
  axis; Alt+middle (or Alt+Shift+left) drag translates. Without a base atom the
  grabbed atom's molecule moves; with several atoms selected, the selection
  moves. Each drag is one undoable edit; Esc cancels.
- **Cut bonds.** Double-click a bond (or click it and press X) to cut it. It stays drawn (thin, red),
  but edits and molecule selection treat the two sides as separate, so you can
  move part of a ring or a ligand freely.
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

Other flags: `--no-ui` (molecule only, e.g. for figures), `--dark`, `--atom-numbers`,
`--ui-scale X`.

Scripted edits (atom numbers are 1-based; values in Å or degrees):

```sh
# stretch the C1–C2 distance to 1.8 Å and save the result
zig-out/bin/chemviewer mol.xyz --select 1,2 --set 1.8 --save stretched.xyz
# set a dihedral, then take a picture
zig-out/bin/chemviewer mol.xyz --select 3,1,2,6 --set 75 --screenshot dih.png
# add a fragment, cut a ring bond, then stretch: the cut side moves as a group
zig-out/bin/chemviewer ring.xyz --add ligand.xyz --cut 4,5 --select 1,2 --set 2.0 --save out.xyz
```

## Controls

| Input | Action |
|---|---|
| Left click | select / deselect an atom; on a bond: select just the bond; empty space: clear |
| Alt + left drag on an atom | rotate its group around the selected base atom (or its molecule about its centre) |
| Alt + right drag | twist the group about the base→grabbed axis |
| Alt + middle drag / Alt + Shift + left drag | translate the group |
| Ctrl + left drag | lasso: add atoms inside (including hidden ones) |
| Ctrl + Shift + left drag | lasso: remove atoms inside |
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
| Esc | cancel a fragment drag, else clear selection |
| Ctrl+A | grow selection to whole molecules; again: select all |
| Ctrl+C | copy selection (or whole frame) as XYZ |
| Ctrl+V | paste XYZ / coordinates as a fragment into the current structure |
| Ctrl+Shift+V | paste as a new structure |
| X / double-click a bond | cut / restore the bond (ignored when moving groups) |
| N | show / hide atom numbers |
| Ctrl+Z | undo geometry edit |
| Ctrl+S | save current frame (with edits) as XYZ |
| Ctrl+O | open file (or drop a file on the window) |

## Layout

See [docs/PLAN.md](docs/PLAN.md) for the architecture and roadmap, and
[docs/DECISIONS.md](docs/DECISIONS.md) for why things are the way they are.
