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

| Item | Value |
|------|-------|
| Type | Self-hosted team communication — you own everything |
| License | AGPL-3.0 |
| Bot tool | Talk Bot API (webhook-based, OCC CLI registration) |
| Protocol | Nextcloud Talk API (HTTP REST + webhook) |
| Encryption | TLS in transit, AES-256-CTR at rest, WebRTC SRTP/DTLS for 1:1 calls |
| Script | `nextcloud-talk-dispatch-helper.sh [setup\|start\|stop\|status\|map\|unmap\|mappings\|test\|logs]` |
| Config | `~/.config/aidevops/nextcloud-talk-bot.json` (600 permissions) |
| Data | `~/.aidevops/.agent-workspace/nextcloud-talk-bot/` |
| Docs | https://nextcloud-talk.readthedocs.io/ · https://docs.nextcloud.com/server/latest/developer_manual/digging_deeper/bots.html |

**Key differentiator**: You own the server, database, encryption keys, and backups. No third party (including Nextcloud GmbH) has access. Unlike Slack/Teams/Discord: zero external data access. Unlike SimpleX/Signal: full collaboration suite (files, calendar, office, contacts).

**Quick start**:

```bash
nextcloud-talk-dispatch-helper.sh setup          # Interactive wizard
nextcloud-talk-dispatch-helper.sh map "general" code-reviewer
nextcloud-talk-dispatch-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Architecture

**Stack**: Talk Room → webhook POST (HMAC-SHA256) → Bot Endpoint (Bun/Node) → `runner-helper.sh` → AI session → OCS API reply → Talk Room.

**Message flow**: signature verify → access control → entity resolution (`entity-helper.sh`) → Layer 0 log → context load → `runner-helper.sh` dispatch → headless AI session → OCS API reply + reaction emoji (⏳ processing, ✅ success, ❌ failure).

**Server components** (YOUR infrastructure): PostgreSQL/MySQL (messages, encrypted at rest), Talk app (conversations, bots), Files app, Collabora/OnlyOffice, Calendar/Contacts.

## Installation

### Prerequisites

| Requirement | Notes |
|-------------|-------|
| Nextcloud server (self-hosted) | Version 27+ for Talk Bot API |
| Talk app (`spreed`) | Installed and enabled |
| Admin access | OCC CLI bot registration |
| Node.js ≥18 or Bun | Webhook handler runtime |
| Network reachability | Bot endpoint reachable from Nextcloud server |

```bash
sudo -u www-data php /var/www/nextcloud/occ app:list | grep spreed
sudo -u www-data php /var/www/nextcloud/occ app:install spreed
sudo -u www-data php /var/www/nextcloud/occ app:enable spreed
sudo -u www-data php /var/www/nextcloud/occ app:info spreed   # verify version 27+
```

### Register Bot + Credentials

```bash
# Register bot (returns bot ID and shared secret)
sudo -u www-data php /var/www/nextcloud/occ talk:bot:install \
  "aidevops" "http://localhost:8780/webhook" "AI-powered DevOps assistant" "YOUR_SHARED_SECRET_HERE"

sudo -u www-data php /var/www/nextcloud/occ talk:bot:list
sudo -u www-data php /var/www/nextcloud/occ talk:bot:remove BOT_ID

# Generate and store shared secret
openssl rand -hex 32
gopass insert aidevops/nextcloud-talk/webhook-secret

# App password: Nextcloud UI → Settings > Security > Devices & sessions > Create new app password
# Name: "aidevops-talk-bot"
gopass insert aidevops/nextcloud-talk/app-password

# Install dependencies
bun add express crypto   # preferred
npm install express      # fallback
```

## Bot API Integration

### Webhook Payload

```json
{
  "type": "Create",
  "actor": { "type": "User", "id": "admin", "name": "Admin User" },
  "object": { "type": "Message", "id": "42", "name": "Hello @aidevops, review the latest PR?", "mediaType": "text/markdown" },
  "target": { "type": "Collection", "id": "conversation-token", "name": "Development" }
}
```

### Webhook Handler

```typescript
// nextcloud-talk-bot.ts
import express from "express";
import { createHmac } from "crypto";

const PORT = 8780;
const NEXTCLOUD_URL = process.env.NEXTCLOUD_URL || "https://cloud.example.com";
const BOT_USER = process.env.BOT_USER || "aidevops-bot";
const APP_PASSWORD = process.env.APP_PASSWORD || "";
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET || "";
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
  await fetch(url, { method: "POST",
    headers: { "Content-Type": "application/json", "OCS-APIRequest": "true", "Authorization": `Basic ${auth}` },
    body: JSON.stringify({ message }) });
}

async function sendReaction(conversationToken: string, messageId: string, reaction: string): Promise<void> {
  const url = `${NEXTCLOUD_URL}/ocs/v2.php/apps/spreed/api/v1/reaction/${conversationToken}/${messageId}`;
  const auth = Buffer.from(`${BOT_USER}:${APP_PASSWORD}`).toString("base64");
  await fetch(url, { method: "POST",
    headers: { "Content-Type": "application/json", "OCS-APIRequest": "true", "Authorization": `Basic ${auth}` },
    body: JSON.stringify({ reaction }) });
}

app.post("/webhook", async (req, res) => {
  const signature = req.headers["x-nextcloud-talk-signature"] as string;
  if (!signature || !verifySignature(req.body, signature)) { res.status(401).send("Invalid signature"); return; }
  res.status(200).send("OK");  // respond immediately — process asynchronously

  const payload = JSON.parse(req.body.toString());
  const { id: userId } = payload.actor || {};
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

### OCS API Endpoints

Base: `https://cloud.example.com/ocs/v2.php/apps/spreed/api/` · Auth: `Basic bot-user:app-password` · Header: `OCS-APIRequest: true`

| Action | Method | Path |
|--------|--------|------|
| List conversations | GET | `v4/room` |
| Send message | POST | `v1/chat/TOKEN` · body: `{"message":"..."}` |
| Get messages | GET | `v1/chat/TOKEN?lookIntoFuture=0&limit=50` |
| Send reaction | POST | `v1/reaction/TOKEN/MESSAGE_ID` · body: `{"reaction":"👍"}` |

Talk supports markdown: `**bold**`, `` `code` ``, headings, lists.

## Security

### Privacy Comparison

| Platform | Who can access your messages |
|----------|------------------------------|
| **Slack** | Salesforce, workspace admins (full export), law enforcement |
| **Microsoft Teams** | Microsoft, tenant admins (eDiscovery), law enforcement |
| **Discord** | Discord Inc., law enforcement, trust & safety team |
| **Google Chat** | Google, Workspace admins, law enforcement |
| **Nextcloud Talk** | **Only you** — server admin of your own instance |

Nextcloud GmbH has ZERO access to your instance. Better theoretical privacy: SimpleX (no user identifiers, no collaboration features) and Signal (E2E everything, no self-hosting or file collaboration).

### Encryption + Compliance

- **In transit**: TLS 1.2+ — you configure certificate, cipher suites, HSTS
- **At rest**: Server-side encryption (AES-256-CTR) — you control the master key
- **1:1 calls**: E2E via WebRTC SRTP/DTLS — media goes peer-to-peer when possible
- **Group chats**: NOT E2E encrypted — server-side at rest only; server admin can read all text messages
- **Metadata**: Only YOUR server sees connection logs, access times, IPs, user agents
- **No third-party**: no analytics beacons, no AI training on your data
- **Local AI**: `assistant` app runs models ON YOUR SERVER — no data leaves unless you configure an external API
- **Jurisdiction**: server is where you put it — no CLOUD Act or FISA 702 exposure unless US-hosted
- **Compliance**: GDPR (full control), HIPAA-configurable, SOC2-configurable, ISO 27001 (Nextcloud GmbH certified for dev processes)
- **Open source**: AGPL-3.0 — server, Talk app, mobile apps, desktop app — fully auditable

### Bot-Specific Security

- **Webhook URL**: Can be `localhost`, LAN, or tunneled (Cloudflare Tunnel, WireGuard) — no public internet required
- **Webhook secret**: HMAC-SHA256 signature verification prevents forged deliveries
- **App password**: Scoped, revocable, auditable — not the user's main password
- **Bot runs in YOUR infrastructure**: webhook handler, logs, and temporary data never leave your control

## aidevops Integration

### Helper Commands

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

### Entity Resolution

- **Known user**: Match on `entity_channels` table (`channel=nextcloud-talk`, `channel_id=username`)
- **New user**: Creates entity via `entity-helper.sh create` with Nextcloud user ID linked
- **Cross-channel**: If linked on Matrix, Slack, SimpleX, or email — full profile available
- **Profile enrichment**: Nextcloud user API provides display name, email, groups — populates entity profile on first contact

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

**Privacy note**: Bridging to external platforms (Slack, Discord, Telegram) means messages leave your server and are stored on third-party infrastructure. Bridging to other self-hosted platforms (Matrix, IRC on your network) preserves the self-hosted privacy model. See `services/communications/matterbridge.md`.

## Limitations

| Limitation | Mitigation |
|------------|------------|
| Self-hosted maintenance overhead (server, PHP/DB updates, SSL, backups) | Managed Nextcloud hosting (Hetzner StorageShare, IONOS) or Cloudron — see `services/hosting/cloudron.md` |
| Talk Bot API maturity — smaller surface, less docs, API may change between major versions | Pin Nextcloud and Talk versions; test upgrades in staging |
| No rich interactive components — text, markdown, reactions, file attachments only | Use slash-command patterns or prefix commands for structured input |
| Group chats not E2E encrypted — server admin can read all text messages | Acceptable for most self-hosted deployments where you trust your own server |
| Performance depends on your hardware | Use dedicated TURN server (coturn), Redis for caching, adequate hardware |
| Mobile push notification setup requires Nextcloud push proxy or self-hosted `notify_push` | Additional configuration beyond base Nextcloud install |
| Smaller ecosystem vs Slack (2000+ apps) or Discord (millions of bots) | Build custom integrations using webhook API or OCS REST API |

## Related

- `services/communications/matrix-bot.md` — Matrix bot (federated, E2E encrypted, self-hostable)
- `services/communications/slack.md` — Slack bot (proprietary, no E2E, comprehensive API)
- `services/communications/simplex.md` — SimpleX Chat (zero-identifier messaging, strongest metadata privacy)
- `services/communications/signal.md` — Signal bot (E2E encrypted, phone number required)
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
