import type { GuiVaultCollectionSummary, GuiVaultStatusData } from "@aidevops/gui-shared";
import type { KeyboardEvent, MouseEvent } from "react";
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

export function vaultDialogIntentForStatus(vault: GuiVaultStatusData): VaultDialogIntent {
  if (vault.unlocked) {
    return "lock";
  }

  if (vault.status === "corrupted") {
    return "recover";
  }
  if (vault.helper_status !== "available" || vault.status === "unknown") {
    return "unavailable";
  }
  if (vault.status === "locked") {
    return "unlock";
  }
  if (vault.status === "uninitialized" && vault.setup_state === "uninitialized" && vault.readiness.setup_required) {
    return "setup";
  }

  return "unavailable";
}

export function vaultActionLabel(intent: VaultDialogIntent): string {
  switch (intent) {
    case "lock": return "Lock Vault";
    case "setup": return "Set up Vault";
    case "unlock": return "Unlock Vault";
    case "recover": return "Review recovery";
    case "unavailable": return "Check Vault status";
  }
}

export function VaultPadlock({ collection, compact = false, onActivate, vault }: {
  collection: GuiVaultCollectionSummary;
  compact?: boolean;
  onActivate?: (intent: VaultDialogIntent) => void;
  vault: GuiVaultStatusData;
}) {
  const locked = collection.state !== "unlocked" || !vault.unlocked;
  const stateLabel = locked ? "Locked" : "Unlocked";
  const Icon = locked ? FiLock : FiUnlock;
  const tooltip = `${stateLabel}: ${vaultCollectionTooltip(collection)}`;
  const className = compact ? "vault-padlock compact" : "vault-padlock";

  const activate = (event: MouseEvent<HTMLSpanElement> | KeyboardEvent<HTMLSpanElement>) => {
    if (onActivate === undefined) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();
    onActivate(vaultDialogIntentForStatus(vault));
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLSpanElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      activate(event);
    }
  };

  return (
    <span
      aria-label={tooltip}
      className={onActivate ? `${className} interactive` : className}
      data-vault-state={locked ? "locked" : "unlocked"}
      onClick={activate}
      onKeyDown={handleKeyDown}
      role={onActivate ? "button" : undefined}
      tabIndex={onActivate ? 0 : undefined}
      title={tooltip}
    >
      <Icon aria-hidden="true" focusable="false" />
      <span>{compact ? stateLabel : `${stateLabel} by Vault`}</span>
    </span>
  );
}
