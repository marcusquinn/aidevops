// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Home-relative toolchain roots workers may read (never write) without a
// maintainer. Extend deliberately; the broker's forbidden pattern still applies.
import { realpathSync } from "node:fs";

const READ_ONLY_ROOTS = ["~/.nvm", "~/.local/bin"];
const READ_ONLY_TOOLS = new Set(["read", "glob", "grep", "list"]);

function normalizeAbsolute(value) {
  return typeof value === "string" ? value.replaceAll("\\", "/").replace(/\/+$/, "") : "";
}

// Resolve symlinks so a link inside an allowed root cannot reach a forbidden
// destination. Missing targets stay lexical (the read fails on its own); any
// other resolution failure denies.
function resolvesToForbidden(target, forbiddenPattern) {
  try {
    return forbiddenPattern.test(normalizeAbsolute(realpathSync(target)));
  } catch (error) {
    return error?.code !== "ENOENT";
  }
}

export function isReadOnlyRootRead(context, raw, forbiddenPattern) {
  const permission = raw?.permission || raw?.type || "";
  const callID = raw?.tool?.callID || raw?.callID || "";
  if (permission !== "external_directory") return false;
  if (!READ_ONLY_TOOLS.has(context.toolCalls.get(callID)?.tool)) return false;
  // Directory-wide patterns (e.g. ~/.local/bin/*) must not approve a forbidden target.
  const target = normalizeAbsolute(context.toolCalls.get(callID)?.target
    || raw?.metadata?.filepath || raw?.metadata?.path);
  if (target && (forbiddenPattern.test(target) || target.split("/").includes(".."))) return false;
  if (target && resolvesToForbidden(target, forbiddenPattern)) return false;
  const input = raw?.patterns ?? raw?.pattern;
  const patterns = Array.isArray(input) ? input : input == null ? [] : [input];
  if (patterns.length === 0 || patterns.length > 20) return false;
  const home = normalizeAbsolute(context.home);
  const roots = READ_ONLY_ROOTS.map((root) => normalizeAbsolute(root.startsWith("~/") ? `${home}/${root.slice(2)}` : root));
  return patterns.every((pattern) => {
    const value = normalizeAbsolute(pattern);
    if (!value || forbiddenPattern.test(value)) return false;
    if (value.split("/").includes("..")) return false;
    return roots.some((root) => value === root || value.startsWith(`${root}/`));
  });
}
