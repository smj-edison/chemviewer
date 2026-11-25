# 08: Arranging lanes

**What to build:** Lanes with several series, resized, collapsed and reordered; the panel grows to about two thirds of the window and scrolls.

**Blocked by:** 03

**Status:** ready-for-agent

- [ ] `layout.zig`: move a series, split it off, share rules; headless tests
- [ ] Dragging a series shows where it would land before it is let go
- [ ] A new series gets its own lane, with a suggestion to share one of the same unit and source
- [ ] At most a left and a right y axis, coloured like their series, readable with any colour vision
- [ ] Lane heights, collapsing and the panel height; the energy lane is first and can be collapsed
- [ ] Playhead and reference on every lane; unreadable and edited frames on the axis
- [ ] The view's clicks and the fit follow the panel's height
