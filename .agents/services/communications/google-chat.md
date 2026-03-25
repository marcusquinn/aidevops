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

- **Purpose**: Bridge Google Chat DMs and spaces to aidevops runners via HTTP webhook endpoint
- **Mode**: HTTP endpoint (Google sends events to your URL) — not WebSocket, not polling
- **Config**: `~/.config/aidevops/google-chat-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/google-chat-bot/`
- **Auth**: Google Cloud service account (JWT) for outbound; Google-signed bearer token for inbound verification
- **Requires**: Google Workspace account, Google Cloud project, public HTTPS URL, Node.js >= 18, jq
- **No Matterbridge support**: Google Chat has no native Matterbridge gateway — standalone integration only

**Quick start**:

```bash
google-chat-helper.sh setup          # Interactive wizard
google-chat-helper.sh start --daemon # Start bot
```

**Privacy warning**: Google Chat stores all messages server-side. Workspace admins have full read access. Gemini AI is integrated — workspace data may be used for AI improvement unless your admin configures DPAs and opts out. No E2E encryption. See [Privacy and Security Assessment](#privacy-and-security-assessment).

<!-- AI-CONTEXT-END -->

## Architecture

```text
Google Chat → Public HTTPS URL → Bot Server (:8443) → runner-helper.sh → AI session
              (Tailscale/Caddy/   1. Verify token
               Cloudflare)        2. Parse event
                                  3. Check perms
                                  4. Dispatch runner
                                  5. Return card/text
```

**Message flow**: User mentions bot → Google POSTs to endpoint → bot verifies JWT → checks allowlist → dispatches to runner → formats Card v2 or text → returns in HTTP response (sync) or posts via Chat API (async >30s).

**Key difference from Matrix/SimpleX**: Synchronous HTTP request-response. Google expects a response within 30 seconds. For longer tasks, return an acknowledgment card immediately and post the full response asynchronously.

## Setup

**Prerequisites**: Google Workspace account, Google Cloud project, public HTTPS URL, Node.js >= 18, jq.

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

[Google Cloud Console > APIs & Services > Google Chat API > Configuration](https://console.cloud.google.com/apis/api/chat.googleapis.com/hangouts-chat):

- **Connection settings**: HTTP endpoint URL → `https://your-public-url.example.com/google-chat`
- **Functionality**: Enable "Receive 1:1 messages" and "Join spaces and group conversations"
- **Authentication Audience**: HTTP endpoint URL (default)

### Step 3: Public URL

| Option | Command | Notes |
|--------|---------|-------|
| Tailscale Funnel | `tailscale funnel 8443` | Zero config, auto TLS, URL tied to machine name |
| Caddy | `caddy reverse-proxy --from chat-bot.example.com --to localhost:8443` | Stable URL, requires domain |
| Cloudflare Tunnel | `cloudflared tunnel --url http://localhost:8443 run chat-bot` | No open ports, DDoS protection, requires Cloudflare DNS |

### Step 4: Bot Configuration

```bash
google-chat-helper.sh setup  # Interactive wizard
```

## Configuration

`~/.config/aidevops/google-chat-bot.json` (600 permissions):

```json
{
  "projectId": "aidevops-chat-bot",
  "serviceAccountKeyPath": "~/.config/aidevops/google-chat-sa-key.json",
  "listenPort": 8443,
  "endpointPath": "/google-chat",
  "allowedUsers": ["admin@example.com", "dev@example.com"],
  "spaceMappings": {
    "spaces/AAAA1234": "code-reviewer",
    "spaces/BBBB5678": "seo-analyst"
  },
  "defaultRunner": "",
  "maxResponseLength": 4096,
  "responseTimeout": 30,
  "asyncResponseTimeout": 600,
  "verifyGoogleTokens": true
}
```

| Option | Default | Description |
|--------|---------|-------------|
| `projectId` | (required) | Google Cloud project ID |
| `serviceAccountKeyPath` | (required) | Path to service account JSON key |
| `allowedUsers` | `[]` (all domain users) | Email addresses allowed to use the bot |
| `spaceMappings` | `{}` | Space name → runner mapping |
| `defaultRunner` | `""` | Runner for unmapped spaces/DMs (empty = ignore) |
| `maxResponseLength` | `4096` | Max response text length before truncation |
| `responseTimeout` | `30` | Seconds before returning async acknowledgment |
| `asyncResponseTimeout` | `600` | Max seconds for async runner response |
| `verifyGoogleTokens` | `true` | **Must remain `true` in production** — disable only for local dev |

## Authentication

### Inbound (Google to Bot)

> **CRITICAL**: Verify Google's bearer token on every request. Without this, anyone who discovers the webhook URL can send forged events.

```typescript
import { createRemoteJWKSet, jwtVerify } from "jose";

const GOOGLE_CHAT_JWKS = createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/chat@system.gserviceaccount.com")
);

async function verifyGoogleChatToken(token: string, audience: string): Promise<boolean> {
  await jwtVerify(token, GOOGLE_CHAT_JWKS, {
    issuer: "chat@system.gserviceaccount.com",
    audience,
  });
  return true;
}
```

Validate: `iss` = `chat@system.gserviceaccount.com`, `aud` = your project number or endpoint URL.

### Outbound (Bot to Google)

```typescript
import { GoogleAuth } from "google-auth-library";

const auth = new GoogleAuth({
  keyFile: config.serviceAccountKeyPath,
  scopes: ["https://www.googleapis.com/auth/chat.bot"],
});
const client = await auth.getClient();
await client.request({
  url: "https://chat.googleapis.com/v1/spaces/SPACE_ID/messages",
  method: "POST",
  data: { text: "Analysis complete..." },
});
```

## Event Types

| Event Type | Trigger | Action |
|------------|---------|--------|
| `ADDED_TO_SPACE` | Bot added to space or DM started | Send welcome message |
| `REMOVED_FROM_SPACE` | Bot removed | Clean up, log |
| `MESSAGE` | User mentions bot or sends DM | Parse prompt, dispatch runner |
| `CARD_CLICKED` | User clicks card button | Handle card action |

**Key payload fields**:
- `message.argumentText` — prompt text with bot mention stripped (use as runner input)
- `user.email` — for access control
- `space.name` — for space-to-runner mapping
- `message.thread.name` — for threading responses

## Messaging

### Synchronous (< 30 seconds)

Return directly in HTTP response body:

```json
{ "text": "Here is the review result..." }
```

### Asynchronous (> 30 seconds)

**Step 1** — Return acknowledgment card immediately:

```json
{
  "cardsV2": [{
    "cardId": "processing",
    "card": {
      "header": { "title": "Processing...", "subtitle": "This may take a few minutes" },
      "sections": [{ "widgets": [{ "decoratedText": { "text": "Dispatching to runner", "startIcon": { "knownIcon": "CLOCK" } } }] }]
    }
  }]
}
```

**Step 2** — Post full response via Chat API:

```bash
curl -X POST "https://chat.googleapis.com/v1/spaces/SPACE_ID/messages" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{ "text": "Analysis complete...", "thread": { "name": "spaces/SPACE_ID/threads/THREAD_ID" }, "threadReply": true }'
```

### Card v2 (Adaptive Cards)

```json
{
  "cardsV2": [{
    "cardId": "review-result",
    "card": {
      "header": { "title": "Code Review: auth.ts", "subtitle": "2 issues found" },
      "sections": [
        { "header": "Critical", "widgets": [{ "decoratedText": { "topLabel": "Line 42", "text": "SQL injection vulnerability", "startIcon": { "knownIcon": "BOOKMARK" } } }] },
        { "header": "Warning", "widgets": [{ "decoratedText": { "topLabel": "Line 87", "text": "Missing rate limiting", "startIcon": { "knownIcon": "DESCRIPTION" } } }] },
        { "widgets": [{ "buttonList": { "buttons": [
          { "text": "View Full Report", "onClick": { "openLink": { "url": "https://github.com/org/repo/pull/123" } } },
          { "text": "Re-run Analysis", "onClick": { "action": { "function": "rerun_analysis", "parameters": [{ "key": "file", "value": "auth.ts" }] } } }
        ] } }] }
      ]
    }
  }]
}
```

**Card limits**: 1 card/message, 100 sections/card, 100 widgets/section, 4096 chars/widget text, 40 chars/button text. Image URLs must be public HTTPS. Test across web, Gmail sidebar, and mobile — rendering varies.

## Space-to-Runner Mapping

```bash
google-chat-helper.sh map 'spaces/AAAA1234' code-reviewer
google-chat-helper.sh map 'spaces/BBBB5678' seo-analyst
google-chat-helper.sh mappings   # list
google-chat-helper.sh unmap 'spaces/AAAA1234'
```

| Space | Runner | Purpose |
|-------|--------|---------|
| Dev Team | `code-reviewer` | Code review, security analysis |
| SEO | `seo-analyst` | SEO audits, keyword research |
| Ops | `ops-monitor` | Server health, deployment status |
| DMs | (default runner) | General AI assistance |

DMs use `defaultRunner`. If unconfigured, bot responds with a help message.

## Access Control

```json
{ "allowedUsers": ["admin@example.com", "dev@example.com"] }
```

Empty `allowedUsers` (`[]`) allows all Workspace domain users who can discover the bot.

**Permission check order**: Google token verification → domain check → user allowlist → space mapping.

**Domain-level control**: Google Admin Console > Apps > Google Workspace > Google Chat > Chat apps settings.

## Operations

```bash
google-chat-helper.sh start --daemon  # Start (background)
google-chat-helper.sh start           # Start (foreground, debug)
google-chat-helper.sh stop
google-chat-helper.sh status
google-chat-helper.sh logs [--follow] [--tail 200]
google-chat-helper.sh test code-reviewer "Review src/auth.ts"   # Test dispatch
google-chat-helper.sh test-event message "Test message from CLI" # Test event
google-chat-helper.sh test-auth                                  # Verify token validation
```

**Health endpoint**: `GET /health` → `{"status":"ok","uptime":3600,"spaces":3,"lastEvent":"..."}`

## Integration with Runners

```bash
runner-helper.sh create code-reviewer --description "Reviews code for security and quality"
runner-helper.sh create seo-analyst --description "SEO analysis and keyword research"
runner-helper.sh edit code-reviewer
```

**Dispatch flow**: Message event → resolve space to runner → `runner-helper.sh dispatch <runner> "<prompt>"` → headless AI session → format Card v2 or text → return sync (≤30s) or post async via Chat API.

## Privacy and Security Assessment

| Aspect | Status | Notes |
|--------|--------|-------|
| E2E encryption | None | TLS in transit only |
| Server-side storage | All messages | Google retains all Chat messages |
| Admin access | Full | Workspace admins can read all messages including DMs |
| Data residency | Google-controlled | Per Workspace settings |
| Retention | Admin-configurable | Via Google Vault |
| Gemini AI training | Risk | Workspace data may train Google AI unless DPA configured |

**Gemini warning**: Google has integrated Gemini directly into Chat. Before deploying a bot handling sensitive data: review your org's Workspace DPA, verify Gemini AI settings in Google Admin Console > Apps > Additional Google services > Gemini, and consider whether sensitive prompts should flow through Google Chat at all.

### Platform Comparison

| Aspect | Google Chat | Matrix (self-hosted) | SimpleX |
|--------|-------------|---------------------|---------|
| E2E encryption | No | Yes (Megolm) | Yes (Double ratchet) |
| Server-side storage | Google-controlled | Self-controlled | None |
| Admin surveillance | Full access | Self-hosted = you control | Not possible |
| AI training risk | Yes (Gemini) | No | No |
| Open source | No | Yes | Yes (AGPL-3.0) |

**Bottom line**: Appropriate for orgs already committed to Google Workspace where convenience outweighs privacy concerns. For sensitive communications, prefer Matrix (self-hosted) or SimpleX.

### Bot-Specific Security

1. **Token verification**: Always `verifyGoogleTokens: true` — prevents forged requests
2. **Service account key**: 600 permissions, never commit to git
3. **User allowlist**: Restrict to specific users, not entire domain
4. **Prompt sanitization**: Scan inbound messages with `prompt-guard-helper.sh` before passing to AI
5. **Response filtering**: Scan outbound for credential patterns before sending
6. **Network**: Use reverse proxy (Caddy/Cloudflare) for TLS termination — don't expose bot directly
7. **Logging**: Log all events for audit trail; redact sensitive content

**FCM note**: Google uses Firebase Cloud Messaging for mobile push notifications — Google's FCM infrastructure knows when users receive Chat notifications.

## Limitations

| Limitation | Detail |
|------------|--------|
| 30s response window | Return acknowledgment card immediately; post full response async via Chat API |
| No Matterbridge | Not a native gateway — requires custom API bridge or relay bot |
| Workspace required | Cannot use with free Gmail accounts |
| Card rendering varies | Test across web, Gmail sidebar, and mobile apps |
| Rate limits | 60 msg/min per space (incoming + outgoing + card actions); 50,000 spaces max |
| Thread limits | Space-scoped only; thread names are opaque; bot cannot create threads proactively |

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
