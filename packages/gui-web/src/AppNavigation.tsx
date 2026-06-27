/* jshint esversion: 11 */
import type { GuiMachineSummary, GuiStatusData } from "@aidevops/gui-shared";
import { useEffect, useState, type ReactNode } from "react";
import type { IconType } from "react-icons";
import {
  FiBookmark,
  FiBox,
  FiBriefcase,
  FiCalendar,
  FiChevronDown,
  FiChevronLeft,
  FiChevronRight,
  FiChevronUp,
  FiClock,
  FiDownloadCloud,
  FiFileText,
  FiFolder,
  FiGitBranch,
  FiGlobe,
  FiGrid,
  FiHash,
  FiHardDrive,
  FiLink,
  FiLink2,
  FiList,
  FiLock,
  FiMail,
  FiMessageSquare,
  FiMonitor,
  FiPackage,
  FiRotateCcw,
  FiServer,
  FiSettings,
  FiShield,
  FiTerminal,
  FiUsers,
} from "react-icons/fi";
import type { ConversationMode, FontPreference, FontSizePreference, ShellMode, SidebarMode, SurfaceIconName, SurfaceId, SurfaceNavGroup, SurfaceNavItem, ThemePreference } from "./app-model";
import { DEFAULT_ACCENT_HUE, dashboardNavItem, fontFamilyForPreference, fontOptions, fontSizeOptions, navGroups, sidebarModeForSurface, surfaceRecordCounts, text } from "./app-model";
import { VaultPadlock, vaultCollectionForSurface } from "./VaultBadges";

const surfaceIcons: Record<SurfaceIconName, IconType> = {
  apps: FiBox,
  bookmark: FiBookmark,
  brand: FiBriefcase,
  calendar: FiCalendar,
  chain: FiLink2,
  clock: FiClock,
  device: FiMonitor,
  document: FiFileText,
  download: FiDownloadCloud,
  folder: FiFolder,
  git: FiGitBranch,
  globe: FiGlobe,
  grid: FiGrid,
  hardDrive: FiHardDrive,
  link: FiLink,
  list: FiList,
  lock: FiLock,
  mail: FiMail,
  message: FiMessageSquare,
  note: FiMessageSquare,
  package: FiPackage,
  server: FiServer,
  settings: FiSettings,
  shield: FiShield,
  terminal: FiTerminal,
  users: FiUsers,
};

export function hueFromInputValue(value: string): number | null {
  const trimmedValue = value.trim();

  if (trimmedValue.length === 0) {
    return null;
  }

  const hue = Number(trimmedValue);

  if (!Number.isInteger(hue)) {
    return null;
  }

  return Math.min(359, Math.max(0, hue));
}

export function SurfaceGlyph({ icon }: { icon: SurfaceIconName }) {
  const Icon = surfaceIcons[icon];

  return <Icon aria-hidden="true" focusable="false" />;
}

export function MachineRail({ machine }: { machine?: GuiMachineSummary }) {
  const localIp = machine?.local_ips?.[0] ?? "127.0.0.1";
  const publicIp = machine?.public_ip ?? "public IP not configured";
  const username = machine?.username ?? "local";
  const initials = machine?.initials ?? "LM";
  const title = `${username}\n${localIp}\n${publicIp}`;

  return (
    <aside className="machine-rail" aria-label="aidevops machines and clients">
      <button className="machine-orb active" title={title} type="button">
        <span>{initials}</span>
      </button>
      <button className="client-folder-orb" title="Client groups planned" type="button">⌁</button>
    </aside>
  );
}

export function Sidebar({ activeSurface, accentHue, conversationMode, fontPreference, fontSizePreference, selectedLocalRepoIndex, setAccentHue, setActiveSurface, setConversationMode, setFontPreference, setFontSizePreference, setSelectedLocalRepoIndex, setShellMode, setShowBorders, setShowNavCounts, setThemePreference, shellMode, showBorders, showNavCounts, status, themePreference }: {
  activeSurface: SurfaceId;
  accentHue: number;
  conversationMode: ConversationMode;
  fontPreference: FontPreference;
  fontSizePreference: FontSizePreference;
  selectedLocalRepoIndex: number;
  setAccentHue: (hue: number) => void;
  setActiveSurface: (surface: SurfaceId) => void;
  setConversationMode: (mode: ConversationMode) => void;
  setFontPreference: (font: FontPreference) => void;
  setFontSizePreference: (size: FontSizePreference) => void;
  setSelectedLocalRepoIndex: (index: number) => void;
  setShellMode: (mode: ShellMode) => void;
  setShowBorders: (show: boolean) => void;
  setShowNavCounts: (show: boolean) => void;
  setThemePreference: (theme: ThemePreference) => void;
  shellMode: ShellMode;
  showBorders: boolean;
  showNavCounts: boolean;
  status: GuiStatusData;
  themePreference: ThemePreference;
}) {
  const [sidebarMode, setSidebarMode] = useState<SidebarMode>(() => sidebarModeForSurface(activeSurface));
  const visibleGroups = navGroups.filter((group) => group.mode === sidebarMode);
  const recordCounts = surfaceRecordCounts(status);

  useEffect(() => {
    setSidebarMode(sidebarModeForSurface(activeSurface));
  }, [activeSurface]);

  return (
    <aside className="app-sidebar" aria-label={text.navigationLabel}>
      <SidebarHeader setShellMode={setShellMode} shellMode={shellMode} />
      <nav className="sidebar-content">
        {shellMode === "devices" ? <>
          <SidebarModeTabs mode={sidebarMode} setMode={(mode) => setSidebarMode(mode as SidebarMode)} />
          <ul className="sidebar-top-link">
            <SidebarItem activeSurface={activeSurface} item={dashboardNavItem} setActiveSurface={setActiveSurface} showCount={false} status={status} />
          </ul>
          {visibleGroups.map((group) => <SidebarGroup activeSurface={activeSurface} group={group} key={group.label} recordCounts={recordCounts} setActiveSurface={setActiveSurface} showNavCounts={showNavCounts} status={status} />)}
        </> : <ConversationSidebar
          conversationMode={conversationMode}
          selectedLocalRepoIndex={selectedLocalRepoIndex}
          setConversationMode={setConversationMode}
          setSelectedLocalRepoIndex={setSelectedLocalRepoIndex}
          status={status}
        />}
      </nav>
      <SidebarFooter
        accentHue={accentHue}
        fontPreference={fontPreference}
        fontSizePreference={fontSizePreference}
        setAccentHue={setAccentHue}
        setFontPreference={setFontPreference}
        setFontSizePreference={setFontSizePreference}
        setShowBorders={setShowBorders}
        setShowNavCounts={setShowNavCounts}
        setThemePreference={setThemePreference}
        showBorders={showBorders}
        showNavCounts={showNavCounts}
        themePreference={themePreference}
      />
    </aside>
  );
}

function IconSwitch<TValue extends string>({ ariaLabel, options, value }: {
  ariaLabel: string;
  options: Array<{ icon: ReactNode; label: string; onSelect: () => void; value: TValue }>;
  value: TValue;
}) {
  return (
    <div className="icon-switch" role="tablist" aria-label={ariaLabel}>
      {options.map((option) => (
        <button
          aria-label={option.label}
          aria-selected={value === option.value}
          className={value === option.value ? "active" : ""}
          key={option.value}
          onClick={option.onSelect}
          role="tab"
          title={option.label}
          type="button"
        >
          {option.icon}
          <span>{option.label}</span>
        </button>
      ))}
    </div>
  );
}

function ConversationSidebar({ conversationMode, selectedLocalRepoIndex, setConversationMode, setSelectedLocalRepoIndex, status }: {
  conversationMode: ConversationMode;
  selectedLocalRepoIndex: number;
  setConversationMode: (mode: ConversationMode) => void;
  setSelectedLocalRepoIndex: (index: number) => void;
  status: GuiStatusData;
}) {
  const repos = status.local_repos.repos;
  const selectedRepo = repos[selectedLocalRepoIndex] ?? repos[0];
  const sessions = selectedRepo === undefined
    ? []
    : status.opencode_sessions.sessions.filter((session) => session.repo_path_ref === selectedRepo.path_ref);
  const canSelectPreviousRepo = selectedLocalRepoIndex > 0;
  const canSelectNextRepo = selectedLocalRepoIndex < repos.length - 1;

  return (
    <section className="conversation-panel" aria-label={text.opencodeSessions}>
      <SidebarModeTabs mode={conversationMode} setMode={setConversationMode} />
      {conversationMode === "people" ? <PeopleChannelList /> : <>
      <button className="new-session-button" disabled title="Creating sessions needs an audited OpenCode write route." type="button">{text.newSession}</button>
      <section className="repo-session-selector" aria-label={text.localRepoSelector}>
        <span className="repo-selector-heading" id="local-repo-selector-label">{text.localRepos}</span>
        <div className="selector-with-stepper repo-selector-row">
          <button aria-label="Previous local repo" className="selector-step-button" disabled={!canSelectPreviousRepo} onClick={() => setSelectedLocalRepoIndex(Math.max(0, selectedLocalRepoIndex - 1))} type="button"><FiChevronLeft aria-hidden="true" /></button>
          <select aria-labelledby="local-repo-selector-label" onChange={(event) => setSelectedLocalRepoIndex(Number.parseInt(event.currentTarget.value, 10))} value={Math.min(selectedLocalRepoIndex, Math.max(0, repos.length - 1))}>
            {repos.length === 0 ? <option value={0}>No local repos</option> : repos.map((repo, index) => <option key={repo.path_ref} value={index}>{repo.name}</option>)}
          </select>
          <button aria-label="Next local repo" className="selector-step-button" disabled={!canSelectNextRepo} onClick={() => setSelectedLocalRepoIndex(Math.min(repos.length - 1, selectedLocalRepoIndex + 1))} type="button"><FiChevronRight aria-hidden="true" /></button>
        </div>
      </section>
      <section className="sidebar-group session-history-list">
        <h2>{text.sessionHistory}</h2>
        {selectedRepo ? <ul>
          {sessions.length === 0
            ? <li><button className="surface-link active" type="button"><span className="surface-icon" aria-hidden="true"><FiHash /></span><span className="surface-copy"><strong>{selectedRepo.name}</strong><small>No OpenCode sessions found for this repo yet.</small></span><em>{text.planned}</em></button></li>
            : sessions.map((session, index) => <li key={session.id_ref}><button className={index === 0 ? "surface-link active" : "surface-link"} type="button"><span className="surface-icon" aria-hidden="true"><FiHash /></span><span className="surface-copy"><strong>{session.title}</strong><small>{session.updated_at}</small></span></button></li>)}
        </ul> : <p className="empty-sidebar-state">No local repos discovered.</p>}
      </section>
      </>}
    </section>
  );
}

function PeopleChannelList() {
  return (
    <section aria-label="People channels">
      <div className="notice compact-notice">{text.simplexReady}</div>
      <section className="sidebar-group session-history-list">
        <h2>{text.teams}</h2>
        <ul>
          {["aidevops", "clients", "ops"].map((team) => <li key={team}><button className="surface-link" type="button"><span className="surface-icon" aria-hidden="true"><FiHash /></span><span className="surface-copy"><strong>{team}</strong><small>SimpleX team channel placeholder</small></span></button></li>)}
        </ul>
      </section>
      <section className="sidebar-group session-history-list">
        <h2>{text.directMessages}</h2>
        <ul>
          {["Marcus", "AI DevOps"].map((person) => <li key={person}><button className="surface-link" type="button"><span className="surface-icon" aria-hidden="true"><FiMessageSquare /></span><span className="surface-copy"><strong>{person}</strong><small>encrypted DM placeholder</small></span></button></li>)}
        </ul>
      </section>
    </section>
  );
}

function SidebarModeTabs<TMode extends SidebarMode | ConversationMode>({ mode, setMode }: {
  mode: TMode;
  setMode: (mode: TMode) => void;
}) {
  const modes = (mode === "ai" || mode === "people"
    ? [{ label: text.ai, value: "ai" }, { label: text.people, value: "people" }]
    : [{ label: text.devops, value: "devops" }, { label: text.comms, value: "comms" }]) as Array<{ label: string; value: TMode }>;

  return (
    <div className="sidebar-mode-tabs" role="tablist" aria-label="Sidebar sections">
      {modes.map((entry) => (
        <button
          aria-selected={mode === entry.value}
          className={mode === entry.value ? "active" : ""}
          key={entry.value}
          onClick={() => setMode(entry.value)}
          role="tab"
          type="button"
        >
          {entry.label}
        </button>
      ))}
    </div>
  );
}

function SidebarGroup({ activeSurface, group, recordCounts, setActiveSurface, showNavCounts, status }: {
  activeSurface: SurfaceId;
  group: SurfaceNavGroup;
  recordCounts: Partial<Record<SurfaceId, number>>;
  setActiveSurface: (surface: SurfaceId) => void;
  showNavCounts: boolean;
  status: GuiStatusData;
}) {
  return (
    <section className="sidebar-group">
      <h2>{group.label}</h2>
      <ul>
        {group.items.map((item) => <SidebarItem activeSurface={activeSurface} item={item} key={item.id} recordCount={recordCounts[item.id]} setActiveSurface={setActiveSurface} showCount={showNavCounts} status={status} />)}
      </ul>
    </section>
  );
}

function SidebarItem({ activeSurface, item, recordCount, setActiveSurface, showCount, status }: {
  activeSurface: SurfaceId;
  item: SurfaceNavItem;
  recordCount?: number;
  setActiveSurface: (surface: SurfaceId) => void;
  showCount: boolean;
  status: GuiStatusData;
}) {
  const isActive = activeSurface === item.id;
  const vaultCollection = vaultCollectionForSurface(status.vault, item.id);
  const vaultTooltip = vaultCollection ? ` ${text.vaultTooltip}` : "";
  const tooltip = `${item.label}: ${item.description}${vaultTooltip}`;
  const shouldShowCount = showCount && recordCount !== undefined && recordCount > 0;

  return (
    <li>
      <button
        aria-label={tooltip}
        aria-current={isActive ? "page" : undefined}
        className={isActive ? "surface-link active" : "surface-link"}
        onClick={() => setActiveSurface(item.id)}
        title={tooltip}
        type="button"
      >
        <span className="surface-icon" aria-hidden="true"><SurfaceGlyph icon={item.icon} /></span>
        <span className="surface-copy">
          <span className="surface-title-row">
            <strong>{item.label}</strong>
            {shouldShowCount ? <span className="surface-count">({recordCount})</span> : null}
          </span>
        </span>
        {vaultCollection ? <VaultPadlock collection={vaultCollection} compact vault={status.vault} /> : null}
        {item.badge ? <em>{item.badge}</em> : null}
      </button>
    </li>
  );
}

function SidebarHeader({ setShellMode, shellMode }: {
  setShellMode: (mode: ShellMode) => void;
  shellMode: ShellMode;
}) {
  return (
    <header className="sidebar-header">
      <div className="sidebar-titlebar">
        <div className="brand-lockup">
          <span className="terminal-mark" aria-hidden="true">›_</span>
          <strong>{text.aidevops}</strong>
        </div>
        <IconSwitch
          ariaLabel="Navigation scope"
          options={[
            { icon: <FiMonitor aria-hidden="true" />, label: text.devices, onSelect: () => setShellMode("devices"), value: "devices" },
            { icon: <FiHash aria-hidden="true" />, label: text.opencodeSessions, onSelect: () => setShellMode("sessions"), value: "sessions" },
          ]}
          value={shellMode}
        />
      </div>
    </header>
  );
}

function SidebarFooter({ accentHue, fontPreference, fontSizePreference, setAccentHue, setFontPreference, setFontSizePreference, setShowBorders, setShowNavCounts, setThemePreference, showBorders, showNavCounts, themePreference }: {
  accentHue: number;
  fontPreference: FontPreference;
  fontSizePreference: FontSizePreference;
  setAccentHue: (hue: number) => void;
  setFontPreference: (font: FontPreference) => void;
  setFontSizePreference: (size: FontSizePreference) => void;
  setShowBorders: (show: boolean) => void;
  setShowNavCounts: (show: boolean) => void;
  setThemePreference: (theme: ThemePreference) => void;
  showBorders: boolean;
  showNavCounts: boolean;
  themePreference: ThemePreference;
}) {
  const [appearanceOpen, setAppearanceOpen] = useState(true);
  const AppearanceChevron = appearanceOpen ? FiChevronDown : FiChevronUp;
  const selectedFontFamily = fontFamilyForPreference(fontPreference);
  const fontIndex = Math.max(0, fontOptions.findIndex((option) => option.value === fontPreference));
  const fontSizeIndex = Math.max(0, fontSizeOptions.findIndex((option) => option.value === fontSizePreference));
  const canSelectPreviousFont = fontIndex > 0;
  const canSelectNextFont = fontIndex < fontOptions.length - 1;
  const [hueInput, setHueInput] = useState(() => String(accentHue));
  const setFontByIndex = (index: number) => {
    const nextFont = fontOptions[index]?.value;

    if (nextFont === undefined) {
      return;
    }

    setFontPreference(nextFont);
  };
  const updateAccentHue = (value: number) => {
    if (!Number.isFinite(value)) {
      return;
    }
    setAccentHue(Math.min(359, Math.max(0, value)));
  };
  const updateHueInput = (value: string) => {
    setHueInput(value);

    const nextHue = hueFromInputValue(value);

    if (nextHue === null) {
      return;
    }

    updateAccentHue(nextHue);
  };

  useEffect(() => {
    setHueInput(String(accentHue));
  }, [accentHue]);

  return (
    <footer className="sidebar-footer">
      <section className={appearanceOpen ? "appearance-panel open" : "appearance-panel collapsed"}>
        <button
          aria-expanded={appearanceOpen}
          className="appearance-panel-tab"
          onClick={() => setAppearanceOpen((current) => !current)}
          type="button"
        >
          {text.appearance}
          <AppearanceChevron aria-hidden="true" className="appearance-chevron" />
        </button>
        {appearanceOpen ? <div className="appearance-panel-body">
          <fieldset className="theme-control compact" aria-label={text.theme}>
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
          </fieldset>
          <div className="theme-hue-control">
            <div className="theme-control-heading">
              <div className="hue-label-row">
                <label htmlFor="theme-hue-slider">{text.hue}</label>
                <input
                  aria-label="Hue value"
                  className="hue-number-input"
                  max="359"
                  min="0"
                  onChange={(event) => updateHueInput(event.currentTarget.value)}
                  type="number"
                  value={hueInput}
                />
              </div>
              <button aria-label="Reset hue to default" className="icon-reset-button" onClick={() => setAccentHue(DEFAULT_ACCENT_HUE)} title={text.reset} type="button"><FiRotateCcw aria-hidden="true" /></button>
            </div>
            <input
              id="theme-hue-slider"
              max="359"
              min="0"
              onChange={(event) => updateAccentHue(Number.parseInt(event.currentTarget.value, 10))}
              type="range"
              value={accentHue}
            />
          </div>
          <label className="switch-control appearance-switch">
            <strong>{text.showBorders}</strong>
            <input checked={showBorders} onChange={(event) => setShowBorders(event.currentTarget.checked)} type="checkbox" />
            <span aria-hidden="true" />
          </label>
          <label className="switch-control appearance-switch">
            <strong>{text.showCounts}</strong>
            <input checked={showNavCounts} onChange={(event) => setShowNavCounts(event.currentTarget.checked)} type="checkbox" />
            <span aria-hidden="true" />
          </label>
          <div className="font-size-control">
            <label htmlFor="font-size-slider">{text.fontSize}</label>
            <input
              id="font-size-slider"
              max={fontSizeOptions.length - 1}
              min="0"
              onChange={(event) => setFontSizePreference(fontSizeOptions[Number.parseInt(event.currentTarget.value, 10)]?.value ?? "m")}
              step="1"
              type="range"
              value={fontSizeIndex}
            />
            <div className="range-labels" aria-hidden="true">
              {fontSizeOptions.map((option) => <span className={option.value === fontSizePreference ? "active" : ""} key={option.value}>{option.label}</span>)}
            </div>
          </div>
          <div className="font-control">
            <span id="appearance-font-selector-label">{text.font}</span>
            <div className="selector-with-stepper font-selector-row">
              <button aria-label="Previous font" className="selector-step-button" disabled={!canSelectPreviousFont} onClick={() => setFontByIndex(fontIndex - 1)} type="button"><FiChevronLeft aria-hidden="true" /></button>
              <select
                aria-labelledby="appearance-font-selector-label"
                onChange={(event) => setFontPreference(event.currentTarget.value as FontPreference)}
                style={{ fontFamily: selectedFontFamily }}
                value={fontPreference}
              >
                {fontOptions.map((option) => (
                  <option key={option.value} style={{ fontFamily: option.fontFamily }} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </select>
              <button aria-label="Next font" className="selector-step-button" disabled={!canSelectNextFont} onClick={() => setFontByIndex(fontIndex + 1)} type="button"><FiChevronRight aria-hidden="true" /></button>
            </div>
          </div>
        </div>
        : null}
      </section>
    </footer>
  );
}
