# 04: Cuts and selection know their numbering

**What to build:** Cuts belong to the current frame and end when the user leaves it. The selection carries over between frames with the same atom numbering and is cleared otherwise. Deleting atoms, and undoing that, translates both. See D24 and the glossary (cut, selection).

Today cuts apply to every frame by atom number, and deleting on one frame renumbers them for all.

**Blocked by:** 02 (Edits go through one edit session)

**Status:** resolved

- [x] Leaving a frame by any means (stepping, scrubbing, playing, undo to another frame) clears its cuts; returning doesn't bring them back
- [x] The selection survives moving between frames with the same numbering, so a measured distance can be watched while scrubbing
- [x] Moving to or from a frame whose atoms were deleted or pasted, with a different numbering, clears the selection
- [x] Delete translates remaining cuts and selected atoms; its undo translates them back, and cuts or selection on the deleted atoms stay gone (06 changes this for selection when selection steps are on)
- [x] Undo and revert never discard cuts made since, except by leaving the frame or removing their atoms
- [x] `--cut` still works with `--select` and `--set`
- [x] Headless tests cover each rule, written to fail first where they cover a bug

## Answer

Implemented: src/picks.zig (`Picks.follow`, `Numbering`), origins in src/edit.zig (`Transaction.delete` and `append`), wired in App (`followPicks`, `numberingOf`). The history no longer stores cuts. Frames are left when another one is shown, so asking for a frame and coming back before it loads keeps the cuts.

Also: steps with different numberings are no longer blended (before, the same number of atoms was enough), so an edit can't land on other atoms than the ones picked. A typed value or paste that changes nothing says so.

Seen failing first: cuts ending with the frame, also when a blend lands; clearing the selection for other elements, deletes and pastes; translating through delete, its undo, revert (also past the undo limit) and undoing a paste; numbering after deleting what was pasted; not blending other numberings.

Passed from the start, so no bug to show: the selection carrying over (also across undo to another frame), cuts while editing, selection on deleted atoms, a cut changing what a typed value moves. The tests in picks.zig and edit.zig were written with their implementation. `--cut` itself was checked by comparing its saved XYZ with the binary from before 02.

Left open: the selection and cut operations themselves are still in App.zig, and a delete or paste that fails in App is untested.
