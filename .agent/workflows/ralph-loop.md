---
description: Ralph Wiggum iterative development loops for autonomous AI coding
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

# Ralph Loop v2 - Iterative AI Development

Implementation of the Ralph Wiggum technique for iterative, self-referential AI development loops.

Based on [Geoffrey Huntley's Ralph technique](https://ghuntley.com/ralph/), enhanced with [flow-next architecture](https://github.com/gmickel/gmickel-claude-marketplace/tree/main/plugins/flow-next) for fresh context per iteration.

## v2 Architecture

The v2 implementation addresses context drift by using:

- **Fresh context per iteration** - External bash loop spawns new AI sessions
- **File I/O as state** - JSON state files, not conversation transcript
- **Re-anchor every iteration** - Re-read TODO.md, git state, memories
- **Receipt-based verification** - Proof of work for each iteration
- **Memory integration** - SQLite FTS5 for cross-session learning

This follows Anthropic's own guidance: "agents must re-anchor from sources of truth to prevent drift."

## What is Ralph?

Ralph is a development methodology based on continuous AI agent loops. The core concept:

> "Ralph is a Bash loop" - a simple `while true` that repeatedly feeds an AI agent a prompt, allowing it to iteratively improve its work until completion.

The technique is named after Ralph Wiggum from The Simpsons, embodying the philosophy of persistent iteration despite setbacks.

## How It Works

```text
1. User starts loop with prompt and completion criteria
2. AI works on the task
3. AI tries to exit/complete
4. Loop checks for completion promise
5. If not complete: feed SAME prompt back
6. AI sees previous work in files/git
7. Repeat until completion or max iterations
```

The loop creates a **self-referential feedback loop** where:

- The prompt never changes between iterations
- Claude's previous work persists in files
- Each iteration sees modified files and git history
- Claude autonomously improves by reading its own past work

## Quick Start

### v2: Fresh Sessions (Recommended)

```bash
# External loop with fresh sessions per iteration
~/.aidevops/agents/scripts/ralph-loop-helper.sh run \
  "Build a REST API for todos" \
  --tool opencode \
  --max-iterations 20 \
  --completion-promise "TASK_COMPLETE"

# Check status
~/.aidevops/agents/scripts/ralph-loop-helper.sh status

# Cancel
~/.aidevops/agents/scripts/ralph-loop-helper.sh cancel
```

### Legacy: Same Session

```bash
# For tools with hook support (Claude Code)
/ralph-loop "Build a REST API" --max-iterations 50 --completion-promise "COMPLETE"

# Cancel
/cancel-ralph
```

## Commands

### ralph-loop-helper.sh run (v2)

Run external loop with fresh AI sessions per iteration.

**Usage:**

```bash
ralph-loop-helper.sh run "<prompt>" --tool <tool> [options]
```

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `--tool <name>` | AI CLI tool (opencode, claude, aider) | opencode |
| `--max-iterations <n>` | Stop after N iterations | 50 |
| `--completion-promise <text>` | Phrase that signals completion | TASK_COMPLETE |
| `--max-attempts <n>` | Block task after N failures | 5 |
| `--task-id <id>` | Task ID for tracking | auto-generated |

### /ralph-loop (Legacy)

Start a Ralph loop in same session (for tools with hook support).

**Usage:**

```bash
/ralph-loop "<prompt>" [--max-iterations <n>] [--completion-promise "<text>"]
```

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `--max-iterations <n>` | Stop after N iterations | unlimited |
| `--completion-promise <text>` | Phrase that signals completion | none |

### /cancel-ralph

Cancel the active Ralph loop.

**Usage:**

```bash
/cancel-ralph
```

## State File

Ralph stores its state in `.claude/ralph-loop.local.md` (gitignored):

```yaml
---
active: true
iteration: 5
max_iterations: 50
completion_promise: "COMPLETE"
started_at: "2025-01-08T10:30:00Z"
---

Your original prompt here...
```

## Completion Promise

To signal completion, output the exact text in `<promise>` tags:

```text
<promise>COMPLETE</promise>
```

**Critical Rules:**

- Use `<promise>` XML tags exactly as shown
- The statement MUST be completely and unequivocally TRUE
- Do NOT output false statements to exit the loop
- Do NOT lie even if you think you should exit

## Prompt Writing Best Practices

### 1. Clear Completion Criteria

**Bad:**

```text
Build a todo API and make it good.
```

**Good:**

```text
Build a REST API for todos.

When complete:
- All CRUD endpoints working
- Input validation in place
- Tests passing (coverage > 80%)
- README with API docs
- Output: <promise>COMPLETE</promise>
```

### 2. Incremental Goals

**Bad:**

```text
Create a complete e-commerce platform.
```

**Good:**

```text
Phase 1: User authentication (JWT, tests)
Phase 2: Product catalog (list/search, tests)
Phase 3: Shopping cart (add/remove, tests)

Output <promise>COMPLETE</promise> when all phases done.
```

### 3. Self-Correction

**Bad:**

```text
Write code for feature X.
```

**Good:**

```text
Implement feature X following TDD:
1. Write failing tests
2. Implement feature
3. Run tests
4. If any fail, debug and fix
5. Refactor if needed
6. Repeat until all green
7. Output: <promise>COMPLETE</promise>
```

### 4. Escape Hatches

Always use `--max-iterations` as a safety net:

```bash
# Recommended: Always set a reasonable iteration limit
/ralph-loop "Try to implement feature X" --max-iterations 20

# In your prompt, include what to do if stuck:
# "After 15 iterations, if not complete:
#  - Document what's blocking progress
#  - List what was attempted
#  - Suggest alternative approaches"
```

## When to Use Ralph

**Good for:**

- Well-defined tasks with clear success criteria
- Tasks requiring iteration and refinement (e.g., getting tests to pass)
- Greenfield projects where you can walk away
- Tasks with automatic verification (tests, linters)

**Not good for:**

- Tasks requiring human judgment or design decisions
- One-shot operations
- Tasks with unclear success criteria
- Production debugging (use targeted debugging instead)

## Philosophy

### 1. Iteration > Perfection

Don't aim for perfect on first try. Let the loop refine the work.

### 2. Failures Are Data

"Deterministically bad" means failures are predictable and informative. Use them to tune prompts.

### 3. Operator Skill Matters

Success depends on writing good prompts, not just having a good model.

### 4. Persistence Wins

Keep trying until success. The loop handles retry logic automatically.

## Cross-Tool Compatibility

This implementation works with:

| Tool | Method |
|------|--------|
| Claude Code | Native plugin (ralph-wiggum) |
| OpenCode | `/ralph-loop` command + helper script |
| Other AI CLIs | Helper script with manual loop |

### For Tools Without Hook Support

If your AI CLI doesn't support stop hooks, use the external loop:

```bash
# External bash loop (for tools without hook support)
~/.aidevops/agents/scripts/ralph-loop-helper.sh external \
  "Your prompt here" \
  --max-iterations 20 \
  --completion-promise "DONE" \
  --tool opencode
```

## Monitoring

```bash
# View current iteration
grep '^iteration:' .claude/ralph-loop.local.md

# View full state
head -10 .claude/ralph-loop.local.md

# Check if loop is active
test -f .claude/ralph-loop.local.md && echo "Active" || echo "Not active"
```

## Multi-Worktree Awareness

When working with git worktrees, Ralph loops are aware of parallel sessions.

### Check All Worktrees

```bash
# Show loops across all worktrees
~/.aidevops/agents/scripts/ralph-loop-helper.sh status --all
```

Output shows:
- Branch name for each active loop
- Current iteration and max
- Which worktree is current

### Parallel Loop Warnings

When starting a new loop, the helper automatically checks for other active loops:

```text
Other active Ralph loops detected:
  - feature/other-task (iteration 5)

Use 'ralph-loop-helper.sh status --all' to see details
```

This helps prevent confusion when multiple AI sessions are running in parallel.

### Integration with worktree-sessions.sh

The worktree session mapper shows Ralph loop status:

```bash
# List all worktrees with their sessions and loop status
~/.aidevops/agents/scripts/worktree-sessions.sh list
```

Output includes a "Ralph loop: iteration X/Y" line for worktrees with active loops.

## CI/CD Wait Time Optimization

When using Ralph loops with PR review workflows, the loop uses adaptive timing based on observed CI/CD service completion times.

### Evidence-Based Timing (from PR #19 analysis)

| Service Category | Services | Typical Time | Initial Wait | Poll Interval |
|------------------|----------|--------------|--------------|---------------|
| **Fast** | CodeFactor, Version, Framework | 1-5s | 10s | 5s |
| **Medium** | SonarCloud, Codacy, Qlty | 43-62s | 60s | 15s |
| **Slow** | CodeRabbit | 120-180s | 120s | 30s |

### Adaptive Waiting Strategy

The `quality-loop-helper.sh` uses three strategies:

1. **Service-aware initial wait**: Waits based on the slowest pending check
2. **Exponential backoff**: Increases wait time between iterations (15s → 30s → 60s → 120s max)
3. **Hybrid approach**: Uses the larger of backoff or adaptive wait

### Customizing Timing

Edit `.agent/scripts/shared-constants.sh` to adjust timing constants:

```bash
# Fast checks
readonly CI_WAIT_FAST=10
readonly CI_POLL_FAST=5

# Medium checks
readonly CI_WAIT_MEDIUM=60
readonly CI_POLL_MEDIUM=15

# Slow checks (CodeRabbit)
readonly CI_WAIT_SLOW=120
readonly CI_POLL_SLOW=30

# Backoff settings
readonly CI_BACKOFF_BASE=15
readonly CI_BACKOFF_MAX=120
```

### Gathering Your Own Timing Data

To optimize for your specific CI/CD setup:

1. Run `gh run list --limit 10 --json name,updatedAt,createdAt` to see workflow durations
2. Check PR check completion times in GitHub UI
3. Update constants in `shared-constants.sh` based on your observations

## Real-World Results

From the original Ralph technique:

- Successfully generated 6 repositories overnight in Y Combinator hackathon testing
- One $50k contract completed for $297 in API costs
- Created entire programming language ("cursed") over 3 months using this approach

## Upstream Sync

This is an **independent implementation** inspired by the Claude Code ralph-wiggum plugin, not a mirror. We maintain our own codebase for cross-tool compatibility.

**Check for upstream changes:**

```bash
~/.aidevops/agents/scripts/ralph-upstream-check.sh
```

This compares our implementation against the Claude plugin and reports any significant differences or new features we might want to incorporate.

The check runs automatically when starting an OpenCode session in the aidevops repository.

## Session Completion & Spawning

Loop agents should detect completion and suggest next steps.

### Loop Completion Detection

When a loop completes successfully (promise fulfilled), suggest:

```text
<promise>PR_MERGED</promise>

---
Loop complete. PR #123 merged successfully.

Suggestions:
1. Run @agent-review to capture learnings
2. Start new session for next task
3. Spawn parallel session for related work
---
```

### Spawning New Sessions from Loops

Loops can spawn new OpenCode sessions for parallel work. See `workflows/session-manager.md` for full spawning patterns (background sessions, terminal tabs, worktrees).

**Quick reference:**

```bash
# Background session
opencode run "Continue with next task" --agent Build+ &

# With worktree (recommended for parallel branches)
~/.aidevops/agents/scripts/worktree-helper.sh add feature/parallel-task
```

### Integration with quality-loop-helper.sh

The `quality-loop-helper.sh` script can spawn new sessions on loop completion:

```bash
# After successful loop, offer to spawn next task
~/.aidevops/agents/scripts/quality-loop-helper.sh preflight --on-complete spawn
```

## Full Development Loop

For end-to-end automation from task conception to deployment, use the Full Development Loop orchestrator. This chains all phases together for maximum AI utility.

### Quick Start

```bash
# Start full loop
~/.aidevops/agents/scripts/full-loop-helper.sh start "Implement feature X with tests"

# Check status
~/.aidevops/agents/scripts/full-loop-helper.sh status

# Resume after manual intervention
~/.aidevops/agents/scripts/full-loop-helper.sh resume

# Cancel if needed
~/.aidevops/agents/scripts/full-loop-helper.sh cancel
```

### Loop Phases

```text
┌─────────────────┐
│  1. TASK LOOP   │  Ralph loop for implementation
│  (Development)  │  Promise: TASK_COMPLETE
└────────┬────────┘
         │ auto
         ▼
┌─────────────────┐
│  2. PREFLIGHT   │  Quality checks before commit
│  (Quality Gate) │  Promise: PREFLIGHT_PASS
└────────┬────────┘
         │ auto
         ▼
┌─────────────────┐
│  3. PR CREATE   │  Auto-create pull request
│  (Auto-create)  │  Output: PR URL
└────────┬────────┘
         │ auto
         ▼
┌─────────────────┐
│  4. PR LOOP     │  Monitor CI and approval
│  (Review/CI)    │  Promise: PR_MERGED
└────────┬────────┘
         │ auto
         ▼
┌─────────────────┐
│  5. POSTFLIGHT  │  Verify release health
│  (Verify)       │  Promise: RELEASE_HEALTHY
└────────┬────────┘
         │ conditional (aidevops repo only)
         ▼
┌─────────────────┐
│  6. DEPLOY      │  Run setup.sh
│  (Local Setup)  │  Promise: DEPLOYED
└─────────────────┘
```

| Phase | Script | Promise | Auto-Trigger |
|-------|--------|---------|--------------|
| Task Development | `ralph-loop-helper.sh` | `TASK_COMPLETE` | Manual start |
| Preflight | `quality-loop-helper.sh preflight` | `PREFLIGHT_PASS` | After task |
| PR Creation | `gh pr create` | (PR URL) | After preflight |
| PR Review | `quality-loop-helper.sh pr-review` | `PR_MERGED` | After PR create |
| Postflight | `quality-loop-helper.sh postflight` | `RELEASE_HEALTHY` | After merge |
| Deploy | `./setup.sh` (aidevops only) | `DEPLOYED` | After postflight |

### Human Decision Points

The loop is designed for maximum AI autonomy while preserving human control at strategic points:

| Phase | AI Autonomous | Human Required |
|-------|---------------|----------------|
| Task Development | Code changes, iterations, fixes | Initial task definition, scope decisions |
| Preflight | Auto-fix, re-run checks | Override to skip (emergency only) |
| PR Creation | Auto-create with `--fill` | Custom title/description if needed |
| PR Review | Address feedback, push fixes | Approve/merge (if required by repo) |
| Postflight | Monitor, report issues | Rollback decision if issues found |
| Deploy | Run `setup.sh` | None (fully autonomous) |

### Options

```bash
full-loop-helper.sh start "<prompt>" [options]

Options:
  --max-task-iterations N       Max iterations for task (default: 50)
  --max-preflight-iterations N  Max iterations for preflight (default: 5)
  --max-pr-iterations N         Max iterations for PR review (default: 20)
  --skip-preflight              Skip preflight checks (not recommended)
  --skip-postflight             Skip postflight monitoring
  --no-auto-pr                  Don't auto-create PR, pause for human
  --no-auto-deploy              Don't auto-run setup.sh (aidevops only)
  --dry-run                     Show what would happen without executing
```

### aidevops-Specific Behavior

When working in the aidevops repository (detected by repo name or `.aidevops-repo` marker), the full loop automatically runs `setup.sh` after successful postflight to deploy changes locally.

```bash
# In aidevops repo, this will auto-deploy
full-loop-helper.sh start "Add new helper script"

# Disable auto-deploy if needed
full-loop-helper.sh start "Add new helper script" --no-auto-deploy
```

### State Management

The full loop maintains state in `.claude/full-loop.local.md` (gitignored), allowing:

- Resume after interruption
- Track current phase
- Preserve PR number across phases

```bash
# Check current state
cat .claude/full-loop.local.md

# Resume from where you left off
full-loop-helper.sh resume
```

## Learn More

- Original technique: <https://ghuntley.com/ralph/>
- Ralph Orchestrator: <https://github.com/mikeyobrien/ralph-orchestrator>
- Claude Code plugin: <https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum>
