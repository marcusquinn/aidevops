// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: OpenCode plugin wiring for the session bus. index.mjs calls
// these hooks. Each hook contains its own failure, so a bus fault never
// breaks a user turn, a tool result or the event loop.

import { isWorkerContext } from "./process-start-identity.mjs";
import { createSessionBus, processKind } from "./session-bus.mjs";
import { createSessionBusTool } from "./session-bus-tool.mjs";

/**
 * Presence for every root session; messaging only in interactive TUI, serve
 * and ACP processes. Headless workers publish read-only presence.
 * @param {object} options - { client, directory, headless, onError(label, err), log(level, message) }
 */
export function createSessionBusHooks({ client, directory, headless = false, onError = () => {}, log = () => {} }) {
  const bus = createSessionBus({
    client,
    directory,
    kind: processKind(process.argv, { headless: headless || isWorkerContext() }),
  });
  return {
    bus,
    /** Register aidevops_sessions where this process can message. */
    addTool(tools, tool) {
      if (bus.messageable) tools.aidevops_sessions = createSessionBusTool(tool, bus);
    },
    /** Deliver pending messages on the user turn. */
    chatMessage: (input, output) =>
      bus.chatMessage(input, output).catch((error) => onError("session bus chat.message", error)),
    /** Deliver pending messages after a tool result; before output scrubbing. */
    toolAfter(input, output) {
      try {
        bus.toolAfter(input, output);
      } catch (error) {
        log("WARN", `[session-bus] tool delivery skipped: ${error?.message ?? error}`);
      }
    },
    handleEvent: (input) => bus.handleEvent(input).catch((error) => onError("session bus", error)),
  };
}
