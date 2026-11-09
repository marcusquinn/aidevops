// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18888/GH#37157: OpenCode 2 adapter for the session bus. The runtime
// (session-bus.mjs) and its store are shared with OpenCode 1.x; this module
// maps the V2 plugin surface onto the V1 shapes the runtime expects.
//
// V2 channels (verified against @opencode/cli 2.0.18):
//   busy           -> tool `execute.after` result content (as V1)
//   next user turn -> `session` hook `prompt`: appended to the prompt text
//   idle wake      -> ctx.session.synthetic({ resume: true }), a synthetic
//                     message that starts a turn (V1: session.promptAsync)
// Gaps: the V2 server plugin has no `session.status` (status comes from
// `session.execution.*` events only) and no `tui.showToast`, so arrivals show
// as `•` rows in the sidebar instead of a toast.

import { createSessionBusHooks } from "./session-bus-plugin.mjs";

const WAKE_DESCRIPTION = "aidevops session-bus";
const IDLE_EVENTS = new Set([
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
]);
// Work milestones only: per-token deltas would re-run the root check per chunk.
const ACTIVITY_EVENTS = new Set([
  "session.step.started",
  "session.step.ended",
  "session.tool.called",
  "session.tool.success",
  "session.tool.failed",
  "session.shell.started",
  "session.shell.ended",
  "session.compaction.started",
  "session.compaction.ended",
]);

/** V2 Session.Info -> the V1 fields the bus reads (`directory` lives in `location`). */
export function v1SessionInfo(info) {
  if (!info || typeof info !== "object" || !info.id) return null;
  return { ...info, directory: info.directory || info.location?.directory || "" };
}

/** Join the text parts of a V1 wake request, ignoring non-text parts. */
function wakeText(body) {
  const parts = Array.isArray(body?.parts) ? body.parts : [];
  return parts.map((part) => (typeof part?.text === "string" ? part.text : "")).filter(Boolean).join("\n\n");
}

/**
 * The client subset the bus uses, backed by the V2 plugin context. The wake
 * ignores the V1 agent/model: a synthetic message resumes the session with
 * its own current agent and model.
 */
export function createV2SessionBusClient(ctx) {
  const session = {
    async get({ path }) {
      return { data: v1SessionInfo(await ctx.session.get({ sessionID: path.id })) };
    },
  };
  if (typeof ctx?.session?.synthetic === "function") {
    session.promptAsync = async ({ path, body }) => {
      await ctx.session.synthetic({
        sessionID: path.id,
        text: wakeText(body),
        description: WAKE_DESCRIPTION,
        metadata: { source: "aidevops-session-bus" },
        resume: true,
      });
      return {};
    };
  }
  return { session };
}

/** V2 `{ type, data }` event -> V1 `{ type, properties }`, or null when the bus ignores it. */
export function normalizeV2BusEvent(event) {
  const type = event?.type;
  const passthrough = Boolean(event?.properties) || !event?.data || typeof event.data !== "object";
  const data = passthrough ? {} : event.data;
  const sessionID = String(data.sessionID || data.info?.id || "");
  let result = { type, properties: data };
  if (typeof type !== "string") result = null;
  else if (passthrough) result = event;
  else if (type === "session.execution.started") result = { type: "session.status", properties: { sessionID, status: { type: "busy" } } };
  else if (IDLE_EVENTS.has(type)) result = { type: "session.idle", properties: { sessionID } };
  else if (type === "session.created" || type === "session.updated") result = sessionInfoEvent(type, data, sessionID);
  else if (type === "session.renamed") result = { type: "session.updated", properties: { sessionID } };
  else if (ACTIVITY_EVENTS.has(type)) result = { type: "message.updated", properties: { sessionID } };
  return result;
}

/** Preserve normalized session information when a V2 lifecycle event includes it. */
function sessionInfoEvent(type, data, sessionID) {
  const info = v1SessionInfo(data.info);
  return { type, properties: info ? { sessionID, info } : { sessionID } };
}

/**
 * Session-bus hooks for the V2 server plugin. Same process kinds as V1:
 * TUI, serve and ACP processes get the tool and wakes; headless workers
 * receive at tool results and prompts without a tool or wakes (t18905); CLI
 * processes publish read-only presence.
 * @param {object} options - { ctx, directory, headless, log(level, message) }
 */
export function createV2SessionBusHooks({ ctx, directory, headless = false, remote = null, log = () => {} }) {
  const hooks = createSessionBusHooks({
    client: createV2SessionBusClient(ctx),
    directory,
    remote,
    headless,
    onError: (label, error) => log("WARN", `[${label}] skipped: ${error?.message ?? error}`),
    log,
  });
  const { bus } = hooks;
  return {
    bus,
    addTool: hooks.addTool,
    /** `session` hook `prompt`: deliver pending messages with the user's turn. */
    async prompt(event) {
      const prompt = event?.prompt && typeof event.prompt === "object" ? event.prompt : null;
      // Without a prompt to carry them, nothing is claimed.
      const output = { message: { id: event?.messageID }, parts: prompt ? [] : undefined };
      await hooks.chatMessage({ sessionID: event?.sessionID }, output);
      const text = (output.parts || []).map((part) => part.text).filter(Boolean).join("\n\n");
      if (text) prompt.text = prompt.text ? `${prompt.text}\n\n${text}` : text;
    },
    /** `tool` hook `execute.before`: publish the running tool (t18905). */
    toolBefore(event) {
      hooks.toolBefore({ sessionID: event?.sessionID, tool: event?.tool });
    },
    /** `tool` hook `execute.after` on the legacy output view; completed results only carry messages. */
    toolAfter(event, output) {
      const input = { sessionID: event?.sessionID, tool: event?.tool };
      if (event?.status === "completed") hooks.toolAfter(input, output);
      else hooks.toolAfter(input, null);
    },
    /** Translate V2 events and update root metadata and turn state before dispatch. */
    handleEvent(input) {
      const event = input?.event;
      const normalized = normalizeV2BusEvent(event);
      if (!normalized) return Promise.resolve();
      const sessionID = normalized.properties?.sessionID;
      if (event.type === "session.renamed" && bus.tree.isKnownRoot(sessionID) && typeof event.data?.title === "string") {
        bus.updateRootInfo({ id: sessionID, title: event.data.title });
      }
      if (event.type === "session.execution.started") bus.turnStarted(sessionID);
      return hooks.handleEvent({ event: normalized });
    },
    /** Release bus resources without allowing cleanup errors to escape. */
    dispose() {
      try {
        bus.dispose();
      } catch { /* best-effort cleanup */ }
    },
  };
}
