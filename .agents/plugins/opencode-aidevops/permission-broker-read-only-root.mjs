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
export function resolveReal(value) {
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

// Lexical and symlink-resolved forms of the recorded target and raw patterns, so
// a link to a credential location is classified non-grantable.
export function resolvedRiskTargets(raw, target) {
  const source = raw?.patterns ?? raw?.pattern;
  const patterns = Array.isArray(source) ? source : source == null ? [] : [source];
  const items = [target || raw?.metadata?.filepath || raw?.metadata?.path || "", ...patterns]
    .filter((item) => typeof item === "string" && item);
  return items.flatMap((item) => {
    const lexical = item.replaceAll("\\", "/");
    const real = resolveReal(lexical);
    return real ? [lexical, real] : [lexical];
  });
}

function toPatternList(raw) {
  const input = raw?.patterns ?? raw?.pattern;
  if (Array.isArray(input)) return input;
  return input == null ? [] : [input];
}

function within(value, list) {
  return list.some((root) => value === root || value.startsWith(`${root}/`));
}

function hasParentSegment(value) {
  return value.split("/").includes("..");
}

// Directory-wide patterns (e.g. ~/.local/bin/*) must not approve a forbidden target.
// Returns the resolved target ("" when none) or null to deny.
function resolveTarget(context, raw, callID, forbiddenPattern) {
  const target = normalizeAbsolute(context.toolCalls.get(callID)?.target
    || raw?.metadata?.filepath || raw?.metadata?.path);
  if (!target) return "";
  if (forbiddenPattern.test(target) || hasParentSegment(target)) return null;
  const realTarget = resolveReal(target);
  if (!realTarget || forbiddenPattern.test(realTarget)) return null;
  return realTarget;
}

function buildRoots(homeValue) {
  const home = normalizeAbsolute(homeValue);
  const roots = READ_ONLY_ROOTS.map((root) => normalizeAbsolute(root.startsWith("~/") ? `${home}/${root.slice(2)}` : root));
  // Resolve only the home prefix: a symlinked root itself must not widen access.
  const realHome = resolveReal(home) || home;
  const realRoots = roots.map((root) => (root.startsWith(`${home}/`) ? `${realHome}${root.slice(home.length)}` : root));
  return { roots, realRoots };
}

function patternAllowed(pattern, rootSet, realTarget, forbiddenPattern) {
  const value = normalizeAbsolute(pattern);
  if (!value || forbiddenPattern.test(value) || hasParentSegment(value)) return false;
  if (!within(value, rootSet.roots)) return false;
  // Symlink destination must stay inside an authorized root and be allowed.
  const real = resolveReal(value);
  if (!real || forbiddenPattern.test(real) || !within(real, rootSet.realRoots)) return false;
  return !realTarget || within(realTarget, rootSet.realRoots);
}

export function isReadOnlyRootRead(context, raw, forbiddenPattern) {
  const permission = raw?.permission || raw?.type || "";
  const callID = raw?.tool?.callID || raw?.callID || "";
  if (permission !== "external_directory") return false;
  if (!READ_ONLY_TOOLS.has(context.toolCalls.get(callID)?.tool)) return false;
  const realTarget = resolveTarget(context, raw, callID, forbiddenPattern);
  if (realTarget === null) return false;
  const patterns = toPatternList(raw);
  if (patterns.length === 0 || patterns.length > 20) return false;
  const rootSet = buildRoots(context.home);
  return patterns.every((pattern) => patternAllowed(pattern, rootSet, realTarget, forbiddenPattern));
}
