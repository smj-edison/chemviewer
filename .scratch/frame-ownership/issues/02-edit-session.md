# 02: Edits go through one edit session

**What to build:** Paste, delete, typed values and adding a fragment all go through one transaction in an edit session that owns the current atoms of every frame and the undo history. A frame counts as edited only while an edit is in effect. See D24 (edit session), D14, D15 and the glossary.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] Snapshot, energy, storing, undo and rollback rules are written once; a failed edit leaves the frame as it was
- [x] Undoing a frame's last edit makes it its file frame again: energy back, "(edited)" gone, no `edited=T` when copied
- [x] If the undo limit has dropped a frame's first edit, it stays edited until it is reverted
- [x] Revert is one undoable geometry step and leaves other frames' history alone
- [x] Undo is one history across frames and jumps to the frame it changed
- [x] Opening or closing a file resets edits, history, selection, cuts, drag, playback and the interpolation position
- [ ] The edit session doesn't depend on SDL, ImGui or Vulkan, and has headless tests for all of the above, written to fail first where they cover a bug
- [x] Existing behaviour of `--select`, `--set`, `--add`, `--cut` and `--save` is unchanged

## Answer

Implemented: src/edit.zig (EditSession, Transaction), wired in App (commitEdit, applyChange, closeDocument). Alt-drag also commits through a transaction; the rest of its abort rules are 03. The reset and jump rules are tested in App.zig, without a window.

Seen failing first: the three App tests (undoing the last edit, revert, reset on open/close). Not seen failing, so that criterion is open: the edit.zig tests, written with their implementation; of those, the undo limit one covers a bug. App's own out-of-memory paths are untested.

Left to 03: pausing playback (undo included), and the drag moving the atoms on screen before it commits. Left to 04: cuts after a revert when the undo limit has dropped a delete.
