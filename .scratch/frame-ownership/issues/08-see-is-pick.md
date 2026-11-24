# 08: What you see is what you pick

**What to build:** Blending between steps moves into the displayed geometry, and everything the user sees or points at uses it. During interpolated playback, labels sit on their atoms and clicks hit what is drawn. See D24.

**Blocked by:** 07 (Bonds always match the atoms)

**Status:** ready-for-agent

- [ ] During interpolated playback, picking, the lasso, atom numbers, element labels, selection badges and label occlusion follow the drawn atoms
- [ ] Measured values shown during the blend match what is drawn
- [ ] Saving and copying use the real step being played from, never a blend
- [ ] One answer exists to "where are the drawn atoms"; consumers that need the real frame ask for it by name
- [ ] Playback timing, holding until the next step is loaded, loop wrap, periodic-jump snapping and the no-overshoot curve behave as before and gain headless tests, with time passed in
- [ ] Atoms and bonds during a blend come from a stated, tested rule (bonds may stay those of the base step)
