// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// OpenCode V2 TUI entrypoint. V2 server plugins run inside the tty-less
// `opencode serve --service` process, so the V1 /dev/tty title writer cannot
// reach the terminal. The TUI process owns the renderer, so the status-dot
// terminal title (⚪ busy, 🟡 permission, 🟢 idle) is rendered here instead.

import { sanitizeTerminalTitle, withTerminalTitleStatus } from "../terminal-title.mjs";

// Distinct from the server plugin id so TUI and server registries never collide.
export const AIDEVOPS_V2_TUI_PLUGIN_ID = "aidevops-tui";
const DEFAULT_TITLE = "OpenCode";
const MAX_TITLE_LENGTH = 40;
const DEFAULT_POLL_MS = 300;
const DEFAULT_REFRESH_MS = 2000;

export function isTerminalTitleOwnedByAidevops(env = process.env) {
  return (
    env.AIDEVOPS_TERMINAL_TITLE_OWNER !== "native" &&
    env.TERMINAL_TITLE_ENABLED !== "false" &&
    env.AIDEVOPS_TABBY_ENABLED !== "false" &&
    env.AIDEVOPS_TAB_STATUS_ENABLED !== "false"
  );
}

function safeCall(fn, fallback) {
  try {
    const value = fn();
    return value === undefined || value === null ? fallback : value;
  } catch {
    return fallback;
  }
}

function sessionFamily(data, sessionID) {
  const root = safeCall(() => data.session.root(sessionID), sessionID) || sessionID;
  const family = safeCall(() => data.session.family(root), []);
  return { root, ids: [...new Set([root, sessionID, ...(Array.isArray(family) ? family : [])])] };
}

// Maps V2 TUI data state to the shared V1 status vocabulary.
export function resolveSessionTitleStatus(data, sessionID) {
  if (!data?.session || !sessionID) return "";
  const { ids } = sessionFamily(data, sessionID);
  const awaitingPermission = ids.some((id) => {
    const pending = safeCall(() => data.session.permission.list(id), []);
    return Array.isArray(pending) && pending.length > 0;
  });
  if (awaitingPermission) return "permission";
  const running = ids.some((id) => safeCall(() => data.session.status(id), "idle") === "running");
  return running ? "busy" : "idle";
}

function truncateTitle(title) {
  return title.length > MAX_TITLE_LENGTH ? `${title.slice(0, MAX_TITLE_LENGTH - 3)}…` : title;
}

// Returns the terminal title for the current route, or "" when the plugin
// should leave the title to OpenCode (plugin routes, missing data).
export function computeTerminalTitle(api) {
  const route = safeCall(() => api.ui.router.current(), undefined);
  if (!route || route.type === "home") return DEFAULT_TITLE;
  if (route.type !== "session" || !route.sessionID) return "";
  const { root } = sessionFamily(api.data, route.sessionID);
  const info = safeCall(() => api.data.session.get(root), undefined);
  const baseTitle = truncateTitle(sanitizeTerminalTitle(info?.title) || DEFAULT_TITLE);
  return withTerminalTitleStatus(baseTitle, resolveSessionTitleStatus(api.data, route.sessionID));
}

// V2's native TUI title writer (`OC | <title>`) can fire after this plugin for
// the same state, so an unchanged title is still re-applied once refreshMs has
// elapsed. That bounds any native overwrite to one refresh interval.
export function createTerminalTitleSync(
  api,
  { env = process.env, refreshMs = DEFAULT_REFRESH_MS, now = Date.now } = {},
) {
  let lastTitle = "";
  let lastWriteAt = 0;
  return function syncTerminalTitle() {
    if (!isTerminalTitleOwnedByAidevops(env)) return false;
    const title = computeTerminalTitle(api);
    if (!title) return false;
    const current = now();
    if (title === lastTitle && current - lastWriteAt < refreshMs) return false;
    if (typeof api?.renderer?.setTerminalTitle !== "function") return false;
    try {
      api.renderer.setTerminalTitle(title);
      lastTitle = title;
      lastWriteAt = current;
      return true;
    } catch {
      // Terminal title synchronization is best-effort and must not affect sessions.
      return false;
    }
  };
}

export function setupTerminalTitle(api, { env = process.env, pollMs = DEFAULT_POLL_MS, timers = globalThis } = {}) {
  if (!isTerminalTitleOwnedByAidevops(env)) return undefined;
  const sync = createTerminalTitleSync(api, { env });
  sync();
  // The TUI's own title effect fires on route/title changes; polling the
  // in-memory store re-applies the decorated title right after it and keeps
  // status changes (busy/permission/idle) visible without event coupling.
  const timer = timers.setInterval(sync, pollMs);
  timer?.unref?.();
  return () => timers.clearInterval(timer);
}

export default {
  id: AIDEVOPS_V2_TUI_PLUGIN_ID,
  setup(api) {
    return setupTerminalTitle(api);
  },
};
