---
description: Start end-to-end development loop (task → preflight → PR → postflight → deploy)
agent: Build+
mode: subagent
---

Full development loop: task implementation → deployment. Task/Prompt: `$ARGUMENTS`

**Phases:** Claim → Branch → Task Dev → Preflight → PR → Review → Postflight → Deploy

## Lifecycle Gate (t5096 + GH#5317 — MANDATORY)

Fatal modes: (1) GH#5317 — exit without commit/PR, (2) t5096 — exit after PR without completing lifecycle.

Steps: 0. Commit+PR gate (`TASK_COMPLETE`) → 1. Review bot gate (poll ≤10 min) → 2. Address critical findings → 3. Merge (`gh pr merge --squash`, no `--delete-branch` in worktrees) → 4. Auto-release (aidevops only) → 5. Issue closing comment → 6. Worktree cleanup (`FULL_LOOP_COMPLETE`)

## Step 0: Resolve Task ID

Extract first arg. If ` -- ` present, use text after (supervisor dispatch t158). If `t\d+`, resolve via TODO.md or `gh issue list`.

**0.45 Decomposition (t1408.2):** `task-decompose-helper.sh classify`. Composite: interactive → show tree; headless → auto-decompose, exit `DECOMPOSED`.

**0.5 Claim (t1017):** Add `assignee: started:` to TODO.md. Push rejection = claimed → STOP.

**0.6 Label `status:in-progress`:** Verify issue `OPEN` (t1343), add assignee + label. Idempotent (t1687).

**0.7 Label `dispatched:{model}`:** Tag issue with model tier.

**1.7 Lineage (t1408.3):** If `TASK LINEAGE:` block, only implement `<-- THIS TASK`, stub siblings.

## Step 1: Branch Setup

`pre-edit-check.sh --loop-mode --task "$ARGUMENTS"` — Exit 0 = feature branch; Exit 2 = main, auto-create worktree.

**1.5 Operation Verification (t1364.3):** High-stakes ops → `verify-operation-helper.sh`. Critical/high → block or verify.

## Step 2: Start Loop

`full-loop-helper.sh start "$ARGUMENTS" --background` | `{status|logs|cancel}`

Headless mode (t174): `--headless` or `FULL_LOOP_HEADLESS=true`.

## Step 3: Task Development

Iterate until `<promise>TASK_COMPLETE</promise>`.

**Completion criteria:** All requirements `[DONE]`; tests/lint/shellcheck clean; generalization check; README gate (t099); conventional commits; actionable finding coverage; runtime testing gate (t1660.7); **Commit+PR gate (GH#5317)** — no uncommitted changes, PR exists.

**Runtime testing (t1660.7):** Critical/High (payment, auth, polling, WebSocket) → `runtime-verified` or BLOCK. Medium (UI, config, DB) → `runtime-verified` if dev env, else `self-assessed`. Low (docs, types) → `self-assessed`. `--skip-runtime-testing` for emergency only.

**Headless rules (t158/t174):** Never prompt; don't edit TODO.md; auth fail → retry 3x, exit; `git pull --rebase` before push; PROCEED for style ambiguity, EXIT for API breaks/missing deps; time budget 45→self-check, 90→draft PR, 120→stop; push fail (#2452) → rebase retry, then BLOCKED.

**Key rules:** Parallelism (t217) — Task tool for concurrent ops. CI debugging (t1334) — read logs first. Blast radius (t1422) — quality-debt PRs ≤5 files.

## Step 4: Phase Progression

After `TASK_COMPLETE`: **4.1** Preflight (quality checks) → **4.2** PR Create (rebase, push, `Closes #NNN` MANDATORY) → **4.3** Label `status:in-review` (check `OPEN` t1343) → **4.4** Review Bot Gate (t1382, poll 60s ≤10 min) → **4.5** Merge (`gh pr merge --squash`) → **4.6** Auto-Release (aidevops: `version-manager.sh bump patch`, tag, release) → **4.7** Issue Closing Comment (What done, Testing Evidence, Files changed, Follow-up) → **4.8** Worktree Cleanup (GH#6740: `worktree-helper.sh remove --force`, see `worktree-cleanup.md`) → **4.9** Postflight (verify health, deploy `setup.sh`).

## Step 5: Human Decision Points

Headless never pauses. Interactive: Merge approval (if required), Rollback (postflight issues), Scope change (task evolves).

## Step 6: Completion

`<promise>FULL_LOOP_COMPLETE</promise>`

## Commands & Options

```bash
/full-loop "Implement X"  # Start
full-loop-helper.sh {status|resume|cancel}
```

Options: `--background` `--headless` `--max-task-iterations N` `--skip-preflight` `--skip-postflight` `--skip-runtime-testing`

**Related:** `workflows/ralph-loop.md`, `workflows/preflight.md`, `workflows/pr.md`, `workflows/postflight.md`, `workflows/worktree-cleanup.md`
