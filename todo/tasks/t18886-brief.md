# t18886: OpenCode session bus: presence and session-to-session messages

## Origin

- Created: 2026-11-07, interactive session (owner-approved plan).
- Plan: `todo/plans/opencode-session-bus.md` (added by this task's PR). Related captures: #37145, #37146. Follow-up: #37157 (t18888, OpenCode 2 support).

## What

Add an OpenCode → OpenCode session bus to the aidevops OpenCode plugin:

1. **Presence:** every live interactive OpenCode root session publishes a ~1KB status record (title, handle, repo, worktree, branch, linked issue/PR, busy/idle/permission, current in-progress todo). `aidevops sessions list` (CLI) and the `aidevops_sessions` tool (`list`/`show`) show what every session is doing.
2. **Messages:** `send` (info), `ask` (expects reply), `reply`, `inbox`, `notify-when-idle` between sessions.
3. **Delivery:** busy recipient → appended to its next tool result (`tool.execute.after`); next user turn → synthetic part on the user message (`chat.message`); idle recipient + `ask`/reply-to-own-ask/requested idle notice → wake with `client.session.promptAsync` (owner decision 1a). TUI toast on arrival.
4. **Sidebar:** an optional "Messages" section in the right sidebar directly under "Prompts" (OpenCode 1.x `v1-tui/tui.tsx`), listing recent sent/received bus messages; disable with `AIDEVOPS_TUI_MESSAGES=false`. OpenCode 2 moved to #37157, because the V2 server plugin does not run the bus yet.
5. **Chat-app wiring (enablement only):** message `origin` field and an outbox so a later SimpleX/Matrix/Buzz gateway can list sessions, send to a live session as an untrusted external origin (never wakes), and collect replies from `outbox/<gateway>/`. Gateways themselves are out of scope.

## Why

Agents repeatedly ask the user to relay messages between parallel OpenCode sessions or to find out what another session is doing. The old mailbox (`mail-helper.sh`) never delivered to live sessions: 1,740 messages, all unread; recipients are folder/branch names, not sessions; no plugin delivery hook. A same-machine bus removes the human relay at negligible storage and context cost, and gives chat apps one contract for remote/mobile use of long-running OpenCode (and OpenCode server) sessions.

## How (as built)

- Storage under `~/.aidevops/.agent-workspace/state/session-bus/` (override `AIDEVOPS_SESSION_BUS_DIR`): `presence/`, `inbox/<session>/` with `delivered/`, `sent/<sender>/`, `subs/<session>/`, `outbox/<app>/`. Atomic temp+rename writes. Liveness is pid plus process start time, implemented in `session-bus-store.mjs`.
- Modules in `.agents/plugins/opencode-aidevops/`: `session-bus-store.mjs` (storage, resolution, limits, framing; re-exports `session-bus-{files,presence-store,targets,messages,inbox,format}.mjs`), `session-bus.mjs` (presence and delivery runtime, 5s poll; uses `session-bus-{presence,identity,events,delivery,client}.mjs`), `session-bus-tool.mjs` (tool), `session-bus-cli.mjs` + `session-bus-cli-commands.mjs` (CLI), `tui-messages.mjs` (sidebar rows). Wired in `index.mjs` via `session-bus-plugin.mjs` (events, `chat.message`, `tool.execute.after`, tool registration) and `compaction.mjs` via `session-bus-compaction.mjs` (open asks). The split keeps each new file under the Qlty smell thresholds that the regression gate enforces.
- CLI: `aidevops sessions …` → `_main_dispatch_opencode_tools` in `aidevops.sh` → `.agents/scripts/session-bus-helper.sh` → `session-bus-cli.mjs`.
- Chat origin: `--origin chat:<app>:<channel>` (the brief's draft said `external:<name>`).
- Docs: `.agents/reference/session-bus.md`, Messages note in `.agents/tools/opencode/opencode.md`. No `.agents/AGENTS.md` pointer: the file is at its 24,000-byte ratchet, and the tool description carries the "do not ask the user to relay" rule.
- Old mailbox untouched (retirement is a separate owner decision).

### Files Scope

- `.agents/plugins/opencode-aidevops/compaction.mjs`
- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-client.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-compaction.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-delivery.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-events.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-files.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-format.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-identity.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-inbox.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-messages.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-plugin.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-presence-store.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-presence.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-store.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-targets.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`
- `.agents/plugins/opencode-aidevops/session-bus.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`
- `.agents/plugins/opencode-aidevops/tui-messages.mjs`
- `.agents/plugins/opencode-aidevops/v1-tui/tui.tsx`
- `.agents/reference/session-bus.md`
- `.agents/scripts/session-bus-helper.sh`
- `.agents/scripts/setup/modules/agent-deploy.sh`
- `.agents/tools/opencode/opencode.md`
- `TODO.md`
- `aidevops.sh`
- `todo/PLANS.md`
- `todo/plans/opencode-session-bus.md`
- `todo/tasks/t18886-brief.md`
- `todo/tasks/t18888-brief.md`

## Safety

- Peer and external messages are framed as non-user authority: cannot approve merges, releases, destructive ops, secrets, settings or scope changes.
- Limits: 2,000-char text cap; 10 sends/min per sender; 50 pending per inbox; 6 wakes/hour per session; `hops ≥ 3` never wakes; only asks take replies; headless workers visible but not messageable; external origins never wake.
- Retention 7 days; files 600 / dirs 700; no network listener.

## Acceptance Criteria

- [ ] `aidevops sessions list` from a shell and `aidevops_sessions {action:"list"}` from a session both show all live interactive OpenCode sessions with repo/branch/state; killed sessions disappear.
- [ ] `ask` from session A to idle session B wakes B; B's `reply` reaches A (waking A if idle).
- [ ] `send` to a busy session appears in its next tool result, framed as peer (non-user) content.
- [ ] Info sent to an idle session is delivered with its next user turn and does not wake it.
- [ ] Rate, queue, wake and hop limits enforced; ambiguous targets return candidates.
- [ ] TUI toast on arrival; sidebar "Messages" section under "Prompts" shows recent traffic (OpenCode 1.x; OpenCode 2 in #37157).
- [ ] `aidevops sessions send --origin chat:<app>:<channel>` delivers without wake; replies land in `outbox/<app>/`.
- [ ] Plugin tests (`npm test` in the plugin dir) and ShellCheck on touched shell pass.

## Verification

- Live: OpenCode sessions in different worktrees; exercise list/send/ask/reply/notify-when-idle; `SIGKILL` one and confirm presence cleanup and inbox survival. Results: `todo/plans/opencode-session-bus.md` "Live verification".
- `npm test --prefix .agents/plugins/opencode-aidevops`; `shellcheck aidevops.sh .agents/scripts/session-bus-helper.sh`.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** new cross-process runtime contract inside the OpenCode plugin with wake/loop safety; owner is building it interactively.
