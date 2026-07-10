import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import {
  type GuiVaultSetupState,
  type GuiVaultStatus,
  type GuiVaultStatusData,
  statusFixture,
} from "../../gui-shared/src";

const GUI_VAULT_STATUSES = ["uninitialized", "locked", "unlocked", "corrupted", "unknown"] as const satisfies readonly GuiVaultStatus[];
const GUI_VAULT_SETUP_STATES = [
  "uninitialized",
  "test-created",
  "restart-required",
  "test-verified",
  "migration-ready",
  "unknown",
] as const satisfies readonly GuiVaultSetupState[];
const INITIALIZED_VAULT_STATUSES = new Set<GuiVaultStatus>(["locked", "unlocked", "corrupted"]);
const RESTART_TEST_SETUP_STATES = new Set<GuiVaultSetupState>(["test-created", "restart-required", "test-verified"]);

export function readVaultSummary(repoRoot: string): GuiVaultStatusData {
  const helperPath = join(repoRoot, ".agents", "scripts", "vault-helper.sh");
  const helperExists = existsSync(helperPath);
  const parsedStatus = helperExists ? readVaultCommand(helperPath, "status", isGuiVaultStatus) : null;
  const parsedSetupState = helperExists ? readVaultCommand(helperPath, "setup-state", isGuiVaultSetupState) : null;
  const coherent = coherentVaultState(parsedStatus, parsedSetupState);
  const rawStatus = coherent ? parsedStatus : null;
  const rawSetupState = coherent ? parsedSetupState : null;
  const helperStatus = vaultHelperStatus(helperExists, rawStatus, rawSetupState);
  const status = rawStatus ?? "unknown";
  const setupState = rawSetupState ?? fallbackSetupState(status);
  const unlocked = status === "unlocked";
  const collectionState = vaultCollectionState(status);
  const setupRequired = helperStatus === "available" && status === "uninitialized" && setupState === "uninitialized";

  return {
    ...statusFixture.vault,
    status,
    setup_state: setupState,
    initialized: INITIALIZED_VAULT_STATUSES.has(status),
    locked: !unlocked,
    unlocked,
    available: helperStatus === "available",
    helper_status: helperStatus,
    readiness: {
      ...statusFixture.vault.readiness,
      migration_allowed: unlocked && setupState === "migration-ready",
      setup_required: setupRequired,
      restart_test_required: RESTART_TEST_SETUP_STATES.has(setupState),
      locked_content_hidden: !unlocked,
    },
    collections: statusFixture.vault.collections.map((collection) => ({
      ...collection,
      state: collection.state === "planned" ? "planned" : collectionState,
    })),
  };
}

function readVaultCommand<T extends string>(
  helperPath: string,
  command: "status" | "setup-state",
  isAllowed: (value: string) => value is T,
): T | null {
  const result = spawnSync("/bin/bash", [helperPath, command], {
    encoding: "utf8",
    env: vaultProbeEnvironment(),
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 750,
  });
  if (result.error !== undefined || result.signal !== null || result.status === null || result.stderr.length > 0) return null;
  const output = result.stdout.endsWith("\n") ? result.stdout.slice(0, -1) : result.stdout;
  if (output.length === 0 || output.includes("\n") || output.includes("\r") || output.trim() !== output) return null;
  return isAllowed(output) && isExpectedVaultExit(command, output, result.status) ? output : null;
}

function vaultProbeEnvironment(): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = { PATH: "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" };
  for (const name of ["HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "AIDEVOPS_VAULT_DIR", "AIDEVOPS_VAULT_RUNTIME_DIR", "AIDEVOPS_VAULT_PYTHON"]) {
    const value = process.env[name];
    if (value !== undefined) environment[name] = value;
  }
  return environment;
}

function coherentVaultState(status: GuiVaultStatus | null, setupState: GuiVaultSetupState | null): boolean {
  if (status === null || setupState === null) return false;
  if (status === "uninitialized") return setupState === "uninitialized";
  if (status === "corrupted") return setupState === "unknown";
  if (status === "unlocked") return setupState === "migration-ready";
  if (status === "locked") return ["test-created", "restart-required", "test-verified", "migration-ready"].includes(setupState);
  return false;
}

function isExpectedVaultExit(command: "status" | "setup-state", value: string, exitCode: number): boolean {
  if (command === "status") {
    return (exitCode === 0 && (value === "locked" || value === "unlocked"))
      || (exitCode === 2 && value === "uninitialized")
      || (exitCode === 3 && value === "corrupted");
  }
  return (exitCode === 0 && ["test-created", "restart-required", "test-verified", "migration-ready"].includes(value))
    || (exitCode === 2 && value === "uninitialized")
    || (exitCode === 3 && value === "unknown");
}

function isGuiVaultStatus(value: string): value is GuiVaultStatus {
  return GUI_VAULT_STATUSES.includes(value as GuiVaultStatus);
}

function isGuiVaultSetupState(value: string): value is GuiVaultSetupState {
  return GUI_VAULT_SETUP_STATES.includes(value as GuiVaultSetupState);
}

function vaultHelperStatus(
  helperExists: boolean,
  status: GuiVaultStatus | null,
  setupState: GuiVaultSetupState | null,
): GuiVaultStatusData["helper_status"] {
  if (!helperExists) {
    return "missing";
  }
  return status === null || setupState === null ? "error" : "available";
}

function fallbackSetupState(status: GuiVaultStatus): GuiVaultSetupState {
  return status === "uninitialized" ? "uninitialized" : "unknown";
}

function vaultCollectionState(status: GuiVaultStatus): GuiVaultStatusData["collections"][number]["state"] {
  if (status === "unlocked") {
    return "unlocked";
  }
  if (status === "locked" || status === "corrupted") {
    return "locked";
  }
  if (status === "uninitialized") {
    return "not_configured";
  }

  return "unknown";
}
