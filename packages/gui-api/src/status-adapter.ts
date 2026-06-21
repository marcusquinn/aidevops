import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertNoSecretSentinels,
  createEnvelope,
  statusFixture,
  type GuiResponseEnvelope,
  type GuiRepoRegistrySummary,
  type GuiRepoSummary,
  type GuiSettingsSummary,
  type GuiStatusData,
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
  const agentsPathRef = "~/.aidevops/agents";
  const settingsPath = expandHome(settingsPathRef);
  const reposPath = expandHome(reposPathRef);
  const aidevopsVersion = existsSync(versionPath)
    ? readFileSync(versionPath, "utf8").trim()
    : statusFixture.aidevops_version;
  const installedVersion = readOptionalText(expandHome("~/.aidevops/agents/VERSION")) ?? aidevopsVersion;
  const restartRequired = installedVersion !== aidevopsVersion;

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
  };

  const envelope = createEnvelope({
    operation_id: "setup.status.read",
    source: {
      surface: "setup",
      authority: "aidevops helpers",
      path_refs: [agentsPathRef, settingsPathRef, "VERSION"],
    },
    data,
    warnings: ["Helper execution is deferred; scaffold reports local path health only."],
    observed_at: options.observedAt,
  });

  assertNoSecretSentinels(envelope);
  return envelope;
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

function extractRepoSummaries(value: unknown): GuiRepoSummary[] {
  if (Array.isArray(value)) {
    return value.map((entry, index) => repoSummaryFromUnknown(entry, `repo-${index + 1}`));
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
