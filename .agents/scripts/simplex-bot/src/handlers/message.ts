/**
 * SimpleX Bot — Message Event Handler
 *
 * Handles newChatItems events (incoming messages).
 * Extracts text content, routes to command handler or ignores non-commands.
 *
 * Reference: t1327.1 research, section 4.2 (Message Event Structure)
 */

import type {
  ChatItem,
  CommandDefinition,
  ContactInfo,
  GroupInfo,
  NewChatItemsEvent,
} from "../types";
import type { SessionStore } from "../session";
import { checkCommandPermission, buildCommandContext, executeCommand } from "./command-executor";

/** Logger interface */
interface Logger {
  debug(msg: string, ...args: unknown[]): void;
  info(msg: string, ...args: unknown[]): void;
  warn(msg: string, ...args: unknown[]): void;
  error(msg: string, ...args: unknown[]): void;
}

/** Command router interface */
interface CommandRouter {
  parse(text: string): { command: string; args: string[] } | null;
  get(name: string): CommandDefinition | undefined;
}

/** Message handler dependencies */
export interface MessageHandlerDeps {
  logger: Logger;
  router: CommandRouter;
  sessions: SessionStore;
  /** Send a reply to a chat item */
  replyToItem: (item: ChatItem, text: string) => Promise<void>;
  /** Cache a contact display name */
  cacheContactName: (contactId: number, displayName: string) => void;
  /** Cache a group display name */
  cacheGroupName: (groupId: number, displayName: string) => void;
  /** Build ContactInfo from cached data */
  buildContactInfo: (contactId: number) => ContactInfo;
  /** Build GroupInfo from cached data */
  buildGroupInfo: (groupId: number) => GroupInfo;
  /** Callback for non-text messages (voice, file, image) */
  onNonTextMessage?: (item: ChatItem, msgType: string) => Promise<void>;
}

// Re-export command execution utilities for external consumers
export { checkCommandPermission, buildCommandContext, executeCommand } from "./command-executor";

/**
 * Handle newChatItems event.
 * Processes each chat item: extracts text, routes commands, tracks sessions.
 */
export async function handleNewChatItems(
  event: NewChatItemsEvent,
  deps: MessageHandlerDeps,
): Promise<void> {
  for (const item of event.chatItems ?? []) {
    try {
      await processItem(item, deps);
    } catch (err) {
      deps.logger.error("Error processing chat item:", err);
    }
  }
}

/**
 * Extract text content from a chat item, handling non-text message routing.
 * Returns the text string if this is a text message, or null otherwise.
 */
export async function extractTextContent(
  item: ChatItem,
  deps: MessageHandlerDeps,
): Promise<string | null> {
  const content = item?.chatItem?.content;
  if (content?.type !== "rcvMsgContent") return null;

  const msgContent = content.msgContent;
  if (!msgContent) return null;

  if (msgContent.type !== "text") {
    deps.logger.debug(`Non-text message type: ${msgContent.type}`);
    if (deps.onNonTextMessage) {
      await deps.onNonTextMessage(item, msgContent.type);
    }
    return null;
  }

  return msgContent.text || null;
}

/** Route a parsed command to its handler */
export async function routeCommand(
  item: ChatItem,
  text: string,
  chatDir: NonNullable<ChatItem["chatItem"]["chatDir"]>,
  deps: MessageHandlerDeps,
): Promise<void> {
  const parsed = deps.router.parse(text);
  if (!parsed) {
    deps.logger.debug("Not a command, ignoring");
    return;
  }

  const cmdDef = deps.router.get(parsed.command);
  if (!cmdDef) {
    deps.logger.debug(`Unknown command: /${parsed.command}`);
    await deps.replyToItem(
      item,
      `Unknown command: /${parsed.command}. Type /help for available commands.`,
    );
    return;
  }

  const permission = checkCommandPermission(cmdDef, chatDir);
  if (!permission.allowed) {
    await deps.replyToItem(item, permission.reason ?? "Command not allowed.");
    return;
  }

  const ctx = buildCommandContext(item, parsed, chatDir, deps);
  await executeCommand(cmdDef, ctx, deps);
}

/** Process a single chat item */
export async function processItem(
  item: ChatItem,
  deps: MessageHandlerDeps,
): Promise<void> {
  const chatDir = item?.chatItem?.chatDir;
  if (!chatDir) return;

  // Cache display names from incoming messages
  cacheContactDisplayName(chatDir, deps);
  cacheGroupDisplayName(chatDir, deps);

  // Track session activity
  trackSession(chatDir, deps);

  // Extract text content (routes non-text messages internally)
  const text = await extractTextContent(item, deps);
  if (!text) return;

  deps.logger.debug(`Received message: ${text.substring(0, 100)}`);
  await routeCommand(item, text, chatDir, deps);
}

/** Cache a contact display name if present in the chat direction */
export function cacheContactDisplayName(
  chatDir: NonNullable<ChatItem["chatItem"]["chatDir"]>,
  deps: MessageHandlerDeps,
): void {
  if (chatDir.contactId === undefined) return;
  const name = chatDir.contact?.localDisplayName;
  if (name) deps.cacheContactName(chatDir.contactId, name);
}

/** Cache a group display name if present in the chat direction */
export function cacheGroupDisplayName(
  chatDir: NonNullable<ChatItem["chatItem"]["chatDir"]>,
  deps: MessageHandlerDeps,
): void {
  if (chatDir.groupId === undefined) return;
  const name = chatDir.groupInfo?.localDisplayName;
  if (name) deps.cacheGroupName(chatDir.groupId, name);
}

/** Track session activity for the chat */
export function trackSession(
  chatDir: NonNullable<ChatItem["chatItem"]["chatDir"]>,
  deps: MessageHandlerDeps,
): void {
  if (chatDir.contactId !== undefined) {
    const session = deps.sessions.getContactSession(
      chatDir.contactId,
      chatDir.contact?.localDisplayName,
    );
    deps.sessions.recordMessage(session.id);
  } else if (chatDir.groupId !== undefined) {
    const session = deps.sessions.getGroupSession(
      chatDir.groupId,
      chatDir.groupInfo?.localDisplayName,
    );
    deps.sessions.recordMessage(session.id);
  }
}
