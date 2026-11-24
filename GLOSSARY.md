# chemviewer

A viewer and light editor for molecular structures and trajectories.

## Language

**File frame**:
One structure of a trajectory exactly as read from its file, never changed.
_Avoid_: Original, raw frame

**Edited frame**:
A frame with at least one geometry edit in effect. It stands in for its file frame, and stops being edited when the last edit is undone.
_Avoid_: Modified frame, dirty frame

**Edit session**:
The current atoms of every frame of an open file, with the history of changes to them. The only thing an edit changes.
_Avoid_: Edit state, edits map

**Displayed geometry**:
The atoms and bonds on screen now, derived from the file frames and the edit session. Never edited directly.
_Avoid_: Shown frame, displayed positions, display positions

**Cut**:
A bond the user has set aside on the current frame, so edits and molecule selection treat its two sides as separate. It ends when the user leaves the frame.
_Avoid_: Broken bond, deleted bond

**Selection**:
The atoms the user has picked, in order. Unlike cuts it carries over between frames with the same atom numbering.

**Geometry step**:
One entry in the undo history that changed a frame's atoms.
_Avoid_: Edit (for the history entry)

**Selection step**:
One entry in the undo history that changed only the selection or the cuts.

**Rotation lock**:
A change of view that keeps frames oriented like an anchor frame, or like the reference while diffing. It never moves atoms.
_Avoid_: Align, alignment option

**Reference**:
The frame a diff compares against. It has a placement, used only when drawing, that lines it up with the current frame.
