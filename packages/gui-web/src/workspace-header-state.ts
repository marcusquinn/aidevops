import { useCallback, useEffect, useRef, useState } from "react";
import type { GuiStatusData } from "../../gui-shared/src";
import type { ConversationMode, ShellMode, SurfaceId } from "./app-model";
import type { CommandPaletteSelection } from "./CommandPalette";

export function useHeaderMenuState() {
  const [assistantOpen, setAssistantOpen] = useState(false);
  const [notificationsOpen, setNotificationsOpen] = useState(false);
  const [profileOpen, setProfileOpen] = useState(false);
  const headerActionsRef = useRef<HTMLDivElement | null>(null);
  const closeHeaderTimerRef = useRef<number | null>(null);
  const clearScheduledHeaderClose = useCallback(() => {
    if (closeHeaderTimerRef.current !== null) {
      window.clearTimeout(closeHeaderTimerRef.current);
      closeHeaderTimerRef.current = null;
    }
  }, []);
  const closeHeaderMenus = useCallback(() => {
    clearScheduledHeaderClose();
    setAssistantOpen(false);
    setNotificationsOpen(false);
    setProfileOpen(false);
  }, [clearScheduledHeaderClose]);
  const scheduleHeaderMenusClose = useCallback(() => {
    clearScheduledHeaderClose();
    closeHeaderTimerRef.current = window.setTimeout(closeHeaderMenus, 2_400);
  }, [clearScheduledHeaderClose, closeHeaderMenus]);
  const toggleNotifications = useCallback(() => {
    clearScheduledHeaderClose();
    setNotificationsOpen((current) => !current);
    setProfileOpen(false);
    setAssistantOpen(false);
  }, [clearScheduledHeaderClose]);
  const toggleAssistant = useCallback(() => {
    clearScheduledHeaderClose();
    setAssistantOpen((current) => !current);
    setNotificationsOpen(false);
    setProfileOpen(false);
  }, [clearScheduledHeaderClose]);
  const toggleProfile = useCallback(() => {
    clearScheduledHeaderClose();
    setProfileOpen((current) => !current);
    setNotificationsOpen(false);
    setAssistantOpen(false);
  }, [clearScheduledHeaderClose]);

  useEffect(() => {
    const closeOnPointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node) || !headerActionsRef.current?.contains(target)) {
        closeHeaderMenus();
      }
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        closeHeaderMenus();
      }
    };

    document.addEventListener("pointerdown", closeOnPointerDown, true);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("pointerdown", closeOnPointerDown, true);
      document.removeEventListener("keydown", closeOnEscape);
      clearScheduledHeaderClose();
    };
  }, [clearScheduledHeaderClose, closeHeaderMenus]);

  return {
    assistantOpen,
    clearScheduledHeaderClose,
    closeHeaderMenus,
    headerActionsRef,
    notificationsOpen,
    profileOpen,
    scheduleHeaderMenusClose,
    toggleAssistant,
    toggleNotifications,
    toggleProfile,
  };
}

export interface CommandPaletteNavigationActions {
  closeCommandPalette: () => void;
  closeHeaderMenus: () => void;
  setActiveSurface: (surface: SurfaceId) => void;
  setConversationMode: (mode: ConversationMode) => void;
  setSelectedLocalRepoIndex: (index: number) => void;
  setSelectedSessionId: (id: string | undefined) => void;
  setShellMode: (mode: ShellMode) => void;
  status: GuiStatusData;
}

export function applyCommandPaletteSelection({ conversationMode, repoPathRef, sessionId, shellMode, surface }: CommandPaletteSelection, actions: CommandPaletteNavigationActions): void {
  const repoIndex = actions.status.local_repos.repos.findIndex((repo) => repo.path_ref === repoPathRef);
  actions.setShellMode(shellMode ?? "devices");
  if (repoIndex >= 0) {
    actions.setSelectedLocalRepoIndex(repoIndex);
  }
  actions.setSelectedSessionId(sessionId);
  if (conversationMode) {
    actions.setConversationMode(conversationMode);
  }
  actions.setActiveSurface(surface);
  actions.closeHeaderMenus();
  actions.closeCommandPalette();
}
