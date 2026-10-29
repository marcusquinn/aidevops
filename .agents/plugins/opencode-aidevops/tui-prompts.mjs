// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Sidebar "Prompts" quick-nav shared by the OpenCode 1.x (v1-tui/tui.tsx) and
// V2 (v2-plugin/tui.mjs) TUI plugins. Rows open the native `session.timeline`
// ("Jump to message") dialog; neither runtime exposes a transcript-scroll or
// message-rendering API to plugins, so navigation stays inside that dialog.
//
// Slash commands: OpenCode stores the expanded command template as the user's
// text part and keeps no durable record of what was typed, so the server plugin
// stamps that part via `command.execute.before` (stampCommandPrompt) and rows
// render `/name arguments`. Unstamped legacy turns drop leading HTML comments
// (command-file SPDX headers) instead of showing them as the prompt.

export const PROMPTS_TIMELINE_COMMAND = "session.timeline";
const DEFAULT_LIMIT = 8;
const DEFAULT_WIDTH = 34;
const LEADING_HTML_COMMENTS = /^\s*(?:<!--[\s\S]*?-->\s*)+/;

function attempt(fn, fallback) {
  try {
    const value = fn();
    return value === undefined || value === null ? fallback : value;
  } catch {
    return fallback;
  }
}

export function isPromptsEnabled(env = process.env) {
  return !["false", "0", "none"].includes(String(env.AIDEVOPS_TUI_PROMPTS ?? "").trim().toLowerCase());
}

function isUserPrompt(message) {
  return (message?.type ?? message?.role) === "user" && !message.synthetic && !message.ignored;
}

function isPromptPart(part) {
  return part?.type === "text" && !part.synthetic && !part.ignored && typeof part.text === "string";
}

function withoutLeadingComments(text) {
  const stripped = text.replace(LEADING_HTML_COMMENTS, "");
  return stripped.trim() ? stripped : text;
}

function commandLabel(part) {
  const command = part?.metadata?.aidevops?.command;
  if (typeof command?.name !== "string" || !command.name) return "";
  const args = typeof command.arguments === "string" ? command.arguments : "";
  return `/${command.name} ${args}`;
}

function partPromptText(part) {
  return commandLabel(part) || withoutLeadingComments(part.text);
}

function promptText(message, partsFor) {
  if (!isUserPrompt(message)) return "";
  if (typeof partsFor !== "function") return typeof message.text === "string" ? withoutLeadingComments(message.text) : "";
  const parts = attempt(() => partsFor(message.id), []);
  if (!Array.isArray(parts)) return "";
  return parts.filter(isPromptPart).map(partPromptText).join(" ");
}

// `command.execute.before` hook: mutate the template text part in place
// (OpenCode keeps its own `parts` reference). Model input and the native
// transcript are unchanged; only part metadata gains the typed command.
export function stampCommandPrompt(input, output) {
  const name = typeof input?.command === "string" ? input.command.trim() : "";
  const part = Array.isArray(output?.parts) ? output.parts.find(isPromptPart) : undefined;
  if (!name || !part) return false;
  const metadata = part.metadata && typeof part.metadata === "object" ? part.metadata : {};
  const command = { name, arguments: typeof input.arguments === "string" ? input.arguments : "" };
  part.metadata = { ...metadata, aidevops: { ...metadata.aidevops, command } };
  return true;
}

function truncate(text, width) {
  const chars = Array.from(text);
  return chars.length > width ? `${chars.slice(0, Math.max(0, width - 1)).join("")}…` : text;
}

// Both stores list messages chronologically. V1 uses role + text parts; V2
// uses type + text and represents synthetic messages as a separate type.
export function extractPromptRows(messages, partsFor, { limit = DEFAULT_LIMIT, width = DEFAULT_WIDTH } = {}) {
  const rows = [];
  if (!Array.isArray(messages)) return rows;
  for (let i = messages.length - 1; i >= 0 && rows.length < limit; i -= 1) {
    const text = promptText(messages[i], partsFor).replace(/\s+/g, " ").trim();
    if (text) rows.push({ id: messages[i].id, text: truncate(text, width) });
  }
  return rows;
}

// V1 exposes `api.keymap.dispatchCommand`; V2 exposes `api.keymap.dispatch`.
export function openPromptsTimeline(keymap) {
  const dispatch = keymap?.dispatchCommand ?? keymap?.dispatch;
  if (typeof dispatch !== "function") return false;
  return attempt(() => {
    dispatch.call(keymap, PROMPTS_TIMELINE_COMMAND);
    return true;
  }, false);
}

function v2TextColor(theme, muted) {
  const text = theme?.text;
  return muted ? text?.subdued ?? text?.muted ?? text?.base : text?.default ?? text?.base;
}

function createV2Text(solid, api, label, onMouseUp, muted) {
  const node = solid.createElement("text");
  solid.setProp(node, "wrapMode", "none");
  solid.setProp(node, "onMouseUp", onMouseUp);
  solid.effect(() => {
    const color = attempt(() => v2TextColor(api.theme, muted), undefined);
    if (color !== undefined) solid.setProp(node, "fg", color);
  });
  solid.insert(node, label);
  return node;
}

// Builds the V2 section with the @opentui/solid universal renderer API so the
// .mjs entrypoint needs no JSX transform. Expanded by default.
export function renderPromptsV2(solid, solidJs, api, props) {
  const rows = solidJs.createMemo(() =>
    attempt(() => extractPromptRows(api.data.session.message.list(props.sessionID)), []),
  );
  const [open, setOpen] = solidJs.createSignal(true);
  const timeline = () => openPromptsTimeline(api.keymap);
  const text = (label, onMouseUp, muted = false) => createV2Text(solid, api, label, onMouseUp, muted);
  const section = solid.createElement("box");
  const header = solid.createElement("box");
  solid.setProp(header, "flexDirection", "row");
  solid.insert(header, text(() => `${open() ? "▼" : "▶"} Prompts`, () => setOpen((value) => !value)));
  solid.insert(header, () => (open() ? undefined : text(() => ` (${rows().length})`, timeline, true)));
  solid.insert(section, header);
  solid.insert(section, () => (open() ? rows().map((row) => text(row.text, timeline)) : []));
  return () => (rows().length > 0 ? section : undefined);
}

export function setupPromptsSlot(
  api,
  { env = process.env, loadSolid = () => import("@opentui/solid"), loadSolidJs = () => import("solid-js") } = {},
) {
  if (!isPromptsEnabled(env) || typeof api?.ui?.slot !== "function") return undefined;
  let disposed = false;
  let unregister;
  const register = ([solid, solidJs]) => {
    if (disposed) return;
    unregister = attempt(
      () => api.ui.slot({
        prepend: "sidebar.content",
        render: (props) => attempt(() => renderPromptsV2(solid, solidJs, api, props), undefined),
      }),
      undefined,
    );
  };
  // A missing renderer must leave the rest of the sidebar usable.
  const ready = Promise.all([loadSolid(), loadSolidJs()]).then(register).catch(() => undefined);
  const cleanup = () => {
    disposed = true;
    if (typeof unregister === "function") attempt(unregister, undefined);
    unregister = undefined;
  };
  cleanup.ready = ready;
  return cleanup;
}
