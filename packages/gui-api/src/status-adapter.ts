import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertNoSecretSentinels,
  createEnvelope,
  statusFixture,
  type GuiResponseEnvelope,
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
  const agentsPathRef = "~/.aidevops/agents";
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
        health: existsSync(expandHome("~/.config/aidevops/settings.json"))
          ? "present"
          : "missing",
      },
    ],
    helper_availability: [
      {
        name: STATUS_ADAPTER_COMMAND.join(" "),
        status: "unchecked",
      },
    ],
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
