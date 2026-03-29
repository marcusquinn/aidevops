---
description: Google Chat bot integration — HTTP webhook mode, Google Cloud project setup, service account auth, DM/space messaging, Adaptive Cards, access control, and aidevops runner dispatch
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

- **Mode**: HTTP endpoint (Google POSTs events to your URL) — not WebSocket, not polling
- **Config**: `~/.config/aidevops/google-chat-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/google-chat-bot/`
- **Auth**: Service account JWT (outbound); Google-signed bearer token (inbound verification)
- **Requires**: Google Workspace account, Google Cloud project, public HTTPS URL, Node.js >= 18, jq

```bash
google-chat-helper.sh setup  # Interactive wizard
```

**Privacy warning**: No E2E encryption. Google retains all messages; Workspace admins have full read access. Gemini AI may use workspace data for training unless your admin configures DPAs and opts out. See [Privacy and Security Assessment](#privacy-and-security-assessment).

<!-- AI-CONTEXT-END -->

## Architecture

```text
Google Chat → HTTPS URL (Tailscale/Caddy/Cloudflare) → Bot (:8443) → runner-helper.sh → AI session
                                                         verify token → parse event → check perms
                                                         → dispatch runner → return card/text
```

## Setup

### Step 1: Google Cloud Project

```bash
gcloud projects create aidevops-chat-bot --name="aidevops Chat Bot"
gcloud config set project aidevops-chat-bot
gcloud services enable chat.googleapis.com
gcloud iam service-accounts create chat-bot --display-name="Chat Bot Service Account"
gcloud iam service-accounts keys create \
  ~/.config/aidevops/google-chat-sa-key.json \
  --iam-account=chat-bot@aidevops-chat-bot.iam.gserviceaccount.com
chmod 600 ~/.config/aidevops/google-chat-sa-key.json
```

### Step 2: Configure Chat App

[Google Cloud Console > APIs & Services > Google Chat API > Configuration](https://console.cloud.google.com/apis/api/chat.googleapis.com/hangouts-chat): set HTTP endpoint URL, enable "Receive 1:1 messages" and "Join spaces and group conversations", set Authentication Audience to HTTP endpoint URL.

### Step 3: Public URL

| Option | Command |
|--------|---------|
| Tailscale Funnel | `tailscale funnel 8443` |
| Caddy | `caddy reverse-proxy --from chat-bot.example.com --to localhost:8443` |
| Cloudflare Tunnel | `cloudflared tunnel --url http://localhost:8443 run chat-bot` |

## Configuration

`~/.config/aidevops/google-chat-bot.json` (600 permissions):

| Option | Default | Description |
|--------|---------|-------------|
| `projectId` | required | Google Cloud project ID |
| `serviceAccountKeyPath` | required | Path to `~/.config/aidevops/google-chat-sa-key.json` |
| `listenPort` | `8443` | Bot server port |
| `endpointPath` | `/google-chat` | Webhook path |
| `allowedUsers` | `[]` | Emails allowed; empty = all domain users |
| `spaceMappings` | `{}` | `"spaces/ID": "runner-name"` mapping |
| `defaultRunner` | `""` | Runner for unmapped spaces/DMs; empty = ignore |
| `responseTimeout` | `30` | Seconds before returning async acknowledgment |
| `asyncResponseTimeout` | `600` | Max seconds for async runner response |
| `verifyGoogleTokens` | `true` | **Must remain `true` in production** |

## Authentication

### Inbound (Google to Bot)

> **CRITICAL**: Verify Google's bearer token on every request — without this, anyone who discovers the webhook URL can send forged events.

```typescript
import { createRemoteJWKSet, jwtVerify } from "jose";
const JWKS = createRemoteJWKSet(new URL("https://www.googleapis.com/service_accounts/v1/jwk/chat@system.gserviceaccount.com"));
async function verifyGoogleChatToken(token: string, audience: string): Promise<boolean> {
  await jwtVerify(token, JWKS, { issuer: "chat@system.gserviceaccount.com", audience });
  return true;
}
```

Validate: `iss` = `chat@system.gserviceaccount.com`, `aud` = your project number or endpoint URL.

### Outbound (Bot to Google)

```typescript
import { GoogleAuth } from "google-auth-library";
const auth = new GoogleAuth({ keyFile: config.serviceAccountKeyPath, scopes: ["https://www.googleapis.com/auth/chat.bot"] });
const client = await auth.getClient();
await client.request({ url: "https://chat.googleapis.com/v1/spaces/SPACE_ID/messages", method: "POST", data: { text: "Analysis complete..." } });
```

## Event Types

| Event Type | Trigger | Action |
|------------|---------|--------|
| `ADDED_TO_SPACE` | Bot added to space or DM started | Send welcome message |
| `REMOVED_FROM_SPACE` | Bot removed | Clean up, log |
| `MESSAGE` | User mentions bot or sends DM | Parse prompt, dispatch runner |
| `CARD_CLICKED` | User clicks card button | Handle card action |

Key payload fields: `message.argumentText` (prompt, bot mention stripped), `user.email` (access control), `space.name` (runner mapping), `message.thread.name` (threading).

## Messaging

**Sync (< 30s)**: Return `{ "text": "..." }` directly in HTTP response body.

**Async (> 30s)**: Return a `cardsV2` acknowledgment card immediately, then post full response via Chat API:

```bash
curl -X POST "https://chat.googleapis.com/v1/spaces/SPACE_ID/messages" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{ "text": "Analysis complete...", "thread": { "name": "spaces/SPACE_ID/threads/THREAD_ID" }, "threadReply": true }'
```

### Card v2 (Adaptive Cards)

```json
{ "cardsV2": [{ "cardId": "review-result", "card": {
  "header": { "title": "Code Review: auth.ts", "subtitle": "2 issues found" },
  "sections": [
    { "header": "Critical", "widgets": [{ "decoratedText": { "topLabel": "Line 42", "text": "SQL injection vulnerability" } }] },
    { "widgets": [{ "buttonList": { "buttons": [
      { "text": "View Full Report", "onClick": { "openLink": { "url": "https://github.com/org/repo/pull/123" } } }
    ] } }] }
  ]
} }] }
```

**Card limits**: 1 card/message, 100 sections, 100 widgets/section, 4096 chars/widget, 40 chars/button. Image URLs must be public HTTPS. Test across web, Gmail sidebar, and mobile.

## Space-to-Runner Mapping and Access Control

```bash
google-chat-helper.sh map 'spaces/AAAA1234' code-reviewer
google-chat-helper.sh mappings   # list
google-chat-helper.sh unmap 'spaces/AAAA1234'
```

DMs use `defaultRunner`. If unconfigured, bot responds with a help message.

`allowedUsers` restricts to specific emails; empty (`[]`) allows all Workspace domain users.

**Permission check order**: token verification → domain → allowlist → space mapping. Domain-level control: Google Admin Console > Apps > Google Workspace > Google Chat > Chat apps settings.

## Operations

```bash
google-chat-helper.sh start --daemon  # background
google-chat-helper.sh start           # foreground (debug)
google-chat-helper.sh stop && google-chat-helper.sh status
google-chat-helper.sh logs [--follow] [--tail 200]
google-chat-helper.sh test code-reviewer "Review src/auth.ts"    # test dispatch
google-chat-helper.sh test-event message "Test message from CLI" # test event
google-chat-helper.sh test-auth                                  # verify token
```

**Health**: `GET /health` → `{"status":"ok","uptime":3600,"spaces":3,"lastEvent":"..."}`

**Runners**: `runner-helper.sh create <name> --description "..."` | `runner-helper.sh edit <name>`

**Dispatch flow**: `MESSAGE` event → space mapping → `runner-helper.sh dispatch <runner> "<prompt>"` → headless AI session → Card v2 or text → sync (≤30s) or async via Chat API.

## Privacy and Security Assessment

| Aspect | Status | Notes |
|--------|--------|-------|
| E2E encryption | None | TLS in transit only |
| Server-side storage | All messages | Google retains all Chat messages; admins have full read access |
| Data/retention | Google-controlled | Per Workspace settings; configurable via Google Vault |
| Gemini AI training | Risk | Workspace data may train Google AI unless DPA configured |

**Gemini warning**: Review your org's Workspace DPA and verify Gemini AI settings (Google Admin Console > Apps > Additional Google services > Gemini) before deploying a bot handling sensitive data.

For sensitive communications, prefer Matrix (self-hosted) or SimpleX — see `tools/security/opsec.md` for platform comparison.

### Bot-Specific Security

- `verifyGoogleTokens: true` always — prevents forged requests
- Service account key: 600 permissions, never commit to git
- `allowedUsers`: restrict to specific users, not entire domain
- Scan inbound with `prompt-guard-helper.sh`; scan outbound for credential patterns
- Use reverse proxy (Caddy/Cloudflare) for TLS — don't expose bot directly
- Log all events; redact sensitive content
- FCM note: Google uses Firebase Cloud Messaging for mobile push — FCM infrastructure knows when users receive Chat notifications

## Limitations

| Limitation | Detail |
|------------|--------|
| 30s response window | Return acknowledgment card immediately; post full response async |
| No Matterbridge | Requires custom API bridge or relay bot |
| Workspace required | Cannot use with free Gmail accounts |
| Card rendering varies | Test across web, Gmail sidebar, and mobile |
| Rate limits | 60 msg/min per space; 50,000 spaces max |
| Thread limits | Space-scoped only; bot cannot create threads proactively |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bot not receiving events | Verify public URL is accessible; check Chat API configuration |
| 401 Unauthorized | Verify service account key is valid; check `chat.bot` scope |
| Token verification fails | Ensure `verifyGoogleTokens: true`; check clock sync (JWT expiry) |
| Bot not visible to users | Check Chat app visibility in Google Cloud Console |
| Async messages not posting | Verify service account has `chat.bot` scope; check space name format |
| Cards not rendering | Validate Card v2 JSON; check for unsupported widget types |
| Rate limited | Reduce frequency; implement exponential backoff |
| Bot removed from space | Check `REMOVED_FROM_SPACE` events in logs; re-add bot |

## Related

- `services/communications/matrix-bot.md` — Matrix bot (self-hosted, E2E encrypted)
- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge)
- `services/communications/matterbridge.md` — Multi-platform chat bridge (40+ platforms)
- `tools/security/opsec.md` — Platform trust matrix, E2E status, metadata warnings
- `tools/security/prompt-injection-defender.md` — Prompt injection scanning
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- `scripts/runner-helper.sh` — Runner management
- [Google Chat API](https://developers.google.com/workspace/chat/api/reference/rest)
- [Google Chat Card v2](https://developers.google.com/workspace/chat/api/reference/rest/v1/cards)
- [Google Workspace DPA](https://workspace.google.com/terms/dpa_terms.html)
