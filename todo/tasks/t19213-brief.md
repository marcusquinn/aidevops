## What

Cut the per-issue cost of the partial-continuation in-review revisit (`_pmpc_revisit_in_review_issue` → `_pmpc_pr_may_own_issue`) by using the PR body and title already present in the issue timeline's `cross-referenced` events (`.source.issue.body`, `.source.issue.title`) instead of one or two `gh_pr_view` reads per walked PR.

## Why (evidence, 2026-11-20)

- A production drain of one private high-volume repo's in-review backlog through `_pmpc_revisit_in_review_issue` took about 16s per issue (70 issues in about 1,150s). The Pulse gives the whole partial-continuation pass about 15s per repo per stale-blocked sweep, so the in-review backstop covers about one issue per pass.
- Each walked merged PR costs `gh_pr_view --json body` plus sometimes `--json title` in `_pmpc_pr_may_own_issue`, for up to `PULSE_PARTIAL_REVISIT_MAX_PRS` (10) PRs per issue.
- The timeline response already includes them: a read-only check on one in-review issue returned 5 cross-referenced events, 3 merged PRs, and a non-null `body`/`title` on all 5.
- GH#39491 (t19212) made the merged-PR lane the fast path; this makes the backstop cheap enough to finish within the cadence.

## How

1. In `_pmpc_revisit_in_review_issue` (`.agents/scripts/pulse-merge-partial-continuation.sh`), emit `number`, `body` and `title` per merged cross-referenced PR from the timeline jq (for example base64 or `@json` per line, so newlines survive).
2. Give `_pmpc_pr_may_own_issue` optional body/title arguments. When supplied, pass the body to `_extract_linked_issue`, `_pmpc_pr_body_has_closing_ref` and `_extract_pr_work_issue` (each already accepts a supplied body; check `_extract_pr_work_issue`'s signature), and use the supplied title for the `^(t|GH#)N` check. Keep the live-read path when a field is missing or non-string (fail to the guard as today).
3. Leave `_pm_restore_partial_continuation` (the guard) unchanged: it re-reads everything fresh before any write.

## Files Scope

- `.agents/scripts/pulse-merge-partial-continuation.sh`
- `.agents/scripts/tests/test-pulse-merge-partial-continuation.sh`

## Acceptance

- The revisit walk makes no `gh_pr_view` body/title reads for PRs whose timeline entry carries both fields; existing GH#38869/GH#39254 skip semantics are unchanged.
- `test-pulse-merge-partial-continuation.sh` passes (adjust the existing timeline fixtures to include body/title where a case depends on the live read); ShellCheck clean.

## Verification

`bash .agents/scripts/tests/test-pulse-merge-partial-continuation.sh`; `shellcheck .agents/scripts/pulse-merge-partial-continuation.sh`; time one `_pmpc_revisit_in_review_issue` call on a repo with several cross-referenced merged PRs before/after (read-only via stubbed `set_issue_status`/`gh_issue_comment`).
