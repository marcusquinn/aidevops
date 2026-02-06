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

Execute the quality loop helper:

```bash
~/.aidevops/agents/scripts/quality-loop-helper.sh pr-review $ARGUMENTS
```

### Step 3: Monitor and Iterate

The script performs these checks each iteration:

1. **CI Status** - Check all GitHub Actions workflows
2. **Review Status** - Check for approvals or change requests
3. **Merge Readiness** - Verify PR can be merged

If issues are found:
- CI failures: Report and wait for fixes
- Changes requested: **Verify before acting** (see below), then address valid feedback
- Stale review: Auto-trigger re-review (unless `--no-auto-trigger`)

### AI Bot Review Verification

When a review bot (Gemini, CodeRabbit, Copilot, etc.) requests changes, **verify factual claims before implementing**. AI reviewers can hallucinate - e.g., claiming a Docker image version doesn't exist when it does, or flagging correct file paths as wrong.

**Verification steps:**

1. **Check factual claims** - Verify version numbers, file paths, API signatures against runtime, documentation, or project conventions
2. **Dismiss incorrect suggestions** - Reply with evidence (e.g., "Image exists: `docker manifest inspect image:tag`")
3. **Address valid feedback** - Implement suggestions that are technically correct
4. **Re-request review** - Push fixes and trigger re-review for remaining items

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
