---
description: Slack Bot integration — Bolt SDK setup, Socket Mode, slash commands, interactive components, Agents API, security (no E2E, AI training), Matterbridge, aidevops dispatch
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

# Slack Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Corporate messaging — no E2E encryption, workspace admin has full access
- **License**: Proprietary (Salesforce). Bot SDK: `@slack/bolt` (MIT)
- **Script**: `slack-dispatch-helper.sh [setup|start|stop|status|map|unmap|mappings|test|logs]`
- **Config**: `~/.config/aidevops/slack-bot.json` (600 perms)
- **Docs**: https://api.slack.com/docs | https://slack.dev/bolt-js/ | https://api.slack.com/apps
- **Flow**: Slack → Socket Mode → Bolt App → `runner-helper.sh` → AI session → `memory.db`. Per-message: access control → channel-runner lookup → entity resolution → Layer 0 log → dispatch → thread reply → reaction (eyes → ✓/✗).

```bash
slack-dispatch-helper.sh setup && slack-dispatch-helper.sh map C04ABCDEF general-assistant && slack-dispatch-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Installation

https://api.slack.com/apps → **Create New App** → **From an app manifest**. Bot scopes: `app_mentions:read channels:history channels:read chat:write commands files:read files:write groups:history groups:read im:history im:read im:write reactions:read reactions:write users:read`. Enable Socket Mode, interactivity, `/ai` slash command. **Socket Mode** (recommended): no public URL, `xapp-` token, firewall-friendly. **Events API**: public URL + signing secret, for public apps at scale. Tokens: **Bot** (`xoxb-...`) OAuth & Permissions > Install to Workspace. **App-Level** (`xapp-...`) Basic Information > App-Level Tokens > `connections:write`. **Signing Secret** Basic Information > App Credentials (Events API only).

```bash
gopass insert aidevops/slack/bot-token && gopass insert aidevops/slack/app-token && gopass insert aidevops/slack/signing-secret
bun add @slack/bolt   # or: npm install @slack/bolt
```

## Bot API

```typescript
import { App } from "@slack/bolt";
const app = new App({ token: process.env.SLACK_BOT_TOKEN, appToken: process.env.SLACK_APP_TOKEN, socketMode: true });
const react = (ch: string, ts: string, n: string) => app.client.reactions.add({ channel: ch, timestamp: ts, name: n });
// Mentions
app.event("app_mention", async ({ event, say }) => {
  const prompt = event.text.replace(/<@[A-Z0-9]+>/g, "").trim();
  if (!prompt) { await say({ text: "Send me a prompt!", thread_ts: event.ts }); return; }
  react(event.channel, event.ts, "eyes");
  try {
    await say({ text: await dispatchToRunner(prompt, event.user, event.channel), thread_ts: event.ts });
    await app.client.reactions.remove({ channel: event.channel, timestamp: event.ts, name: "eyes" });
    react(event.channel, event.ts, "white_check_mark");
  } catch (e) { await say({ text: `Error: ${e.message}`, thread_ts: event.ts }); react(event.channel, event.ts, "x"); }
});
// DMs: channel_type === "im" && !event.subtype → dispatchToRunner(event.text, ...)
// Slash — ack within 3s
app.command("/ai", async ({ command, ack, respond }) => { await ack();
  await respond({ response_type: "ephemeral", text: "Processing..." });
  await respond({ response_type: "in_channel", text: await dispatchToRunner(command.text, command.user_id, command.channel_id) }); });
// Buttons: chat.postMessage with blocks[type:actions, elements:[{type:button, action_id, value}]]; app.action(id, async({ack,respond})=>{await ack();...})
// Thread: chat.postMessage({thread_ts:parentTs}); broadcast: add reply_broadcast:true; file: files.uploadV2({channel_id, filename, content, title})
(async () => { await app.start(); })();
```

**Agents API (beta)** — requires `assistant` scope. Events: `assistant_thread_started`, `assistant_thread_context_changed`. Docs: https://api.slack.com/docs/apps/ai. **Access control**: Use `Set<string>` for `ALLOWED_CHANNELS` / `ALLOWED_USERS` (empty = allow all). Gate: `(!ALLOWED_CHANNELS.size || ALLOWED_CHANNELS.has(ch)) && (!ALLOWED_USERS.size || ALLOWED_USERS.has(u))`.

## Security

**CRITICAL: Slack is among the least private mainstream messaging platforms.**
- **No E2E encryption**: Salesforce has full access to all content — channels, DMs, files, edits, deleted messages.
- **AI training** (Sep 2023): customer data trains ML models unless admin opts out. **Assume all messages may train AI models.**
- **Push notifications**: Google FCM / Apple APNs — default previews visible to Google/Apple in transit. **Jurisdiction**: Salesforce, Inc., San Francisco CA — CLOUD Act, FISA §702, NSLs. EU Data Residency (Enterprise Grid) controls storage, not Salesforce personnel access.
- **Admin export**: Free/Pro = public channels only. Business+ = ALL messages, no notification. Enterprise Grid = full exports + DLP, audit logs, eDiscovery, legal holds.
- **Token security**: `xoxb-` accesses all bot channels; `xapp-` has workspace-wide scope. Enable rotation for production; verify `X-Slack-Signature` on Events API requests.
- **Use where corporate oversight is expected. Never for sensitive personal, legal, or confidential matters.**

| | Slack | Matrix | SimpleX | Signal |
|--|-------|--------|---------|--------|
| E2E encryption | No | Yes | Yes | Yes |
| Server access | Full | None | None | None |
| Admin export | All plans | Admin only | N/A | No |
| AI training | Opt-out req. | No | No | No |
| Self-hostable | No | Yes | Yes | No |
| Jurisdiction | USA (Salesforce) | Self | Self | USA |

## aidevops Integration

```bash
slack-dispatch-helper.sh setup                       # Interactive wizard
slack-dispatch-helper.sh map C04ABCDEF code-reviewer # Map channel → runner; mappings to list; unmap to remove
slack-dispatch-helper.sh start --daemon | stop | status | logs [--follow]
slack-dispatch-helper.sh test code-reviewer "Review src/auth.ts"
```

**Runner dispatch**: `runner-helper.sh` handles headless sessions, memory isolation, entity-aware context, run logging. Entity resolution: Slack user ID → `entity_channels` → entity profile. New users via `entity-helper.sh create`; enriched via `users.info`. **Config** `~/.config/aidevops/slack-bot.json` (600 perms) — store tokens in gopass. `botPrefix` empty = `@mention`/slash commands only; set (e.g., `!ai`) for prefix triggering.

```json
{
  "botToken": "stored-in-gopass", "appToken": "stored-in-gopass", "signingSecret": "stored-in-gopass",
  "socketMode": true, "allowedChannels": ["C04ABCDEF", "C04GHIJKL"], "allowedUsers": [],
  "defaultRunner": "", "channelMappings": { "C04ABCDEF": "code-reviewer", "C04GHIJKL": "seo-analyst" },
  "botPrefix": "", "ignoreOwnMessages": true, "maxPromptLength": 3000, "responseTimeout": 600, "sessionIdleTimeout": 300
}
```

## Matterbridge + Limits

Slack stanza for `matterbridge.toml`: `[slack.myworkspace]` with `Token = "xoxb-..."` and `ShowJoinPart = false`. Wire to a `[[gateway.inout]]` block. Full config: `services/communications/matterbridge.md`. **Warning**: Bridging to E2E-encrypted platforms stores messages unencrypted on Slack's servers. Inform users.

| Constraint | Value |
|-----------|-------|
| Web API / `chat.postMessage` | 1 req/sec per method / 1/sec per channel |
| Socket Mode events / connections | 30,000/hour / 10 concurrent per app |
| Files API | 20/min |
| Free: history / integrations / storage | 90 days / 10 apps / 5 GB |
| Self-hosting | Not available (SaaS only). Bolt handles retries. Alternatives: Mattermost, Matrix, Rocket.Chat |

## Related

- `services/communications/matrix-bot.md` | `simplex.md` | `matterbridge.md`
- `scripts/entity-helper.sh` | `scripts/runner-helper.sh` | `tools/security/opsec.md`
- Slack Bolt SDK: https://slack.dev/bolt-js/ | API: https://api.slack.com/ | Agents API: https://api.slack.com/docs/apps/ai
- Privacy Policy: https://slack.com/trust/privacy/privacy-policy
