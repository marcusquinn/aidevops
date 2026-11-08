<!-- aidevops:brief-schema=v2 -->
# t18891: Session bus chat ingest: scan, verified actor, opt-in owner wakes and redacted listing

## Origin

- **Created:** 2026-11-08
- **Session:** opencode:interactive ses_e480fcfa0ffeCzemlBnZ5j1VBA (t18886 session bus, GH#37149, PR #37165, released in v3.39.136)
- **Created by:** ai-interactive
- **Conversation context:** The owner tested the session bus between two live sessions and asked for every developable and self-testable follow-up to be filed, so they are not needed for testing until it is ready. The owner wants aidevops usable from chat apps (Matrix, SimpleX, Buzz), with long-running sessions per channel and per-task sessions launched from mobile. This task is the shared trust layer the gateways need. Design: `todo/plans/opencode-session-bus.md` section "Chat-app gateways (SimpleX, Matrix, Buzz) — design only", steps 1–3.

## What

Chat-origin messages entering the bus through `aidevops sessions send|ask --origin chat:<app>:<channel>` get a real trust decision instead of a fixed "sender unverified" label:

1. **Scan at ingest:** chat-origin text is scanned with `prompt-guard-helper.sh scan-stdin` before it is written to an inbox. A blocking verdict refuses the send with a clear error. A warning verdict is stored on the message and shown in the framing.
2. **Verified actor:** a new `--actor <entity-id>` flag is resolved through `entity-helper.sh`. The framing says "verified owner", "verified" plus the entity's display name, or "unverified" based on a confirmed channel link for that app and channel ID, never on display names.
3. **Opt-in owner wakes:** a chat-origin `ask` may wake an idle session only when the actor is a verified owner entity and the target session has opted in (`aidevops sessions chat-wake <target> on|off`, and the matching `aidevops_sessions` tool action). The default is off. All existing limits (rate, pending cap, hourly wakes, hop count) still apply.
4. **Redacted listing:** `aidevops sessions list --json --redact` returns rows without title, repo, branch, worktree and directory, for gateways posting into group rooms.

## Why

Today every chat-origin message is framed as unverified and can never wake a session (`session-bus-delivery.mjs:21-24`, `session-bus-format.mjs:70-71`). A gateway therefore cannot let the owner reach an idle session from a phone, and nothing scans chat text before it lands in a session transcript. Without this layer, each gateway would invent its own trust rules.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** This is trust-boundary work. It maps `team-interface-trust.md` profiles onto bus messages and must fail closed on unknown provenance.

## How (Approach)

- **Ingest path:** `sendCommand` (`.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs:81`) builds the chat sender in `chatSender` (`:19-22`) and calls `store.sendMessage` (`session-bus-messages.mjs:104`). Scan and resolve the actor there, before the write. Store the result on the message as `from.trust = { actor, verified, owner, scan }`, and keep `v: 1` readers working by treating a missing `trust` as unverified.
- **Framing:** `senderLabel`/`frameMessage` in `session-bus-format.mjs:70-88` render the chat label. Add the verified/owner state and any scan warning there, and keep the "carries no owner authority" wording for everything except a verified owner.
- **Wake rule:** `isWakeEligible` (`session-bus-delivery.mjs:21-24`) rejects every chat origin. Allow a chat-origin `ask` only when `from.trust.owner === true` and the recipient's opt-in flag is set. Store the opt-in per session under the bus root, for example `chat-wake/<sessionID>.json`, written through a store helper. It must survive restarts and be removed with the session's other files by `prune`.
- **Trust model:** follow `.agents/reference/team-interface-trust.md`: deterministic order at `:38-46`, authority ceilings at `:116-132`, and unknown provenance fails closed at `:141-153`. Entity verification uses `entity-helper.sh verify|link --verified` (usage header `:21-39`). Decide and document how the gateway's channel ID maps to the entity channel (for example `matrix` + `@user:server`).
- **Listing:** `listCommand` (`session-bus-cli-commands.mjs:49`). Add `--redact`, which drops private fields from both the JSON and the text output.

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`: scan, actor resolution, `--actor`, `--redact`, and the `chat-wake` command.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`: parse the new flags and command.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs`: owner wake rule.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-format.mjs`: trust framing.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-messages.mjs` or a new `session-bus-chat-trust.mjs`: trust record, scan and opt-in store helpers. Prefer a new module to keep files small.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`: `chat-wake` action, for the recipient session only.
- EDIT: `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`: trust, wake and redaction cases.
- EDIT: `.agents/reference/session-bus.md` and `todo/plans/opencode-session-bus.md`: document the contract.

### Complete Write Surface

- **Callers/readers:** the plugin delivery path (`session-bus.mjs` tick, `session-bus-delivery.mjs`), the V1 and V2 sidebars (`tui-messages.mjs`), compaction (`session-bus-compaction.mjs`) and `aidevops sessions inbox/outbox` all read message records. Each must tolerate the new optional `from.trust` field.
- **Writers/mutation paths:** `sendMessage` and `sendReply` (`session-bus-messages.mjs:104,121`), plus the new opt-in writer.
- **Existing verification/tests:** `npm test --prefix .agents/plugins/opencode-aidevops` (session-bus suite), `test-team-interface-trust-schema.mjs`.
- **Schemas/config:** message record `v: 1` with an additive optional field. No version bump unless a reader cannot ignore the field.
- **Generated/deployed mirrors:** a new plugin module must be added to the plugin freshness list in `.agents/scripts/setup/modules/agent-deploy.sh` (as t18886 did for its modules).
- **Migrations/backfills:** none. Old messages lack `trust` and are treated as unverified.
- **Cleanup/rollback paths:** `pruneBus` removes opt-in files for sessions with no presence after retention. Rollback is a code revert; queued messages stay readable.

### Implementation Steps

1. Read `team-interface-trust.md` and `entity-helper.sh verify/link`, and decide the actor-to-entity mapping per app (record it in `reference/session-bus.md`).
2. Add the trust module: scan through `prompt-guard-helper.sh scan-stdin` with a timeout, resolve the actor, and return `{ actor, verified, owner, scan }`, failing closed.
3. Call it from `sendCommand` for chat origins before `sendMessage`. Add `--actor` and `--redact` to the CLI parser.
4. Add the opt-in store (`chat-wake/<sessionID>.json`), the `chat-wake` CLI command and the tool action. Extend `pruneBus` to remove stale opt-ins.
5. Change `isWakeEligible` to allow a chat-origin `ask` only for a verified owner with opt-in, and update the framing.
6. Add unit cases, then run the live self-test under Verification and record the results in the PR.

### Hazards and Compatibility

- **Concurrency/atomicity:** write the opt-in and messages with the existing atomic JSON writer (`writeJsonAtomic`). Delivery keeps claiming by rename.
- **Migration/rollback:** no stored data changes; `trust` is additive. Rollback is a code revert, and messages written with `trust` stay readable by the old code.
- **Mixed-version/backward compatibility:** an older plugin reading a newer message ignores `trust` and keeps refusing chat wakes, which is safe. A newer plugin treats a message without `trust` as unverified.
- **Idempotency/retry:** re-running `chat-wake on` is a no-op. A gateway retrying a send gets a new message ID; dedupe stays the gateway's job (Matrix already claims events durably).
- **Partial failure/recovery:** a scan that errors or times out refuses the send and never delivers unscanned chat text. An entity lookup failure means unverified. A crash between scan and write leaves nothing behind.
- **Secrets:** never log message text or entity channel IDs at info level.

### Files Scope

- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-format.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-messages.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-chat-trust.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-files.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`
- `.agents/scripts/setup/modules/agent-deploy.sh`
- `.agents/reference/session-bus.md`
- `todo/plans/opencode-session-bus.md`

### Verification Before Dispatch

```bash
npm test --prefix .agents/plugins/opencode-aidevops
node --check .agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs
```

- **Runtime evidence (self-test, no owner needed):** set `AIDEVOPS_SESSION_BUS_DIR` to a scratch directory and `XDG_DATA_HOME`/`HOME` overrides for an isolated entity DB if `entity-helper.sh` supports one, else use a scratch entity created and deleted by the test. Start two `opencode serve` sessions with the worktree plugin, following the t18886 live verification in `todo/plans/opencode-session-bus.md` "Live verification". Then check each of these:
  - An unverified `ask --origin chat:matrix:!room` reaches a busy session framed "unverified" and does not wake an idle one.
  - A text containing a known injection canary from `prompt-guard-helper.sh` tests is refused or flagged.
  - A verified-owner `ask` wakes an idle session only after `chat-wake <session> on`.
  - `list --json --redact` has no title, repo, branch, worktree or directory.
- **Surface mapping:** unit tests cover the trust record, wake rule, opt-in store and redaction. The live run covers CLI ingest, delivery framing and the wake path.
- **Broad verification trigger:** not required. The changes stay inside the plugin and its docs.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `npm test --prefix .agents/plugins/opencode-aidevops`
- [ ] WIP commit created before broad gates: `wip: t18891 chat ingest trust`
- [ ] Evidence-triggered broad verification then run: not required

### Scope Boundaries

**Hard boundaries:** no gateway or adapter code (t18893, t18894); no channel bindings or session launch (t18892); no change to session-to-session (non-chat) delivery or limits; the old mailbox stays untouched. Chat messages never get capabilities beyond conversation: no tool or approval authority comes from chat text.

**AI brief owner:** the interactive owner session of t18886 (marcusquinn).

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

## Acceptance Criteria

- [ ] Chat-origin `send`/`ask` text is scanned before it is stored; a blocking verdict refuses the send with exit code 1 and a message naming the reason; a scan error also refuses.
- [ ] `--actor <entity-id>` with a confirmed channel link for that app is framed as verified (and as owner when the entity is the owner); any other actor, or none, is framed as unverified.
- [ ] A chat-origin `ask` wakes an idle session only when the actor is a verified owner and the session opted in with `chat-wake on`; otherwise it waits for the next turn. Rate, pending, hourly-wake and hop limits still apply.
- [ ] `aidevops sessions list --json --redact` omits title, repo, branch, worktree and directory.
- [ ] Regression: session-to-session messages, CLI (non-chat) sends and the outbox behave as before; the existing session-bus tests pass unchanged except where they encoded "chat never wakes".
- [ ] Negative: an `--actor` whose verified link is for a different app or channel ID (for example a SimpleX link used with `chat:matrix:…`) is framed unverified and never wakes; display names in the message text never change the framing.

## Relevant Files

- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs:19-22,41,49,81`
- `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs:21-24`
- `.agents/plugins/opencode-aidevops/session-bus-format.mjs:70-88`
- `.agents/plugins/opencode-aidevops/session-bus-messages.mjs:104,121`
- `.agents/reference/team-interface-trust.md:38-46,116-132,141-153`
- `.agents/scripts/entity-helper.sh:21-39`
- `todo/plans/opencode-session-bus.md` (Chat-app gateways section)
