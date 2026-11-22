// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#35528: native desktop automation must not repeatedly seize the operator's
// working desktop. This counts focus-changing native calls per session turn
// and blocks them beyond a small budget so a confused child returns a bounded
// handoff instead of looping. It limits cooperative models; arbitrary script
// text matching is not a security boundary (kb_script_id/script_path bodies
// are opaque here).

import { scalarSessionID } from "./subagent-task-identity.mjs";

export const DEFAULT_NATIVE_FOCUS_BUDGET = 3;
export const NATIVE_FOCUS_BUDGET_ENV = "AIDEVOPS_NATIVE_FOCUS_BUDGET";
const MAX_TRACKED_SESSIONS = 64;

const NATIVE_SCRIPT_TOOL = /^macos[-_]automator_execute_script$/;
const NATIVE_AX_TOOL = /^macos[-_]automator_accessibility_query$/;
const SHELL_TOOLS = new Set(["bash", "shell", "functions.bash"]);
const FOCUS_SCRIPT_PATTERNS = [
  /\bactivate\b/i,
  /\breopen\b/i,
  /\bAXRaise\b/i,
  // `set frontmost to true`, `set frontmost of process "X" to true`, JXA `p.frontmost = true`.
  // Reads such as `whose frontmost is true` stay allowed.
  /\bfrontmost\b[^\n;]{0,160}?(?:\bto\s+true\b|=\s*true\b)/i,
];

function scriptChangesFocus(text) {
  const script = String(text || "");
  return script.length > 0 && FOCUS_SCRIPT_PATTERNS.some((pattern) => pattern.test(script));
}

/** True when the tool call would raise or activate a desktop window. */
export function changesNativeFocus(toolName, args = {}) {
  const tool = String(toolName || "").toLowerCase();
  if (NATIVE_SCRIPT_TOOL.test(tool)) return scriptChangesFocus(args?.script_content);
  if (NATIVE_AX_TOOL.test(tool)) {
    return String(args?.command || "").toLowerCase() === "perform"
      && /\baxraise\b/i.test(String(args?.action_to_perform || ""));
  }
  if (SHELL_TOOLS.has(tool)) {
    const command = String(args?.command || "");
    return /\bosascript\b/.test(command) && scriptChangesFocus(command);
  }
  return false;
}

function configuredBudget(env) {
  const raw = String(env?.[NATIVE_FOCUS_BUDGET_ENV] ?? "").trim();
  return /^\d{1,4}$/.test(raw) ? Number(raw) : DEFAULT_NATIVE_FOCUS_BUDGET;
}

function budgetMessage(limit) {
  return [
    `Native focus budget exhausted (${limit} focus-changing desktop actions this turn; GH#35528).`,
    "Stop desktop interaction and return a bounded handoff: outcome, verified facts with timestamps, actions taken, remaining actions.",
    "Observe without changing focus (accessibility_query query, app-scripting reads, window-scoped screencapture -l).",
    `Do not retry through another route; the operator can raise ${NATIVE_FOCUS_BUDGET_ENV} if more focus changes are authorized.`,
  ].join(" ");
}

function idleSessionID(event) {
  const type = event?.type;
  const idle = type === "session.idle"
    || (type === "session.status" && String(event?.properties?.status?.type || "").toLowerCase() === "idle");
  return idle ? scalarSessionID(event?.properties?.sessionID || event?.properties?.sessionId) : "";
}

/** Per-session-turn budget for focus-changing native desktop calls. */
export function createNativeDesktopFocusGuard({ env = process.env, log = () => {} } = {}) {
  const used = new Map();
  return {
    beforeTool(input, output) {
      if (!changesNativeFocus(input?.tool, output?.args || input?.args || {})) return;
      const sessionID = scalarSessionID(input?.sessionID) || "unknown-session";
      const limit = configuredBudget(env);
      const count = used.get(sessionID) || 0;
      if (count >= limit) {
        log("WARN", `[native-focus-guard] blocked focus change after ${count}/${limit} in one turn`);
        throw new Error(budgetMessage(limit));
      }
      used.delete(sessionID);
      used.set(sessionID, count + 1);
      while (used.size > MAX_TRACKED_SESSIONS) used.delete(used.keys().next().value);
    },
    // A finished turn (child returned, or the operator's next prompt) restores the budget.
    handleEvent(input) {
      const sessionID = idleSessionID(input?.event || input || {});
      if (sessionID) used.delete(sessionID);
    },
  };
}
