/**
 * SimpleX Bot — Contact Event Handlers
 *
 * Handles contact lifecycle events:
 * - contactConnected: new contact connected via address
 * - receivedContactRequest: incoming contact request (when auto-accept is off)
 * - acceptingBusinessRequest: new business address connection
 *
 * Reference: t1327.1 research, section 4.1 (Essential Events for Bots)
 */

import type {
  BotConfig,
  ContactConnectedEvent,
  ContactRequestEvent,
  BusinessRequestEvent,
  SimplexEvent,
} from "../types";
import type { SessionStore } from "../session";

/** Logger interface (matches the Logger class in index.ts) */
interface Logger {
  debug(msg: string, ...args: unknown[]): void;
  info(msg: string, ...args: unknown[]): void;
  warn(msg: string, ...args: unknown[]): void;
  error(msg: string, ...args: unknown[]): void;
}

/** Callback to send a SimpleX CLI command */
type SendCommand = (cmd: string) => Promise<void>;

/** Contact handler dependencies */
export interface ContactHandlerDeps {
  config: BotConfig;
  logger: Logger;
  sessions: SessionStore;
  sendCommand: SendCommand;
  /** Cache a contact display name for reply routing */
  cacheContactName: (contactId: number, displayName: string) => void;
  /** Cache a group display name for reply routing */
  cacheGroupName: (groupId: number, displayName: string) => void;
}

/**
 * Handle contactConnected event.
 * Fired when a user connects via the bot's address.
 * Caches display name, creates session, sends welcome message.
 */
export async function handleContactConnected(
  event: SimplexEvent,
  deps: ContactHandlerDeps,
): Promise<void> {
  const contactEvent = event as ContactConnectedEvent;
  const contact = contactEvent.contact;

  if (!contact) {
    deps.logger.warn("contactConnected event missing contact data");
    return;
  }

  const name = contact.localDisplayName ?? "unknown";
  const contactId = contact.contactId;

  deps.logger.info(`New contact connected: ${name} (id: ${contactId})`);

  // Cache display name for reply routing
  if (contactId !== undefined) {
    deps.cacheContactName(contactId, name);
  }

  // Create or update session
  deps.sessions.getContactSession(contactId, name);

  // Send welcome message if configured
  if (deps.config.autoAcceptContacts && deps.config.welcomeMessage) {
    try {
      await deps.sendCommand(`@${name} ${deps.config.welcomeMessage}`);
    } catch (err) {
      deps.logger.error(`Failed to send welcome message to ${name}:`, err);
    }
  }
}

/**
 * Handle receivedContactRequest event.
 * Fired when auto-accept is off and a new contact request arrives.
 * If auto-accept is enabled in config, accepts automatically.
 */
export async function handleContactRequest(
  event: SimplexEvent,
  deps: ContactHandlerDeps,
): Promise<void> {
  const requestEvent = event as ContactRequestEvent;
  const contactRequest = requestEvent.contactRequest;

  if (!contactRequest) {
    deps.logger.warn("receivedContactRequest event missing contactRequest data");
    return;
  }

  const name = contactRequest.localDisplayName ?? "unknown";
  const reqId = contactRequest.contactRequestId;

  deps.logger.info(`Contact request from: ${name} (reqId: ${reqId})`);

  if (deps.config.autoAcceptContacts) {
    deps.logger.info(`Auto-accepting contact request from ${name}`);
    try {
      await deps.sendCommand(`/_accept ${reqId}`);
    } catch (err) {
      deps.logger.error(`Failed to accept contact request from ${name}:`, err);
    }
  } else {
    deps.logger.info(
      `Contact request from ${name} pending manual approval (reqId: ${reqId})`,
    );
  }
}

/**
 * Handle acceptingBusinessRequest event.
 * Fired when a user connects via a business address.
 * Creates a group chat per customer (business address pattern).
 */
export async function handleBusinessRequest(
  event: SimplexEvent,
  deps: ContactHandlerDeps,
): Promise<void> {
  const bizEvent = event as BusinessRequestEvent;
  const groupInfo = bizEvent.groupInfo;

  if (!groupInfo) {
    deps.logger.warn("acceptingBusinessRequest event missing groupInfo");
    return;
  }

  const groupId = groupInfo.groupId;
  const name = groupInfo.localDisplayName ?? `business-${groupId}`;

  deps.logger.info(
    `Business request: new customer group created (groupId: ${groupId}, name: ${name})`,
  );

  // Cache group name for reply routing
  deps.cacheGroupName(groupId, name);

  // Create session with business metadata
  const session = deps.sessions.getGroupSession(groupId, name);
  deps.sessions.updateMetadata(session.id, { businessChat: true });

  // Send welcome message to the business group
  if (deps.config.welcomeMessage) {
    try {
      await deps.sendCommand(`#${name} ${deps.config.welcomeMessage}`);
    } catch (err) {
      deps.logger.error(
        `Failed to send welcome to business group ${name}:`,
        err,
      );
    }
  }
}
