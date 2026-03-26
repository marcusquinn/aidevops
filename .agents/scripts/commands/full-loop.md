---
description: Start end-to-end development loop (task → preflight → PR → postflight → deploy)
agent: Build+
mode: subagent
---

Start a full development loop that chains all phases from task implementation to deployment.

Task/Prompt: $ARGUMENTS

## Phases

```text
Claim → Branch Setup → Task Development → Preflight → PR Create → PR Review → Postflight → Deploy
```

## Lifecycle Completeness Gate (t5096 + GH#5317 — MANDATORY)

Two fatal failure modes:

1. **GH#5317**: Worker exits after implementation WITHOUT committing or creating a PR. Uncommitted files in worktree are unrecoverable by the supervisor.
2. **GH#5096**: Worker exits after PR creation WITHOUT completing post-PR lifecycle (review, merge, release, cleanup). PR sits unmerged indefinitely.

**Full lifecycle — do NOT skip any step:**

| # | Step | Signal |
|---|------|--------|
| 0 | Commit+PR gate (GH#5317) — all changes committed, PR exists | `TASK_COMPLETE` |
| 1 | Review bot gate — wait for CodeRabbit/Gemini/Copilot (poll ≤10 min) | |
| 2 | Address critical findings from bot reviews | |
| 3 | Merge — `gh pr merge --squash` (no `--delete-branch` in worktrees) | |
| 4 | Auto-release — bump patch + GitHub release (aidevops repo only) | |
| 5 | Issue closing comment — structured comment on every linked issue | |
| 6 | Worktree cleanup — return to main, pull, prune | `FULL_LOOP_COMPLETE` |

This gate applies regardless of dispatch method (pulse, `/runners`, interactive).

---

## Step 0: Resolve Task ID and Set Session Title

Extract the first positional argument from `$ARGUMENTS` (ignoring flags like `--max-task-iterations`).

**Supervisor dispatch format (t158):** If `$ARGUMENTS` contains ` -- `, everything after is the task description. Use it directly instead of looking up TODO.md.

**If first arg matches `t\d+`:**

1. Resolve description via priority chain:
   - Priority 1: Inline description after ` -- `
   - Priority 2: `grep` from TODO.md
   - Priority 3: `gh issue list --search "$TASK_ID"` (for tasks not yet in TODO.md)
2. Set session title: `session-rename(title: "t061: Fix login bug")`
3. Fallback if empty: `"t061: (task not found)"`

**If first arg is NOT a task ID:**

- Use description directly for session title (truncate to ~60 chars if long)
- **Extract issue number if present (#2452 fix):** Parse `issue #NNN` from `$ARGUMENTS` using portable sed (not `grep -oP` — GNU-only, fails on macOS):

  ```bash
  ISSUE_NUM=$(echo "$ARGUMENTS" | sed -En 's/.*[Ii][Ss][Ss][Uu][Ee][[:space:]]*#*([0-9]+).*/\1/p' | head -1)
  ```

### Step 0.45: Task Decomposition Check (t1408.2)

Before claiming, classify whether the task should be decomposed. Catches over-scoped tasks before a worker spends hours on what should be multiple PRs.

**Skip if:** `--no-decompose` flag, or task already has subtasks in TODO.md.

```bash
DECOMPOSE_HELPER="$HOME/.aidevops/agents/scripts/task-decompose-helper.sh"
if [[ -x "$DECOMPOSE_HELPER" && -n "$TASK_ID" ]]; then
  HAS_SUBS=$(/bin/bash "$DECOMPOSE_HELPER" has-subtasks "$TASK_ID") || HAS_SUBS="false"
  if [[ "$HAS_SUBS" == "false" ]]; then
    CLASSIFY=$(/bin/bash "$DECOMPOSE_HELPER" classify "$TASK_DESC" --depth 0) || CLASSIFY=""
    TASK_KIND=$(echo "$CLASSIFY" | jq -r '.kind // "atomic"' || echo "atomic")
  fi
fi
```

**If atomic (default):** Proceed to Step 0.5.

**If composite — interactive:** Show decomposition tree, ask `[Y/n/edit]`. On confirm: create child task IDs via `claim-task-id.sh`, add to TODO.md with `blocked-by:` edges, create briefs, label parent `status:blocked`.

**If composite — headless:** Auto-decompose, create children, label parent blocked, exit with: `DECOMPOSED: task $TASK_ID split into $SUBTASK_COUNT subtasks ($CHILD_IDS). Parent blocked. Children queued for dispatch.`

**Depth limit:** `DECOMPOSE_MAX_DEPTH` env var (default: 3). At depth 3+, always treat as atomic.

### Step 0.5: Claim Task (t1017)

If first arg is a task ID, claim it to prevent concurrent work. Adds `assignee:<identity> started:<ISO>` to TODO.md via git commit+push. Race protection: push rejection = someone else claimed first.

- Exit 0: Claimed (or already yours) — proceed
- Exit 1: Claimed by another — **STOP** (headless: `BLOCKED: task claimed by assignee:{name}`)
- Skip when: not a task ID, or `--no-claim` flag

### Step 0.6: Update Issue Label — `status:in-progress`

Find linked issue number from: (1) `$ISSUE_NUM` extracted in Step 0, (2) TODO.md `ref:GH#NNN`, (3) `gh issue list --search "${TASK_ID}:"`.

```bash
if [[ -n "$ISSUE_NUM" && "$ISSUE_NUM" != "null" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  # t1343 + #2452: Check OPEN state — abort if closed
  ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
  if [[ "$ISSUE_STATE" != "OPEN" ]]; then
    echo "[t1343/#2452] Issue #$ISSUE_NUM is $ISSUE_STATE — aborting worker"
    exit 0
  fi
  WORKER_USER=$(gh api user --jq '.login' 2>/dev/null || whoami)
  gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-assignee "$WORKER_USER" --add-label "status:in-progress" 2>/dev/null || true
  for STALE in "status:available" "status:queued" "status:claimed"; do
    gh issue edit "$ISSUE_NUM" --repo "$REPO" --remove-label "$STALE" 2>/dev/null || true
  done
fi
```

**Label lifecycle:**

| Label | When | Set by |
|-------|------|--------|
| `status:available` | Issue created/recovered | issue-sync / pulse recovery |
| `status:queued` | Pulse dispatches worker | Supervisor |
| `status:in-progress` | Worker starts coding | Worker (this step) |
| `status:in-review` | PR opened | Worker (Step 4) |
| `status:blocked` | Unresolved blockers | Worker/supervisor |
| `status:done` | PR merged | sync-on-pr-merge workflow |
| `dispatched:{model}` | Worker started | Worker (Step 0.7) |

**Consistency:** Always remove prior status labels to keep exactly one active. Stale recovery: 3+ hours with no PR → pulse relabels `status:available`, unassigns, comments.

### Step 0.7: Label Dispatch Model — `dispatched:{model}`

Tag the issue with the model running this worker for cost/quality observability.

Detect model from env vars (`$ANTHROPIC_MODEL`, `$CLAUDE_MODEL`) or system prompt identity. Map: `*opus*` → `dispatched:opus`, `*sonnet*` → `dispatched:sonnet`, `*haiku*` → `dispatched:haiku`. Remove stale `dispatched:*` labels first. Create label if it doesn't exist. Apply in both headless and interactive sessions.

### Step 1.7: Parse Lineage Context (t1408.3)

If dispatch prompt contains `TASK LINEAGE:` block (injected by pulse for subtasks), parse it.

**Worker rules with lineage:**

1. **Scope boundary** — Only implement what's marked `<-- THIS TASK`
2. **Stub dependencies** — Define minimal stubs for sibling-created types/APIs; document in PR body under "Cross-task stubs"
3. **No sibling work** — Each sibling has its own worker/branch/PR
4. **PR body** — Include "Task Lineage" section (parent, this task, siblings, stubs)
5. **Blocked by sibling** — If hard dependency (not stub-able), exit: `BLOCKED: This task (tNNN) requires <item> from sibling tNNN, which has not been merged yet.`

---

## Step 1: Auto-Branch Setup

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "$ARGUMENTS"
```

- Exit 0: Already on feature branch or docs-only task — proceed
- Exit 2: Code task on main — auto-create worktree

**Detection:** Docs-only keywords (`readme`, `changelog`, `docs/`, `typo`). Code keywords override (`feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`).

**Worktree creation:** Prefer `wt switch -c "feature/$branch_name"`, fallback `worktree-helper.sh add`. Verify clean working directory and git remote configured.

### Step 1.5: Operation Verification (t1364.3)

Before high-stakes operations, invoke cross-provider model verification:

```bash
source ~/.aidevops/agents/scripts/verify-operation-helper.sh
risk=$(check_operation "terraform destroy")        # critical|high|moderate|low
result=$(verify_operation "terraform destroy" "$risk")  # verified|concerns:*|blocked:*
```

| Risk | Examples | Action |
|------|----------|--------|
| critical | Force push main, `rm -rf /`, drop DB, prod deploy | Block (headless) / confirm (interactive) |
| high | Force push, hard reset, branch delete, DB migration | Verify via cross-provider call |
| moderate | Package installs, config changes | Log only |
| low | Code edits, docs, tests | No verification |

Config: `VERIFY_ENABLED` (true), `VERIFY_POLICY` (warn), `VERIFY_TIMEOUT` (30s), `VERIFY_MODEL` (haiku).

---

## Step 2: Start Full Loop

**Headless mode (t174):** When dispatched by supervisor, `--headless` is passed automatically. Suppresses interactive prompts, prevents TODO.md edits, ensures clean exit on errors. Also settable via `FULL_LOOP_HEADLESS=true`.

```bash
# Background (recommended — avoids MCP timeout)
~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS" --background

# Monitor: status | logs | cancel
~/.aidevops/agents/scripts/full-loop-helper.sh {status|logs|cancel}

# Foreground (may timeout >120s)
~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS"
```

---

## Step 3: Task Development (Ralph Loop)

Iterate until emitting `<promise>TASK_COMPLETE</promise>`.

### Completion Criteria (ALL required)

1. All requirements implemented (list each as `[DONE]`)
2. Tests passing
3. Code quality acceptable (lint, shellcheck, type-check)
4. **Generalization check** — solution works for varying inputs
5. **README gate** — update README if task adds/changes user-facing features (see below)
6. Conventional commits used
7. Headless rules observed (see below)
8. **Actionable finding coverage** — every deferred finding from audit/review/scan has a tracked task+issue
9. **Runtime testing gate (t1660.7)** — risk-appropriate runtime verification (see below)
10. **Commit+PR gate (GH#5317 — MANDATORY):**

   ```bash
   UNCOMMITTED=$(git status --porcelain | wc -l | tr -d ' ')
   if [[ "$UNCOMMITTED" -gt 0 ]]; then
     git add -A && git commit -m "feat: complete implementation (GH#5317 commit gate)"
   fi
   CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
   if [[ "$CURRENT_BRANCH" != "main" && "$CURRENT_BRANCH" != "master" ]]; then
     git push -u origin HEAD 2>/dev/null || git push origin HEAD
     gh pr view >/dev/null 2>&1 || echo "[GH#5317] No PR — proceed to Step 4"
   fi
   ```

   **Do NOT emit `TASK_COMPLETE` with uncommitted changes or no PR.**

### Actionable Finding Coverage

For multi-finding reports (audit/review/scan): build `severity|title|details` list, then:

```bash
~/.aidevops/agents/scripts/findings-to-tasks-helper.sh create \
  --input <findings.txt> --repo-path "$(git rev-parse --show-toplevel)" --source <type>
```

Include in PR body: `actionable_findings_total=N`, `fixed_in_pr=N`, `deferred_tasks_created=N`, `coverage=100%`.

### Runtime Testing Gate (t1660.7 — MANDATORY)

Before emitting `TASK_COMPLETE`, classify the risk level of your changes and perform the appropriate level of runtime verification. This is a judgment call — the agent reads the diff, identifies risk patterns, and escalates testing accordingly. Static analysis (lint, typecheck) catches syntax; runtime testing catches behaviour.

#### Step 1: Diff Risk Classification

Analyse `git diff origin/main` for high-risk patterns. Each pattern detected raises the required testing level.

**Risk taxonomy:**

| Risk Level | Patterns in Diff | Required Testing |
|------------|-----------------|------------------|
| **Critical** | Payment/billing logic, auth/session handling, data deletion/migration, cryptographic operations, credential flows | `runtime-verified` |
| **High** | Polling/interval loops (`setInterval`, `setTimeout` chains, `while` polling), page reload triggers (`location.reload`, `router.refresh`), WebSocket/SSE connections, state machine transitions, form submission handlers, API endpoint changes | `runtime-verified` |
| **Medium** | UI component changes, CSS/layout modifications, new routes/pages, configuration changes, environment variable usage, database queries | `runtime-verified` when dev env available; `self-assessed` with justification otherwise |
| **Low** | Documentation, comments, type-only changes, test files only, linter config, CI config, agent prompts, markdown | `self-assessed` (no runtime testing needed) |

**Detection approach — intelligence, not regex:**

Read the diff holistically. A one-line CSS change is low risk. A one-line change to a payment webhook URL is critical. The pattern table above is guidance — use judgment for edge cases. When uncertain, escalate.

```bash
# Quick diff summary for risk assessment
git diff --stat origin/main
git diff origin/main -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.php' '*.rb' '*.go' '*.rs'
```

#### Step 2: Determine Testing Level

Three testing levels, in ascending order of rigour:

| Level | What It Means | When to Use |
|-------|--------------|-------------|
| `self-assessed` | Worker reviewed the code, ran static checks, assessed correctness by reading | Low-risk changes; no dev environment available and risk is medium or below |
| `unit-tested` | Automated test suite passes (`npm test`, `pytest`, `cargo test`, etc.) | Any project with an existing test suite; medium-risk changes |
| `runtime-verified` | Application started, behaviour confirmed in a running environment (browser, API call, CLI execution) | High/critical risk; any change touching user-facing behaviour in a project with a dev environment |

**Escalation is one-way:** If the diff contains ANY critical-risk pattern, the entire PR requires `runtime-verified` regardless of other low-risk changes in the same diff.

**Testing config integration (t1660.2):** If `.aidevops/testing.json` exists in the project root, read it for the project's dev environment setup, test commands, and smoke-test URLs. This file is created by `/testing-setup` (t1660.1). When the file doesn't exist, fall back to conventional detection:

```bash
# Detect available test infrastructure
TESTING_CONFIG="$(git rev-parse --show-toplevel)/.aidevops/testing.json"
if [[ -f "$TESTING_CONFIG" ]]; then
  # Use project-specific testing config (t1660.2)
  TEST_CMD=$(jq -r '.test_command // empty' "$TESTING_CONFIG")
  DEV_CMD=$(jq -r '.dev_command // empty' "$TESTING_CONFIG")
  SMOKE_URLS=$(jq -r '.smoke_urls[]? // empty' "$TESTING_CONFIG")
else
  # Conventional detection fallback
  [[ -f "package.json" ]] && TEST_CMD="npm test"
  [[ -f "pytest.ini" || -f "pyproject.toml" ]] && TEST_CMD="pytest"
  [[ -f "Cargo.toml" ]] && TEST_CMD="cargo test"
  [[ -f "go.mod" ]] && TEST_CMD="go test ./..."
fi
```

#### Step 3: Execute Testing

**For `self-assessed`:** Document in the commit message or PR body what you reviewed and why runtime testing was not required. Example: "Self-assessed: docs-only change, no runtime behaviour affected."

**For `unit-tested`:** Run the test suite and confirm it passes:

```bash
if [[ -n "${TEST_CMD:-}" ]]; then
  eval "$TEST_CMD" || {
    echo "[t1660.7] Unit tests failed — fix before TASK_COMPLETE"
    # Do NOT proceed to TASK_COMPLETE
  }
fi
```

**For `runtime-verified`:** Start the dev environment, verify behaviour, and record evidence:

1. **Start dev server** (if not already running):

   ```bash
   # Use testing.json dev_command, or detect conventionally
   if [[ -n "${DEV_CMD:-}" ]]; then
     eval "$DEV_CMD" &
     DEV_PID=$!
     sleep 5  # Allow startup
   fi
   ```

2. **Run smoke checks** — verify the application loads and key pages respond:

   ```bash
   # browser-qa-helper.sh stability (t1660.3) when available
   STABILITY_HELPER="$HOME/.aidevops/agents/scripts/browser-qa-helper.sh"
   if [[ -x "$STABILITY_HELPER" ]] && "$STABILITY_HELPER" help 2>&1 | grep -q 'stability'; then
     "$STABILITY_HELPER" stability --url "${SMOKE_URLS:-http://localhost:3000}" --timeout 30
   else
     # Fallback: basic HTTP check
     curl -sf "${SMOKE_URLS:-http://localhost:3000}" >/dev/null 2>&1 || {
       echo "[t1660.7] Smoke check failed — application not responding"
     }
   fi
   ```

3. **Verify changed behaviour** — for UI changes, load the affected page; for API changes, call the affected endpoint; for CLI changes, run the affected command. This is the agent's judgment call — there is no script for "verify the thing you changed works."

4. **Record evidence** in the PR body (see Step 4.7 structured format, t1660.10):

   ```markdown
   ## Runtime Testing
   - **Testing level:** runtime-verified
   - **Risk classification:** high (polling loop in useDataSync hook)
   - **Dev environment:** npm run dev (Next.js 14, localhost:3000)
   - **Smoke check:** homepage loads, /dashboard renders, /api/health returns 200
   - **Behaviour verified:** polling interval respects backoff, stops on unmount
   ```

#### Step 4: Gate Enforcement

**Before `TASK_COMPLETE`**, verify the testing level matches the risk:

| Situation | Action |
|-----------|--------|
| Critical/high risk + no runtime verification | **BLOCK** — do not emit `TASK_COMPLETE`. Start the dev env and verify, or exit `BLOCKED: runtime testing required but dev environment unavailable` |
| Medium risk + no dev env available | **WARN** — proceed with `self-assessed` but document the gap in PR body: "Medium-risk change, runtime testing recommended but dev environment not configured. Run `/testing-setup` to enable." |
| Low risk + self-assessed | **PASS** — proceed normally |
| Any risk + `testing.json` specifies `required_level` | **ENFORCE** — the project config overrides the default risk mapping. If `testing.json` says `runtime-verified` is required for all PRs, comply regardless of diff risk. |

**Headless mode behaviour:** In headless dispatch, if runtime testing is required but the dev environment fails to start (missing dependencies, port conflict, Docker not running), exit with a structured message:

```text
BLOCKED: Runtime testing required (risk: high — auth flow changes in src/auth/handler.ts)
but dev environment failed to start: npm run dev exited with code 1 (missing NEXT_PUBLIC_API_URL).
Recommend: configure .aidevops/testing.json via /testing-setup, or add env vars to .env.local.
```

**`--skip-runtime-testing` flag:** For emergency hotfixes, pass `--skip-runtime-testing` to `/full-loop`. This bypasses the gate but logs a warning in the PR body: "Runtime testing skipped (emergency override). Manual verification recommended before merge." The flag is intentionally verbose to discourage casual use.

#### Integration with Sibling Tasks

This gate is designed to work standalone (using conventional detection and agent judgment) and to improve as sibling tasks land:

| Task | What It Adds | Gate Behaviour Without It |
|------|-------------|--------------------------|
| t1660.1 `/testing-setup` | Interactive per-repo config | Agent uses conventional detection |
| t1660.2 `testing.json` | Structured project config | Agent detects test/dev commands from package.json etc. |
| t1660.3 `browser-qa stability` | Playwright quiescence detection | Agent uses `curl` smoke checks |
| t1660.4 `verify-brief.sh` runtime | Brief-driven runtime verification | Agent runs tests directly |
| t1660.5 `--testing-level` flag | Proof-log recording | Agent documents level in PR body only |
| t1660.6 PR template section | Structured PR testing section | Agent writes free-form testing section |

### Key Rules

- **Parallelism (t217):** Use Task tool for concurrent independent operations (reading files, lint+typecheck+tests). Serial execution of independent work wastes wall-clock time.
- **Replanning:** If approach isn't working, try a fundamentally different strategy before giving up.
- **CI failure debugging (t1334):** ALWAYS read CI logs first: `gh pr checks`, `gh run view --log | grep -iE 'FAIL|Error'`. Prevents context exhaustion from blind debugging.

### Quality-Debt Blast Radius Cap (t1422 — MANDATORY)

For quality-debt/simplification-debt/batch-fix tasks: PR must touch **at most 5 files**. Large batch PRs conflict with every other PR in flight.

```bash
CHANGED_FILES=$(git diff --name-only origin/main | wc -l | tr -d ' ')
[[ "$CHANGED_FILES" -gt 5 ]] && echo "[t1422] WARNING: $CHANGED_FILES files — split into multiple PRs"
```

File follow-up issues for remaining files. Does NOT apply to feature PRs or bug fixes.

### Headless Dispatch Rules (t158/t174 — MANDATORY for supervisor workers)

1. **Never prompt for input** — use uncertainty framework (rule 7) to proceed or exit
2. **Do NOT edit TODO.md** — notes go in commit messages or PR body
3. **Do NOT edit shared planning files** (`todo/PLANS.md`, `todo/tasks/*`)
4. **Auth failures** — retry 3x then exit cleanly
5. **Unrecoverable errors** — emit clear error, exit (don't loop forever)
6. **`git pull --rebase` before push** (t174)
7. **Uncertainty framework (t176):**
   - **PROCEED** (document in commit): multiple valid approaches (pick simplest), style ambiguity (follow conventions), clear intent from context, equivalent patterns (match precedent), minor scope questions (stay focused)
   - **EXIT** (explain in output): contradicts codebase, requires breaking public API changes, task already done/obsolete, missing dependencies/credentials, requires architectural decisions affecting other tasks, ambiguous create-vs-modify risking data loss
8. **Time budget (MANDATORY):**
   - **45 min:** Self-check. If stuck on dependency → commit partial, exit `BLOCKED: dependency not available`
   - **90 min:** If working code exists → `gh pr create --draft`, file subtask issues, exit
   - **120 min (hard limit):** Stop. PR whatever you have or exit with detailed `BLOCKED:` message
   - **Dependency detection at START:** Verify prerequisites exist (`rg 'tableName|functionName'`). Check `blocked-by:` PRs: `gh pr list --state merged --search "tXXX"`. Missing → exit immediately.
   - **Push/PR failure (#2452):** On failure → log error → retry after `git pull --rebase` → if retry fails → exit `BLOCKED: push/PR creation failed`. Do NOT continue implementing after push failure.
9. **Cross-repo routing:** If fix belongs in different repo → `gh issue create --repo <correct-repo>`. If creating TODOs in another repo → commit+push immediately. **Scope boundary (t1405, GH#2928):** In pulse mode, `PULSE_SCOPE_REPOS` restricts code changes. Filing issues always allowed; branches/PRs only on in-scope repos.
10. **Issue-task alignment (MANDATORY):** Before linking PR to issue, verify work matches issue description (`gh issue view`). Workers have hijacked issues by using task IDs for unrelated work (e.g., t1344). If work is unrelated → create new issue.

### README Gate (MANDATORY — t099)

Before `TASK_COMPLETE`:

1. New feature/tool/API/command/config? → **Update README.md**
2. Changed user-facing behavior? → **Update README.md**
3. Pure refactor/bugfix/internal? → **SKIP**

For aidevops repo: also run `~/.aidevops/agents/scripts/readme-helper.sh check`.

### Changelog

Auto-generated from conventional commits. Prefixes: `feat:` (Added), `fix:` (Fixed), `docs:`/`perf:`/`refactor:` (Changed), `chore:` (excluded). See `workflows/changelog.md`.

---

## Step 4: Automatic Phase Progression

After `TASK_COMPLETE` (commit+PR gate already passed):

### 4.1 Preflight

Runs quality checks, auto-fixes issues.

### 4.2 PR Create

Verifies `gh auth`, rebases onto `origin/main`, pushes, creates PR. If commit+PR gate already created the PR, confirms it exists and ensures proper issue linkage.

**Issue linkage (MANDATORY):** PR body MUST include `Closes #NNN` (or `Fixes`/`Resolves`). This is the ONLY mechanism creating a GitHub PR-issue link.

- **Primary:** Use `$ISSUE_NUM` from Step 0. Always include `Closes #$ISSUE_NUM`.
- **Secondary:** Search for additional related issues by task ID prefix only. Never add `Closes` based on keyword similarity alone.
- **Caution:** GitHub parses `Closes #NNN` anywhere in PR body — including prose. Use backtick-escaped references when describing bugs (PR #2512 closed wrong issue #2498 this way).

### 4.3 Label Update — `status:in-review`

**Issue-state guard (t1343 — MANDATORY):** Before ANY label/comment modification, check state is `OPEN`. Fail-closed: skip on `CLOSED`, `UNKNOWN`, or any non-`OPEN` state.

```bash
ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
[[ "$ISSUE_STATE" != "OPEN" ]] && echo "[t1343] Skipping #$ISSUE_NUM — $ISSUE_STATE" && continue
gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "status:in-review" --remove-label "status:in-progress" 2>/dev/null || true
```

**PR lookup fallback (t1343):** Don't rely solely on session state. Check: local state → `gh pr list --state merged --search "<task_id>"` → issue timeline cross-refs.

The `status:done` transition is handled by `sync-on-pr-merge` workflow — workers don't set it.

### 4.4 Review Bot Gate (t1382 — MANDATORY)

Three enforcement layers:

1. **CI:** `.github/workflows/review-bot-gate.yml` required status check
2. **Agent:** `~/.aidevops/agents/scripts/review-bot-gate-helper.sh check "$PR_NUMBER" "$REPO"` → `PASS`/`WAITING`/`SKIP`
3. **Branch protection:** `review-bot-gate` as required check

If `WAITING`: poll every 60s for up to 10 min. Most bots post in 2-5 min. After timeout: interactive → warn user; headless → proceed with warning (CI is hard gate). If `SKIP`: PR has `skip-review-gate` label. If `PASS`: read reviews, address critical/security findings.

Known bots: CodeRabbit (`coderabbitai`, 1-3 min), Gemini Code Assist (`gemini-code-assist[bot]`, 2-5 min), Augment Code (`augment-code[bot]`, 2-4 min), Copilot (`copilot[bot]`, 1-3 min).

### 4.5 Merge

`gh pr merge --squash` (without `--delete-branch` in worktrees).

### 4.6 Auto-Release (aidevops repo only — MANDATORY)

After merge on `marcusquinn/aidevops`, cut a patch release:

```bash
REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
if [[ "$REPO_SLUG" == "marcusquinn/aidevops" ]]; then
  CANONICAL_DIR="${REPO_ROOT%%.*}"
  git -C "$CANONICAL_DIR" pull origin main
  (cd "$CANONICAL_DIR" && "$HOME/.aidevops/agents/scripts/version-manager.sh" bump patch)
  NEW_VERSION=$(cat "$CANONICAL_DIR/VERSION")
  git -C "$CANONICAL_DIR" add -A
  git -C "$CANONICAL_DIR" commit -m "chore(release): bump version to v${NEW_VERSION}"
  git -C "$CANONICAL_DIR" push origin main
  git -C "$CANONICAL_DIR" tag "v${NEW_VERSION}" && git -C "$CANONICAL_DIR" push origin "v${NEW_VERSION}"
  gh release create "v${NEW_VERSION}" --repo "$REPO_SLUG" --title "v${NEW_VERSION} - AI DevOps Framework" --generate-notes
  "$CANONICAL_DIR/setup.sh" --non-interactive || true
fi
```

**Why patch?** Workers can't determine release significance — that requires human judgment. Patch is always safe.

### 4.7 Issue Closing Comment (MANDATORY)

After merge, post on every linked issue. The **Testing Evidence** section replaces free-text with structured fields so future workers can assess stability at a glance.

```markdown
## Completed via PR #<PR_NUMBER>

**What was done:** <bullet list>

**Testing Evidence:**
- **Testing level:** `runtime-verified` | `self-assessed` | `untested`
  - `runtime-verified` — dev server started, Playwright/curl smoke checks passed
  - `self-assessed` — manual review of diff, no runtime execution
  - `untested` — docs/config only, no executable code changed
- **Stability results:** <pass/fail counts, error messages, or "N/A — docs only">
- **Smoke pages/endpoints checked:** <URLs or commands verified, or "N/A">

**Key decisions:** <non-obvious choices and why>
**Files changed:** `path/to/file` — <what and why>
**Blockers encountered:** <issues hit and resolution, or "None">
**Follow-up needs:** <out-of-scope items, or "None">
**Released in:** v<VERSION> — run `aidevops update` to get this fix.
```

**Rules:**
- Every section needs ≥1 bullet ("None" / "N/A" if nothing to report)
- **Testing level is required** — never omit it. If you did not start a dev server or run any automated check, use `self-assessed`. If the change is docs/config only with no executable code, use `untested`.
- Be specific — "fixed the bug" is useless; "fixed race condition in worktree creation by adding `sleep 2` between dispatches" is useful
- Include file paths with brief descriptions so future workers can find the changes
- Include release version (aidevops repo only). For non-aidevops repos, omit the "Released in" line.
- This is a gate — no `FULL_LOOP_COMPLETE` until closing comments are posted

### 4.8 Worktree Cleanup

See [`worktree-cleanup.md`](worktree-cleanup.md). Key: never pass `--delete-branch` to `gh pr merge` from inside a worktree.

### 4.9 Postflight + Deploy

Verify release health. Deploy: `setup.sh --non-interactive` (aidevops repos only).

---

## Step 5: Human Decision Points

> In `--headless` mode (t174), the loop never pauses — proceeds autonomously, exits if blocked.

| Point | When | Action |
|-------|------|--------|
| Merge approval | Repo requires human approval | Approve PR in GitHub |
| Rollback | Postflight detects issues | Decide rollback |
| Scope change | Task evolves beyond original | Confirm new scope |

## Step 6: Completion

```text
<promise>FULL_LOOP_COMPLETE</promise>
```

---

## Commands

```bash
/full-loop "Implement feature X with tests"                    # Start
~/.aidevops/agents/scripts/full-loop-helper.sh status          # Check
~/.aidevops/agents/scripts/full-loop-helper.sh resume          # Resume
~/.aidevops/agents/scripts/full-loop-helper.sh cancel          # Cancel
```

## Options

```bash
/full-loop "Fix bug Y" --max-task-iterations 30 --skip-postflight
```

| Option | Description |
|--------|-------------|
| `--background`, `--bg` | Run in background (recommended) |
| `--headless` | Fully headless worker mode |
| `--max-task-iterations N` | Max task iterations (default: 50) |
| `--max-preflight-iterations N` | Max preflight iterations (default: 5) |
| `--max-pr-iterations N` | Max PR review iterations (default: 20) |
| `--skip-preflight` | Skip preflight checks |
| `--skip-postflight` | Skip postflight monitoring |
| `--no-auto-pr` | Pause for manual PR creation |
| `--no-auto-deploy` | Don't auto-run setup.sh |
| `--skip-runtime-testing` | Skip runtime testing gate (emergency hotfixes only) |

## Related

- `workflows/ralph-loop.md` — Ralph loop technique
- `workflows/preflight.md` — Pre-commit quality checks
- `workflows/pr.md` — PR creation workflow
- `workflows/postflight.md` — Post-release verification
- `workflows/changelog.md` — Changelog format
- `tools/ai-orchestration/openprose.md` — OpenProse DSL for multi-agent orchestration
