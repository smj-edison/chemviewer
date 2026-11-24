# chemviewer

## Working here

- Change files with Edit and Write; keep each Bash call to one step.
- Build and test with `zig build test --error-style minimal`: the default repeats full command lines on errors.
- `src/app/App.zig` is long: find the functions you need, then read those line ranges.
- To test App behaviour without a window, use `TestApp` at the end of `src/app/App.zig`.
- Reviewing code: check it against `CODING_STANDARDS.md`.
- In a new clone, run `git config core.hooksPath .githooks`.

## Agent skills

### Issue tracker

Specs and tickets are local markdown under `.scratch/`; `docs/feature-requests.md` is the user's inbox. Before closing a ticket, and for everything else about them, see `docs/agents/issue-tracker.md`.

### Triage labels

The five default roles, recorded as `Status:` lines. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context; decisions are in `docs/DECISIONS.md`. See `docs/agents/domain.md`.
