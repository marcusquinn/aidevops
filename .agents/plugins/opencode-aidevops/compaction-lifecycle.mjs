// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";

const MAX_SESSION_STATES = 64;
const TERMINAL_FINISH_REASONS = new Set(["stop", "end_turn", "completed"]);
const CONTINUABLE_FINISH_REASONS = new Set([
  "length",
  "max_tokens",
  "tool-calls",
  "tool_calls",
]);

function unwrapResponse(response) {
  return response?.data ?? response;
}

function capMap(map) {
  while (map.size > MAX_SESSION_STATES) map.delete(map.keys().next().value);
}

function sessionHash(sessionID) {
  return createHash("sha256").update(String(sessionID || "unknown-session")).digest("hex").slice(0, 12);
}

function lifecycleFromMessages(messages) {
  const message = [...(Array.isArray(messages) ? messages : [])]
    .reverse()
    .map((entry) => entry?.info ?? entry)
    .find((info) => info?.role === "assistant" && info?.summary !== true && info?.mode !== "compaction");

  if (!message) return { finish: "", reason: "child_finish_missing" };
  const finish = String(message.finish || "").toLowerCase();
  if (TERMINAL_FINISH_REASONS.has(finish)) return { finish, reason: "child_terminal" };
  if (CONTINUABLE_FINISH_REASONS.has(finish)) return { finish, reason: "child_incomplete" };
  return { finish, reason: finish ? "child_finish_unknown" : "child_finish_missing" };
}

/**
 * Guard OpenCode's experimental.compaction.autocontinue hook.
 *
 * OpenCode 1.18.3 supplies { sessionID, agent, model, provider, message,
 * overflow } and a mutable { enabled } output. Its installed plugin type
 * package currently omits this runtime hook, so focused tests pin the observed
 * contract. The guard only narrows `enabled`; it never changes the message,
 * model, provider, tools, or permission state.
 */
export function createCompactionAutoContinueGuard(client, options = {}) {
  const qualityLog = options.qualityLog;
  const sessions = new Map();
  const finishes = new Map();

  function rememberSession(session) {
    if (!session?.id) return;
    sessions.set(session.id, {
      known: true,
      child: Boolean(session.parentID),
    });
    capMap(sessions);
  }

  function rememberMessage(message) {
    if (message?.role !== "assistant" || message?.summary === true || message?.mode === "compaction") return;
    if (!message.sessionID) return;
    finishes.set(message.sessionID, {
      finish: String(message.finish || "").toLowerCase(),
    });
    capMap(finishes);
  }

  function handleEvent(input) {
    const event = input?.event ?? input;
    if (["session.created", "session.updated"].includes(event?.type)) {
      rememberSession(event.properties?.info);
    } else if (event?.type === "session.deleted") {
      const sessionID = event.properties?.info?.id;
      sessions.delete(sessionID);
      finishes.delete(sessionID);
    } else if (event?.type === "message.updated") {
      rememberMessage(event.properties?.info);
    }
  }

  async function inspect(sessionID) {
    let session = null;
    try {
      session = unwrapResponse(await client?.session?.get?.({ path: { id: sessionID } })) || null;
      rememberSession(session);
    } catch {
      session = null;
    }

    const knownSession = session?.id ? sessions.get(session.id) : sessions.get(sessionID);
    if (knownSession?.known && !knownSession.child) {
      return { enabled: true, reason: "primary_session" };
    }
    if (!knownSession?.child) {
      return { enabled: false, reason: "session_lifecycle_unknown" };
    }

    let lifecycle = null;
    try {
      const response = await client?.session?.messages?.({ path: { id: sessionID } });
      lifecycle = lifecycleFromMessages(unwrapResponse(response));
    } catch {
      lifecycle = lifecycleFromMessages([]);
    }

    if (lifecycle.reason === "child_finish_missing") {
      const cached = finishes.get(sessionID);
      lifecycle = lifecycleFromMessages(cached ? [{ role: "assistant", finish: cached.finish }] : []);
    }
    return {
      enabled: lifecycle.reason === "child_incomplete",
      reason: lifecycle.reason,
      finish: lifecycle.finish,
    };
  }

  async function autoContinue(input, output) {
    const sessionID = String(input?.sessionID || "");
    const decision = sessionID
      ? await inspect(sessionID)
      : { enabled: false, reason: "session_id_missing" };

    if (!decision.enabled) {
      output.enabled = false;
      qualityLog?.(
        "WARN",
        `[compaction-autocontinue] blocked session sha256:${sessionHash(sessionID)} reason=${decision.reason}`,
      );
    }
    return decision;
  }

  return { autoContinue, handleEvent };
}

export { CONTINUABLE_FINISH_REASONS, TERMINAL_FINISH_REASONS, lifecycleFromMessages };
