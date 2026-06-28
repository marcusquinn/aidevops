import { type Dispatch, type SetStateAction, useEffect } from "react";
import type { SurfaceId } from "./app-model";

export interface NavigationHistory {
  entries: SurfaceId[];
  index: number;
}

export function nextHistoryIndex(current: NavigationHistory, direction: -1 | 1): number {
  return Math.min(Math.max(0, current.entries.length - 1), Math.max(0, current.index + direction));
}

export function useNavigationHistoryKeyboard(setNavigation: Dispatch<SetStateAction<NavigationHistory>>): void {
  useEffect(() => {
    const navigateHistoryWithKeyboard = (event: globalThis.KeyboardEvent) => {
      if (shouldIgnoreHistoryShortcut(event)) {
        return;
      }

      const direction = historyShortcutDirection(event.key);
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

function shouldIgnoreHistoryShortcut(event: globalThis.KeyboardEvent): boolean {
  return !(event.metaKey || event.ctrlKey) || isEditableKeyboardTarget(event.target) || isEditableKeyboardTarget(document.activeElement);
}

function historyShortcutDirection(key: string): -1 | 1 | null {
  return key === "[" ? -1 : key === "]" ? 1 : null;
}

function isEditableKeyboardTarget(target: EventTarget | null): boolean {
  if (typeof HTMLElement === "undefined" || !(target instanceof HTMLElement)) {
    return false;
  }

  return target.isContentEditable || target.closest("input, textarea, select, [contenteditable], [role='textbox']") !== null;
}
