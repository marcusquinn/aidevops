// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18897: `ask` with `wait_seconds` blocks the tool call for the matching
// reply. The reply is reserved in the bus's `awaitingReplies` map (ask ID ->
// root session whose waiting call claims it), so the root's own busy and idle
// delivery skip it; the waiter claims it by rename like any delivery.

import * as store from "./session-bus-store.mjs";

export const MAX_WAITS = 2;

/** Drop replies a waiting `ask` call has reserved; the waiter claims them. */
export function withoutReserved(awaiting, entries) {
  if (awaiting.size === 0) return entries;
  return entries.filter((entry) => !(entry.message.re && awaiting.has(entry.message.re)));
}

/** At most MAX_WAITS concurrent waits per root session. */
export function assertReplySlot(awaiting, sessionID) {
  const active = [...awaiting.values()].filter((owner) => owner === sessionID).length;
  if (active >= MAX_WAITS) throw new Error(`at most ${MAX_WAITS} concurrent waits per session; wait for one to finish`);
}

/** Reserve the reply to `askID` for a waiting tool call; returns the release function. */
export function reserveReplySlot(awaiting, sessionID, askID) {
  assertReplySlot(awaiting, sessionID);
  awaiting.set(askID, sessionID);
  return () => awaiting.delete(askID);
}

function sleep(bus, ms, signal) {
  return new Promise((resolve) => {
    const finish = () => {
      bus.timers.clearTimeout(timer);
      signal?.removeEventListener?.("abort", finish);
      resolve();
    };
    const timer = bus.timers.setTimeout(finish, ms);
    signal?.addEventListener?.("abort", finish, { once: true });
  });
}

function claimReply(root, sessionID, askID) {
  const entry = store.pendingMessages(root, sessionID)
    .find(({ message }) => message.type === "reply" && message.re === askID);
  return entry && store.claimMessage(root, sessionID, entry) ? entry.message : null;
}

async function waitForReply(bus, sender, askID, seconds, signal) {
  const deadline = bus.now() + seconds * 1000;
  while (!signal?.aborted) {
    const reply = claimReply(bus.root, sender.sessionID, askID);
    if (reply) return { reply };
    if (bus.now() >= deadline) return { timedOut: true };
    await sleep(bus, Math.min(bus.waitPollMs, Math.max(1, deadline - bus.now())), signal);
  }
  return { aborted: true };
}

/** Wait for the reply to a sent ask; returns the tool result text. */
export async function awaitReply(bus, sender, sent, seconds, signal) {
  const { id } = sent.message;
  const result = await waitForReply(bus, sender, id, seconds, signal);
  if (result.reply) return `${sent.text}\n\nReply received:\n${store.frameMessage(result.reply)}`;
  if (result.aborted) return `${sent.text}\n\nWait cancelled; ask ID ${id}. The reply will follow normal delivery.`;
  return `${sent.text}\n\nNo reply within ${seconds}s; ask ID ${id}. The reply will follow normal delivery to this session.`;
}
