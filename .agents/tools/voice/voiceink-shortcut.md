---
description: macOS Shortcut to send VoiceInk transcription to OpenCode server API
mode: subagent
tools:
  read: true
  bash: true
---

# VoiceInk to OpenCode via macOS Shortcut

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Send VoiceInk voice transcriptions to an OpenCode server session via macOS Shortcut
- **Flow**: VoiceInk transcription -> macOS Shortcut -> HTTP POST -> OpenCode server -> AI response
- **Prerequisites**: [VoiceInk](https://apps.apple.com/app/voiceink-ai-transcription/id6478838191) (macOS, local Whisper STT), OpenCode server running (`opencode serve`)
- **Related**: `tools/ai-assistants/opencode-server.md`, `tools/voice/speech-to-speech.md`

<!-- AI-CONTEXT-END -->

```text
┌──────────┐    ┌──────────────┐    ┌──────────────────┐    ┌──────────────┐
│ You speak │───>│   VoiceInk   │───>│  macOS Shortcut  │───>│   OpenCode   │
│ a command │    │ (Whisper STT)│    │  or shell script │    │  Server API  │
└──────────┘    └──────────────┘    └──────────────────┘    └──────────────┘
                  Local, private       HTTP POST to            AI processes
                  transcription        localhost:4096          your command
```

## Setup

### 1. Start OpenCode Server

```bash
opencode serve --port 4096

# With auth (if exposing beyond localhost)
OPENCODE_SERVER_PASSWORD=your-password opencode serve --port 4096
```

### 2. Create or Identify a Session

```bash
curl -s -X POST http://localhost:4096/session \
  -H "Content-Type: application/json" \
  -d '{"title": "Voice Commands"}' | jq -r '.id'
```

Save the returned session ID (or use an existing session from the OpenCode TUI).

### 3. Configure the macOS Shortcut

#### Option A: Shortcuts App (Recommended)

Create a new Shortcut with these actions:

1. **Receive** input from VoiceInk (text)
2. **Set Variable** `transcription` to the Shortcut Input
3. **Get Contents of URL**:
   - URL: `http://localhost:4096/session/SESSION_ID/prompt_async`
   - Method: POST
   - Headers: `Content-Type: application/json`
   - Request Body (JSON):

     ```json
     {
       "parts": [
         {
           "type": "text",
           "text": "{transcription}"
         }
       ]
     }
     ```

4. (Optional) **Show Notification**: "Sent to OpenCode"

Replace `SESSION_ID` with your actual session ID.

**Sync vs Async endpoints**:

| Endpoint | Behaviour | Use When |
|----------|-----------|----------|
| `/session/:id/prompt_async` | Returns 204 immediately | Default - non-blocking |
| `/session/:id/message` | Waits for full AI response | You want the response in the Shortcut |

#### Option B: Shell Script Action

VoiceInk can also run shell scripts directly:

```bash
#!/bin/bash
# ~/.local/bin/voiceink-to-opencode.sh
# Called by VoiceInk with transcription as $1

set -euo pipefail

local_server="http://localhost:4096"
local_session_id="${OPENCODE_SESSION_ID:-}"
local_transcription="$1"

if [[ -z "$local_session_id" ]]; then
  echo "Error: Set OPENCODE_SESSION_ID environment variable" >&2
  exit 1
fi

if [[ -z "$local_transcription" ]]; then
  echo "Error: No transcription provided" >&2
  exit 1
fi

# Escape for JSON (declare first to avoid SC2155)
local_json_text=""
local_json_text=$(printf '%s' "$local_transcription" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

curl -s -X POST "${local_server}/session/${local_session_id}/prompt_async" \
  -H "Content-Type: application/json" \
  -d "{\"parts\": [{\"type\": \"text\", \"text\": ${local_json_text}}]}"

osascript -e 'display notification "Sent to OpenCode" with title "VoiceInk"'
```

```bash
chmod +x ~/.local/bin/voiceink-to-opencode.sh
```

### 4. Configure VoiceInk Action

In VoiceInk preferences > **Actions** (or **Custom Actions**):

1. Add a new action
2. Set the trigger (e.g., keyword prefix, or default action)
3. Choose either:
   - **Run Shortcut**: Select the Shortcut from Option A
   - **Run Script**: Point to `~/.local/bin/voiceink-to-opencode.sh`

## Advanced Configuration

### Session Auto-Discovery

Discover the most recent active session instead of hardcoding an ID:

```bash
#!/bin/bash
local_session_id=""
local_session_id=$(curl -s http://localhost:4096/session | jq -r '.[0].id')

curl -s -X POST "http://localhost:4096/session/${local_session_id}/prompt_async" \
  -H "Content-Type: application/json" \
  -d "{\"parts\": [{\"type\": \"text\", \"text\": $(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}]}"
```

### With Authentication

```bash
# Shell script — add -u flag
curl -s -X POST "http://localhost:4096/session/${local_session_id}/prompt_async" \
  -u "user:${OPENCODE_SERVER_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d "{\"parts\": [{\"type\": \"text\", \"text\": ${local_json_text}}]}"
```

In macOS Shortcuts, add an `Authorization` header with value `Basic <base64(user:password)>`.

### Sync Mode with Response Display

```bash
#!/bin/bash
# voiceink-to-opencode-sync.sh - Shows AI response

set -euo pipefail

local_server="http://localhost:4096"
local_session_id="${OPENCODE_SESSION_ID:-}"
local_transcription="$1"
local_json_text=""
local_json_text=$(printf '%s' "$local_transcription" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

local_response=""
local_response=$(curl -s -X POST "${local_server}/session/${local_session_id}/message" \
  -H "Content-Type: application/json" \
  -d "{\"parts\": [{\"type\": \"text\", \"text\": ${local_json_text}}]}")

local_reply=""
local_reply=$(echo "$local_response" | jq -r '.parts[] | select(.type=="text") | .text' | head -c 200)

osascript -e "display notification \"${local_reply}\" with title \"OpenCode Response\""
```

### Keyword Routing

Use VoiceInk's action matching to route different voice commands:

| VoiceInk Keyword | Action | OpenCode Behaviour |
|------------------|--------|--------------------|
| "code" | Run Shortcut: Voice to OpenCode | Sends to coding session |
| "deploy" | Run Script: deploy-dispatch.sh | Sends to ops session |
| "remember" | Run Script: memory-store.sh | Stores in aidevops memory |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Connection refused" | Ensure `opencode serve` is running on port 4096 |
| "Session not found" | Create a session first or use auto-discovery |
| Empty transcription | Check VoiceInk is passing text to the action correctly |
| JSON parse error | Ensure special characters are escaped (use the python3 JSON escape) |
| Auth failure | Check `OPENCODE_SERVER_PASSWORD` matches server config |
| Shortcut not triggering | Verify VoiceInk action is set to "Run Shortcut" with correct name |

### Test the Flow Manually

```bash
# 1. Health check
curl -s http://localhost:4096/global/health | jq .

# 2. List sessions
curl -s http://localhost:4096/session | jq '.[].id'

# 3. Send test prompt
curl -s -X POST "http://localhost:4096/session/SESSION_ID/prompt_async" \
  -H "Content-Type: application/json" \
  -d '{"parts": [{"type": "text", "text": "Hello from VoiceInk test"}]}'
```

## Security Notes

- The OpenCode server defaults to `127.0.0.1` (localhost only) - safe for local use
- If exposing to the network, always set `OPENCODE_SERVER_PASSWORD`
- VoiceInk transcription is local (Whisper on-device) - audio never leaves your Mac
- Store any auth credentials via `aidevops secret set OPENCODE_SERVER_PASSWORD`

## See Also

- `tools/ai-assistants/opencode-server.md` - Full OpenCode server API reference
- `tools/voice/speech-to-speech.md` - Full voice pipeline (bidirectional)
- `tools/voice/transcription.md` - Transcription model options
- Related task: t113 (iPhone Shortcut for voice dispatch)
