import type { GuiStatusData, GuiVaultCollectionSummary, GuiVaultStatusData } from "@aidevops/gui-shared";
import type { ReactElement } from "react";
import { text } from "./app-model";
import { type VaultDialogIntent, VaultPadlock, vaultActionLabel, vaultDialogIntentForStatus } from "./VaultBadges";

interface VaultAvailability {
  custodyDetail: string;
  custodyValue: string;
  readinessUnknown: boolean;
}

interface VaultSurfaceProps {
  onVaultRequest: (intent: VaultDialogIntent) => void;
  status: GuiStatusData;
}

export function VaultSurface({ onVaultRequest, status }: VaultSurfaceProps): ReactElement {
  const vault = status.vault;
  const availability = vaultAvailability(vault);

  return (
    <section className="surface-page vault-surface" aria-label={text.vault}>
      <VaultHero availability={availability} onVaultRequest={onVaultRequest} vault={vault} />
      <VaultNotice availability={availability} vault={vault} />
      <VaultFeatureGrid availability={availability} vault={vault} />
      <VaultSetupPanel availability={availability} onVaultRequest={onVaultRequest} vault={vault} />
      <VaultCollectionsPanel onVaultRequest={onVaultRequest} vault={vault} />
      <VaultDevicesPanel vault={vault} />
    </section>
  );
}

export function LockedVaultGate({ collection, label, onVaultRequest, vault }: {
  collection: GuiVaultCollectionSummary;
  label: string;
  onVaultRequest: (intent: VaultDialogIntent) => void;
  vault: GuiVaultStatusData;
}): ReactElement {
  const intent = vaultDialogIntentForStatus(vault);
  const copy = lockedGateCopy(intent, label, vault);

  return (
    <section className="panel vault-locked-gate" aria-label={copy.heading}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{collection.data_class}</p>
          <h2>{copy.heading}</h2>
          <p>{copy.summary}</p>
        </div>
        <VaultPadlock collection={collection} onActivate={onVaultRequest} vault={vault} />
      </div>
      <div className="notice compact-notice" role="note">{copy.detail}</div>
      <button className="secondary-action vault-cta" onClick={() => onVaultRequest(intent)} title={copy.detail} type="button">{vaultActionLabel(intent)}</button>
    </section>
  );
}

function VaultHero({ availability, onVaultRequest, vault }: { availability: VaultAvailability; onVaultRequest: (intent: VaultDialogIntent) => void; vault: GuiVaultStatusData }): ReactElement {
  const vaultCollection = vault.collections.find((collection) => collection.surface_ids.includes("vault")) ?? vault.collections[0];
  return (
    <div className="hero-panel vault-hero">
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{vault.value_policy}</p>
          <h2>{text.vault}</h2>
          <p>{text.vaultIntro}</p>
        </div>
        {vaultCollection ? <VaultPadlock collection={vaultCollection} onActivate={onVaultRequest} vault={vault} /> : null}
      </div>
      <ul aria-label="Vault readiness" className="vault-readiness-strip">
        {vaultReadiness(vault, availability.readinessUnknown).map((item) => <li key={item.label}><strong>{item.label}</strong>{item.value}</li>)}
      </ul>
    </div>
  );
}

function VaultNotice({ availability, vault }: { availability: VaultAvailability; vault: GuiVaultStatusData }): ReactElement {
  const notice = vaultNoticeCopy(vault, availability.readinessUnknown);
  return <div className={`notice compact-notice${notice.warning ? " warning-notice" : ""}`} role="note">{notice.detail}</div>;
}

function VaultFeatureGrid({ availability, vault }: { availability: VaultAvailability; vault: GuiVaultStatusData }): ReactElement {
  return (
    <div className="vault-card-grid">
      {vaultFeatureCards(vault, availability).map((card) => <VaultFeatureCard detail={card.detail} key={card.label} label={card.label} value={card.value} />)}
    </div>
  );
}

function VaultFeatureCard({ detail, label, value }: { detail: string; label: string; value: string }): ReactElement {
  return <article className="vault-feature-card"><span>{label}</span><strong>{value}</strong><small>{detail}</small></article>;
}

function VaultSetupPanel({ availability, onVaultRequest, vault }: { availability: VaultAvailability; onVaultRequest: (intent: VaultDialogIntent) => void; vault: GuiVaultStatusData }): ReactElement {
  const intent = vaultDialogIntentForStatus(vault);
  const detail = availability.readinessUnknown ? availability.custodyDetail : vault.setup_hint;
  return (
    <section className="panel vault-setup-panel" aria-label={text.vaultSetup}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.vaultSetup}</p>
          <h2>{vaultSetupHeading(vault, availability.readinessUnknown)}</h2>
          <p>{detail}</p>
        </div>
        <button className="secondary-action vault-cta" onClick={() => onVaultRequest(intent)} title={availability.readinessUnknown ? availability.custodyDetail : vault.unlock_hint} type="button">{vaultActionLabel(intent)}</button>
      </div>
      {availability.readinessUnknown ? <VaultUnavailableSetupNotice vault={vault} /> : <VaultSetupSteps unlockHint={vault.unlock_hint} />}
    </section>
  );
}

function VaultUnavailableSetupNotice({ vault }: { vault: GuiVaultStatusData }): ReactElement {
  const detail = vault.status === "corrupted"
    ? "Use recovery guidance only. Preserve the current Vault directory and do not run initialization commands."
    : "Retry authoritative status before following setup or unlock instructions.";
  return <p className="empty-state">{detail}</p>;
}

function VaultSetupSteps({ unlockHint }: { unlockHint: string }): ReactElement {
  return (
    <>
      <ol className="vault-step-list">
        <li>Initialize locally with the hidden-prompt helper.</li>
        <li>Verify the harmless restart test before migrating real data.</li>
        <li>Keep passphrases, recovery material, and private keys out of chat, arguments, environment variables, logs, issues, and fixtures.</li>
      </ol>
      <code>{unlockHint}</code>
    </>
  );
}

function VaultCollectionsPanel({ onVaultRequest, vault }: { onVaultRequest: (intent: VaultDialogIntent) => void; vault: GuiVaultStatusData }): ReactElement {
  return (
    <section className="panel" aria-label="Vault encrypted collections">
      <div className="section-heading">
        <p className="eyebrow">{text.vaultStatus}</p>
        <h2>Encrypted collections</h2>
        <p>{text.vaultCollectionIntro}</p>
      </div>
      <ul className="object-list vault-collection-list">
        {vault.collections.map((collection) => <VaultCollectionRow collection={collection} key={collection.id} onVaultRequest={onVaultRequest} vault={vault} />)}
      </ul>
    </section>
  );
}

function VaultCollectionRow({ collection, onVaultRequest, vault }: { collection: GuiVaultCollectionSummary; onVaultRequest: (intent: VaultDialogIntent) => void; vault: GuiVaultStatusData }): ReactElement {
  return (
    <li>
      <strong>{collection.label}</strong>
      <VaultPadlock collection={collection} compact onActivate={onVaultRequest} vault={vault} />
      <span>{collection.preview_policy}</span>
      <small>{collection.labels.join(", ")}</small>
      <small>{collection.surface_ids.join(", ")}</small>
    </li>
  );
}

function VaultDevicesPanel({ vault }: { vault: GuiVaultStatusData }): ReactElement {
  return (
    <section className="panel" aria-label="Vault devices and audit">
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.vaultDevices}</p>
          <h2>Devices, sync, messages, backups, and audit</h2>
          <p>These placeholders expose readiness and redacted metadata only. Git, object storage, messaging, SSH, VPNs, and VPS disks remain untrusted transports.</p>
        </div>
        <span className="count-pill">{vault.sync.transport_policy}</span>
      </div>
      <div className="vault-device-grid">
        {vault.devices.map((device) => (
          <article className="vault-device-card" key={device.id_ref}>
            <p className="eyebrow">{device.trust_state}</p>
            <h3>{device.label}</h3>
            <Detail label="device" value={device.id_ref} />
            <Detail label="last seen" value={device.last_seen} />
            <Detail label="audit head" value={device.audit_head_ref} />
          </article>
        ))}
      </div>
    </section>
  );
}

function Detail({ label, value }: { label: string; value: string }): ReactElement {
  return <span><small>{label}</small><strong>{value}</strong></span>;
}

function vaultAvailability(vault: GuiVaultStatusData): VaultAvailability {
  const readinessUnknown = vault.helper_status !== "available" || vault.status === "unknown" || vault.status === "corrupted";
  let custodyDetail = vault.unlock_hint;
  let custodyValue = vault.locked ? "locked" : "unlocked";
  if (readinessUnknown) {
    custodyDetail = "The local helper did not return authoritative lock metadata.";
    custodyValue = "unavailable";
  }
  if (vault.status === "corrupted") {
    custodyDetail = "Metadata is damaged. Preserve encrypted data and use the recovery guidance.";
    custodyValue = "recovery";
  }
  return { custodyDetail, custodyValue, readinessUnknown };
}

function vaultReadiness(vault: GuiVaultStatusData, readinessUnknown: boolean): Array<{ label: string; value: string }> {
  return [
    { label: "migration", value: migrationReadiness(vault, readinessUnknown) },
    { label: "setup", value: setupReadiness(vault, readinessUnknown) },
    { label: "restart test", value: restartReadiness(vault, readinessUnknown) },
    { label: "remote unlock", value: vault.readiness.remote_unlock_enabled ? "enabled" : "disabled" },
  ];
}

function migrationReadiness(vault: GuiVaultStatusData, readinessUnknown: boolean): string {
  return readinessUnknown ? "unknown" : vault.readiness.migration_allowed ? "ready" : "blocked";
}

function setupReadiness(vault: GuiVaultStatusData, readinessUnknown: boolean): string {
  let value = vault.setup_state === "migration-ready" ? "complete" : "in progress";
  if (vault.readiness.setup_required) value = "required";
  if (readinessUnknown) value = "unknown";
  return value;
}

function restartReadiness(vault: GuiVaultStatusData, readinessUnknown: boolean): string {
  let value = vault.setup_state === "migration-ready" ? "verified" : "pending";
  if (vault.readiness.restart_test_required) value = "required";
  if (vault.status === "uninitialized") value = "not started";
  if (readinessUnknown) value = "unknown";
  return value;
}

function vaultFeatureCards(vault: GuiVaultStatusData, availability: VaultAvailability): Array<{ detail: string; label: string; value: string }> {
  return [
    { label: text.vaultStatus, value: vault.status, detail: "Metadata-only lock state from the local helper." },
    { label: text.vaultSetup, value: vault.setup_state, detail: availability.readinessUnknown ? availability.custodyDetail : vault.setup_hint },
    { label: text.vaultLockUnlock, value: availability.custodyValue, detail: availability.custodyDetail },
    { label: text.vaultDevices, value: `${vault.devices.length} device`, detail: "Device trust metadata only; private keys are never exposed." },
    { label: text.vaultSync, value: vault.sync.status, detail: "Encrypted bundles and signed manifests over untrusted transports." },
    { label: text.vaultMessages, value: vault.secure_messages.status, detail: "Secure message placeholders keep payloads hidden while locked." },
    { label: text.vaultBackups, value: vault.backups.status, detail: "Encrypted backups and recovery flows are metadata-only here." },
    { label: text.vaultAudit, value: vault.audit.status, detail: `${vault.audit.event_count} redacted audit events; ${vault.audit.latest_event_ref}.` },
  ];
}

function vaultNoticeCopy(vault: GuiVaultStatusData, readinessUnknown: boolean): { detail: string; warning: boolean } {
  let detail = vault.locked
    ? `${text.vaultLockedPreview} ${vault.unlock_hint}`
    : "Vault is unlocked for this local session. Protected actions remain read-only until audited write routes are implemented.";
  let warning = false;
  if (readinessUnknown) {
    detail = "Vault lock state is unavailable. Setup and unlock guidance remains disabled until status is authoritative.";
    warning = true;
  }
  if (vault.status === "corrupted") {
    detail = "Vault metadata needs recovery. Preserve existing encrypted data and do not initialise over it.";
  }
  return { detail, warning };
}

function vaultSetupHeading(vault: GuiVaultStatusData, readinessUnknown: boolean): string {
  let heading = vault.readiness.setup_required ? "Setup required" : "Setup metadata";
  if (readinessUnknown) heading = "Setup status unavailable";
  if (vault.status === "corrupted") heading = "Recovery required";
  return heading;
}

function lockedGateCopy(intent: VaultDialogIntent, label: string, vault: GuiVaultStatusData): { detail: string; heading: string; summary: string } {
  let detail = `${text.vaultTooltip} ${vault.unlock_hint}`;
  let heading = `${label} is locked`;
  let summary: string = text.vaultLockedPreview;
  if (intent === "unavailable") {
    detail = "Protected content remains hidden until the local helper returns authoritative status.";
    heading = `${label} Vault status is unavailable`;
    summary = detail;
  }
  if (intent === "recover") {
    detail = "Protected content remains hidden while damaged Vault metadata is reviewed.";
    heading = `${label} needs Vault recovery`;
    summary = detail;
  }
  return { detail, heading, summary };
}
