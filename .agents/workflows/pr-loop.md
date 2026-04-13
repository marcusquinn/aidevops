---
description: Iterate on PR until approved or merged
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Monitor and iterate on a PR until it is approved or merged.

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

AI review verification rules: `reference/session.md` "Bot Reviewer Feedback" and `prompts/build.txt` "AI Suggestion Verification".

### Gate Failure Playbook

When `Maintainer Review & Assignee Gate` fails, the `maintainer-gate` status-context description and the auto-posted gate comment on the PR say why. Map the reason to the fix path below — do not re-read `maintainer-gate.yml` to re-derive it.

| Failure reason (observable in gate output) | Fix path | Who runs it |
|---|---|---|
| `Issue #N has needs-maintainer-review label` | `sudo aidevops approve issue N` — cryptographic, posts signed comment, removes label | **User only** — requires sudo + root-protected SSH key; LLM cannot forge |
| `Issue #N has no assignee` | `gh issue edit N --add-assignee USER` | LLM or user |
| `PR #N has needs-maintainer-review label` | `sudo aidevops approve pr N` | **User only** |
| `Title-based issue lookup failed` | Either fix PR title to `tNNN: ...` format or add `Closes #NNN` to PR body | LLM |

After user-only fixes, the required `Maintainer Review & Assignee Gate` CheckRun auto-refreshes via the `retrigger-pr-checks` job in `maintainer-gate.yml` (t2018). That job observes issue label/assignee changes and calls the `rerun-failed-jobs` REST API endpoint to re-run the failed `check-pr` job. Expect SUCCESS within ~20 seconds of the approval comment being posted (approximate — not explicitly time-bound in the code); the PR becomes mergeable without manual `gh run rerun`.

If the required CheckRun does NOT refresh within ~60 seconds after an approval, fall back to manual: `gh run rerun <run_id> --failed` against the latest `Maintainer Gate` workflow run for the PR's HEAD SHA.

**Hard rule:** NEVER remove `needs-maintainer-review` by direct `gh issue edit --remove-label`. The `protect-labels` job in `maintainer-gate.yml` re-applies it ~7 seconds later unless a `<!-- aidevops-signed-approval -->` comment exists on the issue. Removing the label without the signed comment is a guaranteed-to-fail path that wastes tool calls.

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

State: `.agents/loop-state/quality-loop.local.state`. Blockers: CI running (wait), review pending (ping reviewer), failing checks (fix). Resume: `/pr review` (single cycle) or `/pr-loop` (restart).

```bash
gh pr view --json state,reviewDecision,statusCheckRollup
```

## Related

| Command | Purpose |
|---------|---------|
| `/pr review` | Single PR review cycle |
| `/pr create` | Create PR with pre-checks |
| `/preflight-loop` | Iterative preflight until passing |
| `/postflight-loop` | Monitor release health |
| `/full-loop` | Complete development cycle |
