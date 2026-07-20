<!-- aidevops:brief-schema=v2 -->

# t18164: Add durable one-shot scheduling and completion-aware routine logging

## Pre-flight

- [x] Memory recall: `aidevops routines delayed one-time headless continuation scheduling activity logging issue worker` → 0 hits — no prior reusable lesson found
- [x] Discovery pass: 3 recent commits / 0 related merged PRs / 0 open PRs touch target routine files; GitHub issue search found no equivalent open task
- [x] File refs verified: 14 references checked against `aa1d49e47`, all present
- [x] Tier: `tier:thinking` — durable scheduling, lifecycle state, platform recovery, and cross-module compatibility require architectural judgment across more than five files
- [x] Seeded draft PR decision recorded: skipped — design and failure-mode choices should precede code

## Origin

- **Created:** 2026-07-20
- **Session:** OpenCode:interactive-2026-07-20-gh27777
- **Created by:** ai-interactive at maintainer request
- **Issue:** GH#28313
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** During the post-reset evidence observation for #27777, a request to wait 13 hours and resume autonomously required a bespoke detached scheduler. The routines stack supports recurring jobs but lacks one coherent path for exact one-shot continuation, restart recovery, issue-worker setup, and terminal completion logging.

## What

Add a first-class durable one-shot deferred-job facility to aidevops and integrate it with existing routines and headless-worker infrastructure. Operators and interactive agents must be able to schedule work for an absolute time or relative delay, inspect or cancel it, survive host/runtime restarts, and receive accurate queued, running, and terminal activity records.

Also remove two adjacent inconsistencies exposed by this session:

1. Scheduler-installed LLM routines must use `headless-runtime-helper.sh`, not a bare runtime CLI.
2. Pulse-dispatched agent routines must record terminal success or failure after the agent exits, not optimistic success immediately after background launch.

## Why

The recurring-routine contract intentionally supports daily, weekly, monthly, and cron schedules. It has no one-shot `--at` or `--after` path, so exact delayed continuation currently requires custom sleep and state code outside central inventory, cancellation, restart recovery, and activity reporting.

A fake recurring routine can replay, needs manual cleanup, and conflates one-time task history with `rNNN` definitions. It also would not improve completion evidence today because `.agents/scripts/pulse-routines.sh:144-185` backgrounds the headless agent and immediately records success. Meanwhile `.agents/scripts/routine-helper.sh:133-154` generates bare `opencode run`, contrary to the required headless wrapper.

## Tier

- [ ] Two or fewer files to modify — no; scheduler, CLI, logging, docs, and tests must coordinate.
- [ ] Every target file under 500 lines — no; root CLI and routine logging are larger.
- [ ] Exact replacement blocks for every edit — no; a state machine and scheduler design are required.
- [ ] No design or fallback choices — no; concurrency, restart, privacy, and lifecycle semantics need judgment.
- [ ] Estimate one hour or less — no.

**Selected tier:** `tier:thinking`

**Tier rationale:** This creates a cross-platform scheduling state machine and reconciles recurring-routine, manual-worker, scheduler, and terminal-ledger behavior without creating a parallel execution stack.

## PR Conventions

This is a leaf task. The final implementation PR should use the normal issue-closing convention for this issue.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Evidence defines the gap and constraints, but implementation must select the smallest durable queue and scheduler integration first.
- **Status:** `not-created`
- **Freshness evidence:** memory, commit and PR discovery, issue deduplication, and file verification were performed against `aa1d49e47`.
- **Verification run:** discovery only; no implementation checks run
- **Stale-assumption warning:** re-check routine, scheduler, and launch-worker code if related changes merge first.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/reference/routines.md:4-54` and `.agents/scripts/routine-helper.sh:18-155` — establish recurring-only behavior and the bare-runtime mismatch.
- **Then read:** `.agents/scripts/pulse-routines.sh:89-188` and `.agents/scripts/routine-log-helper.sh:427-669` — establish launch-versus-terminal logging behavior.
- **Load only if changing issue dispatch:** `.agents/scripts/commands/launch-worker.md` and `aidevops.sh:1277-1441` — reuse manual worker ceremony.
- **Load only if terminal linkage is unclear:** `.agents/scripts/headless-runtime-worker.sh:1546-1561` — consume the existing dispatch-ledger outcome.
- **Stop when:** the durable state schema, one scheduler owner, structured headless invocation, completion callback, and focused test seams are clear.

### Worker Quick-Start

```bash
git grep -n -E "build_opencode_command|_routine_execute|routine-log-helper.sh.*update|record-outcome" -- aidevops.sh .agents/scripts .agents/reference/routines.md
git log --oneline -10 -- .agents/scripts/routine-helper.sh .agents/scripts/pulse-routines.sh .agents/scripts/routine-log-helper.sh aidevops.sh
```

Verified facts:

- `routine-helper.sh` accepts only five-field cron schedules and emits bare `opencode run`.
- Pulse agent routines launch the headless helper in the background, then immediately record `success` with near-zero duration.
- `routine-log-helper.sh update` accepts only terminal `success|failure` and requires recurring-routine tracking state.
- Headless workers already record terminal outcomes through `dispatch-ledger-helper.sh`.
- `aidevops launch-worker` already preserves issue status, origin, assignment, worktree, and ledger ceremony for immediate dispatch.

### Files to Modify

- `NEW: .agents/scripts/deferred-job-helper.sh` — structured one-shot creation, atomic due claiming, dispatch, status, cancellation, recovery, retention, and private state. Split a focused sibling library or runner if complexity gates require it.
- `EDIT: aidevops.sh:949-960,1277-1441,1662` — expose thin `aidevops schedule once|status|cancel` delegation; keep scheduler logic out of the root CLI.
- `EDIT: .agents/scripts/routine-helper.sh:18-155,280-469` — route scheduled LLM execution through the headless helper or structured runner and eliminate generated bare runtime invocation.
- `EDIT: .agents/scripts/pulse-routines.sh:89-188` — extract agent dispatch from `_routine_execute`, record launch separately, and finalize metrics only from terminal outcome.
- `EDIT: .agents/scripts/routine-log-helper.sh:427-669` — add backward-compatible lifecycle records such as `queued|running|success|failure|cancelled`; append execution summaries only for terminal states.
- `EDIT: .agents/scripts/setup/_routines.sh` — install one platform-native due-job runner, or reuse one equivalent scheduler owner, so jobs survive reboot without one sleeper or service per job.
- `EDIT: .agents/reference/routines.md:4-54` — document recurring versus one-shot routing and state semantics.
- `EDIT: .agents/workflows/routine.md:10-84` and `.agents/scripts/commands/routine.md:10-84` — teach recurring → `/routine`, delayed once → `aidevops schedule once`, condition-driven → Pulse.
- `NEW: .agents/scripts/tests/test-deferred-job-helper.sh` — fixture-clock tests for state transitions, concurrency, cancellation, overdue recovery, privacy, and dispatch.
- `NEW: .agents/scripts/tests/test-aidevops-schedule-command.sh` — CLI parsing, help, and delegation tests.
- `EDIT: .agents/scripts/tests/test-routine-tracking-updates.sh:161-199` — prove agent routines wait for terminal completion while script routines remain compatible.
- `EDIT: .agents/scripts/tests/test-routine-systemd-calendar.sh` and relevant launchd fixtures — prove platform rendering and recovery without changing a real scheduler.

### Complete Write Surface

- **Callers/readers:** root CLI, `/routine` workflow, scheduler setup, Pulse recurring evaluator, and status or cancel operators.
- **Writers/mutation paths:** `.agents/scripts/deferred-job-helper.sh` writes one-shot job state and logs; due runners claim and finalize jobs; `.agents/scripts/routine-log-helper.sh` writes recurring JSONL, state, and optional tracking summaries; cancellation writes a terminal state without launch.
- **Tests/fixtures:** `.agents/scripts/tests/test-deferred-job-helper.sh` and `.agents/scripts/tests/test-aidevops-schedule-command.sh` use isolated HOME/workspace fixtures; routine and scheduler stubs extend `.agents/scripts/tests/test-routine-tracking-updates.sh`.
- **Schemas/config:** versioned private job schema with ID, due time, lifecycle timestamps/status, structured dispatch fields, attempt and lease identity, prompt digest/reference, PID/session key, and outcome. Preserve the existing `TODO.md` `rNNN repeat:` schema.
- **Generated/deployed mirrors:** setup deploys scripts/docs into runtime bundles; generated scheduler files remain private and use standard `sh.aidevops.*` labels or markers.
- **Migrations/backfills:** `TODO.md` recurring definitions are not converted, and private pre-existing sleepers are not imported; unsupported versions under `$AIDEVOPS_AGENT_WORKSPACE/scheduled/` fail closed with evidence.
- **Cleanup/rollback paths:** `.agents/scripts/deferred-job-helper.sh cancel|uninstall|prune` is idempotent, uninstall preserves queued state unless purge is explicit, and rollback never replays a terminal job.

### Implementation Steps

1. Define and test this public contract before implementation:

   ```text
   aidevops schedule once (--at ISO-UTC | --after DURATION) --name NAME --dir PATH
       (--prompt-file PATH | --issue N --repo OWNER/REPO)
       [--worktree PATH --branch NAME --agent NAME --tier TIER --model MODEL --title TITLE]
   aidevops schedule status [JOB_ID]
   aidevops schedule cancel JOB_ID
   deferred-job-helper.sh run-due
   ```

   `--at` and `--after` are mutually exclusive. Persist structured fields, never a shell command string. Prompt material stays private with mode `0600` and is omitted from public output.

2. Implement a versioned state machine: `queued -> claimed -> running -> success|failure|cancelled`. Use atomic writes plus lock, lease, and fencing identity so concurrent ticks and restart recovery cannot double-launch. Overdue queued jobs run once. Missing worktree, helper, or prompt becomes a durable failed-preflight outcome.

3. Install or reuse one bounded platform scheduler owner that calls `run-due`; do not create one sleeping process or recurring service per job. Test launchd, systemd, and cron rendering with fixtures.

4. Dispatch through `headless-runtime-helper.sh`. Generic jobs use a routine-scoped session key. Issue jobs validate the full issue, repo, and worktree contract or defer to existing manual worker dispatch when a fresh issue launch is intended.

5. Replace generated bare `opencode run` commands in `routine-helper.sh` while preserving existing flags and recurring schedules.

6. Refactor `_routine_execute` before adding lifecycle behavior: it is already about 91 lines. Extract agent launch and terminal-finalization helpers. The background wrapper may detach from Pulse but must wait for the headless process before terminal logging.

7. Extend logging compatibly. Existing `update ... --status success|failure` callers keep working. Non-terminal events must not increment totals, streaks, costs, or completed-run counts. Correlate job/session identity with existing dispatch outcomes where available.

8. Add fixture-clock, race, crash/restart, scheduler-render, privacy, and no-bare-runtime regression tests.

### Hazards and Compatibility

- **Concurrency/atomicity:** two ticks or hosts can observe the same job. Atomic claim plus lease/fencing is mandatory; PID files alone are insufficient.
- **Migration/rollback:** preserve recurring `rNNN` behavior and existing logs. New state is versioned and private. Uninstall must not mutate TODO routine definitions.
- **Mixed-version/backward compatibility:** deployed bundles can differ from source. Store schema and producer/runtime versions; unsupported readers diagnose rather than mutate.
- **Idempotency/retry:** repeated `run-due`, cancel, status, install, and restart recovery are safe. Retrying a failed launch uses a new bounded attempt identity and never replays terminal success.
- **Partial failure/recovery:** cover crash after claim, launch before PID persistence, exit before terminal write, missing worktree, provider outage, and reboot after due time.
- **Security/privacy:** scan prompts, keep private permissions, never persist credentials in argv/state/logs, and omit local paths, private basenames, and account data from public summaries.
- **Accuracy:** parse durations and ISO UTC deterministically, reject ambiguous timestamps, test calendar rollover, and report actual start lateness.

### Complexity Impact

- **Target function:** `_routine_execute` in `.agents/scripts/pulse-routines.sh`
- **Current line count:** approximately 91 lines, with a 100-line function threshold
- **Estimated growth without refactor:** 20 to 40 lines
- **Projected post-change:** over 110 lines
- **Action required:** extract agent dispatch and terminal-finalization helpers first.

Keep `aidevops.sh` changes to thin delegation because the root file is already above the shell file-size threshold.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-deferred-job-helper.sh
bash .agents/scripts/tests/test-aidevops-schedule-command.sh
bash .agents/scripts/tests/test-routine-tracking-updates.sh
bash .agents/scripts/tests/test-pulse-routines-selector.sh
bash .agents/scripts/tests/test-routine-systemd-calendar.sh
shellcheck .agents/scripts/deferred-job-helper.sh .agents/scripts/routine-helper.sh .agents/scripts/pulse-routines.sh .agents/scripts/routine-log-helper.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** deferred-job and CLI tests cover schema, claiming, cancel, privacy, and routing; routine tests cover terminal metrics; scheduler tests cover restart-capable rendering; lint covers Bash 3.2 and policy.
- **Broad verification trigger:** root CLI, setup scheduler, and shared routine lifecycle are framework-wide surfaces.
- **Broad verification command:** run required full framework gates only after focused tests and a WIP checkpoint pass.

### Recoverability Checkpoint

- [ ] Focused tests pass: the five focused commands above
- [ ] WIP commit created before broad gates: `wip: add durable deferred-job lifecycle`
- [ ] Evidence-triggered broad verification then run: required framework gates because root CLI and setup dispatch paths change

### Safety-Stop Recovery

- **Original objective:** durable one-shot scheduling and truthful completion activity without a parallel execution stack
- **Preserved user directions:** base the enhancement on the 13-hour continuation need from the #27777 session
- **Trigger and evidence:** not triggered
- **Completed and verified:** discovery and worker-ready brief only
- **Remaining acceptance criteria:** all implementation criteria below
- **Unsafe route not to repeat:** custom per-job sleepers or recurring cron workarounds presented as durable one-shot scheduling
- **Next safe route:** split state/scheduler, dispatch integration, and logging into sequential children if implementation cannot remain within complexity and time bounds
- **Resume condition:** clean linked worktree and fresh target-file discovery
- **Owner and status:** Build+ worker; not-triggered

### Files Scope

- `aidevops.sh`
- `.agents/scripts/deferred-job-helper.sh`
- `.agents/scripts/deferred-job-*.sh`
- `.agents/scripts/routine-helper.sh`
- `.agents/scripts/pulse-routines.sh`
- `.agents/scripts/routine-log-helper.sh`
- `.agents/scripts/setup/_routines.sh`
- `.agents/reference/routines.md`
- `.agents/workflows/routine.md`
- `.agents/scripts/commands/routine.md`
- `.agents/scripts/tests/test-deferred-job-helper.sh`
- `.agents/scripts/tests/test-aidevops-schedule-command.sh`
- `.agents/scripts/tests/test-routine-tracking-updates.sh`
- `.agents/scripts/tests/test-pulse-routines-selector.sh`
- `.agents/scripts/tests/test-routine-systemd-calendar.sh`

## Acceptance Criteria

- [ ] A user can queue one job with either `--at` or `--after`, inspect due and lifecycle state, and cancel before launch through the aidevops CLI.
- [ ] A queued job survives scheduler/runtime restart and runs at most once when overdue; concurrent due ticks cannot double-launch it.
- [ ] One-shot issue work launches only through canonical headless or manual-dispatch paths with validated issue, repository, and worktree scope.
- [ ] Scheduler-installed LLM routines contain no bare `opencode run` or bare Claude CLI invocation.
- [ ] Agent routine metrics remain non-terminal at launch and record actual success, failure, duration, and available usage only after terminal outcome.
- [ ] Existing recurring TODO routines, deterministic `run:` routines, and historical terminal update callers remain compatible.
- [ ] Private state, log, and prompt files use restrictive permissions; public output excludes prompt content, credentials, local paths, and private basenames.
- [ ] Focused tests, ShellCheck, and changed-file lint pass; a simulated crash and restart fixture proves recovery without replay.

## Context & Decisions

- Keep recurring definitions in `TODO.md`; do not add one-shot jobs as fake `rNNN` entries or another git-tracked recurring registry.
- Reuse the headless helper, manual worker ceremony, platform scheduler helpers, and terminal outcomes rather than building a parallel runtime.
- Leave the live #27777 scheduler untouched; migration would introduce duplicate-launch risk.
- Prior art: #22265 delivered immediate `aidevops launch-worker`; #17712 was closed after recurring ideas were decomposed into the current routines stack. This task fills the remaining one-shot and terminal-observability gap.
- Publication and release are out of scope.

## Relevant Files

- `.agents/reference/routines.md:4-54` — recurring contract and anti-patterns
- `.agents/scripts/routine-helper.sh:18-155` — recurring-only CLI and bare runtime command generation
- `.agents/scripts/routine-helper.sh:280-469` — scheduler installers and logs
- `.agents/scripts/pulse-routines.sh:89-188` — execution and premature success logging
- `.agents/scripts/routine-log-helper.sh:427-669` — terminal-only metric API
- `.agents/scripts/headless-runtime-worker.sh:1546-1561` — canonical terminal outcome
- `.agents/scripts/commands/launch-worker.md:15-80` — immediate issue worker ceremony
- `aidevops.sh:1277-1441` — thin command-routing precedent
- `.agents/scripts/tests/test-routine-tracking-updates.sh:161-199` — metric fixture
- `.agents/scripts/tests/test-aidevops-launch-worker-command.sh:37-73` — CLI test pattern

## Dependencies

- **Blocked by:** none
- **Blocks:** replacement of bespoke delayed continuation schedulers with a supported path
- **External:** no credentials, purchases, or third-party services

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Revalidate scheduler, runtime, routine, and outcome contracts |
| State and CLI | 3h | Durable queue, status, cancel, scheduler integration |
| Dispatch and logging | 2h | Headless routing and terminal lifecycle |
| Tests and docs | 2h | Fixture clock, races, recovery, platform rendering |
| **Total** | **8h** | Tier-thinking framework enhancement |
