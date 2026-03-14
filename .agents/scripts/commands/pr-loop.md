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
| `--wait-for-ci` | Wait for CI checks to complete before checking review status | false |
| `--max-iterations <n>` | Max check iterations | 10 |
| `--no-auto-trigger` | Disable automatic re-review trigger for stale reviews | false |

## Workflow

### Step 1: Parse Arguments

Extract from $ARGUMENTS:
- `pr_number` - PR number (or auto-detect from branch)
- `wait_for_ci` - Whether to wait for CI before checking reviews
- `max_iterations` - Maximum iterations before giving up
- `auto_trigger` - Whether to trigger re-review if stale

### Step 2: Run PR Review Loop

Monitor the PR iteratively using `gh` CLI to check CI status, reviews, and merge readiness.

### Step 3: Monitor and Iterate

The script performs these checks each iteration:

1. **CI Status** - Check all GitHub Actions workflows
2. **Review Bot Gate (t1382)** - Verify AI review bots have posted (see below)
3. **Review Status** - Check for approvals or change requests
4. **Merge Readiness** - Verify PR can be merged

If issues are found:
- CI failures: Report and wait for fixes
- Changes requested: **Verify before acting** (see below), then address valid feedback
- Unresolved AI feedback (COMMENTED): Some bots (e.g., Gemini Code Assist) post as `COMMENTED` rather than `CHANGES_REQUESTED`, so GitHub's `reviewDecision` stays `NONE`. The loop detects unresolved review threads and surfaces this feedback for action.
- Stale review: Auto-trigger re-review (unless `--no-auto-trigger`)

### Review Bot Gate (t1382)

Before proceeding to merge, the loop MUST verify that at least one AI review bot has posted. This prevents the pattern where PRs are merged before bots finish analysis, losing security findings.

```bash
# Check if bots have posted
RESULT=$(~/.aidevops/agents/scripts/review-bot-gate-helper.sh check "$PR_NUMBER" "$REPO")
# Returns: PASS (bots found), WAITING (no bots yet), SKIP (label present)
```

**If WAITING**: The loop continues polling. Most bots post within 2-5 minutes. The `review-bot-gate` CI check (if configured as required) also blocks merge at the GitHub level.

**If PASS**: Read the bot reviews and address critical/security findings before merging. Non-critical suggestions can be noted for follow-up.

**If SKIP**: The PR has the `skip-review-gate` label — proceed without waiting.

### AI Bot Review Verification

For handling AI code reviewer feedback, see `Bot Reviewer Feedback` guidance in `.agents/reference/session.md` and `AI Suggestion Verification` in `.agents/prompts/build.txt`.

## Completion Promises

| Outcome | Promise |
|---------|---------|
| PR approved | `<promise>PR_APPROVED</promise>` |
| PR merged | `<promise>PR_MERGED</promise>` |
| Max iterations reached | Exit with status report |

## Intelligent Timing

The loop uses evidence-based timing for different CI services:

| Service Category | Initial Wait | Poll Interval |
|------------------|--------------|---------------|
| Fast (CodeFactor, Version) | 10s | 5s |
| Medium (SonarCloud, Codacy, Qlty) | 60s | 15s |
| Slow (CodeRabbit) | 120s | 30s |

## Examples

**Monitor current branch's PR:**

```bash
/pr-loop
```

**Monitor specific PR with CI wait:**

```bash
/pr-loop --pr 123 --wait-for-ci
```

**Extended monitoring:**

```bash
/pr-loop --pr 123 --max-iterations 20
```

**Disable auto re-review trigger:**

```bash
/pr-loop --no-auto-trigger
```

## State Tracking

Progress is tracked in `.agents/loop-state/quality-loop.local.state`:

```markdown
## PR Review Loop State

- **Status:** monitoring
- **PR:** #123
- **Iteration:** 3/10
- **Last Check:** <timestamp>

### Check Results
- [x] CI: all checks passing
- [ ] Review: awaiting approval
- [ ] Merge: blocked (needs approval)
```

## When to Use

- After creating a PR to monitor until merge
- When waiting for CI checks and reviews
- As part of `/full-loop` workflow (automatic)

## Timeout Recovery

If the loop times out before completion:

1. **Check current status:**

   ```bash
   gh pr view --json state,reviewDecision,statusCheckRollup
   ```

2. **Review what's pending** - usually one of:
   - CI checks still running (wait and re-check)
   - Review requested but not completed (ping reviewer)
   - Failing checks that need manual intervention

3. **Fix and continue:**

   ```bash
   # Re-run single review cycle
   /pr review

   # Or restart loop
   /pr-loop
   ```

## Related Commands

| Command | Purpose |
|---------|---------|
| `/pr review` | Single PR review (no loop) |
| `/pr create` | Create PR with pre-checks |
| `/preflight-loop` | Iterative preflight until passing |
| `/postflight-loop` | Monitor release health |
| `/full-loop` | Complete development cycle |
