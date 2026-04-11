---
description: Iterate on PR until approved or merged
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Monitor and iterate on a PR until it is approved or merged. Arguments: $ARGUMENTS

## Usage

```bash
/pr-loop [--pr N] [--wait-for-ci] [--max-iterations N] [--no-auto-trigger]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--pr <n>` | auto | PR number (auto-detects from current branch) |
| `--wait-for-ci` | false | Wait for CI before checking review status |
| `--max-iterations <n>` | 10 | Max check iterations |
| `--no-auto-trigger` | false | Disable auto re-review for stale reviews |

## Workflow

Each iteration checks: CI Status → Review Bot Gate (t1382) → Review Status → Merge Readiness.

**On issues:** CI failures → report and wait. Changes requested → verify, address valid feedback. Stale review → auto-trigger re-review (unless `--no-auto-trigger`).

**COMMENTED reviews:** Some bots (e.g., Gemini Code Assist) post as `COMMENTED` not `CHANGES_REQUESTED`, so `reviewDecision` stays `NONE`. The loop detects unresolved review threads and surfaces them.

### Review Bot Gate (t1382)

Before merge, verify at least one AI review bot has posted — prevents merging before bots finish analysis.

```bash
RESULT=$(~/.aidevops/agents/scripts/review-bot-gate-helper.sh check "$PR_NUMBER" "$REPO")
# Returns: PASS (bots found), WAITING (no bots yet), SKIP (label present)
```

| Result | Action |
|--------|--------|
| `WAITING` | Poll (most bots post within 2-5 min). `review-bot-gate` CI check also blocks at GitHub level. |
| `PASS` | Read bot reviews; address critical/security findings before merge. Non-critical → follow-up. |
| `SKIP` | PR has `skip-review-gate` label — proceed. |

AI review verification: `Bot Reviewer Feedback` in `.agents/reference/session.md` and `AI Suggestion Verification` in `.agents/prompts/build.txt`.

## Completion Promises

| Outcome | Promise |
|---------|---------|
| PR approved | `<promise>PR_APPROVED</promise>` |
| PR merged | `<promise>PR_MERGED</promise>` |
| Max iterations reached | Exit with status report |

## Timing

| Service | Initial Wait | Poll Interval |
|---------|--------------|---------------|
| Fast (CodeFactor, Version) | 10s | 5s |
| Medium (SonarCloud, Codacy, Qlty) | 60s | 15s |
| Slow (CodeRabbit) | 120s | 30s |

## Recovery

State tracked in `.agents/loop-state/quality-loop.local.state`. Common blockers: CI running (wait), review pending (ping reviewer), failing checks (fix). Resume: `/pr review` (single cycle) or `/pr-loop` (restart).

```bash
gh pr view --json state,reviewDecision,statusCheckRollup  # Check current status
```

## Related

| Command | Purpose |
|---------|---------|
| `/pr review` | Single PR review cycle |
| `/pr create` | Create PR with pre-checks |
| `/preflight-loop` | Iterative preflight until passing |
| `/postflight-loop` | Monitor release health |
| `/full-loop` | Complete development cycle |
