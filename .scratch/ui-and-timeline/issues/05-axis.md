# 05: The axis

**What to build:** The axis can be frame, time or any monotonic column, chosen at its left end (C4).

**Blocked by:** 04

**Status:** ready-for-agent

- [ ] A time in an unconfirmed unit can't be the axis, and the menu says why
- [ ] `axis.zig` tests: coordinate to frame and back, floors, ties, non-monotonic columns refused with the first offending row
- [ ] The menu greys what can't be an axis, with why
- [ ] Ticks and the readout carry the unit; the frame field keeps the whole frame, the exact coordinate beside it
- [ ] Zoom, marks and scrubbing work in every coordinate
- [ ] `--axis NAME` for screenshots
