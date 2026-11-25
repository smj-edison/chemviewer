# 11: The whole test run, at full speed

**What to build:** A check of everything on `mlip/snapshot` and on 8 lanes of a million points, with fixes for what it finds.

**Blocked by:** 04, 06, 07, 08, 09, 10

**Status:** ready-for-agent

- [ ] The spec's "Done when" holds
- [ ] `--profile` covers the timeline; release build, 8 lanes of a million points, display rate while panning, zooming and playing
- [ ] No UI frame over 50 ms while files are read (measured)
- [ ] Memory use is written down
- [ ] Two-axis review since the spec, and its findings handled
- [ ] README, help table, DECISIONS and GLOSSARY are up to date
