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

// ---------------------------------------------------------------------------
// OpenCode 2 TUI (t18888): the same rows in a `sidebar.content` slot, built
// with the @opentui/solid universal renderer API like tui-prompts.mjs, so the
// .mjs entrypoint needs no JSX transform.
// ---------------------------------------------------------------------------

function attempt(fn, fallback) {
  try {
    const value = fn();
    return value === undefined || value === null ? fallback : value;
  } catch {
    return fallback;
  }
}

function v2TextColor(theme, muted) {
  const text = theme?.text;
  return muted ? text?.subdued ?? text?.muted ?? text?.base : text?.default ?? text?.base;
}

function createV2Text(solid, api, label, { muted = false, onMouseUp } = {}) {
  const node = solid.createElement("text");
  solid.setProp(node, "wrapMode", "none");
  if (onMouseUp) solid.setProp(node, "onMouseUp", onMouseUp);
  solid.effect(() => {
    const color = attempt(() => v2TextColor(api.theme, typeof muted === "function" ? muted() : muted), undefined);
    if (color !== undefined) solid.setProp(node, "fg", color);
  });
  solid.insert(node, label);
  return node;
}

/** Messages section for one sidebar render; `tick` re-reads the bus files. Expanded by default. */
export function renderMessagesV2(solid, solidJs, api, props, { tick = () => 0, readRows = messageRows } = {}) {
  const rows = solidJs.createMemo(() => {
    tick();
    const root = rootSessionID((id) => api.data.session.get(id), props.sessionID);
    return attempt(() => readRows(root), []);
  });
  const [open, setOpen] = solidJs.createSignal(true);
  const section = solid.createElement("box");
  const header = solid.createElement("box");
  solid.setProp(header, "flexDirection", "row");
  solid.insert(header, createV2Text(solid, api, () => `${open() ? "▼" : "▶"} Messages`, {
    onMouseUp: () => setOpen((value) => !value),
  }));
  solid.insert(header, () => (open() ? undefined : createV2Text(solid, api, () => ` (${rows().length})`, { muted: true })));
  solid.insert(section, header);
  solid.insert(section, () => (open()
    ? rows().map((row) => createV2Text(solid, api, row.text, { muted: !row.pending }))
    : []));
  return () => (rows().length > 0 ? section : undefined);
}

/**
 * Registers the Messages section. Pass `after` (the Prompts setup's `ready`)
 * so this prepend claim follows the Prompts claim: V2 renders prepend claims in
 * registration order, ahead of the built-in sections that append.
 */
export function setupMessagesSlot(
  api,
  {
    env = process.env,
    after = Promise.resolve(),
    timers = globalThis,
    pollMs = MESSAGES_POLL_MS,
    readRows = messageRows,
    loadSolid = () => import("@opentui/solid"),
    loadSolidJs = () => import("solid-js"),
  } = {},
) {
  if (!isMessagesEnabled(env) || typeof api?.ui?.slot !== "function") return undefined;
  let disposed = false;
  let unregister;
  let timer;
  const register = ([solid, solidJs]) => {
    if (disposed) return;
    const [tick, setTick] = solidJs.createSignal(0);
    timer = timers.setInterval(() => setTick((value) => value + 1), pollMs);
    timer?.unref?.();
    unregister = attempt(
      () => api.ui.slot({
        prepend: "sidebar.content",
        render: (props) => attempt(() => renderMessagesV2(solid, solidJs, api, props, { tick, readRows }), undefined),
      }),
      undefined,
    );
  };
  // A missing renderer must leave the rest of the sidebar usable.
  const ready = Promise.resolve(after)
    .catch(() => undefined)
    .then(() => Promise.all([loadSolid(), loadSolidJs()]))
    .then(register)
    .catch(() => undefined);
  const cleanup = () => {
    disposed = true;
    if (timer !== undefined) timers.clearInterval(timer);
    if (typeof unregister === "function") attempt(unregister, undefined);
    unregister = undefined;
  };
  cleanup.ready = ready;
  return cleanup;
}
