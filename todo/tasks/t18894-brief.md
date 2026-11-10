<!-- aidevops:brief-schema=v2 -->
# t18894: SimpleX bot adapter for the session bus: replace the /sessions and /ask scaffolds

## Origin

- **Created:** 2026-11-08
- **Session:** opencode:interactive ses_e480fcfa0ffeCzemlBnZ5j1VBA (t18886 session bus, GH#37149, PR #37165, released in v3.39.136)
- **Created by:** ai-interactive
- **Conversation context:** The owner wants to drive OpenCode sessions from mobile chat apps, including SimpleX, and asked for self-testable follow-ups so they are not needed for testing. This is the SimpleX gateway from `todo/plans/opencode-session-bus.md` "Chat-app gateways", built on t18891 (trust) and t18892 (bindings and launch).

## What

The SimpleX bot's placeholder commands become session-bus commands:

- `/sessions`: the live session list. Redacted in groups; full in a direct chat with a verified owner contact.
- `/ask <target> <text>` and `/send <target> <text>`: bus messages with `--origin chat:simplex:<chatRef>`, where `chatRef` is `c<contactId>` for a direct chat or `g<groupId>` for a group.
- `/bind <target>` and `/unbind`: bind this chat to a session.
- `/launch <title> :: <task>`: owner only, through t18892.

A relay loop posts `outbox/simplex` replies back to their chat and acknowledges them.

## Why

`/ask` and `/sessions` in the SimpleX bot only return scaffold text today (`.agents/scripts/simplex-bot/src/commands.ts:69-86,274-288`). SimpleX is the owner's private, metadata-light mobile channel, so it is the natural place to reach a running session from a phone.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The contracts come from t18891 and t18892. This is command handlers, a CLI runner call and a relay loop in an existing TypeScript bot with an existing `bun test` suite.

## How (Approach)

- **Commands:** replace `askCommand` and `sessionsCommand` in `commands.ts`, and add `sendCommand`, `bindCommand`, `unbindCommand` and `launchCommand` to `BUILTIN_COMMANDS` (`commands.ts:295-319`). The `/help` text is built from that list. Rename the old local `/sessions` meaning only if something else uses it (search before changing).
- **CLI calls:** put the bus calls in a new `src/session-bus.ts` that builds argument arrays and runs them through `executeCommand` (`runner.ts:62-100`, `Bun.spawn` with an argument array). Never pass chat text through a shell. Send the text with `--text-file` (a 0600 temp file, removed afterwards) so text starting with `--` is never parsed as an option.
- **Actor:** resolve the SimpleX contact to an entity with `entity-helper.sh` using the `simplex` channel and the contact's identity. Unknown contacts are unverified (t18891 framing).
- **Relay:** a timer in `index.ts`, next to the existing startup wiring (`router.registerAll`, `index.ts:82`), reads `aidevops sessions outbox simplex --json`, sends each reply to its chat through the bot's existing send path, and acknowledges after success. Stop the timer on shutdown.
- **Exec boundary:** `/run` and the approval path (`exec-commands.ts:20-60`) stay unchanged. Bus commands never execute shell commands.

### Files to Modify

- EDIT: `.agents/scripts/simplex-bot/src/commands.ts`: real `/ask` and `/sessions`, plus `/send`, `/bind`, `/unbind` and `/launch`.
- NEW: `.agents/scripts/simplex-bot/src/session-bus.ts`: argument building, CLI calls and outbox relay.
- NEW: `.agents/scripts/simplex-bot/src/session-bus.test.ts`: argument arrays, chat references, redaction choice and relay ack, with an injected runner.
- EDIT: `.agents/scripts/simplex-bot/src/index.ts`: relay timer start and stop.
- EDIT: `.agents/services/communications/simplex.md`: document the commands.
- EDIT: `todo/plans/opencode-session-bus.md`: mark the SimpleX gateway step.

### Complete Write Surface

- **Callers/readers:** the bot router (`router.ts` `registerAll`) and `/help`, which lists `BUILTIN_COMMANDS`.
- **Writers/mutation paths:** bus writes only through the `aidevops sessions` CLI via `executeCommand` in `runner.ts`; temp text files under the bot's workspace, removed after each call.
- **Existing verification/tests:** `bun test` in `.agents/scripts/simplex-bot` (85 tests passing on 2026-11-08), and `bun run typecheck` (passing on 2026-11-08).
- **Schemas/config:** optional `sessionBus` block in the SimpleX bot config (`enabled`, default `false`); validate it in `config-validation.ts`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/simplex-bot/` with the rest of `.agents/scripts/`.
- **Migrations/backfills:** not applicable because the module is new-file-only and the config block is optional with a disabled default.
- **Cleanup/rollback paths:** `sessionBus.enabled=false` restores the scaffold replies; temp files are removed in a `finally` block.

### Implementation Steps

1. Check the deployed SimpleX config and docs for the contact identity field to use as the entity channel ID, and record the choice in `simplex.md`.
2. Write `session-bus.ts` with pure argument builders and an injected runner, then its tests.
3. Replace the scaffolds and add the new commands behind `sessionBus.enabled`.
4. Add the relay timer, then run `bun test` and `bun run typecheck`.
5. Run the scratch-bus check under Verification and record the output in the PR.

### Hazards and Compatibility

- **Concurrency/atomicity:** relay sends and acks one message at a time; a slow send delays the next tick rather than overlapping it.
- **Migration/rollback:** disabled by default; turning it off restores today's replies.
- **Mixed-version/backward compatibility:** against an `aidevops` without t18892, `/bind` and `/launch` return the CLI error text; `/ask`, `/send` and `/sessions` still work.
- **Idempotency/retry:** a failed send leaves the outbox message for the next tick; the ack happens only once.
- **Partial failure/recovery:** a CLI timeout is reported to the chat and logged with no message text; nothing is acknowledged.
- **Leak control:** pass relayed replies through the existing leak detector (`leak-detector.ts`) before sending to a group.

### Files Scope

- `.agents/scripts/simplex-bot/src/types.ts` — typed optional bus configuration.
- `.agents/scripts/simplex-bot/src/runner.ts` — safely drain and preserve complete outbox JSON without changing approval semantics.
- `todo/tasks/t18894-brief.md` — keep this scope correction in sync.
- `.agents/scripts/simplex-bot/src/commands.ts`
- `.agents/scripts/simplex-bot/src/session-bus.ts`
- `.agents/scripts/simplex-bot/src/session-bus.test.ts`
- `.agents/scripts/simplex-bot/src/index.ts`
- `.agents/scripts/simplex-bot/src/config-validation.ts`
- `.agents/services/communications/simplex.md`
- `todo/plans/opencode-session-bus.md`

### Verification Before Dispatch

```bash
bun test --cwd .agents/scripts/simplex-bot
bun --cwd .agents/scripts/simplex-bot run typecheck
```

- **Runtime evidence (self-test, no owner needed):** with `AIDEVOPS_SESSION_BUS_DIR` set to a scratch directory and one `opencode serve` session (t18886 "Live verification" setup), call `session-bus.ts` from `bun` with the real CLI runner and a recording send function. Show that:
  - `/ask` reaches the session, and its reply is relayed and acknowledged.
  - `/sessions` in group mode returns redacted rows.
- **Live SimpleX check:** a run against a real SimpleX CLI profile is not part of this task. It needs the owner's SimpleX setup. Record it as a post-merge check in the PR.
- **Surface mapping:** unit tests cover argument arrays, chat references, redaction and relay. The scratch-bus run covers the real CLI and the bus.
- **Broad verification trigger:** not required. The changes stay inside the SimpleX bot and its docs.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `bun test --cwd .agents/scripts/simplex-bot`
- [ ] WIP commit created before broad gates: `wip: t18894 simplex session bus commands`
- [ ] Evidence-triggered broad verification then run: not required

### Scope Boundaries

**Hard boundaries:** no changes to `/run`, `/approve` or the approval manager; no changes to the bus plugin; no new SimpleX profile, container or CI job; the old mailbox stays untouched.

**AI brief owner:** the interactive owner session of t18886 (marcusquinn).

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

## Acceptance Criteria

- [ ] With `sessionBus.enabled=true`, `/ask` and `/send` call `aidevops sessions ask|send` with `--origin chat:simplex:c<contactId>` (or `g<groupId>`), the resolved `--actor` and the text from a temp file.
- [ ] `/sessions` returns live sessions; group chats get the redacted listing.
- [ ] `/bind`, `/unbind` and `/launch` call the t18892 commands; `/launch` from a non-owner contact is refused by the CLI and the refusal is shown.
- [ ] The relay sends each `outbox/simplex` reply to its chat and acknowledges it only after a successful send.
- [ ] Regression: with `sessionBus` absent or disabled, `/ask` and `/sessions` keep today's replies; the existing 85 tests pass.
- [ ] Negative: chat text starting with `--` or containing shell metacharacters reaches the session as plain text and is never parsed as a CLI flag or run by a shell.

## Relevant Files

- `.agents/scripts/simplex-bot/src/commands.ts:69-86,274-319`
- `.agents/scripts/simplex-bot/src/runner.ts:62-100`
- `.agents/scripts/simplex-bot/src/index.ts:82`
- `.agents/scripts/simplex-bot/src/exec-commands.ts:20-60`
- `.agents/scripts/simplex-bot/src/leak-detector.ts`
- `todo/tasks/t18891-brief.md`, `todo/tasks/t18892-brief.md`
