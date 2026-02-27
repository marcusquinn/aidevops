---
description: Milestone validation — verify milestone completion by running tests, build, linting, and optional browser tests, then report results and create fix tasks on failure
mode: subagent
model: sonnet  # validation is structured checking, not complex reasoning
tools:
  read: true
  write: true
  edit: true
  bash: true
  task: true
---

# Milestone Validation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate that a completed milestone meets its acceptance criteria before the mission advances
- **Script**: `scripts/milestone-validation-worker.sh`
- **Invoked by**: Mission orchestrator (Phase 4) after all features in a milestone are completed
- **Output**: Pass/fail report with specific failures, fix tasks created on failure

**Key files**:

| File | Purpose |
|------|---------|
| `scripts/milestone-validation-worker.sh` | Validation runner script |
| `workflows/mission-orchestrator.md` | Orchestrator that invokes validation |
| `templates/mission-template.md` | Mission state file format |
| `workflows/postflight.md` | Similar pattern for release validation |

<!-- AI-CONTEXT-END -->

## When to Use

The milestone validation worker runs at a specific point in the mission lifecycle:

```text
Features dispatched → Features complete → MILESTONE VALIDATION → Next milestone (or fix tasks)
```

It is triggered when:

1. All features in a milestone have status `completed` (PRs merged in Full mode, commits landed in POC mode)
2. The mission orchestrator sets the milestone status to `validating`
3. The orchestrator dispatches the validation worker

## What It Validates

### Automated Checks (Always Run)

| Check | What it does | Detected via |
|-------|-------------|--------------|
| **Dependencies** | Ensures `node_modules` / venv / deps are installed | `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod` |
| **Test suite** | Runs the project's test framework | `npm test`, `pytest`, `cargo test`, `go test` |
| **Build** | Verifies the project builds cleanly | `npm run build`, `cargo build`, `go build` |
| **Linter** | Runs project linting | `npm run lint`, `ruff`, `tsc --noEmit`, `shellcheck` |

### Optional Checks

| Check | When | Flag |
|-------|------|------|
| **Playwright browser tests** | UI milestones | `--browser-tests` |
| **Custom validation criteria** | Per-milestone criteria from mission file | Automatic (reads `**Validation:**` field) |

### Framework Detection

The script auto-detects the project's tech stack:

| Signal | Framework | Test command | Build command |
|--------|-----------|-------------|---------------|
| `bun.lockb` / `bun.lock` | Bun | `bun test` | `bun run build` |
| `pnpm-lock.yaml` | pnpm | `pnpm test` | `pnpm run build` |
| `yarn.lock` | Yarn | `yarn test` | `yarn run build` |
| `package.json` | npm (fallback) | `npm test` | `npm run build` |
| `pyproject.toml` / `setup.py` | Python | `pytest` | — |
| `Cargo.toml` | Rust | `cargo test` | `cargo build` |
| `go.mod` | Go | `go test ./...` | `go build ./...` |
| `.agents/scripts/` | Shell (aidevops) | `shellcheck` | — |

## Usage

### From the Mission Orchestrator

The orchestrator invokes validation as part of Phase 4:

```bash
# Basic validation
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  ~/Git/myproject/todo/missions/m-20260227-abc123/mission.md 1

# With browser tests for UI milestone
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  ~/Git/myproject/todo/missions/m-20260227-abc123/mission.md 2 \
  --browser-tests --browser-url http://localhost:3000

# Report-only (don't update mission state)
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  mission.md 1 --report-only --verbose
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Validation passed — milestone is good to advance |
| `1` | Validation failed — issues found, fix tasks created |
| `2` | Configuration error — missing arguments, bad paths |
| `3` | Mission state error — milestone not ready for validation |

## Failure Handling

### On Validation Failure

1. Milestone status is set to `failed` in the mission state file
2. A progress log entry is appended with failure details
3. Fix tasks are created (Full mode: GitHub issues; POC mode: logged)
4. The orchestrator can re-dispatch fixes and re-validate

### Retry Logic

The mission orchestrator tracks validation attempts per milestone. After `--max-retries` failures (default: 3) on the same milestone, the mission is paused and the user is notified.

```text
Attempt 1: Validate → Fail → Create fix tasks → Dispatch fixes
Attempt 2: Re-validate → Fail → Create fix tasks → Dispatch fixes
Attempt 3: Re-validate → Fail → PAUSE MISSION → Notify user
```

### Fix Task Format

In Full mode, fix tasks are created as GitHub issues:

```markdown
## Milestone Validation Fix

**Mission:** `m-20260227-abc123`
**Milestone:** 2
**Failure:** Test suite (npm test): 3 tests failed in auth.test.ts

**Context:** Auto-created by milestone validation worker.
**What to fix:** Address the specific failure described above.
**Validation criteria:** Re-run milestone validation after fix.
```

Issues are labelled `bug` and `mission:{id}` for traceability.

## Integration with Mission Orchestrator

The orchestrator's Phase 4 (in `workflows/mission-orchestrator.md`) delegates to this worker:

```bash
# Orchestrator detects all features complete
# Sets milestone status to 'validating'
# Runs validation:

validation_exit=0
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  "$MISSION_FILE" "$MILESTONE_NUM" \
  $([[ "$IS_UI_MILESTONE" == "true" ]] && echo "--browser-tests") \
  || validation_exit=$?

case $validation_exit in
  0) # Advance to next milestone
     ;;
  1) # Validation failed — fixes dispatched automatically
     # Re-validate after fixes complete
     ;;
  *) # Configuration/state error — pause mission
     ;;
esac
```

## Relationship to Postflight

Milestone validation and postflight (`workflows/postflight.md`) serve similar purposes at different scopes:

| Aspect | Milestone Validation | Postflight |
|--------|---------------------|------------|
| **Scope** | One milestone within a mission | One release of the entire project |
| **Trigger** | All milestone features complete | After git tag + GitHub release |
| **Checks** | Tests, build, lint, browser | CI/CD, SonarCloud, security, secrets |
| **On failure** | Create fix tasks, re-validate | Rollback or hotfix release |
| **State** | Mission state file | Git tags, GitHub releases |

## Related

- `workflows/mission-orchestrator.md` — Invokes this worker at Phase 4
- `workflows/postflight.md` — Similar validation pattern for releases
- `workflows/preflight.md` — Pre-commit quality checks
- `scripts/commands/full-loop.md` — Worker execution per feature
- `templates/mission-template.md` — Mission state file format
- `tools/browser/browser-automation.md` — Playwright for browser tests
