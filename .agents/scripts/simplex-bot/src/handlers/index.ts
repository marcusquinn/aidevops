/**
 * SimpleX Bot — Handler Barrel Export
 *
 * Re-exports all event handlers for clean imports.
 */

export type { ContactHandlerDeps } from "./contact";
export {
  handleBusinessRequest,
  handleContactConnected,
  handleContactRequest,
} from "./contact";
export type { FileHandlerDeps } from "./file";
export {
  handleFileComplete,
  handleFileReady,
  handleNonTextMessage,
} from "./file";
export type { GroupHandlerDeps } from "./group";
export {
  handleBotRemovedFromGroup,
  handleGroupInvitation,
  handleMemberConnected,
  handleMemberJoined,
} from "./group";
export type { MessageHandlerDeps } from "./message";
export { handleNewChatItems } from "./message";
