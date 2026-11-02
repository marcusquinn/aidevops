// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// The owner/repo layout migration moved `<parent>/<name>` to
// `<parent>/<name>/<name>`. Sessions live during the move keep the old
// directory string and re-record it, so Tabby recovery would relaunch them in
// the non-repository owner directory forever (GH#36438). Relocate only that
// exact shape, and only into a repos.json-registered repository.

import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

export function defaultReposFile() {
  return process.env.AIDEVOPS_REPOS_JSON || join(homedir(), ".config", "aidevops", "repos.json");
}

function insideGitWorkTree(directory) {
  for (let current = directory; ; current = dirname(current)) {
    if (existsSync(join(current, ".git"))) return true;
    if (dirname(current) === current) return false;
  }
}

function canonicalOrEmpty(path) {
  try {
    return realpathSync(path.replace(/^~(?=\/|$)/, homedir()));
  } catch {
    return "";
  }
}

function isRegisteredRepository(canonicalPath, reposFile) {
  let config;
  try {
    config = JSON.parse(readFileSync(reposFile, "utf8"));
  } catch {
    return false;
  }
  const entries = Array.isArray(config?.initialized_repos) ? config.initialized_repos : [];
  return entries.some((entry) => typeof entry?.path === "string" && canonicalOrEmpty(entry.path) === canonicalPath);
}

// Returns the registered repository that replaced a stale pre-migration
// directory, or the canonical directory unchanged.
export function relocatedSessionDirectory(canonicalDirectory, reposFile = defaultReposFile()) {
  if (insideGitWorkTree(canonicalDirectory)) return canonicalDirectory;
  const candidate = join(canonicalDirectory, basename(canonicalDirectory));
  if (candidate === canonicalDirectory || !existsSync(join(candidate, ".git"))) return canonicalDirectory;
  const canonicalCandidate = canonicalOrEmpty(candidate);
  if (!canonicalCandidate || !isRegisteredRepository(canonicalCandidate, reposFile)) return canonicalDirectory;
  return canonicalCandidate;
}
