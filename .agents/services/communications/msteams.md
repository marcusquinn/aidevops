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

- **Auth**: Azure App ID + Client Secret + Tenant ID (Azure AD / Entra ID)
- **Config**: `~/.config/aidevops/msteams-bot.json` (600 permissions)
- **SDK**: `botbuilder` + `botbuilder-teams` (npm) or `botframework-connector` (REST)
- **Requires**: Node.js >= 18, Azure subscription, Teams admin consent
- **Matterbridge**: Native support via Graph API (see `matterbridge.md`)
- **Docs**: [Bot Framework](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/what-are-bots) | [Graph API](https://learn.microsoft.com/en-us/graph/api/overview) | [Adaptive Cards](https://adaptivecards.io/) | [Manifest Schema](https://learn.microsoft.com/en-us/microsoftteams/platform/resources/schema/manifest-schema)

**Architecture**: Webhook-based — Microsoft pushes activities to your HTTPS endpoint (no persistent WebSocket). Bot must be publicly reachable (ngrok/dev tunnels for dev). No E2E encryption — all messages accessible to Microsoft and tenant admins via eDiscovery. For sensitive comms, use SimpleX or Matrix.

**Security**: Store credentials (`appId`, `clientSecret`, `tenantId`) in gopass (`aidevops secret set MSTEAMS_*`). Never commit secrets. Bot output captured by Microsoft 365 eDiscovery/compliance systems.

<!-- AI-CONTEXT-END -->

## Architecture

```text
Teams Client --> Bot Framework Service (Azure) --> Your Bot Server (Node.js/Express)
                        |
                        v
              Microsoft Graph API (channels, files, users, teams)
```

## Setup

### 1. Azure AD App Registration + Bot Resource

```bash
az ad app create --display-name "aidevops-teams-bot" --sign-in-audience "AzureADMyOrg"
az ad app credential reset --id <appId> --years 2
aidevops secret set MSTEAMS_APP_ID && aidevops secret set MSTEAMS_CLIENT_SECRET && aidevops secret set MSTEAMS_TENANT_ID
az bot create --resource-group mygroup --name aidevops-teams-bot \
  --app-type SingleTenant --appid <appId> --tenant-id <tenantId>
az bot update --resource-group mygroup --name aidevops-teams-bot \
  --endpoint "https://your-server.example.com/api/messages"
az bot msteams create --resource-group mygroup --name aidevops-teams-bot
```

### 2. Teams App Manifest (key fields)

Full schema: [Manifest Schema](https://learn.microsoft.com/en-us/microsoftteams/platform/resources/schema/manifest-schema). RSC permissions allow team/chat data access without tenant-wide admin consent.

```json
{
  "$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.17/MicrosoftTeams.schema.json",
  "manifestVersion": "1.17", "version": "1.0.0", "id": "<appId>",
  "bots": [{ "botId": "<appId>", "scopes": ["personal", "team", "groupChat"], "supportsFiles": true }],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": ["your-server.example.com"],
  "authorization": { "permissions": { "resourceSpecific": [
    { "name": "ChannelMessage.Read.Group", "type": "Application" },
    { "name": "ChatMessage.Read.Chat", "type": "Application" },
    { "name": "ChannelMessage.Send.Group", "type": "Application" }
  ]}}
}
```

```bash
zip -j aidevops-teams-bot.zip manifest.json outline-32x32.png color-192x192.png
# Sideload: Teams > Apps > Manage your apps > Upload a custom app
```

### 3. Bot Server (Node.js)

```bash
npm install botbuilder express
```

```javascript
const { BotFrameworkAdapter, TeamsActivityHandler, CardFactory } = require("botbuilder");
const express = require("express");
const adapter = new BotFrameworkAdapter({ appId: process.env.MSTEAMS_APP_ID, appPassword: process.env.MSTEAMS_CLIENT_SECRET });
adapter.onTurnError = async (context, error) => context.sendActivity("An error occurred.");

class AIDevOpsBot extends TeamsActivityHandler {
  async onMessage(context) {
    const text = context.activity.text?.replace(/<at>.*<\/at>/g, "").trim();
    if (!text || !isAllowedUser(context.activity.from.aadObjectId)) return;
    await context.sendActivity({ type: "typing" });
    await context.sendActivity(await dispatchToRunner(text, context));
  }
}
const bot = new AIDevOpsBot();
const app = express();
app.use(express.json());
app.post("/api/messages", async (req, res) => adapter.process(req, res, (ctx) => bot.run(ctx)));
app.listen(3978);
```

### 4. Development Tunneling

```bash
devtunnel create --allow-anonymous && devtunnel port create -p 3978 && devtunnel host
# Or: ngrok http 3978 — update Azure Bot endpoint to the tunnel URL
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
await context.sendActivity("Hello from the bot!");

// Adaptive Card — see adaptivecards.io/designer for schema
const card = CardFactory.adaptiveCard({ type: "AdaptiveCard", version: "1.5",
  body: [{ type: "TextBlock", text: "Task Result", weight: "Bolder" }],
  actions: [{ type: "Action.OpenUrl", title: "View PR", url: "https://github.com/..." }] });
await context.sendActivity({ attachments: [card] });

// Proactive message (outside a conversation turn)
const { MicrosoftAppCredentials, ConnectorClient } = require("botframework-connector");
const client = new ConnectorClient(new MicrosoftAppCredentials(appId, appPassword), { baseUri: context.activity.serviceUrl });
await client.conversations.sendToConversation(conversationId, { type: "message", text: "..." });

// Thread reply (channel only)
await context.sendActivity({ type: "message", text: "Reply", conversation: { id: `${channelId};messageid=${parentMessageId}` } });

// New top-level channel post (Graph API required)
await graphClient.api(`/teams/${teamId}/channels/${channelId}/messages`).post({ body: { content: "New post" } });
```

## File Handling

| Context | Upload mechanism | Storage |
|---------|-----------------|---------|
| Personal (DM) | Inline attachment | Bot Framework blob storage |
| Channel | SharePoint via Graph API | Team's SharePoint document library |
| Group chat | OneDrive via Graph API | Sender's OneDrive |

```javascript
for (const attachment of context.activity.attachments || []) {
  const isTeamsFile = attachment.contentType === "application/vnd.microsoft.teams.file.download.info";
  const response = await fetch(isTeamsFile ? attachment.content.downloadUrl : attachment.contentUrl,
    { headers: { Authorization: `Bearer ${isTeamsFile ? graphToken : botToken}` } });
}
```

## Graph API Integration

```javascript
const { Client } = require("@microsoft/microsoft-graph-client");
const { ClientSecretCredential } = require("@azure/identity");
const { TokenCredentialAuthenticationProvider } = require("@microsoft/microsoft-graph-client/authProviders/azureTokenCredentials");
const graphClient = Client.initWithMiddleware({ authProvider: new TokenCredentialAuthenticationProvider(
  new ClientSecretCredential(tenantId, appId, clientSecret), { scopes: ["https://graph.microsoft.com/.default"] }) });

const teams = await graphClient.api("/me/joinedTeams").get();
const messages = await graphClient.api(`/teams/${teamId}/channels/${channelId}/messages`).top(50).get();
await graphClient.api(`/teams/${teamId}/channels/${channelId}/messages`).post({ body: { contentType: "html", content: "<b>Done</b>" } });
```

**Required Graph API permissions** (Azure AD app registration):

| Permission | Type | Use |
|------------|------|-----|
| `ChannelMessage.Read.All` / `.Send` | Application | Read/send channel messages |
| `Chat.Read` | Delegated | Read DM/group chat messages |
| `Files.ReadWrite.All` | Application | Upload/download files |
| `User.Read.All` | Application | Look up user profiles |
| `TeamsActivity.Send` | Application | Send activity feed notifications |

## Access Control

Use immutable `aadObjectId` from the activity payload as the primary access control key. `SingleTenant` restricts to your Azure AD tenant; `MultiTenant` accepts any tenant (for published apps / ISVs).

```javascript
function isAllowedUser(aadObjectId) {
  const config = loadConfig();
  if (config.adminUsers?.includes(aadObjectId)) return true;
  if (!config.allowedUsers?.length) return true; // empty = all tenant users allowed
  return config.allowedUsers.includes(aadObjectId);
}
function isAllowedConversation(context) {
  const config = loadConfig();
  if (context.activity.conversation.conversationType === "channel") {
    if (config.allowedChannels?.length && !config.allowedChannels.includes(context.activity.channelData?.channel?.id)) return false;
    if (config.allowedTeams?.length && !config.allowedTeams.includes(context.activity.channelData?.team?.id)) return false;
  }
  return isAllowedUser(context.activity.from.aadObjectId);
}
```

## Configuration

`~/.config/aidevops/msteams-bot.json` (600 permissions). `appId`/`clientSecret` stored in gopass.

```json
{
  "appId": "stored-in-gopass",
  "tenantId": "00000000-0000-0000-0000-000000000000",
  "botEndpoint": "https://your-server.example.com/api/messages",
  "allowedUsers": [], "allowedTeams": [], "allowedChannels": [], "adminUsers": [],
  "defaultRunner": "",
  "channelMappings": { "19:channel-id@thread.tacv2": "code-reviewer" },
  "maxPromptLength": 3000,
  "responseTimeout": 600
}
```

`allowedUsers`/`allowedTeams`/`allowedChannels`: empty = all allowed. `channelMappings`: channel ID → runner name. `maxPromptLength`: 3000. `responseTimeout`: 600s.

## Runner Dispatch Integration

```javascript
const execFileAsync = require("util").promisify(require("child_process").execFile);
async function dispatchToRunner(prompt, context) {
  const config = loadConfig();
  const runner = config.channelMappings[context.activity.channelData?.channel?.id] || config.defaultRunner;
  if (!runner) return "No runner configured for this channel.";
  try {
    const { stdout } = await execFileAsync("runner-helper.sh", ["dispatch", runner, prompt],
      { timeout: config.responseTimeout * 1000, encoding: "utf-8" });
    return stdout.trim();
  } catch { return "Runner dispatch failed. Please try again later or contact an administrator."; }
}
```

## Matterbridge Native Support

Simplest Teams bridge — uses Graph API, no webhook endpoint needed. Bridges channel messages only (not DMs). Use `-tags nomsteams` to exclude (~2.5GB compile memory).

```toml
[msteams]
  [msteams.work]
  TenantID = "your-tenant-id"
  ClientID = "your-app-id"
  ClientSecret = "your-client-secret"  # inject via env var from gopass
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

## Deployment

### Azure App Service

```bash
az webapp create --resource-group mygroup --plan myplan --name aidevops-teams-bot --runtime "NODE:18-lts"
az webapp config appsettings set --resource-group mygroup --name aidevops-teams-bot --settings \
  MSTEAMS_APP_ID="@Microsoft.KeyVault(VaultName=...)" MSTEAMS_TENANT_ID="<tenantId>"
az webapp deployment source config-zip --resource-group mygroup --name aidevops-teams-bot --src bot.zip
```

### Docker / Systemd (Self-Hosted)

```bash
# Docker: use --env-file for credentials; reverse proxy (Caddy/Nginx) for TLS
docker run -d --name msteams-bot --restart unless-stopped -p 3978:3978 \
  --env-file /etc/msteams-bot/env aidevops-teams-bot:latest
# Systemd: EnvironmentFile=/etc/msteams-bot/env, ExecStart=/usr/bin/node index.js
```

## Privacy, Security, and Compliance

**No E2E encryption.** TLS 1.2+ in transit, encrypted at rest, but accessible in plaintext to Microsoft and tenant admins via eDiscovery, DLP, and compliance tools. Legal holds preserve messages even if deleted. Copilot for M365 processes Teams messages by default (restrict via Purview sensitivity labels on E3/E5).

**Network requirements**: Outbound: `login.botframework.com`, `login.microsoftonline.com`, `graph.microsoft.com`, `smba.trafficmanager.net`, `*.botframework.com`. Inbound: HTTPS (443).

**Security checklist**: (1) Single-tenant only (2) AAD object ID allowlists (3) Channel allowlists (4) No secrets in responses (5) Credentials in gopass/Azure Key Vault (6) Verify Bot Framework JWT on incoming requests (7) Per-user rate limiting.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bot not receiving messages | Verify messaging endpoint URL in Azure Bot resource; check HTTPS certificate |
| 401 Unauthorized | Verify App ID and Client Secret; check token validation logic |
| Bot not appearing in Teams | Sideload the app manifest ZIP; check Teams admin policies |
| Messages not delivered to channel | Ensure bot is @mentioned; check RSC permissions |
| File upload fails | Verify `Files.ReadWrite.All` Graph API permission; check SharePoint access |
| Adaptive Card not rendering | Validate at adaptivecards.io/designer; check version compatibility |
| Proactive messages fail | Store and reuse `serviceUrl` and `conversationId` from previous activities |
| Graph API 403 | Check application permissions in Azure AD; ensure admin consent granted |

## Limitations

- **Platform lock-in**: Azure AD + Bot Framework + Graph API required — no self-hosted alternative
- **Message format**: Adaptive Cards are Teams-specific; HTML support limited; 28 KB text / 40 KB card limits
- **Threading**: DMs and group chats are flat; top-level channel posts require Graph API
- **Closed source**: No way to audit server-side code, verify encryption claims, or self-host Teams infrastructure

## Related

- `services/communications/matterbridge.md` — Multi-platform bridge (native Teams support)
- `services/communications/matrix-bot.md` — Matrix bot integration (self-hosted, E2E optional)
- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, E2E encrypted)
- `tools/security/opsec.md` — Operational security guidance
- `tools/ai-assistants/headless-dispatch.md` — Headless dispatch patterns
