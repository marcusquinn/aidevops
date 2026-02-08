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
- **Flow**: Dictate (iOS STT) -> HTTP POST to OpenCode server -> Wait for response -> Speak (iOS TTS)
- **Network**: Requires OpenCode server reachable from iPhone (Tailscale, local Wi-Fi, or port forward)
- **Related**: `tools/voice/speech-to-speech.md` (full pipeline), `tools/ai-assistants/opencode-server.md` (server API)

<!-- AI-CONTEXT-END -->

## Architecture

```text
iPhone                          Mac/Server
┌──────────────────┐           ┌──────────────────────────┐
│  iOS Shortcuts    │           │  OpenCode Server         │
│                   │           │  (opencode serve)        │
│  1. Dictate       │           │                          │
│     (iOS STT)     │           │  POST /session/:id/      │
│  2. HTTP POST ────┼──────────>│       message            │
│  3. Wait for      │<──────────┼── JSON response          │
│     response      │           │                          │
│  4. Speak         │           │  Processes prompt via    │
│     (iOS TTS)     │           │  AI model + tools        │
└──────────────────┘           └──────────────────────────┘
        │                               │
        └───── Tailscale / Wi-Fi ───────┘
```

## Prerequisites

1. **OpenCode server running** on your Mac or a remote server:

   ```bash
   # Local (Mac)
   opencode serve --port 4096 --hostname 0.0.0.0

   # With authentication (recommended for network exposure)
   OPENCODE_SERVER_PASSWORD=your-password opencode serve --port 4096 --hostname 0.0.0.0
   ```

2. **Network connectivity** from iPhone to server:
   - **Tailscale** (recommended): Install on both devices, use Tailscale IP (e.g., `100.x.y.z:4096`)
   - **Same Wi-Fi**: Use Mac's local IP (e.g., `192.168.1.x:4096`)
   - **Port forwarding**: Forward port 4096 through router (less secure)

3. **Session ID**: Create a session once and reuse it. Get one via:

   ```bash
   curl -X POST http://localhost:4096/session \
     -H "Content-Type: application/json" \
     -d '{"title": "iPhone Voice Dispatch"}'
   # Returns: {"id": "session-uuid-here", ...}
   ```

## Shortcut Setup

### Step-by-Step in iOS Shortcuts App

Create a new Shortcut with these actions in order:

**1. Dictate Text**

- Action: `Dictate Text`
- Stop Listening: `After Pause`
- Language: Your preferred language
- This captures your voice and converts to text via iOS built-in STT

**2. Set Variable (Server URL)**

- Action: `Text`
- Content: `http://YOUR-SERVER-IP:4096`
- Save as variable: `ServerURL`

Replace `YOUR-SERVER-IP` with your Tailscale IP or local network IP.

**3. Set Variable (Session ID)**

- Action: `Text`
- Content: `YOUR-SESSION-ID`
- Save as variable: `SessionID`

Replace with the session ID from the prerequisite step.

**4. Get Contents of URL (HTTP POST)**

- Action: `Get Contents of URL`
- URL: `ServerURL/session/SessionID/message`
- Method: `POST`
- Headers:
  - `Content-Type`: `application/json`
  - `Authorization`: `Basic base64(user:password)` (if auth enabled)
- Request Body (JSON):

  ```json
  {
    "parts": [
      {
        "type": "text",
        "text": "Dictated Text"
      }
    ]
  }
  ```

  Use the `Dictated Text` variable from step 1 as the `text` value.

**5. Get Dictionary Value**

- Action: `Get Dictionary Value`
- Get: Value for key `parts`
- From: `Contents of URL` (output of step 4)

**6. Get Item from List**

- Action: `Get Item from List`
- Get: `First Item`
- From: output of step 5

**7. Get Dictionary Value (response text)**

- Action: `Get Dictionary Value`
- Get: Value for key `text`
- From: output of step 6

**8. Speak Text**

- Action: `Speak Text`
- Text: output of step 7
- Rate: `0.5` (adjust to preference)
- Language: Match your dictation language

### Optional Enhancements

**Add authentication** (if `OPENCODE_SERVER_PASSWORD` is set):

- In step 4, add header: `Authorization: Basic <base64(user:password)>`
- Default username is `user` unless `OPENCODE_SERVER_USERNAME` is set
- Encode with: `echo -n "user:password" | base64`

**Add error handling**:

- After step 4, add `If` action checking `Contents of URL` is not empty
- On failure branch, use `Show Alert` with "Could not reach OpenCode server"

**Add session creation** (auto-create if needed):

- Before step 4, add a `Get Contents of URL` to `ServerURL/session` with POST
- Extract the `id` from the response and use it as `SessionID`

## Shortcut JSON (Import-Ready)

For quick setup, create a shortcut manually following the steps above. iOS Shortcuts does not support direct JSON import, but you can share shortcuts via iCloud links once created.

## Async Variant

For fire-and-forget commands (no response needed):

- Change the URL in step 4 to: `ServerURL/session/SessionID/prompt_async`
- This returns `204 No Content` immediately
- Remove steps 5-8 (no response to parse/speak)
- Add `Show Notification` with "Command sent" as confirmation

This is useful for triggering background tasks like "run the test suite" or "deploy to staging".

## Siri Integration

Once the Shortcut is created:

1. Open **Settings > Siri & Search**
2. Find your shortcut under **My Shortcuts**
3. Add a Siri phrase (e.g., "Hey Siri, ask OpenCode")
4. Now you can trigger it hands-free

Alternatively, name the shortcut something natural like "Ask OpenCode" and Siri will suggest it automatically.

## Network Configuration

### Tailscale (Recommended)

Tailscale creates a private mesh VPN between your devices:

1. Install Tailscale on Mac and iPhone
2. Sign in with same account
3. Use Mac's Tailscale IP (shown in Tailscale app, e.g., `100.64.0.1`)
4. Set `ServerURL` to `http://100.64.0.1:4096`

Benefits: Works from anywhere (not just home Wi-Fi), encrypted, no port forwarding needed.

### Local Wi-Fi

1. Find Mac's IP: **System Settings > Wi-Fi > Details > IP Address**
2. Set `ServerURL` to `http://192.168.x.x:4096`
3. Ensure both devices are on the same network

Limitation: Only works on the same Wi-Fi network.

### Security Considerations

- **Always use authentication** when exposing the server beyond localhost
- **Tailscale** provides encryption in transit without additional TLS setup
- **Never expose** port 4096 to the public internet without authentication
- Store the server password in iOS Shortcuts as a variable (not hardcoded in the URL)
- The OpenCode server processes prompts with full tool access -- treat it like SSH access to your machine

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Could not connect to server" | Verify server is running: `curl http://SERVER:4096/global/health` |
| "Connection refused" | Check firewall allows port 4096; verify `--hostname 0.0.0.0` |
| Timeout on response | Long AI operations may exceed iOS timeout; use async variant |
| Empty response | Check session ID is valid: `curl http://SERVER:4096/session/SESSION_ID` |
| Auth failure | Verify Base64 encoding of `user:password`; check `OPENCODE_SERVER_PASSWORD` |
| Tailscale not connecting | Ensure both devices are logged in and Tailscale is active on iPhone |

## See Also

- `tools/ai-assistants/opencode-server.md` - Full OpenCode server API reference
- `tools/voice/speech-to-speech.md` - Full speech-to-speech pipeline (for advanced voice setups)
- `tools/voice/voice-models.md` - TTS/STT model options
- `tools/mobile/ios-simulator-mcp.md` - iOS simulator testing
