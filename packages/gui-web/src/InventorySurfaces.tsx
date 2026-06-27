import type { GuiAppActionId, GuiAppActionJobSummary, GuiManagedAppSummary, GuiResponseEnvelope, GuiStatusData } from "@aidevops/gui-shared";
import { type Dispatch, type ReactElement, type SetStateAction, useEffect, useState } from "react";
import { FiDownload, FiExternalLink, FiRefreshCw, FiRepeat, FiTrash2 } from "react-icons/fi";
import type { InventoryColumn } from "./app-model";
import { installationRows, text } from "./app-model";

interface DraftInventoryRow {
  id: string;
  values: Record<string, string>;
}

let draftRowCounter = 0;

export function AppsSurface({ status }: { status: GuiStatusData }): ReactElement {
  const [selectedJobId, setSelectedJobId] = useState<string | null>(null);
  const [jobs, setJobs] = useState<Record<string, GuiAppActionJobSummary>>({});
  const selectedJob = selectedJobId === null ? null : jobs[selectedJobId] ?? null;

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
          <ManagedAppRow app={app} key={app.id} onJob={(job) => { setJobs((current) => ({ ...current, [job.id]: job })); setSelectedJobId(job.id); }} />
        ))}
      </div>
      {selectedJob ? <AppActionTerminal job={selectedJob} /> : <p className="empty-state compact-notice">Install/update actions run as allowlisted background jobs and stream here. xterm.js with a node-pty bridge is the right next step for full TUI apps such as OpenCode; this view starts with non-interactive command logs.</p>}
    </section>
  );
}

function ManagedAppRow({ app, onJob }: { app: GuiManagedAppSummary; onJob: (job: GuiAppActionJobSummary) => void }): ReactElement {
  return (
    <article className="managed-app-row">
      <div className="managed-app-main">
        <div>
          <p className="eyebrow">{app.category}</p>
          <h3>{app.name}</h3>
          <p>{app.description}</p>
        </div>
        <div className="managed-app-links">
          <OriginLink href={app.origin_website_url} label={text.website} />
          <OriginLink href={app.origin_repo_url} label="Repo" />
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
      <div className="managed-app-actions">
        {app.actions.map((action) => <AppActionButton action={action.id} app={app} disabled={!action.enabled} key={action.id} onJob={onJob} title={action.command_preview} />)}
      </div>
    </article>
  );
}

function OriginLink({ href, label }: { href: string; label: string }): ReactElement {
  if (href.length === 0) {
    return <span className="origin-missing">{label}: source pending</span>;
  }

  return <a href={href} rel="noreferrer" target="_blank">{label} <FiExternalLink aria-hidden="true" /></a>;
}

function ToggleSwitch({ checked, label }: { checked: boolean; label: string }): ReactElement {
  return <span className="managed-toggle"><span aria-hidden="true" className={checked ? "switch-track checked" : "switch-track"}><span /></span>{label}</span>;
}

function AppMeta({ label, value }: { label: string; value: string }): ReactElement {
  return <span className="app-meta"><small>{label}</small><strong>{value}</strong></span>;
}

function AppActionButton({ action, app, disabled, onJob, title }: { action: GuiAppActionId; app: GuiManagedAppSummary; disabled: boolean; onJob: (job: GuiAppActionJobSummary) => void; title: string }): ReactElement {
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

  return <button aria-label={`${action} ${app.name}`} className="app-action-button" disabled={disabled} onClick={() => void runAction()} title={title} type="button">{icon}</button>;
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
