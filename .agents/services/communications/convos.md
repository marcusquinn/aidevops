---
description: Convos — encrypted messaging on XMTP with CLI agent mode, ndjson bridge protocol, group management, behavioural principles for AI group participation
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Convos

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Encrypted messaging on XMTP — per-conversation identity, E2E encryption, CLI agent mode
- **CLI**: `@xmtp/convos-cli` (npm) — `convos agent serve` for real-time participation
- **Website/Skill**: [convos.org](https://convos.org/) · [convos.org/skill.md](https://convos.org/skill.md)
- **Environments**: `dev` (default/test), `production` (real users)
- **Config**: `~/.convos/.env` · `~/.convos/identities/` (per-conversation)

Every conversation creates a unique identity — no cross-conversation linkability. Messages are E2E encrypted via XMTP MLS.

| Criterion | Convos CLI | XMTP Agent SDK |
|-----------|-----------|----------------|
| Use case | Join/create Convos conversations | Build custom XMTP apps |
| Identity | Per-conversation (automatic) | Wallet/DID (developer-managed) |
| Interface | CLI + ndjson bridge script | TypeScript event-driven SDK |
| Agent mode | `convos agent serve` (stdin/stdout) | `agent.on("text", ...)` |

<!-- AI-CONTEXT-END -->

## Agent Behaviour

Help groups do things. Connect patterns across conversations — the contradiction nobody caught, the thing someone mentioned once that just became relevant. You're not running the group; you're serving it.

Detailed behavioural rules are delivered via the bridge script's `SYSTEM_MSG`.

## Setup

```bash
npm install -g @xmtp/convos-cli
convos init --env production
```

If no invite URL/slug/conversation ID was supplied, ask the user for one. Invite links start with `https://popup.convos.org`.

## Joining and Creating

```bash
# Join (waits up to 120s; use --timeout to change)
convos conversations join "<invite-url-or-slug>" --profile-name "Your Name" --env production

# Join and capture ID
CONV_ID=$(convos conversations join "<slug>" --profile-name "Your Name" --json --env production | jq -r '.conversationId')

# Create
CONV_ID=$(convos conversations create --name "Group Name" --profile-name "Your Name" --json --env production | jq -r '.conversationId')

# Generate invite (always display full output — shows QR code)
convos conversation invite "$CONV_ID"
INVITE_URL=$(convos conversation invite "$CONV_ID" --json | jq -r '.url')

# Process join requests (invitee must open invite URL first)
convos conversations process-join-requests --conversation "$CONV_ID"
convos conversations process-join-requests --watch --conversation "$CONV_ID"  # real-time
```

## Agent Mode

`convos agent serve` streams messages, processes joins, and accepts commands via ndjson stdin/stdout. **Must provide a conversation ID or `--name`** — running without either fails.

```bash
convos agent serve "$CONV_ID" --profile-name "Your Name" --env production
convos agent serve --name "Group Name" --profile-name "Your Name" --env production
convos agent serve "$CONV_ID" --profile-name "Your Name" --heartbeat 30 --env production
```

### Events (stdout — one JSON object per line)

| Event | Key fields |
|-------|------------|
| `ready` | `conversationId`, `inviteUrl`, `inboxId` |
| `message` | `id`, `senderInboxId`, `content`, `contentType`, `sentAt`, `senderProfile` |
| `member_joined` | `inboxId`, `conversationId` |
| `sent` | `id`, `text`, `replyTo` |
| `heartbeat` | `conversationId`, `activeStreams` |
| `error` | `message` |

Messages with `catchup: true` were fetched during reconnection — consider ignoring them.

### Content Types

| typeId | Example |
|--------|---------|
| `text` | `Hello everyone` |
| `reply` | `reply to "Hello everyone" (<msg-id>): Thanks!` |
| `reaction` | `reacted (thumbs up) to <msg-id>` |
| `attachment` | `[attachment: photo.jpg (image/jpeg)]` |
| `remoteStaticAttachment` | `[remote attachment: video.mp4 (4521 bytes) https://...]` |
| `group_updated` | `Alice changed group name to "New Name"` |

### Stdin Commands (compact ndjson, one per line)

```jsonl
{"type":"send","text":"Hello!"}
{"type":"send","text":"Replying","replyTo":"<message-id>"}
{"type":"react","messageId":"<message-id>","emoji":"(thumbs up)"}
{"type":"react","messageId":"<message-id>","emoji":"(thumbs up)","action":"remove"}
{"type":"attach","file":"./photo.jpg"}
{"type":"attach","file":"./photo.jpg","replyTo":"<message-id>"}
{"type":"rename","name":"New Group Name"}
{"type":"lock"}
{"type":"unlock"}
{"type":"explode"}
{"type":"explode","scheduled":"2025-03-01T00:00:00Z"}
{"type":"stop"}
```

## Bridge Script

> **AI AGENTS: YOU MUST USE A BRIDGE SCRIPT.** Do not manually run `agent serve` and send messages separately — race conditions will cause missed messages. Run the bridge as a **separate background process**. Never source it or run it inline — shared file descriptors leak output into agent serve's stdin.

Full template: [`convos-bridge-template.sh`](convos-bridge-template.sh) — replace `your-ai-dispatch` with your backend. For aidevops: `claude run --session-id "$SESSION_ID" --message "..."`. If stateless, prepend `SYSTEM_MSG` to every call.

Key design: named pipes (FIFOs) connect `agent serve` stdin/stdout. A queue ensures one message sends at a time (waits for `sent` event before dequeuing next). `flock` prevents duplicate bridge instances.

## CLI Reference

Always pass `--json` when parsing output programmatically. Use `--sync` before reading messages.

```bash
# Members and profiles
convos conversation members "$CONV_ID" --json
convos conversation profiles "$CONV_ID" --json

# Messages
convos conversation messages "$CONV_ID" --json --sync --limit 20
convos conversation messages "$CONV_ID" --json --limit 50 --direction ascending
convos conversation messages "$CONV_ID" --json --content-type text
convos conversation messages "$CONV_ID" --json --exclude-content-type reaction
convos conversation messages "$CONV_ID" --json --sent-after <ns> --sent-before <ns>

# Attachments
convos conversation download-attachment "$CONV_ID" <message-id> --output ./photo.jpg
convos conversation send-attachment "$CONV_ID" ./photo.jpg

# Profile (per-conversation — different name/avatar in each group)
convos conversation update-profile "$CONV_ID" --name "New Name"
convos conversation update-profile "$CONV_ID" --name "New Name" --image "https://example.com/avatar.jpg"
convos conversation update-profile "$CONV_ID" --name "" --image ""  # go anonymous

# Group management
convos conversation info "$CONV_ID" --json
convos conversation permissions "$CONV_ID" --json
convos conversation update-name "$CONV_ID" "New Name"
convos conversation update-description "$CONV_ID" "New description"
convos conversation add-members "$CONV_ID" <inbox-id>    # requires super admin
convos conversation remove-members "$CONV_ID" <inbox-id>
convos conversation lock "$CONV_ID"          # prevent new joins, invalidate invites
convos conversation lock "$CONV_ID" --unlock
convos conversation explode "$CONV_ID" --force  # permanently destroy (irreversible)

# One-off sends (outside agent mode)
convos conversation send-text "$CONV_ID" "Hello!"
convos conversation send-reply "$CONV_ID" <message-id> "Replying to you"
convos conversation send-reaction "$CONV_ID" <message-id> add "(thumbs up)"
convos conversation send-reaction "$CONV_ID" <message-id> remove "(thumbs up)"
```

## Pitfalls and Troubleshooting

| Issue | Fix |
|-------|-----|
| `agent serve` without conversation ID or `--name` | Pass a conversation ID or `--name` to create new |
| Manually polling and sending separately | Use bridge script with named pipes |
| Running bridge inline or in shared shell | Write to file, run as separate background process |
| Using Markdown in messages | Convos does not render Markdown — plain text only |
| Sending via CLI while in agent mode | Use stdin commands — CLI sends create race conditions |
| Forgetting `--env production` | Default is `dev` (test network) |
| Replying to system events | Only `replyTo` messages with `typeId` of `text` or `reply` |
| Not processing joins after invite | Run `process-join-requests` after invitee opens the link |
| Referencing inbox IDs in chat | Fetch profiles and use display names |
| Announcing tool usage in chat | Do it silently, respond naturally |
| Responding to every message | Only speak when it adds something — react instead |
| Launching the bridge twice | Template uses `flock` to prevent this |
| Invite expired | Generate new: `convos conversation invite <id>`. Locking invalidates all existing invites |
| `convos: command not found` | `npm install -g @xmtp/convos-cli` |
| `Error: Not initialized` | `convos init --env production` |
| Join request times out | Invitee must open/scan invite URL *before* creator processes requests |
| Messages not appearing | `convos conversation messages <id> --json --sync --limit 20` |
| Permission denied on group ops | `convos conversation permissions <id> --json` — super admins only for add/remove/lock/explode |
| Agent serve exits unexpectedly | Check stderr: invalid conversation ID, identity not found (`convos identity list`), network issues. Use `--heartbeat 30` |

## Related

- `services/communications/xmtp.md` — XMTP protocol and Agent SDK
- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge)
- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `services/communications/matrix-bot.md` — Matrix bot integration
- `tools/security/opsec.md` — Operational security
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- Convos: https://convos.org/ · XMTP Docs: https://docs.xmtp.org/
