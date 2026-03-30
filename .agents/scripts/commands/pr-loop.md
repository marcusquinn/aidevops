---
description: Iterate on PR until approved or merged
agent: Build+
mode: subagent
---

Monitor and iterate on a PR until it is approved or merged.

Arguments: $ARGUMENTS

## Usage

```bash
/pr-loop [--pr N] [--wait-for-ci] [--max-iterations N] [--no-auto-trigger]
```

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--pr <n>` | PR number (auto-detects from current branch if omitted) | auto |
| `--wait-for-ci` | Wait for CI checks before checking review status | false |
| `--max-iterations <n>` | Max check iterations | 10 |
| `--no-auto-trigger` | Disable automatic re-review trigger for stale reviews | false |

## Workflow

Each iteration checks:

1. **CI Status** — all GitHub Actions workflows
2. **Review Bot Gate (t1382)** — verify AI review bots have posted (see below)
3. **Review Status** — approvals or change requests
4. **Merge Readiness** — verify PR can be merged

**On issues:** CI failures → report and wait. Changes requested → verify before acting, then address valid feedback. Stale review → auto-trigger re-review (unless `--no-auto-trigger`).

**COMMENTED reviews:** Some bots (e.g., Gemini Code Assist) post as `COMMENTED` not `CHANGES_REQUESTED`, so `reviewDecision` stays `NONE`. The loop detects unresolved review threads and surfaces them.

### Review Bot Gate (t1382)

Before merge, verify at least one AI review bot has posted — prevents merging before bots finish analysis.

```bash
RESULT=$(~/.aidevops/agents/scripts/review-bot-gate-helper.sh check "$PR_NUMBER" "$REPO")
# Returns: PASS (bots found), WAITING (no bots yet), SKIP (label present)
```

| Result | Action |
|--------|--------|
| `WAITING` | Continue polling (most bots post within 2-5 min). `review-bot-gate` CI check also blocks at GitHub level. |
| `PASS` | Read bot reviews; address critical/security findings before merge. Non-critical → follow-up. |
| `SKIP` | PR has `skip-review-gate` label — proceed. |

**AI review verification:** See `Bot Reviewer Feedback` in `.agents/reference/session.md` and `AI Suggestion Verification` in `.agents/prompts/build.txt`.

## Completion Promises

| Outcome | Promise |
|---------|---------|
| PR approved | `<promise>PR_APPROVED</promise>` |
| PR merged | `<promise>PR_MERGED</promise>` |
| Max iterations reached | Exit with status report |

## Intelligent Timing

| Service Category | Initial Wait | Poll Interval |
|------------------|--------------|---------------|
| Fast (CodeFactor, Version) | 10s | 5s |
| Medium (SonarCloud, Codacy, Qlty) | 60s | 15s |
| Slow (CodeRabbit) | 120s | 30s |

## Examples

```bash
/pr-loop                              # Monitor current branch's PR
/pr-loop --pr 123 --wait-for-ci       # Specific PR, wait for CI
/pr-loop --pr 123 --max-iterations 20 # Extended monitoring
/pr-loop --no-auto-trigger            # Disable auto re-review
```

## State Tracking

Progress tracked in `.agents/loop-state/quality-loop.local.state` (PR number, iteration count, check results).

## Timeout Recovery

```bash
gh pr view --json state,reviewDecision,statusCheckRollup  # Check current status
```

Common blockers: CI still running (wait), review not completed (ping reviewer), failing checks (manual fix). Resume with `/pr review` (single cycle) or `/pr-loop` (restart loop).

## Related Commands

| Command | Purpose |
|---------|---------|
| `/pr review` | Single PR review (no loop) |
| `/pr create` | Create PR with pre-checks |
| `/preflight-loop` | Iterative preflight until passing |
| `/postflight-loop` | Monitor release health |
| `/full-loop` | Complete development cycle |
