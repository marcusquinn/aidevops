// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { lstatSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";

function hasBoundedReadTarget(raw, target, forbidden) {
  if (typeof target !== "string" || !isAbsolute(target)) return false;
  if (/[*?\[\]{}\u0000]/.test(target) || forbidden.test(target)) return false;
  if (target.split(/[\\/]+/).includes("..")) return false;
  const source = raw?.patterns ?? raw?.pattern ?? [];
  const patterns = Array.isArray(source) ? source : [source];
  const bounded = [target, `${dirname(target)}/*`, `${dirname(target)}/**`];
  return patterns.length > 0 && patterns.every((pattern) =>
    !forbidden.test(String(pattern)) && bounded.includes(pattern));
}

function missingTargetAncestor(target) {
  let ancestor = resolve(target);
  try {
    lstatSync(ancestor);
    return "";
  } catch (err) {
    if (err.code !== "ENOENT") return "";
  }
  while (true) {
    const parent = dirname(ancestor);
    if (parent === ancestor) return "";
    ancestor = parent;
    try {
      lstatSync(ancestor);
      return ancestor;
    } catch (err) {
      if (err.code !== "ENOENT") return "";
    }
  }
}

function hasSymlinkAncestor(ancestor) {
  // Checking only the nearest directory misses symlinks above it.
  let component = ancestor;
  try {
    while (true) {
      if (lstatSync(component).isSymbolicLink()) return true;
      const parent = dirname(component);
      if (parent === component) break;
      component = parent;
    }
  } catch {
    return true;
  }
  return false;
}

function isWithin(root, target) {
  const within = relative(resolve(root), target);
  if (within === ".." || within.startsWith("../")) return false;
  return !isAbsolute(within);
}

function isMissingOutsideManaged(context, target) {
  const ancestor = missingTargetAncestor(target);
  if (!ancestor || hasSymlinkAncestor(ancestor)) return false;
  const managed = [join(context.home, ".aidevops"),
    join(context.dataHome, "opencode", "tool-output"), process.env.WORKER_WORKTREE_PATH].filter(Boolean);
  return !managed.some((root) => isWithin(root, ancestor));
}

// Exact absent read-only targets fail, never auto-allow. Ambiguous filesystem
// errors, symlinks, unbounded patterns and credentials keep the normal gate.
export function impossibleExternalRead(context, raw, forbidden) {
  if ((raw?.permission || raw?.type) !== "external_directory") return "";
  const call = context.toolCalls.get(raw?.tool?.callID || raw?.callID || "");
  const tool = call?.tool || raw?.metadata?.tool;
  if (!["read", "glob", "grep", "list"].includes(tool)) return "";
  const target = call?.target || raw?.metadata?.filepath || raw?.metadata?.path;
  if (!hasBoundedReadTarget(raw, target, forbidden)) return "";
  if (!isMissingOutsideManaged(context, target)) return "";
  const hint = target.includes("/.aidevops/.agent-workspace/")
    ? ` Resolve MCP artifacts from the session output directory under ${join(context.home, ".aidevops", ".agent-workspace")}.`
    : " Check the tool's artifact path and working directory.";
  return `External read target does not exist; no permission approval can make this read succeed.${hint}`;
}

export function rejectImpossibleToolRead(context, input, forbidden) {
  if (!context.isHeadless()) return;
  const callID = input?.callID || input?.callId;
  const target = context.toolCalls.get(callID)?.target;
  const message = impossibleExternalRead(context, {
    permission: "external_directory", callID, patterns: target ? [target] : [],
  }, forbidden);
  if (message) throw new Error(message);
}
