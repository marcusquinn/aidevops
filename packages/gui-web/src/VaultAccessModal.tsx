import type { GuiVaultStatusData } from "@aidevops/gui-shared";
import { type ReactElement, type RefObject, useRef } from "react";
import type { IconType } from "react-icons";
import { FiAlertTriangle, FiCheckCircle, FiClipboard, FiLock, FiRefreshCw, FiShield, FiTerminal, FiUnlock } from "react-icons/fi";
import { terminalActionForIntent, useVaultCommandLaunch, useVaultDialogFocus, type VaultLaunchStatus } from "./useVaultAccessDialog";
import type { VaultDialogIntent } from "./VaultBadges";
import { vaultCommandText } from "./vault-command-bridge";

export { terminalActionForIntent } from "./useVaultAccessDialog";

interface VaultAccessModalProps {
  intent: VaultDialogIntent;
  onClose: () => void;
  onRefresh: () => Promise<void> | void;
  onTerminalLaunch: () => void;
  vault: GuiVaultStatusData;
}

export function VaultAccessModal({ intent, onClose, onRefresh, onTerminalLaunch, vault }: VaultAccessModalProps): ReactElement {
  const primaryActionRef = useRef<HTMLButtonElement | null>(null);
  const dialogRef = useRef<HTMLElement | null>(null);
  const content = dialogContentFactories[intent](vault);
  const terminalAction = terminalActionForIntent(intent);
  const { launchStatus, launchTerminal } = useVaultCommandLaunch({ intent, onRefresh, onTerminalLaunch });
  useVaultDialogFocus({ dialogRef, intent, onClose, primaryActionRef });

  return (
    <div className="vault-modal-backdrop">
      <section
        aria-describedby="vault-access-description"
        aria-labelledby="vault-access-title"
        aria-modal="true"
        className="vault-modal"
        ref={dialogRef}
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
          {/* biome-ignore lint/a11y/useSemanticElements: role=group preserves the existing grid element and requested accessible grouping. */}
          <div className="vault-modal-state-grid" aria-label="Current Vault metadata" role="group">
            <span><strong>Vault</strong>{vault.status}</span><span><strong>Setup</strong>{vault.setup_state}</span><span><strong>Helper</strong>{vault.helper_status}</span>
          </div>
          <VaultLaunchStatusMessage status={launchStatus} />
        </div>
        <VaultModalActions content={content} intent={intent} launchStatus={launchStatus} onClose={onClose} onRefresh={onRefresh} onTerminalLaunch={launchTerminal} primaryActionRef={primaryActionRef} />
        <p className="vault-modal-footnote">This dialog never requests or stores a passphrase. Secret input belongs only in the terminal helper's hidden local prompt.</p>
      </section>
    </div>
  );
}

interface DialogContent {
  action: string;
  detail: string;
  notice: string;
  title: string;
}

const dialogContentFactories: Record<VaultDialogIntent, (vault: GuiVaultStatusData) => DialogContent> = {
  lock: () => ({ action: "Lock Vault", detail: "Locking forgets in-memory keys and hides protected previews again.", notice: "The fixed native action does not receive browser data or secret material.", title: "Lock local Vault" }),
  recover: () => ({ action: "Refresh status", detail: "Vault metadata appears damaged. Preserve existing encrypted data and use direct CLI recovery guidance.", notice: "Do not initialise with --force or overwrite the existing Vault.", title: "Review Vault recovery" }),
  setup: () => ({ action: "Set up securely", detail: "Create this device's Vault in the native secure surface.", notice: "Save the new passphrase in a trusted password manager. aidevops cannot recover it.", title: "Set up Vault" }),
  unavailable: () => ({ action: "Retry status", detail: "Vault readiness is not authoritative, so setup and passphrase actions are disabled.", notice: "Check the local helper and crypto runtime, then retry. Existing encrypted data will not be reinitialised.", title: "Vault status unavailable" }),
  unlock: () => ({ action: "Unlock securely", detail: "Unlock the existing Vault with the passphrase you already saved.", notice: "Passphrase input remains in the native secure surface and never enters the web view.", title: "Unlock existing Vault" }),
};

const dialogIcons: Record<VaultDialogIntent, IconType> = {
  lock: FiLock,
  recover: FiAlertTriangle,
  setup: FiShield,
  unavailable: FiAlertTriangle,
  unlock: FiUnlock,
};

function dialogIcon(intent: VaultDialogIntent): ReactElement {
  const Icon = dialogIcons[intent];
  return <Icon />;
}

function VaultModalActions({ content, intent, launchStatus, onClose, onRefresh, onTerminalLaunch, primaryActionRef }: {
  content: DialogContent;
  intent: VaultDialogIntent;
  launchStatus: VaultLaunchStatus;
  onClose: () => void;
  onRefresh: () => Promise<void> | void;
  onTerminalLaunch: () => Promise<void>;
  primaryActionRef: RefObject<HTMLButtonElement | null>;
}): ReactElement {
  const retriesStatus = intent === "unavailable";
  const ActionIcon = retriesStatus ? FiRefreshCw : FiTerminal;
  const className = intent === "lock" || intent === "recover" ? "secondary-action" : "primary-action";
  const runAction = retriesStatus ? onRefresh : onTerminalLaunch;

  return (
    <footer className="vault-modal-actions">
      <button className="secondary-action" onClick={onClose} type="button">Close</button>
      <button className={className} data-vault-intent={intent} disabled={!retriesStatus && launchStatus === "requesting"} onClick={() => void runAction()} ref={primaryActionRef} type="button"><ActionIcon aria-hidden="true" /> {content.action}</button>
    </footer>
  );
}

const launchStatusPresentation: Partial<Record<VaultLaunchStatus, { Icon: IconType; className: string; role: "alert" | "status"; text: string }>> = {
  copied: { Icon: FiClipboard, className: "vault-valid", role: "status", text: "Command copied. Run it in your local terminal." },
  failed: { Icon: FiAlertTriangle, className: "vault-invalid", role: "alert", text: "Open a local terminal and run the displayed command." },
  opened: { Icon: FiCheckCircle, className: "vault-valid", role: "status", text: "Secure terminal opened. Return here after the command completes; status refreshes on focus." },
  succeeded: { Icon: FiCheckCircle, className: "vault-valid", role: "status", text: "Vault action completed securely." },
  cancelled: { Icon: FiAlertTriangle, className: "vault-invalid", role: "status", text: "Vault action cancelled and native buffers cleared." },
  requesting: { Icon: FiTerminal, className: "vault-valid", role: "status", text: "Requesting the secure local terminal…" },
};

function VaultLaunchStatusMessage({ status }: { status: VaultLaunchStatus }): ReactElement | null {
  const presentation = launchStatusPresentation[status];
  if (presentation === undefined) {
    return null;
  }

  const { Icon, className, role, text } = presentation;
  return <p className={className} role={role}><Icon aria-hidden="true" /> {text}</p>;
}
