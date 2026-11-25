# UI audit: The Design of Everyday Things

2026-11-24. Step 3 of `decisions.md`. Covers today's UI (2fcf861) and the timeline
design. Screenshots are in `renders/audit/` (not in git). Pick by number.

Evidence: **seen** = in a screenshot, **code** = read in the source. Nothing was
tried by hand, so cursor, hover and feel are judged from the code.

## What was picked (2026-11-24)

All but 9 (usual for panels over a view) and 16. Changes to the proposals:
- 1: leaving without saving is common, so "Discard all" is one click, beside saving
  edited frames one by one. Asked only when there are unsaved edits.
- No pop-ups for mistakes. Messages are inline in the bar above the timeline, as in
  Blender. This replaces "bottom-right and fade" in `decisions.md`, step 2.
- 11: no standing indicator. A bond is outlined while the mouse is over it, and the
  bar says that a double-click cuts (or restores) it.
- 17 and T1 to T6 go into the timeline spec.

## Severe: work can be lost, or the app misleads

**1. Edits are dropped without asking.** *(error prevention; code)*
Quit, closing the window, File > Close, opening a file and dropping one all discard
every edit, and opening also clears the undo history. `quit_requested` is set
unconditionally, and `install` calls `closeDocument`. A dropped file is the
easiest slip.
→ Keep track of edited frames that aren't saved. Ask "Save, Discard, Cancel" only
then, naming how many frames. Medium.

**2. Only the shown frame can be saved, and nothing lists the edited ones.**
*(mapping, feedback; code)* With edits on frames 3 and 40, you must remember both. The
"(edited)" in the inspector is for the shown frame only and stays after saving.
→ Mark edited frames on the timeline (already agreed for step 4), and add "Save
trajectory as XYZ" with the edits. Medium. Needed for 1 to offer a useful Save.

**3. Nothing shows what a click or drag would hit.** *(signifiers, feedback; code)*
There is no hover highlight and the cursor never changes. Bonds are clickable only
by double-click, and "Drag an atom, not a bond" arrives after the mistake.
→ Outline the atom under the mouse faintly, and the bond only where a double-click
would cut it. With Alt held, tint the group that would move. Medium; the Alt part
is the most useful.

**4. An edit switches Lock rotation off silently.** *(modes, feedback; code)*
`unlockRotation` clears the checkbox and says nothing; undo and redo do it too, and
it doesn't come back on undo. Only the checkbox's tooltip mentions it.
→ Flash the checkbox when it changes by itself. No message. Small.

## Moderate: slower or harder to discover

**5. Help is at the bottom of a panel that can be closed.** *(discoverability; seen:
`empty.png`)* With the inspector closed there is no list of gestures anywhere, and
there is no Help menu.
→ Help menu with "Mouse & keys" (F1) as its own window; drop the section. Small.

**6. The empty window offers text, not an action.** *(signifiers; seen: `empty.png`)*
The instructions sit in a corner panel, among bond sliders that affect nothing.
→ "Open..." button and "or drop a file here" in the middle of the view. Small.

**7. Looks aren't remembered.** *(knowledge in the world; code)* `Settings` keeps only
the three section flags: theme, style, background, sizes, bond sliders and
UI scale start over every run.
→ Remember them, with "Reset to defaults" beside each section. Small to medium.

**8. Undo doesn't say what it will undo.** *(feedforward; code)* The menu says
"Undo", selection clicks and edits share one history, and undo may jump to another
frame.
→ "Undo move (frame 12)", "Undo selection". Small to medium.

**9. The molecule is centred behind the panels.** *(visibility; seen: `narrow.png`)*
Fit uses the whole window. At 800x500 the inspector covers part of it.
→ Fit and centre in the uncovered area. Medium; picking must agree.

**10. The diff relies on red and green alone.** *(signifiers; seen: `diff.png`)*
Also, red oxygen and a red cut bond look like "reference". The timeline's
reference line is red with no label.
→ Blue and orange, plus a swatch by each label; label the line "ref". Small.

**11. Cut bonds explain themselves once.** *(feedback; seen: `edited-cut.png`)*
The message fades in 4 s; after that red and thin has no legend, and leaving
the frame ends the cut without a word. "Restore all cut bonds" is in the Edit menu only.
→ "1 bond cut [Restore]" in the bar while there are any. Small.

**12. "Reset" in the diff panel says nothing about what it resets.** *(mapping; code)*
→ "Show file positions". Small.

## Minor

**13.** "links" in the inspector and tooltips, "bonds" everywhere else. *(consistency)*
→ "bonds". It counts hidden ones too ("8 links"): count the drawn ones.
**14.** "Cut-off x r1", "Snap" and "Hide below" need their tooltips to be understood.
*(conceptual model)* → "Longest bond (x single)", "Colour steps", "Hide weaker than".
**15.** "move both sides / C2 side" appears beside values but acts only on the next
typed value. *(mapping)* → "when changed, move ...".
**16.** Where the (?) hint is used the row is full; the hint needs about 650 px.
*(visibility)* Already swaps on Alt. → Leave.
**17.** The energy plot has no unit and no frame ticks. *(feedback; code)*
→ Step 4.
**18.** A playhead on the first or last frame sits on the plot's edge (seen:
`narrow.png`). → Inset the plot by a few pixels.

## Modes

| Mode | Visible where it acts? | Verdict |
|---|---|---|
| Alt, Ctrl, Shift held | Alt yes (bar); Ctrl only once the lasso starts | fine |
| Lock rotation | checkbox, far from the view | finding 4 |
| Diff overlay | the colours | finding 10 |
| Cut bonds | thin and red, no legend | finding 11 |
| Edit mode (both / one side) | beside the value | finding 15 |
| Interpolate, Loop | checkboxes beside Play | fine |

## The timeline design

**T1. The same column can be an axis and a lane.** Radio and checkbox side by side will
look alike. → Put the axis choice at the axis's own end only, as its menu.
**T2. Several meanings of wheel and drag** (Ctrl, Shift, middle, left, right) are only
discoverable by trying. → The overview strip and a zoom slider must do everything the
modifiers do. Show the bar's hint while the mouse is over the timeline.
**T3. Grey already means disabled and now "beyond the last frame".** → Hatch instead.
**T4. "Unconfirmed" alignment is a persistent mode.** → Show it on every lane that
uses it, with Confirm beside it, not only in the panel.
**T5. "Stale" needs a cause.** → The mark's tooltip says which edit, with "Go to".
**T6. A remembered layout can hide why a lane is there.** → Name its source on each lane.

## Fixed already (trivial)

- Playback controls are greyed out with fewer than two frames.
- "No structure loaded / No trajectory loaded" is now "No file open", once.
- "Fit view" and "Fit to view" are both "Fit to view".
- The diff's mismatch text no longer mentions "Phase 3".

## Recommended

First 1 with 2, 3 and 4; then the small ones 5, 6, 8, 10, 11, 12 and 13 together; 7
next. 9 if you use small windows. 17 and T1 to T6 go into the timeline spec.
