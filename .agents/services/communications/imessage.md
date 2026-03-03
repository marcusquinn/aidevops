---
description: iMessage / BlueBubbles — Apple encrypted messaging, BlueBubbles REST API bot integration, imsg CLI send-only, macOS-only requirement, security model, SMS fallback risks
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

- **Type**: Apple's encrypted messaging — E2E encrypted, Apple ecosystem only
- **License**: BlueBubbles (Apache-2.0), imsg CLI (MIT, [github.com/steipete/imsg](https://github.com/steipete/imsg))
- **Bot tools**: BlueBubbles REST API (recommended, full-featured) OR imsg CLI (simple send-only)
- **Protocol**: Apple Push Notification service (APNs) + iMessage protocol
- **Encryption**: E2E (PQ3 with AES-256-CTR on iOS 17.4+; classic: RSA-OAEP/ECIES key wrapping + AES-128-CTR; ECDSA P-256 for signing)
- **BlueBubbles server**: [github.com/BlueBubblesApp/bluebubbles-server](https://github.com/BlueBubblesApp/bluebubbles-server)
- **BlueBubbles docs**: [docs.bluebubbles.app](https://docs.bluebubbles.app/)
- **Requirement**: macOS host with Messages.app (always-on Mac, Apple ID signed in)
- **Platforms**: iMessage users only (iPhone, iPad, Mac, Apple Watch, Apple Vision Pro)

**Key differentiator**: iMessage is the default messaging platform for over 1 billion Apple users. Unlike open protocols (Matrix, SimpleX, XMTP), iMessage has no official bot API — BlueBubbles provides an unofficial bridge by wrapping Messages.app on a macOS host. This makes it the only viable path for programmatic iMessage interaction.

**When to use iMessage vs other protocols**:

| Criterion | iMessage (BlueBubbles) | SimpleX | Matrix | Signal |
|-----------|----------------------|---------|--------|--------|
| User base | 1B+ Apple users | Growing niche | Enterprise/tech | 40M+ |
| Identity | Apple ID / phone | None | `@user:server` | Phone number |
| E2E encryption | Yes (closed source) | Yes (audited) | Optional (Megolm) | Yes (audited) |
| Official bot API | No (unofficial only) | WebSocket JSON | First-class SDK | No |
| Open source | No (BlueBubbles is) | Yes (AGPL-3.0) | Yes | Yes |
| Platform | Apple-only | Cross-platform | Cross-platform | Cross-platform |
| Best for | Reaching Apple users | Privacy-first | Team collaboration | Privacy + mainstream |

<!-- AI-CONTEXT-END -->

## Architecture

```text
Path 1: BlueBubbles (bidirectional)       Path 2: imsg CLI (send-only)

┌───────────────────┐                     ┌───────────────────┐
│ iPhone / iPad /   │                     │ aidevops runner / │
│ Mac Users         │                     │ cron job / script │
└────────┬──────────┘                     └────────┬──────────┘
         │ iMessage (E2E via APNs)                 │ shell exec
┌────────▼──────────┐                     ┌────────▼──────────┐
│ macOS Host        │                     │ imsg CLI (Swift)  │
│ ├─ Messages.app   │                     │ → Messages.app    │
│ ├─ BlueBubbles    │                     │ → iMessage / SMS  │
│ │  (Electron,     │                     └───────────────────┘
│ │   private APIs) │
│ └─ REST :1234     │
│    + WebSocket    │
└────────┬──────────┘
         │ HTTP REST + WebSocket
┌────────▼──────────┐
│ Bot Process       │
│ ├─ Webhook recv   │
│ ├─ Command router │
│ └─ aidevops       │
└───────────────────┘
```

**Message flow (BlueBubbles)**: User sends iMessage → APNs delivers to macOS host → Messages.app decrypts → BlueBubbles detects via private API → fires webhook/WebSocket to bot → bot replies via REST API → BlueBubbles instructs Messages.app → encrypted send via APNs.

## Installation

### Path 1: BlueBubbles Server (Recommended)

**Requirements**:

- macOS 11 (Big Sur) or later
- Apple ID signed into Messages.app
- Always-on Mac (Mac mini recommended for servers)
- Full Disk Access permission for BlueBubbles
- Accessibility permission for BlueBubbles

**Setup**:

1. Download BlueBubbles `.dmg` from [GitHub releases](https://github.com/BlueBubblesApp/bluebubbles-server/releases)
2. Install to `/Applications`, open, grant Full Disk Access + Accessibility permissions
3. Sign into Messages.app with your Apple ID (must be running)
4. Configure: set server password, port (default: 1234), enable Private API
5. Verify: `curl -s "http://localhost:1234/api/v1/server?password=YOUR_PASSWORD" | jq .`

**Private API setup** (required for full features):

BlueBubbles uses a "Private API" helper that hooks into macOS internals for features like typing indicators, read receipts, reactions, and message editing. This requires:

1. Disable SIP (System Integrity Protection) — **only on the server Mac**
2. Install the Private API helper bundle
3. Restart BlueBubbles

See: [docs.bluebubbles.app/private-api](https://docs.bluebubbles.app/server/private-api-setup)

**Headless / VM setup**: Prevent display sleep (`sudo pmset -a displaysleep 0 sleep 0`), create a launchd plist (`sh.aidevops.messages-keepalive.plist`) with `KeepAlive: true` to keep Messages.app running. For macOS VMs, use screen sharing for initial setup, then run headless.

### Path 2: imsg CLI (Send-Only)

```bash
# Install via Homebrew
brew install steipete/tap/imsg

# Or build from source
git clone https://github.com/steipete/imsg.git
cd imsg
swift build -c release
cp .build/release/imsg /usr/local/bin/

# Verify
imsg --version
```

**Usage**:

```bash
# Send a message to a phone number
imsg send "+1234567890" "Hello from aidevops"

# Send to an email (Apple ID)
imsg send "user@example.com" "Deployment complete"

# Send to a group chat (by group name)
imsg send --group "DevOps Team" "Build passed"
```

**Limitations**: imsg can only send messages. It cannot receive, read, or react to messages. For bidirectional communication, use BlueBubbles.

## Bot API (BlueBubbles)

### REST API Endpoints

All requests require the `password` query parameter or `Authorization` header.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/message` | GET | List messages (with pagination, filtering) |
| `/api/v1/message/:guid` | GET | Get specific message |
| `/api/v1/message/text` | POST | Send text message |
| `/api/v1/message/:chatGuid/tapback` | POST | Send reaction/tapback |
| `/api/v1/message/:guid/edit` | PUT | Edit a sent message |
| `/api/v1/message/:guid/unsend` | POST | Unsend a message |
| `/api/v1/chat` | GET | List chats (DMs and groups) |
| `/api/v1/chat/:guid` | GET | Get specific chat |
| `/api/v1/chat/new` | POST | Create new chat |
| `/api/v1/contact` | GET | List contacts |
| `/api/v1/attachment/:guid` | GET | Download attachment |
| `/api/v1/attachment/upload` | POST | Upload attachment |
| `/api/v1/server` | GET | Server info and status |
| `/api/v1/handle` | GET | List handles (phone numbers/emails) |

### WebSocket Real-Time Events

Connect to `ws://localhost:1234` for real-time events:

| Event | Description |
|-------|-------------|
| `new-message` | New message received |
| `updated-message` | Message edited or tapback added |
| `typing-indicator` | Contact started/stopped typing |
| `group-name-change` | Group chat renamed |
| `participant-added` | Member added to group |
| `participant-removed` | Member removed from group |
| `chat-read-status-changed` | Chat marked as read |

### Features

| Feature | BlueBubbles API | imsg CLI |
|---------|----------------|----------|
| Send DM | Yes | Yes |
| Send group message | Yes | Yes (by name) |
| Receive messages | Yes (webhook/WebSocket) | No |
| Reactions/tapbacks | Yes (Private API) | No |
| Edit message | Yes (Private API, macOS 13+) | No |
| Unsend message | Yes (Private API, macOS 13+) | No |
| Reply threading | Yes (Private API) | No |
| Attachments (send) | Yes | No |
| Attachments (receive) | Yes | No |
| Typing indicators | Yes (Private API) | No |
| Read receipts | Yes (Private API) | No |
| Contact info | Yes | No |
| Group management | Limited | No |
| Message search | Yes | No |

### Access Control Patterns

```typescript
// allowlist of Apple IDs / phone numbers permitted to interact with bot
const ALLOWED_SENDERS = new Set([
  "+1234567890",
  "admin@example.com",
]);

function isAuthorized(handle: string): boolean {
  return ALLOWED_SENDERS.has(handle);
}
```

### Webhook-Based Message Handling

```typescript
import express from "express";

const app = express();
app.use(express.json());

const BB_PASSWORD = process.env.BLUEBUBBLES_PASSWORD;
const BB_URL = process.env.BLUEBUBBLES_URL || "http://localhost:1234";

app.post("/webhook", async (req, res) => {
  const { type, data } = req.body;
  if (type !== "new-message" || data.isFromMe) { res.sendStatus(200); return; }

  const { text, handle, chats } = data;
  if (!isAuthorized(handle?.address)) { res.sendStatus(200); return; }

  if (text.startsWith("/")) {
    const chatGuid = chats?.[0]?.guid;
    const response = await handleCommand(text.slice(1).trim());
    await fetch(`${BB_URL}/api/v1/message/text?password=${BB_PASSWORD}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chatGuid, message: response, method: "private-api" }),
    });
  }
  res.sendStatus(200);
});

app.listen(3000);
```

**Webhook setup**: In BlueBubbles, navigate to API & Webhooks → add URL `http://your-bot-host:3000/webhook` → select events (`new-message`, `updated-message`).

## Security Considerations

### Encryption

iMessage uses E2E encryption with different cryptographic primitives depending on protocol version:

| Component | Classic iMessage | PQ3 (iOS 17.4+) |
|-----------|-----------------|------------------|
| Content encryption | AES-128-CTR (per-message key) | AES-256-CTR |
| Key wrapping | RSA-OAEP (modulus size not specified by Apple); ECIES on P-256 available since iOS 13 | Post-quantum key establishment (Kyber-768 + P-256 ECDH) |
| Signing / authentication | ECDSA P-256 (sender authentication, not content encryption) | ECDSA P-256 |
| Attachment encryption | AES-256-CTR (random 256-bit key) | AES-256-CTR |
| Forward secrecy | Limited — keys rotate on device changes, not per-message | Periodic rekeying via post-quantum ratchet |

- **Group chats**: Each message individually encrypted per recipient device (no group key)
- **Key verification**: Contact Key Verification (iOS 17.2+) — manual verification like Signal's safety numbers
- Apple **cannot** read iMessage content in transit

### Metadata

Apple sees metadata despite E2E encryption: sender/recipient identifiers (phone/Apple ID), timestamps, IP addresses, device info. Apple retains metadata for up to 30 days. Message content, attachments, and reactions are NOT visible to Apple.

### iCloud Backups (CRITICAL)

Default iCloud backups are **NOT E2E encrypted** — Apple holds the keys, meaning Apple and law enforcement (with warrant) can access message content from backups. **Advanced Data Protection** (opt-in, iOS 16.3+) enables E2E encrypted backups. **Recommendation**: Enable Advanced Data Protection or disable iCloud backup for Messages. This is the single biggest practical privacy risk for iMessage.

### Push Notifications

Delivered via APNs. Apple sees notification metadata (device token, timestamp) but **not** message content. Push tokens linkable to Apple ID. No way to use iMessage without APNs.

### AI Training

Apple states they do **not** use iMessage content for AI training. Apple Intelligence features process data on-device where possible; server-side processing uses "Private Cloud Compute" with published transparency logs. No third-party AI model has access to iMessage content via Apple's systems.

### Open Source Status

- **iMessage protocol + Apple servers**: CLOSED source — no independent audit of E2E implementation (though security researchers including Johns Hopkins have analyzed and found it sound)
- **BlueBubbles**: OPEN source (Apache-2.0) — auditable bridge layer
- **imsg CLI**: OPEN source (MIT) — auditable send-only tool
- Apple publishes a [Platform Security Guide](https://support.apple.com/guide/security/welcome/web) with protocol details (self-reported, not independently verified)

### Jurisdiction

Apple Inc., USA (Cupertino, CA). Subject to US law enforcement (NSLs, FISA, subpoenas). Apple has historically fought for user privacy (FBI vs Apple, 2016) and publishes transparency reports. Non-US user data may transit US infrastructure.

### Bot-Specific Security

- BlueBubbles Mac has access to **all decrypted messages** for the signed-in Apple ID — secure the host: FileVault, strong password, auto-lock, firewall, minimal software
- REST API must be localhost-only or behind reverse proxy with TLS + auth — **never** expose port 1234 to the internet
- Use a **dedicated Apple ID** for the bot, not a personal one
- Store BlueBubbles password via gopass or env vars — never in code or logs

### SMS Fallback (CRITICAL)

When iMessage is unavailable, messages **fall back to SMS** which is **completely unencrypted**. There is **no way to prevent this programmatically**. Users can disable it per-device (Settings > Messages > "Send as SMS" off), but bots cannot control this. **Recommendation**: Check the BlueBubbles `service` field (`iMessage` vs `SMS`) before sending sensitive content.

### Comparison Summary

Strong privacy for a mainstream platform:

| Aspect | iMessage | Signal | WhatsApp | SimpleX |
|--------|----------|--------|----------|---------|
| E2E encryption | Yes | Yes | Yes | Yes |
| Open source | No | Yes | No (client) | Yes |
| Metadata collection | Moderate (30d) | Minimal | Extensive | None |
| Independent audit | No | Yes | Yes (protocol) | Yes |
| iCloud backup risk | Yes (default) | N/A | Yes (default) | N/A |
| SMS fallback | Yes (unencrypted) | No | No | No |
| Closed protocol | Yes | No | Yes | No |

**Bottom line**: Better than WhatsApp (less metadata harvesting by the service provider). Worse than Signal (Apple still sees metadata, protocol is closed source, iCloud backup is a practical risk). The iCloud backup issue and SMS fallback are the biggest real-world privacy risks.

## Integration with aidevops

### Components

| Component | Purpose |
|-----------|---------|
| `imessage-dispatch-helper.sh` | Shell helper for sending notifications via imsg CLI |
| BlueBubbles webhook handler | Receives inbound messages, dispatches to runners |
| `entity-helper.sh` | Resolves user identifiers (phone/Apple ID) to aidevops entities |
| Config file | `~/.config/aidevops/imessage-bot.json` |

### imessage-dispatch-helper.sh Pattern

```bash
#!/usr/bin/env bash
# imessage-dispatch-helper.sh — send notifications via iMessage
set -euo pipefail

send_imessage() {
  local recipient="$1"
  local message="$2"
  if ! command -v imsg &>/dev/null; then
    echo "ERROR: imsg not installed. brew install steipete/tap/imsg" >&2
    return 1
  fi
  imsg send "$recipient" "$message"
  return 0
}
# Usage: imessage-dispatch-helper.sh "+1234567890" "Build #42 passed"
```

### BlueBubbles Webhook to Runner Dispatch

Flow: iMessage user sends command → BlueBubbles webhook → verify sender via entity-helper.sh → parse command → dispatch via runner-helper.sh → return result → reply via BlueBubbles API.

### Entity Resolution

```bash
# Resolve phone/Apple ID to aidevops entity
entity-helper.sh resolve "+1234567890"
# → { "entity": "marcus", "role": "admin", "platforms": ["imessage", "matrix"] }

# Check authorization
entity-helper.sh check-auth "+1234567890" "deploy"
# → exit 0 (authorized) or exit 1 (denied)
```

### Configuration

```json
{
  "server_url": "http://localhost:1234",
  "server_password_ref": "gopass:aidevops/bluebubbles/password",
  "webhook_port": 3000,
  "webhook_path": "/webhook",
  "allowed_handles": [
    "+1234567890",
    "admin@example.com"
  ],
  "command_prefix": "/",
  "send_method": "private-api",
  "notifications": {
    "build_status": true,
    "deploy_alerts": true,
    "error_alerts": true
  }
}
```

Store at `~/.config/aidevops/imessage-bot.json`. Server password must reference a gopass secret, never stored in plaintext in the config file.

## Matterbridge Integration

### No Native Support

Matterbridge does **not** have native support for iMessage. There is no official or community gateway for iMessage in the Matterbridge ecosystem.

### Custom Gateway Feasibility

A custom gateway could bridge BlueBubbles REST API → custom Node.js adapter → Matterbridge API (:4242) → Matrix, Telegram, Discord, SimpleX, etc.

**Considerations**: Poll BlueBubbles or listen on WebSocket for inbound; send via REST API for outbound. Main complexity is identity mapping and iMessage-specific features (tapbacks → reactions). Inherits all BlueBubbles limitations. Effort: medium.

**Alternative**: For simple 1:1 bridging (e.g., iMessage ↔ Matrix), a direct bridge bot avoids the Matterbridge abstraction — BlueBubbles webhook receives iMessage, bot forwards to Matrix via matrix-bot-sdk, and vice versa.

## Limitations

- **macOS only**: Requires always-on Mac with Messages.app. No Linux/Windows. Mac mini (M-series, ~$500-600) recommended. macOS VMs possible on Apple hardware only.
- **Apple ID required**: Dedicated Apple ID needed, phone number for verification, mandatory 2FA. Apple may lock accounts used for automated messaging.
- **No official bot API**: BlueBubbles uses unofficial private APIs + AppleScript — can break with macOS updates. Apple has not endorsed third-party iMessage automation and could actively block it.
- **SMS fallback is unencrypted**: Non-iMessage recipients silently get SMS. No programmatic prevention. Check `service` field in API responses.
- **BlueBubbles requirements**: Electron app (~200-400MB RAM), Full Disk Access + Accessibility permissions, Private API requires SIP disabled, restart needed after macOS updates.
- **Group management limited**: Programmatic group creation supported but minimal admin controls compared to Matrix/Telegram.
- **Rate limiting**: Apple imposes undocumented limits. Bulk messaging violates Apple ToS. Implement bot-side rate limiting (max 10-20 messages/minute).
- **No cross-platform**: Apple-only. No web client. RCS (iOS 18+) improves SMS interop but is not iMessage.
- **Unofficial integration risk**: Apple may break private APIs with any macOS update. Treat iMessage as a "best-effort" integration, not mission-critical.

## Related

- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, no identifiers)
- `services/communications/matrix-bot.md` — Matrix bot integration (federated, official SDK)
- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `services/communications/twilio.md` — SMS/voice via Twilio (for non-Apple messaging)
- `tools/security/opsec.md` — Operational security guidance
- `tools/credentials/gopass.md` — Secure credential storage
- BlueBubbles: https://bluebubbles.app/
- BlueBubbles GitHub: https://github.com/BlueBubblesApp/bluebubbles-server
- BlueBubbles API Docs: https://docs.bluebubbles.app/
- imsg CLI: https://github.com/steipete/imsg
- Apple Platform Security Guide: https://support.apple.com/guide/security/welcome/web
