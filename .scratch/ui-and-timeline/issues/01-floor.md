# 01: Pausing and editing floor

**What to build:** Stopping an interpolated playback, or editing during one, lands on the frame at or before the playhead, never the next one. See "Flooring" in the spec; changes D24 (nearest).

**Blocked by:** None

**Status:** ready-for-agent

- [ ] Pausing at 0.7 between frames 4 and 5 shows frame 4, and the timeline position is 4
- [ ] The same for an edit, a save, undo and revert
- [ ] Playing on from there starts at frame 4
- [ ] The Interpolate tooltip and D24 say so
- [ ] Existing tests that expect the nearest frame are changed deliberately, each one named in the answer
