import type { GuiResponseEnvelope, GuiStatusData } from "@aidevops/gui-shared";
import { useCallback, useEffect, useRef, useState } from "react";
import { fetchStatus, mockedStatus, unavailableStatus } from "./status-client";
import { type VaultDialogIntent, vaultDialogIntentForStatus } from "./VaultBadges";

interface GuiStatusController {
  markVaultTerminalLaunch: () => void;
  refreshStatus: () => Promise<void>;
  setVaultDialogIntent: (intent: VaultDialogIntent | null) => void;
  status: GuiResponseEnvelope<GuiStatusData>;
  statusLoading: boolean;
  vaultDialogIntent: VaultDialogIntent | null;
}

export function useGuiStatus(): GuiStatusController {
  const [status, setStatus] = useState<GuiResponseEnvelope<GuiStatusData>>(mockedStatus());
  const [statusLoading, setStatusLoading] = useState(true);
  const [vaultDialogIntent, setVaultDialogIntent] = useState<VaultDialogIntent | null>(null);
  const hasPromptedVaultSetup = useRef(false);
  const refreshVaultAfterTerminal = useRef(false);
  const currentVaultIntent = vaultDialogIntentForStatus(status.data.vault);
  const shouldPromptSetup = shouldPromptVaultSetup(statusLoading, status.data.vault, hasPromptedVaultSetup.current);

  const refreshStatus = useCallback(async () => {
    setStatusLoading(true);
    try {
      setStatus(await fetchStatus());
    } catch {
      setStatus(unavailableStatus());
    } finally {
      setStatusLoading(false);
    }
  }, []);

  useEffect(() => {
    void refreshStatus();
  }, [refreshStatus]);

  useEffect(() => {
    const refreshAfterTerminal = () => {
      if (refreshVaultAfterTerminal.current) {
        refreshVaultAfterTerminal.current = false;
        void refreshStatus();
      }
    };
    window.addEventListener("focus", refreshAfterTerminal);
    return () => window.removeEventListener("focus", refreshAfterTerminal);
  }, [refreshStatus]);

  useEffect(() => {
    setVaultDialogIntent((openIntent) => openIntent !== null && openIntent !== currentVaultIntent ? null : openIntent);
  }, [currentVaultIntent]);

  useEffect(() => {
    if (shouldPromptSetup) {
      hasPromptedVaultSetup.current = true;
      setVaultDialogIntent("setup");
    }
  }, [shouldPromptSetup]);

  return {
    markVaultTerminalLaunch: () => {
      refreshVaultAfterTerminal.current = true;
    },
    refreshStatus,
    setVaultDialogIntent,
    status,
    statusLoading,
    vaultDialogIntent,
  };
}

export function shouldPromptVaultSetup(statusLoading: boolean, vault: GuiStatusData["vault"], hasPromptedVaultSetup: boolean): boolean {
  const setupIsReady = vault.helper_status === "available"
    && vault.status === "uninitialized"
    && vault.setup_state === "uninitialized"
    && vault.readiness.setup_required;
  return !statusLoading && setupIsReady && !hasPromptedVaultSetup;
}
