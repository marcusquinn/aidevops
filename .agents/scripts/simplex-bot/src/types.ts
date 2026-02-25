/**
 * SimpleX Bot Framework — Type Definitions
 *
 * Types for the SimpleX WebSocket JSON API, bot commands, events,
 * and the channel-agnostic gateway architecture.
 *
 * Reference: https://github.com/simplex-chat/simplex-chat/tree/stable/bots/api
 */

// =============================================================================
// WebSocket API Types
// =============================================================================

/** Command sent to SimpleX CLI via WebSocket */
export interface SimplexCommand {
  corrId: string;
  cmd: string;
}

/** Response from SimpleX CLI via WebSocket */
export interface SimplexResponse {
  corrId?: string;
  resp: SimplexEvent;
}

/** Base event type from SimpleX CLI */
export interface SimplexEvent {
  type: string;
  [key: string]: unknown;
}

// =============================================================================
// Chat Item Types
// =============================================================================

/** Message content types */
export type MessageContentType =
  | "text"
  | "link"
  | "image"
  | "video"
  | "voice"
  | "file";

/** Message content from SimpleX */
export interface MessageContent {
  type: MessageContentType;
  text?: string;
  fileName?: string;
  fileSize?: number;
  filePath?: string;
}

/** Chat item content wrapper */
export interface ChatItemContent {
  type: "rcvMsgContent" | "sndMsgContent";
  msgContent: MessageContent;
}

/** A single chat item (message) */
export interface ChatItem {
  chatItem: {
    content: ChatItemContent;
    chatDir?: {
      type: string;
      contactId?: number;
      groupId?: number;
    };
    meta?: {
      itemId: number;
      itemTs: string;
      createdAt: string;
    };
  };
}

/** New chat items event */
export interface NewChatItemsEvent extends SimplexEvent {
  type: "newChatItems";
  chatItems: ChatItem[];
}

/** Contact connected event */
export interface ContactConnectedEvent extends SimplexEvent {
  type: "contactConnected";
  contact: ContactInfo;
}

/** Contact info */
export interface ContactInfo {
  contactId: number;
  localDisplayName: string;
  profile: {
    displayName: string;
    fullName?: string;
    image?: string;
    contactLink?: string;
    preferences?: Record<string, unknown>;
  };
}

/** Group info */
export interface GroupInfo {
  groupId: number;
  localDisplayName: string;
  groupProfile: {
    displayName: string;
    fullName?: string;
    description?: string;
    image?: string;
  };
}

// =============================================================================
// Bot Command Types
// =============================================================================

/** Bot command handler function */
export type CommandHandler = (
  ctx: CommandContext,
) => Promise<string | void>;

/** Context passed to command handlers */
export interface CommandContext {
  /** The raw command string (e.g., "/status") */
  command: string;
  /** Arguments after the command */
  args: string[];
  /** Full raw text of the message */
  rawText: string;
  /** Contact who sent the message (if DM) */
  contact?: ContactInfo;
  /** Group the message was sent in (if group) */
  group?: GroupInfo;
  /** The chat item that triggered this command */
  chatItem: ChatItem;
  /** Send a reply to the sender */
  reply: (text: string) => Promise<void>;
}

/** Registered command definition */
export interface CommandDefinition {
  /** Command name without slash (e.g., "help") */
  name: string;
  /** Short description for help menu */
  description: string;
  /** Handler function */
  handler: CommandHandler;
  /** Whether this command is available in groups */
  groupEnabled: boolean;
  /** Whether this command is available in DMs */
  dmEnabled: boolean;
}

// =============================================================================
// Bot Configuration
// =============================================================================

/** Bot configuration */
export interface BotConfig {
  /** WebSocket port for SimpleX CLI (default: 5225) */
  port: number;
  /** WebSocket host (default: 127.0.0.1) */
  host: string;
  /** Bot display name */
  displayName: string;
  /** Auto-accept contact requests */
  autoAcceptContacts: boolean;
  /** Welcome message for new contacts */
  welcomeMessage?: string;
  /** Log level */
  logLevel: "debug" | "info" | "warn" | "error";
  /** Reconnect interval in ms (default: 5000) */
  reconnectInterval: number;
  /** Maximum reconnect attempts (default: 10, 0 = infinite) */
  maxReconnectAttempts: number;
}

/** Default bot configuration */
export const DEFAULT_BOT_CONFIG: BotConfig = {
  port: 5225,
  host: "127.0.0.1",
  displayName: "AIBot",
  autoAcceptContacts: false,
  welcomeMessage: "Hello! I'm an aidevops bot. Type /help for available commands.",
  logLevel: "info",
  reconnectInterval: 5000,
  maxReconnectAttempts: 10,
};

// =============================================================================
// Channel-Agnostic Gateway Types
// =============================================================================

/** Channel adapter interface — SimpleX is the first adapter */
export interface ChannelAdapter {
  /** Unique name for this channel */
  name: string;
  /** Connect to the channel */
  connect(): Promise<void>;
  /** Disconnect from the channel */
  disconnect(): Promise<void>;
  /** Send a message to a target */
  send(target: string, message: string): Promise<void>;
  /** Whether the adapter is connected */
  isConnected(): boolean;
}

/** Gateway event types */
export type GatewayEventType =
  | "message"
  | "command"
  | "connect"
  | "disconnect"
  | "error";

/** Gateway event */
export interface GatewayEvent {
  type: GatewayEventType;
  channel: string;
  timestamp: Date;
  data: unknown;
}
