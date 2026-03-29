---
description: Google Chat bot integration — HTTP webhook, service account auth, DM/space messaging, Cards, access control, runner dispatch
mode: subagent
tools: { read: true, bash: true }
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

**Privacy warning**: No E2E encryption. Google retains all messages; admins have full read access. Gemini AI may train on workspace data unless DPA configured. See [Privacy and Security](#privacy-and-security).

<!-- AI-CONTEXT-END -->

**Flow**: `Google Chat → HTTPS → Bot (:8443)` → verify token → parse event → check perms → `runner-helper.sh dispatch` → AI session → Card v2 or text response

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

Cloud Console > APIs & Services > Google Chat API > Configuration: set HTTP endpoint URL, enable "Receive 1:1 messages" + "Join spaces and group conversations", set Authentication Audience to endpoint URL.

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

> **CRITICAL**: Verify Google's bearer token on every request — without this, anyone can send forged events.

```typescript
import { createRemoteJWKSet, jwtVerify } from "jose";
const JWKS = createRemoteJWKSet(new URL("https://www.googleapis.com/service_accounts/v1/jwk/chat@system.gserviceaccount.com"));
async function verifyGoogleChatToken(token: string, audience: string): Promise<boolean> {
  await jwtVerify(token, JWKS, { issuer: "chat@system.gserviceaccount.com", audience });
  return true;
} // Validate: iss = chat@system.gserviceaccount.com, aud = project number or endpoint URL
```

### Outbound (Bot to Google)

```typescript
import { GoogleAuth } from "google-auth-library";
const auth = new GoogleAuth({ keyFile: config.serviceAccountKeyPath, scopes: ["https://www.googleapis.com/auth/chat.bot"] });
await (await auth.getClient()).request({ url: "https://chat.googleapis.com/v1/spaces/SPACE_ID/messages", method: "POST", data: { text: "..." } });
```

## Event Types

| Event Type | Trigger | Action |
|------------|---------|--------|
| `ADDED_TO_SPACE` | Bot added to space/DM | Send welcome message |
| `REMOVED_FROM_SPACE` | Bot removed | Clean up, log |
| `MESSAGE` | User mentions bot or DMs | Parse prompt, dispatch runner |
| `CARD_CLICKED` | Card button click | Handle card action |

Payload: `message.argumentText` (prompt, mention stripped), `user.email` (ACL), `space.name` (runner mapping), `message.thread.name` (threading).

## Messaging

**Sync (< 30s)**: Return `{ "text": "..." }` directly in HTTP response body.

**Async (> 30s)**: Return `cardsV2` acknowledgment immediately, then POST full response via `https://chat.googleapis.com/v1/spaces/SPACE_ID/messages` with `Authorization: Bearer <token>`, `thread.name`, and `threadReply: true`.

### Card v2 (Adaptive Cards)

Structure: `cardsV2[].card` with `header` (`title`, `subtitle`) and `sections[].widgets`. Limits: 1 card/message, 100 sections, 100 widgets/section, 4096 chars/widget, 40 chars/button. Public HTTPS image URLs only. See [Card v2 reference](https://developers.google.com/workspace/chat/api/reference/rest/v1/cards).

## Space-to-Runner Mapping and Access Control

```bash
google-chat-helper.sh map 'spaces/AAAA1234' code-reviewer
google-chat-helper.sh mappings   # list all
google-chat-helper.sh unmap 'spaces/AAAA1234'
```

DMs use `defaultRunner`; unconfigured = help message. `allowedUsers` restricts to specific emails; empty = all domain users.

**Permission check order**: token verification → domain → allowlist → space mapping. Domain control: Google Admin Console > Apps > Google Workspace > Google Chat > Chat apps settings.

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

**Health**: `GET /health` → `{"status":"ok","uptime":3600,"spaces":3,"lastEvent":"..."}`. **Runners**: `runner-helper.sh create <name> --description "..."` | `runner-helper.sh edit <name>`

## Privacy and Security

| Aspect | Status |
|--------|--------|
| E2E encryption | None — TLS in transit only |
| Server-side storage | Google retains all messages; admins have full read access |
| Data/retention | Google-controlled; configurable via Google Vault |
| Gemini AI training | Risk — workspace data may train AI unless DPA configured |

**Gemini warning**: Verify Gemini AI settings (Admin Console > Additional Google services > Gemini) and Workspace DPA before deploying with sensitive data.

**Bot security rules**: SA key: 600 perms, never commit | `allowedUsers`: restrict to specific users in production | Scan inbound with `prompt-guard-helper.sh`, outbound for credential patterns | Reverse proxy (Caddy/Cloudflare) for TLS | Log all events, redact sensitive content | FCM: Google FCM infrastructure knows when users receive Chat push notifications.

## Limitations

| Limitation | Detail |
|------------|--------|
| 30s response window | Return ack card immediately; full response async |
| No Matterbridge | Requires custom API bridge or relay bot |
| Workspace required | Free Gmail accounts unsupported |
| Card rendering varies | Test across web, Gmail sidebar, mobile |
| Rate limits | 60 msg/min per space; 50,000 spaces max |
| Thread limits | Space-scoped; bot cannot create threads proactively |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Not receiving events | Verify public URL accessible; check Chat API config |
| 401 Unauthorized | Verify SA key valid; check `chat.bot` scope |
| Token verification fails | `verifyGoogleTokens: true`; check clock sync (JWT expiry) |
| Bot not visible | Check Chat app visibility in Cloud Console |
| Async messages fail | Verify `chat.bot` scope; check space name format |
| Cards not rendering | Validate Card v2 JSON; check widget types |
| Rate limited | Reduce frequency; exponential backoff |

## Related

- `services/communications/matrix-bot.md` — Matrix (self-hosted, E2E)
- `services/communications/simplex.md` — SimpleX (zero-knowledge)
- `services/communications/matterbridge.md` — Chat bridge (40+ platforms)
- `tools/security/opsec.md` — Platform trust matrix
- `tools/security/prompt-injection-defender.md` — Prompt injection scanning
- `tools/ai-assistants/headless-dispatch.md` — Headless dispatch
- `scripts/runner-helper.sh` — Runner management
- [Chat API](https://developers.google.com/workspace/chat/api/reference/rest) | [Card v2](https://developers.google.com/workspace/chat/api/reference/rest/v1/cards) | [Workspace DPA](https://workspace.google.com/terms/dpa_terms.html)
