# 04: Units, and alignment with evidence

**What to build:** Sources are lined up by energies, or by the clock of one that is (C1), and say so. The user can change the rule and its numbers, and confirm. Time units come from MDLogger's header and plumed.log or plumed.dat (C3), else "unknown", editable.

**Blocked by:** 03

**Status:** ready-for-agent

- [ ] Units are read from the test run's plumed.log (fs) and md.log (ps), and agree after conversion
- [ ] plumed.log missing, unreadable, without a unit, or disagreeing with plumed.dat: the unit is unknown, the source asks for it in place, and the data is shown meanwhile (tests for each)
- [ ] An unknown time unit must be confirmed before it is used to align
- [ ] `align.zig` tests: exact, offset start, cut-off ends, rounded energies, constant energies, too few rows, one wrong row, no energies
- [ ] The test run: md.log by energies at 10 frames per row; COLVAR and HILLS through its clock; none by equal spans
- [ ] The evidence is in words ("8 of 8 energies match, 10 frames per row"; "guess: equal spans")
- [ ] Every lane whose source isn't confirmed says so, with Confirm beside it (T4)
- [ ] Editing the ratio or offset redraws at once and can be undone to the proposal
- [ ] A proposal made while energies are still being scanned is upgraded, never after confirming
