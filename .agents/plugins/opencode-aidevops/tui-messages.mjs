// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: sidebar "Messages" section (under "Prompts") for the
// session bus. The TUI reads the current root session's bus files directly,
// with no server round trip. Rows: `← handle: text` for received and
// `→ handle: text` for sent; a leading `•` means not yet delivered to the
// model. AIDEVOPS_TUI_MESSAGES=false hides the section.

import { busRoot, messagePreview, recentTraffic } from "./session-bus-store.mjs";

export const MESSAGES_POLL_MS = 5000;
const DEFAULT_LIMIT = 6;
const DEFAULT_WIDTH = 34;

export function isMessagesEnabled(env = process.env) {
  return !["false", "0", "none"].includes(String(env.AIDEVOPS_TUI_MESSAGES ?? "").trim().toLowerCase());
}

/** Walk parentID links so a subagent view shows its root session's traffic. */
export function rootSessionID(getSession, sessionID) {
  let current = sessionID;
  for (let depth = 0; depth < 8 && current; depth += 1) {
    let parent;
    try {
      parent = getSession(current)?.parentID;
    } catch {
      parent = undefined;
    }
    if (!parent) return current;
    current = parent;
  }
  return current;
}

function truncate(text, width) {
  const chars = Array.from(text);
  return chars.length > width ? `${chars.slice(0, Math.max(0, width - 1)).join("")}…` : text;
}

export function messageRows(sessionID, { root = busRoot(), limit = DEFAULT_LIMIT, width = DEFAULT_WIDTH } = {}) {
  let traffic;
  try {
    traffic = recentTraffic(root, sessionID, { limit });
  } catch {
    return [];
  }
  return traffic.map(({ direction, pending, message }) => {
    const peer = direction === "in"
      ? message.from?.handle || "peer"
      : message.to_handle || String(message.to || "").slice(-6) || "outbox";
    const arrow = direction === "in" ? "←" : "→";
    const label = `${pending ? "• " : ""}${arrow} ${peer}: ${messagePreview(message, width * 2)}`;
    return { id: message.id, pending, direction, text: truncate(label, width) };
  });
}
