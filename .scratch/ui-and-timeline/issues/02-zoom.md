# 02: Zoom, pan and the overview strip

**What to build:** The energy plot zooms from the whole run to single frames. An overview strip under it shows the window; drag it to pan, its edges to zoom. A slider and a fit button do the same (C5). Ticks and the energy's unit (audit 17).

**Blocked by:** None

**Status:** ready-for-agent

- [ ] `window.zig`: zoom keeps the coordinate under the cursor, never shows less than 2 frames or more than all; headless tests, 1 to 500,000 frames
- [ ] Ctrl+wheel zooms, Shift+wheel and middle drag pan, left drag scrubs, right drag scrubs finely, a key fits
- [ ] The strip, slider and buttons do all of that without modifiers (T2)
- [ ] The bar shows the timeline's hint while the mouse is over it
- [ ] The playhead stays in view while playing; a user's pan holds until it leaves
- [ ] Edited and reference marks use the window; overlapping ones come apart when zoomed
- [ ] Frame ticks at round numbers; the energy label has a unit where the format gives one, else none
- [ ] `--window A,B` for screenshots
