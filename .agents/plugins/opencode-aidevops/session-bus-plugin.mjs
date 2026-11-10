// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: OpenCode plugin wiring for the session bus. index.mjs calls
// these hooks. Each hook contains its own failure, so a bus fault never
// breaks a user turn, a tool result or the event loop.

import { isWorkerContext } from "./process-start-identity.mjs";
import { createSessionBus, processKind } from "./session-bus.mjs";
import { createSessionBusTool } from "./session-bus-tool.mjs";
import { isRemoteInteractiveConversation } from "./team-interface-context.mjs";

/**
 * t18898: the remote-hosted context for the bus, or null for a local process.
 * #aidevops:trust-boundary: derived only from the verified launch overlay.
 * A remote-interactive overlay always yields an object, so unreadable context
 * still gets the remote origin and no wakes.
 */
export function remoteBusContext(conversation) {
  if (!isRemoteInteractiveConversation(conversation)) return null;
  const overlay = conversation.overlay;
  return { agent: overlay?.agent?.agent_id, context: overlay?.context };
}

/**
 * Presence for every root session. Interactive TUI, serve and ACP processes
 * get the tool and wakes. t18905: headless workers receive messages at tool
 * results and turns, with no tool (no schema cost) and no wakes; they answer
 * from their shell with `aidevops sessions reply`. CLI processes are read-only.
 * @param {object} options - { client, directory, headless, remote ({ agent, context } for a remote-interactive process, t18898), onError(label, err), log(level, message) }
 */
export function createSessionBusHooks({ client, directory, headless = false, remote = null, onError = () => {}, log = () => {} }) {
  const bus = createSessionBus({
    client,
    directory,
    remote,
    kind: processKind(process.argv, { headless: headless || isWorkerContext() }),
  });
  return {
    bus,
    /** Register aidevops_sessions in interactive processes only. */
    addTool(tools, tool) {
      if (bus.messageable && bus.wakeable) tools.aidevops_sessions = createSessionBusTool(tool, bus);
    },
    /** Deliver pending messages on the user turn. */
    chatMessage: (input, output) =>
      bus.chatMessage(input, output).catch((error) => onError("session bus chat.message", error)),
    /** Publish the running tool (throttled with other presence writes). */
    toolBefore(input) {
      try {
        bus.toolBefore(input);
      } catch (error) {
        log("WARN", `[session-bus] tool presence skipped: ${error?.message ?? error}`);
      }
    },
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
