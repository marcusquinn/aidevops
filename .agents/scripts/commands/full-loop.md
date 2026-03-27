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

Two fatal modes: (1) **GH#5317** — worker exits without committing/creating PR, (2) **GH#5096** — worker exits after PR without completing lifecycle. **Do NOT skip any step:**

| # | Step | Signal |
|---|------|--------|
| 0 | Commit+PR gate — all changes committed, PR exists | `TASK_COMPLETE` |
| 1 | Review bot gate — wait for bots (poll ≤10 min) | |
| 2 | Address critical findings from bot reviews | |
| 3 | Merge — `gh pr merge --squash` (no `--delete-branch` in worktrees) | |
| 4 | Auto-release — bump patch + GitHub release (aidevops repo only) | |
| 5 | Issue closing comment — structured comment on every linked issue | |
| 6 | Worktree cleanup — return to main, pull, prune | `FULL_LOOP_COMPLETE` |

Applies regardless of dispatch method (pulse, `/runners`, interactive).

---

## Step 0: Resolve Task ID and Set Session Title

Extract first positional argument from `$ARGUMENTS` (ignoring flags like `--max-task-iterations`).

**Supervisor dispatch (t158):** If `$ARGUMENTS` contains ` -- `, everything after is the task description — use directly instead of TODO.md lookup.

**If first arg matches `t\d+`:** Resolve description: (1) inline after ` -- `, (2) grep TODO.md, (3) `gh issue list --search "$TASK_ID"`. Set session title: `"t061: Fix login bug"`.

**If NOT a task ID:** Use description directly. Extract issue number if present (#2452 fix):

```bash
ISSUE_NUM=$(echo "$ARGUMENTS" | sed -En 's/.*[Ii][Ss][Ss][Uu][Ee][[:space:]]*#*([0-9]+).*/\1/p' | head -1)
```

### Step 0.45: Task Decomposition Check (t1408.2)

Before claiming, classify whether the task should be decomposed. **Skip if:** `--no-decompose` flag or task already has subtasks.

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

- **Atomic (default):** Proceed to Step 0.5.
- **Composite — interactive:** Show tree, ask `[Y/n/edit]`. Create child IDs via `claim-task-id.sh`, add `blocked-by:` edges, label parent `status:blocked`.
- **Composite — headless:** Auto-decompose, exit: `DECOMPOSED: task $TASK_ID split into $SUBTASK_COUNT subtasks ($CHILD_IDS).`
- **Depth limit:** `DECOMPOSE_MAX_DEPTH` (default: 3). At depth 3+, treat as atomic.

### Step 0.5: Claim Task (t1017)

Adds `assignee:<identity> started:<ISO>` to TODO.md via commit+push. Push rejection = someone else claimed first → **STOP**. Skip when not a task ID or `--no-claim`.

### Step 0.6: Update Issue Label — `status:in-progress`

Find linked issue: (1) `$ISSUE_NUM` from Step 0, (2) TODO.md `ref:GH#NNN`, (3) `gh issue list --search "${TASK_ID}:"`.

```bash
if [[ -n "$ISSUE_NUM" && "$ISSUE_NUM" != "null" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
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

**Label lifecycle:** `available` → `queued` → `in-progress` → `in-review` → `done`. Always remove prior labels. Stale recovery: 3+ hours with no PR → pulse relabels `status:available`.

**Idempotent with claim-on-create (t1687):** If `/new-task` already assigned the user and set `status:in-progress` (option 2 — "claim for this session"), this step is a no-op. The `gh issue edit` calls are idempotent — adding an already-present assignee or label succeeds silently. The race window is closed when claim-on-create succeeds — if the `/new-task` claim failed silently (e.g. no network), this step re-applies it before the pulse can dispatch.

### Step 0.7: Label Dispatch Model — `dispatched:{model}`

Tag issue with model. Detect from `$ANTHROPIC_MODEL`/`$CLAUDE_MODEL` or system prompt. Map: `*opus*`→`dispatched:opus`, `*sonnet*`→`dispatched:sonnet`, `*haiku*`→`dispatched:haiku`. Remove stale labels first.

### Step 1.7: Parse Lineage Context (t1408.3)

If dispatch prompt contains `TASK LINEAGE:` block (from pulse for subtasks): (1) only implement `<-- THIS TASK`, (2) stub sibling dependencies, (3) no sibling work, (4) include lineage in PR body, (5) hard dependency not stub-able → exit `BLOCKED`.

---

## Step 1: Auto-Branch Setup

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "$ARGUMENTS"
```

- Exit 0: Already on feature branch — proceed
- Exit 2: On main — auto-create worktree

**Detection:** Docs-only keywords (`readme`, `changelog`, `docs/`, `typo`). Code keywords override (`feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`).

### Step 1.5: Operation Verification (t1364.3)

Before high-stakes operations, invoke cross-provider verification:

```bash
source ~/.aidevops/agents/scripts/verify-operation-helper.sh
risk=$(check_operation "terraform destroy")
result=$(verify_operation "terraform destroy" "$risk")
```

Critical/high risk → block or verify. Moderate → log. Low → no verification. Config: `VERIFY_ENABLED`, `VERIFY_POLICY`, `VERIFY_TIMEOUT` (30s), `VERIFY_MODEL` (haiku).

---

## Step 2: Start Full Loop

**Headless mode (t174):** `--headless` or `FULL_LOOP_HEADLESS=true`. Suppresses interactive prompts, prevents TODO.md edits, ensures clean exit on errors.

```bash
# Background (recommended — avoids MCP timeout)
~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS" --background

# Monitor: status | logs | cancel
~/.aidevops/agents/scripts/full-loop-helper.sh {status|logs|cancel}
```

---

## Step 3: Task Development (Ralph Loop)

Iterate until emitting `<promise>TASK_COMPLETE</promise>`.

### Completion Criteria (ALL required)

1. All requirements implemented (list each `[DONE]`)
2. Tests passing, code quality acceptable (lint, shellcheck, type-check)
3. **Generalization check** — works for varying inputs
4. **README gate (t099)** — update if user-facing features change; skip for refactor/bugfix. aidevops repo: also run `readme-helper.sh check`
5. Conventional commits, headless rules observed
6. **Actionable finding coverage** — every deferred finding has tracked task+issue
7. **Runtime testing gate (t1660.7)** — risk-appropriate verification (see below)
8. **Commit+PR gate (GH#5317 — MANDATORY):**

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

For multi-finding reports: `findings-to-tasks-helper.sh create --input <findings.txt> --repo-path "$(git rev-parse --show-toplevel)" --source <type>`. Include in PR body: `actionable_findings_total=N`, `fixed_in_pr=N`, `deferred_tasks_created=N`, `coverage=100%`.

### Runtime Testing Gate (t1660.7 — MANDATORY)

Classify diff risk and perform appropriate runtime verification before `TASK_COMPLETE`.

**Risk taxonomy:**

| Risk | Patterns | Required |
|------|----------|----------|
| **Critical** | Payment/billing, auth/session, data deletion, crypto, credentials | `runtime-verified` |
| **High** | Polling loops, page reloads, WebSocket/SSE, state machines, form handlers, API endpoints | `runtime-verified` |
| **Medium** | UI components, CSS, routes, config, env vars, DB queries | `runtime-verified` if dev env available; `self-assessed` otherwise |
| **Low** | Docs, comments, types-only, test files, linter/CI config, agent prompts | `self-assessed` |

**Detection is intelligence, not regex.** Read the diff holistically. Escalation is one-way: ANY critical pattern → entire PR requires `runtime-verified`.

**Testing levels:** `self-assessed` (code review only), `unit-tested` (test suite passes), `runtime-verified` (app started, behaviour confirmed). Use `.aidevops/testing.json` if present (from `/testing-setup`), otherwise detect from `package.json`/`pytest.ini`/`Cargo.toml`/`go.mod`.

**Gate enforcement:**

| Situation | Action |
|-----------|--------|
| Critical/high + no runtime verification | **BLOCK** — verify or exit `BLOCKED: runtime testing required but dev environment unavailable` |
| Medium + no dev env | **WARN** — proceed with `self-assessed`, document gap in PR body |
| Low + self-assessed | **PASS** |
| `testing.json` specifies `required_level` | **ENFORCE** — project config overrides defaults |

**`--skip-runtime-testing` flag:** Emergency hotfixes only. Logs warning in PR body.

**Record in PR body:** `## Runtime Testing` section with: testing level, risk classification, dev environment, smoke check results, behaviour verified.

### Key Rules

- **Parallelism (t217):** Use Task tool for concurrent independent operations.
- **Replanning:** Try a fundamentally different strategy before giving up.
- **CI debugging (t1334):** ALWAYS read CI logs first: `gh pr checks`, `gh run view --log | grep -iE 'FAIL|Error'`.
- **Blast radius cap (t1422):** Quality-debt/simplification PRs touch **at most 5 files**. File follow-up issues for rest. Does NOT apply to feature/bugfix PRs.

### Headless Dispatch Rules (t158/t174 — MANDATORY)

1. **Never prompt** — use uncertainty framework to proceed or exit
2. **Do NOT edit** TODO.md or shared planning files
3. **Auth failures** — retry 3x then exit. **Unrecoverable** — emit error, exit
4. **`git pull --rebase` before push** (t174)
5. **Uncertainty (t176):** PROCEED (document in commit) for style ambiguity, multiple valid approaches, clear intent. EXIT (explain in output) for contradicts codebase, breaks public API, task obsolete, missing deps/credentials, architectural decisions.
6. **Time budget:** 45 min → self-check. 90 min → `gh pr create --draft`, exit. 120 min (hard limit) → stop.
7. **Dependency detection at START:** Verify prerequisites. Missing → exit immediately.
8. **Push/PR failure (#2452):** Retry after rebase. Retry fails → exit `BLOCKED`.
9. **Cross-repo (t1405, GH#2928):** `PULSE_SCOPE_REPOS` restricts code changes; issues always allowed.
10. **Issue-task alignment:** Verify work matches issue before linking PR (t1344). Mismatch → new issue.

### Changelog

Auto-generated from conventional commits. Prefixes: `feat:` (Added), `fix:` (Fixed), `docs:`/`perf:`/`refactor:` (Changed), `chore:` (excluded). See `workflows/changelog.md`.

---

## Step 4: Automatic Phase Progression

After `TASK_COMPLETE` (commit+PR gate already passed):

### 4.1 Preflight

Runs quality checks, auto-fixes issues.

### 4.2 PR Create

Verifies `gh auth`, rebases onto `origin/main`, pushes, creates PR.

**Issue linkage (MANDATORY):** PR body MUST include `Closes #NNN` — the ONLY mechanism creating a GitHub PR-issue link. **Caution:** GitHub parses this anywhere in body — backtick-escape when describing bugs (PR #2512 closed wrong issue #2498).

### 4.3 Label Update — `status:in-review`

**Issue-state guard (t1343 — MANDATORY):** Check state is `OPEN` before any label/comment modification. Fail-closed: skip on non-`OPEN` state.

```bash
ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
[[ "$ISSUE_STATE" != "OPEN" ]] && echo "[t1343] Skipping #$ISSUE_NUM — $ISSUE_STATE" && continue
gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "status:in-review" --remove-label "status:in-progress" 2>/dev/null || true
```

The `status:done` transition is handled by `sync-on-pr-merge` workflow — workers don't set it.

### 4.4 Review Bot Gate (t1382 — MANDATORY)

`review-bot-gate-helper.sh check "$PR_NUMBER" "$REPO"` → `PASS`/`WAITING`/`SKIP`. If `WAITING`: poll every 60s up to 10 min. After timeout: interactive → warn; headless → proceed (CI is hard gate).

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

### 4.7 Issue Closing Comment (MANDATORY)

After merge, post structured comment on every linked issue with: **What was done** (bullets), **Testing Evidence** (level: `runtime-verified`/`self-assessed`/`untested`, stability results, smoke checks), **Key decisions**, **Files changed** (`path` — what/why), **Blockers**, **Follow-up needs**, **Released in** (aidevops only).

Every section needs ≥1 bullet ("None"/"N/A" if nothing). Testing level required — never omit. Gate — no `FULL_LOOP_COMPLETE` until posted.

### 4.8 Worktree Cleanup (GH#6740 — MANDATORY)

Workers MUST clean up their worktree after successful merge. Without this, worktrees accumulate indefinitely during batch dispatch and eventually block new workers from creating worktrees.

```bash
# After merge (Step 4.5) succeeds:
WORKTREE_PATH="$(pwd)"
BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CANONICAL_DIR="${REPO_ROOT%%.*}"  # ~/Git/repo from ~/Git/repo.branch-name

# 1. Return to canonical repo directory (on main)
cd "$CANONICAL_DIR" || cd "$HOME"

# 2. Pull merged changes
git pull origin main 2>/dev/null || true

# 3. Remove the worktree
HELPER="$HOME/.aidevops/agents/scripts/worktree-helper.sh"
if [[ -x "$HELPER" ]]; then
  WORKTREE_FORCE_REMOVE=true "$HELPER" remove "$BRANCH_NAME" --force 2>/dev/null || true
else
  git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
fi

# 4. Delete the remote branch (GitHub may auto-delete, but be explicit)
git push origin --delete "$BRANCH_NAME" 2>/dev/null || true
git branch -D "$BRANCH_NAME" 2>/dev/null || true
```

**Key rules:**
- Never pass `--delete-branch` to `gh pr merge` from inside a worktree — it fails because the branch is checked out
- Always `cd` out of the worktree before removing it
- Use `--force` because the worktree is clean (all changes merged)
- Failures are non-fatal (`|| true`) — the PR is already merged, cleanup is best-effort

See [`worktree-cleanup.md`](worktree-cleanup.md) for the full procedure.

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
