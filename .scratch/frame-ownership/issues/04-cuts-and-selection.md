# 04: Cuts and selection know their numbering

**What to build:** Cuts belong to the current frame and end when the user leaves it. The selection carries over between frames with the same atom numbering and is cleared otherwise. Deleting atoms, and undoing that, translates both. See D24 and the glossary (cut, selection).

Today cuts apply to every frame by atom number, and deleting on one frame renumbers them for all.

**Blocked by:** 02 (Edits go through one edit session)

**Status:** ready-for-agent

- [ ] Leaving a frame by any means (stepping, scrubbing, playing, undo to another frame) clears its cuts; returning doesn't bring them back
- [ ] The selection survives moving between frames with the same numbering, so a measured distance can be watched while scrubbing
- [ ] Moving to or from a frame whose atoms were deleted or pasted, with a different numbering, clears the selection
- [ ] Delete translates remaining cuts and selected atoms; its undo translates them back, and cuts or selection on the deleted atoms stay gone (06 changes this for selection when selection steps are on)
- [ ] Undo and revert never discard cuts made since, except by leaving the frame or removing their atoms
- [ ] `--cut` still works with `--select` and `--set`
- [ ] Headless tests cover each rule, written to fail first where they cover a bug
