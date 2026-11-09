<!-- aidevops:brief-schema=v2 -->
# t18905: Session bus for workers: messageable headless workers, worker presence and pulse steering relay

## Origin

- **Created:** 2026-11-09
- **Session:** opencode:interactive ses_e41ae4936ffe8KO55XWGJ32s24 (Pulse and worker inter-session messaging)
- **Created by:** ai-interactive
- **Conversation context:** The owner asked whether pulse and workers could use the session bus (t18886) for throughput and self-healing, then approved changing the "workers cannot be messaged" non-goal: "i'm ok with updating that rule to allow same-user inter-messaging sessions", with the aim that "background workers should be just as effective at solving issues first-time as interactive sessions, and perseverant". The session agreed options 1-4 of its recommendation; this task covers 1, 2 and 4. Option 3 (interactive sessions see workers before claiming) extends t18895 (GH#37248).

## What

1. **Headless workers are messageable (same user, same machine).** `send` and `ask` to a worker (`kind: headless`) are accepted from the tool and CLI. Workers receive messages at their next tool result or turn, exactly like busy interactive sessions. Workers are never woken, get no poll timer and no `aidevops_sessions` tool (no schema cost); they answer asks through the CLI.
2. **`aidevops sessions reply <msg-id> <text>`.** A CLI reply for shells inside an OpenCode session (the worker's Bash tool), using the session ID from the shell environment. Asks delivered to a headless session say how to reply with the CLI.
3. **Worker presence.** Headless records gain `worker` (issue, repo, attempt, tier from the dispatch environment). Every root record gains `tool` (`name`, `since_epoch`) while a tool runs. `list`/`show` label workers and show a long-running tool.
4. **Worker finished notices.** `notify-when-idle` accepts a worker. When its run ends the subscriber gets one notice naming the worker, its last task and the issue to check.
5. **Pulse steering relay.** A new `worker-bus-relay-helper.sh relay`, run as an optional pulse stage, checks each live worker's issue at most every 2 minutes (one REST call when nothing changed) and sends that worker one pointer message when:
   - a maintainer adds a comment (collaborator author, not bot, not a worker/pulse machine comment; interactive-session comments count),
   - the issue is closed,
   - the issue gains `hold-for-review`.
   The message names the comment ID and the exact `gh` command to read it; it never copies GitHub text into the bus.

## Why

- Today a running worker cannot be corrected: a maintainer comment, a closed issue or a hold is seen only by the next dispatch, so the worker finishes the wrong approach or spends its slot on dead work. Interactive sessions get steering live; workers should too.
- `todo/plans/opencode-session-bus.md:76` recorded worker messaging as a non-goal to keep the tool schema out of worker requests. Delivery is a hook, not a tool, so workers can receive messages with no schema cost (`session-bus.mjs:200-204` already runs in worker processes; only `messageable` gates it).
- Orchestrating interactive sessions poll GitHub to learn when a worker finished; an idle notice is free.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Trust-boundary change (who may message workers and what relayed GitHub content may say) across the plugin, the CLI and a pulse stage.

## How (Approach)

- **Messageable workers:** `MESSAGEABLE_KINDS` gains `headless` (`session-bus-files.mjs:34`). `SessionBus` adds `wakeable = messageable && kind !== "headless"`; the poll timer, `deliverToIdle` and wakes require `wakeable` (`session-bus.mjs:72`, `session-bus-delivery.mjs:59-64`). `addTool` skips headless (`session-bus-plugin.mjs:40-42`).
- **CLI reply:** `replyCommand` next to `sendCommand` (`session-bus-cli-commands.mjs:110`), reusing `store.findReceived` and `store.sendReply` (`session-bus-messages.mjs:128`). `frameMessage(message, { cliReply })` gives the CLI form of the ask guidance (`session-bus-format.mjs:71-76`); the bus passes it for headless recipients.
- **Presence:** `workerContext(env)` from `WORKER_ISSUE_NUMBER`, `WORKER_REPO_SLUG`, `AIDEVOPS_ATTEMPT_ID`, `AIDEVOPS_DISPATCH_TIER` (set by `pulse-dispatch-worker-launch.sh:1762-1784`); added in `PresencePublisher.record` (`session-bus-presence.mjs:99-124`). `toolBefore` hook in V1 (`index.mjs:772`) and V2 (`v2.mjs:480`) records the running tool; `toolAfter` clears it.
- **Labelled shell sender:** `--sender <label>` for sessionless CLI senders (rejected inside a session); the sent/ key becomes `cli-<label>` so the relay has its own rate budget.
- **Relay:** new `.agents/scripts/worker-bus-relay-helper.sh` with `relay` and `status`; state in `~/.aidevops/.agent-workspace/state/worker-bus-relay/`. Pulse stage via `_pulse_run_optional_stage_with_timeout` (REST/GraphQL budget-deferred) after `reap_orphan_workers` (`pulse-wrapper.sh:1033-1036`).

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/session-bus-files.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/session-bus.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-plugin.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-presence.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-format.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-messages.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-v2.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/index.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/v2.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`
- NEW: `.agents/scripts/worker-bus-relay-helper.sh`
- EDIT: `.agents/scripts/pulse-wrapper.sh`
- EDIT: `.agents/reference/session-bus.md`
- EDIT: `todo/plans/opencode-session-bus.md`

### Complete Write Surface

- **Callers/readers:** `aidevops_sessions` tool, `aidevops sessions` CLI (`session-bus-helper.sh`), pulse cycle, worker tool results.
- **Writers/mutation paths:** `sendMessage` (`session-bus-messages.mjs:111`), presence writes (`session-bus-presence-store.mjs:97`), relay state files.
- **Existing verification/tests:** `npm test --prefix .agents/plugins/opencode-aidevops` (session bus suites), ShellCheck.
- **Schemas/config:** additive presence fields `worker`, `tool`; new env knobs `AIDEVOPS_WORKER_BUS_RELAY=0` (off), `WORKER_BUS_RELAY_MIN_INTERVAL` (default 120 s).
- **Generated/deployed mirrors:** `setup/modules/agent-deploy.sh` plugin freshness list only if a new plugin module is added.
- **Migrations/backfills:** none; older readers ignore new fields; older plugins keep rejecting sends to workers (the CLI checks the record's `messageable`, which older workers publish as false).
- **Cleanup/rollback paths:** the relay prunes state for sessions no longer live; a code revert restores read-only workers; `AIDEVOPS_WORKER_BUS_RELAY=0` stops the relay without a revert.

### Implementation Steps

1. Messageable workers, no wakes, no tool; CLI reply and frame guidance.
2. Presence `worker` and `tool`; list/show labels.
3. Worker idle notices.
4. Relay helper and pulse stage.
5. Docs, plan decision log; unit tests for the new paths; live run with a scratch bus and a real `opencode run`.

### Hazards and Compatibility

- **Trust:** relayed messages are pointers; only collaborator comments are relayed (`#aidevops:trust-boundary`); bus framing still says peer text carries no authority. Non-collaborator comment text is never pointed to.
- **Concurrency/atomicity:** delivery keeps the existing rename claim, so a message reaches a worker once; relay state is written temp+rename per worker; two relay runs at once can at worst send a duplicate pointer, which is harmless.
- **Migration/rollback:** additive presence fields and new state directory; rollback is a code revert (workers return to read-only) or `AIDEVOPS_WORKER_BUS_RELAY=0`.
- **Mixed-version/backward compatibility:** a worker on an older plugin publishes `messageable: false`, so sends are refused cleanly; older readers ignore `worker` and `tool`.
- **Idempotency/retry:** relay state records the last relayed comment ID, closed and hold notices; a failed send leaves state unchanged so the next run retries.
- **Partial failure/recovery:** relay errors never fail the pulse cycle (optional stage, `|| true`); a missing bus CLI or `gh` failure skips that worker for the run.
- **Noise:** one message per new comment batch, one per close, one per hold; per-worker minimum interval; the "closed" notice says to ignore it when the worker's own PR closed the issue.
- **API budget:** one `GET issues/N` per worker per interval; comments fetched only when `updated_at` moved; optional-stage budget deferral.

### Files Scope

- `.agents/plugins/opencode-aidevops/session-bus-files.mjs`
- `.agents/plugins/opencode-aidevops/session-bus.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-plugin.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-presence.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-format.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-messages.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-v2.mjs`
- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/v2.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-session-bus-v2.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-presence-store.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-compaction.mjs`
- `.agents/scripts/worker-bus-relay-helper.sh`
- `.agents/scripts/pulse-wrapper.sh`
- `.agents/scripts/pulse-budget-priority.sh` (classify `worker_bus_relay` as deferrable)
- `.agents/scripts/tests/test-pulse-graphql-budget-priority.sh`
- `.agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh`
- `.agents/reference/session-bus.md`
- `todo/plans/opencode-session-bus.md`
- `todo/tasks/t18905-brief.md`
- `TODO.md`

### Verification Before Dispatch

```bash
npm test --prefix .agents/plugins/opencode-aidevops
shellcheck .agents/scripts/worker-bus-relay-helper.sh .agents/scripts/pulse-wrapper.sh
```

- **Runtime evidence:** scratch `AIDEVOPS_SESSION_BUS_DIR`; start `opencode run` with worker env in a scratch repo; `aidevops sessions send` to it; confirm the framed message appears after its next tool result and that `aidevops sessions reply` from its shell reaches the asker: the asker's inbox when the ask came from a session, `outbox/cli` when it came from a sessionless shell (`ask --wait`).
- **Surface mapping:** unit tests cover messageability, no-wake, frame guidance, CLI reply and `--sender`, presence fields and idle notices; the relay is exercised against live GitHub reads with a seeded worker record in a scratch bus and state directory (baseline, label change, no repeat); the live `opencode run` covers real delivery.

### Scope Boundaries

**Hard boundaries:** no wakes for workers; no worker tool; no GitHub writes from the relay; no change to dispatch, kill or claim logic; relayed text is pointers only.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

## Acceptance Criteria

- [ ] `aidevops sessions send <worker>` succeeds and the worker sees the framed message at its next tool result; no wake is attempted.
- [ ] Headless processes get no `aidevops_sessions` tool and no poll timer.
- [ ] `aidevops sessions reply <ask-id> <text>` inside a session shell answers an ask; outside one it fails with a clear message.
- [ ] Headless presence carries `worker` from the dispatch env; records carry `tool` while a tool runs.
- [ ] `notify-when-idle` on a worker delivers one notice when the worker's run ends.
- [ ] Relay sends one pointer per new maintainer comment batch, close and hold; skips worker/pulse machine comments, bots and non-collaborators; respects the per-worker interval; `AIDEVOPS_WORKER_BUS_RELAY=0` disables it.
- [ ] Regression: existing session-bus tests pass; ShellCheck clean.

## Relevant Files

- `.agents/plugins/opencode-aidevops/session-bus.mjs:69-76,200-204`
- `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs:59-64`
- `.agents/plugins/opencode-aidevops/session-bus-files.mjs:34`
- `.agents/scripts/pulse-dispatch-worker-launch.sh:1762-1784`
- `.agents/scripts/pulse-wrapper.sh:1033-1036`
- `todo/plans/opencode-session-bus.md:76,161,192`
