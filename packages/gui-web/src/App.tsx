/* jshint esversion: 11 */
import { useEffect, useState } from "react";
import type { GuiResponseEnvelope, GuiStatusData } from "../../gui-shared/src";
import { fetchStatus, mockedStatus } from "./status-client";
import { Sidebar, Workspace } from "./AppSurfaces";
import { fileRootBySurface, findSurface, getSystemTheme } from "./app-model";
import type { SurfaceId, ThemePreference } from "./app-model";

export function App() {
  const [status, setStatus] = useState<GuiResponseEnvelope<GuiStatusData>>(mockedStatus());
  const [activeSurface, setActiveSurface] = useState<SurfaceId>("overview");
  const [themePreference, setThemePreference] = useState<ThemePreference>("system");
  const [systemTheme, setSystemTheme] = useState<"light" | "dark">("light");
  const resolvedTheme = themePreference === "system" ? systemTheme : themePreference;
  const activeItem = findSurface(activeSurface);
  const fileRoot = fileRootBySurface[activeSurface];

  useEffect(() => {
    const savedTheme = window.localStorage.getItem("aidevops-gui-theme");
    if (savedTheme === "system" || savedTheme === "light" || savedTheme === "dark") {
      setThemePreference(savedTheme);
    }

    const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    const updateSystemTheme = () => setSystemTheme(getSystemTheme());
    updateSystemTheme();
    mediaQuery.addEventListener("change", updateSystemTheme);

    return () => mediaQuery.removeEventListener("change", updateSystemTheme);
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = resolvedTheme;
    document.documentElement.style.colorScheme = resolvedTheme;
    window.localStorage.setItem("aidevops-gui-theme", themePreference);
  }, [resolvedTheme, themePreference]);

  useEffect(() => {
    fetchStatus()
      .then(setStatus)
      .catch(() => setStatus(mockedStatus()));
  }, []);

  return (
    <main className="app-shell">
      <Sidebar
        activeSurface={activeSurface}
        setActiveSurface={setActiveSurface}
        setThemePreference={setThemePreference}
        themePreference={themePreference}
      />
      <Workspace activeItem={activeItem} activeSurface={activeSurface} fileRoot={fileRoot} status={status.data} />
    </main>
  );
}
