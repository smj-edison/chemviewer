# 01: Bad frames don't stall a trajectory

**What to build:** When a frame of a trajectory can't be read, the user stays on the last good frame and is told once which frame failed. Playback skips it, and prefetch and the energy plot carry on past it. Going back to it by hand tries again. See D24 (frame stream) and D8.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] The frame stream answers ready, pending or failed for each frame; a pending frame is never reported as failed
- [x] A failure names the frame that failed, even when it was only being prefetched
- [x] A failed frame is reported once, not on every UI update
- [x] Prefetch and the energy scan continue past a failed frame, without a hot loop
- [x] Playback skips a failed frame, with and without interpolation, and ends or loops normally if the last frame is the bad one
- [x] A failed frame is not retried automatically; navigating to it by hand retries it
- [x] Headless tests cover these with a source that fails on chosen frames, written to fail first

## Answer

Implemented: src/stream.zig (states, takeFailure, retry), src/playback.zig (skipping), wired in App. The timeline stays at a bad frame so stepping past works; see D24. App wiring (mouse, keys, status line) has no headless tests.
