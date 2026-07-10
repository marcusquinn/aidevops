/* jshint esversion: 11 */
import { useState } from "react";
import type { GuiAiAppSummary, GuiLocalRepoSetupSummary, GuiSetupTargetSummary, GuiStatusData, GuiVaultCollectionSummary, GuiVaultStatusData } from "../../gui-shared/src";
import { plannedHomes, text } from "./app-model";
import { FileExplorerSurface } from "./FileExplorerSurface";
import { PathActions } from "./PathActions";
import { type VaultDialogIntent, VaultPadlock, vaultActionLabel, vaultDialogIntentForStatus } from "./VaultBadges";

export { AiProvidersSurface } from "./AiProvidersSurface";
export { SecuritySurface } from "./SecuritySurface";

export function OverviewSurface({ status }: { status: GuiStatusData }) {
  const metrics = [
    { label: text.setup, value: status.update.restart_required ? "restart" : "current", detail: status.update.installed_version },
    { label: text.projects, value: String(status.repos.total), detail: status.repos.health },
    { label: text.config, value: String(status.settings.key_count), detail: status.settings.value_policy },
    { label: text.security, value: status.vault.unlocked ? String(status.secrets.length) : "hidden", detail: "secret references" },
  ];

  return (
    <section className="surface-page" aria-label="Overview">
      <div className="hero-panel compact-hero">
        <p className="eyebrow">{text.roadmapIntro}</p>
        <h2>{text.aidevops}</h2>
        <p>{text.repoDescription}</p>
      </div>
      <div className="metric-grid">
        {metrics.map((metric) => (
          <article className="metric-card" key={metric.label}>
            <span>{metric.label}</span>
            <strong>{metric.value}</strong>
            <small>{metric.detail}</small>
          </article>
        ))}
      </div>
      <section className="panel">
        <div className="section-heading">
          <p className="eyebrow">{text.plannedHomes}</p>
          <h2>{text.fileBrowser}</h2>
        </div>
        <div className="planned-home-grid">
          {plannedHomes.map((home) => (
            <article className="planned-home" key={home.area}>
              <span>{home.phase}</span>
              <strong>{home.area}</strong>
              <small>{home.home}</small>
            </article>
          ))}
        </div>
      </section>
      <section className="panel">
        <div className="section-heading">
          <p className="eyebrow">{text.path}</p>
          <h2>{text.localSetup}</h2>
        </div>
        <ul className="object-list">
          {status.paths.map((path) => (
            <li key={path.label}>
              <strong>{path.label}</strong>
              <span>{path.health}</span>
              <code>{path.path_ref}</code>
              <PathActions pathRef={path.path_ref} />
            </li>
          ))}
        </ul>
      </section>
      <SetupTargetsPanel status={status} />
      <AiAppsPanel status={status} />
    </section>
  );
}

export function ProjectsSurface({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label={text.projects}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.development}</p>
          <h2>{text.projects}</h2>
          <p>{status.repos.path_ref}</p>
        </div>
        <PathActions pathRef={status.repos.path_ref} />
      </div>
      {status.repos.repos.length === 0 ? (
        <p className="empty-state">{text.noProjectEntries}</p>
      ) : (
        <ul className="object-list">
          {status.repos.repos.map((repo) => (
            <li key={`${repo.platform}:${repo.slug}`}>
              <strong>{repo.name}</strong>
              <span>{repo.platform}</span>
              <small>{repo.slug}</small>
              <small>{repo.local_path_status}</small>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

export function VaultSurface({ onVaultRequest, status }: { onVaultRequest: (intent: VaultDialogIntent) => void; status: GuiStatusData }) {
  const vault = status.vault;
  const vaultCollection = vault.collections.find((collection) => collection.surface_ids.includes("vault")) ?? vault.collections[0];
  const readinessUnknown = vault.helper_status !== "available" || vault.status === "unknown" || vault.status === "corrupted";
  const custodyState = vault.status === "corrupted"
    ? { detail: "Metadata is damaged. Preserve encrypted data and use the recovery guidance.", value: "recovery" }
    : readinessUnknown
      ? { detail: "The local helper did not return authoritative lock metadata.", value: "unavailable" }
      : { detail: vault.unlock_hint, value: vault.locked ? "locked" : "unlocked" };
  const readiness = [
    { label: "migration", value: readinessUnknown ? "unknown" : vault.readiness.migration_allowed ? "ready" : "blocked" },
    { label: "setup", value: readinessUnknown ? "unknown" : vault.readiness.setup_required ? "required" : vault.setup_state === "migration-ready" ? "complete" : "in progress" },
    { label: "restart test", value: readinessUnknown ? "unknown" : vault.status === "uninitialized" ? "not started" : vault.readiness.restart_test_required ? "required" : vault.setup_state === "migration-ready" ? "verified" : "pending" },
    { label: "remote unlock", value: vault.readiness.remote_unlock_enabled ? "enabled" : "disabled" },
  ];
  const featureCards = [
    { label: text.vaultStatus, value: vault.status, detail: "Metadata-only lock state from the local helper." },
    { label: text.vaultSetup, value: vault.setup_state, detail: vault.setup_hint },
    { label: text.vaultLockUnlock, value: custodyState.value, detail: custodyState.detail },
    { label: text.vaultDevices, value: `${vault.devices.length} device`, detail: "Device trust metadata only; private keys are never exposed." },
    { label: text.vaultSync, value: vault.sync.status, detail: "Encrypted bundles and signed manifests over untrusted transports." },
    { label: text.vaultMessages, value: vault.secure_messages.status, detail: "Secure message placeholders keep payloads hidden while locked." },
    { label: text.vaultBackups, value: vault.backups.status, detail: "Encrypted backups and recovery flows are metadata-only here." },
    { label: text.vaultAudit, value: vault.audit.status, detail: `${vault.audit.event_count} redacted audit events; ${vault.audit.latest_event_ref}.` },
  ];

  return (
    <section className="surface-page vault-surface" aria-label={text.vault}>
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
          {readiness.map((item) => <li key={item.label}><strong>{item.label}</strong>{item.value}</li>)}
        </ul>
      </div>
      {vault.status === "corrupted" ? (
        <div className="notice compact-notice warning-notice" role="note">
          Vault metadata needs recovery. Preserve existing encrypted data and do not initialise over it.
        </div>
      ) : readinessUnknown ? (
        <div className="notice compact-notice warning-notice" role="note">
          Vault lock state is unavailable. Setup and unlock guidance remains disabled until status is authoritative.
        </div>
      ) : vault.locked ? (
        <div className="notice compact-notice" role="note">
          {text.vaultLockedPreview} {vault.unlock_hint}
        </div>
      ) : (
        <div className="notice compact-notice" role="note">
          Vault is unlocked for this local session. Protected actions remain read-only until audited write routes are implemented.
        </div>
      )}
      <div className="vault-card-grid">
        {featureCards.map((card) => <VaultFeatureCard detail={card.detail} key={card.label} label={card.label} value={card.value} />)}
      </div>
      <section className="panel vault-setup-panel" aria-label={text.vaultSetup}>
        <div className="section-heading split-heading">
          <div>
            <p className="eyebrow">{text.vaultSetup}</p>
            <h2>{vault.status === "corrupted" ? "Recovery required" : readinessUnknown ? "Setup status unavailable" : vault.readiness.setup_required ? "Setup required" : "Setup metadata"}</h2>
            <p>{readinessUnknown ? custodyState.detail : vault.setup_hint}</p>
          </div>
          <button className="secondary-action vault-cta" onClick={() => onVaultRequest(vaultDialogIntentForStatus(vault))} title={vault.unlock_hint} type="button">{vaultActionLabel(vaultDialogIntentForStatus(vault))}</button>
        </div>
        {readinessUnknown ? (
          <p className="empty-state">{vault.status === "corrupted" ? "Use recovery guidance only. Preserve the current Vault directory and do not run initialization commands." : "Retry authoritative status before following setup or unlock instructions."}</p>
        ) : (
          <>
            <ol className="vault-step-list">
              <li>Initialize locally with the hidden-prompt helper.</li>
              <li>Verify the harmless restart test before migrating real data.</li>
              <li>Keep passphrases, recovery material, and private keys out of chat, arguments, environment variables, logs, issues, and fixtures.</li>
            </ol>
            <code>{vault.unlock_hint}</code>
          </>
        )}
      </section>
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
    </section>
  );
}

export function LockedVaultGate({ collection, label, onVaultRequest, vault }: {
  collection: GuiVaultCollectionSummary;
  label: string;
  onVaultRequest: (intent: VaultDialogIntent) => void;
  vault: GuiVaultStatusData;
}) {
  return (
    <section className="panel vault-locked-gate" aria-label={`${label} locked by Vault`}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{collection.data_class}</p>
          <h2>{label} is locked</h2>
          <p>{text.vaultLockedPreview}</p>
        </div>
        <VaultPadlock collection={collection} onActivate={onVaultRequest} vault={vault} />
      </div>
      <div className="notice compact-notice" role="note">
        {text.vaultTooltip} {vault.unlock_hint}
      </div>
      <button className="secondary-action vault-cta" onClick={() => onVaultRequest(vaultDialogIntentForStatus(vault))} title={vault.unlock_hint} type="button">{vaultActionLabel(vaultDialogIntentForStatus(vault))}</button>
    </section>
  );
}

function VaultFeatureCard({ detail, label, value }: { detail: string; label: string; value: string }) {
  return (
    <article className="vault-feature-card">
      <span>{label}</span>
      <strong>{value}</strong>
      <small>{detail}</small>
    </article>
  );
}

function VaultCollectionRow({ collection, onVaultRequest, vault }: { collection: GuiVaultCollectionSummary; onVaultRequest: (intent: VaultDialogIntent) => void; vault: GuiVaultStatusData }) {
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

export function LocalReposSurface({ status }: { status: GuiStatusData }) {
  const [activeTab, setActiveTab] = useState<"setup" | "files">("setup");

  return (
    <section className="surface-page local-repos-surface" aria-label={text.localRepos}>
      <nav className="pill-tabs" aria-label="Local Repos views">
        <button aria-pressed={activeTab === "setup"} className={activeTab === "setup" ? "active" : ""} onClick={() => setActiveTab("setup")} type="button">
          {text.setup}
        </button>
        <button aria-pressed={activeTab === "files"} className={activeTab === "files" ? "active" : ""} onClick={() => setActiveTab("files")} type="button">
          File Explorer
        </button>
      </nav>
      {activeTab === "setup" ? <LocalReposSetupPanel status={status} /> : <FileExplorerSurface rootId="git" />}
    </section>
  );
}

function LocalReposSetupPanel({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel repo-setup-panel" aria-label="Local repo setup">
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{status.local_repos.path_ref}</p>
          <h2>{text.setup}</h2>
          <p>{text.localReposSetupIntro}</p>
        </div>
        <span className="count-pill">{status.local_repos.total} repos</span>
      </div>
      <div className="repo-summary-strip">
        <span>{status.local_repos.health}</span>
        <span>{status.local_repos.excluded_worktrees} worktrees excluded</span>
        <span>repos.json: {status.repos.health}</span>
      </div>
      {status.local_repos.repos.length === 0 ? (
        <p className="empty-state">No canonical local repo folders were discovered.</p>
      ) : (
        <div className="repo-card-grid">
          {status.local_repos.repos.map((repo) => <LocalRepoCard key={repo.path_ref} repo={repo} />)}
        </div>
      )}
    </section>
  );
}

function LocalRepoCard({ repo }: { repo: GuiLocalRepoSetupSummary }) {
  const pulseLabel = repo.pulse === null ? "not registered" : repo.pulse ? "included" : "excluded";

  return (
    <article className="repo-setup-card">
      <header>
        <div>
          <h3>{repo.name}</h3>
          <code>{repo.path_ref}</code>
        </div>
        <PathActions pathRef={repo.path_ref} />
      </header>
      <div className="repo-card-meta">
        <Detail label="aidevops init" value={repo.aidevops_version} />
        <Detail label="default branch" value={repo.default_branch} />
        <Detail label="init scope" value={repo.init_scope} />
        <Detail label="knowledge" value={repo.knowledge} />
        <Detail label="priority" value={repo.priority} />
        <Detail label="interface" value={repo.has_interface === null ? "unknown" : repo.has_interface ? "yes" : "no"} />
      </div>
      <div className="repo-remotes">
        <span>Remote copy paths</span>
        {repo.remotes.length === 0 ? <small>none configured</small> : repo.remotes.map((remote) => <code key={`${remote.name}:${remote.url_ref}`}>{remote.name}: {remote.url_ref}</code>)}
      </div>
      <div className="repo-card-footer">
        <label className="switch-control" title="Read-only preview; changing Pulse requires an audited repos.json write route.">
          <input checked={repo.pulse === true} disabled type="checkbox" />
          <span aria-hidden="true" />
          <strong>Pulse</strong>
        </label>
        <small>{pulseLabel}</small>
        <small>{repo.local_only ? "local only" : repo.registered ? "registered" : "unregistered"}</small>
      </div>
      {repo.features.length > 0 ? (
        <div className="tag-list repo-tags">
          {repo.features.slice(0, 6).map((feature) => <span key={feature}>{feature}</span>)}
        </div>
      ) : null}
    </article>
  );
}

function SetupTargetsPanel({ status }: { status: GuiStatusData }) {
  const needsUpdate = status.setup_targets.filter((target) => target.needs_update).length;

  return (
    <section className="panel setup-targets-panel" aria-label={text.setupTargets}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.localSetup}</p>
          <h2>{text.setupTargets}</h2>
          <p>{text.setupTargetsIntro}</p>
        </div>
        <span className="count-pill">{needsUpdate} need update</span>
      </div>
      {status.setup_targets.length === 0 ? (
        <p className="empty-state">No aidevops setup targets were reported.</p>
      ) : (
        <div className="setup-card-grid">
          {status.setup_targets.map((target) => <SetupTargetCard key={target.path_ref} target={target} />)}
        </div>
      )}
    </section>
  );
}

function SetupTargetCard({ target }: { target: GuiSetupTargetSummary }) {
  return (
    <article className="setup-target-card">
      <header>
        <div>
          <p className="eyebrow">{target.health}</p>
          <h3>{target.label}</h3>
        </div>
        <span className={target.needs_update ? "status-pill warn" : "status-pill"}>{target.needs_update ? "update" : "current"}</span>
      </header>
      <p>{target.purpose}</p>
      <div className="repo-card-meta">
        <Detail label="installed" value={target.installed_version} />
        <Detail label="latest" value={target.latest_version} />
      </div>
      <div className="setup-path-row">
        <code>{target.path_ref}</code>
        <MaybePathActions pathRef={target.path_ref} />
      </div>
    </article>
  );
}

function AiAppsPanel({ status }: { status: GuiStatusData }) {
  const foundApps = status.ai_apps.filter((app) => app.status === "found").length;

  return (
    <section className="panel ai-apps-panel" aria-label={text.aiApps}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.localSetup}</p>
          <h2>{text.aiApps}</h2>
          <p>{text.aiAppsIntro}</p>
        </div>
        <span className="count-pill">{foundApps}/{status.ai_apps.length} found</span>
      </div>
      {status.ai_apps.length === 0 ? (
        <p className="empty-state">No local AI app metadata was reported.</p>
      ) : (
        <div className="ai-app-grid">
          {status.ai_apps.map((app) => <AiAppCard app={app} key={app.name} />)}
        </div>
      )}
    </section>
  );
}

function AiAppCard({ app }: { app: GuiAiAppSummary }) {
  return (
    <article className="ai-app-card">
      <header>
        <div>
          <p className="eyebrow">{app.status}</p>
          <h3>{app.name}</h3>
        </div>
        <span className={app.needs_update ? "status-pill warn" : "status-pill"}>{app.needs_update ? "update" : "current"}</span>
      </header>
      <div className="repo-card-meta">
        <Detail label="app version" value={app.app_version} />
        <Detail label="aidevops" value={app.aidevops_version} />
        <Detail label="latest" value={app.latest_version} />
      </div>
      <div className="setup-path-list">
        <PathRow label="app" pathRef={app.app_path_ref} />
        <PathRow label="binary" pathRef={app.binary_path_ref} />
        <PathRow label="config" pathRef={app.config_path_ref} />
        <PathRow label="aidevops" pathRef={app.aidevops_target_path_ref} />
      </div>
    </article>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <span>
      <small>{label}</small>
      <strong>{value}</strong>
    </span>
  );
}

function PathRow({ label, pathRef }: { label: string; pathRef: string }) {
  return (
    <div className="setup-path-row">
      <small>{label}</small>
      <code>{pathRef}</code>
      <MaybePathActions pathRef={pathRef} />
    </div>
  );
}

function MaybePathActions({ pathRef }: { pathRef: string }) {
  return isActionablePathRef(pathRef) ? <PathActions pathRef={pathRef} /> : null;
}

function isActionablePathRef(pathRef: string): boolean {
  return pathRef.startsWith("~/") || pathRef.startsWith("/");
}

export function PlannedSurface({ detail, label, tourId }: { detail: string; label: string; tourId?: string }) {
  return (
    <section className="panel" aria-label={label} data-tour={tourId}>
      <div className="section-heading">
        <p className="eyebrow">{text.planned}</p>
        <h2>{label}</h2>
        <p>{detail}</p>
      </div>
      <p className="empty-state">{text.plannedNotice}</p>
    </section>
  );
}
