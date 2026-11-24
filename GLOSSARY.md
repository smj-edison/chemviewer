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
_Avoid_: Displayed positions, display positions

**Shown frame**:
Which frame is on screen. It lags behind the timeline position while a frame loads, and stays at the last good one if that frame can't be read. Its atoms on screen are the displayed geometry.

**Transaction**:
One edit of one frame in the making. Nothing changes until it is committed as a geometry step, or it is aborted.

**Cut**:
A bond the user has set aside on the current frame, so edits and molecule selection treat its two sides as separate. It ends when the user leaves the frame.
_Avoid_: Broken bond, deleted bond

**Selection**:
The atoms the user has picked, in order. Unlike cuts it carries over between frames with the same atom numbering.

**Picks**:
The selection and the cuts together, with the numbering they refer to.

**Visit**:
The time from showing a frame until another one is shown. Cuts end with it.

**Origin**:
Where an atom of a frame comes from: its number in the file, or an id of its own if it was pasted. It stays the same when other atoms are deleted.

**Numbering**:
Which atom each atom number of a frame means: its elements and origins. Frames have the same numbering if both match.

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
