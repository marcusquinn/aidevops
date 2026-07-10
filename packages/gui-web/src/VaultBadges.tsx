import type { GuiVaultCollectionSummary, GuiVaultStatusData } from "@aidevops/gui-shared";
import { FiLock, FiUnlock } from "react-icons/fi";
import type { SurfaceId } from "./app-model";
import { text } from "./app-model";

export function vaultCollectionForSurface(
  vault: GuiVaultStatusData,
  surface: SurfaceId,
): GuiVaultCollectionSummary | undefined {
  return vault.collections.find((collection) => collection.surface_ids.includes(surface));
}

export function isVaultSurfaceLocked(vault: GuiVaultStatusData, surface: SurfaceId): boolean {
  const collection = vaultCollectionForSurface(vault, surface);
  return surface !== "vault" && collection?.encrypted === true && collection?.preview_policy === "hidden_while_locked" && !vault.unlocked;
}

export function vaultCollectionTooltip(collection: GuiVaultCollectionSummary): string {
  if (collection.preview_policy === "metadata_only") {
    return text.vaultMetadataPreview;
  }

  return text.vaultTooltip;
}

export type VaultDialogIntent = "setup" | "unlock" | "lock" | "recover" | "unavailable";

const vaultActionLabels: Record<VaultDialogIntent, string> = {
  lock: "Lock Vault",
  recover: "Review recovery",
  setup: "Set up Vault",
  unavailable: "Check Vault status",
  unlock: "Unlock Vault",
};

const authoritativeStatusIntents: Partial<Record<GuiVaultStatusData["status"], VaultDialogIntent>> = {
  locked: "unlock",
  uninitialized: "setup",
};

export function vaultDialogIntentForStatus(vault: GuiVaultStatusData): VaultDialogIntent {
  let intent = authoritativeStatusIntents[vault.status] ?? "unavailable";
  if (vault.unlocked) {
    intent = "lock";
  } else if (vault.status === "corrupted") {
    intent = "recover";
  } else if (vault.helper_status !== "available" || vault.status === "unknown") {
    intent = "unavailable";
  } else if (intent === "setup" && !vaultSetupIsRequired(vault)) {
    intent = "unavailable";
  }

  return intent;
}

export function vaultActionLabel(intent: VaultDialogIntent): string {
  return vaultActionLabels[intent];
}

export function VaultPadlock({ collection, compact = false, onActivate, vault }: {
  collection: GuiVaultCollectionSummary;
  compact?: boolean;
  onActivate?: (intent: VaultDialogIntent) => void;
  vault: GuiVaultStatusData;
}) {
  const intent = vaultDialogIntentForStatus(vault);
  const presentation = vaultPadlockPresentation(collection, compact, onActivate !== undefined, intent, vault);
  const content = <PadlockContent presentation={presentation} />;

  if (onActivate === undefined) {
    return <span aria-label={presentation.tooltip} className={presentation.className} data-vault-state={presentation.state} role="img" title={presentation.tooltip}>{content}</span>;
  }

  return (
    <button
      aria-label={presentation.tooltip}
      className={presentation.className}
      data-vault-state={presentation.state}
      onClick={(event) => {
        event.preventDefault();
        event.stopPropagation();
        onActivate(intent);
      }}
      title={presentation.tooltip}
      type="button"
    >
      {content}
    </button>
  );
}

interface VaultPadlockPresentation {
  className: string;
  label: string;
  locked: boolean;
  state: "locked" | "unlocked";
  tooltip: string;
}

function vaultPadlockPresentation(collection: GuiVaultCollectionSummary, compact: boolean, interactive: boolean, intent: VaultDialogIntent, vault: GuiVaultStatusData): VaultPadlockPresentation {
  const locked = collection.state !== "unlocked" || !vault.unlocked;
  const stateLabel = vaultStateLabel(intent, locked);
  const compactLabel = compact || intent === "recover" || intent === "unavailable";
  const classNames = ["vault-padlock"];
  if (compact) classNames.push("compact");
  if (interactive) classNames.push("interactive");

  return {
    className: classNames.join(" "),
    label: compactLabel ? stateLabel : `${stateLabel} by Vault`,
    locked,
    state: locked ? "locked" : "unlocked",
    tooltip: vaultStateTooltip(intent, stateLabel, collection),
  };
}

function PadlockContent({ presentation }: { presentation: VaultPadlockPresentation }) {
  const Icon = presentation.locked ? FiLock : FiUnlock;
  return <><Icon aria-hidden="true" focusable="false" /><span>{presentation.label}</span></>;
}

function vaultStateLabel(intent: VaultDialogIntent, locked: boolean): string {
  const intentLabels: Partial<Record<VaultDialogIntent, string>> = {
    recover: "Recovery required",
    unavailable: "Status unavailable",
  };
  return intentLabels[intent] ?? (locked ? "Locked" : "Unlocked");
}

function vaultStateTooltip(intent: VaultDialogIntent, stateLabel: string, collection: GuiVaultCollectionSummary): string {
  const intentTooltips: Partial<Record<VaultDialogIntent, string>> = {
    recover: "Recovery required: Vault metadata is damaged; preserve encrypted data.",
    unavailable: "Status unavailable: protected content remains hidden until Vault state is authoritative.",
  };
  return intentTooltips[intent] ?? `${stateLabel}: ${vaultCollectionTooltip(collection)}`;
}

function vaultSetupIsRequired(vault: GuiVaultStatusData): boolean {
  return vault.status === "uninitialized" && vault.setup_state === "uninitialized" && vault.readiness.setup_required;
}
