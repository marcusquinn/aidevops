---
description: Start end-to-end development loop (task → preflight → PR → postflight → deploy)
agent: Build+
mode: subagent
---

Task/Prompt: $ARGUMENTS

## Lifecycle Gate (t5096 + GH#5317 — MANDATORY)

`Claim → Branch → Develop → Preflight → PR → Review → Merge → Release → Close → Cleanup`

Fatal modes: **GH#5317** (exits without PR), **GH#5096** (exits after PR). Do NOT skip any step:

| # | Step | Signal |
|---|------|--------|
| 0 | Commit+PR gate — all changes committed, PR exists | `TASK_COMPLETE` |
| 1 | Review bot gate — wait for bots (poll ≤10 min) | |
| 2 | Address critical bot review findings | |
| 3 | Merge — `gh pr merge --squash` (no `--delete-branch` in worktrees) | |
| 4 | Auto-release — bump patch + GitHub release (aidevops repo only) | |
| 5 | Issue closing comment — structured comment on every linked issue | |
| 6 | Worktree cleanup — return to main, pull, prune | `FULL_LOOP_COMPLETE` |

---

## Step 0: Resolve Task ID

Extract first positional arg from `$ARGUMENTS` (ignore flags). If `$ARGUMENTS` contains ` -- `, everything after is the task description (t158). Task ID (`t\d+`): resolve via inline ` -- `, TODO.md, or `gh issue list --search "$TASK_ID"`. Set session title: `"t061: Fix login bug"`. Otherwise use description directly.

Extract issue number: `ISSUE_NUM=$(echo "$ARGUMENTS" | sed -En 's/.*[Ii][Ss][Ss][Uu][Ee][[:space:]]*#*([0-9]+).*/\1/p' | head -1)`

### Step 0.45: Task Decomposition Check (t1408.2)

Skip if `--no-decompose` or already has subtasks. Run `task-decompose-helper.sh classify "$TASK_DESC" --depth 0` to get `kind`.

- **Composite — interactive:** Show tree, ask `[Y/n/edit]`. Create child IDs via `claim-task-id.sh`, add `blocked-by:` edges, label parent `status:blocked`.
- **Composite — headless:** Auto-decompose, exit: `DECOMPOSED: task $TASK_ID split into $SUBTASK_COUNT subtasks ($CHILD_IDS).`
- **Depth limit:** `DECOMPOSE_MAX_DEPTH` (default: 3). At depth 3+, treat as atomic.

**Step 0.5 — Claim (t1017):** Adds `assignee:<identity> started:<ISO>` to TODO.md via commit+push. Push rejection = claimed → **STOP**. Skip when not a task ID or `--no-claim`.

**Step 0.6 — Label `status:in-progress`** (lifecycle: `available` → `queued` → `in-progress` → `in-review` → `done`; stale 3+ hrs → pulse relabels `available`)**:** Find linked issue: (1) `$ISSUE_NUM`, (2) TODO.md `ref:GH#NNN`, (3) `gh issue list --search "${TASK_ID}:"`. Abort if issue is not `OPEN` (t1343/#2452). Assign worker, add `status:in-progress`, remove stale labels.

**Step 0.7 — Label dispatch model:** Detect from `$ANTHROPIC_MODEL`/`$CLAUDE_MODEL` or system prompt. Map: `*opus*`→`dispatched:opus`, `*sonnet*`→`dispatched:sonnet`, `*haiku*`→`dispatched:haiku`. Remove stale labels first.

**Step 1.7 — Lineage context (t1408.3):** If dispatch prompt contains `TASK LINEAGE:` block: (1) only implement `<-- THIS TASK`, (2) stub sibling dependencies, (3) no sibling work, (4) include lineage in PR body, (5) hard dependency not stub-able → exit `BLOCKED`.

---

## Step 1: Auto-Branch Setup

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "$ARGUMENTS"
```

Exit 0: already on feature branch. Exit 2: on main — auto-create worktree. Docs-only keywords (`readme`, `changelog`, `docs/`, `typo`) skip worktree; code keywords override.

**Step 1.5 — Operation verification (t1364.3):** Source `verify-operation-helper.sh`, call `check_operation`/`verify_operation`. Critical/high → block or verify. Moderate → log. Low → skip. Config: `VERIFY_ENABLED`, `VERIFY_POLICY`, `VERIFY_TIMEOUT` (30s), `VERIFY_MODEL` (haiku).

Start the loop: `~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS" --background`

`--headless` / `FULL_LOOP_HEADLESS=true`: suppresses prompts, prevents TODO.md edits.

---

## Step 3: Task Development (Ralph Loop)

Iterate until emitting `<promise>TASK_COMPLETE</promise>`.

### Completion Criteria (ALL required)

1. Requirements implemented (list each `[DONE]`); tests pass; lint/shellcheck/type-check clean; works for varying inputs
2. **README gate (t099)** — update if user-facing features change; skip for refactor/bugfix. aidevops: also `readme-helper.sh check`
3. Conventional commits; headless rules observed; every deferred finding has tracked task+issue
4. **Runtime testing gate (t1660.7)** — risk-appropriate verification (see below)
5. **Commit+PR gate (GH#5317 — MANDATORY):** Commit all changes, push branch, ensure PR exists. **Do NOT emit `TASK_COMPLETE` with uncommitted changes or no PR.**

**Actionable findings:** `findings-to-tasks-helper.sh create --input <findings.txt> --repo-path "$(git rev-parse --show-toplevel)" --source <type>`. PR body: `actionable_findings_total=N`, `fixed_in_pr=N`, `deferred_tasks_created=N`, `coverage=100%`.

### Runtime Testing Gate (t1660.7 — MANDATORY)

| Risk | Patterns | Required |
|------|----------|----------|
| **Critical** | Payment/billing, auth/session, data deletion, crypto, credentials | `runtime-verified` |
| **High** | Polling loops, WebSocket/SSE, state machines, form handlers, API endpoints | `runtime-verified` |
| **Medium** | UI components, CSS, routes, config, env vars, DB queries | `runtime-verified` if dev env available; `self-assessed` otherwise |
| **Low** | Docs, comments, types-only, test files, linter/CI config, agent prompts | `self-assessed` |

Detection is intelligence, not regex. ANY critical pattern → entire PR requires `runtime-verified`. Levels: `self-assessed` (review only), `unit-tested` (suite passes), `runtime-verified` (app started). Use `.aidevops/testing.json` if present; otherwise detect from `package.json`/`pytest.ini`/`Cargo.toml`/`go.mod`.

| Situation | Action |
|-----------|--------|
| Critical/high + no runtime verification | **BLOCK** — exit `BLOCKED: runtime testing required but dev environment unavailable` |
| Medium + no dev env | **WARN** — proceed `self-assessed`, document in PR body |
| Low + self-assessed | **PASS** |
| `testing.json` specifies `required_level` | **ENFORCE** — overrides defaults |

`--skip-runtime-testing`: emergency hotfixes only. Logs warning in PR body. Record in PR body: `## Runtime Testing` — level, risk, dev environment, smoke check results.

**Key rules:** Parallelism (t217) — use Task tool for concurrent ops. Replanning — try a different strategy before giving up. CI (t1334) — `gh pr checks`, `gh run view --log | grep -iE 'FAIL|Error'`. Blast radius (t1422) — quality-debt PRs ≤5 files; file follow-up issues for rest (not for feature/bugfix).

### Headless Dispatch Rules (t158/t174 — MANDATORY)

1. **Never prompt** — use uncertainty framework to proceed or exit
2. **Do NOT edit** TODO.md or shared planning files
3. **Auth failures** — retry 3x then exit. Unrecoverable → emit error, exit
4. **`git pull --rebase` before push**
5. **Uncertainty (t176):** PROCEED for style ambiguity, multiple valid approaches, clear intent. EXIT for contradicts codebase, breaks public API, task obsolete, missing deps/credentials, architectural decisions.
6. **Time budget:** 45 min → self-check. 90 min → `gh pr create --draft`, exit. 120 min → stop.
7. Verify prerequisites at START. Missing → exit. Push/PR failure → retry after rebase → exit `BLOCKED`.
8. `PULSE_SCOPE_REPOS` restricts code changes; issues always allowed (t1405). Mismatch between work and issue → new issue (t1344).

Changelog: `feat:` → Added, `fix:` → Fixed, `docs:`/`perf:`/`refactor:` → Changed, `chore:` → excluded. See `workflows/changelog.md`.

---

## Step 4: PR, Review & Merge

**4.1 Preflight:** Quality checks, auto-fixes. See `workflows/preflight.md`.

**4.2 PR Create:** Verify `gh auth`, rebase onto `origin/main`, push, create PR. **PR body MUST include `Closes #NNN`** (only mechanism creating a GitHub PR-issue link). Backtick-escape issue refs in bug descriptions to avoid unintended closes. **Append signature footer** to the PR body: run `SIG_FOOTER=$(~/.aidevops/agents/scripts/gh-signature-helper.sh footer --model "$ANTHROPIC_MODEL")` and append `${SIG_FOOTER}` as the last content in the `--body`.

### 4.3 Label Update — `status:in-review` (t1343 — MANDATORY)

Fail-closed — skip on non-`OPEN` state. `status:done` is set by `sync-on-pr-merge` — workers don't set it.

```bash
ISSUE_STATE=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
[[ "$ISSUE_STATE" != "OPEN" ]] && echo "[t1343] Skipping #$ISSUE_NUM — $ISSUE_STATE" && continue
gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "status:in-review" --remove-label "status:in-progress" 2>/dev/null || true
```

**4.4 Review Bot Gate (t1382 — MANDATORY):** `review-bot-gate-helper.sh check "$PR_NUMBER" "$REPO"` → `PASS`/`WAITING`/`SKIP`. Poll every 60s up to 10 min. Timeout: interactive → warn; headless → proceed.

**4.5 Merge:** `gh pr merge --squash` (without `--delete-branch` in worktrees).

### 4.6 Auto-Release (aidevops repo only — MANDATORY)

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

**4.7 Issue Closing Comment (MANDATORY):** Post structured comment on every linked issue: **What was done**, **Testing Evidence** (level: `runtime-verified`/`self-assessed`/`untested`, smoke checks), **Key decisions**, **Files changed** (path — what/why), **Blockers**, **Follow-up needs**, **Released in** (aidevops only). Every section ≥1 bullet ("None"/"N/A" if empty). Append a signature footer (see `build.txt` "GitHub comment signature footer" — use `gh-signature-helper.sh footer --model <model>`). Gate — no `FULL_LOOP_COMPLETE` until posted.

### 4.8 Worktree Cleanup (GH#6740 — MANDATORY)

```bash
WORKTREE_PATH="$(pwd)"
BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CANONICAL_DIR="${REPO_ROOT%%.*}"

cd "$CANONICAL_DIR" || cd "$HOME"
git pull origin main 2>/dev/null || true

HELPER="$HOME/.aidevops/agents/scripts/worktree-helper.sh"
if [[ -x "$HELPER" ]]; then
  WORKTREE_FORCE_REMOVE=true "$HELPER" remove "$BRANCH_NAME" --force 2>/dev/null || true
else
  git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
fi

git push origin --delete "$BRANCH_NAME" 2>/dev/null || true
git branch -D "$BRANCH_NAME" 2>/dev/null || true
```

Never `--delete-branch` from inside a worktree. Always `cd` out first. Failures are non-fatal. See [`worktree-cleanup.md`](worktree-cleanup.md).

**4.9 Postflight + Deploy:** Verify release health. Deploy: `setup.sh --non-interactive` (aidevops repos only). Emit: `<promise>FULL_LOOP_COMPLETE</promise>`

---

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

`workflows/ralph-loop.md` · `workflows/preflight.md` · `workflows/pr.md` · `workflows/postflight.md` · `workflows/changelog.md` · `tools/ai-orchestration/openprose.md`
