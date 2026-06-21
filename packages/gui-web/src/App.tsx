/* jshint esversion: 11 */
import { useEffect, useState } from "react";
import type { GuiResponseEnvelope, GuiStatusData } from "../../gui-shared/src";
import {
  fileRootBySurface,
  findSurface,
  inventorySurfaces,
  navGroups,
  plannedHomes,
  text,
  type SurfaceId,
  type ThemePreference,
} from "./app-model";
import { FileExplorerSurface } from "./file-explorer-surface";
import { AppsSurface, EditableInventorySurface, InstallationSurface } from "./inventory-surfaces";
import { PathActions } from "./path-actions";
import { fetchStatus, mockedStatus } from "./status-client";

function getSystemTheme(): "light" | "dark" {
  if (typeof window === "undefined") {
    return "light";
  }

  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function App() {
  const [status, setStatus] = useState<GuiResponseEnvelope<GuiStatusData>>(mockedStatus());
  const [activeSurface, setActiveSurface] = useState<SurfaceId>("overview");
  const [themePreference, setThemePreference] = useState<ThemePreference>("system");
  const [systemTheme, setSystemTheme] = useState<"light" | "dark">("light");
  const resolvedTheme = themePreference === "system" ? systemTheme : themePreference;
  const activeItem = findSurface(activeSurface);
  const fileRoot = fileRootBySurface[activeSurface];
  const inventoryDefinition = inventorySurfaces[activeSurface];

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
      .then(setStatus)
      .catch(() => setStatus(mockedStatus()));
  }, []);

  return (
    <main className="app-shell">
      <aside className="app-sidebar" aria-label={text.navigationLabel}>
        <SidebarHeader />
        <SidebarNav activeSurface={activeSurface} setActiveSurface={setActiveSurface} />
        <SidebarFooter setThemePreference={setThemePreference} themePreference={themePreference} />
      </aside>

      <section className="app-inset" aria-label={text.workspaceLabel}>
        <WorkspaceHeader title={activeItem.label} />
        <div className="workspace-scroll">
          {activeSurface === "overview" ? <OverviewSurface status={status.data} /> : null}
          {fileRoot ? <FileExplorerSurface key={fileRoot} rootId={fileRoot} /> : null}
          {activeSurface === "routines" ? <PlannedSurface label={text.routines} detail={text.routineDetail} /> : null}
          {activeSurface === "apps" ? <AppsSurface /> : null}
          {activeSurface === "installation" ? <InstallationSurface /> : null}
          {inventoryDefinition ? <EditableInventorySurface definition={inventoryDefinition} /> : null}
          {activeSurface === "projects" ? <ProjectsSurface status={status.data} /> : null}
          {activeSurface === "security" ? <SecuritySurface status={status.data} /> : null}
        </div>
      </section>
    </main>
  );
}

function SidebarHeader() {
  return (
    <header className="sidebar-header">
      <div className="brand-lockup">
        <span className="terminal-mark" aria-hidden="true">›_</span>
        <strong>{text.aidevops}</strong>
      </div>
    </header>
  );
}

function SidebarNav({ activeSurface, setActiveSurface }: {
  activeSurface: SurfaceId;
  setActiveSurface: (surface: SurfaceId) => void;
}) {
  return (
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
  );
}

function SidebarFooter({ setThemePreference, themePreference }: {
  setThemePreference: (theme: ThemePreference) => void;
  themePreference: ThemePreference;
}) {
  return (
    <footer className="sidebar-footer">
      <p>{text.theme}</p>
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

function WorkspaceHeader({ title }: { title: string }) {
  return (
    <header className="workspace-header">
      <div className="header-title">
        <button className="sidebar-trigger" type="button" aria-label="Sidebar is fixed in this preview">☰</button>
        <div>
          <p>{text.appShell}</p>
          <h1>{title}</h1>
        </div>
      </div>
      <div className="header-actions">
        <label className="workspace-search">
          <span>⌘K</span>
          <input disabled placeholder={text.searchPlaceholder} />
        </label>
        <span className="read-only-pill"><i />{text.readOnly}</span>
      </div>
    </header>
  );
}

function OverviewSurface({ status }: { status: GuiStatusData }) {
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
    </section>
  );
}

function ProjectsSurface({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label={text.projects}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.inventory}</p>
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

function SecuritySurface({ status }: { status: GuiStatusData }) {
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

function PlannedSurface({ detail, label }: { detail: string; label: string }) {
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
