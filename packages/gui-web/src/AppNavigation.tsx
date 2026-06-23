/* jshint esversion: 11 */
import type { GuiMachineSummary, GuiStatusData } from "@aidevops/gui-shared";
import { useEffect, useState } from "react";
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
  FiHardDrive,
  FiLink,
  FiLink2,
  FiList,
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
import type { FontPreference, FontSizePreference, SidebarMode, SurfaceIconName, SurfaceId, SurfaceNavGroup, SurfaceNavItem, ThemePreference } from "./app-model";
import { DEFAULT_ACCENT_HUE, dashboardNavItem, fontFamilyForPreference, fontOptions, fontSizeOptions, navGroups, sidebarModeForSurface, surfaceRecordCounts, text } from "./app-model";

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

export function Sidebar({ activeSurface, accentHue, canGoBack, canGoForward, fontPreference, fontSizePreference, goBack, goForward, setAccentHue, setActiveSurface, setFontPreference, setFontSizePreference, setShowBorders, setShowNavCounts, setThemePreference, showBorders, showNavCounts, status, themePreference }: {
  activeSurface: SurfaceId;
  accentHue: number;
  canGoBack: boolean;
  canGoForward: boolean;
  fontPreference: FontPreference;
  fontSizePreference: FontSizePreference;
  goBack: () => void;
  goForward: () => void;
  setAccentHue: (hue: number) => void;
  setActiveSurface: (surface: SurfaceId) => void;
  setFontPreference: (font: FontPreference) => void;
  setFontSizePreference: (size: FontSizePreference) => void;
  setShowBorders: (show: boolean) => void;
  setShowNavCounts: (show: boolean) => void;
  setThemePreference: (theme: ThemePreference) => void;
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
      <SidebarHeader canGoBack={canGoBack} canGoForward={canGoForward} goBack={goBack} goForward={goForward} />
      <nav className="sidebar-content">
        <SidebarModeTabs mode={sidebarMode} setMode={setSidebarMode} />
        <ul className="sidebar-top-link">
          <SidebarItem activeSurface={activeSurface} item={dashboardNavItem} setActiveSurface={setActiveSurface} showCount={false} />
        </ul>
        {visibleGroups.map((group) => <SidebarGroup activeSurface={activeSurface} group={group} key={group.label} recordCounts={recordCounts} setActiveSurface={setActiveSurface} showNavCounts={showNavCounts} />)}
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

function SidebarModeTabs({ mode, setMode }: {
  mode: SidebarMode;
  setMode: (mode: SidebarMode) => void;
}) {
  const modes: Array<{ label: string; value: SidebarMode }> = [
    { label: text.devops, value: "devops" },
    { label: text.comms, value: "comms" },
  ];

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

function SidebarGroup({ activeSurface, group, recordCounts, setActiveSurface, showNavCounts }: {
  activeSurface: SurfaceId;
  group: SurfaceNavGroup;
  recordCounts: Partial<Record<SurfaceId, number>>;
  setActiveSurface: (surface: SurfaceId) => void;
  showNavCounts: boolean;
}) {
  return (
    <section className="sidebar-group">
      <h2>{group.label}</h2>
      <ul>
        {group.items.map((item) => <SidebarItem activeSurface={activeSurface} item={item} key={item.id} recordCount={recordCounts[item.id]} setActiveSurface={setActiveSurface} showCount={showNavCounts} />)}
      </ul>
    </section>
  );
}

function SidebarItem({ activeSurface, item, recordCount, setActiveSurface, showCount }: {
  activeSurface: SurfaceId;
  item: SurfaceNavItem;
  recordCount?: number;
  setActiveSurface: (surface: SurfaceId) => void;
  showCount: boolean;
}) {
  const isActive = activeSurface === item.id;
  const tooltip = `${item.label}: ${item.description}`;
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
        {item.badge ? <em>{item.badge}</em> : null}
      </button>
    </li>
  );
}

function SidebarHeader({ canGoBack, canGoForward, goBack, goForward }: {
  canGoBack: boolean;
  canGoForward: boolean;
  goBack: () => void;
  goForward: () => void;
}) {
  return (
    <header className="sidebar-header">
      <div className="sidebar-titlebar">
        <div className="brand-lockup">
          <span className="terminal-mark" aria-hidden="true">›_</span>
          <strong>{text.aidevops}</strong>
        </div>
        <div className="sidebar-history-controls">
          <button aria-label="Previous surface" disabled={!canGoBack} onClick={goBack} type="button"><FiChevronLeft /></button>
          <button aria-label="Next surface" disabled={!canGoForward} onClick={goForward} type="button"><FiChevronRight /></button>
        </div>
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
  const fontSizeIndex = Math.max(0, fontSizeOptions.findIndex((option) => option.value === fontSizePreference));
  const [hueInput, setHueInput] = useState(() => String(accentHue));
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
          <label className="font-control">
            <span>{text.font}</span>
            <select
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
          </label>
        </div>
        : null}
      </section>
    </footer>
  );
}
