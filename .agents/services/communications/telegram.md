---
description: Telegram Bot Integration — Bot API, grammY SDK (TypeScript/Bun), BotFather setup, long polling vs webhooks, group/DM access control, inline keyboards, forum topics, security model, Matterbridge native support, and aidevops dispatch integration
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

# Telegram Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

| Field | Value |
|-------|-------|
| **Type** | Cloud-based messaging with optional E2E (Secret Chats only — 1:1 mobile) |
| **License** | Client open-source (GPLv2); server proprietary and closed-source |
| **Bot API** | HTTP Bot API (`https://api.telegram.org/bot<token>/`) + grammY SDK |
| **grammY SDK** | TypeScript, MIT license, 4.5k+ stars, `grammy` on npm |
| **Protocol** | MTProto 2.0 |
| **Encryption** | Server-client by default; Secret Chats use E2E — NOT available for bots, groups, or channels |
| **Bot setup** | [@BotFather](https://t.me/BotFather) on Telegram |
| **Docs** | https://core.telegram.org/bots/api, https://grammy.dev/ |
| **File limits** | 50 MB download, 20 MB upload via Bot API; 2 GB via local Bot API server |
| **Rate limits** | ~30 msg/s globally, 1 msg/s per chat (group: 20/min) |

**Platform comparison**:

| Criterion | Telegram | Signal/SimpleX | Slack/Discord |
|-----------|----------|-----------------|---------------|
| Default E2E | No (server-client only) | Yes | No |
| Bot E2E | No | N/A (Signal) / Yes (SimpleX) | No |
| Server code | Proprietary | Open-source | Proprietary |
| Metadata visible | All | Minimal/None | All |
| Phone required | Yes | Yes/No | No |
| Best for | Public bots, large communities | Maximum privacy | Team workspaces |

**Key differentiator**: Most feature-rich bot platform among mainstream messengers — inline keyboards, inline queries, payments, games, forum topics, web apps. All bot messages are server-side accessible (no E2E for bots).

<!-- AI-CONTEXT-END -->

## Architecture

```text
Telegram Apps (iOS/Android/Desktop/Web)
    │ MTProto 2.0 (server-client encrypted)
    ▼
Telegram Cloud Servers (proprietary; messages stored server-side)
    │ HTTPS Bot API  https://api.telegram.org/bot<token>/
    ▼
grammY Bot Process (TypeScript/Bun)
    ├─ Long polling / Webhook
    ├─ Command router + inline keyboard handler
    ├─ Conversation middleware + file handler
    └─ aidevops dispatch
```

**Important**: Telegram servers have full access to all message content (except Secret Chats). The Bot API is an HTTP wrapper — the bot never connects directly via MTProto.

## Installation

```bash
bun add grammy                    # recommended for aidevops
npm install grammy                # alternative
```

### BotFather Setup

1. Open Telegram → search `@BotFather` → send `/newbot`
2. Choose a display name and username (must end in `bot`)
3. BotFather returns an API token (`<bot-id>:<auth-token>`)
4. Store the token securely (see [Security](#security))

Key BotFather commands: `/newbot`, `/setcommands`, `/setprivacy`, `/mybots`, `/token` (regenerate), `/deletebot`.

**Group privacy mode**: By default, bots only receive commands and direct replies. To receive ALL group messages, disable privacy mode via `/setprivacy` in BotFather.

## Bot API Integration

### Basic Bot Setup (grammY + Bun)

```typescript
import { Bot, Context } from "grammy";

const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) throw new Error("TELEGRAM_BOT_TOKEN not set");

const bot = new Bot(token);

bot.command("start", (ctx) => ctx.reply("Welcome! Use /help for commands."));
bot.command("help", (ctx) => ctx.reply("/status — System status\n/ask <q> — Ask AI\n/run <cmd> — Run (admin only)"));
bot.command("status", async (ctx) => { await ctx.reply("Checking..."); });

bot.on("message:text", (ctx) => {
  // Only fires if privacy mode is disabled (groups) or in DMs
  console.log(`Message from ${ctx.from?.id}: ${ctx.message.text}`);
});

bot.catch((err) => console.error("Bot error:", err));
bot.start();
```

Run with: `bun run bot.ts`

### Long Polling vs Webhooks

| Aspect | Long Polling | Webhooks |
|--------|-------------|----------|
| Setup | Zero config, works behind NAT | Requires public HTTPS URL |
| Latency | ~300ms | Near-instant |
| Scaling | Single instance | Multiple instances OK |
| Best for | Local dev | Production |

```typescript
// Long polling (default)
bot.start();

// Webhooks (production) — allowed ports: 443, 80, 88, 8443
import { webhookCallback } from "grammy";
Bun.serve({ port: 8443, fetch: webhookCallback(bot, "bun") });
// await bot.api.setWebhook("https://bot.example.com/webhook");
```

### Inline Keyboards

```typescript
import { InlineKeyboard } from "grammy";

bot.command("menu", async (ctx) => {
  const keyboard = new InlineKeyboard()
    .text("System Status", "cb:status").text("Run Task", "cb:run")
    .row().text("View Logs", "cb:logs").url("Docs", "https://example.com/docs");
  await ctx.reply("Choose an action:", { reply_markup: keyboard });
});

bot.callbackQuery("cb:status", async (ctx) => {
  await ctx.answerCallbackQuery({ text: "Checking..." });
  await ctx.editMessageText("System is operational.");
});
```

### Key Features

| Feature | Description |
|---------|-------------|
| Commands | `/command` — auto-suggested in command menu |
| Inline keyboards | Buttons attached to messages (callback queries) |
| Inline mode | Bot results in any chat via `@botname query` |
| Forum topics | Thread-based discussions in supergroups |
| Files | Documents, photos, videos, audio (see limits) |
| Payments | Built-in payment processing |
| Web Apps | Mini apps embedded in Telegram UI |
| Reactions | Message reactions (emoji or custom) |

### Forum Topics

```typescript
// Send to a specific forum topic
await bot.api.sendMessage(chatId, "Message in topic", { message_thread_id: topicId });

// Create a new topic
const topic = await bot.api.createForumTopic(chatId, "New Topic", { icon_color: 0x6FB9F0 });
```

### DM vs Group Access Control

```typescript
import { Context } from "grammy";

const isDM = (ctx: Context) => ctx.chat?.type === "private";
const isGroup = (ctx: Context) => ctx.chat?.type === "group" || ctx.chat?.type === "supergroup";

async function adminOnly(ctx: Context, next: () => Promise<void>) {
  const adminIds = (process.env.TELEGRAM_ADMIN_IDS ?? "").split(",").map(Number);
  if (!ctx.from || !adminIds.includes(ctx.from.id)) {
    await ctx.reply("Unauthorized.");
    return;
  }
  await next();
}

bot.command("run", adminOnly, async (ctx) => {
  await ctx.reply(`Running: ${ctx.match}`);
});

bot.command("config", async (ctx) => {
  if (!isDM(ctx)) { await ctx.reply("DMs only."); return; }
  // Show config options
});
```

### Conversations (Multi-Step Interactions)

```bash
bun add @grammyjs/conversations
```

```typescript
import { conversations, createConversation } from "@grammyjs/conversations";
import type { Conversation, ConversationFlavor } from "@grammyjs/conversations";

type BotContext = Context & ConversationFlavor;

async function askQuestion(conversation: Conversation<BotContext>, ctx: BotContext) {
  await ctx.reply("What would you like to ask?");
  const response = await conversation.wait();
  const question = response.message?.text;
  if (!question) { await ctx.reply("Please send text."); return; }
  await ctx.reply(`Processing: "${question}"...`);
}

bot.use(conversations());
bot.use(createConversation(askQuestion));
bot.command("ask", async (ctx) => ctx.conversation.enter("askQuestion"));
```

## Security

### Encryption Model

**Server-client encryption only (by default)**. Messages are stored on Telegram's servers and accessible to Telegram in plaintext.

**Secret Chats** provide E2E (MTProto 2.0 + DH key exchange), but:
- Only for 1:1 chats on mobile apps
- NOT available for bots, groups, channels, Desktop (except macOS native), or Web
- Device-specific (not synced across devices)

**For bot integrations**: All bot messages are transmitted and stored without E2E. Telegram can technically read every message a bot sends or receives.

### Metadata Exposure

Telegram servers have access to: social graph, message timestamps, group memberships, IP addresses, phone numbers, device info, online status, and shared location data.

### Server Access

Telegram (Dubai, UAE) has **full access to all non-Secret-Chat messages**. The server code is **completely proprietary and closed-source** — no independent audit of server-side data handling exists. Telegram has disclosed user data (IP addresses, phone numbers) to authorities in some cases. In 2024, Telegram updated its privacy policy to clarify law enforcement cooperation.

### Bot-Specific Security

- **Bots CANNOT use Secret Chats** — all bot communication is server-accessible
- **Bot tokens grant full access** to all messages the bot receives — treat as critical secrets
- **Bot tokens in URLs** — token is part of every API call URL; ensure HTTPS and log sanitization
- **Group bots** — if privacy mode is disabled, bot receives ALL group messages
- **Webhook security** — verify `X-Telegram-Bot-Api-Secret-Token` header; use a secret path
- **File access** — files uploaded to Telegram can be downloaded by anyone with the `file_id`

### Token Management

```bash
# Store via aidevops secret management (gopass)
gopass insert aidevops/telegram/bot-token

# Or via credentials.sh (600 permissions)
echo 'export TELEGRAM_BOT_TOKEN="<your-token>"' >> ~/.config/aidevops/credentials.sh

# NEVER commit tokens to git, log them, or pass as CLI arguments
# Regenerate via @BotFather /token if compromised
```

## aidevops Integration

### Components

| Component | File | Purpose |
|-----------|------|---------|
| Subagent doc | `.agents/services/communications/telegram.md` | This file |
| Helper script | `.agents/scripts/telegram-dispatch-helper.sh` | Bot lifecycle management |
| Config | `~/.config/aidevops/telegram-bot.json` | Bot configuration |

### Helper Script

```bash
telegram-dispatch-helper.sh setup    # configure bot token and chat mappings
telegram-dispatch-helper.sh start    # launch bot process
telegram-dispatch-helper.sh stop     # gracefully stop
telegram-dispatch-helper.sh status   # check health
telegram-dispatch-helper.sh map <telegram_chat_id> <entity_type> <entity_id>
telegram-dispatch-helper.sh unmap <telegram_chat_id>
```

### Runner Dispatch

```typescript
bot.command("run", adminOnly, async (ctx) => {
  const command = ctx.match;
  if (!command) { await ctx.reply("Usage: /run <command>"); return; }
  await ctx.reply(`Dispatching: ${command}`);
  const proc = Bun.spawn(
    ["runner-helper.sh", "dispatch", command],  // array args prevent injection
    { stdout: "pipe", stderr: "pipe", signal: AbortSignal.timeout(600_000), env: { ...process.env, RUNNER_TIMEOUT: "600" } }
  );
  const output = await new Response(proc.stdout).text();
  await ctx.reply(`Result:\n\`\`\`\n${output.slice(0, 4000)}\n\`\`\``);
});
```

### Entity Resolution

```bash
entity-helper.sh resolve telegram:-1001234567890   # → project:myproject
entity-helper.sh lookup project:myproject telegram  # → -1001234567890
```

### Configuration

`~/.config/aidevops/telegram-bot.json`:

```json
{
  "token_source": "gopass:aidevops/telegram/bot-token",
  "mode": "polling",
  "webhook_url": null,
  "webhook_port": 8443,
  "admin_ids": [123456789],
  "allowed_chats": [-1001234567890],
  "entity_mappings": {
    "-1001234567890": {
      "type": "project",
      "id": "myproject",
      "commands": ["status", "run", "ask"]
    }
  },
  "features": { "inline_mode": false, "forum_topics": false, "file_handling": true }
}
```

## Matterbridge Integration

Telegram has **native support** in Matterbridge — no adapter required.

### Configuration

```toml
[telegram]
  [telegram.main]
  Token="YOUR_BOT_TOKEN"
  # MessageFormat="HTMLNick"

[[gateway]]
name="project-bridge"
enable=true

  [[gateway.inout]]
  account="telegram.main"
  channel="-1001234567890"  # Supergroup chat ID (negative number)

  [[gateway.inout]]
  account="matrix.home"
  channel="#project:example.com"
```

**Getting the chat ID**: Add `@userinfobot` or `@getidsbot` to the group — it replies with the chat ID. Supergroup IDs are negative and start with `-100`. Alternatively, check `getUpdates` after sending a message.

**Bot requirements**: Add to group, disable privacy mode (`/setprivacy` → Disabled), grant send permission.

### Bridging Limitations

| Limitation | Detail |
|------------|--------|
| Formatting | Telegram HTML/Markdown may not render identically on other platforms |
| File size | Bot API: 20 MB upload, 50 MB download — larger files won't bridge |
| Stickers | Bridged as PNG — animation lost |
| Reactions | Not bridged by default |
| Threads/Topics | Forum topics may not map to other platforms' thread models |
| Edits/Deletions | May not propagate across all platforms |

## Limitations

### File Size Limits

| Operation | Bot API | Local Bot API Server |
|-----------|---------|---------------------|
| Download | 50 MB | 2 GB |
| Upload | 20 MB | 2 GB |

The [Local Bot API Server](https://github.com/tdlib/telegram-bot-api) can be self-hosted to raise limits to 2 GB:

```bash
git clone --recursive https://github.com/tdlib/telegram-bot-api.git
cd telegram-bot-api && mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release .. && cmake --build . --target install
telegram-bot-api --api-id=YOUR_API_ID --api-hash=YOUR_API_HASH --local
```

### Rate Limits

| Scope | Limit |
|-------|-------|
| Global | ~30 msg/s |
| Per chat (private) | 1 msg/s |
| Per chat (group) | 20 msg/min |
| Inline query results | 50 per query |

```bash
bun add @grammyjs/auto-retry @grammyjs/transformer-throttler
```

```typescript
import { autoRetry } from "@grammyjs/auto-retry";
import { apiThrottler } from "@grammyjs/transformer-throttler";
bot.api.config.use(autoRetry());
bot.api.config.use(apiThrottler());
```

### Other Limitations

- **No E2E for bots** — all bot communication is server-accessible; no workaround. Use SimpleX/Signal if E2E required.
- **Phone number required** — every account requires a phone number (SIM-swap risk; users can hide it from others but Telegram always has it)
- **Unofficial API risks** — MTProto userbots (Telethon, Pyrogram, GramJS) violate ToS, risk account ban, and may trigger flood waits. Always use the official Bot API.
- **No message scheduling** — bots cannot schedule future delivery
- **No voice/video calls** — bots cannot initiate or receive calls
- **No message search** — Bot API has no search; bots must maintain their own index
- **No message history** — bots cannot access messages sent before they joined a group
- **Channel posting** — bots can post to channels but cannot read channel messages unless channel admin

## Related

- `.agents/services/communications/simplex.md` — SimpleX Chat (maximum privacy, E2E, no identifiers)
- `.agents/services/communications/matrix-bot.md` — Matrix messaging (federated, self-hostable)
- `.agents/services/communications/matterbridge.md` — Multi-platform chat bridge (Telegram native support)
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/credentials/gopass.md` — Secure credential storage
- grammY docs: https://grammy.dev/
- Telegram Bot API: https://core.telegram.org/bots/api
- Local Bot API Server: https://github.com/tdlib/telegram-bot-api
- Matterbridge: https://github.com/42wim/matterbridge
