// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Delivery notes for `aidevops_sessions` send/ask results: what the recipient
// will do with the message, and whether an ask can wake it. Split from
// session-bus-tool.mjs (GH#40449).

import * as store from "./session-bus-store.mjs";

const OFFLINE_NOTE = "That session is not running. The message is kept for 7 days and delivered when the session resumes in any OpenCode process.";
const ACTIVE_STATUSES = new Set(["busy", "permission"]);

function workerNote(type, record) {
  const answer = type === "ask" ? " It answers from its shell; the reply arrives in this session." : "";
  return `${record.handle} is a pulse worker (${record.status}); it sees the message at its next tool result and is never woken.${answer}`;
}

/**
 * GH#40449: a remote-hosted sender (t18898) sends with a chat origin, and
 * delivery never wakes an idle session for it (isWakeEligible). Name the
 * sender's app so the ask result does not promise a wake.
 */
function remoteSenderApp(sender) {
  return store.parseChatOrigin(sender?.from?.origin)?.app || "";
}

/** An idle interactive session: info waits for its next turn; an ask wakes it unless a chat app drives either side. */
function idleNote(type, record, sender) {
  const state = `${record.handle} is ${record.status};`;
  if (type !== "ask") return `${state} info messages wait for its next turn.`;
  if (record.interface) return `${state} ${store.viaLabel(record)}, so the question does not wake it. This session is driven from ${record.interface}; it answers on its next chat turn.`;
  const app = remoteSenderApp(sender);
  if (app) return `${state} this session is remote-hosted (${app}), so the question does not wake it. It arrives at that session's next turn or tool result, and its reply arrives in this session.`;
  return `${state} the question wakes it (at most ${store.LIMITS.wakesPerHour} wakes per hour). Its reply arrives in this session.`;
}

/** Classify a recipient for delivery notes: offline, worker, active, or idle. */
function recipientKind(record) {
  if (!record) return "offline";
  if (store.isWorker(record)) return "worker";
  return ACTIVE_STATUSES.has(record.status) ? "active" : "idle";
}

/** GH#40449: a remote-hosted sender's ask to an idle local session cannot wake it, so a reply wait cannot help. */
export function remoteAskToIdle(record, sender) {
  if (recipientKind(record) !== "idle" || record.interface) return false;
  return Boolean(remoteSenderApp(sender));
}

export function deliveryNote(type, record, sender) {
  const kind = recipientKind(record);
  if (kind === "offline") return OFFLINE_NOTE;
  if (kind === "worker") return workerNote(type, record);
  if (kind === "active") return `${record.handle} is ${record.status}; it sees the message at its next tool result.`;
  return idleNote(type, record, sender);
}
