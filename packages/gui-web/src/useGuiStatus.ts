import type { GuiResponseEnvelope, GuiStatusData } from "@aidevops/gui-shared";
import { useCallback, useEffect, useRef, useState } from "react";
import { fetchStatus, mockedStatus, unavailableStatus } from "./status-client";
import { type VaultDialogIntent, vaultDialogIntentForStatus } from "./VaultBadges";

const VAULT_TERMINAL_REFRESH_DELAYS_MS = [1200, 3000, 7000] as const;

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
  const vaultStatusAtTerminalLaunch = useRef<GuiStatusData["vault"]["status"] | null>(null);
  const vaultTerminalRefreshTimeouts = useRef<number[]>([]);
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

  const clearVaultTerminalRefreshes = useCallback(() => {
    for (const timeoutId of vaultTerminalRefreshTimeouts.current) {
      window.clearTimeout(timeoutId);
    }
    vaultTerminalRefreshTimeouts.current = [];
  }, []);

  const runVaultTerminalRefresh = useCallback(() => {
    if (refreshVaultAfterTerminal.current) {
      void refreshStatus();
    }
  }, [refreshStatus]);

  const scheduleVaultTerminalRefreshes = useCallback(() => {
    clearVaultTerminalRefreshes();
    vaultTerminalRefreshTimeouts.current = VAULT_TERMINAL_REFRESH_DELAYS_MS.map((delay) => (
      window.setTimeout(runVaultTerminalRefresh, delay)
    ));
  }, [clearVaultTerminalRefreshes, runVaultTerminalRefresh]);

  useEffect(() => {
    const refreshAfterTerminal = () => {
      if (refreshVaultAfterTerminal.current) {
        refreshVaultAfterTerminal.current = false;
        clearVaultTerminalRefreshes();
        void refreshStatus();
      }
    };
    window.addEventListener("focus", refreshAfterTerminal);
    return () => window.removeEventListener("focus", refreshAfterTerminal);
  }, [clearVaultTerminalRefreshes, refreshStatus]);

  useEffect(() => {
    if (refreshVaultAfterTerminal.current && status.data.vault.status !== vaultStatusAtTerminalLaunch.current) {
      refreshVaultAfterTerminal.current = false;
      clearVaultTerminalRefreshes();
    }
  }, [clearVaultTerminalRefreshes, status.data.vault.status]);

  useEffect(() => () => {
    clearVaultTerminalRefreshes();
  }, [clearVaultTerminalRefreshes]);

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
      vaultStatusAtTerminalLaunch.current = status.data.vault.status;
      scheduleVaultTerminalRefreshes();
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
