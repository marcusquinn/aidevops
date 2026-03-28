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

<!-- AI-CONTEXT-END -->

## Auto-Detection Logic

When `/save-todo` is invoked, analyze the conversation for complexity signals:

| Signal | Indicates | Action |
|--------|-----------|--------|
| Single action item / < 2h estimate / "quick" or "simple" | Simple | TODO.md only |
| Multiple distinct steps / research needed / >= 2h / multi-session / PRD needed | Complex | PLANS.md + TODO.md |

## Ralph Classification

Tasks can be classified as "Ralph-able" — suitable for autonomous iterative AI loops.

**Criteria** (all required): clear success criteria, automated verification, bounded scope, no human judgment needed.

| Signal | Ralph-able? |
|--------|-------------|
| "Make all tests pass" / "Fix linting errors" / "Implement feature X with tests" | Yes |
| "Refactor until clean" | Maybe (needs specific criteria) |
| "Make it look better" / "Design the API" / "Debug production issue" | No |

**Tagging**: `- [ ] t042 Fix all ShellCheck violations #ralph(SHELLCHECK_CLEAN) ~1h` with optional `ralph-promise:`, `ralph-verify:`, `ralph-max:` fields.

**Running**: `/ralph-task t042` or `/ralph-loop "$(grep -E '^- \[ \] t042\s' TODO.md | head -n1)" --completion-promise "SHELLCHECK_CLEAN" --max-iterations 10`

**Quality loop integration**: Preflight (`/preflight-loop`, `PREFLIGHT_PASS`), PR Review (`/pr-loop`, `PR_APPROVED`), Postflight (`/postflight-loop`, `RELEASE_HEALTHY`).

## Auto-Dispatch Tagging

Add `#auto-dispatch` only when ALL inclusion criteria pass and NO exclusion criteria apply:

| Include (ALL required) | Exclude (ANY blocks) |
|------------------------|----------------------|
| Clear fix/feature with specific files or patterns | Requires credentials, accounts, or purchases |
| Bounded scope (~1h or less) | Is a `#plan` needing decomposition first |
| No design decisions requiring user preference | Requires hardware or external service setup |
| Verification is automatable (tests, ShellCheck, syntax, browser) | Description says "investigate"/"evaluate" without clear deliverable |
| | Has `blocked-by:` dependencies on incomplete tasks |

## Saving Work

### MANDATORY: Task Brief Requirement

**Every task MUST have a brief file** at `todo/tasks/{task_id}-brief.md`. A task without a brief is undevelopable — it loses the conversation context that informed it. Use `templates/brief-template.md`. Captures: origin (session ID, date, author), what, why, how (with file refs), acceptance criteria, context.

**Session provenance is mandatory.** Detect runtime: `$OPENCODE_SESSION_ID`, `$CLAUDE_SESSION_ID`, or `{app}:unknown-{date}`.

### Task Description Quality (GH#6419)

Task descriptions in TODO.md become GitHub issue titles — primary input to pulse duplicate detection. Include the **what** (action), **where** (component/file/feature area), and **when/why** (triggering condition). Exception: persistent/pinned monitoring issues keep their concise title style.

**Good**: `Add WooCommerce tax fallback when no tax class matches product category`
**Bad**: `Tax fallback`

### Save Flow

Extract from conversation: title, description, estimate (`~Xh (ai:Xh test:Xh read:Xm)`), tags, context, session ID.

**Simple** — present: `Saving to TODO.md: "{title}" ~{estimate} | Creating brief: todo/tasks/{task_id}-brief.md | 1. Confirm  2. Add more details  3. Create full plan instead`

1. Create brief at `todo/tasks/{task_id}-brief.md`
2. Add to TODO.md Backlog: `- [ ] t{NNN} {title} #{tag} ~{estimate} logged:{YYYY-MM-DD}`

Format elements (all optional except id and description): `@owner`, `#tag`, `~estimate`, `logged:YYYY-MM-DD`, `blocked-by:t001,t002`, `blocks:t003`.

**Auto-dispatch gate**: Only add `#auto-dispatch` if the brief has at least 2 specific acceptance criteria, a non-empty How section with file references, and a clear What section.

**Complex** — present: `This looks like complex work. Creating execution plan. Title: {title} | Estimate: ~{estimate} | Phases: {count} | Creating brief: todo/tasks/{task_id}-brief.md | 1. Confirm and create plan + brief  2. Simplify to TODO.md + brief  3. Add more context`

1. Create PLANS.md entry using `templates/plans-template.md`. Required sections: **Status/Estimate**, **Purpose**, **Progress** (timestamped phases), **Context from Discussion**, **Decision Log**, **Surprises & Discoveries**.
2. Add reference to TODO.md: `- [ ] {title} #plan -> [todo/PLANS.md#{slug}] ~{estimate} logged:{YYYY-MM-DD}`
3. Optionally create PRD/tasks if scope warrants (`/create-prd`, `/generate-tasks`)

## Starting Work from Plans

When user says "Let's work on X":

1. **Find**: `grep -i "{keyword}" TODO.md todo/PLANS.md`
2. **Load context**: Read PRD/tasks files if they exist
3. **Present**: `Found: "{title}" (~{estimate}) -- 1. Start working  2. View details  3. Different task`
4. **Follow**: `git-workflow.md` after branch creation

## During Implementation

Update PLANS.md in place: check off Progress items with timestamps, add Decision Log entries (`Decision:`, `Rationale:`, `Date:`), and record Surprises & Discoveries (`Observation:`, `Evidence:`, `Impact:`).

## Completing a Plan

1. Ensure all tasks in `todo/tasks/tasks-{slug}.md` are checked
2. Record time at commit (offer: accept session duration, enter different time, or skip)
3. Update PLANS.md status to `Completed` with outcomes and time summary
4. Mark TODO.md reference done: `- [x] {title} #plan -> [todo/PLANS.md#{slug}] ~4h actual:3h15m completed:2025-01-15`
5. Update CHANGELOG.md following `workflows/changelog.md` format

## PRD and Task Generation

**Generate PRD** (`/create-prd`): Ask clarifying questions with numbered options. Create PRD in `todo/tasks/prd-{slug}.md` using `templates/prd-template.md`.

**Generate Tasks** (`/generate-tasks`): Phase 1 — present high-level tasks with estimates, ask "Go". Phase 2 — create in `todo/tasks/tasks-{slug}.md` with numbered hierarchy (`0.0`, `1.0`, `1.1`, etc.) using `templates/tasks-template.md`.

## Time Estimation

Use calibrated tiers from `reference/planning-detail.md` (based on 340 completed tasks). Default `~30m` for most tasks. Estimates >= 2h trigger auto-subtasking.

## Dependencies and Blocking

```markdown
- [ ] t001 Parent task ~4h
  - [ ] t001.1 Subtask ~2h blocked-by:t002
    - [ ] t001.1.1 Sub-subtask ~1h
  - [ ] t001.2 Another subtask ~1h blocks:t003
```

**TOON machine-readable format**: `<!--TOON:dependencies[N]{from_id,to_id,type}: t019.2,t019.1,blocked-by -->`

**`/ready` command**: `~/.aidevops/agents/scripts/todo-ready.sh` — shows tasks with no open blockers and lists blocked tasks with their dependencies.

## Beads Integration

`/sync-beads push` (TODO→Beads) | `/sync-beads pull` (Beads→TODO) | `/sync-beads` (two-way with conflict detection). Script: `beads-sync-helper.sh [push|pull|sync]`. Guarantees: lock file, checksum verification, audit trail in `.beads/sync.log`, command-led only.

**Beads UIs**: `bv` (graph analytics), `npx beads-ui start` (web dashboard), `bdui` (terminal), `perles` (BQL queries), `M-x beads-list` (Emacs).

## Time Tracking Configuration

Configure per-repo in `.aidevops.json`: `{ "time_tracking": "prompt", "features": ["planning", "time-tracking", "beads"] }`. Values: `true` = always prompt | `false` = never | `prompt` = ask once per session. Use `/log-time-spent` to manually log time.

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

**Workers (headless dispatch runners) must NEVER edit TODO.md directly.** Primary cause of merge conflicts when multiple workers + supervisor push to TODO.md on main simultaneously.

| Actor | May edit TODO.md? | How they report status |
|-------|-------------------|----------------------|
| **Supervisor** (cron pulse) | Yes (via `todo_commit_push()`) | Directly updates TODO.md |
| **Interactive user session** | Yes (via `planning-commit-helper.sh`) | Directly updates TODO.md |
| **Worker** (headless runner) | **NO** | Exit code + log output + mailbox + PR creation |

## MANDATORY: Commit and Push After TODO Changes

After ANY edit to TODO.md, todo/PLANS.md, or todo/tasks/*, commit and push immediately. **Interactive sessions and supervisor only — not workers.**

| Condition | Action |
|-----------|--------|
| TODO.md-only changes | Commit directly on main — `planning-commit-helper.sh "chore: add {description} to backlog"` |
| Mixed changes (TODO + code/agent files) | Create a worktree (`wt switch -c chore/todo-{slug}`), make changes, commit, push, PR, merge |
| Adding 3+ unrelated items on a feature branch | Suggest committing on main instead |

**NEVER use `git checkout -b` or `git stash` in the main repo directory.**

**Commit message conventions**: New backlog item: `chore: add t{NNN} {short description} to backlog` | Multiple items: `chore: add t{NNN}-t{NNN} backlog items` | Status update: `chore: update task t{NNN} status` | Plan creation: `chore: add plan for {title}`

## GitHub Issue Sync

- **GitHub issue titles** MUST be prefixed with their TODO.md task ID: `t{NNN}: {title}`
- **TODO.md tasks** MUST reference their GitHub issue: `ref:GH#{NNN}`
- When creating both together: assign t-number → create GitHub issue → add TODO entry with `ref:GH#` → commit and push immediately.

Example: `- [ ] t146 bug: supervisor no_pr retry counter #bugfix ~15m logged:2026-02-07 ref:GH#439`

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
