import { spawnSync } from "node:child_process";
import { existsSync, lstatSync } from "node:fs";
import { join } from "node:path";
import {
  type GuiVaultSetupState,
  type GuiVaultStatus,
  type GuiVaultStatusData,
  type GuiSecretReference,
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

export function readSecretInventory(repoRoot: string, vault: GuiVaultStatusData): {
  backends: { gopass: "available" | "missing" | "error"; credentials: "available" | "missing" | "error" };
  secrets: GuiSecretReference[];
} {
  const empty = { backends: { gopass: "missing", credentials: "missing" } as const, secrets: [] };
  if (vault.status !== "unlocked" || !vault.unlocked || vault.locked || vault.helper_status !== "available") return empty;
  const helperPath = join(repoRoot, ".agents", "scripts", "secret-helper.sh");
  if (!isTrustedHelper(helperPath)) return empty;
  const result = spawnSync("/bin/bash", [helperPath, "inventory"], {
    encoding: "utf8",
    env: vaultProbeEnvironment(),
    maxBuffer: 65_536,
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 300,
  });
  if (result.error !== undefined || result.signal !== null || result.status !== 0 || result.stdout.length > 65_535) return empty;
  try {
    const value: unknown = JSON.parse(result.stdout);
    if (!isInventory(value)) return empty;
    const confirmed = readVaultSummary(repoRoot);
    if (confirmed.status !== "unlocked" || !confirmed.unlocked || confirmed.locked || confirmed.helper_status !== "available") return empty;
    return { backends: value.backends, secrets: value.secrets };
  } catch {
    return empty;
  }
}

function isTrustedHelper(path: string): boolean {
  try {
    const stat = lstatSync(path);
    return stat.isFile() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o022) === 0;
  } catch {
    return false;
  }
}

function isInventory(value: unknown): value is {
  version: 1;
  backends: { gopass: "available" | "missing" | "error"; credentials: "available" | "missing" | "error" };
  secrets: GuiSecretReference[];
} {
  if (typeof value !== "object" || value === null) return false;
  const inventory = value as Record<string, unknown>;
  if (inventory.version !== 1 || !Array.isArray(inventory.secrets) || inventory.secrets.length > 512) return false;
  const backends = inventory.backends as Record<string, unknown> | null;
  const states = ["available", "missing", "error"];
  if (backends === null || typeof backends !== "object" || !states.includes(String(backends.gopass)) || !states.includes(String(backends.credentials))) return false;
  let previous = "";
  const names = new Set<string>();
  for (const entry of inventory.secrets) {
    if (typeof entry !== "object" || entry === null) return false;
    const secret = entry as Record<string, unknown>;
    if (typeof secret.name !== "string" || !/^[A-Z][A-Z0-9_]{0,127}$/.test(secret.name) || secret.status !== "configured") return false;
    if (secret.name <= previous || names.has(secret.name) || Object.keys(secret).some((key) => key !== "name" && key !== "status")) return false;
    previous = secret.name;
    names.add(secret.name);
  }
  return Object.keys(inventory).length === 3 && Object.keys(backends).length === 2;
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
