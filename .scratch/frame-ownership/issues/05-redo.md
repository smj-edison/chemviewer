# 05: Redo

**What to build:** The user can redo what they just undid, with Ctrl+Shift+Z, Ctrl+Y or the Edit menu. See D25.

**Blocked by:** 02 (Edits go through one edit session)

**Status:** resolved

- [x] Ctrl+Shift+Z, Ctrl+Y and Edit > Redo redo the last undone step, jumping to its frame like undo
- [x] A new step clears the redo history
- [x] Undo then redo restores atoms, numbering, energy and the edited state exactly, for set, drag, paste, delete and revert
- [x] Shortcuts yield while a text field is being edited, like the others
- [x] The menu item is disabled when there is nothing to redo, and the mouse and keys help lists the shortcut
- [x] Headless tests cover the history rules

## Answer

Implemented: `EditSession.redo` in src/edit.zig (undo and redo swap a step's atoms with its frame's), `redo`, `jumpToChange` and `historyKey` in App. The menu items are now "Undo" and "Redo".

Seen failing first (against stubs): redo across frames, a new step clearing redo, a full history, numbering, each kind of edit, jumping and translating cuts and selection, aborting drags and pausing playback, a cancelled drag, the keys. Not seen failing: clear, a failed edit keeping redo, and a new step after undoing some of a full history (added after review). Yielding to text fields and the disabled menu item have no headless tests: they need ImGui.

Not covered by a ticket: jumping to an edited frame still asks the stream for its file frame, so if that can't be read any more the status line says so instead of what was undone or redone.
