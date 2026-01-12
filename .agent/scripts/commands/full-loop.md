---
description: Start end-to-end development loop (task → preflight → PR → postflight → deploy)
agent: Build+
mode: subagent
---

Start a full development loop that chains all phases from task implementation to deployment.

Task/Prompt: $ARGUMENTS

## Full Loop Phases

```text
Task Development → Preflight → PR Create → PR Review → Postflight → Deploy
```

## Workflow

### Step 1: Auto-Branch Setup

The loop automatically handles branch setup when on main/master:

```bash
# Run pre-edit check in loop mode with task description
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "$ARGUMENTS"
```

**Exit codes:**
- `0` - Already on feature branch OR docs-only task (proceed)
- `1` - Interactive mode fallback (shouldn't happen in loop)
- `2` - Code task on main (auto-create worktree)

**Auto-decision logic:**
- **Docs-only tasks** (README, CHANGELOG, docs/, typos): Stay on main
- **Code tasks** (features, fixes, refactors, enhancements): Auto-create worktree

**Detection keywords:**
- Docs-only: `readme`, `changelog`, `documentation`, `docs/`, `typo`, `spelling`
- Code (overrides docs): `feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`, `port`, `ssl`

**When worktree is needed:**

```bash
# Generate branch name from task (sanitized, truncated to 40 chars)
branch_name=$(echo "$ARGUMENTS" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)
~/.aidevops/agents/scripts/worktree-helper.sh add "feature/$branch_name"
# Continue in new worktree directory
```

Also verify:
- **Clean working directory**: Uncommitted changes should be committed or stashed
- **Git remote configured**: Need to push and create PR

```bash
git status --short
```

### Step 2: Start Full Loop

```bash
~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS"
```

This will:
1. Initialize the Ralph loop for task development
2. Set up state tracking in `.agent/loop-state/full-loop.local.md`
3. Begin iterating on the task

### Step 3: Task Development (Ralph Loop)

The AI will iterate on the task until outputting:

```text
<promise>TASK_COMPLETE</promise>
```

**Completion criteria:**
- All requirements implemented
- Tests passing (if applicable)
- Code quality acceptable
- README.md updated (if adding features/APIs)
- Conventional commits used (for auto-changelog)

### Step 4: Automatic Phase Progression

After task completion, the loop automatically:

1. **Preflight**: Runs quality checks, auto-fixes issues
2. **PR Create**: Creates pull request with `gh pr create --fill`
3. **PR Review**: Monitors CI checks and review status
4. **Postflight**: Verifies release health after merge
5. **Deploy**: Runs `setup.sh` (aidevops repos only)

### Step 5: Human Decision Points

The loop pauses for human input at:

| Point | When | Action Required |
|-------|------|-----------------|
| Merge approval | If repo requires human approval | Approve PR in GitHub |
| Rollback | If postflight detects issues | Decide whether to rollback |
| Scope change | If task evolves beyond original | Confirm new scope |

### Step 6: Completion

When all phases complete:

```text
<promise>FULL_LOOP_COMPLETE</promise>
```

## Commands

```bash
# Start new loop
/full-loop "Implement feature X with tests"

# Check status
~/.aidevops/agents/scripts/full-loop-helper.sh status

# Resume after interruption
~/.aidevops/agents/scripts/full-loop-helper.sh resume

# Cancel loop
~/.aidevops/agents/scripts/full-loop-helper.sh cancel
```

## Options

Pass options after the prompt:

```bash
/full-loop "Fix bug Y" --max-task-iterations 30 --skip-postflight
```

| Option | Description |
|--------|-------------|
| `--max-task-iterations N` | Max iterations for task (default: 50) |
| `--max-preflight-iterations N` | Max iterations for preflight (default: 5) |
| `--max-pr-iterations N` | Max iterations for PR review (default: 20) |
| `--skip-preflight` | Skip preflight checks |
| `--skip-postflight` | Skip postflight monitoring |
| `--no-auto-pr` | Pause for manual PR creation |
| `--no-auto-deploy` | Don't auto-run setup.sh |

## Examples

```bash
# Basic feature implementation
/full-loop "Add user authentication with JWT tokens"

# Bug fix with limited iterations
/full-loop "Fix memory leak in connection pool" --max-task-iterations 20

# Skip postflight for quick iteration
/full-loop "Update documentation" --skip-postflight

# Manual PR creation
/full-loop "Refactor database layer" --no-auto-pr
```

## Documentation & Changelog

### README Updates

When implementing features or APIs, include README updates in your task:

```bash
/full-loop "Add user authentication with JWT tokens and update README"
```

The task development phase should update README.md with:
- New feature documentation
- Usage examples
- API endpoint descriptions
- Configuration options

### Changelog (Auto-Generated)

The release workflow auto-generates CHANGELOG.md from conventional commits. Use proper commit prefixes during task development:

| Prefix | Changelog Section | Example |
|--------|-------------------|---------|
| `feat:` | Added | `feat: add JWT authentication` |
| `fix:` | Fixed | `fix: resolve token expiration bug` |
| `docs:` | Changed | `docs: update API documentation` |
| `perf:` | Changed | `perf: optimize database queries` |
| `refactor:` | Changed | `refactor: simplify auth middleware` |
| `chore:` | (excluded) | `chore: update dependencies` |

See `workflows/changelog.md` for format details.

## OpenProse Orchestration

For complex multi-phase workflows, consider expressing the full loop in OpenProse DSL:

```prose
agent developer:
  model: opus
  prompt: "You are a senior developer"

# Phase 1: Task Development
loop until **task is complete** (max: 50):
  session: developer
    prompt: "Implement the feature, run tests, fix issues"

# Phase 2: Preflight (parallel quality checks)
parallel:
  lint = session "Run linters and fix issues"
  types = session "Check types and fix issues"
  tests = session "Run tests and fix failures"

if **any checks failed**:
  loop until **all checks pass** (max: 5):
    session "Fix remaining issues"
      context: { lint, types, tests }

# Phase 3: PR Creation
let pr = session "Create pull request with gh pr create --fill"

# Phase 4: PR Review Loop
loop until **PR is merged** (max: 20):
  parallel:
    ci = session "Check CI status"
    review = session "Check review status"
  
  if **CI failed**:
    session "Fix CI issues and push"
  
  if **changes requested**:
    session "Address review feedback and push"

# Phase 5: Postflight
session "Verify release health"
```

See `tools/ai-orchestration/openprose.md` for full OpenProse documentation.

## Related

- `workflows/ralph-loop.md` - Ralph loop technique details
- `workflows/preflight.md` - Pre-commit quality checks
- `workflows/pr.md` - PR creation workflow
- `workflows/postflight.md` - Post-release verification
- `workflows/changelog.md` - Changelog format and validation
- `tools/ai-orchestration/openprose.md` - OpenProse DSL for multi-agent orchestration
