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

- **Type**: Encrypted messaging app built on XMTP — per-conversation identity, E2E encryption, CLI agent mode
- **License**: Open source
- **CLI**: `@xmtp/convos-cli` (npm) — join, create, and participate in conversations
- **Agent mode**: `convos agent serve` — long-lived ndjson stdin/stdout protocol for real-time participation
- **Website**: [convos.org](https://convos.org/)
- **Upstream skill**: [convos.org/skill.md](https://convos.org/skill.md)
- **Environments**: `dev` (test network, default), `production` (real users)
- **Config**: `~/.convos/.env` (created by `convos init`), `~/.convos/identities/` (per-conversation)

**Key differentiator**: Every conversation creates a unique identity — no cross-conversation linkability. Messages are end-to-end encrypted via XMTP's MLS protocol. Groups support invites, profiles, reactions, attachments, and self-destruction.

**Relationship to XMTP**: Convos is a consumer-facing app built on the XMTP protocol. `xmtp.md` covers the protocol/SDK layer for building custom apps. `convos.md` covers participating in Convos conversations as an agent. The two are complementary.

| Criterion | Convos CLI | XMTP Agent SDK |
|-----------|-----------|----------------|
| Use case | Join/create Convos conversations | Build custom XMTP apps |
| Identity | Per-conversation (automatic) | Wallet/DID (developer-managed) |
| Interface | CLI + ndjson bridge script | TypeScript event-driven SDK |
| Agent mode | `convos agent serve` (stdin/stdout) | `agent.on("text", ...)` |
| Best for | Participating in existing Convos groups | Building new messaging products |

<!-- AI-CONTEXT-END -->

## Agent Behaviour

Your job is to help groups do things. Your value comes from connecting what others have said — the pattern across conversations, the contradiction nobody caught, the thing someone mentioned once that just became relevant. You're not running the group. You're serving it. Tell people they can train you just by talking to you.

The detailed behavioural rules are delivered via the bridge script's `SYSTEM_MSG` (see Bridge Scripts below).

## Getting Started

If you haven't been supplied an invite URL, slug, or conversation ID, ask the user for one. Invite links start with `https://popup.convos.org`.

```bash
# Install and initialize
npm install -g @xmtp/convos-cli
convos init --env production
```

This creates `~/.convos/.env`. Each conversation gets its own isolated identity in `~/.convos/identities/`. The channel is Convos — never ask users which platform they're on or for API credentials.

## Joining a Conversation

```bash
# Join with a display name (waits up to 120s for acceptance; use --timeout to change)
convos conversations join "<invite-url-or-slug>" \
  --profile-name "Your Name" --env production

# Join and capture the conversation ID
CONV_ID=$(convos conversations join "<slug>" \
  --profile-name "Your Name" --json --env production | jq -r '.conversationId')
```

## Creating a Conversation

```bash
# Create (add --permissions admin-only for restricted groups)
CONV_ID=$(convos conversations create \
  --name "Group Name" --profile-name "Your Name" \
  --json --env production | jq -r '.conversationId')

# Generate invite (shows QR code in terminal)
convos conversation invite "$CONV_ID"
# Get invite URL for scripting
INVITE_URL=$(convos conversation invite "$CONV_ID" --json | jq -r '.url')
```

Always display the full unmodified output when generating invites so the QR code renders correctly.

### Processing Join Requests

After someone opens your invite, you must process their join request:

```bash
# Process all pending requests
convos conversations process-join-requests --conversation "$CONV_ID"

# Watch for requests in real-time (use when timing is unknown)
convos conversations process-join-requests --watch --conversation "$CONV_ID"
```

The invitee must open/scan the invite URL *before* you process.

## Agent Mode

`convos agent serve` is the core of real-time agent participation. It streams messages, processes joins, and accepts commands via ndjson on stdin/stdout.

> **You MUST provide either a conversation ID or `--name` to create a new one.**
> Running `convos agent serve` with neither will fail.

```bash
# Attach to existing conversation
convos agent serve "$CONV_ID" --profile-name "Your Name" --env production

# Create new conversation and start serving
convos agent serve --name "Group Name" --profile-name "Your Name" --env production

# With periodic health checks
convos agent serve "$CONV_ID" --profile-name "Your Name" --heartbeat 30 --env production
```

When started, agent serve: creates/attaches to the conversation, prints a QR code invite to stderr, emits a `ready` event, processes pending join requests, streams messages in real-time, accepts commands on stdin, and automatically adds new members who join via invite.

### Events (stdout)

One JSON object per line with an `event` field:

| Event | Meaning | Key fields |
|-------|---------|------------|
| `ready` | Session started | `conversationId`, `inviteUrl`, `inboxId` |
| `message` | Someone sent a message | `id`, `senderInboxId`, `content`, `contentType`, `sentAt`, `senderProfile` |
| `member_joined` | New member added | `inboxId`, `conversationId` |
| `sent` | Your message was delivered | `id`, `text`, `replyTo` |
| `heartbeat` | Health check | `conversationId`, `activeStreams` |
| `error` | Something went wrong | `message` |

Messages with `catchup: true` were fetched during a stream reconnection — consider whether to respond to old catchup messages or ignore them.

### Message Content Types

The `content` field is always a string. Format depends on `contentType.typeId`:

| typeId | Example |
|--------|---------|
| `text` | `Hello everyone` |
| `reply` | `reply to "Hello everyone" (<msg-id>): Thanks!` |
| `reaction` | `reacted (thumbs up) to <msg-id>` |
| `attachment` | `[attachment: photo.jpg (image/jpeg)]` |
| `remoteStaticAttachment` | `[remote attachment: video.mp4 (4521 bytes) https://...]` |
| `group_updated` | `Alice changed group name to "New Name"` |

Replies and reactions reference another message by ID. `group_updated` covers: name changes, joins by invite, member add/remove, admin promotions, profile name/photo changes.

### Commands (stdin)

One compact JSON object per line (no pretty-printing):

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

## Bridge Scripts

> **AI AGENTS: YOU MUST USE A BRIDGE SCRIPT.**
>
> Do not try to manually run `agent serve` and send messages separately — that
> creates race conditions and you will miss messages. You cannot natively pipe
> stdin/stdout to a long-running process. Write the bridge script below, run it,
> and let it handle the event loop.

### How It Works

1. Write the bridge script to a file (use the template below)
2. Make it executable (`chmod +x bridge.sh`)
3. Run it as a **separate background process** (`./bridge.sh "$CONV_ID" &`)

**The bridge MUST run as its own process.** Do not source it, run it inline, or execute it in the same shell. If other processes share the bridge's file descriptors, their output can leak into agent serve's stdin and get sent as chat messages.

### Bridge Script Template

This template uses a headless AI dispatch for reply generation. Replace `your-ai-dispatch` calls with your preferred backend. For aidevops, replace with `Claude run --session-id "$SESSION_ID" --message "..."`.

The sub-session gets full tool access and retains conversation history via `--session-id`. If your backend is stateless, prepend `SYSTEM_MSG` to every call instead of delivering it once on `ready`.

The bridge processes sub-session output line by line: lines starting with `{` are passed directly to agent serve as stdin commands; other lines are sent as text messages.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Close inherited stdin so nothing leaks into agent serve
exec 0</dev/null

CONV_ID="${1:?Usage: $0 <conversation-id>}"
SESSION_ID="convos-${CONV_ID}"
MY_INBOX=""

# Prevent duplicate bridges for the same conversation
LOCK_FILE="/tmp/convos-bridge-${CONV_ID}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Bridge already running for $CONV_ID (lock: $LOCK_FILE)" >&2
  exit 1
fi

# Named pipes for agent serve communication
FIFO_DIR=$(mktemp -d)
FIFO_IN="$FIFO_DIR/in"
FIFO_OUT="$FIFO_DIR/out"
mkfifo "$FIFO_IN" "$FIFO_OUT"
trap 'rm -rf "$FIFO_DIR" "$LOCK_FILE"' EXIT

# Start agent serve with named pipes
convos agent serve "$CONV_ID" --profile-name "AI Agent" \
  < "$FIFO_IN" > "$FIFO_OUT" 2>/dev/null &
AGENT_PID=$!

# Persistent write FD — stays open for the lifetime of the script
exec 3>"$FIFO_IN"

# Message queue — sends one at a time, waits for "sent" confirmation
QUEUE_FILE="$FIFO_DIR/queue"
: > "$QUEUE_FILE"

# Queue a reply: JSON commands pass through, text gets wrapped
queue_reply() {
  local reply="$1"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == "{"* ]]; then
      echo "$line" | jq -c . >> "$QUEUE_FILE"
    else
      jq -nc --arg text "$line" '{"type":"send","text":$text}' >> "$QUEUE_FILE"
    fi
  done <<< "$reply"
  send_next
}

# Send the next queued command to agent serve
send_next() {
  [[ ! -s "$QUEUE_FILE" ]] && return 0
  head -1 "$QUEUE_FILE" >&3
  tail -n +2 "$QUEUE_FILE" > "$QUEUE_FILE.tmp"
  mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
  return 0
}

while IFS= read -r event; do
  evt=$(echo "$event" | jq -r '.event // empty')

  case "$evt" in
    ready)
      MY_INBOX=$(echo "$event" | jq -r '.inboxId')
      echo "Ready: $CONV_ID" >&2
      PROFILES=$(convos conversation profiles "$CONV_ID" --json 2>/dev/null || echo "[]")
      SYSTEM_MSG=$(cat <<SYSMSG
[system] You are an AI group agent in Convos conversation $CONV_ID.
Your job is to help this group do things.

YOUR OUTPUT GOES DIRECTLY TO CHAT. Every non-empty line you produce is sent
as a message or command. Follow these rules from your very first output:

Rules:
1. Listen first. Learn who these people are before you contribute.
2. Earn your seat. Only speak when it adds something no one else could.
3. Plain text only. No markdown (no **bold**, \`code\`, [links](url), or lists).
4. Be concise. Protect people's attention. React instead of typing when possible.
5. Reply, don't broadcast. Messages include a msg-id — use it with replyTo.
   Only reply to actual messages — never to system events like group updates.
6. Be the memory. Connect dots across time. Surface things that just became
   relevant. But never weaponize memory.
7. Use names, not inbox IDs. Refresh with: convos conversation profiles "$CONV_ID" --json
8. Never narrate what you are doing. Your stdout IS the chat — every line
   you output is sent as a message to real people. Never say "let me check",
   "reading now", or describe what you're about to do. Do all reasoning and
   tool use silently. Only output words you want humans to read.
9. Honor renames immediately. Run: convos conversation update-profile "$CONV_ID" --name "New Name"
10. Read the room. If people are having fun, be fun. If quiet, respect the quiet.
11. Respect privacy. What's said in the group stays in the group.
12. Tell people they can train you by talking to you.

Output format — each line is processed separately:
- Lines starting with { = JSON commands sent to agent serve
- Other non-empty lines = sent as text messages

JSON commands (compact single-line ndjson):
{"type":"send","text":"Hello!"}
{"type":"send","text":"Replying","replyTo":"<message-id>"}
{"type":"react","messageId":"<message-id>","emoji":"(thumbs up)"}
{"type":"attach","file":"./photo.jpg"}
{"type":"rename","name":"New Group Name"}

CLI commands (safe to run alongside agent serve):
convos conversation profiles "$CONV_ID" --json
convos conversation messages "$CONV_ID" --json --sync --limit 20
convos conversation update-profile "$CONV_ID" --name "Name"
convos conversation info "$CONV_ID" --json

REMEMBER: every line you output is sent to the chat. Do not output reasoning,
status updates, or narration. Only output messages you intend humans to read.

Current group members:
$PROFILES
SYSMSG
)
      # Replace this dispatch call with your AI backend
      reply=$(your-ai-dispatch \
        --session-id "$SESSION_ID" \
        --message "$SYSTEM_MSG" \
        2>/dev/null)
      queue_reply "$reply"
      ;;

    sent)
      # Previous message confirmed — send the next queued one
      send_next
      ;;

    message)
      type_id=$(echo "$event" | jq -r '.contentType.typeId // empty')
      [[ "$type_id" != "text" && "$type_id" != "reply" ]] && continue

      catchup=$(echo "$event" | jq -r '.catchup // false')
      [[ "$catchup" == "true" ]] && continue

      sender=$(echo "$event" | jq -r '.senderInboxId // empty')
      [[ "$sender" == "$MY_INBOX" ]] && continue

      sender_name=$(echo "$event" | jq -r '.senderProfile.name // "Someone"')
      msg_id=$(echo "$event" | jq -r '.id // empty')
      content=$(echo "$event" | jq -r '.content')

      # Replace this dispatch call with your AI backend
      reply=$(your-ai-dispatch \
        --session-id "$SESSION_ID" \
        --message "$sender_name (msg-id: $msg_id): $content" \
        2>/dev/null)

      queue_reply "$reply"
      ;;

    member_joined)
      jq -nc '{"type":"send","text":"Welcome!"}' >&3
      ;;
  esac
done < "$FIFO_OUT"

wait "$AGENT_PID"
```

## CLI Reference

Commands for reading and querying while participating. Always pass `--json` when parsing output programmatically.

### Members, Profiles, and History

```bash
# Members (inbox IDs + permission levels)
convos conversation members "$CONV_ID" --json

# Profiles (display names + avatars) — refresh on member_joined or profile changes
convos conversation profiles "$CONV_ID" --json

# Recent messages (sync from network first)
convos conversation messages "$CONV_ID" --json --sync --limit 20

# Oldest first
convos conversation messages "$CONV_ID" --json --limit 50 --direction ascending

# Filter by type
convos conversation messages "$CONV_ID" --json --content-type text
convos conversation messages "$CONV_ID" --json --exclude-content-type reaction

# Time range (nanosecond timestamps)
convos conversation messages "$CONV_ID" --json --sent-after <ns> --sent-before <ns>
```

### Attachments

```bash
# Download (optionally specify output path)
convos conversation download-attachment "$CONV_ID" <message-id> --output ./photo.jpg

# Send (small files inline, large files auto-uploaded)
convos conversation send-attachment "$CONV_ID" ./photo.jpg
```

### Profile Management

Profiles are per-conversation — different name and avatar in each group.

```bash
convos conversation update-profile "$CONV_ID" --name "New Name"
convos conversation update-profile "$CONV_ID" --name "New Name" --image "https://example.com/avatar.jpg"
convos conversation update-profile "$CONV_ID" --name "" --image ""  # Go anonymous
```

### Group Management

```bash
convos conversation info "$CONV_ID" --json
convos conversation permissions "$CONV_ID" --json
convos conversation update-name "$CONV_ID" "New Name"
convos conversation update-description "$CONV_ID" "New description"

# Member management (requires super admin)
convos conversation add-members "$CONV_ID" <inbox-id>
convos conversation remove-members "$CONV_ID" <inbox-id>

# Lock (prevent new joins, invalidate existing invites) / unlock
convos conversation lock "$CONV_ID"
convos conversation lock "$CONV_ID" --unlock

# Permanently destroy conversation (irreversible)
convos conversation explode "$CONV_ID" --force
```

### Send Messages (CLI)

For scripting or one-off sends outside of agent mode:

```bash
convos conversation send-text "$CONV_ID" "Hello!"
convos conversation send-reply "$CONV_ID" <message-id> "Replying to you"
convos conversation send-reaction "$CONV_ID" <message-id> add "(thumbs up)"
convos conversation send-reaction "$CONV_ID" <message-id> remove "(thumbs up)"
```

## Common Mistakes

| Mistake | Correct approach |
|---------|-----------------|
| `agent serve` without conversation ID or `--name` | Pass a conversation ID to join existing, or `--name` to create new |
| Manually polling and sending messages separately | Use a bridge script with named pipes for stdin/stdout |
| Running bridge inline or in shared shell | Write bridge to a file, run as separate background process |
| Using markdown in messages | Convos does not render markdown — write plain text |
| Sending via CLI while in agent mode | Use stdin commands (`{"type":"send",...}`) — CLI sends create race conditions |
| Forgetting `--env production` | Default is `dev` (test network) — always pass `--env production` for real conversations |
| Replying to system events | Only `replyTo` messages with `contentType.typeId` of `text`, `reply`, or `attachment` |
| Generating invite but not processing joins | Run `process-join-requests` after the invitee opens the link |
| Referencing inbox IDs in chat | Fetch profiles and use display names |
| Announcing tool usage in chat | Just do it silently and respond naturally |
| Responding to every message | Only speak when it adds something — react instead of replying when possible |
| Launching the bridge twice | The template uses `flock` to prevent this — always check for an existing process |

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `convos: command not found` | `npm install -g @xmtp/convos-cli` |
| `Error: Not initialized` | `convos init --env production` |
| Join request times out | Invitee must open/scan the invite URL *before* creator processes requests |
| Messages not appearing | Sync first: `convos conversation messages <id> --json --sync --limit 20` |
| Permission denied on group ops | Check `convos conversation permissions <id> --json` — only super admins can add/remove members, lock, or explode |
| Invite expired or invalid | Generate new: `convos conversation invite <id>`. Locking invalidates all existing invites |
| Agent serve exits unexpectedly | Check stderr. Common causes: invalid conversation ID, identity not found (`convos identity list`), network issues. Use `--heartbeat 30` to monitor |

## Tips

- Use `--json` when parsing output — human-readable format can change between versions
- Use `--sync` before reading messages to ensure fresh data from the network
- Identities are automatic — creating or joining a conversation creates one. Rarely need to manage directly
- Show full QR code output when generating invites. In agent mode, the QR code PNG path is in the `ready` event's `qrCodePath` field
- Lock before exploding — lock a conversation first to prevent new joins, then explode when ready

## Related

- `services/communications/xmtp.md` — XMTP protocol and Agent SDK (the protocol layer Convos is built on)
- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, no identifiers)
- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `services/communications/matrix-bot.md` — Matrix bot integration (federated)
- `tools/security/opsec.md` — Operational security guidance
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- Convos: https://convos.org/
- Convos Skill: https://convos.org/skill.md
- XMTP Docs: https://docs.xmtp.org/
