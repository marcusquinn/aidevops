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

Implementation of the [Ralph Wiggum technique](https://ghuntley.com/ralph/) for iterative AI development loops, enhanced with [flow-next architecture](https://github.com/gmickel/gmickel-claude-marketplace/tree/main/plugins/flow-next) for fresh context per iteration.

## Core Concept

Ralph is a `while true` bash loop that repeatedly feeds an AI agent a prompt until completion. **Externalize state to files/git; throw away context each iteration.**

```text
1. User starts loop with prompt + completion criteria
2. AI works on the task
3. AI outputs completion promise → loop exits
4. If not complete: same prompt fed back; AI sees previous work in files/git
5. Repeat until completion or max iterations
```

| Context (bad for state) | Files + Git (good for state) |
|------------------------|------------------------------|
| Dies with the conversation | Persists across sessions |
| Polluted by dead ends | Can be patched / rolled back |
| Can't delete wrong turns | Git doesn't hallucinate |

**Guardrails**: Store failures as signs in the state file. Mistakes evaporate from context; lessons accumulate in files. Next iteration reads guardrails first.

**Evolving draft agents**: When a loop iteration discovers reusable domain patterns, capture them as a draft agent in `~/.aidevops/agents/draft/`. See `tools/build-agent/build-agent.md` "Agent Lifecycle Tiers".

## Quick Start

> `ralph-loop-helper.sh` archived (t1336). Use `/full-loop` for end-to-end development, or `/ralph-loop` for in-session loops.

```bash
# End-to-end development loop (recommended)
/full-loop "Build a REST API for todos"

# In-session iteration
/ralph-loop "<prompt>" [--max-iterations <n>] [--completion-promise "<text>"]

# Cancel active loop
/cancel-ralph
```

### Auto-Branch Handling (Loop Mode)

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "Build a REST API for todos"
```

| Task Type | Detection Keywords | Action |
|-----------|-------------------|--------|
| Docs-only | readme, changelog, docs/, documentation, typo, spelling | Stay on main (exit 0) |
| Code | feature, fix, bug, implement, refactor, add, update, enhance | Create worktree (exit 2) |

## State File

State stored in `.agents/loop-state/ralph-loop.local.md` (gitignored):

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

```bash
# Monitor loop
grep '^iteration:' .agents/loop-state/ralph-loop.local.md
test -f .agents/loop-state/ralph-loop.local.md && echo "Active" || echo "Not active"
```

## Completion Promise

Output the exact text in `<promise>` tags to signal completion:

```text
<promise>COMPLETE</promise>
```

- Use `<promise>` XML tags exactly as shown
- The statement MUST be completely and unequivocally TRUE
- Do NOT output false statements to exit the loop

## Prompt Writing Best Practices

### 1. Clear Completion Criteria

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

```text
Phase 1: User authentication (JWT, tests)
Phase 2: Product catalog (list/search, tests)
Phase 3: Shopping cart (add/remove, tests)

Output <promise>COMPLETE</promise> when all phases done.
```

### 3. Self-Correction Loop

```text
Implement feature X following TDD:
1. Write failing tests
2. Implement feature
3. Run tests — if any fail, debug and fix
4. Refactor if needed
5. Repeat until all green
6. Output: <promise>COMPLETE</promise>
```

### 4. README Gate (MANDATORY before COMPLETE)

1. New feature, tool, API, command, or config option? → **Update README.md**
2. Changed existing user-facing behavior? → **Update README.md**
3. Pure refactor, bugfix with no behavior change, or internal-only? → **SKIP**

For aidevops repo: also run `readme-helper.sh check`. See `scripts/commands/full-loop.md` Step 3.

### 5. Escape Hatches

Always set `--max-iterations` and include stuck-handling:

```text
After 15 iterations, if not complete:
- Document what's blocking progress
- List what was attempted
- Suggest alternative approaches
```

### 6. Replanning

If 3+ iterations on the same sub-problem without progress, STOP and replan. Signs:

- Same error recurring despite fixes
- Incremental patches increasing complexity without solving root issue
- Tests still failing after 3+ attempts at the same approach

A fresh strategy beats incremental fixes to a broken approach.

## When to Use Ralph

**Good for:** Well-defined tasks with clear success criteria, tasks requiring iteration (getting tests to pass), greenfield projects, tasks with automatic verification.

**Not good for:** Tasks requiring human judgment, one-shot operations, unclear success criteria, production debugging.

## Full Development Loop

Use `/full-loop` for end-to-end automation. Full docs: `scripts/commands/full-loop.md`.

| Phase | Promise |
|-------|---------|
| Task Development | `TASK_COMPLETE` |
| Preflight | `PREFLIGHT_PASS` |
| PR Review | `PR_MERGED` |
| Postflight | `RELEASE_HEALTHY` |
| Deploy (aidevops only) | `DEPLOYED` |

State: `.agents/loop-state/full-loop.local.md` (gitignored). Resume: `full-loop-helper.sh resume`.

## CI/CD Timing

Adaptive timing based on observed service completion times (from PR #19 analysis):

| Category | Services | Initial Wait | Poll Interval |
|----------|----------|--------------|---------------|
| Fast | CodeFactor, Version, Framework | 10s | 5s |
| Medium | SonarCloud, Codacy, Qlty | 60s | 15s |
| Slow | CodeRabbit | 120s | 30s |

Adjust constants in `.agents/scripts/shared-constants.sh` (`CI_WAIT_FAST`, `CI_WAIT_MEDIUM`, `CI_WAIT_SLOW`, `CI_BACKOFF_BASE`, `CI_BACKOFF_MAX`).

## Multi-Worktree Awareness

```bash
~/.aidevops/agents/scripts/worktree-sessions.sh list
# Output includes "Ralph loop: iteration X/Y" for worktrees with active loops
```

## OpenProse Integration

```prose
# Parallel reviews (instead of sequential)
parallel:
  security = session "Security review"
  perf     = session "Performance review"
  style    = session "Style review"
session "Synthesize all reviews"
  context: { security, perf, style }

# AI-evaluated loop condition
loop until **all tests pass and coverage exceeds 80%** (max: 20):
  session "Run tests, analyze failures, fix bugs"

# Error recovery
loop until **task complete** (max: 50):
  try:
    session "Attempt implementation"
      retry: 3
      backoff: "exponential"
  catch as err:
    session "Analyze failure and adjust approach"
      context: err
```

| Scenario | Recommendation |
|----------|----------------|
| Simple iterative task | Native Ralph loop |
| Multi-agent parallel work | OpenProse `parallel:` blocks |
| Complex conditional logic | OpenProse `if`/`choice` blocks |
| Error recovery workflows | OpenProse `try/catch/retry` |

Full docs: `tools/ai-orchestration/openprose.md`.

## Session Completion & Spawning

See `workflows/session-manager.md` for session lifecycle, completion detection, spawning patterns, and handoff templates.

```bash
/full-loop "Next task description"
# Or spawn a background session:
opencode run "Continue with next task" --agent Build+ &
```

## Learn More

- Original technique: <https://ghuntley.com/ralph/>
- Ralph Orchestrator: <https://github.com/mikeyobrien/ralph-orchestrator>
- Claude Code plugin: <https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum>
- OpenProse DSL: <https://github.com/openprose/prose>
- Upstream sync: `~/.aidevops/agents/scripts/ralph-upstream-check.sh`
