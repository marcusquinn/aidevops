<!-- aidevops:brief-schema=v2 -->
# t18888: OpenCode 2 support for the session bus: run the bus from v2.mjs and add the sidebar Messages section

## Origin

- **Created:** 2026-11-08
- **Session:** opencode:interactive (t18886 build, GH#37149)
- **Created by:** ai-interactive
- **Conversation context:** t18886 shipped the session bus (presence, `aidevops_sessions`, `aidevops sessions`, delivery, wakes, V1 sidebar) for OpenCode 1.x. GH#37149 also asked for the sidebar "Messages" section in V2. The V2 server plugin does not run the bus, so a V2 sidebar alone would always be empty. The V2 part was split out into this task.

## What

OpenCode 2 sessions take part in the session bus the same way OpenCode 1.x sessions do:

1. The V2 server plugin (`v2.mjs`) runs `createSessionBus`: it publishes root-session presence, polls inboxes, delivers messages and wakes idle sessions.
2. V2 sessions get the `aidevops_sessions` tool when the process is messageable (TUI, `serve`, ACP).
3. The V2 TUI (`v2-plugin/tui.mjs`) shows the **Messages** sidebar section directly under **Prompts**, with the same rows and the same `AIDEVOPS_TUI_MESSAGES=false` switch as V1.

## Why

Without this, V2 sessions are invisible to `aidevops sessions list` and cannot send or receive messages, so agents in V2 still ask the user to relay between sessions.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The V2 host exposes different hook and client surfaces from V1. Delivery needs equivalents of `chat.message`, `tool.execute.after`, `session.promptAsync` and `tui.showToast`, and those must be verified against the V2 host before wiring.

## How (Approach)

- V1 reference wiring: `.agents/plugins/opencode-aidevops/index.mjs` creates the bus at 446 (`createSessionBus({ client, directory, kind })`, `session-bus.mjs:551`), registers the tool at 467 (`if (sessionBus.messageable) …`), and calls `sessionBus.chatMessage` (741), `sessionBus.toolAfter` (793) and `sessionBus.handleEvent` (838).
- V2 server plugin: `.agents/plugins/opencode-aidevops/v2.mjs` builds tools at 367 (`createSchemaGatedTools`), adds them to the V2 editor at 459 (`addV1ToolsToV2Editor`), and feeds events at 274 and 550 (`handleEvent`). Add the bus there. Unknown until verified: which V2 hooks can append to a tool result or a user message, and whether the V2 client exposes `session.promptAsync` and `tui.showToast`. If a channel has no V2 equivalent, deliver through the remaining channels and record the gap in the PR.
- V2 TUI: follow `setupPromptsSlot` (`v2-plugin/tui.mjs:303`; slot registration `tui-prompts.mjs:152`, `prepend: "sidebar.content"`). Reuse `tui-messages.mjs` (`messageRows`, `rootSessionID`, `isMessagesEnabled`, `MESSAGES_POLL_MS`) so V1 and V2 show the same rows. Place it after Prompts.
- Keep `session-bus-store.mjs` unchanged unless V2 needs a new process `kind`; `processKind` is at `session-bus.mjs:38`.

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/v2.mjs`: create the bus, register the tool, connect the hooks.
- EDIT: `.agents/plugins/opencode-aidevops/v2-plugin/tui.mjs`: add the Messages slot after Prompts.
- EDIT: `.agents/plugins/opencode-aidevops/tui-messages.mjs`: add a V2 slot setup next to the shared row builder, if that is the cleanest home (as `tui-prompts.mjs` does for Prompts).
- EDIT: `.agents/plugins/opencode-aidevops/tests/test-tui-prompts.mjs` or a new focused test only if slot order needs a regression check (pattern: lines 117–131).
- EDIT: `.agents/reference/session-bus.md` and `.agents/tools/opencode/opencode.md`: drop the "OpenCode 1.x only" scope notes.

### Complete Write Surface

- **Callers/readers:** `aidevops sessions` (`session-bus-cli.mjs`), the `aidevops_sessions` tool (`session-bus-tool.mjs`), the V1 sidebar (`v1-tui/tui.tsx` via `tui-messages.mjs`) and compaction (`compaction.mjs` `getSessionBusState`) all read the bus files. They need no change: V2 sessions write the same records.
- **Writers/mutation paths:** the only new writer is the bus instance created in `v2.mjs`, which writes through `session-bus-store.mjs` (presence, inbox claims, sent copies, subscriptions, outbox), the same code V1 uses.
- **Existing verification/tests:** `tests/test-session-bus.mjs` (store, runtime, tool, CLI, V1 rows) and `tests/test-tui-prompts.mjs:117-131` (V2 slot registration pattern). Runtime path: `aidevops sessions list` plus a live V2 session.
- **Schemas/config:** no schema change. Record `v: 1` stays. `AIDEVOPS_TUI_MESSAGES` and `AIDEVOPS_SESSION_BUS_DIR` keep their meaning.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/plugins/opencode-aidevops/` to `~/.aidevops/agents/plugins/`. `v2.mjs`, `v2-plugin/tui.mjs` and `tui-messages.mjs` are already in the freshness list in `.agents/scripts/setup/modules/agent-deploy.sh:317-343`.
- **Migrations/backfills:** no stored data changes. V2 writes the same `v: 1` records into the directory layout that V1 already creates (`session-bus-store.mjs` `busRoot`), so nothing is migrated or backfilled.
- **Cleanup/rollback paths:** presence is removed on `session.deleted` and process exit and swept by `list` when the pid is dead. Rollback is reverting the `v2.mjs` and `v2-plugin/tui.mjs` edits; V2 sessions then simply stop appearing.

### Implementation Steps

1. Read the installed V2 host's plugin types (locate them with `fd` under the V2 install; do not guess paths) and record which hooks can append to a user message or a tool result, and whether the V2 client has `session.promptAsync`, `session.status` and `tui.showToast`.
2. Decide the delivery channels for V2 from step 1. If one is missing, keep the others and note the gap in the PR and in `reference/session-bus.md`.
3. In `v2.mjs`, create the bus once per process next to the existing tool setup (around 367), add `aidevops_sessions` to the tool set when `sessionBus.messageable`, and route events and hooks to `handleEvent`, `chatMessage` and `toolAfter` as `index.mjs` does.
4. In `v2-plugin/tui.mjs`, register a Messages slot after `setupPromptsSlot(api)` (line 303) that renders `messageRows` for the current root session every `MESSAGES_POLL_MS`.
5. Run the plugin tests, then the live check under Verification.

### Hazards and Compatibility

- **Concurrency/atomicity:** V1 and V2 processes can hold the same session. Delivery already claims by rename (`session-bus-store.mjs`), so only one process delivers each message. Keep using the store API and do not write files directly.
- **Migration/rollback:** no stored data changes, so rollback is a code revert. Messages already queued stay valid for V1.
- **Mixed-version/backward compatibility:** V1 and V2 plugins read and write the same `v: 1` records. A V2 process must not start a second bus in the same process if V1 hooks are also loaded; check the existing V1/V2 load guard in `v2.mjs` before wiring.
- **Idempotency/retry:** presence writes are idempotent, and wakes are rolled back on failure (`session-bus.mjs` wake path), so a retried wake does not double-deliver.
- **Partial failure/recovery:** if the V2 client lacks `promptAsync`, wakes fail and messages wait for the next turn; the runtime logs the failure through `warn()`. A crash leaves undelivered files, which any process delivers when the session resumes.

### Files Scope

- `.agents/plugins/opencode-aidevops/v2.mjs`
- `.agents/plugins/opencode-aidevops/v2-plugin/tui.mjs`
- `.agents/plugins/opencode-aidevops/tui-messages.mjs`
- `.agents/plugins/opencode-aidevops/session-bus.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-tui-prompts.mjs`
- `.agents/reference/session-bus.md`
- `.agents/tools/opencode/opencode.md`
- `todo/plans/opencode-session-bus.md`

### Verification Before Dispatch

```bash
npm test --prefix .agents/plugins/opencode-aidevops
node --check .agents/plugins/opencode-aidevops/v2.mjs
```

- **Runtime evidence:** run an OpenCode 2 host (`aidevops opencode-sandbox` installs versions in isolation). With `AIDEVOPS_SESSION_BUS_DIR` pointing at a scratch directory, start one V2 session and one V1 session. `aidevops sessions list` shows both. A V1 `ask` to the idle V2 session wakes it, and its reply reaches V1. The V2 sidebar shows the Messages rows under Prompts.
- **Test setup note:** an isolated `XDG_CONFIG_HOME` that loads the plugin from a repo worktree cannot resolve `@opencode-ai/plugin`, so no tools register (`tool-schema.mjs` logs `V1 schemas unavailable`). Link the deployed plugin's `node_modules/@opencode-ai/plugin` into the worktree plugin directory for the test, then remove the link (it is gitignored).
- **Surface mapping:** `npm test` covers the shared store and runtime (concurrency, idempotency, partial-failure rollback) and the V1 regression criterion. `node --check` covers `v2.mjs` syntax. The live V1↔V2 run covers the `v2.mjs` writer path, the V2 presence, messaging and wake criteria, the headless criterion (start one `opencode run` and confirm it is listed read-only with `list --all`), and mixed-version compatibility. A V2 TUI session covers `v2-plugin/tui.mjs` and the sidebar criterion; the owner checks it visually.
- **Broad verification trigger:** Not required. Changes stay inside the plugin and its docs.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `npm test --prefix .agents/plugins/opencode-aidevops`
- [ ] WIP commit created before broad gates: `wip: t18888 V2 session bus`
- [ ] Evidence-triggered broad verification then run: not required (plugin-only change)

### Scope Boundaries

**Hard boundaries:** no change to message format, limits, trust framing or storage layout; V1 behaviour unchanged; no chat-app gateway work (Phase 3); old mailbox untouched.

**AI brief owner:** the interactive owner session of t18886 (marcusquinn).

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

## Acceptance Criteria

- [ ] V2 root sessions appear in `aidevops sessions list` with repo, branch and state, and disappear when their process dies.
- [ ] A V2 session can `send`, `ask` and `reply` with V1 sessions; an `ask` to an idle V2 session wakes it, or the PR documents which V2 channel is missing and how messages arrive instead.
- [ ] The V2 sidebar shows the Messages section under Prompts; `AIDEVOPS_TUI_MESSAGES=false` hides it.
- [ ] Headless V2 processes publish read-only presence and get no `aidevops_sessions` tool.
- [ ] Regression: V1 sessions behave as before (V1 session-bus tests pass; V1 sidebar unchanged), and a session open in both a V1 and a V2 process gets each message exactly once.
- [ ] Negative: a V2 session never wakes for `info` or chat-origin messages, and `send` to a headless V2 session is refused.

## Relevant Files

- `.agents/plugins/opencode-aidevops/index.mjs:446,467,741,793,838`
- `.agents/plugins/opencode-aidevops/session-bus.mjs:38,551`
- `.agents/plugins/opencode-aidevops/v2.mjs:274,367,459,550`
- `.agents/plugins/opencode-aidevops/v2-plugin/tui.mjs:303`
- `.agents/plugins/opencode-aidevops/tui-prompts.mjs:152`
- `.agents/plugins/opencode-aidevops/tui-messages.mjs:12-41`
- `todo/plans/opencode-session-bus.md`
