// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Home-relative toolchain roots workers may read (never write) without a
// maintainer. Extend deliberately; the broker's forbidden pattern still applies.
const READ_ONLY_ROOTS = ["~/.nvm"];
const READ_ONLY_TOOLS = new Set(["read", "glob", "grep", "list"]);

function normalizeAbsolute(value) {
  return typeof value === "string" ? value.replaceAll("\\", "/").replace(/\/+$/, "") : "";
}

export function isReadOnlyRootRead(context, raw, forbiddenPattern) {
  const permission = raw?.permission || raw?.type || "";
  const callID = raw?.tool?.callID || raw?.callID || "";
  if (permission !== "external_directory") return false;
  if (!READ_ONLY_TOOLS.has(context.toolCalls.get(callID)?.tool)) return false;
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
