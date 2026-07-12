export type NativeVaultAction = "init" | "unlock" | "lock";
export type NativeVaultResult = "presented" | "running" | "succeeded" | "failed" | "cancelled";

export function isNativeVaultResult(value: unknown): value is NativeVaultResult {
  return value === "presented" || value === "running" || value === "succeeded" || value === "failed" || value === "cancelled";
}

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
