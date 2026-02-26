/**
 * SimpleX Bot — Group Event Handlers
 *
 * Handles group lifecycle events:
 * - receivedGroupInvitation: bot invited to a group
 * - joinedGroupMember: new member joined a group
 * - deletedMemberUser: bot removed from a group
 * - memberConnected: member fully connected to group
 *
 * Reference: t1327.1 research, section 4.1 (Essential Events for Bots)
 */

import type {
  SimplexEvent,
  GroupInvitationEvent,
  GroupMemberEvent,
} from "../types";
import type { SessionStore } from "../session";

/** Logger interface */
interface Logger {
  debug(msg: string, ...args: unknown[]): void;
  info(msg: string, ...args: unknown[]): void;
  warn(msg: string, ...args: unknown[]): void;
  error(msg: string, ...args: unknown[]): void;
}

/** Callback to send a SimpleX CLI command */
type SendCommand = (cmd: string) => Promise<void>;

/** Group handler dependencies */
export interface GroupHandlerDeps {
  logger: Logger;
  sessions: SessionStore;
  sendCommand: SendCommand;
  /** Cache a group display name for reply routing */
  cacheGroupName: (groupId: number, displayName: string) => void;
  /** Whether to auto-join group invitations */
  autoJoinGroups: boolean;
}

/**
 * Handle receivedGroupInvitation event.
 * Fired when the bot is invited to a group.
 * Auto-joins if configured, otherwise logs for manual approval.
 */
export async function handleGroupInvitation(
  event: SimplexEvent,
  deps: GroupHandlerDeps,
): Promise<void> {
  const inviteEvent = event as GroupInvitationEvent;
  const groupInfo = inviteEvent.groupInfo;

  if (!groupInfo) {
    deps.logger.warn("receivedGroupInvitation event missing groupInfo");
    return;
  }

  const groupId = groupInfo.groupId;
  const name = groupInfo.localDisplayName ?? `group-${groupId}`;

  deps.logger.info(`Group invitation received: ${name} (groupId: ${groupId})`);

  // Cache group name
  deps.cacheGroupName(groupId, name);

  if (deps.autoJoinGroups) {
    deps.logger.info(`Auto-joining group: ${name}`);
    try {
      await deps.sendCommand(`/_join #${groupId}`);
      // Create session for the group
      deps.sessions.getGroupSession(groupId, name);
    } catch (err) {
      deps.logger.error(`Failed to join group ${name}:`, err);
    }
  } else {
    deps.logger.info(
      `Group invitation from ${name} pending manual approval (groupId: ${groupId})`,
    );
  }
}

/**
 * Handle joinedGroupMember event.
 * Fired when a new member joins a group the bot is in.
 * Optionally sends a welcome message.
 */
export async function handleMemberJoined(
  event: SimplexEvent,
  deps: GroupHandlerDeps,
): Promise<void> {
  const memberEvent = event as GroupMemberEvent;
  const groupInfo = memberEvent.groupInfo;
  const member = memberEvent.member;

  if (!groupInfo || !member) {
    deps.logger.debug("joinedGroupMember event missing groupInfo or member");
    return;
  }

  const groupName = groupInfo.localDisplayName ?? `group-${groupInfo.groupId}`;
  const memberName = member.localDisplayName ?? "unknown";

  deps.logger.info(
    `Member joined group ${groupName}: ${memberName}`,
  );

  // Update session activity
  deps.sessions.getGroupSession(groupInfo.groupId, groupName);
}

/**
 * Handle deletedMemberUser event.
 * Fired when the bot is removed from a group.
 * Cleans up the session.
 */
export async function handleBotRemovedFromGroup(
  event: SimplexEvent,
  deps: GroupHandlerDeps,
): Promise<void> {
  const memberEvent = event as GroupMemberEvent;
  const groupInfo = memberEvent.groupInfo;

  if (!groupInfo) {
    deps.logger.warn("deletedMemberUser event missing groupInfo");
    return;
  }

  const groupId = groupInfo.groupId;
  const name = groupInfo.localDisplayName ?? `group-${groupId}`;

  deps.logger.info(`Bot removed from group: ${name} (groupId: ${groupId})`);

  // Clean up session
  deps.sessions.deleteSession(`group:${groupId}`);
}

/**
 * Handle memberConnected event.
 * Fired when a group member's connection is fully established.
 * Useful for knowing when a member can receive messages.
 */
export async function handleMemberConnected(
  event: SimplexEvent,
  deps: GroupHandlerDeps,
): Promise<void> {
  const memberEvent = event as GroupMemberEvent;
  const groupInfo = memberEvent.groupInfo;
  const member = memberEvent.member;

  if (!groupInfo || !member) {
    deps.logger.debug("memberConnected event missing data");
    return;
  }

  const groupName = groupInfo.localDisplayName ?? `group-${groupInfo.groupId}`;
  const memberName = member.localDisplayName ?? "unknown";

  deps.logger.debug(
    `Member connected in ${groupName}: ${memberName}`,
  );
}
