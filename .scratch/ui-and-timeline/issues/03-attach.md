# 03: Attach a table and plot a column

**What to build:** "+ Data" on the timeline, a menu item, `--data FILE` or a drop attaches a PLUMED, MDLogger or generic table. A tree of source > columns with checkboxes; a checked column gets a lane under the energy. Lined up by frames per row (rules 3 and 4 only), marked unconfirmed.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] `table.zig` reads the three kinds; tests cover every case in the spec's Testing section
- [ ] Reading runs in the background, is cancelled on close, and the lane fills as it goes
- [ ] `pyramid.zig`: min and max agree with the raw rows at every level (test on random data)
- [ ] PLUMED columns are grouped by the part before the dot; the trajectory's energy is in the tree
- [ ] A folder offers its recognised files; a file that isn't recognised says why, in the bar
- [ ] A dropped structure file still opens as a structure, a data file attaches
- [ ] Skipped rows are counted on the source; on a rewind later rows win, and it says so
- [ ] Rows past either end of the trajectory are hatched (C2)
- [ ] Each lane names its source (T6); hovering reads every lane at that point
- [ ] HILLS are points, the rest lines, switchable
