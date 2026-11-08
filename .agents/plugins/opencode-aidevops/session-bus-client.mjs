// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: OpenCode client calls made by the session-bus runtime.
// Each call contains its own failure, so a client fault never breaks a hook.

import { messagePreview } from "./session-bus-store.mjs";

const MAX_TOASTED = 256;
const TOAST_MS = 8000;

export const unwrap = (result) => (result && typeof result === "object" && "data" in result ? result.data : result);

function responseError(result) {
  if (result?.error) return result.error;
  return result?.response && result.response.ok === false ? `HTTP ${result.response.status}` : null;
}

function describeError(error) {
  if (error?.message) return String(error.message);
  try {
    return String(typeof error === "object" ? JSON.stringify(error) : error);
  } catch {
    return String(error);
  }
}

export function warn(label, error) {
  console.error(`[aidevops] session-bus ${label}: ${describeError(error).slice(0, 300)}`);
}

export async function showToast(client, title, message) {
  try {
    await client?.tui?.showToast?.({ body: { title, message, variant: "info", duration: TOAST_MS } });
  } catch {
    // Toasts are advisory; delivery does not depend on them.
  }
}

/** Live busy/idle statuses keyed by session ID, or null when unavailable. */
export async function liveStatuses(client) {
  try {
    const statuses = unwrap(await client?.session?.status?.());
    return statuses && typeof statuses === "object" ? statuses : null;
  } catch {
    return null;
  }
}

export const canPrompt = (client) => typeof client?.session?.promptAsync === "function";

/** Start a turn in an idle session. Returns the failure, or null once OpenCode accepts it. */
export async function promptSession(client, sessionID, body) {
  try {
    return responseError(await client.session.promptAsync({ path: { id: sessionID }, body }));
  } catch (error) {
    return error;
  }
}

/** One toast per pending message per process, batched per poll. */
export class ArrivalToasts {
  constructor(client) {
    this.client = client;
    this.seen = new Set();
  }

  fresh(pending) {
    const fresh = pending.filter((entry) => !this.seen.has(entry.message.id));
    for (const entry of fresh) this.seen.add(entry.message.id);
    while (this.seen.size > MAX_TOASTED) this.seen.delete(this.seen.values().next().value);
    return fresh;
  }

  async announce(handle, pending) {
    const fresh = this.fresh(pending);
    if (fresh.length === 0) return;
    const latest = fresh[fresh.length - 1].message;
    const target = handle || "this session";
    const kind = latest.type === "ask" ? "Question" : "Message";
    const title = fresh.length > 1 ? `${fresh.length} messages for ${target}` : `${kind} for ${target}`;
    await showToast(this.client, title, `${latest.from?.handle || "peer"}: ${messagePreview(latest, 100)}`);
  }
}
