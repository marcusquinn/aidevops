---
description: Discord bot integration — discord.js (TypeScript), bot setup (Developer Portal, intents, OAuth2), DM/guild/thread messaging, slash commands, interactive components v2, role-based routing, access control, privacy/security assessment, aidevops runner dispatch, Matterbridge bridging
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

# Discord Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Centralized chat platform — guild-based channels, DMs, threads, forums, voice, video, streaming
- **License**: Proprietary (closed-source server and clients)
- **Bot SDK**: `discord.js` v14+ (TypeScript/Node.js, Apache-2.0)
- **API**: Discord REST API v10 + Gateway WebSocket (real-time events)
- **Developer Portal**: [discord.com/developers/applications](https://discord.com/developers/applications)
- **Docs**: [discord.js.org](https://discord.js.org/) | [discord.com/developers/docs](https://discord.com/developers/docs)
- **Repo**: [github.com/discordjs/discord.js](https://github.com/discordjs/discord.js) (25K+ stars)
- **Requires**: Node.js >= 18, bot token from Developer Portal

**When to use Discord vs other protocols**:

| Criterion | Discord | Matrix | SimpleX | XMTP |
|-----------|---------|--------|---------|------|
| Server model | Centralized (Discord Inc.) | Federated | Decentralized relays | Decentralized nodes |
| E2E encryption | No | Optional (Megolm) | Yes (double ratchet) | Yes (MLS) |
| Bot ecosystem | Mature (slash commands, components) | Mature (SDK, bridges) | Growing (WebSocket API) | First-class (Agent SDK) |
| Community features | Guilds, roles, threads, forums, voice, stage | Rooms, spaces | Groups (experimental) | Groups (MLS) |
| Data ownership | Discord Inc. owns all data | Self-hostable | User-controlled | User-controlled |
| Best for | Community engagement, developer support | Team collaboration, bridges | Maximum privacy | Web3/agent messaging |

<!-- AI-CONTEXT-END -->

## Architecture

```text
Discord Client ──> Gateway WebSocket ──> Bot Process (Node.js)
                   (messageCreate,        1. Parse event
                    interactionCreate,    2. Check perms
                    guildMemberAdd)       3. Route command
                                          4. Dispatch to runner
                                          5. Respond
```

**Slash command flow**: User types `/ask prompt:Review auth.ts` → Gateway sends `interactionCreate` → bot validates role → defers reply (15-min window) → dispatches to aidevops runner → edits deferred reply with response (file attachment if >2000 chars).

## Bot Setup

### 1. Create Application

Go to [discord.com/developers/applications](https://discord.com/developers/applications) → "New Application" → note the **Application ID**.

### 2. Create Bot User

**Bot** tab → "Add Bot" → copy the **Bot Token**:

```bash
aidevops secret set DISCORD_BOT_TOKEN
```

Settings: **Public Bot**: Off | **Requires OAuth2 Code Grant**: Off | **Message Content Intent**: On (required for non-slash-command message reading).

### 3. Configure Gateway Intents

Privileged intents require manual approval for bots in 100+ guilds. Enable in Developer Portal: **Bot** tab > **Privileged Gateway Intents**.

| Intent | Privileged | Required for |
|--------|-----------|--------------|
| `Guilds` | No | Guild/channel structure, roles |
| `GuildMessages` | No | Message events in guild channels |
| `GuildMembers` | Yes | Member join/leave, role changes |
| `MessageContent` | Yes | Reading message text (non-slash-command) |
| `DirectMessages` | No | DM events |
| `GuildMessageReactions` | No | Reaction events |
| `GuildVoiceStates` | No | Voice channel join/leave |

**Recommendation**: Use slash commands as the primary interaction method — avoids needing the `MessageContent` privileged intent entirely.

### 4. OAuth2 Bot Invite

**OAuth2** > **URL Generator** → scopes: `bot`, `applications.commands` → permissions: Send Messages, Send Messages in Threads, Embed Links, Attach Files, Read Message History, Use Slash Commands, Add Reactions, Use External Emojis, Manage Threads.

**Permission integer**: `326417591296`

```text
https://discord.com/oauth2/authorize?client_id=YOUR_APP_ID&permissions=326417591296&scope=bot+applications.commands
```

## Installation

```bash
mkdir discord-bot && cd discord-bot
npm init -y
npm i discord.js
npm i -D typescript tsx @types/node
```

### Minimal Bot

```typescript
import { Client, GatewayIntentBits, Events } from "discord.js";

const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.DirectMessages],
});

client.once(Events.ClientReady, (c) => console.log(`Logged in as ${c.user.tag}`));

client.on(Events.InteractionCreate, async (interaction) => {
  if (!interaction.isChatInputCommand()) return;
  if (interaction.commandName === "ping") await interaction.reply("Pong!");
});

const token = process.env.DISCORD_BOT_TOKEN;
if (!token) throw new Error("DISCORD_BOT_TOKEN not set");
client.login(token);
```

## Slash Commands

### Registering Commands

```typescript
import { REST, Routes, SlashCommandBuilder } from "discord.js";

const commands = [
  new SlashCommandBuilder()
    .setName("ask")
    .setDescription("Ask the AI a question")
    .addStringOption((opt) =>
      opt.setName("prompt").setDescription("Your question or instruction").setRequired(true)
    )
    .addStringOption((opt) =>
      opt.setName("runner").setDescription("Which runner to use")
        .addChoices(
          { name: "Code Reviewer", value: "code-reviewer" },
          { name: "SEO Analyst", value: "seo-analyst" },
          { name: "Ops Monitor", value: "ops-monitor" }
        )
    ),
  new SlashCommandBuilder().setName("status").setDescription("Check bot and runner status"),
].map((cmd) => cmd.toJSON());

const rest = new REST().setToken(process.env.DISCORD_BOT_TOKEN!);

// Register globally (up to 1 hour to propagate) or per-guild (instant, for development)
await rest.put(Routes.applicationCommands(process.env.DISCORD_APP_ID!), { body: commands });
// await rest.put(Routes.applicationGuildCommands(appId, guildId), { body: commands });
```

### Handling Commands

```typescript
client.on(Events.InteractionCreate, async (interaction) => {
  if (!interaction.isChatInputCommand()) return;
  if (interaction.commandName !== "ask") return;

  const prompt = interaction.options.getString("prompt", true);
  const runner = interaction.options.getString("runner") ?? "code-reviewer";

  await interaction.deferReply();
  try {
    const result = await dispatchToRunner(runner, prompt);
    if (result.length <= 2000) {
      await interaction.editReply(result);
    } else {
      await interaction.editReply({
        content: "Response attached (exceeded 2000 char limit):",
        files: [{ attachment: Buffer.from(result, "utf-8"), name: "response.md" }],
      });
    }
  } catch (err) {
    await interaction.editReply(`Error: ${(err as Error).message}`);
  }
});
```

## Interactive Components v2

```typescript
import {
  ActionRowBuilder, ButtonBuilder, ButtonStyle,
  StringSelectMenuBuilder, ModalBuilder, TextInputBuilder, TextInputStyle,
} from "discord.js";

// Buttons
const row = new ActionRowBuilder<ButtonBuilder>().addComponents(
  new ButtonBuilder().setCustomId("approve").setLabel("Approve").setStyle(ButtonStyle.Success),
  new ButtonBuilder().setCustomId("reject").setLabel("Reject").setStyle(ButtonStyle.Danger)
);
await interaction.reply({ content: "Review this PR?", components: [row] });

client.on(Events.InteractionCreate, async (i) => {
  if (i.isButton() && i.customId === "approve") await i.update({ content: "Approved!", components: [] });
});

// Select menu
const select = new ActionRowBuilder<StringSelectMenuBuilder>().addComponents(
  new StringSelectMenuBuilder()
    .setCustomId("runner-select").setPlaceholder("Choose a runner")
    .addOptions(
      { label: "Code Reviewer", value: "code-reviewer" },
      { label: "SEO Analyst", value: "seo-analyst" },
      { label: "Ops Monitor", value: "ops-monitor" }
    )
);
await interaction.reply({ content: "Select runner:", components: [select] });

// Modal (text input form)
const modal = new ModalBuilder().setCustomId("task-modal").setTitle("Create Task");
modal.addComponents(
  new ActionRowBuilder<TextInputBuilder>().addComponents(
    new TextInputBuilder().setCustomId("task-title").setLabel("Task Title").setStyle(TextInputStyle.Short).setRequired(true)
  ),
  new ActionRowBuilder<TextInputBuilder>().addComponents(
    new TextInputBuilder().setCustomId("task-desc").setLabel("Description").setStyle(TextInputStyle.Paragraph).setRequired(false)
  )
);
await interaction.showModal(modal);

client.on(Events.InteractionCreate, async (i) => {
  if (i.isModalSubmit() && i.customId === "task-modal") {
    await i.reply(`Task created: **${i.fields.getTextInputValue("task-title")}**`);
  }
});
```

## Messaging Patterns

```typescript
import { EmbedBuilder, AttachmentBuilder, ChannelType } from "discord.js";

// Channel message + embed
const channel = await client.channels.fetch("CHANNEL_ID");
if (channel?.isTextBased()) {
  await channel.send("Hello from the bot!");
  await channel.send({ embeds: [
    new EmbedBuilder().setTitle("Runner Status").setColor(0x00ff00)
      .addFields({ name: "code-reviewer", value: "Online", inline: true })
      .setTimestamp()
  ]});
}

// Direct message
const user = await client.users.fetch("USER_ID");
await user.send("Your task has been completed.");
client.on(Events.MessageCreate, async (message) => {
  if (message.author.bot || message.guild) return;
  await message.reply("I received your DM. Use /ask in a server for AI help.");
});

// Thread from message
const thread = await message.startThread({ name: "AI Discussion", autoArchiveDuration: 60 });

// Forum channel post
const forum = await client.channels.fetch("FORUM_CHANNEL_ID");
if (forum?.type === ChannelType.GuildForum) {
  await forum.threads.create({
    name: "Bug Report: Auth failure",
    message: { content: "Description of the bug..." },
    appliedTags: ["BUG_TAG_ID"],
  });
}

// File upload + reactions
await channel.send({ files: [new AttachmentBuilder(Buffer.from("content", "utf-8"), { name: "output.md" })] });
await message.react("✅");
await channel.sendTyping(); // resets after 10s or when message sent
```

## Role-Based Routing and Access Control

Config at `~/.config/aidevops/discord-bot.json` (600 permissions):

> **Security**: Store `botToken` in gopass (`aidevops secret set DISCORD_BOT_TOKEN`), not in this JSON file.

```json
{
  "guildId": "YOUR_GUILD_ID",
  "botToken": "stored-in-gopass",
  "roleRouting": {
    "developer": "code-reviewer",
    "seo-team": "seo-analyst",
    "ops": "ops-monitor",
    "content": "content-writer"
  },
  "channelRouting": { "dev-chat": "code-reviewer", "seo-room": "seo-analyst" },
  "defaultRunner": "code-reviewer",
  "allowedRoles": ["developer", "seo-team", "ops", "content", "admin"],
  "adminRoles": ["admin"],
  "maxPromptLength": 3000,
  "responseTimeout": 600
}
```

Resolution order: explicit `--runner` option > channel name > highest matching role > `defaultRunner`.

```typescript
import { ChatInputCommandInteraction, GuildMember, TextChannel } from "discord.js";

// Runner resolution
function resolveRunner(interaction: ChatInputCommandInteraction, config: Record<string, any>): string {
  const explicit = interaction.options.getString("runner");
  if (explicit) return explicit;
  const ch = (interaction.channel as TextChannel)?.name;
  if (ch && config.channelRouting[ch]) return config.channelRouting[ch];
  const member = interaction.member as GuildMember;
  for (const [role, runner] of Object.entries(config.roleRouting)) {
    if (member.roles.cache.some((r) => r.name === role)) return runner as string;
  }
  return config.defaultRunner;
}

// Access control: guild, channel, user, and role allowlists
function checkAccess(interaction: ChatInputCommandInteraction, config: {
  allowedGuilds?: string[]; allowedChannels?: string[]; allowedUsers?: string[]; allowedRoles?: string[];
}): boolean {
  if (config.allowedGuilds?.length && !config.allowedGuilds.includes(interaction.guildId!)) return false;
  if (config.allowedChannels?.length && !config.allowedChannels.includes(interaction.channelId)) return false;
  if (config.allowedUsers?.length && !config.allowedUsers.includes(interaction.user.id)) return false;
  if (config.allowedRoles?.length) {
    const member = interaction.member as GuildMember;
    if (!config.allowedRoles.some((r) => member.roles.cache.some((role) => role.name === r))) return false;
  }
  return true;
}

// Sliding-window rate limiter (in-memory)
const rateLimits = new Map<string, number[]>();
function checkRateLimit(userId: string, max = 10, windowMs = 60_000): boolean {
  const now = Date.now();
  const recent = (rateLimits.get(userId) ?? []).filter((t) => now - t < windowMs);
  if (recent.length >= max) return false;
  recent.push(now);
  rateLimits.set(userId, recent);
  return true;
}
```

## Privacy and Security

Discord is centralized — all data (messages, metadata, identity, voice/video, files, bot interactions, presence) passes through and is stored on Discord's servers with full access by Discord Inc. No E2E encryption. Infrastructure hosted on Google Cloud. Discord staff can access any message for trust & safety review. Push notifications route through FCM (Google) or APNs (Apple).

**AI training**: Discord's privacy policy permits using data for AI/ML features and service improvement. Opt-out in Settings > Privacy & Safety does not prevent data access/storage.

**Recommendations**: Do not send secrets or sensitive data through Discord. Use it for community engagement, not confidential communications. For sensitive AI dispatch, prefer Matrix or SimpleX. Inform users that bot messages are processed by Discord and the AI runner. Store bot token in gopass, never commit, rotate if compromised. Request only needed permissions. Log all bot dispatches locally.

## Integration with aidevops Runners

### Dispatch Pattern

```typescript
import { spawnSync } from "node:child_process";

function dispatchToRunner(runner: string, prompt: string): string {
  // spawnSync with argument array bypasses the shell entirely,
  // preventing injection via ;, |, &&, $(), backticks, etc.
  const child = spawnSync(
    "runner-helper.sh",
    ["dispatch", runner, prompt],
    { encoding: "utf-8", timeout: 600_000, env: { ...process.env, RUNNER_TIMEOUT: "600" } }
  );
  if (child.error) throw child.error;
  if (child.status !== 0) throw new Error(`Runner failed (${child.status}): ${child.stderr}`);
  return child.stdout.trim();
}
```

### Recommended Slash Commands

| Command | Description | Runner |
|---------|-------------|--------|
| `/ask <prompt>` | General AI question | Role-based routing |
| `/review <file>` | Code review request | `code-reviewer` |
| `/seo <url>` | SEO analysis | `seo-analyst` |
| `/status` | Bot and runner status | (local) |
| `/deploy <project>` | Trigger deployment | `ops-monitor` |
| `/task <description>` | Create a task | (local — creates TODO entry) |

## Voice Channels

Requires `@discordjs/voice`:

```bash
npm i @discordjs/voice @discordjs/opus sodium-native
```

```typescript
import { joinVoiceChannel, createAudioPlayer, createAudioResource } from "@discordjs/voice";

const connection = joinVoiceChannel({
  channelId: "VOICE_CHANNEL_ID",
  guildId: guild.id,
  adapterCreator: guild.voiceAdapterCreator,
});
const player = createAudioPlayer();
player.play(createAudioResource("./response.mp3"));
connection.subscribe(player);
```

Voice enables speech-to-text → AI dispatch → text-to-speech workflows. See `tools/voice/speech-to-speech.md`.

## Matterbridge Integration

Discord is natively supported by [Matterbridge](https://github.com/42wim/matterbridge). See `services/communications/matterbridge.md` for full configuration.

```toml
[discord]
  [discord.myserver]
  Token="Bot YOUR_BOT_TOKEN"
  Server="My Server Name"

[[gateway]]
name="discord-matrix-bridge"
enable=true

  [[gateway.inout]]
  account="discord.myserver"
  channel="general"

  [[gateway.inout]]
  account="matrix.home"
  channel="#general:example.com"
```

**Bridge notes**: Messages bridged to Matrix/SimpleX lose E2E encryption at the bridge boundary. Discord-side messages remain visible to Discord Inc. regardless. Webhook mode provides better username/avatar display. File attachments are re-uploaded to the destination. Users needing privacy should use Matrix or SimpleX directly.

## Deployment

```bash
# PM2 (recommended)
npm i -g pm2
pm2 start src/bot.ts --interpreter tsx --name discord-bot
pm2 save && pm2 startup

# systemd
sudo tee /etc/systemd/system/discord-bot.service <<'EOF'
[Unit]
Description=Discord aidevops bot
After=network.target
[Service]
Type=simple
User=discord-bot
WorkingDirectory=/opt/discord-bot
ExecStart=/opt/discord-bot/node_modules/.bin/tsx src/bot.ts
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now discord-bot
```

```dockerfile
# Docker
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
CMD ["./node_modules/.bin/tsx", "src/bot.ts"]
```

### Health Monitoring

```typescript
client.on(Events.ClientReady, () => {
  setInterval(() => {
    if (client.ws.ping > 500) console.warn(`High gateway latency: ${client.ws.ping}ms`);
  }, 30_000);
});
client.on(Events.ShardReconnecting, () => console.log("Reconnecting to Discord gateway..."));
client.on(Events.ShardError, (error) => console.error("Gateway error:", error));
```

## Limits and Timeouts

| Scope | Limit |
|-------|-------|
| Message length | 2000 chars (use file attachment, embeds up to 6000, or threads for longer) |
| Global rate | 50 requests/second |
| Per-channel send | 5/5s |
| Per-guild slash response | 5/5s |
| Initial interaction response | 3 seconds (use `deferReply()`) |
| Deferred response edit | 15 minutes |
| Component/modal interaction | 3 seconds (use `deferUpdate()`) |

discord.js handles rate limiting automatically with request queuing.

**Long response strategies**: (1) File attachment as `.md`/`.txt`, (2) Embeds (4096 chars in description), (3) Thread with multiple messages, (4) Pagination (risk of rate limiting).

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bot not responding to slash commands | Verify commands are registered (`Routes.applicationCommands`); check guild vs global |
| "Missing Access" error | Bot lacks required permissions in the channel; re-invite with correct permissions |
| "Missing Intent" error | Enable the required intent in Developer Portal > Bot > Privileged Intents |
| Interaction timeout (3s) | Use `deferReply()` before long operations |
| Rate limited | discord.js queues automatically; reduce message frequency if persistent |
| Bot offline after deploy | Check token is correct; verify `client.login()` is called; check process manager logs |
| Slash commands not appearing | Global commands take up to 1 hour; use guild commands for instant testing |
| Cannot read message content | Enable `MessageContent` intent, or switch to slash commands |

## Related

- `services/communications/matterbridge.md` — Multi-platform chat bridge (native Discord support)
- `services/communications/matrix-bot.md` — Matrix bot integration (federated, E2E capable)
- `services/communications/simplex.md` — SimpleX Chat (maximum privacy, no identifiers)
- `services/communications/xmtp.md` — XMTP (Web3 messaging, agent SDK)
- `tools/security/opsec.md` — Operational security guidance
- `tools/voice/speech-to-speech.md` — Voice pipeline for audio interactions
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- discord.js Docs: https://discord.js.org/
- Discord Developer Docs: https://discord.com/developers/docs
- Discord Developer Portal: https://discord.com/developers/applications
