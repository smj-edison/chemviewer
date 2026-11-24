# 03: Drags abort cleanly

**What to build:** An Alt-drag is a transaction of the edit session, tied to the frame it started on. Anything that would change the frame under it aborts it and puts the atoms back. Starting any edit pauses playback. See D24 and D17.

Today a frame change during a drag writes the old frame's atoms into the new frame, possibly out of bounds.

**Blocked by:** 02 (Edits go through one edit session)

**Status:** resolved

- [x] A frame change, undo, paste, delete, revert, close or file open during a drag aborts it first, restores the atoms, then proceeds
- [x] An aborted drag adds nothing to the undo history and doesn't mark the frame edited
- [x] A completed drag is one geometry step; Esc still cancels
- [x] Starting a drag, typed value, paste or delete pauses playback; with interpolation it lands on the nearest real step, and the edit applies to that frame
- [x] Atoms are picked as they were visible when the user clicked
- [ ] Headless tests cover aborting by each cause, including a new frame with fewer atoms, written to fail first

## Answer

Implemented in src/app/App.zig: `beginEdit` (every transaction starts there), `stopForEdit`, `showNearerNext`, `showFrame`; `moveTo` and `showFrame` abort a drag. Undo and revert pause playback too, but stay on the shown frame instead of landing on the nearest step. If the next step isn't loaded, an edit applies to the step on screen. src/app/measure.zig applies a typed value after drawing, as the edit frees the frame it drew from (a bug from 02; no headless test, it needs ImGui).

Seen failing first: aborting by a frame change, a frame with fewer atoms, playback, an unreadable file, delete (with and without a selection), a paste with an empty clipboard and a missing fragment file; pausing and landing for each kind of edit; an edit while the next frame loads; undo and revert while playing; revert during a blend; pausing at once; picking during a blend; going back to the shown frame.

Not seen failing, so the last criterion is open: undo, revert, close and opening another file (already aborted by 02), undo with nothing to undo, a completed drag, Esc, bonds after landing, and a drag running out of memory.

Left to 07: bonds in general, and a drag still showing its atoms by writing to the shown frame. Left to 08: lasso, labels and measured values during a blend.

Not covered by a ticket: after an abort the button is still held, so moving the mouse on turns the camera (as Esc already did); and where playback lands is decided in App.zig, not in playback.zig.
