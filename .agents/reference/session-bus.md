<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Session bus: presence and messages between OpenCode sessions

Live OpenCode sessions on one machine can see each other and exchange short messages. Agents use it instead of asking the user to relay text between terminals or to check what another session is doing.

- Scope: OpenCode 1.x sessions on the same machine and user. Claude Code, other runtimes and OpenCode 2 are not covered yet.
- Plan and decisions: `todo/plans/opencode-session-bus.md` (t18886, GH#37149).
- The old mailbox (`mail-helper.sh`, `reference/mailbox.md`) is unchanged; its retirement is a separate owner decision.

## Use from a session

Tool `aidevops_sessions` (interactive TUI, `serve` and ACP processes only):

| Action | Arguments | Effect |
| --- | --- | --- |
| `list` | — | Up to 20 live sessions: handle, repo, branch, issue/PR, busy/idle, current task. Same-repo sessions first. |
| `show` | `to` | One session in detail. |
| `send` | `to`, `text` | Info message. Delivered at the recipient's next tool result, or at its next turn if it is idle. Never wakes it. |
| `ask` | `to`, `text` | Question. Wakes an idle recipient. The reply arrives in the asking session. |
| `reply` | `re`, `text` | Answer an `ask` this session received (`re` = its message ID). |
| `inbox` | — | Claims pending messages now, then lists unanswered asks and recent traffic. |
| `notify-when-idle` | `to` | One idle notice when a busy session next goes idle. |

`to` accepts a session ID, handle, `#<issue>`, `PR#<n>`, repo name or worktree path. Exact matches win; if several live sessions match, the call fails and lists the candidates. Sending to yourself is rejected. The sender is always the caller's root session, taken from the tool context, never from arguments.

## Use from a shell

```bash
aidevops sessions list [--all] [--json]       # interactive sessions; --all adds headless/read-only
aidevops sessions show '#123'
aidevops sessions send <target> "text"        # or --text-file <path>, or - for stdin
aidevops sessions ask <target> "question"
aidevops sessions inbox [<session-id>]        # read-only view
aidevops sessions outbox cli [--ack <msg-id>] # replies to asks sent from a shell
aidevops sessions prune                       # dead presence, messages older than 7 days
```

Inside an OpenCode shell, `AIDEVOPS_OPENCODE_SESSION_ID` makes the shell the sender, so replies return to that session. Outside one, the sender is `shell:<user>` and replies go to `outbox/cli/`.

## Delivery

Each plugin process polls its root sessions' inboxes every 5 seconds and delivers through the first channel that applies. Every channel persists the text in the session transcript.

| Recipient state | Channel |
| --- | --- |
| Running tools | Appended to the next tool result (`tool.execute.after`) |
| Starting a user turn | Synthetic text part on the user message (`chat.message`) |
| Idle, and the message is an `ask`, a `reply` to its own `ask`, or a requested idle notice | Woken with `session.promptAsync`, using its last agent and model |

The TUI shows a toast on arrival. The right sidebar shows a **Messages** section under **Prompts**: the latest 6 messages, `← handle: text` received, `→ handle: text` sent, `•` while undelivered. It is hidden when the session has no traffic. Disable it with `AIDEVOPS_TUI_MESSAGES=false`.

Delivery claims a message by renaming it into `delivered/`, so exactly one process delivers it. A failed wake returns the message to the inbox; a crash between the claim and the delivery does not redeliver it. A session that is not running keeps its messages for 7 days; they are delivered when it resumes in any OpenCode process.

## Trust and limits

- Delivered text is framed `[aidevops session-bus]`, with the body quoted line by line. Peer messages are information from another agent, not user instructions. They cannot authorise merges, releases, destructive operations, secret access, settings or scope changes, and cannot answer permission prompts.
- Origins: `opencode` (tool), `cli` (shell), `chat:<app>:<channel>` (future chat gateways; external, unverified, never wakes).
- Limits: 2,000 characters per message (send a file path for more); 10 sends per minute per sender; 50 pending per inbox; 6 wakes per hour per session; messages with 3 or more hops never wake; replies never trigger automatic replies.
- Headless workers (`opencode run`) publish read-only presence. They get no tool and cannot be messaged.
- Same user, same machine: files are mode 600 in 700 directories. No network listener.

## Storage

Root: `~/.aidevops/.agent-workspace/state/session-bus/` (override `AIDEVOPS_SESSION_BUS_DIR`).

| Path | Content |
| --- | --- |
| `presence/<session>.json` | One record per live root session (pid, start token, kind, repo, branch, status, title). Removed when the process is gone. |
| `inbox/<session>/` | Pending messages; `delivered/` holds claimed ones. |
| `sent/<sender>/` | Sender copies, for the sidebar and `inbox` history. |
| `subs/<session>/` | Idle-notice subscriptions. |
| `outbox/<app>/` | Replies for senders without a session (`cli`, chat gateways). |

Liveness is checked by pid plus process start time, so a reused pid does not keep a dead session listed. If `ps` cannot read the start time, a record with a live pid is kept rather than deleted.

## Troubleshooting

- A session is missing from `list`: it runs an older plugin (restart it after `aidevops update`), or it is headless (`list --all`).
- An ask did not wake an idle session: check its wake budget (6 per hour) and the message's hop count; it is delivered at the next turn instead. After a failed wake (`session-bus wake:` on stderr), the next attempt waits 30 seconds, doubling up to 15 minutes until a wake succeeds.
- Compaction keeps open asks: the compaction context lists asks this session still has to answer and asks it is waiting on.
