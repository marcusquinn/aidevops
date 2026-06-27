import type { GuiAppActionId, GuiAppActionJobSummary, GuiManagedAppSummary, GuiResponseEnvelope, GuiStatusData } from "@aidevops/gui-shared";
import { type Dispatch, type ReactElement, type SetStateAction, useEffect, useState } from "react";
import { FiChevronDown, FiDownload, FiExternalLink, FiRefreshCw, FiRepeat, FiTrash2 } from "react-icons/fi";
import type { InventoryColumn } from "./app-model";
import { installationRows, text } from "./app-model";

interface DraftInventoryRow {
  id: string;
  values: Record<string, string>;
}

let draftRowCounter = 0;

export function AppsSurface({ status }: { status: GuiStatusData }): ReactElement {
  const [selectedJobId, setSelectedJobId] = useState<string | null>(null);
  const [expandedAppIds, setExpandedAppIds] = useState<Set<string>>(() => new Set(status.managed_apps.length > 0 ? [status.managed_apps[0].id] : []));
  const [jobs, setJobs] = useState<Record<string, GuiAppActionJobSummary>>({});
  const selectedJob = selectedJobId === null ? null : jobs[selectedJobId] ?? null;

  useEffect(() => {
    if (status.managed_apps.length === 0) {
      return;
    }
    setExpandedAppIds((current) => current.size === 0 ? new Set([status.managed_apps[0].id]) : current);
  }, [status.managed_apps]);

  useEffect(() => {
    if (selectedJob === null || selectedJob.status !== "running") {
      return undefined;
    }

    const timer = window.setInterval(() => {
      void refreshJob(selectedJob.id, setJobs);
    }, 1_500);

    return () => window.clearInterval(timer);
  }, [selectedJob]);

  return (
    <section className="panel" aria-label={text.apps}>
      <div className="section-heading">
        <p className="eyebrow">{text.infrastructure}</p>
        <h2>{text.apps}</h2>
        <p>{text.appsIntro}</p>
      </div>
      <div className="managed-app-list">
        {status.managed_apps.map((app) => (
          <ManagedAppPanel
            app={app}
            expanded={expandedAppIds.has(app.id)}
            job={jobForApp(app.id, jobs, selectedJob)}
            key={app.id}
            onJob={(job) => {
              setJobs((current) => ({ ...current, [job.id]: job }));
              setSelectedJobId(job.id);
              setExpandedAppIds((current) => toggledAppIds(current, app.id, true));
            }}
            onToggle={() => setExpandedAppIds((current) => toggledAppIds(current, app.id))}
          />
        ))}
      </div>
      <p className="empty-state compact-notice">Install/update actions run as allowlisted background jobs and stream inside each app panel. xterm.js with a node-pty bridge is the right next step for full TUI apps such as OpenCode; this view starts with non-interactive command logs.</p>
    </section>
  );
}

function ManagedAppPanel({ app, expanded, job, onJob, onToggle }: { app: GuiManagedAppSummary; expanded: boolean; job: GuiAppActionJobSummary | null; onJob: (job: GuiAppActionJobSummary) => void; onToggle: () => void }): ReactElement {
  return (
    <article className={expanded ? "managed-app-card expanded" : "managed-app-card"}>
      <button aria-expanded={expanded} className="managed-app-summary" data-tooltip={`${expanded ? "Collapse" : "Expand"} ${app.name} controls`} onClick={onToggle} type="button">
        <span className="managed-app-title-block">
          <span className="eyebrow">{app.category}</span>
          <strong>{app.name}</strong>
          <span>{app.description}</span>
        </span>
        <span className="managed-app-summary-meta">
          <SummaryChip label="Status" value={app.status} />
          <SummaryChip label="Installed" value={app.installed_version} />
          <SummaryChip label="Latest" value={app.latest_version} />
          <FiChevronDown aria-hidden="true" className="managed-app-chevron" />
        </span>
      </button>
      {expanded ? <div className="managed-app-body">
        <div className="managed-app-toolbar">
          <div className="managed-app-links">
            <OriginLink href={app.origin_website_url} label={text.website} />
            <OriginLink href={app.origin_repo_url} label="Repo" />
          </div>
          <div className="managed-app-actions">
            {app.actions.map((action) => <AppActionButton action={action.id} app={app} disabled={!action.enabled} key={action.id} onJob={onJob} commandPreview={action.command_preview} />)}
          </div>
        </div>
      <div className="managed-app-details">
        <ToggleSwitch checked={app.aidevops_install} label="setup installs" />
        <ToggleSwitch checked={app.aidevops_update} label="update maintains" />
        <AppMeta label="Installed" value={app.installed_version} />
        <AppMeta label="Latest" value={app.latest_version} />
        <AppMeta label={text.path} value={app.install_path_ref} />
        <AppMeta label="Status" value={app.status} />
      </div>
      {job ? <AppActionTerminal job={job} /> : <p className="empty-state compact-notice">No recent command output for this app. Run an action to open this app's terminal log.</p>}
      </div> : null}
    </article>
  );
}

function SummaryChip({ label, value }: { label: string; value: string }): ReactElement {
  return <span className="managed-summary-chip"><small>{label}</small><span>{value}</span></span>;
}

function OriginLink({ href, label }: { href: string; label: string }): ReactElement {
  if (href.length === 0) {
    return <span className="origin-missing">{label}: source pending</span>;
  }

  return <a data-tooltip={`Open ${label.toLowerCase()} destination`} href={href} rel="noreferrer" target="_blank">{label} <FiExternalLink aria-hidden="true" /></a>;
}

function ToggleSwitch({ checked, label }: { checked: boolean; label: string }): ReactElement {
  return <span className="managed-toggle"><span aria-hidden="true" className={checked ? "switch-track checked" : "switch-track"}><span /></span>{label}</span>;
}

function AppMeta({ label, value }: { label: string; value: string }): ReactElement {
  return <span className="app-meta"><small>{label}</small><strong>{value}</strong></span>;
}

function AppActionButton({ action, app, commandPreview, disabled, onJob }: { action: GuiAppActionId; app: GuiManagedAppSummary; commandPreview: string; disabled: boolean; onJob: (job: GuiAppActionJobSummary) => void }): ReactElement {
  const icon = action === "install" ? <FiDownload /> : action === "update" ? <FiRefreshCw /> : action === "reinstall" ? <FiRepeat /> : <FiTrash2 />;

  async function runAction(): Promise<void> {
    if (disabled) {
      return;
    }
    if ((action === "remove" || action === "reinstall") && !window.confirm(`${action} ${app.name}?`)) {
      return;
    }

    const response = await fetch(`/api/apps/${encodeURIComponent(app.id)}/actions/${action}`, { method: "POST" });
    const envelope = await response.json() as GuiResponseEnvelope<GuiAppActionJobSummary>;
    onJob(envelope.data);
  }

  return <button aria-label={`${action} ${app.name}`} className={action === "remove" ? "app-action-button remove" : "app-action-button"} data-tooltip={commandPreview} disabled={disabled} onClick={() => void runAction()} type="button">{icon}<span>{action}</span></button>;
}

function AppActionTerminal({ job }: { job: GuiAppActionJobSummary }): ReactElement {
  return (
    <section className="app-terminal" aria-label="App action terminal output">
      <header><strong>{job.app_id} {job.action}</strong><span>{job.status}{job.exit_code === null ? "" : ` (${job.exit_code})`}</span></header>
      <pre>{job.output.join("\n")}</pre>
    </section>
  );
}

async function refreshJob(jobId: string, setJobs: Dispatch<SetStateAction<Record<string, GuiAppActionJobSummary>>>): Promise<void> {
  const response = await fetch(`/api/apps/jobs/${encodeURIComponent(jobId)}`);
  if (!response.ok) {
    return;
  }
  const envelope = await response.json() as GuiResponseEnvelope<GuiAppActionJobSummary>;
  setJobs((current) => ({ ...current, [envelope.data.id]: envelope.data }));
}

function jobForApp(appId: string, jobs: Record<string, GuiAppActionJobSummary>, selectedJob: GuiAppActionJobSummary | null): GuiAppActionJobSummary | null {
  if (selectedJob?.app_id === appId) {
    return selectedJob;
  }

  return Object.values(jobs).reverse().find((job) => job.app_id === appId) ?? null;
}

function toggledAppIds(current: Set<string>, appId: string, forceOpen = false): Set<string> {
  const next = new Set(current);
  if (forceOpen || !next.has(appId)) {
    next.add(appId);
  } else {
    next.delete(appId);
  }

  return next;
}

export function InstallationSurface(): ReactElement {
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

export function EditableInventorySurface({ columns, initialRows, intro, title }: {
  columns: InventoryColumn[];
  initialRows: Record<string, string>[];
  intro: string;
  title: string;
}): ReactElement {
  const [draftRows, setDraftRows] = useState(() => initialRows.map((row) => createDraftRow(row)));

  function updateDraftRow(rowId: string, key: string, value: string): void {
    setDraftRows((currentRows) => currentRows.map((row) => row.id === rowId ? { ...row, values: { ...row.values, [key]: value } } : row));
  }

  function addDraftRow(): void {
    setDraftRows((currentRows) => [...currentRows, createDraftRow(emptyRow(columns))]);
  }

  return (
    <section className="panel" aria-label={title}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.infrastructure}</p>
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
        {draftRows.map((row) => (
          <div className="editable-row" key={row.id}>
            {columns.map((column) => (
              <input
                aria-label={`${title} ${column.label}`}
                key={column.key}
                onChange={(event) => updateDraftRow(row.id, column.key, event.currentTarget.value)}
                placeholder={column.label}
                value={row.values[column.key] ?? ""}
              />
            ))}
          </div>
        ))}
      </div>
    </section>
  );
}

function TogglePill({ checked, label }: { checked: boolean; label: string }): ReactElement {
  return <span className={checked ? "toggle-pill checked" : "toggle-pill"}>{label}</span>;
}

function createDraftRow(values: Record<string, string>): DraftInventoryRow {
  draftRowCounter += 1;
  return { id: `draft-row-${draftRowCounter}`, values };
}

function emptyRow(columns: InventoryColumn[]): Record<string, string> {
  const row: Record<string, string> = {};
  for (const column of columns) {
    row[column.key] = "";
  }

  return row;
}
