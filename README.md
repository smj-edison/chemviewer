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
- **Instant scrubbing.** A timeline with an energy plot you can click or drag,
  and zoom from the whole trajectory to single frames.
  Large trajectories are streamed from disk with background prefetch.
  **Lock rotation** (next to Loop) turns the view with each frame so a
  tumbling structure keeps its orientation: every frame is superposed onto
  the frame shown when the lock was switched on, or onto the reference of a
  diff. Editing switches it off.
- **Diffing.** Line up a reference frame with the current one (Horn/Kabsch),
  with an orange/blue overlay, RMSD and max deviation. Alt+drag works in the
  overlay: Lock rotation switches off, the reference stays put, and the numbers
  update live. Lock again to refit, or show both at their file positions.
- **Measure and edit.** Click two to four atoms to get a distance, angle or
  dihedral in the bottom bar. Type a new value (degrees or radians for
  angles) and the attached group moves with it, Chemcraft-style. Edits are per
  frame, undoable (reverting to the file too), and can be saved as XYZ.
- **XYZ clipboard.** Ctrl+C copies the selected atoms (or the whole frame) as
  XYZ, with the source in the comment line. Ctrl+V pastes XYZ, bare
  `El x y z` lines, or a Gaussian/ORCA input into the current structure as a
  new fragment (Ctrl+Shift+V opens it as a new structure instead).
- **Drag fragments with Alt.** Alt+left drag moves, Alt+right twists, and
  Alt+middle (or Alt+Shift+left) rotates. With a single base atom selected, drag
  any other atom: the branch beyond the base moves, twists about the line
  from the base to that atom, or swings around the base with the atom following
  the cursor. With several selected, drag one of them to move or rotate them
  all; with nothing selected, the grabbed atom's molecule. The bar above
  the timeline says what each button does. Each drag is one undoable edit;
  Esc cancels, and so does anything that changes the frame under it.
- **Undo and redo.** Edits, selections and cuts are undone one gesture at a time.
  Edits jump to the frame they were on; selections and cuts stay on yours.
- **Cut bonds.** Double-click a bond to cut it (and again to restore it). It stays drawn (thin, red),
  but edits and molecule selection treat the two sides as separate, so you can
  move part of a ring or a ligand freely. Cuts end when you leave the frame.
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

On other Linux systems, `zig build -Doptimize=ReleaseSafe --prefix ~/.local`.

`packaging/build-packages.sh linux|windows|macos VERSION` builds the packages into
`dist/`, as CI does (`zig build -Dpackage=local|installer`). macOS ones need a
Mac, as SDL needs Apple's SDK; the others can be built anywhere.

| | `-local` | `-installer` |
|---|---|---|
| Linux | the program (`chmod +x` it) | `.tar.gz` with `install.sh`, desktop entry, icons, file types |
| Windows | the program | per-user setup program (building it needs NSIS's `makensis`) |
| macOS | `.app` in a `.zip` | `.dmg` |

The Linux program needs only glibc 2.31+ and a Vulkan driver. The macOS app is
a folder with MoltenVK inside, so it can't be a single file.
`packaging/test-in-podman.sh linux|windows` runs the Linux or Windows CI build
locally, from scratch. The GitHub workflow
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
| F1 | show / hide this list |
| Left click | select / deselect an atom; empty space: clear selection |
| Double-click a bond | cut / restore it (until you leave the frame) |
| Alt + left drag | move the selection; with one base atom selected, the branch beyond it; with nothing selected, a molecule |
| Alt + right drag | twist the branch about the line from the base to the grabbed atom |
| Alt + middle drag / Alt + Shift + left drag | rotate about the base, else about the centre |
| Ctrl + left drag | lasso: add atoms inside (including hidden ones) |
| Ctrl + Shift + left drag | lasso: remove atoms inside |
| Left drag | rotate |
| Right drag ← → | rotate about the viewing axis |
| Right drag ↑ ↓ | zoom (up = closer) |
| Middle drag / Shift + left or right drag | translate |
| Wheel | zoom |
| Right drag on the timeline | scrub one frame per pixel |
| Ctrl + wheel on the timeline | zoom at the mouse |
| Shift + wheel / middle drag on the timeline | pan |
| Z | show every frame on the timeline |
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
| Ctrl+Z | undo the last edit, selection or cut (including deletes, pastes and reverts) |
| Ctrl+Shift+Z / Ctrl+Y | redo what was undone |
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

## License

MIT, see [LICENSE](LICENSE). Bundled libraries:
[packaging/THIRD-PARTY-NOTICES.txt](packaging/THIRD-PARTY-NOTICES.txt).
