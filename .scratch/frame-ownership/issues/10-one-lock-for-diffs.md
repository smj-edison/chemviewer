# 10: One lock for diffs, with Alt-drag in the overlay

**What to build:** In a diff, the current structure is drawn at its own coordinates and the reference is lined up with it by a placement used only for drawing. The same Lock rotation checkbox controls it, so Alt-drag works in the overlay. See D26.

**Blocked by:** 09 (Rotation lock follows the displayed geometry)

**Status:** resolved

- [x] With the lock on, the diff looks as it does today: same overlay, RMSD, deviations and worst atom
- [x] Starting a diff turns the lock on with the reference as anchor; ending it restores the lock's previous state
- [x] Changing frame while locked keeps the reference and the background still on screen
- [x] Alt-drag works in the overlay; the "turn off the overlay first" refusal is gone
- [x] An edit unlocks: the reference doesn't move, and RMSD and deviations update live against that placement; locking again refits
- [x] Changing frame while unlocked keeps the placement
- [x] Reset in the diff panel shows both frames at their file positions
- [x] The reference's stored atoms and the current frame's atoms are never changed by lining up
- [x] Picking, lasso and labels match what is drawn in the overlay
- [x] Headless tests cover the placement and camera cancelling on screen; `--diff-ref` screenshots match today's

## Answer

Implemented: `Diff` in src/diff.zig (headless: placement, RMSD, deviations), `Transform.inverse`, and in App `followRotationLock` (anchored at the reference while diffing), `resetPlacement`, `drawnReference`. `App.refresh` runs again after the UI, so a camera moved from the UI is never drawn with the old scene. Fit and clipping include the reference.

Seen failing first: drawing at its own coordinates, locking and restoring, Alt-drag, ending a diff with a frame on the way, a reference that can't be set, fitting. Not seen failing: the other App diff tests and diff.zig's, written with the code. `refresh`, the panel and labels need a GPU or ImGui and have no headless tests.

Screenshots: the old and new `--diff-ref` molecules match except for edge pixels (under 0.02%), and RMSD and worst atom are the same. With the Aero sky a few background bubbles differ. The old binary changes a bubble in the same way with only `--lock-rotation`, so the sky shader is sensitive to the tiny changes in the pattern's placement; not looked into.

Changed: frames are comparable only with the same numbering (origins too), not just the same elements. `--lock-rotation` with `--diff-ref` leaves the lock on when the diff ends.
