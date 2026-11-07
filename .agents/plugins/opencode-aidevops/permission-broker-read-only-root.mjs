// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { realpathSync } from "node:fs";

// Home-relative toolchain roots workers may read (never write) without a
// maintainer. Extend deliberately; the broker's forbidden pattern still applies.
const READ_ONLY_ROOTS = ["~/.nvm", "~/.local/bin"];
const READ_ONLY_TOOLS = new Set(["read", "glob", "grep", "list"]);

function normalizeAbsolute(value) {
  return typeof value === "string" ? value.replaceAll("\\", "/").replace(/\/+$/, "") : "";
}

// Resolve symlinks (including through the nearest existing ancestor for absent
// paths). Returns "" when resolution fails, so callers deny.
function resolveReal(value) {
  const base = value.replace(/\/\*{1,2}$/, "");
  if (/[*?\[\]{}]/.test(base)) return "";
  let existing = base;
  let rest = "";
  while (existing) {
    try {
      return normalizeAbsolute(realpathSync(existing)) + rest;
    } catch (err) {
      if (err?.code !== "ENOENT") return "";
      const cut = existing.lastIndexOf("/");
      if (cut <= 0) return "";
      rest = existing.slice(cut) + rest;
      existing = existing.slice(0, cut);
    }
  }
  return "";
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
  const realTarget = target ? resolveReal(target) : "";
  if (target && (!realTarget || forbiddenPattern.test(realTarget))) return false;
  const input = raw?.patterns ?? raw?.pattern;
  const patterns = Array.isArray(input) ? input : input == null ? [] : [input];
  if (patterns.length === 0 || patterns.length > 20) return false;
  const home = normalizeAbsolute(context.home);
  const roots = READ_ONLY_ROOTS.map((root) => normalizeAbsolute(root.startsWith("~/") ? `${home}/${root.slice(2)}` : root));
  // Resolve only the home prefix: a symlinked root itself must not widen access.
  const realHome = resolveReal(home) || home;
  const realRoots = roots.map((root) => (root.startsWith(`${home}/`) ? `${realHome}${root.slice(home.length)}` : root));
  const within = (value, list) => list.some((root) => value === root || value.startsWith(`${root}/`));
  return patterns.every((pattern) => {
    const value = normalizeAbsolute(pattern);
    if (!value || forbiddenPattern.test(value)) return false;
    if (value.split("/").includes("..")) return false;
    if (!within(value, roots)) return false;
    // Symlink destination must stay inside an authorized root and be allowed.
    const real = resolveReal(value);
    if (!real || forbiddenPattern.test(real)) return false;
    if (!within(real, realRoots)) return false;
    return !realTarget || within(realTarget, realRoots);
  });
}
