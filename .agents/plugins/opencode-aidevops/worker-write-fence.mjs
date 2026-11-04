// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Headless workers read widely but write only inside their own worktree and
// managed temp. Sibling worktrees are read-only (GH#35139).

import { execFileSync } from "child_process";
import { realpathSync } from "fs";
import { homedir } from "os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "path";
import { resolveTrustedExecutable } from "../../scripts/trusted-executable.mjs";
import { isHeadless } from "./proxy-lifecycle.mjs";

const GIT_BINARY = resolveTrustedExecutable("git");

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
  return { dir, mutating, verb, rest };
}

// GH#36608: a worker publishes only its own task branch to its dispatched
// repository. Framework helpers that open cross-repo PRs run as scripts and
// are not parsed here; this fences direct model-issued `git push` commands.
export const WORKER_PUSH_MESSAGE = "BLOCKED: Workers push only their task branch to their own repository.";
const PROTECTED_PUSH_BRANCHES = new Set(["main", "master"]);
const PUSH_VALUE_OPTIONS = new Set(["-o", "--push-option", "--receive-pack", "--exec"]);
const WHOLE_REPO_PUSH_OPTIONS = new Set(["--all", "--mirror", "--branches"]);

function pushMessage(detail, env) {
  return `${WORKER_PUSH_MESSAGE} ${detail} Push the current task branch to origin`
    + `${env.WORKER_REPO_SLUG ? ` (${env.WORKER_REPO_SLUG})` : ""} and open a PR there. `
    + "If the fix belongs in another repository, stop and report it as a blocker with the "
    + "target repository and proposed change instead of cloning, copying or pushing there.";
}

function normalizeSlug(value) {
  return String(value || "").toLowerCase().replace(/\.git$/, "").replace(/\/+$/, "");
}

// Extract owner/repo from https, ssh or scp-style remote URLs.
function remoteUrlSlug(url) {
  const match = String(url || "").trim()
    .match(/^(?:[a-z+]+:\/\/(?:[^@/]+@)?[^/]+\/|[^@\s]+@[^:\s]+:)([^/\s]+\/[^/\s]+?)(?:\.git)?\/?$/i);
  return match ? normalizeSlug(match[1]) : "";
}

function isRemoteUrl(remote) {
  return /^[a-z+]+:\/\//i.test(remote) || /^[^@\s/]+@[^:\s]+:/.test(remote)
    || remote.startsWith("/") || remote.startsWith(".");
}

function readGit(dir, args) {
  try {
    return execFileSync(GIT_BINARY, ["-C", dir, ...args], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 5000,
    }).trim();
  } catch {
    return "";
  }
}

function parsePushArgs(rest) {
  const positional = [];
  let remote = "";
  let wholeRepo = false;
  for (let index = 0; index < rest.length; index += 1) {
    const arg = rest[index];
    if (arg === "--") {
      positional.push(...rest.slice(index + 1));
      break;
    }
    if (WHOLE_REPO_PUSH_OPTIONS.has(arg)) wholeRepo = true;
    else if (arg === "--repo") remote = rest[++index] || "";
    else if (arg.startsWith("--repo=")) remote = arg.slice("--repo=".length);
    else if (PUSH_VALUE_OPTIONS.has(arg)) index += 1;
    else if (!arg.startsWith("-")) positional.push(arg);
  }
  if (!remote && positional.length) remote = positional.shift();
  return { remote, refspecs: positional, wholeRepo };
}

function destinationBranch(refspec) {
  const spec = refspec.replace(/^\+/, "");
  const destination = spec.includes(":") ? spec.slice(spec.lastIndexOf(":") + 1) : spec;
  return destination.replace(/^refs\/heads\//, "");
}

// Classify the push remote: the dispatched repository, a same-name fork used
// by the external-contribution flow (workflows/pr.md), or a foreign repository.
function classifyPushRemote(remote, dir, env) {
  const expected = normalizeSlug(env.WORKER_REPO_SLUG);
  const name = remote || "origin";
  const url = isRemoteUrl(name) ? name : readGit(dir, ["remote", "get-url", "--push", name]);
  if (!url) return { kind: name === "origin" ? "own" : "foreign", label: name };
  if (!expected) return { kind: name === "origin" ? "own" : "unverified", label: url };
  const actual = remoteUrlSlug(url);
  if (actual === expected) return { kind: "own", label: actual };
  const sameName = actual && actual.split("/")[1] === expected.split("/")[1];
  return { kind: sameName ? "fork" : "foreign", label: actual || url };
}

function assertWorkerPushTarget(rest, dir, env) {
  const { remote, refspecs, wholeRepo } = parsePushArgs(rest);
  if (wholeRepo) throw new Error(pushMessage("--all/--mirror/--branches pushes are not allowed.", env));
  const target = classifyPushRemote(remote, dir, env);
  if (target.kind === "foreign") {
    throw new Error(pushMessage(
      `Remote '${remote || "origin"}' targets ${target.label}, not ${env.WORKER_REPO_SLUG || "the worker repository"}.`, env,
    ));
  }
  if (target.kind !== "own") return;
  const defaultBranch = readGit(dir, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
    .replace(/^origin\//, "");
  for (const refspec of refspecs) {
    const branch = destinationBranch(refspec);
    if (PROTECTED_PUSH_BRANCHES.has(branch) || (defaultBranch && branch === defaultBranch)) {
      throw new Error(pushMessage(`Destination branch '${branch}' is a default branch.`, env));
    }
  }
}

export function assertWorkerGitTargets(command, cwd, env = process.env) {
  if (!workerFenceActive(env) || typeof command !== "string" || !command) return;
  let current = resolve(cwd || process.cwd());
  for (const segment of command.split(/&&|\|\||[;|\n]/)) {
    const tokens = segment.trim().split(/\s+/).filter(Boolean).map(unquote);
    if (tokens[0] === "cd" && tokens[1]) {
      current = resolve(current, tokens[1]);
    } else if (tokens[0] === "git") {
      const { dir, mutating, verb, rest } = segmentGitTarget(tokens, current);
      if (mutating && isOutsideWorkerRoots(dir, env)) {
        throw new Error(fenceMessage("Git target", dir, env));
      }
      if (verb === "push") assertWorkerPushTarget(rest, dir, env);
    }
  }
}
