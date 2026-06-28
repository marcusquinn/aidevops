import type { GuiResponseEnvelope, GuiStatusData } from "@aidevops/gui-shared";
import { type Dispatch, type KeyboardEvent as ReactKeyboardEvent, type MouseEvent as ReactMouseEvent, type ReactElement, type SetStateAction, useEffect, useState } from "react";
import { MachineRail, Sidebar } from "./AppNavigation";
import { Workspace } from "./AppWorkspace";
import type { ConversationMode, FontPreference, FontSizePreference, ShellMode, SurfaceId, ThemePreference } from "./app-model";
import { DEFAULT_ACCENT_HUE, DEFAULT_FONT, DEFAULT_FONT_SIZE, fileRootBySurface, findSurface, findSurfaceSectionLabel, fontFamilyForPreference, fontSizeForPreference, getSystemTheme, isFontPreference, isFontSizePreference } from "./app-model";
import { fetchStatus, mockedStatus } from "./status-client";

interface NavigationHistory {
  entries: SurfaceId[];
  index: number;
}

interface WebKitBridgeWindow extends Window {
  webkit?: {
    messageHandlers?: {
      accentHue?: {
        postMessage: (hue: number) => void;
      };
    };
  };
}

type AppearanceStorage = Pick<Storage, "getItem" | "setItem">;
type ReadableAppearanceStorage = Pick<Storage, "getItem">;
type AppearanceStorageKey = (typeof appearanceStorageKeys)[keyof typeof appearanceStorageKeys];

export const appearanceStorageKeys = {
  accentHue: "aidevops-gui-accent-hue",
  font: "aidevops-gui-font",
  fontSize: "aidevops-gui-font-size",
  machineRail: "aidevops-gui-show-machine-rail",
  showBorders: "aidevops-gui-show-borders",
  showNavCounts: "aidevops-gui-show-nav-counts",
  sidebarWidth: "aidevops-gui-sidebar-width",
  theme: "aidevops-gui-theme",
} as const;

const defaultSidebarWidth = 302;
const minSidebarWidth = 300;
const maxSidebarWidth = 520;
export const loadingSkeletonPanelLabels = ["machine rail", "sidebar", "workspace", "status bar"] as const;
export const loadingBrandGlyph = ">_";

export interface StoredAppearancePreferences {
  accentHue: number;
  fontPreference: FontPreference;
  fontSizePreference: FontSizePreference;
  machineRailVisible: boolean;
  showBorders: boolean;
  showNavCounts: boolean;
  themePreference: ThemePreference;
}

export function readStoredAppearancePreferences(storage: ReadableAppearanceStorage | undefined = browserLocalStorage(), isDesktopShell = isMacosDesktopBrowser()): StoredAppearancePreferences {
  const savedTheme = storage?.getItem(appearanceStorageKeys.theme);
  const savedAccentHue = Number.parseInt(storage?.getItem(appearanceStorageKeys.accentHue) ?? "", 10);
  const savedFont = storage?.getItem(appearanceStorageKeys.font) ?? null;
  const savedFontSize = storage?.getItem(appearanceStorageKeys.fontSize) ?? null;

  return {
    accentHue: Number.isFinite(savedAccentHue) && savedAccentHue >= 0 && savedAccentHue <= 359 ? savedAccentHue : DEFAULT_ACCENT_HUE,
    fontPreference: isFontPreference(savedFont) ? savedFont : DEFAULT_FONT,
    fontSizePreference: isFontSizePreference(savedFontSize) ? savedFontSize : DEFAULT_FONT_SIZE,
    machineRailVisible: isDesktopShell ? readStoredBoolean(storage, appearanceStorageKeys.machineRail, true) : true,
    showBorders: readStoredBoolean(storage, appearanceStorageKeys.showBorders, true),
    showNavCounts: readStoredBoolean(storage, appearanceStorageKeys.showNavCounts, true),
    themePreference: savedTheme === "system" || savedTheme === "light" || savedTheme === "dark" ? savedTheme : "system",
  };
}

export function isEditableKeyboardTarget(target: EventTarget | null): boolean {
  if (typeof HTMLElement === "undefined" || !(target instanceof HTMLElement)) {
    return false;
  }

  return target.isContentEditable || target.closest("input, textarea, select, [contenteditable], [role='textbox']") !== null;
}

function nextHistoryIndex(current: NavigationHistory, direction: -1 | 1): number {
  return Math.min(Math.max(0, current.entries.length - 1), Math.max(0, current.index + direction));
}

function useNavigationHistoryKeyboard(setNavigation: Dispatch<SetStateAction<NavigationHistory>>): void {
  useEffect(() => {
    const navigateHistoryWithKeyboard = (event: globalThis.KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || isEditableKeyboardTarget(event.target) || isEditableKeyboardTarget(document.activeElement)) {
        return;
      }

      const direction: -1 | 1 | null = event.key === "[" ? -1 : event.key === "]" ? 1 : null;
      if (direction === null) {
        return;
      }

      event.preventDefault();
      setNavigation((current) => ({ ...current, index: nextHistoryIndex(current, direction) }));
    };

    window.addEventListener("keydown", navigateHistoryWithKeyboard);

    return () => window.removeEventListener("keydown", navigateHistoryWithKeyboard);
  }, [setNavigation]);
}

export function App(): ReactElement {
  const [storedAppearancePreferences] = useState<StoredAppearancePreferences>(() => readStoredAppearancePreferences());
  const [status, setStatus] = useState<GuiResponseEnvelope<GuiStatusData>>(mockedStatus());
  const [statusLoading, setStatusLoading] = useState(true);
  const [navigation, setNavigation] = useState<NavigationHistory>({ entries: ["overview"], index: 0 });
  const [themePreference, setThemePreference] = useState<ThemePreference>(storedAppearancePreferences.themePreference);
  const [accentHue, setAccentHue] = useState(storedAppearancePreferences.accentHue);
  const [fontPreference, setFontPreference] = useState<FontPreference>(storedAppearancePreferences.fontPreference);
  const [fontSizePreference, setFontSizePreference] = useState<FontSizePreference>(storedAppearancePreferences.fontSizePreference);
  const [machineRailVisible, setMachineRailVisible] = useState(storedAppearancePreferences.machineRailVisible);
  const [showNavCounts, setShowNavCounts] = useState(storedAppearancePreferences.showNavCounts);
  const [showBorders, setShowBorders] = useState(storedAppearancePreferences.showBorders);
  const [shellMode, setShellMode] = useState<ShellMode>("devices");
  const [conversationMode, setConversationMode] = useState<ConversationMode>("ai");
  const [selectedLocalRepoIndex, setSelectedLocalRepoIndex] = useState(0);
  const [selectedSessionId, setSelectedSessionId] = useState<string | undefined>();
  const [systemTheme, setSystemTheme] = useState<"light" | "dark">("light");
  const resolvedTheme = themePreference === "system" ? systemTheme : themePreference;
  const activeSurface: SurfaceId = navigation.entries[navigation.index] ?? "overview";
  const activeItem = findSurface(activeSurface);
  const activeSectionLabel = findSurfaceSectionLabel(activeSurface);
  const canGoBack = navigation.index > 0;
  const canGoForward = navigation.index < navigation.entries.length - 1;
  const fileRoot = fileRootBySurface[activeSurface];
  useNavigationHistoryKeyboard(setNavigation);

  const setActiveSurface = (surface: SurfaceId) => {
    setNavigation((current) => {
      const currentSurface = current.entries[current.index] ?? "overview";
      if (currentSurface === surface) {
        return current;
      }

      const entries = current.entries.slice(0, current.index + 1);
      entries.push(surface);
      return { entries, index: entries.length - 1 };
    });
  };

  const goBack = () => {
    setNavigation((current) => ({ ...current, index: nextHistoryIndex(current, -1) }));
  };

  const goForward = () => {
    setNavigation((current) => ({ ...current, index: nextHistoryIndex(current, 1) }));
  };

  useEffect(() => {
    const isMacosDesktop = isMacosDesktopBrowser();
    const toggleMachineRail = () => setMachineRailVisible((current) => !current);

    if (isMacosDesktop) {
      document.documentElement.dataset.desktopShell = "macos";
    } else {
      delete document.documentElement.dataset.desktopShell;
    }

    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    const updateSystemTheme = () => setSystemTheme(getSystemTheme());
    updateSystemTheme();
    mediaQuery.addEventListener("change", updateSystemTheme);
    window.addEventListener("aidevops:toggle-machine-rail", toggleMachineRail);

    return () => {
      mediaQuery.removeEventListener("change", updateSystemTheme);
      window.removeEventListener("aidevops:toggle-machine-rail", toggleMachineRail);
    };
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = resolvedTheme;
    document.documentElement.style.colorScheme = resolvedTheme;
    persistAppearancePreference(appearanceStorageKeys.theme, themePreference);
  }, [resolvedTheme, themePreference]);

  useEffect(() => {
    document.documentElement.style.setProperty("--accent-hue", String(accentHue));
    persistAppearancePreference(appearanceStorageKeys.accentHue, String(accentHue));
    sendNativeAccentHue(accentHue);
  }, [accentHue]);

  useEffect(() => {
    document.documentElement.style.setProperty("--font-family-app", fontFamilyForPreference(fontPreference));
    persistAppearancePreference(appearanceStorageKeys.font, fontPreference);
  }, [fontPreference]);

  useEffect(() => {
    document.documentElement.style.setProperty("--font-size-app", fontSizeForPreference(fontSizePreference));
    persistAppearancePreference(appearanceStorageKeys.fontSize, fontSizePreference);
  }, [fontSizePreference]);

  useEffect(() => {
    fetchStatus()
      .then(setStatus)
      .catch(() => setStatus(mockedStatus()))
      .finally(() => setStatusLoading(false));
  }, []);

  useEffect(() => {
    persistAppearancePreference(appearanceStorageKeys.showNavCounts, String(showNavCounts));
  }, [showNavCounts]);

  useEffect(() => {
    document.documentElement.dataset.borders = showBorders ? "visible" : "hidden";
    persistAppearancePreference(appearanceStorageKeys.showBorders, String(showBorders));
  }, [showBorders]);

  useEffect(() => {
    persistAppearancePreference(appearanceStorageKeys.machineRail, String(machineRailVisible));
  }, [machineRailVisible]);

  useEffect(() => {
    setSelectedLocalRepoIndex((current) => Math.min(current, Math.max(0, status.data.local_repos.repos.length - 1)));
  }, [status.data.local_repos.repos.length]);

  if (statusLoading) {
    return <AppLoadingSkeleton machineRailVisible={machineRailVisible} />;
  }

  return (
    <main className={machineRailVisible ? "app-shell" : "app-shell machine-rail-collapsed"}>
      <div className="desktop-titlebar-tagline" aria-hidden="true">Your data protected. Your systems managed. Your creations published.</div>
      {machineRailVisible ? <MachineRail machine={status.data.machine} /> : null}
      <Sidebar
        activeSurface={activeSurface}
        accentHue={accentHue}
        conversationMode={conversationMode}
        fontSizePreference={fontSizePreference}
        fontPreference={fontPreference}
        selectedLocalRepoIndex={selectedLocalRepoIndex}
        selectedSessionId={selectedSessionId}
        setAccentHue={setAccentHue}
        setActiveSurface={setActiveSurface}
        setConversationMode={setConversationMode}
        setFontSizePreference={setFontSizePreference}
        setFontPreference={setFontPreference}
        setSelectedLocalRepoIndex={setSelectedLocalRepoIndex}
        setSelectedSessionId={setSelectedSessionId}
        setShellMode={setShellMode}
        setShowBorders={setShowBorders}
        setShowNavCounts={setShowNavCounts}
        setThemePreference={setThemePreference}
        shellMode={shellMode}
        showBorders={showBorders}
        showNavCounts={showNavCounts}
        status={status.data}
        themePreference={themePreference}
      />
      <SidebarResizeHandle />
      <Workspace
        activeItem={activeItem}
        activeSectionLabel={activeSectionLabel}
        activeSurface={activeSurface}
        canGoBack={canGoBack}
        canGoForward={canGoForward}
        conversationMode={conversationMode}
        fileRoot={fileRoot}
        goBack={goBack}
        goForward={goForward}
        selectedLocalRepoIndex={selectedLocalRepoIndex}
        selectedSessionId={selectedSessionId}
        setActiveSurface={setActiveSurface}
        setConversationMode={setConversationMode}
        setSelectedLocalRepoIndex={setSelectedLocalRepoIndex}
        setSelectedSessionId={setSelectedSessionId}
        setShellMode={setShellMode}
        shellMode={shellMode}
        status={status.data}
      />
      <DesktopStatusBar status={status.data} />
    </main>
  );
}

export function AppLoadingSkeleton({ machineRailVisible }: { machineRailVisible: boolean }): ReactElement {
  return (
    <main className={machineRailVisible ? "app-shell app-loading-shell" : "app-shell app-loading-shell machine-rail-collapsed"} aria-busy="true" aria-label="Loading aidevops interface">
      <div className="desktop-titlebar-tagline loading-line loading-titlebar" aria-hidden="true" />
      <LoadingBrandOverlay />
      {machineRailVisible ? (
        <section className="machine-rail loading-panel" aria-label={loadingSkeletonPanelLabels[0]}>
          {Array.from({ length: 6 }, (_, index) => <span className="loading-orb" key={index} />)}
        </section>
      ) : null}
      <section className="app-sidebar loading-panel" aria-label={loadingSkeletonPanelLabels[1]}>
        <div className="loading-sidebar-header">
          <span className="loading-logo" />
          <span className="loading-line loading-line-wide" />
        </div>
        <span className="loading-pill" />
        <div className="loading-list">
          {Array.from({ length: 12 }, (_, index) => <span className={index % 3 === 0 ? "loading-line loading-line-short" : "loading-line"} key={index} />)}
        </div>
        <div className="loading-sidebar-footer">
          <span className="loading-pill" />
          <span className="loading-line" />
        </div>
      </section>
      <SidebarResizeHandle />
      <section className="app-inset loading-panel" aria-label={loadingSkeletonPanelLabels[2]}>
        <div className="workspace-header loading-workspace-header">
          <span className="loading-icon" />
          <span className="loading-line loading-line-wide" />
          <span className="loading-search" />
          <span className="loading-circle" />
          <span className="loading-circle" />
        </div>
        <div className="loading-workspace-body">
          <span className="loading-line loading-line-hero" />
          <div className="loading-card-grid">
            {Array.from({ length: 6 }, (_, index) => <span className="loading-card" key={index} />)}
          </div>
          <span className="loading-panel-block" />
        </div>
      </section>
      <div className="desktop-status-bar loading-status-bar" aria-label={loadingSkeletonPanelLabels[3]}>
        {Array.from({ length: 8 }, (_, index) => <span className={index === 0 ? "loading-dot" : "loading-line"} key={index} />)}
      </div>
    </main>
  );
}

function LoadingBrandOverlay(): ReactElement {
  return (
    <div className="loading-brand-overlay" aria-label="Starting aidevops">
      <span className="loading-brand-mark" aria-hidden="true">
        <span className="loading-brand-word">aidevops</span>
        <span className="loading-brand-chevron">&gt;</span>
        <span className="loading-brand-cursor">_</span>
      </span>
      <span className="loading-brand-status">Preparing local GUI</span>
    </div>
  );
}

export function clampSidebarWidth(width: number): number {
  return Math.min(maxSidebarWidth, Math.max(minSidebarWidth, Math.round(width)));
}

function SidebarResizeHandle(): ReactElement {
  const [sidebarWidth, setSidebarWidth] = useState(() => readStoredSidebarWidth());

  useEffect(() => {
    document.documentElement.style.setProperty("--sidebar-width", `${sidebarWidth}px`);
    persistAppearancePreference(appearanceStorageKeys.sidebarWidth, String(sidebarWidth));
  }, [sidebarWidth]);

  const startSidebarResize = (event: ReactMouseEvent<HTMLElement>) => {
    const startX = event.clientX;
    const startWidth = sidebarWidth;
    const resizeSidebar = (moveEvent: MouseEvent) => setSidebarWidth(clampSidebarWidth(startWidth + moveEvent.clientX - startX));
    const stopResize = () => {
      document.documentElement.classList.remove("resizing-sidebar");
      window.removeEventListener("mousemove", resizeSidebar);
      window.removeEventListener("mouseup", stopResize);
    };

    event.preventDefault();
    document.documentElement.classList.add("resizing-sidebar");
    window.addEventListener("mousemove", resizeSidebar);
    window.addEventListener("mouseup", stopResize);
  };

  const resizeSidebarWithKeyboard = (event: ReactKeyboardEvent<HTMLElement>) => {
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      setSidebarWidth((current) => clampSidebarWidth(current + (event.key === "ArrowRight" ? 16 : -16)));
    }

    if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      setSidebarWidth(event.key === "Home" ? minSidebarWidth : maxSidebarWidth);
    }
  };

  return <hr aria-label="Resize sidebar" aria-orientation="vertical" aria-valuemax={maxSidebarWidth} aria-valuemin={minSidebarWidth} aria-valuenow={sidebarWidth} className="sidebar-resize-handle" onKeyDown={resizeSidebarWithKeyboard} onMouseDown={startSidebarResize} tabIndex={0} />;
}

function readStoredSidebarWidth(storage: ReadableAppearanceStorage | undefined = browserLocalStorage()): number {
  const savedWidth = Number.parseInt(storage?.getItem(appearanceStorageKeys.sidebarWidth) ?? "", 10);
  return Number.isFinite(savedWidth) ? clampSidebarWidth(savedWidth) : defaultSidebarWidth;
}

function sendNativeAccentHue(hue: number): void {
  const webkit = (window as WebKitBridgeWindow).webkit;
  webkit?.messageHandlers?.accentHue?.postMessage(hue);
}

function browserLocalStorage(): AppearanceStorage | undefined {
  if (typeof window === "undefined") {
    return undefined;
  }

  try {
    return window.localStorage;
  } catch {
    return undefined;
  }
}

function isMacosDesktopBrowser(): boolean {
  if (typeof window === "undefined") {
    return false;
  }

  return new URLSearchParams(window.location.search).get("desktop") === "macos";
}

function persistAppearancePreference(key: AppearanceStorageKey, value: string): void {
  try {
    browserLocalStorage()?.setItem(key, value);
  } catch {
    // Ignore unavailable storage so the local GUI can still render.
  }
}

function readStoredBoolean(storage: ReadableAppearanceStorage | undefined, key: AppearanceStorageKey, fallback: boolean): boolean {
  const savedValue = storage?.getItem(key);

  if (savedValue === "false") {
    return false;
  }

  if (savedValue === "true") {
    return true;
  }

  return fallback;
}

function DesktopStatusBar({ status }: { status: GuiStatusData }): ReactElement {
  const version = status.update.installed_version !== "unknown" ? status.update.installed_version : status.aidevops_version;
  const versionLabel = version === "unknown" || version.startsWith("v") ? version : `v${version}`;
  const needsUpdate = status.setup_targets.filter((target) => target.needs_update).length + status.ai_apps.filter((app) => app.needs_update).length;
  const oauthAccounts = status.oauth_pool.providers.reduce((total, provider) => total + provider.total, 0);
  const localRepoCount = status.local_repos.total || status.local_repos.repos.length;
  const remoteRepoCount = status.repos.total || status.repos.repos.length;
  const statusLabel = status.update.restart_required ? "Restart required" : "Ready";
  const vaultLabel = status.vault?.unlocked ? "Vault unlocked" : `Vault ${status.vault?.status ?? "unknown"}`;

  return (
    <div className="desktop-status-bar" role="status">
      <span className={status.update.restart_required ? "status-dot warn" : "status-dot"} aria-hidden="true" />
      <strong>{statusLabel}</strong>
      <span>Read-only local GUI</span>
      <span>{versionLabel}</span>
      <span>{localRepoCount} local repos</span>
      <span>{remoteRepoCount} remote repos</span>
      <span>{status.secrets.length} secrets</span>
      <span>{vaultLabel}</span>
      <span>{oauthAccounts} provider accounts</span>
      <span>{needsUpdate} need update</span>
    </div>
  );
}
