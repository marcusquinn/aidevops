// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
import { resolve } from "node:path";
import { activeLocalOnlyPolicy, LocalOnlyPolicyError, isLoopbackDestination } from "./local-only-policy.mjs";
import { canonicalizeLocalOnlyShell, canonicalizeLocalOnlyOperation } from "./local-only-shell-policy.mjs";

// #aidevops:trust-boundary — host configuration only, keyed by trusted project.
// Copy fields so tool args and later object mutation cannot grant locality.
const mcpConfigurations = new Map();
export function captureLocalOnlyMcpConfig(entries, directory = process.cwd()) {
  const snapshot = Object.fromEntries(Object.entries(entries || {}).map(([name, entry]) =>
    [name, Object.freeze({ type: entry?.type, url: entry?.url })]));
  mcpConfigurations.set(resolve(directory), Object.freeze(snapshot));
}

export function assertLocalOnlyToolDestination(allowed, policy = activeLocalOnlyPolicy()) {
  if (policy.bound && !allowed) {
    throw new LocalOnlyPolicyError("Tool egress was blocked before execution by the local-only session binding.");
  }
}

export function assertLocalOnlyMcp(name, policy = activeLocalOnlyPolicy(), directory = process.cwd()) {
  const entry = mcpConfigurations.get(resolve(directory))?.[name];
  assertLocalOnlyToolDestination(entry?.type === "local"
    || (entry?.type === "remote" && isLoopbackDestination(entry.url)), policy);
}

const LOCAL_NATIVE_TOOLS = new Set([
  "read", "grep", "glob", "list", "write", "edit", "apply_patch", "todowrite", "todoread",
  "task", "aidevops_hook_status", "aidevops_pre_edit_check",
]);

function assertRegisteredTool(name, policy, directory) {
  const server = Object.keys(mcpConfigurations.get(resolve(directory)) || {}).sort((a, b) => b.length - a.length)
    .find((key) => name.startsWith(`${key.toLowerCase()}_`) || name.startsWith(`mcp__${key.toLowerCase()}__`));
  if (server) assertLocalOnlyMcp(server, policy, directory);
  else assertLocalOnlyToolDestination(LOCAL_NATIVE_TOOLS.has(name), policy);
}

export function assertLocalOnlyToolCall(tool, args = {}, policy = activeLocalOnlyPolicy()) {
  if (!policy.bound) return;
  const directory = policy.directory || process.cwd();
  const name = String(tool || "").toLowerCase();
  switch (name) {
    case "bash":
    case "functions_bash":
      assertLocalOnlyToolDestination(canonicalizeLocalOnlyShell(args), policy);
      break;
    case "aidevops_mcp":
      if (args.action === "connect") assertLocalOnlyMcp(args.name, policy, directory);
      break;
    default:
      if (name.endsWith("aidevops_bounded_operation")) {
        assertLocalOnlyToolDestination(canonicalizeLocalOnlyOperation(args), policy);
      } else assertRegisteredTool(name, policy, directory);
  }
}
