# 06: Steps finer than frames

**What to build:** With Shift, dragging and Left/Right go by the finest visible data points, so the playhead may rest between frames. The structure and all values floor.

**Blocked by:** 05

**Status:** needs-triage

- [ ] Without Shift, steps are whole frames whatever the axis
- [ ] With Shift, the finest series in view decides; with none finer, it is a frame
- [ ] Resting between frames shows the frame before, unblended, and editing edits that one
- [ ] The readout shows each series' floored value, and "-" before its first row
- [ ] The playhead stops at the last frame even if data goes on
