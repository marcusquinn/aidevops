import { useEffect, useState } from "react";
import type { GuiNavigationItem, GuiResponseEnvelope, GuiStatusData } from "../../gui-shared/src";
import { fetchStatus, mockedStatus } from "./status-client";

type ThemePreference = "system" | "light" | "dark";

interface ControlNode {
  detail: string;
  id: string;
  refs: string[];
  state: string;
  tier: "core" | "inventory" | "automation" | "integration" | "guardrail" | "planned";
  title: string;
}

interface NodeTypeSummary {
  label: string;
  value: string;
}

const uiText = {
  agentsAndHelpers: "Agents and helpers",
  api: "API",
  automation: "Automation",
  automationDetail: "Agents, helpers, routines, and dispatchable workflows.",
  canvas: "Canvas",
  capabilitiesCount: "capabilities",
  capabilitiesDescription: "Capability cards map the aidevops agent and helper surfaces that can become guided workflows.",
  configuration: "Configuration",
  controlGraph: "Control graph",
  current: "current",
  currentLocalSignals: "Current local signals",
  guarded: "guarded",
  guardrails: "Guardrails",
  helperAvailability: "Helper availability",
  helpers: "helpers",
  installed: "installed",
  inspector: "Inspector",
  integrations: "Integrations",
  integrationsDetail: "Git hosts, infrastructure providers, calendars, and future Cloudron surfaces.",
  interactionPolicy: "Interaction policy",
  interactionPolicyText: "Read-only first. Future setup and management actions should appear as explicit guided flows, not generic command execution.",
  inventory: "Inventory",
  keys: "keys",
  localOperatingGraph: "Local operating graph",
  localReadOnly: "local read-only",
  mode: "Mode",
  needsRestart: "needs restart",
  nodeTypes: "Node types",
  nodesDescription: "Nodes describe what aidevops can observe now and where guided setup or management flows can attach later.",
  noControlActions: "no control actions",
  observed: "Observed",
  planned: "planned",
  providerStatusOnly: "provider status only",
  providers: "providers",
  projects: "Projects",
  projectsDetail: "Known repositories and local path health.",
  readOnlyControlGraph: "Read-only local control graph",
  ready: "ready",
  records: "records",
  repos: "repos",
  restartRequired: "restart required",
  running: "Running",
  routines: "routines",
  secretRefs: "secret refs",
  secrets: "secrets",
  security: "Security",
  securityDetail: "Secret references, security posture, and trust-boundary checks.",
  settings: "Settings",
  settingsDetail: "Configuration precedence and safe key-only visibility.",
  setup: "Setup",
  setupDetail: "Local framework install, update, and restart signal.",
  source: "Source",
  status: "status",
  surfaceLibrary: "Surface library",
  valuesHidden: "values hidden",
} as const;

const nodeTypeSummaries: NodeTypeSummary[] = [
  { label: uiText.setup, value: uiText.status },
  { label: uiText.projects, value: uiText.repos },
  { label: uiText.automation, value: uiText.routines },
  { label: uiText.integrations, value: uiText.providers },
  { label: uiText.security, value: uiText.secrets },
];

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
  const activeItem = navigationItemById(status.data.navigation, activeSection);
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
          <span>{uiText.localReadOnly}</span>
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
          <p className="sidebar-kicker">{uiText.surfaceLibrary}</p>
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
              <p className="eyebrow">{uiText.readOnlyControlGraph}</p>
              <h1>{activeSection === "overview" ? "aidevops control plane" : surfaceLabel(activeItem)}</h1>
            </div>
            <div className="toolbar-messages">
              {warning ? <p role="status">{warning}</p> : null}
              {update.restart_required ? (
                <p className="alert" role="alert">
                  {`${update.message} ${uiText.running} ${update.running_version}; ${uiText.installed} ${update.installed_version}.`}
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
            <p className="eyebrow">{uiText.inspector}</p>
            <h2>{surfaceLabel(activeItem)}</h2>
            <p>{surfaceDescription(activeItem)}</p>
            <dl className="inspector-list">
              <dt>{uiText.source}</dt>
              <dd>{status.source.authority}</dd>
              <dt>{uiText.mode}</dt>
              <dd>{status.data.runtime.api} {uiText.api}</dd>
            </dl>
          </section>
          <section className="rail-card">
            <h3>{uiText.nodeTypes}</h3>
            <ul>
              {nodeTypeSummaries.map((nodeType) => (
                <li key={nodeType.label}><span>{nodeType.label}</span><strong>{nodeType.value}</strong></li>
              ))}
            </ul>
          </section>
          <section className="rail-card">
            <h3>{uiText.interactionPolicy}</h3>
            <p>{uiText.interactionPolicyText}</p>
          </section>
        </aside>
      </div>

      <footer className="app-statusbar" aria-label="App status">
        <span>{status.data.runtime.api} {uiText.api}</span>
        <span>{status.source.authority}</span>
        <span>{uiText.observed} {new Date(status.observed_at).toLocaleTimeString()}</span>
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
        <p className="eyebrow">{uiText.canvas}</p>
        <h2>{uiText.localOperatingGraph}</h2>
        <p>{uiText.nodesDescription}</p>
      </div>
      <div className="flow-canvas">
        {nodes.map((node) => <FlowNodeCard key={node.id} node={node} />)}
      </div>
      <h2>{uiText.currentLocalSignals}</h2>
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
        <p className="eyebrow">{uiText.inventory}</p>
        <h2>{uiText.projects}</h2>
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
        <p className="eyebrow">{uiText.configuration}</p>
        <h2>{uiText.settings}</h2>
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
        <p className="eyebrow">{uiText.automation}</p>
        <h2>{uiText.agentsAndHelpers}</h2>
        <p>{uiText.capabilitiesDescription}</p>
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
      <h3>{uiText.helperAvailability}</h3>
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
        <p className="eyebrow">{uiText.guardrails}</p>
        <h2>{uiText.security}</h2>
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
      detail: uiText.setupDetail,
      id: "setup",
      refs: [`aidevops ${status.aidevops_version}`, status.update.restart_required ? uiText.restartRequired : uiText.current],
      state: status.update.restart_required ? uiText.needsRestart : uiText.ready,
      tier: "core",
      title: uiText.setup,
    },
    {
      detail: uiText.projectsDetail,
      id: "projects",
      refs: [`${status.repos.total} ${uiText.records}`, status.repos.path_ref],
      state: status.repos.health,
      tier: "inventory",
      title: uiText.projects,
    },
    {
      detail: uiText.automationDetail,
      id: "automation",
      refs: [`${status.capabilities.length} ${uiText.capabilitiesCount}`, `${status.helper_availability.length} ${uiText.helpers}`],
      state: "observed",
      tier: "automation",
      title: uiText.automation,
    },
    {
      detail: uiText.integrationsDetail,
      id: "integrations",
      refs: [uiText.providerStatusOnly, uiText.noControlActions],
      state: uiText.planned,
      tier: "integration",
      title: uiText.integrations,
    },
    {
      detail: uiText.settingsDetail,
      id: "settings",
      refs: [`${status.settings.key_count} ${uiText.keys}`, status.settings.value_policy],
      state: status.settings.health,
      tier: "guardrail",
      title: uiText.settings,
    },
    {
      detail: uiText.securityDetail,
      id: "security",
      refs: [`${status.secrets.length} ${uiText.secretRefs}`, uiText.valuesHidden],
      state: uiText.guarded,
      tier: "guardrail",
      title: uiText.security,
    },
  ];
}

function navigationItemById(items: GuiNavigationItem[], itemId: GuiNavigationItem["id"]): GuiNavigationItem | undefined {
  for (const item of items) {
    if (item.id === itemId) {
      return item;
    }
  }

  return items[0];
}

function surfaceLabel(item: GuiNavigationItem | undefined): string {
  if (!item) {
    return uiText.controlGraph;
  }

  if (item.id === "overview") {
    return uiText.controlGraph;
  }
  if (item.id === "repos") {
    return uiText.projects;
  }
  if (item.id === "capabilities") {
    return uiText.automation;
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
