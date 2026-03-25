---
description: Slack Bot integration — Bolt SDK setup, Socket Mode, slash commands, interactive components, Agents API, security considerations (no E2E, AI training), Matterbridge, and aidevops dispatch
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

# Slack Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Corporate messaging — no E2E encryption, workspace admin has full access
- **License**: Proprietary (Salesforce). Bot SDK: `@slack/bolt` (MIT)
- **Protocol**: Slack API (HTTP + WebSocket Socket Mode)
- **Encryption**: TLS in transit, AES-256 at rest — NO end-to-end encryption
- **Script**: `slack-dispatch-helper.sh [setup|start|stop|status|map|unmap|mappings|test|logs]`
- **Config**: `~/.config/aidevops/slack-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/slack-bot/`
- **Docs**: https://api.slack.com/docs | https://slack.dev/bolt-js/
- **App Management**: https://api.slack.com/apps

**Quick start**:

```bash
slack-dispatch-helper.sh setup          # Interactive wizard
slack-dispatch-helper.sh map C04ABCDEF general-assistant
slack-dispatch-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Architecture

```text
Slack Workspace → Socket Mode (WebSocket) → Bolt App (Bun/Node)
                                                  │
                                          aidevops Dispatch
                                          runner-helper.sh → AI session → response
                                                  │
                                          memory.db (shared)
                                          ├── entities / entity_channels
                                          └── interactions / conversations
```

**Message flow**: User message → Bolt receives via Socket Mode → access control check → channel-to-runner lookup → entity resolution (Slack user ID → entity profile) → Layer 0 log → context load → runner dispatch → response posted to thread → reaction updated (eyes → checkmark/X).

## Installation

### Prerequisites

1. Slack workspace with admin or app installation permissions
2. Node.js >= 18 or Bun runtime
3. Slack App created at https://api.slack.com/apps

### Step 1: Create App and Install

Go to https://api.slack.com/apps → **Create New App** → **From an app manifest** → paste:

```yaml
display_information:
  name: aidevops Bot
  description: AI-powered DevOps assistant
  background_color: "#1a1a2e"

features:
  bot_user:
    display_name: aidevops
    always_online: true
  slash_commands:
    - command: /ai
      description: Send a prompt to the AI assistant
      usage_hint: "[prompt]"
      should_escape: false

oauth_config:
  scopes:
    bot:
      - app_mentions:read
      - channels:history
      - channels:read
      - chat:write
      - commands
      - files:read
      - files:write
      - groups:history
      - groups:read
      - im:history
      - im:read
      - im:write
      - reactions:read
      - reactions:write
      - users:read

settings:
  event_subscriptions:
    bot_events:
      - app_mention
      - message.channels
      - message.groups
      - message.im
  interactivity:
    is_enabled: true
  org_deploy_enabled: false
  socket_mode_enabled: true
  token_rotation_enabled: false
```

### Step 2: Obtain Tokens

After installing the app:

- **Bot Token** (`xoxb-...`): OAuth & Permissions > Install to Workspace
- **App-Level Token** (`xapp-...`): Basic Information > App-Level Tokens > `connections:write` scope
- **Signing Secret**: Basic Information > App Credentials (Events API only)

```bash
# Store via gopass (preferred)
gopass insert aidevops/slack/bot-token      # xoxb-...
gopass insert aidevops/slack/app-token      # xapp-...
gopass insert aidevops/slack/signing-secret # Events API only
```

### Step 3: Socket Mode vs Events API

| Feature | Socket Mode (recommended) | Events API |
|---------|--------------------------|------------|
| Public URL required | No | Yes |
| Token needed | `xapp-` (App-Level) | Signing Secret |
| Firewall-friendly | Yes (outbound only) | No (inbound HTTP) |
| Best for | Internal bots, development | Public apps, high scale |

Use Socket Mode for aidevops bots — no public endpoint, works behind firewalls.

### Step 4: Install Dependencies

```bash
bun add @slack/bolt   # preferred
npm install @slack/bolt
```

## Bot API Integration

### Basic Bolt App

```typescript
import { App } from "@slack/bolt";

const token = process.env.SLACK_BOT_TOKEN;    // xoxb-...
const appToken = process.env.SLACK_APP_TOKEN; // xapp-... (Socket Mode)
if (!token || !appToken) throw new Error("SLACK_BOT_TOKEN and SLACK_APP_TOKEN must be set");

const app = new App({ token, appToken, socketMode: true });

app.event("app_mention", async ({ event, say }) => {
  const prompt = event.text.replace(/<@[A-Z0-9]+>/g, "").trim();
  if (!prompt) { await say({ text: "Send me a prompt!", thread_ts: event.ts }); return; }

  await app.client.reactions.add({ channel: event.channel, timestamp: event.ts, name: "eyes" });
  try {
    const response = await dispatchToRunner(prompt, event.user, event.channel);
    await say({ text: response, thread_ts: event.ts });
    await app.client.reactions.remove({ channel: event.channel, timestamp: event.ts, name: "eyes" });
    await app.client.reactions.add({ channel: event.channel, timestamp: event.ts, name: "white_check_mark" });
  } catch (error) {
    await say({ text: `Error: ${error.message}`, thread_ts: event.ts });
    await app.client.reactions.add({ channel: event.channel, timestamp: event.ts, name: "x" });
  }
});

// DMs
app.event("message", async ({ event, say }) => {
  if (event.channel_type !== "im" || event.subtype) return;
  await say({ text: await dispatchToRunner(event.text, event.user, event.channel), thread_ts: event.ts });
});

(async () => { await app.start(); console.log("Slack bot running (Socket Mode)"); })();
```

### Slash Commands

```typescript
app.command("/ai", async ({ command, ack, respond }) => {
  await ack(); // Must acknowledge within 3 seconds
  await respond({ response_type: "ephemeral", text: `Processing: "${command.text}"...` });
  const result = await dispatchToRunner(command.text, command.user_id, command.channel_id);
  await respond({ response_type: "in_channel", text: result });
});
```

### Interactive Components

```typescript
// Send buttons
await app.client.chat.postMessage({
  channel: channelId,
  text: "Choose an action:",
  blocks: [{
    type: "actions",
    elements: [
      { type: "button", text: { type: "plain_text", text: "Run Tests" }, action_id: "run_tests", value: "test_suite_all" },
      { type: "button", text: { type: "plain_text", text: "Deploy" }, action_id: "deploy", style: "primary", value: "deploy_staging" },
    ],
  }],
});

app.action("run_tests", async ({ ack, respond }) => { await ack(); await respond({ text: "Running tests...", replace_original: false }); });
app.action("deploy", async ({ ack, respond }) => { await ack(); await respond({ text: "Deploying to staging...", replace_original: false }); });
```

### Thread, Reactions, Files

```typescript
// Thread reply
await app.client.chat.postMessage({ channel: channelId, thread_ts: parentTs, text: "Analysis..." });

// Broadcast thread reply to channel
await app.client.chat.postMessage({ channel: channelId, thread_ts: parentTs, reply_broadcast: true, text: "Summary." });

// Reactions
await app.client.reactions.add({ channel, timestamp, name: "hourglass_flowing_sand" });
await app.client.reactions.remove({ channel, timestamp, name: "hourglass_flowing_sand" });

// File upload
await app.client.files.uploadV2({ channel_id: channelId, filename: "report.md", content: reportContent, title: "Report" });
```

### Slack Agents API (beta)

```typescript
// Requires assistant scope and Agents API beta access
app.event("assistant_thread_started", async ({ event, say }) => {
  await say({ text: "Hello! I'm the aidevops assistant.", thread_ts: event.assistant_thread.thread_ts });
});
app.event("assistant_thread_context_changed", async ({ event }) => {
  console.log(`Context changed to channel ${event.assistant_thread.channel_id}`);
});
```

See: https://api.slack.com/docs/apps/ai

### Access Control

```typescript
const ALLOWED_CHANNELS = new Set(["C04ABCDEF", "C04GHIJKL"]);
const ALLOWED_USERS = new Set<string>(); // empty = allow all

function isAllowed(userId: string, channelId: string): boolean {
  if (ALLOWED_CHANNELS.size > 0 && !ALLOWED_CHANNELS.has(channelId)) return false;
  if (ALLOWED_USERS.size > 0 && !ALLOWED_USERS.has(userId)) return false;
  return true;
}

app.event("app_mention", async ({ event, say }) => {
  if (!isAllowed(event.user, event.channel)) { await say({ text: "Access denied.", thread_ts: event.ts }); return; }
  // ... dispatch
});
```

## Security Considerations

**CRITICAL: Read before deploying any bot that processes sensitive information via Slack.**

### Encryption

Slack provides TLS 1.2+ in transit and AES-256 at rest. There is **NO end-to-end encryption**. Slack (Salesforce) has full technical access to ALL message content — channels, DMs, files, edits, and deleted messages (retained server-side).

### Workspace Admin Access

| Plan | Admin Export Capability |
|------|------------------------|
| **Free / Pro** | Public channel exports. Private channels/DMs require Slack support; may notify users. |
| **Business+** | Full compliance exports of ALL messages including private channels and DMs. No user notification required. |
| **Enterprise Grid** | Full compliance exports, DLP, audit logs, eDiscovery, legal holds, data residency. Messages searchable/exportable by design. |

### Metadata Collection

Slack stores: full message history with edit history, deletion logs (recoverable by admins), file records, reaction/emoji usage, read receipts, login times/IPs/devices, channel membership history, search queries, integration usage patterns.

### AI Training and Data Processing

**CRITICAL**: Slack's privacy policy (updated September 2023) allows customer data (messages, content, usage) to be used for global ML model training unless the workspace admin explicitly opts out. The opt-out is not automatic — many admins are unaware of this default.

- **Slack AI features** (channel summaries, search answers): process messages server-side
- **Salesforce Einstein AI**: can integrate with Slack data for CRM insights
- **Third-party Marketplace apps**: each governed by its own privacy policy

**Assume any Slack message may train AI models unless the admin has explicitly opted out.**

### Push Notifications

Delivered via Google FCM (Android) and Apple APNs (iOS). Default notification content includes message preview — visible to Google/Apple in transit. Admins can restrict to "You have a new message" to reduce exposure.

### Open Source and Auditability

- **Slack platform**: Entirely closed source. No independent audit possible.
- **Slack SDKs** (`@slack/bolt`, `@slack/web-api`): Open source (MIT). Bot code is auditable; server-side is not.

### Jurisdiction and Legal

- **Entity**: Salesforce, Inc. — San Francisco, California, USA
- **Jurisdiction**: US federal law including CLOUD Act, FISA Section 702, National Security Letters
- **EU Data Residency**: Enterprise Grid only. Controls where data is stored, not who can access it — Salesforce US personnel may still access EU-resident data.

### Bot-Specific Security

- Bot tokens (`xoxb-`) are scoped but can access all channels the bot is added to
- App-level tokens (`xapp-`) have workspace-wide scope for connection management
- **Token rotation**: Supported but disabled by default in the manifest — enable for production
- **Signing secrets**: When using Events API, always verify `X-Slack-Signature` to prevent request forgery

### Platform Comparison

| Aspect | Slack | Matrix (self-hosted) | SimpleX | Signal |
|--------|-------|---------------------|---------|--------|
| E2E encryption | No | Yes (Megolm) | Yes (Double ratchet) | Yes (Signal Protocol) |
| Server access to content | Full | None (if E2E on) | None (stateless) | None (sealed sender) |
| Admin message export | Yes (all plans) | Server admin only | N/A | No |
| AI training default | Opt-out required | No | No | No |
| Open source server | No | Yes (Synapse) | Yes (SMP) | Partial |
| Self-hostable | No | Yes | Yes | No |
| Jurisdiction | USA (Salesforce) | Self-determined | Self-determined | USA (Signal Foundation) |

**Summary**: Slack is among the least private mainstream messaging platforms. Treat all Slack messages as fully observable by the employer AND Salesforce. Use for work communication where corporate oversight is expected. Never use for sensitive personal communication, confidential legal matters, or information that should not be accessible to the workspace owner or Salesforce.

## aidevops Integration

### slack-dispatch-helper.sh

```bash
slack-dispatch-helper.sh setup                    # Interactive wizard
slack-dispatch-helper.sh map C04ABCDEF code-reviewer
slack-dispatch-helper.sh map C04GHIJKL seo-analyst
slack-dispatch-helper.sh mappings                 # List mappings
slack-dispatch-helper.sh unmap C04ABCDEF          # Remove mapping
slack-dispatch-helper.sh start --daemon
slack-dispatch-helper.sh stop
slack-dispatch-helper.sh status
slack-dispatch-helper.sh test code-reviewer "Review src/auth.ts"
slack-dispatch-helper.sh logs [--follow]
```

### Runner Dispatch and Entity Resolution

The bot dispatches to runners via `runner-helper.sh` (handles runner AGENTS.md, headless sessions, memory namespace isolation, entity-aware context, run logging).

Entity resolution: Slack user ID (`U01ABCDEF`) → `entity_channels` table lookup → entity profile. New users are created via `entity-helper.sh create`. Cross-channel identity (Matrix, SimpleX, email) is available if linked. Profile enrichment uses Slack's `users.info` API (display name, email, timezone) on first contact.

### Configuration

`~/.config/aidevops/slack-bot.json` (600 permissions):

> **Security**: Store `botToken`, `appToken`, and `signingSecret` in gopass (`aidevops secret set slack-bot-token`), not in this JSON file. Reference them via environment variables or `credentials.sh`. The values below are placeholders only.

```json
{
  "botToken": "stored-in-gopass",
  "appToken": "stored-in-gopass",
  "signingSecret": "stored-in-gopass",
  "socketMode": true,
  "allowedChannels": ["C04ABCDEF", "C04GHIJKL"],
  "allowedUsers": [],
  "defaultRunner": "",
  "channelMappings": {
    "C04ABCDEF": "code-reviewer",
    "C04GHIJKL": "seo-analyst"
  },
  "botPrefix": "",
  "ignoreOwnMessages": true,
  "maxPromptLength": 3000,
  "responseTimeout": 600,
  "sessionIdleTimeout": 300
}
```

`botPrefix` is empty by default — Slack bots are invoked via `@mention` or slash commands. Set a prefix (e.g., `!ai`) for prefix-based triggering in addition to mentions.

## Matterbridge Integration

Slack is natively supported by [Matterbridge](https://github.com/42wim/matterbridge) via the Slack Bot API.

```toml
# matterbridge.toml
[slack.myworkspace]
Token = "xoxb-your-bot-token"
ShowJoinPart = false
UseThread = false

[[gateway]]
name = "dev-bridge"
enable = true

[[gateway.inout]]
account = "slack.myworkspace"
channel = "dev-general"

[[gateway.inout]]
account = "matrix.myserver"
channel = "#dev:matrix.example.com"
```

**Privacy warning**: Bridging Slack to E2E-encrypted platforms (Matrix, SimpleX) means those messages are stored unencrypted on Slack's servers. Inform users on the encrypted side. See `services/communications/matterbridge.md`.

## Limitations

### Rate Limits

| API | Rate Limit |
|-----|-----------|
| Web API (most methods) | 1 req/sec per method per workspace (burst allowed) |
| `chat.postMessage` | 1/sec per channel (higher for Enterprise Grid) |
| Socket Mode | 30,000 events/hour per app |
| Files API | 20/min (upload + download combined) |

Bolt SDK handles rate limiting with automatic retries.

### Free Plan

- 90-day message history (hidden, not deleted — visible on upgrade)
- 10 app integrations maximum
- No compliance exports (public channels only)
- 1:1 huddles only (no group audio/video)
- 5 GB file storage per workspace

### Socket Mode

- Requires `xapp-` token with `connections:write` scope
- Maximum 10 concurrent connections per app
- Connections may drop — Bolt SDK handles auto-reconnect

### No Self-Hosting

SaaS-only. All data on Salesforce infrastructure (AWS). Organizations requiring full data sovereignty must use alternatives (Mattermost, Matrix, Rocket.Chat).

### Enterprise Grid

Adds complexity: org-level vs workspace-level tokens, cross-workspace channel sharing, multiple admin permission levels, separate compliance/DLP configurations.

### No End-to-End Encryption

Fundamental platform design choice — Slack's compliance and eDiscovery capabilities depend on server-side access. AI training opt-out is a policy default requiring active admin action.

## Related

- `services/communications/matrix-bot.md` — Matrix bot (E2E encrypted, self-hostable)
- `services/communications/simplex.md` — SimpleX Chat (no identifiers, maximum privacy)
- `services/communications/matterbridge.md` — Multi-platform chat bridging
- `scripts/entity-helper.sh` — Entity memory system (identity resolution, Layer 0/1/2)
- `scripts/runner-helper.sh` — Runner management
- `tools/security/opsec.md` — Operational security guidance
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- Slack Bolt SDK: https://slack.dev/bolt-js/
- Slack API: https://api.slack.com/
- Slack Agents API: https://api.slack.com/docs/apps/ai
- Slack Privacy Policy: https://slack.com/trust/privacy/privacy-policy
