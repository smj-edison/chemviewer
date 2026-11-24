# 10: One lock for diffs, with Alt-drag in the overlay

**What to build:** In a diff, the current structure is drawn at its own coordinates and the reference is lined up with it by a placement used only for drawing. The same Lock rotation checkbox controls it, so Alt-drag works in the overlay. See D26.

**Blocked by:** 09 (Rotation lock follows the displayed geometry)

**Status:** ready-for-agent

- [ ] With the lock on, the diff looks as it does today: same overlay, RMSD, deviations and worst atom
- [ ] Starting a diff turns the lock on with the reference as anchor; ending it restores the lock's previous state
- [ ] Changing frame while locked keeps the reference and the background still on screen
- [ ] Alt-drag works in the overlay; the "turn off the overlay first" refusal is gone
- [ ] An edit unlocks: the reference doesn't move, and RMSD and deviations update live against that placement; locking again refits
- [ ] Changing frame while unlocked keeps the placement
- [ ] Reset in the diff panel shows both frames at their file positions
- [ ] The reference's stored atoms and the current frame's atoms are never changed by lining up
- [ ] Picking, lasso and labels match what is drawn in the overlay
- [ ] Headless tests cover the placement and camera cancelling on screen; `--diff-ref` screenshots match today's
