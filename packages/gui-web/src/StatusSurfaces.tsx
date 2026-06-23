/* jshint esversion: 11 */
import { useState } from "react";
import type { GuiAiAppSummary, GuiLocalRepoSetupSummary, GuiOAuthProviderSummary, GuiSetupTargetSummary, GuiStatusData } from "../../gui-shared/src";
import { plannedHomes, text } from "./app-model";
import { FileExplorerSurface } from "./FileExplorerSurface";
import { PathActions } from "./PathActions";

export function OverviewSurface({ status }: { status: GuiStatusData }) {
  const metrics = [
    { label: text.setup, value: status.update.restart_required ? "restart" : "current", detail: status.update.installed_version },
    { label: text.projects, value: String(status.repos.total), detail: status.repos.health },
    { label: text.config, value: String(status.settings.key_count), detail: status.settings.value_policy },
    { label: text.security, value: String(status.secrets.length), detail: "secret references" },
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

export function SecuritySurface({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label={text.security}>
      <div className="section-heading">
        <p className="eyebrow">{text.readOnly}</p>
        <h2>{text.security}</h2>
        <p>{text.securityBoundary}</p>
      </div>
      <ul className="object-list">
        {status.secrets.map((secret) => (
          <li key={secret.name}>
            <strong>{secret.name}</strong>
            <span>{secret.status}</span>
          </li>
        ))}
      </ul>
    </section>
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

export function AiProvidersSurface({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel ai-providers-panel" aria-label={text.aiProviders}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{status.oauth_pool.path_ref}</p>
          <h2>{text.aiProviders}</h2>
          <p>{text.aiProvidersIntro}</p>
        </div>
        <span className="count-pill">{status.oauth_pool.value_policy}</span>
      </div>
      <div className="provider-grid">
        {status.oauth_pool.providers.map((provider) => <ProviderCard key={provider.provider} provider={provider} />)}
      </div>
    </section>
  );
}

function ProviderCard({ provider }: { provider: GuiOAuthProviderSummary }) {
  return (
    <article className="provider-card">
      <header>
        <div>
          <p className="eyebrow">{provider.configured ? "configured" : "not configured"}</p>
          <h3>{provider.provider}</h3>
        </div>
        <strong>{provider.available}/{provider.total}</strong>
      </header>
      <div className="repo-card-meta provider-metrics">
        <Detail label="active/idle" value={String(provider.active_or_idle)} />
        <Detail label="rate limited" value={String(provider.rate_limited)} />
        <Detail label="auth errors" value={String(provider.auth_errors)} />
        <Detail label="pending token" value={provider.pending_token ? "yes" : "no"} />
      </div>
      <fieldset className="provider-actions" aria-label={`${provider.provider} planned management controls`}>
        {['Add account', 'Rotate', 'Check', 'Reset cooldowns'].map((action) => <button disabled key={action} type="button">{action}</button>)}
      </fieldset>
      {provider.accounts.length === 0 ? (
        <p className="empty-state compact-empty">No accounts in this pool.</p>
      ) : (
        <ul className="provider-account-list">
          {provider.accounts.map((account) => (
            <li key={`${provider.provider}:${account.email_ref}`}>
              <strong>{account.email_ref}</strong>
              <span>{account.status}</span>
              <small>priority {account.priority ?? "default"}</small>
              <small>expires {account.expires_at}</small>
              {account.cooldown_until ? <small>cooldown {account.cooldown_until}</small> : null}
              <button disabled type="button">Manage</button>
            </li>
          ))}
        </ul>
      )}
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

export function PlannedSurface({ detail, label }: { detail: string; label: string }) {
  return (
    <section className="panel" aria-label={label}>
      <div className="section-heading">
        <p className="eyebrow">{text.planned}</p>
        <h2>{label}</h2>
        <p>{detail}</p>
      </div>
      <p className="empty-state">{text.plannedNotice}</p>
    </section>
  );
}
