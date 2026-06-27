import { Database } from "bun:sqlite";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { hostname, networkInterfaces, userInfo } from "node:os";
import { join } from "node:path";
import {
  assertNoSecretSentinels,
  createEnvelope,
  type GuiAiAppSummary,
  type GuiAiProviderId,
  type GuiLocalRepoSetupSummary,
  type GuiManagedAppSummary,
  type GuiOAuthPoolSummary,
  type GuiOAuthProviderSummary,
  type GuiOpenCodeSessionRegistrySummary,
  type GuiOpenCodeSessionSummary,
  type GuiRepoRegistrySummary,
  type GuiRepoSummary,
  type GuiResponseEnvelope,
  type GuiSettingsSummary,
  type GuiSetupTargetSummary,
  type GuiStatusData,
  type GuiVaultStatusData,
  statusFixture,
  VAULT_STATUS_ROUTE_MANIFEST,
} from "../../gui-shared/src";
import {
  collapseHome,
  cooldownReady,
  expandHome,
  formatEpochField,
  formatNullableEpochField,
  isRecord,
  numberField,
  readJsonObject,
  readOptionalText,
  stringField,
} from "./status-adapter-utils";
import { readLocalReposSetupSummary } from "./status-local-repos";
import { readVaultSummary } from "./status-vault";

export { readVaultSummary } from "./status-vault";

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
  const opencodeDbPathRef = "~/.local/share/opencode/opencode.db";
  const agentsPathRef = "~/.aidevops/agents";
  const vaultPathRef = statusFixture.vault.path_ref;
  const settingsPath = expandHome(settingsPathRef);
  const reposPath = expandHome(reposPathRef);
  const oauthPoolPath = expandHome(oauthPoolPathRef);
  const opencodeDbPath = expandHome(opencodeDbPathRef);
  const aidevopsVersion = existsSync(versionPath)
    ? readFileSync(versionPath, "utf8").trim()
    : statusFixture.aidevops_version;
  const installedVersion = readOptionalText(expandHome("~/.aidevops/agents/VERSION")) ?? aidevopsVersion;
  const restartRequired = installedVersion !== aidevopsVersion;
  const setupTargets = readSetupTargets(aidevopsVersion || "unknown", installedVersion || "unknown");
  const aiApps = readAiApps(aidevopsVersion || "unknown", installedVersion || "unknown");
  const managedApps = readManagedApps(aidevopsVersion || "unknown", installedVersion || "unknown");
  const localRepos = readLocalReposSetupSummary(reposPath);
  const opencodeSessions = readOpenCodeSessions(opencodeDbPath, opencodeDbPathRef, localRepos.repos);
  const vault = readVaultSummary(repoRoot);
  const sourcePathRefs = [
    agentsPathRef,
    settingsPathRef,
    reposPathRef,
    oauthPoolPathRef,
    opencodeDbPathRef,
    vaultPathRef,
    "VERSION",
    ...setupTargets.map((target) => target.path_ref),
    ...aiApps.flatMap((app) => [app.app_path_ref, app.binary_path_ref, app.config_path_ref, app.aidevops_target_path_ref]),
    ...managedApps.map((app) => app.install_path_ref),
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
    local_repos: localRepos,
    opencode_sessions: opencodeSessions,
    oauth_pool: readOAuthPoolSummary(oauthPoolPath, oauthPoolPathRef),
    setup_targets: setupTargets,
    ai_apps: aiApps,
    managed_apps: managedApps,
    vault,
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

export function readVaultStatus(
  options: StatusAdapterOptions = {},
): GuiResponseEnvelope<GuiVaultStatusData> {
  const data = readVaultSummary(options.repoRoot ?? process.cwd());
  const envelope = createEnvelope({
    operation_id: VAULT_STATUS_ROUTE_MANIFEST.operation_id,
    source: {
      surface: "vault",
      authority: "aidevops vault helper",
      path_refs: [data.path_ref],
    },
    data,
    warnings: ["Vault status exposes metadata only; passphrases, keys, recovery material, and payloads are never returned."],
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

interface ManagedAppDefinition {
  id: string;
  name: string;
  description: string;
  category: string;
  binary: string | null;
  version_args: string[];
  install_path_refs: string[];
  origin_website_url: string;
  origin_repo_url: string;
  aidevops_install: boolean;
  aidevops_update: boolean;
  latest_version_source: "aidevops" | "binary" | "unknown";
  action_commands: Partial<Record<"install" | "update" | "reinstall" | "remove", string>>;
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

const MANAGED_APP_DEFINITIONS: ManagedAppDefinition[] = [
  managedApp("aidevops", "aidevops", "Framework CLI, agents, workflows, scripts, and local GUI assets.", "core", "aidevops", ["--version"], ["~/.aidevops/agents", "/opt/homebrew/bin/aidevops", "/usr/local/bin/aidevops"], "https://aidevops.sh", "https://github.com/marcusquinn/aidevops.git", true, true, "aidevops", { install: "./setup.sh --non-interactive", update: "aidevops update", reinstall: "./setup.sh --non-interactive" }),
  managedApp("agents", "Deployed agents", "Canonical aidevops agents, commands, workflows, scripts, and reference files.", "core", null, [], ["~/.aidevops/agents/VERSION"], "https://aidevops.sh", "https://github.com/marcusquinn/aidevops.git", true, true, "aidevops", { install: "aidevops setup --scope agents", update: "aidevops setup --scope agents", reinstall: "aidevops setup --scope agents" }),
  managedApp("gui-desktop", "aidevops.app", "Native macOS desktop launcher for the local GUI.", "desktop", null, [], ["~/Applications/aidevops.app", "/Applications/aidevops.app"], "https://aidevops.sh", "https://github.com/marcusquinn/aidevops.git", true, true, "aidevops", { install: "aidevops setup --scope gui-desktop", update: "aidevops setup --scope gui-desktop", reinstall: "aidevops setup --scope gui-desktop" }),
  managedApp("opencode", "OpenCode", "AI terminal runtime configured by aidevops for local sessions.", "ai runtime", "opencode", ["--version"], ["~/Applications/OpenCode AIDevOps.app", "/Applications/OpenCode.app", "~/.config/opencode/opencode.json"], "https://opencode.ai", "", true, true, "binary", { install: "aidevops setup --scope opencode", update: "aidevops setup --scope opencode", reinstall: "aidevops setup --scope opencode" }),
  managedApp("hooks", "Safety hooks", "Git, prompt, privacy, complexity, task-id, and canonical-install guards.", "safety", null, [], ["~/.aidevops/hooks", "~/.config/aidevops"], "https://aidevops.sh", "https://github.com/marcusquinn/aidevops.git", true, true, "aidevops", { install: "aidevops setup --scope hooks", update: "aidevops setup --scope hooks", reinstall: "aidevops setup --scope hooks" }),
  managedApp("pulse", "Pulse scheduler", "Launchd/cron supervisor for autonomous aidevops maintenance and dispatch routines.", "automation", null, [], ["~/Library/LaunchAgents/sh.aidevops.pulse.plist", "~/.aidevops/.agent-workspace/pulse"], "https://aidevops.sh", "https://github.com/marcusquinn/aidevops.git", true, true, "aidevops", { install: "aidevops setup --scope pulse", update: "aidevops setup --scope pulse", reinstall: "aidevops setup --scope pulse" }),
  managedApp("tabby", "Tabby terminal profiles", "Terminal profile sync for aidevops-managed shells.", "terminal", "tabby", ["--version"], ["~/Library/Application Support/tabby", "/Applications/Tabby.app"], "https://github.com/Eugeny/tabby/releases/latest", "https://github.com/Eugeny/tabby/releases/latest", true, true, "binary", { install: "aidevops setup --scope tabby", update: "aidevops setup --scope tabby", reinstall: "aidevops setup --scope tabby" }),
  managedApp("gh", "GitHub CLI", "GitHub issues, PRs, checks, releases, and API automation.", "git", "gh", ["--version"], ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"], "", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("glab", "GitLab CLI", "GitLab repository, issue, merge request, and CI automation.", "git", "glab", ["--version"], ["/opt/homebrew/bin/glab", "/usr/local/bin/glab", "/usr/bin/glab"], "", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("fd", "fd", "Fast file discovery for agents and developer workflows.", "search", "fd", ["--version"], ["/opt/homebrew/bin/fd", "/usr/local/bin/fd", "/usr/bin/fd"], "", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("ripgrep", "ripgrep", "Fast code and text search used by agents and local diagnostics.", "search", "rg", ["--version"], ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"], "", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("ripgrep-all", "ripgrep-all", "Document/archive-aware search companion for ripgrep.", "search", "rga", ["--version"], ["/opt/homebrew/bin/rga", "/usr/local/bin/rga", "/usr/bin/rga"], "", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("shellcheck", "ShellCheck", "Shell script static analysis gate.", "quality", "shellcheck", ["--version"], ["/opt/homebrew/bin/shellcheck", "/usr/local/bin/shellcheck", "/usr/bin/shellcheck"], "", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("shfmt", "shfmt", "Shell formatter used by local quality workflows.", "quality", "shfmt", ["--version"], ["/opt/homebrew/bin/shfmt", "/usr/local/bin/shfmt", "/usr/bin/shfmt"], "", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("bun", "Bun", "JavaScript runtime used for the GUI and toolchain helpers.", "runtime", "bun", ["--version"], ["~/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"], "https://bun.sh/install", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("node", "Node.js", "JavaScript runtime required by npm-hosted helpers and frontend tooling.", "runtime", "node", ["--version"], ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"], "https://nodejs.org/", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("homebrew", "Homebrew", "macOS package manager used by setup/update when available.", "package manager", "brew", ["--version"], ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"], "https://brew.sh", "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("qlty", "Qlty CLI", "Optional code quality aggregator installed by setup when selected.", "quality", "qlty", ["--version"], ["/opt/homebrew/bin/qlty", "/usr/local/bin/qlty", "~/.qlty/bin/qlty"], "https://qlty.sh", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("rtk", "rtk", "Token-optimized GitHub/API helper used by interactive discovery.", "developer tooling", "rtk", ["--version"], ["~/.local/bin/rtk", "/opt/homebrew/bin/rtk", "/usr/local/bin/rtk"], "https://github.com/rtk-ai/rtk#installation", "https://github.com/rtk-ai/rtk", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("cursor", "Cursor CLI", "Cursor command-line integration and config targets.", "ai runtime", "cursor", ["--version"], ["~/.cursor/bin/cursor", "/Applications/Cursor.app"], "https://cursor.com/install", "", true, true, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
  managedApp("zed", "Zed", "Optional editor installed by setup when selected.", "editor", "zed", ["--version"], ["/Applications/Zed.app", "/opt/homebrew/bin/zed", "/usr/local/bin/zed"], "https://zed.dev/download", "", false, false, "binary", { install: "./setup.sh --non-interactive" }),
  managedApp("orbstack", "OrbStack", "Optional local container/VM runtime for macOS development.", "runtime", "orb", ["version"], ["/Applications/OrbStack.app", "/opt/homebrew/bin/orb"], "https://orbstack.dev/", "", false, false, "binary", { install: "./setup.sh --non-interactive" }),
  managedApp("ollama", "Ollama", "Optional local model runtime for local AI workflows.", "ai runtime", "ollama", ["--version"], ["/Applications/Ollama.app", "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"], "https://ollama.com", "", false, false, "binary", { install: "./setup.sh --non-interactive", update: "aidevops update-tools --update" }),
];

function managedApp(id: string, name: string, description: string, category: string, binary: string | null, versionArgs: string[], installPathRefs: string[], originWebsiteUrl: string, originRepoUrl: string, aidevopsInstall: boolean, aidevopsUpdate: boolean, latestVersionSource: ManagedAppDefinition["latest_version_source"], actionCommands: ManagedAppDefinition["action_commands"]): ManagedAppDefinition {
  return { id, name, description, category, binary, version_args: versionArgs, install_path_refs: installPathRefs, origin_website_url: originWebsiteUrl, origin_repo_url: originRepoUrl, aidevops_install: aidevopsInstall, aidevops_update: aidevopsUpdate, latest_version_source: latestVersionSource, action_commands: actionCommands };
}

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

function readManagedApps(latestVersion: string, installedVersion: string): GuiManagedAppSummary[] {
  return MANAGED_APP_DEFINITIONS.map((definition) => managedAppSummary(definition, latestVersion, installedVersion));
}

function managedAppSummary(definition: ManagedAppDefinition, latestVersion: string, installedVersion: string): GuiManagedAppSummary {
  const binaryPath = definition.binary === null ? null : resolveBinary(definition.binary);
  const installPathRef = firstExistingPathRef(definition.install_path_refs) ?? definition.install_path_refs[0] ?? "not found";
  const installedVersionText = readManagedAppVersion(definition, binaryPath, installedVersion);
  const latestVersionText = definition.latest_version_source === "aidevops"
    ? latestVersion
    : definition.latest_version_source === "binary"
      ? installedVersionText
      : "unknown";

  return {
    id: definition.id,
    name: definition.name,
    description: definition.description,
    category: definition.category,
    origin_website_url: definition.origin_website_url,
    origin_repo_url: definition.origin_repo_url,
    aidevops_install: definition.aidevops_install,
    aidevops_update: definition.aidevops_update,
    installed_version: installedVersionText,
    latest_version: latestVersionText,
    install_path_ref: binaryPath === null ? installPathRef : collapseHome(binaryPath),
    status: binaryPath !== null || definition.install_path_refs.some((pathRef) => existsSync(expandHome(pathRef))) ? "found" : "missing",
    actions: (["install", "update", "reinstall", "remove"] as const).map((action) => ({
      id: action,
      label: action[0].toUpperCase() + action.slice(1),
      enabled: definition.action_commands[action] !== undefined,
      command_preview: definition.action_commands[action] ?? "No allowlisted command yet",
      confirmation: action === "remove" ? "required" : action === "reinstall" ? "recommended" : "none",
    })),
  };
}

function readManagedAppVersion(definition: ManagedAppDefinition, binaryPath: string | null, installedVersion: string): string {
  if (definition.latest_version_source === "aidevops") {
    return firstExistingPathRef(definition.install_path_refs) === null ? "not installed" : installedVersion;
  }

  if (binaryPath === null) {
    return "not installed";
  }

  return readBinaryVersion(binaryPath, definition.version_args);
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
      timeout: 200,
    }).trim();
    return output.split("\n").find((line) => line.length > 0) ?? null;
  } catch {
    return null;
  }
}

interface OpenCodeSessionRow {
  id: string;
  directory: string;
  title: string;
  time_updated: number;
  model: string | null;
  agent: string | null;
}

function readOpenCodeSessions(dbPath: string, dbPathRef: string, repos: GuiLocalRepoSetupSummary[]): GuiOpenCodeSessionRegistrySummary {
  if (!existsSync(dbPath)) {
    return {
      path_ref: dbPathRef,
      health: "missing",
      value_policy: "metadata_only_no_message_payloads",
      sessions: [],
    };
  }

  try {
    const database = new Database(dbPath, { readonly: true });
    try {
      const rows = database.query(`
        SELECT id, directory, title, time_updated, model, agent
        FROM session
        WHERE time_archived IS NULL
        ORDER BY time_updated DESC
        LIMIT 200
      `).all() as OpenCodeSessionRow[];
      const sessions = rows
        .map((row) => opencodeSessionFromRow(row, repos))
        .filter((session): session is GuiOpenCodeSessionSummary => session !== null);

      return {
        path_ref: dbPathRef,
        health: "present",
        value_policy: "metadata_only_no_message_payloads",
        sessions,
      };
    } finally {
      database.close();
    }
  } catch {
    return {
      path_ref: dbPathRef,
      health: "invalid",
      value_policy: "metadata_only_no_message_payloads",
      sessions: [],
    };
  }
}

function opencodeSessionFromRow(row: OpenCodeSessionRow, repos: GuiLocalRepoSetupSummary[]): GuiOpenCodeSessionSummary | null {
  const repo = repos.find((candidate) => row.directory === expandHome(candidate.path_ref) || row.directory.startsWith(`${expandHome(candidate.path_ref)}/`));

  if (!repo) {
    return null;
  }

  return {
    id_ref: row.id,
    repo_path_ref: repo.path_ref,
    title: row.title.trim().length > 0 ? row.title : "Untitled session",
    updated_at: formatUnixMillis(row.time_updated),
    model: row.model ?? "unknown",
    agent: row.agent ?? "unknown",
  };
}

function formatUnixMillis(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return "unknown";
  }

  return new Date(value).toISOString();
}

function readBinaryVersion(binaryPath: string, args: string[]): string {
  if (args.length === 0) {
    return "unknown";
  }

  try {
    const output = execFileSync(binaryPath, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 500,
    }).trim();
    return output.split("\n").find((line) => line.length > 0) ?? "unknown";
  } catch {
    return "unknown";
  }
}

function isSourcePathRef(pathRef: string): boolean {
  return pathRef === "VERSION" || pathRef.startsWith("~/") || pathRef.startsWith("/");
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
