# Timeline: spec

Status: needs-triage (waiting for the user's review; no code before that)

From `decisions.md` section 4, `audit.md` (2, 17, T1 to T6) and what the test run's
files contain. Everything in section 4 holds unless "Changes" below says otherwise.

## Problem

The timeline shows one thing, the trajectory's energy, against the frame number. A
metadynamics run has dozens of quantities in other files, written at other
intervals. Today they can't be seen beside the structure, and with 500,000 frames
one pixel covers hundreds of them.

## What the user can do

1. Attach COLVAR, HILLS, md.log or any table with a header; pick columns in a tree.
2. See them in lanes under the energy, sharing one axis and playhead.
3. Trust where they sit: each file says how it was lined up with the frames, and why.
4. Choose what the axis is: frame, time, reaction coordinate, or a monotonic column.
5. Zoom from the whole run to single frames, by mouse, strip or keys.
6. Read every value at the playhead, and see which no longer describe the structure.
7. Find all of it again next time.

## What the test run taught

`mlip/snapshot`, checked 2026-11-24:

| File | Rows | Interval | Ends at |
|---|---|---|---|
| metad.traj | 492,963 frames | 5 fs (not in the file) | 2,464,810 fs |
| COLVAR | 49,299 | 50 fs | 2,464,900 fs |
| md.log | 49,296 | 0.05 ps | 2,464.75 ps |
| HILLS | about 24,650 | 100 fs, from 100 | 2,464,900 fs |

- The files end at different times: the run was stopped while they were being
  written. COLVAR goes past the last frame, md.log stops before it.
- **Equal spans is wrong here**, by 12 frames at md.log's end and 18 at COLVAR's.
- **Energies match exactly:** md.log's Epot (4 decimals) is frame 10 x row's energy
  in all 8 rows tried, from the first to the last.
- COLVAR has no energies, but shares a clock with md.log once the units are known.
- There is no plumed.dat. The unit is in `plumed.log` ("time: fs = 0.001 ps"), and in
  a string in `run_trajectory.py`, which we don't read.
- Every file is regular: no rewinds, gaps or repeated headers. Those need made-up
  test files.

## Changes to what was agreed (please confirm)

- **C1. Alignment is proposed in this order:** (1) energies; (2) the clock of a file
  that is already aligned, with both time units known; (3) the nearest whole number
  of frames per row, if it is within 1%; (4) equal spans, last and marked "guess".
  Agreed was: energies, else equal spans.
- **C2. Files may extend past the trajectory at either end.** The rows past it are
  hatched, not grey (T3).
- **C3. plumed.log is read for its unit lines only**; its other contents aren't data.
- **C4. The axis is chosen in a menu at the axis's left end** (T1), not by radio
  buttons in the tree. Columns that can't be an axis are greyed there, with why.
- **C5. The overview strip and a zoom slider do everything the modifiers do** (T2).

## Terms (for GLOSSARY.md)

- **Source**: an attached data file, as read. Never changed.
- **Series**: one column of a source, or a computed one; values at rows.
- **Row position**: where a row of a source sits among the frames, as a frame
  number that may be fractional.
- **Alignment**: the rule giving a source its row positions, with its evidence.
  Proposed, then confirmed by the user.
- **Coordinate**: what the axis measures.
- **Lane**: one plot of the timeline, with one or more series.
- **View window**: the part of the axis that is visible.
- **Stale**: describing a frame that has since been edited.

## Design

Headless modules with their tests; `src/app/` only draws and forwards input.

- `src/data/table.zig`: reads PLUMED `#! FIELDS` (again after a restart; `SET` lines
  kept), ASE MDLogger (units from its header) and generic columns. Streams; a bad
  row is skipped and counted. Numbers are `f64`.
- `src/data/source.zig`: a source being read by `io.concurrent`, published in blocks,
  so the UI never waits. Cancelled like the frame stream.
- `src/data/pyramid.zig`: min and max per block at each level, so a lane costs a few
  values per pixel whatever the zoom.
- `src/data/align.zig`: `propose(source, frames) -> Alignment{ rule, evidence,
  confirmed }`, and row position to and from row.
- `src/data/axis.zig`: coordinate to and from frame, the floor, monotonic checks.
- `src/data/window.zig`: view window to and from pixels, zoom at a point, pan, fit.
- `src/data/layout.zig`: lanes and what is in them; drag and share rules; text form.
- `src/app/timeline.zig` is split: `timeline.zig` (transport, panel), `lanes.zig`.

**Alignment by energy.** For a candidate ratio k (1 to 10,000 frames per row) and
offset, compare the rows spread over the file with frame energies, to the printed
precision. Accepted if all of at least 8 distinct values match. Constant or too few
energies prove nothing: go to the next rule. It runs as the energy scan arrives.

**Flooring.** At playhead p a series reads the last row with position <= p; before the
first row it reads nothing ("-"), not the first value.

**Stale.** A series row is stale if the frame its position floors to is edited. The
trajectory's own energy for an edited frame is stale, not missing.

**Remembered** in the app's config, by absolute path with size and modification time:
attached files, alignments, units, lanes, coordinate, view window. Not in the
user's data directories.

## Not in this spec

Computed series, ORCA IRC, following growing files, reading HDF5 or EDR, editing data,
saving ASE trajectories (on the request list).

## Testing

Headless tests per module, on small made-up files: rewinds, repeated headers, bad
rows, NaN, one row, no rows, more rows than frames, non-monotonic time, CRLF.
`--data FILE` (repeatable), `--axis NAME` and `--window A,B` for screenshots. Every new
kind of window is also checked at display scale 1.5.

Done when the test run attaches COLVAR, HILLS and md.log with the alignments above
and no hand edits except confirming, and 8 lanes of a million points draw at the
display rate in a release build.
