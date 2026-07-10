export type NativeVaultAction = "init" | "unlock" | "lock" | "status" | "lost-passphrase";

interface WebKitVaultCommandWindow extends Window {
  webkit?: {
    messageHandlers?: {
      vaultCommand?: {
        postMessage: (action: NativeVaultAction) => void;
      };
    };
  };
}

export function postNativeVaultCommand(action: NativeVaultAction): boolean {
  if (typeof window === "undefined") return false;
  const handler = (window as WebKitVaultCommandWindow).webkit?.messageHandlers?.vaultCommand;
  if (handler === undefined) return false;
  try {
    handler.postMessage(action);
    return true;
  } catch {
    return false;
  }
}

export function vaultCommandText(action: NativeVaultAction): string {
  return `aidevops vault ${action}`;
}
