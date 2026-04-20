<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Review Bot Gate (t1382, GH#3827, GH#17541)

Before merging any PR, wait for AI code review bots (CodeRabbit, Gemini Code Assist,
etc.) to post their reviews. PRs merged before bots post lose security findings.

## Enforcement Layers

1. **CI**: `.github/workflows/review-bot-gate.yml` — required status check
2. **Pulse merge path**: `pulse-wrapper.sh` line 8243 — `review-bot-gate-helper.sh check` before merge (code-enforced since GH#17490)
3. **Worker merge path**: `full-loop-helper.sh merge` — `review-bot-gate-helper.sh wait` before merge (code-enforced since GH#17541)
4. **Branch protection**: add `review-bot-gate` as required check per repo

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
- PASS_RATE_LIMITED means bots are rate-limited but the PR exceeded the grace period (default 4h). Safe to merge — bot reviews will arrive later and can be addressed in follow-up PRs. Use `request-retry` to trigger a re-review once rate limits clear.
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
