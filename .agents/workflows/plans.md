---
description: Planning workflow with auto-complexity detection
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Plans Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Save planning discussions as actionable tasks or plans
- **Commands**: `/save-todo` (auto-detects), `/ready` (show unblocked), `/sync-beads` (sync to Beads)
- **Principle**: Don't make user think about where to save

**Files**:

| File | Purpose |
|------|---------|
| `TODO.md` | All tasks (simple + plan references) with dependencies |
| `todo/PLANS.md` | Complex execution plans with context |
| `todo/tasks/prd-{name}.md` | Product requirement documents |
| `todo/tasks/tasks-{name}.md` | Implementation task lists |
| `.beads/` | Beads database (synced from TODO.md) |

**Task ID Format**: `tNNN` (top-level), `tNNN.N` (subtask), `tNNN.N.N` (sub-subtask)

**Dependency Syntax**: `blocked-by:t001,t002` | `blocks:t003` | 2-space indentation = parent-child

**Workflow**:

```text
Planning Conversation → /save-todo → Auto-detect → Save appropriately
Future Session → "Work on X" → Load context → git-workflow.md
                            → /ready → Show unblocked tasks
                            → /sync-beads → Sync to Beads for graph view
```

<!-- AI-CONTEXT-END -->

## Auto-Detection Logic

When `/save-todo` is invoked, analyze the conversation for complexity signals:

| Signal | Indicates | Action |
|--------|-----------|--------|
| Single action item / < 2h estimate / "quick" or "simple" | Simple | TODO.md only |
| Multiple distinct steps / research needed / > 2h / multi-session / PRD needed | Complex | PLANS.md + TODO.md |

## Ralph Classification

Tasks can be classified as "Ralph-able" — suitable for autonomous iterative AI loops.

### Ralph Criteria

| Criterion | Required |
|-----------|----------|
| Clear success criteria | Yes |
| Automated verification (tests, linters, type checkers) | Yes |
| Bounded scope (single feature, specific bug fix) | Yes |
| No human judgment needed | Yes |

| Signal | Ralph-able? |
|--------|-------------|
| "Make all tests pass" / "Fix linting errors" / "Implement feature X with tests" | Yes |
| "Refactor until clean" | Maybe (needs specific criteria) |
| "Make it look better" / "Design the API" / "Debug production issue" | No |

### Tagging Ralph-able Tasks

```markdown
- [ ] t042 Fix all ShellCheck violations in scripts/ #ralph ~1h
  ralph-promise: "SHELLCHECK_CLEAN"
  ralph-verify: "shellcheck .agents/scripts/*.sh"
  ralph-max: 10

# Shorthand
- [ ] t042 Fix all ShellCheck violations #ralph(SHELLCHECK_CLEAN) ~1h
```

### Auto-Dispatch Tagging

Add `#auto-dispatch` when ALL of these are true:
- Clear fix/feature description with specific files or patterns
- Bounded scope (~1h or less estimated)
- No user credentials, accounts, or purchases needed
- No design decisions requiring user preference
- Verification is automatable (tests, ShellCheck, syntax check, browser test)

Do NOT add `#auto-dispatch` when ANY of these are true:
- Requires credentials, top-up accounts, or purchases
- Is a `#plan` needing decomposition first
- Requires hardware setup or external service configuration
- Description says "investigate" or "evaluate" without a clear deliverable
- Has `blocked-by:` dependencies on incomplete tasks

**AI agents MUST**: Default to including `#auto-dispatch` — only omit when a specific exclusion criterion applies.

### Running Ralph Tasks

```bash
/ralph-loop "$(grep 't042' TODO.md)" --completion-promise "SHELLCHECK_CLEAN" --max-iterations 10
/ralph-task t042
```

### Quality Loop Integration

| Workflow | Command | Promise |
|----------|---------|---------|
| Preflight | `/preflight-loop` | `PREFLIGHT_PASS` |
| PR Review | `/pr-loop` | `PR_APPROVED` |
| Postflight | `/postflight-loop` | `RELEASE_HEALTHY` |

## Saving Work

### MANDATORY: Task Brief Requirement

**Every task MUST have a brief file** at `todo/tasks/{task_id}-brief.md`. A task without a brief is undevelopable — it loses the conversation context that informed it.

Use `templates/brief-template.md`. The brief captures: origin (session ID, date, author), what (clear deliverable), why (problem/need/value), how (technical approach, file references), acceptance criteria, and context from the conversation.

**Session provenance is mandatory.** Detect runtime: `$OPENCODE_SESSION_ID`, `$CLAUDE_SESSION_ID`, or `{app}:unknown-{date}`.

### Step 1: Extract from Conversation

Title, description, estimate (`~Xh (ai:Xh test:Xh read:Xm)`), tags, context, session ID.

### Step 2: Present with Auto-Detection

**For Simple tasks:**
```text
Saving to TODO.md: "{title}" ~{estimate}
Creating brief: todo/tasks/{task_id}-brief.md
1. Confirm  2. Add more details  3. Create full plan instead
```

**For Complex work:**
```text
This looks like complex work. Creating execution plan.
Title: {title} | Estimate: ~{estimate} | Phases: {count}
Creating brief: todo/tasks/{task_id}-brief.md
1. Confirm and create plan + brief  2. Simplify to TODO.md + brief  3. Add more context
```

### Step 3: Save Appropriately

#### Simple Save (TODO.md + brief)

1. Create brief at `todo/tasks/{task_id}-brief.md`
2. Add to TODO.md Backlog:

```markdown
- [ ] t{NNN} {title} #{tag} ~{estimate} logged:{YYYY-MM-DD}
```

Format elements (all optional except id and description): `@owner`, `#tag`, `~estimate`, `logged:YYYY-MM-DD`, `blocked-by:t001,t002`, `blocks:t003`.

**Auto-dispatch gate**: Only add `#auto-dispatch` if the brief has at least 2 specific acceptance criteria, a non-empty How section with file references, and a clear What section.

#### Complex Save (PLANS.md + TODO.md)

1. Create PLANS.md entry:

```markdown
### [{YYYY-MM-DD}] {Title}

**Status:** Planning | **Estimate:** ~{estimate}
**PRD:** [todo/tasks/prd-{slug}.md](tasks/prd-{slug}.md) (if needed)

#### Purpose
{Why this work matters}

#### Progress
- [ ] ({timestamp}) Phase 1: {description} ~{est}
- [ ] ({timestamp}) Phase 2: {description} ~{est}

#### Context from Discussion
{Key decisions, research findings, constraints}

#### Decision Log
(To be populated during implementation)

#### Surprises & Discoveries
(To be populated during implementation)
```

2. Add reference to TODO.md: `- [ ] {title} #plan → [todo/PLANS.md#{slug}] ~{estimate} logged:{YYYY-MM-DD}`
3. Optionally create PRD/tasks if scope warrants (`/create-prd`, `/generate-tasks`)

## Context Preservation

Always capture from the conversation: decisions and rationale, research findings, constraints, open questions, related links. This goes into PLANS.md "Context from Discussion" so future sessions have full context.

## Starting Work from Plans

When user says "Let's work on X":

1. **Find**: `grep -i "{keyword}" TODO.md todo/PLANS.md`
2. **Load context**: Read PRD/tasks files if they exist
3. **Present**: `Found: "{title}" (~{estimate}) — 1. Start working  2. View details  3. Different task`
4. **Follow**: `git-workflow.md` after branch creation

## During Implementation

### Update Progress

```markdown
#### Progress
- [x] (2025-01-14 10:00Z) Research API endpoints
- [ ] (2025-01-15 09:00Z) Implement core logic ← IN PROGRESS
```

### Record Decisions

```markdown
#### Decision Log
- **Decision:** Use TypeScript + Bun stack
  **Rationale:** Matches existing MCP patterns, faster builds
  **Date:** 2025-01-14
```

### Note Surprises

```markdown
#### Surprises & Discoveries
- **Observation:** Ahrefs rate limits are per-minute, not per-day
  **Evidence:** API docs state 500 requests/minute
  **Impact:** Need to implement request queuing
```

## Completing a Plan

1. Ensure all tasks in `todo/tasks/tasks-{slug}.md` are checked
2. Record time at commit (offer: accept session duration, enter different time, or skip)
3. Update PLANS.md status to `Completed` with outcomes and time summary
4. Mark TODO.md reference done: `- [x] {title} #plan → [todo/PLANS.md#{slug}] ~4h actual:3h15m completed:2025-01-15`
5. Update CHANGELOG.md following `workflows/changelog.md` format

## PRD and Task Generation

### Generate PRD (`/create-prd`)

Ask clarifying questions with numbered options. Create PRD in `todo/tasks/prd-{slug}.md` using `templates/prd-template.md`.

### Generate Tasks (`/generate-tasks`)

**Phase 1**: Present high-level tasks with estimates, ask "Go" to generate sub-tasks.

**Phase 2**: Create in `todo/tasks/tasks-{slug}.md`:

```markdown
- [ ] 0.0 Create feature branch
  - [ ] 0.1 Create and checkout: `git checkout -b feature/{slug}`
- [ ] 1.0 {First major task}
  - [ ] 1.1 {Sub-task}
```

## Time Estimation Heuristics

| Task Type | AI Time | Test Time | Read Time |
|-----------|---------|-----------|-----------|
| Simple fix | 15-30m | 10-15m | 5m |
| New function | 30m-1h | 15-30m | 10m |
| New component | 1-2h | 30m-1h | 15m |
| New feature | 2-4h | 1-2h | 30m |
| Architecture change | 4-8h | 2-4h | 1h |
| Research/spike | 1-2h | — | 30m |

## Dependencies and Blocking

```markdown
- [ ] t001 Parent task ~4h
  - [ ] t001.1 Subtask ~2h blocked-by:t002
    - [ ] t001.1.1 Sub-subtask ~1h
  - [ ] t001.2 Another subtask ~1h blocks:t003
```

**TOON machine-readable format**:

```markdown
<!--TOON:dependencies[N]{from_id,to_id,type}:
t019.2,t019.1,blocked-by
t019.3,t019.2,blocked-by
-->
```

### /ready Command

```bash
/ready
# or: ~/.aidevops/agents/scripts/todo-ready.sh
```

Shows tasks with no open blockers and lists blocked tasks with their dependencies.

## Beads Integration

```bash
/sync-beads push   # TODO.md → Beads
/sync-beads pull   # Beads → TODO.md
/sync-beads        # Two-way sync with conflict detection
# or: ~/.aidevops/agents/scripts/beads-sync-helper.sh [push|pull|sync]
```

**Sync guarantees**: Lock file during sync, checksum verification, conflict detection, audit trail in `.beads/sync.log`, command-led only (no automatic sync).

**Beads UIs**: `bv` (graph analytics), `npx beads-ui start` (web dashboard), `bdui` (terminal), `perles` (BQL queries), `M-x beads-list` (Emacs).

## Time Tracking Configuration

Configure per-repo in `.aidevops.json`:

```json
{ "time_tracking": "prompt", "features": ["planning", "time-tracking", "beads"] }
```

`true` = always prompt | `false` = never | `prompt` = ask once per session.

Use `/log-time-spent` to manually log time anytime.

## Git Branch Strategy for TODO.md Changes

**Stay on current branch** (default): Task discovered during work, subtask additions, status updates, dependency updates, context notes.

**Consider dedicated worktree** when adding unrelated backlog items:

| Condition | Recommendation |
|-----------|----------------|
| TODO.md-only changes | Commit directly on main (no branch needed) |
| Mixed changes (TODO + code/agent files) | Create a worktree |
| Adding 3+ unrelated items on a feature branch | Suggest committing on main instead |

**NEVER use `git checkout -b` in the main repo directory.** Use `wt switch -c` for dedicated branches.

**Bottom line**: Related work stays together; unrelated TODO-only backlog goes directly to main; mixed changes use a worktree.

## Distributed Task Claiming (t164/t165)

**TODO.md is the master source of truth** for task ownership. GitHub issues are a public interface — bi-directionally synced but never authoritative over TODO.md.

| Step | What happens |
|------|-------------|
| **Claim** | `git pull` → check `assignee:` → add `assignee:identity started:ISO` → commit+push → sync to GH issue |
| **Check** | `grep "assignee:"` on task line — instant, offline |
| **Unclaim** | Remove `assignee:` + `started:` → commit+push → sync to GH issue |
| **Race protection** | Git push rejection = someone else claimed first. Pull, re-check, abort. |

**Identity**: Set `AIDEVOPS_IDENTITY` env var, or defaults to `$(whoami)@$(hostname -s)`.

**Status labels** on GitHub Issues: `status:available` → `status:claimed` → `status:in-review` → `status:done`

## MANDATORY: Worker TODO.md Restriction

**Workers (headless dispatch runners) must NEVER edit TODO.md directly.** This is the primary cause of merge conflicts when multiple workers + supervisor push to TODO.md on main simultaneously.

| Actor | May edit TODO.md? | How they report status |
|-------|-------------------|----------------------|
| **Supervisor** (cron pulse) | Yes (via `todo_commit_push()`) | Directly updates TODO.md |
| **Interactive user session** | Yes (via `planning-commit-helper.sh`) | Directly updates TODO.md |
| **Worker** (headless runner) | **NO** | Exit code + log output + mailbox + PR creation |

Workers communicate via: exit code (0 = success), log output, `mail-helper.sh send`, and PR creation. The supervisor updates TODO.md based on these signals during its pulse cycle.

## MANDATORY: Commit and Push After TODO Changes

After ANY edit to TODO.md, todo/PLANS.md, or todo/tasks/*, commit and push immediately. **Interactive sessions and supervisor only — not workers.**

### Planning-only changes (on main)

```bash
~/.aidevops/agents/scripts/planning-commit-helper.sh "chore: add {description} to backlog"
```

No branch, no PR — commit and push directly to main. Uses `todo_commit_push()` for serialized locking.

### Mixed changes (planning + non-exception files)

1. Create a worktree: `wt switch -c chore/todo-{slug}`
2. Make changes in the worktree directory
3. Commit, push, PR, merge from the worktree

**NEVER use `git checkout -b` or `git stash` in the main repo directory.**

**Commit message conventions**:

| Change | Message |
|--------|---------|
| New backlog item | `chore: add t{NNN} {short description} to backlog` |
| Multiple items | `chore: add t{NNN}-t{NNN} backlog items` |
| Status update | `chore: update task t{NNN} status` |
| Plan creation | `chore: add plan for {title}` |

## GitHub Issue Sync

- **GitHub issue titles** MUST be prefixed with their TODO.md task ID: `t{NNN}: {title}`
- **TODO.md tasks** MUST reference their GitHub issue: `ref:GH#{NNN}`

```bash
# Create issue with t-number prefix
gh issue create --title "t146: bug: supervisor no_pr retry counter non-functional" ...

# TODO.md entry with ref
- [ ] t146 bug: supervisor no_pr retry counter #bugfix ~15m logged:2026-02-07 ref:GH#439
```

When creating both together: assign t-number → create GitHub issue → add TODO entry with `ref:GH#` → commit and push immediately.

## Integration with Other Workflows

| Workflow | Integration |
|----------|-------------|
| `git-workflow.md` | Branch names derived from tasks/plans |
| `branch.md` | Task 0.0 creates branch |
| `preflight.md` | Run before marking plan complete |
| `changelog.md` | Update on plan completion |

## Templates

- `templates/prd-template.md` — PRD structure
- `templates/tasks-template.md` — Task list format
- `templates/todo-template.md` — TODO.md for new repos
- `templates/plans-template.md` — PLANS.md for new repos
