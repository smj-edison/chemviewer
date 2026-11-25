# 09: Stale values

**What to build:** Editing a frame marks what was computed for it as stale, until the edit is undone. Nothing stale is saved or copied.

**Blocked by:** 03

**Status:** needs-triage

- [ ] Stale rows look different without relying on colour, and the readout says "(stale)"
- [ ] The inspector shows an edited frame's file energy as "(stale)" instead of hiding it
- [ ] The mark's tooltip says which step made it so, with "Go to" (T5)
- [ ] Undo, redo and revert update it at once; tests with the edit session
- [ ] Saving and copying an edited frame write no energy, as now (test)
- [ ] Anything combined from stale values is stale (a test on the rule; nothing combines yet)
