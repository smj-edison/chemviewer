# chemviewer

A fast molecular structure and trajectory viewer written in Zig, with SDL3,
Vulkan (via [vulkan-zig](https://github.com/Snektron/vulkan-zig)) and Dear
ImGui (via cimgui) doing the heavy lifting.

- **No bond guessing.** Every pair that *could* be bonded gets a link,
  coloured by a continuous bond character (0 → single → double → triple)
  based on per-pair Pyykkö reference lengths. See [docs/BONDS.md](docs/BONDS.md).
- **Colour-blind-aware colours.** Bond order reads from lightness alone, so it
  survives greyscale printing and any colour vision. Element colours stay
  distinct under simulated colour blindness; when two elements in a structure
  could still be mistaken for each other, the rarer one is labelled with its
  symbol (View > Element labels). The inspector shows an element key.
- **Instant scrubbing.** A timeline with an energy plot you can click or drag.
  Large trajectories are streamed from disk with background prefetch.
  **Lock rotation** (next to Loop) turns the view with each frame so a
  tumbling structure keeps its orientation: every frame is superposed onto
  the frame shown when the lock was switched on, as in diffing.
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
- **Drag fragments (GaussView-style Alt).** Alt+drag a selected atom to move
  the whole selection (rotate about its centre, twist, translate). With a
  single base atom selected, Alt+drag any other atom and the branch beyond the
  base swings around it, with the grabbed atom following the cursor. Alt+right
  drag twists; Alt+middle (or Alt+Shift+left/right) drag translates. With nothing
  selected the grabbed atom's molecule moves. Each drag is one undoable edit;
  Esc cancels.
- **Cut bonds.** Double-click a bond to cut it (and again to restore it). It stays drawn (thin, red),
  but edits and molecule selection treat the two sides as separate, so you can
  move part of a ring or a ligand freely.
- **Formats:** XYZ / extended XYZ, Gaussian input (`.gjf`/`.com`) and output
  (`.log`), ORCA input (`.inp`) and output (`.out`), ASE trajectories (`.traj`).

## Build & run

Requires Zig 0.17, a Vulkan 1.3 driver, and `glslc` (the shader compiler from
shaderc: the `shaderc` package on Arch/Homebrew, `glslc` on Debian/Ubuntu, or
the LunarG Vulkan SDK on Windows and macOS). Point the build at another
compiler with `-Dglslc=PATH`. On macOS, Vulkan runs on Metal through MoltenVK
(`brew install molten-vk`, or the Vulkan SDK). Dear ImGui, cimgui, the Vulkan
headers and the vulkan-zig bindings are fetched and compiled automatically.
Debug builds turn on the Khronos validation layer when it is installed.
SDL3 comes from:

- **macOS / Linux:** the system package, found via pkg-config
  (`brew install sdl3 pkgconf`, or your distro's `sdl3` dev package).
- **Windows:** built from source automatically (statically linked; nothing to
  install).

Pass `-Dsystem-sdl=false` to build SDL3 from source on any platform, or
`-Dsystem-sdl=true` to use an installed one on Windows. Cross-compiling works
too, e.g. `zig build -Dtarget=x86_64-windows-gnu`.

```sh
zig build run -- path/to/file.log              # open a file
zig build -Doptimize=ReleaseFast               # optimised build → zig-out/bin/
zig build test                                 # core unit tests (headless)
zig build inspect -- file1.xyz file2.traj      # headless summary of files
```

Install on Arch Linux (program, desktop entry, icons and file types). The
package builds the latest commit on GitHub; run the same command again to
upgrade:

```sh
cd packaging/aur && makepkg -Csi
```

On other Linux systems, `zig build -Doptimize=ReleaseFast --prefix ~/.local`.

Windows and macOS packages are written to the install prefix. Windows ones can
be built on any system, macOS ones only on a Mac (SDL needs Apple's SDK):

```sh
zig build -Dtarget=x86_64-windows-gnu -Dcpu=baseline -Doptimize=ReleaseFast -Dpackage=portable   # .zip
zig build -Dsystem-sdl=false -Dcpu=baseline -Doptimize=ReleaseFast -Dpackage=portable            # .app in a .zip
```

`-Dpackage=installer` makes a per-user setup program (needs NSIS's `makensis`)
or a `.dmg` instead; `-Dversion=X.Y.Z` sets the version. The GitHub workflow
`package.yml` builds them all; pushing a `v*` tag puts them on a draft release.
They are not signed by a paid certificate, so Windows SmartScreen and macOS
Gatekeeper warn on first launch.

Headless rendering (for CI or quick checks):

```sh
SDL_VIDEO_DRIVER=offscreen zig-out/bin/chemviewer traj.traj \
    --frame 120 --diff-ref 1 --screenshot out.png --size 1400x900
```

Other flags: `--no-ui` (molecule only, e.g. for figures), `--dark`, `--flat` (flat style), `--flat-pop` (flat with soft shadows and a thin
outline), `--aero` (glossy Frutiger Aero-inspired style), `--glass` (experimental glass style; `--no-liquid` for separate balls and sticks), `--play` (start playing), `--interpolate`
(smooth playback at the display rate, blending between steps), `--fps N` (steps per second), `--atom-numbers`,
`--ui-scale X`, `--backdrop none|cells|space`
(background, default space; `--no-bg-pattern` is the same as `none`), `--bg-blur K` (backdrop depth of field, default 0.6), and
a camera pose for scripted screenshots: `--orbit DX,DY` and `--pan DX,DY` (mouse
drag in pixels), `--zoom STEPS` (wheel steps). `--lock-rotation` locks on
the first frame before going to `--frame N`, so frame N is drawn in frame 1's
orientation.

GPU profiling: `--profile N` renders N frames while orbiting the camera and
prints the mean GPU time of the background pass and the rest of the scene
(`--profile-static` keeps the camera still). Use a release build.

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
| Left click | select / deselect an atom; empty space: clear selection |
| Double-click a bond | cut / restore it |
| Alt + left drag | on a selected atom: rotate the selection about its centre; with one base atom selected, on another atom: swing its branch around the base |
| Alt + right drag | twist the group about the base→grabbed axis |
| Alt + middle drag / Alt + Shift + left or right drag | translate the group |
| Ctrl + left drag | lasso: add atoms inside (including hidden ones) |
| Ctrl + Shift + left drag | lasso: remove atoms inside |
| Left drag | rotate |
| Right drag ← → | rotate about the viewing axis |
| Right drag ↑ ↓ | zoom (up = closer) |
| Middle drag / Shift + left or right drag | translate |
| Wheel | zoom |
| Right drag on the timeline | scrub one frame per pixel |
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
| N | show / hide atom numbers |
| Delete / Backspace | delete the selected atoms |
| Ctrl+Z | undo geometry edit (including deletes and pastes) |
| Ctrl+S | save current frame (with edits) as XYZ |
| Ctrl+O | open file (or drop a file on the window) |

## Layout

See [docs/PLAN.md](docs/PLAN.md) for the architecture and roadmap, and
[docs/DECISIONS.md](docs/DECISIONS.md) for why things are the way they are.

## Credits

The flat style (`--flat`) is inspired by the flat illustration style of
[Kurzgesagt – In a Nutshell](https://kurzgesagt.org). It borrows the general
look only, not any of their artwork. See
[docs/style-refs/kurzgesagt/README.md](docs/style-refs/kurzgesagt/README.md).
