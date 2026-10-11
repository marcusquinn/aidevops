<!-- aidevops:brief-schema=v2 -->

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `bounded operation supervisor ps CPU tracking macOS` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found 0 open issues / 0 open PRs for the three target files; last changes are GH#34047 (0ab1dfae6a), GH#33747 (c3b6e74dfb), GH#33514 (3a35a6b121)
- [x] File refs verified: 3 source files and 1 test file checked at origin/main 8b6b30c5ad
- [x] Tier: `tier:standard` — process-containment semantics in a security-relevant supervisor; needs judgement about when the marker scan must still run
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Found while investigating why the pulse dispatched 0 workers per cycle. `preflight_initial_capacity` logged `max workers: 0, load=77.12/16 ... cpu_gate=closed cpu_idle_pct=1` while only 2 workers were active. Host CPU was 0.15–3.5% idle with 34–38% system time, and seven `bounded-operation-supervisor.mjs` processes from one interactive session were each spawning `ps` continuously.

## What

On macOS, every active `aidevops_bounded_operation` supervisor reads the environment of every process on the host four times a second. Measured cost: about 0.41 CPU cores per running operation, and about 0.95 cores during the 25 ms post-exit drain loop. Expected outcome: escaped-process recovery (GH#33747) keeps its guarantees at exit, termination and drain, while periodic tracking stops paying for a full environment scan on every 250 ms tick.

## Why

`bounded-operation-supervisor.mjs:146` calls `tracker.track` every 250 ms (`TRACK_INTERVAL_MS`, line 31). The drain loop at `:167-173` calls it every 25 ms after the command exits. Each `track()` (`bounded-operation-process-tree.mjs:68-76`) runs `recordSnapshot` (`:55-62`), and that always calls `recoverMarked` (`:48-53`). On darwin, `recoverMarked` calls `darwinOperationPids` (`bounded-operation-process-snapshot.mjs:55-66`), which runs `ps axeww -o uid=,pid=,command=` and parses every process environment to find `AIDEVOPS_OPERATION_ID=<id>`. On Linux, it reads `/proc/<pid>/environ` for every process.

Measurements, taken by importing `createProcessTreeTracker` and calling `track()` at the supervisor's cadence for 10 s under `/usr/bin/time -p`:

| Cadence | Marker scan | Ticks | CPU (user+sys) | Cores |
|---|---|---|---|---|
| 250 ms | yes (production) | 37 | 1.53 + 2.71 = 4.24 s / 10.29 s | ~0.41 |
| 250 ms | no | 40 | 0.25 + 0.86 = 1.11 s / 10.14 s | ~0.11 |
| 25 ms (drain) | yes | 52 | 1.91 + 2.98 = 4.89 s / 5.17 s | ~0.95 |

The host had about 960 processes. `ps axeww` returned about 870 KB per call.

Impact: seven concurrent operations from one session used about 2.9 cores (about 18% of a 16-core host) on tracking alone. The pulse CPU admission gate (`pulse-capacity.sh:388-418`: load/core above `orchestration.max_load_per_core` and idle below the admit percentage) then closed worker admission entirely. After those operations ended, system CPU fell from 34–38% to 19–23% and idle rose from 0–3.5% to 8.5–22.6%. The operations' own workloads ended at the same time, so that drop is supporting evidence only; the controlled measurement above is the primary evidence.

Recovery needs the marker scan only at decision points. Marker matching is exact per operation, and a matched process keeps its marker for its lifetime. A scan at exit, termination or the final drain check therefore finds the same escaped processes that a scan every 250 ms would find.

## Tier

### Tier checklist (verify before assigning)

- [x] **Exact execution contract supplied?** Edits are specified below, but containment semantics need judgement.
- [x] **Targets and reference pattern verified?** All line refs checked at 8b6b30c5ad.
- [ ] **No semantic or design decision remains?** The marker cadence and the decision points that force a scan are design choices.
- [x] **Bounded, reversible, low-consequence impact?** Two files; revertible in one commit.
- [x] **No stateful coordination to invent?** Only a per-tracker timestamp.
- [x] **Focused verification and rollback are explicit?** See Verification.
- [x] **No dispatch-path risk override?** Not a worker dispatch path, although bounded operations contain test servers.

**Selected tier:** `tier:standard`

**Tier rationale:** a small change to containment-sensitive code, where the decision points must preserve GH#33514, GH#33747 and GH#34047 guarantees.

## How (Approach)

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/bounded-operation-process-tree.mjs:55-83` — run `recoverMarked` (and the second `recordOwnedDescendants` pass) only when a scan is due. A scan is due on the first track, when `MARKER_SCAN_INTERVAL_MS` (5000) has elapsed since the last scan, or when the caller passes `{ markers: true }`. Periodic callers pass no argument.
- `EDIT: .agents/plugins/opencode-aidevops/bounded-operation-supervisor.mjs:70-104,155-164` — force the marker scan in three places: terminator `signalNested`, the child `exit` handler, and `ownedTreeDrained` just before it would report a drained tree.

### Complete Write Surface

- **Callers/readers:** `createProcessTreeTracker` is used only by `bounded-operation-supervisor.mjs:115`. `rg -n "createProcessTreeTracker|tracker\.track" .agents/plugins` finds no other runtime caller.
- **Writers/mutation paths:** process signals only, through `signalEach` and `signalOwnGroup`. No files or state are written.
- **Existing verification/tests:** `.agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs` covers GH#33514 nested groups, GH#33747 escaped servers on completion, cancel and expiry, GH#34047 post-exit receipts, and PID-reuse identity.
- **Schemas/config:** none. The receipt fields are unchanged.
- **Generated/deployed mirrors:** `setup.sh` deploys the plugin into versioned runtime bundles. Sessions that are already running keep their pinned bundle until restart.
- **Migrations/backfills:** N/A because the change is in-memory scheduling only (evidence: the tracker has no persisted state).
- **Cleanup/rollback paths:** revert the single commit.

### Hazards and Compatibility

- **Concurrency/atomicity:** `track()` runs on the single Node event loop, so the timestamp has no concurrent writers.
- **Missed escapee risk:** take the case where an escaped, marked process spawns a child that clears its environment and is reparented, all between periodic scans. That child is attributable only while its marked parent is known. A 5 s cadence narrows that window but does not close it. Forced scans at exit, termination and the final drain check cover every escapee that still carries the marker.
- **Mixed-version:** a new plugin bundle applies only to newly launched sessions. Older bundles keep the old cadence.
- **Partial failure:** if a forced scan's `ps` fails, `track()` returns null as it does today, and drain retries on the next 25 ms tick.

### Verification

```bash
node --check .agents/plugins/opencode-aidevops/bounded-operation-process-tree.mjs
node --check .agents/plugins/opencode-aidevops/bounded-operation-supervisor.mjs
node --test .agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs .agents/plugins/opencode-aidevops/tests/test-bounded-operation-dispatch-launcher.mjs
```

- **Runtime evidence:** repeat the 10 s tracker measurement at 250 ms with an operation ID. Expect CPU close to the no-marker row (about 0.1–0.15 cores), with one marker scan per 5 s instead of 4 per second.
- **Broad verification trigger:** not required. CI `plugin-import-check.yml` runs every plugin test.

### Files Scope

- `.agents/plugins/opencode-aidevops/bounded-operation-process-tree.mjs`
- `.agents/plugins/opencode-aidevops/bounded-operation-supervisor.mjs`

## Acceptance Criteria

- [ ] Periodic `track()` calls run the marker scan at most once per `MARKER_SCAN_INTERVAL_MS`. Calls that pass `{ markers: true }` always run it.

  ```yaml
  verify:
    method: codebase
    pattern: "MARKER_SCAN_INTERVAL_MS"
    path: ".agents/plugins/opencode-aidevops/bounded-operation-process-tree.mjs"
  ```

- [ ] Exit, termination and the final drain confirmation all force the marker scan.

  ```yaml
  verify:
    method: codebase
    pattern: "markers: true"
    path: ".agents/plugins/opencode-aidevops/bounded-operation-supervisor.mjs"
  ```

- [ ] Existing bounded-operation tests pass, including the GH#33747 escaped-server cases for completion, cancel and expiry.

  ```yaml
  verify:
    method: bash
    run: "node --test .agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs .agents/plugins/opencode-aidevops/tests/test-bounded-operation-dispatch-launcher.mjs"
  ```

- [ ] The PR reports before/after CPU from the tracker measurement at the 250 ms cadence.

  ```yaml
  verify:
    method: manual
    prompt: "Confirm the PR body includes before/after user+sys CPU for 10 s of 250 ms tracking with an operation ID."
  ```

## Context & Decisions

- Keep `TRACK_INTERVAL_MS` at 250 ms. The cheap parent-chain snapshot still catches short-lived intermediate parents before they reparent, so only the expensive marker scan changes.
- Out of scope: pulse CPU admission thresholds (`orchestration.max_load_per_core`, idle admit percentage). Those are host-protection policy; this change only removes avoidable framework load.

## Relevant Files

- `.agents/plugins/opencode-aidevops/bounded-operation-supervisor.mjs:31,70-104,146,155-173` — tracking cadence, terminator, drain loop and exit handler.
- `.agents/plugins/opencode-aidevops/bounded-operation-process-tree.mjs:48-83` — `recoverMarked`, `recordSnapshot` and `createProcessTreeTracker`.
- `.agents/plugins/opencode-aidevops/bounded-operation-process-snapshot.mjs:38-75` — the `ps` snapshot and the darwin `ps axeww` marker scan.
- `.agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs:457-580` — containment and escaped-server tests.
- `.agents/scripts/pulse-capacity.sh:388-418` — the CPU admission gate this load closes.

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | done during the investigation |
| Implementation | 20m | two files |
| Verification | 20m | plugin tests and CPU measurement |
| **Total** | **55m** | |
