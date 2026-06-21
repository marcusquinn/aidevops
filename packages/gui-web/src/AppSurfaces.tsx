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
import { fetchFileExplorer, mockedFileExplorer } from "./status-client";
import {
  appRows,
  installationRows,
  inventorySurfaceConfigs,
  navGroups,
  plannedHomes,
  text,
} from "./app-model";
import type { InventoryColumn, SurfaceId, SurfaceNavGroup, SurfaceNavItem, ThemePreference } from "./app-model";

export function Sidebar({ activeSurface, setActiveSurface, setThemePreference, themePreference }: {
  activeSurface: SurfaceId;
  setActiveSurface: (surface: SurfaceId) => void;
  setThemePreference: (theme: ThemePreference) => void;
  themePreference: ThemePreference;
}) {
  return (
    <aside className="app-sidebar" aria-label={text.navigationLabel}>
      <SidebarHeader />
      <nav className="sidebar-content">
        {navGroups.map((group) => <SidebarGroup activeSurface={activeSurface} group={group} key={group.label} setActiveSurface={setActiveSurface} />)}
      </nav>
      <SidebarFooter setThemePreference={setThemePreference} themePreference={themePreference} />
    </aside>
  );
}

function SidebarGroup({ activeSurface, group, setActiveSurface }: {
  activeSurface: SurfaceId;
  group: SurfaceNavGroup;
  setActiveSurface: (surface: SurfaceId) => void;
}) {
  return (
    <section className="sidebar-group">
      <h2>{group.label}</h2>
      <ul>
        {group.items.map((item) => <SidebarItem activeSurface={activeSurface} item={item} key={item.id} setActiveSurface={setActiveSurface} />)}
      </ul>
    </section>
  );
}

function SidebarItem({ activeSurface, item, setActiveSurface }: {
  activeSurface: SurfaceId;
  item: SurfaceNavItem;
  setActiveSurface: (surface: SurfaceId) => void;
}) {
  const isActive = activeSurface === item.id;

  return (
    <li>
      <button
        aria-current={isActive ? "page" : undefined}
        className={isActive ? "surface-link active" : "surface-link"}
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
  );
}

export function Workspace({ activeItem, activeSurface, fileRoot, status }: {
  activeItem: SurfaceNavItem;
  activeSurface: SurfaceId;
  fileRoot: GuiFileRootId | undefined;
  status: GuiStatusData;
}) {
  return (
    <section className="app-inset" aria-label={text.workspaceLabel}>
      <WorkspaceHeader activeItem={activeItem} />
      <div className="workspace-scroll">
        <SurfaceContent activeSurface={activeSurface} fileRoot={fileRoot} status={status} />
      </div>
    </section>
  );
}

function WorkspaceHeader({ activeItem }: { activeItem: SurfaceNavItem }) {
  return (
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
  );
}

function SurfaceContent({ activeSurface, fileRoot, status }: {
  activeSurface: SurfaceId;
  fileRoot: GuiFileRootId | undefined;
  status: GuiStatusData;
}) {
  const inventoryConfig = inventorySurfaceConfigs[activeSurface];

  if (fileRoot) {
    return <FileExplorerSurface key={fileRoot} rootId={fileRoot} />;
  }

  if (inventoryConfig) {
    return <EditableInventorySurface {...inventoryConfig} />;
  }

  switch (activeSurface) {
    case "overview":
      return <OverviewSurface status={status} />;
    case "routines":
      return <PlannedSurface label={text.routines} detail={text.routineDetail} />;
    case "apps":
      return <AppsSurface />;
    case "installation":
      return <InstallationSurface />;
    case "projects":
      return <ProjectsSurface status={status} />;
    case "security":
      return <SecuritySurface status={status} />;
    default:
      return null;
  }
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
