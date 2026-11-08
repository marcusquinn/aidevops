<!-- aidevops:brief-schema=v2 -->
# t18892: Session bus channel bindings and per-task session launch on opencode serve

## Origin

- **Created:** 2026-11-08
- **Session:** opencode:interactive ses_e480fcfa0ffeCzemlBnZ5j1VBA (t18886 session bus, GH#37149, PR #37165, released in v3.39.136)
- **Created by:** ai-interactive
- **Conversation context:** The owner wants long-running sessions per chat channel and per-task sessions launched from a mobile chat app, for remote work and `opencode serve` hosts. They asked for every self-testable follow-up to be filed so they are not needed for testing. Design: `todo/plans/opencode-session-bus.md` "Origin, outbox and chat-gateway wiring" (channel binding, per-task launch, remote serve).

## What

Two gateway-neutral CLI capabilities that every chat adapter (Matrix t18893, SimpleX t18894, Buzz later) calls instead of re-implementing:

1. **Channel bindings:** `aidevops sessions bind <app> <channel> <target>`, `unbind <app> <channel>` and `bindings [--app <app>] [--json]` manage `bindings/<app>/<channel>.json` (reserved in the plan's storage layout). Any `send`/`ask` target may be `channel:<app>:<channel>`, which resolves through the binding. If the bound session is no longer live, the command exits with a distinct code (3) and says so. It never silently retargets.
2. **Per-task launch:** `aidevops sessions launch --server <url> --title "Issue #N: …" --bind <app>:<channel> --actor <entity-id> --text-file <path>` creates a session on an `opencode serve` instance, binds the channel to it, enables chat wakes for that session, and sends the task text through the inbox as a chat-origin `ask` from the verified actor. Presence then lists it like any other session. Launch requires a verified owner actor (t18891). Any other actor is refused.

## Why

Without bindings a gateway must remember session IDs per room itself, and each gateway would do it differently. Without a shared launch command, "start a session for this task from my phone" stays a Matrix-only path (`matrix-bot.mjs.template:168-194`) that bypasses the bus, its framing and its limits.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The launch path crosses the OpenCode server API and the trust layer, and the binding lifecycle (stale, rebound, deleted sessions) needs design decisions.

## How (Approach)

- **Target resolution:** `resolveTarget` (`.agents/plugins/opencode-aidevops/session-bus-targets.mjs:62`) handles session ID, handle, `#issue`, `PR#n`, repo and worktree. Add `channel:<app>:<channel>` resolved from the binding file, then require a live presence record for the bound session.
- **Binding store:** new helpers next to the inbox/outbox helpers, written with `writeJsonAtomic` (`session-bus-files.mjs:60`). Record shape: `{ v: 1, app, channel, session_id, actor, server, created_at, updated_at }`. App and channel names must be validated and path-safe (reuse `parseChatOrigin` rules).
- **Launch:** follow the existing server calls in `matrix-bot.mjs.template:173-183` (`POST /session` with a title). Then use the bus, not `/session/{id}/message`: write the binding, write the `chat-wake` opt-in (t18891), and send an `ask` with `--origin chat:<app>:<channel>` and the actor. Verify against the installed OpenCode server whether `POST /session` accepts a working directory. If it does not, document that a launch uses the server's own directory, and that `--server` must be a server started in the target repo or worktree.
- **CLI wiring:** add commands in `session-bus-cli-commands.mjs` and parse them in `session-bus-cli.mjs`. The shell wrapper `.agents/scripts/session-bus-helper.sh` needs no change unless it filters subcommands.
- **Retention:** `pruneBus` (`session-bus-files.mjs:122`) removes bindings whose session has had no presence and no pending messages for the retention period.

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/session-bus-targets.mjs`: `channel:` targets.
- NEW: `.agents/plugins/opencode-aidevops/session-bus-bindings.mjs`: binding store helpers.
- NEW: `.agents/plugins/opencode-aidevops/session-bus-launch.mjs`: server session creation plus bind, opt-in and first ask.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs` and `session-bus-cli.mjs`: `bind`, `unbind`, `bindings` and `launch`.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-files.mjs`: prune bindings.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-store.mjs`: re-export the new helpers (barrel).
- EDIT: `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`: binding and target cases, plus launch with an injected fetch.
- EDIT: `.agents/scripts/setup/modules/agent-deploy.sh`: add the new modules to the plugin freshness list.
- EDIT: `.agents/reference/session-bus.md`, `todo/plans/opencode-session-bus.md`: document the commands and exit codes.

### Complete Write Surface

- **Callers/readers:** gateways (t18893, t18894) through the CLI; `aidevops_sessions` tool target resolution (`session-bus-tool.mjs` `resolveOrThrow`) gains `channel:` targets automatically.
- **Writers/mutation paths:** the new binding store in `session-bus-bindings.mjs`, the launch command in `session-bus-launch.mjs` (server session creation, binding, opt-in, inbox message through `sendMessage` in `session-bus-messages.mjs:104`), and binding removal in `pruneBus` (`session-bus-files.mjs:122`).
- **Existing verification/tests:** `npm test --prefix .agents/plugins/opencode-aidevops`.
- **Schemas/config:** new `bindings/<app>/<channel>.json` record, `v: 1`. No change to message or presence records.
- **Generated/deployed mirrors:** `agent-deploy.sh` plugin freshness list.
- **Migrations/backfills:** not applicable because `bindings/` is new-file-only; no existing records change.
- **Cleanup/rollback paths:** `unbind`, retention prune; rollback is a code revert plus deleting `bindings/`.

### Implementation Steps

1. Confirm the installed OpenCode server API for session creation (title, directory) by reading the installed SDK types or calling a scratch `opencode serve`; record the result in the plan.
2. Add the binding store and `channel:` target resolution with path-safety validation.
3. Add `bind`/`unbind`/`bindings` with JSON output and the exit code 3 for a dead bound session.
4. Add `launch`, injecting `fetch` for tests. It refuses without a verified owner actor (t18891 trust helper), creates the session, then binds, opts in and asks.
5. Extend prune and the deploy freshness list. Then run unit tests and the live self-test.

### Hazards and Compatibility

- **Concurrency/atomicity:** two gateways binding the same channel race; the last atomic write wins and `bindings --json` shows it. `launch` writes the binding only after the server returns a session ID.
- **Migration/rollback:** additive directory; rollback deletes it.
- **Mixed-version/backward compatibility:** an older CLI does not know `channel:` targets and fails with "no live session matches", which is safe.
- **Idempotency/retry:** `bind` with the same target is a no-op; `launch` retried after a server error creates a new session only if the previous attempt returned no ID. Document that a partially failed launch is reported with the created session ID so the gateway can bind or delete it.
- **Partial failure/recovery:** if the inbox `ask` fails after session creation, launch prints the session ID and exit code 4, and leaves the binding in place so a retry `send channel:…` reaches it.
- **Network:** `--server` defaults to loopback; any non-loopback server URL must be `https` (the Matrix template applies the same rule at `:169`).

### Files Scope

- `.agents/plugins/opencode-aidevops/session-bus-targets.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-bindings.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-launch.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-files.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-store.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`
- `.agents/scripts/setup/modules/agent-deploy.sh`
- `.agents/reference/session-bus.md`
- `todo/plans/opencode-session-bus.md`

### Verification Before Dispatch

```bash
npm test --prefix .agents/plugins/opencode-aidevops
node --check .agents/plugins/opencode-aidevops/session-bus-launch.mjs
```

- **Runtime evidence (self-test, no owner needed):** with `AIDEVOPS_SESSION_BUS_DIR` set to a scratch directory, start `opencode serve` on a free loopback port with the worktree plugin (t18886 "Live verification" setup in `todo/plans/opencode-session-bus.md`), and a scratch verified owner entity. Run `launch`, then confirm:
  - The new session appears in `aidevops sessions list`.
  - It wakes and answers the task `ask`.
  - The reply appears in `aidevops sessions outbox <app> --json`.
  - `send channel:<app>:<channel>` reaches the same session.
  - After the session is deleted, `send channel:…` exits 3.
- **Surface mapping:** unit tests cover the binding store, target resolution, path safety and launch with injected fetch. The live run covers the real server API, presence, wake and outbox.
- **Broad verification trigger:** not required. The changes stay inside the plugin, its deploy list and its docs.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `npm test --prefix .agents/plugins/opencode-aidevops`
- [ ] WIP commit created before broad gates: `wip: t18892 bindings and launch`
- [ ] Evidence-triggered broad verification then run: not required

### Scope Boundaries

**Hard boundaries:** no chat-app adapter code; no cross-host bus (a remote `opencode serve` needs its own gateway on that host); the Matrix template's existing `!ai` path stays unchanged; the old mailbox stays untouched.

**AI brief owner:** the interactive owner session of t18886 (marcusquinn).

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

## Acceptance Criteria

- [ ] `bind`, `unbind` and `bindings --json` manage `bindings/<app>/<channel>.json`; app and channel names that are not path-safe are rejected.
- [ ] `send|ask channel:<app>:<channel>` delivers to the bound live session, and exits 3 with a clear message when the bound session is not live; it never picks another session.
- [ ] `launch` against a live `opencode serve` creates a titled session, binds the channel, and the task `ask` wakes it; the reply reaches the gateway outbox.
- [ ] `launch` without a verified owner actor is refused before any server call.
- [ ] Regression: existing targets (session ID, handle, `#issue`, `PR#n`, repo, worktree) resolve as before; the session-bus tests pass.
- [ ] Negative: a `channel:` target with `..`, `/` or empty parts is rejected, and a non-loopback `http://` server URL is refused.

## Relevant Files

- `.agents/plugins/opencode-aidevops/session-bus-targets.mjs:62`
- `.agents/plugins/opencode-aidevops/session-bus-files.mjs:42,60,122`
- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs:49,81,109`
- `.agents/scripts/matrix-bot.mjs.template:168-194`
- `todo/plans/opencode-session-bus.md` (Storage layout; Origin, outbox and chat-gateway wiring)
- `todo/tasks/t18891-brief.md` (trust layer this depends on)
