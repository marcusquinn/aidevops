// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const COMMAND_RULES = [
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?gh\s+repo\s+fork\b/, "github", "fork"],
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?gh\s+repo\s+(?:create|delete|archive|rename|edit)\b/, "github", "repository"],
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?gh\s+issue\s+(?:create|edit|close|reopen|comment|delete|transfer|pin|unpin|lock|unlock)\b/, "github", "issue"],
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?gh\s+pr\s+(?:create|edit|close|reopen|merge|comment|review|ready)\b/, "github", "pull_request"],
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?git\s+worktree\s+(?:add|move|remove|prune|repair)\b/, "git", "worktree"],
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?git\s+push\b/, "git", "push"],
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?git\s+commit\b/, "git", "commit"],
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?git\s+remote\s+(?:add|remove|rename|set-url|set-head|prune|update)\b/, "git", "remote"],
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?git\s+(?:branch|tag|update-ref|symbolic-ref)\b/, "git", "ref"],
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?git\s+(?:add|rm|mv|merge|rebase|reset|revert|cherry-pick|stash|clean)\b/, "git", "state"],
  [/\bgh\s+api\b[^\n]*(?:--method|-x)\s+(?:post|put|patch|delete)\b/, "external", "write"],
  [/\bcurl\b[^\n]*(?:-x|--request)\s+(?:post|put|patch|delete)\b/, "external", "write"],
  [/(?:^|[;&|]\s*)(?:rm|mv|cp|touch|mkdir|install|tee)\b/, "file", "write"],
  [/(?:^|[;&|]\s*)(?:[\w./-]+\/)?osascript\b/, "desktop", "native_ui"],
];

const FILE_TOOLS = new Set(["write", "edit", "apply_patch", "write_file", "functions.apply_patch"]);
const READ_ONLY_TOOLS = new Set(["read", "grep", "glob", "todowrite", "webfetch"]);
const SHELL_TOOLS = new Set(["bash", "shell", "functions.bash"]);

export function safeToolName(value) {
  const name = String(value || "unknown").toLowerCase();
  return /^[a-z0-9_.:-]+$/.test(name) ? name.slice(0, 48) : "redacted-tool";
}

function commandText(args) {
  let command = "";
  if (typeof args?.command === "string") command = args.command;
  else if (Array.isArray(args?.argv)) command = args.argv.join(" ");
  return command;
}

// GH#35529: native desktop actions (scripts can be opaque kb_script_id/script_path
// references, so every execute_script counts) and AX perform actions.
function nativeDesktopAction(tool, args) {
  if (!tool.startsWith("macos-automator_")) return false;
  if (tool.endsWith("_execute_script")) return true;
  return tool.endsWith("_accessibility_query") && String(args?.command || "").toLowerCase() === "perform";
}

function commandClassification(command) {
  const text = String(command || "").toLowerCase();
  const rule = COMMAND_RULES.find(([pattern]) => pattern.test(text));
  return rule ? { kind: rule[1], operation: rule[2] } : null;
}

/** Classify only observed mutation-shaped calls without retaining their arguments. */
export function classifySideEffect(toolName, args = {}) {
  const tool = safeToolName(toolName);
  let effect = null;
  if (FILE_TOOLS.has(tool)) {
    effect = { kind: "file", operation: "write", tool };
  } else if (READ_ONLY_TOOLS.has(tool)) {
    effect = null;
  } else if (nativeDesktopAction(tool, args)) {
    effect = { kind: "desktop", operation: "native_ui", tool };
  } else if (SHELL_TOOLS.has(tool)) {
    const classification = commandClassification(commandText(args));
    effect = classification ? { ...classification, tool } : null;
  } else if (/fork/.test(tool)) {
    effect = { kind: "github", operation: "fork", tool };
  } else if (/issue/.test(tool) && /create|edit|close|comment|write|update|delete/.test(tool)) {
    effect = { kind: "github", operation: "issue", tool };
  } else if (/(?:pull.?request|\bpr\b)/.test(tool) && /create|edit|close|merge|comment|review|write|update/.test(tool)) {
    effect = { kind: "github", operation: "pull_request", tool };
  } else if (/create|write|edit|update|delete|remove|send|post|publish|deploy|merge|push/.test(tool)) {
    effect = { kind: "external", operation: "write", tool };
  }
  return effect;
}
