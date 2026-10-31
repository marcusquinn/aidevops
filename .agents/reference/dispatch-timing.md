<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Dispatch Ceremony Timing — Per-Stage Instrumentation (t3034)

After t3026 raised the per-candidate timeout floor to 360s, fresh
`exceeded 360s` events still appeared. This instrumentation captures
elapsed time for each sub-stage of the `dispatch_with_dedup` ceremony
so tail latencies (p95/p99) can be identified and optimized.

## Architecture

The instrumentation follows the same pattern as `gh-api-instrument.sh`
(t2902): a sourceable helper with a fail-open TSV append per stage.

```text
dispatch-stage-instrument.sh       — helper (sourceable + CLI)
pulse-dispatch-core.sh             — high-level stages instrumented
pulse-dispatch-worker-launch.sh    — launch sub-stages instrumented
~/.aidevops/logs/dispatch-stages.tsv — TSV log (append-only)
```

## Instrumented Stages

### High-level stages (in `dispatch_with_dedup`)

| Stage name           | What it covers                                      |
|----------------------|-----------------------------------------------------|
| `gh_issue_view`      | Single canonical metadata fetch (t2996 bundle)      |
| `dedup_check`        | All 9 dedup layers (`_dispatch_dedup_check_layers`)  |
| `brief_freshness`    | Brief-body freshness guard (`_ensure_issue_body_has_brief`) |
| `tier_body_shape`    | explicit tier:simple execution-contract guard        |
| `predispatch_validator` | Generator-tagged premise validation (GH#19118)    |
| `eligibility_gate`   | Generic eligibility gate (CLOSED, status:done, recent-merge) |
| `worker_launch_total` | Full `_dispatch_launch_worker` call                 |
| `ceremony_total`     | End-to-end `dispatch_with_dedup` from metadata fetch to launch |

A stage row records that the stage ran and how long it took, not its verdict.
For example, `dedup.zero_attempt_backoff` rows appear for every pre-claim
evaluation. Count actual holds with
`rg -c "DISPATCH_BLOCK_REASON reason=zero_attempt_backoff" ~/.aidevops/logs/pulse.log`.

Gate order inside `dedup_check` is cheapest-rejection first: capacity, state/label,
NMR and blocked-by gates, then the read-only `7_layers` dedup (active claims, PR
evidence, terminal-blocker circuit), then the costly scope gates
(`consolidation`, `large_file`, `footprint`), then the external-author gate.
Most candidates are rejected by `7_layers`; running scope gates first spent hours
per day per runner and could fire consolidation or simplification side effects
for issues another runner owns (GH#32729). Keep new costly gates after `7_layers`.

### Launch sub-stages (in `_dispatch_launch_worker`)

| Stage name            | What it covers                                     |
|-----------------------|----------------------------------------------------|
| `assign_and_label`    | Issue edit: swap assignees + status:queued + origin:worker |
| `resolve_tier_model`  | Label-based tier resolution + ordered healthy model fallback |
| `lock_issue`          | Verified issue conversation lock (t1894/t1934); linked PRs remain open for CI reviews |
| `final_ownership_fence` | Live ownership check immediately before queued assignment |
| `precreate_worktree`  | Git worktree pre-creation (or reuse) + dep restore  |
| `worker_spawn`        | DB prewarm + setsid/nohup launch + early-exit monitor |
| `post_launch_hooks`   | Stagger delay + ledger + dispatch comment + claim audit |

### Worktree pre-creation sub-stages (`precreate.*`, GH#35602)

`precreate_worktree` is split so its tail can be attributed. The dispatcher
exports `AIDEVOPS_DISPATCH_STAGE_ISSUE`/`AIDEVOPS_DISPATCH_STAGE_REPO` to
`worktree-helper.sh add`; the helper records sub-stages through
`_ds_substage_run`/`_ds_substage_record` only while that context is set, so
interactive worktree creation writes nothing. Nested stages overlap their
parent (`create_worktree` contains the fetch, remote checks and `git worktree add`).

| Stage name | What it covers |
|------------|----------------|
| `precreate.helper_add` | Whole `worktree-helper.sh add` subprocess, including startup (dispatcher side) |
| `precreate.restore_deps` | Dispatcher node_modules restore after creation |
| `precreate.capacity_check` | Filesystem capacity gate |
| `precreate.create_worktree` | `_cmd_add_create_worktree`: remote checks, base refresh, native add |
| `precreate.stale_remote_check` / `precreate.unmerged_remote_check` | Stale and unmerged remote-branch probes |
| `precreate.sibling_status` | One `git status` health probe of a sibling fetch worktree |
| `precreate.scratch_add` | Scratch fetch worktree when no healthy sibling exists |
| `precreate.base_fetch` | `git fetch --no-tags origin <default>` fresh-base refresh |
| `precreate.registry_begin_create` | Registry `begin-create` transaction |
| `precreate.git_worktree_add` | Native `git worktree add` checkout |
| `precreate.registry_register` | Creation-metadata registration |
| `precreate.verify_generation` | Ownership registration + generation verification |
| `precreate.managed_enroll` | Managed-lifetime enroll (systemd backend only) |
| `precreate.helper_deps` / `precreate.exclusions` / `precreate.preview_routes` | Helper dependency bootstrap, Spotlight/Time Machine exclusions, preview routes |

**Attributing the tail (GH#36132).** Aggregate percentiles of nested stages
cannot be subtracted exactly, so attribute from raw attempts. Each attempt ID
ends with the start time in nanoseconds (`<cycle>:<issue>:<stage>:<start_ns>`).
Helper-side records use the helper's PID as the cycle, so join them to
`precreate.helper_add` by issue number and a start time inside its window.
Derived intervals:

- Dispatcher reuse selection: `precreate_worktree` start to `helper_add` start.
- Helper startup: `helper_add` start to `capacity_check` start.
- Dispatcher registration: `helper_add` end to `precreate_worktree` end, minus `restore_deps`.

For contention, count overlapping same-repo attempts: an object-store
bottleneck raises `git_worktree_add`/`base_fetch` with overlap, while host load
inflates every stage at once. `_ds_substage_run` records a stage whatever its
exit status, so a recorded `create_worktree` does not prove the creation
succeeded. Look for the next stage (`verify_generation`) or
`pre_runtime_failure:*`.

## TSV Log Format

```text
<ISO8601_UTC>\t#<issue_number>\t<repo_slug>\t<stage_name>\t<elapsed_ms>
```

Example:

```text
2026-04-29T01:15:30Z	#21500	marcusquinn/aidevops	gh_issue_view	1250
2026-04-29T01:15:32Z	#21500	marcusquinn/aidevops	dedup_check	2100
2026-04-29T01:15:33Z	#21500	marcusquinn/aidevops	brief_freshness	45
```

## CLI Usage

```bash
# Print per-stage p50/p95/p99/max from the last 24h of data:
dispatch-stage-instrument.sh report

# Custom time window (1h = 3600s):
dispatch-stage-instrument.sh report 3600

# Rotate the log if it exceeds the line cap (the pulse already does this every cycle):
dispatch-stage-instrument.sh trim

# Wipe the log:
dispatch-stage-instrument.sh clear
```

`report` streams the log through awk and a C-locale sort. It honours the
window, skips `start` rows and writes no scratch copy, so it finishes in
seconds on a log of months of data (GH#35935). The pulse calls `_ds_trim_log`
at cycle finish next to `gh_trim_log`. Each trim removes
`dispatch-stages.tsv.report.*` / `.trim.*` scratch files older than 60 minutes
that killed runs left behind. When the log exceeds the cap, it also keeps only
the newest half.

## Manual p95 Computation

`report` already prints these percentiles. For an ad-hoc all-time cut, skip
`start` rows, which carry elapsed `0`:

```bash
awk -F'\t' '$6 != "start" && $5 > 0 {print $4 "\t" $5}' ~/.aidevops/logs/dispatch-stages.tsv | \
    sort -k1,1 -k2,2n | \
    awk -F'\t' '
    { stage[$1]=stage[$1] " " $2; count[$1]++ }
    END { for (s in stage) {
      n=split(stage[s], arr, " "); p95_idx=int(n*0.95);
      print s, "p95=" arr[p95_idx] "ms (n=" count[s] ")"
    }}'
```

## Env Vars

### Prelaunch lease budget

The dispatcher renews its live claim immediately after winning, before comment
reads and worktree preparation. `AIDEVOPS_DISPATCH_PRELAUNCH_BUDGET_SECONDS`
defaults to 300 (valid range 1–999). The renewed lease covers the remaining
preparation interval plus the existing OpenCode warm-up/handoff allowance.
Preparation has a fixed elapsed-time deadline: the warm-up renewal cannot
restart it. Expired budgets stop at stage boundaries before further ownership
publication or spawn; underlying operations retain their own timeout controls.
Failed renewal aborts through the existing exact-claim cleanup path.

Queued ownership publication needs more than `remaining > 0`: the issue lock,
the final ownership fence and the assignment each re-check the deadline with a
publication reserve, so ownership is never published when the remaining budget
cannot reach spawn (GH#35602). The reserve covers `assign_and_label` (observed
max about 51 s) plus the live open-issue guard and spawn (about 5–25 s).
`AIDEVOPS_DISPATCH_PUBLICATION_RESERVE_SECONDS` defaults to 75 (valid 0–999;
0 restores the bare deadline check; invalid values use the default). A short
reserve aborts before any lock, assignment or label change with
`pre_runtime_failure:prelaunch_reserve_insufficient`; an expired deadline keeps
`prelaunch_budget_exhausted`. The reserve never slides the deadline and leaves
lease TTL arithmetic unchanged.

`CLAIM_WON expires_at` reports the persisted lease expiry, not a fresh deadline
calculated after consensus. Claim acquisition consumes that lease; an expired
claim is never revived. Keep the default orphan grace and ownership gates intact
rather than increasing orphan retention to hide slow preparation.

| Variable | Default | Description |
|----------|---------|-------------|
| `AIDEVOPS_DISPATCH_STAGES_LOG` | `~/.aidevops/logs/dispatch-stages.tsv` | Log file path |
| `AIDEVOPS_DISPATCH_STAGES_LOG_MAX_LINES` | `200000` | Trim threshold (about 16 days at ~12.5k records/day) |
| `AIDEVOPS_DISPATCH_STAGES_DISABLE` | `0` | Set `1` to no-op all recording |
| `AIDEVOPS_DISPATCH_PRELAUNCH_BUDGET_SECONDS` | `300` | Fixed prelaunch preparation deadline |
| `AIDEVOPS_DISPATCH_PUBLICATION_RESERVE_SECONDS` | `75` | Budget that must remain before lock/fence/assignment |
| `AIDEVOPS_DISPATCH_STAGE_ISSUE` / `AIDEVOPS_DISPATCH_STAGE_REPO` | unset | Set by the dispatcher for the worktree helper; enables `precreate.*` |

## Hypotheses (from t3034 issue)

1. **Primary**: `gh issue view` + `gh api` rate-limit retries stack into
   the 360s envelope when GraphQL is exhausted (REST fallback also has
   retry+backoff). The `gh_issue_view` and `dedup_check` stages are the
   most likely culprits.

2. **Secondary**: `_dlw_prewarm_opencode_db` migration step on cold
   isolated DB adds 10-20s that compounds with retry-heavy gh calls.

3. **Tertiary**: `post_launch_hooks` includes a configurable stagger
   delay (`PULSE_DISPATCH_STAGGER_SECONDS`, default 8s) that contributes
   to ceremony overhead in batch dispatch scenarios.

## Follow-Up Tasks

After accumulating 50+ dispatches:

1. Identify stages with p95 > 60s.
2. File follow-up optimization tasks for each.
3. If sum of medians < 360s but tail behaviour pushes above, document
   and size the timeout floor accordingly.
