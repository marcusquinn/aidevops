<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2393: Signature footer auto-append on all pulse + worker GitHub comments

## Origin

- **Created:** 2026-04-19
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none
- **Conversation context:** Maintainer asked whether all pulse + worker comments on GitHub issues/PRs can carry a signature so we can tell which app, version, and model wrote each one. t2115 (PR #19102) already enforced this for `gh issue create` / `gh pr create` via `_gh_wrapper_auto_sig` in `shared-constants.sh`. This task extends the same treatment to `gh issue comment` / `gh pr comment`.

## What

Two new wrappers in `shared-constants.sh`:

- `gh_issue_comment` — thin wrapper around `gh issue comment` that runs `_gh_wrapper_auto_sig` on the `--body` / `--body-file` args before the command is invoked.
- `gh_pr_comment`    — same for `gh pr comment`.

The wrappers must be drop-in: callers pass the same args they pass to `gh issue comment`/`gh pr comment`; the wrappers emit the same stdout/stderr and exit codes. No caller behaviour change is required; the only visible difference is that the posted comment ends with the standard `<!-- aidevops:sig -->` + signature block if the body didn't already contain one.

Migration sweep: route the largest comment-consolidation point (`_gh_idempotent_comment` in `pulse-triage.sh`) and every direct `gh issue comment` / `gh pr comment` call in pulse + worker + session-lifecycle scripts through the new wrappers. Existing manually-composed signatures keep working because `_gh_wrapper_auto_sig` dedups on the `<!-- aidevops:sig -->` marker.

## Why

Diagnostics. When a comment appears on an issue or PR, an operator (or the pulse itself, via `contribution-watch-helper.sh`, `backfill-origin-labels.sh`, `dispatch-dedup-cost.sh`) needs to know which runtime wrote it, which aidevops version was active, which model ran, and how much time + tokens the session spent. Today ~50% of our comment paths are unsigned (dispatch dedup ticks, stale-recovery escalations, watchdog kills, tier-escalation diagnostics, terminal blockers, claim/release audit comments). Signing them closes the diagnostic gap without any reader-side regression risk (see audit below).

## Tier

### Tier checklist

Answered for `tier:simple`:

- [ ] 2 or fewer files? NO — ~15–25 files touched.
- [x] Every target file under 500 lines? No — `shared-constants.sh` is 2265 lines; many helpers are 500+.
- [x] Exact oldString/newString for every edit? Yes, this brief documents them.
- [x] No judgment or design decisions? Correct — pattern mirrors t2115 exactly.
- [x] No error handling to design? Correct — existing helper handles failure by returning the original body.
- [x] No cross-package changes? Correct — single repo.
- [x] Estimate ≤ 1h? No — closer to 2h including tests + migration sweep.
- [x] 4 or fewer acceptance criteria? See below; 6 criteria.

**Selected tier:** `tier:standard`

**Tier rationale:** >2 files and >4 acceptance criteria disqualify `tier:simple`. Work is mechanical (pattern copy + sweep) with a well-defined regression-check surface, so `tier:standard` is sufficient — no architectural judgment required.

## How

### Files to modify

- **EDIT:** `.agents/scripts/shared-constants.sh` — add two wrappers next to `gh_create_issue` / `gh_create_pr` (around line 1019–1156). Model on those — same `_gh_wrapper_auto_sig` dispatch, minus the origin-label/assignee logic.
- **EDIT:** `.agents/scripts/pulse-triage.sh` (`_gh_idempotent_comment` at ~line 227) — replace `gh issue comment` / `gh pr comment` with `gh_issue_comment` / `gh_pr_comment`.
- **EDIT (sweep):** every other script in the inventory below — replace direct `gh issue comment "$X"` / `gh pr comment "$X"` invocations with the wrappers. Each script already sources `shared-constants.sh`.

**Sweep inventory** (direct callers per `grep 'gh issue comment\|gh pr comment' .agents/scripts/`):

- `worker-lifecycle-common.sh:790,858,1094`
- `tier-simple-body-shape-helper.sh:291`
- `pulse-nmr-approval.sh:527`
- `pulse-issue-reconcile.sh:1021,1334`
- `stats-quality-sweep.sh:1239`
- `routine-log-helper.sh:820`
- `pulse-simplification.sh:171`
- `pre-dispatch-validator-helper.sh:243`
- `interactive-session-helper.sh:312,533,634,1194,1251`
- `draft-response-helper.sh:1590,1592,1891,1893`
- `worker-watchdog.sh:920`
- `pulse-cleanup.sh:349`
- `full-loop-helper.sh:895,1011,1086`
- `pulse-merge.sh:142,162,258,496,1061,1099`
- `pulse-triage.sh:265,268,1202` (+ the `_gh_idempotent_comment` body)
- `dispatch-dedup-stale.sh:149,208,263,274`
- `review-bot-gate-helper.sh:782`
- `dispatch-dedup-cost.sh:178`
- `pulse-ancillary-dispatch.sh:148,638,978`
- `stuck-detection-helper.sh:369,496`
- `quality-feedback-issues-lib.sh:342,451`
- `approval-helper.sh:396,442,447`
- `circuit-breaker-helper.sh:592`
- `loop-common.sh:1122`

Exclude: `routine-comment-responder.sh:185` (string literal in agent prompt, not an executable call); `gh-signature-helper.sh:1475` (literal in documentation); all `.agents/scripts/tests/` stubs.

### Reference pattern

`.agents/scripts/shared-constants.sh:1019-1058` (`gh_create_issue`) and `:1140-1156` (`gh_create_pr`). Copy the `_gh_wrapper_auto_sig` invocation pattern. We drop the origin-label + assignee logic because those are creation-only concerns; comment posting just needs the sig.

### Tests

- **EDIT:** `.agents/scripts/tests/test-gh-wrapper-auto-sig.sh` — add cases for `gh_issue_comment` and `gh_pr_comment` covering: (a) body without sig gets one appended, (b) body already containing `<!-- aidevops:sig -->` does NOT get a second sig, (c) `--body-file` path appends sig to the file in place, (d) exit code matches the underlying `gh` call.
- **NEW:** `.agents/scripts/tests/test-comment-wrapper-marker-dedup.sh` — regression coverage: when `_gh_idempotent_comment` posts a comment and a signature is auto-appended, the next `grep -qF "$marker"` check still succeeds on the full body (marker at top, sig at bottom).

### Verification

```bash
# From worktree root:
.agents/scripts/tests/test-gh-wrapper-auto-sig.sh
.agents/scripts/tests/test-comment-wrapper-marker-dedup.sh
shellcheck .agents/scripts/shared-constants.sh .agents/scripts/pulse-triage.sh
.agents/scripts/linters-local.sh
```

## Acceptance Criteria

1. `gh_issue_comment` and `gh_pr_comment` exist in `shared-constants.sh` and emit the signature footer when missing, dedup when present.
2. `_gh_idempotent_comment` in `pulse-triage.sh` uses the new wrappers.
3. Every direct `gh issue comment` / `gh pr comment` call in the sweep inventory above now routes through the wrappers.
4. `test-gh-wrapper-auto-sig.sh` passes and includes comment-wrapper cases.
5. `test-comment-wrapper-marker-dedup.sh` passes and covers both `--body` and `--body-file` paths.
6. `shellcheck` zero-warning on every modified file, existing marker-based readers (`pulse-nmr-approval.sh`, `dispatch-dedup-stale.sh`, `_gh_idempotent_comment`, `check_terminal_blockers`) continue to match markers despite the appended footer — verified by replaying the existing test suites (`test-pulse-nmr-automation-signature.sh`, `test-stale-recovery-escalation.sh`, `test-pulse-labelless-reconcile.sh`, `test-pulse-merge-interactive-handover.sh`).

## Context

### Reader-side regression assessment (pre-agreed with maintainer)

Audited 100+ comment-reading sites. Findings:

- **Marker-detection readers** (`contains(marker)` / `test(marker)` / `grep -qF marker`) — unaffected because the HTML marker sits at the top of the body and the footer is appended at the end.
- **Signature-specific readers** (`dispatch-dedup-cost.sh::_sum_issue_token_spend`, `contribution-watch-helper.sh`, `backfill-origin-labels.sh`) — the change is strictly additive: they get more footers to parse, improving accuracy.
- **Body-length / size checks** — only `pulse-merge-carry-forward-diff.sh` truncates PR bodies (65KB cap). Footer adds ~200 chars, well under the threshold.
- **Terminal-blocker regex** (`_match_terminal_blocker_pattern`) — matches specific error phrases ("workflow scope", "ACTION REQUIRED") that do not appear in a signature footer.
- **Author filtering** — `.user.login` is orthogonal to body content.

No regression path identified. The change is strictly additive to what's already there.

### Prior art

- PR #19102 / t2115 — initial signature enforcement on `gh_create_issue` / `gh_create_pr`.
- PR #17932 / rule #8a — reader-side rule to skip signature content when reading GH threads.
- `gh-signature-helper.sh` — runtime-agnostic signature generator (OpenCode, Claude Code, Cursor, Windsurf, Aider, Continue, Copilot, Cody, Kilo Code, Augment, Factory Droid, Warp, Codex).
