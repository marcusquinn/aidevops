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
  return surface !== "vault" && collection?.encrypted === true && !vault.unlocked;
}

export function VaultPadlock({ collection, compact = false, vault }: {
  collection: GuiVaultCollectionSummary;
  compact?: boolean;
  vault: GuiVaultStatusData;
}) {
  const locked = collection.state !== "unlocked" || !vault.unlocked;
  const stateLabel = locked ? "Locked" : "Unlocked";
  const Icon = locked ? FiLock : FiUnlock;
  const tooltip = `${stateLabel}: ${text.vaultTooltip}`;

  return (
    <span
      aria-label={`${stateLabel} by aidevops Vault: ${collection.label}`}
      className={compact ? "vault-padlock compact" : "vault-padlock"}
      data-vault-state={locked ? "locked" : "unlocked"}
      title={tooltip}
    >
      <Icon aria-hidden="true" focusable="false" />
      <span>{compact ? stateLabel : `${stateLabel} by Vault`}</span>
    </span>
  );
}
