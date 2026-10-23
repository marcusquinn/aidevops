// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Headless workers read widely but write only inside their own worktree and
// managed temp. Sibling worktrees are read-only (GH#35139).

import { realpathSync } from "fs";
import { homedir } from "os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "path";
import { isHeadless } from "./proxy-lifecycle.mjs";

// Stable prefix; fenceMessage() appends the target and the accepted roots.
export const SIBLING_WORKTREE_MESSAGE =
  "BLOCKED: Sibling worktrees are read-only for workers.";

const MUTATING_GIT_VERBS = new Set([
  "add", "commit", "checkout", "switch", "reset", "restore", "stash", "clean",
  "merge", "rebase", "push", "rm", "mv", "cherry-pick", "revert", "apply", "am",
]);
const MUTATING_WORKTREE_SUBCOMMANDS = new Set(["remove", "move", "prune", "add"]);
// Git options that consume the following token as a value.
const GIT_VALUE_OPTIONS = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]);

function pathIsWithin(candidate, parent) {
  const relation = relative(parent, candidate);
  return relation === "" || (relation !== ".." && !relation.startsWith(`..${sep}`) && !isAbsolute(relation));
}

// Resolve symlinks for the longest existing ancestor, then re-append the rest.
function physicalPath(target) {
  let current = resolve(target);
  const tail = [];
  for (;;) {
    try {
      return join(realpathSync(current), ...tail.reverse());
    } catch {
      const parent = dirname(current);
      if (parent === current) return resolve(target);
      tail.push(current.slice(parent.length).replace(/^[\\/]+/, ""));
      current = parent;
    }
  }
}

function managedTempRoot(env) {
  return physicalPath(env.AIDEVOPS_TEMP_DIR || join(env.HOME || homedir(), ".aidevops", ".agent-workspace", "tmp"));
}

function allowedRoots(env) {
  return [env.WORKER_WORKTREE_PATH && physicalPath(env.WORKER_WORKTREE_PATH), managedTempRoot(env)].filter(Boolean);
}

// Name both accepted roots: a block that only pointed at the worktree sent
// private scratch work into Git, where repository tools refuse it (GH#35495).
function fenceMessage(label, target, env) {
  return `${SIBLING_WORKTREE_MESSAGE} ${label}: ${target} is outside the worker write roots. `
    + `Workers write only inside their own worktree (${physicalPath(env.WORKER_WORKTREE_PATH)}) `
    + `or AIDEVOPS_TEMP_DIR (${managedTempRoot(env)}). Copy repository files into the worktree; `
    + "put scratch or private artifacts in a new 0700 subdirectory of AIDEVOPS_TEMP_DIR.";
}

function workerFenceActive(env) {
  return isHeadless() && Boolean(env.WORKER_WORKTREE_PATH);
}

function isOutsideWorkerRoots(target, env) {
  const physical = physicalPath(target);
  return !allowedRoots(env).some((root) => pathIsWithin(physical, root));
}

export function assertWorkerWritePaths(paths, env = process.env) {
  if (!workerFenceActive(env)) return;
  for (const target of paths) {
    if (target && isOutsideWorkerRoots(target, env)) {
      throw new Error(fenceMessage("Target", target, env));
    }
  }
}

export function patchTargetPaths(patchText, cwd) {
  const text = typeof patchText === "string" ? patchText : "";
  const paths = [...text.matchAll(/^\*\*\* (?:Update|Delete|Add) File: (.+)$/gm)]
    .map((match) => resolve(cwd, match[1].trim()));
  for (const move of text.matchAll(/^\*\*\* Move to: (.+)$/gm)) paths.push(resolve(cwd, move[1].trim()));
  return paths;
}

function unquote(token) {
  return token.replace(/^(["'])(.*)\1$/, "$2");
}

function segmentGitTarget(tokens, cwd) {
  let dir = cwd;
  let index = 1;
  let verb = "";
  while (index < tokens.length) {
    const token = tokens[index];
    if (GIT_VALUE_OPTIONS.has(token)) {
      if (token === "-C" || token === "--git-dir" || token === "--work-tree") {
        dir = resolve(dir, tokens[index + 1] || "");
      }
      index += 2;
    } else if (/^--(?:git-dir|work-tree)=/.test(token)) {
      dir = resolve(dir, token.split("=").slice(1).join("="));
      index += 1;
    } else if (token.startsWith("-")) {
      index += 1;
    } else {
      verb = token;
      break;
    }
  }
  const rest = tokens.slice(index + 1);
  const mutating = MUTATING_GIT_VERBS.has(verb)
    || (verb === "worktree" && MUTATING_WORKTREE_SUBCOMMANDS.has(rest[0]));
  return { dir, mutating };
}

export function assertWorkerGitTargets(command, cwd, env = process.env) {
  if (!workerFenceActive(env) || typeof command !== "string" || !command) return;
  let current = resolve(cwd || process.cwd());
  for (const segment of command.split(/&&|\|\||[;|\n]/)) {
    const tokens = segment.trim().split(/\s+/).filter(Boolean).map(unquote);
    if (tokens[0] === "cd" && tokens[1]) {
      current = resolve(current, tokens[1]);
    } else if (tokens[0] === "git") {
      const { dir, mutating } = segmentGitTarget(tokens, current);
      if (mutating && isOutsideWorkerRoots(dir, env)) {
        throw new Error(fenceMessage("Git target", dir, env));
      }
    }
  }
}
