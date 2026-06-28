import type { GuiAppActionId, GuiAppActionJobSummary, GuiManagedAppSummary, GuiResponseEnvelope } from "@aidevops/gui-shared";
import { type MouseEvent as ReactMouseEvent, type ReactElement, useState } from "react";
import { FiChevronDown, FiDownload, FiExternalLink, FiRefreshCw, FiRepeat, FiTrash2 } from "react-icons/fi";
import { AppActionTerminal } from "./AppActionTerminal";
import { text } from "./app-model";

type ManagedPolicyId = "setup" | "update";

export function ManagedAppPanel({ app, dismissedJobIds, expanded, job, onDismissJob, onJob, onPolicyToggle, onToggle, policyJobs }: { app: GuiManagedAppSummary; dismissedJobIds: Set<string>; expanded: boolean; job: GuiAppActionJobSummary | null; onDismissJob: (jobId: string) => void; onJob: (job: GuiAppActionJobSummary) => void; onPolicyToggle: (policy: ManagedPolicyId, value: boolean) => void; onToggle: () => void; policyJobs: GuiAppActionJobSummary[] }): ReactElement {
  const lockedPolicy = isEssentialManagedApp(app);
  const visibleJob = job === null || dismissedJobIds.has(job.id) ? null : job;
  const visiblePolicyJobs = policyJobs.filter((policyJob) => !dismissedJobIds.has(policyJob.id));

  return (
    <article className={expanded ? "managed-app-card expanded" : "managed-app-card"}>
      <button aria-expanded={expanded} className="managed-app-summary" data-tooltip={`${expanded ? "Collapse" : "Expand"} ${app.name} controls`} onClick={onToggle} type="button">
        <span className="managed-app-title-block">
          <span className="eyebrow">{app.category}</span>
          <strong>{app.name}</strong>
          <span>{app.description}</span>
        </span>
        <span className="managed-app-summary-meta">
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
        <ToggleSwitch checked={app.aidevops_install} disabled={lockedPolicy} label="setup installs" onChange={(value) => onPolicyToggle("setup", value)} />
        <ToggleSwitch checked={app.aidevops_update} disabled={lockedPolicy} label="update maintains" onChange={(value) => onPolicyToggle("update", value)} />
        {visibleJob ? <AppLogLink job={visibleJob} /> : null}
      </div>
      <AppMeta className="managed-app-path" label={text.path} value={app.install_path_ref} />
      {visibleJob ? <AppActionTerminal job={visibleJob} onDismiss={onDismissJob} /> : null}
      {visiblePolicyJobs.map((policyJob) => <AppActionTerminal job={policyJob} key={policyJob.id} onDismiss={onDismissJob} />)}
      {visibleJob === null && visiblePolicyJobs.length === 0 ? <p className="empty-state compact-notice">No recent command output for this app. Run an action or change a policy toggle to open this app's terminal log.</p> : null}
      </div> : null}
    </article>
  );
}

function isEssentialManagedApp(app: GuiManagedAppSummary): boolean {
  return ["core", "safety", "automation"].includes(app.category);
}

function SummaryChip({ label, value }: { label: string; value: string }): ReactElement {
  const tooltip = `${label}: ${value}`;
  return <span className="managed-summary-chip" data-tooltip={tooltip} title={tooltip}><small>{label}</small><span>{value}</span></span>;
}

function OriginLink({ href, label }: { href: string; label: string }): ReactElement {
  if (href.length === 0) {
    return <span className="origin-missing">{label}: source pending</span>;
  }

  return <a data-tooltip={href} href={href} onClick={(event) => openExternalLink(event, href)} rel="noreferrer" target="_blank" title={href}>{label} <FiExternalLink aria-hidden="true" /></a>;
}

function ToggleSwitch({ checked, disabled = false, label, onChange }: { checked: boolean; disabled?: boolean; label: string; onChange: (checked: boolean) => void }): ReactElement {
  return <button aria-pressed={checked} className={checked ? "managed-toggle checked" : "managed-toggle"} data-tooltip={disabled ? "Essential aidevops component; policy is locked on" : undefined} disabled={disabled} onClick={() => onChange(!checked)} title={disabled ? "Essential aidevops component; policy is locked on" : undefined} type="button"><span className="managed-toggle-label">{label}</span><span aria-hidden="true" className={checked ? "switch-track checked" : "switch-track"}><span /></span></button>;
}

function AppMeta({ className = "", label, value }: { className?: string; label: string; value: string }): ReactElement {
  return <span className={className.length > 0 ? `app-meta ${className}` : "app-meta"}><small>{label}</small><strong>{value}</strong></span>;
}

function AppLogLink({ job }: { job: GuiAppActionJobSummary }): ReactElement {
  return <a className="app-meta app-log-link" href={`#app-job-${job.id}`}><small>Logs</small><strong>{job.action} · {job.status}</strong></a>;
}

function AppActionButton({ action, app, commandPreview, disabled, onJob }: { action: GuiAppActionId; app: GuiManagedAppSummary; commandPreview: string; disabled: boolean; onJob: (job: GuiAppActionJobSummary) => void }): ReactElement {
  const icon = action === "install" ? <FiDownload /> : action === "update" ? <FiRefreshCw /> : action === "reinstall" ? <FiRepeat /> : <FiTrash2 />;
  const [confirmOpen, setConfirmOpen] = useState(false);

  async function runAction(): Promise<void> {
    if (disabled) {
      return;
    }

    try {
      const response = await fetch(`/api/apps/${encodeURIComponent(app.id)}/actions/${action}`, { method: "POST" });
      if (!response.ok) {
        console.error(`Failed to run ${action} for ${app.id}: ${response.status} ${response.statusText}`);
        return;
      }

      const envelope = await response.json() as GuiResponseEnvelope<GuiAppActionJobSummary>;
      if (!envelope.ok) {
        console.error(`Action ${action} for ${app.id} returned an error envelope: ${envelope.errors.join("; ")}`);
        return;
      }

      onJob(envelope.data);
    } catch (error) {
      console.error(`Network error running ${action} for ${app.id}:`, error);
    }
  }

  return <>
    <button aria-label={`${action} ${app.name}`} className={action === "remove" ? "app-action-button remove" : "app-action-button"} data-tooltip={commandPreview} disabled={disabled} onClick={() => setConfirmOpen(true)} type="button">{icon}<span>{action}</span></button>
    {confirmOpen ? <ConfirmActionModal action={action} app={app} commandPreview={commandPreview} close={() => setConfirmOpen(false)} confirm={() => { setConfirmOpen(false); void runAction(); }} /> : null}
  </>;
}

function ConfirmActionModal({ action, app, close, commandPreview, confirm }: { action: GuiAppActionId; app: GuiManagedAppSummary; close: () => void; commandPreview: string; confirm: () => void }): ReactElement {
  return (
    <div className="modal-backdrop" role="presentation">
      <section aria-modal="true" className="confirm-modal" role="dialog" aria-labelledby={`confirm-${app.id}-${action}`}>
        <p className="eyebrow">Confirm action</p>
        <h3 id={`confirm-${app.id}-${action}`}>{action} {app.name}?</h3>
        <p>This will start the allowlisted background command for this app.</p>
        <code>{commandPreview}</code>
        <div className="confirm-modal-actions">
          <button className="secondary-action" onClick={close} type="button">Cancel</button>
          <button className={action === "remove" ? "app-action-button remove" : "app-action-button"} onClick={confirm} type="button">Confirm</button>
        </div>
      </section>
    </div>
  );
}

function openExternalLink(event: ReactMouseEvent<HTMLAnchorElement>, href: string): void {
  event.stopPropagation();
  if (!shouldUseBrowserDefault(event)) {
    event.preventDefault();
    openExternalDestination(href);
  }
}

function shouldUseBrowserDefault(event: ReactMouseEvent<HTMLAnchorElement>): boolean {
  return [event.defaultPrevented, event.metaKey, event.ctrlKey, event.shiftKey, event.altKey].some(Boolean);
}

function openExternalDestination(href: string): void {
  if (document.documentElement.dataset.desktopShell === "macos") {
    window.location.assign(href);
  } else {
    const opened = window.open(href, "_blank", "noopener,noreferrer");
    if (opened === null) {
      window.location.assign(href);
    } else {
      opened.opener = null;
    }
  }
}
