---
description: Microsoft Teams Bot integration — Azure Bot Framework setup, Adaptive Cards, threading, RSC permissions, security considerations (no E2E, Copilot data processing), Matterbridge, and aidevops dispatch
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

# Microsoft Teams Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Microsoft 365 corporate messaging — no E2E encryption, tenant admin has full access
- **License**: Proprietary (Microsoft). Bot Framework SDK: `botbuilder` (MIT)
- **Bot tool**: Azure Bot Framework + Teams Bot SDK (TypeScript)
- **Protocol**: Bot Framework Protocol (HTTP webhook)
- **Encryption**: TLS in transit, Microsoft-managed at rest — NO end-to-end encryption
- **Script**: `msteams-dispatch-helper.sh [setup|start|stop|status|map|unmap|mappings|test|logs]`
- **Config**: `~/.config/aidevops/msteams-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/msteams-bot/`
- **Docs**: https://learn.microsoft.com/en-us/microsoftteams/platform/ | https://learn.microsoft.com/en-us/azure/bot-service/
- **App Management**: https://dev.teams.microsoft.com/apps | https://portal.azure.com

**Quick start**:

```bash
msteams-dispatch-helper.sh setup          # Interactive wizard
msteams-dispatch-helper.sh map <channel-id> general-assistant
msteams-dispatch-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────┐
│ Teams Client          │
│ (Desktop/Web/Mobile)  │
│                       │
│ User sends message    │
│ or @mentions bot      │
└──────────┬───────────┘
           │
           │  Bot Framework Protocol (HTTPS)
           │
┌──────────▼───────────┐
│ Azure Bot Service     │
│                       │
│ ├─ App ID             │  Azure AD app registration
│ ├─ Client Secret      │  Authentication
│ └─ Tenant ID          │  Scope restriction
└──────────┬───────────┘
           │
           │  HTTP POST (webhook)
           │
┌──────────▼───────────┐     ┌──────────────────────┐
│ Bot App (Bun/Node)    │     │ aidevops Dispatch     │
│                       │     │                       │
│ ├─ Activity handlers  │────▶│ runner-helper.sh      │
│ ├─ Adaptive Cards     │     │ → AI session          │
│ ├─ Access control     │◀────│ → response            │
│ ├─ Entity resolution  │     │                       │
│ └─ Thread management  │     │                       │
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

1. User sends message or @mentions bot in Teams (personal chat, channel, or group chat)
2. Teams delivers activity to Azure Bot Service
3. Azure Bot Service authenticates and forwards to bot's webhook endpoint
4. Bot app receives activity, checks access control (tenant/team/channel/user allowlists)
5. Bot looks up channel-to-runner mapping
6. Entity resolution: Azure AD object ID resolved to entity via `entity-helper.sh`
7. Layer 0 logging: user message logged as immutable interaction
8. Context loading: entity profile + conversation summary + recent interactions
9. Bot dispatches entity-aware prompt to runner via `runner-helper.sh`
10. Runner executes via headless dispatch
11. Bot posts response back as Adaptive Card or text in the conversation
12. Bot adds typing indicator while processing

## Installation

### Prerequisites

1. **Microsoft 365 tenant** with Teams enabled
2. **Azure subscription** for Bot registration (free tier available)
3. **Node.js >= 18** or **Bun** runtime
4. **Azure CLI** (`az`) installed for setup automation

### Step 1: Azure Bot Registration

1. Go to https://portal.azure.com
2. Create a new **Azure Bot** resource (Search: "Azure Bot")
3. Choose **Multi Tenant** or **Single Tenant** (single tenant for internal bots)
4. Note the generated **App ID** (also called Microsoft App ID)
5. Go to **Configuration** > **Manage Password** to create a **Client Secret**
6. Note your **Tenant ID** from Azure Active Directory > Overview

Alternatively, use Azure CLI:

```bash
# Login to Azure
az login

# Create app registration
az ad app create --display-name "aidevops-teams-bot" \
  --sign-in-audience AzureADMyOrg

# Note the appId from output, then create a secret
az ad app credential reset --id <app-id> --append

# Create the Bot resource
az bot create \
  --resource-group <rg-name> \
  --name "aidevops-teams-bot" \
  --app-type SingleTenant \
  --appid <app-id> \
  --tenant-id <tenant-id>
```

### Step 2: Teams App Manifest

Create a `manifest.json` for sideloading or Teams Admin Center deployment:

```json
{
  "$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.17/MicrosoftTeams.schema.json",
  "manifestVersion": "1.17",
  "version": "1.0.0",
  "id": "<app-id>",
  "developer": {
    "name": "aidevops",
    "websiteUrl": "https://aidevops.sh",
    "privacyUrl": "https://aidevops.sh/privacy",
    "termsOfUseUrl": "https://aidevops.sh/terms"
  },
  "name": {
    "short": "aidevops Bot",
    "full": "aidevops AI DevOps Assistant"
  },
  "description": {
    "short": "AI-powered DevOps assistant",
    "full": "AI-powered DevOps assistant for code review, task management, and automation."
  },
  "icons": {
    "outline": "outline.png",
    "color": "color.png"
  },
  "accentColor": "#1a1a2e",
  "bots": [
    {
      "botId": "<app-id>",
      "scopes": ["personal", "team", "groupChat"],
      "supportsFiles": true,
      "isNotificationOnly": false,
      "commandLists": [
        {
          "scopes": ["personal", "team", "groupChat"],
          "commands": [
            {
              "title": "help",
              "description": "Show available commands"
            },
            {
              "title": "status",
              "description": "Check bot and runner status"
            }
          ]
        }
      ]
    }
  ],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": [],
  "authorization": {
    "permissions": {
      "resourceSpecific": [
        {
          "name": "ChannelMessage.Read.Group",
          "type": "Application"
        },
        {
          "name": "ChatMessage.Read.Chat",
          "type": "Application"
        }
      ]
    }
  }
}
```

### Step 3: Deploy the App

**Option A: Sideloading (development)**

1. Package `manifest.json` + icons into a `.zip` file
2. In Teams > Apps > Manage your apps > Upload a custom app
3. Select the `.zip` file
4. The bot appears in the app catalogue for your tenant

**Option B: Teams Admin Center (production)**

1. Go to https://admin.teams.microsoft.com/policies/manage-apps
2. Upload the app package
3. Configure app setup policies to deploy to users/groups
4. Optionally pin the app in the Teams sidebar

### Step 4: Install Dependencies

```bash
# Using Bun (preferred)
bun add botbuilder botframework-connector

# Using npm
npm install botbuilder botframework-connector
```

### Step 5: Store Credentials

```bash
# Via gopass (preferred)
gopass insert aidevops/msteams/app-id          # Azure App ID
gopass insert aidevops/msteams/client-secret   # Azure Client Secret
gopass insert aidevops/msteams/tenant-id       # Azure AD Tenant ID

# Or via credentials.sh fallback
# Added to ~/.config/aidevops/credentials.sh (600 permissions)
```

## Bot API Integration

### Basic Teams Bot

```typescript
import {
  CloudAdapter,
  ConfigurationBotFrameworkAuthentication,
  TurnContext,
  ActivityTypes,
  CardFactory,
} from "botbuilder";
import { createServer } from "http";

const botAuth = new ConfigurationBotFrameworkAuthentication({
  MicrosoftAppId: process.env.MSTEAMS_APP_ID,
  MicrosoftAppPassword: process.env.MSTEAMS_CLIENT_SECRET,
  MicrosoftAppTenantId: process.env.MSTEAMS_TENANT_ID,
  MicrosoftAppType: "SingleTenant",
});

const adapter = new CloudAdapter(botAuth);

// Error handler
adapter.onTurnError = async (context: TurnContext, error: Error) => {
  console.error(`Bot error: ${error.message}`);
  await context.sendActivity("An error occurred. Please try again.");
};

// Message handler
async function onMessage(context: TurnContext): Promise<void> {
  if (context.activity.type !== ActivityTypes.Message) return;

  const text = context.activity.text?.replace(/<at>.*?<\/at>/g, "").trim();
  if (!text) return;

  const userId = context.activity.from.aadObjectId; // Azure AD object ID
  const channelId = context.activity.channelData?.channel?.id
    || context.activity.conversation.id;

  // Send typing indicator
  await context.sendActivity({ type: ActivityTypes.Typing });

  try {
    // Dispatch to runner (placeholder — integrate with runner-helper.sh)
    const response = await dispatchToRunner(text, userId, channelId);

    // Reply with Adaptive Card
    const card = CardFactory.adaptiveCard({
      type: "AdaptiveCard",
      version: "1.5",
      body: [
        {
          type: "TextBlock",
          text: response,
          wrap: true,
          fontType: "Default",
        },
      ],
    });

    await context.sendActivity({ attachments: [card] });
  } catch (error) {
    await context.sendActivity(`Error: ${error.message}`);
  }
}

// HTTP server for webhook
const server = createServer(async (req, res) => {
  if (req.url === "/api/messages" && req.method === "POST") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", async () => {
      try {
        await adapter.process(req, res, async (context) => {
          await onMessage(context);
        });
      } catch (err) {
        res.writeHead(500);
        res.end();
      }
    });
  } else {
    res.writeHead(200);
    res.end("OK");
  }
});

server.listen(3978, () => {
  console.log("Teams bot listening on port 3978");
});
```

### Adaptive Cards

Adaptive Cards are the primary rich content format for Teams bots. They support text, images, buttons, inputs, and complex layouts.

```typescript
// Rich response card with actions
const responseCard = CardFactory.adaptiveCard({
  type: "AdaptiveCard",
  version: "1.5",
  body: [
    {
      type: "TextBlock",
      text: "Analysis Complete",
      size: "Large",
      weight: "Bolder",
    },
    {
      type: "TextBlock",
      text: "Found 3 issues in the codebase.",
      wrap: true,
    },
    {
      type: "FactSet",
      facts: [
        { title: "Critical", value: "1" },
        { title: "Warning", value: "2" },
        { title: "Info", value: "0" },
      ],
    },
  ],
  actions: [
    {
      type: "Action.Submit",
      title: "Fix All",
      data: { action: "fix_all", scope: "codebase" },
    },
    {
      type: "Action.Submit",
      title: "Show Details",
      data: { action: "show_details" },
    },
    {
      type: "Action.OpenUrl",
      title: "View PR",
      url: "https://github.com/org/repo/pull/42",
    },
  ],
});

await context.sendActivity({ attachments: [responseCard] });

// Handle card action submissions
async function onMessage(context: TurnContext): Promise<void> {
  // Card action submissions come as messages with value property
  if (context.activity.value) {
    const action = context.activity.value.action;
    if (action === "fix_all") {
      await context.sendActivity({ type: ActivityTypes.Typing });
      const result = await dispatchToRunner("fix all issues", userId, channelId);
      await context.sendActivity(result);
      return;
    }
  }
  // ... normal message handling
}
```

### Threading Model

Teams has a distinct threading model that differs from Slack:

- **Channels**: Messages are either top-level "Posts" or replies within a thread
- **Personal/Group chats**: Flat conversation (no threading)
- **Thread context**: `context.activity.conversation.id` contains the thread ID for channel replies

```typescript
// Reply in a thread (channels only)
// The conversation ID includes the thread reference
const conversationId = context.activity.conversation.id;

// To start a new thread in a channel, use proactive messaging
import { MicrosoftAppCredentials, ConnectorClient } from "botframework-connector";

async function postToChannel(
  serviceUrl: string,
  channelId: string,
  message: string
): Promise<void> {
  const credentials = new MicrosoftAppCredentials(
    process.env.MSTEAMS_APP_ID!,
    process.env.MSTEAMS_CLIENT_SECRET!
  );
  const client = new ConnectorClient(credentials, { baseUri: serviceUrl });

  await client.conversations.createConversation({
    isGroup: true,
    channelData: { channel: { id: channelId } },
    activity: {
      type: ActivityTypes.Message,
      text: message,
    },
  });
}

// Reply to an existing thread
async function replyToThread(context: TurnContext, message: string): Promise<void> {
  await context.sendActivity(message);
  // Replies automatically go to the thread context of the incoming message
}
```

### File Handling

File handling differs between personal chats and channels:

```typescript
// DM (personal chat): files sent as attachments via Bot Framework
// Channels: files stored in SharePoint, referenced via Graph API

// Receive file attachments (personal chat)
if (context.activity.attachments?.length) {
  for (const attachment of context.activity.attachments) {
    if (attachment.contentUrl) {
      // Download file content
      const response = await fetch(attachment.contentUrl, {
        headers: {
          Authorization: `Bearer ${await getToken()}`,
        },
      });
      const content = await response.text();
      // Process file content
    }
  }
}

// Send file to personal chat
await context.sendActivity({
  attachments: [
    {
      contentType: "application/vnd.microsoft.teams.file.download.info",
      name: "report.md",
      content: {
        downloadUrl: "<pre-uploaded-url>",
        uniqueId: "<file-id>",
        fileType: "md",
      },
    },
  ],
});
```

For channel file operations, use the Microsoft Graph API:

```typescript
// Upload to SharePoint (channel files)
import { Client } from "@microsoft/microsoft-graph-client";

const graphClient = Client.init({
  authProvider: async (done) => {
    const token = await getGraphToken();
    done(null, token);
  },
});

// Upload file to team's SharePoint
await graphClient
  .api(`/teams/${teamId}/channels/${channelId}/filesFolder/content`)
  .put(fileBuffer);
```

### Access Control

```typescript
// Tenant allowlist (restrict to specific tenants)
const ALLOWED_TENANTS = new Set([process.env.MSTEAMS_TENANT_ID]);

// Team/channel allowlist
const ALLOWED_CHANNELS = new Set(["19:abc123@thread.tacv2"]);

// User allowlist (Azure AD object IDs)
const ALLOWED_USERS = new Set(["aad-object-id-1", "aad-object-id-2"]);

function isAllowed(context: TurnContext): boolean {
  const tenantId = context.activity.channelData?.tenant?.id;
  const userId = context.activity.from.aadObjectId;
  const channelId = context.activity.channelData?.channel?.id;

  // Tenant check (always enforce for multi-tenant bots)
  if (ALLOWED_TENANTS.size > 0 && !ALLOWED_TENANTS.has(tenantId)) {
    return false;
  }

  // Channel check (skip for personal chats)
  if (channelId && ALLOWED_CHANNELS.size > 0 && !ALLOWED_CHANNELS.has(channelId)) {
    return false;
  }

  // User check
  if (ALLOWED_USERS.size > 0 && !ALLOWED_USERS.has(userId)) {
    return false;
  }

  return true;
}

// Apply in message handler
async function onMessage(context: TurnContext): Promise<void> {
  if (!isAllowed(context)) {
    await context.sendActivity("Access denied.");
    return;
  }
  // ... dispatch
}
```

## Security Considerations

**CRITICAL: Read this section carefully before deploying any bot that processes sensitive information via Microsoft Teams.**

### Encryption

Microsoft Teams provides **TLS 1.2+ in transit** and **Microsoft-managed encryption at rest** (BitLocker for disk-level encryption + per-file encryption using unique keys). There is **NO end-to-end encryption**. Microsoft has full technical access to ALL message content, including:

- All channel messages (standard and private channels)
- All direct messages (1:1 and group chats)
- All file uploads and SharePoint content
- All message edits and their full history
- All deleted messages (retained per retention policies, recoverable by admins)
- Meeting recordings, transcripts, and chat

### Tenant Admin Access

Microsoft 365 tenant administrators have full access to ALL message data by design. This is a core feature of the platform, not a limitation:

| Tool | Capability |
|------|-----------|
| **Compliance Center** | Search and export all messages across all users, channels, and chats. Content search spans Teams, Exchange, SharePoint, and OneDrive simultaneously. |
| **eDiscovery** | Legal holds, case management, review sets. Preserves messages even if users delete them. Standard and Premium tiers. |
| **Content Search** | Keyword-based search across all Teams content. Results exportable as PST or individual messages. |
| **Audit Logs** | Every action logged — message sends, edits, deletes, file access, bot interactions, admin actions. Retained 90 days (standard) to 10 years (premium). |
| **Communication Compliance** | AI-powered policy matching that scans messages for policy violations (harassment, sensitive info, regulatory compliance). Processes message content in real-time. |
| **Data Loss Prevention (DLP)** | Scans messages and files for sensitive information (credit cards, SSNs, custom patterns). Can block or flag messages before delivery. |
| **Information Barriers** | Prevents communication between specific groups (e.g., investment banking and advisory). |

### Metadata Collection

Microsoft stores comprehensive metadata beyond message content:

- Full message history with timestamps and edit history
- Deletion logs (deleted messages recoverable via eDiscovery)
- File upload, download, and sharing records (SharePoint audit)
- Reactions and emoji usage
- Read receipts (when enabled)
- Presence status history (Available, Busy, Away, Do Not Disturb)
- Login times, IP addresses, device information, client versions
- Meeting attendance, duration, join/leave times
- Call logs (duration, participants, quality metrics)
- Search queries within Teams
- App and bot interaction logs
- Channel membership and join/leave history

### AI Training and Copilot Data Processing

**CRITICAL WARNING**: Microsoft has integrated Copilot directly into Teams as a core feature.

- **Copilot for Microsoft 365**: Copilot processes Teams messages to provide meeting summaries, chat summaries, action item extraction, and contextual answers. It accesses the full message history the user has access to. Copilot is licensed per-user and enabled by default for licensed users.
- **Copilot in meetings**: When enabled, Copilot processes meeting transcripts and chat in real-time to generate summaries, notes, and follow-up actions. Meeting participants may not always be aware of the scope of AI processing.
- **Data boundary**: Microsoft states that Copilot data is processed within the Microsoft 365 compliance boundary and that customer data is not used to train foundation models. However, the scope of AI processing within the compliance boundary is extensive — Copilot indexes and reasons over all accessible Teams content.
- **Tenant admin control**: Admins can disable Copilot per-user or tenant-wide via Microsoft 365 admin center. They can also configure which data sources Copilot can access. However, the default deployment enables broad access for all licensed users.
- **Semantic Index**: Microsoft 365 builds a semantic index across Teams, Exchange, SharePoint, and OneDrive to power Copilot. This index processes and organises all content for AI retrieval.
- **Third-party AI apps**: Apps from the Teams app store may access message content within their consented permissions. Each app's data handling is governed by the publisher's privacy policy, not Microsoft's.

**Practical impact**: Assume that any message sent in Teams is processed by Microsoft's AI systems (Copilot, communication compliance, DLP) unless the tenant admin has explicitly disabled all AI features. The default configuration enables extensive AI processing.

### Push Notifications

Push notifications are delivered via:

- **Windows**: Windows Notification Service (WNS)
- **Android**: Firebase Cloud Messaging (FCM) — Google infrastructure
- **iOS**: Apple Push Notification Service (APNs)

Notification content includes message previews by default, making content visible to the respective platform provider during transit. Admins can configure notification content policies but cannot fully eliminate platform exposure.

### Open Source and Auditability

- **Teams platform**: Entirely CLOSED source. No independent audit of Teams' data handling, encryption implementation, Copilot processing, or compliance tooling is possible.
- **Bot Framework SDK**: Open source under MIT license (`botbuilder`, `botframework-connector`, etc.). Bot code is auditable; Microsoft's server-side processing is not.
- **Teams clients**: Desktop client is Electron-based but closed source. Mobile clients are closed source. Web client is obfuscated JavaScript. No reproducible builds.
- **Azure Bot Service**: Closed source relay. Messages transit through Microsoft's infrastructure before reaching the bot endpoint.

### Jurisdiction and Legal

- **Entity**: Microsoft Corporation — headquartered in Redmond, Washington, USA
- **Jurisdiction**: Subject to US federal law, including the CLOUD Act (compels disclosure of data stored abroad), FISA Section 702, and National Security Letters
- **EU Data Boundary**: Available for Enterprise customers. Microsoft has committed to processing and storing EU customer data within the EU, but implementation is phased and some metadata may still transit US infrastructure. Microsoft US personnel may access EU-resident data under specific circumstances for support and security.
- **Government requests**: Microsoft publishes a transparency report. Law enforcement requests are processed per Microsoft's Law Enforcement Requests Report. Microsoft has challenged government requests in court (notably the Ireland email case, superseded by CLOUD Act).

### Bot-Specific Security

- Azure Bot registration requires an Azure subscription (free tier available for development)
- Bot Framework uses a webhook model — the bot must be publicly accessible via HTTPS, or use Azure Bot Service as a proxy (ngrok for development, Azure App Service or similar for production)
- App ID and Client Secret authenticate the bot with Azure Bot Service — treat the client secret as a critical credential
- RSC (Resource-Specific Consent) permissions scope bot access per team or chat, reducing over-privileged access
- **Token validation**: Always validate incoming activities using the Bot Framework authentication library. Unvalidated webhooks are vulnerable to spoofing.
- **Single-tenant vs multi-tenant**: Single-tenant bots are restricted to one Azure AD tenant (recommended for internal bots). Multi-tenant bots can be installed in any tenant (requires more careful access control).

### Comparison with Other Platforms

| Aspect | Teams | Slack | Matrix (self-hosted) | Signal |
|--------|-------|-------|---------------------|--------|
| E2E encryption | No | No | Yes (Megolm) | Yes (Signal Protocol) |
| Server access to content | Full | Full | None (if E2E on) | None (sealed sender) |
| Admin message export | Yes (all plans) | Yes (Business+ for DMs) | Server admin only | No |
| AI processing default | Copilot enabled | Opt-out required | No | No |
| Compliance features | Most mature | Moderate | Basic | None |
| Open source server | No | No | Yes (Synapse) | Partial |
| User identifiers | Azure AD / email | Workspace email | `@user:server` | Phone number |
| Metadata retention | Comprehensive | Comprehensive | Moderate | Minimal |
| Self-hostable | No | No | Yes | No |
| Jurisdiction | USA (Microsoft) | USA (Salesforce) | Self-determined | USA (Signal Foundation) |

**Summary**: Microsoft Teams is a **corporate compliance platform** with messaging capabilities, not a privacy-focused messenger. No E2E encryption, full admin export and eDiscovery, aggressive AI integration (Copilot processes messages by default), comprehensive metadata retention, and closed-source infrastructure. The compliance features (eDiscovery, DLP, information barriers, communication compliance) are the most mature of any enterprise messaging platform. **Treat all Teams messages as fully observable by the tenant admin, Microsoft, and — if Copilot is enabled — processed by AI systems.** Teams is designed for enterprise communication where corporate oversight and regulatory compliance are expected. Never use it for sensitive personal communication or information that should not be accessible to the employer or Microsoft.

## aidevops Integration

### msteams-dispatch-helper.sh

The helper script follows the same pattern as `slack-dispatch-helper.sh`:

```bash
# Setup wizard — prompts for App ID, client secret, tenant ID, channel mappings
msteams-dispatch-helper.sh setup

# Map Teams channels to runners
msteams-dispatch-helper.sh map "19:abc123@thread.tacv2" code-reviewer
msteams-dispatch-helper.sh map "19:def456@thread.tacv2" seo-analyst

# List mappings
msteams-dispatch-helper.sh mappings

# Remove a mapping
msteams-dispatch-helper.sh unmap "19:abc123@thread.tacv2"

# Start/stop the bot
msteams-dispatch-helper.sh start --daemon
msteams-dispatch-helper.sh stop
msteams-dispatch-helper.sh status

# Test dispatch
msteams-dispatch-helper.sh test code-reviewer "Review src/auth.ts"

# View logs
msteams-dispatch-helper.sh logs
msteams-dispatch-helper.sh logs --follow
```

### Azure Bot Service Configuration

The bot requires a publicly accessible HTTPS endpoint for Azure Bot Service to deliver activities. Options:

| Method | Use Case | Setup Complexity |
|--------|----------|-----------------|
| **ngrok / cloudflared** | Development / testing | Low |
| **Azure App Service** | Production (Microsoft-hosted) | Medium |
| **Self-hosted + reverse proxy** | Production (self-managed) | Medium |
| **Azure Bot Service (direct line)** | Alternative protocol | Medium |

Configure the messaging endpoint in Azure Portal > Bot resource > Configuration:

```text
Messaging endpoint: https://your-domain.com/api/messages
```

### Runner Dispatch

The bot dispatches to runners via `runner-helper.sh`, which handles:

- Runner AGENTS.md (personality/instructions)
- Headless session management
- Memory namespace isolation
- Entity-aware context loading
- Run logging

### Entity Resolution

When a Teams user sends a message, the bot resolves their Azure AD object ID to an entity:

- **Known user**: Match on `entity_channels` table (`channel=msteams`, `channel_id=aad-object-id`)
- **New user**: Creates entity via `entity-helper.sh create` with Azure AD object ID linked
- **Cross-channel**: If the same person is linked on other channels (Slack, Matrix, email), their full profile is available
- **Profile enrichment**: Azure AD provides display name, email, job title, department — used to populate entity profile on first contact via Graph API `users/{id}` endpoint

### Configuration

`~/.config/aidevops/msteams-bot.json` (600 permissions):

```json
{
  "appId": "<azure-app-id>",
  "clientSecret": "<azure-client-secret>",
  "tenantId": "<azure-tenant-id>",
  "appType": "SingleTenant",
  "webhookPort": 3978,
  "webhookPath": "/api/messages",
  "allowedTenants": ["<tenant-id>"],
  "allowedChannels": [],
  "allowedUsers": [],
  "defaultRunner": "",
  "channelMappings": {
    "19:abc123@thread.tacv2": "code-reviewer",
    "19:def456@thread.tacv2": "seo-analyst"
  },
  "useAdaptiveCards": true,
  "maxPromptLength": 3000,
  "responseTimeout": 600,
  "sessionIdleTimeout": 300
}
```

## Matterbridge Integration

Microsoft Teams is supported by [Matterbridge](https://github.com/42wim/matterbridge), but with important limitations.

```text
Teams Workspace
    │
    │  Teams Bot API or Incoming Webhook
    │
Matterbridge (Go binary)
    │
    ├── Slack channels
    ├── Matrix rooms
    ├── Discord channels
    ├── Telegram groups
    ├── IRC channels
    └── 40+ other platforms
```

### Matterbridge Configuration

Add to `matterbridge.toml`:

```toml
[msteams.myorg]
## Option 1: Incoming Webhook (send-only — cannot receive messages FROM Teams)
WebhookURL = "https://outlook.office.com/webhook/..."

## Option 2: Bot Framework (bidirectional — requires Azure Bot registration)
## TenantID = "<tenant-id>"
## ClientID = "<app-id>"
## ClientSecret = "<client-secret>"
## TeamID = "<team-id>"
```

Gateway configuration:

```toml
[[gateway]]
name = "dev-bridge"
enable = true

[[gateway.inout]]
account = "msteams.myorg"
channel = "General"

[[gateway.inout]]
account = "slack.myworkspace"
channel = "dev-general"

[[gateway.inout]]
account = "matrix.myserver"
channel = "#dev:matrix.example.com"
```

**Matterbridge limitations with Teams**:

- **Webhook mode is send-only**: Incoming Webhooks can post TO Teams but cannot receive messages FROM Teams. Use Bot Framework mode for bidirectional bridging.
- **Bot Framework mode requires Azure setup**: Same Azure Bot registration and permissions as direct integration.
- **Rich content**: Adaptive Cards are not bridged — only plain text crosses the bridge. Messages from other platforms arrive as plain text in Teams.

**Privacy warning**: Bridging Teams to other platforms means messages from E2E-encrypted platforms (Matrix, SimpleX) will be stored unencrypted on Microsoft's servers. Users on the encrypted side should be informed. See `services/communications/matterbridge.md` for full bridging considerations.

## Limitations

### No End-to-End Encryption

Teams does not support E2E encryption for messages. Microsoft-managed encryption at rest (BitLocker + per-file keys) protects against physical disk theft but not against Microsoft or tenant admin access. This is a fundamental platform design choice — compliance, eDiscovery, and Copilot features depend on server-side access to plaintext content.

### Azure Subscription Required

Bot registration requires an Azure subscription. The free tier supports development and low-volume production, but production bots with high message volume may incur costs. Azure Bot Service pricing applies for premium channels and higher throughput.

### Copilot Processes Chat Data by Default

For tenants with Copilot for Microsoft 365 licenses, Copilot processes Teams messages by default. Admins must explicitly disable Copilot access to Teams data if this is not desired. Users may not be aware that AI systems are processing their conversations.

### Complex Setup

Teams bot deployment involves multiple systems:

1. Azure Portal (Bot registration, App ID, client secret)
2. Azure AD (app registration, API permissions)
3. Teams Admin Center (app policies, deployment)
4. App manifest (JSON, icons, RSC permissions)
5. Webhook endpoint (public HTTPS required)

This is significantly more complex than Slack (1 portal, OAuth) or Telegram (BotFather, single token).

### File Handling Asymmetry

- **Personal/group chats**: Files sent as Bot Framework attachments (direct upload/download)
- **Channels**: Files stored in SharePoint via Graph API (different authentication, different API surface)

This split requires the bot to detect conversation type and use different file handling paths.

### Rate Limits

| Operation | Rate Limit | Notes |
|-----------|-----------|-------|
| Bot messages (per conversation) | ~1 message per second | Varies by conversation type |
| Bot messages (per tenant) | Varies | Microsoft doesn't publish exact limits |
| Graph API | 10,000 requests per 10 minutes per app | Per tenant |
| Adaptive Card actions | No specific limit | Subject to message rate limits |
| Proactive messages | Throttled | Must have prior conversation context |

Rate limits are enforced by Azure Bot Service and are less transparent than Slack's documented limits.

### No Self-Hosting

Teams is a SaaS-only platform within Microsoft 365. There is no self-hosted option. All data is stored on Microsoft's infrastructure (Azure datacenters). Organizations requiring full data sovereignty must use alternatives (Mattermost, Matrix, Rocket.Chat).

### App Approval Process

Deploying a bot org-wide requires:

- **Sideloading**: Must be enabled by admin (disabled by default in many tenants)
- **Admin approval**: Teams Admin Center approval required for org-wide deployment
- **Microsoft Store**: Publishing to the public Teams app store requires Microsoft review and validation
- **RSC consent**: Resource-Specific Consent must be granted per team/chat where the bot operates

## Related

- `services/communications/slack.md` — Slack bot integration (closest comparison — corporate, no E2E)
- `services/communications/matrix-bot.md` — Matrix bot integration (E2E encrypted, self-hostable)
- `services/communications/simplex.md` — SimpleX Chat (no identifiers, maximum privacy)
- `services/communications/matterbridge.md` — Multi-platform chat bridging
- `scripts/entity-helper.sh` — Entity memory system (identity resolution, Layer 0/1/2)
- `scripts/runner-helper.sh` — Runner management
- `tools/security/opsec.md` — Operational security guidance
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- Azure Bot Framework: https://learn.microsoft.com/en-us/azure/bot-service/
- Teams Platform: https://learn.microsoft.com/en-us/microsoftteams/platform/
- Adaptive Cards: https://adaptivecards.io/
- Microsoft Graph API: https://learn.microsoft.com/en-us/graph/
- Microsoft Privacy: https://privacy.microsoft.com/
