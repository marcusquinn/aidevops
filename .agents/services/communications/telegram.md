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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Telegram Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

| Field | Value |
|-------|-------|
| **Bot API** | `https://api.telegram.org/bot<token>/` + grammY SDK (TypeScript, MIT, `grammy` on npm) |
| **Protocol** | MTProto 2.0; server-client encrypted by default |
| **Encryption** | Secret Chats only (1:1 mobile — not bots/groups/channels) |
| **Bot setup** | [@BotFather](https://t.me/BotFather) |
| **Docs** | https://core.telegram.org/bots/api · https://grammy.dev/ |
| **File limits** | 50 MB download / 20 MB upload (Bot API); 2 GB via local server |
| **Rate limits** | ~30 msg/s global · 1 msg/s per chat · 20 msg/min groups |

**vs alternatives**: Telegram = richest bot platform (inline keyboards, payments, web apps, forum topics); Signal/SimpleX = E2E by default; Slack/Discord = team workspaces. All bot messages are server-accessible — no E2E for bots.

<!-- AI-CONTEXT-END -->

## Setup

```bash
bun add grammy   # or: npm install grammy
```

**BotFather**: `/newbot` → name + username (must end in `bot`) → token. Key commands: `/setcommands`, `/setprivacy`, `/token` (regenerate), `/deletebot`.

**Group privacy mode**: bots receive commands + direct replies only by default. Disable via `/setprivacy` to receive all group messages.

## Bot API (grammY)

```typescript
import { Bot, Context } from "grammy";
const bot = new Bot(process.env.TELEGRAM_BOT_TOKEN!);

bot.command("start", (ctx) => ctx.reply("Welcome!"));
bot.command("status", async (ctx) => { await ctx.reply("Checking..."); });
bot.on("message:text", (ctx) => console.log(`${ctx.from?.id}: ${ctx.message.text}`));
bot.catch((err) => console.error(err));
bot.start();  // long polling
```

**Long polling vs webhooks**:

| | Long Polling | Webhooks |
|--|--|--|
| Setup | Zero config, works behind NAT | Requires public HTTPS URL |
| Latency | ~300ms | Near-instant |
| Best for | Local dev | Production (ports: 443, 80, 88, 8443) |

```typescript
// Webhooks
import { webhookCallback } from "grammy";
Bun.serve({ port: 8443, fetch: webhookCallback(bot, "bun") });
// await bot.api.setWebhook("https://bot.example.com/webhook");
```

**Inline keyboards**:

```typescript
import { InlineKeyboard } from "grammy";
bot.command("menu", async (ctx) => {
  const kb = new InlineKeyboard()
    .text("Status", "cb:status").text("Run", "cb:run")
    .row().url("Docs", "https://example.com/docs");
  await ctx.reply("Choose:", { reply_markup: kb });
});
bot.callbackQuery("cb:status", async (ctx) => {
  await ctx.answerCallbackQuery({ text: "Checking..." });
  await ctx.editMessageText("System operational.");
});
```

**Access control**:

```typescript
const isDM = (ctx: Context) => ctx.chat?.type === "private";
async function adminOnly(ctx: Context, next: () => Promise<void>) {
  const adminIds = (process.env.TELEGRAM_ADMIN_IDS ?? "").split(",").map(Number);
  if (!ctx.from || !adminIds.includes(ctx.from.id)) { await ctx.reply("Unauthorized."); return; }
  await next();
}
bot.command("run", adminOnly, async (ctx) => { /* ... */ });
bot.command("config", async (ctx) => { if (!isDM(ctx)) { await ctx.reply("DMs only."); return; } });
```

**Forum topics**: `await bot.api.sendMessage(chatId, "text", { message_thread_id: topicId })`

**Multi-step conversations**: `bun add @grammyjs/conversations` then use `conversation.wait()` to pause for user input.

## Security

- **Default**: server-client encryption only — Telegram has full plaintext access to all non-Secret-Chat messages
- **Secret Chats**: E2E (MTProto 2.0 + DH), 1:1 mobile only — not available for bots, groups, channels, or Desktop (except macOS native)
- **Metadata exposed**: social graph, timestamps, group memberships, IPs, phone numbers, device info
- **Server**: proprietary, closed-source (Dubai, UAE); has disclosed IPs + phone numbers to authorities; updated privacy policy 2024 re: law enforcement

**Bot-specific**:
- Bot tokens grant full access to all received messages — treat as critical secrets
- Tokens appear in every API URL — ensure HTTPS and sanitize logs
- Webhook: verify `X-Telegram-Bot-Api-Secret-Token` header; use a secret path
- Files: anyone with a `file_id` can download — treat as semi-public

```bash
gopass insert aidevops/telegram/bot-token
# Or: echo 'export TELEGRAM_BOT_TOKEN="<token>"' >> ~/.config/aidevops/credentials.sh
# NEVER commit tokens or pass as CLI arguments. Regenerate via @BotFather /token if compromised.
```

## aidevops Integration

| Component | Location |
|-----------|----------|
| Helper script | `.agents/scripts/telegram-dispatch-helper.sh` |
| Config | `~/.config/aidevops/telegram-bot.json` |

```bash
telegram-dispatch-helper.sh setup|start|stop|status
telegram-dispatch-helper.sh map <chat_id> <entity_type> <entity_id>
entity-helper.sh resolve telegram:-1001234567890   # → project:myproject
```

**Runner dispatch**: Use array args to prevent injection:

```typescript
bot.command("run", adminOnly, async (ctx) => {
  const proc = Bun.spawn(["runner-helper.sh", "dispatch", ctx.match!],
    { stdout: "pipe", signal: AbortSignal.timeout(600_000), env: { ...process.env } });
  await ctx.reply(`\`\`\`\n${(await new Response(proc.stdout).text()).slice(0, 4000)}\n\`\`\``);
});
```

**Config** (`~/.config/aidevops/telegram-bot.json`):

```json
{
  "token_source": "gopass:aidevops/telegram/bot-token",
  "mode": "polling",
  "admin_ids": [123456789],
  "allowed_chats": [-1001234567890],
  "entity_mappings": { "-1001234567890": { "type": "project", "id": "myproject" } }
}
```

## Matterbridge

Native Telegram support — no adapter needed.

```toml
[telegram.main]
Token="YOUR_BOT_TOKEN"

[[gateway]]
name="project-bridge"
enable=true
  [[gateway.inout]]
  account="telegram.main"
  channel="-1001234567890"   # supergroup ID (negative, starts with -100)
  [[gateway.inout]]
  account="matrix.home"
  channel="#project:example.com"
```

Get chat ID: add `@getidsbot` to group. Bot requirements: add to group, disable privacy mode, grant send permission.

**Bridging limits**: formatting differences, 20 MB upload cap, stickers → PNG only, reactions/edits/threads may not propagate.

## Limitations

**File limits**: 50 MB download / 20 MB upload (Bot API); 2 GB via [local server](https://github.com/tdlib/telegram-bot-api).

**Rate limits**: ~30 msg/s global · 1 msg/s per chat · 20/min groups · 50 inline results/query.

```typescript
// bun add @grammyjs/auto-retry @grammyjs/transformer-throttler
import { autoRetry } from "@grammyjs/auto-retry";
import { apiThrottler } from "@grammyjs/transformer-throttler";
bot.api.config.use(autoRetry());
bot.api.config.use(apiThrottler());
```

**Other**: no E2E for bots (use SimpleX/Signal if required) · phone number required · MTProto userbots (Telethon/Pyrogram) violate ToS · no message scheduling/search/history · bots can post to channels but not read them unless admin.

## Related

- `.agents/services/communications/simplex.md` — maximum privacy, E2E, no identifiers
- `.agents/services/communications/matrix-bot.md` — federated, self-hostable
- `.agents/services/communications/matterbridge.md` — multi-platform bridge
- `.agents/tools/security/opsec.md` · `.agents/tools/credentials/gopass.md`
- grammY: https://grammy.dev/ · Bot API: https://core.telegram.org/bots/api
