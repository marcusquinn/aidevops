# t2388 — Nudge parent-task issues with no filed children

**Session origin:** interactive (2026-04-19 diagnostic audit on 17 open issues)

**Issue:** GH#19927

## What

Extend `reconcile_completed_parent_tasks` in
`.agents/scripts/pulse-issue-reconcile.sh` (function starts at line 997)
to post a one-time idempotent decomposition-nudge comment on `parent-task`
issues that have zero filed children. The parent currently has two signals
fighting each other: (1) the `parent-task` label unconditionally blocks
dispatch (correct — see `dispatch-dedup-helper.sh` `PARENT_TASK_BLOCKED`),
and (2) no children exist to do the work. The existing scanner silently
`continue`s on empty `$child_nums` at line 1040, so the maintainer never
gets a prompt to decompose.

Fix: when the scanner detects a parent with zero children, post one nudge
comment with marker `<!-- parent-needs-decomposition -->` explaining the
stall and listing the two options (file children under a `## Children`
heading, OR remove the `parent-task` label). Idempotent: re-runs skip any
parent already nudged.

## Why

Observed 4 stranded issues on 2026-04-19: #19808 (t2264 PR scope-leak
decomposition designed but not filed), #19858 (override-flags audit —
designed as parent but no children filed), #19859 (gh-audit-log — same
pattern), #19874 (claim-task-id race investigation — probably should not
be a parent at all). All four:

- Have the `parent-task` label — dispatch blocked.
- Have ZERO filed children — no progress possible.
- Have ZERO signal to the maintainer that they need attention.

This is a silent failure mode: the issues simply sit there forever.
Adding a nudge closes the observability gap. Workers and the maintainer
reading the pulse will see the "NEEDS DECOMPOSITION" comments and act.

## How

Edit `.agents/scripts/pulse-issue-reconcile.sh`:

1. Add a new helper `_post_parent_decomposition_nudge` near
   `_try_close_parent_tracker` (around line 953) that:

   - Takes `slug`, `parent_num`, `parent_title`, `parent_body` as arguments.
   - Does an idempotency check for the marker
     `<!-- parent-needs-decomposition -->` via
     `gh api repos/SLUG/issues/N/comments --jq '[.[] | select(.body | contains(MARKER))] | length'`.
   - Returns 1 (no-op) if the marker is already present.
   - Posts a templated comment explaining:
     - This parent has the `parent-task` label, which unconditionally
       blocks dispatch.
     - No children are filed (no `## Children` / `## Sub-tasks` /
       `## Child issues` section, or empty section, or empty sub-issue
       graph).
     - The maintainer has two options: (a) file children under one of
       the recognised headings with `#NNNN` references, or (b) remove
       the `parent-task` label so the pulse can dispatch this issue
       directly.
     - Links to the relevant docs (`.agents/AGENTS.md` Parent /
       meta tasks section).
   - Returns 0 after posting.

2. In `reconcile_completed_parent_tasks` (the main scanner), after the
   existing child-detection path and BEFORE the silent continue on empty
   `$child_nums`, call the nudge helper. Only call if body-section
   extraction also yielded empty (i.e., both graph AND body produced
   zero children). Rate-limit nudges per cycle to 5 (match the `max_closes`
   cap pattern already in the function).

3. Track nudge count in a new local `total_nudged` counter, log it at
   function end alongside `total_closed`.

## Verification

1. **Structural test** in a new file
   `.agents/scripts/tests/test-pulse-parent-nudge.sh`:
   - Extract `_post_parent_decomposition_nudge` via awk, verify:
     - It checks for the `<!-- parent-needs-decomposition -->` marker.
     - It calls `gh issue comment` with the marker in the body.
     - The function exits 1 (no-op) before the `gh issue comment` call
       when the marker lookup returns a positive count.
   - Extract `reconcile_completed_parent_tasks` and verify:
     - The nudge helper is called when `child_nums` is empty.
     - The rate-limit cap (5 or similar) gates the nudge path.

2. **Shellcheck:** `shellcheck .agents/scripts/pulse-issue-reconcile.sh`.

## Acceptance Criteria

- [ ] `_post_parent_decomposition_nudge` helper added to
  `pulse-issue-reconcile.sh` with idempotency via the
  `<!-- parent-needs-decomposition -->` marker.
- [ ] `reconcile_completed_parent_tasks` calls the helper when
  both sub-issue graph AND body-section yield zero children.
- [ ] Per-cycle rate-limit (max 5 nudges per pulse) prevents noise.
- [ ] Structural tests pass.
- [ ] Shellcheck clean.

## Context

- **Companion fixes:** t2386 (PR #19909, NMR preservation), t2387
  (PR #19918, no_work skip). Together these form the 2026-04-19
  diagnostic audit framework bundle.
- **Related:** GH#19736 (t2228 — parent with already-filed children, 2
  still open due to no_work failures that t2387 addresses).
- **Blocks on:** nothing — independent edit to `pulse-issue-reconcile.sh`.

## PR Conventions

Leaf issue (not parent-task). Use `Resolves #19927` in PR body.
