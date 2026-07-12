import { type RefObject, useCallback, useEffect, useRef, useState } from "react";
import type { VaultDialogIntent } from "./VaultBadges";
import { isNativeVaultResult, type NativeVaultAction, type NativeVaultResult, postNativeVaultCommand, vaultCommandText } from "./vault-command-bridge";

export type VaultLaunchStatus = "idle" | "requesting" | "opened" | "copied" | "failed" | "succeeded" | "cancelled";

const terminalActions: Record<VaultDialogIntent, NativeVaultAction | null> = {
  lock: "lock",
  recover: null,
  setup: "init",
  unavailable: null,
  unlock: "unlock",
};
const nativeResultStatuses: Record<NativeVaultResult, VaultLaunchStatus> = {
  cancelled: "cancelled",
  failed: "failed",
  presented: "opened",
  running: "opened",
  succeeded: "succeeded",
};

export function terminalActionForIntent(intent: VaultDialogIntent): NativeVaultAction | null {
  return terminalActions[intent];
}

export function useVaultDialogFocus({ dialogRef, intent, onClose, primaryActionRef }: {
  dialogRef: RefObject<HTMLElement | null>;
  intent: VaultDialogIntent;
  onClose: () => void;
  primaryActionRef: RefObject<HTMLButtonElement | null>;
}): void {
  useEffect(() => {
    const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    return () => previousFocus?.focus();
  }, []);

  useEffect(() => {
    const primaryAction = primaryActionRef.current;
    if (primaryAction?.dataset.vaultIntent === intent) {
      primaryAction.focus();
    }
  }, [intent, primaryActionRef]);

  useEffect(() => {
    const handleDialogKeys = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
      }
      trapDialogFocus(event, dialogRef.current);
    };
    window.addEventListener("keydown", handleDialogKeys);
    return () => window.removeEventListener("keydown", handleDialogKeys);
  }, [dialogRef, onClose]);
}

export function useVaultCommandLaunch({ intent, onRefresh, onTerminalLaunch }: {
  intent: VaultDialogIntent;
  onRefresh: () => Promise<void> | void;
  onTerminalLaunch: () => void;
}): { launchStatus: VaultLaunchStatus; launchTerminal: () => Promise<void> } {
  const [launchState, setLaunchState] = useState<{ intent: VaultDialogIntent; status: VaultLaunchStatus }>({ intent, status: "idle" });
  const nativeResultTimeout = useRef<number | null>(null);
  const timeoutIntent = useRef(intent);
  const launchStatus = launchState.intent === intent ? launchState.status : "idle";
  const setLaunchStatus = useCallback((status: VaultLaunchStatus) => setLaunchState({ intent, status }), [intent]);
  const clearNativeResultTimeout = useCallback(() => clearScheduledTimeout(nativeResultTimeout), []);

  useEffect(() => {
    const handleNativeResult = (event: Event) => {
      clearNativeResultTimeout();
      const result = (event as CustomEvent<unknown>).detail;
      setLaunchStatus(isNativeVaultResult(result) ? nativeResultStatuses[result] : "failed");
      if (result === "succeeded") void onRefresh();
    };
    window.addEventListener("aidevops:vault-command-result", handleNativeResult);
    return () => window.removeEventListener("aidevops:vault-command-result", handleNativeResult);
  }, [clearNativeResultTimeout, onRefresh, setLaunchStatus]);

  useEffect(() => {
    if (timeoutIntent.current !== intent) {
      clearNativeResultTimeout();
      timeoutIntent.current = intent;
    }
    return clearNativeResultTimeout;
  }, [clearNativeResultTimeout, intent]);

  const launchTerminal = async () => {
    const terminalAction = terminalActionForIntent(intent);
    if (terminalAction === null) {
      await onRefresh();
      return;
    }

    const status = await requestVaultCommand(terminalAction);
    setLaunchStatus(status);
    if (status !== "failed") {
      onTerminalLaunch();
    }
    if (status === "requesting") {
      clearNativeResultTimeout();
      nativeResultTimeout.current = scheduleNativeResultTimeout(intent, setLaunchState);
    }
  };

  return { launchStatus, launchTerminal };
}

async function requestVaultCommand(action: NativeVaultAction): Promise<"requesting" | "copied" | "failed"> {
  if (postNativeVaultCommand(action)) {
    return "requesting";
  }

  const copied = await copyVaultCommand(action);
  return copied ? "copied" : "failed";
}

async function copyVaultCommand(action: NativeVaultAction): Promise<boolean> {
  let copied = false;
  if (typeof navigator !== "undefined" && navigator.clipboard !== undefined) {
    try {
      await navigator.clipboard.writeText(vaultCommandText(action));
      copied = true;
    } catch {
      copied = false;
    }
  }
  return copied;
}

function scheduleNativeResultTimeout(intent: VaultDialogIntent, setLaunchState: (update: (current: { intent: VaultDialogIntent; status: VaultLaunchStatus }) => { intent: VaultDialogIntent; status: VaultLaunchStatus }) => void): number {
  return window.setTimeout(() => {
    setLaunchState((current) => current.intent === intent && current.status === "requesting" ? { ...current, status: "failed" } : current);
  }, 3000);
}

function clearScheduledTimeout(timeoutRef: { current: number | null }): void {
  if (timeoutRef.current !== null) {
    window.clearTimeout(timeoutRef.current);
    timeoutRef.current = null;
  }
}

function trapDialogFocus(event: KeyboardEvent, dialog: HTMLElement | null): void {
  if (event.key !== "Tab" || dialog === null) {
    return;
  }

  const focusable = [...dialog.querySelectorAll<HTMLButtonElement>("button:not([disabled])")];
  const first = focusable[0];
  const last = focusable.at(-1);
  if (first === undefined || last === undefined) {
    return;
  }
  const activeIndex = focusable.indexOf(document.activeElement as HTMLButtonElement);
  const targetIndex = dialogFocusTargetIndex(activeIndex, focusable.length, event.shiftKey);
  if (targetIndex !== null) {
    event.preventDefault();
    focusable[targetIndex]?.focus();
  }
}

export function dialogFocusTargetIndex(activeIndex: number, focusableCount: number, shiftKey: boolean): number | null {
  if (focusableCount === 0) return null;
  if (activeIndex < 0) return shiftKey ? focusableCount - 1 : 0;
  if (shiftKey && activeIndex === 0) return focusableCount - 1;
  if (!shiftKey && activeIndex === focusableCount - 1) return 0;
  return null;
}
