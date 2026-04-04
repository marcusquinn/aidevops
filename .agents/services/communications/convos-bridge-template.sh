#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Convos AI bridge template — connects agent serve to an AI backend via named pipes.
# Replace `your-ai-dispatch` with your backend. For aidevops:
#   claude run --session-id "$SESSION_ID" --message "..."
# Lines starting with { are stdin commands; other lines are sent as text.
# Run as a SEPARATE BACKGROUND PROCESS — never source or run inline.
set -euo pipefail

exec 0</dev/null # Close inherited stdin

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
	<"$FIFO_IN" >"$FIFO_OUT" 2>>"$AGENT_ERR_LOG" &
AGENT_PID=$!

exec 3>"$FIFO_IN"

QUEUE_FILE="$FIFO_DIR/queue"
: >"$QUEUE_FILE"

queue_reply() {
	local reply="$1"
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		if [[ "$line" == "{"* ]]; then
			echo "$line" | jq -c . >>"$QUEUE_FILE"
		else
			jq -nc --arg text "$line" '{"type":"send","text":$text}' >>"$QUEUE_FILE"
		fi
	done <<<"$reply"
	send_next
}

send_next() {
	[[ ! -s "$QUEUE_FILE" ]] && return 0
	head -1 "$QUEUE_FILE" >&3
	tail -n +2 "$QUEUE_FILE" >"$QUEUE_FILE.tmp"
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
		SYSTEM_MSG=$(
			cat <<SYSMSG
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
done <"$FIFO_OUT"

wait "$AGENT_PID"
