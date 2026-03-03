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

- **Type**: Apple iMessage bot integration via two paths: BlueBubbles (full-featured) or imsg CLI (send-only)
- **Platform**: macOS only (Messages.app required as iMessage relay)
- **BlueBubbles**: REST API, webhook-based, DMs/groups/reactions/attachments/typing/read receipts
- **imsg CLI**: Swift-based, send-only, no incoming message handling
- **BlueBubbles repo**: [github.com/BlueBubblesApp/bluebubbles-server](https://github.com/BlueBubblesApp/bluebubbles-server) (Apache-2.0)
- **imsg repo**: [github.com/steipete/imsg](https://github.com/steipete/imsg) (MIT)
- **Encryption**: iMessage uses E2E encryption (Apple-managed keys); BlueBubbles accesses messages locally on the Mac
- **Identifier**: Apple ID (email) or phone number required
- **Privacy**: Apple cannot read message content; metadata (who, when, IP) visible to Apple

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
┌──────────────────────┐
│ iPhone / iPad /       │
│ Mac (sender)          │
│                       │
│ Messages.app          │
└──────────┬───────────┘
           │ iMessage Protocol (E2E encrypted)
           │ Apple Push Notification service (APNs)
           │
┌──────────▼───────────┐
│ Apple iMessage        │
│ Servers (relay only)  │
│ (cannot read content) │
└──────────┬───────────┘
           │
┌──────────▼───────────┐
│ macOS Host            │
│ Messages.app          │
│ (signed-in Apple ID)  │
│                       │
│ ┌──────────────────┐  │
│ │ BlueBubbles       │  │
│ │ Server            │  │
│ │ (reads Messages   │  │
│ │  SQLite DB +      │  │
│ │  AppleScript)     │  │
│ └────────┬─────────┘  │
│          │ REST API    │
│          │ + Webhooks  │
└──────────┼───────────┘
           │
┌──────────▼───────────┐
│ Bot Process            │
│ (any language/runtime) │
│                        │
│ ├─ Webhook receiver    │
│ ├─ Command router      │
│ ├─ aidevops dispatch   │
│ └─ Response sender     │
└────────────────────────┘
```

**Message flow (inbound)**:

1. Sender's device encrypts message with iMessage protocol (RSA/ECDSA + AES)
2. Encrypted message relayed via APNs to recipient's Apple ID
3. macOS host's Messages.app decrypts and stores in local SQLite database
4. BlueBubbles server detects new message (filesystem events on chat.db)
5. BlueBubbles fires webhook to bot process with message payload
6. Bot processes message and responds via BlueBubbles REST API
7. BlueBubbles sends response through Messages.app (AppleScript)
8. Messages.app encrypts and sends via iMessage protocol

**Message flow (imsg CLI — send-only)**:

1. Bot calls `imsg send` with recipient and message text
2. imsg uses AppleScript to send via Messages.app
3. Messages.app encrypts and sends via iMessage protocol
4. No inbound message handling — imsg is fire-and-forget

## Integration Path 1: BlueBubbles (Recommended)

BlueBubbles is a full-featured iMessage bridge that exposes a REST API and webhook system. It runs as a macOS application alongside Messages.app.

### Requirements

- **macOS** 11 (Big Sur) or later
- **Messages.app** signed in with an Apple ID
- **Full Disk Access** granted to BlueBubbles (System Settings > Privacy & Security)
- **Accessibility** permissions for AppleScript automation
- **Persistent macOS session** — Messages.app must remain running (no sleep/logout)

### Installation

Download the DMG from [BlueBubbles GitHub Releases](https://github.com/BlueBubblesApp/bluebubbles-server/releases) and install manually. The `bluebubbles` Homebrew cask is deprecated (disabled 2026-09-01) due to a macOS Gatekeeper issue — do not use `brew install --cask bluebubbles`.

```bash
# 1. Download latest .dmg from GitHub Releases:
#    https://github.com/BlueBubblesApp/bluebubbles-server/releases
# 2. Open the .dmg and drag BlueBubbles to /Applications
# 3. On first launch, right-click > Open to bypass Gatekeeper

# Launch and complete setup wizard:
# 1. Grant Full Disk Access
# 2. Grant Accessibility permissions
# 3. Configure server password
# 4. Set up Cloudflare tunnel or local network access
# 5. Verify Messages.app is signed in
```

### Server Configuration

BlueBubbles server exposes configuration via its GUI and config file:

| Setting | Default | Description |
|---------|---------|-------------|
| Server port | `1234` | Local REST API port |
| Password | (required) | API authentication password |
| Proxy service | Cloudflare | Tunnel for remote access (Cloudflare, Ngrok, or Dynamic DNS) |
| Check interval | `1000ms` | How often to poll chat.db for new messages |
| Auto-start | Off | Launch BlueBubbles on macOS login |

**Headless/VM considerations**:

- Messages.app requires an active GUI session — headless macOS VMs need a virtual display
- Use `caffeinate -d` or Amphetamine to prevent sleep
- For Mac mini servers: enable auto-login, disable screen lock
- For VMs (UTM, Parallels): ensure GPU passthrough or virtual display is configured
- iCloud sign-in may require 2FA — complete interactively before going headless

### REST API

BlueBubbles exposes a comprehensive REST API. All requests require the server password as a query parameter or header.

#### Authentication

```bash
# Query parameter authentication
curl "http://localhost:1234/api/v1/chat?password=YOUR_PASSWORD"

# Or header authentication
curl -H "Authorization: Bearer YOUR_PASSWORD" \
  "http://localhost:1234/api/v1/chat"
```

#### Key Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/chat` | List all chats (DMs and groups) |
| GET | `/api/v1/chat/:guid/message` | Get messages for a chat |
| POST | `/api/v1/message/text` | Send a text message |
| POST | `/api/v1/message/attachment` | Send an attachment |
| POST | `/api/v1/message/react` | Send a reaction (tapback) |
| GET | `/api/v1/contact` | List contacts |
| GET | `/api/v1/handle` | List handles (phone/email addresses) |
| GET | `/api/v1/server/info` | Server status and version |
| GET | `/api/v1/fcm/client` | Firebase Cloud Messaging config |

#### Sending Messages

```bash
# Send text message to individual
curl -X POST "http://localhost:1234/api/v1/message/text" \
  -H "Content-Type: application/json" \
  -d '{
    "chatGuid": "iMessage;-;+1234567890",
    "message": "Hello from the bot!",
    "method": "apple-script",
    "password": "YOUR_PASSWORD"
  }'

# Send text to group chat
curl -X POST "http://localhost:1234/api/v1/message/text" \
  -H "Content-Type: application/json" \
  -d '{
    "chatGuid": "iMessage;+;chat123456",
    "message": "Hello group!",
    "method": "apple-script",
    "password": "YOUR_PASSWORD"
  }'

# Send attachment
curl -X POST "http://localhost:1234/api/v1/message/attachment" \
  -F "chatGuid=iMessage;-;+1234567890" \
  -F "attachment=@/path/to/file.png" \
  -F "password=YOUR_PASSWORD"

# Send reaction (tapback)
curl -X POST "http://localhost:1234/api/v1/message/react" \
  -H "Content-Type: application/json" \
  -d '{
    "chatGuid": "iMessage;-;+1234567890",
    "selectedMessageGuid": "p:0/MESSAGE-GUID",
    "reaction": "love",
    "password": "YOUR_PASSWORD"
  }'
```

**Chat GUID format**:

| Type | Format | Example |
|------|--------|---------|
| DM (phone) | `iMessage;-;+{number}` | `iMessage;-;+14155551234` |
| DM (email) | `iMessage;-;{email}` | `iMessage;-;user@example.com` |
| Group | `iMessage;+;chat{id}` | `iMessage;+;chat123456789` |
| SMS fallback | `SMS;-;+{number}` | `SMS;-;+14155551234` |

**Reaction types**: `love`, `like`, `dislike`, `laugh`, `emphasize`, `question`

#### Webhooks

BlueBubbles can send webhooks for real-time event notification:

```bash
# Configure webhook URL in BlueBubbles settings
# Or via API:
curl -X POST "http://localhost:1234/api/v1/server/webhook" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "http://localhost:8080/webhook",
    "password": "YOUR_PASSWORD"
  }'
```

**Webhook events**:

| Event | Description |
|-------|-------------|
| `new-message` | New message received (DM or group) |
| `updated-message` | Message edited or unsent |
| `typing-indicator` | Contact started/stopped typing |
| `read-receipt` | Message read by recipient |
| `group-name-change` | Group chat renamed |
| `participant-added` | Member added to group |
| `participant-removed` | Member removed from group |
| `participant-left` | Member left group |
| `chat-read-status-changed` | Chat marked read/unread |

**Webhook payload example** (`new-message`):

```json
{
  "type": "new-message",
  "data": {
    "guid": "p:0/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
    "text": "Hello bot!",
    "chatGuid": "iMessage;-;+14155551234",
    "handle": {
      "address": "+14155551234"
    },
    "dateCreated": 1700000000000,
    "isFromMe": false,
    "hasAttachments": false,
    "attachments": [],
    "associatedMessageGuid": null,
    "associatedMessageType": null
  }
}
```

### Messaging Features

| Feature | Supported | Notes |
|---------|-----------|-------|
| Send/receive text | Yes | DMs and groups |
| Attachments (images, files) | Yes | Send and receive |
| Reactions (tapbacks) | Yes | Love, like, dislike, laugh, emphasize, question |
| Reply threading | Yes | Via `selectedMessageGuid` |
| Edit messages | Yes | Detected via `updated-message` webhook |
| Unsend messages | Yes | Detected via `updated-message` webhook |
| Typing indicators | Yes | Inbound only (outbound requires private API) |
| Read receipts | Yes | Inbound and outbound |
| Group chat management | Partial | Read members; add/remove requires AppleScript |
| Contact info | Yes | Name, phone, email from Contacts.app |
| SMS fallback | Yes | When recipient not on iMessage |
| Rich links | Yes | URL previews generated by Messages.app |
| Mentions | No | iMessage does not have a mention protocol |
| Stickers/Memoji | No | Not exposed via API |

## Integration Path 2: imsg CLI (Simple Send-Only)

[imsg](https://github.com/steipete/imsg) is a lightweight Swift CLI for sending iMessages. It is send-only — no incoming message handling.

### Requirements

- **macOS** 12 (Monterey) or later
- **Messages.app** signed in with an Apple ID
- **Accessibility** permissions for the terminal app running imsg

### Installation

```bash
# Install via Homebrew
brew install steipete/tap/imsg

# Or build from source
git clone https://github.com/steipete/imsg.git
cd imsg
swift build -c release
cp .build/release/imsg /usr/local/bin/
```

### Usage

```bash
# Send text message
imsg send "+14155551234" "Hello from the CLI!"

# Send to email address
imsg send "user@example.com" "Hello via email handle"

# Send to group (by group name)
imsg send --group "Family" "Hello family!"

# Check if recipient has iMessage
imsg check "+14155551234"
```

### When to Use imsg vs BlueBubbles

| Criterion | imsg | BlueBubbles |
|-----------|------|-------------|
| Direction | Send only | Send and receive |
| Setup complexity | Minimal (brew install) | Moderate (GUI app + permissions) |
| Incoming messages | No | Yes (webhooks) |
| Reactions/tapbacks | No | Yes |
| Attachments | No | Yes |
| Typing indicators | No | Yes |
| Best for | Notifications, alerts, one-way updates | Interactive bots, two-way conversations |

**Recommendation**: Use imsg for simple notification pipelines (CI alerts, monitoring). Use BlueBubbles for anything interactive.

## macOS Host Requirements

Both integration paths require a dedicated macOS host running Messages.app.

### Hardware Options

| Option | Pros | Cons |
|--------|------|------|
| Mac mini (dedicated) | Reliable, always-on, native macOS | Hardware cost (~$600+) |
| Mac mini (shared) | Lower cost if already owned | Contention with other uses |
| macOS VM (UTM/Parallels) | No dedicated hardware | Requires Apple Silicon host, licensing |
| Cloud Mac (MacStadium, AWS EC2 Mac) | No local hardware | $50-200/month, latency |

### Keepalive Configuration

Messages.app must remain running and the Mac must not sleep:

```bash
# Prevent sleep (run in background)
caffeinate -d &

# Or use pmset (persistent across reboots)
sudo pmset -a sleep 0
sudo pmset -a disablesleep 1

# Auto-login (System Settings > Users & Groups > Login Options)
# Set automatic login to the user running Messages.app

# Launch Messages.app on login
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/System/Applications/Messages.app", hidden:true}'

# Verify Messages.app is running
pgrep -x Messages && echo "Running" || echo "Not running"

# Restart Messages.app if crashed
if ! pgrep -x Messages > /dev/null; then
  open -a Messages
fi
```

### Monitoring Script

```bash
#!/bin/bash
# imessage-keepalive.sh — ensure Messages.app and BlueBubbles stay running
# Run via launchd: sh.aidevops.imessage-keepalive

check_and_restart() {
  local app_name="$1"

  # Use pgrep -x for exact process name match (avoids substring false positives)
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

check_and_restart "Messages"      # com.apple.MobileSMS
check_and_restart "BlueBubbles"   # com.bluebubbles.server
```

## Access Control

### BlueBubbles API Security

- **Password authentication**: All API requests require the server password
- **Network binding**: Bind to `127.0.0.1` for local-only access; use Cloudflare tunnel for remote
- **Firewall**: Block port 1234 from external access if not using a tunnel

### Bot-Level Access Control

Implement access control in the bot process, not in BlueBubbles:

```text
Access control patterns:

1. Allowlist by phone/email
   - Maintain a list of approved senders
   - Ignore messages from unknown handles
   - Log rejected messages for audit

2. Allowlist by group
   - Only respond in specific group chats
   - Ignore DMs or vice versa

3. Command-level permissions
   - Different commands available to different users
   - Admin commands restricted to specific handles

4. Rate limiting
   - Per-sender message rate limits
   - Global rate limit to prevent abuse
   - Cooldown period after rapid messages

5. Content filtering
   - Scan inbound messages for prompt injection (prompt-guard-helper.sh)
   - Sanitize before passing to AI models
   - Block messages matching abuse patterns
```

### Credential Storage

```bash
# Store BlueBubbles password securely
aidevops secret set BLUEBUBBLES_PASSWORD

# Or in credentials.sh (600 permissions)
# BLUEBUBBLES_PASSWORD="your-server-password"
# BLUEBUBBLES_URL="http://localhost:1234"

# Never expose the password in logs or bot output
```

## Privacy and Security Assessment

### iMessage Encryption

iMessage uses end-to-end encryption managed by Apple:

| Component | Detail |
|-----------|--------|
| Key exchange | IDS (Identity Services) — Apple-managed key directory |
| Key wrapping (classic) | RSA-OAEP (per Apple docs; modulus size not specified) + AES-128-CTR per message |
| Key wrapping (iOS 13+) | ECIES on NIST P-256 (available since iOS 13) + AES-128-CTR per message |
| Encryption (PQ3, iOS 17.4+) | Post-quantum key establishment + AES-256-CTR for payloads and attachments |
| Signing / authentication | ECDSA P-256 — used for sender authentication, not content encryption |
| Forward secrecy | Limited in classic iMessage — keys rotate on device changes, not per-message; PQ3 adds periodic rekeying |
| Key verification | Contact Key Verification (iOS 17.2+) — optional manual verification |
| Group encryption | Each message encrypted separately per recipient device |

**What Apple can see**:

- **Message content**: No — E2E encrypted, Apple does not hold decryption keys
- **Metadata**: Yes — who you message, when, your IP address, device info
- **Contact graph**: Yes — Apple knows your communication partners via IDS lookups
- **Push notifications**: APNs sees notification metadata (not content)
- **iCloud backups**: If iCloud Backup is enabled without Advanced Data Protection, Apple can access message backups (they hold the backup encryption key)

**What Apple cannot see**:

- Message text, images, attachments (E2E encrypted in transit)
- Message content in iCloud with Advanced Data Protection enabled (E2E encrypted at rest)

### Advanced Data Protection

With Advanced Data Protection (ADP) enabled:

- iCloud message backups are E2E encrypted — Apple cannot access them
- Recovery key or recovery contact required (no Apple-assisted recovery)
- Available on iOS 16.2+, macOS 13.1+

**Recommendation**: Enable ADP on the macOS host running the bot to ensure message backups are E2E encrypted.

### BlueBubbles Security Model

BlueBubbles accesses messages by reading the local Messages.app SQLite database (`~/Library/Messages/chat.db`). This means:

| Aspect | Implication |
|--------|-------------|
| Message access | BlueBubbles reads decrypted messages from the local database |
| No protocol interception | Does not intercept or modify the iMessage protocol |
| Local only | Messages are only accessible on the Mac where Messages.app runs |
| Full Disk Access | Required permission — grants broad filesystem access |
| AppleScript | Used for sending — requires Accessibility permission |
| No Apple account access | BlueBubbles does not have Apple ID credentials |

**Threat model**:

- **Mac compromise** = full message access (same as any local app with Full Disk Access)
- **Network exposure** = API password protects against unauthorized access; use tunnel + firewall
- **BlueBubbles server compromise** = attacker can read/send messages as the bot's Apple ID
- **Apple cooperation** = Apple can provide metadata (not content) to law enforcement

### Comparison with Other Protocols

| Aspect | iMessage | Signal | SimpleX | Matrix |
|--------|----------|--------|---------|--------|
| E2E encryption | Yes (Apple-managed) | Yes (user-managed) | Yes (user-managed) | Optional (Megolm) |
| Forward secrecy | Limited | Yes (per-message) | Yes (double ratchet) | Yes (Megolm ratchet) |
| Metadata protection | Low (Apple sees metadata) | Moderate (sealed sender) | High (no identifiers) | Low (server sees metadata) |
| Open protocol | No (closed, proprietary) | Partially open | Fully open | Fully open |
| Independent audit | Apple publishes security guide; no independent protocol audit | Independently audited | Independently audited | Independently audited |
| Key verification | Contact Key Verification (iOS 17.2+) | Safety numbers | QR code / fingerprint | Cross-signing |
| AI training | Apple states iMessage content is not used for AI training | Not used | Not applicable | Depends on server |

### Apple Privacy Policy Summary

- Apple's privacy policy states iMessage content is **not** used for advertising or AI model training
- iMessage data is **not** sold to third parties
- Apple may provide metadata to law enforcement with valid legal process
- Siri suggestions may use on-device message analysis (local, not sent to Apple)
- With ADP disabled, iCloud backups are accessible to Apple (and thus to law enforcement with warrant)

### Recommendations

1. **Enable Advanced Data Protection** on the macOS host
2. **Disable iCloud Backup for Messages** if ADP is not available
3. **Use a dedicated Apple ID** for the bot — not a personal account
4. **Bind BlueBubbles to localhost** and use Cloudflare tunnel for remote access
5. **Rotate the BlueBubbles server password** periodically
6. **Monitor the macOS host** for unauthorized access (FileVault, firewall, login alerts)
7. **Do not store sensitive data in iMessage conversations** — metadata is visible to Apple

## Integration with aidevops

### Runner Dispatch Pattern

```text
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ iMessage User    │     │ Bot Process       │     │ aidevops Runner  │
│                  │     │ (webhook handler) │     │                  │
│ Sends:           │────▶│ 1. Receive webhook│────▶│ runner-helper.sh │
│ "/ask How do I   │     │ 2. Check perms    │     │ → AI session     │
│  deploy X?"      │     │ 3. Parse command  │     │ → response       │
│                  │◀────│ 4. Dispatch       │◀────│                  │
│ Gets AI response │     │ 5. Send response  │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Bot Webhook Handler (Conceptual)

```bash
# Minimal webhook handler pattern (pseudocode)
# Receives BlueBubbles webhook, dispatches to runner, sends response

# 1. Start webhook listener on port 8080
# 2. On POST /webhook:
#    - Parse JSON payload
#    - Check event type == "new-message"
#    - Check sender is in allowlist
#    - Extract message text and chatGuid
#    - If message starts with command prefix:
#      - Dispatch to runner via runner-helper.sh
#      - Send response via BlueBubbles API
#    - Log interaction
```

### Integration Components

| Component | Status | Description |
|-----------|--------|-------------|
| Subagent doc | This file | iMessage integration reference |
| BlueBubbles setup | Manual | Install BlueBubbles on macOS host |
| Bot webhook handler | To build | Receives webhooks, dispatches to runners |
| imsg notifications | Available | `brew install steipete/tap/imsg` for send-only |
| Keepalive monitor | Template above | Ensures Messages.app + BlueBubbles stay running |

### Matterbridge Integration

iMessage is **not** natively supported by Matterbridge. However, BlueBubbles can bridge to other platforms:

1. **BlueBubbles API → custom adapter → Matterbridge API**: Write a small adapter that translates BlueBubbles webhooks to Matterbridge API messages
2. **BlueBubbles → bot → Matrix → Matterbridge**: Route through Matrix as an intermediary

See `services/communications/matterbridge.md` for Matterbridge configuration.

## Limitations

### Platform Lock-In

- **macOS only** — iMessage protocol is proprietary and requires Apple hardware/software
- **Apple ID required** — bot needs a dedicated Apple ID with iMessage enabled
- **No Linux/Windows** — cannot run on non-Apple platforms
- **No official API** — BlueBubbles is a third-party workaround, not an Apple-supported integration

### Reliability Concerns

- **Messages.app crashes** — requires monitoring and auto-restart
- **macOS updates** — may break BlueBubbles compatibility temporarily
- **Apple ID lockouts** — unusual activity (bot-like patterns) may trigger Apple security
- **iCloud sync conflicts** — if the Apple ID is signed in on multiple devices, message delivery may be inconsistent
- **AppleScript fragility** — sending relies on AppleScript automation, which Apple may restrict in future macOS versions

### Feature Gaps

- **No mention system** — iMessage has no @mention protocol
- **No bot profile** — cannot distinguish bot from regular user in the UI
- **No command menus** — unlike Telegram or SimpleX, no native command discovery
- **Limited group management** — creating groups and managing members programmatically is fragile
- **No message search API** — BlueBubbles can query the local database, but no full-text search endpoint

### Legal and ToS Considerations

- BlueBubbles accesses Messages.app via AppleScript and direct database reads — this is not an Apple-sanctioned integration method
- Apple's Terms of Service do not explicitly prohibit this use, but automated messaging at scale could trigger account restrictions
- Use a dedicated Apple ID for the bot to isolate risk from personal accounts
- Do not use for spam or unsolicited messaging — Apple may disable the Apple ID

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Messages.app not running | Check `pgrep -x Messages`; restart with `open -a Messages` |
| BlueBubbles can't read messages | Grant Full Disk Access in System Settings > Privacy & Security |
| Send fails via AppleScript | Grant Accessibility permission to BlueBubbles |
| Mac sleeping | Run `caffeinate -d &` or `sudo pmset -a sleep 0` |
| API returns 401 | Check server password in request |
| Webhook not firing | Verify webhook URL is reachable from the Mac; check BlueBubbles logs |
| iMessage not activating | Verify Apple ID is signed in to Messages.app; check internet connection |
| SMS instead of iMessage | Recipient may not have iMessage; check with `imsg check` |
| Apple ID locked | Too many automated messages; wait 24h or contact Apple support |
| macOS update broke BlueBubbles | Check BlueBubbles GitHub releases for compatible version |

## Related

- `.agents/services/communications/simplex.md` — SimpleX messaging (maximum privacy, no identifiers)
- `.agents/services/communications/matrix-bot.md` — Matrix bot for runner dispatch
- `.agents/services/communications/matterbridge.md` — Multi-platform chat bridge
- `.agents/services/communications/twilio.md` — SMS/voice via Twilio (cross-platform)
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- BlueBubbles docs: https://docs.bluebubbles.app/
- Apple iMessage security: https://support.apple.com/guide/security/imessage-security-overview-secd9764312f/web
- imsg CLI: https://github.com/steipete/imsg
