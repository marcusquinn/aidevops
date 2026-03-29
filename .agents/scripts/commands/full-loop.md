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
| 6 | Postflight + deploy — verify release health, run setup.sh | `FULL_LOOP_COMPLETE` |
| 7 | Worktree cleanup — return to main, pull, prune | |

---

## Step 0: Resolve Task ID

Extract first positional arg. If ` -- ` present, use text after (t158). Task ID (`t\d+`): resolve via TODO.md or `gh issue list --search`. Extract issue number via `sed -En 's/.*[Ii]ssue[[:space:]]*#*([0-9]+).*/\1/p'`.

**Decomposition (t1408.2):** Skip if `--no-decompose` or has subtasks. `task-decompose-helper.sh classify "$TASK_DESC"`. Composite interactive → show tree, ask `[Y/n/edit]`, create child IDs via `claim-task-id.sh`. Composite headless → auto-decompose, exit `DECOMPOSED: ...`. Max depth 3.

**Claim (t1017):** Add `assignee:<identity> started:<ISO>` to TODO.md. Push rejection = claimed → **STOP**.

**Issue labels (t1343/#2452):** Find via `$ISSUE_NUM`, `ref:GH#NNN`, or `gh issue list --search`. Guard: state must be `OPEN`. Set `status:in-progress`, remove stale labels. Lifecycle: `available` → `queued` → `in-progress` → `in-review` → `done`. Idempotent (t1687).

**Step 0.7 — Dispatch model:** `dispatched:{opus|sonnet|haiku}` from `$ANTHROPIC_MODEL`. **Step 0.8 — Session origin:** `origin:worker` or `origin:interactive` via `shared-constants.sh`. **Step 1.7 — Lineage (t1408.3):** If `TASK LINEAGE:` block: implement only `<-- THIS TASK`, stub siblings, include in PR body.

---

## Step 1: Auto-Branch Setup

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "$ARGUMENTS"
```

Exit 0: on feature branch. Exit 2: on main — auto-create worktree.

**Operation Verification (t1364.3):** `verify-operation-helper.sh check/verify`. Critical/high → block or verify.

Start: `~/.aidevops/agents/scripts/full-loop-helper.sh start "$ARGUMENTS" --background`. `--headless` / `FULL_LOOP_HEADLESS=true`: no prompts, no TODO.md edits.

---

## Step 3: Task Development (Ralph Loop)

Iterate until emitting `<promise>TASK_COMPLETE</promise>`.

**Completion criteria (ALL required):**
1. Requirements implemented (list each `[DONE]`); tests pass; lint/shellcheck/type-check clean; works for varying inputs
2. **README gate (t099)** — update if user-facing features change; skip for refactor/bugfix
3. Conventional commits; headless rules observed; every deferred finding has tracked task+issue (`findings-to-tasks-helper.sh create`)
4. **Runtime testing gate (t1660.7)** — risk-appropriate verification (see below)
5. **Commit+PR gate (GH#5317 — MANDATORY):** Commit all changes, push, ensure PR exists. Do NOT emit `TASK_COMPLETE` with uncommitted changes or no PR.
6. **Signature footer gate (GH#12805 — MANDATORY):** PR body and issue closing comment MUST contain the `aidevops.sh` signature footer. Verify: `echo "$PR_BODY" | grep -q 'aidevops.sh'`. Missing signature = incomplete PR.

### Runtime Testing Gate (t1660.7 — MANDATORY)

| Risk | Patterns | Required |
|------|----------|----------|
| **Critical** | Payment/billing, auth/session, data deletion, crypto, credentials | `runtime-verified` |
| **High** | Polling loops, WebSocket/SSE, state machines, form handlers, API endpoints | `runtime-verified` |
| **Medium** | UI components, CSS, routes, config, env vars, DB queries | `runtime-verified` if dev env available; `self-assessed` otherwise |
| **Low** | Docs, comments, types-only, test files, linter/CI config, agent prompts | `self-assessed` |

Detection is intelligence, not regex. ANY critical pattern → entire PR requires `runtime-verified`. Critical/high + no runtime → **BLOCK**. Use `.aidevops/testing.json` if present. Record `## Runtime Testing` in PR body. `--skip-runtime-testing`: emergency hotfixes only.

**Key rules:** Parallelism (t217) — use Task tool. CI (t1334) — `gh pr checks`, `gh run view --log`. Blast radius (t1422) — quality-debt PRs ≤5 files.

### Headless Dispatch Rules (t158/t174 — MANDATORY)

1. **Never prompt** — use uncertainty framework to proceed or exit
2. **Do NOT edit** TODO.md or shared planning files
3. **Auth failures** — retry 3x then exit
4. **`git pull --rebase` before push**
5. **Uncertainty (t176):** PROCEED for style/approach ambiguity. EXIT for API breaks, obsolete task, missing deps/credentials, architectural decisions.
6. **Time budget:** 45 min → self-check. 90 min → draft PR, exit. 120 min → stop.
7. Verify prerequisites at START. Missing → exit. Push/PR failure (#2452) → retry after rebase → exit `BLOCKED`.
8. `PULSE_SCOPE_REPOS` restricts code; issues always allowed (t1405). Mismatch → new issue (t1344).

Changelog: `feat:` → Added, `fix:` → Fixed, `docs:`/`perf:`/`refactor:` → Changed, `chore:` → excluded. See `workflows/changelog.md`.

---

## Step 4: PR, Review & Merge

**4.1 Preflight** — quality checks, auto-fixes.

**4.2 PR Create** — rebase onto `origin/main`, push, create PR. Body MUST include `Closes #NNN` (MANDATORY). Add `origin:worker` or `origin:interactive` label. **Signature footer (GH#12805 — MANDATORY):** `SIG_FOOTER=$(gh-signature-helper.sh footer --model "$ANTHROPIC_MODEL")` — append to body, verify with `gh pr view --json body -q .body | grep -q 'aidevops.sh'`; edit to add if missing.

**4.3 Label `status:in-review` (t1343)** — check issue is `OPEN` first. `status:done` set by `sync-on-pr-merge` — workers don't set it.

**4.4 Review Bot Gate (t1382)** — `review-bot-gate-helper.sh check "$PR_NUMBER" "$REPO"`. Poll 60s up to 10 min.

**4.5 Merge** — `gh pr merge --squash` (no `--delete-branch` from inside worktree).

**4.6 Auto-Release (aidevops only)** — `version-manager.sh bump patch`, tag, push, `gh release create`, `setup.sh --non-interactive`.

**4.7 Closing Comments (MANDATORY)** — post the same structured closing comment on **both** the issue AND the PR: What done, Testing Evidence (level required), Key decisions, Files changed, Blockers, Follow-up, Released in. Every section ≥1 bullet. The PR comment cross-references the issue ("Closes #NNN") and the issue comment cross-references the PR ("PR #NNN"). Gate — no `FULL_LOOP_COMPLETE` until both are posted.

**4.8 Postflight + Deploy** — verify release health; `setup.sh --non-interactive`. Emit: `<promise>FULL_LOOP_COMPLETE</promise>`

**4.9 Worktree Cleanup (GH#6740 — MANDATORY)** — `cd` canonical dir, pull, `worktree-helper.sh remove "$BRANCH_NAME" --force`, delete remote branch. See `worktree-cleanup.md`.

---

## Options

| Option | Description |
|--------|-------------|
| `--background`, `--bg` | Run in background (recommended) |
| `--headless` | Fully headless worker mode |
| `--dry-run` | Simulate without making changes |
| `--max-task-iterations N` | Max task iterations (default: 50) |
| `--max-preflight-iterations N` | Max preflight iterations (default: 5) |
| `--max-pr-iterations N` | Max PR review iterations (default: 20) |
| `--skip-preflight` | Skip preflight checks |
| `--skip-postflight` | Skip postflight monitoring |
| `--no-auto-pr` | Pause for manual PR creation |
| `--no-auto-deploy` | Don't auto-run setup.sh |
| `--skip-runtime-testing` | Skip runtime testing gate (emergency hotfixes only) |

`full-loop-helper.sh {status|resume|logs [N]|cancel|help}`

## Related

`workflows/ralph-loop.md` · `workflows/preflight.md` · `workflows/pr.md` · `workflows/postflight.md` · `workflows/changelog.md` · `worktree-cleanup.md`
