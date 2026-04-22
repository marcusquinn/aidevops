<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Worker Diagnostics and Architecture

<!-- AI-CONTEXT-START -->

Reference for diagnosing headless worker failures. Workers are OpenCode instances dispatched by the pulse to solve GitHub issues autonomously.

**Scripts**: `headless-runtime-helper.sh` (worker lifecycle), `pulse-wrapper.sh` (dispatch), `dispatch-dedup-helper.sh` (dedup), `dispatch-claim-helper.sh` (claims).

<!-- AI-CONTEXT-END -->

## Worker Lifecycle

```text
Pulse cycle (every 3 min, configurable)
  → Version guard (enforce OPENCODE_PINNED_VERSION)
  → Canary smoke test (cached 30 min)
  → dispatch_with_dedup (claim + dedup check)
  → nohup worker launch (survives pulse-wrapper exit)
    → DB isolation (XDG_DATA_HOME per worker)
    → Activity watchdog (standalone process, monitors output growth)
    → OpenCode run (headless, direct to Anthropic API via OAuth)
    → On completion: merge worker DB back to shared DB, cleanup
    → On failure: CLAIM_RELEASED posted, issue available for re-dispatch
```

## Architecture Decisions

### SQLite DB Isolation (v3.6.130)

**Problem**: All headless workers shared `~/.local/share/opencode/opencode.db` with `busy_timeout=0`. Concurrent writes caused `SQLITE_BUSY` which silently broke OpenCode's streaming connection handler. Workers stalled at `step_start` with zero API errors logged.

**Why it was hard to find**: Interactive sessions (single instance) never hit contention. Version bisecting was misleading — fewer workers = less contention = fewer failures, creating a false correlation with OpenCode versions.

**Fix**: Each worker gets its own DB via `XDG_DATA_HOME=/tmp/aidevops-worker-auth.XXXXXX`. After completion, `_merge_worker_db()` copies session/message rows back to the shared DB using `ATTACH DATABASE` + `INSERT OR IGNORE` with a 5s timeout.

**Diagnostic**: If workers stall at `step_start` with no API errors, check:

```bash
# Are isolated dirs being created?
ls -d /tmp/aidevops-worker-auth.* 2>/dev/null || ls -d "$TMPDIR"/aidevops-worker-auth.* 2>/dev/null
# Is OPENCODE_DB still set? (it should NOT be)
grep 'OPENCODE_DB' ~/.aidevops/agents/scripts/headless-runtime-helper.sh
```

### Activity Watchdog (v3.6.126, fixed v3.6.140)

**Problem**: The original watchdog was a bash function backgrounded with `&` inside the worker's subshell. When `nohup` launched the worker (to survive pulse-wrapper exit), the backgrounded function died with its parent context. Stalled workers sat indefinitely with no kill mechanism.

**Fix**: Watchdog launched as a standalone process that outlives the worker subshell.

**Diagnostic**: If workers stall past the 300s timeout:

```bash
# Are watchdog processes alive?
ps aux | grep 'worker-activity-watchdog\|activity_watchdog' | grep -v grep
# Check worker log for WATCHDOG_KILL marker
grep WATCHDOG_KILL /tmp/pulse-*-<issue>.log
# Check for CLAIM_RELEASED on the issue
gh api repos/<slug>/issues/<num>/comments --jq '.[] | select(.body | test("CLAIM_RELEASED")) | .created_at'
```

### Canary Smoke Test (v3.6.123)

**Rules**:
1. Must use a **verified-working** model name (currently `anthropic/claude-sonnet-4-20250514`)
2. Must run **before** any side effects (claims, locks, ledger updates) — a failed canary must not block re-dispatch
3. Cached for 30 min (`~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass`)
4. Version guard runs on every dispatch (not cached)

**Diagnostic**: If no workers dispatch at all:

```bash
# Check canary cache
cat ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass
# Clear cache to force re-test
rm -f ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass
# Test canary manually
opencode run "Reply with exactly: CANARY_OK" -m anthropic/claude-sonnet-4-20250514 --dir "$HOME"
```

### Version Guard

**Problem**: Something outside aidevops periodically upgrades OpenCode to latest. The version guard in `headless-runtime-helper.sh` runs on every dispatch and reinstalls `OPENCODE_PINNED_VERSION` from `shared-constants.sh` if drift is detected.

**When to pin**: Set `OPENCODE_PINNED_VERSION` in `.agents/scripts/shared-constants.sh` to a specific version when a known-broken release exists. Set to `"latest"` when no pin is needed.

## Diagnostic Quick Reference

| Symptom | Check | Likely cause |
|---------|-------|-------------|
| Workers stall at `step_start`, no errors | Isolated DBs exist? Watchdog alive? | SQLite contention (if no isolation) or stream drop (if isolated) |
| No workers dispatched | Canary cache, pulse log | Broken canary, dedup blocking, no dispatchable issues |
| Workers rejected immediately | `grep "Claim guard" /tmp/pulse-*.log` | Claim format mismatch (removed in v3.6.138) |
| Workers dispatch but produce 0 bytes | Version check, `opencode --version` | Wrong OpenCode version, auth failure |
| PRs created but not merged | `review-bot-gate-helper.sh check <PR>` | Review bot rate-limited (passes immediately since v3.6.136) |
| Claim/release loop | Comment history on issue | Stale claims, guard rejections — recreate issue with clean context |
| Watchdog doesn't fire | `ps aux \| grep watchdog` | Watchdog process died with subshell |

## Proving Workers Are Doing Real Work

Don't trust process counts or log existence. Prove output growth:

```bash
# Measure actual output growth over 15 seconds
for log in $(ls -t /tmp/pulse-*-*.log | head -3); do
  issue=$(basename "$log" .log | sed 's/pulse-[^-]*-[^-]*-//')
  s1=$(wc -c < "$log" | tr -d ' ')
  sleep 15
  s2=$(wc -c < "$log" | tr -d ' ')
  echo "#$issue: +$((s2-s1))b in 15s"
done

# Check GitHub notifications for actual PRs
gh api notifications --jq '.[0:5] | .[] | "\(.updated_at[0:16]) \(.subject.type): \(.subject.title)"'
```

## Multi-Runner Environments

When multiple pulse runners are operating across machines, single-worker diagnostics above
remain valid. For cross-runner race conditions, stale-recovery loops, and new runner setup,
see `reference/cross-runner-coordination.md`.

## `gh pr checks` cancelled-vs-fail

`gh pr checks` renders the GitHub Actions `cancelled` conclusion as
`fail` in its TSV/default output. Only `success` becomes `pass`; all
of `cancelled`, `timed_out`, `action_required`, `failure` collapse to
`fail`.

Before assuming a PR is broken, run:

```bash
gh api repos/OWNER/REPO/actions/runs -f branch=BRANCH \
  -q '.workflow_runs[] | [.conclusion, .name] | @tsv'
```

If all "fail"s are `cancelled`, the CI is not actually broken — a
concurrency cascade (or manual cancel) produced them. See parent issue
GH#19736 for the cascade class.

## Recovery Checklist

When workers are failing systemically:

1. **Version**: `opencode --version` — matches pin in `shared-constants.sh`?
2. **Canary**: `rm -f ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass` and check next cycle
3. **Processes**: `ps aux | grep opencode` — stale processes? Kill with `pkill -f 'opencode.*run'`
4. **Isolation**: `grep 'db_isolated' /tmp/pulse-*.log` — are workers getting isolated DBs?
5. **Watchdog**: `ps aux | grep watchdog` — are watchdog processes surviving?
6. **Pulse log**: `tail -30 ~/.aidevops/logs/pulse.log` — dedup blocked? backoff? claim errors?
7. **Issue comments**: check for `CLAIM_RELEASED` / `DISPATCH_CLAIM` comment loops
8. **Review gate**: `review-bot-gate-helper.sh check <PR>` — `WAITING` means bot is blocking merge

## Pre-Dispatch Eligibility Gate (t2424)

Runs after all dedup/claim/validator layers pass, before the worker spawns. Catches issues that are already resolved:
- CLOSED state
- `status:done` or `status:resolved` label
- Linked PR merged in the last 5 minutes (window: `AIDEVOPS_PREDISPATCH_RECENT_MERGE_WINDOW`, default 300s)

Behaviour: fail-open on API errors (logs warning, dispatch proceeds). Each abort increments `pre_dispatch_aborts` in `~/.aidevops/logs/pulse-stats.json` (visible via `aidevops status`).

Emergency bypass: `AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY=1`

Test coverage: `.agents/scripts/tests/test-pre-dispatch-eligibility.sh`

## Pulse Decision Correlation

When a PR doesn't auto-merge (or merges unexpectedly), use `pulse-diagnose-helper.sh` to
correlate pulse.log entries with the PR's GitHub state:

```bash
pulse-diagnose-helper.sh pr <N> --repo <owner/repo>
```

The helper reads `~/.aidevops/logs/pulse.log` (and rotated companions), filters lines
mentioning the PR, classifies each against a 60+ rule inventory, and cross-references
`gh pr view` metadata to produce a chronological report.

### Worked example

```text
$ pulse-diagnose-helper.sh pr 20329 --repo marcusquinn/aidevops

PR #20329 (marcusquinn, CLOSED 2026-04-21T18:01:09Z, merged=no)
  Title: t2710: fix dirty-pr-sweep
  Created: 2026-04-20T09:00:00Z  Review: CHANGES_REQUESTED  MergeState: DIRTY

  2026-04-20T10:00:00Z  pulse-wrapper.sh                pw-merge-skip-changes-requested
              Merge pass skipped — review decision is CHANGES_REQUESTED
              source: pulse-wrapper.sh:968

  2026-04-21T17:45:03Z  pulse-dirty-pr-sweep.sh         dps-classify
              Dirty PR sweep classification decision
              source: pulse-dirty-pr-sweep.sh:788

  2026-04-21T17:45:04Z  pulse-dirty-pr-sweep.sh         dps-notify
              Dirty PR notification posted
              source: pulse-dirty-pr-sweep.sh:721

Summary:
  Total pulse events: 3
  Last pulse decision: dps-notify
  Outcome: PR was closed without merge.
```

Each event line shows: timestamp, source script, rule ID, human description, and the
exact `script:line` of the rule that produced the log entry. Use `--verbose` to see raw
log lines alongside classifications. Use `--json` for programmatic consumption.

### Subcommands

| Command | Description |
|---------|-------------|
| `pr <N> [--repo <slug>] [--verbose] [--json]` | Diagnose pulse behaviour for PR #N |
| `rules [--json]` | List the full rule inventory (60+ entries) |
| `help` | Show usage |

### Limitations

- Read-only diagnostic — does not change pulse behaviour.
- Covers PR merge/sweep decisions only. Issue-lifecycle (dispatch, NMR, parent-task)
  is a candidate follow-up (`pulse-diagnose-helper.sh issue <N>`).
- Log lines without timestamps are sorted lexically (best effort).
- Rotated `.gz` logs require `zcat` to be available.
