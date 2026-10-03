<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Open issue backlog mission — 2026-10-03

## Authority and objective

The repository owner requested an unattended orchestrator mission to resolve all
solvable remaining open issues, complete full-loop verification and merges, make
intermediate releases when useful, and publish a final release. Preserve source,
permission, trust, billing, and worktree isolation boundaries. Do not mistake
closing an issue, dispatching a worker, or opening a PR for verified delivery.

## Baseline

- Repository: `marcusquinn/aidevops`; authenticated permission: admin/maintain/write.
- Initial inventory: 27 open issues and 8 open PRs.
- Persistent dashboards (not implementation backlog): #24670, #23855, #23404,
  #23126. Leave their routine-owned lifecycle intact.
- Pulse dispatch circuit: closed. Eligible work is repeatedly deferred by file
  overlap with stuck PRs: #33419 by #32618; #33356 by #32453.
- No issue-backed worker is launched by this mission before deduplication,
  source/brief verification, and scope assignment.

## Stable units and ownership

Concurrency cap: two independent mission workers; existing unrelated workers are
not stopped. Serialize shared-file work. Parent owns integration, review, merge,
issue disposition, release, and durable continuation.

| Unit | Issues / PRs | Scope / owner | Dependency | Tier | Status / reuse key |
|---|---|---|---|---|---|
| P1 | #33248 / #33271 | Runtime-pin helper; parent verification/merge | None | standard | Merged `f5ac9141c783`; routine-owned cleanup |
| P2 | #33150 / #33318 | Curated skill sync; parent verification/merge | None | standard | Merged `84b76dcf8468`; 36 checks and 418 links reverified |
| P3 | #33048 / #33052; #33110 | Pulse reconciliation refactor; mission child | None | standard | Repair exact head `fc6f263722`; initialize three multi-var declarations |
| P4 | #32618 / #32643 | Plugin provenance; parent verification/merge | W7 OC2 completion | standard | Merged `8aaf3b4b958b`; OC1/OC2 rows independently selected |
| P5 | #32644 / #32702 | On-demand tool loading; parent repair | P4 (shared plugin files) | standard | Failed import gate; head `c6d696c18e` |
| P6 | #32453 / #32459 | Canonical synchronization/health; mission child | None | standard | Repair/reverify exact head `144ecf9551`; historical failure is repository-wide debt |
| P7 | #32446 / #32457 | NanoGPT probe; parent review | None | standard | Draft offline harness; no recurring paid authority |
| P8 | closed #32682 / #32756 | Quoted body flags; parent dedup/repair | P4/P5 (plugin files) | standard | Held quality regression; head `f01227ebc1` |
| W1 | #33303 | Pre-edit manual-worker identity | None | standard | Pending scoped dispatch |
| W2 | #33113 | Old-bundle pulse refills | None; serialize runtime-library edits with W5 | standard | Missing auto-dispatch; verify current regression |
| W3 | #33356 | Targeted backup deletion | P6 (preservation docs) | standard | Pending; destructive execution stays opt-in |
| W4 | #33419 | Playwright artifact path handling | P4/P5 (plugin files) | standard | Pending; preserve external-directory boundary |
| W5 | #28838 / #33327 | Headless library debt / thread consolidation | W2 if shared runtime files | standard | Verify current file length before implementing |
| W6 | #33292 / #33441 | Browser-QA layout/viewport journey; parent | Supersedes closed #33436 | standard | Review green successor head `24a96b15a8`; do not duplicate prior repair |
| W7 | #32619 / #33440; #32622 / #33439 | OC2 observability; tool descriptions | P4/P5/P8 (plugin files) | standard | OC2 merged `f157e301057b`; descriptions await parent review |
| A1 | #33278, #32829, #32820, #32523, #32273 | Manual/upstream/runtime reviews; parent | Evidence-specific | standard | Research child unavailable; no inferred holds |
| A2 | #33139 | Framework value audit parent; parent decomposition | Inspect child acceptance/evidence | thinking | Never auto-dispatch parent directly |
| R1 | Final release | Canonical publisher lane; parent | All safely solvable units verified | standard | Explicit release authority from current request |

## Verification and completion

Use normal CLI/runtime paths, scoped lint and existing tests. High-risk changes
require runtime evidence and independent review. Review every included PR commit,
repair only terminal failures for the exact current head, and merge through the
full-loop helper. Existing PR issue closure requires the issue-close verifier.
No test infrastructure, guard bypasses, blanket permission grants, or spending
authority are introduced merely to finish the backlog.

For each unit, record verified disposition, immutable commit/PR evidence, tests,
remaining criteria, executor, next action, and wake condition. A real external
blocker remains open with its exact prerequisite; persistent dashboards remain
open by design. A checkpoint is continuation evidence, not mission completion.

## Verified delivery checkpoint — 2026-10-03 03:27 UTC

- #33318: exact head `307ea91038132165fe139fb8ab9033150fc9df37`, merged as
  `84b76dcf8468c7c3892a7d45fd855340dfbaf1e9`. Parent inspected curated import,
  registry ownership, scanner rejection propagation, exact retirement cleanup,
  and preservation of custom files. Re-ran 36 normal-flow regression assertions
  and all 418 nested skill links. Required checks and review gate passed.
- #33440: exact head `86ce47eefae114f74898da25c148cb403aae266c`, merged as
  `f157e301057ba0d6323174dc92f8fbeead7d0ad9`. Parent independently inspected
  released step-event projection, bounded tracking, malformed-event handling,
  replay deduplication and unchanged OC1 recording. Re-ran 49 focused checks;
  missing local dependencies were installed from the committed lockfile without
  lifecycle scripts. Review bundle:
  `e882c4430f0cc9513264bb33e66c65afa78917a00056ce4f17505f9df4fc2859`.
- Read-only production SQLite independently confirms OC2 row `1299159` has
  runtime `2.0.3`, adapter `opencode-v2@3.38.0`, and input/output `3/4`; OC1 row
  `1299197` has runtime `1.18.34`, adapter `opencode-v1@3.38.0`, and `3/4`.
  Final release/deployment remains pending; recheck fresh runtime acceptance at
  postflight rather than treating historical null rows as a backfill target.
- #33436 was closed unmerged by terminal CI-feedback routing. #33441 recovers
  its implementation and reduces Qlty smells; all reported checks are green at
  head `24a96b15a8434ba7ae255c42434ea0f514229614`. Parent review is next.
- P3 and P6 are the next independent repair units. Children own only their listed
  PR write surfaces, use fresh linked worktrees, preserve original commits, and
  fast-forward-update existing PR branches without force. They must not merge,
  release, edit this plan, delegate again, or weaken quality/security gates.
