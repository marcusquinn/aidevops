# Review Bot Gate (t1382, GH#3827)

Before merging any PR, wait for AI code review bots (CodeRabbit, Gemini Code Assist,
etc.) to post their reviews. PRs merged before bots post lose security findings.

## Enforcement Layers

1. **CI**: `.github/workflows/review-bot-gate.yml` — required status check
2. **Agent**: `review-bot-gate-helper.sh check <PR> [REPO]` — returns PASS/PASS_RATE_LIMITED/WAITING/SKIP
3. **Branch protection**: add `review-bot-gate` as required check per repo

## Workflow

- Before merging: run `review-bot-gate-helper.sh check <PR_NUMBER>`. If WAITING, poll up to 10 minutes. Most bots post within 2-5 minutes.
- If the PR has `skip-review-gate` label, bypass the gate (for docs-only PRs or repos without bots).
- In headless mode: if still WAITING after timeout, proceed but log a warning. The CI required check is the hard gate.
- ALWAYS read bot reviews before merging. Address critical/security findings; note non-critical suggestions for follow-up.
- PASS_RATE_LIMITED means bots are rate-limited but the PR exceeded the grace period (default 4h). Safe to merge — bot reviews will arrive later and can be addressed in follow-up PRs. Use `request-retry` to trigger a re-review once rate limits clear.
- When many PRs are rate-limited simultaneously, use `request-retry` on the highest-priority PRs first. Stagger retries to avoid re-triggering rate limits.
