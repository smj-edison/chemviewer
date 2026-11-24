# 05: Redo

**What to build:** The user can redo what they just undid, with Ctrl+Shift+Z, Ctrl+Y or the Edit menu. See D25.

**Blocked by:** 02 (Edits go through one edit session)

**Status:** ready-for-agent

- [ ] Ctrl+Shift+Z, Ctrl+Y and Edit > Redo redo the last undone step, jumping to its frame like undo
- [ ] A new step clears the redo history
- [ ] Undo then redo restores atoms, numbering, energy and the edited state exactly, for set, drag, paste, delete and revert
- [ ] Shortcuts yield while a text field is being edited, like the others
- [ ] The menu item is disabled when there is nothing to redo, and the mouse and keys help lists the shortcut
- [ ] Headless tests cover the history rules
