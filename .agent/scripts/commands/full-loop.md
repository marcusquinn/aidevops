---
description: Start end-to-end development loop (task → preflight → PR → postflight → deploy)
agent: Build+
mode: subagent
---

Start a full development loop that chains all phases from task implementation to deployment.

Task/Prompt: $ARGUMENTS

## Step 0: Resolve Task ID and Set Session Title

**IMPORTANT**: Before proceeding, extract the first positional argument from `$ARGUMENTS` (ignoring flags like `--max-task-iterations`). Check if it matches the task ID pattern `t\d+` (e.g., `t061`).

If the first argument is a task ID (e.g., `t061`):

1. Extract the task ID and look up its description from TODO.md:

   ```bash
   # Extract first argument (the task ID)
   TASK_ID=$(echo "$ARGUMENTS" | awk '{print $1}')
   
   # Look up description (matches open, completed, or declined tasks)
   TASK_DESC=$(grep -E "^- \[( |x|-)\] $TASK_ID " TODO.md 2>/dev/null | head -1 | sed -E 's/^- \[( |x|-)\] [^ ]* //')
   ```

2. Set the session title using the `session-rename` MCP tool:

   ```text
   # Call the session-rename tool with the title parameter
   session-rename(title: "t061: Improve session title to include task description")
   ```

   - Good: `"t061: Improve session title to include task description"`
   - Bad: `"Full loop development for t061"`

3. **Fallback**: If `$TASK_DESC` is empty (task not found in TODO.md), use: `"t061: (task not found in TODO.md)"`

4. Store the full task description for use in subsequent steps.

If the first argument is NOT a task ID (it's a description):
- Use the description directly for the session title
- Call `session-rename` tool with a concise version if the description is very long (truncate to ~60 chars)

**Example session titles:**
- Task ID `t061` with description "Improve session title format" → `"t061: Improve session title format"`
- Task ID `t999` not found → `"t999: (task not found in TODO.md)"`
- Description "Add JWT authentication" → `"Add JWT authentication"`

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

# Preferred: Use Worktrunk (wt) if installed
wt switch -c "feature/$branch_name"

# Fallback: Use worktree-helper.sh if wt not available
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

**Recommended: Background mode** (avoids timeout issues):

```bash
~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS" --background
```

This starts the loop in the background and returns immediately. Use these commands to monitor:

```bash
# Check status
~/.aidevops/agents/scripts/full-loop-helper.sh status

# View logs
~/.aidevops/agents/scripts/full-loop-helper.sh logs

# Cancel if needed
~/.aidevops/agents/scripts/full-loop-helper.sh cancel
```

**Foreground mode** (may timeout in MCP tools):

```bash
~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS"
```

This will:
1. Initialize the Ralph loop for task development
2. Set up state tracking in `.agent/loop-state/full-loop.local.md`
3. Begin iterating on the task

**Note**: Foreground mode may timeout when called via MCP Bash tool (default 120s timeout). Use `--background` for long-running tasks.

### Step 3: Task Development (Ralph Loop)

The AI will iterate on the task until outputting:

```text
<promise>TASK_COMPLETE</promise>
```

**Completion criteria (ALL must be satisfied before emitting TASK_COMPLETE):**

1. All requirements implemented
2. Tests passing (if applicable)
3. Code quality acceptable
4. **README gate passed** (see below)
5. Conventional commits used (for auto-changelog)

**README gate (MANDATORY - do NOT skip):**

Before emitting `TASK_COMPLETE`, answer this decision tree:

1. Did this task add a new feature, tool, API, command, or config option? → **Update README.md**
2. Did this task change existing user-facing behavior? → **Update README.md**
3. Is this a pure refactor, bugfix with no behavior change, or internal-only change? → **SKIP**

If README update is needed:

```bash
# For any repo: use targeted section updates
/readme --sections "usage"  # or relevant section

# For aidevops repo: also check if counts are stale
~/.aidevops/agents/scripts/readme-helper.sh check
# If stale, run: readme-helper.sh update --apply
```

**Do NOT emit TASK_COMPLETE until README is current.** This is a gate, not a suggestion. The t099 Neural-Chromium task was merged without a README update because this gate was advisory - it is now mandatory.

### Step 4: Automatic Phase Progression

After task completion, the loop automatically:

1. **Preflight**: Runs quality checks, auto-fixes issues
2. **PR Create**: Creates pull request with `gh pr create --fill`
3. **PR Review**: Monitors CI checks and review status
4. **Merge**: Squash merge (without `--delete-branch` when in worktree)
5. **Worktree Cleanup**: Return to main repo, pull, clean merged worktrees
6. **Postflight**: Verifies release health after merge
7. **Deploy**: Runs `setup.sh` (aidevops repos only)

**Worktree cleanup after merge:**

```bash
# When in a worktree, merge without --delete-branch
gh pr merge --squash

# Then clean up from main repo
cd ~/Git/$(basename "$PWD" | cut -d. -f1)  # Return to main repo
git pull origin main                        # Get merged changes
wt prune                                    # Clean merged worktrees
```

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
| `--background`, `--bg` | Run in background (recommended for long tasks) |
| `--max-task-iterations N` | Max iterations for task (default: 50) |
| `--max-preflight-iterations N` | Max iterations for preflight (default: 5) |
| `--max-pr-iterations N` | Max iterations for PR review (default: 20) |
| `--skip-preflight` | Skip preflight checks |
| `--skip-postflight` | Skip postflight monitoring |
| `--no-auto-pr` | Pause for manual PR creation |
| `--no-auto-deploy` | Don't auto-run setup.sh |

## Examples

```bash
# Basic feature implementation (background mode recommended)
/full-loop "Add user authentication with JWT tokens" --background

# Foreground mode (may timeout for long tasks)
/full-loop "Add user authentication with JWT tokens"

# Bug fix with limited iterations
/full-loop "Fix memory leak in connection pool" --max-task-iterations 20 --background

# Skip postflight for quick iteration
/full-loop "Update documentation" --skip-postflight

# Manual PR creation
/full-loop "Refactor database layer" --no-auto-pr --background

# View background loop progress
~/.aidevops/agents/scripts/full-loop-helper.sh logs
```

## Documentation & Changelog

### README Updates

README updates are enforced by the **README gate** in Step 3 completion criteria. You do NOT need to include "and update README" in your prompt - the gate catches it automatically.

When the gate triggers, update README.md with:
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
