/* jshint esversion: 11 */
import { useEffect, useState } from "react";
import type { GuiResponseEnvelope, GuiStatusData } from "../../gui-shared/src";
import { fetchStatus, mockedStatus } from "./status-client";

type ThemePreference = "system" | "light" | "dark";
type SurfaceId = "overview" | "repos" | "capabilities" | "routines" | "integrations" | "settings" | "security";

interface SurfaceNavItem {
  badge?: string;
  description: string;
  icon: string;
  id: SurfaceId;
  label: string;
}

interface SurfaceNavGroup {
  items: SurfaceNavItem[];
  label: string;
}

const text = {
  agentsAndHelpers: "Agents and helpers",
  appName: "aidevops",
  appShell: "App shell",
  api: "API",
  automation: "Automation",
  capabilities: "Agents",
  capabilityIntro: "Capability cards map AI DevOps agent and helper surfaces that can become guided workflows.",
  configuration: "Configuration",
  controlPlaneTitle: "Local control plane",
  dashboard: "Dashboard",
  filesystemRefs: "Filesystem and helper references are displayed as safe path labels, not secret material.",
  guarded: "Guarded",
  guardrailIntro: "Secret values, prefixes, suffixes, raw credential files, and arbitrary commands are not exposed.",
  guardrails: "Guardrails",
  health: "Health",
  helperAvailability: "Helper availability",
  installedVersion: "installed",
  integrations: "Integrations",
  integrationsDetail: "Provider, infrastructure, and service status belongs here without control actions.",
  inventory: "Inventory",
  keysOnly: "keys only",
  localOnly: "Local only",
  localPathLabel: "local path:",
  localReadOnly: "Local read-only",
  localSession: "Local session",
  localSetupHealth: "Local setup health",
  noProjectEntries: "No project registry entries are available yet.",
  noSettingsKeys: "No settings keys are available yet.",
  operate: "Operate",
  overview: "Overview",
  path: "Path",
  plannedAdapter: "Planned adapter",
  plannedPlaceholder: "Read-only placeholder. No setup action is available from this preview.",
  policy: "Policy",
  projects: "Projects",
  readOnlyApi: "Read-only API",
  registrySummaryPrefix: "Read-only registry summary from ",
  registrySummarySuffix: ".",
  routineDetail: "Routine setup and scheduling status will appear here as read-only adapters land.",
  routines: "Routines",
  runningVersion: "Running",
  searchPlaceholder: "Search setup, projects, agents",
  security: "Security",
  sessionInitials: "AD",
  settings: "Settings",
  settingsIntro: "Values are intentionally not rendered; this view shows keys and file health only.",
  setup: "Setup",
  setupCardTitle: "Local control plane",
  setupCardText: "Observe setup, repos, agents, routines, integrations, settings, and security posture without exposing secrets or running arbitrary commands.",
  signals: "Signals",
  version: "Version",
  trustBoundary: "No write routes, no shell bridge, no hosted app control, no pairing, no secret values.",
  workspaceLabel: "aidevops workspace",
  navigationLabel: "aidevops navigation",
} as const;

const navGroups: SurfaceNavGroup[] = [
  {
    label: text.operate,
    items: [
      { id: "overview", label: text.dashboard, description: "Setup and status overview", icon: "⌘" },
      { id: "repos", label: text.projects, description: "Repository registry", icon: "◇" },
      { id: "capabilities", label: text.capabilities, description: "Agents and helpers", icon: "✦" },
      { id: "routines", label: text.routines, description: "Scheduled workflows", icon: "◷", badge: "planned" },
    ],
  },
  {
    label: text.configuration,
    items: [
      { id: "settings", label: text.settings, description: "Config keys only", icon: "⚙" },
      { id: "integrations", label: text.integrations, description: "Providers and services", icon: "⬡", badge: "planned" },
      { id: "security", label: text.security, description: "Secrets and guardrails", icon: "◈" },
    ],
  },
];

function getSystemTheme(): "light" | "dark" {
  if (typeof window === "undefined") {
    return "light";
  }

  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function findSurface(id: SurfaceId): SurfaceNavItem {
  for (const group of navGroups) {
    for (const item of group.items) {
      if (item.id === id) {
        return item;
      }
    }
  }

  return navGroups[0].items[0];
}

function formatLocalPathStatus(localPathStatus: string): string {
  return `${text.localPathLabel} ${localPathStatus}`;
}

function formatRestartNotice(update: GuiStatusData["update"]): string {
  return `${update.message} ${text.runningVersion} ${update.running_version}; ${text.installedVersion} ${update.installed_version}.`;
}

function formatSessionMeta(resolvedTheme: "light" | "dark"): string {
  return `${text.guarded} · ${resolvedTheme}`;
}

export function App() {
  const [status, setStatus] = useState<GuiResponseEnvelope<GuiStatusData>>(mockedStatus());
  const [warning, setWarning] = useState<string | null>("Using local fixture until the API responds.");
  const [activeSurface, setActiveSurface] = useState<SurfaceId>("overview");
  const [themePreference, setThemePreference] = useState<ThemePreference>("system");
  const [systemTheme, setSystemTheme] = useState<"light" | "dark">("light");
  const resolvedTheme = themePreference === "system" ? systemTheme : themePreference;
  const update = status.data.update;
  const activeItem = findSurface(activeSurface);

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
      <aside className="app-sidebar" aria-label={text.navigationLabel}>
        <SidebarHeader status={status.data} />
        <nav className="sidebar-content">
          {navGroups.map((group) => (
            <section className="sidebar-group" key={group.label}>
              <h2>{group.label}</h2>
              <ul>
                {group.items.map((item) => (
                  <li key={item.id}>
                    <button
                      aria-current={activeSurface === item.id ? "page" : undefined}
                      className={activeSurface === item.id ? "surface-link active" : "surface-link"}
                      onClick={() => setActiveSurface(item.id)}
                      type="button"
                    >
                      <span className="surface-icon" aria-hidden="true">{item.icon}</span>
                      <span className="surface-copy">
                        <strong>{item.label}</strong>
                        <small>{item.description}</small>
                      </span>
                      {item.badge ? <em>{item.badge}</em> : null}
                    </button>
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </nav>
        <SidebarFooter resolvedTheme={resolvedTheme} setThemePreference={setThemePreference} themePreference={themePreference} />
      </aside>

      <section className="app-inset" aria-label={text.workspaceLabel}>
        <header className="workspace-header">
          <div className="header-title">
            <button className="sidebar-trigger" type="button" aria-label="Sidebar is fixed in this preview">☰</button>
            <div>
              <p>{text.appShell}</p>
              <h1>{activeItem.label}</h1>
            </div>
          </div>
          <div className="header-actions">
            <label className="workspace-search">
              <span>⌘K</span>
              <input disabled placeholder={text.searchPlaceholder} />
            </label>
            <span className="read-only-pill"><i />{text.localReadOnly}</span>
          </div>
        </header>

        <div className="workspace-scroll">
          {warning ? <p className="notice" role="status">{warning}</p> : null}
          {update.restart_required ? (
            <p className="alert" role="alert">
              {formatRestartNotice(update)}
            </p>
          ) : (
            <p className="notice" role="status">{update.message}</p>
          )}

          {activeSurface === "overview" ? <OverviewSurface status={status.data} /> : null}
          {activeSurface === "repos" ? <ProjectsSurface status={status.data} /> : null}
          {activeSurface === "capabilities" ? <AgentsSurface status={status.data} /> : null}
          {activeSurface === "routines" ? <PlannedSurface label={text.routines} detail={text.routineDetail} /> : null}
          {activeSurface === "integrations" ? <PlannedSurface label={text.integrations} detail={text.integrationsDetail} /> : null}
          {activeSurface === "settings" ? <SettingsSurface status={status.data} /> : null}
          {activeSurface === "security" ? <SecuritySurface status={status.data} /> : null}
        </div>
      </section>
    </main>
  );
}

function SidebarHeader({ status }: { status: GuiStatusData }) {
  return (
    <header className="sidebar-header">
      <div className="brand-lockup">
        <span className="terminal-mark" aria-hidden="true">›_</span>
        <div>
          <strong>{text.appName}</strong>
          <small>{text.readOnlyApi}</small>
        </div>
      </div>
      <section className="setup-card" aria-label="Local setup summary">
        <span>{text.localOnly}</span>
        <h2>{text.setupCardTitle}</h2>
        <p>{text.setupCardText}</p>
        <dl>
          <div><dt>{text.version}</dt><dd>{status.aidevops_version}</dd></div>
          <div><dt>{text.api}</dt><dd>{status.runtime.api}</dd></div>
        </dl>
      </section>
    </header>
  );
}

function SidebarFooter({ resolvedTheme, setThemePreference, themePreference }: {
  resolvedTheme: "light" | "dark";
  setThemePreference: (theme: ThemePreference) => void;
  themePreference: ThemePreference;
}) {
  return (
    <footer className="sidebar-footer">
      <div className="session-card">
        <div className="session-avatar" aria-hidden="true">{text.sessionInitials}</div>
        <div>
          <strong>{text.localSession}</strong>
          <small>{formatSessionMeta(resolvedTheme)}</small>
        </div>
      </div>
      <div className="theme-control compact">
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
    </footer>
  );
}

function OverviewSurface({ status }: { status: GuiStatusData }) {
  const metrics = [
    { label: text.setup, value: status.update.restart_required ? "restart" : "current", detail: status.update.installed_version },
    { label: text.projects, value: String(status.repos.total), detail: status.repos.health },
    { label: text.settings, value: String(status.settings.key_count), detail: text.keysOnly },
    { label: text.security, value: String(status.secrets.length), detail: "secret references" },
  ];

  return (
    <section className="surface-page" aria-label="Overview">
      <div className="hero-panel">
        <p className="eyebrow">{text.localReadOnly}</p>
        <h2>{text.controlPlaneTitle}</h2>
        <p>{text.trustBoundary}</p>
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
          <p className="eyebrow">{text.signals}</p>
          <h2>{text.localSetupHealth}</h2>
          <p>{text.filesystemRefs}</p>
        </div>
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
    </section>
  );
}

function ProjectsSurface({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Projects">
      <div className="section-heading">
        <p className="eyebrow">{text.inventory}</p>
        <h2>{text.projects}</h2>
        <p>{text.registrySummaryPrefix}<code>{status.repos.path_ref}</code>{text.registrySummarySuffix}</p>
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
              <small>{formatLocalPathStatus(repo.local_path_status)}</small>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function AgentsSurface({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Agents">
      <div className="section-heading">
        <p className="eyebrow">{text.automation}</p>
        <h2>{text.agentsAndHelpers}</h2>
        <p>{text.capabilityIntro}</p>
      </div>
      <div className="capability-grid">
        {status.capabilities.map((capability) => (
          <article className="capability-card" key={capability.id}>
            <span>{capability.status}</span>
            <strong>{capability.label}</strong>
            <code>{capability.doc_ref}</code>
          </article>
        ))}
      </div>
      <h3>{text.helperAvailability}</h3>
      <ul className="object-list compact-list">
        {status.helper_availability.map((helper) => (
          <li key={helper.name}>
            <strong>{helper.name}</strong>
            <span>{helper.status}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

function SettingsSurface({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Settings">
      <div className="section-heading">
        <p className="eyebrow">{text.configuration}</p>
        <h2>{text.settings}</h2>
        <p>{text.settingsIntro}</p>
      </div>
      <dl className="inline-details">
        <dt>{text.path}</dt>
        <dd><code>{status.settings.path_ref}</code></dd>
        <dt>{text.health}</dt>
        <dd>{status.settings.health}</dd>
        <dt>{text.policy}</dt>
        <dd>{status.settings.value_policy}</dd>
      </dl>
      {status.settings.keys.length === 0 ? (
        <p className="empty-state">{text.noSettingsKeys}</p>
      ) : (
        <ul className="tag-list">
          {status.settings.keys.map((key) => <li key={key}>{key}</li>)}
        </ul>
      )}
    </section>
  );
}

function SecuritySurface({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Security">
      <div className="section-heading">
        <p className="eyebrow">{text.guardrails}</p>
        <h2>{text.security}</h2>
        <p>{text.guardrailIntro}</p>
      </div>
      <ul className="object-list">
        {status.secrets.map((secret) => (
          <li key={secret.name}>
            <strong>{secret.name}</strong>
            <span>{secret.status}</span>
          </li>
        ))}
      </ul>
      <p className="empty-state">{status.placeholders[0]}</p>
    </section>
  );
}

function PlannedSurface({ detail, label }: { detail: string; label: string }) {
  return (
    <section className="panel" aria-label={label}>
      <div className="section-heading">
        <p className="eyebrow">{text.plannedAdapter}</p>
        <h2>{label}</h2>
        <p>{detail}</p>
      </div>
      <p className="empty-state">{text.plannedPlaceholder}</p>
    </section>
  );
}
