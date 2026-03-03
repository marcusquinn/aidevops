---
description: Discord Bot integration — discord.js setup, slash commands, interactive components, gateway events, security considerations (no E2E, AI features, content scanning), Matterbridge, and aidevops dispatch
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

- **Type**: Community/gaming platform — no E2E encryption, Discord staff can access all messages
- **License**: Proprietary. Bot SDK: discord.js (Apache-2.0)
- **Bot tool**: discord.js (TypeScript, official community SDK, 25k+ stars)
- **Protocol**: Discord API (HTTP REST + WebSocket Gateway)
- **Encryption**: TLS in transit, at rest encryption — NO end-to-end encryption
- **Script**: `discord-dispatch-helper.sh [setup|start|stop|status|map|unmap|mappings|test|logs]`
- **Config**: `~/.config/aidevops/discord-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/discord-bot/`
- **Docs**: https://discord.com/developers/docs | https://discord.js.org/
- **App Management**: https://discord.com/developers/applications

**Quick start**:

```bash
discord-dispatch-helper.sh setup          # Interactive wizard
discord-dispatch-helper.sh map 123456789012345678 general-assistant
discord-dispatch-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────────┐
│ Discord Server (Guild)    │
│                           │
│ User sends message,       │
│ slash command, or         │
│ interacts with component  │
└────────────┬─────────────┘
             │
             │  Gateway (WebSocket)         +    REST API (HTTP)
             │  (real-time events)               (commands, responses)
             │
┌────────────▼─────────────┐     ┌──────────────────────┐
│ discord.js Bot (Bun/Node) │     │ aidevops Dispatch     │
│                           │     │                       │
│ ├─ Gateway event handlers │────▶│ runner-helper.sh      │
│ ├─ Slash commands         │     │ → AI session          │
│ ├─ Interactive components │◀────│ → response            │
│ ├─ Access control         │     │                       │
│ └─ Entity resolution      │     │                       │
└────────────┬─────────────┘     └──────────────────────┘
             │
┌────────────▼─────────────┐
│ memory.db (shared)        │
│ ├── entities              │  Entity profiles
│ ├── entity_channels       │  Cross-channel identity
│ ├── interactions          │  Layer 0: Immutable log
│ └── conversations         │  Layer 1: Context summaries
└───────────────────────────┘
```

**Message flow**:

1. User sends message, slash command, or interacts with a component in a Discord guild or DM
2. Discord delivers event via Gateway WebSocket connection
3. discord.js client receives event, checks access control (guild/channel/user/role allowlists)
4. Bot looks up channel-to-runner mapping
5. Entity resolution: Discord user ID (`123456789012345678`) resolved to entity via `entity-helper.sh`
6. Layer 0 logging: user message logged as immutable interaction
7. Context loading: entity profile + conversation summary + recent interactions
8. Bot dispatches entity-aware prompt to runner via `runner-helper.sh`
9. Runner executes via headless dispatch
10. Bot posts response back to Discord channel, thread, or DM
11. Bot adds reaction emoji (eyes while processing, checkmark on success, X on failure)

## Installation

### Prerequisites

1. **Discord account** with access to the [Discord Developer Portal](https://discord.com/developers/applications)
2. **Node.js >= 18** or **Bun** runtime
3. **A Discord server (guild)** where you have Manage Server permission to add bots

### Step 1: Create a Discord Application

1. Go to https://discord.com/developers/applications and click **New Application**
2. Name the application (e.g., "aidevops Bot")
3. Note the **Application ID** and **Public Key** from the General Information page

### Step 2: Create a Bot User

1. Navigate to **Bot** section > **Add Bot**
2. Configure: set username, avatar, disable **Public Bot** if restricting access
3. Under **Privileged Gateway Intents**, enable **MESSAGE CONTENT INTENT** (required to read message content). Optionally enable SERVER MEMBERS and PRESENCE intents.

**Note**: MESSAGE_CONTENT is a privileged intent. Auto-approved for <100 servers. For 100+ servers, apply for verification through Discord.

### Step 3: Generate Bot Invite URL

Navigate to **OAuth2 > URL Generator**:

1. **Scopes**: Select `bot` and `applications.commands`
2. **Bot Permissions**: Send Messages, Send Messages in Threads, Create Public/Private Threads, Embed Links, Attach Files, Add Reactions, Use Slash Commands, Read Message History, View Channels
3. Copy the generated URL and open it in a browser to invite the bot to your server

### Step 4: Obtain and Store the Bot Token

Navigate to **Bot** > **Reset Token**. Copy immediately — shown only once. Store securely:

```bash
# Via gopass (preferred)
gopass insert aidevops/discord/bot-token

# Or via credentials.sh fallback
# Added to ~/.config/aidevops/credentials.sh (600 permissions)
```

**CRITICAL**: Never commit the bot token to version control. Never share it. Anyone with the token has full control of the bot in all guilds it has joined.

### Step 5: Install Dependencies

```bash
# Using Bun (preferred)
bun add discord.js

# Using npm
npm install discord.js
```

## Bot API Integration

### Basic discord.js Bot with Slash Commands

```typescript
import { Client, GatewayIntentBits, Events, REST, Routes, SlashCommandBuilder } from "discord.js";

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent, GatewayIntentBits.DirectMessages,
    GatewayIntentBits.GuildMessageReactions,
  ],
});

// Register slash commands (global — takes up to 1h; use guild commands for dev)
const commands = [
  new SlashCommandBuilder().setName("ai").setDescription("Send a prompt to the AI assistant")
    .addStringOption((opt) => opt.setName("prompt").setDescription("Your prompt").setRequired(true)),
  new SlashCommandBuilder().setName("status").setDescription("Check bot and runner status"),
];
const rest = new REST().setToken(process.env.DISCORD_BOT_TOKEN!);
await rest.put(Routes.applicationCommands(process.env.DISCORD_APP_ID!), {
  body: commands.map((cmd) => cmd.toJSON()),
});

// Handle slash commands
client.on(Events.InteractionCreate, async (interaction) => {
  if (!interaction.isChatInputCommand()) return;
  if (interaction.commandName === "ai") {
    const prompt = interaction.options.getString("prompt", true);
    await interaction.deferReply(); // gives 15 min instead of 3 sec
    try {
      const response = await dispatchToRunner(prompt, interaction.user.id, interaction.channelId);
      await interaction.editReply(response);
    } catch (error) {
      await interaction.editReply(`Error: ${error.message}`);
    }
  }
  if (interaction.commandName === "status") {
    await interaction.reply({ content: "Bot is running.", ephemeral: true });
  }
});

// Handle DMs and @mentions
client.on(Events.MessageCreate, async (message) => {
  if (message.author.bot) return;
  const isDM = !message.guild;
  const isMention = message.guild && message.mentions.has(client.user!);
  if (!isDM && !isMention) return;

  const prompt = isDM ? message.content : message.content.replace(/<@!?\d+>/g, "").trim();
  if (!prompt) { await message.reply("Send me a prompt and I'll help!"); return; }

  await message.react("\u{1F440}");
  try {
    const response = await dispatchToRunner(prompt, message.author.id, message.channelId);
    await message.reply(response);
    await message.reactions.cache.get("\u{1F440}")?.users.remove(client.user!);
    await message.react("\u2705");
  } catch (error) {
    await message.reply(`Error: ${error.message}`);
    await message.react("\u274C");
  }
});

client.once(Events.ClientReady, (c) => console.log(`Discord bot ready as ${c.user.tag}`));
await client.login(process.env.DISCORD_BOT_TOKEN);
```

### Thread and Forum Messaging

```typescript
import { ChannelType } from "discord.js";

// Create a thread from a message
const thread = await message.startThread({
  name: "AI Discussion",
  autoArchiveDuration: 60, // minutes: 60, 1440, 4320, 10080
});
await thread.send("Thread created. I'll respond here.");

// Create a forum post
const forumChannel = await client.channels.fetch(forumChannelId);
if (forumChannel?.type === ChannelType.GuildForum) {
  await forumChannel.threads.create({
    name: "Analysis Report",
    message: { content: "Here's the analysis..." },
    appliedTags: [tagId],
  });
}
```

### Interactive Components (Buttons, Selects, Modals)

```typescript
import {
  ActionRowBuilder, ButtonBuilder, ButtonStyle,
  StringSelectMenuBuilder, ModalBuilder, TextInputBuilder, TextInputStyle,
} from "discord.js";

// Buttons
const row = new ActionRowBuilder<ButtonBuilder>().addComponents(
  new ButtonBuilder().setCustomId("run_tests").setLabel("Run Tests").setStyle(ButtonStyle.Secondary),
  new ButtonBuilder().setCustomId("deploy").setLabel("Deploy").setStyle(ButtonStyle.Primary),
);

await interaction.reply({ content: "Choose an action:", components: [row] });

// Handle button clicks
client.on(Events.InteractionCreate, async (interaction) => {
  if (!interaction.isButton()) return;
  if (interaction.customId === "run_tests") {
    await interaction.update({ content: "Running tests...", components: [] });
  }
});

// Select menus
const selectRow = new ActionRowBuilder<StringSelectMenuBuilder>().addComponents(
  new StringSelectMenuBuilder()
    .setCustomId("runner_select")
    .setPlaceholder("Choose a runner")
    .addOptions(
      { label: "Code Reviewer", value: "code-reviewer" },
      { label: "SEO Analyst", value: "seo-analyst" },
      { label: "General Assistant", value: "general-assistant" }
    )
);

// Modals — show in response to button/command interaction
const modal = new ModalBuilder().setCustomId("prompt_modal").setTitle("AI Prompt").addComponents(
  new ActionRowBuilder<TextInputBuilder>().addComponents(
    new TextInputBuilder()
      .setCustomId("prompt_input")
      .setLabel("Enter your prompt")
      .setStyle(TextInputStyle.Paragraph)
      .setRequired(true)
  )
);
await interaction.showModal(modal);
```

### File Uploads

```typescript
import { AttachmentBuilder } from "discord.js";

const attachment = new AttachmentBuilder(Buffer.from(reportContent), {
  name: "report.md",
  description: "Analysis report",
});
await message.reply({ content: "Here's the report:", files: [attachment] });
```

### Role-Based Routing and Permission Checks

```typescript
// Role-based runner routing
function getRunnerForRoles(member: GuildMember): string {
  if (member.roles.cache.has(ADMIN_ROLE_ID)) return "admin-assistant";
  if (member.roles.cache.has(DEV_ROLE_ID)) return "code-reviewer";
  if (member.roles.cache.has(MARKETING_ROLE_ID)) return "seo-analyst";
  return "general-assistant";
}

// Permission check before dispatch
client.on(Events.MessageCreate, async (message) => {
  if (!message.guild || message.author.bot) return;
  const member = await message.guild.members.fetch(message.author.id);
  if (!member.roles.cache.has(ALLOWED_ROLE_ID)) {
    await message.react("\u{1F6AB}");
    return;
  }
  const runner = getRunnerForRoles(member);
  const response = await dispatchToRunner(message.content, message.author.id, message.channelId, runner);
  await message.reply(response);
});
```

### Access Control

```typescript
// Allowlists — empty set = allow all
const ALLOWED_GUILDS = new Set(["123456789012345678"]);
const ALLOWED_CHANNELS = new Set(["111111111111111111"]);
const ALLOWED_USERS = new Set<string>([]);   // empty = allow all
const REQUIRED_ROLES = new Set<string>([]);  // empty = no role requirement

function isAllowed(userId: string, channelId: string, guildId: string | null, memberRoles?: string[]): boolean {
  if (ALLOWED_GUILDS.size > 0 && guildId && !ALLOWED_GUILDS.has(guildId)) return false;
  if (ALLOWED_CHANNELS.size > 0 && !ALLOWED_CHANNELS.has(channelId)) return false;
  if (ALLOWED_USERS.size > 0 && !ALLOWED_USERS.has(userId)) return false;
  if (REQUIRED_ROLES.size > 0 && memberRoles && !memberRoles.some((r) => REQUIRED_ROLES.has(r))) return false;
  return true;
}
```

## Security Considerations

**CRITICAL: Read this section carefully before deploying any bot that processes sensitive information via Discord.**

### Encryption

Discord provides **TLS in transit** and **encryption at rest** on Discord's servers. There is **NO end-to-end encryption**. Discord has full technical access to ALL message content, including:

- All guild channel messages (text, voice chat text, forum posts)
- All direct messages (1:1 and group DMs)
- All file uploads, images, and embedded media
- All message edits and their full history
- All deleted messages (retained server-side)
- Voice channel audio (processed server-side, not E2E encrypted)

### Staff Access

Discord's Trust & Safety team can and does read messages when investigating reports. Discord's privacy policy grants them broad access to user content for enforcement of Terms of Service and Community Guidelines. Unlike corporate platforms like Slack, there is no admin export tool for server owners — but Discord itself has unrestricted access to all data.

### Metadata Collection

Discord stores comprehensive metadata beyond message content: full message history with timestamps, edit/deletion history (deleted messages retained server-side), file upload/download records, reaction usage, read state tracking, voice channel participation, screen sharing activity, online/idle/gaming status, IP addresses, device info, client version, guild membership history, friend/block lists, and search queries.

### AI Training and Data Processing

**WARNING**: Discord has introduced and expanded AI features with data processing implications:

- **Clyde AI** (discontinued March 2024): AI chatbot that processed messages, establishing the precedent of AI processing message content.
- **Message summaries and AutoMod AI**: Server-side AI processing of message content for summaries, conversation topics, and content moderation.
- **Discord's privacy policy** allows using data for "service improvement" and "developing new features," including AI/ML. The scope is not fully transparent.
- **User opt-out**: Users can toggle some data usage in Privacy & Safety settings, but effectiveness for AI processing specifically is unclear.
- **Third-party bot data**: Messages processed by third-party bots are subject to each bot developer's privacy policy, not Discord's.

**Practical impact**: Assume any message sent on Discord may be processed by AI systems. Discord's privacy policy supports this usage.

### Push Notifications

Delivered via FCM (Android) and APNs (iOS). Message previews visible to Google/Apple during transit by default. Users can disable previews in notification settings, but this is a per-user choice, not a server-wide control.

### Open Source and Auditability

Discord platform is entirely closed source — no independent audit possible. discord.js is open source (Apache-2.0) so bot code is auditable, but Discord's server-side processing is not. Discord clients (desktop, mobile) are closed source with no reproducible builds.

### Jurisdiction and Legal

- **Entity**: Discord Inc. — San Francisco, California, USA
- **Jurisdiction**: Subject to US law including CLOUD Act, FISA Section 702, and National Security Letters
- **Data residency**: No user-selectable data residency. All data on Google Cloud Platform. No EU residency option.
- **Government requests**: Discord publishes a transparency report and complies with valid legal process.
- **GDPR**: Compliant for EU users. Users can request data export/deletion. Messages in servers you've left may persist.

### Bot-Specific Security

- Bot tokens grant access to ALL guilds the bot is in — a compromised token exposes every server
- **MESSAGE_CONTENT privileged intent** gives access to full text of all messages in guilds. Broad permission.
- Bots can be added to any server by anyone with **Manage Server** permission — scope creep risk. Disable "Public Bot" in developer portal.
- **No token rotation API**: Tokens must be manually reset in the developer portal if compromised.
- Excessive rate limit violations can result in bot account termination.

### Content Scanning

Discord actively scans for CSAM and prohibited content using PhotoDNA and custom ML models. Automated content analysis applies to all messages and media uploads, server-side, regardless of privacy settings.

### Comparison with Other Platforms

| Aspect | Discord | Slack | Matrix (self-hosted) | SimpleX |
|--------|---------|-------|---------------------|---------|
| E2E encryption | No | No | Yes (Megolm) | Yes (Double ratchet) |
| Platform content access | Full | Full | None (if E2E on) | None (stateless) |
| AI training risk | Yes (policy allows) | Opt-out required | No | No |
| Content scanning | Yes (automated) | Limited | No | No |
| Open source server | No | No | Yes (Synapse) | Yes (SMP) |
| Self-hostable | No | No | Yes | Yes |
| Jurisdiction | USA (Discord Inc.) | USA (Salesforce) | Self-determined | Self-determined |

**Summary**: Similar privacy profile to Slack — no E2E, platform has full access, AI features process content. Discord has less corporate oversight (no admin export tool) but broader platform access and active content scanning. **Not suitable for sensitive communications.** Use for community engagement and casual team communication.

## aidevops Integration

### discord-dispatch-helper.sh

The helper script follows the same pattern as other dispatch helpers:

```bash
# Setup wizard — prompts for token, application ID, guild/channel mappings
discord-dispatch-helper.sh setup

# Map Discord channels to runners
discord-dispatch-helper.sh map 123456789012345678 code-reviewer
discord-dispatch-helper.sh map 987654321098765432 seo-analyst

# List mappings
discord-dispatch-helper.sh mappings

# Remove a mapping
discord-dispatch-helper.sh unmap 123456789012345678

# Start/stop the bot
discord-dispatch-helper.sh start --daemon
discord-dispatch-helper.sh stop
discord-dispatch-helper.sh status

# Test dispatch
discord-dispatch-helper.sh test code-reviewer "Review src/auth.ts"

# View logs
discord-dispatch-helper.sh logs
discord-dispatch-helper.sh logs --follow
```

### Runner Dispatch

The bot dispatches to runners via `runner-helper.sh`, which handles:

- Runner AGENTS.md (personality/instructions)
- Headless session management
- Memory namespace isolation
- Entity-aware context loading
- Run logging

### Entity Resolution

When a Discord user sends a message, the bot resolves their Discord user ID to an entity:

- **Known user**: Match on `entity_channels` table (`channel=discord`, `channel_id=123456789012345678`)
- **New user**: Creates entity via `entity-helper.sh create` with Discord user ID linked
- **Cross-channel**: If the same person is linked on other channels (Matrix, Slack, SimpleX, email), their full profile is available
- **Profile enrichment**: Discord's user API provides username, display name, avatar, and guild-specific nickname — used to populate entity profile on first contact

### Configuration

`~/.config/aidevops/discord-bot.json` (600 permissions):

```json
{
  "botToken": "",
  "applicationId": "",
  "allowedGuilds": ["123456789012345678"],
  "allowedChannels": ["111111111111111111", "222222222222222222"],
  "allowedUsers": [],
  "requiredRoles": [],
  "defaultRunner": "",
  "channelMappings": {
    "111111111111111111": "code-reviewer",
    "222222222222222222": "seo-analyst"
  },
  "respondToMentions": true,
  "respondToDMs": true,
  "ignoreOwnMessages": true,
  "maxPromptLength": 3000,
  "responseTimeout": 600,
  "sessionIdleTimeout": 300
}
```

**Note**: `respondToMentions` is enabled by default. Discord bots are typically invoked via `@mention` or slash commands. Set `respondToDMs` to `false` if you want to restrict the bot to guild channels only.

## Matterbridge Integration

Discord is natively supported by [Matterbridge](https://github.com/42wim/matterbridge) using the Discord Bot API.

```text
Discord Server (Guild)
    │
    │  Discord Bot API (via bot token)
    │
Matterbridge (Go binary)
    │
    ├── Matrix rooms
    ├── Slack channels
    ├── Telegram groups
    ├── SimpleX contacts
    ├── IRC channels
    └── 40+ other platforms
```

### Matterbridge Configuration

Add to `matterbridge.toml`:

```toml
[discord.myserver]
Token = "Bot YOUR_BOT_TOKEN"
Server = "123456789012345678"  # Guild ID
## Optional: auto-create webhooks for better username display
AutoWebhooks = true
```

Gateway configuration:

```toml
[[gateway]]
name = "dev-bridge"
enable = true

[[gateway.inout]]
account = "discord.myserver"
channel = "ID:111111111111111111"  # Channel ID (use ID: prefix)

[[gateway.inout]]
account = "matrix.myserver"
channel = "#dev:matrix.example.com"
```

**Privacy warning**: Bridging Discord to E2E-encrypted platforms (Matrix, SimpleX) means those messages will be stored unencrypted on Discord's servers and subject to content scanning. Inform users on the encrypted side. See `services/communications/matterbridge.md` for full bridging considerations.

## Limitations

### No End-to-End Encryption

Discord does not support E2E encryption. All messages are readable by Discord Inc. and subject to automated content scanning. Discord's Trust & Safety operations depend on server-side content access.

### MESSAGE_CONTENT Privileged Intent

Required to read message text in guild channels. Auto-approved for <100 servers. For 100+ servers, apply through the Developer Portal — process takes weeks and requires demonstrating a valid use case.

### Rate Limits

| API | Rate Limit | Notes |
|-----|-----------|-------|
| Global | 50 requests per second | Across all routes |
| Per-route | Varies (typically 5-10/sec) | Returns `X-RateLimit-*` headers |
| `POST /channels/{id}/messages` | 5 per 5 seconds per channel | |
| Gateway | 120 events per 60 seconds | Outbound (identify, heartbeat, etc.) |
| Slash command registration (global) | 200 per day | Global commands take up to 1 hour to propagate |
| Slash command registration (guild) | 200 per day per guild | Guild commands update instantly |

discord.js handles rate limiting automatically with internal queuing.

### File Upload Limits

25 MB (free), 50 MB (Nitro Basic / Boost L2), 100 MB (Boost L3), 500 MB (Nitro). Bot uploads follow the same limits. For larger files, upload to external storage and share a link.

### Slash Command Propagation

Global slash commands take **up to 1 hour** to propagate. Use **guild-specific commands** during development (instant updates). Switch to global commands for production.

### No Self-Hosting

Cloud-only platform. No self-hosted option. All data on Google Cloud Platform. For data sovereignty, use Matrix, Mattermost, or Rocket.Chat.

### Bot Must Be in Guild

A bot can only access messages in guilds where it has been explicitly added, and only in channels where its role has View Channel permission.

## Related

- `services/communications/slack.md` — Slack bot integration (similar privacy profile, corporate focus)
- `services/communications/matrix-bot.md` — Matrix bot integration (E2E encrypted, self-hostable)
- `services/communications/simplex.md` — SimpleX Chat (no identifiers, maximum privacy)
- `services/communications/matterbridge.md` — Multi-platform chat bridging
- `scripts/entity-helper.sh` — Entity memory system (identity resolution, Layer 0/1/2)
- `scripts/runner-helper.sh` — Runner management
- `tools/security/opsec.md` — Operational security guidance
- `tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- discord.js: https://discord.js.org/
- discord.js Guide: https://discordjs.guide/
- Discord API: https://discord.com/developers/docs
- Discord Developer Portal: https://discord.com/developers/applications
- Discord Privacy Policy: https://discord.com/privacy
- Discord Transparency Report: https://discord.com/safety/transparency
