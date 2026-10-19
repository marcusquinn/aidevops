// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#35121: Capture Check for the session-continuation guard. Tracks files
// changed by this session's edit tools and, when a closeout asks the user for
// nothing, reports which remain uncommitted using live `git status` on those
// paths only. Unrelated or user-owned dirty files never count; Git failures
// are skipped (fail-open). Never commits anything.

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { editedPaths, isUnaskedCloseout } from "./session-continuation-utils.mjs";

const MAX_EDITED_PATHS = 200;
const MAX_GIT_ROOTS = 8;
const GIT_TIMEOUT_MS = 3000;

function git(cwd, args) {
  return execFileSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: GIT_TIMEOUT_MS,
  });
}

function tryGit(cwd, args) {
  try { return git(cwd, args); } catch { return null; }
}

// Git reports canonical roots, so canonicalise the directory too: symlinked
// prefixes (macOS /var -> /private/var) must still yield in-repository paths.
function canonicalDirectory(path) {
  try { return realpathSync(dirname(path)); } catch { return ""; }
}

function rootOf(directory, cache) {
  if (!cache.has(directory)) cache.set(directory, (tryGit(directory, ["rev-parse", "--show-toplevel"]) || "").trim());
  return cache.get(directory);
}

function groupByRoot(paths) {
  const byRoot = new Map();
  const cache = new Map();
  for (const path of paths) {
    const directory = canonicalDirectory(path);
    const root = directory ? rootOf(directory, cache) : "";
    if (!root || (!byRoot.has(root) && byRoot.size >= MAX_GIT_ROOTS)) continue;
    if (!byRoot.has(root)) byRoot.set(root, []);
    byRoot.get(root).push(relative(root, join(directory, basename(path))));
  }
  return byRoot;
}

// Returns [{ root, files: [changed relative paths] }] for roots with dirty
// session edits.
export function defaultDirtyEdits(paths) {
  const dirty = [];
  for (const [root, files] of groupByRoot(paths)) {
    const status = tryGit(root, ["status", "--porcelain=v1", "--untracked-files=all", "--", ...files]) || "";
    const changed = status.split("\n").filter(Boolean).map((line) => line.slice(3));
    if (changed.length > 0) dirty.push({ root, files: changed });
  }
  return dirty;
}

// Adds the absolute paths an edit tool call changed; returns the updated set,
// or null when the call edited nothing.
export function addEditedPaths(edits, tool, args, repository) {
  const paths = editedPaths(tool, args);
  if (paths.length === 0) return null;
  const next = edits || new Set();
  for (const path of paths) {
    if (next.size >= MAX_EDITED_PATHS) break;
    next.add(resolve(repository, path));
  }
  return next;
}

function steeringText(dirty) {
  const summary = dirty
    .map(({ root, files }) => `${root} (${files.length} file${files.length === 1 ? "" : "s"}: ${files.slice(0, 5).join(", ")}${files.length > 5 ? ", …" : ""})`)
    .join("; ");
  return `Your closeout asks the user for nothing, but files this session edited remain uncommitted: ${summary}. Per the reference/session.md Capture Check, commit them now if you hold commit authority; otherwise ask for bounded commit/PR/merge approval under Needed from you, name each worktree and its changes under Left to capture, and keep Close at Not yet. Do not commit without authority.`;
}

// Returns { steering, fingerprint, dirty } when the closeout should be
// steered, { error } when the dirty check threw, otherwise {}. A dirty set
// already steered (same fingerprint) is not steered again.
export function captureCheck(edits, text, dirtyEdits, previousFingerprint) {
  if (!edits || edits.size === 0 || !isUnaskedCloseout(text)) return {};
  let dirty;
  try {
    dirty = dirtyEdits([...edits]);
  } catch (error) {
    return { error };
  }
  if (!Array.isArray(dirty) || dirty.length === 0) return {};
  const fingerprint = createHash("sha256").update(JSON.stringify(dirty)).digest("hex");
  if (fingerprint === previousFingerprint) return {};
  return { steering: steeringText(dirty), fingerprint, dirty };
}
