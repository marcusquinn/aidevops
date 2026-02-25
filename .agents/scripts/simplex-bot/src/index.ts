/**
 * SimpleX Bot Framework — Entry Point
 *
 * Channel-agnostic gateway with SimpleX as the first adapter.
 * Connects to SimpleX CLI via WebSocket, routes commands, handles events.
 *
 * Architecture:
 *   SimpleX CLI (WebSocket :5225)
 *       |
 *   SimplexAdapter (this file)
 *       |
 *   CommandRouter → CommandHandlers
 *       |
 *   aidevops CLI / AI model routing
 *
 * Usage:
 *   bun run src/index.ts
 *   SIMPLEX_PORT=5225 bun run src/index.ts
 *
 * Reference: t1327.4 bot framework specification
 */

import type {
  BotConfig,
  ChatItem,
  CommandContext,
  CommandDefinition,
  NewChatItemsEvent,
  SimplexCommand,
  SimplexEvent,
  SimplexResponse,
} from "./types";
import { DEFAULT_BOT_CONFIG } from "./types";
import { BUILTIN_COMMANDS } from "./commands";

// =============================================================================
// Logger
// =============================================================================

type LogLevel = "debug" | "info" | "warn" | "error";

/** Numeric priority for each log level */
const LOG_LEVELS: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

/** Level-filtered console logger for bot output */
class Logger {
  private level: number;

  /** Create a logger that filters messages below the given level */
  constructor(level: LogLevel) {
    this.level = LOG_LEVELS[level];
  }

  /** Log a debug-level message */
  debug(msg: string, ...args: unknown[]): void {
    if (this.level <= LOG_LEVELS.debug) {
      console.log(`[DEBUG] ${msg}`, ...args);
    }
  }

  /** Log an info-level message */
  info(msg: string, ...args: unknown[]): void {
    if (this.level <= LOG_LEVELS.info) {
      console.log(`[INFO] ${msg}`, ...args);
    }
  }

  /** Log a warning-level message */
  warn(msg: string, ...args: unknown[]): void {
    if (this.level <= LOG_LEVELS.warn) {
      console.warn(`[WARN] ${msg}`, ...args);
    }
  }

  /** Log an error-level message */
  error(msg: string, ...args: unknown[]): void {
    if (this.level <= LOG_LEVELS.error) {
      console.error(`[ERROR] ${msg}`, ...args);
    }
  }
}

// =============================================================================
// Command Router
// =============================================================================

/** Routes incoming messages to registered command handlers */
class CommandRouter {
  private commands: Map<string, CommandDefinition> = new Map();

  /** Register a single command definition */
  register(cmd: CommandDefinition): void {
    this.commands.set(cmd.name.toLowerCase(), cmd);
  }

  /** Register multiple command definitions at once */
  registerAll(cmds: CommandDefinition[]): void {
    for (const cmd of cmds) {
      this.register(cmd);
    }
  }

  /** Look up a command by name (case-insensitive) */
  get(name: string): CommandDefinition | undefined {
    return this.commands.get(name.toLowerCase());
  }

  /** Return all registered commands */
  list(): CommandDefinition[] {
    return Array.from(this.commands.values());
  }

  /** Parse a message into command name and args */
  parse(text: string): { command: string; args: string[] } | null {
    const trimmed = text.trim();
    if (!trimmed.startsWith("/")) {
      return null;
    }
    const parts = trimmed.slice(1).split(/\s+/);
    const command = parts[0]?.toLowerCase() ?? "";
    const args = parts.slice(1);
    return { command, args };
  }
}

// =============================================================================
// SimpleX Adapter
// =============================================================================

/** WebSocket adapter connecting to SimpleX CLI for message handling */
class SimplexAdapter {
  private ws: WebSocket | null = null;
  private config: BotConfig;
  private logger: Logger;
  private router: CommandRouter;
  private corrIdCounter = 0;
  private reconnectAttempts = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private contactNames: Map<number, string> = new Map();
  private groupNames: Map<number, string> = new Map();

  /** Initialize adapter with optional config overrides */
  constructor(config: Partial<BotConfig> = {}) {
    this.config = { ...DEFAULT_BOT_CONFIG, ...config };
    this.logger = new Logger(this.config.logLevel);
    this.router = new CommandRouter();
    this.router.registerAll(BUILTIN_COMMANDS);
  }

  /** Register a custom command */
  registerCommand(cmd: CommandDefinition): void {
    this.router.register(cmd);
    this.logger.info(`Registered command: /${cmd.name}`);
  }

  /** Connect to SimpleX CLI WebSocket */
  async connect(): Promise<void> {
    const protocol = this.config.useTls ? "wss" : "ws";
    const url = `${protocol}://${this.config.host}:${this.config.port}`;
    this.logger.info(`Connecting to SimpleX CLI at ${url}...`);

    return new Promise((resolve, reject) => {
      try {
        this.ws = new WebSocket(url);

        this.ws.onopen = () => {
          this.logger.info("Connected to SimpleX CLI");
          this.reconnectAttempts = 0;
          resolve();
        };

        this.ws.onmessage = (event: MessageEvent) => {
          this.handleMessage(String(event.data));
        };

        this.ws.onclose = () => {
          this.logger.warn("WebSocket connection closed");
          this.ws = null;
          this.scheduleReconnect();
        };

        this.ws.onerror = (event: Event) => {
          this.logger.error("WebSocket error", event);
          if (this.reconnectAttempts === 0) {
            // Clear any pending reconnect to avoid dangling timers
            this.disconnect();
            reject(new Error(`Failed to connect to ${url}`));
          }
        };
      } catch (err) {
        reject(err);
      }
    });
  }

  /** Disconnect from SimpleX CLI */
  disconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this.logger.info("Disconnected from SimpleX CLI");
  }

  /** Whether the adapter is connected */
  isConnected(): boolean {
    return this.ws !== null && this.ws.readyState === WebSocket.OPEN;
  }

  /** Send a command to SimpleX CLI */
  private async sendCommand(cmd: string): Promise<void> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      this.logger.error("Cannot send command: not connected");
      return;
    }

    this.corrIdCounter += 1;
    const command: SimplexCommand = {
      corrId: String(this.corrIdCounter),
      cmd,
    };

    this.ws.send(JSON.stringify(command));
    this.logger.debug(`Sent command: ${cmd} (corrId: ${command.corrId})`);
  }

  /** Send a text message to a contact or group */
  async sendMessage(target: string, text: string): Promise<void> {
    // target format: @contactName or #groupName
    await this.sendCommand(`${target} ${text}`);
  }

  /** Handle incoming WebSocket message */
  private handleMessage(data: string): void {
    let response: SimplexResponse;
    try {
      response = JSON.parse(data) as SimplexResponse;
    } catch {
      this.logger.warn("Failed to parse WebSocket message:", data);
      return;
    }

    // Ignore correlated responses (command results) — we only care about events
    if (response.corrId) {
      this.logger.debug(`Response for corrId ${response.corrId}:`, response.resp?.type);
      return;
    }

    const event = response.resp;
    if (!event?.type) {
      return;
    }

    switch (event.type) {
      case "newChatItems":
        this.handleNewChatItems(event as NewChatItemsEvent);
        break;
      case "contactConnected":
        this.handleContactConnected(event);
        break;
      default:
        // Tolerate unknown events (per API spec)
        this.logger.debug(`Unhandled event type: ${event.type}`);
        break;
    }
  }

  /** Cache contact and group display names from a chat item for reply routing */
  private cacheDisplayNames(chatDir: ChatItem["chatItem"]["chatDir"]): void {
    if (chatDir?.contactId !== undefined) {
      const contact = (chatDir as Record<string, unknown>).contact as
        | { localDisplayName?: string }
        | undefined;
      if (contact?.localDisplayName) {
        this.contactNames.set(chatDir.contactId, contact.localDisplayName);
      }
    }
    if (chatDir?.groupId !== undefined) {
      const groupInfo = (chatDir as Record<string, unknown>).groupInfo as
        | { localDisplayName?: string }
        | undefined;
      if (groupInfo?.localDisplayName) {
        this.groupNames.set(chatDir.groupId, groupInfo.localDisplayName);
      }
    }
  }

  /** Extract text content from a chat item, or null if not a text message */
  private extractTextContent(item: ChatItem): string | null {
    const content = item?.chatItem?.content;
    if (content?.type !== "rcvMsgContent") {
      return null;
    }
    const msgContent = content.msgContent;
    if (msgContent?.type !== "text" || !msgContent.text) {
      this.logger.debug(`Non-text message type: ${msgContent?.type}`);
      return null;
    }
    return msgContent.text;
  }

  /** Check whether a command is allowed in the current chat context */
  private isCommandAllowed(
    cmdDef: CommandDefinition,
    chatDir: ChatItem["chatItem"]["chatDir"],
  ): { allowed: boolean; reason?: string } {
    const isGroup = chatDir?.groupId !== undefined;
    const isDm = chatDir?.contactId !== undefined;
    if (isGroup && !cmdDef.groupEnabled) {
      return { allowed: false, reason: `/${cmdDef.name} is not available in group chats.` };
    }
    if (isDm && !cmdDef.dmEnabled) {
      return { allowed: false, reason: `/${cmdDef.name} is not available in direct messages.` };
    }
    return { allowed: true };
  }

  /** Handle new chat items (incoming messages) */
  private async handleNewChatItems(event: NewChatItemsEvent): Promise<void> {
    for (const item of event.chatItems ?? []) {
      const chatDir = item?.chatItem?.chatDir;
      this.cacheDisplayNames(chatDir);

      const text = this.extractTextContent(item);
      if (!text) {
        continue;
      }

      this.logger.info(`Received message: ${text.substring(0, 100)}`);

      const parsed = this.router.parse(text);
      if (!parsed) {
        this.logger.debug("Not a command, ignoring");
        continue;
      }

      const cmdDef = this.router.get(parsed.command);
      if (!cmdDef) {
        this.logger.debug(`Unknown command: /${parsed.command}`);
        await this.replyToItem(item, `Unknown command: /${parsed.command}. Type /help for available commands.`);
        continue;
      }

      const permission = this.isCommandAllowed(cmdDef, chatDir);
      if (!permission.allowed) {
        await this.replyToItem(item, permission.reason ?? "Command not allowed.");
        continue;
      }

      const ctx: CommandContext = {
        command: parsed.command,
        args: parsed.args,
        rawText: text,
        chatItem: item,
        reply: async (replyText: string) => {
          await this.replyToItem(item, replyText);
        },
      };

      try {
        await this.executeCommand(cmdDef, ctx);
      } catch (err) {
        this.logger.error(`Unhandled error in command /${parsed.command}:`, err);
      }
    }
  }

  /** Execute a command handler */
  private async executeCommand(
    cmdDef: CommandDefinition,
    ctx: CommandContext,
  ): Promise<void> {
    try {
      this.logger.info(`Executing command: /${cmdDef.name}`);
      const result = await cmdDef.handler(ctx);
      if (result) {
        await ctx.reply(result);
      }
    } catch (err) {
      this.logger.error(`Command /${cmdDef.name} failed:`, err);
      await ctx.reply(`Error executing /${cmdDef.name}: ${String(err)}`);
    }
  }

  /** Reply to a chat item using cached display names */
  private async replyToItem(item: ChatItem, text: string): Promise<void> {
    const chatDir = item?.chatItem?.chatDir;
    if (!chatDir) {
      this.logger.warn("Cannot reply: no chat direction info");
      return;
    }

    let target: string;
    if (chatDir.contactId !== undefined) {
      const displayName = this.contactNames.get(chatDir.contactId);
      if (!displayName) {
        this.logger.warn(
          `Cannot reply: no cached display name for contactId ${chatDir.contactId}`,
        );
        return;
      }
      target = `@${displayName}`;
    } else if (chatDir.groupId !== undefined) {
      const displayName = this.groupNames.get(chatDir.groupId);
      if (!displayName) {
        this.logger.warn(
          `Cannot reply: no cached display name for groupId ${chatDir.groupId}`,
        );
        return;
      }
      target = `#${displayName}`;
    } else {
      this.logger.warn("Cannot reply: unknown chat direction");
      return;
    }

    await this.sendMessage(target, text);
  }

  /** Handle new contact connection — caches display name for reply routing */
  private handleContactConnected(event: SimplexEvent): void {
    const contact = (event as Record<string, unknown>).contact as
      | { localDisplayName?: string; contactId?: number }
      | undefined;
    const name = contact?.localDisplayName ?? "unknown";
    this.logger.info(`New contact connected: ${name}`);

    // Cache display name for reply routing
    if (contact?.contactId !== undefined && contact.localDisplayName) {
      this.contactNames.set(contact.contactId, contact.localDisplayName);
    }

    if (this.config.autoAcceptContacts && this.config.welcomeMessage) {
      this.sendMessage(`@${name}`, this.config.welcomeMessage).catch((err) => {
        this.logger.error(`Failed to send welcome message to ${name}:`, err);
      });
    }
  }

  /** Schedule reconnection attempt with linear backoff (capped at 6x interval) */
  private scheduleReconnect(): void {
    if (
      this.config.maxReconnectAttempts > 0 &&
      this.reconnectAttempts >= this.config.maxReconnectAttempts
    ) {
      this.logger.error(
        `Max reconnect attempts (${this.config.maxReconnectAttempts}) reached. Giving up.`,
      );
      return;
    }

    this.reconnectAttempts += 1;
    const delay = this.config.reconnectInterval * Math.min(this.reconnectAttempts, 6);
    this.logger.info(
      `Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts})...`,
    );

    this.reconnectTimer = setTimeout(async () => {
      try {
        await this.connect();
      } catch {
        this.logger.error("Reconnection failed");
      }
    }, delay);
  }
}

// =============================================================================
// Main
// =============================================================================

/** Validate and parse log level from environment */
function parseLogLevel(value: string | undefined): LogLevel {
  const valid: LogLevel[] = ["debug", "info", "warn", "error"];
  if (value && valid.includes(value as LogLevel)) {
    return value as LogLevel;
  }
  return DEFAULT_BOT_CONFIG.logLevel;
}

/** Entry point — configure and start the bot */
async function main(): Promise<void> {
  const config: Partial<BotConfig> = {
    port: Number(process.env.SIMPLEX_PORT) || DEFAULT_BOT_CONFIG.port,
    host: process.env.SIMPLEX_HOST || DEFAULT_BOT_CONFIG.host,
    displayName: process.env.SIMPLEX_BOT_NAME || DEFAULT_BOT_CONFIG.displayName,
    autoAcceptContacts: process.env.SIMPLEX_AUTO_ACCEPT === "true",
    logLevel: parseLogLevel(process.env.SIMPLEX_LOG_LEVEL),
  };

  const bot = new SimplexAdapter(config);

  // Graceful shutdown
  process.on("SIGINT", () => {
    console.log("\nShutting down...");
    bot.disconnect();
    process.exit(0);
  });

  process.on("SIGTERM", () => {
    bot.disconnect();
    process.exit(0);
  });

  try {
    await bot.connect();
    console.log("SimpleX bot is running. Press Ctrl+C to stop.");
  } catch (err) {
    console.error("Failed to start bot:", err);
    console.error(
      "\nMake sure SimpleX CLI is running as WebSocket server:",
    );
    console.error(`  simplex-chat -p ${config.port ?? 5225}`);
    process.exit(1);
  }
}

main();
