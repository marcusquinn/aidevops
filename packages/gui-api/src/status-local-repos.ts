import { existsSync, readdirSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import type { GuiLocalRepoSetupSummary, GuiLocalReposSetupSummary } from "../../gui-shared/src";
import {
  booleanField,
  collapseHome,
  expandHome,
  featureList,
  isRecord,
  readJsonObject,
  readOptionalText,
  safeRealpath,
  stringField,
} from "./status-adapter-utils";

interface RepoCollector {
  excludedWorktrees: number;
  repos: Map<string, GuiLocalRepoSetupSummary>;
}

export function readLocalReposSetupSummary(reposPath: string): GuiLocalReposSetupSummary {
  const registry = readJsonObject(reposPath);
  const registryEntries = extractInitializedRepoEntries(registry.value);
  const parentRefs = extractGitParentDirs(registry.value);
  const parentDirs = parentRefs.map(expandHome).filter((pathName) => existsSync(pathName));
  const collector = createRepoCollector();

  addRegistryRepos(collector, registryEntries);
  addParentRepos(collector, parentDirs, registryEntries);

  return {
    path_ref: parentRefs.join(", ") || "~/Git",
    health: localReposHealth(registry.health, parentDirs, collector.repos.size),
    total: collector.repos.size,
    excluded_worktrees: collector.excludedWorktrees,
    repos: sortedRepoSummaries(collector.repos),
  };
}

function createRepoCollector(): RepoCollector {
  return { excludedWorktrees: 0, repos: new Map<string, GuiLocalRepoSetupSummary>() };
}

function addRegistryRepos(collector: RepoCollector, registryEntries: Record<string, unknown>[]): void {
  for (const entry of registryEntries) {
    const pathRef = stringField(entry, "path");
    if (pathRef !== undefined) {
      addCandidateRepo(collector, expandHome(pathRef), entry);
    }
  }
}

function addParentRepos(
  collector: RepoCollector,
  parentDirs: string[],
  registryEntries: Record<string, unknown>[],
): void {
  for (const parentDir of parentDirs) {
    for (const childPath of listChildDirectories(parentDir)) {
      addCandidateRepo(collector, childPath, matchingRegistryEntry(registryEntries, childPath));
    }
  }
}

function addCandidateRepo(
  collector: RepoCollector,
  pathName: string,
  registryEntry?: Record<string, unknown>,
): void {
  if (!isGitRepoFolder(pathName)) {
    return;
  }
  if (isLinkedWorktree(pathName)) {
    collector.excludedWorktrees += 1;
    return;
  }
  const key = safeRealpath(pathName) ?? pathName;
  if (!collector.repos.has(key)) {
    collector.repos.set(key, localRepoSummaryFromPath(pathName, registryEntry));
  }
}

function localReposHealth(
  registryHealth: "present" | "missing" | "invalid",
  parentDirs: string[],
  repoCount: number,
): GuiLocalReposSetupSummary["health"] {
  if (registryHealth === "invalid") {
    return "invalid";
  }
  return parentDirs.length > 0 || repoCount > 0 ? "present" : "missing";
}

function sortedRepoSummaries(repos: Map<string, GuiLocalRepoSetupSummary>): GuiLocalRepoSetupSummary[] {
  return Array.from(repos.values()).sort((left, right) => left.name.localeCompare(right.name)).slice(0, 80);
}

function localRepoSummaryFromPath(pathName: string, registryEntry?: Record<string, unknown>): GuiLocalRepoSetupSummary {
  const config = readJsonObject(join(pathName, ".aidevops.json")).value;
  const initConfig = isRecord(config) ? config : {};
  const registry = registryEntry ?? {};
  const features = featureList(initConfig.features ?? registryEntry?.features);
  const remotes = readGitRemotes(pathName);

  return {
    name: basename(pathName),
    path_ref: collapseHome(safeRealpath(pathName) ?? pathName),
    aidevops_version: stringField(initConfig, "version") ?? stringField(registry, "version") ?? "not initialized",
    default_branch: readGitDefaultBranch(pathName),
    remotes,
    registered: registryEntry !== undefined,
    pulse: booleanField(registry, "pulse"),
    local_only: booleanField(registry, "local_only") ?? remotes.length === 0,
    init_scope: stringField(initConfig, "init_scope") ?? stringField(registry, "init_scope") ?? "unknown",
    knowledge: stringField(registry, "knowledge") ?? "off",
    priority: stringField(registry, "priority") ?? "default",
    has_interface: booleanField(initConfig, "has_interface") ?? booleanField(registry, "has_interface"),
    features,
    settings_policy: "read_only_no_writes",
  };
}

function extractInitializedRepoEntries(value: unknown): Record<string, unknown>[] {
  if (!isRecord(value) || !Array.isArray(value.initialized_repos)) {
    return [];
  }
  return value.initialized_repos.filter(isRecord);
}

function extractGitParentDirs(value: unknown): string[] {
  if (!isRecord(value) || !Array.isArray(value.git_parent_dirs)) {
    return ["~/Git"];
  }
  const dirs = value.git_parent_dirs.filter((entry): entry is string => typeof entry === "string" && entry.length > 0);
  return dirs.length > 0 ? dirs : ["~/Git"];
}

function listChildDirectories(parentDir: string): string[] {
  try {
    return readdirSync(parentDir)
      .map((name) => join(parentDir, name))
      .filter((pathName) => {
        try {
          return statSync(pathName).isDirectory();
        } catch {
          return false;
        }
      });
  } catch {
    return [];
  }
}

function isGitRepoFolder(pathName: string): boolean {
  try {
    if (!statSync(pathName).isDirectory()) {
      return false;
    }
    const gitMarker = statSync(join(pathName, ".git"));
    return gitMarker.isDirectory() || gitMarker.isFile();
  } catch {
    return false;
  }
}

function isLinkedWorktree(pathName: string): boolean {
  try {
    return statSync(join(pathName, ".git")).isFile();
  } catch {
    return false;
  }
}

function matchingRegistryEntry(entries: Record<string, unknown>[], pathName: string): Record<string, unknown> | undefined {
  return entries.find((entry) => {
    const entryPath = stringField(entry, "path");
    return entryPath !== undefined && pathsMatch(expandHome(entryPath), pathName);
  });
}

function pathsMatch(left: string, right: string): boolean {
  return (safeRealpath(left) ?? left) === (safeRealpath(right) ?? right);
}

function readGitDefaultBranch(pathName: string): string {
  const remoteHead = readOptionalText(join(pathName, ".git/refs/remotes/origin/HEAD"));
  const remoteBranch = branchNameFromRef(remoteHead, "refs/remotes/origin/");
  if (remoteBranch !== null) {
    return remoteBranch;
  }

  const localHead = readOptionalText(join(pathName, ".git/HEAD"));
  return branchNameFromRef(localHead, "refs/heads/") ?? "unknown";
}

function readGitRemotes(pathName: string): GuiLocalRepoSetupSummary["remotes"] {
  const config = readOptionalText(join(pathName, ".git/config"));
  if (config === null) {
    return [];
  }

  const remotes: GuiLocalRepoSetupSummary["remotes"] = [];
  let currentRemote = "";
  for (const line of config.split("\n")) {
    const section = line.match(/^\s*\[remote\s+"([^"]+)"\]\s*$/);
    if (section !== null) {
      currentRemote = section[1];
      continue;
    }
    if (line.match(/^\s*\[/) !== null) {
      currentRemote = "";
      continue;
    }
    const url = line.match(/^\s*url\s*=\s*(.+)\s*$/);
    if (url !== null && currentRemote.length > 0) {
      remotes.push({ name: currentRemote, url_ref: sanitizeRemoteUrl(url[1]) });
    }
  }
  return remotes;
}

function branchNameFromRef(value: string | null, prefix: string): string | null {
  if (value === null || !value.startsWith("ref: ")) {
    return null;
  }
  const ref = value.slice(5).trim();
  return ref.startsWith(prefix) ? ref.slice(prefix.length) : null;
}

function sanitizeRemoteUrl(value: string): string {
  try {
    const parsed = new URL(value);
    parsed.username = "";
    parsed.password = "";
    return parsed.toString().replace(/\/$/, "");
  } catch {
    return value.replace(/(https?:\/\/)[^/@\s]+@/i, "$1");
  }
}
