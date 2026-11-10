<!-- aidevops:brief-schema=v2 -->
# t18898: Session bus for Buzz-hosted agents: labelled presence, remote provenance and safe delivery

## Origin

- **Created:** 2026-11-08
- **Session:** opencode:interactive ses_e480fcfa0ffeCzemlBnZ5j1VBA (t18886 session bus, GH#37149, PR #37165, released in v3.39.136)
- **Created by:** ai-interactive
- **Conversation context:** The owner wants aidevops usable from chat apps (SimpleX, Matrix, Buzz) and asked for every self-testable follow-up to be filed. Matrix and SimpleX adapters are t18893 and t18894. While scoping a Buzz adapter, code reading showed that Buzz-hosted agents are probably already session-bus endpoints. Their current defaults (wakes and `opencode` sender origin) were designed for local terminal sessions. This task makes them safe and visible first. Posting bus replies into Buzz channels stays with the Buzz plugin work in t18883 (GH#36976, owner-gated).

## What

Treat an OpenCode process started by the remote-interactive launcher (`AIDEVOPS_REMOTE_INTERFACE=1`, `remote_interactive_v1` overlay) as a remote-hosted bus endpoint:

1. **Labelled presence:** its presence record gains additive fields `interface` (for example `buzz`, from the overlay's `provider_ref`) and `agent` (the overlay agent ID). `aidevops sessions list`, `show` and the sidebar show "via Buzz agent …", so local sessions can tell a chat-driven agent from a terminal session.
2. **Remote provenance:** messages it sends carry origin `chat:<app>:<conversation>` (built from `provider_ref` and `conversation_ref`) instead of `opencode`. The existing rule that chat origins never wake a session (`session-bus-delivery.mjs:21-23`) then applies, so a chat-driven turn cannot wake the owner's local sessions. Its replies still arrive in its own inbox, because `sendReply` routes by sender session ID first (`session-bus-messages.mjs:123-128`).
3. **No wakes into it:** messages to a remote-hosted session wait for its next turn started from the chat app. They never trigger a bus wake, because a turn the chat app did not start has no channel to answer in (see Hazards).

## Why

Code-path evidence suggests remote-interactive Buzz agents already publish presence and get `aidevops_sessions`, with the same defaults as a terminal session:

- The restricted conversation profile returns early, without the bus (`index.mjs:366-368`). The remote-interactive profile continues to `createSessionBusHooks` (`index.mjs:445-451`).
- `opencode acp` is a messageable kind (`session-bus-files.mjs:34`, `session-bus-presence.mjs:23-30`).
- The launcher keeps HOME (`opencode-launcher-helper.sh:1770-1797`), so `busRoot` (`session-bus-files.mjs:42-45`) is the shared bus.

Two defaults are then wrong:

- **Wakes into the agent:** a woken turn runs inside the ACP process, but the Buzz plugin only posts the reply for the turn it started. `recordUpdate` keeps text for any known session (`.agents/plugins/buzz-aidevops/plugin.js:324-332`), and the plugin posts plain text as the reply (`.agents/plugins/buzz-aidevops/README.md:68-69`). The woken turn's output is therefore lost, or leaks into the next channel reply.
- **Wakes from the agent:** Buzz starts turns for the owner's messages and for messages the owner attested (`README.md:57-58`). With origin `opencode`, those turns can wake local owner sessions, which the chat trust model reserves for verified owner actors (`.agents/reference/team-interface-trust.md`, t18891).

None of this is verified live yet; step 1 confirms it before any change.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The design is decided here and reuses existing chat-origin and reply rules. The work is a plugin-option plumb-through, two delivery guards, display fields and one ACP self-test.

## How (Approach)

- **Detection:** `index.mjs:361` already loads the team-interface conversation. Pass `isRemoteInteractiveConversation(conversation)` (`team-interface-context.mjs:93`) and the overlay's agent ID and `interface_context` into `createSessionBusHooks` (`session-bus-plugin.mjs:17`), then into `createSessionBus`. Do the same in `v2.mjs:373` (`createV2SessionBusHooks` in `session-bus-v2.mjs:106`). The overlay's `context` property (`.agents/schemas/team-interface/opencode-launch-overlay-v1.schema.json:156`) holds the `interface_context` refs (definition at `:24-60`); confirm how the loader exposes it. Do not read `BUZZ_*` variables: the remote boundary strips them (`team-interface-remote-boundary.mjs:107`).
- **App and channel:** app = the `provider_ref` value after `provider:`, lower-cased and checked against the chat app part of `CHAT_ORIGIN` (`session-bus-files.mjs:38`). Channel = the `conversation_ref` value after `conversation:`, if it matches the channel part. Otherwise use the agent ID. If neither is valid, use app `remote` and channel `agent`. Never fall back to `opencode`.
- **Presence:** add `interface` and `agent` to the record in `PresencePublisher.record` (`session-bus-presence.mjs:99-117`), only when set, so local records stay byte-identical. Show them in `session-bus-format.mjs` rows and `show` output.
- **Sender:** `fromFor` (`session-bus.mjs:230-239`) returns the chat origin when the bus is remote-hosted.
- **Delivery:** `canWake` (`session-bus-delivery.mjs:55-58`) returns false when this process is remote-hosted. Pending messages still deliver through the user-turn path (`index.mjs:739-742`, `sessionBus.chatMessage`) and the tool-result path. Senders already see "delivered at the recipient's next turn" semantics for `info`. For an `ask`, add one line to the send result when the recipient record has `interface` set, for example `this session is driven from buzz; it answers on its next chat turn`.
- **Docs:** add a "Remote-hosted sessions" section to `.agents/reference/session-bus.md`, and one line to the Buzz plugin README "How a turn runs" list.

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/index.mjs`: pass the remote-interactive context to the bus hooks.
- EDIT: `.agents/plugins/opencode-aidevops/v2.mjs`: the same for OpenCode 2.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-plugin.mjs`: accept and forward the option.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-v2.mjs`: forward the option.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus.mjs`: remote flag, chat origin in `fromFor`.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-presence.mjs`: `interface` and `agent` fields.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs`: no wake into a remote-hosted session.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-format.mjs`: "via" label in rows, `show` and the ask notice.
- EDIT: `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`: unit cases for the three behaviours.
- EDIT: `.agents/reference/session-bus.md`: remote-hosted sessions section.
- EDIT: `.agents/plugins/buzz-aidevops/README.md`: one line on bus messages.
- EDIT: `todo/plans/opencode-session-bus.md`: Phase 3 table row for t18898.

### Complete Write Surface

- **Callers/readers:** `aidevops sessions list|show` (`session-bus-cli-commands.mjs`), the `aidevops_sessions` tool, the TUI sidebar (`tui-messages.mjs`), and t18895 coordination readers. All read presence and treat the new fields as optional.
- **Writers/mutation paths:** presence writes in `PresencePublisher` (`session-bus-presence.mjs`); message `from` built by `fromFor` (`session-bus.mjs:230`) and written by `sendMessage`/`sendReply` (`session-bus-messages.mjs:104,121`); wake claims in `deliverToIdle` (`session-bus-delivery.mjs:95`).
- **Existing verification/tests:** `npm test --prefix .agents/plugins/opencode-aidevops`; `node --test .agents/plugins/opencode-aidevops/tests/test-team-interface-remote-interactive-profile.mjs`; the ACP canary pattern in `.agents/scripts/tests/test-team-interface-buzz-installed-startup.mjs`.
- **Schemas/config:** presence record gains two optional fields at the same `v`; no message schema change (origin is already a free string validated by `CHAT_ORIGIN`).
- **Generated/deployed mirrors:** none; no new modules, so the `agent-deploy.sh` freshness list is unchanged.
- **Migrations/backfills:** not applicable because presence records are rewritten on every publish and messages expire after 7 days; nothing persisted needs conversion.
- **Cleanup/rollback paths:** revert the plugin change; `PresencePublisher` (`session-bus-presence.mjs`) rewrites each record on its next publish, so stale `interface` and `agent` fields disappear without a cleanup step.

### Implementation Steps

1. **Confirm the premise (self-test):** with `AIDEVOPS_SESSION_BUS_DIR` set to a scratch directory, start a remote-interactive ACP process the way the installed-startup canary does (`opencode-launcher-helper.sh remote-interactive --overlay … --dir … --session-id …`, or the canary's own spawn). Send ACP `initialize` and `session/new`, then confirm a presence record with `kind: "acp"` appears. Record the result in the plan. If no presence appears, stop. Update this brief and the issue with the evidence, because the premise is false.
2. Plumb the remote context through the hooks (V1 and V2).
3. Add presence fields and the chat-origin sender.
4. Add the `canWake` guard and the ask notice.
5. Unit tests, docs, then rerun step 1 and verify the three behaviours live.

### Hazards and Compatibility

- **Concurrency/atomicity:** no new shared files. Presence and message writes keep `writeJsonAtomic`.
- **Migration/rollback:** additive optional fields; rollback is a revert.
- **Mixed-version/backward compatibility:** an older CLI ignores unknown presence fields. An older local plugin treats `chat:` origins as non-waking, the same as the new code, so mixed versions are safe in both directions.
- **Idempotency/retry:** no new retries. Messages that skip a wake stay pending until the next chat-started turn or the 7-day retention prune.
- **Partial failure/recovery:** if the overlay context cannot be parsed, the process still counts as remote-hosted (origin `chat:remote:agent`, no wakes). It never falls back to local defaults.
- **Trust boundary:** mark the remote-hosted guard in `canWake` and `fromFor` with `#aidevops:trust-boundary`. Never derive the remote flag or origin from model-supplied tool arguments.
- **Overlap:** t18891 (GH#37244, in progress) changes chat-origin wake rules (verified-actor opt-in wakes) in the same files. Rebase on it and keep its opt-in from applying to remote-hosted senders, unless its verified-actor check passes.

### Files Scope

- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/v2.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-plugin.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-v2.mjs`
- `.agents/plugins/opencode-aidevops/session-bus.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-presence.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-format.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`
- `.agents/reference/session-bus.md`
- `.agents/plugins/buzz-aidevops/README.md`
- `todo/plans/opencode-session-bus.md`

### Verification Before Dispatch

```bash
npm test --prefix .agents/plugins/opencode-aidevops
node --test .agents/plugins/opencode-aidevops/tests/test-team-interface-remote-interactive-profile.mjs
node .agents/scripts/tests/test-team-interface-buzz-installed-startup.mjs
```

- **Runtime evidence (self-test, no owner needed):** step 1's scratch-bus ACP process. Then confirm:
  - `aidevops sessions list` shows the ACP session with its `via` label.
  - A message sent to it from a scratch local session does not wake it, and is delivered on the next ACP `session/prompt`.
  - An `ask` it sends reaches a scratch local session with a `chat:` origin, does not wake that session, and the reply arrives back in the ACP session's inbox.
- **Surface mapping:** unit tests cover option plumbing, origin construction, fallbacks and the `canWake` guard. The ACP run covers real presence, delivery and reply routing.
- **Owner check after merge (not a blocker):** in Buzz Desktop, ask an aidevops agent "which sessions are live?" and confirm it lists them, and that a local session sees it as "via Buzz".
- **Broad verification trigger:** not required. The changes stay inside the plugin, its tests and docs.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `npm test --prefix .agents/plugins/opencode-aidevops`
- [ ] WIP commit created before broad gates: `wip: t18898 remote-hosted session bus endpoints`
- [ ] Evidence-triggered broad verification then run: not required

### Scope Boundaries

**Hard boundaries:** no Buzz plugin code beyond the README line. Posting bus replies or notices into a Buzz channel, and listing sessions from Buzz without an agent turn, belong to the Buzz plugin under t18883 (owner-gated). Also excluded: changes to the restricted conversation profile; changes to chat ingest from gateways (t18891); and the old mailbox.

**AI brief owner:** the interactive owner session of t18886 (marcusquinn).

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

## Acceptance Criteria

- [ ] Step 1 evidence is recorded in `todo/plans/opencode-session-bus.md`: a remote-interactive ACP process publishes presence (or the task stops with the evidence).
- [ ] A remote-hosted session's presence has `interface` and `agent`, and `aidevops sessions list` shows the label. Local session records are unchanged.
- [ ] Messages from a remote-hosted session carry a `chat:` origin and never wake a local session; replies to its asks arrive in its own inbox.
- [ ] A message to a remote-hosted session never triggers a wake and is delivered on its next chat-started turn.
- [ ] Negative: a malformed or missing overlay context yields `chat:remote:agent` and no wakes, never `opencode`.
- [ ] Regression: local TUI and serve sessions keep their current wake, origin and presence behaviour; all session-bus tests pass.

## Relevant Files

- `.agents/plugins/opencode-aidevops/index.mjs:361-368,445-451,739-742`
- `.agents/plugins/opencode-aidevops/session-bus.mjs:230-239`
- `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs:21-23,55-58,95`
- `.agents/plugins/opencode-aidevops/session-bus-messages.mjs:104-138`
- `.agents/plugins/opencode-aidevops/session-bus-files.mjs:34,38,42-45`
- `.agents/plugins/opencode-aidevops/session-bus-presence.mjs:23-30,99-117`
- `.agents/plugins/opencode-aidevops/team-interface-context.mjs:61,93`
- `.agents/plugins/opencode-aidevops/team-interface-remote-boundary.mjs:95,107`
- `.agents/scripts/opencode-launcher-helper.sh:1770-1797`
- `.agents/plugins/buzz-aidevops/plugin.js:324-332`
- `.agents/plugins/buzz-aidevops/README.md:57-74`
- `.agents/schemas/team-interface/opencode-launch-overlay-v1.schema.json:24-60`
- `.agents/scripts/tests/test-team-interface-buzz-installed-startup.mjs`
- `todo/tasks/t18891-brief.md`, `todo/tasks/t18883-brief.md`
