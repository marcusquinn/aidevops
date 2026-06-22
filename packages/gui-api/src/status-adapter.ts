import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { hostname, networkInterfaces, userInfo } from "node:os";
import { basename, join } from "node:path";
import {
  assertNoSecretSentinels,
  createEnvelope,
  type GuiAiAppSummary,
  type GuiAiProviderId,
  type GuiLocalRepoSetupSummary,
  type GuiLocalReposSetupSummary,
  type GuiOAuthPoolSummary,
  type GuiOAuthProviderSummary,
  type GuiRepoRegistrySummary,
  type GuiRepoSummary,
  type GuiResponseEnvelope,
  type GuiSettingsSummary,
  type GuiSetupTargetSummary,
  type GuiStatusData,
  statusFixture,
} from "../../gui-shared/src";

export interface StatusAdapterOptions {
  repoRoot?: string;
  observedAt?: string;
}

export const STATUS_ADAPTER_COMMAND = ["aidevops", "status"] as const;

export function readStatus(
  options: StatusAdapterOptions = {},
): GuiResponseEnvelope<GuiStatusData> {
  const repoRoot = options.repoRoot ?? process.cwd();
  const versionPath = join(repoRoot, "VERSION");
  const settingsPathRef = "~/.config/aidevops/settings.json";
  const reposPathRef = "~/.config/aidevops/repos.json";
  const oauthPoolPathRef = "~/.aidevops/oauth-pool.json";
  const agentsPathRef = "~/.aidevops/agents";
  const settingsPath = expandHome(settingsPathRef);
  const reposPath = expandHome(reposPathRef);
  const oauthPoolPath = expandHome(oauthPoolPathRef);
  const aidevopsVersion = existsSync(versionPath)
    ? readFileSync(versionPath, "utf8").trim()
    : statusFixture.aidevops_version;
  const installedVersion = readOptionalText(expandHome("~/.aidevops/agents/VERSION")) ?? aidevopsVersion;
  const restartRequired = installedVersion !== aidevopsVersion;
  const setupTargets = readSetupTargets(aidevopsVersion || "unknown", installedVersion || "unknown");
  const aiApps = readAiApps(aidevopsVersion || "unknown", installedVersion || "unknown");
  const sourcePathRefs = [
    agentsPathRef,
    settingsPathRef,
    reposPathRef,
    oauthPoolPathRef,
    "VERSION",
    ...setupTargets.map((target) => target.path_ref),
    ...aiApps.flatMap((app) => [app.app_path_ref, app.binary_path_ref, app.config_path_ref, app.aidevops_target_path_ref]),
  ].filter(isSourcePathRef);

  const data: GuiStatusData = {
    ...statusFixture,
    aidevops_version: aidevopsVersion || "unknown",
    update: {
      running_version: aidevopsVersion || "unknown",
      installed_version: installedVersion || "unknown",
      restart_required: restartRequired,
      message: restartRequired
        ? "aidevops has updated in the background. Restart the GUI app to use the latest installed version."
        : "The GUI app is using the latest installed aidevops version.",
    },
    machine: readMachineSummary(),
    paths: [
      {
        label: "deployed agents",
        path_ref: agentsPathRef,
        health: existsSync(expandHome("~/.aidevops/agents")) ? "present" : "missing",
      },
      {
        label: "settings",
        path_ref: settingsPathRef,
        health: existsSync(settingsPath)
          ? "present"
          : "missing",
      },
      {
        label: "repo registry",
        path_ref: reposPathRef,
        health: existsSync(reposPath) ? "present" : "missing",
      },
    ],
    helper_availability: [
      {
        name: STATUS_ADAPTER_COMMAND.join(" "),
        status: "unchecked",
      },
    ],
    settings: readSettingsSummary(settingsPath, settingsPathRef),
    repos: readRepoRegistrySummary(reposPath, reposPathRef),
    local_repos: readLocalReposSetupSummary(reposPath),
    oauth_pool: readOAuthPoolSummary(oauthPoolPath, oauthPoolPathRef),
    setup_targets: setupTargets,
    ai_apps: aiApps,
  };

  const envelope = createEnvelope({
    operation_id: "setup.status.read",
    source: {
      surface: "setup",
      authority: "aidevops helpers",
      path_refs: sourcePathRefs,
    },
    data,
    warnings: ["Helper execution is deferred; scaffold reports local path health only."],
    observed_at: options.observedAt,
  });

  assertNoSecretSentinels(envelope);
  return envelope;
}

const AI_PROVIDER_IDS: GuiAiProviderId[] = ["anthropic", "openai", "cursor", "google"];

const SETUP_TARGET_DEFINITIONS: Array<Pick<GuiSetupTargetSummary, "label" | "path_ref" | "purpose">> = [
  {
    label: "Deployed agents",
    path_ref: "~/.aidevops/agents/VERSION",
    purpose: "Canonical aidevops agent, workflow, script, and reference bundle.",
  },
  {
    label: "OpenCode prompt",
    path_ref: "~/.config/opencode/AGENTS.md",
    purpose: "OpenCode system prompt pointer into the deployed aidevops guide.",
  },
  {
    label: "OpenCode config",
    path_ref: "~/.config/opencode/opencode.json",
    purpose: "OpenCode agents, commands, MCPs, and prompt configuration.",
  },
  {
    label: "Claude Code prompt",
    path_ref: "~/.config/Claude/AGENTS.md",
    purpose: "Claude Code global instructions pointer into the deployed aidevops guide.",
  },
  {
    label: "Claude commands",
    path_ref: "~/.claude/commands",
    purpose: "Claude Code slash commands generated by aidevops.",
  },
  {
    label: "Codex instructions",
    path_ref: "~/.codex/instructions.md",
    purpose: "Codex global instructions generated by aidevops.",
  },
  {
    label: "Cursor MCP config",
    path_ref: "~/.cursor/mcp.json",
    purpose: "Cursor MCP server configuration managed by aidevops.",
  },
];

interface AiAppDefinition {
  name: string;
  binary: string;
  app_path_refs: string[];
  config_path_ref: string;
  aidevops_target_path_ref: string;
  version_args: string[];
}

const AI_APP_DEFINITIONS: AiAppDefinition[] = [
  {
    name: "OpenCode",
    binary: "opencode",
    app_path_refs: ["~/Applications/OpenCode AIDevOps.app", "/Applications/OpenCode.app", "~/Applications/OpenCode.app"],
    config_path_ref: "~/.config/opencode/opencode.json",
    aidevops_target_path_ref: "~/.config/opencode/AGENTS.md",
    version_args: ["--version"],
  },
  {
    name: "Claude Code",
    binary: "claude",
    app_path_refs: ["/Applications/Claude.app", "~/Applications/Claude.app"],
    config_path_ref: "~/.config/Claude/claude_desktop_config.json",
    aidevops_target_path_ref: "~/.config/Claude/AGENTS.md",
    version_args: ["--version"],
  },
  {
    name: "Codex CLI",
    binary: "codex",
    app_path_refs: [],
    config_path_ref: "~/.codex/config.toml",
    aidevops_target_path_ref: "~/.codex/instructions.md",
    version_args: ["--version"],
  },
  {
    name: "Cursor",
    binary: "cursor",
    app_path_refs: ["/Applications/Cursor.app", "~/Applications/Cursor.app"],
    config_path_ref: "~/.cursor/mcp.json",
    aidevops_target_path_ref: "~/.cursor/rules",
    version_args: [],
  },
];

function readMachineSummary(): GuiStatusData["machine"] {
  const username = userInfo().username || "local";
  const displayName = readAccountDisplayName() ?? username;
  const host = hostname() || "localhost";
  const localIps = Object.values(networkInterfaces())
    .flatMap((entries) => entries ?? [])
    .filter((entry) => entry.family === "IPv4" && !entry.internal)
    .map((entry) => entry.address)
    .sort();

  return {
    id: "local",
    label: host,
    initials: initialsFromUsername(displayName),
    username: displayName,
    hostname: host,
    local_ips: localIps.length > 0 ? localIps : ["127.0.0.1"],
    public_ip: null,
  };
}

function readAccountDisplayName(): string | null {
  try {
    const displayName = execFileSync("id", ["-F"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    return displayName.length > 0 ? displayName : null;
  } catch {
    return null;
  }
}

function initialsFromUsername(username: string): string {
  const parts = username.split(/[^a-z0-9]+/i).filter(Boolean);
  if (parts.length >= 2) {
    return `${parts[0][0]}${parts[1][0]}`.toUpperCase();
  }

  const letters = username.replace(/[^a-z0-9]/gi, "").slice(0, 2);
  return (letters || "LM").toUpperCase();
}

function readSettingsSummary(pathName: string, pathRef: string): GuiSettingsSummary {
  if (!existsSync(pathName)) {
    return {
      ...statusFixture.settings,
      path_ref: pathRef,
      health: "missing",
    };
  }

  try {
    const parsed = JSON.parse(readFileSync(pathName, "utf8")) as Record<string, unknown>;
    const keys = Object.keys(parsed).sort();
    return {
      path_ref: pathRef,
      health: "present",
      key_count: keys.length,
      keys,
      value_policy: "keys_only_no_values",
    };
  } catch {
    return {
      ...statusFixture.settings,
      path_ref: pathRef,
      health: "invalid",
    };
  }
}

function readRepoRegistrySummary(pathName: string, pathRef: string): GuiRepoRegistrySummary {
  if (!existsSync(pathName)) {
    return {
      ...statusFixture.repos,
      path_ref: pathRef,
      health: "missing",
    };
  }

  try {
    const parsed = JSON.parse(readFileSync(pathName, "utf8")) as unknown;
    const repos = extractRepoSummaries(parsed).slice(0, 12);
    return {
      path_ref: pathRef,
      health: "present",
      total: extractRepoSummaries(parsed).length,
      repos,
    };
  } catch {
    return {
      ...statusFixture.repos,
      path_ref: pathRef,
      health: "invalid",
    };
  }
}

function readLocalReposSetupSummary(reposPath: string): GuiLocalReposSetupSummary {
  const registry = readJsonObject(reposPath);
  const registryEntries = extractInitializedRepoEntries(registry.value);
  const parentRefs = extractGitParentDirs(registry.value);
  const parentDirs = parentRefs.map(expandHome).filter((pathName) => existsSync(pathName));
  const repos = new Map<string, GuiLocalRepoSetupSummary>();
  let excludedWorktrees = 0;

  for (const entry of registryEntries) {
    const pathRef = stringField(entry, "path");
    if (pathRef === undefined) {
      continue;
    }
    const pathName = expandHome(pathRef);
    if (!isGitRepoFolder(pathName)) {
      continue;
    }
    if (isLinkedWorktree(pathName)) {
      excludedWorktrees += 1;
      continue;
    }
    const key = safeRealpath(pathName) ?? pathName;
    repos.set(key, localRepoSummaryFromPath(pathName, entry));
  }

  for (const parentDir of parentDirs) {
    for (const childPath of listChildDirectories(parentDir)) {
      if (!isGitRepoFolder(childPath)) {
        continue;
      }
      if (isLinkedWorktree(childPath)) {
        excludedWorktrees += 1;
        continue;
      }
      const key = safeRealpath(childPath) ?? childPath;
      if (!repos.has(key)) {
        repos.set(key, localRepoSummaryFromPath(childPath, matchingRegistryEntry(registryEntries, childPath)));
      }
    }
  }

  const health = registry.health === "invalid"
    ? "invalid"
    : parentDirs.length > 0 || repos.size > 0
      ? "present"
      : "missing";

  return {
    path_ref: parentRefs.join(", ") || "~/Git",
    health,
    total: repos.size,
    excluded_worktrees: excludedWorktrees,
    repos: Array.from(repos.values()).sort((left, right) => left.name.localeCompare(right.name)).slice(0, 80),
  };
}

function readOAuthPoolSummary(pathName: string, pathRef: string): GuiOAuthPoolSummary {
  const parsed = readJsonObject(pathName);
  if (parsed.health === "missing") {
    return {
      ...statusFixture.oauth_pool,
      path_ref: pathRef,
      health: "missing",
    };
  }
  if (parsed.health === "invalid") {
    return {
      ...statusFixture.oauth_pool,
      path_ref: pathRef,
      health: "invalid",
    };
  }

  const pool = parsed.value;
  return {
    path_ref: pathRef,
    health: "present",
    value_policy: "metadata_only_no_tokens",
    providers: AI_PROVIDER_IDS.map((provider) => oauthProviderSummary(pool, provider)),
  };
}

function readSetupTargets(latestVersion: string, installedVersion: string): GuiSetupTargetSummary[] {
  return SETUP_TARGET_DEFINITIONS.map((target) => {
    const health = existsSync(expandHome(target.path_ref)) ? "present" : "missing";
    const targetVersion = health === "present" ? installedVersion : "not installed";

    return {
      ...target,
      health,
      installed_version: targetVersion,
      latest_version: latestVersion,
      needs_update: targetVersion !== latestVersion,
    };
  });
}

function readAiApps(latestVersion: string, installedVersion: string): GuiAiAppSummary[] {
  return AI_APP_DEFINITIONS.map((definition) => aiAppSummary(definition, latestVersion, installedVersion));
}

function aiAppSummary(definition: AiAppDefinition, latestVersion: string, installedVersion: string): GuiAiAppSummary {
  const binaryPath = resolveBinary(definition.binary);
  const appPathRef = firstExistingPathRef(definition.app_path_refs) ?? definition.app_path_refs[0] ?? "not applicable";
  const hasApp = definition.app_path_refs.some((pathRef) => existsSync(expandHome(pathRef)));
  const hasConfig = existsSync(expandHome(definition.config_path_ref));
  const hasAidevopsTarget = existsSync(expandHome(definition.aidevops_target_path_ref));
  const aidevopsTargetVersion = hasAidevopsTarget ? installedVersion : "not installed";

  return {
    name: definition.name,
    status: binaryPath !== null || hasApp || hasConfig ? "found" : "missing",
    app_path_ref: appPathRef,
    binary_path_ref: binaryPath === null ? "not found" : collapseHome(binaryPath),
    config_path_ref: definition.config_path_ref,
    aidevops_target_path_ref: definition.aidevops_target_path_ref,
    app_version: binaryPath === null ? "unknown" : readBinaryVersion(binaryPath, definition.version_args),
    aidevops_version: aidevopsTargetVersion,
    latest_version: latestVersion,
    needs_update: aidevopsTargetVersion !== latestVersion,
  };
}

function firstExistingPathRef(pathRefs: string[]): string | null {
  return pathRefs.find((pathRef) => existsSync(expandHome(pathRef))) ?? null;
}

function resolveBinary(binary: string): string | null {
  try {
    const output = execFileSync("/usr/bin/which", [binary], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 1_000,
    }).trim();
    return output.split("\n").find((line) => line.length > 0) ?? null;
  } catch {
    return null;
  }
}

function readBinaryVersion(binaryPath: string, args: string[]): string {
  if (args.length === 0) {
    return "unknown";
  }

  try {
    const output = execFileSync(binaryPath, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 1_500,
    }).trim();
    return output.split("\n").find((line) => line.length > 0) ?? "unknown";
  } catch {
    return "unknown";
  }
}

function isSourcePathRef(pathRef: string): boolean {
  return pathRef === "VERSION" || pathRef.startsWith("~/") || pathRef.startsWith("/");
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

function oauthProviderSummary(pool: Record<string, unknown>, provider: GuiAiProviderId): GuiOAuthProviderSummary {
  const accounts = Array.isArray(pool[provider]) ? pool[provider].filter(isRecord) : [];
  const now = Date.now();
  const accountSummaries = accounts.map((account) => oauthAccountSummary(account));

  return {
    provider,
    configured: accountSummaries.length > 0,
    total: accountSummaries.length,
    available: accountSummaries.filter((account) => cooldownReady(account.cooldown_until, now)).length,
    active_or_idle: accountSummaries.filter((account) => account.status === "active" || account.status === "idle").length,
    rate_limited: accountSummaries.filter((account) => account.status === "rate-limited" && !cooldownReady(account.cooldown_until, now)).length,
    auth_errors: accountSummaries.filter((account) => account.status === "auth-error").length,
    pending_token: isRecord(pool[`_pending_${provider}`]),
    accounts: accountSummaries,
  };
}

function oauthAccountSummary(account: Record<string, unknown>): GuiOAuthProviderSummary["accounts"][number] {
  return {
    email_ref: stringField(account, "email") ?? "unknown",
    status: stringField(account, "status") ?? "unknown",
    priority: numberField(account, "priority"),
    last_used: stringField(account, "lastUsed") ?? stringField(account, "added") ?? "unknown",
    expires_at: formatEpochField(account.expires),
    cooldown_until: formatNullableEpochField(account.cooldownUntil),
  };
}

function extractRepoSummaries(value: unknown): GuiRepoSummary[] {
  if (Array.isArray(value)) {
    return value.map((entry, index) => repoSummaryFromUnknown(entry, `repo-${index + 1}`));
  }
  if (isRecord(value) && Array.isArray(value.initialized_repos)) {
    return value.initialized_repos.map((entry, index) => repoSummaryFromUnknown(entry, `repo-${index + 1}`));
  }
  if (isRecord(value) && Array.isArray(value.repos)) {
    return value.repos.map((entry, index) => repoSummaryFromUnknown(entry, `repo-${index + 1}`));
  }
  if (isRecord(value)) {
    return Object.entries(value)
      .filter(([, entry]) => isRecord(entry))
      .map(([name, entry]) => repoSummaryFromUnknown(entry, name));
  }

  return [];
}

function repoSummaryFromUnknown(value: unknown, fallbackName: string): GuiRepoSummary {
  if (!isRecord(value)) {
    return {
      name: fallbackName,
      platform: "unknown",
      slug: fallbackName,
      local_path_status: "not_provided",
    };
  }

  const name = stringField(value, "name") ?? stringField(value, "slug") ?? fallbackName;
  const slug = stringField(value, "slug") ?? stringField(value, "repo") ?? name;
  const platform = stringField(value, "platform") ?? stringField(value, "provider") ?? "unknown";
  const localPath = stringField(value, "path") ?? stringField(value, "local_path");

  return {
    name,
    platform,
    slug,
    local_path_status: localPath === undefined ? "not_provided" : existsSync(expandHome(localPath)) ? "present" : "missing",
  };
}

function readJsonObject(pathName: string): { health: "present" | "missing" | "invalid"; value: Record<string, unknown> } {
  if (!existsSync(pathName)) {
    return { health: "missing", value: {} };
  }

  try {
    const parsed = JSON.parse(readFileSync(pathName, "utf8"));
    return isRecord(parsed) ? { health: "present", value: parsed } : { health: "invalid", value: {} };
  } catch {
    return { health: "invalid", value: {} };
  }
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
    return readdirSync(parentDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => join(parentDir, entry.name));
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

function safeRealpath(pathName: string): string | null {
  try {
    return realpathSync(pathName);
  } catch {
    return null;
  }
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

function collapseHome(pathName: string): string {
  const home = process.env.HOME ?? "";
  if (home.length > 0 && pathName === home) {
    return "~";
  }
  if (home.length > 0 && pathName.startsWith(`${home}/`)) {
    return `~/${pathName.slice(home.length + 1)}`;
  }
  return pathName;
}

function booleanField(value: Record<string, unknown>, key: string): boolean | null {
  const field = value[key];
  return typeof field === "boolean" ? field : null;
}

function numberField(value: Record<string, unknown>, key: string): number | null {
  const field = value[key];
  return typeof field === "number" && Number.isFinite(field) ? field : null;
}

function featureList(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.filter((entry): entry is string => typeof entry === "string" && entry.length > 0).sort();
  }
  if (typeof value === "string" && value.length > 0) {
    return value.split(",").map((entry) => entry.trim()).filter(Boolean).sort();
  }
  if (isRecord(value)) {
    return Object.entries(value)
      .filter(([, enabled]) => enabled === true)
      .map(([feature]) => feature)
      .sort();
  }
  return [];
}

function formatNullableEpochField(value: unknown): string | null {
  if (value === null || value === undefined || value === 0) {
    return null;
  }
  return formatEpochField(value);
}

function formatEpochField(value: unknown): string {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    return "unknown";
  }
  const millis = value > 9_999_999_999 ? value : value * 1000;
  return new Date(millis).toISOString();
}

function cooldownReady(cooldownUntil: string | null, now: number): boolean {
  if (cooldownUntil === null) {
    return true;
  }
  const parsed = Date.parse(cooldownUntil);
  return Number.isNaN(parsed) || parsed <= now;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringField(value: Record<string, unknown>, key: string): string | undefined {
  const field = value[key];
  return typeof field === "string" && field.length > 0 ? field : undefined;
}

function expandHome(pathRef: string): string {
  if (!pathRef.startsWith("~/")) {
    return pathRef;
  }

  return join(process.env.HOME ?? "", pathRef.slice(2));
}

function readOptionalText(pathName: string): string | null {
  if (!existsSync(pathName)) {
    return null;
  }

  return readFileSync(pathName, "utf8").trim();
}
