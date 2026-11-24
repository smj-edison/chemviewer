# 06: Selection steps in the undo history

**What to build:** As in Blender, selecting and cutting are undoable, one step per gesture. This is provisional: the user wants to try it and may switch it off. See D25.

**Blocked by:** 04 (Cuts and selection know their numbering), 05 (Redo)

**Status:** ready-for-agent

- [ ] One step per gesture that changes something: a click, a lasso, Ctrl+A, a clear, a cut or restored bond, restoring all cuts. Camera moves, playback and frame changes are never steps
- [ ] Paste and delete stay one geometry step that also restores the selection and cuts
- [ ] Selection steps apply on the frame the user is on and never change frame; geometry steps still jump
- [ ] Steps that no longer apply (cuts of a frame that was left, atoms not in the current numbering) are skipped, on to the next step that has an effect
- [ ] Selection and cut steps don't mark a frame edited
- [ ] At most 100 geometry steps and 1,000 in total; when the total is full the oldest selection steps go first
- [ ] One constant switches selection steps off, giving the behaviour after ticket 05; tests cover both settings
