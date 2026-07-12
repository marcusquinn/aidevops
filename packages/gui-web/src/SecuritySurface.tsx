import type { GuiSecretReference, GuiStatusData, GuiVaultStatusData } from "@aidevops/gui-shared";
import { type ReactElement, useMemo, useState } from "react";
import { FiActivity, FiAlertTriangle, FiCheckCircle, FiKey, FiLink, FiLock, FiSearch, FiShield, FiTerminal } from "react-icons/fi";
import { type VaultDialogIntent, vaultActionLabel, vaultDialogIntentForStatus } from "./VaultBadges";

type SecretFilter = "all" | "configured" | "attention";

export function SecuritySurface({ onVaultRequest, status }: {
  onVaultRequest: (intent: VaultDialogIntent) => void;
  status: GuiStatusData;
}): ReactElement {
  const [filter, setFilter] = useState<SecretFilter>("all");
  const [query, setQuery] = useState("");
  const vault = status.vault;
  const intent = vaultDialogIntentForStatus(vault);
  const configured = status.secrets.filter((secret) => secret.status === "configured").length;
  const needsAttention = status.secrets.length - configured;
  const hiddenCount = vault.unlocked ? undefined : "Hidden";
  const filteredSecrets = useMemo(
    () => status.secrets.filter((secret) => secretMatches(secret, filter, query)),
    [filter, query, status.secrets],
  );

  return (
    <section className="surface-page secrets-surface" aria-label="Secrets">
      <div className="hero-panel secrets-hero">
        <div className="section-heading split-heading">
          <div>
            <p className="eyebrow">Secret references · metadata only</p>
            <h2>Secrets</h2>
            <p>Understand credential readiness and dependencies without exposing, copying, or sending secret values anywhere.</p>
          </div>
          <div className="secrets-hero-actions">
            <span className={`secrets-state-badge ${vaultStateTone(vault)}`}><VaultStateIcon vault={vault} /> {vaultStateLabel(vault)}</span>
            <button className={intent === "setup" || intent === "unlock" ? "primary-action" : "secondary-action"} onClick={() => onVaultRequest(intent)} type="button">{vaultActionLabel(intent)}</button>
          </div>
        </div>
        <div className="secrets-boundary" role="note">
          <FiShield aria-hidden="true" />
          <div><strong>Values stay out of the interface.</strong><span>Only reference names and non-sensitive health metadata become visible after local Vault unlock. Values are never returned, rendered, copied, exported, logged, or sent to AI.</span></div>
        </div>
      </div>

      {/* biome-ignore lint/a11y/useSemanticElements: role=group preserves the existing grid element and requested accessible grouping. */}
      <div className="secrets-metric-grid" aria-label="Secrets summary" role="group">
        <SecretMetric detail={vault.unlocked ? "metadata records" : "visible after local unlock"} icon={<FiKey />} label="References" value={hiddenCount ?? String(status.secrets.length)} />
        <SecretMetric detail={vault.unlocked ? "ready for dependent tools" : "visible after local unlock"} icon={<FiCheckCircle />} label="Configured" value={hiddenCount ?? String(configured)} />
        <SecretMetric detail={vault.unlocked ? "missing or not yet checked" : "visible after local unlock"} icon={<FiAlertTriangle />} label="Needs attention" value={hiddenCount ?? String(needsAttention)} />
        <SecretMetric detail="hidden local prompt only" icon={<FiTerminal />} label="Value custody" value="Write-only" />
        <SecretMetric detail={`credentials: ${status.secret_backends.credentials}`} icon={<FiActivity />} label="gopass backend" value={vault.unlocked ? status.secret_backends.gopass : "Hidden"} />
      </div>

      {vault.unlocked ? (
        <UnlockedSecrets filter={filter} filteredSecrets={filteredSecrets} onFilterChange={setFilter} onQueryChange={setQuery} query={query} total={status.secrets.length} />
      ) : (
        <LockedSecrets intent={intent} onVaultRequest={onVaultRequest} vault={vault} />
      )}
    </section>
  );
}

function LockedSecrets({ intent, onVaultRequest, vault }: { intent: VaultDialogIntent; onVaultRequest: (intent: VaultDialogIntent) => void; vault: GuiVaultStatusData }): ReactElement {
  const guidance = vaultGuidance(vault);
  return (
    <>
      <section className={`panel secrets-guidance ${vault.status === "corrupted" ? "is-error" : ""}`} aria-label="Vault access guidance">
        <div className="section-heading split-heading">
          <div>
            <p className="eyebrow">{guidance.eyebrow}</p>
            <h2>{guidance.title}</h2>
            <p>{guidance.detail}</p>
          </div>
          <button className="secondary-action" onClick={() => onVaultRequest(intent)} type="button">{vaultActionLabel(intent)}</button>
        </div>
        <div className="secrets-evidence-strip" role="status">
          <span><strong>Vault</strong>{vault.status}</span>
          <span><strong>Setup</strong>{vault.setup_state}</span>
          <span><strong>Helper</strong>{vault.helper_status}</span>
          <span><strong>Preview</strong>hidden</span>
        </div>
      </section>
      <section className="panel" aria-label="What Vault unlock enables">
        <div className="section-heading">
          <p className="eyebrow">Protected capabilities</p>
          <h2>What unlock enables</h2>
          <p>Unlock grants this local session access to reference metadata. Secret material remains behind secure storage helpers.</p>
        </div>
        <div className="secrets-capability-grid">
          <SecretCapability detail="Names and non-sensitive configured, missing, and unchecked health states." icon={<FiKey />} title="Reference inventory" />
          <SecretCapability detail="See which integrations, routines, and resources depend on each reference as adapters mature." icon={<FiLink />} title="Dependency awareness" />
          <SecretCapability detail="Run allowlisted checks and rotation handoffs without reveal or copy controls." icon={<FiActivity />} title="Validation and rotation" />
        </div>
      </section>
    </>
  );
}

function UnlockedSecrets({ filter, filteredSecrets, onFilterChange, onQueryChange, query, total }: {
  filter: SecretFilter;
  filteredSecrets: GuiSecretReference[];
  onFilterChange: (filter: SecretFilter) => void;
  onQueryChange: (query: string) => void;
  query: string;
  total: number;
}): ReactElement {
  return (
    <section className="panel secrets-inventory" aria-label="Secret reference inventory">
      <div className="section-heading split-heading">
        <div><p className="eyebrow">Unlocked for this local session</p><h2>Reference inventory</h2><p>Metadata can be reviewed; values remain unavailable to the browser.</p></div>
        <span className="count-pill">{filteredSecrets.length} of {total}</span>
      </div>
      <div className="secrets-toolbar">
        <label className="secrets-search"><FiSearch aria-hidden="true" /><span className="sr-only">Search references</span><input onChange={(event) => onQueryChange(event.currentTarget.value)} placeholder="Search reference names" type="search" value={query} /></label>
        {/* biome-ignore lint/a11y/useSemanticElements: role=group preserves the existing toolbar layout and requested accessible grouping. */}
        <div className="secrets-filters" aria-label="Filter references" role="group">
          {(["all", "configured", "attention"] as const).map((option) => <button aria-pressed={filter === option} key={option} onClick={() => onFilterChange(option)} type="button">{option === "attention" ? "Needs attention" : titleCase(option)}</button>)}
        </div>
      </div>
      {filteredSecrets.length === 0 ? <p className="empty-state">No secret references match this view.</p> : (
        <div className="secrets-table-wrap">
          <table className="secrets-reference-table">
            <thead><tr><th scope="col">Reference</th><th scope="col">Health</th><th scope="col">Value access</th><th scope="col">Management</th></tr></thead>
            <tbody>{filteredSecrets.map((secret) => <SecretRow key={secret.name} secret={secret} />)}</tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function SecretRow({ secret }: { secret: GuiSecretReference }): ReactElement {
  return (
    <tr>
      <td data-label="Reference"><strong>{secret.name}</strong></td>
      <td data-label="Health"><span className={`secret-health ${secret.status}`}>{secret.status}</span></td>
      <td data-label="Value access">Never displayed</td>
      <td data-label="Management"><span className="metadata-only-label"><FiTerminal aria-hidden="true" /> Secure helper</span></td>
    </tr>
  );
}

function SecretMetric({ detail, icon, label, value }: { detail: string; icon: ReactElement; label: string; value: string }): ReactElement {
  return <article className="secret-metric-card"><span className="secret-metric-icon" aria-hidden="true">{icon}</span><div><span>{label}</span><strong>{value}</strong><small>{detail}</small></div></article>;
}

function SecretCapability({ detail, icon, title }: { detail: string; icon: ReactElement; title: string }): ReactElement {
  return <article className="secret-capability-card"><span aria-hidden="true">{icon}</span><div><h3>{title}</h3><p>{detail}</p></div></article>;
}

function VaultStateIcon({ vault }: { vault: GuiVaultStatusData }): ReactElement {
  if (vault.unlocked) return <FiCheckCircle aria-hidden="true" />;
  if (vault.status === "unknown" || vault.status === "corrupted") return <FiAlertTriangle aria-hidden="true" />;
  return <FiLock aria-hidden="true" />;
}

function vaultStateLabel(vault: GuiVaultStatusData): string {
  if (vault.unlocked) return "Vault unlocked";
  if (vault.status === "locked") return "Vault locked";
  if (vault.status === "uninitialized") return "Vault not configured";
  if (vault.status === "corrupted") return "Recovery required";
  return "Status unavailable";
}

function vaultStateTone(vault: GuiVaultStatusData): string {
  if (vault.unlocked) return "success";
  if (vault.status === "corrupted") return "error";
  if (vault.status === "locked" || vault.status === "uninitialized") return "warning";
  return "unknown";
}

function vaultGuidance(vault: GuiVaultStatusData): { detail: string; eyebrow: string; title: string } {
  if (vault.status === "locked") return { eyebrow: "Local Vault", title: "Unlock protected metadata", detail: "Use the existing passphrase in the local hidden terminal prompt. The app will refresh when you return." };
  if (vault.status === "uninitialized") return { eyebrow: "First-use setup", title: "Create the local Vault", detail: "Initialise once in a local hidden prompt, save the passphrase in a trusted password manager, then complete the restart verification." };
  if (vault.status === "corrupted") return { eyebrow: "Recovery required", title: "Vault metadata needs attention", detail: "Do not initialise over existing data. Review the conservative recovery options before making changes." };
  return { eyebrow: "Status unavailable", title: "Vault readiness could not be verified", detail: "No setup or passphrase action will be offered until both local status probes return authoritative metadata." };
}

function secretMatches(secret: GuiSecretReference, filter: SecretFilter, query: string): boolean {
  const matchesQuery = secret.name.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase());
  if (!matchesQuery) return false;
  if (filter === "configured") return secret.status === "configured";
  if (filter === "attention") return secret.status !== "configured";
  return true;
}

function titleCase(value: string): string {
  return `${value.charAt(0).toLocaleUpperCase()}${value.slice(1)}`;
}
