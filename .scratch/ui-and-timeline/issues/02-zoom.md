# 02: Zoom, pan and the overview strip

**What to build:** The energy plot zooms from the whole run to single frames. An overview strip under it shows the window; drag it to pan, its edges to zoom. A slider and a fit button do the same (C5). Ticks and the energy's unit (audit 17).

**Blocked by:** None

**Status:** resolved

- [x] `window.zig`: zoom keeps the coordinate under the cursor, never shows less than 2 frames or more than all; headless tests, 1 to 500,000 frames
- [x] The wheel zooms (up is in), Shift+wheel and middle drag pan, left drag scrubs, right drag scrubs finely, a key fits
- [x] The strip, slider and buttons do all of that without modifiers (T2)
- [x] The bar shows the timeline's hint while the mouse is over it
- [x] While playing, the playhead runs to the middle and the plot then moves steadily under it; a user's pan holds
- [x] Edited and reference marks use the window; overlapping ones come apart when zoomed
- [x] Frame ticks at round numbers; the energy label has a unit where the format gives one, else none
- [x] `--window A,B` for screenshots

## Answer

src/data/window.zig (arithmetic, wheel, following), src/data/envelope.zig (per-column min and max, kept), src/app/plot.zig (drawing and input; was in timeline.zig). D27. The key is Z.

The following, two-frame, wheel and flat-line tests were written before the code they test, and failed to compile or failed without it; the rest of the window and envelope tests came with their code. Mouse gestures on the strip and the bar's hint have no tests; the user tried the wheel, zooming a 492,963-frame file, and following.

After the review: the energy scale is the whole run's, and changes only by Fit E (the user: values are delicate, only atoms interpolate).

Left: 8 lanes of a million points at the display rate (11).
