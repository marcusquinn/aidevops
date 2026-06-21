/* jshint esversion: 11 */
import { useEffect, useState } from "react";
import type {
  GuiFileEntry,
  GuiFileExplorerData,
  GuiFilePreview,
  GuiFileRootId,
  GuiResponseEnvelope,
  GuiStatusData,
} from "../../gui-shared/src";
import { fetchFileExplorer, fetchStatus, mockedFileExplorer, mockedStatus } from "./status-client";

type ThemePreference = "system" | "light" | "dark";
type SurfaceId =
  | "overview"
  | "agents"
  | "config"
  | "localSetup"
  | "git"
  | "routines"
  | "apps"
  | "installation"
  | "personas"
  | "brands"
  | "domains"
  | "registrars"
  | "hosts"
  | "servers"
  | "projects"
  | "security";

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

interface InventoryColumn {
  key: string;
  label: string;
}

const text = {
  aidevops: "aidevops",
  appShell: "App shell",
  apps: "Apps",
  appsIntro: "App and CLI inventory for tools installed or updated by aidevops. Version and homepage adapters are planned.",
  appStatusPending: "adapter pending",
  brands: "Brands",
  brandsIntro: "Draft brand inventory for names and website references.",
  codeView: "Code",
  config: "Config",
  configIntro: "Read-only file explorer for ~/.config/aidevops. Contents stay hidden until redaction rules land.",
  copyPath: "Copy path",
  dashboard: "Dashboard",
  domains: "Domains",
  domainsIntro: "Draft domain ownership inventory across providers.",
  draftOnly: "Local browser draft only. Saving requires a write-action manifest, confirmation, and audit trail.",
  fileBrowser: "File browser",
  folderOpenBlocked: "Native folder opening needs a desktop bridge and an allowlisted action.",
  git: "Git",
  gitIntro: "Read-only file explorer for ~/Git workspaces and worktrees.",
  hosts: "Hosts",
  hostsIntro: "Recommended and user-owned hosting providers with setup notes later.",
  addRow: "Add row",
  channel: "Channel",
  installation: "Installation",
  installationIntro: "Optional aidevops setup/update components. Toggles are shown as planned controls until writes are enabled.",
  install: "Install",
  inventory: "Inventory",
  latest: "Latest",
  localSetup: "Local Setup",
  localSetupIntro: "Read-only file explorer for ~/.aidevops runtime folders, cache, memory, and deployed assets.",
  markdownFormatted: "Markdown formatted",
  markdownView: "Markdown",
  name: "Name",
  noProjectEntries: "No project registry entries are available yet.",
  noPreview: "Select a file to preview safe content.",
  operations: "Operations",
  parentDirectory: "..",
  path: "Path",
  personas: "Personas",
  personasIntro: "Draft identity list for first and last names.",
  planned: "planned",
  plannedHomes: "Planned homes",
  plannedNotice: "This surface is a local UI placeholder. Persistence and actions need explicit trust-boundary work.",
  projects: "Projects",
  readOnly: "Read-only",
  registrars: "Registrars",
  registrarsIntro: "Recommended and user-owned domain registrars.",
  roadmapIntro: "The GUI plan already has homes for setup/status, Git/repos, infrastructure inventory, providers, routines, agents, Cloudron, pairing, OpenCode sessions, and desktop packaging.",
  routines: "Routines",
  routineDetail: "Routine schedule, next run, run history, script/LLM-backed type, and diagnostic homes are planned.",
  searchPlaceholder: "Search setup, files, providers",
  security: "Security",
  securityBoundary: "No write routes, no shell bridge, no hosted app control, no pairing, no secret values.",
  servers: "Servers",
  serversIntro: "Server inventory by provider, operating system, orchestrator, and installed apps.",
  setup: "Setup",
  theme: "Theme",
  truncated: "Preview truncated for safety.",
  update: "Update",
  website: "Website",
  workspaceLabel: "aidevops workspace",
  navigationLabel: "aidevops navigation",
} as const;

const navGroups: SurfaceNavGroup[] = [
  {
    label: text.operations,
    items: [
      { id: "overview", label: text.dashboard, description: "Setup, status, and roadmap homes", icon: "⌘" },
      { id: "agents", label: "Agents", description: "~/.aidevops/agents explorer", icon: "A" },
      { id: "config", label: text.config, description: "~/.config/aidevops explorer", icon: "C" },
      { id: "localSetup", label: text.localSetup, description: "~/.aidevops explorer", icon: "L" },
      { id: "git", label: text.git, description: "~/Git explorer", icon: "G" },
      { id: "routines", label: text.routines, description: "Scheduled workflows", icon: "R", badge: text.planned },
    ],
  },
  {
    label: text.inventory,
    items: [
      { id: "apps", label: text.apps, description: "Installed tools and apps", icon: "P" },
      { id: "installation", label: text.installation, description: "Optional setup toggles", icon: "I" },
      { id: "personas", label: text.personas, description: "People and identities", icon: "P" },
      { id: "brands", label: text.brands, description: "Brands and websites", icon: "B" },
      { id: "domains", label: text.domains, description: "Owned domains", icon: "D" },
      { id: "registrars", label: text.registrars, description: "Domain registrars", icon: "R" },
      { id: "hosts", label: text.hosts, description: "Hosting providers", icon: "H" },
      { id: "servers", label: text.servers, description: "Servers and orchestrators", icon: "S" },
    ],
  },
  {
    label: "Reference",
    items: [
      { id: "projects", label: text.projects, description: "repos.json summary", icon: "◇" },
      { id: "security", label: text.security, description: "Trust boundary", icon: "◈" },
    ],
  },
];

const fileRootBySurface: Partial<Record<SurfaceId, GuiFileRootId>> = {
  agents: "agents",
  config: "config",
  localSetup: "localSetup",
  git: "git",
};

const appRows = [
  { name: "aidevops", latest: text.appStatusPending, channel: "setup/update", website: "https://aidevops.sh" },
  { name: "OpenCode", latest: text.appStatusPending, channel: "runtime", website: text.appStatusPending },
  { name: "Bun", latest: text.appStatusPending, channel: "toolchain", website: text.appStatusPending },
  { name: "GitHub CLI", latest: text.appStatusPending, channel: "git", website: text.appStatusPending },
  { name: "ShellCheck", latest: text.appStatusPending, channel: "quality", website: text.appStatusPending },
  { name: "Biome", latest: text.appStatusPending, channel: "quality", website: text.appStatusPending },
];

const installationRows = [
  { name: "OpenCode runtime", install: true, update: true, scope: "core" },
  { name: "GUI desktop launcher", install: true, update: true, scope: "local" },
  { name: "Shell quality tools", install: true, update: true, scope: "quality" },
  { name: "Cloudron helpers", install: false, update: false, scope: "optional" },
  { name: "Calendar sync helpers", install: false, update: false, scope: "optional" },
];

const plannedHomes = [
  { area: "Setup/status", home: "Dashboard + Local Setup", phase: "P6" },
  { area: "Repos and local Git", home: "Projects + Git", phase: "P7" },
  { area: "Infrastructure inventory", home: "Domains, Registrars, Hosts, Servers", phase: "P8" },
  { area: "Provider catalog", home: "Registrars, Hosts, Apps", phase: "P9" },
  { area: "Routines", home: "Routines", phase: "P10" },
  { area: "Agents and knowledgebase", home: "Agents", phase: "P12" },
  { area: "Cloudron and machine pairing", home: "Servers + Apps", phase: "P13/P14" },
  { area: "OpenCode sessions", home: "Future Sessions surface", phase: "P15" },
  { area: "Desktop wrapper", home: "Installation", phase: "P16" },
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

export function App() {
  const [status, setStatus] = useState<GuiResponseEnvelope<GuiStatusData>>(mockedStatus());
  const [activeSurface, setActiveSurface] = useState<SurfaceId>("overview");
  const [themePreference, setThemePreference] = useState<ThemePreference>("system");
  const [systemTheme, setSystemTheme] = useState<"light" | "dark">("light");
  const resolvedTheme = themePreference === "system" ? systemTheme : themePreference;
  const activeItem = findSurface(activeSurface);
  const fileRoot = fileRootBySurface[activeSurface];

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
        <SidebarFooter setThemePreference={setThemePreference} themePreference={themePreference} />
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
            <span className="read-only-pill"><i />{text.readOnly}</span>
          </div>
        </header>

        <div className="workspace-scroll">
          {activeSurface === "overview" ? <OverviewSurface status={status.data} /> : null}
          {fileRoot ? <FileExplorerSurface key={fileRoot} rootId={fileRoot} /> : null}
          {activeSurface === "routines" ? <PlannedSurface label={text.routines} detail={text.routineDetail} /> : null}
          {activeSurface === "apps" ? <AppsSurface /> : null}
          {activeSurface === "installation" ? <InstallationSurface /> : null}
          {activeSurface === "personas" ? <EditableInventorySurface title={text.personas} intro={text.personasIntro} columns={[{ key: "firstName", label: "First Name" }, { key: "lastName", label: "Last Name" }]} initialRows={[{ firstName: "", lastName: "" }]} /> : null}
          {activeSurface === "brands" ? <EditableInventorySurface title={text.brands} intro={text.brandsIntro} columns={[{ key: "brandName", label: "Brand Name" }, { key: "website", label: "Website URL" }]} initialRows={[{ brandName: "", website: "" }]} /> : null}
          {activeSurface === "domains" ? <EditableInventorySurface title={text.domains} intro={text.domainsIntro} columns={[{ key: "domain", label: "Domain" }, { key: "provider", label: "Provider" }, { key: "status", label: "Status" }]} initialRows={[{ domain: "", provider: "", status: "" }]} /> : null}
          {activeSurface === "registrars" ? <EditableInventorySurface title={text.registrars} intro={text.registrarsIntro} columns={[{ key: "name", label: "Registrar" }, { key: "recommendation", label: "Recommendation" }, { key: "notes", label: "Notes" }]} initialRows={[{ name: "Porkbun", recommendation: "recommended", notes: "provider catalog" }, { name: "Cloudflare Registrar", recommendation: "recommended", notes: "provider catalog" }]} /> : null}
          {activeSurface === "hosts" ? <EditableInventorySurface title={text.hosts} intro={text.hostsIntro} columns={[{ key: "name", label: "Host" }, { key: "category", label: "Category" }, { key: "notes", label: "Notes" }]} initialRows={[{ name: "Cloudron", category: "app platform", notes: "recommended" }, { name: "Coolify", category: "app platform", notes: "recommended" }, { name: "Ubicloud", category: "cloud", notes: "recommended" }]} /> : null}
          {activeSurface === "servers" ? <EditableInventorySurface title={text.servers} intro={text.serversIntro} columns={[{ key: "provider", label: "Provider" }, { key: "server", label: "Server" }, { key: "os", label: "OS" }, { key: "orchestrator", label: "Orchestrator" }, { key: "apps", label: "Apps" }]} initialRows={[{ provider: "", server: "", os: "", orchestrator: "", apps: "" }]} /> : null}
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

function FileExplorerSurface({ rootId }: { rootId: GuiFileRootId }) {
  const [relativePath, setRelativePath] = useState("");
  const [explorer, setExplorer] = useState<GuiResponseEnvelope<GuiFileExplorerData>>(() => mockedFileExplorer(rootId));
  const [markdownFormatted, setMarkdownFormatted] = useState(true);

  useEffect(() => {
    let cancelled = false;
    fetchFileExplorer(rootId, relativePath)
      .then((response) => {
        if (!cancelled) {
          setExplorer(response);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setExplorer(mockedFileExplorer(rootId));
        }
      });

    return () => {
      cancelled = true;
    };
  }, [rootId, relativePath]);

  const data = explorer.data;
  const intro = rootId === "agents" ? data.root.description : rootId === "config" ? text.configIntro : rootId === "localSetup" ? text.localSetupIntro : text.gitIntro;

  return (
    <section className="surface-page" aria-label={data.root.label}>
      <section className="panel explorer-panel">
        <div className="section-heading split-heading">
          <div>
            <p className="eyebrow">{data.root.path_ref}</p>
            <h2>{data.root.label}</h2>
            <p>{intro}</p>
          </div>
          <PathActions pathRef={data.current_path_ref} />
        </div>
        <div className="file-workspace">
          <ul className="file-list" aria-label={`${data.root.label} file list`}>
            <li>
              <button className="file-entry parent-entry" disabled={data.current_relative_path.length === 0} onClick={() => setRelativePath(parentPath(data.current_relative_path))} type="button">
                <span>↰</span>
                <strong>{text.parentDirectory}</strong>
              </button>
            </li>
            {data.entries.map((entry) => (
              <FileEntryButton entry={entry} key={entry.path_ref} setRelativePath={setRelativePath} />
            ))}
          </ul>
          <FilePreviewPanel markdownFormatted={markdownFormatted} preview={data.selected_preview} setMarkdownFormatted={setMarkdownFormatted} />
        </div>
      </section>
    </section>
  );
}

function FileEntryButton({ entry, setRelativePath }: { entry: GuiFileEntry; setRelativePath: (path: string) => void }) {
  return (
    <li className="file-entry-row">
      <button className="file-entry" onClick={() => setRelativePath(entry.relative_path)} type="button">
        <span>{entry.kind === "directory" ? "▸" : "•"}</span>
        <strong>{entry.name}</strong>
        <small>{entry.kind}</small>
      </button>
      <PathActions pathRef={entry.path_ref} />
    </li>
  );
}

function FilePreviewPanel({ markdownFormatted, preview, setMarkdownFormatted }: {
  markdownFormatted: boolean;
  preview: GuiFilePreview | null;
  setMarkdownFormatted: (value: boolean) => void;
}) {
  if (preview === null) {
    return <aside className="file-preview empty-preview"><p>{text.noPreview}</p></aside>;
  }

  if (preview.mode === "blocked") {
    return <aside className="file-preview empty-preview"><p>{preview.reason}</p></aside>;
  }

  const isMarkdown = preview.mode === "markdown";
  return (
    <aside className="file-preview">
      <div className="preview-header">
        <div>
          <p className="eyebrow">{preview.language || text.codeView}</p>
          <strong>{preview.path_ref}</strong>
        </div>
        {isMarkdown ? (
          <label className="toggle-row">
            <input checked={markdownFormatted} onChange={(event) => setMarkdownFormatted(event.currentTarget.checked)} type="checkbox" />
            <span>{text.markdownFormatted}</span>
          </label>
        ) : null}
      </div>
      {preview.truncated ? <p className="notice compact-notice">{text.truncated}</p> : null}
      {isMarkdown && markdownFormatted ? <MarkdownPreview content={preview.content} /> : <pre className="code-preview"><code>{preview.content}</code></pre>}
    </aside>
  );
}

function MarkdownPreview({ content }: { content: string }) {
  return (
    <div className="markdown-preview">
      {content.split("\n").slice(0, 240).map((line, index) => {
        if (line.startsWith("### ")) {
          return <h4 key={`${index}:${line}`}>{line.slice(4)}</h4>;
        }
        if (line.startsWith("## ")) {
          return <h3 key={`${index}:${line}`}>{line.slice(3)}</h3>;
        }
        if (line.startsWith("# ")) {
          return <h2 key={`${index}:${line}`}>{line.slice(2)}</h2>;
        }
        if (line.startsWith("- ")) {
          return <p className="markdown-bullet" key={`${index}:${line}`}>{line}</p>;
        }
        return <p key={`${index}:${line}`}>{line.length > 0 ? line : "\u00a0"}</p>;
      })}
    </div>
  );
}

function AppsSurface() {
  return (
    <section className="panel" aria-label={text.apps}>
      <div className="section-heading">
        <p className="eyebrow">{text.inventory}</p>
        <h2>{text.apps}</h2>
        <p>{text.appsIntro}</p>
      </div>
      <div className="data-table">
        <div className="data-row header-row"><span>{text.name}</span><span>{text.latest}</span><span>{text.channel}</span><span>{text.website}</span></div>
        {appRows.map((row) => (
          <div className="data-row" key={row.name}><span>{row.name}</span><span>{row.latest}</span><span>{row.channel}</span><span>{row.website}</span></div>
        ))}
      </div>
    </section>
  );
}

function InstallationSurface() {
  return (
    <section className="panel" aria-label={text.installation}>
      <div className="section-heading">
        <p className="eyebrow">{text.setup}</p>
        <h2>{text.installation}</h2>
        <p>{text.installationIntro}</p>
      </div>
      <div className="installation-list">
        {installationRows.map((row) => (
          <article className="install-row" key={row.name}>
            <div><strong>{row.name}</strong><small>{row.scope}</small></div>
            <TogglePill checked={row.install} label={text.install} />
            <TogglePill checked={row.update} label={text.update} />
          </article>
        ))}
      </div>
      <p className="empty-state">{text.plannedNotice}</p>
    </section>
  );
}

function TogglePill({ checked, label }: { checked: boolean; label: string }) {
  return <span className={checked ? "toggle-pill checked" : "toggle-pill"}>{label}</span>;
}

function EditableInventorySurface({ columns, initialRows, intro, title }: {
  columns: InventoryColumn[];
  initialRows: Record<string, string>[];
  intro: string;
  title: string;
}) {
  const [draftRows, setDraftRows] = useState(initialRows);

  function updateDraftRow(rowIndex: number, key: string, value: string): void {
    setDraftRows((currentRows) => currentRows.map((row, index) => index === rowIndex ? { ...row, [key]: value } : row));
  }

  function addDraftRow(): void {
    const emptyRow: Record<string, string> = {};
    for (const column of columns) {
      emptyRow[column.key] = "";
    }
    setDraftRows((currentRows) => [...currentRows, emptyRow]);
  }

  return (
    <section className="panel" aria-label={title}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.inventory}</p>
          <h2>{title}</h2>
          <p>{intro}</p>
        </div>
        <button className="secondary-action" onClick={addDraftRow} type="button">{text.addRow}</button>
      </div>
      <p className="notice compact-notice">{text.draftOnly}</p>
      <div className="editable-table">
        <div className="editable-row header-row">
          {columns.map((column) => <span key={column.key}>{column.label}</span>)}
        </div>
        {draftRows.map((row, rowIndex) => (
          <div className="editable-row" key={`${title}:${rowIndex}`}>
            {columns.map((column) => (
              <input
                aria-label={`${title} ${column.label}`}
                key={column.key}
                onChange={(event) => updateDraftRow(rowIndex, column.key, event.currentTarget.value)}
                placeholder={column.label}
                value={row[column.key] ?? ""}
              />
            ))}
          </div>
        ))}
      </div>
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

function PathActions({ pathRef }: { pathRef: string }) {
  const copy = () => {
    if (typeof navigator !== "undefined" && navigator.clipboard !== undefined) {
      void navigator.clipboard.writeText(pathRef);
    }
  };

  return (
    <span className="path-actions">
      <button aria-label={text.copyPath} onClick={copy} title={text.copyPath} type="button">⧉</button>
      <button aria-label={text.folderOpenBlocked} disabled title={text.folderOpenBlocked} type="button">⌂</button>
    </span>
  );
}

function parentPath(relativePath: string): string {
  const parts = relativePath.split("/").filter(Boolean);
  parts.pop();
  return parts.join("/");
}
