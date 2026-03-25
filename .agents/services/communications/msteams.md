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

- **Type**: Enterprise messaging — Azure Bot Framework webhook-based bot
- **License**: Proprietary (Microsoft 365)
- **Auth**: Azure App ID + Client Secret + Tenant ID (Azure AD / Entra ID)
- **Config**: `~/.config/aidevops/msteams-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/msteams-bot/`
- **SDK**: `botbuilder` + `botbuilder-teams` (npm) or `botframework-connector` (REST)
- **Requires**: Node.js >= 18, Azure subscription, Teams admin consent
- **Matterbridge**: Native support via Graph API (see `matterbridge.md`)
- **Docs**: [Bot Framework](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/what-are-bots) | [Graph API](https://learn.microsoft.com/en-us/graph/api/overview)

**Key characteristics**: Teams bots are webhook-based — Microsoft pushes activities to your HTTPS endpoint. No persistent WebSocket connection. The bot must be publicly reachable (or use ngrok/dev tunnels for development). All messages pass through Microsoft's servers in plaintext — no E2E encryption.

**When to use Teams vs other platforms**:

| Criterion | Teams | Matrix | SimpleX | Slack |
|-----------|-------|--------|---------|-------|
| Identity model | Azure AD (Entra ID) | `@user:server` | None | Workspace email |
| Encryption | TLS in transit only | Megolm (optional E2E) | Double ratchet (E2E) | TLS in transit only |
| Data residency | Microsoft 365 tenant | Self-hosted | Local device | Salesforce cloud |
| Bot SDK | Bot Framework (mature) | `matrix-bot-sdk` | WebSocket JSON API | Bolt SDK |
| Best for | Enterprise orgs on M365 | Self-hosted teams | Maximum privacy | Startup/dev teams |

<!-- AI-CONTEXT-END -->

## Architecture

```text
Teams Client → Bot Framework Service (Azure) → Your Bot Server (Node.js/Express)
                        │
                        ▼
              Microsoft Graph API
              (channel messages, files, user profiles, team membership)
```

**Message flow**: User sends message → Teams client → Bot Framework authenticates + wraps as Activity JSON → POSTed to your HTTPS endpoint → Bot verifies JWT → dispatches to aidevops runner → sends response via Bot Framework Connector REST API.

**Key difference from Matrix/SimpleX**: The bot never connects outbound — Microsoft pushes to your endpoint. Your server must be HTTPS-reachable from the internet.

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
| Client Secret | Azure AD > Certificates & secrets | `gopass` or `msteams-bot.json` |
| Tenant ID | Azure AD > Overview | `msteams-bot.json` |

```bash
aidevops secret set MSTEAMS_APP_ID
aidevops secret set MSTEAMS_CLIENT_SECRET
aidevops secret set MSTEAMS_TENANT_ID
```

## Setup

### 1. Azure AD App Registration

```bash
az ad app create --display-name "aidevops-teams-bot" --sign-in-audience "AzureADMyOrg"
# Note the appId, then create client secret (valid 2 years):
az ad app credential reset --id <appId> --years 2
```

Or via Azure Portal: Azure Active Directory > App registrations > New registration > note Application (client) ID > Certificates & secrets > New client secret.

### 2. Azure Bot Resource

```bash
az bot create --resource-group mygroup --name aidevops-teams-bot \
  --app-type SingleTenant --appid <appId> --tenant-id <tenantId>
az bot update --resource-group mygroup --name aidevops-teams-bot \
  --endpoint "https://your-server.example.com/api/messages"
az bot msteams create --resource-group mygroup --name aidevops-teams-bot
```

### 3. Teams App Manifest

```json
{
  "$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.17/MicrosoftTeams.schema.json",
  "manifestVersion": "1.17",
  "version": "1.0.0",
  "id": "<appId>",
  "developer": { "name": "Your Org", "websiteUrl": "https://example.com",
    "privacyUrl": "https://example.com/privacy", "termsOfUseUrl": "https://example.com/terms" },
  "name": { "short": "AI DevOps Bot", "full": "AI DevOps Runner Dispatch Bot" },
  "description": { "short": "Dispatch AI tasks from Teams",
    "full": "Dispatch tasks to aidevops runners from Microsoft Teams channels and DMs." },
  "icons": { "outline": "outline-32x32.png", "color": "color-192x192.png" },
  "accentColor": "#4F6BED",
  "bots": [{
    "botId": "<appId>",
    "scopes": ["personal", "team", "groupChat"],
    "supportsFiles": true,
    "isNotificationOnly": false,
    "commandLists": [{ "scopes": ["personal", "team", "groupChat"], "commands": [
      { "title": "help", "description": "Show available commands" },
      { "title": "status", "description": "Check runner status" },
      { "title": "ask", "description": "Ask the AI a question" },
      { "title": "review", "description": "Request code review" }
    ]}]
  }],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": ["your-server.example.com"],
  "authorization": { "permissions": { "resourceSpecific": [
    { "name": "ChannelMessage.Read.Group", "type": "Application" },
    { "name": "ChatMessage.Read.Chat", "type": "Application" },
    { "name": "TeamSettings.Read.Group", "type": "Application" },
    { "name": "ChannelMessage.Send.Group", "type": "Application" }
  ]}}
}
```

**RSC permissions** allow the bot to access team/chat data without tenant-wide admin consent.

```bash
zip -j aidevops-teams-bot.zip manifest.json outline-32x32.png color-192x192.png
# Sideload: Teams > Apps > Manage your apps > Upload a custom app
```

### 4. Bot Server (Node.js)

```bash
mkdir msteams-bot && cd msteams-bot && npm init -y && npm install botbuilder express
```

```javascript
const { BotFrameworkAdapter, TeamsActivityHandler, CardFactory } = require("botbuilder");
const express = require("express");

const adapter = new BotFrameworkAdapter({
  appId: process.env.MSTEAMS_APP_ID,
  appPassword: process.env.MSTEAMS_CLIENT_SECRET,
});

adapter.onTurnError = async (context, error) => {
  console.error(`Bot error: ${error.message}`);
  await context.sendActivity("An error occurred processing your request.");
};

class AIDevOpsBot extends TeamsActivityHandler {
  async onMessage(context) {
    const text = context.activity.text?.replace(/<at>.*<\/at>/g, "").trim();
    if (!text) return;
    const userId = context.activity.from.aadObjectId;
    if (!isAllowedUser(userId)) {
      await context.sendActivity("You are not authorized to use this bot.");
      return;
    }
    await context.sendActivity({ type: "typing" });
    const result = await dispatchToRunner(text, context);
    await context.sendActivity(result);
  }
  async onTeamsMembersAdded(membersAdded, teamInfo, context) {
    for (const member of membersAdded) {
      if (member.id === context.activity.recipient.id) {
        await context.sendActivity("AI DevOps Bot installed. Mention me with a task to get started.");
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

```bash
# Azure Dev Tunnels (recommended)
devtunnel create --allow-anonymous && devtunnel port create -p 3978 && devtunnel host
# Or ngrok: ngrok http 3978
# Update Azure Bot endpoint to the tunnel URL
```

## Messaging

### Conversation Types

| Type | Scope | Bot Mention Required | Threading |
|------|-------|---------------------|-----------|
| Personal (DM) | 1:1 with bot | No | Flat |
| Channel | Team channel | Yes (`@BotName`) | Posts with reply threads |
| Group chat | Multi-user chat | Yes (`@BotName`) | Flat |

### Sending Messages

```javascript
// Reply to current conversation
await context.sendActivity("Hello from the bot!");

// Send Adaptive Card
const card = CardFactory.adaptiveCard({
  type: "AdaptiveCard", $schema: "http://adaptivecards.io/schemas/adaptive-card.json",
  version: "1.5",
  body: [
    { type: "TextBlock", text: "Task Result", weight: "Bolder", size: "Large" },
    { type: "TextBlock", text: "Code review completed.", wrap: true },
    { type: "FactSet", facts: [
      { title: "Status", value: "Passed" },
      { title: "Issues", value: "0 critical, 2 warnings" },
    ]},
  ],
  actions: [{ type: "Action.OpenUrl", title: "View PR", url: "https://github.com/..." }],
});
await context.sendActivity({ attachments: [card] });

// Proactive message (outside a conversation turn)
const { MicrosoftAppCredentials, ConnectorClient } = require("botframework-connector");
const client = new ConnectorClient(new MicrosoftAppCredentials(appId, appPassword),
  { baseUri: context.activity.serviceUrl });
await client.conversations.sendToConversation(conversationId,
  { type: "message", text: "Proactive notification: deployment complete." });
```

### Threading (Channel Posts vs Replies)

```javascript
// Reply to a specific thread
await context.sendActivity({ type: "message", text: "Thread reply",
  conversation: { id: `${channelId};messageid=${parentMessageId}` } });

// New top-level post requires Graph API
await graphClient.api(`/teams/${teamId}/channels/${channelId}/messages`)
  .post({ body: { content: "New top-level post" } });
```

### Adaptive Cards with Input

```javascript
const inputCard = CardFactory.adaptiveCard({
  type: "AdaptiveCard", version: "1.5",
  body: [
    { type: "TextBlock", text: "Dispatch Task", weight: "Bolder" },
    { type: "Input.Text", id: "taskPrompt", placeholder: "Describe the task...", isMultiline: true },
    { type: "Input.ChoiceSet", id: "runner", label: "Runner", choices: [
      { title: "Code Reviewer", value: "code-reviewer" },
      { title: "SEO Analyst", value: "seo-analyst" },
    ]},
  ],
  actions: [{ type: "Action.Submit", title: "Dispatch", data: { action: "dispatch" } }],
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

| Context | Upload mechanism | Storage |
|---------|-----------------|---------|
| Personal (DM) | Inline attachment | Bot Framework blob storage |
| Channel | SharePoint via Graph API | Team's SharePoint document library |
| Group chat | OneDrive via Graph API | Sender's OneDrive |

```javascript
// Receiving files
for (const attachment of context.activity.attachments || []) {
  if (attachment.contentType === "application/vnd.microsoft.teams.file.download.info") {
    // Channel/group: download from SharePoint/OneDrive
    const response = await fetch(attachment.content.downloadUrl,
      { headers: { Authorization: `Bearer ${graphToken}` } });
  } else if (attachment.contentUrl) {
    // DM: direct download
    const response = await fetch(attachment.contentUrl,
      { headers: { Authorization: `Bearer ${botToken}` } });
  }
}
```

## Graph API Integration

```javascript
const { Client } = require("@microsoft/microsoft-graph-client");
const { ClientSecretCredential } = require("@azure/identity");
const { TokenCredentialAuthenticationProvider } =
  require("@microsoft/microsoft-graph-client/authProviders/azureTokenCredentials");

const graphClient = Client.initWithMiddleware({
  authProvider: new TokenCredentialAuthenticationProvider(
    new ClientSecretCredential(tenantId, appId, clientSecret),
    { scopes: ["https://graph.microsoft.com/.default"] }
  )
});

// List teams, get channel messages, send notifications
const teams = await graphClient.api("/me/joinedTeams").get();
const messages = await graphClient.api(`/teams/${teamId}/channels/${channelId}/messages`).top(50).get();
await graphClient.api(`/teams/${teamId}/channels/${channelId}/messages`)
  .post({ body: { contentType: "html", content: "<b>Deployment complete</b>" } });
```

**Graph API permissions** (Azure AD app registration):

| Permission | Type | Use |
|------------|------|-----|
| `ChannelMessage.Read.All` | Application | Read channel messages |
| `ChannelMessage.Send` | Application | Send channel messages |
| `Chat.Read` | Delegated | Read DM/group chat messages |
| `Files.ReadWrite.All` | Application | Upload/download files |
| `User.Read.All` | Application | Look up user profiles |
| `TeamsActivity.Send` | Application | Send activity feed notifications |

## Access Control

### AAD Object ID Allowlists

Every Teams user has a unique, immutable `aadObjectId` in the activity payload. Use this as the primary access control mechanism.

```javascript
function isAllowedUser(aadObjectId) {
  const config = loadConfig();
  if (config.adminUsers?.includes(aadObjectId)) return true;
  if (!config.allowedUsers?.length) return true; // empty = all tenant users allowed
  return config.allowedUsers.includes(aadObjectId);
}

function isAllowedConversation(context) {
  const config = loadConfig();
  const type = context.activity.conversation.conversationType;
  if (type === "channel") {
    const channelId = context.activity.channelData?.channel?.id;
    const teamId = context.activity.channelData?.team?.id;
    if (config.allowedChannels?.length && !config.allowedChannels.includes(channelId)) return false;
    if (config.allowedTeams?.length && !config.allowedTeams.includes(teamId)) return false;
  }
  return isAllowedUser(context.activity.from.aadObjectId);
}
```

### Tenant Isolation

Single-tenant bots (recommended) only accept requests from one Azure AD tenant.

| Type | Accepts from | Use case |
|------|-------------|----------|
| `SingleTenant` | One tenant only | Internal org bot |
| `MultiTenant` | Any Azure AD tenant | Published app / ISV |

## Configuration

`~/.config/aidevops/msteams-bot.json` (600 permissions):

> **Security**: Store `appId` and `clientSecret` in gopass (`aidevops secret set msteams-app-id`), not in this JSON file.

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
    "19:channel-id@thread.tacv2": "code-reviewer"
  },
  "botPrefix": "",
  "maxPromptLength": 3000,
  "responseTimeout": 600
}
```

| Option | Default | Description |
|--------|---------|-------------|
| `allowedUsers` | `[]` (all tenant users) | AAD object IDs of allowed users |
| `channelMappings` | `{}` | Channel ID → runner name |
| `maxPromptLength` | `3000` | Max prompt length before truncation |
| `responseTimeout` | `600` | Max seconds to wait for runner response |

## Runner Dispatch Integration

```javascript
const { execFile } = require("child_process");
const { promisify } = require("util");
const execFileAsync = promisify(execFile);

async function dispatchToRunner(prompt, context) {
  const channelId = context.activity.channelData?.channel?.id;
  const config = loadConfig();
  const runner = config.channelMappings[channelId] || config.defaultRunner;
  if (!runner) return "No runner configured for this channel.";
  try {
    // Use execFile with array args to prevent command injection
    const { stdout } = await execFileAsync(
      "runner-helper.sh", ["dispatch", runner, prompt],
      { timeout: config.responseTimeout * 1000, encoding: "utf-8" }
    );
    return stdout.trim();
  } catch (error) {
    console.error("Runner dispatch failed", { error });
    return "Runner dispatch failed. Please try again later or contact an administrator.";
  }
}
```

**Channel-to-runner mapping**: `#dev` → `code-reviewer`, `#seo` → `seo-analyst`, `#ops` → `ops-monitor`.

## Matterbridge Native Support

Matterbridge has native Microsoft Teams support via the Graph API — the simplest way to bridge Teams to other platforms without building a custom bot.

> **Security**: Store `ClientSecret` in gopass and inject via environment variable. Never commit the actual secret value.

```toml
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

**Notes**: Uses Graph API (not Bot Framework) — no webhook endpoint needed. Bridges channel messages only (not DMs). Build note: Teams support adds ~2.5GB to compile memory; use `-tags nomsteams` to exclude if not needed.

## Deployment

### Azure App Service

```bash
az webapp create --resource-group mygroup --plan myplan --name aidevops-teams-bot --runtime "NODE:18-lts"
az webapp config appsettings set --resource-group mygroup --name aidevops-teams-bot --settings \
  MSTEAMS_APP_ID="<appId>" MSTEAMS_CLIENT_SECRET="<secret>" MSTEAMS_TENANT_ID="<tenantId>"
az webapp deployment source config-zip --resource-group mygroup --name aidevops-teams-bot --src bot.zip
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
docker run -d --name msteams-bot --restart unless-stopped -p 3978:3978 \
  -e MSTEAMS_APP_ID="<appId>" -e MSTEAMS_CLIENT_SECRET="<secret>" \
  -e MSTEAMS_TENANT_ID="<tenantId>" aidevops-teams-bot:latest
```

**Note**: Use a reverse proxy (Caddy, Nginx) with TLS termination in front of the container.

### Systemd

```ini
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

## Privacy and Security

### No E2E Encryption

**Teams does not support end-to-end encryption.** All messages are encrypted in transit (TLS 1.2+) and at rest, but **accessible in plaintext to Microsoft and tenant administrators** via eDiscovery, compliance tools, and DLP policies. Legal holds preserve messages even if users delete them.

**For sensitive communications**: Use SimpleX (zero-knowledge, E2E encrypted) or Matrix with E2E enabled.

### Microsoft 365 Data Processing

| Data type | Storage | Admin access |
|-----------|---------|--------------|
| Chat messages | Exchange Online | eDiscovery, Content Search |
| Channel messages | SharePoint/Exchange | eDiscovery, Content Search |
| Files (channels) | SharePoint Online | SharePoint admin |
| Files (DMs) | OneDrive for Business | OneDrive admin |

**Copilot AI Training Warning**: Microsoft Copilot for Microsoft 365 processes Teams messages by default. Enterprise customers (E3/E5) can configure data processing agreements and use Microsoft Purview sensitivity labels to restrict Copilot access.

### Compliance Features

| Feature | Impact |
|---------|--------|
| eDiscovery | All messages searchable by compliance officers |
| Legal Hold | Messages preserved even if deleted by users |
| DLP | Content scanned for sensitive data patterns |
| Audit Logs | All bot interactions logged in Microsoft 365 audit |

**Bot-specific**: Bot responses containing sensitive data (code, credentials, internal URLs) will be captured by eDiscovery. Never include secrets in bot responses.

### Network Requirements

Outbound from bot server: `login.botframework.com`, `login.microsoftonline.com`, `graph.microsoft.com`, `smba.trafficmanager.net`, `*.botframework.com`. Inbound: HTTPS (443) from Microsoft Bot Framework.

### Security Recommendations

1. Single-tenant only — restrict bot to your Azure AD tenant
2. AAD object ID allowlists — restrict which users can interact
3. Channel allowlists — restrict which channels the bot responds in
4. No secrets in responses — stored in Microsoft 365 compliance systems
5. Credential storage — use gopass or Azure Key Vault, never in code
6. JWT validation — always verify Bot Framework JWT on incoming requests
7. Rate limiting — implement per-user rate limits to prevent abuse

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
| Graph API 403 | Check application permissions in Azure AD; ensure admin consent granted |

## Limitations

- **Platform lock-in**: Azure AD required for auth, Bot Framework for message routing, Graph API for advanced features — no self-hosted alternative
- **Message format**: Adaptive Cards are Teams-specific; HTML support is limited; message size limit 28 KB text / 40 KB cards
- **Threading**: DMs and group chats are flat; top-level channel posts require Graph API
- **Closed source**: No way to audit server-side code, verify encryption claims, or self-host Teams infrastructure

## Related

- `services/communications/matterbridge.md` — Multi-platform bridge (native Teams support)
- `services/communications/matrix-bot.md` — Matrix bot integration (self-hosted, E2E optional)
- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, E2E encrypted)
- `tools/security/opsec.md` — Operational security guidance
- `tools/ai-assistants/headless-dispatch.md` — Headless dispatch patterns
- Bot Framework Docs: https://learn.microsoft.com/en-us/microsoftteams/platform/bots/what-are-bots
- Adaptive Cards: https://adaptivecards.io/
- Graph API: https://learn.microsoft.com/en-us/graph/api/overview
- Teams App Manifest: https://learn.microsoft.com/en-us/microsoftteams/platform/resources/schema/manifest-schema
