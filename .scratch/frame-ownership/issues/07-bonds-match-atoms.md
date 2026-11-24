# 07: Bonds always match the atoms

**What to build:** The displayed geometry becomes the one place that answers which atoms and bonds are on screen, derived from the edit session. Any edit sees bonds that match the atoms it edits. See D24 (displayed geometry) and D14.

Reproduced today: adding a water fragment with `--add` and then setting its O-H distance with `--set` moves the oxygen without its second hydrogen; opened directly, they move together.

**Blocked by:** 02 (Edits go through one edit session), 03 (Drags abort cleanly)

**Status:** resolved

- [x] `--add` followed by `--set` on the fragment moves the attached group, as when the fragment is opened directly
- [x] Delete followed at once by a click, Ctrl+A or another edit never uses old bonds or indexes out of range
- [x] Bonds also follow drags, undo, redo, revert and changes to the bond cut-off
- [x] Nothing edits the displayed geometry directly
- [ ] Bonds aren't searched again when nothing changed, and large trajectories play as fast as before
- [x] The module doesn't depend on SDL, ImGui or Vulkan; headless tests are written to fail first, including the `--add` case

## Answer

Implemented: `BondedAtoms` in src/display.zig, used for the displayed geometry (`Document.display`) and a diff's reference. Bonds are found when asked for and kept until the atoms or the cut-off change. `bonds_dirty` is gone: `update` compares `changes`. A drag changes its transaction's atoms and shows those. The diff follows the shown frame at once, so a click in an overlay right after a delete is safe.

Seen failing first: `--add` then `--set`, bonds following everything, a delete followed at once (the last two on the first check already, since nothing searched for bonds in App tests before), an unmoved drag searching again, a diff out of memory. Not seen failing: the display.zig tests (written with it), a delete in a diff overlay, an edit whose search fails (it makes every allocation fail, so it doesn't single out the search).

Open: bonds aren't searched again when nothing changed (tested), but playback speed on a large trajectory wasn't measured. By reading, each shown frame is searched once, as before, and the reference no longer is.

"Nothing edits it directly" is by convention: `frame` is readable, and written only through `show`, `move` and `hide`.
