# 11: Remove the old paths

**What to build:** Nothing new for the user. The duplicate state and functions the earlier tickets replaced are gone, and the documents describe what exists.

**Blocked by:** 01 (Bad frames don't stall a trajectory), 06 (Selection steps in the undo history), 10 (One lock for diffs)

**Status:** ready-for-agent

- [ ] No leftover second answer to who owns a frame's atoms, its bonds, its edited state or where atoms are drawn
- [ ] Dirty flags that the displayed geometry made unnecessary are removed, and callers no longer have to remember them
- [ ] Unused functions found in the architecture review are removed or used (the stream's synchronous load, the duplicated per-atom deviations)
- [ ] D24, D25 and D26 no longer say "not implemented yet"; D25 still says provisional; D21 points to D26
- [ ] README and the mouse and keys help match the behaviour: redo, selection undo, cuts ending with the frame, Alt-drag in the overlay
- [ ] GLOSSARY.md terms match the names in the code
- [ ] Unit tests pass, and headless screenshots show no validation errors in a debug build
