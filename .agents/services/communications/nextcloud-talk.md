---
description: Nextcloud Talk — self-hosted team communication with strongest corporate privacy, Talk Bot API (webhook-based, OCC CLI), server-side encryption, Matterbridge bridging, and aidevops dispatch
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

# Nextcloud Talk Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Self-hosted team communication — you own everything, strongest privacy for corporate use
- **License**: AGPL-3.0 (Nextcloud server + Talk app)
- **Bot tool**: Talk Bot API (webhook-based, OCC CLI registration)
- **Protocol**: Nextcloud Talk API (HTTP REST + webhook)
- **Encryption**: TLS in transit, server-side at rest (you control the keys), E2E for 1:1 calls (WebRTC)
- **Script**: `nextcloud-talk-dispatch-helper.sh [setup|start|stop|status|map|unmap|mappings|test|logs]`
- **Config**: `~/.config/aidevops/nextcloud-talk-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/nextcloud-talk-bot/`
- **Docs**: https://nextcloud-talk.readthedocs.io/ | https://docs.nextcloud.com/server/latest/developer_manual/digging_deeper/bots.html
- **Server**: https://nextcloud.com/install/ | https://docs.nextcloud.com/server/latest/admin_manual/

**Key differentiator**: Nextcloud Talk is the strongest privacy option for corporate/team communication. You own the server, the database, the encryption keys, the backups — everything. No third party (including Nextcloud GmbH) has access to any of your data. Unlike Slack/Teams/Discord, there is ZERO external data access. Unlike SimpleX/Signal, you also get a full collaboration suite (files, calendar, office, contacts).

**Quick start**:

```bash
nextcloud-talk-dispatch-helper.sh setup          # Interactive wizard
nextcloud-talk-dispatch-helper.sh map "general" code-reviewer
nextcloud-talk-dispatch-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────┐
│ Nextcloud Talk Room   │
│                       │
│ User sends message    │
│ @bot or in mapped     │
│ conversation          │
└──────────┬───────────┘
           │
           │  Talk Bot API (webhook POST)
           │  HMAC-SHA256 signature verification
           │
┌──────────▼───────────┐     ┌──────────────────────┐
│ Bot Webhook Endpoint  │     │ aidevops Dispatch     │
│ (Bun/Node HTTP)       │     │                       │
│                       │     │ runner-helper.sh      │
│ ├─ Signature verify   │────▶│ → AI session          │
│ ├─ Access control     │     │ → response            │
│ ├─ Message parsing    │◀────│                       │
│ ├─ Entity resolution  │     │                       │
│ └─ Reply via OCS API  │     │                       │
└──────────┬───────────┘     └──────────────────────┘
           │
┌──────────▼───────────┐
│ Nextcloud Server      │
│ (YOUR infrastructure) │
│                       │
│ ├── PostgreSQL/MySQL  │  Message storage (encrypted at rest)
│ ├── Talk app          │  Conversations, participants, bots
│ ├── Files app         │  File sharing, attachments
│ ├── Collabora/OnlyO.  │  Office document editing
│ └── Calendar/Contacts │  Full collaboration suite
└───────────────────────┘
```

**Message flow**:

1. User sends message in a Nextcloud Talk conversation
2. Talk server checks if a bot is registered for that conversation
3. Talk server sends webhook POST to bot endpoint with HMAC-SHA256 signature
4. Bot verifies signature using shared secret
5. Bot checks access control (Nextcloud user ID allowlists)
6. Entity resolution: Nextcloud user ID resolved to entity via `entity-helper.sh`
7. Layer 0 logging: user message logged as immutable interaction
8. Context loading: entity profile + conversation summary + recent interactions
9. Bot dispatches entity-aware prompt to runner via `runner-helper.sh`
10. Runner executes via headless dispatch
11. Bot posts response back to Talk conversation via OCS API
12. Bot adds reaction emoji (hourglass while processing, checkmark on success, X on failure)

## Installation

### Prerequisites

1. **Nextcloud server** (self-hosted) — version 27+ recommended for Talk Bot API
2. **Talk app** installed and enabled (bundled with Nextcloud, or install from App Store)
3. **Admin access** to the Nextcloud instance (for OCC CLI bot registration)
4. **Node.js >= 18** or **Bun** runtime for the webhook handler
5. **Network reachability**: Bot endpoint must be reachable from the Nextcloud server (localhost, LAN, or tunneled)

### Step 1: Ensure Talk App is Installed

```bash
# Check if Talk is installed
sudo -u www-data php /var/www/nextcloud/occ app:list | grep spreed

# Install Talk if not present
sudo -u www-data php /var/www/nextcloud/occ app:install spreed

# Enable Talk if disabled
sudo -u www-data php /var/www/nextcloud/occ app:enable spreed

# Verify version (27+ required for Bot API)
sudo -u www-data php /var/www/nextcloud/occ app:info spreed
```

### Step 2: Register a Bot via OCC CLI

The Talk Bot API uses OCC CLI for bot registration. Each bot gets a name, a webhook URL, a description, and a shared secret for signature verification.

```bash
# Register a new bot
# The command returns a JSON object with the bot ID and shared secret
sudo -u www-data php /var/www/nextcloud/occ talk:bot:install \
  "aidevops" \
  "http://localhost:8780/webhook" \
  "AI-powered DevOps assistant" \
  "YOUR_SHARED_SECRET_HERE"

# List registered bots
sudo -u www-data php /var/www/nextcloud/occ talk:bot:list

# Remove a bot
sudo -u www-data php /var/www/nextcloud/occ talk:bot:remove BOT_ID

# Enable bot for a specific conversation
# (done via Talk admin settings or API)
```

### Step 3: Generate a Shared Secret

```bash
# Generate a cryptographically secure secret
openssl rand -hex 32

# Store securely
gopass insert aidevops/nextcloud-talk/webhook-secret

# Or via credentials.sh fallback (600 permissions)
```

### Step 4: Configure the Webhook Endpoint

The bot must run an HTTP server that receives webhook POSTs from the Nextcloud server. The endpoint must:

1. Accept POST requests with JSON body
2. Verify the `X-Nextcloud-Talk-Signature` header (HMAC-SHA256)
3. Respond with 200 OK quickly (process asynchronously)

### Step 5: Create an App Password for API Access

The bot needs an app password to send messages back via the OCS API:

```bash
# Create via Nextcloud UI:
# Settings > Security > Devices & sessions > Create new app password
# Name: "aidevops-talk-bot"

# Or via OCC (admin only):
sudo -u www-data php /var/www/nextcloud/occ user:setting BOT_USER app_password

# Store securely
gopass insert aidevops/nextcloud-talk/app-password
```

### Step 6: Install Dependencies

```bash
# Using Bun (preferred)
bun add express crypto

# Using npm
npm install express
```

## Bot API Integration

### Webhook Payload Format

When a message is posted in a conversation where the bot is enabled, Talk sends a webhook POST:

```json
{
  "type": "Create",
  "actor": {
    "type": "User",
    "id": "admin",
    "name": "Admin User"
  },
  "object": {
    "type": "Message",
    "id": "42",
    "name": "Hello @aidevops, can you review the latest PR?",
    "content": "Hello @aidevops, can you review the latest PR?",
    "mediaType": "text/markdown"
  },
  "target": {
    "type": "Collection",
    "id": "conversation-token",
    "name": "Development"
  }
}
```

### Signature Verification

Every webhook request includes an `X-Nextcloud-Talk-Signature` header containing an HMAC-SHA256 signature of the request body, computed with the shared secret.

```typescript
import { createHmac } from "crypto";

function verifySignature(body: string, signature: string, secret: string): boolean {
  const expected = createHmac("sha256", secret)
    .update(body)
    .digest("hex");
  // Constant-time comparison to prevent timing attacks
  if (expected.length !== signature.length) return false;
  let result = 0;
  for (let i = 0; i < expected.length; i++) {
    result |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  return result === 0;
}
```

### Complete Webhook Handler

```typescript
// nextcloud-talk-bot.ts — webhook handler for Nextcloud Talk Bot API
import express from "express";
import { createHmac } from "crypto";

const PORT = 8780;
const NEXTCLOUD_URL = process.env.NEXTCLOUD_URL || "https://cloud.example.com";
const BOT_USER = process.env.BOT_USER || "aidevops-bot";
const APP_PASSWORD = process.env.APP_PASSWORD || "";
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET || "";

// Allowed Nextcloud user IDs
const ALLOWED_USERS = new Set(["admin", "developer1", "developer2"]);

const app = express();

// Raw body needed for signature verification
app.use(express.raw({ type: "application/json" }));

function verifySignature(body: Buffer, signature: string): boolean {
  const expected = createHmac("sha256", WEBHOOK_SECRET)
    .update(body)
    .digest("hex");
  if (expected.length !== signature.length) return false;
  let result = 0;
  for (let i = 0; i < expected.length; i++) {
    result |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  return result === 0;
}

// Send message to a Talk conversation via OCS API
async function sendMessage(conversationToken: string, message: string): Promise<void> {
  const url = `${NEXTCLOUD_URL}/ocs/v2.php/apps/spreed/api/v1/chat/${conversationToken}`;
  const auth = Buffer.from(`${BOT_USER}:${APP_PASSWORD}`).toString("base64");

  await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "OCS-APIRequest": "true",
      "Authorization": `Basic ${auth}`,
    },
    body: JSON.stringify({ message }),
  });
}

// Send reaction to a message
async function sendReaction(
  conversationToken: string,
  messageId: string,
  reaction: string,
): Promise<void> {
  const url = `${NEXTCLOUD_URL}/ocs/v2.php/apps/spreed/api/v1/reaction/${conversationToken}/${messageId}`;
  const auth = Buffer.from(`${BOT_USER}:${APP_PASSWORD}`).toString("base64");

  await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "OCS-APIRequest": "true",
      "Authorization": `Basic ${auth}`,
    },
    body: JSON.stringify({ reaction }),
  });
}

app.post("/webhook", async (req, res) => {
  const signature = req.headers["x-nextcloud-talk-signature"] as string;
  if (!signature || !verifySignature(req.body, signature)) {
    res.status(401).send("Invalid signature");
    return;
  }

  // Respond immediately — process asynchronously
  res.status(200).send("OK");

  const payload = JSON.parse(req.body.toString());
  const userId = payload.actor?.id;
  const messageText = payload.object?.name || "";
  const messageId = payload.object?.id;
  const conversationToken = payload.target?.id;

  // Access control
  if (ALLOWED_USERS.size > 0 && !ALLOWED_USERS.has(userId)) {
    return;
  }

  // Skip empty messages or non-text
  if (!messageText.trim()) return;

  // Add processing reaction
  await sendReaction(conversationToken, messageId, "👀");

  try {
    // Dispatch to runner (integrate with runner-helper.sh)
    const response = await dispatchToRunner(messageText, userId, conversationToken);

    await sendMessage(conversationToken, response);

    // Success reaction
    await sendReaction(conversationToken, messageId, "✅");
  } catch (error) {
    await sendMessage(conversationToken, `Error: ${error.message}`);
    await sendReaction(conversationToken, messageId, "❌");
  }
});

app.listen(PORT, () => {
  console.log(`Nextcloud Talk bot listening on port ${PORT}`);
});
```

### OCS API: Messaging and Conversations

```bash
# List conversations the bot user is part of
curl -s -u "bot-user:app-password" \
  -H "OCS-APIRequest: true" \
  "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v4/room" | jq

# Send a message to a conversation
curl -s -u "bot-user:app-password" \
  -H "OCS-APIRequest: true" \
  -H "Content-Type: application/json" \
  -d '{"message":"Hello from the bot!"}' \
  "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v1/chat/CONVERSATION_TOKEN"

# Get chat messages from a conversation
curl -s -u "bot-user:app-password" \
  -H "OCS-APIRequest: true" \
  "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v1/chat/CONVERSATION_TOKEN?lookIntoFuture=0&limit=50"

# Send a reaction
curl -s -u "bot-user:app-password" \
  -H "OCS-APIRequest: true" \
  -H "Content-Type: application/json" \
  -d '{"reaction":"👍"}' \
  "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v1/reaction/CONVERSATION_TOKEN/MESSAGE_ID"
```

### Markdown Support

Talk supports markdown in messages. The bot can send formatted responses:

```typescript
const formattedResponse = `
## Analysis Results

**Repository**: \`myproject\`
**Branch**: \`feature/auth-refactor\`

### Issues Found

1. **SQL injection** in \`src/db/query.ts:42\` — use parameterised queries
2. **Missing input validation** in \`src/api/users.ts:18\`

### Recommendations

- Add input sanitisation middleware
- Enable CSP headers

> Overall: 2 critical, 0 warnings
`;

await sendMessage(conversationToken, formattedResponse);
```

### Access Control

```typescript
// Nextcloud user ID allowlist
const ALLOWED_USERS = new Set(["admin", "developer1", "ops-team"]);

// Conversation allowlist (by token)
const ALLOWED_CONVERSATIONS = new Set(["abc123token", "def456token"]);

function isAllowed(userId: string, conversationToken: string): boolean {
  if (ALLOWED_USERS.size > 0 && !ALLOWED_USERS.has(userId)) {
    return false;
  }
  if (ALLOWED_CONVERSATIONS.size > 0 && !ALLOWED_CONVERSATIONS.has(conversationToken)) {
    return false;
  }
  return true;
}
```

## Security Considerations

> **CRITICAL**: Nextcloud Talk is the PRIVACY CHAMPION for self-hosted corporate communication. This section details why it offers the strongest privacy of any team collaboration platform.

### Self-Hosted: The Key Advantage

This is the fundamental differentiator. All data stays on YOUR server. You control:

- **Hardware**: Your server, your rack, your data centre (or your chosen VPS)
- **Software**: Open-source stack you can audit, modify, and rebuild
- **Network**: Your firewall rules, your VPN, your DNS
- **Backups**: Your backup schedule, your backup location, your retention policy
- **Encryption keys**: Server-side encryption keys are generated and stored on YOUR server
- **Access**: No third party has access to anything unless you explicitly grant it

No Slack admin at Salesforce, no Microsoft engineer at Teams, no Google employee at Chat can read your messages. The software is AGPL-3.0 — you download it, you run it, you own the entire stack.

### Encryption

- **In transit**: TLS 1.2+ — you configure the certificate (Let's Encrypt, self-signed, or CA-issued). You control the cipher suites, the certificate rotation, the HSTS headers
- **At rest**: Nextcloud server-side encryption module encrypts files and data in your database. You control the master key. When enabled, data on disk is encrypted with AES-256-CTR
- **E2E for calls**: 1:1 video and audio calls use WebRTC with OWASP-recommended encryption (SRTP with DTLS key exchange). Media goes peer-to-peer when possible — never through Nextcloud servers
- **Message storage**: Message content is stored in your Nextcloud database (PostgreSQL/MySQL/MariaDB). If you enable server-side encryption, database contents are encrypted at rest. You control the database credentials, the connection, the backup encryption

### Metadata

- **Only YOUR server sees metadata**. Connection logs, access times, IP addresses, user agents — all stored on YOUR server in YOUR log files
- **No third-party metadata collection**. Unlike Slack (Salesforce collects comprehensive metadata), Teams (Microsoft telemetry), or Discord (full message analytics), no external company receives any metadata
- **You control log retention**. Set log rotation, audit trail retention, and data lifecycle policies according to YOUR requirements
- **No analytics beacons**. Nextcloud does not phone home with usage data (you can optionally enable anonymous usage statistics, but it is opt-in and sends minimal aggregate data)

### No Third-Party Data Access

Unlike Slack/Teams/Discord/Google Chat, NO external company has access to your messages:

| Platform | Who can access your messages |
|----------|------------------------------|
| **Slack** | Salesforce, workspace admins (full export), law enforcement (Salesforce compliance) |
| **Microsoft Teams** | Microsoft, tenant admins (eDiscovery/compliance), law enforcement (Microsoft compliance) |
| **Discord** | Discord Inc., law enforcement, trust & safety team |
| **Google Chat** | Google, Workspace admins, law enforcement (Google compliance) |
| **Nextcloud Talk** | **Only you** — server admin of your own instance |

Nextcloud GmbH (the company that develops Nextcloud) has ZERO access to your instance. They make the software. They do not operate it. They cannot see your data. This is architecturally guaranteed by the self-hosted model.

### Push Notifications

- **Nextcloud push proxy**: Nextcloud provides a push notification proxy (`push-notifications` app) that relays wake-up signals to mobile devices via FCM/APNs. Minimal metadata is sent — a notification ID, no message content. The mobile app then fetches the actual message directly from YOUR server over TLS
- **Self-hosted push proxy**: You can run your own push notification proxy (`notify_push`) to eliminate ALL third-party notification metadata. The `notify_push` binary connects directly to your Nextcloud server and pushes via WebSocket to connected clients
- **Desktop/web**: Desktop and web clients use direct WebSocket connections to your server — no push proxy needed, no third-party involvement

### AI Training

- **NO external AI training**. Nextcloud GmbH has ZERO access to your data. There is no data pipeline, no telemetry that includes message content, no model training on your conversations
- **Local AI integration**: Nextcloud offers optional AI features (smart search, OCR, text generation) via the `assistant` app. When configured, these use local models running ON YOUR SERVER (via llamafile, Ollama, or external API you configure). No data leaves your infrastructure unless you explicitly point it at an external API
- **Your choice**: You decide whether to enable AI features, which models to use, and where they run. The default is no AI processing at all

### Open Source

- **Nextcloud server**: AGPL-3.0 — fully open source, auditable, forkable
- **Talk app**: AGPL-3.0 — same license, full source available
- **Mobile apps** (Android/iOS): Open source on GitHub
- **Desktop app**: Open source, Electron-based
- **Regular security audits**: Nextcloud participates in HackerOne bug bounty programme. Independent security audits published regularly
- **Reproducible builds**: Community-verified builds available
- **You can audit every line of code** that touches your data

### Jurisdiction

- **YOUR jurisdiction**. The server is where you put it. Run it in Germany, Switzerland, Iceland, your own office — your choice
- **Nextcloud GmbH** is headquartered in Stuttgart, Germany, and is subject to German/EU law (strong data protection under GDPR). But they have no access to your instance — jurisdiction only matters for the software distribution, not your data
- **No CLOUD Act exposure** (unless you choose to host in the US)
- **No FISA Section 702 exposure** (unless you choose to host in the US)
- **Data sovereignty**: You have complete control over where your data physically resides

### Compliance

You control compliance because you control the entire stack:

- **GDPR**: Full control over data processing, retention, deletion, portability, and consent. Nextcloud provides GDPR compliance tools (data export, right to erasure)
- **HIPAA**: Can be configured for HIPAA compliance with proper access controls, audit logging, and encryption. Several healthcare organisations run Nextcloud for this reason
- **SOC2**: Audit logs, access controls, encryption at rest/in transit — all configurable
- **ISO 27001**: Nextcloud GmbH itself is ISO 27001 certified for their development processes
- **Full audit logs**: Every file access, share, login, and admin action is logged. You control retention
- **Data retention policies**: Configure automatic deletion of old messages, files, and logs
- **User management**: LDAP/AD integration, 2FA (TOTP, WebAuthn/FIDO2), SSO (SAML, OIDC)

### Bot-Specific Security

- **Webhook URL**: Must be reachable from your Nextcloud server. Can be `localhost` (same machine), LAN address (internal network), or tunneled (Cloudflare Tunnel, WireGuard). No public internet exposure required
- **Webhook secret**: HMAC-SHA256 signature verification prevents forged webhook deliveries. Only your Nextcloud server knows the secret
- **App password**: Bot authenticates to OCS API with an app password — scoped, revocable, auditable. Not the user's main password
- **Bot runs in YOUR infrastructure**: The webhook handler runs on your server or your network. Bot code, logs, and temporary data never leave your control

### Comparison

Nextcloud Talk offers the **STRONGEST privacy of any corporate-style collaboration platform**. The only platforms with better theoretical privacy are:

- **SimpleX** — no user identifiers at all, stateless servers, but no collaboration features (files, calendar, office)
- **Signal** — E2E everything with sealed sender, but no self-hosting, no file collaboration, no office suite

Nextcloud Talk sits in a unique position: **corporate-grade collaboration features** (file sharing, calendar, contacts, office suite, video conferencing, task boards) combined with **self-hosted privacy** where you own and control everything.

## aidevops Integration

### nextcloud-talk-dispatch-helper.sh

The helper script follows the same pattern as `matrix-dispatch-helper.sh` and `slack-dispatch-helper.sh`:

```bash
# Setup wizard — prompts for Nextcloud URL, app password, webhook secret, conversation mappings
nextcloud-talk-dispatch-helper.sh setup

# Map conversations to runners
nextcloud-talk-dispatch-helper.sh map "development" code-reviewer
nextcloud-talk-dispatch-helper.sh map "seo-team" seo-analyst
nextcloud-talk-dispatch-helper.sh map "operations" ops-monitor

# List mappings
nextcloud-talk-dispatch-helper.sh mappings

# Remove a mapping
nextcloud-talk-dispatch-helper.sh unmap "development"

# Start/stop the webhook handler
nextcloud-talk-dispatch-helper.sh start --daemon
nextcloud-talk-dispatch-helper.sh stop
nextcloud-talk-dispatch-helper.sh status

# Test dispatch
nextcloud-talk-dispatch-helper.sh test code-reviewer "Review src/auth.ts"

# View logs
nextcloud-talk-dispatch-helper.sh logs
nextcloud-talk-dispatch-helper.sh logs --follow
```

### Runner Dispatch

The bot dispatches to runners via `runner-helper.sh`, which handles:

- Runner AGENTS.md (personality/instructions)
- Headless session management
- Memory namespace isolation
- Entity-aware context loading
- Run logging

### Entity Resolution

When a Nextcloud user sends a message, the bot resolves their Nextcloud user ID to an entity:

- **Known user**: Match on `entity_channels` table (`channel=nextcloud-talk`, `channel_id=username`)
- **New user**: Creates entity via `entity-helper.sh create` with Nextcloud user ID linked
- **Cross-channel**: If the same person is linked on other channels (Matrix, Slack, SimpleX, email), their full profile is available
- **Profile enrichment**: Nextcloud's user API provides display name, email, groups — used to populate entity profile on first contact

### Configuration

`~/.config/aidevops/nextcloud-talk-bot.json` (600 permissions):

```json
{
  "nextcloudUrl": "https://cloud.example.com",
  "botUser": "aidevops-bot",
  "appPassword": "",
  "webhookSecret": "",
  "webhookPort": 8780,
  "allowedUsers": ["admin", "developer1"],
  "defaultRunner": "",
  "conversationMappings": {
    "development": "code-reviewer",
    "seo-team": "seo-analyst",
    "operations": "ops-monitor"
  },
  "ignoreOwnMessages": true,
  "maxPromptLength": 3000,
  "responseTimeout": 600,
  "sessionIdleTimeout": 300
}
```

**Note**: `appPassword` and `webhookSecret` should be stored via `gopass` (preferred) or in the config file with 600 permissions. Never commit credentials to version control.

## Matterbridge Integration

Nextcloud Talk is natively supported by [Matterbridge](https://github.com/42wim/matterbridge) via the Talk API.

```text
Nextcloud Talk
    │
    │  Talk API (via app password)
    │
Matterbridge (Go binary)
    │
    ├── Matrix rooms
    ├── Slack workspaces
    ├── Discord channels
    ├── Telegram groups
    ├── Signal contacts
    ├── SimpleX chats
    ├── IRC channels
    └── 40+ other platforms
```

### Matterbridge Configuration

Add to `matterbridge.toml`:

```toml
[nextcloud.myserver]
Server = "https://cloud.example.com"
Login = "matterbridge-bot"
Password = "app-password-here"

## SectionJoinPart shows join/leave messages
ShowJoinPart = false
```

Gateway configuration:

```toml
[[gateway]]
name = "dev-bridge"
enable = true

[[gateway.inout]]
account = "nextcloud.myserver"
channel = "development"

[[gateway.inout]]
account = "matrix.myserver"
channel = "#dev:matrix.example.com"
```

**Privacy note**: Bridging Nextcloud Talk to external platforms (Slack, Discord, Telegram) means messages from your self-hosted server will be stored on third-party infrastructure. Users should be informed that bridged conversations lose the privacy guarantees of self-hosting. Bridging to other self-hosted platforms (Matrix on your server, IRC on your network) preserves the self-hosted privacy model. See `services/communications/matterbridge.md` for full bridging considerations.

## Limitations

### Self-Hosted Maintenance Overhead

Nextcloud Talk requires you to run and maintain a Nextcloud server. This includes:

- Server provisioning and hardening
- Regular Nextcloud updates (PHP, database, app updates)
- SSL certificate management
- Backup configuration and testing
- Monitoring and alerting
- Database maintenance (PostgreSQL/MySQL tuning)

**Mitigation**: Use managed Nextcloud hosting (e.g., Hetzner StorageShare, IONOS) or Cloudron for simplified deployment. See `services/hosting/cloudron.md`.

### Talk Bot API Maturity

The Talk Bot API (webhook-based) is relatively new compared to Slack's Bolt SDK or Discord's bot framework:

- API surface is smaller — fewer interactive features
- Documentation is less comprehensive than Slack/Discord
- Community ecosystem of bots is smaller
- API may change between major Talk versions

**Mitigation**: Pin Nextcloud and Talk versions, test upgrades in staging.

### No Rich Interactive Components

Talk does not support interactive UI elements in bot messages:

- No inline buttons or action menus
- No modals or dialogs
- No dropdown selects or form inputs
- Text, markdown, reactions, and file attachments only

Bot interaction is text-based. Use slash-command patterns or prefix commands for structured input.

### E2E Encryption Scope

- E2E encryption is available for **1:1 video and audio calls** (WebRTC SRTP/DTLS)
- **Group chats and text messages are NOT end-to-end encrypted** — they rely on server-side encryption at rest
- This means the server admin (you) can read all text messages in the database
- For most self-hosted deployments this is acceptable — you trust your own server

### Performance Depends on Your Hardware

Unlike SaaS platforms with global CDN infrastructure, Nextcloud Talk performance depends on your server:

- Video call quality depends on server bandwidth and TURN server configuration
- Message delivery latency depends on server load and database performance
- File sharing speed depends on storage backend (local disk, S3, NFS)

**Mitigation**: Use a dedicated TURN server (coturn), Redis for caching, and adequate hardware.

### Mobile Push Notification Setup

Push notifications require either:

- Nextcloud's push proxy (minimal metadata to FCM/APNs)
- Self-hosted `notify_push` binary (eliminates all third-party notification traffic)

Both require additional configuration beyond the base Nextcloud install.

### Smaller Ecosystem

Compared to Slack (2000+ apps in marketplace) or Discord (millions of bots), Nextcloud Talk has a smaller bot and integration ecosystem. Most integrations need to be built custom using the webhook API or OCS REST API.

## Related

- `services/communications/matrix-bot.md` — Matrix bot integration (federated, E2E encrypted, self-hostable)
- `services/communications/slack.md` — Slack bot integration (proprietary, no E2E, comprehensive API)
- `services/communications/simplex.md` — SimpleX Chat (zero-identifier messaging, strongest metadata privacy)
- `services/communications/signal.md` — Signal bot integration (E2E encrypted, phone number required)
- `services/communications/matterbridge.md` — Multi-platform chat bridging
- `scripts/entity-helper.sh` — Entity memory system (identity resolution, Layer 0/1/2)
- `scripts/runner-helper.sh` — Runner management
- `tools/security/opsec.md` — Operational security guidance
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- `services/hosting/cloudron.md` — Cloudron platform for simplified Nextcloud hosting
- Nextcloud Talk docs: https://nextcloud-talk.readthedocs.io/
- Nextcloud Talk Bot API: https://docs.nextcloud.com/server/latest/developer_manual/digging_deeper/bots.html
- Nextcloud server admin: https://docs.nextcloud.com/server/latest/admin_manual/
- Nextcloud Talk source: https://github.com/nextcloud/spreed
- Nextcloud server source: https://github.com/nextcloud/server
