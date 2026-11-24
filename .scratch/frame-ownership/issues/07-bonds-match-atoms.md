# 07: Bonds always match the atoms

**What to build:** The displayed geometry becomes the one place that answers which atoms and bonds are on screen, derived from the edit session. Any edit sees bonds that match the atoms it edits. See D24 (displayed geometry) and D14.

Reproduced today: adding a water fragment with `--add` and then setting its O-H distance with `--set` moves the oxygen without its second hydrogen; opened directly, they move together.

**Blocked by:** 02 (Edits go through one edit session), 03 (Drags abort cleanly)

**Status:** ready-for-agent

- [ ] `--add` followed by `--set` on the fragment moves the attached group, as when the fragment is opened directly
- [ ] Delete followed at once by a click, Ctrl+A or another edit never uses old bonds or indexes out of range
- [ ] Bonds also follow drags, undo, redo, revert and changes to the bond cut-off
- [ ] Nothing edits the displayed geometry directly
- [ ] Bonds aren't searched again when nothing changed, and large trajectories play as fast as before
- [ ] The module doesn't depend on SDL, ImGui or Vulkan; headless tests are written to fail first, including the `--add` case
