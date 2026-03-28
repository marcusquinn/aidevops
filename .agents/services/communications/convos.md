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

`convos agent serve` streams messages, processes joins, and accepts commands via ndjson stdin/stdout.

> **Must provide a conversation ID or `--name`** — running without either fails.

```bash
convos agent serve "$CONV_ID" --profile-name "Your Name" --env production
convos agent serve --name "Group Name" --profile-name "Your Name" --env production
convos agent serve "$CONV_ID" --profile-name "Your Name" --heartbeat 30 --env production
```

### Events (stdout — one JSON object per line)

| Event | Meaning | Key fields |
|-------|---------|------------|
| `ready` | Session started | `conversationId`, `inviteUrl`, `inboxId` |
| `message` | Message received | `id`, `senderInboxId`, `content`, `contentType`, `sentAt`, `senderProfile` |
| `member_joined` | New member added | `inboxId`, `conversationId` |
| `sent` | Your message delivered | `id`, `text`, `replyTo` |
| `heartbeat` | Health check | `conversationId`, `activeStreams` |
| `error` | Error | `message` |

Messages with `catchup: true` were fetched during reconnection — consider ignoring them.

### Message Content Types

| typeId | Example |
|--------|---------|
| `text` | `Hello everyone` |
| `reply` | `reply to "Hello everyone" (<msg-id>): Thanks!` |
| `reaction` | `reacted (thumbs up) to <msg-id>` |
| `attachment` | `[attachment: photo.jpg (image/jpeg)]` |
| `remoteStaticAttachment` | `[remote attachment: video.mp4 (4521 bytes) https://...]` |
| `group_updated` | `Alice changed group name to "New Name"` |

### Commands (stdin — compact ndjson, one per line)

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

> **AI AGENTS: YOU MUST USE A BRIDGE SCRIPT.** Do not manually run `agent serve` and send messages separately — race conditions will cause missed messages. Run the bridge as a **separate background process**. Never source it or run it inline — shared file descriptors leak output into agent serve's stdin.

Replace `your-ai-dispatch` with your backend. For aidevops: `Claude run --session-id "$SESSION_ID" --message "..."` (retains history via `--session-id`). If stateless, prepend `SYSTEM_MSG` to every call. Lines starting with `{` are stdin commands; other lines are sent as text.

```bash
#!/usr/bin/env bash
set -euo pipefail

exec 0</dev/null  # Close inherited stdin

CONV_ID="${1:?Usage: $0 <conversation-id>}"
SESSION_ID="convos-${CONV_ID}"
MY_INBOX=""

LOCK_FILE="/tmp/convos-bridge-${CONV_ID}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Bridge already running for $CONV_ID (lock: $LOCK_FILE)" >&2
  exit 1
fi

FIFO_DIR=$(mktemp -d)
FIFO_IN="$FIFO_DIR/in"
FIFO_OUT="$FIFO_DIR/out"
mkfifo "$FIFO_IN" "$FIFO_OUT"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/convos"
mkdir -p "$LOG_DIR"
AGENT_ERR_LOG="$LOG_DIR/agent-${CONV_ID}.stderr.log"
trap 'rm -rf "$FIFO_DIR" "$LOCK_FILE"' EXIT

convos agent serve "$CONV_ID" --profile-name "AI Agent" \
  < "$FIFO_IN" > "$FIFO_OUT" 2>>"$AGENT_ERR_LOG" &
AGENT_PID=$!

exec 3>"$FIFO_IN"

QUEUE_FILE="$FIFO_DIR/queue"
: > "$QUEUE_FILE"

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
3. Plain text only. No Markdown (no **bold**, \`code\`, [links](url), or lists).
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
      reply=$(your-ai-dispatch \
        --session-id "$SESSION_ID" \
        --message "$SYSTEM_MSG" \
        2>/dev/null)
      queue_reply "$reply"
      ;;

    sent)
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

Always pass `--json` when parsing output programmatically. Use `--sync` before reading messages to ensure fresh data.

```bash
# Members and profiles
convos conversation members "$CONV_ID" --json
convos conversation profiles "$CONV_ID" --json  # refresh on member_joined or profile changes

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

## Common Mistakes

| Mistake | Correct approach |
|---------|-----------------|
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

## Troubleshooting

| Problem | Solution |
|---------|----------|
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
