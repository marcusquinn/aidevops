/**
 * SimpleX Bot — Handler Barrel Export
 *
 * Re-exports all event handlers for clean imports.
 */

export {
  handleContactConnected,
  handleContactRequest,
  handleBusinessRequest,
} from "./contact";
export type { ContactHandlerDeps } from "./contact";

export { handleNewChatItems } from "./message";
export type { MessageHandlerDeps } from "./message";

export {
  handleGroupInvitation,
  handleMemberJoined,
  handleBotRemovedFromGroup,
  handleMemberConnected,
} from "./group";
export type { GroupHandlerDeps } from "./group";

export {
  handleFileReady,
  handleFileComplete,
  handleNonTextMessage,
} from "./file";
export type { FileHandlerDeps } from "./file";
