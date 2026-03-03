---
description: Google Chat Bot integration — HTTP webhook/REST API setup, card messages, security considerations (no E2E, Gemini AI training), Matterbridge (unsupported), and aidevops dispatch
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

# Google Chat Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Google Workspace messaging — no E2E encryption, Google has full access
- **License**: Proprietary (Google). No official TypeScript SDK — HTTP API + webhook
- **Bot tool**: Google Chat API (HTTP webhook mode, REST API)
- **Protocol**: Google Chat API (HTTP/JSON)
- **Encryption**: TLS in transit, Google-managed at rest — NO end-to-end encryption
- **Script**: `google-chat-dispatch-helper.sh [setup|start|stop|status|map|unmap|mappings|test|logs]`
- **Config**: `~/.config/aidevops/google-chat-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/google-chat-bot/`
- **Docs**: https://developers.google.com/workspace/chat/api/reference/rest | https://developers.google.com/workspace/chat
- **Console**: https://console.cloud.google.com/apis/api/chat.googleapis.com

**Quick start**:

```bash
google-chat-dispatch-helper.sh setup          # Interactive wizard
google-chat-dispatch-helper.sh map spaces/AAAA general-assistant
google-chat-dispatch-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────────┐
│ Google Chat Space         │
│                           │
│ User sends message        │
│ or @mentions bot          │
└────────────┬─────────────┘
             │
             │  HTTP POST (webhook push)        OR      Pub/Sub subscription
             │  (Google pushes events to URL)           (async event delivery)
             │
             │  ⚠ Requires public URL:
             │    Tailscale Funnel (recommended)
             │    Caddy reverse proxy
             │    Cloudflare Tunnel
             │    ngrok
             │
┌────────────▼─────────────┐     ┌──────────────────────┐
│ Webhook Handler (Bun)    │     │ aidevops Dispatch     │
│                           │     │                       │
│ ├─ Event router           │────▶│ runner-helper.sh      │
│ ├─ Message handler        │     │ → AI session          │
│ ├─ Card action handler    │◀────│ → response            │
│ ├─ Access control         │     │                       │
│ └─ Entity resolution      │     │                       │
└────────────┬─────────────┘     └──────────────────────┘
             │
┌────────────▼─────────────┐
│ memory.db (shared)        │
│ ├── entities              │  Entity profiles
│ ├── entity_channels       │  Cross-channel identity
│ ├── interactions          │  Layer 0: Immutable log
│ └── conversations         │  Layer 1: Context summaries
└───────────────────────────┘
```

**Message flow**: User sends message/mention → Google pushes HTTP POST to webhook URL → handler verifies authenticity and checks access control → space-to-runner mapping lookup → entity resolution via `entity-helper.sh` → Layer 0 logging → context loading (entity profile + conversation summary) → dispatch to runner via `runner-helper.sh` → response sent back via REST API → emoji reaction added (success/failure).

## Installation

### Prerequisites

1. **Google Workspace account** — consumer Google accounts cannot create Chat bots
2. **Google Cloud project** with billing enabled
3. **Node.js >= 18** or **Bun** runtime
4. **Public URL** for webhook delivery (see architecture diagram above)

### Step 1: Create a Google Cloud Project

1. Go to https://console.cloud.google.com and create a new project (or select an existing one)
2. Note the **Project ID** — you will need it for API calls

### Step 2: Enable the Google Chat API

```bash
# Via gcloud CLI
gcloud services enable chat.googleapis.com --project=YOUR_PROJECT_ID

# Or via Console: APIs & Services > Library > search "Google Chat API" > Enable
```

### Step 3: Create a Service Account

```bash
# Create service account and download key
gcloud iam service-accounts create aidevops-chat-bot \
  --display-name="aidevops Chat Bot" --project=YOUR_PROJECT_ID

gcloud iam service-accounts keys create /tmp/chat-bot-sa-key.json \
  --iam-account=aidevops-chat-bot@YOUR_PROJECT_ID.iam.gserviceaccount.com

# Store securely via gopass (preferred) — then delete the plaintext key
gopass insert -m aidevops/google-chat/service-account-key < /tmp/chat-bot-sa-key.json
rm /tmp/chat-bot-sa-key.json
```

### Step 4: Configure the Chat App

1. Go to https://console.cloud.google.com/apis/api/chat.googleapis.com/hangouts-chat > **Configuration**
2. Set app name ("aidevops Bot"), description, functionality (1:1 messages + spaces)
3. Connection settings: **HTTP endpoint URL** — enter your public webhook URL
4. Set visibility (who can discover and install the bot) and click **Save**

### Step 5: Set Up a Public URL

Google Chat requires a publicly accessible HTTPS endpoint — **no Socket Mode equivalent**. Recommended: Tailscale Funnel (no open ports, persistent URL). Alternatives: Caddy reverse proxy, Cloudflare Tunnel, ngrok.

```bash
# Expose local port via Tailscale Funnel
tailscale funnel 8443
# Endpoint: https://your-machine.your-tailnet.ts.net:8443
```

### Step 6: Install Dependencies

```bash
# Using Bun (preferred)
bun add googleapis google-auth-library

# Using npm
npm install googleapis google-auth-library
```

## Bot API Integration

### HTTP Webhook Handler

Google Chat delivers events as HTTP POST requests with JSON payloads. This is the primary integration mode — there is no WebSocket or Socket Mode equivalent.

```typescript
import { google } from "googleapis";
import { GoogleAuth } from "google-auth-library";

const PORT = Number(process.env.PORT) || 8443;

// Authenticate with service account
const auth = new GoogleAuth({
  keyFile: process.env.GOOGLE_CHAT_SA_KEY_PATH,
  scopes: ["https://www.googleapis.com/auth/chat.bot"],
});
const chat = google.chat({ version: "v1", auth });

// Webhook handler (Bun.serve)
Bun.serve({
  port: PORT,
  async fetch(req) {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const event = await req.json();

    // Route by event type
    switch (event.type) {
      case "ADDED_TO_SPACE":
        return handleAddedToSpace(event);
      case "MESSAGE":
        return handleMessage(event);
      case "CARD_CLICKED":
        return handleCardClicked(event);
      case "REMOVED_FROM_SPACE":
        return handleRemovedFromSpace(event);
      default:
        return Response.json({ text: "" });
    }
  },
});

async function handleAddedToSpace(event: any): Promise<Response> {
  return Response.json({ text: "Hello! I'm the aidevops assistant. Mention me or send a DM." });
}

async function handleMessage(event: any): Promise<Response> {
  const userMessage = event.message.argumentText?.trim() || event.message.text?.trim();
  if (!userMessage) return Response.json({ text: "Send me a prompt and I'll help!" });

  try {
    const response = await dispatchToRunner(userMessage, event.user, event.space.name);
    return Response.json({ text: response });
  } catch (error) {
    return Response.json({ text: `Error: ${error.message}` });
  }
}

async function handleCardClicked(event: any): Promise<Response> {
  return Response.json({ text: `Action "${event.action.actionMethodName}" received.` });
}

async function handleRemovedFromSpace(_event: any): Promise<Response> {
  return Response.json({});
}

console.log(`Google Chat webhook handler running on port ${PORT}`);
```

### Sending Messages via REST API

Synchronous webhook responses work for simple replies. For async responses (long-running tasks), use the REST API:

```typescript
// Send a message to a space
async function sendMessage(spaceName: string, text: string, threadKey?: string) {
  const requestBody: any = { text };

  if (threadKey) {
    requestBody.thread = { threadKey };
    // Reply in existing thread
  }

  const res = await chat.spaces.messages.create({
    parent: spaceName,
    requestBody,
    // messageReplyOption: "REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD",
  });

  return res.data;
}

// Send to a specific space
await sendMessage("spaces/AAAAxxxxxx", "Deployment complete.");
```

### Card Messages

Google Chat supports rich card messages with headers, sections, widgets, and buttons (Cards v2):

```typescript
// Minimal card with header, decorated text, and action button
const requestBody = {
  cardsV2: [{
    cardId: "status-card",
    card: {
      header: { title: "Deployment Status", subtitle: "v2.3.1" },
      sections: [{
        widgets: [
          { decoratedText: { topLabel: "Status", text: "Deployed", startIcon: { knownIcon: "STAR" } } },
          { buttonList: { buttons: [{
            text: "View Logs",
            onClick: { action: { actionMethodName: "view_logs", parameters: [{ key: "id", value: "dep-123" }] } },
          }] } },
        ],
      }],
    },
  }],
};

await chat.spaces.messages.create({ parent: spaceName, requestBody });
```

See: https://developers.google.com/workspace/chat/api/reference/rest/v1/cards

### Reactions and Typing Indicators

```typescript
// Add an emoji reaction to a message
await chat.spaces.messages.reactions.create({
  parent: event.message.name, // "spaces/AAAA/messages/BBBB"
  requestBody: {
    emoji: { unicode: "U+1F440" }, // eyes emoji
  },
});

// Note: Google Chat does not have a typing indicator API.
// The bot cannot show "typing..." status to users.
```

### Access Control

```typescript
// Space allowlist
const ALLOWED_SPACES = new Set(["spaces/AAAAxxxx", "spaces/BBBByyyy"]);

// User allowlist (Google Workspace email addresses)
const ALLOWED_USERS = new Set(["admin@company.com", "dev@company.com"]);

function isAllowed(user: any, spaceName: string): boolean {
  if (ALLOWED_SPACES.size > 0 && !ALLOWED_SPACES.has(spaceName)) {
    return false;
  }
  if (ALLOWED_USERS.size > 0 && !ALLOWED_USERS.has(user.email)) {
    return false;
  }
  return true;
}

// Apply in webhook handler
async function handleMessage(event: any): Promise<Response> {
  if (!isAllowed(event.user, event.space.name)) {
    return Response.json({ text: "Access denied." });
  }
  // ... dispatch
}
```

## Security Considerations

**CRITICAL: Read this section carefully before deploying any bot that processes sensitive information via Google Chat.**

### Encryption

Google Chat provides **TLS 1.2+ in transit** and **AES-256 at rest** using Google-managed encryption keys. There is **NO end-to-end encryption**. Google has full technical access to ALL message content — space messages, DMs, file uploads, message edits, deleted messages (retained per retention policies), and card interactions.

### Google's Data Access

Google Chat is a Google Workspace product. All messages are stored on Google's servers. Google retains the technical ability to access all content. Workspace admins have full access via Admin Console, Google Vault (eDiscovery — legal holds, search, export of all Chat data including DMs and deleted messages), and audit logs.

### Metadata Collection

Google stores comprehensive metadata: full message history with timestamps, edit/deletion history, space membership, reactions, file sharing records, read receipts, login times, IP addresses, device info, user agents, search queries, bot interaction logs, and usage patterns.

### AI Training and Data Processing

**CRITICAL WARNING**: Google has integrated **Gemini AI directly into Google Chat**. This is arguably the most aggressive AI integration of any major messaging platform.

- **Gemini in Chat**: Gemini can summarise conversations, answer questions about chat history, generate content, and suggest replies — all by processing message content on Google's servers. This is enabled by default in many Workspace configurations.
- **Gemini app in spaces**: Users can @mention Gemini directly in Chat spaces. Gemini reads and processes the conversation context to generate responses. Other users in the space may invoke Gemini on messages you sent.
- **Google's AI terms**: Google's Generative AI Additional Terms of Service and Privacy Notice govern how Chat data is processed by Gemini. Under default Workspace terms, Google states it does not use Workspace Core Services data to train its AI models — but this is a policy commitment, not a technical guarantee, and applies only to organisations with Workspace agreements.
- **Workspace admin control**: Admins can disable Gemini features in Chat via Admin Console (Apps > Google Workspace > Google Chat > Gemini settings). However, the **default configuration enables Gemini** in most Workspace editions.
- **Data processing agreements (DPAs)**: Enterprise customers can negotiate DPAs that restrict Google's data processing. But default Workspace terms are broad, and Google has been fined for GDPR violations. Without a specific DPA, assume Google processes Chat data for service improvement.
- **Smart features**: Beyond Gemini, Google Chat has "smart features" (Smart Reply, smart compose) that process message content to generate suggestions. These can be disabled at the organisation level.

**Practical impact**: Assume that any message sent in Google Chat is processed by Gemini and Google's AI systems unless the Workspace admin has explicitly disabled all AI features and smart features, AND has a specific DPA in place.

### Push Notifications

Push notifications are delivered via **Firebase Cloud Messaging (FCM)** for Android and **Apple Push Notification Service (APNs)** for iOS. FCM is Google's own service — Google sees all notification metadata and content. On Android, notification content is unencrypted in transit to the device via FCM. Admins cannot configure notification content redaction.

### Open Source and Auditability

Google Chat is entirely **closed source** — no independent audit of data handling, encryption, or access controls is possible. Google client libraries (`googleapis`, `google-auth-library`) are open source under Apache 2.0, so bot-side code is auditable, but Google's server-side processing is opaque. Clients (web, mobile) are closed source with no reproducible builds.

### Jurisdiction and Legal

**Entity**: Google LLC, Mountain View, California, USA. Subject to US federal law including the CLOUD Act, FISA Section 702, and National Security Letters. EU data residency is available on Enterprise plans but controls storage location only — Google US personnel may still access EU-resident data. Google publishes a Transparency Report for government requests.

### Bot-Specific Security

- **Service account auth**: Bot authenticates as a service account with access only to spaces where it has been added
- **Webhook verification**: Google includes a bearer token in the `Authorization` header. Verification is recommended but **not enforced** — bots can function without checking, creating a security risk if the webhook URL is discovered
- **Public URL exposure**: If the URL leaks and payload verification is not implemented, anyone can send fake events to the bot

### Comparison with Other Platforms

| Aspect | Google Chat | Slack | Matrix (self-hosted) | SimpleX |
|--------|-------------|-------|---------------------|---------|
| E2E encryption | No | No | Yes (Megolm) | Yes (Double ratchet) |
| Server access to content | Full (Google) | Full (Salesforce) | None (if E2E on) | None (stateless) |
| Admin message export | Yes (Vault) | Yes (all plans) | Server admin only | N/A |
| AI integration default | Gemini (most aggressive) | Opt-out required | No | No |
| Open source server | No | No | Yes (Synapse) | Yes (SMP) |
| User identifiers | Google Workspace email | Workspace email | `@user:server` | None |
| Metadata retention | Comprehensive | Comprehensive | Moderate | Minimal |
| Self-hostable | No | No | Yes | Yes |
| Jurisdiction | USA (Google) | USA (Salesforce) | Self-determined | Self-determined |

**Summary**: Google Chat is among the **least private** mainstream messaging platforms, comparable to Slack and Microsoft Teams. No E2E encryption, full admin and platform access to all content, and **Gemini AI integration that actively processes conversations by default**. Google's AI integration is arguably the most aggressive of the three major corporate platforms. **Treat all Google Chat messages as fully observable by the Workspace admin AND Google.** Use Google Chat for work communication where corporate oversight is expected and acceptable. Never use it for sensitive personal communication, confidential legal matters, or information that should not be accessible to the organisation owner or Google.

## aidevops Integration

### google-chat-dispatch-helper.sh

The helper script follows the same pattern as `slack-dispatch-helper.sh` and `matrix-dispatch-helper.sh`:

```bash
# Setup wizard — prompts for project ID, service account, webhook URL
google-chat-dispatch-helper.sh setup

# Map Google Chat spaces to runners
google-chat-dispatch-helper.sh map spaces/AAAAxxxx code-reviewer
google-chat-dispatch-helper.sh map spaces/BBBByyyy seo-analyst

# List mappings
google-chat-dispatch-helper.sh mappings

# Remove a mapping
google-chat-dispatch-helper.sh unmap spaces/AAAAxxxx

# Start/stop the webhook handler
google-chat-dispatch-helper.sh start --daemon
google-chat-dispatch-helper.sh stop
google-chat-dispatch-helper.sh status

# Test dispatch
google-chat-dispatch-helper.sh test code-reviewer "Review src/auth.ts"

# View logs
google-chat-dispatch-helper.sh logs
google-chat-dispatch-helper.sh logs --follow
```

### Public URL Setup

The webhook handler requires a public URL. Tailscale Funnel is the recommended approach:

```bash
# Start the webhook handler on a local port
google-chat-dispatch-helper.sh start --port 8443

# Expose via Tailscale Funnel
tailscale funnel 8443

# Configure the public URL in Google Cloud Console:
# https://your-machine.your-tailnet.ts.net:8443
```

### Runner Dispatch

The bot dispatches to runners via `runner-helper.sh`, which handles:

- Runner AGENTS.md (personality/instructions)
- Headless session management
- Memory namespace isolation
- Entity-aware context loading
- Run logging

### Entity Resolution

When a Google Chat user sends a message, the bot resolves their Google user identity to an entity:

- **Known user**: Match on `entity_channels` table (`channel=google-chat`, `channel_id=users/USER_ID`)
- **New user**: Creates entity via `entity-helper.sh create` with Google user ID linked
- **Cross-channel**: If the same person is linked on other channels (Slack, Matrix, email), their full profile is available
- **Profile enrichment**: Google Chat's user object provides display name and email (Workspace directory) — used to populate entity profile on first contact

### Configuration

`~/.config/aidevops/google-chat-bot.json` (600 permissions):

```json
{
  "projectId": "your-gcp-project-id",
  "serviceAccountKeyPath": "",
  "webhookPort": 8443,
  "allowedSpaces": ["spaces/AAAAxxxx", "spaces/BBBByyyy"],
  "allowedUsers": [],
  "defaultRunner": "",
  "spaceMappings": {
    "spaces/AAAAxxxx": "code-reviewer",
    "spaces/BBBByyyy": "seo-analyst"
  },
  "verifyWebhookToken": true,
  "maxPromptLength": 3000,
  "responseTimeout": 600,
  "sessionIdleTimeout": 300
}
```

**Notes**:

- `serviceAccountKeyPath` should point to the key file or be empty if using `gopass` for credential retrieval
- `verifyWebhookToken` should always be `true` in production — set to `false` only during local development
- Google Chat bots are invoked via @mention or DM — there is no text prefix or slash command equivalent

## Matterbridge Integration

Google Chat is **NOT natively supported** by [Matterbridge](https://github.com/42wim/matterbridge). There is no built-in gateway for Google Chat.

### Bridging Feasibility

Bridging would require a custom Go gateway using the Matterbridge plugin architecture + Google Chat API. Challenges: webhook-only model (no Socket Mode) complicates bidirectional bridging, service account auth adds complexity, and Workspace-only nature limits adoption. The Matterbridge project has not prioritised Google Chat support.

**Alternative**: Use Google Chat API directly in a custom bridge, or use a paid integration platform (Zapier, Make, Workato) as an intermediary.

**Privacy warning**: Bridging Google Chat to E2E-encrypted platforms (Matrix, SimpleX) means messages from encrypted platforms will be stored unencrypted on Google's servers. Users on the encrypted side should be informed. See `services/communications/matterbridge.md` for full bridging considerations.

## Limitations

### Google Workspace Required

Google Chat bots can only be created within Google Workspace organisations. Consumer Google accounts (`@gmail.com`) cannot create or configure Chat apps. This limits deployment to organisations with paid Workspace subscriptions.

### Public URL Required

Google Chat delivers webhook events via HTTP POST to a public URL. There is **no Socket Mode, WebSocket, or long-polling alternative**. You must expose a publicly accessible HTTPS endpoint. This is a fundamental architectural difference from Slack (which offers Socket Mode) and adds operational complexity for developers behind NAT or firewalls.

### No End-to-End Encryption

Google Chat does not support E2E encryption. All messages are readable by Google and Workspace administrators. This is a platform design choice — Google Vault eDiscovery and Gemini AI features depend on server-side access to message content.

### Gemini AI Processes Chat Data by Default

Gemini is integrated directly into Google Chat and processes conversation content by default in most Workspace editions. Users can @mention Gemini in spaces, and Gemini reads the full conversation context. Workspace admins can disable this, but it requires explicit action.

### Limited Bot Interactivity

Compared to Slack and Discord: no slash commands (bots respond to @mentions and DMs only), no modal dialogs (dialog cards are less flexible than Slack's `views.open`), no app home tab, no shortcut menus, and card messages are less flexible than Slack Block Kit.

### No Socket Mode Equivalent

Every Google Chat bot must expose a public HTTPS endpoint or use Pub/Sub. No outbound-only connections. Firewall/NAT traversal required, local development needs a tunnel (Tailscale Funnel, ngrok), and the public endpoint adds security surface.

### Rate Limits

| API | Rate Limit | Notes |
|-----|-----------|-------|
| Chat API (per project) | 60 requests per minute per space | Applies to messages.create, messages.update |
| Chat API (global) | 600 requests per minute per project | Aggregate across all spaces |
| Webhook responses | Synchronous (must reply within 30 seconds) | For async work, respond immediately and use REST API later |
| File attachments | Via Google Drive API | Separate Drive API quotas apply |

### Service Account Complexity

Setting up a Google Chat bot requires: Google Cloud project creation, Chat API enablement, service account creation and key management, Chat app configuration in Admin Console, OAuth consent screen configuration, and Workspace admin approval. This is significantly more complex than Slack or Discord (create app, paste token).

### No Consumer Support

Unlike Telegram, Discord, or Slack (free workspaces), Google Chat bots are exclusively for Google Workspace organisations. There is no way to create a public bot that any Google user can interact with.

## Related

- `services/communications/slack.md` — Slack bot integration (closest comparable — corporate, no E2E, but has Socket Mode)
- `services/communications/matrix-bot.md` — Matrix bot integration (E2E encrypted, self-hostable)
- `services/communications/simplex.md` — SimpleX Chat (no identifiers, maximum privacy)
- `services/communications/matterbridge.md` — Multi-platform chat bridging (no Google Chat support)
- `scripts/entity-helper.sh` — Entity memory system (identity resolution, Layer 0/1/2)
- `scripts/runner-helper.sh` — Runner management
- `tools/security/opsec.md` — Operational security guidance
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- Google Chat API: https://developers.google.com/workspace/chat
- Google Chat REST reference: https://developers.google.com/workspace/chat/api/reference/rest
- Google Cloud Console: https://console.cloud.google.com
- Google Workspace Admin: https://admin.google.com
- Google Vault: https://vault.google.com
- Google Transparency Report: https://transparencyreport.google.com
