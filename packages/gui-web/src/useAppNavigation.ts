import { useEffect, useRef, useState } from "react";
import type { SurfaceId } from "./app-model";
import { type NavigationHistory, nextHistoryIndex, useNavigationHistoryKeyboard } from "./navigation-history";

interface AppNavigationController {
  activeSurface: SurfaceId;
  canGoBack: boolean;
  canGoForward: boolean;
  goBack: () => void;
  goForward: () => void;
  setActiveSurface: (surface: SurfaceId) => void;
}

export function useAppNavigation(): AppNavigationController {
  const [navigation, setNavigation] = useState<NavigationHistory>({ entries: ["overview"], index: 0 });
  const pendingWorkspaceSurface = useRef<SurfaceId | null>(null);
  const activeSurface = navigation.entries[navigation.index] ?? "overview";
  useNavigationHistoryKeyboard(setNavigation);

  useEffect(() => {
    if (pendingWorkspaceSurface.current !== activeSurface) {
      return;
    }

    pendingWorkspaceSurface.current = null;
    if (typeof window.matchMedia !== "function" || !window.matchMedia("(max-width: 980px)").matches) return;
    const animationFrame = window.requestAnimationFrame(() => document.querySelector<HTMLElement>(".app-inset")?.scrollIntoView({ block: "start" }));
    return () => window.cancelAnimationFrame(animationFrame);
  }, [activeSurface]);

  const setActiveSurface = (surface: SurfaceId) => {
    setNavigation((current) => navigateToSurface(current, surface, pendingWorkspaceSurface));
  };

  return {
    activeSurface,
    canGoBack: navigation.index > 0,
    canGoForward: navigation.index < navigation.entries.length - 1,
    goBack: () => setNavigation((current) => ({ ...current, index: nextHistoryIndex(current, -1) })),
    goForward: () => setNavigation((current) => ({ ...current, index: nextHistoryIndex(current, 1) })),
    setActiveSurface,
  };
}

function navigateToSurface(current: NavigationHistory, surface: SurfaceId, pendingWorkspaceSurface: { current: SurfaceId | null }): NavigationHistory {
  const currentSurface = current.entries[current.index] ?? "overview";
  if (currentSurface === surface) {
    return current;
  }

  const entries = current.entries.slice(0, current.index + 1);
  entries.push(surface);
  pendingWorkspaceSurface.current = surface;
  return { entries, index: entries.length - 1 };
}
