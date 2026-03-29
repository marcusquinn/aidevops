---
description: iOS Shortcut for voice dispatch to OpenCode server
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: true
  task: false
---

# iPhone Shortcut for Voice Dispatch to OpenCode

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Dictate voice commands on iPhone, dispatch to OpenCode server, hear response
- **Flow**: Dictate (iOS STT) → HTTP POST to OpenCode → Wait → Speak (iOS TTS)
- **Network**: Requires OpenCode server reachable from iPhone (Tailscale, local Wi-Fi, or port forward)
- **Related**: `tools/voice/speech-to-speech.md`, `tools/ai-assistants/opencode-server.md`

<!-- AI-CONTEXT-END -->

## Architecture

```text
iPhone                    Mac/Server
┌───────────────┐        ┌─────────────────────┐
│ iOS Shortcuts  │        │ OpenCode Server      │
│ 1. Dictate     │  POST  │ /session/:id/message │
│ 2. HTTP POST ──┼───────>│                      │
│ 3. Wait        │<───────┼── JSON response      │
│ 4. Speak (TTS) │        │                      │
└───────────────┘        └─────────────────────┘
       └── Tailscale / Wi-Fi ──┘
```

## Prerequisites

1. **OpenCode server running**:

   ```bash
   # With authentication (recommended for network exposure)
   OPENCODE_SERVER_PASSWORD=your-password opencode serve --port 4096 --hostname 0.0.0.0
   ```

2. **Network connectivity** from iPhone to server:
   - **Tailscale** (recommended): Install on both devices, use Tailscale IP (`100.x.y.z:4096`). Works from anywhere, encrypted, no port forwarding.
   - **Same Wi-Fi**: Mac's local IP (`192.168.x.x:4096`). System Settings > Wi-Fi > Details > IP Address.
   - **Port forwarding**: Forward port 4096 through router (less secure).

3. **Session ID** — create once and reuse:

   ```bash
   curl -X POST http://localhost:4096/session \
     -H "Content-Type: application/json" \
     -d '{"title": "iPhone Voice Dispatch"}'
   # Returns: {"id": "session-uuid-here", ...}
   ```

## Shortcut Setup

Create a new Shortcut in iOS Shortcuts app with these actions in order:

| # | Action | Configuration |
|---|--------|---------------|
| 1 | **Dictate Text** | Stop Listening: `After Pause`. Language: your preference. |
| 2 | **Text** (Server URL) | `http://YOUR-SERVER-IP:4096` — save as variable `ServerURL` |
| 3 | **Text** (Session ID) | `YOUR-SESSION-ID` — save as variable `SessionID` |
| 4 | **Get Contents of URL** | See request config below |
| 5 | **Get Dictionary Value** | Key: `parts` from output of step 4 |
| 6 | **Get Item from List** | `First Item` from output of step 5 |
| 7 | **Get Dictionary Value** | Key: `text` from output of step 6 |
| 8 | **Speak Text** | Output of step 7. Rate: `0.5` (adjust to preference). |

### Step 4 Request Config

- URL: `ServerURL/session/SessionID/message`
- Method: `POST`
- Headers: `Content-Type: application/json`; if auth enabled: `Authorization: Basic <base64(user:password)>` — default username `user` (override with `OPENCODE_SERVER_USERNAME`). Encode: `echo -n "user:password" | base64`.
- Request Body (JSON):

  ```json
  {
    "parts": [{ "type": "text", "text": "Dictated Text" }]
  }
  ```

  Use the `Dictated Text` variable from step 1 as the `text` value.

### Optional Enhancements

**Error handling**: After step 4, add `If` action checking `Contents of URL` is not empty. Failure branch: `Show Alert` with "Could not reach OpenCode server".

**Auto session creation**: Before step 4, POST to `ServerURL/session`, extract `id` from response, use as `SessionID`.

## Async Variant (Fire-and-Forget)

Change step 4 URL to `ServerURL/session/SessionID/prompt_async` (returns `204 No Content` immediately). Remove steps 5-8. Add `Show Notification` with "Command sent". Useful for background tasks like "run the test suite" or "deploy to staging".

## Siri Integration

Name the shortcut something natural (e.g., "Ask OpenCode") — Siri suggests it automatically. Or: Settings > Siri & Search > My Shortcuts > add a trigger phrase.

## Security

- **Always use authentication** when exposing beyond localhost
- **Tailscale** provides encryption in transit without additional TLS
- **Never expose** port 4096 to the public internet without authentication
- Store server password as an iOS Shortcuts variable, not hardcoded in the URL
- OpenCode server has full tool access — treat it like SSH access to your machine

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Could not connect to server" | Verify server running: `curl http://SERVER:4096/global/health` |
| "Connection refused" | Check firewall allows port 4096; verify `--hostname 0.0.0.0` |
| Timeout on response | Long AI operations may exceed iOS timeout; use async variant |
| Empty response | Check session ID valid: `curl http://SERVER:4096/session/SESSION_ID` |
| Auth failure | Verify Base64 encoding of `user:password`; check `OPENCODE_SERVER_PASSWORD` |
| Tailscale not connecting | Ensure both devices logged in and Tailscale active on iPhone |

## See Also

- `tools/ai-assistants/opencode-server.md` — OpenCode server API reference
- `tools/voice/speech-to-speech.md` — Full speech-to-speech pipeline
- `tools/voice/voice-models.md` — TTS/STT model options
- `tools/mobile/ios-simulator-mcp.md` — iOS simulator testing
