---
mode: subagent
---
# t1312: Interactive Brief Generation with Latent Criteria Probing

## Origin

- **Created:** 2026-02-22
- **Session:** OpenCode:manifest-dev-analysis
- **Created by:** human + ai-interactive
- **Conversation context:** Analysis of doodledood/manifest-dev revealed their `/define` command's structured interview process surfaces "latent criteria" — requirements users don't know they have until probed. Our brief template captures the same fields but doesn't enforce an interactive discovery process.

## What

A `/define` (or `/brief`) slash command that walks the user through structured questions before creating a task brief at `todo/tasks/{task_id}-brief.md`. The command:

1. Classifies the task type (feature, bugfix, refactor, docs, research, content)
2. Runs a structured interview with concrete options (not open-ended questions)
3. Probes for latent criteria using domain-grounded pre-mortem scenarios
4. Generates a complete brief from `templates/brief-template.md` with all fields populated
5. Outputs the brief for user review before writing

The interview should surface requirements the user hasn't thought of by:
- **Domain grounding**: Exploring the affected codebase area first, then asking informed questions
- **Pre-mortem**: "Imagine this failed — what went wrong?" with concrete failure scenarios
- **Backcasting**: "Imagine this succeeded on first review — what had to go right?"
- **Outside view**: "What typically goes wrong with this class of task?"

Each question presents 2-4 concrete options with one marked as recommended, reducing cognitive load.

## Why

Task briefs are mandatory in aidevops but the quality varies wildly. When a human types a quick description, the brief often misses:
- Edge cases that surface during implementation
- Acceptance criteria that would catch regressions
- Constraints from existing code patterns
- Non-obvious dependencies

The `/define` interview front-loads this discovery. Every criterion found during the interview is one fewer rejection during PR review. This is especially valuable for auto-dispatched tasks where the worker has no human to ask mid-implementation.

## How (Approach)

### Implementation as a slash command

Create `.agents/scripts/commands/define.md` — a slash command that the agent follows as a workflow, not a bash script. The command:

1. Accepts `$ARGUMENTS` as task description
2. Claims a task ID via `claim-task-id.sh`
3. Classifies task type from description
4. Loads task-type-specific probing angles (see below)
5. Runs the interview (multiple turns)
6. Generates brief from template
7. Writes to `todo/tasks/{task_id}-brief.md`

### Task-type probing angles

Adapt manifest-dev's task file concept to our domain. Create `.agents/reference/define-probes/` with:

| File | Task Types | Probing Angles |
|------|-----------|----------------|
| `coding.md` | All code changes | Silent regression, environment drift, performance cliff, security gap, concurrency, dependency conflict, breaking implicit contract, error swallowing, config mismatch, observability blindspot |
| `feature.md` | New features | Scope creep, breaking consumers, missing edge cases, security blind spot, silent production failure, mental model mismatch, partial state corruption, permission gap, backward compatibility, migration, feature flag complexity |
| `bugfix.md` | Bug fixes | Root cause vs symptom, regression prevention, reproduction reliability, blast radius |
| `refactor.md` | Refactoring | Behavior preservation, characterization tests, migration completeness |
| `shell.md` | Shell scripts | ShellCheck compliance, set -euo pipefail, local var pattern, explicit returns, POSIX compatibility |

These are NOT full agent docs — they're lists of probing angles the `/define` command uses to generate interview questions. Compact, one line per angle.

### Key design decisions from manifest-dev analysis

**Steal:**
- Concrete options with recommended default (reduces cognitive load)
- Domain grounding before probing (explore codebase first, then ask informed questions)
- Pre-mortem with specific failure scenarios (not "what could go wrong?" but "I'm imagining two workers dispatched for the same task — how should we handle?")
- Backcasting (what had to go right? surfaces load-bearing assumptions)
- Confirm understanding periodically (prevents interpretation drift)
- Batch related questions (reduces round-trips)

**Don't steal:**
- Manifest schema (we have brief-template.md, it's simpler and sufficient)
- Verification loop with separate verifier agent (over-engineered for our use case)
- Discovery log file (our brief IS the output, no need for intermediate state)
- AskUserQuestion tool constraint (we don't have this tool, use natural conversation)

### Integration with existing workflow

- `/define` outputs a brief, then asks: "implement now or queue for runner?"
- If queue: adds TODO entry with `#auto-dispatch` tag
- If implement: proceeds to worktree creation per git workflow
- Brief includes `verify:` blocks on acceptance criteria (see t1313)

## Acceptance Criteria

- [ ] `/define "add dark mode toggle"` triggers a structured interview (not just template fill)
- [ ] Interview asks at least 3 domain-grounded questions based on task type
- [ ] Each question presents 2-4 concrete options with one recommended
- [ ] Pre-mortem generates at least 2 specific failure scenarios for the task
- [ ] Generated brief passes all fields from `templates/brief-template.md`
- [ ] Acceptance criteria in the brief are specific and testable (not vague)
- [ ] Command works for all task types: feature, bugfix, refactor, shell, docs
- [ ] Brief is written to `todo/tasks/{task_id}-brief.md`
- [ ] TODO entry is created with proper format
- [ ] Lint clean (markdownlint, shellcheck if any shell involved)

## Context & Decisions

- Inspired by manifest-dev's `/define` SKILL.md (30KB prompt) but adapted to be much lighter
- manifest-dev uses a separate manifest file + discovery log + verifier agent — we collapse this into a single brief output
- manifest-dev's AskUserQuestion tool forces structured options — we achieve the same by instructing the agent to present numbered options
- The probing angles files are reference material, not full agent prompts — keeps context cost low
- LLM_CODING_CAPABILITIES.md from manifest-dev confirms: "LLMs are goal-oriented pattern matchers trained through RL. Clear acceptance criteria play to their strength." This validates front-loading criteria discovery.

## Relevant Files

- `.agents/templates/brief-template.md` — output template
- `.agents/scripts/commands/new-task.md` — existing task creation command (extend or replace)
- `.agents/workflows/plans.md` — planning workflow context
- `.agents/scripts/claim-task-id.sh` — task ID allocation
- `.agents/AGENTS.md:Development Lifecycle` — where briefs fit in the workflow

## Dependencies

- **Blocked by:** nothing
- **Blocks:** t1313 (verification blocks benefit from structured briefs)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review new-task.md, brief-template.md, plans.md |
| Probing angles files | 1h | Create reference/define-probes/*.md |
| Slash command | 2h | define.md with full interview workflow |
| Testing | 30m | Test with 3 task types |
| **Total** | **4h** | |
