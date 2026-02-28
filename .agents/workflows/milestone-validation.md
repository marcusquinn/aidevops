---
description: Milestone validation — verify milestone completion by running tests, build, linting, browser QA, and integration checks, then report results and create fix tasks on failure
mode: subagent
model: sonnet  # validation is structured checking, not complex reasoning
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
| `tools/browser/browser-qa.md` | Browser QA subagent for visual validation |
| `scripts/browser-qa-helper.sh` | Playwright-based visual testing CLI |
| `scripts/accessibility/playwright-contrast.mjs` | Contrast/accessibility checks |
| `templates/mission-template.md` | Mission state file format |
| `workflows/postflight.md` | Similar pattern for release validation |

<!-- AI-CONTEXT-END -->

## How to Think

You are a QA engineer validating a milestone. Your job is to run every check that could catch a regression, layout bug, broken link, or missing feature — then report clearly what passed and what failed. You are not implementing features; you are verifying them.

**Validation is pass/fail, not subjective.** Every check must have a clear criterion. "Looks good" is not a validation result. "All 5 pages render without console errors, all links return 2xx, hero image loads in <3s" is.

**Fail fast, report everything.** Don't stop at the first failure. Run all checks, collect all failures, then report them together. The orchestrator needs the full picture to create targeted fix tasks.

**Use the cheapest tool that works.** For most checks, `curl` + status codes is sufficient. Use Playwright only when you need to verify rendered output, JavaScript-dependent content, or visual layout. Use Stagehand only when page structure is unknown and you need AI to interpret it.

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

### Browser QA (UI Milestones)

When the milestone's validation criteria mention UI, pages, visual, layout, responsive, or the milestone features include frontend components, run the browser QA pipeline via `scripts/browser-qa-helper.sh`:

| Check | What it does | Command |
|-------|-------------|---------|
| **Smoke test** | Console errors, network failures, basic rendering | `browser-qa-helper.sh smoke --url URL --pages "/ /about"` |
| **Screenshots** | Multi-viewport visual capture | `browser-qa-helper.sh screenshot --url URL --viewports desktop,mobile` |
| **Broken links** | Crawl internal links, verify 2xx responses | `browser-qa-helper.sh links --url URL --depth 2` |
| **Accessibility** | WCAG contrast, ARIA, heading hierarchy, labels | `browser-qa-helper.sh a11y --url URL --level AA` |
| **Full pipeline** | All of the above in sequence | `browser-qa-helper.sh run --url URL --pages "/ /about"` |

See `tools/browser/browser-qa.md` for the full browser QA subagent documentation, including severity mapping and content verification patterns.

### Optional Checks

| Check | When | Flag |
|-------|------|------|
| **Playwright browser tests** | UI milestones with existing test suite | `--browser-tests` |
| **Browser QA (visual testing)** | UI milestones, especially POC mode without test suite | `--browser-qa` |
| **Custom validation criteria** | Per-milestone criteria from mission file | Automatic (reads `**Validation:**` field) |

**Browser QA vs Browser Tests**: `--browser-tests` runs the project's own Playwright test suite (requires `playwright.config.{ts,js}`). `--browser-qa` runs generic visual QA — screenshots, broken link detection, console error capture — that works even without a test suite. Both can be used together. See `workflows/browser-qa.md` for details.

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

# With browser tests for UI milestone (project has playwright.config.ts)
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  ~/Git/myproject/todo/missions/m-20260227-abc123/mission.md 2 \
  --browser-tests --browser-url http://localhost:3000

# With browser QA for visual testing (no test suite needed)
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  ~/Git/myproject/todo/missions/m-20260227-abc123/mission.md 2 \
  --browser-qa --browser-url http://localhost:3000

# Both browser tests and browser QA
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  mission.md 2 --browser-tests --browser-qa --browser-url http://localhost:3000

# Browser QA with custom flows
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  mission.md 2 --browser-qa --browser-url http://localhost:3000 \
  --browser-qa-flows '["/", "/about", "/login"]'

# Report-only (don't update mission state)
~/.aidevops/agents/scripts/milestone-validation-worker.sh \
  mission.md 1 --report-only --verbose
```

### Browser QA (Standalone)

For direct browser QA without the full validation pipeline:

```bash
# Full QA suite
browser-qa-helper.sh run --url http://localhost:3000 --pages "/ /about /dashboard" --format json

# Screenshot comparison
browser-qa-helper.sh screenshot --url http://localhost:3000 --pages "/" --viewports desktop,mobile

# Broken link check
browser-qa-helper.sh links --url http://localhost:3000

# Accessibility check
browser-qa-helper.sh a11y --url http://localhost:3000
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Validation passed — milestone is good to advance |
| `1` | Validation failed — issues found, fix tasks created |
| `2` | Configuration error — missing arguments, bad paths |
| `3` | Mission state error — milestone not ready for validation |

## Failure Handling

### Severity Classification

| Finding | Severity | Blocks Milestone? |
|---------|----------|-------------------|
| Build fails, tests crash | Critical | Yes |
| Page returns 5xx, blank page | Critical | Yes |
| Console error on load | Critical | Yes |
| Broken internal link (404) | Major | Yes |
| Layout break at required viewport | Major | Yes |
| Missing content from acceptance criteria | Major | Yes |
| Contrast ratio failure (AA) | Major | Yes (if a11y is in criteria) |
| Missing alt text | Minor | No (note in report) |
| Heading hierarchy skip | Minor | No (note in report) |
| Console warning (not error) | Minor | No (note in report) |

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

## Dev Server Management

The validation worker must start and stop the dev server cleanly:

```bash
# Detect and start
if [[ -f "package.json" ]]; then
  # Check for dev script
  if jq -e '.scripts.dev' package.json &>/dev/null; then
    npm run dev &
    DEV_PID=$!
  elif jq -e '.scripts.start' package.json &>/dev/null; then
    npm start &
    DEV_PID=$!
  fi
fi

# Wait for server to be ready
for i in {1..30}; do
  curl -s http://localhost:3000 >/dev/null 2>&1 && break
  sleep 1
done

# ... run validation ...

# Cleanup
if [[ -n "${DEV_PID:-}" ]]; then
  kill "$DEV_PID" 2>/dev/null || true
fi
```

**Port detection**: Check `package.json` scripts for port numbers, or try common ports (3000, 3001, 5173, 8080, 8000).

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
| **Checks** | Tests, build, lint, browser tests, browser QA | CI/CD, SonarCloud, security, secrets |
| **On failure** | Create fix tasks, re-validate | Rollback or hotfix release |
| **State** | Mission state file | Git tags, GitHub releases |

## Related

- `workflows/mission-orchestrator.md` — Invokes this worker at Phase 4
- `tools/browser/browser-qa.md` — Browser QA subagent (visual testing details)
- `scripts/browser-qa-helper.sh` — CLI for Playwright-based visual testing
- `tools/browser/browser-automation.md` — Browser tool selection guide
- `scripts/accessibility/playwright-contrast.mjs` — Contrast/accessibility checks
- `workflows/postflight.md` — Similar validation pattern for releases
- `workflows/preflight.md` — Pre-commit quality checks
- `scripts/commands/full-loop.md` — Worker execution per feature
- `scripts/browser-qa-worker.sh` — Browser QA shell wrapper
- `scripts/browser-qa/browser-qa.mjs` — Playwright QA engine
- `templates/mission-template.md` — Mission state file format
