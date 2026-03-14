---
description: Microsoft Teams bot integration — Azure Bot Framework, Teams app manifest, DM/channel/group messaging, Adaptive Cards, threading, file handling, Graph API, access control, runner dispatch, Matterbridge native support, privacy/security assessment
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

- **Type**: Enterprise messaging platform — Azure Bot Framework webhook-based bot
- **License**: Proprietary (Microsoft 365)
- **Bot Framework**: Azure Bot Service + Bot Framework SDK (Node.js / C# / Python / Java)
- **Auth**: Azure App ID + Client Secret + Tenant ID (Azure AD / Entra ID)
- **Config**: `~/.config/aidevops/msteams-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/msteams-bot/`
- **SDK**: `botbuilder` + `botbuilder-teams` (npm) or `botframework-connector` (REST)
- **Requires**: Node.js >= 18, Azure subscription, Teams admin consent
- **Matterbridge**: Native support via Graph API (see `matterbridge.md`)
- **Docs**: [Bot Framework docs](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/what-are-bots) | [Graph API](https://learn.microsoft.com/en-us/graph/api/overview)

**Key characteristics**: Teams bots are webhook-based — Microsoft pushes activities to your HTTPS endpoint. No persistent WebSocket connection. The bot must be publicly reachable (or use ngrok/dev tunnels for development). All messages pass through Microsoft's servers in plaintext — no E2E encryption.

**When to use Teams vs other platforms**:

| Criterion | Teams | Matrix | SimpleX | Slack |
|-----------|-------|--------|---------|-------|
| Identity model | Azure AD (Entra ID) | `@user:server` | None | Workspace email |
| Encryption | TLS in transit only | Megolm (optional E2E) | Double ratchet (E2E) | TLS in transit only |
| Data residency | Microsoft 365 tenant | Self-hosted | Local device | Salesforce cloud |
| Bot SDK | Bot Framework (mature) | `matrix-bot-sdk` | WebSocket JSON API | Bolt SDK |
| Admin control | Full (compliance, eDiscovery, DLP) | Server admin | None (decentralized) | Workspace admin |
| Best for | Enterprise orgs on M365 | Self-hosted teams | Maximum privacy | Startup/dev teams |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ Teams Client      │     │ Microsoft Bot    │     │ Your Bot Server  │
│ (Desktop, Web,   │     │ Framework Service│     │ (Node.js/Express)│
│  Mobile)          │     │ (Azure)          │     │                  │
│                   │     │                  │     │                  │
│ User sends msg   │────▶│ 1. Auth + route  │────▶│ 1. Verify JWT    │
│ in channel/DM    │     │ 2. Wrap as       │     │ 2. Parse activity│
│                  │◀────│    Activity JSON  │◀────│ 3. Dispatch to   │
│ Bot response     │     │ 3. Deliver resp  │     │    runner         │
│ (Adaptive Card)  │     │                  │     │ 4. Send response │
└──────────────────┘     └──────────────────┘     └──────────────────┘
                                │
                                ▼
                    ┌──────────────────────┐
                    │ Microsoft Graph API  │
                    │ ├── Channel messages │
                    │ ├── File uploads     │
                    │ ├── User profiles    │
                    │ ├── Team membership  │
                    │ └── Chat history     │
                    └──────────────────────┘
```

**Message flow**:

1. User sends message in Teams (DM, channel, or group chat)
2. Teams client sends to Microsoft Bot Framework Service
3. Bot Framework authenticates and wraps message as an Activity JSON object
4. Activity POSTed to your bot's HTTPS messaging endpoint
5. Bot verifies JWT token (issued by `login.botframework.com`)
6. Bot processes message, optionally dispatches to aidevops runner
7. Bot sends response back via Bot Framework Connector REST API
8. Bot Framework delivers response to Teams client

**Key difference from Matrix/SimpleX**: The bot never connects outbound — Microsoft pushes to your endpoint. Your server must be HTTPS-reachable from the internet (or use Azure Bot Service's built-in hosting).

## Prerequisites

### Azure Resources

1. **Azure subscription** — free tier sufficient for development
2. **Azure Bot resource** — created in Azure Portal or via `az` CLI
3. **Azure AD (Entra ID) app registration** — provides App ID and client secret
4. **Teams admin consent** — tenant admin must approve the bot for the organization

### Credentials

| Credential | Source | Storage |
|------------|--------|---------|
| App ID (Client ID) | Azure AD app registration | `msteams-bot.json` |
| Client Secret | Azure AD app registration > Certificates & secrets | `gopass` or `msteams-bot.json` |
| Tenant ID | Azure AD > Overview | `msteams-bot.json` |
| Bot Framework endpoint | Your server's public HTTPS URL | Azure Bot resource config |

```bash
# Store credentials securely
aidevops secret set MSTEAMS_APP_ID
aidevops secret set MSTEAMS_CLIENT_SECRET
aidevops secret set MSTEAMS_TENANT_ID
```

## Setup

### 1. Azure AD App Registration

```bash
# Via Azure CLI
az ad app create --display-name "aidevops-teams-bot" \
  --sign-in-audience "AzureADMyOrg"

# Note the appId from output
# Create client secret (valid 2 years)
az ad app credential reset --id <appId> --years 2

# Note the password (client secret) — shown only once
```

Or via Azure Portal:

1. Azure Portal > Azure Active Directory > App registrations > New registration
2. Name: `aidevops-teams-bot`
3. Supported account types: "Accounts in this organizational directory only" (single tenant)
4. Register, note the Application (client) ID
5. Certificates & secrets > New client secret > note the value

### 2. Azure Bot Resource

```bash
# Create bot resource linked to the app registration
az bot create --resource-group mygroup \
  --name aidevops-teams-bot \
  --app-type SingleTenant \
  --appid <appId> \
  --tenant-id <tenantId>

# Configure messaging endpoint
az bot update --resource-group mygroup \
  --name aidevops-teams-bot \
  --endpoint "https://your-server.example.com/api/messages"

# Enable Teams channel
az bot msteams create --resource-group mygroup \
  --name aidevops-teams-bot
```

### 3. Teams App Manifest

Create a Teams app package (`manifest.json` + icons) for sideloading or publishing:

```json
{
  "$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.17/MicrosoftTeams.schema.json",
  "manifestVersion": "1.17",
  "version": "1.0.0",
  "id": "<appId>",
  "developer": {
    "name": "Your Org",
    "websiteUrl": "https://example.com",
    "privacyUrl": "https://example.com/privacy",
    "termsOfUseUrl": "https://example.com/terms"
  },
  "name": {
    "short": "AI DevOps Bot",
    "full": "AI DevOps Runner Dispatch Bot"
  },
  "description": {
    "short": "Dispatch AI tasks from Teams",
    "full": "Dispatch tasks to aidevops runners from Microsoft Teams channels and DMs."
  },
  "icons": {
    "outline": "outline-32x32.png",
    "color": "color-192x192.png"
  },
  "accentColor": "#4F6BED",
  "bots": [
    {
      "botId": "<appId>",
      "scopes": ["personal", "team", "groupChat"],
      "supportsFiles": true,
      "isNotificationOnly": false,
      "commandLists": [
        {
          "scopes": ["personal", "team", "groupChat"],
          "commands": [
            { "title": "help", "description": "Show available commands" },
            { "title": "status", "description": "Check runner status" },
            { "title": "ask", "description": "Ask the AI a question" },
            { "title": "review", "description": "Request code review" }
          ]
        }
      ]
    }
  ],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": ["your-server.example.com"],
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
        },
        {
          "name": "TeamSettings.Read.Group",
          "type": "Application"
        },
        {
          "name": "ChannelMessage.Send.Group",
          "type": "Application"
        }
      ]
    }
  }
}
```

**RSC (Resource-Specific Consent) permissions** allow the bot to access team/chat data without tenant-wide admin consent. Users grant permissions when installing the app in their team or chat.

Package the manifest:

```bash
# Create app package (ZIP with manifest.json + icons)
zip -j aidevops-teams-bot.zip manifest.json outline-32x32.png color-192x192.png

# Sideload via Teams Admin Center or Teams client
# Teams > Apps > Manage your apps > Upload a custom app
```

### 4. Bot Server (Node.js)

```bash
mkdir msteams-bot && cd msteams-bot
npm init -y
npm install botbuilder express
```

Minimal bot server:

```javascript
const { BotFrameworkAdapter, TeamsActivityHandler, CardFactory } = require("botbuilder");
const express = require("express");

const appId = process.env.MSTEAMS_APP_ID;
const appPassword = process.env.MSTEAMS_CLIENT_SECRET;
if (!appId || !appPassword) {
  throw new Error("MSTEAMS_APP_ID and MSTEAMS_CLIENT_SECRET must be set");
}

const adapter = new BotFrameworkAdapter({ appId, appPassword });

// Error handler
adapter.onTurnError = async (context, error) => {
  console.error(`Bot error: ${error.message}`);
  await context.sendActivity("An error occurred processing your request.");
};

class AIDevOpsBot extends TeamsActivityHandler {
  async onMessage(context) {
    const text = context.activity.text?.replace(/<at>.*<\/at>/g, "").trim();
    if (!text) return;

    // Access control: check AAD object ID
    const userId = context.activity.from.aadObjectId;
    if (!isAllowedUser(userId)) {
      await context.sendActivity("You are not authorized to use this bot.");
      return;
    }

    // Dispatch to runner (placeholder — integrate with runner-helper.sh)
    await context.sendActivity({ type: "typing" });
    const result = await dispatchToRunner(text, context);
    await context.sendActivity(result);
  }

  // Handle bot installed in team
  async onTeamsMembersAdded(membersAdded, teamInfo, context) {
    for (const member of membersAdded) {
      if (member.id === context.activity.recipient.id) {
        await context.sendActivity(
          "AI DevOps Bot installed. Mention me with a task to get started."
        );
      }
    }
  }
}

const bot = new AIDevOpsBot();
const app = express();
app.use(express.json());

app.post("/api/messages", async (req, res) => {
  await adapter.process(req, res, (context) => bot.run(context));
});

app.listen(3978, () => console.log("Bot listening on port 3978"));
```

### 5. Development Tunneling

For local development, expose your bot endpoint:

```bash
# Using Azure Dev Tunnels (recommended)
devtunnel create --allow-anonymous
devtunnel port create -p 3978
devtunnel host

# Or ngrok
ngrok http 3978

# Update the Azure Bot messaging endpoint to the tunnel URL
az bot update --resource-group mygroup \
  --name aidevops-teams-bot \
  --endpoint "https://<tunnel-id>.devtunnels.ms/api/messages"
```

## Messaging

### Conversation Types

| Type | Scope | Bot Mention Required | Threading |
|------|-------|---------------------|-----------|
| Personal (DM) | 1:1 with bot | No | Flat (no threads) |
| Channel | Team channel | Yes (`@BotName`) | Posts with reply threads |
| Group chat | Multi-user chat | Yes (`@BotName`) | Flat (no threads) |

### Sending Messages

```javascript
// Reply to current conversation
await context.sendActivity("Hello from the bot!");

// Send Adaptive Card
const card = CardFactory.adaptiveCard({
  type: "AdaptiveCard",
  $schema: "http://adaptivecards.io/schemas/adaptive-card.json",
  version: "1.5",
  body: [
    { type: "TextBlock", text: "Task Result", weight: "Bolder", size: "Large" },
    { type: "TextBlock", text: "Code review completed.", wrap: true },
    {
      type: "FactSet",
      facts: [
        { title: "Status", value: "Passed" },
        { title: "Issues", value: "0 critical, 2 warnings" },
        { title: "Duration", value: "45s" },
      ],
    },
  ],
  actions: [
    { type: "Action.OpenUrl", title: "View PR", url: "https://github.com/..." },
  ],
});
await context.sendActivity({ attachments: [card] });

// Proactive message (outside of a conversation turn)
const { MicrosoftAppCredentials, ConnectorClient } = require("botframework-connector");
const credentials = new MicrosoftAppCredentials(appId, appPassword);
const client = new ConnectorClient(credentials, {
  baseUri: context.activity.serviceUrl,
});
await client.conversations.sendToConversation(conversationId, {
  type: "message",
  text: "Proactive notification: deployment complete.",
});
```

### Threading (Posts vs Replies)

Teams channels use a Posts + Replies model:

```javascript
// Reply to a specific thread (channel)
const replyActivity = {
  type: "message",
  text: "Thread reply",
  conversation: {
    id: `${channelId};messageid=${parentMessageId}`,
  },
};
await context.sendActivity(replyActivity);

// Create a new top-level post in a channel
// Requires Graph API — Bot Framework sends replies by default
// (assumes graphClient is initialized as shown in "Graph API Integration" section)
await graphClient
  .api(`/teams/${teamId}/channels/${channelId}/messages`)
  .post({ body: { content: "New top-level post" } });
```

### Adaptive Cards

Adaptive Cards are the primary rich content format in Teams. They support:

- Text, images, media
- Input forms (text, date, choice sets, toggles)
- Action buttons (submit, open URL, show card)
- Data binding and templating
- Version 1.5 supported in Teams

```javascript
// Card with user input
const inputCard = CardFactory.adaptiveCard({
  type: "AdaptiveCard",
  version: "1.5",
  body: [
    { type: "TextBlock", text: "Dispatch Task", weight: "Bolder" },
    {
      type: "Input.Text",
      id: "taskPrompt",
      placeholder: "Describe the task...",
      isMultiline: true,
    },
    {
      type: "Input.ChoiceSet",
      id: "runner",
      label: "Runner",
      choices: [
        { title: "Code Reviewer", value: "code-reviewer" },
        { title: "SEO Analyst", value: "seo-analyst" },
      ],
    },
  ],
  actions: [
    {
      type: "Action.Submit",
      title: "Dispatch",
      data: { action: "dispatch" },
    },
  ],
});

// Handle card submit
async onAdaptiveCardInvoke(context) {
  const data = context.activity.value.action.data;
  if (data.action === "dispatch") {
    const result = await dispatchToRunner(data.taskPrompt, data.runner);
    return { statusCode: 200, type: "application/vnd.microsoft.activity.message", value: result };
  }
}
```

**Adaptive Card reference**: [adaptivecards.io](https://adaptivecards.io/) | [Designer](https://adaptivecards.io/designer/)

## File Handling

File handling differs between DMs and channels:

| Context | Upload mechanism | Storage |
|---------|-----------------|---------|
| Personal (DM) | Inline attachment (base64 or URL) | Bot Framework blob storage |
| Channel | SharePoint via Graph API | Team's SharePoint document library |
| Group chat | OneDrive via Graph API | Sender's OneDrive |

### Receiving Files

```javascript
async onMessage(context) {
  const attachments = context.activity.attachments || [];

  for (const attachment of attachments) {
    if (attachment.contentType === "application/vnd.microsoft.teams.file.download.info") {
      // Channel/group file — download from SharePoint/OneDrive
      const downloadUrl = attachment.content.downloadUrl;
      const response = await fetch(downloadUrl, {
        headers: { Authorization: `Bearer ${graphToken}` },
      });
      const buffer = await response.arrayBuffer();
      // Process file...
    } else if (attachment.contentUrl) {
      // DM file — direct download
      const response = await fetch(attachment.contentUrl, {
        headers: { Authorization: `Bearer ${botToken}` },
      });
      const buffer = await response.arrayBuffer();
      // Process file...
    }
  }
}
```

### Sending Files

```javascript
// DM: send as inline attachment
const fileBuffer = fs.readFileSync("report.pdf");
const base64 = fileBuffer.toString("base64");
await context.sendActivity({
  attachments: [
    {
      contentType: "application/pdf",
      contentUrl: `data:application/pdf;base64,${base64}`,
      name: "report.pdf",
    },
  ],
});

// Channel: upload to SharePoint via Graph API, then share link
const uploadSession = await graphClient
  .api(
    `/teams/${teamId}/channels/${channelId}/filesFolder/root:/${fileName}:/createUploadSession`
  )
  .post({});
// Upload file chunks to uploadSession.uploadUrl
// Then send message with file card
```

## Graph API Integration

The Microsoft Graph API provides access to Teams data beyond what the Bot Framework offers:

```javascript
const { Client } = require("@microsoft/microsoft-graph-client");
const {
  ClientSecretCredential,
} = require("@azure/identity");
const {
  TokenCredentialAuthenticationProvider,
} = require("@microsoft/microsoft-graph-client/authProviders/azureTokenCredentials");

const credential = new ClientSecretCredential(tenantId, appId, clientSecret);
const authProvider = new TokenCredentialAuthenticationProvider(credential, {
  scopes: ["https://graph.microsoft.com/.default"],
});
const graphClient = Client.initWithMiddleware({ authProvider });

// List teams the bot is installed in
const teams = await graphClient.api("/me/joinedTeams").get();

// Get channel messages (requires ChannelMessage.Read.All)
const messages = await graphClient
  .api(`/teams/${teamId}/channels/${channelId}/messages`)
  .top(50)
  .get();

// Get user profile
const user = await graphClient.api(`/users/${aadObjectId}`).get();

// Send channel notification
await graphClient
  .api(`/teams/${teamId}/channels/${channelId}/messages`)
  .post({
    body: { contentType: "html", content: "<b>Deployment complete</b>" },
  });
```

**Graph API permissions** (configured in Azure AD app registration):

| Permission | Type | Use |
|------------|------|-----|
| `ChannelMessage.Read.All` | Application | Read channel messages |
| `ChannelMessage.Send` | Application | Send channel messages |
| `Chat.Read` | Delegated | Read DM/group chat messages |
| `Files.ReadWrite.All` | Application | Upload/download files |
| `User.Read.All` | Application | Look up user profiles |
| `Team.ReadBasic.All` | Application | List teams |
| `TeamsActivity.Send` | Application | Send activity feed notifications |

## Access Control

### AAD Object ID Allowlists

The primary access control mechanism is Azure AD (Entra ID) object ID allowlists. Every Teams user has a unique, immutable `aadObjectId` in the activity payload.

```json
{
  "allowedUsers": [
    "00000000-0000-0000-0000-000000000001",
    "00000000-0000-0000-0000-000000000002"
  ],
  "allowedTeams": [
    "team-id-1"
  ],
  "allowedChannels": [
    "19:channel-id@thread.tacv2"
  ],
  "adminUsers": [
    "00000000-0000-0000-0000-000000000001"
  ]
}
```

```javascript
function isAllowedUser(aadObjectId) {
  const config = loadConfig();

  // Admin users always allowed
  if (config.adminUsers?.includes(aadObjectId)) return true;

  // If allowlist is empty, all users in the tenant are allowed
  if (!config.allowedUsers?.length) return true;

  return config.allowedUsers.includes(aadObjectId);
}

function isAllowedConversation(context) {
  const config = loadConfig();
  const conversationType = context.activity.conversation.conversationType;

  if (conversationType === "personal") {
    return isAllowedUser(context.activity.from.aadObjectId);
  }

  if (conversationType === "channel") {
    const channelId = context.activity.channelData?.channel?.id;
    const teamId = context.activity.channelData?.team?.id;

    if (config.allowedChannels?.length && !config.allowedChannels.includes(channelId)) {
      return false;
    }
    if (config.allowedTeams?.length && !config.allowedTeams.includes(teamId)) {
      return false;
    }
    return isAllowedUser(context.activity.from.aadObjectId);
  }

  // Group chat
  return isAllowedUser(context.activity.from.aadObjectId);
}
```

### Tenant Isolation

Single-tenant bots (recommended) only accept requests from one Azure AD tenant. Multi-tenant bots accept from any tenant — use only if you need cross-org access.

The `appType` in the Azure Bot resource controls this:

| Type | Accepts from | Use case |
|------|-------------|----------|
| `SingleTenant` | One tenant only | Internal org bot |
| `MultiTenant` | Any Azure AD tenant | Published app / ISV |
| `UserAssignedMSI` | Managed identity | Azure-hosted bots |

## Configuration

### Config File

`~/.config/aidevops/msteams-bot.json` (600 permissions):

> **Security**: Store `appId` and `clientSecret` in gopass (`aidevops secret set msteams-app-id`, `aidevops secret set msteams-client-secret`), not in this JSON file. Reference them via environment variables or `credentials.sh`. The values below are placeholders only.

```json
{
  "appId": "stored-in-gopass",
  "tenantId": "00000000-0000-0000-0000-000000000000",
  "botEndpoint": "https://your-server.example.com/api/messages",
  "allowedUsers": [],
  "allowedTeams": [],
  "allowedChannels": [],
  "adminUsers": [],
  "defaultRunner": "",
  "channelMappings": {
    "19:channel-id@thread.tacv2": "code-reviewer",
    "19:another-channel@thread.tacv2": "seo-analyst"
  },
  "botPrefix": "",
  "maxPromptLength": 3000,
  "responseTimeout": 600
}
```

**Note**: `botPrefix` is empty by default because Teams bots are triggered by @mention, not a text prefix. In DMs, all messages are delivered to the bot without mention.

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `appId` | (required) | Azure AD application (client) ID |
| `tenantId` | (required) | Azure AD tenant ID |
| `botEndpoint` | (required) | Public HTTPS URL for bot messaging endpoint |
| `allowedUsers` | `[]` (all tenant users) | AAD object IDs of allowed users |
| `allowedTeams` | `[]` (all) | Team IDs where bot responds |
| `allowedChannels` | `[]` (all) | Channel IDs where bot responds |
| `adminUsers` | `[]` | AAD object IDs with admin privileges |
| `defaultRunner` | `""` | Runner for unmapped channels (empty = ignore) |
| `channelMappings` | `{}` | Channel ID to runner name mapping |
| `botPrefix` | `""` | Optional text prefix (in addition to @mention) |
| `maxPromptLength` | `3000` | Max prompt length before truncation |
| `responseTimeout` | `600` | Max seconds to wait for runner response |

## Runner Dispatch Integration

The bot dispatches to aidevops runners following the same pattern as the Matrix bot:

```javascript
const { execFile } = require("child_process");
const { promisify } = require("util");

const execFileAsync = promisify(execFile);

async function dispatchToRunner(prompt, context) {
  const channelId = context.activity.channelData?.channel?.id;
  const config = loadConfig();

  // Resolve runner from channel mapping or default
  const runner = config.channelMappings[channelId] || config.defaultRunner;
  if (!runner) {
    return "No runner configured for this channel.";
  }

  try {
    // Use execFile with array args to prevent command injection
    // (never use execSync with string interpolation)
    const { stdout } = await execFileAsync(
      "runner-helper.sh",
      ["dispatch", runner, prompt],
      { timeout: config.responseTimeout * 1000, encoding: "utf-8" }
    );
    return stdout.trim();
  } catch (error) {
    console.error("Runner dispatch failed", { error });
    return "Runner dispatch failed. Please try again later or contact an administrator.";
  }
}
```

### Channel-to-Runner Mapping

Same pattern as Matrix room mappings:

| Channel | Runner | Purpose |
|---------|--------|---------|
| `#dev` | `code-reviewer` | Code review, security analysis |
| `#seo` | `seo-analyst` | SEO audits, keyword research |
| `#ops` | `ops-monitor` | Server health, deployment status |
| `#general` | (default runner) | General AI assistance |

## Matterbridge Native Support

Matterbridge has native Microsoft Teams support via the Graph API. This is the simplest way to bridge Teams to other platforms without building a custom bot.

> **Security**: Store `ClientSecret` in gopass (`aidevops secret set MSTEAMS_CLIENT_SECRET`) and inject it via environment variable substitution or a templating step. Never commit the actual secret value to `matterbridge.toml`. The value below is a placeholder only.

```toml
# matterbridge.toml — Teams bridge configuration
[msteams]
  [msteams.work]
  TenantID = "your-tenant-id"
  ClientID = "your-app-id"
  ClientSecret = "your-client-secret"
  TeamID = "your-team-id"

[[gateway]]
name = "teams-matrix-bridge"
enable = true

  [[gateway.inout]]
  account = "msteams.work"
  channel = "General"

  [[gateway.inout]]
  account = "matrix.home"
  channel = "#general:example.com"
```

**Matterbridge Teams notes**:

- Uses Graph API (not Bot Framework) — simpler setup, no webhook endpoint needed
- Requires `ChannelMessage.Read.All` and `ChannelMessage.Send` Graph API permissions
- Bridges channel messages only (not DMs or group chats)
- Build note: Teams support adds ~2.5GB to Matterbridge compile memory; use `-tags nomsteams` to exclude if not needed
- See `matterbridge.md` for full configuration reference

## Deployment

### Azure App Service (Recommended)

```bash
# Create App Service
az webapp create --resource-group mygroup \
  --plan myplan --name aidevops-teams-bot \
  --runtime "NODE:18-lts"

# Configure environment
az webapp config appsettings set --resource-group mygroup \
  --name aidevops-teams-bot --settings \
  MSTEAMS_APP_ID="<appId>" \
  MSTEAMS_CLIENT_SECRET="<secret>" \
  MSTEAMS_TENANT_ID="<tenantId>"

# Deploy
az webapp deployment source config-zip --resource-group mygroup \
  --name aidevops-teams-bot --src bot.zip
```

### Docker (Self-Hosted)

```dockerfile
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --production
COPY . .
EXPOSE 3978
CMD ["node", "index.js"]
```

```bash
docker run -d \
  --name msteams-bot \
  --restart unless-stopped \
  -p 3978:3978 \
  -e MSTEAMS_APP_ID="<appId>" \
  -e MSTEAMS_CLIENT_SECRET="<secret>" \
  -e MSTEAMS_TENANT_ID="<tenantId>" \
  aidevops-teams-bot:latest
```

**Note**: The bot must be reachable via HTTPS from the internet. Use a reverse proxy (Caddy, Nginx) with TLS termination in front of the Docker container.

### Systemd

```ini
# /etc/systemd/system/msteams-bot.service
[Unit]
Description=AI DevOps Teams Bot
After=network.target

[Service]
Type=simple
User=msteams-bot
WorkingDirectory=/opt/msteams-bot
ExecStart=/usr/bin/node index.js
Restart=on-failure
RestartSec=5
EnvironmentFile=/etc/msteams-bot/env

[Install]
WantedBy=multi-user.target
```

## Privacy and Security Assessment

### No E2E Encryption

**Teams does not support end-to-end encryption for messages.** All messages are:

- Encrypted in transit (TLS 1.2+)
- Encrypted at rest in Microsoft 365 storage
- **Accessible in plaintext to Microsoft and tenant administrators**

This means:

- Microsoft can read all message content (subject to their privacy policy)
- Tenant admins can access all messages via compliance tools
- eDiscovery searches can surface any Teams message
- Data Loss Prevention (DLP) policies scan message content server-side
- Legal holds preserve messages even if users delete them

**Comparison**: Matrix (with E2E enabled) and SimpleX encrypt messages so that only participants can read them. Teams is architecturally equivalent to email — the server operator has full access.

### Microsoft 365 Data Processing

All Teams data is stored and processed within the Microsoft 365 ecosystem:

| Data type | Storage | Retention | Admin access |
|-----------|---------|-----------|--------------|
| Chat messages | Exchange Online | Configurable (default: indefinite) | eDiscovery, Content Search |
| Channel messages | SharePoint/Exchange | Configurable | eDiscovery, Content Search |
| Files (channels) | SharePoint Online | SharePoint retention policies | SharePoint admin |
| Files (DMs) | OneDrive for Business | OneDrive retention policies | OneDrive admin |
| Call recordings | OneDrive/SharePoint | Configurable | Admin center |
| Meeting transcripts | Exchange Online | Configurable | eDiscovery |

### Copilot AI Training Warning

**Microsoft Copilot for Microsoft 365 processes Teams messages.** Key implications:

- **Copilot in Teams** is integrated directly into the Teams chat interface
- Copilot can summarize conversations, generate meeting notes, and answer questions about chat history
- Microsoft's privacy policy permits using customer data to improve AI models (with opt-out options for enterprise customers)
- Enterprise customers with Microsoft 365 E3/E5 can configure data processing agreements
- **Default behavior**: Copilot features have access to Teams chat data within the tenant

**Mitigations for enterprise customers**:

- Configure Microsoft Purview sensitivity labels to restrict Copilot access to specific channels
- Use Information Barriers to prevent Copilot from cross-referencing sensitive conversations
- Review and configure the Microsoft 365 Copilot data residency and processing settings
- Disable Copilot for specific users or groups via admin policies
- Monitor Copilot usage via Microsoft 365 audit logs

**For sensitive communications**: Do not use Teams. Use SimpleX (zero-knowledge, E2E encrypted) or Matrix with E2E encryption enabled. Teams is appropriate for enterprise collaboration where compliance and admin oversight are features, not bugs.

### Compliance and eDiscovery

Teams messages are subject to Microsoft 365 compliance features:

| Feature | Impact |
|---------|--------|
| **eDiscovery** | All messages searchable by compliance officers |
| **Legal Hold** | Messages preserved even if deleted by users |
| **Retention Policies** | Automatic deletion or preservation per policy |
| **DLP** | Content scanned for sensitive data patterns |
| **Communication Compliance** | Messages monitored for policy violations |
| **Audit Logs** | All bot interactions logged in Microsoft 365 audit |
| **Information Barriers** | Restrict communication between groups |

**Bot-specific implications**:

- All messages sent to/from the bot are subject to the same compliance policies as user messages
- Bot responses containing sensitive data (code, credentials, internal URLs) will be captured by eDiscovery
- Ensure bot responses do not include secrets, API keys, or credentials — they will be stored in Microsoft 365 and accessible to compliance tools
- Consider using Adaptive Cards with ephemeral content for sensitive responses (though even these may be logged)

### Push Notifications

Teams push notifications are delivered via:

- **Windows**: Windows Notification Service (WNS)
- **iOS**: Apple Push Notification Service (APNs)
- **Android**: Firebase Cloud Messaging (FCM)

Each notification service receives metadata about the notification (that a message was received) but not the message content. However, notification previews may include message text depending on user settings.

### Network Requirements

The bot server must allow outbound connections to:

| Endpoint | Purpose |
|----------|---------|
| `login.botframework.com` | JWT token validation |
| `login.microsoftonline.com` | Azure AD authentication |
| `graph.microsoft.com` | Graph API calls |
| `smba.trafficmanager.net` | Bot Framework connector |
| `*.botframework.com` | Bot Framework services |

Inbound: HTTPS (443) from Microsoft Bot Framework to your messaging endpoint.

### Security Recommendations

1. **Single-tenant only** — restrict bot to your Azure AD tenant
2. **AAD object ID allowlists** — restrict which users can interact with the bot
3. **Channel allowlists** — restrict which channels the bot responds in
4. **No secrets in responses** — bot responses are stored in Microsoft 365 compliance systems
5. **Credential storage** — use gopass or Azure Key Vault, never store in code or config
6. **HTTPS only** — bot endpoint must use TLS 1.2+
7. **JWT validation** — always verify the Bot Framework JWT token on incoming requests
8. **Rate limiting** — implement per-user rate limits to prevent abuse
9. **Audit logging** — log all bot interactions locally (in addition to Microsoft 365 audit)
10. **Sensitivity labels** — apply Microsoft Purview labels to restrict Copilot/eDiscovery access where needed

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bot not receiving messages | Verify messaging endpoint URL in Azure Bot resource; check HTTPS certificate |
| 401 Unauthorized | Verify App ID and Client Secret; check token validation logic |
| Bot not appearing in Teams | Sideload the app manifest ZIP; check Teams admin policies |
| Messages not delivered to channel | Ensure bot is @mentioned; check RSC permissions |
| File upload fails | Verify Graph API permissions (`Files.ReadWrite.All`); check SharePoint access |
| Adaptive Card not rendering | Validate card JSON at adaptivecards.io/designer; check version compatibility |
| Proactive messages fail | Store and reuse `serviceUrl` and `conversationId` from previous activities |
| Rate limited by Bot Framework | Implement exponential backoff; reduce message frequency |
| Graph API 403 | Check application permissions in Azure AD; ensure admin consent granted |

## Limitations

### Platform Lock-In

Teams bots are tightly coupled to the Microsoft ecosystem:

- Azure AD required for authentication
- Bot Framework required for message routing
- Graph API required for advanced features
- No self-hosted alternative — Microsoft controls the infrastructure

### Message Format Constraints

- Adaptive Cards are Teams-specific — they do not render on other platforms
- HTML support is limited to a subset of tags
- Markdown support differs from standard CommonMark
- Message size limit: 28 KB for text, 40 KB for Adaptive Cards

### Threading Model

- DMs and group chats are flat (no threading)
- Channel posts support reply threads, but the API for creating top-level posts requires Graph API (not Bot Framework)
- Thread context is lost when bridging to platforms with different threading models

### Closed Source

Teams client and server are proprietary. There is no way to:

- Audit the server-side code
- Verify encryption claims independently
- Self-host the Teams infrastructure
- Modify the client behavior

## Related

- `services/communications/matterbridge.md` — Multi-platform bridge (native Teams support)
- `services/communications/matrix-bot.md` — Matrix bot integration (self-hosted, E2E optional)
- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, E2E encrypted)
- `tools/security/opsec.md` — Operational security guidance
- `tools/ai-assistants/headless-dispatch.md` — Headless dispatch patterns
- `scripts/runner-helper.sh` — Runner management
- Bot Framework Docs: https://learn.microsoft.com/en-us/microsoftteams/platform/bots/what-are-bots
- Adaptive Cards: https://adaptivecards.io/
- Graph API: https://learn.microsoft.com/en-us/graph/api/overview
- Teams App Manifest: https://learn.microsoft.com/en-us/microsoftteams/platform/resources/schema/manifest-schema
