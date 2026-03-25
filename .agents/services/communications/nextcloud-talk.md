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

1. **Nextcloud server** (self-hosted) — version 27+ required for Talk Bot API
2. **Talk app** installed and enabled (`spreed`)
3. **Admin access** for OCC CLI bot registration
4. **Node.js >= 18** or **Bun** runtime for the webhook handler
5. **Network reachability**: Bot endpoint must be reachable from the Nextcloud server

```bash
# Check/install/enable Talk app
sudo -u www-data php /var/www/nextcloud/occ app:list | grep spreed
sudo -u www-data php /var/www/nextcloud/occ app:install spreed
sudo -u www-data php /var/www/nextcloud/occ app:enable spreed
sudo -u www-data php /var/www/nextcloud/occ app:info spreed   # verify version 27+
```

### Register Bot via OCC CLI

```bash
# Register bot — returns JSON with bot ID and shared secret
sudo -u www-data php /var/www/nextcloud/occ talk:bot:install \
  "aidevops" \
  "http://localhost:8780/webhook" \
  "AI-powered DevOps assistant" \
  "YOUR_SHARED_SECRET_HERE"

sudo -u www-data php /var/www/nextcloud/occ talk:bot:list
sudo -u www-data php /var/www/nextcloud/occ talk:bot:remove BOT_ID
```

### Generate and Store Shared Secret

```bash
openssl rand -hex 32
gopass insert aidevops/nextcloud-talk/webhook-secret
# Or credentials.sh fallback (600 permissions)
```

### Create App Password for OCS API

```bash
# Via Nextcloud UI: Settings > Security > Devices & sessions > Create new app password
# Name: "aidevops-talk-bot"
# Or via OCC (admin only):
sudo -u www-data php /var/www/nextcloud/occ user:setting BOT_USER app_password

gopass insert aidevops/nextcloud-talk/app-password
```

### Install Dependencies

```bash
bun add express crypto   # preferred
npm install express      # fallback
```

## Bot API Integration

### Webhook Payload Format

```json
{
  "type": "Create",
  "actor": { "type": "User", "id": "admin", "name": "Admin User" },
  "object": {
    "type": "Message",
    "id": "42",
    "name": "Hello @aidevops, can you review the latest PR?",
    "content": "Hello @aidevops, can you review the latest PR?",
    "mediaType": "text/markdown"
  },
  "target": { "type": "Collection", "id": "conversation-token", "name": "Development" }
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

// Allowed Nextcloud user IDs (empty = allow all)
const ALLOWED_USERS = new Set(["admin", "developer1", "developer2"]);

const app = express();
app.use(express.raw({ type: "application/json" }));  // raw body required for signature verification

function verifySignature(body: Buffer, signature: string): boolean {
  const expected = createHmac("sha256", WEBHOOK_SECRET).update(body).digest("hex");
  if (expected.length !== signature.length) return false;
  let result = 0;
  for (let i = 0; i < expected.length; i++) {
    result |= expected.charCodeAt(i) ^ signature.charCodeAt(i);  // constant-time comparison
  }
  return result === 0;
}

async function sendMessage(conversationToken: string, message: string): Promise<void> {
  const url = `${NEXTCLOUD_URL}/ocs/v2.php/apps/spreed/api/v1/chat/${conversationToken}`;
  const auth = Buffer.from(`${BOT_USER}:${APP_PASSWORD}`).toString("base64");
  await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "OCS-APIRequest": "true", "Authorization": `Basic ${auth}` },
    body: JSON.stringify({ message }),
  });
}

async function sendReaction(conversationToken: string, messageId: string, reaction: string): Promise<void> {
  const url = `${NEXTCLOUD_URL}/ocs/v2.php/apps/spreed/api/v1/reaction/${conversationToken}/${messageId}`;
  const auth = Buffer.from(`${BOT_USER}:${APP_PASSWORD}`).toString("base64");
  await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "OCS-APIRequest": "true", "Authorization": `Basic ${auth}` },
    body: JSON.stringify({ reaction }),
  });
}

app.post("/webhook", async (req, res) => {
  const signature = req.headers["x-nextcloud-talk-signature"] as string;
  if (!signature || !verifySignature(req.body, signature)) {
    res.status(401).send("Invalid signature");
    return;
  }

  res.status(200).send("OK");  // respond immediately — process asynchronously

  const payload = JSON.parse(req.body.toString());
  const userId = payload.actor?.id;
  const messageText = payload.object?.name || "";
  const messageId = payload.object?.id;
  const conversationToken = payload.target?.id;

  if (ALLOWED_USERS.size > 0 && !ALLOWED_USERS.has(userId)) return;
  if (!messageText.trim()) return;

  await sendReaction(conversationToken, messageId, "👀");
  try {
    const response = await dispatchToRunner(messageText, userId, conversationToken);
    await sendMessage(conversationToken, response);
    await sendReaction(conversationToken, messageId, "✅");
  } catch (error) {
    await sendMessage(conversationToken, `Error: ${error.message}`);
    await sendReaction(conversationToken, messageId, "❌");
  }
});

app.listen(PORT, () => console.log(`Nextcloud Talk bot listening on port ${PORT}`));
```

### OCS API Reference

```bash
# List conversations
curl -s -u "bot-user:app-password" -H "OCS-APIRequest: true" \
  "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v4/room" | jq

# Send message
curl -s -u "bot-user:app-password" -H "OCS-APIRequest: true" \
  -H "Content-Type: application/json" -d '{"message":"Hello from the bot!"}' \
  "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v1/chat/CONVERSATION_TOKEN"

# Get messages
curl -s -u "bot-user:app-password" -H "OCS-APIRequest: true" \
  "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v1/chat/CONVERSATION_TOKEN?lookIntoFuture=0&limit=50"

# Send reaction
curl -s -u "bot-user:app-password" -H "OCS-APIRequest: true" \
  -H "Content-Type: application/json" -d '{"reaction":"👍"}' \
  "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v1/reaction/CONVERSATION_TOKEN/MESSAGE_ID"
```

Talk supports markdown in messages. Bot responses can use `**bold**`, `` `code` ``, headings, and lists.

## Security

### Privacy Comparison

Nextcloud Talk offers the **strongest privacy of any corporate-style collaboration platform**:

| Platform | Who can access your messages |
|----------|------------------------------|
| **Slack** | Salesforce, workspace admins (full export), law enforcement |
| **Microsoft Teams** | Microsoft, tenant admins (eDiscovery), law enforcement |
| **Discord** | Discord Inc., law enforcement, trust & safety team |
| **Google Chat** | Google, Workspace admins, law enforcement |
| **Nextcloud Talk** | **Only you** — server admin of your own instance |

Nextcloud GmbH (the company) has ZERO access to your instance — they make the software, they do not operate it. The only platforms with better theoretical privacy are SimpleX (no user identifiers, but no collaboration features) and Signal (E2E everything, but no self-hosting or file collaboration).

### Encryption

- **In transit**: TLS 1.2+ — you configure the certificate, cipher suites, HSTS
- **At rest**: Server-side encryption module (AES-256-CTR) — you control the master key
- **E2E for calls**: 1:1 video/audio via WebRTC SRTP/DTLS — media goes peer-to-peer when possible
- **Group chats**: NOT end-to-end encrypted — rely on server-side encryption at rest. Server admin can read all text messages in the database. For most self-hosted deployments this is acceptable — you trust your own server.

### Metadata and Compliance

- Only YOUR server sees metadata (connection logs, access times, IPs, user agents)
- No third-party metadata collection, no analytics beacons, no AI training on your data
- Optional local AI features (`assistant` app) use models running ON YOUR SERVER — no data leaves unless you explicitly configure an external API
- **Jurisdiction**: server is where you put it — no CLOUD Act or FISA 702 exposure unless you host in the US
- **Compliance**: GDPR (full control over processing/retention/deletion), HIPAA-configurable, SOC2-configurable, ISO 27001 (Nextcloud GmbH certified for development processes)
- **Open source**: AGPL-3.0 server, Talk app, mobile apps, desktop app — fully auditable

### Bot-Specific Security

- **Webhook URL**: Can be `localhost`, LAN, or tunneled (Cloudflare Tunnel, WireGuard) — no public internet exposure required
- **Webhook secret**: HMAC-SHA256 signature verification prevents forged webhook deliveries
- **App password**: Scoped, revocable, auditable — not the user's main password
- **Bot runs in YOUR infrastructure**: webhook handler, logs, and temporary data never leave your control

## aidevops Integration

### nextcloud-talk-dispatch-helper.sh

```bash
nextcloud-talk-dispatch-helper.sh setup          # Interactive wizard
nextcloud-talk-dispatch-helper.sh map "development" code-reviewer
nextcloud-talk-dispatch-helper.sh map "seo-team" seo-analyst
nextcloud-talk-dispatch-helper.sh map "operations" ops-monitor
nextcloud-talk-dispatch-helper.sh mappings        # list mappings
nextcloud-talk-dispatch-helper.sh unmap "development"
nextcloud-talk-dispatch-helper.sh start --daemon
nextcloud-talk-dispatch-helper.sh stop
nextcloud-talk-dispatch-helper.sh status
nextcloud-talk-dispatch-helper.sh test code-reviewer "Review src/auth.ts"
nextcloud-talk-dispatch-helper.sh logs [--follow]
```

### Runner Dispatch and Entity Resolution

The bot dispatches to runners via `runner-helper.sh` (runner AGENTS.md, headless session management, memory namespace isolation, entity-aware context loading, run logging).

When a Nextcloud user sends a message, the bot resolves their user ID to an entity:

- **Known user**: Match on `entity_channels` table (`channel=nextcloud-talk`, `channel_id=username`)
- **New user**: Creates entity via `entity-helper.sh create` with Nextcloud user ID linked
- **Cross-channel**: If the same person is linked on Matrix, Slack, SimpleX, or email, their full profile is available
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

Store `appPassword` and `webhookSecret` via `gopass` (preferred) or in the config file with 600 permissions. Never commit credentials to version control.

## Matterbridge Integration

Nextcloud Talk is natively supported by [Matterbridge](https://github.com/42wim/matterbridge) via the Talk API.

```toml
# matterbridge.toml
[nextcloud.myserver]
Server = "https://cloud.example.com"
Login = "matterbridge-bot"
Password = "app-password-here"
ShowJoinPart = false

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

**Privacy note**: Bridging to external platforms (Slack, Discord, Telegram) means messages leave your self-hosted server and are stored on third-party infrastructure. Users should be informed. Bridging to other self-hosted platforms (Matrix on your server, IRC on your network) preserves the self-hosted privacy model. See `services/communications/matterbridge.md`.

## Limitations

| Limitation | Mitigation |
|------------|------------|
| **Self-hosted maintenance overhead** — server provisioning, Nextcloud/PHP/DB updates, SSL, backups, monitoring | Use managed Nextcloud hosting (Hetzner StorageShare, IONOS) or Cloudron — see `services/hosting/cloudron.md` |
| **Talk Bot API maturity** — smaller API surface, less documentation, smaller bot ecosystem than Slack/Discord, API may change between major versions | Pin Nextcloud and Talk versions; test upgrades in staging |
| **No rich interactive components** — no inline buttons, modals, dropdowns, or form inputs; text, markdown, reactions, and file attachments only | Use slash-command patterns or prefix commands for structured input |
| **Group chats not E2E encrypted** — server-side encryption at rest only; server admin can read all text messages | Acceptable for most self-hosted deployments where you trust your own server |
| **Performance depends on your hardware** — video call quality, message latency, and file sharing speed depend on server resources | Use a dedicated TURN server (coturn), Redis for caching, and adequate hardware |
| **Mobile push notification setup** — requires either Nextcloud's push proxy (minimal metadata to FCM/APNs) or self-hosted `notify_push` binary | Both require additional configuration beyond the base Nextcloud install |
| **Smaller ecosystem** — far fewer bots and integrations than Slack (2000+ apps) or Discord (millions of bots) | Build custom integrations using the webhook API or OCS REST API |

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
