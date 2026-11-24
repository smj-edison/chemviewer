# 08: What you see is what you pick

**What to build:** Blending between steps moves into the displayed geometry, and everything the user sees or points at uses it. During interpolated playback, labels sit on their atoms and clicks hit what is drawn. See D24.

**Blocked by:** 07 (Bonds always match the atoms)

**Status:** resolved

- [x] During interpolated playback, picking, the lasso, atom numbers, element labels, selection badges and label occlusion follow the drawn atoms
- [x] Measured values shown during the blend match what is drawn
- [x] Saving and copying use the real step being played from, never a blend
- [x] One answer exists to "where are the drawn atoms"; consumers that need the real frame ask for it by name
- [x] Playback timing, holding until the next step is loaded, loop wrap, periodic-jump snapping and the no-overshoot curve behave as before and gain headless tests, with time passed in
- [x] Atoms and bonds during a blend come from a stated, tested rule (bonds may stay those of the base step)

## Answer

Implemented: `DisplayedGeometry` in src/display.zig (the blend, moved from App), `App.drawnPositions` as the one answer, `display.real` for the real atoms, `App.measured` for the bar. Bonds of a blend are the base step's. Timing tests are in src/playback.zig, curve and snapping tests in src/display.zig.

Seen failing first: where atoms are drawn, the lasso, measured values, copying (only because nothing was blended yet), and steps with other atoms shaping the curve. Not seen failing: the display.zig and playback.zig tests (behaviour kept as it was), clicks, and a diff not blending. Labels, badges and occlusion use `drawnPositions` but need ImGui, and saving is by reading: no headless tests for those.

Changed: a step before or after the blend shapes its curve only if it has the same numbering (before, the same atom count). In a diff overlay, measured values are those of the aligned atoms drawn, until 10.

Not covered by a ticket: the value field shows blended numbers during playback, so pressing Enter in it untouched may apply a blended value (by reading, not tried); playback goes on while the save dialog is open, so the frame shown when it closes is saved; F fits the real atoms.
