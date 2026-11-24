# Coding standards

Read during review. Judgement calls only: formatting and tests are checked by
`.githooks/pre-commit` and CI. Terms are in `GLOSSARY.md`.

- **Handle the result of a commit.** `commit` says whether anything changed, and
  what the user is told depends on it.
- **One way to begin an edit.** Pausing, aborting a drag and starting the
  transaction belong in one place that every edit goes through.
- **Compare vectors by element** (`@reduce(.Or, a != b)`). A `Vec3` has padding,
  which byte comparison includes.
- **Logic goes in a headless module**, with its tests, as in `src/edit.zig` and
  `src/playback.zig`. `App.zig` connects modules to SDL and ImGui.
- **Failure paths have tests**: the state after an error is the state before it.
