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
  CommandDefinition,
  ContactInfo,
  ExecApprovalConfig,
  GroupInfo,
  NewChatItemsEvent,
  SimplexCommand,
  SimplexEvent,
  SimplexResponse,
} from "./types";
import { DEFAULT_BOT_CONFIG, DEFAULT_EXEC_APPROVAL_CONFIG } from "./types";
import { BUILTIN_COMMANDS, getApprovalManager, setApprovalManager } from "./commands";
import { ApprovalManager } from "./approval";
import { scanForLeaks, redactLeaks, formatLeakWarning } from "./leak-detector";
import { loadConfig } from "./config";
import { SessionStore } from "./session";
import { Logger } from "./logger";
import { CommandRouter } from "./router";
import {
  handleContactConnected,
  handleContactRequest,
  handleBusinessRequest,
  handleNewChatItems,
  handleGroupInvitation,
  handleMemberJoined,
  handleBotRemovedFromGroup,
  handleMemberConnected,
  handleFileReady,
  handleFileComplete,
  handleNonTextMessage,
} from "./handlers";

// Re-export for consumers that import from this module
export { Logger } from "./logger";
export { CommandRouter } from "./router";

// =============================================================================
// SimpleX Adapter
// =============================================================================

/** WebSocket adapter connecting to SimpleX CLI for message handling */
export class SimplexAdapter {
  private ws: WebSocket | null = null;
  private config: BotConfig;
  private logger: Logger;
  private router: CommandRouter;
  private sessions: SessionStore;
  private corrIdCounter = 0;
  private reconnectAttempts = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private intentionalDisconnect = false;
  private hasConnected = false;
  private contactNames: Map<number, string> = new Map();
  private groupNames: Map<number, string> = new Map();

  /** Initialize adapter with config (use loadConfig() for file-based config) */
  constructor(config: BotConfig) {
    this.config = config;
    this.logger = new Logger(this.config.logLevel);
    this.router = new CommandRouter();
    this.router.registerAll(BUILTIN_COMMANDS);
    this.sessions = new SessionStore(this.config.dataDir);

    // Initialise the exec approval manager with config
    const approvalConfig: Partial<ExecApprovalConfig> = this.config.execApproval ?? {};
    setApprovalManager(new ApprovalManager(approvalConfig));
    this.logger.info("Exec approval flow initialised");
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
      let settled = false;

      try {
        this.ws = new WebSocket(url);

        this.ws.onopen = () => {
          settled = true;
          this.logger.info("Connected to SimpleX CLI");
          this.reconnectAttempts = 0;
          this.hasConnected = true;
          resolve();
        };

        this.ws.onmessage = (event: MessageEvent) => {
          this.handleMessage(String(event.data));
        };

        this.ws.onclose = () => {
          this.logger.warn("WebSocket connection closed");
          this.ws = null;
          if (!this.intentionalDisconnect) {
            this.scheduleReconnect();
          }
          this.intentionalDisconnect = false;
          if (!settled) {
            settled = true;
            reject(new Error(`Connection to ${url} closed before opening`));
          }
        };

        this.ws.onerror = (event: Event) => {
          this.logger.error("WebSocket error", event);
          if (!this.hasConnected && this.ws) {
            this.intentionalDisconnect = true;
            this.ws.close();
            this.ws = null;
          }
        };
      } catch (err) {
        if (!settled) {
          settled = true;
          reject(err);
        }
      }
    });
  }

  /** Disconnect from SimpleX CLI (suppresses reconnect scheduling) */
  disconnect(): void {
    this.intentionalDisconnect = true;
    this.hasConnected = false;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this.sessions.close();
    // Clean up approval manager timers
    getApprovalManager().shutdown();
    this.logger.info("Disconnected from SimpleX CLI");
  }

  /** Whether the adapter is connected */
  isConnected(): boolean {
    return this.ws !== null && this.ws.readyState === WebSocket.OPEN;
  }

  /** Send a command to SimpleX CLI */
  async sendCommand(cmd: string): Promise<void> {
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

  /** Send a text message to a contact or group (gated by leak detection) */
  async sendMessage(target: string, text: string): Promise<void> {
    // target format: @contactName or #groupName
    const safeText = this.scanAndRedact(text);
    await this.sendCommand(`${target} ${safeText}`);
  }

  /**
   * Scan outbound text for credential/secret leaks and redact if found.
   * This is the send-boundary gate — all outbound messages pass through here.
   */
  private scanAndRedact(text: string): string {
    if (!this.config.leakDetection.enabled) {
      return text;
    }

    const result = scanForLeaks(text, this.config.leakDetection);
    if (!result.hasLeaks) {
      return text;
    }

    this.logger.warn(formatLeakWarning(result));
    return redactLeaks(text, result);
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

    if (response.corrId) {
      this.logger.debug(`Response for corrId ${response.corrId}:`, response.resp?.type);
      return;
    }

    const event = response.resp;
    if (!event?.type) {
      return;
    }

    this.dispatchEvent(event);
  }

  /** Dispatch an event to the appropriate handler */
  private dispatchEvent(event: SimplexEvent): void {
    const contactDeps = {
      config: this.config,
      logger: this.logger,
      sessions: this.sessions,
      sendCommand: (cmd: string) => this.sendCommand(cmd),
      cacheContactName: (id: number, name: string) => this.contactNames.set(id, name),
      cacheGroupName: (id: number, name: string) => this.groupNames.set(id, name),
    };

    const groupDeps = {
      logger: this.logger,
      sessions: this.sessions,
      sendCommand: (cmd: string) => this.sendCommand(cmd),
      cacheGroupName: (id: number, name: string) => this.groupNames.set(id, name),
      autoJoinGroups: this.config.autoJoinGroups,
    };

    const fileDeps = {
      logger: this.logger,
      sessions: this.sessions,
      sendCommand: (cmd: string) => this.sendCommand(cmd),
      replyToItem: (item: ChatItem, text: string) => this.replyToItem(item, text),
      autoAcceptFiles: this.config.autoAcceptFiles,
      maxFileSize: this.config.maxFileSize,
    };

    const messageDeps = {
      logger: this.logger,
      router: this.router,
      sessions: this.sessions,
      replyToItem: (item: ChatItem, text: string) => this.replyToItem(item, text),
      cacheContactName: (id: number, name: string) => this.contactNames.set(id, name),
      cacheGroupName: (id: number, name: string) => this.groupNames.set(id, name),
      buildContactInfo: (id: number): ContactInfo => {
        const name = this.contactNames.get(id) ?? "";
        return { contactId: id, localDisplayName: name, profile: { displayName: name } };
      },
      buildGroupInfo: (id: number): GroupInfo => {
        const name = this.groupNames.get(id) ?? "";
        return { groupId: id, localDisplayName: name, groupProfile: { displayName: name } };
      },
      onNonTextMessage: (item: ChatItem, msgType: string) =>
        handleNonTextMessage(item, msgType, fileDeps),
    };

    // Handler map: event type → [handler function, deps object]
    const handlers: Record<string, [Function, unknown]> = {
      newChatItems: [handleNewChatItems, messageDeps],
      contactConnected: [handleContactConnected, contactDeps],
      receivedContactRequest: [handleContactRequest, contactDeps],
      acceptingBusinessRequest: [handleBusinessRequest, contactDeps],
      receivedGroupInvitation: [handleGroupInvitation, groupDeps],
      joinedGroupMember: [handleMemberJoined, groupDeps],
      deletedMemberUser: [handleBotRemovedFromGroup, groupDeps],
      memberConnected: [handleMemberConnected, groupDeps],
      rcvFileDescrReady: [handleFileReady, fileDeps],
      rcvFileComplete: [handleFileComplete, fileDeps],
    };

    const entry = handlers[event.type];
    if (entry) {
      const [handler, deps] = entry;
      void handler(event, deps).catch((err: unknown) => {
        this.logger.error(`Error handling ${event.type}:`, err);
      });
    } else {
      this.logger.debug(`Unhandled event type: ${event.type}`);
    }
  }

  /** Resolve a chat direction to a @contact or #group target string, or null. */
  private resolveTarget(chatDir: { contactId?: number; groupId?: number }): string | null {
    if (chatDir.contactId !== undefined) {
      const name = this.contactNames.get(chatDir.contactId);
      return name ? `@${name}` : null;
    }
    if (chatDir.groupId !== undefined) {
      const name = this.groupNames.get(chatDir.groupId);
      return name ? `#${name}` : null;
    }
    return null;
  }

  /** Reply to a chat item using cached display names */
  private async replyToItem(item: ChatItem, text: string): Promise<void> {
    const chatDir = item?.chatItem?.chatDir;
    if (!chatDir) {
      this.logger.warn("Cannot reply: no chat direction info");
      return;
    }

    const target = this.resolveTarget(chatDir);
    if (!target) {
      this.logger.warn("Cannot reply: no cached display name for chat target");
      return;
    }

    await this.sendMessage(target, text);
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

// Entry point moved to start.ts — run with: bun run src/start.ts
