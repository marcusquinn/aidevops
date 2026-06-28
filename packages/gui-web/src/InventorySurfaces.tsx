import type { GuiAppActionId, GuiAppActionJobSummary, GuiManagedAppSummary, GuiResponseEnvelope, GuiStatusData } from "@aidevops/gui-shared";
import { type CSSProperties, type Dispatch, type FocusEvent as ReactFocusEvent, type MouseEvent as ReactMouseEvent, type PointerEvent as ReactPointerEvent, type ReactElement, type ReactNode, type SetStateAction, useEffect, useRef, useState } from "react";
import { FiChevronDown, FiDownload, FiExternalLink, FiRefreshCw, FiRepeat, FiTrash2, FiX } from "react-icons/fi";
import type { InventoryColumn } from "./app-model";
import { installationRows, text } from "./app-model";
import { RecommendedAppsSurface, nextRecommendedFilterValue, recommendedAppMatchesFilters, recommendedApps, type RecommendedOsId, type RecommendedPlatformFilterId } from "./RecommendedAppsSurface";

export { nextRecommendedFilterValue } from "./RecommendedAppsSurface";

interface DraftInventoryRow {
  id: string;
  values: Record<string, string>;
}

let draftRowCounter = 0;

export function AppsSurface({ status }: { status: GuiStatusData }): ReactElement {
  const [appCollection, setAppCollection] = useState<AppCollectionId>("aidevops");
  const [managedCategory, setManagedCategory] = useState<ManagedCategoryId>("core");
  const [recommendedPlatform, setRecommendedPlatform] = useState<RecommendedPlatformFilterId>("all");
  const [recommendedOs, setRecommendedOs] = useState<RecommendedOsId>("all");
  const [selectedJobId, setSelectedJobId] = useState<string | null>(null);
  const [expandedAppId, setExpandedAppId] = useState<string | null>(() => sortedManagedApps(status.managed_apps).find((app) => managedCategoryForApp(app) === "core")?.id ?? null);
  const [jobs, setJobs] = useState<Record<string, GuiAppActionJobSummary>>({});
  const [dismissedJobIds, setDismissedJobIds] = useState<Set<string>>(() => new Set());
  const [tooltip, setTooltip] = useState<AppTooltipState | null>(null);
  const [policyJobs, setPolicyJobs] = useState<Record<string, GuiAppActionJobSummary[]>>({});
  const [policyToggles, setPolicyToggles] = useState<ManagedPolicyToggleState>(() => readManagedPolicyToggles());
  const selectedJob = selectedJobId === null ? null : jobs[selectedJobId] ?? null;
  const managedApps = sortedManagedApps(status.managed_apps).map((app) => applyManagedPolicyToggles(app, policyToggles[app.id]));
  const visibleManagedApps = managedApps.filter((app) => managedCategoryForApp(app) === managedCategory);
  const firstVisibleManagedAppId = visibleManagedApps[0]?.id ?? null;
  const visibleRecommendedApps = recommendedApps.filter((app) => recommendedAppMatchesFilters(app, recommendedPlatform, recommendedOs));
  const selectRecommendedPlatform = (value: RecommendedPlatformFilterId) => setRecommendedPlatform((current) => nextRecommendedFilterValue(current, value, "all"));
  const selectRecommendedOs = (value: RecommendedOsId) => setRecommendedOs((current) => nextRecommendedFilterValue(current, value, "all"));

  useEffect(() => {
    setExpandedAppId(firstVisibleManagedAppId);
  }, [firstVisibleManagedAppId]);

  const runningJobIdsKey = Object.values(jobs).filter((job) => job.status === "running").map((job) => job.id).sort().join("|");

  useEffect(() => {
    const runningJobIds = runningJobIdsKey.split("|").filter(Boolean);
    if (runningJobIds.length === 0) {
      return undefined;
    }

    const refreshRunningJobs = () => {
      for (const jobId of runningJobIds) {
        void refreshJob(jobId, setJobs);
      }
    };
    refreshRunningJobs();
    const timer = window.setInterval(refreshRunningJobs, 1_500);

    return () => window.clearInterval(timer);
  }, [runningJobIdsKey]);

  return (
    <section className="apps-surface" aria-label={text.apps} onBlur={() => setTooltip(null)} onFocus={showFocusedAppTooltip(setTooltip)} onPointerLeave={() => setTooltip(null)} onPointerMove={showPointedAppTooltip(setTooltip)}>
      <div className="section-heading">
        <p className="eyebrow">{text.infrastructure}</p>
        <h2>{text.apps}</h2>
        <p>{text.appsIntro}</p>
      </div>
      <TabNav label="Apps collections" tabs={appCollectionTabs} value={appCollection} onChange={(value) => setAppCollection(value)} />
      {appCollection === "aidevops" ? <>
        <TabNav label="aidevops app groups" tabs={managedCategoryTabs} value={managedCategory} onChange={(value) => setManagedCategory(value)} />
        <div className="managed-app-list">
          {visibleManagedApps.map((app) => (
            <ManagedAppPanel
              app={app}
              expanded={expandedAppId === app.id}
              job={jobForApp(app.id, jobs, selectedJob)}
              key={app.id}
              dismissedJobIds={dismissedJobIds}
              policyJobs={policyJobs[app.id] ?? []}
              onDismissJob={(jobId) => setDismissedJobIds((current) => new Set([...current, jobId]))}
              onJob={(job) => {
                setDismissedJobIds((current) => {
                  const next = new Set(current);
                  next.delete(job.id);
                  return next;
                });
                setJobs((current) => ({ ...current, [job.id]: job }));
                setSelectedJobId(job.id);
                setExpandedAppId(app.id);
              }}
              onPolicyToggle={(policy, value) => {
                setPolicyToggles((current) => {
                  const next = { ...current, [app.id]: { ...current[app.id], [policy]: value } };
                  writeManagedPolicyToggles(next);
                  return next;
                });
                const policyJob = createPolicyJob(app.id, policy, value);
                setPolicyJobs((current) => ({ ...current, [app.id]: [...(current[app.id] ?? []), policyJob] }));
                setSelectedJobId(policyJob.id);
                setExpandedAppId(app.id);
              }}
              onToggle={() => setExpandedAppId((current) => current === app.id ? null : app.id)}
            />
          ))}
        </div>
        <p className="empty-state compact-notice">Install/update actions run as allowlisted background jobs and stream inside each app panel. xterm.js with a node-pty bridge is the right next step for full TUI apps such as OpenCode; this view starts with non-interactive command logs.</p>
      </> : <RecommendedAppsSurface apps={visibleRecommendedApps} os={recommendedOs} platform={recommendedPlatform} setOs={selectRecommendedOs} setPlatform={selectRecommendedPlatform} />}
      {tooltip === null ? null : <AppTooltip tooltip={tooltip} />}
    </section>
  );
}

function ManagedAppPanel({ app, dismissedJobIds, expanded, job, onDismissJob, onJob, onPolicyToggle, onToggle, policyJobs }: { app: GuiManagedAppSummary; dismissedJobIds: Set<string>; expanded: boolean; job: GuiAppActionJobSummary | null; onDismissJob: (jobId: string) => void; onJob: (job: GuiAppActionJobSummary) => void; onPolicyToggle: (policy: ManagedPolicyId, value: boolean) => void; onToggle: () => void; policyJobs: GuiAppActionJobSummary[] }): ReactElement {
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

    const response = await fetch(`/api/apps/${encodeURIComponent(app.id)}/actions/${action}`, { method: "POST" });
    const envelope = await response.json() as GuiResponseEnvelope<GuiAppActionJobSummary>;
    onJob(envelope.data);
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

function AppActionTerminal({ job, onDismiss }: { job: GuiAppActionJobSummary; onDismiss: (jobId: string) => void }): ReactElement {
  const outputRef = useRef<HTMLPreElement | null>(null);

  useEffect(() => {
    if (outputRef.current !== null) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight;
    }
  }, [job.output.length]);

  return (
    <section className="app-terminal" id={`app-job-${job.id}`} aria-label="App action terminal output">
      <header><strong>{job.app_id} {job.action}</strong><span>{terminalStatusLabel(job)}</span><button aria-label={`Dismiss ${job.app_id} ${job.action} terminal output`} className="terminal-close-button" onClick={() => onDismiss(job.id)} title="Dismiss terminal output" type="button"><FiX aria-hidden="true" /></button></header>
      <pre ref={outputRef}>{renderTerminalOutput(job.output)}</pre>
    </section>
  );
}

function terminalStatusLabel(job: GuiAppActionJobSummary): string {
  if (job.status === "running") {
    return "running";
  }
  if (job.exit_code === null) {
    return job.status;
  }
  return `${job.status} · exit ${job.exit_code}`;
}

function renderTerminalOutput(lines: string[]): ReactNode[] {
  return lines.flatMap((line, index) => [
    ...renderAnsiLine(line, `line-${index}`),
    index === lines.length - 1 ? null : "\n",
  ]).filter((node): node is ReactNode => node !== null);
}

function renderAnsiLine(line: string, keyPrefix: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  const ansiPattern = new RegExp("\\x1b\\[([0-9;]*)m", "g");
  let activeClass = "";
  let lastIndex = 0;
  let match = ansiPattern.exec(line);

  while (match !== null) {
    if (match.index > lastIndex) {
      nodes.push(terminalSpan(line.slice(lastIndex, match.index), activeClass, `${keyPrefix}-${nodes.length}`));
    }
    activeClass = ansiClassForCodes(match[1]);
    lastIndex = ansiPattern.lastIndex;
    match = ansiPattern.exec(line);
  }

  if (lastIndex < line.length) {
    nodes.push(terminalSpan(line.slice(lastIndex), activeClass, `${keyPrefix}-${nodes.length}`));
  }

  if (nodes.length === 0) {
    nodes.push(terminalSpan(line, activeClass, `${keyPrefix}-0`));
  }

  return nodes;
}

function terminalSpan(textValue: string, className: string, key: string): ReactNode {
  const promptClass = textValue.startsWith("$ ") ? "ansi-prompt" : "";
  const combinedClass = [className, promptClass].filter(Boolean).join(" ");
  return combinedClass.length > 0 ? <span className={combinedClass} key={key}>{textValue}</span> : textValue;
}

function ansiClassForCodes(rawCodes: string): string {
  const codes = rawCodes.length === 0 ? [0] : rawCodes.split(";").map((code) => Number.parseInt(code, 10));
  const colorCode = [...codes].reverse().find((code) => (code >= 30 && code <= 37) || (code >= 90 && code <= 97));
  if (colorCode === undefined) {
    return "";
  }
  return `ansi-fg-${colorCode}`;
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

  let latestJob: GuiAppActionJobSummary | null = null;
  for (const job of Object.values(jobs)) {
    if (job.app_id === appId && (latestJob === null || job.started_at > latestJob.started_at)) {
      latestJob = job;
    }
  }

  return latestJob;
}

function sortedManagedApps(apps: GuiManagedAppSummary[]): GuiManagedAppSummary[] {
  return [...apps].sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: "base" }));
}

function managedCategoryForApp(app: GuiManagedAppSummary): ManagedCategoryId {
  const exactCategory = managedCategoryByExactName[app.category];
  return exactCategory ?? managedCategoryByKeyword(app);
}

function managedCategoryByKeyword(app: GuiManagedAppSummary): ManagedCategoryId {
  const loweredName = app.name.toLowerCase();
  const categoryRules: Array<{ matches: boolean; category: ManagedCategoryId }> = [
    { matches: app.category.includes("cli"), category: "cli" },
    { matches: app.category.includes("ai"), category: "ai" },
    { matches: loweredName.includes("terminal"), category: "terminal" },
  ];

  return categoryRules.find((rule) => rule.matches)?.category ?? "cli";
}

function isEssentialManagedApp(app: GuiManagedAppSummary): boolean {
  return ["core", "safety", "automation"].includes(app.category);
}

type AppCollectionId = "aidevops" | "recommended";
type ManagedCategoryId = "core" | "ai" | "cli" | "desktop" | "terminal";
type ManagedPolicyId = "setup" | "update";
type ManagedPolicyToggleState = Record<string, Partial<Record<ManagedPolicyId, boolean>>>;

interface TabOption<T extends string> {
  id: T;
  label: string;
}

const appCollectionTabs: TabOption<AppCollectionId>[] = [
  { id: "aidevops", label: "AIDevOps" },
  { id: "recommended", label: "Recommended" },
];

const managedCategoryByExactName: Record<string, ManagedCategoryId> = {
  automation: "core",
  core: "core",
  desktop: "desktop",
  editor: "desktop",
  safety: "core",
  terminal: "terminal",
};

const managedCategoryTabs: TabOption<ManagedCategoryId>[] = [
  { id: "core", label: "Core" },
  { id: "ai", label: "AI" },
  { id: "cli", label: "CLI" },
  { id: "desktop", label: "Desktop" },
  { id: "terminal", label: "Terminal" },
];

function TabNav<T extends string>({ label, onChange, tabs, value }: { label: string; onChange: (value: T) => void; tabs: TabOption<T>[]; value: T }): ReactElement {
  return <div aria-label={label} className="pill-tabs app-subnav" role="tablist">{tabs.map((tab) => <button aria-selected={value === tab.id} className={value === tab.id ? "active" : ""} key={tab.id} onClick={() => onChange(tab.id)} role="tab" type="button">{tab.label}</button>)}</div>;
}

function applyManagedPolicyToggles(app: GuiManagedAppSummary, policy: Partial<Record<ManagedPolicyId, boolean>> | undefined): GuiManagedAppSummary {
  if (policy === undefined) {
    return app;
  }

  return {
    ...app,
    aidevops_install: policy.setup ?? app.aidevops_install,
    aidevops_update: policy.update ?? app.aidevops_update,
  };
}

function createPolicyJob(appId: string, policy: ManagedPolicyId, value: boolean): GuiAppActionJobSummary {
  const mode = value ? "on" : "off";
  const command = `aidevops app policy set ${appId} --${policy === "setup" ? "setup-installs" : "update-maintains"} ${mode}`;
  const now = new Date().toISOString();

  return {
    id: `policy-${appId}-${policy}-${Date.now()}`,
    app_id: appId,
    action: "update",
    status: "completed",
    command_preview: command,
    started_at: now,
    finished_at: now,
    exit_code: 0,
    output: [
      `$ ${command}`,
      `Saved local aidevops.app policy override for ${appId}: ${policy}=${mode}.`,
      "Persistence: browser localStorage key aidevops-gui-managed-app-policy.",
    ],
  };
}

function readManagedPolicyToggles(): ManagedPolicyToggleState {
  if (typeof window === "undefined") {
    return {};
  }

  try {
    const raw = window.localStorage.getItem("aidevops-gui-managed-app-policy");
    return raw === null ? {} : JSON.parse(raw) as ManagedPolicyToggleState;
  } catch {
    return {};
  }
}

function writeManagedPolicyToggles(policy: ManagedPolicyToggleState): void {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.setItem("aidevops-gui-managed-app-policy", JSON.stringify(policy));
}

interface AppTooltipState {
  text: string;
  x: number;
  y: number;
}

function showPointedAppTooltip(setTooltip: Dispatch<SetStateAction<AppTooltipState | null>>) {
  return (event: ReactPointerEvent<HTMLElement>) => {
    const target = tooltipTarget(event.target);
    setTooltip(target === null ? null : tooltipForElement(target));
  };
}

function showFocusedAppTooltip(setTooltip: Dispatch<SetStateAction<AppTooltipState | null>>) {
  return (event: ReactFocusEvent<HTMLElement>) => {
    const target = tooltipTarget(event.target);
    if (target !== null) {
      setTooltip(tooltipForElement(target));
    }
  };
}

function tooltipTarget(target: EventTarget): HTMLElement | null {
  return target instanceof HTMLElement ? target.closest<HTMLElement>("[data-tooltip]") : null;
}

function tooltipForElement(element: HTMLElement): AppTooltipState | null {
  const textValue = element.dataset.tooltip;
  if (textValue === undefined || textValue.length === 0) {
    return null;
  }

  const rect = element.getBoundingClientRect();
  return { text: textValue, x: rect.left + (rect.width / 2), y: rect.top };
}

function AppTooltip({ tooltip }: { tooltip: AppTooltipState }): ReactElement {
  const style = {
    "--tooltip-x": `${tooltip.x}px`,
    "--tooltip-y": `${tooltip.y}px`,
  } as CSSProperties;

  return <div className="app-global-tooltip" role="tooltip" style={style}>{tooltip.text}</div>;
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
