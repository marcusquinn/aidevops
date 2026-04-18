<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2228: v3.8.71 lifecycle retrospective (umbrella parent-task)

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19734
**Tier:** n/a (parent-task — pulse never dispatches)

## What

Umbrella tracker for seven framework improvements surfaced during the v3.8.71 release lifecycle. Each child is independently dispatchable once its brief, TODO entry, and issue exist. This umbrella stays open until all seven children merge; it carries the `parent-task` label to block pulse dispatch unconditionally.

## Why

All seven incidents cost reviewer/agent time during a single interactive session (2026-04-18). None were one-off anomalies — each is a framework gap that will recur until fixed, and three are silent data-loss risks. Consolidating them under one umbrella makes the retrospective visible, trackable, and prevents the children from scattering.

## Children

| Priority | Task | Issue | Summary |
|---|---|---|---|
| HIGH | t2229 | #19735 | `.task-counter` silent regression on PR merge |
| MEDIUM | t2230 | #19743 | GitHub release workflow on tag push |
| MEDIUM | t2233 | #19737 | `version-manager.sh release` push retry loop |
| MEDIUM | t2235 | #19744 | Forbid task ID suffixes in `build.txt` |
| MEDIUM | t2236 | #19751 | Document `origin:interactive` auto-merge window |
| LOW | t2237 | #19752 | Pre-commit hook false positives on release commits |
| LOW | t2238 | #19753 | Curl retry in `validate-version-consistency.sh` |

## How

- **This PR (planning only)**: filing TODO entries + briefs for all 7 children + this umbrella. PR body uses `For #19734` (never `Closes` — t2046 parent-task rule).
- **Follow-up PRs**: each child merges independently. `#auto-dispatch` is applied to 5 of 7 mechanical fixes; two (t2229 `.task-counter`, t2237 pre-commit) carry option lists requiring maintainer choice.

## Acceptance criteria

- [x] Umbrella issue #19734 filed with full child table
- [x] All 7 children issues filed (#19735, #19737, #19743, #19744, #19751, #19752, #19753)
- [ ] All 7 briefs exist at `todo/tasks/tNNN-brief.md`
- [ ] All 7 TODO.md entries exist with `ref:GH#NNN`
- [ ] Planning PR merged with `For #19734`
- [ ] All 7 children merged
- [ ] Umbrella closed with a final comment linking the children's merged PRs

## Context

- Source lifecycle: PR #19708 (t2213 cloudron skill sync) + PR #19715 (t2214 gemini nits), release v3.8.71 commit `abe2e89fb9`.
- Retrospective conducted in the same session that produced both PRs, so context on each incident is first-hand.
- Two of the seven (t2229, t2230) could have prevented themselves — fixing them forward locks the feedback loop.
- Incidental: during claim allocation for this umbrella's children, a parallel session (#19736 et al.) created issues whose `tNNN:` title prefixes did not match the CAS-allocated IDs. Noted in the umbrella issue body; not filing a child for it since it's the brief drafter hardcoding expected IDs, not a CAS bug.
