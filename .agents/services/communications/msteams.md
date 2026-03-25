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
- **Docs**: [Bot Framework](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/what-are-bots) | [Graph API](https://learn.microsoft.com/en-us/graph/api/overview) | [Adaptive Cards](https://adaptivecards.io/) | [Manifest Schema](https://learn.microsoft.com/en-us/microsoftteams/platform/resources/schema/manifest-schema)

**Key characteristics**: Teams bots are webhook-based — Microsoft pushes activities to your HTTPS endpoint (no persistent WebSocket). The bot must be publicly reachable (or use ngrok/dev tunnels for development). All messages pass through Microsoft's servers in plaintext — no E2E encryption. For sensitive communications, use SimpleX or Matrix with E2E enabled.

**Security (applies throughout)**: Store all credentials (`appId`, `clientSecret`, `tenantId`) in gopass (`aidevops secret set MSTEAMS_*`). Never commit secrets to code, config files, or bot responses — all bot output is captured by Microsoft 365 eDiscovery/compliance systems.

<!-- AI-CONTEXT-END -->

## Architecture

```text
Teams Client --> Bot Framework Service (Azure) --> Your Bot Server (Node.js/Express)
                        |
                        v
              Microsoft Graph API (channels, files, users, teams)
```

**Message flow**: User --> Teams client --> Bot Framework (authenticates, wraps as Activity JSON) --> POSTed to your HTTPS endpoint --> Bot verifies JWT --> dispatches to aidevops runner --> responds via Connector REST API. Your server must be HTTPS-reachable from the internet.

## Setup

### 1. Azure AD App Registration + Bot Resource

Prerequisites: Azure subscription (free tier sufficient), Azure AD tenant admin consent.

```bash
# App registration (or via Azure Portal: AD > App registrations > New registration)
az ad app create --display-name "aidevops-teams-bot" --sign-in-audience "AzureADMyOrg"
az ad app credential reset --id <appId> --years 2  # Note appId, create client secret

# Store credentials
aidevops secret set MSTEAMS_APP_ID
aidevops secret set MSTEAMS_CLIENT_SECRET
aidevops secret set MSTEAMS_TENANT_ID

# Bot resource
az bot create --resource-group mygroup --name aidevops-teams-bot \
  --app-type SingleTenant --appid <appId> --tenant-id <tenantId>
az bot update --resource-group mygroup --name aidevops-teams-bot \
  --endpoint "https://your-server.example.com/api/messages"
az bot msteams create --resource-group mygroup --name aidevops-teams-bot
```

### 2. Teams App Manifest

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

RSC permissions allow the bot to access team/chat data without tenant-wide admin consent.

```bash
zip -j aidevops-teams-bot.zip manifest.json outline-32x32.png color-192x192.png
# Sideload: Teams > Apps > Manage your apps > Upload a custom app
```

### 3. Bot Server (Node.js)

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

### 4. Development Tunneling

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

### Sending Messages, Cards, and Threading

```javascript
// Simple reply
await context.sendActivity("Hello from the bot!");

// Adaptive Card (display-only)
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

// Adaptive Card with input + submit handler
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
// Handle submit in onAdaptiveCardInvoke:
// const data = context.activity.value.action.data;
// return { statusCode: 200, type: "application/vnd.microsoft.activity.message", value: result };

// Proactive message (outside a conversation turn)
const { MicrosoftAppCredentials, ConnectorClient } = require("botframework-connector");
const client = new ConnectorClient(new MicrosoftAppCredentials(appId, appPassword),
  { baseUri: context.activity.serviceUrl });
await client.conversations.sendToConversation(conversationId,
  { type: "message", text: "Proactive notification: deployment complete." });

// Thread reply (channel only)
await context.sendActivity({ type: "message", text: "Thread reply",
  conversation: { id: `${channelId};messageid=${parentMessageId}` } });

// New top-level channel post requires Graph API
await graphClient.api(`/teams/${teamId}/channels/${channelId}/messages`)
  .post({ body: { content: "New top-level post" } });
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
const teams = await graphClient.api("/me/joinedTeams").get();
const messages = await graphClient.api(`/teams/${teamId}/channels/${channelId}/messages`).top(50).get();
await graphClient.api(`/teams/${teamId}/channels/${channelId}/messages`)
  .post({ body: { contentType: "html", content: "<b>Deployment complete</b>" } });
```

**Required Graph API permissions** (set in Azure AD app registration):

| Permission | Type | Use |
|------------|------|-----|
| `ChannelMessage.Read.All` / `.Send` | Application | Read/send channel messages |
| `Chat.Read` | Delegated | Read DM/group chat messages |
| `Files.ReadWrite.All` | Application | Upload/download files |
| `User.Read.All` | Application | Look up user profiles |
| `TeamsActivity.Send` | Application | Send activity feed notifications |

## Access Control

Use the immutable `aadObjectId` from the activity payload as the primary access control mechanism.

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

**Tenant isolation**: Use `SingleTenant` (recommended) to restrict the bot to your Azure AD tenant. `MultiTenant` accepts requests from any tenant (for published apps / ISVs).

## Configuration

`~/.config/aidevops/msteams-bot.json` (600 permissions). `appId`/`clientSecret` stored in gopass.

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
  "channelMappings": { "19:channel-id@thread.tacv2": "code-reviewer" },
  "botPrefix": "",
  "maxPromptLength": 3000,
  "responseTimeout": 600
}
```

`allowedUsers`/`allowedTeams`/`allowedChannels`: empty = all allowed. `channelMappings`: channel ID to runner name (e.g., `#dev` to `code-reviewer`). `maxPromptLength`: truncation limit (default 3000). `responseTimeout`: max wait seconds (default 600).

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

## Matterbridge Native Support

Simplest way to bridge Teams to other platforms — uses Graph API, no webhook endpoint needed.

```toml
[msteams]
  [msteams.work]
  TenantID = "your-tenant-id"
  ClientID = "your-app-id"
  ClientSecret = "your-client-secret"  # Store in gopass, inject via env var
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

Bridges channel messages only (not DMs). Build note: Teams support adds ~2.5GB to compile memory; use `-tags nomsteams` to exclude.

## Deployment

### Azure App Service

```bash
az webapp create --resource-group mygroup --plan myplan --name aidevops-teams-bot --runtime "NODE:18-lts"
az webapp config appsettings set --resource-group mygroup --name aidevops-teams-bot --settings \
  MSTEAMS_APP_ID="@Microsoft.KeyVault(VaultName=...)" MSTEAMS_TENANT_ID="<tenantId>"
az webapp deployment source config-zip --resource-group mygroup --name aidevops-teams-bot --src bot.zip
```

### Docker / Systemd (Self-Hosted)

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
# Docker: use --env-file for credentials, reverse proxy (Caddy/Nginx) for TLS
docker run -d --name msteams-bot --restart unless-stopped -p 3978:3978 \
  --env-file /etc/msteams-bot/env aidevops-teams-bot:latest

# Systemd: /etc/systemd/system/msteams-bot.service
# [Service] Type=simple User=msteams-bot WorkingDirectory=/opt/msteams-bot
# ExecStart=/usr/bin/node index.js Restart=on-failure EnvironmentFile=/etc/msteams-bot/env
```

## Privacy, Security, and Compliance

**No E2E encryption.** TLS 1.2+ in transit, encrypted at rest, but accessible in plaintext to Microsoft and tenant admins via eDiscovery, DLP, and compliance tools. Legal holds preserve messages even if deleted. Copilot for M365 processes Teams messages by default (restrict via Purview sensitivity labels on E3/E5).

**Data storage**: Chat messages in Exchange Online, channel messages in SharePoint/Exchange, channel files in SharePoint Online, DM files in OneDrive for Business — all searchable via eDiscovery. Bot responses containing sensitive data are captured. Never include secrets in bot responses.

**Network requirements**: Outbound: `login.botframework.com`, `login.microsoftonline.com`, `graph.microsoft.com`, `smba.trafficmanager.net`, `*.botframework.com`. Inbound: HTTPS (443).

**Security checklist**: (1) Single-tenant only (2) AAD object ID allowlists (3) Channel allowlists (4) No secrets in responses (5) Credentials in gopass/Azure Key Vault (6) Verify Bot Framework JWT on incoming requests (7) Per-user rate limiting.

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
