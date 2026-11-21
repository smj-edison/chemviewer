# Feature requests

Ideas noted while using the viewer. Status notes in *italics* are added when
something is picked up.

- [x] Option to show atom numbers
  *View > Atom numbers or N (`--atom-numbers` on the CLI). 1-based, with a
  halo; labels are hidden by atoms in front of them (fading when partly
  covered); skipped above 5000 atoms.*
- [ ] Timeline scrubbing should update immediately instead of waiting for scrubbing to stop
  *Couldn't reproduce headlessly: a scripted scrub updates on the next loop
  iteration for the in-memory IRC log and keeps up with metad.traj. Two
  latency fixes are in: frames are requested the moment the timeline moves,
  and the background energy scan yields every 32 frames instead of 256.
  If it still lags, note the file, whether it's a debug build (`zig build
  run`) or `-Doptimize=ReleaseFast`, and whether it's the slider or the
  energy plot.*
- [x] Double click on bond to toggle being ignored
  *Double-clicking a bond toggles its cut (same as X). Clicking a bond selects
  only the bond, not its atoms.*
- [x] Moving a group based on a reference atom should always move relative to the
  first selected atom (I ran into an issue where I 1. selected an atom, and 2.
  used a lasso selection, but the lasso selection didn't rotate relative to
  the first selected atom.)
  *The first selected atom is now always the base. Alt-dragging an atom of
  the selection moves the rest of the selection around the base; an
  unselected atom moves its branch beyond the base; grabbing the base itself
  moves the selection about its centre.*
