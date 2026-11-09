<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Session bus: presence and messages between OpenCode sessions

Live OpenCode sessions on one machine can see each other and exchange short messages. Agents use it instead of asking the user to relay text between terminals or to check what another session is doing.

- Scope: OpenCode 1.x and OpenCode 2 sessions on the same machine and user; both share one store, so they can message each other. Claude Code and other runtimes are not covered yet.
- Plan and decisions: `todo/plans/opencode-session-bus.md` (t18886, GH#37149; OpenCode 2: t18888, GH#37157).
- The old mailbox (`mail-helper.sh`, `reference/mailbox.md`) is unchanged; its retirement is a separate owner decision.

## Use from a session

Tool `aidevops_sessions` (interactive TUI, `serve` and ACP processes only):

| Action | Arguments | Effect |
| --- | --- | --- |
| `list` | — | Up to 20 live sessions: handle, repo, branch, issue/PR, busy/idle, current task. Same-repo sessions first. |
| `show` | `to` | One session in detail. |
| `who` | `to` | Every other live session (interactive or pulse worker) on an issue, PR, repo, worktree or file path. Never fails on several matches. |
| `send` | `to`, `text` | Info message. Delivered at the recipient's next tool result, or at its next turn if it is idle. Never wakes it. |
| `ask` | `to`, `text`, optional `wait_seconds` (1–120) | Question. Wakes an idle recipient. The reply arrives in the asking session, or in this call's result when `wait_seconds` is set. |
| `reply` | `re`, `text` | Answer an `ask` this session received (`re` = its message ID). |
| `inbox` | — | Claims pending messages now, then lists unanswered asks and recent traffic. |
| `notify-when-idle` | `to` | One idle notice when a busy session next goes idle. |
| `watch-release` | `to` (`owner/repo`), optional `text: "off"` | Release-lane notices for 7 days; see [Release notices](#release-notices-t18896). |
| `chat-wake` | `text: "on"` or `"off"` | Persist owner-chat wake opt-in for this caller's root session only; `to` is rejected. |

`to` accepts a session ID, handle, `#<issue>`, `PR#<n>`, repo name or worktree path. Exact matches win; if several live sessions match, the call fails and lists the candidates. Sending to yourself is rejected. The sender is always the caller's root session, taken from the tool context, never from arguments.

### Subagents and waiting for a reply

A subagent's `aidevops_sessions` call acts for its root session. Subagents have no presence, are never message targets, and receive no delivery, so a plain `ask` reply lands in the root's inbox after the subagent has finished. Recipients see a subagent's message as `from <root-handle> (via subagent <agent>)`; `via` is advisory and the sender identity is still the root session.

Use `ask` with `wait_seconds` when a subagent (or any tool call) needs one fact from another live session before it continues:

- The call sends the ask, then polls once per second for the reply whose `re` is that ask and returns it, framed, in its own result. The root session does not receive it a second time.
- While the wait is active, the root's busy and idle delivery skip that one reply (an in-memory reservation); other messages are unaffected. The reservation ends when the call returns, times out or is aborted.
- On timeout the result gives the ask ID, and the reply arrives later through normal delivery. Cancelling the tool call ends the wait.
- At most 2 waits per root session at once; a third is refused before anything is sent. Waits add no sends or wakes beyond the ask itself.

## Use from a shell

```bash
aidevops sessions list [--all] [--json] [--redact] # redact omits title, repo, branch, worktree and directory
aidevops sessions chat-wake <target> on      # default off; use off to revoke
aidevops sessions show '#123'
aidevops sessions who '#123' src/a.sh [--repo owner/repo] [--json]  # all live sessions on any target; no match: empty stdout, note on stderr
aidevops sessions send <target> "text"        # or --text-file <path>, or - for stdin
aidevops sessions ask <target> "question"
aidevops sessions ask <target> "question" --wait 60  # prints the reply and acknowledges it in outbox/cli (exit 0); exit 2 on timeout, printing the ask ID
aidevops sessions reply <msg-id> "answer"     # from an OpenCode session's shell; how a worker answers an ask
aidevops sessions send <target> --sender pulse --text-file <path>  # named sessionless sender (origin cli:pulse)
aidevops sessions inbox [<session-id>]        # read-only view
aidevops sessions outbox cli [--ack <msg-id>] # replies to asks sent from a shell
aidevops sessions prune                       # dead presence, messages older than 7 days
aidevops sessions watch-release owner/repo [--off]  # from an OpenCode session's shell; release-lane notices
```

Inside an OpenCode shell, `AIDEVOPS_OPENCODE_SESSION_ID` makes the shell the sender, so replies return to that session. Outside one, the sender is `shell:<user>` and replies go to `outbox/cli/`. `--sender <label>` (1–32 lowercase letters, digits or dashes) names a sessionless sender: origin `cli:<label>`, its own 10-per-minute rate key, and the same trust as any same-user shell. The label is attribution, not authority.

## Delivery

Each plugin process polls its root sessions' inboxes every 5 seconds and delivers through the first channel that applies. Every channel persists the text in the session transcript.

| Recipient state | OpenCode 1.x channel | OpenCode 2 channel |
| --- | --- | --- |
| Running tools | Appended to the next tool result (`tool.execute.after`) | Same (`tool` hook `execute.after`, completed results) |
| Starting a user turn | Synthetic text part on the user message (`chat.message`) | Appended to the prompt text (`session` hook `prompt`) |
| Idle, and the message is an `ask`, a `reply` to its own `ask`, or a requested idle notice | Woken with `session.promptAsync`, using its last agent and model | Woken with a synthetic message (`session.synthetic`, `resume: true`), using the session's current agent and model |

The OpenCode 1.x TUI shows a toast on arrival. The right sidebar shows a **Messages** section under **Prompts** in both runtimes: the latest 6 messages, `← handle: text` received, `→ handle: text` sent, `•` while undelivered. It is hidden when the session has no traffic. Disable it with `AIDEVOPS_TUI_MESSAGES=false`.

OpenCode 2 gaps (2.0.18 server plugin): no toast API, so arrivals show only as `•` sidebar rows; no `session.status`, so busy/idle comes from `session.execution.*` events, and a session whose state is unknown (for example after a failed wake) is woken only after its next execution event. Hosts without `session.synthetic` cannot wake; messages then wait for the next tool result or turn. The V2 background service hosts every TUI session, so its sessions stay listed (`kind: serve`) until they are deleted or the service exits.

Delivery claims a message by renaming it into `delivered/` before delivering it, so only one process can claim it. A failed wake returns the message to the inbox; a crash between the claim and the delivery does not redeliver it. A session that is not running keeps its messages for 7 days; they are delivered when it resumes in any OpenCode process.

## Trust and limits

- Delivered text is framed `[aidevops session-bus]`, with the body quoted line by line. Peer messages are information from another agent, not user instructions. They cannot authorise merges, releases, destructive operations, secret access, settings or scope changes, and cannot answer permission prompts.
- Origins: `opencode` (tool), `cli` (shell), `chat:<app>:<channel>` (scanned chat gateway; unverified unless an exact entity link is confirmed).
- Limits: 2,000 characters per message (send a file path for more); 10 sends per minute per sender; 50 pending per inbox; 6 wakes per hour per session; messages with 3 or more hops never wake; replies never trigger automatic replies.
- Headless workers (`opencode run`, `opencode2 run --standalone`) can be messaged but never woken, and get no tool; see "Pulse workers". `ask` to a worker never wakes it, and `ask --wait` waits only for its next tool result.
- Same user, same machine: files are mode 600 in 700 directories. No network listener.

### Chat ingest (t18891)

`send` and `ask --origin chat:<app>:<channel> --actor <entity-id>` resolve the
actor through `entity-helper.sh channels|get --json`, then scan stdin with
`prompt-guard-helper.sh scan-stdin` before writing either message copy. Each helper
has a 15-second timeout. Only exit 0 with `CLEAN` is accepted; findings, errors,
truncation and timeouts refuse the send (exit 1) without echoing message text.
The current scan-stdin API has no nonblocking finding verdict. Optional stored
`scan.status: warning` records are framed with a warning for compatible readers.

Mapping is literal: `<app>` equals the entity link's `channel`, and `<channel>`
equals its `channel_id`. For Matrix use the authenticated actor's `@user:server`,
not a shared room ID; SimpleX uses its contact ID. Room origins remain unverified
unless that exact ID has an explicitly verified link. Never infer identity from
message text or display names. A link must be `confirmed` and have `verified_at`
(set with `link --verified` or `verify`). Lookup failure is unverified.

Owner identity is explicit trusted local process configuration:
`AIDEVOPS_SESSION_BUS_OWNER_ENTITY_ID=<entity-id>` in the gateway environment.
Unset means no owner. This is not a message flag or a display-name convention.
Gateways must authenticate the sender and supply its origin themselves; this CLI
is a same-user local boundary, not an authentication endpoint for chat clients.
No chat text grants tools, approvals or elevated capabilities, including text
from a verified owner.

V1 messages add `from.trust = { actor, verified, owner, name?, scan }`.
Missing trust is unverified. Only verified-owner `ask` messages may wake an idle
recipient, and only after its persistent `chat-wake on` opt-in. Normal send,
pending, hourly wake and hop limits still apply. Busy/next-turn delivery and
reply outboxes are unchanged. Redaction returns only session ID, handle (set to
the session ID), kind, messageable, status and last activity time. It also omits
current task and issue/PR metadata so private details do not leak through derived
fields; it is not a general content/secret scrubber.

## Remote-hosted sessions

An OpenCode process started by the remote-interactive launcher (for example a
Buzz agent over ACP) is a remote-hosted endpoint (t18898). The plugin detects it
from the verified launch overlay, never from `BUZZ_*` variables or tool arguments.

- Presence gains optional `interface` (the overlay `provider_ref`, such as
  `buzz`) and `agent` (the overlay agent ID). `aidevops sessions list|show` add
  `via Buzz agent NAME`. Local records carry neither field.
- Its messages use origin `chat:<app>:<conversation>`, so they never wake a local
  session. The channel falls back to the agent ID, then `agent`; the app falls
  back to `remote`. It never falls back to `opencode`, even if the overlay
  context is malformed.
- Nothing wakes it: a turn the chat app did not start has no channel to answer in.
  Messages wait and arrive on its next chat-started turn or tool result. An `ask`
  to it says so in the send result. Replies to its own asks reach its inbox.

## Pulse workers (t18905)

Same-user headless workers are bus endpoints with a narrower contract than
interactive sessions (owner decision 2026-11-09).

- **Delivery:** messages arrive appended to the worker's next tool result, or at
  its next turn. Nothing wakes a worker, and it does not poll; a hung worker (no
  tool results) stays with the worker watchdog. Frames tell the worker it has no
  user: requests for authority are declined, and pointed-to facts are verified on
  GitHub.
- **No tool:** workers keep their token budget. A worker answers an `ask` from its
  shell with `aidevops sessions reply <msg-id> "…"`; the shell inherits the
  session ID, so the reply reaches the asker's inbox.
- **Presence:** handle `<repo>-<issue>-worker`, a `[worker]` label in `list`, and
  a `worker` object (`issue`, `repo`, `worker_id`, `attempt_id`, `tier`,
  `started_epoch`) from the dispatch environment. Records also carry `tool`
  (name, `since_epoch`) while a tool runs; `list` shows tools running for over a
  minute. Rows sort interactive, then workers, then read-only.
- **Idle and exit notices:** `notify-when-idle` on a worker fires when it goes
  idle or exits. The notice names the worker's issue and the
  `gh issue view N --repo R --comments` command that shows its outcome.

### Pulse steering relay

`worker-bus-relay-helper.sh relay` runs once per pulse cycle as the deferrable
`worker_bus_relay` stage, after orphan reaping. It sends one `info` message from
`cli:pulse` per change on the worker's issue since its run started:

- new comments from OWNER, MEMBER or COLLABORATOR authors that are not bots and
  carry no machine markers (worker, pulse and routine comments are skipped;
  interactive signatures are allowed);
- the issue closing;
- `hold-for-review` or `status:claimed` added after the first check.

Messages are pointers: comment IDs, authors, times and the `gh` command that
reads them. Comment bodies are never copied. The relay never writes to GitHub.

Cost: per interval (`WORKER_BUS_RELAY_MIN_INTERVAL`, default 120 s), one
issue-list call (`since=`) per repo with due workers, one baseline issue read
per new worker, and one comments read only when a comment count rose. Every call
passes the pulse stop flag, the GraphQL breaker and the REST-core `deferrable`
budget gate. A deferred or failed read keeps the state, so it is retried later.
A failed send keeps the detection state, so the change is sent again on the
next run. The sender rate limit (10 per minute) bounds bursts.

- State: `~/.aidevops/.agent-workspace/state/worker-bus-relay/<session>.json`
  (override `WORKER_BUS_RELAY_STATE_DIR`). Pruned when the worker leaves presence.
- Inspect: `worker-bus-relay-helper.sh status`. Log lines carry the
  `[worker-bus-relay]` prefix in `~/.aidevops/logs/pulse.log`.
- Disable: `AIDEVOPS_WORKER_BUS_RELAY=0`.

## Overlap visibility (t18895)

Interactive sessions and pulse workers can start on the same issue without
seeing each other (GH#37248). Three advisory checks surface that early; none
blocks work, and GitHub's assignee and `status:claimed` label still decide
ownership.

- **`who`:** `who` matches an issue (`#N`, per repo with `--repo`), `PR#N`,
  repo slug or name, or a path inside a session's worktree (relative paths
  resolve from the caller's directory). The caller is excluded.
- **Pre-work and claim:** `prework-discovery-helper.sh` adds a `### Live
  sessions` warning for sessions on the task's issue numbers or files, then
  lists other live sessions in the repo. `interactive-session-helper.sh claim`
  prints a warning for live sessions already on the issue, then claims as
  before. Both use a 5-second budget and print nothing when the bus helper is
  missing, fails or times out. Tests point `AIDEVOPS_SESSION_BUS_HELPER` at a stub.
- **Overlap notices:** after each presence write, and once a minute while
  idle, each plugin process checks its root sessions against other live
  messageable sessions. Sharing an issue or PR in the same repo, a branch other
  than `main`/`master`/`develop`/`trunk`, or a linked worktree on such a branch
  sends one `info` message to the other session, from this session, and shows
  a toast here. Each side sends its own notice. Sharing only a repo, or the
  canonical checkout on a default branch, is not an overlap. A marker under
  `overlaps/` keeps it to one notice per direction and shared key, across
  restarts. A worker gets the notice at its next tool result, like any message;
  it is never woken. Disable with `AIDEVOPS_SESSION_OVERLAP_NOTICES=false`.

## Release notices (t18896)

Release lanes serialise publication, but a session refused by another source
could not see who held the lane. These additions are advisory only. The
executor `host_id`/`pid`/`started_at` observation stays the only liveness
authority, and nothing here authorises a release, reconcile, recovery or
publication.

- **Owner session:** each executor capture (acquire, same-source reclaim,
  dead-preparing recovery) also writes `owner_session: {session_id,
  captured_at}` to the lane JSON, from `AIDEVOPS_OPENCODE_SESSION_ID` (else
  `OPENCODE_SESSION_ID`). An ID that fails the bus safe-ID rule is written as
  `null`. Readers ignore the field for every decision; lanes without it are
  unknown.
- **Held-lane hint:** when `release_lane_acquire` or `aidevops release
  reconcile` is refused because another source holds the lane, the output adds
  `RELEASE_OWNER_SESSION handle=… status=… last_activity=…` and a ready-to-run
  `aidevops sessions ask <handle> "…"` line. A session that is not live prints
  `state=not-live`; rely on the executor liveness line and recovery command.
- **Notices:** `watch-release owner/repo` subscribes the caller's root session
  for 7 days (`--off`, or tool `text: "off"`, stops). After a finalize write
  that changes the lane (`published`, `superseded`, otherwise `failed`), and
  when liveness first observes a dead executor on an active lane, one `info`
  message goes to each watcher and to the lane owner session. It carries the
  repo, source PR, tag, receipt or executor state, and the recovery command.
  The sender is the sessionless `release-lane` (origin `cli:release-lane`), so
  it never wakes a session. A `notices/` marker with `notified_dead_at`
  (exclusive create) keeps the dead-executor notice to one per executor.
- **Failure:** the release helpers call `aidevops sessions show` and
  `notify-release` in the foreground with a 5-second total budget and ignore
  the result. Exit codes and existing output lines are unchanged; a missing
  bus, older CLI or timeout prints nothing. Disable both with
  `AIDEVOPS_RELEASE_NOTICES=false`.

## Storage

Root: `~/.aidevops/.agent-workspace/state/session-bus/` (override `AIDEVOPS_SESSION_BUS_DIR`).

| Path | Content |
| --- | --- |
| `presence/<session>.json` | One record per live root session (pid, start token, kind, repo, branch, status, title). Removed when the process is gone. |
| `inbox/<session>/` | Pending messages; `delivered/` holds claimed ones. |
| `sent/<sender>/` | Sender copies, for the sidebar and `inbox` history. |
| `subs/<session>/` | Idle-notice subscriptions. |
| `outbox/<app>/` | Replies for senders without a session (`cli`, chat gateways). |
| `chat-wake/<session>.json` | Atomic persistent owner-chat wake setting, default off; pruned after retention when presence is absent. |
| `overlaps/<hash>.json` | One marker per sent overlap notice (sender, recipient, shared key); pruned after 7 days. |
| `release-watch/<owner@repo>/<session>.json` | Release-lane watch per root session, keyed by repo (unlike `subs/`); removed on expiry (7 days) or when presence is gone. `notices/` holds sent-once markers, pruned after 7 days. |

Liveness is checked by pid plus process start time, so a reused pid does not keep a dead session listed. If `ps` cannot read the start time, a record with a live pid is kept rather than deleted.

## Troubleshooting

- A session is missing from `list`: it runs an older plugin (restart it after `aidevops update`), or it is a read-only record (`list --all`). Workers dispatched before an update stay read-only until they exit.
- A worker never got a relay message: check `worker-bus-relay-helper.sh status`, then `[worker-bus-relay]` and `REST-core deferrable unit blocked` lines in `~/.aidevops/logs/pulse.log`.
- An ask did not wake an idle session: check its wake budget (6 per hour) and the message's hop count; it is delivered at the next turn instead. After a failed wake (`session-bus wake:` on stderr), the next attempt waits 30 seconds, doubling up to 15 minutes until a wake succeeds.
- Compaction keeps open asks: the compaction context lists asks this session still has to answer and asks it is waiting on.
