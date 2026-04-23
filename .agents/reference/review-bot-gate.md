<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Review Bot Gate (t1382, GH#3827, GH#17541)

Before merging any PR, wait for AI code review bots (CodeRabbit, Gemini Code Assist,
etc.) to post their reviews. PRs merged before bots post lose security findings.

## Enforcement Layers

1. **CI**: `.github/workflows/review-bot-gate.yml` — required status check. Delegates
   to `review-bot-gate-helper.sh check` (vendored from marcusquinn/aidevops). Applies
   the t2139 settlement check, which defeats CodeRabbit's two-phase placeholder pattern.
   Re-triggers on `issue_comment:edited` so Phase 2 edits clear the gate automatically.
2. **Pulse merge path**: `pulse-wrapper.sh` line 8243 — `review-bot-gate-helper.sh check` before merge (code-enforced since GH#17490)
3. **Worker merge path**: `full-loop-helper.sh merge` — `review-bot-gate-helper.sh wait` before merge (code-enforced since GH#17541)
4. **Branch protection**: add `review-bot-gate` as required check per repo

All layers share the same `review-bot-gate-helper.sh` implementation — the settlement
check and rate-limit behaviour are consistent across CI and in-agent merge paths (GH#20493).

## Merge Commands

| Context | Command | Gate |
|---------|---------|------|
| Worker (full-loop) | `full-loop-helper.sh merge <PR> [REPO]` | Code-enforced `wait` |
| Pulse (deterministic) | Internal `_merge_ready_prs_for_repo` | Code-enforced `check` |
| Manual (interactive) | `review-bot-gate-helper.sh wait <PR> [REPO]` then `gh pr merge` | Prompt-level |

Workers MUST use `full-loop-helper.sh merge` — direct `gh pr merge` bypasses the gate (GH#17541).

## Workflow

- Before merging: run `review-bot-gate-helper.sh check <PR_NUMBER>`. If WAITING, poll up to 10 minutes. Most bots post within 2-5 minutes.
- If the PR has `skip-review-gate` label, bypass the gate (for docs-only PRs or repos without bots).
- In headless mode: if still WAITING after timeout, proceed but log a warning. The CI required check is the hard gate.
- ALWAYS read bot reviews before merging. Address critical/security findings; note non-critical suggestions for follow-up.
- PASS_RATE_LIMITED means bots are rate-limited and `rate_limit_behavior=pass` (default). Safe to merge — bot reviews will arrive later and can be addressed in follow-up PRs. Use `request-retry` to trigger a re-review once rate limits clear. External-contributor PRs are exempt: rate-limit grace is always disabled for them.
- When many PRs are rate-limited simultaneously, use `request-retry` on the highest-priority PRs first. Stagger retries to avoid re-triggering rate limits.

## Additive suggestion decision tree

When a review bot comments with a suggestion that isn't a correctness issue in the PR's own code:

1. **Is the suggestion a correctness fix for code introduced by this PR?**
   - Yes → expand the PR, add a commit, re-request review.
   - No → go to 2.

2. **Is the suggestion adding coverage, generality, new behaviour, or cosmetic improvements?**
   - Yes → file as follow-up task with `ref:GH#<current-PR>`.
   - No → skip (may be a nit; see `coderabbit-nits-ok` rule in `prompts/build.txt` §"Review Bot Gate").

3. **File follow-up via:**
   - Claim task ID (`claim-task-id.sh`).
   - Write brief in the current planning worktree.
   - File issue with worker-ready body + `Source: review comment on PR #<N> by @<bot>` citation.

### Example

PR #19712 (t2209) Gemini review suggested extending the duplicate-ID regex to cover declined tasks and routine IDs. This is additive (broader coverage), not a correctness fix for the PR's shipped behaviour. Filed as t2222 / #19723.

See also: `prompts/build.txt` §"Review Bot Gate (t1382)" for the authoritative rule and rationale.

## Composition with auto-merge paths

The review bot gate runs as the FINAL gate in `_check_pr_merge_gates` — after both the `origin:interactive` (t2411) and `origin:worker` worker-briefed (t2449) gates. This means:

- **`origin:interactive` PRs**: must pass draft/hold-for-review checks AND the review bot gate before auto-merge.
- **`origin:worker` PRs (maintainer-briefed, t2449)**: must pass the worker-briefed gates (issue-author-association, NMR crypto-vs-auto, draft, hold-for-review, no worker-takeover) AND the review bot gate before auto-merge. The `min_edit_lag_seconds` mechanism (t2139) ensures bot comments have settled before the merge fires — this prevents merging during CodeRabbit's two-phase placeholder window.
- **All other PRs**: the review bot gate is still the last check before merge.

The bot gate is NOT bypassed by either auto-merge path — it composes with them as a mandatory final check. The `hold-for-review` label blocks both auto-merge paths independently of the bot gate.
