# 01: Pausing and editing floor

**What to build:** Stopping an interpolated playback, or editing during one, lands on the frame at or before the playhead, never the next one. See "Flooring" in the spec; changes D24 (nearest).

**Blocked by:** None

**Status:** resolved

- [x] Pausing at 0.7 between frames 4 and 5 shows frame 4, and the timeline position is 4
- [x] The same for an edit, a save, undo and revert
- [x] Playing on from there starts at frame 4
- [x] The Interpolate tooltip and D24 say so
- [x] Existing tests that expect the nearest frame are changed deliberately, each one named in the answer

## Answer

`togglePlay` and `stopForEdit` in src/app/App.zig; `showNearerNext` and `DisplayedGeometry.takeNext` are gone, and a check in delete that only they made necessary.

Seen failing before the code, with the old names where they changed: "an edit during interpolated playback pauses it and applies to the nearest step", "pausing shows the nearest step at once", "an edit that lands on another step uses its bonds", "landing on the next step of a blend leaves the frame and its cuts" (cuts now stay), "measured values during a blend are those of what is drawn", "an edit that lands on the next step follows it there before unlocking", "a drag grabs the atom that was drawn under the cursor"; and the new "saving during a blend saves the step it plays from". Undo and revert floored already.
