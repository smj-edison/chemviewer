# 11: Remove the old paths

**What to build:** Nothing new for the user. The duplicate state and functions the earlier tickets replaced are gone, and the documents describe what exists.

**Blocked by:** 01 (Bad frames don't stall a trajectory), 06 (Selection steps in the undo history), 10 (One lock for diffs)

**Status:** resolved

- [x] No leftover second answer to who owns a frame's atoms, its bonds, its edited state or where atoms are drawn
- [x] Dirty flags that the displayed geometry made unnecessary are removed, and callers no longer have to remember them
- [x] Unused functions found in the architecture review are removed or used (the stream's synchronous load, the duplicated per-atom deviations)
- [x] D24, D25 and D26 no longer say "not implemented yet"; D25 still says provisional; D21 points to D26
- [x] README and the mouse and keys help match the behaviour: redo, selection undo, cuts ending with the frame, Alt-drag in the overlay
- [x] GLOSSARY.md terms match the names in the code
- [x] Unit tests pass, and headless screenshots show no validation errors in a debug build

## Answer

`scene_dirty` is gone: `App.refresh` builds the scene again when `App.sceneKey` (everything it is drawn from) differs. Also removed: `Document.followed`, `FrameStream.loadNow`, `align.deviations`, `App.atomAt`, `setInterp`, `showPicks`. README, in-app help, PLAN, GLOSSARY and the decisions are updated.

Seen failing first: the scene key's changes (against a stub), draw-only style, a coordinate that isn't a number, a blend that gets another shape while locked. Not seen failing: building again after a failed bond search, the hash and the held-steps count. Building the scene needs the renderer, so `refresh` and its retry after a failed build have no headless test.

Screenshots in all four styles with a diff, with the lock, and during interpolated playback: no validation errors, and the molecules as before.

Left: while locked in a diff, the lock's transform and the diff's placement are inverses kept in step by `followRotationLock`. `Mat4.orthographic`, `text.Lines.peek` and `text.startsWithIgnoreCase` have no callers; they are older than this feature.
