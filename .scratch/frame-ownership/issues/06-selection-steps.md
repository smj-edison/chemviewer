# 06: Selection steps in the undo history

**What to build:** As in Blender, selecting and cutting are undoable, one step per gesture. This is provisional: the user wants to try it and may switch it off. See D25.

**Blocked by:** 04 (Cuts and selection know their numbering), 05 (Redo)

**Status:** resolved

- [x] One step per gesture that changes something: a click, a lasso, Ctrl+A, a clear, a cut or restored bond, restoring all cuts. Camera moves, playback and frame changes are never steps
- [x] Paste and delete stay one geometry step that also restores the selection and cuts
- [x] Selection steps apply on the frame the user is on and never change frame; geometry steps still jump
- [x] Steps that no longer apply (cuts of a frame that was left, atoms not in the current numbering) are skipped, on to the next step that has an effect
- [x] Selection and cut steps don't mark a frame edited
- [x] At most 100 geometry steps and 1,000 in total; when the total is full the oldest selection steps go first
- [x] One constant switches selection steps off, giving the behaviour after ticket 05; tests cover both settings

## Answer

Implemented: steps in src/picks.zig (`Step`, `Kept`, `Snapshot`), the mixed history in src/edit.zig (`selection_steps`, `max_total`, `recordSelection`, `undo`/`redo` taking the picks), gestures in App (`beginGesture`, `endGesture`). `--select` and `--cut` aren't steps. Undoing a revert that renumbered restores the picks too, which the ticket didn't ask for. The tests pass with the constant on and off.

Seen failing first: one step per gesture, cuts, gestures that change nothing, paste and delete, a delete whose frame was left, staying on the frame and jumping, skipping (two tests), both limits, undoing a revert. Not seen failing: steps off (the behaviour before), and the tests added after review (redoing skipped steps, gestures, deletes and pastes that run out of memory). The allocation-failure test in edit.zig found a double free.

For trying it out: going back to a frame can make an old step have an effect again. If moving between frames cleared a selection, undoing the click that extended it selects what came before that click.

Left open: each step holds the whole selection before and after, about 0.8 MB per click with 100,000 atoms selected. While the Edit menu is open, undo and redo are checked against up to 1,000 steps.
