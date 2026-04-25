# Auto-Dispatch Reference

Detail for auto-dispatch mechanics, origin label rules, and dispatch dedup. For the essential rules, see `AGENTS.md` "Auto-Dispatch and Completion".

## Origin Label Mutual Exclusion (t2200)

`origin:interactive`, `origin:worker`, and `origin:worker-takeover` are mutually exclusive — an issue/PR has exactly one origin at any time.

**To change an existing issue's origin label:** use `set_origin_label <num> <slug> <kind>` from `shared-constants.sh` — it atomically adds the target and removes the siblings in a single `gh issue edit` call (mirrors the `set_issue_status` pattern for status labels).

For edit sites that fold origin changes into another `gh issue edit` call (e.g., `set_issue_status` extra flags), include explicit `--remove-label` for both sibling origins alongside the `--add-label`.

New issue/PR creation via `gh_create_issue`/`gh_create_pr` is safe — no siblings exist yet.

The `ORIGIN_LABELS` constant in `shared-constants.sh` is the canonical list.

- Regression test: `.agents/scripts/tests/test-origin-label-exclusion.sh`
- One-shot reconciliation: `.agents/scripts/reconcile-origin-labels.sh`

## `#auto-dispatch` Skips `origin:interactive` Self-Assignment (t2157, t2406, t2218)

When any of the three issue-creation paths creates an issue tagged `#auto-dispatch`, the pusher is NOT self-assigned even when the session origin is `interactive`.

**Why:** Self-assignment would create the `(origin:interactive + assigned + active status)` combo that GH#18352/t1996 treats as a permanent dispatch block, stranding the issue until manual `gh issue edit --remove-assignee` or the 24h `STAMPLESS_INTERACTIVE_AGE_THRESHOLD` safety net (t2148).

The three paths where the skip fires:
- `issue-sync-helper.sh` (TODO-first push)
- `gh_create_issue` (direct wrapper)
- `claim-task-id.sh` (agent-claimed follow-up)

An `[INFO]` log line is emitted when the skip fires: `Skipping auto-assign for #N — auto-dispatch entry is worker-owned`.

For issues already created before this carve-out, `interactive-session-helper.sh post-merge <PR>` (t2225) automates the heal across every issue referenced in a just-merged PR.

Regression tests:
- `.agents/scripts/tests/test-auto-dispatch-no-assign.sh` (issue-sync path)
- `.agents/scripts/tests/test-gh-create-issue-auto-dispatch-skip.sh` (gh_create_issue path)
- `.agents/scripts/tests/test-claim-task-id-autodispatch.sh` (claim-task-id path)

## General Dedup Rule — Combined Signal (t1996)

The dispatch dedup signal is `(active status label) AND (non-self assignee)` — both required, neither sufficient alone. Every code path that emits a dispatch claim must consult `dispatch-dedup-helper.sh is-assigned` before assigning a worker. Label-only or assignee-only filters are not safe in multi-operator conditions.

Four cases:

| State | Result |
|-------|--------|
| Status label without assignee | Degraded state (worker died mid-claim) — safe to reclaim after `normalize_active_issue_assignments` / stale recovery |
| Non-owner/maintainer assignee without status label | Active contributor claim — always blocks dispatch regardless of labels |
| Owner/maintainer assignee WITH active status label | Active pulse claim — blocks dispatch (GH#18352) |
| Owner/maintainer assignee WITHOUT active status label | Passive backlog bookkeeping — allows dispatch (GH#10521) |

Architecture: `dispatch_with_dedup` → `check_dispatch_dedup` Layer 6 is the canonical enforcement point for all implementation dispatch.

`normalize_active_issue_assignments` in `pulse-issue-reconcile.sh` was hardened in t1996 to also call `is_assigned` before self-assigning orphaned issues.

Test coverage: `.agents/scripts/tests/test-dispatch-dedup-multi-operator.sh` (7 assertions).

## `origin:interactive` Skips Pulse Dispatch (GH#18352)

When an issue carries `origin:interactive` AND has any human assignee, the pulse's deterministic dedup guard (`dispatch-dedup-helper.sh is-assigned`) treats the assignee as blocking — even if that assignee is the repo owner or maintainer, regardless of the current `status:*` label.

This closes the race where an interactive session claimed a task via `claim-task-id.sh` (applying `status:claimed` + owner assignment) and the pulse dispatched a duplicate worker before the session could open its PR.

Full active lifecycle recognised: `status:queued`, `status:in-progress`, `status:in-review`, and `status:claimed` all keep owner/maintainer assignees in the blocking set.

## Issue-Sync TODO Auto-Completion (t2029 → t2166)

`issue-sync.yml` auto-marks TODO entries complete on PR merge but cannot push to `main` without a `SYNC_PAT` — branch protection rejects `github-actions[bot]` pushes (`required_approving_review_count: 1`, no bypass on personal-account plans — `bypass_pull_request_allowances` returns HTTP 500, re-verified 2026-04-13).

**To enable auto-sync** (run in a separate terminal, NOT in AI chat):

Create a fine-grained PAT in GitHub UI: `Settings → Developer settings → Personal access tokens → Fine-grained → Only selected repositories → <repo> → Contents: Read and write`, then:

```bash
gh secret set SYNC_PAT --repo <owner>/<repo> --body "<PAT>"
```

`SYNC_PAT` is per-repo — every repo using `issue-sync.yml` needs it set independently. The requirement is unchanged under the reusable-workflow model (t2770): `secrets: inherit` in the caller grants the reusable workflow access to the caller's secrets, so the PAT still has to exist in each downstream repo.

Once set, the job log reads: `SYNC_PAT present — TODO.md push will use PAT`.

Without it, the workflow posts a remediation comment containing both the root-cause fix and the `ta[redacted-credential].sh` immediate workaround.

**t2166** extended the fallback to all four jobs and promotes the missing-secret signal to `::warning::` so operators see it on every run.

**Currently active for:** `marcusquinn/aidevops` (verified end-to-end 2026-04-19). Other registered repos still emit the t2166 warning until set per-repo — visible via `aidevops security check`.

**Detector scope (t2806, GH#20745):** `aidevops security check` detects the need for SYNC_PAT under both classic branch-protection rules AND repository rulesets. Repos migrated to the modern rulesets API (Settings → Rules → Rulesets) return 404 on the legacy `/branches/{branch}/protection` endpoint but carry protection via `/repos/{slug}/rulesets`; the detector now falls back to the rulesets path when the classic endpoint reports "not protected". See `security-posture-helper.sh::_branch_is_rulesets_protected`.

**Known false-positive (pending t2252):** the auto-completion path may mis-mark planning-only PRs (those using `Ref #NNN` / `For #NNN` without closing keywords) as `status:done` on merge — tracked as GH#19782.

## Dispatch-Path Default (t2821)

Tasks that modify the worker dispatch/spawn path have a **tautology failure mode**: a worker dispatched to fix broken dispatch runs through the code being fixed. Observed on #20765 (t2814): 3 worker attempts across ~90 minutes, ~90K tokens burned before a successful opus-4-7 run.

### Trigger

The task's brief `## How` section or `### Files Scope` references any file in the canonical self-hosting set. The canonical list is `.agents/configs/self-hosting-files.conf` — shared by `pre-dispatch-validator-helper.sh` (t2819) and the helpers below. Current entries: `pulse-wrapper.sh`, `pulse-dispatch-*`, `pulse-cleanup.sh`, `headless-runtime-helper.sh`, `headless-runtime-lib.sh`, `worker-lifecycle-common.sh`, `shared-dispatch-dedup.sh`, `shared-claim-lifecycle.sh`, `worker-activity-watchdog.sh`, `dispatch-dedup-helper.sh` (t2832).

### Decision tree

1. Brief references a dispatch-path file → recommend `#parent`, `no-auto-dispatch`, `#interactive` in the TODO entry.
2. Author overrides with `#dispatch-path-ok` → auto-dispatch proceeds with the `dispatch-path-ok` label applied. The t2819 self-hosting pre-dispatch detector remains active as a safety net (`model:opus-4-7` applied before dispatch).
3. No dispatch-path files in brief → normal dispatch rules apply.

### Tooling

- `task-brief-helper.sh` scans the generated brief after write and appends a `## Dispatch-Path Classification` section when patterns are found.
- `claim-task-id.sh` emits a **non-blocking** stderr advisory when `--labels auto-dispatch` is used on a dispatch-path task.
- Both helpers load patterns from `.agents/configs/self-hosting-files.conf`; adding a new file to the conf automatically updates all detection points.

### Why interactive is better for dispatch-path tasks

1. Human context for judgment calls about dispatch-path design trade-offs.
2. Bypasses the broken dispatch path entirely — interactive sessions don't spawn workers through the pulse.
3. Unlimited context budget vs ~200K soft-ceiling for workers.
4. Faster iteration on canary/FD/session-lock logic requiring visibility into the running system.

### Environment overrides

| Variable | Effect |
|---|---|
| `AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1` | Disable both the brief notice and claim-task-id warning |
| `AIDEVOPS_DISPATCH_PATH_FILES_CONF=<path>` | Override the conf file path |

### Labels

| Label | Meaning |
|---|---|
| `dispatch-path-ok` | Author explicitly requested auto-dispatch on a dispatch-path task |
| `parent-task` | Unconditional dispatch block — `dispatch-dedup-helper.sh` `_is_assigned_check_parent_task` short-circuits with `PARENT_TASK_BLOCKED` |
| `no-auto-dispatch` | Unconditional dispatch block (t2832) — `dispatch-dedup-helper.sh` `_is_assigned_check_no_auto_dispatch` short-circuits with `NO_AUTO_DISPATCH_BLOCKED`. Pre-fix the label was honoured by enrich/decomposition only; the dispatch path itself ignored it. After t2832, `no-auto-dispatch` alone is sufficient to block dispatch on a focused fix — no need to combine with `#parent`. Use `#parent` only for actual decomposition trackers. |

Companion fixes: t2819 (self-hosting pre-dispatch tier override), t2820 (no_work reclassification), t2832 (no-auto-dispatch unconditional block), derived from #20765 / GH#20827 dispatch-history analysis.

## Reusable-Workflow Architecture (t2770)

Since v3.9.0, `issue-sync.yml` is a **reusable workflow** — downstream repos ship a ~45-line caller YAML that `uses:` the reusable workflow from `marcusquinn/aidevops`. This eliminates YAML drift (the canonical cause of GH#20637-class incidents where downstream copies went stale) and removes the need for downstream repos to carry `.agents/scripts/` — framework scripts are fetched at runtime via a secondary `actions/checkout` step.

Full architecture, pinning strategies, migration guide: `reference/reusable-workflows.md`.
