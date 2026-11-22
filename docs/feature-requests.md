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
  *Revised after discussion: a single selected atom is the base. Alt-dragging
  an unselected atom swings its branch around it. Alt-dragging a selected atom
  moves the whole selection about its centre, so a pasted fragment always
  moves as one piece. An explicit pivot (e.g. Alt+click) could be added later
  for groups that bonds can't separate.*
- [x] Design theme with color-blind awareness. For example, single to double
  to triple gradient should increase in brightness, so both color blindness
  and converting to grayscale work (the latter is common in publication).
  *Bond gradients done on the kurzgesagt-style branch: in both themes the
  lightness moves steadily away from the background from no bond to triple
  (light: darker, dark: brighter), so order reads from lightness alone in
  greyscale and for any colour vision; a unit test enforces it. On a light
  background "brighter = stronger" would reverse against the fade of weak
  contacts, hence darker.*
  *Element colours re-chosen by simulating protanopia, deuteranopia and
  tritanopia (Machado et al. 2009) and maximising the worst-case OKLab
  distance between elements that bond, within each element's familiar hue.
  Bonded pairs (Au-P, Au-S, C-N, C-O, O-P, ...) now stay apart in all four;
  before, Au-F, C-Cl (tritanopia) and Au-S were near-identical. Remaining
  close pairs are rare neighbours: Cl-F, N-I, O-Br, Au-F. Comparison
  renders: renders/colorblind/.*
- [x] Shift right-click and shift-middle click should match shift left-click
  (e.g. panning)
  *Shift with any button pans (Shift+middle already did, since middle pans).
  With Alt, Shift+right now translates the group too.*
- [x] Get rid of plus and minus buttons for adjusting bond and angle lengths
  *Removed; type a value and press Enter.*
- [x] Single clicking bonds doesn't make sense, in fact the concept of selecting
  bonds doesn't really make sense. The only affordance they should have is double
  clicking to have them cut. The cut checkbox doesn't make sense either anymore.
  *Bonds can't be selected any more: a single click on a bond does nothing,
  a double click cuts or restores it. The cut checkboxes, the X key and the
  Edit > Cut / restore menu item are gone; Edit > Restore all cut bonds stays.*
