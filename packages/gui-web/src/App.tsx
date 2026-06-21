import React, { useEffect, useState } from "react";
import type { GuiNavigationItem, GuiResponseEnvelope, GuiStatusData } from "../../gui-shared/src";
import { fetchStatus, mockedStatus } from "./status-client";

export function App() {
  const [status, setStatus] = useState<GuiResponseEnvelope<GuiStatusData>>(mockedStatus());
  const [warning, setWarning] = useState<string | null>("Using local fixture until the API responds.");
  const [activeSection, setActiveSection] = useState<GuiNavigationItem["id"]>("overview");
  const update = status.data.update ?? {
    running_version: status.data.aidevops_version,
    installed_version: status.data.aidevops_version,
    restart_required: false,
    message: "The GUI app is using local read-only status data.",
  };

  useEffect(() => {
    fetchStatus()
      .then((nextStatus) => {
        setStatus(nextStatus);
        setWarning(null);
      })
      .catch(() => {
        setWarning("API unavailable; showing read-only fixture data.");
      });
  }, []);

  return (
    <main className="app-shell">
      <aside className="sidebar" aria-label="Dashboard navigation">
        <div className="brand-mark">aidevops</div>
        <nav>
          {status.data.navigation.map((item) => (
            <button
              aria-current={activeSection === item.id ? "page" : undefined}
              className={activeSection === item.id ? "nav-item active" : "nav-item"}
              key={item.id}
              onClick={() => setActiveSection(item.id)}
              type="button"
            >
              <span>{item.label}</span>
              <small>{item.description}</small>
            </button>
          ))}
        </nav>
      </aside>

      <section className="content" aria-label="aidevops dashboard">
        <header className="hero">
          <p className="eyebrow">Read-only local dashboard</p>
          <h1>aidevops control plane</h1>
          <p className="lede">
            Local setup, repos, settings, capabilities, and secret-reference health in one read-only surface.
          </p>
          {warning ? <p role="status">{warning}</p> : null}
          {update.restart_required ? (
            <p className="alert" role="alert">
              {update.message} Running {update.running_version}; installed {update.installed_version}.
            </p>
          ) : (
            <p className="notice" role="status">{update.message}</p>
          )}
        </header>

        {activeSection === "overview" ? <OverviewSection status={status.data} /> : null}
        {activeSection === "repos" ? <ReposSection status={status.data} /> : null}
        {activeSection === "settings" ? <SettingsSection status={status.data} /> : null}
        {activeSection === "capabilities" ? <CapabilitiesSection status={status.data} /> : null}
        {activeSection === "security" ? <SecuritySection status={status.data} /> : null}
      </section>
    </main>
  );
}

function OverviewSection({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Overview">
      <div className="card-grid">
        <MetricCard label="Version" value={status.aidevops_version} detail="Installed framework version" />
        <MetricCard label="API" value={status.runtime.api} detail="Local read-only API boundary" />
        <MetricCard label="Repos" value={String(status.repos.total)} detail={status.repos.health} />
        <MetricCard label="Settings keys" value={String(status.settings.key_count)} detail={status.settings.health} />
      </div>
      <h2>Path health</h2>
      <ul className="object-list">
        {status.paths.map((path) => (
          <li key={path.label}>
            <strong>{path.label}</strong>
            <span>{path.health}</span>
            <code>{path.path_ref}</code>
          </li>
        ))}
      </ul>
    </section>
  );
}

function ReposSection({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Repos">
      <h2>Repos</h2>
      <p>Read-only registry summary from <code>{status.repos.path_ref}</code>.</p>
      {status.repos.repos.length === 0 ? (
        <p className="empty-state">No repo registry entries are available yet.</p>
      ) : (
        <ul className="object-list">
          {status.repos.repos.map((repo) => (
            <li key={`${repo.platform}:${repo.slug}`}>
              <strong>{repo.name}</strong>
              <span>{repo.platform}</span>
              <small>{repo.slug}</small>
              <small>local path: {repo.local_path_status}</small>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function SettingsSection({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Settings">
      <h2>Settings</h2>
      <p>Values are intentionally not rendered; this view shows keys and file health only.</p>
      <dl className="inline-details">
        <dt>Path</dt>
        <dd><code>{status.settings.path_ref}</code></dd>
        <dt>Health</dt>
        <dd>{status.settings.health}</dd>
        <dt>Policy</dt>
        <dd>{status.settings.value_policy}</dd>
      </dl>
      {status.settings.keys.length === 0 ? (
        <p className="empty-state">No settings keys are available yet.</p>
      ) : (
        <ul className="tag-list">
          {status.settings.keys.map((key) => <li key={key}>{key}</li>)}
        </ul>
      )}
    </section>
  );
}

function CapabilitiesSection({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Capabilities">
      <h2>Capabilities</h2>
      <ul className="object-list">
        {status.capabilities.map((capability) => (
          <li key={capability.id}>
            <strong>{capability.label}</strong>
            <span>{capability.status}</span>
            <code>{capability.doc_ref}</code>
          </li>
        ))}
      </ul>
    </section>
  );
}

function SecuritySection({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Security">
      <h2>Security</h2>
      <p>Secret values, prefixes, suffixes, raw credential files, and arbitrary commands are not exposed.</p>
      <ul className="object-list">
        {status.secrets.map((secret) => (
          <li key={secret.name}>
            <strong>{secret.name}</strong>
            <span>{secret.status}</span>
          </li>
        ))}
      </ul>
      <p>{status.placeholders[0]}</p>
    </section>
  );
}

function MetricCard({ label, value, detail }: { label: string; value: string; detail: string }) {
  return (
    <article className="metric-card">
      <span>{label}</span>
      <strong>{value}</strong>
      <small>{detail}</small>
    </article>
  );
}
