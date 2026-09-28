// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// OpenCode V2 TUI entrypoint. V2 server plugins run inside the tty-less
// `opencode serve --service` process, so the V1 /dev/tty title writer cannot
// reach the terminal. The TUI process owns the renderer, so the status-dot
// terminal title (⚪ busy, 🟡 permission, 🟢 idle) is rendered here instead.

import { homedir } from "node:os";
import { join } from "node:path";
import { readAidevopsVersion, withAidevopsTitleSuffix } from "../session-title-suffix.mjs";
import { sanitizeTerminalTitle, withTerminalTitleStatus } from "../terminal-title.mjs";

// Distinct from the server plugin id so TUI and server registries never collide.
export const AIDEVOPS_V2_TUI_PLUGIN_ID = "aidevops-tui";
const DEFAULT_TITLE = "OpenCode";
const MAX_TITLE_LENGTH = 40;
const DEFAULT_POLL_MS = 300;
const DEFAULT_REFRESH_MS = 2000;
const VERSION_CACHE_MS = 60_000;

// V1 stores `· AIDevOps <version>` in the session title itself; V2 session
// titles are also V2 tab labels, so the suffix is applied to the terminal
// title only. The version file is re-read at most once per minute so a
// long-running TUI picks up `aidevops update` without per-poll file reads.
export function createVersionReader({
  agentsDir = join(homedir(), ".aidevops", "agents"),
  readVersion = readAidevopsVersion,
  now = Date.now,
  cacheMs = VERSION_CACHE_MS,
} = {}) {
  let cached = "";
  let readAt = -Infinity;
  return () => {
    const current = now();
    if (current - readAt >= cacheMs) {
      cached = safeCall(() => readVersion(agentsDir), cached);
      readAt = current;
    }
    return cached;
  };
}

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
export function computeTerminalTitle(api, version = "") {
  const route = safeCall(() => api.ui.router.current(), undefined);
  if (!route || route.type === "home") return withAidevopsTitleSuffix(DEFAULT_TITLE, version);
  if (route.type !== "session" || !route.sessionID) return "";
  const { root } = sessionFamily(api.data, route.sessionID);
  const info = safeCall(() => api.data.session.get(root), undefined);
  const baseTitle = truncateTitle(sanitizeTerminalTitle(info?.title) || DEFAULT_TITLE);
  return withTerminalTitleStatus(
    withAidevopsTitleSuffix(baseTitle, version),
    resolveSessionTitleStatus(api.data, route.sessionID),
  );
}

// V2's native TUI title writer (`OC | <title>`) can fire after this plugin for
// the same state, so an unchanged title is still re-applied once refreshMs has
// elapsed. That bounds any native overwrite to one refresh interval.
export function createTerminalTitleSync(
  api,
  { env = process.env, refreshMs = DEFAULT_REFRESH_MS, now = Date.now, getVersion = () => "" } = {},
) {
  let lastTitle = "";
  let lastWriteAt = 0;
  const isFresh = (title, current) => title === lastTitle && current - lastWriteAt < refreshMs;
  return function syncTerminalTitle() {
    const canWrite =
      isTerminalTitleOwnedByAidevops(env) && typeof api?.renderer?.setTerminalTitle === "function";
    const title = canWrite ? computeTerminalTitle(api, safeCall(getVersion, "")) : "";
    const current = now();
    if (!title || isFresh(title, current)) return false;
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

export function setupTerminalTitle(
  api,
  { env = process.env, pollMs = DEFAULT_POLL_MS, timers = globalThis, getVersion = createVersionReader() } = {},
) {
  if (!isTerminalTitleOwnedByAidevops(env)) return undefined;
  const sync = createTerminalTitleSync(api, { env, getVersion });
  sync();
  // The TUI's own title effect fires on route/title changes; polling the
  // in-memory store re-applies the decorated title right after it and keeps
  // status changes (busy/permission/idle) visible without event coupling.
  const timer = timers.setInterval(sync, pollMs);
  timer?.unref?.();
  return () => timers.clearInterval(timer);
}

// V2 UI slots that show version labels. `prompt.footer.status` covers both the
// home and session prompts; `sidebar.footer` pairs the OpenCode and AIDevOps
// versions. Other slots stay available for AIDEVOPS_TUI_VERSION_SLOTS (comma
// list, or "none" to disable).
export const DEFAULT_VERSION_SLOTS = ["prompt.footer.status", "sidebar.footer"];
export const VERSION_SLOT_CANDIDATES = [
  ...DEFAULT_VERSION_SLOTS,
  "sidebar.content",
  "home.footer.status",
];
const SLOTS_WITH_OPENCODE_VERSION = new Set(["sidebar.footer"]);
const VERSION_SLOT_POLL_MS = 5000;

export function resolveVersionSlots(env = process.env) {
  const raw = String(env.AIDEVOPS_TUI_VERSION_SLOTS ?? "").trim();
  if (!raw) return [...DEFAULT_VERSION_SLOTS];
  if (raw === "none" || raw === "false") return [];
  return raw
    .split(",")
    .map((slot) => slot.trim())
    .filter((slot) => VERSION_SLOT_CANDIDATES.includes(slot));
}

export function formatVersionLabel(version, opencodeVersion = "") {
  const aidevops = version ? `AIDevOps ${version}` : "";
  const opencode = opencodeVersion ? `OpenCode ${String(opencodeVersion).replace(/^v/i, "")}` : "";
  return [opencode, aidevops].filter(Boolean).join(" · ");
}

export function formatSlotLabel(slot, version, opencodeVersion = "") {
  return formatVersionLabel(version, SLOTS_WITH_OPENCODE_VERSION.has(slot) ? opencodeVersion : "");
}

function themeColor(theme) {
  return safeCall(() => theme?.text?.muted ?? theme?.text?.base, undefined);
}

// Builds `<text fg={muted}>AIDevOps x.y.z</text>` with the @opentui/solid
// universal renderer API, so this .mjs entrypoint needs no JSX transform.
export function renderVersionText(solid, label, theme) {
  const el = solid.createElement("text");
  solid.effect(() => {
    const color = themeColor(theme);
    if (color !== undefined) solid.setProp(el, "fg", color);
  });
  solid.insert(el, label);
  return el;
}

// Registers the version label in each configured slot. The label is a Solid
// signal refreshed from the cached version reader, so `aidevops update`
// appears in running sessions without a TUI restart.
export function setupVersionSlots(
  api,
  {
    env = process.env,
    timers = globalThis,
    getVersion = createVersionReader(),
    loadSolid = () => import("@opentui/solid"),
    loadSolidJs = () => import("solid-js"),
    pollMs = VERSION_SLOT_POLL_MS,
  } = {},
) {
  const slots = resolveVersionSlots(env);
  if (slots.length === 0 || typeof api?.ui?.slot !== "function") return undefined;
  const disposers = [];
  let disposed = false;
  const ready = Promise.all([loadSolid(), loadSolidJs()])
    .then(([solid, solidJs]) => {
      if (disposed) return;
      const [version, setVersion] = solidJs.createSignal(safeCall(getVersion, ""));
      const timer = timers.setInterval(() => setVersion(safeCall(getVersion, "")), pollMs);
      timer?.unref?.();
      disposers.push(() => timers.clearInterval(timer));
      const opencodeVersion = () => safeCall(() => api.app?.version, "");
      for (const slot of slots) {
        const label = () => formatSlotLabel(slot, version(), opencodeVersion());
        const unregister = safeCall(
          () => api.ui.slot({ append: slot, render: () => renderVersionText(solid, label, api.theme) }),
          undefined,
        );
        if (typeof unregister === "function") disposers.push(unregister);
      }
    })
    .catch(() => {
      // Version display is cosmetic; a missing renderer must not affect the TUI.
    });
  const cleanup = () => {
    disposed = true;
    for (const dispose of disposers.splice(0)) safeCall(dispose, undefined);
  };
  cleanup.ready = ready;
  return cleanup;
}

export default {
  id: AIDEVOPS_V2_TUI_PLUGIN_ID,
  setup(api) {
    const cleanups = [setupTerminalTitle(api), setupVersionSlots(api)].filter(Boolean);
    return () => {
      for (const cleanup of cleanups) cleanup();
    };
  },
};
