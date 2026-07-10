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
type VaultCommand = "status" | "setup-state";
type VaultProbeValue = GuiVaultStatus | GuiVaultSetupState;
const COHERENT_VAULT_STATES: Readonly<Record<GuiVaultStatus, ReadonlySet<GuiVaultSetupState>>> = {
  uninitialized: new Set(["uninitialized"]),
  locked: new Set(["test-created", "restart-required", "test-verified", "migration-ready"]),
  unlocked: new Set(["migration-ready"]),
  corrupted: new Set(["unknown"]),
  unknown: new Set(),
};
const EXPECTED_VAULT_EXIT_CODES: Readonly<
  Record<VaultCommand, Readonly<Partial<Record<VaultProbeValue, number>>>>
> = {
  status: { locked: 0, unlocked: 0, uninitialized: 2, corrupted: 3 },
  "setup-state": {
    "test-created": 0,
    "restart-required": 0,
    "test-verified": 0,
    "migration-ready": 0,
    uninitialized: 2,
    unknown: 3,
  },
};

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

function readVaultCommand<T extends VaultProbeValue>(
  helperPath: string,
  command: VaultCommand,
  isAllowed: (value: string) => value is T,
): T | null {
  const result = spawnSync("/bin/bash", [helperPath, command], {
    encoding: "utf8",
    env: vaultProbeEnvironment(),
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 750,
  });
  if (result.error !== undefined || result.signal !== null || result.status === null) return null;
  const output = result.stdout.endsWith("\n") ? result.stdout.slice(0, -1) : result.stdout;
  if (output.length === 0 || output.includes("\n") || output.includes("\r") || output.trim() !== output) return null;
  return isAllowed(output) && isExpectedVaultExit(command, output, result.status) ? output : null;
}

function vaultProbeEnvironment(): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = { PATH: "/usr/bin:/bin:/usr/sbin:/sbin" };
  for (const name of ["HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "AIDEVOPS_VAULT_DIR", "AIDEVOPS_VAULT_RUNTIME_DIR", "AIDEVOPS_VAULT_PYTHON"]) {
    const value = process.env[name];
    if (value !== undefined) environment[name] = value;
  }
  return environment;
}

function coherentVaultState(status: GuiVaultStatus | null, setupState: GuiVaultSetupState | null): boolean {
  if (status === null || setupState === null) return false;
  return COHERENT_VAULT_STATES[status].has(setupState);
}

function isExpectedVaultExit(command: VaultCommand, value: VaultProbeValue, exitCode: number): boolean {
  return EXPECTED_VAULT_EXIT_CODES[command][value] === exitCode;
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
