import type { GuiAppActionId, GuiAppActionJobSummary, GuiManagedAppSummary, GuiResponseEnvelope, GuiStatusData } from "@aidevops/gui-shared";
import { type Dispatch, type MouseEvent as ReactMouseEvent, type ReactElement, type SetStateAction, useEffect, useRef, useState } from "react";
import type { IconType } from "react-icons";
import { FaApple, FaLinux, FaWindows } from "react-icons/fa";
import { FiChevronDown, FiCode, FiDownload, FiExternalLink, FiGlobe, FiMonitor, FiRefreshCw, FiRepeat, FiTerminal, FiTrash2 } from "react-icons/fi";
import { IoLogoAndroid } from "react-icons/io";
import { SiIos } from "react-icons/si";
import type { InventoryColumn } from "./app-model";
import { installationRows, text } from "./app-model";

interface DraftInventoryRow {
  id: string;
  values: Record<string, string>;
}

let draftRowCounter = 0;

export function AppsSurface({ status }: { status: GuiStatusData }): ReactElement {
  const [appCollection, setAppCollection] = useState<AppCollectionId>("aidevops");
  const [managedCategory, setManagedCategory] = useState<ManagedCategoryId>("core");
  const [recommendedPlatform, setRecommendedPlatform] = useState<RecommendedPlatformFilterId>("all");
  const [selectedJobId, setSelectedJobId] = useState<string | null>(null);
  const [expandedAppId, setExpandedAppId] = useState<string | null>(() => sortedManagedApps(status.managed_apps).find((app) => managedCategoryForApp(app) === "core")?.id ?? null);
  const [jobs, setJobs] = useState<Record<string, GuiAppActionJobSummary>>({});
  const [policyJobs, setPolicyJobs] = useState<Record<string, GuiAppActionJobSummary[]>>({});
  const [policyToggles, setPolicyToggles] = useState<ManagedPolicyToggleState>(() => readManagedPolicyToggles());
  const selectedJob = selectedJobId === null ? null : jobs[selectedJobId] ?? null;
  const managedApps = sortedManagedApps(status.managed_apps).map((app) => applyManagedPolicyToggles(app, policyToggles[app.id]));
  const visibleManagedApps = managedApps.filter((app) => managedCategoryForApp(app) === managedCategory);
  const visibleRecommendedApps = recommendedApps.filter((app) => recommendedPlatform === "all" || app.platforms.includes(recommendedPlatform));

  useEffect(() => {
    setExpandedAppId(visibleManagedApps[0]?.id ?? null);
  }, [managedCategory, status.managed_apps]);

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
    <section className="apps-surface" aria-label={text.apps}>
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
              policyJobs={policyJobs[app.id] ?? []}
              onJob={(job) => {
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
      </> : <RecommendedAppsSurface apps={visibleRecommendedApps} platform={recommendedPlatform} setPlatform={setRecommendedPlatform} />}
    </section>
  );
}

function ManagedAppPanel({ app, expanded, job, onJob, onPolicyToggle, onToggle, policyJobs }: { app: GuiManagedAppSummary; expanded: boolean; job: GuiAppActionJobSummary | null; onJob: (job: GuiAppActionJobSummary) => void; onPolicyToggle: (policy: ManagedPolicyId, value: boolean) => void; onToggle: () => void; policyJobs: GuiAppActionJobSummary[] }): ReactElement {
  const lockedPolicy = isEssentialManagedApp(app);

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
        <AppMeta label="Installed" value={app.installed_version} />
        <AppMeta label="Latest" value={app.latest_version} />
        <AppMeta label={text.path} value={app.install_path_ref} />
        {job ? <AppLogLink job={job} /> : null}
      </div>
      {job ? <AppActionTerminal job={job} /> : null}
      {policyJobs.map((policyJob) => <AppActionTerminal job={policyJob} key={policyJob.id} />)}
      {job === null && policyJobs.length === 0 ? <p className="empty-state compact-notice">No recent command output for this app. Run an action or change a policy toggle to open this app's terminal log.</p> : null}
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

  return <a href={href} onClick={(event) => openExternalLink(event, href)} rel="noreferrer" target="_blank" title={href}>{label} <FiExternalLink aria-hidden="true" /></a>;
}

function ToggleSwitch({ checked, disabled = false, label, onChange }: { checked: boolean; disabled?: boolean; label: string; onChange: (checked: boolean) => void }): ReactElement {
  return <button aria-pressed={checked} className={checked ? "managed-toggle checked" : "managed-toggle"} data-tooltip={disabled ? "Essential aidevops component; policy is locked on" : undefined} disabled={disabled} onClick={() => onChange(!checked)} title={disabled ? "Essential aidevops component; policy is locked on" : undefined} type="button"><span aria-hidden="true" className={checked ? "switch-track checked" : "switch-track"}><span /></span>{label}</button>;
}

function AppMeta({ label, value }: { label: string; value: string }): ReactElement {
  return <span className="app-meta"><small>{label}</small><strong>{value}</strong></span>;
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

function AppActionTerminal({ job }: { job: GuiAppActionJobSummary }): ReactElement {
  const outputRef = useRef<HTMLPreElement | null>(null);

  useEffect(() => {
    if (outputRef.current !== null) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight;
    }
  }, [job.output]);

  return (
    <section className="app-terminal" id={`app-job-${job.id}`} aria-label="App action terminal output">
      <header><strong>{job.app_id} {job.action}</strong><span>{job.status}{job.exit_code === null ? "" : ` (${job.exit_code})`}</span></header>
      <pre ref={outputRef}>{job.output.join("\n")}</pre>
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

function sortedManagedApps(apps: GuiManagedAppSummary[]): GuiManagedAppSummary[] {
  return [...apps].sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: "base" }));
}

function managedCategoryForApp(app: GuiManagedAppSummary): ManagedCategoryId {
  if (["core", "safety", "automation"].includes(app.category)) {
    return "core";
  }
  if (app.category.includes("cli")) {
    return "cli";
  }
  if (app.category.includes("ai")) {
    return "ai";
  }
  if (["desktop", "editor"].includes(app.category)) {
    return "desktop";
  }
  if (["terminal"].includes(app.category) || app.name.toLowerCase().includes("terminal")) {
    return "terminal";
  }

  return "cli";
}

function isEssentialManagedApp(app: GuiManagedAppSummary): boolean {
  return ["core", "safety", "automation"].includes(app.category);
}

type AppCollectionId = "aidevops" | "recommended";
type ManagedCategoryId = "core" | "ai" | "cli" | "desktop" | "terminal";
type RecommendedOsId = "all" | "macos" | "linux" | "windows" | "ios" | "android";
type RecommendedPlatformId = "webapp" | "saas" | "cli" | "api";
type RecommendedPlatformFilterId = "all" | RecommendedPlatformId;
type ManagedPolicyId = "setup" | "update";
type ManagedPolicyToggleState = Record<string, Partial<Record<ManagedPolicyId, boolean>>>;

interface TabOption<T extends string> {
  id: T;
  label: string;
}

interface RecommendedApp {
  name: string;
  description: string;
  websiteUrl: string;
  alternativeToUrl?: string;
  repoUrl?: string;
  iosUrl?: string;
  androidUrl?: string;
  fdroidUrl?: string;
  obtainiumUrl?: string;
  os: RecommendedOsId[];
  platforms: RecommendedPlatformId[];
}

const appCollectionTabs: TabOption<AppCollectionId>[] = [
  { id: "aidevops", label: "aidevops" },
  { id: "recommended", label: "Recommended" },
];

const managedCategoryTabs: TabOption<ManagedCategoryId>[] = [
  { id: "core", label: "Core" },
  { id: "ai", label: "AI" },
  { id: "cli", label: "CLI" },
  { id: "desktop", label: "Desktop" },
  { id: "terminal", label: "Terminal" },
];

const recommendedPlatformTabs: TabOption<RecommendedPlatformFilterId>[] = [
  { id: "all", label: "All" },
  { id: "webapp", label: "WebApp" },
  { id: "saas", label: "SaaS" },
  { id: "cli", label: "CLI" },
  { id: "api", label: "API" },
];

const recommendedApps = ([
  { name: "Affinity Studio", description: "Creative design suite.", websiteUrl: "https://www.affinity.studio/", alternativeToUrl: "https://alternativeto.net/software/affinity-1/", os: ["macos", "windows", "ios"], platforms: [] },
  { name: "Bitwarden", description: "Open source password manager.", websiteUrl: "https://bitwarden.com", alternativeToUrl: "https://alternativeto.net/software/bitwarden--free-password-manager/", repoUrl: "https://github.com/bitwarden", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["webapp", "saas", "cli", "api"] },
  { name: "Brave Browser", description: "Privacy-focused web browser.", websiteUrl: "https://brave.com/", alternativeToUrl: "https://alternativeto.net/software/brave/", os: ["macos", "linux", "windows", "ios", "android"], platforms: [] },
  { name: "Cloudron", description: "Self-hosted app platform.", websiteUrl: "https://www.cloudron.io/", alternativeToUrl: "https://alternativeto.net/software/cloudron/", os: ["linux"], platforms: ["webapp", "cli", "api"] },
  { name: "Collabora Online", description: "Online office collaboration.", websiteUrl: "https://www.collaboraonline.com/collabora-online/", alternativeToUrl: "https://alternativeto.net/software/collabora-online/", os: ["linux"], platforms: ["webapp", "api"] },
  { name: "Cometly", description: "Marketing attribution analytics.", websiteUrl: "https://www.cometly.com/", os: [], platforms: ["saas", "api"] },
  { name: "DaVinci Resolve", description: "Professional video editing, color, VFX, and audio post-production.", websiteUrl: "https://www.blackmagicdesign.com/products/davinciresolve/", alternativeToUrl: "https://alternativeto.net/software/davinci-resolve/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "DocuSeal", description: "Open source document signing.", websiteUrl: "https://www.docuseal.com/", alternativeToUrl: "https://alternativeto.net/software/docuseal/", os: ["linux"], platforms: ["webapp", "saas", "api"] },
  { name: "Element", description: "Matrix messaging client.", websiteUrl: "https://element.io/", alternativeToUrl: "https://alternativeto.net/software/element-app/", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["webapp"] },
  { name: "Enpass", description: "Offline-first password manager.", websiteUrl: "https://www.enpass.io/", alternativeToUrl: "https://alternativeto.net/software/enpass/", os: ["macos", "linux", "windows", "ios", "android"], platforms: [] },
  { name: "EspoCRM", description: "Open source CRM.", websiteUrl: "https://www.espocrm.com/", alternativeToUrl: "https://alternativeto.net/software/espocrm/", os: ["linux"], platforms: ["webapp", "saas", "api"] },
  { name: "Fathom Analytics", description: "Privacy-first analytics.", websiteUrl: "https://usefathom.com/", alternativeToUrl: "https://alternativeto.net/software/fathom-analytics/", os: [], platforms: ["saas", "api"] },
  { name: "FontBase", description: "Font management and reference tool.", websiteUrl: "https://fontba.se/", alternativeToUrl: "https://alternativeto.net/software/fontbase/", os: ["macos"], platforms: [] },
  { name: "Forgejo", description: "Self-hosted Git forge.", websiteUrl: "https://forgejo.org/", alternativeToUrl: "https://alternativeto.net/software/forgejo/", os: ["linux"], platforms: ["webapp", "cli", "api"] },
  { name: "Ghost", description: "Publishing platform.", websiteUrl: "https://ghost.org/", alternativeToUrl: "https://alternativeto.net/software/ghost/", os: ["linux"], platforms: ["webapp", "saas", "cli", "api"] },
  { name: "Gitea", description: "Self-hosted Git service.", websiteUrl: "https://about.gitea.com/", alternativeToUrl: "https://alternativeto.net/software/gitea/", os: ["linux", "windows"], platforms: ["webapp", "cli", "api"] },
  { name: "GitLab", description: "DevSecOps and Git hosting platform.", websiteUrl: "https://gitlab.com/", alternativeToUrl: "https://alternativeto.net/software/gitlab/", os: ["linux"], platforms: ["webapp", "saas", "cli", "api"] },
  { name: "LibreOffice", description: "Open source office suite.", websiteUrl: "https://www.libreoffice.org/", alternativeToUrl: "https://alternativeto.net/software/libreoffice/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "LocalWP", description: "Local WordPress development.", websiteUrl: "https://localwp.com/", alternativeToUrl: "https://alternativeto.net/software/local-by-flywheel/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "Matomo", description: "Open analytics platform.", websiteUrl: "https://matomo.org/", alternativeToUrl: "https://alternativeto.net/software/piwik/", os: ["linux"], platforms: ["webapp", "saas", "api"] },
  { name: "Nextcloud", description: "Open source content collaboration platform.", websiteUrl: "https://nextcloud.com/", alternativeToUrl: "https://alternativeto.net/software/nextcloud/", repoUrl: "https://github.com/nextcloud", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["webapp", "saas", "api"] },
  { name: "Nextcloud Talk", description: "Open source video calls, chat, and collaboration for Nextcloud.", websiteUrl: "https://nextcloud.com/talk/", repoUrl: "https://github.com/nextcloud/spreed", iosUrl: "https://apps.apple.com/us/app/nextcloud-talk/id1296825574", androidUrl: "https://play.google.com/store/apps/details?id=com.nextcloud.talk2&hl=en", os: ["ios", "android"], platforms: ["webapp"] },
  { name: "OBS Studio", description: "Open source video recording and live streaming.", websiteUrl: "https://obsproject.com/", alternativeToUrl: "https://alternativeto.net/software/open-broadcaster-software/", repoUrl: "https://github.com/obsproject/obs-studio", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "ONLYOFFICE", description: "Office and document collaboration.", websiteUrl: "https://www.onlyoffice.com/", alternativeToUrl: "https://alternativeto.net/software/onlyoffice/", repoUrl: "https://github.com/ONLYOFFICE/", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["webapp", "saas", "api"] },
  { name: "OpenScreen", description: "Open screen-sharing project.", websiteUrl: "https://github.com/getopenscreen/openscreen/releases", alternativeToUrl: "https://alternativeto.net/software/openscreen/", repoUrl: "https://github.com/getopenscreen/openscreen", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "Osaurus", description: "AI app workspace.", websiteUrl: "https://osaurus.ai/", alternativeToUrl: "https://alternativeto.net/software/osaurus/", os: ["macos"], platforms: [] },
  { name: "Parallels Desktop", description: "Run Windows, Linux, and virtual machines on macOS.", websiteUrl: "https://www.parallels.com/products/desktop/", alternativeToUrl: "https://alternativeto.net/software/parallels-desktop/about/", os: ["macos"], platforms: [] },
  { name: "PDF Studio", description: "PDF editor.", websiteUrl: "https://www.qoppa.com/pdfstudio/", alternativeToUrl: "https://alternativeto.net/software/qoppa-pdf-studio/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "Pixelmator Pro", description: "Professional image editor for macOS.", websiteUrl: "https://www.apple.com/pixelmator-pro/", os: ["macos"], platforms: [] },
  { name: "PostHog", description: "Product analytics platform.", websiteUrl: "https://posthog.com/", alternativeToUrl: "https://alternativeto.net/software/posthog/", os: ["linux"], platforms: ["webapp", "saas", "cli", "api"] },
  { name: "Postiz", description: "Social media scheduling.", websiteUrl: "https://postiz.com/", alternativeToUrl: "https://alternativeto.net/software/postiz/", os: ["linux"], platforms: ["webapp", "saas", "api"] },
  { name: "PrivateBin", description: "Zero-knowledge pastebin.", websiteUrl: "https://privatebin.info/", alternativeToUrl: "https://alternativeto.net/software/privatebin/", repoUrl: "https://github.com/PrivateBin/PrivateBin", os: ["linux"], platforms: ["webapp", "api"] },
  { name: "Proxmox", description: "Virtualization platform.", websiteUrl: "https://www.proxmox.com/", alternativeToUrl: "https://alternativeto.net/software/proxmox-virtual-environment/", os: ["linux"], platforms: ["webapp", "cli", "api"] },
  { name: "QuickFile", description: "Accounting platform.", websiteUrl: "https://www.quickfile.co.uk/", os: [], platforms: ["saas", "api"] },
  { name: "Reframed", description: "Creative framing utility.", websiteUrl: "https://www.reframed.dev/", alternativeToUrl: "https://alternativeto.net/software/reframed/", os: ["macos"], platforms: [] },
  { name: "Rybbit", description: "Web analytics.", websiteUrl: "https://rybbit.com/", alternativeToUrl: "https://alternativeto.net/software/rybbit/", os: ["linux"], platforms: ["webapp", "saas", "api"] },
  { name: "SchildiChat", description: "Matrix messaging client.", websiteUrl: "https://schildi.chat/", alternativeToUrl: "https://alternativeto.net/software/schildichat/", os: ["macos", "linux", "windows", "android"], platforms: ["webapp"] },
  { name: "ScreenFlow", description: "Screen recording and editing.", websiteUrl: "https://www.telestream.net/screenflow/", alternativeToUrl: "https://alternativeto.net/software/screenflow/", os: ["macos", "ios"], platforms: [] },
  { name: "SEO Utils", description: "Desktop SEO tools.", websiteUrl: "https://seoutils.app/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "Shottr", description: "macOS screenshot utility.", websiteUrl: "https://shottr.cc/", alternativeToUrl: "https://alternativeto.net/software/shottr/", os: ["macos"], platforms: [] },
  { name: "Signal", description: "Private messenger.", websiteUrl: "https://signal.org/", alternativeToUrl: "https://alternativeto.net/software/signal-private-messenger/", os: ["macos", "linux", "windows", "ios", "android"], platforms: [] },
  { name: "SimpleX Chat", description: "Private messenger with no user IDs.", websiteUrl: "https://simplex.chat/", alternativeToUrl: "https://alternativeto.net/software/simplex-chat/about/", repoUrl: "https://github.com/simplex-chat", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["cli"] },
  { name: "Telegram", description: "Cloud-based mobile and desktop messaging app.", websiteUrl: "https://telegram.org/", iosUrl: "https://telegram.org/dl/ios", androidUrl: "https://telegram.org/android", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["webapp", "api"] },
  { name: "Thunderbird", description: "Email and calendar app.", websiteUrl: "https://www.thunderbird.net/", alternativeToUrl: "https://alternativeto.net/software/mozilla-thunderbird/about/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "Ubicloud", description: "Open cloud platform.", websiteUrl: "https://www.ubicloud.com/", alternativeToUrl: "https://alternativeto.net/software/ubicloud/about/", repoUrl: "https://github.com/ubicloud/ubicloud", os: ["linux"], platforms: ["webapp", "saas", "cli", "api"] },
  { name: "Vaultwarden", description: "Alternative Bitwarden server implementation.", websiteUrl: "https://github.com/dani-garcia/vaultwarden", alternativeToUrl: "https://alternativeto.net/software/vaultwarden/", repoUrl: "https://github.com/dani-garcia/vaultwarden", os: ["linux"], platforms: ["webapp", "api"] },
  { name: "VideoProc", description: "Video processing toolkit.", websiteUrl: "https://www.videoproc.com/", alternativeToUrl: "https://alternativeto.net/software/videoproc/about/", os: ["macos", "windows"], platforms: [] },
  { name: "VirtualBox", description: "Virtualization app.", websiteUrl: "https://www.virtualbox.org/", alternativeToUrl: "https://alternativeto.net/software/virtualbox/about/", os: ["macos", "linux", "windows"], platforms: ["cli"] },
  { name: "WordPress", description: "Open source publishing platform.", websiteUrl: "https://wordpress.org/", alternativeToUrl: "https://alternativeto.net/software/wordpress/about/", os: ["linux"], platforms: ["webapp", "saas", "cli", "api"] },
] satisfies RecommendedApp[]).sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: "base" }));

function TabNav<T extends string>({ label, onChange, tabs, value }: { label: string; onChange: (value: T) => void; tabs: TabOption<T>[]; value: T }): ReactElement {
  return <div aria-label={label} className="pill-tabs app-subnav" role="tablist">{tabs.map((tab) => <button aria-selected={value === tab.id} className={value === tab.id ? "active" : ""} key={tab.id} onClick={() => onChange(tab.id)} role="tab" type="button">{tab.label}</button>)}</div>;
}

function RecommendedAppsSurface({ apps, platform, setPlatform }: { apps: RecommendedApp[]; platform: RecommendedPlatformFilterId; setPlatform: (platform: RecommendedPlatformFilterId) => void }): ReactElement {
  return <>
    <TabNav label="Recommended app platform filters" tabs={recommendedPlatformTabs} value={platform} onChange={setPlatform} />
    <div className="recommended-app-grid">
      {apps.map((app) => <RecommendedAppCard app={app} key={app.name} setPlatform={setPlatform} />)}
    </div>
  </>;
}

function RecommendedAppCard({ app, setPlatform }: { app: RecommendedApp; setPlatform: (platform: RecommendedPlatformFilterId) => void }): ReactElement {
  return <article className="recommended-app-card">
    <div>
      <strong>{app.name}</strong>
      <p>{app.description}</p>
    </div>
    <div className="app-icon-groups">
      <PlatformIconList platforms={app.platforms} setPlatform={setPlatform} />
      <OsIconList os={app.os} />
    </div>
    <div className="managed-app-links plain-links">
      <OriginLink href={app.websiteUrl} label={text.website} />
      {app.alternativeToUrl ? <OriginLink href={app.alternativeToUrl} label="AlternativeTo" /> : null}
      {app.repoUrl ? <OriginLink href={app.repoUrl} label="Repo" /> : null}
      {app.iosUrl ? <OriginLink href={app.iosUrl} label="iOS" /> : null}
      {app.androidUrl ? <OriginLink href={app.androidUrl} label="Android" /> : null}
      {app.fdroidUrl ? <OriginLink href={app.fdroidUrl} label="F-Droid" /> : null}
      {app.obtainiumUrl ? <OriginLink href={app.obtainiumUrl} label="Obtainium" /> : null}
    </div>
  </article>;
}

function PlatformIconList({ platforms, setPlatform }: { platforms: RecommendedPlatformId[]; setPlatform: (platform: RecommendedPlatformFilterId) => void }): ReactElement | null {
  if (platforms.length === 0) {
    return null;
  }

  return <span className="os-icon-list platform-icon-list">{platforms.map((platform) => <PlatformIcon id={platform} key={platform} setPlatform={setPlatform} />)}</span>;
}

function PlatformIcon({ id, setPlatform }: { id: RecommendedPlatformId; setPlatform: (platform: RecommendedPlatformFilterId) => void }): ReactElement {
  const iconMap: Record<RecommendedPlatformId, { Icon: IconType; label: string }> = {
    webapp: { Icon: FiMonitor, label: "WebApp" },
    saas: { Icon: FiGlobe, label: "SaaS" },
    cli: { Icon: FiTerminal, label: "CLI" },
    api: { Icon: FiCode, label: "API" },
  };
  const { Icon, label } = iconMap[id];

  return <button aria-label={`Filter by ${label}`} data-tooltip={`Filter by ${label}`} onClick={() => setPlatform(id)} title={`Filter by ${label}`} type="button"><Icon aria-hidden="true" focusable="false" /></button>;
}

function OsIconList({ os }: { os: RecommendedOsId[] }): ReactElement | null {
  if (os.length === 0) {
    return null;
  }

  return <span className="os-icon-list">{os.map((item) => <OsIcon id={item} key={item} />)}</span>;
}

function OsIcon({ id }: { id: RecommendedOsId }): ReactElement {
  const iconMap: Record<RecommendedOsId, { Icon: IconType; label: string }> = {
    all: { Icon: FiGlobe, label: "Web app" },
    macos: { Icon: FaApple, label: "macOS" },
    linux: { Icon: FaLinux, label: "Linux" },
    windows: { Icon: FaWindows, label: "Windows" },
    ios: { Icon: SiIos, label: "iOS" },
    android: { Icon: IoLogoAndroid, label: "Android" },
  };
  const { Icon, label } = iconMap[id];

  return <span aria-label={label} data-tooltip={label} role="img" title={label}><Icon aria-hidden="true" focusable="false" /></span>;
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

function openExternalLink(event: ReactMouseEvent<HTMLAnchorElement>, href: string): void {
  event.stopPropagation();
  if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
    return;
  }

  const opened = window.open(href, "_blank", "noopener,noreferrer");
  if (opened !== null) {
    event.preventDefault();
    opened.opener = null;
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
