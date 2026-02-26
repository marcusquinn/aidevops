/**
 * SimpleX Bot — Command Execution
 *
 * Handles command routing, permission checking, context building, and execution.
 * Extracted from message.ts to keep per-file complexity low.
 */

import type {
  ChatItem,
  CommandContext,
  CommandDefinition,
} from "../types";
import type { MessageHandlerDeps } from "./message";

/** Check whether a command is allowed in the current chat context */
export function checkCommandPermission(
  cmdDef: CommandDefinition,
  chatDir: NonNullable<ChatItem["chatItem"]["chatDir"]>,
): { allowed: boolean; reason?: string } {
  const isGroup = chatDir.groupId !== undefined;
  const isDm = chatDir.contactId !== undefined;

  if (isGroup && !cmdDef.groupEnabled) {
    return {
      allowed: false,
      reason: `/${cmdDef.name} is not available in group chats.`,
    };
  }
  if (isDm && !cmdDef.dmEnabled) {
    return {
      allowed: false,
      reason: `/${cmdDef.name} is not available in direct messages.`,
    };
  }
  return { allowed: true };
}

/** Build a CommandContext for the handler */
export function buildCommandContext(
  item: ChatItem,
  parsed: { command: string; args: string[] },
  chatDir: NonNullable<ChatItem["chatItem"]["chatDir"]>,
  deps: MessageHandlerDeps,
): CommandContext {
  return {
    command: parsed.command,
    args: parsed.args,
    rawText: item.chatItem.content.msgContent.text ?? "",
    chatItem: item,
    contact:
      chatDir.contactId !== undefined
        ? deps.buildContactInfo(chatDir.contactId)
        : undefined,
    group:
      chatDir.groupId !== undefined
        ? deps.buildGroupInfo(chatDir.groupId)
        : undefined,
    reply: async (replyText: string) => {
      await deps.replyToItem(item, replyText);
    },
  };
}

/** Execute a command handler with error handling */
export async function executeCommand(
  cmdDef: CommandDefinition,
  ctx: CommandContext,
  deps: MessageHandlerDeps,
): Promise<void> {
  try {
    deps.logger.info(`Executing command: /${cmdDef.name}`);

    // Track last command in session metadata
    const sessionId = ctx.contact
      ? `direct:${ctx.contact.contactId}`
      : ctx.group
        ? `group:${ctx.group.groupId}`
        : null;
    if (sessionId) {
      deps.sessions.updateMetadata(sessionId, {
        lastCommand: `/${cmdDef.name}`,
      });
    }

    const result = await cmdDef.handler(ctx);
    if (result) {
      await ctx.reply(result);
    }
  } catch (err) {
    deps.logger.error(`Command /${cmdDef.name} failed:`, err);
    await ctx.reply(`Error executing /${cmdDef.name}: ${String(err)}`);
  }
}
