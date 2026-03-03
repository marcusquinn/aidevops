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
- **Auth**: Google Cloud service account (JWT) for outbound messages; Google-signed bearer token for inbound verification
- **Requires**: Google Workspace account, Google Cloud project, public HTTPS URL, Node.js >= 18, jq
- **No Matterbridge support**: Google Chat has no native Matterbridge gateway — this is a standalone integration

**Quick start**:

```bash
# 1. Create Google Cloud project and enable Chat API (see Setup below)
# 2. Configure the bot
google-chat-helper.sh setup          # Interactive wizard
# 3. Expose endpoint publicly (pick one)
tailscale funnel 8443                # Tailscale Funnel
# or: caddy reverse-proxy --from chat-bot.example.com --to localhost:8443
# or: cloudflared tunnel --url http://localhost:8443
# 4. Start the bot
google-chat-helper.sh start --daemon
```

**Privacy/security warning**: Google Chat is a Google Workspace product. All messages are stored server-side, accessible to workspace admins, and subject to Google's data processing policies. **Google has integrated Gemini AI directly into Chat** — workspace data may be used for AI feature improvement unless the workspace admin configures data processing agreements (DPAs) and opts out. There is no E2E encryption. See [Privacy and Security Assessment](#privacy-and-security-assessment) for full analysis.

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ Google Chat      │     │ Public HTTPS URL │     │ Bot Server       │
│ (Workspace)      │     │ (Tailscale/Caddy │     │ (Node.js :8443)  │
│                  │     │  /Cloudflare)    │     │                  │
│ User types:      │────▶│ TLS termination  │────▶│ 1. Verify token  │
│ @BotName review  │     │ + proxy          │     │ 2. Parse event   │
│ auth.ts          │     │                  │     │ 3. Check perms   │
│                  │◀────│                  │◀────│ 4. Dispatch      │
│ AI response      │     │                  │     │    to runner     │
│ (Card or text)   │     │                  │     │ 5. Return card   │
└──────────────────┘     └──────────────────┘     └──────────────────┘
                                                        │
                                                        ▼
                                                  ┌──────────────┐
                                                  │ runner-       │
                                                  │ helper.sh    │
                                                  │ → AI session │
                                                  └──────────────┘
```

**Message flow**:

1. User mentions the bot or sends a DM in Google Chat
2. Google sends an HTTP POST to the bot's configured endpoint URL
3. Bot verifies the request bearer token against Google's public keys (JWKS)
4. Bot parses the event (message, added-to-space, removed-from-space, card-clicked)
5. Bot checks user email against the allowlist
6. Bot dispatches the prompt to a runner via `runner-helper.sh`
7. Runner executes via headless AI session
8. Bot formats the response as a Card v2 or plain text and returns it in the HTTP response body
9. Google Chat renders the response to the user

**Key difference from Matrix/SimpleX**: Google Chat uses a synchronous HTTP request-response model. Google sends an event, the bot must respond within 30 seconds. For longer tasks, the bot returns an acknowledgment card immediately and posts the full response asynchronously via the Chat API.

## Setup

### Prerequisites

1. **Google Workspace account** — Google Chat bots require Workspace (free Gmail accounts cannot create Chat apps)
2. **Google Cloud project** — for Chat API access and service account credentials
3. **Public HTTPS URL** — Google must reach your bot endpoint over the internet
4. **Node.js >= 18** — bot runtime
5. **jq** — JSON processing

### Step 1: Google Cloud Project

```bash
# Create project (or use existing)
gcloud projects create aidevops-chat-bot --name="aidevops Chat Bot"
gcloud config set project aidevops-chat-bot

# Enable the Chat API
gcloud services enable chat.googleapis.com

# Create service account for outbound API calls
gcloud iam service-accounts create chat-bot \
  --display-name="Chat Bot Service Account"

# Download service account key (store securely)
gcloud iam service-accounts keys create \
  ~/.config/aidevops/google-chat-sa-key.json \
  --iam-account=chat-bot@aidevops-chat-bot.iam.gserviceaccount.com

# Restrict permissions on key file
chmod 600 ~/.config/aidevops/google-chat-sa-key.json
```

### Step 2: Configure Chat App

1. Go to [Google Cloud Console > APIs & Services > Google Chat API > Configuration](https://console.cloud.google.com/apis/api/chat.googleapis.com/hangouts-chat)
2. Set:
   - **App name**: aidevops Bot (or your preferred name)
   - **Avatar URL**: (optional)
   - **Description**: AI DevOps assistant
   - **Functionality**: Check "Receive 1:1 messages" and "Join spaces and group conversations"
   - **Connection settings**: Select "HTTP endpoint URL"
   - **HTTP endpoint URL**: `https://your-public-url.example.com/google-chat`
   - **Authentication Audience**: Select "HTTP endpoint URL" (default)
   - **Visibility**: Select who can discover and use the bot (specific people or entire domain)
3. Click **Save**

### Step 3: Public URL

Google Chat requires a publicly accessible HTTPS endpoint. Three recommended options:

#### Option A: Tailscale Funnel (Simplest)

```bash
# Expose local port via Tailscale's global network
# Requires Tailscale installed and logged in
tailscale funnel 8443

# This gives you a URL like: https://your-machine.tail12345.ts.net/
# Use this URL in the Chat API configuration
```

**Pros**: Zero config, automatic TLS, no domain needed.
**Cons**: Requires Tailscale account, URL changes if machine name changes.

#### Option B: Caddy Reverse Proxy

```bash
# With a domain pointing to your server
caddy reverse-proxy --from chat-bot.example.com --to localhost:8443

# Or in Caddyfile
# chat-bot.example.com {
#     reverse_proxy localhost:8443
# }
```

**Pros**: Automatic HTTPS via Let's Encrypt, stable URL, production-grade.
**Cons**: Requires domain and DNS configuration.

#### Option C: Cloudflare Tunnel

```bash
# Install cloudflared
brew install cloudflared  # macOS
# or: curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared

# Create tunnel
cloudflared tunnel create chat-bot
cloudflared tunnel route dns chat-bot chat-bot.example.com

# Run tunnel
cloudflared tunnel --url http://localhost:8443 run chat-bot
```

**Pros**: No open ports, Cloudflare DDoS protection, stable URL.
**Cons**: Requires Cloudflare account and domain on Cloudflare DNS.

### Step 4: Bot Configuration

```bash
# Interactive setup wizard
google-chat-helper.sh setup

# Or manual configuration
```

## Configuration

### Config File

`~/.config/aidevops/google-chat-bot.json` (600 permissions):

```json
{
  "projectId": "aidevops-chat-bot",
  "serviceAccountKeyPath": "~/.config/aidevops/google-chat-sa-key.json",
  "listenPort": 8443,
  "endpointPath": "/google-chat",
  "allowedUsers": [
    "admin@example.com",
    "dev@example.com"
  ],
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

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `projectId` | (required) | Google Cloud project ID |
| `serviceAccountKeyPath` | (required) | Path to service account JSON key file |
| `listenPort` | `8443` | Local port for the HTTP server |
| `endpointPath` | `/google-chat` | URL path for the webhook endpoint |
| `allowedUsers` | `[]` (all domain users) | Email addresses allowed to use the bot |
| `spaceMappings` | `{}` | Space name to runner mapping |
| `defaultRunner` | `""` | Runner for unmapped spaces (empty = ignore) |
| `maxResponseLength` | `4096` | Max response text length before truncation |
| `responseTimeout` | `30` | Seconds before returning async acknowledgment |
| `asyncResponseTimeout` | `600` | Max seconds for async runner response |
| `verifyGoogleTokens` | `true` | Verify inbound request bearer tokens against Google JWKS |

## Authentication

### Inbound (Google to Bot)

Google signs every HTTP request to the bot with a bearer token (JWT). The bot must verify this token to prevent spoofed requests.

**Verification flow**:

1. Extract `Authorization: Bearer <token>` header from the request
2. Decode the JWT header to get the `kid` (key ID)
3. Fetch Google's public keys from `https://www.googleapis.com/service_accounts/v1/jwk/chat@system.gserviceaccount.com`
4. Verify the JWT signature using the matching public key
5. Validate claims: `iss` = `chat@system.gserviceaccount.com`, `aud` = your project number or endpoint URL

```typescript
import { createRemoteJWKSet, jwtVerify } from "jose";

const GOOGLE_CHAT_JWKS = createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/chat@system.gserviceaccount.com")
);

async function verifyGoogleChatToken(token: string, audience: string): Promise<boolean> {
  const { payload } = await jwtVerify(token, GOOGLE_CHAT_JWKS, {
    issuer: "chat@system.gserviceaccount.com",
    audience,
  });
  return true;
}
```

### Outbound (Bot to Google)

To send messages asynchronously (after the initial 30s window), the bot authenticates using the service account:

```typescript
import { GoogleAuth } from "google-auth-library";

const auth = new GoogleAuth({
  keyFile: config.serviceAccountKeyPath,
  scopes: ["https://www.googleapis.com/auth/chat.bot"],
});

const client = await auth.getClient();

// Send async message to a space
const response = await client.request({
  url: "https://chat.googleapis.com/v1/spaces/SPACE_ID/messages",
  method: "POST",
  data: {
    text: "Here is the analysis result...",
  },
});
```

## Event Types

Google Chat sends these event types to the bot endpoint:

| Event Type | Trigger | Typical Action |
|------------|---------|----------------|
| `ADDED_TO_SPACE` | Bot added to a space or DM started | Send welcome message, log space |
| `REMOVED_FROM_SPACE` | Bot removed from a space | Clean up, log removal |
| `MESSAGE` | User sends a message mentioning the bot or in a DM | Parse prompt, dispatch to runner |
| `CARD_CLICKED` | User clicks a button on an interactive card | Handle card action |

### Event Payload Structure

```json
{
  "type": "MESSAGE",
  "eventTime": "2025-01-15T10:30:00.000Z",
  "space": {
    "name": "spaces/AAAA1234",
    "type": "ROOM",
    "displayName": "Dev Team"
  },
  "message": {
    "name": "spaces/AAAA1234/messages/abcdef.123456",
    "sender": {
      "name": "users/1234567890",
      "displayName": "Jane Developer",
      "email": "jane@example.com",
      "type": "HUMAN"
    },
    "text": "@aidevops Review src/auth.ts for security vulnerabilities",
    "argumentText": "Review src/auth.ts for security vulnerabilities",
    "thread": {
      "name": "spaces/AAAA1234/threads/abcdef"
    }
  },
  "user": {
    "name": "users/1234567890",
    "displayName": "Jane Developer",
    "email": "jane@example.com",
    "type": "HUMAN"
  }
}
```

**Key fields**:

- `message.argumentText` — the message text with the bot mention stripped (use this as the prompt)
- `user.email` — for access control checks
- `space.name` — for space-to-runner mapping
- `message.thread.name` — for threading responses

## Messaging

### Synchronous Response (< 30 seconds)

For fast responses, return the message directly in the HTTP response body:

```json
{
  "text": "Here is the review result:\n\n**auth.ts** looks good. No critical vulnerabilities found."
}
```

### Asynchronous Response (> 30 seconds)

For longer tasks (AI runner dispatch), return an acknowledgment immediately and post the result later:

**Step 1**: Return acknowledgment card in HTTP response:

```json
{
  "cardsV2": [{
    "cardId": "processing",
    "card": {
      "header": {
        "title": "Processing your request...",
        "subtitle": "This may take a few minutes"
      },
      "sections": [{
        "widgets": [{
          "decoratedText": {
            "text": "Dispatching to code-reviewer runner",
            "startIcon": { "knownIcon": "CLOCK" }
          }
        }]
      }]
    }
  }]
}
```

**Step 2**: Post the full response via the Chat API:

```bash
# Using the REST API directly
curl -X POST \
  "https://chat.googleapis.com/v1/spaces/SPACE_ID/messages" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Analysis complete. Here are the results...",
    "thread": { "name": "spaces/SPACE_ID/threads/THREAD_ID" },
    "threadReply": true
  }'
```

### Card v2 (Adaptive Cards)

Google Chat supports rich interactive cards for structured responses:

```json
{
  "cardsV2": [{
    "cardId": "review-result",
    "card": {
      "header": {
        "title": "Code Review: auth.ts",
        "subtitle": "2 issues found",
        "imageUrl": "https://example.com/icon.png",
        "imageType": "CIRCLE"
      },
      "sections": [
        {
          "header": "Critical",
          "widgets": [{
            "decoratedText": {
              "topLabel": "Line 42",
              "text": "SQL injection vulnerability in user input handling",
              "startIcon": { "knownIcon": "BOOKMARK" }
            }
          }]
        },
        {
          "header": "Warning",
          "widgets": [{
            "decoratedText": {
              "topLabel": "Line 87",
              "text": "Missing rate limiting on login endpoint",
              "startIcon": { "knownIcon": "DESCRIPTION" }
            }
          }]
        },
        {
          "widgets": [{
            "buttonList": {
              "buttons": [
                {
                  "text": "View Full Report",
                  "onClick": {
                    "openLink": { "url": "https://github.com/org/repo/pull/123" }
                  }
                },
                {
                  "text": "Re-run Analysis",
                  "onClick": {
                    "action": {
                      "function": "rerun_analysis",
                      "parameters": [{ "key": "file", "value": "auth.ts" }]
                    }
                  }
                }
              ]
            }
          }]
        }
      ]
    }
  }]
}
```

### Card Limitations

| Feature | Limit |
|---------|-------|
| Cards per message | 1 |
| Sections per card | 100 |
| Widgets per section | 100 |
| Text length | 4096 characters per widget |
| Button text | 40 characters |
| Image URL | Must be publicly accessible HTTPS |

## Space-to-Runner Mapping

Each Google Chat space maps to a runner, similar to the Matrix bot pattern:

```bash
# Map spaces to runners (space names from Chat API)
google-chat-helper.sh map 'spaces/AAAA1234' code-reviewer
google-chat-helper.sh map 'spaces/BBBB5678' seo-analyst

# List mappings
google-chat-helper.sh mappings

# Remove a mapping
google-chat-helper.sh unmap 'spaces/AAAA1234'
```

### Recommended Space Layout

| Space | Runner | Purpose |
|-------|--------|---------|
| Dev Team | `code-reviewer` | Code review, security analysis |
| SEO | `seo-analyst` | SEO audits, keyword research |
| Ops | `ops-monitor` | Server health, deployment status |
| DMs | (default runner) | General AI assistance |

### DM Handling

When a user sends a direct message to the bot (no space context), the bot uses the `defaultRunner`. If no default runner is configured, the bot responds with a help message listing available commands.

## Access Control

### User Allowlist

Restrict bot access to specific Google Workspace users:

```json
{
  "allowedUsers": [
    "admin@example.com",
    "dev-team@example.com",
    "contractor@example.com"
  ]
}
```

When `allowedUsers` is empty (`[]`), all users in the Google Workspace domain who can discover the bot are allowed.

### Domain-Level Control

Google Workspace admins control bot visibility at the organizational level:

1. **Google Admin Console** > Apps > Google Workspace > Google Chat
2. **Chat apps settings** > Allow users to install Chat apps
3. **Allowlisting**: Restrict which Chat apps users can install

### Permission Checks

The bot verifies permissions in this order:

1. **Google token verification** — is this request genuinely from Google?
2. **Domain check** — is the user from an allowed Workspace domain?
3. **User allowlist** — is this specific user permitted?
4. **Space mapping** — is this space mapped to a runner?

## Operations

### Start/Stop

```bash
# Start in daemon mode (background)
google-chat-helper.sh start --daemon

# Start in foreground (for debugging)
google-chat-helper.sh start

# Stop the bot
google-chat-helper.sh stop

# Check status
google-chat-helper.sh status
```

### Monitoring

```bash
# View latest logs
google-chat-helper.sh logs

# Follow logs in real-time
google-chat-helper.sh logs --follow

# View more history
google-chat-helper.sh logs --tail 200
```

### Testing

```bash
# Test dispatch without Google Chat (directly to runner)
google-chat-helper.sh test code-reviewer "Review src/auth.ts"

# Send a test event payload
google-chat-helper.sh test-event message "Test message from CLI"

# Verify Google token validation
google-chat-helper.sh test-auth
```

### Health Check

The bot exposes a health endpoint for monitoring:

```bash
# GET /health returns 200 OK with status JSON
curl http://localhost:8443/health
# {"status":"ok","uptime":3600,"spaces":3,"lastEvent":"2025-01-15T10:30:00Z"}
```

## Integration with Runners

The bot dispatches to runners via `runner-helper.sh`, identical to the Matrix bot pattern:

```bash
# Create runners for Google Chat spaces
runner-helper.sh create code-reviewer \
  --description "Reviews code for security and quality"

runner-helper.sh create seo-analyst \
  --description "SEO analysis and keyword research"

# Edit runner instructions
runner-helper.sh edit code-reviewer
```

### Dispatch Flow

1. Bot receives message event from Google
2. Bot resolves space to runner (or uses default for DMs)
3. Bot calls `runner-helper.sh dispatch <runner> "<prompt>"` with user context
4. Runner executes via headless AI session
5. Bot formats the response as a Card v2 or plain text
6. If within 30s window: returns in HTTP response
7. If async: posts via Chat API to the original thread

## Privacy and Security Assessment

### Data Handling

| Aspect | Status | Notes |
|--------|--------|-------|
| **E2E encryption** | None | Messages are encrypted in transit (TLS) but not end-to-end |
| **Server-side storage** | All messages stored | Google retains all Chat messages server-side |
| **Admin access** | Full | Workspace admins can read all messages, including DMs |
| **Data residency** | Google-controlled | Data stored in Google's infrastructure per Workspace settings |
| **Retention** | Admin-configurable | Workspace admins set retention policies via Vault |
| **Export** | Google Vault / Takeout | Admins can export all Chat data |

### Gemini AI Integration Warning

**Google has integrated Gemini AI directly into Google Chat.** This has significant privacy implications:

- **Gemini in Chat**: Workspace users can interact with Gemini directly in Chat spaces
- **AI features**: Smart compose, summarization, and other AI features process message content
- **Training data**: Under Google's default terms, Workspace data may be used to improve Google AI products
- **Opt-out**: Workspace admins can configure Data Processing Agreements (DPAs) and disable AI features
- **Enterprise controls**: Enterprise customers can negotiate specific data processing terms

**Recommendation**: Before deploying a Chat bot that handles sensitive data:

1. Review your organization's Google Workspace DPA
2. Verify Gemini AI features are configured per your data policy
3. Check Google Admin Console > Apps > Additional Google services > Gemini for settings
4. Consider whether sensitive prompts/responses should flow through Google Chat at all

### Comparison with Other Platforms

| Aspect | Google Chat | Matrix (self-hosted) | SimpleX |
|--------|-------------|---------------------|---------|
| E2E encryption | No | Yes (Megolm) | Yes (Double ratchet) |
| Server-side storage | Google-controlled | Self-controlled | None (stateless relays) |
| User identifiers | Google account email | `@user:server` | None |
| Admin surveillance | Full access | Self-hosted = you control | Not possible |
| AI training risk | Yes (Gemini) | No | No |
| Metadata exposure | Full to Google | Self-controlled | Minimal |
| Open source | No | Yes (Synapse) | Yes (AGPL-3.0) |

**Bottom line**: Google Chat is appropriate for organizations already committed to Google Workspace where convenience outweighs privacy concerns. For sensitive communications, prefer Matrix (self-hosted) or SimpleX.

### Bot-Specific Security

1. **Token verification**: Always verify Google's bearer tokens on inbound requests (`verifyGoogleTokens: true`)
2. **Service account key**: Store with 600 permissions, never commit to git
3. **User allowlist**: Restrict bot access to specific users, not entire domain
4. **Prompt sanitization**: Treat all inbound messages as untrusted input — scan with `prompt-guard-helper.sh` before passing to AI
5. **Response filtering**: Scan outbound messages for credential patterns before sending
6. **Network**: Bot server should not be directly internet-accessible — use a reverse proxy (Caddy/Cloudflare) with TLS termination
7. **Logging**: Log all events for audit trail but redact sensitive content from logs

### Push Notifications

Google Chat uses Firebase Cloud Messaging (FCM) for push notifications on mobile devices. This means:

- Google's FCM infrastructure knows when a user receives a Chat notification
- Notification content may be visible to FCM (depending on notification type)
- This is standard for all Google Workspace mobile notifications

## Limitations

### 30-Second Response Window

Google Chat expects an HTTP response within 30 seconds. For longer tasks:

- Return an acknowledgment card immediately
- Post the full response asynchronously via the Chat API
- The async approach requires the `chat.bot` scope on the service account

### No Native Matterbridge Support

Google Chat is not supported as a native Matterbridge gateway. Bridging to other platforms requires:

- Custom API bridge using Matterbridge's REST API
- Or a separate relay bot that forwards messages between platforms

### Workspace Requirement

Google Chat bots require Google Workspace. They cannot be used with free Gmail accounts. This limits deployment to organizations with Workspace subscriptions.

### Card Rendering Differences

Card v2 rendering varies slightly between:

- Google Chat web (chat.google.com)
- Google Chat in Gmail sidebar
- Google Chat mobile apps
- Google Chat in Google Workspace apps

Test cards across all target platforms before deploying.

### Rate Limits

| Operation | Limit |
|-----------|-------|
| Incoming messages | 60 per minute per space |
| Outgoing messages (API) | 60 per minute per space |
| Card actions | 60 per minute per space |
| Spaces the bot can be in | 50,000 |

### Thread Limitations

- Threads are space-scoped — no cross-space threading
- Thread names are opaque strings assigned by Google
- Bot cannot create threads proactively — only reply to existing ones or start new top-level messages

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bot not receiving events | Verify public URL is accessible; check Chat API configuration |
| 401 Unauthorized | Verify service account key is valid; check `chat.bot` scope |
| Token verification fails | Ensure `verifyGoogleTokens` is true; check clock sync (JWT expiry) |
| Bot not visible to users | Check Chat app visibility settings in Google Cloud Console |
| Async messages not posting | Verify service account has `chat.bot` scope; check space name format |
| Cards not rendering | Validate Card v2 JSON structure; check for unsupported widget types |
| Rate limited | Reduce message frequency; implement exponential backoff |
| Bot removed from space | Check `REMOVED_FROM_SPACE` events in logs; re-add bot to space |

## Related

- `services/communications/matrix-bot.md` — Matrix bot for aidevops runner dispatch (self-hosted, E2E encrypted)
- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, no user identifiers)
- `services/communications/matterbridge.md` — Multi-platform chat bridge (40+ platforms)
- `tools/security/opsec.md` — Platform trust matrix, E2E status, metadata warnings
- `tools/security/prompt-injection-defender.md` — Prompt injection scanning for untrusted input
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- `scripts/runner-helper.sh` — Runner management
- Google Chat API docs: https://developers.google.com/workspace/chat/api/reference/rest
- Google Chat Card v2: https://developers.google.com/workspace/chat/api/reference/rest/v1/cards
- Google Workspace DPA: https://workspace.google.com/terms/dpa_terms.html
