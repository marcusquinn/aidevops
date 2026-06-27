import { execFileSync } from "node:child_process";
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
  const rawStatus = helperExists ? readVaultCommand(helperPath, ["status"], isGuiVaultStatus) : null;
  const rawSetupState = helperExists ? readVaultCommand(helperPath, ["setup-state"], isGuiVaultSetupState) : null;
  const helperStatus = vaultHelperStatus(helperExists, rawStatus, rawSetupState);
  const status = rawStatus ?? "unknown";
  const setupState = rawSetupState ?? fallbackSetupState(status);
  const unlocked = status === "unlocked";
  const collectionState = vaultCollectionState(status);

  return {
    ...statusFixture.vault,
    status,
    setup_state: setupState,
    initialized: INITIALIZED_VAULT_STATUSES.has(status),
    locked: !unlocked,
    unlocked,
    available: helperExists && helperStatus !== "error",
    helper_status: helperStatus,
    readiness: {
      ...statusFixture.vault.readiness,
      migration_allowed: unlocked && setupState === "migration-ready",
      setup_required: status === "uninitialized" || setupState === "uninitialized",
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
  args: string[],
  isAllowed: (value: string) => value is T,
): T | null {
  try {
    const output = execFileSync("sh", [helperPath, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 300,
    }).trim();
    const firstLine = output.split(/\r?\n/).find((line) => line.trim().length > 0)?.trim() ?? "";
    return isAllowed(firstLine) ? firstLine : null;
  } catch {
    return null;
  }
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
  return status === null && setupState === null ? "error" : "available";
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
