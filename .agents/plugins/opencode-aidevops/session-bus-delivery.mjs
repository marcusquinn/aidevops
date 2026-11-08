// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: session-bus delivery. Every channel persists in the
// session (Phase 0 verified on OpenCode v1.19.5):
//   busy -> appended to the next tool result (appendToolMessages)
//   next user turn -> synthetic parts on the user message (appendTurnMessages)
//   idle + ask/reply/idle-notice -> client.session.promptAsync (deliverToIdle)
// These functions own no state: the runtime (session-bus.mjs) passes itself
// as `bus`.

import * as store from "./session-bus-store.mjs";
import { canPrompt, liveStatuses, promptSession, showToast, warn } from "./session-bus-client.mjs";
import { setStatus, statusFromType } from "./session-bus-events.mjs";

const HOUR_MS = 60 * 60 * 1000;
const WAKE_RETRY_MS = 30 * 1000;
const WAKE_RETRY_MAX_MS = 15 * 60 * 1000;
const WAKE_TYPES = new Set(["ask", "reply", "idle-notice"]);

export function isWakeEligible(message) {
  if (!message || message.hops >= store.LIMITS.maxWakeHops) return false;
  return !store.parseChatOrigin(message.from?.origin) && WAKE_TYPES.has(message.type);
}

const eligibleEntry = (entry) => isWakeEligible(entry.message);
const framed = (claimed) => claimed.map((entry) => store.frameMessage(entry.message)).join("\n\n");

/** Busy channel: claimed messages follow the tool's own output. */
export function appendToolMessages(output, claimed) {
  if (claimed.length > 0) output.output = `${output.output}\n\n${framed(claimed)}`;
  return claimed.length;
}

/** Turn channel: one synthetic text part per claimed message. */
export function appendTurnMessages(output, claimed, sessionID) {
  const base = output.parts.find((part) => part?.type === "text") || output.parts[0] || {};
  const messageID = output.message?.id || base.messageID;
  claimed.forEach((entry, index) => {
    const part = { type: "text", text: store.frameMessage(entry.message), synthetic: true, sessionID, messageID };
    if (base.id) part.id = `${base.id}zb${index}`;
    output.parts.push(part);
  });
}

// ---------------------------------------------------------------------------
// Wake channel
// ---------------------------------------------------------------------------

function hasWakeBudget(state, now) {
  state.wakeTimes = state.wakeTimes.filter((time) => time > now - HOUR_MS);
  return state.wakeTimes.length < store.LIMITS.wakesPerHour;
}

function canWake(bus, state, pending, now) {
  if (state.status !== "idle" || now < state.wakeRetryAt) return false;
  return pending.some(eligibleEntry) && hasWakeBudget(state, now) && canPrompt(bus.client);
}

// The oldest batch, unless it holds nothing that may wake the session.
function wakeBatch(pending) {
  const limit = store.LIMITS.deliverPerBatch;
  const batch = pending.slice(0, limit);
  return batch.some(eligibleEntry) ? batch : pending.filter(eligibleEntry).slice(0, limit);
}

function wakeBody(state, claimed) {
  const body = { parts: [{ type: "text", text: framed(claimed), synthetic: true }] };
  if (state.agent) body.agent = state.agent;
  if (state.model) body.model = state.model;
  return body;
}

function beginWake(state, claimed, now) {
  state.status = "busy";
  state.wakePending = true;
  state.wakeHops = Math.max(...claimed.map((entry) => Number(entry.message.hops) || 0));
  state.wakeTimes.push(now);
}

// A failed wake returns its messages and budget, then waits before the next
// attempt (30s, doubling to 15min), so a persistent fault such as a rejected
// model does not retry and warn on every poll. The wait counts from when the
// failure is seen, so a slow failing prompt still gets the full delay.
function rollbackWake(bus, sessionID, state, claimed) {
  for (const entry of claimed) store.unclaimMessage(bus.root, sessionID, entry);
  state.wakePending = false;
  state.wakeTimes.pop();
  state.status = "unknown";
  state.wakeFailures += 1;
  state.wakeRetryAt = bus.now() + Math.min(WAKE_RETRY_MS * 2 ** (state.wakeFailures - 1), WAKE_RETRY_MAX_MS);
}

/** Wake an idle session with its pending messages. True once OpenCode accepts the prompt. */
export async function deliverToIdle(bus, sessionID, state, allPending = store.pendingMessages(bus.root, sessionID)) {
  const now = bus.now();
  // A reply reserved by a waiting ask call (t18897) neither wakes nor is delivered here.
  const pending = bus.unreserved(allPending);
  if (!canWake(bus, state, pending, now)) return false;
  const claimed = bus.claimPending(sessionID, store.LIMITS.deliverPerBatch, wakeBatch(pending));
  if (claimed.length === 0) return false;
  beginWake(state, claimed, now);
  const failure = await promptSession(bus.client, sessionID, wakeBody(state, claimed));
  if (failure) {
    rollbackWake(bus, sessionID, state, claimed);
    warn("wake", failure);
    return false;
  }
  state.wakeFailures = 0;
  state.wakeRetryAt = 0;
  const first = claimed[0].message;
  await showToast(bus.client, `Woke ${state.handle || "session"}`, `${first.from?.handle || "peer"}: ${store.messagePreview(first, 100)}`);
  return true;
}

// ---------------------------------------------------------------------------
// notify-when-idle
// ---------------------------------------------------------------------------

function idleNoticeText(state, sessionID) {
  const what = [state.title && `title: ${state.title}`, state.task && `last task: ${state.task}`].filter(Boolean).join("; ");
  return `Session ${state.handle || sessionID} is now idle${what ? ` (${what})` : ""}.`;
}

/** One-shot notices from this session to every notify-when-idle subscriber. */
export function sendIdleNotices(bus, sessionID, state) {
  const text = idleNoticeText(state, sessionID);
  for (const subscription of store.takeIdleSubscriptions(bus.root, sessionID)) {
    try {
      store.sendMessage(bus.root, {
        from: bus.fromFor(sessionID),
        to: subscription.subscriber,
        toHandle: subscription.handle,
        type: "idle-notice",
        text,
      });
    } catch (error) {
      warn("idle notice", error);
    }
  }
}

// ---------------------------------------------------------------------------
// Poll
// ---------------------------------------------------------------------------

async function refreshUnknownStatus(bus, sessionID, state, live) {
  if (live.statuses === undefined) live.statuses = await liveStatuses(bus.client);
  // A session absent from the status map is treated as idle.
  if (live.statuses) setStatus(state, statusFromType(live.statuses[sessionID]?.type || "idle"));
}

async function pollSession(bus, sessionID, state, live) {
  const pending = bus.unreserved(store.pendingMessages(bus.root, sessionID));
  if (pending.length === 0) return;
  void bus.toasts.announce(state.handle, pending);
  if (state.status === "unknown") await refreshUnknownStatus(bus, sessionID, state, live);
  if (state.status === "idle") await deliverToIdle(bus, sessionID, state, pending);
}

/** One poll: toast new arrivals, then wake idle sessions that hold eligible messages. */
export async function pollInboxes(bus) {
  const live = { statuses: undefined };
  for (const [sessionID, state] of bus.sessions) {
    if (bus.tree.isKnownRoot(sessionID)) await pollSession(bus, sessionID, state, live);
  }
}
