/**
 * SimpleX Bot — File & Voice Event Handlers
 *
 * Handles file lifecycle events:
 * - rcvFileDescrReady: incoming file descriptor ready (initiate download)
 * - rcvFileComplete: file download complete (process file)
 * - Voice notes: received as file attachments with type "voice"
 *
 * Reference: t1327.1 research, section 4.1 (Essential Events for Bots)
 */

import type {
  ChatItem,
  SimplexEvent,
  FileEvent,
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

/** File handler dependencies */
export interface FileHandlerDeps {
  logger: Logger;
  sessions: SessionStore;
  sendCommand: SendCommand;
  /** Reply to the chat item that sent the file */
  replyToItem: (item: ChatItem, text: string) => Promise<void>;
  /** Maximum file size to auto-accept (bytes, default: 50MB) */
  maxFileSize?: number;
  /** Whether to auto-accept incoming files */
  autoAcceptFiles: boolean;
}

/** Default max file size: 50MB */
const DEFAULT_MAX_FILE_SIZE = 50 * 1024 * 1024;

/**
 * Handle rcvFileDescrReady event.
 * Fired when an incoming file descriptor is ready.
 * Auto-accepts the file if configured and within size limits.
 */
export async function handleFileReady(
  event: SimplexEvent,
  deps: FileHandlerDeps,
): Promise<void> {
  const fileEvent = event as FileEvent;
  const fileId = fileEvent.fileId;
  const fileName = fileEvent.fileName ?? "unknown";
  const fileSize = fileEvent.fileSize ?? 0;

  if (fileId === undefined) {
    deps.logger.warn("rcvFileDescrReady event missing fileId");
    return;
  }

  deps.logger.info(
    `Incoming file: ${fileName} (${formatFileSize(fileSize)}, fileId: ${fileId})`,
  );

  const maxSize = deps.maxFileSize ?? DEFAULT_MAX_FILE_SIZE;

  if (!deps.autoAcceptFiles) {
    deps.logger.info(`File auto-accept disabled, ignoring file ${fileName}`);
    return;
  }

  if (fileSize > maxSize) {
    deps.logger.warn(
      `File ${fileName} exceeds max size (${formatFileSize(fileSize)} > ${formatFileSize(maxSize)}), skipping`,
    );
    return;
  }

  // Accept the file
  try {
    await deps.sendCommand(`/freceive ${fileId}`);
    deps.logger.info(`Accepted file: ${fileName} (fileId: ${fileId})`);
  } catch (err) {
    deps.logger.error(`Failed to accept file ${fileName}:`, err);
  }
}

/**
 * Handle rcvFileComplete event.
 * Fired when a file download is complete.
 * Determines file type and dispatches to appropriate processor.
 */
export async function handleFileComplete(
  event: SimplexEvent,
  deps: FileHandlerDeps,
): Promise<void> {
  const fileEvent = event as FileEvent;
  const fileId = fileEvent.fileId;
  const filePath = fileEvent.filePath;
  const fileName = fileEvent.fileName ?? "unknown";

  if (fileId === undefined) {
    deps.logger.warn("rcvFileComplete event missing fileId");
    return;
  }

  deps.logger.info(
    `File download complete: ${fileName} (fileId: ${fileId}, path: ${filePath ?? "unknown"})`,
  );

  // File processing is a scaffold — in production this would:
  // 1. Detect file type (voice, image, document, etc.)
  // 2. Route to appropriate processor
  // 3. Return results to the sender
  //
  // For now, log the completion for manual processing
  deps.logger.info(
    `File ready for processing: ${filePath ?? fileName}`,
  );
}

/**
 * Handle non-text message types from chat items.
 * Called by the message handler when a non-text message is received.
 * Routes voice notes, images, files to appropriate handlers.
 */
export async function handleNonTextMessage(
  item: ChatItem,
  msgType: string,
  deps: FileHandlerDeps,
): Promise<void> {
  const content = item?.chatItem?.content?.msgContent;

  switch (msgType) {
    case "voice": {
      deps.logger.info("Voice note received");
      // Voice notes are file attachments — the file events handle download.
      // After download, the voice file can be transcribed via speech-to-speech agent.
      // Scaffold: acknowledge receipt
      await deps.replyToItem(
        item,
        "Voice note received. Voice processing is not yet connected. " +
          "(Requires speech-to-speech agent integration.)",
      );
      break;
    }

    case "image": {
      deps.logger.info("Image received");
      await deps.replyToItem(
        item,
        "Image received. Image analysis is not yet connected.",
      );
      break;
    }

    case "file": {
      deps.logger.info(`File attachment received: ${content?.fileName ?? "unknown"}`);
      // File download is handled by rcvFileDescrReady/rcvFileComplete events
      await deps.replyToItem(
        item,
        `File received: ${content?.fileName ?? "unknown"}. Processing via file events.`,
      );
      break;
    }

    case "video": {
      deps.logger.info("Video received");
      await deps.replyToItem(
        item,
        "Video received. Video processing is not yet supported.",
      );
      break;
    }

    case "link": {
      deps.logger.debug("Link preview message — treating as text");
      // Link messages have text content too, handled by message handler
      break;
    }

    default: {
      deps.logger.debug(`Unhandled message type: ${msgType}`);
      break;
    }
  }
}

/** Format file size for human-readable display */
function formatFileSize(bytes: number): string {
  if (bytes === 0) {
    return "0 B";
  }
  const units = ["B", "KB", "MB", "GB"];
  const i = Math.min(
    Math.floor(Math.log(bytes) / Math.log(1024)),
    units.length - 1,
  );
  const size = bytes / Math.pow(1024, i);
  return `${size.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
}
