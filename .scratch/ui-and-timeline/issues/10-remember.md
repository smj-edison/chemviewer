# 10: Finding it again

**What to build:** Opening a trajectory brings back its data, alignments, lanes, axis and window. Files beside a trajectory are offered. Reload reads again.

**Blocked by:** 05, 08

**Status:** ready-for-agent

- [ ] Kept in the app's config by path, size and modification time; never in the data's directories
- [ ] A missing file keeps its place, with "Locate..."; a changed one is marked and its alignment is unconfirmed again
- [ ] Offered files are one line in the bar, once per trajectory, and never attached by themselves
- [ ] Reload keeps the columns and lanes that still exist, and says which don't
- [ ] Damaged or old config is ignored, as for settings; a failed write is tried again (tests)
- [ ] Scripted runs neither read nor write it
