---
description: Google Chat bot — HTTP webhook, service account auth, DM/space messaging, Cards, ACL, runner dispatch
mode: subagent
tools: { read: true, bash: true }
---

# Google Chat Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Mode**: HTTP endpoint (Google POSTs events) — not WebSocket/polling
- **Config**: `~/.config/aidevops/google-chat-bot.json` (600 perms)
- **Data**: `~/.aidevops/.agent-workspace/google-chat-bot/`
- **Auth**: Service account JWT (outbound); Google-signed bearer (inbound)
- **Requires**: Google Workspace, GCP project, public HTTPS URL, Node.js >= 18, jq
- **Setup**: `google-chat-helper.sh setup` (interactive wizard)
- **Privacy**: No E2E encryption; Google retains all messages; Gemini may train on data unless DPA configured. See [Privacy and Security](#privacy-and-security).

<!-- AI-CONTEXT-END -->

**Flow**: `Google Chat → HTTPS → Bot (:8443)` → verify token → parse → ACL check → `runner-helper.sh dispatch` → AI session → Card v2/text response

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

Cloud Console > APIs & Services > Google Chat API > Configuration: set HTTP endpoint URL, enable "Receive 1:1 messages" + "Join spaces and group conversations", set auth audience to endpoint URL.

### Step 3: Public URL

| Option | Command |
|--------|---------|
| Tailscale Funnel | `tailscale funnel 8443` |
| Caddy | `caddy reverse-proxy --from chat-bot.example.com --to localhost:8443` |
| Cloudflare Tunnel | `cloudflared tunnel --url http://localhost:8443 run chat-bot` |

## Configuration

`~/.config/aidevops/google-chat-bot.json` (600 perms):

| Option | Default | Description |
|--------|---------|-------------|
| `projectId` | required | GCP project ID |
| `serviceAccountKeyPath` | required | Path to SA key JSON |
| `listenPort` | `8443` | Bot server port |
| `endpointPath` | `/google-chat` | Webhook path |
| `allowedUsers` | `[]` | Permitted emails; empty = all domain users |
| `spaceMappings` | `{}` | `"spaces/ID": "runner-name"` |
| `defaultRunner` | `""` | Runner for unmapped spaces/DMs; empty = ignore |
| `responseTimeout` | `30` | Seconds before async ack |
| `asyncResponseTimeout` | `600` | Max seconds for async response |
| `verifyGoogleTokens` | `true` | **Must be `true` in production** |

## Authentication

### Inbound (Google → Bot)

> **CRITICAL**: Verify Google's bearer token on every request — without this, anyone can send forged events.

```typescript
import { createRemoteJWKSet, jwtVerify } from "jose";
const JWKS = createRemoteJWKSet(new URL("https://www.googleapis.com/service_accounts/v1/jwk/chat@system.gserviceaccount.com"));
// Validate: iss = chat@system.gserviceaccount.com, aud = project number or endpoint URL
async function verifyGoogleChatToken(token: string, audience: string): Promise<boolean> {
  await jwtVerify(token, JWKS, { issuer: "chat@system.gserviceaccount.com", audience });
  return true;
}
```

### Outbound (Bot → Google)

```typescript
import { GoogleAuth } from "google-auth-library";
const auth = new GoogleAuth({ keyFile: config.serviceAccountKeyPath, scopes: ["https://www.googleapis.com/auth/chat.bot"] });
await (await auth.getClient()).request({ url: "https://chat.googleapis.com/v1/spaces/SPACE_ID/messages", method: "POST", data: { text: "..." } });
```

## Events and Messaging

| Event Type | Trigger | Action |
|------------|---------|--------|
| `ADDED_TO_SPACE` | Bot added to space/DM | Send welcome message |
| `REMOVED_FROM_SPACE` | Bot removed | Clean up, log |
| `MESSAGE` | User mentions bot or DMs | Parse prompt, dispatch runner |
| `CARD_CLICKED` | Card button click | Handle card action |

Payload fields: `message.argumentText` (prompt, mention stripped), `user.email` (ACL), `space.name` (runner mapping), `message.thread.name` (threading).

**Sync (< 30s)**: Return `{ "text": "..." }` in HTTP response. **Async (> 30s)**: Return `cardsV2` ack, then POST full response to `spaces/SPACE_ID/messages` with `Authorization: Bearer <token>`, `thread.name`, `threadReply: true`.

**Card v2**: `cardsV2[].card` with `header`/`sections[].widgets`. Limits: 1 card/msg, 100 sections, 100 widgets/section, 4096 chars/widget, 40 chars/button. Public HTTPS image URLs only. [Reference](https://developers.google.com/workspace/chat/api/reference/rest/v1/cards).

## Space-to-Runner Mapping

```bash
google-chat-helper.sh map 'spaces/AAAA1234' code-reviewer
google-chat-helper.sh mappings   # list all
google-chat-helper.sh unmap 'spaces/AAAA1234'
```

DMs use `defaultRunner`; unconfigured = help message. **ACL order**: token verification → domain → allowlist → space mapping. Domain control: Admin Console > Apps > Google Workspace > Google Chat > Chat apps settings.

## Operations

```bash
google-chat-helper.sh start --daemon   # background
google-chat-helper.sh start            # foreground (debug)
google-chat-helper.sh stop && google-chat-helper.sh status
google-chat-helper.sh logs [--follow] [--tail 200]
google-chat-helper.sh test code-reviewer "Review src/auth.ts"     # dispatch test
google-chat-helper.sh test-event message "Test message from CLI"  # event test
google-chat-helper.sh test-auth                                   # token verify
```

**Health**: `GET /health` → `{"status":"ok","uptime":...,"spaces":N}` · **Runners**: `runner-helper.sh create|edit <name>`

## Privacy and Security

No E2E encryption (TLS in transit only). Google retains all messages; admins have full read access. Retention: Google Vault. **Gemini AI**: workspace data may train AI unless DPA configured — verify Admin Console > Additional Google services > Gemini and [Workspace DPA](https://workspace.google.com/terms/dpa_terms.html) before deploying with sensitive data.

**Bot security**: SA key 600 perms, never commit · `allowedUsers` allowlist in production · Scan inbound (`prompt-guard-helper.sh`) and outbound (credential patterns) · Reverse proxy for TLS · Log events, redact sensitive content · FCM: Google sees push notification metadata.

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
| Not receiving events | Verify public URL reachable; check Chat API config |
| 401 / token verification | SA key valid? `chat.bot` scope? `verifyGoogleTokens: true`? Clock sync (JWT expiry)? |
| Bot not visible | Check Chat app visibility in Cloud Console |
| Async messages fail | Verify `chat.bot` scope; check space name format |
| Cards not rendering | Validate Card v2 JSON; check widget types |
| Rate limited | Reduce frequency; exponential backoff |

## Related

`matrix-bot.md` (E2E) · `simplex.md` · `matterbridge.md` (40+ platforms) · `opsec.md` (trust matrix) · `prompt-injection-defender.md` · `headless-dispatch.md` · `runner-helper.sh` · [Chat API](https://developers.google.com/workspace/chat/api/reference/rest) · [Card v2](https://developers.google.com/workspace/chat/api/reference/rest/v1/cards)
