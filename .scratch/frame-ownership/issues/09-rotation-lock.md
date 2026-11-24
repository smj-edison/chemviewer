# 09: Rotation lock follows the displayed geometry

**What to build:** The rotation lock follows the displayed geometry and unlocks when the user starts editing, without the view jumping. Lining up is only ever a change of view. See D26 and D21.

**Blocked by:** 08 (What you see is what you pick)

**Status:** resolved

- [ ] Any geometry edit (drag, typed value, paste, delete, and their undo or redo) unticks Lock rotation; the view and the background stay exactly where they are
- [x] Undoing an edit doesn't tick it again; ticking it by hand refits from the current frame
- [x] While locked, the molecule keeps its orientation and the background stays still on screen, stepped or interpolated
- [x] A frame looks the same however it was reached, and the user's own rotations are kept
- [x] A frame with different atoms restarts the lock there
- [x] Headless tests cover path independence, blends and unlocking without a jump
- [x] The checkbox stays above the energy plot, off by default

## Answer

Implemented: `RotationLock` in src/lock.zig (headless), `followRotationLock` and `unlockRotation` in App. A drag unlocks when it first moves, and stays unlocked if cancelled; an edit that changes nothing doesn't unlock. An edit, undo, redo or revert that lands on or jumps to another frame follows it there first, so on screen nothing turns. Opening or closing a file unlocks.

Open: all edits untick it, but a paste that lands out of sight still zooms out to show the fragment (D15), so the view isn't exactly where it was. It no longer turns the background.

Seen failing first: each edit unlocking, an edit landing from a blend, undo/redo/revert during a blend or of another frame, the background turning on a paste, the lock surviving an open, switching a diff overlay. Not seen failing: path independence, blends, restarting, refitting, edits that keep the lock, a long way round, and the lock.zig tests (written with it). `--lock-rotation` screenshots are pixel-identical to the binary from before 02.

F (fit) still puts the background pattern back to its own orientation.
