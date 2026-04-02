# Self-Improvement

Every session must improve the system. Fix the process, not the symptom.

## Core Workflow

**State observation.** `TODO.md`, `todo/PLANS.md`, and GitHub issues/PRs are the canonical state. Never duplicate into separate files/logs.

**Signals** (check via `gh` CLI):
- PR open 6h+ with no progress or no change in consecutive pulses.
- PR closed without merge (worker failure).
- Repeated CI failures or duplicate PRs.

**Response: file an issue.** Describe pattern, root cause, and proposed fix. Never patch around broken processes.

## Routing & Filing

**Framework-level** (`~/.aidevops/`, scripts, prompts, orchestration) → `marcusquinn/aidevops`. **Project-specific** (CI, code, deps) → current repo. Test: "Does this apply to all repos?" Never file framework tasks in project repos.

### Filing framework issues (GH#5149)

Use `framework-issue-helper.sh`, not `claim-task-id.sh`:

```bash
# Detect framework vs project (exit 0=framework, 1=project)
~/.aidevops/agents/scripts/framework-issue-helper.sh detect "description"

# File on marcusquinn/aidevops (auto-deduplicates)
~/.aidevops/agents/scripts/framework-issue-helper.sh log \
  --title "Bug: supervisor pipeline fails..." --body "Observed in..." --label "bug"
```

## Constraints & Quality

**Scope boundary (t1405, GH#2928):** `PULSE_SCOPE_REPOS` limits worktrees/PRs. Filing issues is always allowed. Outside scope → file issue and stop.

**Issue quality filter (GH#6508):** Enhancements require (1) observed failure (no preemptive bloat), (2) no deterministic alternative, (3) not a deliberate framework choice. Bar: **observed failure first, minimal guidance**.

**Intelligence over determinism:** See `prompts/build.txt`. Use deterministic rules for CLI/paths/security; judgment for everything else. Use cheapest capable model.

## What to Improve

- Repeated failure patterns, prompt misunderstandings, or missing automation.
- Stale blocked tasks or **information gaps (t1416)** (missing tier/branch/diagnosis).
- Run session miner pulse (`scripts/session-miner-pulse.sh`).

## Autonomous Operation

"continue"/"monitor"/"keep going" → autonomous mode: sleep/wait loops, perpetual todo for compaction survival. Interrupt only for blocking errors requiring user input.
