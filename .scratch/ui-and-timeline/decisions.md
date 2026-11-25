# UI fixes, audit and timeline: what was agreed

From grilling the user on `docs/feature-requests.md`, 2026-11-24. Input for the
spec and tickets; not a spec itself.

Build order: 1. visual fixes, 2. Alt buttons, bar hint and message area, 3. audit
report (stop: the user picks), 4. timeline spec and tickets (stop: the user
reviews before any code).

## 1. Visual fixes
- Flat+ is Flat with "Soft shadow + outline"; the checkbox goes.
- Flat only: radii compressed toward carbon's, gold about 1.3x carbon (was 1.65x),
  hydrogen left alone.
- Aero loses its sky, hills and bubbles and gets None / Space / Cells. Its glossy
  atoms and panel colours stay.
- Contrast 4.5:1 for all text, hints included; hints stay fainter than body text.
  Text over the 3D view has a halo that gives it 4.5:1.
- Element key: swatch, count, symbol, as "o 34 C  o 37 H". Colours stay.
- File, Bonds and Display collapse, open at first, remembered between runs.
- Unit cell box: greyed out with a reason when the file has none.
- UI scale applies on release, shows its value, and can be typed.
- Mouse & keys: a two-column table, grouped Camera, Selecting, Editing, Timeline,
  Files, in the README's order.
- Cel: no black halo where a bond enters an atom.

## 2. Alt buttons and messages
- Alt+left translates, Alt+right twists about the base-grabbed bond, Alt+middle
  rotates about the base atom. Alt+Shift+left rotates too (touchpads); the other
  Shift variants go. D17 is corrected, and no longer says the buttons are GaussView's.
- Several atoms selected: translate and rotate (about the centre) move the
  selection, if one of its atoms is grabbed. Twist, or grabbing an unselected atom,
  does nothing and warns.
- Nothing selected: translate and rotate move the grabbed atom's molecule; twist
  warns.
- The bar always shows the hint for the current selection, dimmer, right of the
  coordinates; the active gesture is highlighted while Alt is held.
- All transient messages are inline in the bar above the timeline, as in Blender
  (revised 2026-11-24, after trying them bottom-right). Refusals and errors look
  different and last longer.

## 3. Audit (Design of Everyday Things)
Report first: findings with principle, screenshot and proposed fix, by severity.
Trivial fixes at once, listed. Held-key modes are fine; persistent ones must be
visible where they act. Covers today's UI and the timeline design.

## 4. Timeline
Data and alignment
- First formats: PLUMED COLVAR and HILLS (`#! FIELDS`), ASE MDLogger, generic
  columns with a header. The reaction coordinate from Gaussian IRC logs. Not
  plumed.log; ORCA IRC later.
- "+ Data" on the timeline, a menu item, files, folders (recognised files only) and
  drops. A tree of source > columns with checkboxes; PLUMED columns grouped by the
  part before the dot. The trajectory's energy is listed too.
- Files found beside a trajectory are offered, never attached silently.
- Alignment is proposed (matching energies if there are any, else equal spans),
  shown with its evidence, and edited there. Until confirmed: "unconfirmed".
- Units come from plumed.dat or plumed.log if found. Otherwise an explicit
  "unknown" that can be edited. Time units must be confirmed.
- Data beyond the last frame is grey; the playhead stops at the last frame. On a
  rewind later rows win, and the source says so.
- No following of growing files, but Reload, and the design leaves room for it.
- Attached data and layout are remembered in the app's own config, by path. Missing
  files keep their place, with "locate...". Changed ones are stale.
- Computed series (measured distances) later; a series is defined to allow them.

Axis and playhead
- One primary coordinate: frame, time, reaction coordinate, or any column that is
  monotonic over the frames. A radio button each in the data tree (others greyed,
  with the reason); its name at the axis's left end opens that panel.
- Everything floors: the frame and the values at or before the playhead. Stopped,
  nothing is blended. Interpolated playback still blends while it runs.
- Pausing and editing floor too, and move the playhead there (changes D24: nearest).
- Dragging and Left/Right go by frames. With Shift, by the finest visible data
  points; then the playhead may rest between frames.
- The frame field shows the whole frame, with the exact coordinate beside it.
- Playback is in frames per second. On a reaction coordinate, stepping and playback
  follow the path; the frame field shows the file's number.

Stale
- Editing a frame marks the frame stale; undoing the edit clears it. Data is kept.
- Anything combined from data of which some is stale is stale.
- Stale values are marked when drawn and read out, and never saved or copied. The
  inspector shows an edited frame's energy as "(stale)".

Lanes
- Stacked lanes share the axis and playhead; each has one or more series. Drag a
  series between them. New ones get their own lane, or a suggestion to share one
  with the same unit and source.
- At most a left and a right y axis, coloured like their series.
- The panel resizes (up to about two thirds of the window) and scrolls; lanes have
  their own height and collapse. The energy plot is the first lane.
- Ctrl+wheel zooms at the cursor, wheel scrolls, Shift+wheel and middle drag pan, an
  overview strip shows the window (drag its edges), and a key fits. Left drag
  scrubs, right drag scrubs finely.
- Lines, or points for HILLS, switchable.
- Playhead and reference on every lane; unreadable and edited frames on the axis.
- Display rate with 8 lanes of a million points; parsing never blocks the UI.

Test run: `mlip/snapshot` in the user's research folder: 492,963 frames without
times, COLVAR and md.log about every 10th, HILLS every 20th.

Headless modules for alignment, parsing, zoom mapping and flooring. CLI flags
(`--data FILE`, `--axis time`) for screenshots.
