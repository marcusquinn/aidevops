import React, { useEffect, useState } from "react";
import type { GuiNavigationItem, GuiResponseEnvelope, GuiStatusData } from "../../gui-shared/src";
import { fetchStatus, mockedStatus } from "./status-client";

type ThemePreference = "system" | "light" | "dark";

function getSystemTheme(): "light" | "dark" {
  if (typeof window === "undefined") {
    return "light";
  }

  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function App() {
  const [status, setStatus] = useState<GuiResponseEnvelope<GuiStatusData>>(mockedStatus());
  const [warning, setWarning] = useState<string | null>("Using local fixture until the API responds.");
  const [activeSection, setActiveSection] = useState<GuiNavigationItem["id"]>("overview");
  const [themePreference, setThemePreference] = useState<ThemePreference>("system");
  const [systemTheme, setSystemTheme] = useState<"light" | "dark">("light");
  const resolvedTheme = themePreference === "system" ? systemTheme : themePreference;
  const update = status.data.update ?? {
    running_version: status.data.aidevops_version,
    installed_version: status.data.aidevops_version,
    restart_required: false,
    message: "The GUI app is using local read-only status data.",
  };

  useEffect(() => {
    const savedTheme = window.localStorage.getItem("aidevops-gui-theme");
    if (savedTheme === "system" || savedTheme === "light" || savedTheme === "dark") {
      setThemePreference(savedTheme);
    }

    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    const updateSystemTheme = () => setSystemTheme(getSystemTheme());
    updateSystemTheme();
    mediaQuery.addEventListener("change", updateSystemTheme);

    return () => mediaQuery.removeEventListener("change", updateSystemTheme);
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = resolvedTheme;
    document.documentElement.style.colorScheme = resolvedTheme;
    window.localStorage.setItem("aidevops-gui-theme", themePreference);
  }, [resolvedTheme, themePreference]);

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
      <header className="app-topbar" aria-label="App controls">
        <div className="window-controls" aria-hidden="true">
          <span className="traffic red" />
          <span className="traffic yellow" />
          <span className="traffic green" />
        </div>
        <div className="topbar-brand" aria-label="aidevops">
          <span className="terminal-mark small" aria-hidden="true">›_</span>
          <strong>aidevops</strong>
        </div>
        <div className="command-palette" aria-label="Read-only dashboard search placeholder">
          <span aria-hidden="true">⌘K</span>
          <input aria-label="Search dashboard" disabled placeholder="Search setup, repos, settings, capabilities" />
        </div>
        <div className="topbar-status">
          <span className="status-dot" aria-hidden="true" />
          <span>read-only</span>
        </div>
        <div className="theme-control compact" aria-label="Theme preference">
          {(["system", "light", "dark"] as const).map((theme) => (
            <button
              aria-pressed={themePreference === theme}
              className={themePreference === theme ? "theme-option active" : "theme-option"}
              key={theme}
              onClick={() => setThemePreference(theme)}
              type="button"
            >
              {theme}
            </button>
          ))}
        </div>
      </header>

      <div className="workspace">
        <aside className="sidebar" aria-label="Dashboard navigation">
          <div className="brand-mark" aria-label="aidevops">
            <span className="terminal-mark" aria-hidden="true">›_</span>
            <span>aidevops</span>
          </div>
          <p className="sidebar-kicker">Control library</p>
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
              Local setup, repos, settings, capabilities, and secret-reference health in one app-like surface.
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

        <aside className="detail-rail" aria-label="Dashboard details">
          <section className="rail-card now-card">
            <p className="eyebrow">Now viewing</p>
            <h2>{status.data.navigation.find((item) => item.id === activeSection)?.label ?? "Overview"}</h2>
            <p>{status.data.navigation.find((item) => item.id === activeSection)?.description}</p>
          </section>
          <section className="rail-card">
            <h3>Local mode</h3>
            <ul>
              <li><span>API</span><strong>{status.data.runtime.api}</strong></li>
              <li><span>Version</span><strong>{status.data.aidevops_version}</strong></li>
              <li><span>Theme</span><strong>{themePreference === "system" ? systemTheme : themePreference}</strong></li>
            </ul>
          </section>
          <section className="rail-card">
            <h3>Trust boundary</h3>
            <p>No writes, shell, exec, Cloudron control, pairing, or secret values.</p>
          </section>
        </aside>
      </div>

      <footer className="app-statusbar" aria-label="App status">
        <span>Local API: {status.data.runtime.api}</span>
        <span>Repos: {status.data.repos.total}</span>
        <span>Settings keys: {status.data.settings.key_count}</span>
        <span>Theme: {themePreference === "system" ? `system/${systemTheme}` : themePreference}</span>
      </footer>
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
