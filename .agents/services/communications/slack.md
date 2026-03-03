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

- **Type**: Corporate messaging platform — no E2E encryption, workspace admin has full access
- **License**: Proprietary (Salesforce). Bot SDK: `@slack/bolt` (MIT)
- **Bot tool**: Slack Bolt SDK (TypeScript, official)
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
┌──────────────────────┐
│ Slack Workspace       │
│                       │
│ User sends message    │
│ or slash command      │
└──────────┬───────────┘
           │
           │  Socket Mode (WebSocket)      OR      Events API (HTTP POST)
           │  (recommended — no public URL)        (requires public endpoint)
           │
┌──────────▼───────────┐     ┌──────────────────────┐
│ Bolt App (Bun/Node)  │     │ aidevops Dispatch     │
│                       │     │                       │
│ ├─ Event listeners    │────▶│ runner-helper.sh      │
│ ├─ Slash commands     │     │ → AI session          │
│ ├─ Interactive handler│◀────│ → response            │
│ ├─ Access control     │     │                       │
│ └─ Entity resolution  │     │                       │
└──────────┬───────────┘     └──────────────────────┘
           │
┌──────────▼───────────┐
│ memory.db (shared)    │
│ ├── entities          │  Entity profiles
│ ├── entity_channels   │  Cross-channel identity
│ ├── interactions      │  Layer 0: Immutable log
│ └── conversations     │  Layer 1: Context summaries
└───────────────────────┘
```

**Message flow**:

1. User sends message or slash command in a Slack channel or DM
2. Slack delivers event via Socket Mode (WebSocket) or Events API (HTTP)
3. Bolt app receives event, checks access control (workspace/channel/user allowlists)
4. Bot looks up channel-to-runner mapping
5. Entity resolution: Slack user ID (`U01ABCDEF`) resolved to entity via `entity-helper.sh`
6. Layer 0 logging: user message logged as immutable interaction
7. Context loading: entity profile + conversation summary + recent interactions
8. Bot dispatches entity-aware prompt to runner via `runner-helper.sh`
9. Runner executes via headless dispatch
10. Bot posts response back to Slack channel or thread
11. Bot adds reaction emoji (eyes while processing, checkmark on success, X on failure)

## Installation

### Prerequisites

1. **Slack workspace** with admin or app installation permissions
2. **Node.js >= 18** or **Bun** runtime
3. **Slack App** created at https://api.slack.com/apps

### Step 1: Create a Slack App

1. Go to https://api.slack.com/apps and click **Create New App**
2. Choose **From an app manifest** (recommended) or **From scratch**
3. Select the target workspace
4. If using a manifest, paste the YAML below

### App Manifest

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

### Step 2: Install and Obtain Tokens

After creating the app:

1. **Bot Token** (`xoxb-...`): OAuth & Permissions > Install to Workspace > Copy Bot User OAuth Token
2. **App-Level Token** (`xapp-...`): Basic Information > App-Level Tokens > Generate Token with `connections:write` scope
3. **Signing Secret**: Basic Information > App Credentials > Signing Secret (for HTTP Events API only)

Store tokens securely:

```bash
# Via gopass (preferred)
gopass insert aidevops/slack/bot-token      # xoxb-...
gopass insert aidevops/slack/app-token      # xapp-...
gopass insert aidevops/slack/signing-secret # (if using Events API)

# Or via credentials.sh fallback
# Added to ~/.config/aidevops/credentials.sh (600 permissions)
```

### Step 3: Socket Mode vs Events API

| Feature | Socket Mode (recommended) | Events API |
|---------|--------------------------|------------|
| Public URL required | No | Yes |
| Connection method | WebSocket | HTTP POST |
| Token needed | App-Level Token (`xapp-`) | Signing Secret |
| Firewall-friendly | Yes (outbound only) | No (inbound HTTP) |
| Latency | Slightly lower | Standard |
| Best for | Development, internal bots | Public apps, high scale |

**Recommendation**: Use Socket Mode for aidevops bots. No public endpoint needed, simpler setup, works behind firewalls.

### Step 4: Install Dependencies

```bash
# Using Bun (preferred)
bun add @slack/bolt

# Using npm
npm install @slack/bolt
```

## Bot API Integration

### Basic Bolt App

```typescript
import { App } from "@slack/bolt";

const app = new App({
  token: process.env.SLACK_BOT_TOKEN,       // xoxb-...
  appToken: process.env.SLACK_APP_TOKEN,     // xapp-... (Socket Mode)
  socketMode: true,
});

// Listen for messages mentioning the bot
app.event("app_mention", async ({ event, say }) => {
  const prompt = event.text.replace(/<@[A-Z0-9]+>/g, "").trim();
  if (!prompt) {
    await say({ text: "Send me a prompt and I'll help!", thread_ts: event.ts });
    return;
  }

  // Add processing reaction
  await app.client.reactions.add({
    channel: event.channel,
    timestamp: event.ts,
    name: "eyes",
  });

  try {
    // Dispatch to runner (placeholder — integrate with runner-helper.sh)
    const response = await dispatchToRunner(prompt, event.user, event.channel);

    await say({ text: response, thread_ts: event.ts });

    // Replace eyes with checkmark
    await app.client.reactions.remove({
      channel: event.channel,
      timestamp: event.ts,
      name: "eyes",
    });
    await app.client.reactions.add({
      channel: event.channel,
      timestamp: event.ts,
      name: "white_check_mark",
    });
  } catch (error) {
    await say({ text: `Error: ${error.message}`, thread_ts: event.ts });
    await app.client.reactions.add({
      channel: event.channel,
      timestamp: event.ts,
      name: "x",
    });
  }
});

// Listen for DMs
app.event("message", async ({ event, say }) => {
  if (event.channel_type !== "im" || event.subtype) return;

  const response = await dispatchToRunner(event.text, event.user, event.channel);
  await say({ text: response, thread_ts: event.ts });
});

(async () => {
  await app.start();
  console.log("Slack bot running (Socket Mode)");
})();
```

### Slash Commands

```typescript
// /ai <prompt>
app.command("/ai", async ({ command, ack, respond }) => {
  await ack(); // Acknowledge within 3 seconds

  const prompt = command.text;
  const userId = command.user_id;
  const channelId = command.channel_id;

  // Respond ephemerally first (only visible to the user)
  await respond({
    response_type: "ephemeral",
    text: `Processing: "${prompt}"...`,
  });

  const result = await dispatchToRunner(prompt, userId, channelId);

  // Follow-up with visible response
  await respond({
    response_type: "in_channel",
    text: result,
  });
});
```

### Interactive Components (Buttons, Selects, Modals)

```typescript
// Send a message with buttons
await app.client.chat.postMessage({
  channel: channelId,
  text: "Choose an action:",
  blocks: [
    {
      type: "actions",
      elements: [
        {
          type: "button",
          text: { type: "plain_text", text: "Run Tests" },
          action_id: "run_tests",
          value: "test_suite_all",
        },
        {
          type: "button",
          text: { type: "plain_text", text: "Deploy" },
          action_id: "deploy",
          style: "primary",
          value: "deploy_staging",
        },
      ],
    },
  ],
});

// Handle button clicks
app.action("run_tests", async ({ ack, body, respond }) => {
  await ack();
  await respond({ text: "Running test suite...", replace_original: false });
  // Dispatch test runner
});

app.action("deploy", async ({ ack, body, respond }) => {
  await ack();
  await respond({ text: "Starting deployment to staging...", replace_original: false });
  // Dispatch deploy runner
});
```

### Thread Messaging

```typescript
// Reply in a thread
await app.client.chat.postMessage({
  channel: channelId,
  thread_ts: parentMessageTs, // Creates or continues a thread
  text: "Here's the analysis...",
});

// Broadcast thread reply to channel
await app.client.chat.postMessage({
  channel: channelId,
  thread_ts: parentMessageTs,
  reply_broadcast: true,
  text: "Summary posted to channel from thread.",
});
```

### Reactions and Typing Indicators

```typescript
// Add/remove reactions
await app.client.reactions.add({ channel, timestamp, name: "hourglass_flowing_sand" });
await app.client.reactions.remove({ channel, timestamp, name: "hourglass_flowing_sand" });

// Typing indicator (Slack doesn't have a direct API — but the bot shows
// "typing" automatically while processing Socket Mode events)
```

### File Uploads

```typescript
// Upload a file to a channel
await app.client.files.uploadV2({
  channel_id: channelId,
  filename: "report.md",
  content: reportContent,
  title: "Analysis Report",
  initial_comment: "Here's the requested report.",
});

// Upload from filesystem
await app.client.files.uploadV2({
  channel_id: channelId,
  file: fs.createReadStream("/path/to/file.pdf"),
  filename: "document.pdf",
});
```

### Slack Agents and AI Apps API

Slack provides a native Agents API (beta) for building AI assistants with streaming responses and contextual suggestions.

```typescript
// Agent-mode: handle assistant thread events
// Requires the assistant scope and Agents API beta access
app.event("assistant_thread_started", async ({ event, say }) => {
  await say({
    text: "Hello! I'm the aidevops assistant. How can I help?",
    thread_ts: event.assistant_thread.thread_ts,
  });
});

app.event("assistant_thread_context_changed", async ({ event }) => {
  // User switched channels — update context
  console.log(`Context changed to channel ${event.assistant_thread.channel_id}`);
});
```

See: https://api.slack.com/docs/apps/ai

### Access Control

```typescript
// Channel allowlist
const ALLOWED_CHANNELS = new Set(["C04ABCDEF", "C04GHIJKL"]);

// User allowlist (optional — restrict to specific users)
const ALLOWED_USERS = new Set(["U01ADMIN", "U02DEV"]);

function isAllowed(userId: string, channelId: string): boolean {
  // If allowlists are empty, allow all
  if (ALLOWED_CHANNELS.size > 0 && !ALLOWED_CHANNELS.has(channelId)) {
    return false;
  }
  if (ALLOWED_USERS.size > 0 && !ALLOWED_USERS.has(userId)) {
    return false;
  }
  return true;
}

// Apply in event handlers
app.event("app_mention", async ({ event, say }) => {
  if (!isAllowed(event.user, event.channel)) {
    await say({ text: "Access denied.", thread_ts: event.ts });
    return;
  }
  // ... dispatch
});
```

## Security Considerations

**CRITICAL: Read this section carefully before deploying any bot that processes sensitive information via Slack.**

### Encryption

Slack provides **TLS 1.2+ in transit** and **AES-256 at rest** on Slack's servers. There is **NO end-to-end encryption**. Slack (Salesforce) has full technical access to ALL message content, including:

- All channel messages (public and private)
- All direct messages (1:1 and group DMs)
- All file uploads
- All message edits and their history
- All deleted messages (retained server-side)

### Workspace Admin Access

Workspace owners and admins have broad access to message data:

| Plan | Admin Export Capability |
|------|----------------------|
| **Free / Pro** | Admins can request data exports of public channels. Compliance exports of private channels and DMs require contacting Slack support and may notify users. |
| **Business+** | Full compliance exports of ALL messages including private channels and DMs. No user notification required. Corporate eDiscovery tools. |
| **Enterprise Grid** | Full compliance exports, DLP integration, audit logs, eDiscovery, legal holds, data residency controls. Designed for regulatory compliance — messages are searchable and exportable by design. |

### Metadata Collection

Slack stores comprehensive metadata beyond message content:

- Full message history with timestamps
- Edit history (all versions retained)
- Deletion logs (deleted messages recoverable by admins)
- File upload and download records
- Reaction and emoji usage
- Read receipts (who read what, when)
- Login times, IP addresses, device information
- Channel membership and join/leave history
- Search queries
- Integration and app usage patterns

### AI Training and Data Processing

**CRITICAL WARNING**: Slack's terms of service and privacy policy (updated September 2023) include provisions regarding AI/ML model development:

- **Global models**: Slack's privacy policy states that customer data including messages, content, and usage data may be used to develop and train machine learning models that improve Slack's services globally. This applies to all plans unless the workspace admin explicitly opts out.
- **Workspace admins must opt out**: The opt-out is not automatic. Admins must contact Slack or adjust settings to exclude their workspace data from global ML training. Many admins are unaware of this default.
- **Slack AI features**: Slack AI (channel summaries, search answers, thread summaries) processes message content to generate responses. These features are enabled per-workspace and process messages server-side.
- **Salesforce Einstein AI**: Salesforce's AI platform can integrate with Slack data for CRM insights, sales intelligence, and workflow automation. Data flows between Slack and Salesforce are governed by Salesforce's data processing agreements.
- **Third-party AI apps**: Apps installed from the Slack Marketplace may access message content within their granted scopes. Each app's data handling is governed by its own privacy policy, not Slack's.

**Practical impact**: Assume that any message sent in Slack may be used to train AI models unless the workspace admin has explicitly opted out of all data sharing.

### Push Notifications

Push notifications are delivered via Google Firebase Cloud Messaging (FCM) for Android and Apple Push Notification Service (APNs) for iOS. By default, notification content includes a message preview, making it visible to Google or Apple during transit. Admins can configure notification content to show only "You have a new message" to reduce exposure.

### Open Source and Auditability

- **Slack platform**: Entirely closed source. No independent audit of Slack's data handling, encryption implementation, or access controls is possible.
- **Slack SDKs**: Open source under MIT license (`@slack/bolt`, `@slack/web-api`, etc.). Bot code is auditable; Slack's server-side processing is not.
- **No reproducible builds**: Slack clients (desktop, mobile, web) are closed source. Users cannot verify that the client matches any claimed security properties.

### Jurisdiction and Legal

- **Entity**: Salesforce, Inc. — headquartered in San Francisco, California, USA
- **Jurisdiction**: Subject to US federal law, including the CLOUD Act (allows US government to compel disclosure of data stored abroad), FISA Section 702, and National Security Letters
- **EU Data Residency**: Available on Enterprise Grid plans. Data can be stored in specific AWS regions (Frankfurt, etc.). Note: data residency controls where data is stored, not who can access it — Salesforce US personnel may still access EU-resident data under certain conditions
- **Government requests**: Slack publishes a transparency report. Law enforcement requests are processed per Slack's Law Enforcement Guidelines

### Bot-Specific Security

- Bot tokens (`xoxb-`) have scoped permissions based on OAuth scopes, but can access all channels the bot is added to
- Slack's permission model is **workspace-centric** — a bot installed in a workspace can potentially access more data than intended if OAuth scopes are broad
- App-level tokens (`xapp-`) have workspace-wide scope for connection management
- **Token rotation**: Slack supports token rotation but it is disabled by default in the app manifest. Enable for production deployments
- **Signing secrets**: When using Events API (HTTP), always verify the `X-Slack-Signature` header to prevent request forgery

### Comparison with Other Platforms

| Aspect | Slack | Matrix (self-hosted) | SimpleX | Signal |
|--------|-------|---------------------|---------|--------|
| E2E encryption | No | Yes (Megolm) | Yes (Double ratchet) | Yes (Signal Protocol) |
| Server access to content | Full | None (if E2E on) | None (stateless) | None (sealed sender) |
| Admin message export | Yes (all plans) | Server admin only | N/A (no server storage) | No |
| AI training default | Opt-out required | No | No | No |
| Open source server | No | Yes (Synapse) | Yes (SMP) | Partial |
| User identifiers | Workspace email | `@user:server` | None | Phone number |
| Metadata retention | Comprehensive | Moderate | Minimal | Minimal |
| Self-hostable | No | Yes | Yes | No |
| Jurisdiction | USA (Salesforce) | Self-determined | Self-determined | USA (Signal Foundation) |

**Summary**: Slack is among the **least private** mainstream messaging platforms. No E2E encryption, full admin export capability, AI training opt-out (not opt-in), comprehensive metadata retention, and closed-source server. **Treat all Slack messages as fully observable by the employer AND Salesforce.** Use Slack for work communication where corporate oversight is expected and acceptable. Never use it for sensitive personal communication, confidential legal matters, or information that should not be accessible to the workspace owner or Salesforce.

## aidevops Integration

### slack-dispatch-helper.sh

The helper script follows the same pattern as `matrix-dispatch-helper.sh`:

```bash
# Setup wizard — prompts for tokens, workspace, channel mappings
slack-dispatch-helper.sh setup

# Map Slack channels to runners
slack-dispatch-helper.sh map C04ABCDEF code-reviewer
slack-dispatch-helper.sh map C04GHIJKL seo-analyst

# List mappings
slack-dispatch-helper.sh mappings

# Remove a mapping
slack-dispatch-helper.sh unmap C04ABCDEF

# Start/stop the bot
slack-dispatch-helper.sh start --daemon
slack-dispatch-helper.sh stop
slack-dispatch-helper.sh status

# Test dispatch
slack-dispatch-helper.sh test code-reviewer "Review src/auth.ts"

# View logs
slack-dispatch-helper.sh logs
slack-dispatch-helper.sh logs --follow
```

### Runner Dispatch

The bot dispatches to runners via `runner-helper.sh`, which handles:

- Runner AGENTS.md (personality/instructions)
- Headless session management
- Memory namespace isolation
- Entity-aware context loading
- Run logging

### Entity Resolution

When a Slack user sends a message, the bot resolves their Slack user ID to an entity:

- **Known user**: Match on `entity_channels` table (`channel=slack`, `channel_id=U01ABCDEF`)
- **New user**: Creates entity via `entity-helper.sh create` with Slack user ID linked
- **Cross-channel**: If the same person is linked on other channels (Matrix, SimpleX, email), their full profile is available
- **Profile enrichment**: Slack's `users.info` API provides display name, email (if shared), timezone — used to populate entity profile on first contact

### Configuration

`~/.config/aidevops/slack-bot.json` (600 permissions):

```json
{
  "botToken": "xoxb-...",
  "appToken": "xapp-...",
  "signingSecret": "",
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

**Note**: `botPrefix` is empty by default because Slack bots are typically invoked via `@mention` or slash commands rather than text prefixes. Set a prefix (e.g., `!ai`) if you want prefix-based triggering in addition to mentions.

## Matterbridge Integration

Slack is natively supported by [Matterbridge](https://github.com/42wim/matterbridge) using the Slack Bot API.

```text
Slack Workspace
    │
    │  Slack Bot API (via bot token)
    │
Matterbridge (Go binary)
    │
    ├── Matrix rooms
    ├── Discord channels
    ├── Telegram groups
    ├── SimpleX contacts
    ├── IRC channels
    └── 40+ other platforms
```

### Matterbridge Configuration

Add to `matterbridge.toml`:

```toml
[slack.myworkspace]
Token = "xoxb-your-bot-token"
## Optional: restrict to specific channels
## Channels are specified in the gateway section below

## Optional: show join/leave messages
ShowJoinPart = false

## Optional: use thread replies
UseThread = false
```

Gateway configuration:

```toml
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

**Privacy warning**: Bridging Slack to other platforms means messages from E2E-encrypted platforms (Matrix, SimpleX) will be stored unencrypted on Slack's servers. Users on the encrypted side should be informed that their messages will be visible to Slack, Salesforce, and workspace admins. See `services/communications/matterbridge.md` for full bridging considerations.

## Limitations

### No End-to-End Encryption

Slack does not support E2E encryption. All messages are readable by Slack (Salesforce) and workspace administrators. This is a fundamental platform design choice, not a missing feature — Slack's compliance and eDiscovery capabilities depend on server-side access to message content.

### AI Training Default-On

Workspace data may be used for AI/ML model training unless the admin explicitly opts out. This is a policy default, not a technical limitation. Admins must take active steps to disable this.

### Rate Limits

| API | Rate Limit | Notes |
|-----|-----------|-------|
| Web API (most methods) | 1 request per second per method per workspace | Burst allowed, then throttled |
| `chat.postMessage` | 1 per second per channel | Higher for Enterprise Grid |
| Events API | Varies by event type | Slack may retry on 5xx |
| Socket Mode | 30,000 events per hour | Per app |
| Files API | 20 per minute | Upload/download combined |

Bolt SDK handles rate limiting automatically with retries.

### Free Plan Restrictions

- **90-day message history**: Messages older than 90 days are hidden (not deleted — become visible on upgrade)
- **10 app integrations**: Maximum 10 third-party apps or custom integrations
- **No compliance exports**: Admin export limited to public channels
- **1:1 huddles only**: No group audio/video
- **5 GB file storage**: Per workspace

### Socket Mode Requirements

- Requires an app-level token (`xapp-`) with `connections:write` scope
- Maximum 10 concurrent Socket Mode connections per app
- Connections may be dropped and must be auto-reconnected (Bolt SDK handles this)

### No Self-Hosting

Slack is a SaaS-only platform. There is no self-hosted option. All data is stored on Salesforce's infrastructure (AWS). Organizations requiring full data sovereignty must use alternatives (Mattermost, Matrix, Rocket.Chat).

### Enterprise Grid Complexity

Enterprise Grid (multi-workspace) adds complexity:

- Org-level tokens vs workspace-level tokens
- Cross-workspace channel sharing
- Different admin permission levels
- Separate compliance and DLP configurations

## Related

- `services/communications/matrix-bot.md` — Matrix bot integration (E2E encrypted, self-hostable)
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
