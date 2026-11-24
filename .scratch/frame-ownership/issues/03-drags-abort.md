# 03: Drags abort cleanly

**What to build:** An Alt-drag is a transaction of the edit session, tied to the frame it started on. Anything that would change the frame under it aborts it and puts the atoms back. Starting any edit pauses playback. See D24 and D17.

Today a frame change during a drag writes the old frame's atoms into the new frame, possibly out of bounds.

**Blocked by:** 02 (Edits go through one edit session)

**Status:** ready-for-agent

- [ ] A frame change, undo, paste, delete, revert, close or file open during a drag aborts it first, restores the atoms, then proceeds
- [ ] An aborted drag adds nothing to the undo history and doesn't mark the frame edited
- [ ] A completed drag is one geometry step; Esc still cancels
- [ ] Starting a drag, typed value, paste or delete pauses playback; with interpolation it lands on the nearest real step, and the edit applies to that frame
- [ ] Atoms are picked as they were visible when the user clicked
- [ ] Headless tests cover aborting by each cause, including a new frame with fewer atoms, written to fail first
