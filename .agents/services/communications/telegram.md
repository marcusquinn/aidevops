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
| **Encryption** | Server-client encryption by default; optional Secret Chats use E2E (MTProto 2.0 with DH key exchange) — Secret Chats NOT available for bots, groups, or channels |
| **Bot setup** | [@BotFather](https://t.me/BotFather) on Telegram |
| **Docs** | https://core.telegram.org/bots/api, https://grammy.dev/ |
| **File limits** | 50 MB download, 20 MB upload via Bot API; 2 GB via local Bot API server |
| **Rate limits** | ~30 messages/second globally, 1 message/second per chat (group: 20/minute) |

**Key differentiator**: Telegram's Bot API is the most feature-rich bot platform among mainstream messengers — inline keyboards, inline queries, payments, games, stickers, forum topics, reactions, web apps, and more. However, all bot messages are server-side accessible (no E2E for bots).

**When to use Telegram over other platforms**:

| Criterion | Telegram | Signal/SimpleX | Slack/Discord |
|-----------|----------|-----------------|---------------|
| Bot ecosystem | Very mature, HTTP API | Growing | Mature |
| E2E encryption | Optional (Secret Chats only, not bots) | Always-on | None |
| User identifiers | Phone number + username | Phone (Signal) / None (SimpleX) | Email |
| Self-hosting | Client only (server proprietary) | Full stack | No |
| Group scalability | 200,000 members | Experimental (1000+) | Limited |
| Best for | Public bots, large communities | Maximum privacy | Team workspaces |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────────┐
│ Telegram Mobile/Desktop   │
│ Apps (iOS, Android,       │
│ macOS, Windows, Linux,    │
│ Web)                      │
└──────────┬───────────────┘
           │ MTProto 2.0 (server-client encrypted)
           │
┌──────────▼───────────────┐
│ Telegram Cloud Servers    │
│ (proprietary, multi-DC,   │
│ messages stored server-   │
│ side in plaintext from    │
│ Telegram's perspective)   │
└──────────┬───────────────┘
           │ HTTPS Bot API
           │ https://api.telegram.org/bot<token>/
           │
┌──────────▼───────────────┐
│ grammY Bot Process        │
│ (TypeScript/Bun)          │
│                           │
│ ├─ Long polling / Webhook │
│ ├─ Command router         │
│ ├─ Inline keyboard handler│
│ ├─ Conversation middleware│
│ ├─ File handler           │
│ └─ aidevops dispatch      │
└───────────────────────────┘
```

**Message flow**:

1. User sends message in Telegram app → MTProto 2.0 to Telegram servers
2. Telegram servers store the message and route to recipients
3. If message is directed at a bot (or bot is in a group), Telegram queues an Update
4. Bot retrieves Updates via long polling (`getUpdates`) or receives them via webhook
5. grammY processes the Update, runs middleware chain, executes handlers
6. Bot responds via HTTP POST to Bot API → Telegram servers → user's app

**Important**: Telegram servers have full access to all message content (except Secret Chats). The Bot API is an HTTP wrapper around Telegram's internal MTProto — the bot never connects directly via MTProto.

## Installation

### grammY SDK (TypeScript/Bun)

```bash
# Using bun (recommended for aidevops)
bun add grammy

# Using npm
npm install grammy

# Using deno
# import { Bot } from "https://deno.land/x/grammy/mod.ts";
```

### BotFather Setup

1. Open Telegram and search for `@BotFather`
2. Send `/newbot` and follow the prompts
3. Choose a name (display name) and username (must end in `bot`)
4. BotFather returns an API token (format: `<bot-id>:<auth-token>`, e.g. `123456789:YOUR-TOKEN-FROM-BOTFATHER`)
5. Store the token securely (see [Security Considerations](#security-considerations))

**BotFather commands**:

| Command | Description |
|---------|-------------|
| `/newbot` | Create a new bot |
| `/setcommands` | Set bot command menu |
| `/setdescription` | Set bot description (shown in profile) |
| `/setabouttext` | Set "About" text |
| `/setuserpic` | Set bot profile photo |
| `/setinline` | Enable inline mode |
| `/setjoingroups` | Allow/disallow adding to groups |
| `/setprivacy` | Toggle group privacy mode |
| `/mybots` | List and manage your bots |
| `/deletebot` | Delete a bot |
| `/token` | Regenerate API token |

**Group privacy mode** (important): By default, bots in groups only receive messages that are commands (`/command`) or direct replies to the bot. To receive ALL group messages, disable privacy mode via `/setprivacy` in BotFather. This is required for bots that need to monitor all conversation.

## Bot API Integration

### Basic Bot Setup (grammY + Bun)

```typescript
import { Bot, Context } from "grammy";

// Load token from secure storage — NEVER hardcode
const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) throw new Error("TELEGRAM_BOT_TOKEN not set");

const bot = new Bot(token);

// Command handlers
bot.command("start", (ctx) =>
  ctx.reply("Welcome! I'm an aidevops bot. Use /help for commands.")
);

bot.command("help", (ctx) =>
  ctx.reply(
    "Available commands:\n" +
    "/status — System status\n" +
    "/ask <question> — Ask AI\n" +
    "/run <command> — Run a command (admin only)\n" +
    "/help — Show this help"
  )
);

bot.command("status", async (ctx) => {
  await ctx.reply("Checking status...");
  // Dispatch to aidevops runner
});

// Text message handler (non-command messages)
bot.on("message:text", (ctx) => {
  // Only fires if privacy mode is disabled (for groups)
  // or in DMs
  console.log(`Message from ${ctx.from?.id}: ${ctx.message.text}`);
});

// Error handler
bot.catch((err) => {
  console.error("Bot error:", err);
});

// Start with long polling
bot.start();
console.log("Bot started (long polling)");
```

Run with: `bun run bot.ts`

### Long Polling vs Webhooks

| Aspect | Long Polling | Webhooks |
|--------|-------------|----------|
| Setup | Zero config, works behind NAT | Requires public HTTPS URL |
| Latency | ~300ms (poll interval) | Near-instant |
| Scaling | Single instance only | Multiple instances OK |
| Development | Best for local dev | Best for production |
| Reliability | Handles reconnects automatically | Must handle failures |

**Long polling** (development / simple deployments):

```typescript
// Default — grammY handles everything
bot.start();
```

**Webhooks** (production):

```typescript
import { webhookCallback } from "grammy";

// With Bun's native HTTP server
Bun.serve({
  port: 8443,
  fetch: webhookCallback(bot, "bun"),
});

// Set webhook URL (run once)
// await bot.api.setWebhook("https://bot.example.com/webhook");
```

Webhook ports allowed by Telegram: 443, 80, 88, 8443.

### Inline Keyboards

```typescript
import { InlineKeyboard } from "grammy";

bot.command("menu", async (ctx) => {
  const keyboard = new InlineKeyboard()
    .text("System Status", "cb:status")
    .text("Run Task", "cb:run")
    .row()
    .text("View Logs", "cb:logs")
    .url("Documentation", "https://example.com/docs");

  await ctx.reply("Choose an action:", { reply_markup: keyboard });
});

// Handle callback queries from inline keyboard
bot.callbackQuery("cb:status", async (ctx) => {
  await ctx.answerCallbackQuery({ text: "Checking..." });
  await ctx.editMessageText("System is operational.");
});

bot.callbackQuery("cb:run", async (ctx) => {
  await ctx.answerCallbackQuery();
  await ctx.editMessageText("What would you like to run?");
});
```

### Key Features

| Feature | API Method / Description |
|---------|--------------------------|
| **Commands** | `/command` — auto-suggested in command menu |
| **Inline keyboards** | Buttons attached to messages (callback queries) |
| **Reply keyboards** | Custom keyboard replacing the default one |
| **Inline mode** | Bot results in any chat via `@botname query` |
| **Stickers** | Send/receive sticker packs |
| **Voice messages** | Send/receive OGG Opus audio |
| **Files** | Documents, photos, videos, audio (see limits) |
| **Forum topics** | Thread-based discussions in supergroups |
| **Reactions** | Message reactions (emoji or custom) |
| **Payments** | Built-in payment processing |
| **Web Apps** | Mini apps embedded in Telegram UI |
| **Polls** | Create and manage polls |
| **Location** | Share and receive live locations |
| **Dice** | Animated randomized emoji (dice, darts, etc.) |

### Forum Topics

Telegram supergroups can enable "Topics" — thread-based discussions. Bots can create, manage, and post to specific topics:

```typescript
// Send to a specific forum topic
await bot.api.sendMessage(chatId, "Message in topic", {
  message_thread_id: topicId,
});

// Create a new topic
const topic = await bot.api.createForumTopic(chatId, "New Topic", {
  icon_color: 0x6FB9F0,
});
```

### DM vs Group Access Control

```typescript
import { Context } from "grammy";

// Check if message is from a private chat (DM)
function isDM(ctx: Context): boolean {
  return ctx.chat?.type === "private";
}

// Check if message is from a group
function isGroup(ctx: Context): boolean {
  return ctx.chat?.type === "group" || ctx.chat?.type === "supergroup";
}

// Admin-only middleware
async function adminOnly(ctx: Context, next: () => Promise<void>) {
  const adminIds = (process.env.TELEGRAM_ADMIN_IDS ?? "").split(",").map(Number);
  if (!ctx.from || !adminIds.includes(ctx.from.id)) {
    await ctx.reply("Unauthorized. This command requires admin access.");
    return;
  }
  await next();
}

// Apply to specific commands
bot.command("run", adminOnly, async (ctx) => {
  // Only admins reach here
  const command = ctx.match; // text after /run
  await ctx.reply(`Running: ${command}`);
});

// DM-only commands
bot.command("config", async (ctx) => {
  if (!isDM(ctx)) {
    await ctx.reply("This command is only available in DMs.");
    return;
  }
  // Show config options
});
```

### Conversations (Multi-Step Interactions)

grammY provides the `conversations` plugin for multi-step interactions:

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
  if (!question) {
    await ctx.reply("Please send a text message.");
    return;
  }
  await ctx.reply(`Processing: "${question}"...`);
  // Dispatch to AI
}

bot.use(conversations());
bot.use(createConversation(askQuestion));
bot.command("ask", async (ctx) => {
  await ctx.conversation.enter("askQuestion");
});
```

## Security Considerations

### Encryption Model

**Server-client encryption only (by default)**. Telegram uses MTProto 2.0 for transport encryption between the app and Telegram's servers. However, messages are stored on Telegram's servers and are accessible to Telegram in plaintext.

**Secret Chats** provide E2E encryption using MTProto 2.0 with Diffie-Hellman key exchange, but with critical limitations:

- Only available for 1:1 chats on mobile apps
- NOT available for bots
- NOT available for groups or channels
- NOT available on Telegram Desktop (except macOS native app)
- NOT available on Telegram Web
- Messages are device-specific (not synced across devices)

**For bot integrations**: All bot messages are transmitted and stored without E2E encryption. Telegram (the company) can technically read every message a bot sends or receives.

### Metadata Exposure

Telegram servers have access to comprehensive metadata:

- **Who messages whom** — full social graph of all conversations
- **When** — timestamps of all messages
- **Group memberships** — every group a user belongs to
- **IP addresses** — connection IPs (unless using Tor/VPN)
- **Phone numbers** — required for registration, linked to account
- **Device information** — app version, device model, OS
- **Online status** — last seen timestamps (unless hidden by user)
- **Location data** — if shared via live location or nearby features

### Server Access

Telegram (the company) has **full access to all non-Secret-Chat messages**. Their privacy policy states they do not use message data for advertising, and they claim not to read messages. However:

- The server code is **completely proprietary and closed-source**
- No independent security audit of server-side data handling exists
- Telegram employees with server access could technically read messages
- Law enforcement requests could compel data disclosure (see Jurisdiction below)
- Telegram has disclosed user data to authorities in some cases (IP addresses, phone numbers)

### Push Notifications

- **Android**: Via Firebase Cloud Messaging (FCM / Google) — notification metadata visible to Google
- **iOS**: Via Apple Push Notification Service (APNs) — notification metadata visible to Apple
- Notification content is encrypted, but the fact that a notification was sent (timing, sender) is visible to Google/Apple

### AI and Data Processing

As of 2025, Telegram has introduced several AI-powered features:

- Message translation
- AI-generated profile photos (Premium)
- AI chatbot features (Telegram Premium)
- Story and media AI enhancements

It is **unclear what data these features process** and whether chat content is used for AI training. Telegram's privacy policy does not explicitly address AI training on user data. Users should assume that messages processed by AI features may be sent to third-party AI providers.

### Open Source Status

- **Client apps**: Open-source under GPLv2 (iOS, Android, Desktop, Web)
- **Server**: Completely **proprietary and closed-source**
- **Bot API server**: Open-source ([tdlib/telegram-bot-api](https://github.com/tdlib/telegram-bot-api)) — can be self-hosted for higher file limits
- **TDLib**: Core client library is open-source (Boost Software License)

The proprietary server means there is **no way to independently verify** what happens to messages on Telegram's infrastructure.

### Jurisdiction

- Telegram FZ-LLC is registered in **Dubai, UAE**
- Previously based in various jurisdictions (Russia, UK, Singapore)
- Has historically resisted government data requests (notably Russia)
- However, legal frameworks are evolving — UAE, EU (DSA), and other jurisdictions may compel data disclosure
- In 2024, Telegram's CEO was detained in France related to platform moderation obligations
- Telegram updated its privacy policy in late 2024 to clarify cooperation with law enforcement

### Bot-Specific Security

- **Bots CANNOT use Secret Chats** — all bot communication is server-accessible
- **Bot tokens grant full access** to all messages the bot receives — treat tokens as critical secrets
- **Bot tokens in URLs** — the token is part of every API call URL; ensure HTTPS and log sanitization
- **Group bots** — if privacy mode is disabled, the bot receives ALL messages in the group
- **Inline bots** — can receive queries from any user in any chat
- **Webhook security** — verify the `X-Telegram-Bot-Api-Secret-Token` header; use a secret path
- **File access** — files uploaded to Telegram can be downloaded by anyone with the `file_id` (not truly private)

### Token Management

```bash
# Store token via aidevops secret management (gopass)
gopass insert aidevops/telegram/bot-token

# Or via credentials.sh (600 permissions)
echo 'export TELEGRAM_BOT_TOKEN="<your-token>"' >> ~/.config/aidevops/credentials.sh

# NEVER commit tokens to git
# NEVER log tokens in output
# NEVER pass tokens as CLI arguments (visible in process list)
# Regenerate via @BotFather /token if compromised
```

### Comparison with Other Platforms

| Aspect | Telegram | Signal | SimpleX | Slack/Discord |
|--------|----------|--------|---------|---------------|
| Default E2E | No (server-client only) | Yes | Yes | No |
| Bot E2E | No | N/A | Yes | No |
| Server code | Proprietary | Open-source | Open-source | Proprietary |
| Metadata visible to server | All | Minimal | None | All |
| Phone required | Yes | Yes | No | No (email) |
| Data location | Dubai (UAE) | USA | User-chosen | USA |
| Independent audit | Client only | Full stack | Full stack | No |

**Summary**: Telegram is **less private** than Signal/SimpleX (no default E2E, proprietary server, full metadata access), but **more private** than Slack/Discord/Teams (at least offers optional E2E for 1:1, client is open-source, no ads-driven data mining). For aidevops bot integrations, assume **all bot messages are readable by Telegram**.

## aidevops Integration

### Components

| Component | File | Purpose |
|-----------|------|---------|
| Subagent doc | `.agents/services/communications/telegram.md` | This file |
| Helper script | `.agents/scripts/telegram-dispatch-helper.sh` | Bot lifecycle management |
| Config | `~/.config/aidevops/telegram-bot.json` | Bot configuration |

### Helper Script Pattern

`telegram-dispatch-helper.sh` follows the standard aidevops helper pattern:

```bash
# Setup — configure bot token and default chat mappings
telegram-dispatch-helper.sh setup

# Start — launch the bot process (long polling or webhook)
telegram-dispatch-helper.sh start

# Stop — gracefully stop the bot process
telegram-dispatch-helper.sh stop

# Status — check if bot is running and healthy
telegram-dispatch-helper.sh status

# Map — associate a Telegram chat/group with an aidevops entity
telegram-dispatch-helper.sh map <telegram_chat_id> <entity_type> <entity_id>
# Example: telegram-dispatch-helper.sh map -1001234567890 project myproject

# Unmap — remove a chat-entity association
telegram-dispatch-helper.sh unmap <telegram_chat_id>
```

### Runner Dispatch

Bot messages can trigger aidevops runner dispatch via `runner-helper.sh`:

```typescript
// In bot command handler
bot.command("run", adminOnly, async (ctx) => {
  const command = ctx.match;
  if (!command) {
    await ctx.reply("Usage: /run <command>");
    return;
  }

  await ctx.reply(`Dispatching: ${command}`);

  const signal = AbortSignal.timeout(600_000); // 10 minutes

  // Dispatch via runner-helper.sh (use array args to prevent command injection)
  const proc = Bun.spawn(
    ["runner-helper.sh", "dispatch", command],
    { stdout: "pipe", stderr: "pipe", signal, env: { ...process.env, RUNNER_TIMEOUT: "600" } }
  );
  const output = await new Response(proc.stdout).text();
  await ctx.reply(`Result:\n\`\`\`\n${output.slice(0, 4000)}\n\`\`\``);
});
```

### Entity Resolution

Use `entity-helper.sh` to resolve Telegram chats to aidevops entities:

```bash
# Resolve a Telegram chat ID to an aidevops project
entity-helper.sh resolve telegram:-1001234567890
# Returns: project:myproject

# Reverse lookup — find Telegram chat for an entity
entity-helper.sh lookup project:myproject telegram
# Returns: -1001234567890
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
  "features": {
    "inline_mode": false,
    "forum_topics": false,
    "file_handling": true
  }
}
```

## Matterbridge Integration

Telegram has **native support** in Matterbridge — no adapter required (unlike SimpleX which needs a separate bridge process).

### Configuration

In `matterbridge.toml`:

```toml
[telegram]
  [telegram.main]
  Token="YOUR_BOT_TOKEN"
  # Optional: use HTML or Markdown parse mode
  # MessageFormat="HTMLNick"
  # UseFirstName=false

[[gateway]]
name="project-bridge"
enable=true

  [[gateway.inout]]
  account="telegram.main"
  channel="-1001234567890"  # Supergroup chat ID (negative number)

  [[gateway.inout]]
  account="matrix.home"
  channel="#project:example.com"

  # Add other platforms as needed
  # [[gateway.inout]]
  # account="discord.myserver"
  # channel="project"
```

### Getting the Chat ID

1. Add `@userinfobot` or `@getidsbot` to the group
2. It will reply with the group's chat ID
3. For supergroups, the ID is negative and starts with `-100`
4. Alternatively, check the bot's `getUpdates` response after sending a message in the group

### Bridging Limitations

| Limitation | Detail |
|------------|--------|
| **Formatting** | Telegram HTML/Markdown may not render identically on other platforms |
| **File size** | Bot API limits: 20 MB upload, 50 MB download — files larger than this won't bridge |
| **Stickers** | Bridged as images (PNG) — animation lost |
| **Reactions** | Not bridged by default in most Matterbridge versions |
| **Threads/Topics** | Forum topics may not map to other platforms' thread models |
| **Edits** | Message edits are bridged as new messages on some platforms |
| **Deletions** | Message deletions may not propagate across all platforms |
| **Voice messages** | Bridged as audio files — no inline playback on some platforms |

### Bot Requirements for Bridging

The bot used for Matterbridge must:

1. Be added to the target group as a member
2. Have **privacy mode disabled** (via BotFather `/setprivacy` → Disabled) to see all messages
3. Have permission to send messages in the group

## Limitations

### No E2E Encryption for Bots

All bot communication is server-client encrypted only. Telegram (the company) can read all bot messages. There is no workaround — the Bot API is an HTTP interface that goes through Telegram's servers. If E2E is required, use SimpleX or Signal instead.

### Phone Number Required

Every Telegram account requires a phone number. This creates:

- A link between real-world identity and Telegram account
- Potential for SIM-swap attacks
- Privacy concerns for users who don't want to share phone numbers
- A barrier to anonymous bot usage

Users can hide their phone number from other users (Settings > Privacy > Phone Number), but Telegram always has it.

### Unofficial API Risks

Using unofficial client libraries that connect via MTProto directly (e.g., Telethon, Pyrogram, GramJS) to automate user accounts:

- **Violates Telegram ToS** — risk of account ban
- **Session hijacking risk** — MTProto sessions can be stolen
- **Rate limiting** — aggressive automation triggers flood waits
- **Legal risk** — may violate computer fraud laws in some jurisdictions

Always use the official Bot API for automation. User account automation ("userbots") is unsupported and risky.

### File Size Limits

| Operation | Bot API | Local Bot API Server |
|-----------|---------|---------------------|
| Download files | 20 MB | 2 GB |
| Upload files | 50 MB | 2 GB |
| Upload thumbnails | 200 KB | 200 KB |

The [Local Bot API Server](https://github.com/tdlib/telegram-bot-api) can be self-hosted to raise file limits to 2 GB. It handles file storage locally instead of proxying through Telegram's servers.

```bash
# Build and run local Bot API server
git clone --recursive https://github.com/tdlib/telegram-bot-api.git
cd telegram-bot-api
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
cmake --build . --target install

# Run (requires api_id and api_hash from https://my.telegram.org)
telegram-bot-api --api-id=YOUR_API_ID --api-hash=YOUR_API_HASH --local
```

### Rate Limits

| Scope | Limit |
|-------|-------|
| Global (all chats) | ~30 messages/second |
| Per chat (private) | 1 message/second |
| Per chat (group) | 20 messages/minute |
| Bulk notifications | 30 messages/second to different chats |
| Inline query results | 50 results per query |

grammY has built-in rate limiting via the `auto-retry` and `transformer-throttler` plugins:

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

- **No message scheduling for bots** — bots cannot schedule messages for future delivery
- **No voice/video calls** — bots cannot initiate or receive calls
- **Group admin limitations** — bots cannot promote members above their own permission level
- **Channel posting** — bots can post to channels but cannot read channel messages unless they are the channel admin
- **Search** — Bot API has no message search capability; bots must maintain their own message index
- **Message history** — bots cannot access messages sent before they were added to a group

## Related

- `.agents/services/communications/simplex.md` — SimpleX Chat (maximum privacy, E2E, no identifiers)
- `.agents/services/communications/matrix-bot.md` — Matrix messaging (federated, self-hostable)
- `.agents/services/communications/matterbridge.md` — Multi-platform chat bridge (Telegram native support)
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/voice/speech-to-speech.md` — Voice message transcription
- `.agents/tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- `.agents/tools/credentials/gopass.md` — Secure credential storage
- grammY docs: https://grammy.dev/
- Telegram Bot API: https://core.telegram.org/bots/api
- Telegram Bot FAQ: https://core.telegram.org/bots/faq
- Local Bot API Server: https://github.com/tdlib/telegram-bot-api
- Matterbridge: https://github.com/42wim/matterbridge
