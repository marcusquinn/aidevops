import { useEffect, useRef, useState, type ReactElement } from "react";
import { FiAlertTriangle, FiCheckCircle, FiClipboard, FiLock, FiRefreshCw, FiShield, FiTerminal, FiUnlock } from "react-icons/fi";
import type { GuiVaultStatusData } from "@aidevops/gui-shared";
import type { VaultDialogIntent } from "./VaultBadges";
import { type NativeVaultAction, postNativeVaultCommand, vaultCommandText } from "./vault-command-bridge";

export function VaultAccessModal({ intent, onClose, onRefresh, vault }: {
  intent: VaultDialogIntent;
  onClose: () => void;
  onRefresh: () => Promise<void> | void;
  vault: GuiVaultStatusData;
}): ReactElement {
  const [launchStatus, setLaunchStatus] = useState<"idle" | "opened" | "copied" | "failed">("idle");
  const primaryActionRef = useRef<HTMLButtonElement | null>(null);
  const content = dialogContent(intent, vault);
  const terminalAction = terminalActionForIntent(intent);

  useEffect(() => {
    setLaunchStatus("idle");
    primaryActionRef.current?.focus();
  }, [intent]);

  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose]);

  const launchTerminal = async () => {
    if (terminalAction === null) {
      await onRefresh();
      return;
    }
    if (postNativeVaultCommand(terminalAction)) {
      setLaunchStatus("opened");
      return;
    }
    if (typeof navigator !== "undefined" && navigator.clipboard !== undefined) {
      await navigator.clipboard.writeText(vaultCommandText(terminalAction));
      setLaunchStatus("copied");
      return;
    }
    setLaunchStatus("failed");
  };

  return (
    <div className="vault-modal-backdrop">
      <section
        aria-describedby="vault-access-description"
        aria-labelledby="vault-access-title"
        aria-modal="true"
        className="vault-modal"
        role="dialog"
      >
        <header className="vault-modal-header">
          <span className="vault-modal-icon" aria-hidden="true">{dialogIcon(intent)}</span>
          <div><p className="eyebrow">aidevops Vault</p><h2 id="vault-access-title">{content.title}</h2></div>
        </header>
        <div className="vault-modal-body">
          <p id="vault-access-description">{content.detail}</p>
          <div className={`notice compact-notice ${intent === "recover" || intent === "unavailable" ? "warning-notice" : ""}`} role="note">{content.notice}</div>
          {terminalAction === null ? null : <div className="vault-command-preview"><FiTerminal aria-hidden="true" /><code>{vaultCommandText(terminalAction)}</code></div>}
          <div className="vault-modal-state-grid" aria-label="Current Vault metadata">
            <span><strong>Vault</strong>{vault.status}</span><span><strong>Setup</strong>{vault.setup_state}</span><span><strong>Helper</strong>{vault.helper_status}</span>
          </div>
          {launchStatus === "opened" ? <p className="vault-valid" role="status"><FiCheckCircle aria-hidden="true" /> Secure terminal opened. Return here after the command completes; status refreshes on focus.</p> : null}
          {launchStatus === "copied" ? <p className="vault-valid" role="status"><FiClipboard aria-hidden="true" /> Command copied. Run it in your local terminal.</p> : null}
          {launchStatus === "failed" ? <p className="vault-invalid" role="alert"><FiAlertTriangle aria-hidden="true" /> Open a local terminal and run the displayed command.</p> : null}
        </div>
        <footer className="vault-modal-actions">
          <button className="secondary-action" onClick={onClose} type="button">Close</button>
          {intent === "unavailable" ? <button className="primary-action" onClick={() => void onRefresh()} ref={primaryActionRef} type="button"><FiRefreshCw aria-hidden="true" /> Retry status</button> : <button className={intent === "lock" || intent === "recover" ? "secondary-action" : "primary-action"} onClick={() => void launchTerminal()} ref={primaryActionRef} type="button"><FiTerminal aria-hidden="true" /> {content.action}</button>}
        </footer>
        <p className="vault-modal-footnote">This dialog never requests or stores a passphrase. Secret input belongs only in the terminal helper's hidden local prompt.</p>
      </section>
    </div>
  );
}

export function terminalActionForIntent(intent: VaultDialogIntent): NativeVaultAction | null {
  if (intent === "setup") return "init";
  if (intent === "unlock") return "unlock";
  if (intent === "lock") return "lock";
  if (intent === "recover") return "lost-passphrase";
  return null;
}

function dialogContent(intent: VaultDialogIntent, vault: GuiVaultStatusData): { action: string; detail: string; notice: string; title: string } {
  if (intent === "setup") return { action: "Open setup terminal", detail: "Create this device's Vault once through the secure local helper.", notice: "Save the new passphrase in a trusted password manager. aidevops cannot recover it.", title: "Set up Vault" };
  if (intent === "unlock") return { action: "Open secure terminal", detail: "Unlock the existing Vault with the passphrase you already saved.", notice: vault.unlock_hint, title: "Unlock existing Vault" };
  if (intent === "lock") return { action: "Open lock terminal", detail: "Locking forgets in-memory keys and hides protected previews again.", notice: "The fixed local command does not receive browser data or secret material.", title: "Lock local Vault" };
  if (intent === "recover") return { action: "Open recovery guidance", detail: "Vault metadata appears damaged. Preserve existing encrypted data and review conservative recovery options.", notice: "Do not initialise with --force or overwrite the existing Vault.", title: "Review Vault recovery" };
  return { action: "Retry status", detail: "Vault readiness is not authoritative, so setup and passphrase actions are disabled.", notice: "Check the local helper and crypto runtime, then retry. Existing encrypted data will not be reinitialised.", title: "Vault status unavailable" };
}

function dialogIcon(intent: VaultDialogIntent): ReactElement {
  if (intent === "lock") return <FiLock />;
  if (intent === "recover" || intent === "unavailable") return <FiAlertTriangle />;
  if (intent === "setup") return <FiShield />;
  return <FiUnlock />;
}
