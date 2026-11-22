// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: sidebar "Messages" section (under "Prompts") for the
// session bus. The TUI reads the current root session's bus files directly,
// with no server round trip. Rows: `← handle: text` for received and
// `→ handle: text` for sent; a leading `•` means not yet delivered to the
// model. Clicking a row opens the full message in a dialog.
// AIDEVOPS_TUI_MESSAGES=false hides the section.

import { busRoot, messagePreview, recentTraffic } from "./session-bus-store.mjs";

export const MESSAGES_POLL_MS = 5000;
const DEFAULT_LIMIT = 6;
const DEFAULT_WIDTH = 34;
const DETAIL_DIALOG_SIZE = "large";
const TYPE_TITLE = { info: "Message", ask: "Question", reply: "Reply", "idle-notice": "Idle notice" };

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

function peerLabel(direction, message) {
  return direction === "in"
    ? message.from?.handle || "peer"
    : message.to_handle || String(message.to || "").slice(-6) || "outbox";
}

// Bus files are local data any process can write, so the dialog re-applies the
// send-time control-character filter (newline and tab survive).
function displayText(value) {
  return String(value ?? "").replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000B-\u001F\u007F-\u009F]/g, "");
}

function sentAt(createdMs) {
  const date = new Date(Number(createdMs));
  return Number(createdMs) > 0 && !Number.isNaN(date.getTime()) ? date.toLocaleString() : "";
}

function partyLine(label, handle, place, sessionID) {
  const where = place ? ` (${place})` : "";
  return `${label}: ${handle || "?"}${where}${sessionID ? ` · ${sessionID}` : ""}`;
}

/** Dialog title and body for one traffic entry: metadata lines, a blank line, then the full text. */
export function messageDetail({ direction, pending, message } = {}) {
  const entry = message && typeof message === "object" ? message : {};
  const from = entry.from || {};
  const incoming = direction === "in";
  const kind = TYPE_TITLE[entry.type] || TYPE_TITLE.info;
  const place = [from.repo, from.branch].filter(Boolean).join("@");
  const status = incoming ? (pending ? "not yet delivered to the model" : "delivered to the model") : "sent";
  const meta = [
    incoming
      ? partyLine("From", from.handle, place, from.session_id)
      : partyLine("To", entry.to_handle, "", entry.to),
    sentAt(entry.created_ms) && `Sent: ${sentAt(entry.created_ms)}`,
    `Status: ${status}`,
    entry.re && `Re: ${entry.re}`,
    entry.id && `ID: ${entry.id}`,
  ].filter(Boolean);
  return {
    title: displayText(`${kind} ${incoming ? "from" : "to"} ${peerLabel(direction, entry)}`),
    message: displayText([...meta, "", entry.text].join("\n")),
  };
}

export function messageRows(sessionID, { root = busRoot(), limit = DEFAULT_LIMIT, width = DEFAULT_WIDTH } = {}) {
  let traffic;
  try {
    traffic = recentTraffic(root, sessionID, { limit });
  } catch {
    return [];
  }
  return traffic.map((item) => {
    const { direction, pending, message } = item;
    const arrow = direction === "in" ? "←" : "→";
    const label = `${pending ? "• " : ""}${arrow} ${peerLabel(direction, message)}: ${messagePreview(message, width * 2)}`;
    return { id: message.id, pending, direction, text: truncate(label, width), detail: messageDetail(item) };
  });
}

/**
 * Opens a row's detail in the host's alert dialog. V2 exposes
 * `ui.dialog.alert`; OpenCode 1.x passes `alert` built from its DialogAlert
 * component (v1-tui/tui.tsx). Both hosts reset the size on open, so the
 * larger size is applied afterwards. Call on mouse-up: the dialog backdrop
 * closes on mouse-up, so opening on mouse-down would dismiss it at once.
 */
export function openMessageDialog(dialog, detail, { alert } = {}) {
  if (!dialog || !detail) return false;
  const show = alert ?? (typeof dialog.alert === "function" ? (input) => dialog.alert(input) : undefined);
  if (typeof show !== "function") return false;
  return attempt(() => {
    const closed = show({ title: detail.title, message: detail.message });
    if (typeof closed?.catch === "function") closed.catch(() => undefined);
    attempt(() => (typeof dialog.set === "function" ? dialog.set({ size: DETAIL_DIALOG_SIZE }) : dialog.setSize?.(DETAIL_DIALOG_SIZE)), undefined);
    return true;
  }, false);
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
  const showDetail = (row) => () => openMessageDialog(api.ui?.dialog, row.detail);
  solid.insert(section, () => (open()
    ? rows().map((row) => createV2Text(solid, api, row.text, { muted: !row.pending, onMouseUp: showDetail(row) }))
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
