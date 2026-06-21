import React, { useEffect, useState } from "react";
import type { GuiNavigationItem, GuiResponseEnvelope, GuiStatusData } from "../../gui-shared/src";
import { fetchStatus, mockedStatus } from "./status-client";

type ThemePreference = "system" | "light" | "dark";

type ControlNode = {
  detail: string;
  id: string;
  refs: string[];
  state: string;
  tier: "core" | "inventory" | "automation" | "integration" | "guardrail" | "planned";
  title: string;
};

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
  const activeItem = status.data.navigation.find((item) => item.id === activeSection) ?? status.data.navigation[0];
  const navGroups: Array<{ label: string; items: GuiNavigationItem[] }> = [
    {
      label: "Operate",
      items: status.data.navigation.filter((item) => item.id === "overview" || item.id === "repos" || item.id === "capabilities"),
    },
    {
      label: "Configure",
      items: status.data.navigation.filter((item) => item.id === "settings"),
    },
    {
      label: "Protect",
      items: status.data.navigation.filter((item) => item.id === "security"),
    },
  ];

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
          <input aria-label="Search dashboard" disabled placeholder="Find nodes, surfaces, settings" />
        </div>
        <div className="topbar-status">
          <span className="status-dot" aria-hidden="true" />
          <span>local read-only</span>
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
          <p className="sidebar-kicker">Surface library</p>
          <nav>
            {navGroups.map((group) => (
              <div className="nav-group" key={group.label}>
                <p>{group.label}</p>
                {group.items.map((item) => (
                  <button
                    aria-current={activeSection === item.id ? "page" : undefined}
                    className={activeSection === item.id ? "nav-item active" : "nav-item"}
                    key={item.id}
                    onClick={() => setActiveSection(item.id)}
                    type="button"
                  >
                    <span>{surfaceLabel(item)}</span>
                    <small>{surfaceDescription(item)}</small>
                  </button>
                ))}
              </div>
            ))}
          </nav>
        </aside>

        <section className="content" aria-label="aidevops dashboard">
          <header className="canvas-toolbar">
            <div>
              <p className="eyebrow">Read-only local control graph</p>
              <h1>{activeSection === "overview" ? "aidevops control plane" : surfaceLabel(activeItem)}</h1>
            </div>
            <div className="toolbar-messages">
              {warning ? <p role="status">{warning}</p> : null}
              {update.restart_required ? (
                <p className="alert" role="alert">
                  {update.message} Running {update.running_version}; installed {update.installed_version}.
                </p>
              ) : (
                <p className="notice" role="status">{update.message}</p>
              )}
            </div>
          </header>

          {activeSection === "overview" ? <OverviewSection status={status.data} /> : null}
          {activeSection === "repos" ? <ReposSection status={status.data} /> : null}
          {activeSection === "settings" ? <SettingsSection status={status.data} /> : null}
          {activeSection === "capabilities" ? <CapabilitiesSection status={status.data} /> : null}
          {activeSection === "security" ? <SecuritySection status={status.data} /> : null}
        </section>

        <aside className="detail-rail" aria-label="Inspector">
          <section className="rail-card now-card">
            <p className="eyebrow">Inspector</p>
            <h2>{surfaceLabel(activeItem)}</h2>
            <p>{surfaceDescription(activeItem)}</p>
            <dl className="inspector-list">
              <dt>Source</dt>
              <dd>{status.source.authority}</dd>
              <dt>Mode</dt>
              <dd>{status.data.runtime.api} API</dd>
            </dl>
          </section>
          <section className="rail-card">
            <h3>Node types</h3>
            <ul>
              <li><span>Setup</span><strong>status</strong></li>
              <li><span>Projects</span><strong>repos</strong></li>
              <li><span>Automation</span><strong>routines</strong></li>
              <li><span>Integrations</span><strong>providers</strong></li>
              <li><span>Security</span><strong>secrets</strong></li>
            </ul>
          </section>
          <section className="rail-card">
            <h3>Interaction policy</h3>
            <p>Read-only first. Future setup and management actions should appear as explicit guided flows, not generic command execution.</p>
          </section>
        </aside>
      </div>

      <footer className="app-statusbar" aria-label="App status">
        <span>{status.data.runtime.api} API</span>
        <span>{status.source.authority}</span>
        <span>Observed {new Date(status.observed_at).toLocaleTimeString()}</span>
        <span>{themePreference === "system" ? `system/${systemTheme}` : themePreference}</span>
      </footer>
    </main>
  );
}

function OverviewSection({ status }: { status: GuiStatusData }) {
  const nodes = controlNodes(status);

  return (
    <section className="panel flow-panel" aria-label="Control graph">
      <div className="section-heading">
        <p className="eyebrow">Canvas</p>
        <h2>Local operating graph</h2>
        <p>Nodes describe what aidevops can observe now and where guided setup or management flows can attach later.</p>
      </div>
      <div className="flow-canvas" aria-label="aidevops capability graph">
        {nodes.map((node) => <FlowNodeCard key={node.id} node={node} />)}
      </div>
      <h2>Current local signals</h2>
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

function FlowNodeCard({ node }: { node: ControlNode }) {
  return (
    <article className="flow-node" data-tier={node.tier}>
      <div className="node-port" aria-hidden="true" />
      <div>
        <strong>{node.title}</strong>
        <span>{node.state}</span>
      </div>
      <p>{node.detail}</p>
      <ul>
        {node.refs.map((ref) => <li key={ref}>{ref}</li>)}
      </ul>
    </article>
  );
}

function ReposSection({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Projects">
      <div className="section-heading">
        <p className="eyebrow">Inventory</p>
        <h2>Projects</h2>
        <p>Read-only registry summary from <code>{status.repos.path_ref}</code>.</p>
      </div>
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
      <div className="section-heading">
        <p className="eyebrow">Configuration</p>
        <h2>Settings</h2>
        <p>Values are intentionally not rendered; this view shows keys and file health only.</p>
      </div>
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
    <section className="panel" aria-label="Automation">
      <div className="section-heading">
        <p className="eyebrow">Automation</p>
        <h2>Agents and helpers</h2>
        <p>Capability cards map the aidevops agent and helper surfaces that can become guided workflows.</p>
      </div>
      <ul className="object-list">
        {status.capabilities.map((capability) => (
          <li key={capability.id}>
            <strong>{capability.label}</strong>
            <span>{capability.status}</span>
            <code>{capability.doc_ref}</code>
          </li>
        ))}
      </ul>
      <h3>Helper availability</h3>
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

function SecuritySection({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label="Security">
      <div className="section-heading">
        <p className="eyebrow">Guardrails</p>
        <h2>Security</h2>
        <p>Secret values, prefixes, suffixes, raw credential files, and arbitrary commands are not exposed.</p>
      </div>
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

function controlNodes(status: GuiStatusData): ControlNode[] {
  return [
    {
      detail: "Local framework install, update, and restart signal.",
      id: "setup",
      refs: [`aidevops ${status.aidevops_version}`, status.update.restart_required ? "restart required" : "current"],
      state: status.update.restart_required ? "needs restart" : "ready",
      tier: "core",
      title: "Setup",
    },
    {
      detail: "Known repositories and local path health.",
      id: "projects",
      refs: [`${status.repos.total} records`, status.repos.path_ref],
      state: status.repos.health,
      tier: "inventory",
      title: "Projects",
    },
    {
      detail: "Agents, helpers, routines, and dispatchable workflows.",
      id: "automation",
      refs: [`${status.capabilities.length} capabilities`, `${status.helper_availability.length} helpers`],
      state: "observed",
      tier: "automation",
      title: "Automation",
    },
    {
      detail: "Git hosts, infrastructure providers, calendars, and future Cloudron surfaces.",
      id: "integrations",
      refs: ["provider status only", "no control actions"],
      state: "planned",
      tier: "integration",
      title: "Integrations",
    },
    {
      detail: "Configuration precedence and safe key-only visibility.",
      id: "settings",
      refs: [`${status.settings.key_count} keys`, status.settings.value_policy],
      state: status.settings.health,
      tier: "guardrail",
      title: "Settings",
    },
    {
      detail: "Secret references, security posture, and trust-boundary checks.",
      id: "security",
      refs: [`${status.secrets.length} secret refs`, "values hidden"],
      state: "guarded",
      tier: "guardrail",
      title: "Security",
    },
  ];
}

function surfaceLabel(item: GuiNavigationItem | undefined): string {
  if (!item) {
    return "Control graph";
  }

  if (item.id === "overview") {
    return "Control graph";
  }
  if (item.id === "repos") {
    return "Projects";
  }
  if (item.id === "capabilities") {
    return "Automation";
  }

  return item.label;
}

function surfaceDescription(item: GuiNavigationItem | undefined): string {
  if (!item) {
    return "Map aidevops setup, projects, automation, integrations, settings, and security.";
  }

  if (item.id === "overview") {
    return "Map aidevops setup, projects, automation, integrations, settings, and security.";
  }
  if (item.id === "repos") {
    return "Inspect the read-only project registry and local path health.";
  }
  if (item.id === "capabilities") {
    return "Inspect agents, helpers, routines, and workflow capabilities.";
  }

  return item.description;
}
