// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#36608: a headless worker publishes only its own task branch to its
// dispatched repository. Framework helpers that open cross-repo PRs run as
// scripts and are not parsed here; this fences direct model-issued `git push`
// commands. worker-write-fence.mjs calls it for every parsed push segment.

import { execFileSync } from "child_process";
import { resolveTrustedExecutable } from "../../scripts/trusted-executable.mjs";

const GIT_BINARY = resolveTrustedExecutable("git");

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

// rest: tokens after the `push` verb; dir: resolved git working directory.
export function assertWorkerPushTarget(rest, dir, env) {
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
