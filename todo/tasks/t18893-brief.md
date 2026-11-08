<!-- aidevops:brief-schema=v2 -->
# t18893: Matrix bot adapter for the session bus: room commands, bound rooms and outbox relay

## Origin

- **Created:** 2026-11-08
- **Session:** opencode:interactive ses_e480fcfa0ffeCzemlBnZ5j1VBA (t18886 session bus, GH#37149, PR #37165, released in v3.39.136)
- **Created by:** ai-interactive
- **Conversation context:** The owner wants to drive OpenCode sessions from mobile chat apps, with one long-running session per channel and per-task sessions launched from chat. They asked for self-testable follow-ups so they are not needed for testing. This is the Matrix gateway from `todo/plans/opencode-session-bus.md` "Chat-app gateways", built on the trust layer (t18891) and the bindings and launch commands (t18892).

## What

The existing Matrix bot (`matrix-bot.mjs.template`) gains a session-bus bridge:

- **Room commands** for allowlisted users: `!sessions` (redacted list in rooms with more than two members, full list in a direct room), `!ask <target> <text>`, `!send <target> <text>`, `!bind <target>`, `!unbind`, and `!launch <title> :: <task text>` (owner only).
- **Bound rooms:** in a room bound with `!bind`, a normal prefixed message (`!ai …`) becomes `aidevops sessions ask channel:matrix:<roomId>` instead of a runner dispatch. Unbound rooms keep today's runner path unchanged.
- **Outbox relay:** replies from sessions in `outbox/matrix/` are posted to their room and then acknowledged with `aidevops sessions outbox matrix --ack <id>`.

All bus calls go through the `aidevops sessions` CLI with `--origin chat:matrix:<roomId>` and `--actor <entity-id>` from the bot's existing entity resolution.

## Why

The Matrix bot can already create a fresh OpenCode session per prompt (`matrix-bot.mjs.template:168-194`), but it cannot reach a running session, see what sessions exist, or receive a session's reply later. The bus provides all three, and this bridge connects them, so the owner can work with live sessions from a phone.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The bus, trust and binding contracts are fixed by t18891 and t18892. This task is command parsing, CLI calls and a relay loop in an existing bot, following existing ingress patterns.

## How (Approach)

- **New pure module** `.agents/scripts/matrix-session-bus-bridge.mjs`: `parseBusCommand(text, prefix)`, `busArgsFor(command, { roomId, actorEntityId })`, and `relayOutbox({ runCli, sendText, now })`. Inject `runCli` (spawn of `aidevops sessions … --json`) and `sendText` so the module needs no network or homeserver in tests.
- **Bot wiring:** in the `room.message` handler (`matrix-bot.mjs.template:383-460`), after `normalizeMatrixIngress` accepts the event and `store.claimEvent` claims it (`:396-398`), check `parseBusCommand` first and route bus commands to the bridge. Keep the per-room `activeDispatches` guard. Entity resolution (`resolveEntityCached`) provides the actor entity ID for `--actor`.
- **Relay timer:** add a relay interval next to the compaction interval (`:373-380`), every 5 s, matching the bus poll. Post with `client.sendText` and acknowledge only after a successful send. Stop it in `shutdown()` (`:501`).
- **Import path:** the generated bot imports helpers from the deployed scripts directory (`matrix-bot.mjs.template:15`, `../../agents/scripts/…`). Use the same path for the bridge.
- **Redaction:** count room members with the SDK (`getJoinedRoomMembers`). Use `aidevops sessions list --json --redact` (t18891) unless the room has exactly two members (the bot and one user).
- **Docs:** add a "Session bus" section to `.agents/services/communications/matrix-bot.md` covering the commands, bound rooms and the owner-only launch.

### Files to Modify

- NEW: `.agents/scripts/matrix-session-bus-bridge.mjs`: command parsing, CLI arguments and outbox relay.
- EDIT: `.agents/scripts/matrix-bot.mjs.template`: route bus commands, relay timer, shutdown.
- NEW: `.agents/scripts/tests/test-matrix-session-bus-bridge.mjs`: parser, argument and relay cases with an injected `runCli` and `sendText`, following `test-team-interface-matrix-ingress.mjs`.
- EDIT: `.agents/services/communications/matrix-bot.md`: document the commands.
- EDIT: `todo/plans/opencode-session-bus.md`: mark the Matrix gateway step.

### Complete Write Surface

- **Callers/readers:** `matrix-dispatch-helper.sh` `generate_bot_script` copies the template (`matrix-dispatch-helper.sh:191-193`); the bot process imports the bridge at runtime.
- **Writers/mutation paths:** bus writes happen only through the `aidevops sessions` CLI (`send`, `ask`, `bind`, `unbind`, `launch`, `outbox --ack`); the bot's own `store.claimEvent`/`addMessage` stay as they are.
- **Existing verification/tests:** `node .agents/scripts/tests/test-team-interface-matrix-ingress.mjs`, `node .agents/scripts/tests/test-team-interface-matrix-adapter.mjs`, `node .agents/scripts/tests/test-matrix-session-store.mjs`.
- **Schemas/config:** optional `sessionBus` block in the Matrix bot config (`enabled`, default `false`; `relayIntervalSeconds`, default 5); existing configs keep working.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`; `matrix-dispatch-helper.sh` regenerates the bot from the template on start.
- **Migrations/backfills:** not applicable because the bridge is new-file-only and the config block is optional with a disabled default.
- **Cleanup/rollback paths:** `sessionBus.enabled=false` restores today's behaviour; the relay timer stops in `shutdown()`.

### Implementation Steps

1. Write `matrix-session-bus-bridge.mjs` with pure parsing and argument builders, then the relay function with injected I/O.
2. Add the focused test file covering each command, a bound-room `!ai` message, an unbound-room `!ai` message (no bus call), relay success with ack, and relay send failure without ack.
3. Wire the template behind `sessionBus.enabled`, add the relay timer and the shutdown cleanup.
4. Document the commands; run the existing Matrix tests and the new test.
5. Run the scratch-bus check under Verification and record the output in the PR.

### Hazards and Compatibility

- **Concurrency/atomicity:** the per-room `activeDispatches` guard and the durable `claimEvent` stay in front of bus calls, so a redelivered Matrix event never sends twice. Relay acknowledges only after `sendText` succeeds.
- **Migration/rollback:** disabled by default; turning it off restores the runner-only path.
- **Mixed-version/backward compatibility:** a bot running against an older `aidevops` without t18892 gets a CLI error for `bind`/`launch`, which the bridge reports in the room; plain `ask` and `send` still work.
- **Idempotency/retry:** a relay retry after a failed send posts the reply once more at most; ack happens once.
- **Partial failure/recovery:** a CLI timeout (10 s) is reported in the room and logged; nothing is acknowledged. A failed `launch` reports the session ID returned by t18892 so the owner can `!bind` it.
- **Trust:** never pass room text as CLI flags. Text goes through `--text-file` or stdin, so a message starting with `--` cannot inject options.

### Files Scope

- `.agents/scripts/matrix-session-bus-bridge.mjs`
- `.agents/scripts/matrix-bot.mjs.template`
- `.agents/scripts/tests/test-matrix-session-bus-bridge.mjs`
- `.agents/services/communications/matrix-bot.md`
- `todo/plans/opencode-session-bus.md`

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-matrix-session-bus-bridge.mjs
node .agents/scripts/tests/test-team-interface-matrix-ingress.mjs
node .agents/scripts/tests/test-matrix-session-store.mjs
node --check .agents/scripts/matrix-session-bus-bridge.mjs
```

- **Runtime evidence (self-test, no owner needed):** with `AIDEVOPS_SESSION_BUS_DIR` set to a scratch directory and one `opencode serve` session (t18886 "Live verification" setup), call the bridge functions from a short Node script using the real `aidevops sessions` CLI as `runCli` and a recording `sendText`. Show that:
  - `!ask` reaches the session and its reply comes back through the relay.
  - The outbox is empty after the ack.
- **Live homeserver check:** a real Synapse or Conduit run is not part of this task. It needs either an existing configured homeserver or the owner's approval for a local container. Record it as a post-merge check in the PR.
- **Surface mapping:** unit tests cover parsing, arguments and relay. The scratch-bus run covers the real CLI and the bus.
- **Broad verification trigger:** not required. The changes stay in the Matrix bot and its docs.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `node .agents/scripts/tests/test-matrix-session-bus-bridge.mjs`
- [ ] WIP commit created before broad gates: `wip: t18893 matrix session bus bridge`
- [ ] Evidence-triggered broad verification then run: not required

### Scope Boundaries

**Hard boundaries:** no changes to the bus plugin (t18891, t18892 own those); no new homeserver, container or CI job; the unbound-room `!ai` runner path and the session store schema stay unchanged; the old mailbox relay stays untouched.

**AI brief owner:** the interactive owner session of t18886 (marcusquinn).

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

## Acceptance Criteria

- [ ] With `sessionBus.enabled=true`, `!sessions`, `!ask`, `!send`, `!bind`, `!unbind` and `!launch` map to the matching `aidevops sessions` CLI calls with `--origin chat:matrix:<roomId>` and the resolved `--actor`.
- [ ] In a bound room, `!ai <text>` becomes an `ask` to `channel:matrix:<roomId>`; in an unbound room it uses the existing runner path with no bus call.
- [ ] The relay posts each `outbox/matrix` reply to its room and acknowledges it only after a successful send.
- [ ] `!sessions` in a room with more than two members uses the redacted listing.
- [ ] Regression: with `sessionBus` absent or disabled, the bot behaves exactly as before; the existing Matrix tests pass.
- [ ] Negative: a message whose text starts with `--` or contains newlines and flag-like tokens is passed as text, never as CLI options.

## Relevant Files

- `.agents/scripts/matrix-bot.mjs.template:15,168-194,373-380,383-460,501`
- `.agents/scripts/team-interface-matrix-ingress.mjs:160-221`
- `.agents/scripts/matrix-dispatch-helper.sh:191-193`
- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs:109-120`
- `todo/tasks/t18891-brief.md`, `todo/tasks/t18892-brief.md`
