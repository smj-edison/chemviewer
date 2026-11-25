# Feature requests

Ideas noted while using the viewer. Status notes in *italics* are added when
something is picked up.

- [x] Option to show atom numbers
  *View > Atom numbers or N (`--atom-numbers` on the CLI). 1-based, with a
  halo; labels are hidden by atoms in front of them (fading when partly
  covered); skipped above 5000 atoms.*
- [x] Timeline scrubbing should update immediately instead of waiting for scrubbing to stop
  *Couldn't reproduce headlessly: a scripted scrub updates on the next loop
  iteration for the in-memory IRC log and keeps up with metad.traj. Two
  latency fixes are in: frames are requested the moment the timeline moves,
  and the background energy scan yields every 32 frames instead of 256.
  If it still lags, note the file, whether it's a debug build (`zig build
  run`) or `-Doptimize=ReleaseFast`, and whether it's the slider or the
  energy plot.*
  *Confirmed gone by the user, 2026-11-24.*
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
- [x] IRC files aren't read based on normal convention, e.g. the peaks should
  meet at the middle, and then get lower as the energy profile travels left
  or right along the reaction coordinate.
  *Gaussian IRC logs now run reverse endpoint, TS, forward endpoint, as in
  Gaussian's summary table. Geometries that aren't path points (such as the
  endpoint printed again at the end) are dropped. The plot is still by frame,
  so the TS is off-centre when the two paths differ in length.*
- [x] When there's only a few frames (like 6), the timeline line desynchronizes
  from the energy line.
  *The energy line, playhead and mouse now share one mapping from frame to x,
  and short files are drawn as a line through the frames.*
- [x] Make space the default background. Also have a "none" background.
  *Display > Background: None / Space / Cells, replacing the pattern checkbox
  (`--backdrop none|space|cells`).*
- [x] Discussion point (not settled but I want to remember it): do we need
  a timeline slider as well as the energy timeline? It might be simpler to
  just have the timeline, along with a frame count above/below. That way the
  frame number could also be copied.
  *Settled: the slider is gone. The frame number is a field next to the play
  buttons: type a number and press Enter, or select and copy it.*
- [x] Right-click scrubbing moves one frame per-pixel. Maybe wrap mouse around?
  *There was no right-click scrubbing, so this is read as a request: right-drag
  on the energy plot moves one frame per pixel. The pointer is hidden
  and captured while dragging (Wayland can't wrap it), so the screen edge
  doesn't stop it. Not yet tried with a real mouse.*
- [x] Could you add a checkbox for "rotation lock", where when you go from
  one frame to the next, it finds the closest matching rotation, similar
  to the diff, but only for a single view?
  *"Lock rotation", next to Loop and Interpolate above the energy plot
  (`--lock-rotation` on the CLI). It matches each frame to the one shown when
  it was switched on, rather than to the previous frame, so a frame looks the
  same however you reach it. Interpolated playback used to swing between
  steps and snap back at each one; fixed.*
- [x] The UI contrast between the slider knob and the text isn't great.
  *Knob colours re-chosen in all four themes (light, dark, Aero light/dark):
  at least 4.5:1 against the text on top and 2:1 against the track. Comparison:
  renders/slider-contrast/compare.png.*
- [x] Make chemviewer installable with a desktop entry. I don't feel strongly
  about an icon, but it might be nice to have a glass rendering of something
  like H2O or CH4 to make it look distinctive. Could you also make an AUR
  build for it so I can install it on my computer, as well as upgrade it?
  *`packaging/aur/PKGBUILD` (chemviewer-git): `makepkg -Csi` installs, and
  again upgrades, from the latest commit on GitHub. Includes a desktop entry,
  a glass H2O icon and the .xyz/.gjf/.traj file types (.log, .inp and .out are
  too generic to claim). Not published to the AUR: that needs the user's AUR
  account, and the project has no license yet.*
- [ ] Split Flat + checkbox into Flat and Flat+. Remove aero background. Double
  check contrast for all text for all themes. Make Flat's bigger atoms not quite
  as relatively big (the gold in particular stands out.) Also in the File
  section, why do you have the atom types with their atomic number? Shouldn't it
  just be the type of atom? The Display section should also be collapsable. Also
  what does the Unit Cell view do? Also using the UI scale slider is impossible,
  since the UI shifts while it adjusts. Wait until the user lets go before
  adjusting. The Mouse and Key section is also really hard to read, be sure to
  separate parts with enters.
  *Done, to be tried by hand: Flat and Flat+, gold in Flat 1.3x carbon (was
  1.65x), Aero without its sky, all text at least 4.5:1 (checked by a test),
  "34 C" in the element key (it was a count), File/Bonds/Display collapse and are
  remembered, "Unit cell box" says when there is none (it draws the periodic box),
  UI scale applies on release, Mouse & keys is a table. Agreed in
  `.scratch/ui-and-timeline/decisions.md`.*
- [x] Audit current UI design based on the principles in "The Design of Everyday
  Things." Make sure we have signifiers for standard things and progressive
  discoverability for others. Also make sure we avoid modes as much as
  reasonably possible.
  *Done: report and what was picked in `.scratch/ui-and-timeline/audit.md`.
  Findings 17 and T1 to T6 go into the timeline spec.*
- [x] Small visual glitch in Cel display style. If you look at the root where a bond
  joins with an atom, you can see a black halo around the bond, but it should appear
  to be a filled cylinder with the bond embedded inside of it.
  *Done: a bond's outline is not drawn over its own two atoms, and an atom's
  outline no longer pokes through bonds that enter from the side.*
- [x] Adjust mouse buttons with Alt. Alt + Left should translate, Alt + Right should
  rotate along the bond axis, and Alt + Center should rotate around the center atom.
  Also, when a single atom is selected, it should have a tooltip in the bar above
  the timeline where it describes what mouse button does what operation.
  *Done (D17): the bar shows the hint for every selection. Messages are inline
  in that bar and fade; refusals and errors are marked and last longer.*
- [ ] Design discussion: I'd like to be able to have multiple values plotted in
  the timeline, both overlayed on one timeline, and with multiple timelines. I'd
  like to be able to ingest data from PLUMED log files, ASE dynamics logs, and
  such. This does mean that the scrubber will need to be based on time when more
  than one data source is there (or maybe have the smallest step size be based
  on the smallest step size of the combined data, but still allow for the, user
  to see things in terms of frames and edit the frame number.) This also means
  there needs to be a data ingestion interface, where someone could a folder,
  and/or multiple files. Then the data ingestion would have a tree view, with
  subsets of data under a tree branch (for example with PLUMED, you could select
  what types of data you want plotted.) Being able to reopen the ingestion panel
  should be easy later on, and so should organizing graphs. The timeline will
  probably also need a zoom feature. I have a feeling taking navgation ideas
  from video editors would be a good start.
  *Spec and tickets in `.scratch/ui-and-timeline/`; waiting for review.*
- [ ] Right dragging up and down in the molecule view is reversed.
  *Asked for in conversation, 2026-11-24; for later. Now up is closer.*
- [ ] Saving as an ASE trajectory (.traj), as well as XYZ.
  *Asked for in conversation, 2026-11-24; for later.*
