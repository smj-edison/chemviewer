# 09: Rotation lock follows the displayed geometry

**What to build:** The rotation lock follows the displayed geometry and unlocks when the user starts editing, without the view jumping. Lining up is only ever a change of view. See D26 and D21.

**Blocked by:** 08 (What you see is what you pick)

**Status:** ready-for-agent

- [ ] Any geometry edit (drag, typed value, paste, delete, and their undo or redo) unticks Lock rotation; the view and the background stay exactly where they are
- [ ] Undoing an edit doesn't tick it again; ticking it by hand refits from the current frame
- [ ] While locked, the molecule keeps its orientation and the background stays still on screen, stepped or interpolated
- [ ] A frame looks the same however it was reached, and the user's own rotations are kept
- [ ] A frame with different atoms restarts the lock there
- [ ] Headless tests cover path independence, blends and unlocking without a jump
- [ ] The checkbox stays above the energy plot, off by default
