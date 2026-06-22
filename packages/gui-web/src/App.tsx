import type { GuiResponseEnvelope, GuiStatusData } from "@aidevops/gui-shared";
import { type ReactElement, useEffect, useState } from "react";
import { MachineRail, Sidebar } from "./AppNavigation";
import { Workspace } from "./AppWorkspace";
import type { FontPreference, FontSizePreference, SurfaceId, ThemePreference } from "./app-model";
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
  theme: "aidevops-gui-theme",
} as const;

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

export function App(): ReactElement {
  const [storedAppearancePreferences] = useState<StoredAppearancePreferences>(() => readStoredAppearancePreferences());
  const [status, setStatus] = useState<GuiResponseEnvelope<GuiStatusData>>(mockedStatus());
  const [navigation, setNavigation] = useState<NavigationHistory>({ entries: ["overview"], index: 0 });
  const [themePreference, setThemePreference] = useState<ThemePreference>(storedAppearancePreferences.themePreference);
  const [accentHue, setAccentHue] = useState(storedAppearancePreferences.accentHue);
  const [fontPreference, setFontPreference] = useState<FontPreference>(storedAppearancePreferences.fontPreference);
  const [fontSizePreference, setFontSizePreference] = useState<FontSizePreference>(storedAppearancePreferences.fontSizePreference);
  const [machineRailVisible, setMachineRailVisible] = useState(storedAppearancePreferences.machineRailVisible);
  const [showNavCounts, setShowNavCounts] = useState(storedAppearancePreferences.showNavCounts);
  const [showBorders, setShowBorders] = useState(storedAppearancePreferences.showBorders);
  const [systemTheme, setSystemTheme] = useState<"light" | "dark">("light");
  const resolvedTheme = themePreference === "system" ? systemTheme : themePreference;
  const activeSurface: SurfaceId = navigation.entries[navigation.index] ?? "overview";
  const activeItem = findSurface(activeSurface);
  const activeSectionLabel = findSurfaceSectionLabel(activeSurface);
  const canGoBack = navigation.index > 0;
  const canGoForward = navigation.index < navigation.entries.length - 1;
  const fileRoot = fileRootBySurface[activeSurface];

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
    setNavigation((current) => ({ ...current, index: Math.max(0, current.index - 1) }));
  };

  const goForward = () => {
    setNavigation((current) => ({ ...current, index: Math.min(current.entries.length - 1, current.index + 1) }));
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
      .catch(() => setStatus(mockedStatus()));
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

  return (
    <main className={machineRailVisible ? "app-shell" : "app-shell machine-rail-collapsed"}>
      <div className="desktop-titlebar-tagline" aria-hidden="true">Your data protected. Your systems managed. Your creations published.</div>
      {machineRailVisible ? <MachineRail machine={status.data.machine} /> : null}
      <Sidebar
        activeSurface={activeSurface}
        accentHue={accentHue}
        canGoBack={canGoBack}
        canGoForward={canGoForward}
        fontSizePreference={fontSizePreference}
        fontPreference={fontPreference}
        goBack={goBack}
        goForward={goForward}
        setAccentHue={setAccentHue}
        setActiveSurface={setActiveSurface}
        setFontSizePreference={setFontSizePreference}
        setFontPreference={setFontPreference}
        setShowBorders={setShowBorders}
        setShowNavCounts={setShowNavCounts}
        setThemePreference={setThemePreference}
        showBorders={showBorders}
        showNavCounts={showNavCounts}
        status={status.data}
        themePreference={themePreference}
      />
      <Workspace activeItem={activeItem} activeSectionLabel={activeSectionLabel} activeSurface={activeSurface} fileRoot={fileRoot} status={status.data} />
      <DesktopStatusBar status={status.data} />
    </main>
  );
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

  return (
    <div className="desktop-status-bar" role="status">
      <span className={status.update.restart_required ? "status-dot warn" : "status-dot"} aria-hidden="true" />
      <strong>{statusLabel}</strong>
      <span>Read-only local GUI</span>
      <span>{versionLabel}</span>
      <span>{localRepoCount} local repos</span>
      <span>{remoteRepoCount} remote repos</span>
      <span>{status.secrets.length} secrets</span>
      <span>{oauthAccounts} provider accounts</span>
      <span>{needsUpdate} need update</span>
    </div>
  );
}
