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

# Ralph Loop - Iterative AI Development

Implementation of the Ralph Wiggum technique for iterative, self-referential AI development loops.

Based on [Geoffrey Huntley's Ralph technique](https://ghuntley.com/ralph/) and the [Claude Code ralph-wiggum plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum).

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

### Starting a Loop

```bash
# Basic usage
/ralph-loop "Build a REST API for todos. Requirements: CRUD operations, input validation, tests. Output <promise>COMPLETE</promise> when done." --max-iterations 50

# With completion promise
/ralph-loop "Fix all TypeScript errors in src/" --completion-promise "ALL_ERRORS_FIXED" --max-iterations 20

# Unlimited iterations (use with caution)
/ralph-loop "Refactor the auth module until all tests pass"
```

### Canceling a Loop

```bash
/cancel-ralph
```

## Commands

### /ralph-loop

Start a Ralph loop in your current session.

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

## Learn More

- Original technique: <https://ghuntley.com/ralph/>
- Ralph Orchestrator: <https://github.com/mikeyobrien/ralph-orchestrator>
- Claude Code plugin: <https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum>
