import { useEffect, useMemo, useState, type ReactElement } from "react";
import { FiAlertTriangle, FiCheckCircle, FiLock, FiShield, FiUnlock } from "react-icons/fi";
import type { GuiVaultStatusData } from "@aidevops/gui-shared";
import type { VaultDialogIntent } from "./VaultBadges";

export function VaultPassphraseModal({ intent, onClose, vault }: {
  intent: VaultDialogIntent;
  onClose: () => void;
  vault: GuiVaultStatusData;
}): ReactElement {
  const [step, setStep] = useState(0);
  const [passphrase, setPassphrase] = useState("");
  const [passphraseConfirm, setPassphraseConfirm] = useState("");
  const [unlockPassphrase, setUnlockPassphrase] = useState("");
  const [savedWarningAccepted, setSavedWarningAccepted] = useState(false);
  const setupMode = intent === "setup";
  const title = setupMode ? "Set Vault encryption passphrase" : intent === "unlock" ? "Unlock Vault" : "Lock Vault";
  const actionLabel = setupMode ? "Use passphrase and continue" : intent === "unlock" ? "Unlock Vault" : "Lock Vault";
  const setupPassphrasesMatch = passphrase.length > 0 && passphrase === passphraseConfirm;
  const finalPassphraseMatches = unlockPassphrase.length > 0 && unlockPassphrase === passphrase;
  const canContinue = useMemo(() => {
    if (!setupMode) {
      return intent === "lock" || unlockPassphrase.length > 0;
    }

    if (step === 0) {
      return setupPassphrasesMatch;
    }
    if (step === 1) {
      return savedWarningAccepted;
    }
    return finalPassphraseMatches;
  }, [finalPassphraseMatches, intent, savedWarningAccepted, setupMode, setupPassphrasesMatch, step, unlockPassphrase.length]);

  useEffect(() => {
    setStep(0);
    setPassphrase("");
    setPassphraseConfirm("");
    setUnlockPassphrase("");
    setSavedWarningAccepted(false);
  }, [intent]);

  const continueFlow = () => {
    if (setupMode && step < 2) {
      setStep((current) => current + 1);
      return;
    }

    onClose();
  };

  return (
    <div className="vault-modal-backdrop" role="presentation">
      <section
        aria-label={title}
        aria-modal="true"
        className="vault-modal"
        role="dialog"
      >
        <form
          onSubmit={(event) => {
            event.preventDefault();
            if (canContinue) {
              continueFlow();
            }
          }}
          style={{ display: "contents" }}
        >
          <header className="vault-modal-header">
            <span className="vault-modal-icon" aria-hidden="true">{intent === "lock" ? <FiLock /> : <FiUnlock />}</span>
            <div>
              <p className="eyebrow">aidevops Vault</p>
              <h2>{title}</h2>
            </div>
          </header>
          {setupMode ? <SetupStep accepted={savedWarningAccepted} confirm={passphraseConfirm} match={setupPassphrasesMatch} onAcceptChange={setSavedWarningAccepted} onConfirmChange={setPassphraseConfirm} onPassphraseChange={setPassphrase} onUnlockPassphraseChange={setUnlockPassphrase} passphrase={passphrase} step={step} unlockMatch={finalPassphraseMatches} unlockPassphrase={unlockPassphrase} /> : <UnlockStep intent={intent} onUnlockPassphraseChange={setUnlockPassphrase} unlockPassphrase={unlockPassphrase} vault={vault} />}
          <footer className="vault-modal-actions">
            <button className="secondary-action" onClick={onClose} type="button">Cancel</button>
            <button className="primary-action" disabled={!canContinue} type="submit">{setupMode && step < 2 ? "Continue" : actionLabel}</button>
          </footer>
          <p className="vault-modal-footnote">Passphrases stay in this local dialog state only and are never shown in logs, issues, command arguments, or AI chat.</p>
        </form>
      </section>
    </div>
  );
}

function SetupStep({ accepted, confirm, match, onAcceptChange, onConfirmChange, onPassphraseChange, onUnlockPassphraseChange, passphrase, step, unlockMatch, unlockPassphrase }: {
  accepted: boolean;
  confirm: string;
  match: boolean;
  onAcceptChange: (accepted: boolean) => void;
  onConfirmChange: (value: string) => void;
  onPassphraseChange: (value: string) => void;
  onUnlockPassphraseChange: (value: string) => void;
  passphrase: string;
  step: number;
  unlockMatch: boolean;
  unlockPassphrase: string;
}): ReactElement {
  if (step === 1) {
    return (
      <div className="vault-modal-body">
        <div className="notice warning-notice" role="alert"><FiAlertTriangle aria-hidden="true" /> Save this passphrase in a password manager now. aidevops cannot recover encrypted data if it is lost.</div>
        <label className="vault-confirm-check"><input checked={accepted} onChange={(event) => onAcceptChange(event.currentTarget.checked)} type="checkbox" /> I have saved the Vault passphrase in a password manager and understand recovery is not possible without it.</label>
      </div>
    );
  }

  if (step === 2) {
    return (
      <div className="vault-modal-body">
        <p>Final safety check: enter the newly saved passphrase once more before any confidential app data is encrypted.</p>
        <label className="vault-field"><span>Use saved passphrase</span><input autoComplete="current-password" onChange={(event) => onUnlockPassphraseChange(event.currentTarget.value)} type="password" value={unlockPassphrase} /></label>
        {unlockPassphrase.length > 0 ? <p className={unlockMatch ? "vault-valid" : "vault-invalid"}>{unlockMatch ? "Passphrase matches." : "Passphrase does not match the saved setup value."}</p> : null}
      </div>
    );
  }

  return (
    <div className="vault-modal-body">
      <p>Create the encryption passphrase for this local Vault. Use a long unique value generated by your password manager.</p>
      <label className="vault-field"><span>New passphrase</span><input autoComplete="new-password" autoFocus onChange={(event) => onPassphraseChange(event.currentTarget.value)} type="password" value={passphrase} /></label>
      <label className="vault-field"><span>Repeat passphrase</span><input autoComplete="new-password" onChange={(event) => onConfirmChange(event.currentTarget.value)} type="password" value={confirm} /></label>
      {confirm.length > 0 ? <p className={match ? "vault-valid" : "vault-invalid"}>{match ? "Passphrases match." : "Passphrases must match before continuing."}</p> : null}
    </div>
  );
}

function UnlockStep({ intent, onUnlockPassphraseChange, unlockPassphrase, vault }: {
  intent: VaultDialogIntent;
  onUnlockPassphraseChange: (value: string) => void;
  unlockPassphrase: string;
  vault: GuiVaultStatusData;
}): ReactElement {
  if (intent === "lock") {
    return <div className="vault-modal-body"><p><FiLock aria-hidden="true" /> Locking forgets in-memory keys for this local session. Protected previews will be hidden again.</p></div>;
  }

  return (
    <div className="vault-modal-body">
      <p><FiShield aria-hidden="true" /> Enter your Vault passphrase to unlock protected previews and write actions for this local session.</p>
      <label className="vault-field"><span>Vault passphrase</span><input autoComplete="current-password" autoFocus onChange={(event) => onUnlockPassphraseChange(event.currentTarget.value)} type="password" value={unlockPassphrase} /></label>
      <div className="notice compact-notice" role="note"><FiCheckCircle aria-hidden="true" /> {vault.unlock_hint}</div>
    </div>
  );
}
