import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { hostname, networkInterfaces, userInfo } from "node:os";
import { join } from "node:path";
import {
  assertNoSecretSentinels,
  createEnvelope,
  type GuiAiAppSummary,
  type GuiAiProviderId,
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
