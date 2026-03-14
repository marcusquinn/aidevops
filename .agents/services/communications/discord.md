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
- **License**: Proprietary (closed-source server, closed-source clients)
- **Bot SDK**: `discord.js` v14+ (TypeScript/Node.js, Apache-2.0)
- **API**: Discord REST API v10 + Gateway WebSocket (real-time events)
- **Developer Portal**: [discord.com/developers/applications](https://discord.com/developers/applications)
- **Docs**: [discord.js.org](https://discord.js.org/) | [discord.com/developers/docs](https://discord.com/developers/docs)
- **Repo**: [github.com/discordjs/discord.js](https://github.com/discordjs/discord.js) (25K+ stars)
- **Requires**: Node.js >= 18, bot token from Developer Portal

**Key characteristics**: Discord is the dominant platform for developer communities, open-source projects, and gaming. It provides rich bot APIs with slash commands, interactive components (buttons, selects, modals), threads, forums, and voice channels. However, Discord is a centralized, closed-source platform with significant privacy trade-offs.

**When to use Discord vs other protocols**:

| Criterion | Discord | Matrix | SimpleX | XMTP |
|-----------|---------|--------|---------|------|
| Server model | Centralized (Discord Inc.) | Federated | Decentralized relays | Decentralized nodes |
| E2E encryption | No | Optional (Megolm) | Yes (double ratchet) | Yes (MLS) |
| User identifiers | Username + discriminator | `@user:server` | None | Wallet/DID |
| Bot ecosystem | Mature (slash commands, components) | Mature (SDK, bridges) | Growing (WebSocket API) | First-class (Agent SDK) |
| Community features | Guilds, roles, threads, forums, voice, stage | Rooms, spaces | Groups (experimental) | Groups (MLS) |
| Data ownership | Discord Inc. owns all data | Self-hostable | User-controlled | User-controlled |
| Best for | Community engagement, developer support | Team collaboration, bridges | Maximum privacy | Web3/agent messaging |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ Discord Client   │     │ Discord Gateway  │     │ Bot Process      │
│ (Desktop, Mobile,│     │ (WebSocket)      │     │ (Node.js)        │
│  Browser)        │     │                  │     │                  │
│                  │────▶│ Events:          │────▶│ 1. Parse event   │
│ User sends:      │     │ - messageCreate  │     │ 2. Check perms   │
│ /ask Review auth │     │ - interactionCreate │  │ 3. Route command  │
│                  │◀────│ - guildMemberAdd │◀────│ 4. Dispatch       │
│ Bot response     │     │ - threadCreate   │     │ 5. Respond        │
└──────────────────┘     └──────────────────┘     └──────────────────┘
                                │                        │
                                ▼                        ▼
                    ┌──────────────────────┐  ┌──────────────────────┐
                    │ Discord REST API v10 │  │ aidevops Runner      │
                    │ - Send messages      │  │ runner-helper.sh     │
                    │ - Manage channels    │  │ → AI session         │
                    │ - Register commands  │  │ → response           │
                    │ - Upload files       │  │                      │
                    └──────────────────────┘  └──────────────────────┘
```

**Message flow (slash command)**:

1. User types `/ask prompt:Review auth.ts` in a guild channel
2. Discord Gateway sends `interactionCreate` event to bot
3. Bot validates user has required role (e.g., `@developer`)
4. Bot defers reply (shows "thinking..." indicator, 15-minute window)
5. Bot dispatches prompt to aidevops runner via `runner-helper.sh`
6. Runner executes via headless AI session
7. Bot edits deferred reply with the AI response
8. If response exceeds 2000 chars, bot sends as file attachment or paginated embeds

## Bot Setup

### 1. Create Application

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications)
2. Click "New Application", name it (e.g., "aidevops Bot")
3. Note the **Application ID** (used for OAuth2 and command registration)

### 2. Create Bot User

1. In the application, go to **Bot** tab
2. Click "Add Bot" (if not auto-created)
3. Copy the **Bot Token** — store securely:

```bash
aidevops secret set DISCORD_BOT_TOKEN
# Or fallback: add to ~/.config/aidevops/credentials.sh
# DISCORD_BOT_TOKEN="your-token-here"
```

4. Configure bot settings:
   - **Public Bot**: Off (prevents others from adding your bot)
   - **Requires OAuth2 Code Grant**: Off (not needed for bot-only usage)
   - **Message Content Intent**: On (required to read message content — see Intents below)

### 3. Configure Gateway Intents

Discord requires declaring which events your bot needs. Privileged intents require manual approval for bots in 100+ guilds.

| Intent | Privileged | Required for |
|--------|-----------|--------------|
| `Guilds` | No | Guild/channel structure, roles |
| `GuildMessages` | No | Message events in guild channels |
| `GuildMembers` | Yes | Member join/leave, role changes |
| `MessageContent` | Yes | Reading message text (non-slash-command) |
| `DirectMessages` | No | DM events |
| `GuildMessageReactions` | No | Reaction events |
| `GuildVoiceStates` | No | Voice channel join/leave |

**Recommendation**: Use slash commands as the primary interaction method. This avoids needing the `MessageContent` privileged intent entirely. Only enable `MessageContent` if you need prefix-based commands (e.g., `!ai prompt`).

Enable intents in Developer Portal: **Bot** tab > **Privileged Gateway Intents**.

### 4. OAuth2 Bot Invite

Generate an invite URL to add the bot to guilds:

1. Go to **OAuth2** > **URL Generator**
2. Select scopes: `bot`, `applications.commands`
3. Select bot permissions:
   - Send Messages
   - Send Messages in Threads
   - Embed Links
   - Attach Files
   - Read Message History
   - Use Slash Commands
   - Add Reactions
   - Use External Emojis
   - Manage Threads (if bot creates threads)
4. Copy the generated URL and open it to invite the bot

**Permission integer** (for the above set): `326417591296`

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
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.DirectMessages,
  ],
});

client.once(Events.ClientReady, (c) => {
  console.log(`Logged in as ${c.user.tag}`);
});

client.on(Events.InteractionCreate, async (interaction) => {
  if (!interaction.isChatInputCommand()) return;

  if (interaction.commandName === "ping") {
    await interaction.reply("Pong!");
  }
});

// Token from environment or gopass
const token = process.env.DISCORD_BOT_TOKEN;
if (!token) throw new Error("DISCORD_BOT_TOKEN not set");
client.login(token);
```

## Slash Commands

Slash commands are the recommended interaction method. They provide auto-complete, validation, and do not require the `MessageContent` intent.

### Registering Commands

```typescript
import { REST, Routes, SlashCommandBuilder } from "discord.js";

const commands = [
  new SlashCommandBuilder()
    .setName("ask")
    .setDescription("Ask the AI a question")
    .addStringOption((opt) =>
      opt
        .setName("prompt")
        .setDescription("Your question or instruction")
        .setRequired(true)
    )
    .addStringOption((opt) =>
      opt
        .setName("runner")
        .setDescription("Which runner to use")
        .addChoices(
          { name: "Code Reviewer", value: "code-reviewer" },
          { name: "SEO Analyst", value: "seo-analyst" },
          { name: "Ops Monitor", value: "ops-monitor" }
        )
    ),
  new SlashCommandBuilder()
    .setName("status")
    .setDescription("Check bot and runner status"),
].map((cmd) => cmd.toJSON());

const token = process.env.DISCORD_BOT_TOKEN;
const appId = process.env.DISCORD_APP_ID;
if (!token || !appId) {
  throw new Error("DISCORD_BOT_TOKEN and DISCORD_APP_ID must be set");
}

const rest = new REST().setToken(token);

// Register globally (takes up to 1 hour to propagate)
await rest.put(Routes.applicationCommands(appId), {
  body: commands,
});

// Or register per-guild (instant, good for development)
const guildId = process.env.DISCORD_GUILD_ID;
if (guildId) {
  await rest.put(
    Routes.applicationGuildCommands(appId, guildId),
    { body: commands }
  );
}
```

### Handling Commands

```typescript
client.on(Events.InteractionCreate, async (interaction) => {
  if (!interaction.isChatInputCommand()) return;

  if (interaction.commandName === "ask") {
    const prompt = interaction.options.getString("prompt", true);
    const runner = interaction.options.getString("runner") ?? "code-reviewer";

    // Defer reply — gives 15 minutes to respond (vs 3 seconds default)
    await interaction.deferReply();

    try {
      const result = await dispatchToRunner(runner, prompt);

      if (result.length <= 2000) {
        await interaction.editReply(result);
      } else {
        // Send as file attachment for long responses
        const buffer = Buffer.from(result, "utf-8");
        await interaction.editReply({
          content: "Response attached (exceeded 2000 char limit):",
          files: [{ attachment: buffer, name: "response.md" }],
        });
      }
    } catch (err) {
      await interaction.editReply(`Error: ${(err as Error).message}`);
    }
  }
});
```

## Interactive Components v2

Discord's component system supports buttons, select menus, modals, and the newer container-based layouts.

### Buttons

```typescript
import {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
} from "discord.js";

const row = new ActionRowBuilder<ButtonBuilder>().addComponents(
  new ButtonBuilder()
    .setCustomId("approve")
    .setLabel("Approve")
    .setStyle(ButtonStyle.Success),
  new ButtonBuilder()
    .setCustomId("reject")
    .setLabel("Reject")
    .setStyle(ButtonStyle.Danger)
);

await interaction.reply({ content: "Review this PR?", components: [row] });

// Handle button click
client.on(Events.InteractionCreate, async (i) => {
  if (!i.isButton()) return;
  if (i.customId === "approve") {
    await i.update({ content: "Approved!", components: [] });
  }
});
```

### Select Menus

```typescript
import {
  ActionRowBuilder,
  StringSelectMenuBuilder,
} from "discord.js";

const select = new ActionRowBuilder<StringSelectMenuBuilder>().addComponents(
  new StringSelectMenuBuilder()
    .setCustomId("runner-select")
    .setPlaceholder("Choose a runner")
    .addOptions(
      { label: "Code Reviewer", value: "code-reviewer" },
      { label: "SEO Analyst", value: "seo-analyst" },
      { label: "Ops Monitor", value: "ops-monitor" }
    )
);

await interaction.reply({ content: "Select runner:", components: [select] });
```

### Modals (Text Input Forms)

```typescript
import {
  ModalBuilder,
  TextInputBuilder,
  TextInputStyle,
  ActionRowBuilder,
} from "discord.js";

const modal = new ModalBuilder()
  .setCustomId("task-modal")
  .setTitle("Create Task");

const titleInput = new TextInputBuilder()
  .setCustomId("task-title")
  .setLabel("Task Title")
  .setStyle(TextInputStyle.Short)
  .setRequired(true);

const descInput = new TextInputBuilder()
  .setCustomId("task-desc")
  .setLabel("Description")
  .setStyle(TextInputStyle.Paragraph)
  .setRequired(false);

modal.addComponents(
  new ActionRowBuilder<TextInputBuilder>().addComponents(titleInput),
  new ActionRowBuilder<TextInputBuilder>().addComponents(descInput)
);

// Show modal (only from button/command interactions)
await interaction.showModal(modal);

// Handle modal submit
client.on(Events.InteractionCreate, async (i) => {
  if (!i.isModalSubmit()) return;
  if (i.customId === "task-modal") {
    const title = i.fields.getTextInputValue("task-title");
    const desc = i.fields.getTextInputValue("task-desc");
    await i.reply(`Task created: **${title}**\n${desc}`);
  }
});
```

## Messaging Patterns

### Guild Channel Messages

```typescript
// Send to a specific channel
const channel = await client.channels.fetch("CHANNEL_ID");
if (channel?.isTextBased()) {
  await channel.send("Hello from the bot!");
}

// Send embed
import { EmbedBuilder } from "discord.js";

const embed = new EmbedBuilder()
  .setTitle("Runner Status")
  .setColor(0x00ff00)
  .addFields(
    { name: "code-reviewer", value: "Online", inline: true },
    { name: "seo-analyst", value: "Busy", inline: true }
  )
  .setTimestamp();

await channel.send({ embeds: [embed] });
```

### Direct Messages

```typescript
// Send DM to a user
const user = await client.users.fetch("USER_ID");
await user.send("Your task has been completed.");

// Reply to DM
client.on(Events.MessageCreate, async (message) => {
  if (message.author.bot) return;
  if (!message.guild) {
    // This is a DM
    await message.reply("I received your DM. Use /ask in a server for AI help.");
  }
});
```

### Threads

```typescript
// Create a thread from a message
const thread = await message.startThread({
  name: "AI Discussion",
  autoArchiveDuration: 60, // minutes: 60, 1440, 4320, 10080
});
await thread.send("Thread created for this discussion.");

// Create a thread in a channel (without a parent message)
if (channel.isTextBased() && "threads" in channel) {
  const thread = await channel.threads.create({
    name: "Task t1385.7 Discussion",
    autoArchiveDuration: 1440,
  });
  await thread.send("Tracking task t1385.7 here.");
}
```

### Forum Channels

```typescript
import { ChannelType } from "discord.js";

// Post to a forum channel
const forum = await client.channels.fetch("FORUM_CHANNEL_ID");
if (forum?.type === ChannelType.GuildForum) {
  const thread = await forum.threads.create({
    name: "Bug Report: Auth failure",
    message: { content: "Description of the bug..." },
    appliedTags: ["BUG_TAG_ID"],
  });
}
```

### File Uploads

```typescript
import { AttachmentBuilder } from "discord.js";

// From buffer
const buffer = Buffer.from("file content here", "utf-8");
const attachment = new AttachmentBuilder(buffer, { name: "output.md" });
await channel.send({ files: [attachment] });

// From file path
await channel.send({ files: ["./report.pdf"] });
```

### Reactions and Typing

```typescript
// Add reaction
await message.react("✅");
await message.react("⏳"); // hourglass while processing

// Show typing indicator (resets after 10 seconds or when message sent)
await channel.sendTyping();
```

## Role-Based Routing

Map Discord roles to aidevops runners. Users with specific roles get routed to the appropriate AI personality.

### Configuration

`~/.config/aidevops/discord-bot.json` (600 permissions):

> **Security**: Store `botToken` in gopass (`aidevops secret set DISCORD_BOT_TOKEN`), not in this JSON file. Reference it via environment variables or `credentials.sh`. The value below is a placeholder only.

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
  "channelRouting": {
    "dev-chat": "code-reviewer",
    "seo-room": "seo-analyst"
  },
  "defaultRunner": "code-reviewer",
  "allowedRoles": ["developer", "seo-team", "ops", "content", "admin"],
  "adminRoles": ["admin"],
  "maxPromptLength": 3000,
  "responseTimeout": 600
}
```

### Routing Logic

```typescript
import { ChatInputCommandInteraction, GuildMember, TextChannel } from "discord.js";

interface BotConfig {
  channelRouting: { [key: string]: string };
  roleRouting: { [key: string]: string };
  defaultRunner: string;
  allowedGuilds?: string[];
  allowedChannels?: string[];
  allowedUsers?: string[];
  allowedRoles?: string[];
  adminRoles?: string[];
  maxPromptLength?: number;
  responseTimeout?: number;
}

function resolveRunner(
  interaction: ChatInputCommandInteraction,
  config: BotConfig
): string {
  // 1. Explicit runner choice from command option
  const explicit = interaction.options.getString("runner");
  if (explicit) return explicit;

  // 2. Channel-based routing
  const channelName = (interaction.channel as TextChannel)?.name;
  if (channelName && config.channelRouting[channelName]) {
    return config.channelRouting[channelName];
  }

  // 3. Role-based routing (highest role wins)
  const member = interaction.member as GuildMember;
  for (const [roleName, runner] of Object.entries(config.roleRouting)) {
    if (member.roles.cache.some((r) => r.name === roleName)) {
      return runner;
    }
  }

  // 4. Default
  return config.defaultRunner;
}
```

## Access Control

### Guild/Channel/User/Role Allowlists

```typescript
import { ChatInputCommandInteraction, GuildMember } from "discord.js";


function checkAccess(
  interaction: ChatInputCommandInteraction,
  config: BotConfig
): boolean {
  const member = interaction.member as GuildMember;

  // Guild allowlist (if configured)
  if (config.allowedGuilds?.length) {
    if (!config.allowedGuilds.includes(interaction.guildId!)) return false;
  }

  // Channel allowlist (if configured)
  if (config.allowedChannels?.length) {
    if (!config.allowedChannels.includes(interaction.channelId)) return false;
  }

  // User allowlist (if configured)
  if (config.allowedUsers?.length) {
    if (!config.allowedUsers.includes(interaction.user.id)) return false;
  }

  // Role allowlist (user must have at least one allowed role)
  if (config.allowedRoles?.length) {
    const hasRole = config.allowedRoles.some((roleName) =>
      member.roles.cache.some((r) => r.name === roleName)
    );
    if (!hasRole) return false;
  }

  return true;
}
```

### Rate Limiting

```typescript
const rateLimits = new Map<string, number[]>();

function checkRateLimit(
  userId: string,
  maxRequests: number = 10,
  windowMs: number = 60_000
): boolean {
  const now = Date.now();
  const timestamps = rateLimits.get(userId) ?? [];
  const recent = timestamps.filter((t) => now - t < windowMs);

  if (recent.length >= maxRequests) return false;

  recent.push(now);
  rateLimits.set(userId, recent);
  return true;
}
```

## Privacy and Security Assessment

### What Discord Sees

Discord is a centralized platform. All messages pass through and are stored on Discord's servers.

| Data | Discord access | Notes |
|------|---------------|-------|
| Message content | Full access | Stored server-side, no E2E encryption |
| Message metadata | Full access | Timestamps, sender, channel, guild |
| User identity | Full access | Email, IP, device info, payment info |
| Voice/video | Full access | Processed server-side, not E2E |
| File uploads | Full access | Stored on Discord CDN |
| Bot interactions | Full access | All slash commands, button clicks |
| Presence/activity | Full access | Online status, game activity, Spotify |

### AI Training Warning

**Discord's privacy policy permits using data for AI/ML features and service improvement.** Discord has introduced AI-powered features:

- **Clyde** (AI chatbot, powered by OpenAI — paused but precedent set)
- **Conversation summaries** (AI-generated channel summaries)
- **AutoMod AI** (AI-powered content moderation)
- **Topic suggestions** (AI-generated channel topics)

Users should assume:

1. All Discord messages are accessible to Discord Inc.
2. Message content may be used for AI model training and feature development
3. Discord staff can access any message for trust & safety review
4. Push notifications route through FCM (Google) or APNs (Apple)
5. Discord's CDN and infrastructure is hosted on Google Cloud

**Opt-out**: Users can disable some AI features in Settings > Privacy & Safety, but this does not prevent Discord from accessing or storing the data — only from surfacing AI features in the UI.

### Comparison with E2E Encrypted Alternatives

| Aspect | Discord | Matrix (E2E) | SimpleX | Signal |
|--------|---------|-------------|---------|--------|
| E2E encryption | No | Optional | Yes | Yes |
| Server reads messages | Yes | No (with E2E) | No | No |
| AI training risk | Yes | No (self-hosted) | No | No |
| Metadata collection | Extensive | Moderate | Minimal | Minimal |
| Open-source server | No | Yes | Yes | Partial |
| Data portability | Limited (GDPR export) | Full | Full | Limited |

### Recommendations

- **Do not send secrets, credentials, or sensitive business data** through Discord
- **Use Discord for community engagement**, not for confidential communications
- **For sensitive AI dispatch**, prefer Matrix or SimpleX — use Discord only for non-sensitive prompts
- **Inform users** that their messages to the bot are processed by Discord and the AI runner
- **Bot token security**: Store in gopass, never commit to repos, rotate if compromised
- **Minimal permissions**: Request only the bot permissions you need
- **Audit logging**: Log all bot dispatches locally for accountability

## Integration with aidevops Runners

### Dispatch Pattern

```typescript
import { spawnSync } from "node:child_process";

function dispatchToRunner(runner: string, prompt: string): string {
  // Use spawnSync with argument array — bypasses the shell entirely,
  // preventing injection via ;, |, &&, $(), backticks, and all other
  // shell metacharacters. Never use execSync with string interpolation.
  const child = spawnSync(
    "runner-helper.sh",
    ["dispatch", runner, prompt],
    {
      encoding: "utf-8",
      timeout: 600_000, // 10 minutes
      env: { ...process.env, RUNNER_TIMEOUT: "600" },
    }
  );

  if (child.error) {
    throw child.error;
  }

  if (child.status !== 0) {
    // Note: stderr may contain sensitive info — sanitize before surfacing to users
    throw new Error(`Runner failed with exit code ${child.status}: ${child.stderr}`);
  }

  return child.stdout.trim();
}
```

### Recommended Architecture

```text
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ Discord Guild    │     │ Discord Bot      │     │ aidevops Runner  │
│                  │     │ (Node.js)        │     │                  │
│ /ask prompt      │────▶│ 1. Parse command │────▶│ runner-helper.sh │
│ /status          │     │ 2. Check roles   │     │ → AI session     │
│ Button clicks    │◀────│ 3. Route runner  │◀────│ → response       │
│                  │     │ 4. Dispatch      │     │                  │
│ AI response      │     │ 5. Format reply  │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
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

### Thread-Per-Request Pattern

For longer conversations, create a thread per AI request:

```typescript
client.on(Events.InteractionCreate, async (interaction) => {
  if (!interaction.isChatInputCommand()) return;
  if (interaction.commandName !== "ask") return;

  const prompt = interaction.options.getString("prompt", true);

  // Create thread for this conversation
  const reply = await interaction.reply({
    content: `Processing: *${prompt.slice(0, 100)}...*`,
    fetchReply: true,
  });

  const thread = await reply.startThread({
    name: `AI: ${prompt.slice(0, 90)}`,
    autoArchiveDuration: 60,
  });

  // Dispatch and post result in thread
  const result = await dispatchToRunner("code-reviewer", prompt);
  await thread.send(result.slice(0, 2000));
});
```

## Voice Channels

Discord bots can join voice channels for audio interactions. This requires the `@discordjs/voice` package.

```bash
npm i @discordjs/voice @discordjs/opus sodium-native
```

```typescript
import {
  joinVoiceChannel,
  createAudioPlayer,
  createAudioResource,
} from "@discordjs/voice";

// Fetch the guild from the client (assuming 'client' is your Discord.js Client instance)
const guild = client.guilds.cache.get("GUILD_ID");
if (!guild) {
  throw new Error("Guild not found");
}

// Join voice channel
const connection = joinVoiceChannel({
  channelId: "VOICE_CHANNEL_ID",
  guildId: guild.id,
  adapterCreator: guild.voiceAdapterCreator,
});

// Play audio
const player = createAudioPlayer();
const resource = createAudioResource("./response.mp3");
player.play(resource);
connection.subscribe(player);
```

Voice integration enables speech-to-text → AI dispatch → text-to-speech workflows. See `tools/voice/speech-to-speech.md` for the audio pipeline.

## Matterbridge Integration

Discord is natively supported by [Matterbridge](https://github.com/42wim/matterbridge). See `services/communications/matterbridge.md` for full configuration.

### Quick Config

```toml
[discord]
  [discord.myserver]
  Token="Bot YOUR_BOT_TOKEN"
  Server="My Server Name"
  # Use webhooks for better username/avatar spoofing
  # WebhookURL="https://discord.com/api/webhooks/..."

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

### Bridge Considerations

- Discord messages bridged to Matrix/SimpleX lose E2E encryption at the bridge boundary
- Discord-side messages are always visible to Discord Inc. regardless of bridge
- Matterbridge uses a bot token — the bridge bot needs appropriate permissions in the Discord guild
- Webhook mode provides better username/avatar display for bridged messages
- File attachments are re-uploaded to the destination platform

### Privacy Gradient

Users who need privacy use Matrix or SimpleX directly. Discord serves as the convenience/community layer. Messages flow between platforms transparently via Matterbridge, but users should understand that anything sent through Discord is accessible to Discord Inc.

## Deployment

### Process Management

```bash
# PM2 (recommended for production)
npm i -g pm2
pm2 start src/bot.ts --interpreter tsx --name discord-bot
pm2 save
pm2 startup

# Or systemd
cat > /etc/systemd/system/discord-bot.service <<'EOF'
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

sudo systemctl daemon-reload
sudo systemctl enable --now discord-bot
```

### Docker

```dockerfile
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
CMD ["./node_modules/.bin/tsx", "src/bot.ts"]
```

### Health Monitoring

```typescript
// Heartbeat check
client.on(Events.ClientReady, () => {
  setInterval(() => {
    const ping = client.ws.ping;
    if (ping > 500) {
      console.warn(`High gateway latency: ${ping}ms`);
    }
  }, 30_000);
});

// Reconnection handling (discord.js handles this automatically)
client.on(Events.ShardReconnecting, () => {
  console.log("Reconnecting to Discord gateway...");
});

client.on(Events.ShardError, (error) => {
  console.error("Gateway error:", error);
});
```

## Limitations

### Message Length

Discord messages are limited to 2000 characters. AI responses frequently exceed this. Strategies:

1. **File attachment**: Send long responses as `.md` or `.txt` files
2. **Pagination**: Split into multiple messages (risk of rate limiting)
3. **Embeds**: Up to 4096 chars in embed description, 6000 total across all embeds
4. **Thread**: Create a thread and post multiple messages

### Rate Limits

Discord enforces strict rate limits:

| Scope | Limit |
|-------|-------|
| Global | 50 requests/second |
| Per-channel message send | 5/5s |
| Per-guild slash command response | 5/5s |
| Interaction response | 3 seconds (or defer) |
| Deferred interaction edit | 15 minutes |

discord.js handles rate limiting automatically with request queuing.

### Interaction Timeouts

- **Initial response**: 3 seconds (use `deferReply()` for longer operations)
- **Deferred response edit**: 15 minutes
- **Component interactions**: 3 seconds (use `deferUpdate()`)
- **Modal submit**: 3 seconds

### No E2E Encryption

Discord does not support E2E encryption. All messages are readable by Discord. This is a fundamental platform limitation, not a configuration issue.

### Privileged Intents

Bots in 100+ guilds must apply for privileged intents (`MessageContent`, `GuildMembers`, `GuildPresences`) through the Developer Portal. Approval is not guaranteed. Design bots to work without `MessageContent` by using slash commands.

### Closed Source

Discord's server and clients are closed-source. There is no way to audit what Discord does with message data, verify encryption claims, or self-host. This is a trust-the-provider model.

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
