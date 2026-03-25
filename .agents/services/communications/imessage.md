---
description: iMessage/BlueBubbles bot integration — BlueBubbles REST API (recommended), imsg CLI (send-only), macOS requirements, messaging features, access control, privacy/security assessment, and aidevops runner dispatch
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

# iMessage / BlueBubbles Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Platform**: macOS only (Messages.app required as iMessage relay)
- **BlueBubbles**: Full-featured REST API + webhooks — DMs/groups/reactions/attachments/typing/read receipts
- **imsg CLI**: Swift-based, send-only, no incoming message handling
- **BlueBubbles repo**: [github.com/BlueBubblesApp/bluebubbles-server](https://github.com/BlueBubblesApp/bluebubbles-server) (Apache-2.0)
- **imsg repo**: [github.com/steipete/imsg](https://github.com/steipete/imsg) (MIT)
- **Encryption**: iMessage uses E2E encryption (Apple-managed keys); BlueBubbles accesses messages locally on the Mac
- **Identifier**: Apple ID (email) or phone number required

**When to use iMessage vs other protocols**:

| Criterion | iMessage (BlueBubbles) | SimpleX | Matrix | Signal |
|-----------|------------------------|---------|--------|--------|
| User identifiers | Apple ID / phone | None | `@user:server` | Phone |
| E2E encryption | Yes (Apple-managed) | Yes (user-managed) | Optional | Yes |
| Server requirement | macOS host + Messages.app | SMP relays | Homeserver | Signal servers |
| Bot ecosystem | BlueBubbles REST API | WebSocket API | Mature SDK | Limited |
| Best for | Reaching Apple users natively | Maximum privacy | Team collaboration | Secure 1:1 |
| Open source | Server: yes; protocol: no | Fully open | Fully open | Partially open |

<!-- AI-CONTEXT-END -->

## Architecture

```text
iPhone/iPad/Mac → iMessage Protocol (E2E encrypted) → Apple Servers (relay only)
                                                              ↓
macOS Host: Messages.app + BlueBubbles Server (reads chat.db + AppleScript)
                                                              ↓ REST API + Webhooks
                                                       Bot Process
                                                       ├─ Webhook receiver
                                                       ├─ Command router
                                                       ├─ aidevops dispatch
                                                       └─ Response sender
```

**Inbound flow**: Sender encrypts → APNs relay → Messages.app decrypts to local SQLite → BlueBubbles detects via filesystem events → fires webhook → bot responds via BlueBubbles REST API → Messages.app encrypts and sends.

**imsg flow**: Bot calls `imsg send` → AppleScript → Messages.app → iMessage. Fire-and-forget, no inbound handling.

## Integration Path 1: BlueBubbles (Recommended)

### Requirements

- macOS 11 (Big Sur) or later, Messages.app signed in with Apple ID
- Full Disk Access granted to BlueBubbles (System Settings > Privacy & Security)
- Accessibility permissions for AppleScript automation
- Persistent macOS session — Messages.app must remain running

### Installation

Download the DMG from [BlueBubbles GitHub Releases](https://github.com/BlueBubblesApp/bluebubbles-server/releases). The `bluebubbles` Homebrew cask is deprecated (disabled 2026-09-01) — do not use `brew install --cask bluebubbles`.

```bash
# 1. Download latest .dmg from GitHub Releases
# 2. Open .dmg, drag BlueBubbles to /Applications
# 3. Right-click > Open to bypass Gatekeeper on first launch
# 4. Grant Full Disk Access + Accessibility permissions
# 5. Configure server password and Cloudflare tunnel or local network access
```

### Server Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| Server port | `1234` | Local REST API port |
| Password | (required) | API authentication |
| Proxy service | Cloudflare | Tunnel for remote access |
| Check interval | `1000ms` | Poll frequency for chat.db |
| Auto-start | Off | Launch on macOS login |

**Headless/VM**: Messages.app requires an active GUI session. Use `caffeinate -d` to prevent sleep. For VMs (UTM, Parallels): ensure virtual display is configured. Complete iCloud 2FA interactively before going headless.

### REST API

All requests require the server password as a header (not query parameter — query strings are logged).

```bash
curl -H "Authorization: Bearer YOUR_PASSWORD" "http://localhost:1234/api/v1/chat"
```

#### Key Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/chat` | List all chats |
| GET | `/api/v1/chat/:guid/message` | Get messages for a chat |
| POST | `/api/v1/message/text` | Send text message |
| POST | `/api/v1/message/attachment` | Send attachment |
| POST | `/api/v1/message/react` | Send reaction (tapback) |
| GET | `/api/v1/contact` | List contacts |
| GET | `/api/v1/handle` | List handles |
| GET | `/api/v1/server/info` | Server status |

#### Sending Messages

```bash
# Text to individual
curl -X POST "http://localhost:1234/api/v1/message/text" \
  -H "Content-Type: application/json" -H "Authorization: Bearer YOUR_PASSWORD" \
  -d '{"chatGuid":"iMessage;-;+1234567890","message":"Hello!","method":"apple-script"}'

# Text to group
curl -X POST "http://localhost:1234/api/v1/message/text" \
  -H "Content-Type: application/json" -H "Authorization: Bearer YOUR_PASSWORD" \
  -d '{"chatGuid":"iMessage;+;chat123456","message":"Hello group!","method":"apple-script"}'

# Attachment
curl -X POST "http://localhost:1234/api/v1/message/attachment" \
  -H "Authorization: Bearer YOUR_PASSWORD" \
  -F "chatGuid=iMessage;-;+1234567890" -F "attachment=@/path/to/file.png"

# Reaction (tapback)
curl -X POST "http://localhost:1234/api/v1/message/react" \
  -H "Content-Type: application/json" -H "Authorization: Bearer YOUR_PASSWORD" \
  -d '{"chatGuid":"iMessage;-;+1234567890","selectedMessageGuid":"p:0/MSG-GUID","reaction":"love"}'
```

**Chat GUID format**:

| Type | Format |
|------|--------|
| DM (phone) | `iMessage;-;+14155551234` |
| DM (email) | `iMessage;-;user@example.com` |
| Group | `iMessage;+;chat123456789` |
| SMS fallback | `SMS;-;+14155551234` |

**Reaction types**: `love`, `like`, `dislike`, `laugh`, `emphasize`, `question`

#### Webhooks

```bash
curl -X POST "http://localhost:1234/api/v1/server/webhook" \
  -H "Content-Type: application/json" \
  -d '{"url":"http://localhost:8080/webhook","password":"YOUR_PASSWORD"}'
```

**Webhook events**: `new-message`, `updated-message`, `typing-indicator`, `read-receipt`, `group-name-change`, `participant-added`, `participant-removed`, `participant-left`, `chat-read-status-changed`

**`new-message` payload**:

```json
{
  "type": "new-message",
  "data": {
    "guid": "p:0/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
    "text": "Hello bot!", "chatGuid": "iMessage;-;+14155551234",
    "handle": {"address": "+14155551234"},
    "dateCreated": 1700000000000, "isFromMe": false,
    "hasAttachments": false, "attachments": []
  }
}
```

### Messaging Features

| Feature | Supported | Notes |
|---------|-----------|-------|
| Send/receive text | Yes | DMs and groups |
| Attachments | Yes | Send and receive |
| Reactions (tapbacks) | Yes | 6 types |
| Reply threading | Yes | Via `selectedMessageGuid` |
| Edit/unsend detection | Yes | Via `updated-message` webhook |
| Typing indicators | Yes | Inbound only |
| Read receipts | Yes | Inbound and outbound |
| Group chat management | Partial | Read members; add/remove via AppleScript |
| SMS fallback | Yes | When recipient not on iMessage |
| Mentions, Stickers/Memoji | No | Not exposed via API |

## Integration Path 2: imsg CLI (Simple Send-Only)

### Installation

```bash
brew install steipete/tap/imsg
# or build from source: git clone https://github.com/steipete/imsg.git && swift build -c release
```

**Requirements**: macOS 12+, Messages.app signed in, Accessibility permissions for terminal app.

### Usage

```bash
imsg send "+14155551234" "Hello from the CLI!"
imsg send "user@example.com" "Hello via email handle"
imsg send --group "Family" "Hello family!"
imsg check "+14155551234"  # Check if recipient has iMessage
```

### imsg vs BlueBubbles

| Criterion | imsg | BlueBubbles |
|-----------|------|-------------|
| Direction | Send only | Send and receive |
| Setup | Minimal (brew install) | Moderate (GUI app + permissions) |
| Incoming/Reactions/Attachments/Typing | No | Yes |
| Best for | Notifications, alerts, one-way updates | Interactive bots, two-way conversations |

## macOS Host Requirements

### Hardware Options

| Option | Pros | Cons |
|--------|------|------|
| Mac mini (dedicated) | Reliable, always-on | ~$600+ hardware cost |
| macOS VM (UTM/Parallels) | No dedicated hardware | Requires Apple Silicon host |
| Cloud Mac (MacStadium, AWS EC2) | No local hardware | $50-200/month |

### Keepalive Configuration

```bash
caffeinate -d &                          # Prevent sleep (session)
sudo pmset -a sleep 0                    # Prevent sleep (persistent)
# Enable auto-login: System Settings > Users & Groups > Login Options
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/System/Applications/Messages.app", hidden:true}'
pgrep -x Messages && echo "Running" || echo "Not running"
```

### Monitoring Script

```bash
#!/bin/bash
# imessage-keepalive.sh — ensure Messages.app and BlueBubbles stay running
# Run via launchd: sh.aidevops.imessage-keepalive

check_and_restart() {
  local app_name="$1"
  if ! pgrep -x "$app_name" > /dev/null; then
    echo "$(date): $app_name not running, restarting..."
    open -a "$app_name"
    sleep 5
    if pgrep -x "$app_name" > /dev/null; then
      echo "$(date): $app_name restarted successfully"
    else
      echo "$(date): ERROR: Failed to restart $app_name"
      return 1
    fi
  fi
  return 0
}

check_and_restart "Messages"
check_and_restart "BlueBubbles"
```

## Access Control

### BlueBubbles API Security

- Bind to `127.0.0.1` for local-only access; use Cloudflare tunnel for remote
- Block port 1234 from external access if not using a tunnel

### Bot-Level Access Control

Implement in the bot process, not in BlueBubbles:

1. **Allowlist by phone/email** — ignore messages from unknown handles, log rejections
2. **Allowlist by group** — only respond in specific group chats
3. **Command-level permissions** — admin commands restricted to specific handles
4. **Rate limiting** — per-sender limits, global limit, cooldown after rapid messages
5. **Content filtering** — scan inbound messages with `prompt-guard-helper.sh`, sanitize before passing to AI

### Credential Storage

```bash
aidevops secret set BLUEBUBBLES_PASSWORD
# Never expose the password in logs or bot output
```

## Privacy and Security

### iMessage Encryption

| Component | Detail |
|-----------|--------|
| Key exchange | IDS (Apple-managed key directory) |
| Key wrapping (classic) | RSA-OAEP + AES-128-CTR per message |
| Key wrapping (iOS 13+) | ECIES on NIST P-256 + AES-128-CTR |
| Encryption (PQ3, iOS 17.4+) | Post-quantum key establishment + AES-256-CTR |
| Signing | ECDSA P-256 (sender authentication) |
| Forward secrecy | Limited in classic; PQ3 adds periodic rekeying |
| Key verification | Contact Key Verification (iOS 17.2+, optional) |

**Apple can see**: Metadata (who, when, IP), contact graph via IDS lookups. **Apple cannot see**: Message content (E2E encrypted), content with Advanced Data Protection enabled.

**iCloud Backups**: If iCloud Backup is enabled without Advanced Data Protection, Apple can access message backups. Enable ADP (iOS 16.2+, macOS 13.1+) to make backups E2E encrypted.

### BlueBubbles Security Model

BlueBubbles reads the local Messages.app SQLite database (`~/Library/Messages/chat.db`):

- Does not intercept or modify the iMessage protocol
- Requires Full Disk Access (broad filesystem permission) and Accessibility (for AppleScript)
- **Threat model**: Mac compromise = full message access; network exposure mitigated by API password + tunnel; BlueBubbles server compromise = attacker can read/send as the bot's Apple ID

### Security Recommendations

1. Enable Advanced Data Protection on the macOS host
2. Use a dedicated Apple ID for the bot — not a personal account
3. Bind BlueBubbles to localhost, use Cloudflare tunnel for remote access
4. Rotate the BlueBubbles server password periodically
5. Monitor the macOS host (FileVault, firewall, login alerts)
6. Do not store sensitive data in iMessage — metadata is visible to Apple

## Integration with aidevops

### Runner Dispatch Pattern

```text
iMessage User → Bot Process (webhook handler) → aidevops Runner → AI session → response
```

### Bot Webhook Handler (Conceptual)

```bash
# Minimal pattern:
# 1. Start webhook listener on port 8080
# 2. On POST /webhook: parse JSON, check event type == "new-message"
# 3. Check sender is in allowlist, extract message text and chatGuid
# 4. If message starts with command prefix: dispatch to runner-helper.sh
# 5. Send response via BlueBubbles API, log interaction
```

### Matterbridge Integration

iMessage is not natively supported by Matterbridge. Options:
1. BlueBubbles API → custom adapter → Matterbridge API
2. BlueBubbles → bot → Matrix → Matterbridge

See `services/communications/matterbridge.md`.

## Limitations

**Platform lock-in**: macOS only, Apple ID required, no Linux/Windows, no official Apple API.

**Reliability**: Messages.app crashes require monitoring; macOS updates may break BlueBubbles; unusual bot-like activity may trigger Apple ID lockouts; AppleScript may be restricted in future macOS versions.

**Feature gaps**: No @mention system, no bot profile distinction, no command menus, limited group management, no full-text search API.

**Legal**: BlueBubbles uses AppleScript and direct DB reads — not Apple-sanctioned. Use a dedicated Apple ID; do not use for spam.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Messages.app not running | `pgrep -x Messages`; restart with `open -a Messages` |
| BlueBubbles can't read messages | Grant Full Disk Access in System Settings > Privacy & Security |
| Send fails via AppleScript | Grant Accessibility permission to BlueBubbles |
| Mac sleeping | `caffeinate -d &` or `sudo pmset -a sleep 0` |
| API returns 401 | Check server password in request |
| Webhook not firing | Verify webhook URL is reachable; check BlueBubbles logs |
| iMessage not activating | Verify Apple ID signed in to Messages.app; check internet |
| SMS instead of iMessage | Recipient may not have iMessage; check with `imsg check` |
| Apple ID locked | Too many automated messages; wait 24h or contact Apple support |
| macOS update broke BlueBubbles | Check BlueBubbles GitHub releases for compatible version |

## Related

- `.agents/services/communications/simplex.md` — SimpleX messaging (maximum privacy)
- `.agents/services/communications/matrix-bot.md` — Matrix bot for runner dispatch
- `.agents/services/communications/matterbridge.md` — Multi-platform chat bridge
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- BlueBubbles docs: https://docs.bluebubbles.app/
- Apple iMessage security: https://support.apple.com/guide/security/imessage-security-overview-secd9764312f/web
- imsg CLI: https://github.com/steipete/imsg
