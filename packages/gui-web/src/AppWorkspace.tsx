/* jshint esversion: 11 */
import { type ReactElement, type ReactNode, useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { FiBell, FiChevronLeft, FiChevronRight, FiCommand, FiCpu, FiGlobe, FiHash, FiLogOut, FiMessageSquare, FiSearch, FiSettings, FiShield, FiUser } from "react-icons/fi";
import type { GuiFileRootId, GuiStatusData } from "../../gui-shared/src";
import { SurfaceGlyph } from "./AppNavigation";
import type { ConversationMode, ShellMode, SurfaceId, SurfaceNavItem } from "./app-model";
import { inventorySurfaceConfigs, orderedNavItems, text } from "./app-model";
import { FileExplorerSurface } from "./FileExplorerSurface";
import { AppsSurface, EditableInventorySurface, InstallationSurface } from "./InventorySurfaces";
import { AiProvidersSurface, LocalReposSurface, LockedVaultGate, OverviewSurface, PlannedSurface, ProjectsSurface, SecuritySurface, VaultSurface } from "./StatusSurfaces";
import { isVaultSurfaceLocked, vaultCollectionForSurface } from "./VaultBadges";

const communityLinks = {
  github: "https://github.com/marcusquinn/aidevops",
  x: "https://x.com/marcuswquinn",
} as const;

export function Workspace({ activeItem, activeSectionLabel, activeSurface, canGoBack, canGoForward, conversationMode, fileRoot, goBack, goForward, selectedLocalRepoIndex, setActiveSurface, shellMode, status }: {
  activeItem: SurfaceNavItem;
  activeSectionLabel: string;
  activeSurface: SurfaceId;
  canGoBack: boolean;
  canGoForward: boolean;
  conversationMode: ConversationMode;
  fileRoot: GuiFileRootId | undefined;
  goBack: () => void;
  goForward: () => void;
  selectedLocalRepoIndex: number;
  setActiveSurface: (surface: SurfaceId) => void;
  shellMode: ShellMode;
  status: GuiStatusData;
}) {
  return (
    <section className="app-inset" aria-label={text.workspaceLabel}>
      <WorkspaceHeader activeItem={activeItem} activeSectionLabel={activeSectionLabel} activeSurface={activeSurface} canGoBack={canGoBack} canGoForward={canGoForward} goBack={goBack} goForward={goForward} setActiveSurface={setActiveSurface} status={status} />
      <div className="workspace-scroll">
        {shellMode === "sessions"
          ? <ConversationWorkspace conversationMode={conversationMode} selectedLocalRepoIndex={selectedLocalRepoIndex} status={status} />
          : <SurfaceContent activeItem={activeItem} activeSurface={activeSurface} fileRoot={fileRoot} status={status} />}
      </div>
    </section>
  );
}

function WorkspaceHeader({ activeItem, activeSectionLabel, activeSurface, canGoBack, canGoForward, goBack, goForward, setActiveSurface, status }: {
  activeItem: SurfaceNavItem;
  activeSectionLabel: string;
  activeSurface: SurfaceId;
  canGoBack: boolean;
  canGoForward: boolean;
  goBack: () => void;
  goForward: () => void;
  setActiveSurface: (surface: SurfaceId) => void;
  status: GuiStatusData;
}): ReactElement {
  const [assistantOpen, setAssistantOpen] = useState(false);
  const [commandInitialQuery, setCommandInitialQuery] = useState("");
  const [commandOpen, setCommandOpen] = useState(false);
  const [notificationsOpen, setNotificationsOpen] = useState(false);
  const [profileOpen, setProfileOpen] = useState(false);
  const userInitials = status.machine.initials || "AI";
  const userName = status.machine.username || "Local user";

  useEffect(() => {
    const openCommandPalette = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setCommandInitialQuery("");
        setCommandOpen(true);
        return;
      }

      if (event.key === "/" && !isEditableShortcutTarget(event.target)) {
        event.preventDefault();
        setCommandInitialQuery("/");
        setCommandOpen(true);
        return;
      }

      if (["#", "@"].includes(event.key) && !isEditableShortcutTarget(event.target)) {
        event.preventDefault();
        setCommandInitialQuery(event.key);
        setCommandOpen(true);
        return;
      }

      if (event.key === "." && !isEditableShortcutTarget(event.target)) {
        event.preventDefault();
        setCommandInitialQuery("");
        setCommandOpen(true);
      }
    };

    window.addEventListener("keydown", openCommandPalette);
    return () => window.removeEventListener("keydown", openCommandPalette);
  }, []);

  const closeMenus = () => {
    setNotificationsOpen(false);
    setProfileOpen(false);
  };

  const openSurface = (surface: SurfaceId) => {
    setActiveSurface(surface);
    closeMenus();
    setCommandOpen(false);
  };

  return (
    <header className="workspace-header">
      <div className="header-title">
        <span className="workspace-surface-icon" aria-hidden="true"><SurfaceGlyph icon={activeItem.icon} /></span>
        <div>
          <p>{activeSectionLabel}</p>
          <h1>{activeItem.label}</h1>
        </div>
      </div>
      <div className="header-center-controls">
        <div className="sidebar-history-controls workspace-history-controls">
          <button aria-label="Previous surface" disabled={!canGoBack} onClick={goBack} type="button"><FiChevronLeft /></button>
          <button aria-label="Next surface" disabled={!canGoForward} onClick={goForward} type="button"><FiChevronRight /></button>
        </div>
        <button className="workspace-search command-trigger" onClick={() => { setCommandInitialQuery(""); setCommandOpen(true); }} type="button">
          <FiSearch aria-hidden="true" />
          <span>⌘K</span>
          <strong>{text.searchPlaceholder}</strong>
        </button>
      </div>
      <div className="header-actions">
        <div className="header-action-menu">
          <button aria-expanded={notificationsOpen} aria-label="Open notifications" className="header-icon-button" onClick={() => { setNotificationsOpen((current) => !current); setProfileOpen(false); }} type="button">
            <FiBell aria-hidden="true" />
            <span className="notification-dot" aria-hidden="true" />
          </button>
          {notificationsOpen ? <NotificationsMenu openSurface={openSurface} /> : null}
        </div>
        <button aria-pressed={assistantOpen} aria-label="Toggle AI Assistant" className={assistantOpen ? "header-icon-button active" : "header-icon-button"} onClick={() => setAssistantOpen((current) => !current)} type="button">
          <FiCpu aria-hidden="true" />
        </button>
        <div className="header-action-menu">
          <button aria-expanded={profileOpen} aria-label={`Open profile menu for ${userName}`} className="profile-avatar-button" onClick={() => { setProfileOpen((current) => !current); setNotificationsOpen(false); }} title={userName} type="button">
            <span>{userInitials}</span>
          </button>
          {profileOpen ? <ProfileMenu openSurface={openSurface} userName={userName} /> : null}
        </div>
      </div>
      {assistantOpen ? <AssistantPanel activeSurface={activeSurface} userName={userName} /> : null}
      {commandOpen ? <CommandPalette close={() => setCommandOpen(false)} initialQuery={commandInitialQuery} openSurface={openSurface} status={status} /> : null}
    </header>
  );
}

function isEditableShortcutTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) {
    return false;
  }

  return target.isContentEditable || ["INPUT", "SELECT", "TEXTAREA"].includes(target.tagName);
}

function NotificationsMenu({ openSurface }: { openSurface: (surface: SurfaceId) => void }): ReactElement {
  return (
    <div className="popover-menu notifications-menu" role="menu">
      <strong>Notifications</strong>
      <p>Local readiness updates, release activity, and account alerts will collect here.</p>
      <button onClick={() => openSurface("notifications")} role="menuitem" type="button">Open notifications</button>
    </div>
  );
}

function ConversationWorkspace({ conversationMode, selectedLocalRepoIndex, status }: {
  conversationMode: ConversationMode;
  selectedLocalRepoIndex: number;
  status: GuiStatusData;
}) {
  const selectedRepo = status.local_repos.repos[selectedLocalRepoIndex] ?? status.local_repos.repos[0];
  const selectedSession = selectedRepo === undefined
    ? undefined
    : status.opencode_sessions.sessions.find((session) => session.repo_path_ref === selectedRepo.path_ref);
  const title = conversationMode === "ai" ? selectedRepo?.name ?? text.opencodeSessions : text.teams;

  return (
    <section className="chat-surface" aria-label={conversationMode === "ai" ? text.opencodeSessions : "People chat"}>
      <div className="chat-thread-panel">
        <header className="chat-thread-header">
          <div>
            <p className="eyebrow">{conversationMode === "ai" ? text.opencodeSessions : "SimpleX channels"}</p>
            <h2><FiHash aria-hidden="true" /> {title}</h2>
          </div>
          <span className="count-pill">{text.readOnly}</span>
        </header>
        <div className="chat-message-list">
          {conversationMode === "ai" ? <>
            <ChatBubble speaker="assistant" title={selectedSession?.title ?? "AI session bridge"} body={selectedSession ? `Most recent OpenCode session metadata: ${selectedSession.model} via ${selectedSession.agent}, updated ${selectedSession.updated_at}. Message payloads stay out of the status API until the turbostarter/ai chat bridge lands.` : "OpenCode session creation and continuation need an audited write route. This panel is ready for the turbostarter/ai chat surface once that adapter is connected."} />
            <ChatBubble speaker="user" title={selectedRepo?.name ?? "Local repo"} body={selectedRepo ? `Selected repo: ${selectedRepo.path_ref}. Session metadata is grouped per local repo and sorted newest first from ${status.opencode_sessions.path_ref}.` : "No local repos were discovered yet."} />
          </> : <>
            <ChatBubble speaker="assistant" title="SimpleX transport" body={text.simplexReady} />
            <ChatBubble speaker="user" title="People channel" body="Teams and direct messages share the same Slack-like channel layout while protected message payloads remain behind Vault policy." />
          </>}
        </div>
        <form className="chat-composer" aria-label="Chat composer">
          <textarea disabled placeholder={text.chatInputPlaceholder} />
          <button disabled type="button">Send</button>
        </form>
      </div>
    </section>
  );
}

function ChatBubble({ body, speaker, title }: { body: string; speaker: "assistant" | "user"; title: string }) {
  return (
    <article className={`chat-bubble ${speaker}`}>
      <strong>{title}</strong>
      <p>{body}</p>
    </article>
  );
}

function ProfileMenu({ openSurface, userName }: { openSurface: (surface: SurfaceId) => void; userName: string }): ReactElement {
  return (
    <div className="popover-menu profile-menu" role="menu">
      <div className="profile-menu-heading">
        <FiUser aria-hidden="true" />
        <span>{userName}</span>
      </div>
      <button onClick={() => openSurface("settings")} role="menuitem" type="button"><FiSettings aria-hidden="true" /> Settings</button>
      <button onClick={() => openSurface("settings")} role="menuitem" type="button"><FiCommand aria-hidden="true" /> Theme</button>
      <button onClick={() => openSurface("settings")} role="menuitem" type="button"><FiGlobe aria-hidden="true" /> Language</button>
      <div className="menu-separator" />
      <strong>Community</strong>
      <a href={communityLinks.github} rel="noreferrer" role="menuitem" target="_blank"><FiMessageSquare aria-hidden="true" /> GitHub</a>
      <a href={communityLinks.x} rel="noreferrer" role="menuitem" target="_blank"><FiGlobe aria-hidden="true" /> X</a>
      <div className="menu-separator" />
      <button onClick={() => openSurface("admin")} role="menuitem" type="button"><FiShield aria-hidden="true" /> Admin</button>
      <button className="disabled-menu-item" disabled role="menuitem" title="Hosted login is planned" type="button"><FiLogOut aria-hidden="true" /> Logout</button>
    </div>
  );
}

function AssistantPanel({ activeSurface, userName }: { activeSurface: SurfaceId; userName: string }): ReactElement {
  return (
    <aside className="assistant-panel" aria-label="AI Assistant">
      <div>
        <strong>AI Assistant</strong>
        <p>Ready to help {userName} with the current {activeSurface} surface.</p>
      </div>
      <div className="assistant-message">Hosted chat, local context, and workflow hand-off controls are planned.</div>
    </aside>
  );
}

interface CommandPaletteItem {
  description: string;
  icon: SurfaceNavItem["icon"];
  id: string;
  label: string;
  searchText: string;
  surface: SurfaceId;
  tag: string;
}

const commandPaletteRecentStorageKey = "aidevops-gui-command-palette-recents";
const commandPaletteRecentLimit = 7;

const slashCommandItems: CommandPaletteItem[] = [
  { id: "slash-add-device", label: "/add-device", description: "Start device pairing setup", icon: "device", searchText: "/add-device add device pair machine", surface: "devices", tag: "Command" },
  { id: "slash-add-local-repo", label: "/add-local-repo", description: "Add a local repository path", icon: "folder", searchText: "/add-local-repo add local repo git", surface: "git", tag: "Command" },
  { id: "slash-add-remote-repo", label: "/add-remote-repo", description: "Register a remote repository", icon: "git", searchText: "/add-remote-repo add remote repo", surface: "projects", tag: "Command" },
  { id: "slash-add-secret", label: "/add-secret", description: "Add a protected secret reference", icon: "shield", searchText: "/add-secret add secret vault", surface: "security", tag: "Command" },
  { id: "slash-add-ai-provider", label: "/add-ai-provider", description: "Connect an AI provider account", icon: "users", searchText: "/add-ai-provider add ai provider oauth", surface: "aiProviders", tag: "Command" },
];

const plannedChannelItems: CommandPaletteItem[] = [
  { id: "channel-devops", label: "#devops", description: "Chat channel for aidevops operations", icon: "message", searchText: "#devops devops channel chat", surface: "messagingAccounts", tag: "Channel" },
  { id: "channel-comms", label: "#comms", description: "Chat channel for communications", icon: "message", searchText: "#comms comms channel chat", surface: "messagingAccounts", tag: "Channel" },
];

function CommandPalette({ close, initialQuery, openSurface, status }: { close: () => void; initialQuery: string; openSurface: (surface: SurfaceId) => void; status: GuiStatusData }): ReactElement {
  const allItems = useMemo(() => commandPaletteItems(status), [status]);
  const [query, setQuery] = useState(initialQuery);
  const [activeIndex, setActiveIndex] = useState(0);
  const [recentIds, setRecentIds] = useState<string[]>(() => readCommandPaletteRecentIds());
  const inputRef = useRef<HTMLInputElement>(null);
  const matches = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    const prefix = normalizedQuery.charAt(0);
    const scopedItems = itemsForCommandPrefix(allItems, prefix);

    if (normalizedQuery.length === 0 || ["/", "@", "#"].includes(normalizedQuery)) {
      return orderCommandItemsByRecency(scopedItems, recentIds).slice(0, 8);
    }

    return scopedItems
      .filter((item) => normalizedQuery.length === 0 || item.searchText.toLowerCase().includes(normalizedQuery))
      .slice(0, 8);
  }, [allItems, query, recentIds]);

  const selectItem = (item: CommandPaletteItem | undefined) => {
    if (!item) {
      return;
    }

    const nextRecentIds = [item.id, ...recentIds.filter((id) => id !== item.id)].slice(0, commandPaletteRecentLimit);
    setRecentIds(nextRecentIds);
    writeCommandPaletteRecentIds(nextRecentIds);
    openSurface(item.surface);
  };

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  useEffect(() => {
    setActiveIndex(0);
  }, [query]);

  useEffect(() => {
    setActiveIndex((current) => Math.min(current, Math.max(0, matches.length - 1)));
  }, [matches.length]);

  useEffect(() => {
    const handlePaletteKeys = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        close();
        return;
      }

      if (event.key === "ArrowDown") {
        event.preventDefault();
        setActiveIndex((current) => Math.min(matches.length - 1, current + 1));
        return;
      }

      if (event.key === "ArrowUp") {
        event.preventDefault();
        setActiveIndex((current) => Math.max(0, current - 1));
        return;
      }

      if (event.key === "Enter") {
        event.preventDefault();
        selectItem(matches[activeIndex]);
      }
    };

    window.addEventListener("keydown", handlePaletteKeys);
    return () => window.removeEventListener("keydown", handlePaletteKeys);
  }, [activeIndex, close, matches, selectItem]);

  return createPortal(
    <div className="command-palette-backdrop" role="presentation">
      <button aria-label="Close command palette" className="command-palette-scrim" onClick={close} type="button" />
      <section aria-label="Command palette" className="command-palette">
        <label className="command-input-row">
          <FiSearch aria-hidden="true" />
          <input aria-activedescendant={matches[activeIndex]?.id} aria-controls="command-palette-results" aria-expanded="true" aria-autocomplete="list" ref={inputRef} onChange={(event) => setQuery(event.currentTarget.value)} placeholder="Search commands, #sessions, #channels, @people, or /actions" role="combobox" value={query} />
        </label>
        <ul id="command-palette-results" role="listbox">
          {matches.map((item, index) => (
            <li key={item.id}>
              <button aria-selected={index === activeIndex} className={index === activeIndex ? "active" : undefined} id={item.id} onClick={() => selectItem(item)} role="option" type="button">
                <span className="surface-icon" aria-hidden="true"><SurfaceGlyph icon={item.icon} /></span>
                <span><strong>{item.label}</strong><small>{item.tag} · {item.description}</small></span>
              </button>
            </li>
          ))}
        </ul>
      </section>
    </div>,
    document.body,
  );
}

function commandPaletteItems(status: GuiStatusData): CommandPaletteItem[] {
  const surfaceItems: CommandPaletteItem[] = orderedNavItems.map((item) => ({
    description: item.description,
    icon: item.icon,
    id: `surface-${item.id}`,
    label: item.label,
    searchText: `${item.label} ${item.description}`,
    surface: item.id,
    tag: "Surface",
  }));
  const sessionItems: CommandPaletteItem[] = status.opencode_sessions.sessions.map((session) => ({
    description: `AI session in ${session.repo_path_ref}`,
    icon: "terminal",
    id: `session-${session.id_ref}`,
    label: `#${session.title}`,
    searchText: `#${session.title} ${session.title} ${session.repo_path_ref} ${session.agent} ${session.model}`,
    surface: "git",
    tag: "AI session",
  }));
  const directMessageItems: CommandPaletteItem[] = [{
    description: "Direct message thread placeholder",
    icon: "users",
    id: "dm-local-user",
    label: `@${status.machine.username || "local-user"}`,
    searchText: `@${status.machine.username || "local-user"} direct message dm person local user`,
    surface: "messagingAccounts",
    tag: "Direct message",
  }];

  return [...surfaceItems, ...sessionItems, ...plannedChannelItems, ...directMessageItems, ...slashCommandItems];
}

function itemsForCommandPrefix(items: CommandPaletteItem[], prefix: string): CommandPaletteItem[] {
  if (prefix === "/") {
    return items.filter((item) => item.tag === "Command");
  }

  if (prefix === "@") {
    return items.filter((item) => item.tag === "Direct message");
  }

  if (prefix === "#") {
    return items.filter((item) => item.tag === "AI session" || item.tag === "Channel");
  }

  return items.filter((item) => item.tag === "Surface");
}

function orderCommandItemsByRecency(items: CommandPaletteItem[], recentIds: string[]): CommandPaletteItem[] {
  const recentItems = recentIds
    .map((id) => items.find((item) => item.id === id))
    .filter((item): item is CommandPaletteItem => item !== undefined);
  const recentItemIds = new Set(recentItems.map((item) => item.id));

  return [...recentItems, ...items.filter((item) => !recentItemIds.has(item.id))];
}

function readCommandPaletteRecentIds(): string[] {
  try {
    const storedValue = window.localStorage.getItem(commandPaletteRecentStorageKey);
    const parsedValue: unknown = storedValue ? JSON.parse(storedValue) : [];
    return Array.isArray(parsedValue) ? parsedValue.filter((value): value is string => typeof value === "string").slice(0, commandPaletteRecentLimit) : [];
  } catch {
    return [];
  }
}

function writeCommandPaletteRecentIds(ids: string[]): void {
  try {
    window.localStorage.setItem(commandPaletteRecentStorageKey, JSON.stringify(ids.slice(0, commandPaletteRecentLimit)));
  } catch {
    // Ignore unavailable storage; command navigation still works without recents.
  }
}

function SurfaceContent({ activeItem, activeSurface, fileRoot, status }: {
  activeItem: SurfaceNavItem;
  activeSurface: SurfaceId;
  fileRoot: GuiFileRootId | undefined;
  status: GuiStatusData;
}) {
  const inventoryConfig = inventorySurfaceConfigs[activeSurface];
  const vaultCollection = vaultCollectionForSurface(status.vault, activeSurface);
  const staticSurfaces: Partial<Record<SurfaceId, ReactNode>> = {
    overview: <OverviewSurface status={status} />,
    settings: <SettingsSurface status={status} />,
    notifications: <NotificationsSurface />,
    admin: <AdminSurface />,
    vault: <VaultSurface status={status} />,
    routines: <PlannedSurface label={text.routines} detail={text.routineDetail} />,
    devices: <PlannedSurface label={text.devices} detail={text.devicesIntro} />,
    vpnsProxies: <PlannedSurface label={text.vpnsProxies} detail={text.vpnsProxiesIntro} />,
    emailAccounts: <PlannedSurface label={text.emailAccounts} detail={text.managementIntro} />,
    messagingAccounts: <PlannedSurface label={text.messagingAccounts} detail={text.managementIntro} />,
    tasks: <PlannedSurface label={text.tasks} detail={text.managementIntro} />,
    contacts: <PlannedSurface label={text.contacts} detail={text.managementIntro} />,
    events: <PlannedSurface label={text.events} detail={text.managementIntro} />,
    notes: <PlannedSurface label={text.notes} detail={text.managementIntro} />,
    bookmarks: <PlannedSurface label={text.bookmarks} detail={text.managementIntro} />,
    websites: <PlannedSurface label={text.websites} detail={text.websitesIntro} />,
    forums: <PlannedSurface label={text.forums} detail={text.forumsIntro} />,
    socialMedia: <PlannedSurface label={text.socialMedia} detail={text.socialMediaIntro} />,
    marketplaces: <PlannedSurface label={text.marketplaces} detail={text.marketplacesIntro} />,
    inbox: <PlannedSurface label={text.inbox} detail={text.projectWorkIntro} />,
    campaigns: <PlannedSurface label={text.campaigns} detail={text.projectWorkIntro} />,
    cases: <PlannedSurface label={text.cases} detail={text.projectWorkIntro} />,
    projectConfig: <PlannedSurface label={text.config} detail={text.projectWorkIntro} />,
    feedback: <PlannedSurface label={text.feedback} detail={text.projectWorkIntro} />,
    knowledge: <PlannedSurface label={text.knowledge} detail={text.projectWorkIntro} />,
    maintenance: <PlannedSurface label={text.maintenance} detail={text.projectWorkIntro} />,
    performance: <PlannedSurface label={text.performance} detail={text.projectWorkIntro} />,
    reports: <PlannedSurface label={text.reports} detail={text.projectWorkIntro} />,
    apps: <AppsSurface />,
    installation: <InstallationSurface />,
    projects: <ProjectsSurface status={status} />,
    security: <SecuritySurface status={status} />,
    aiProviders: <AiProvidersSurface status={status} />,
  };

  if (isVaultSurfaceLocked(status.vault, activeSurface) && vaultCollection) {
    return <LockedVaultGate collection={vaultCollection} label={activeItem.label} vault={status.vault} />;
  }

  if (activeSurface === "git") {
    return <LocalReposSurface status={status} />;
  }

  if (fileRoot) {
    return <FileExplorerSurface key={fileRoot} rootId={fileRoot} />;
  }

  if (inventoryConfig) {
    return <EditableInventorySurface {...inventoryConfig} />;
  }

  return staticSurfaces[activeSurface] ?? null;
}

function SettingsSurface({ status }: { status: GuiStatusData }): ReactElement {
  return (
    <section className="settings-surface">
      <div className="planned-card">
        <h2>General settings</h2>
        <p>{text.settingsAccountIntro}</p>
      </div>
      <form className="settings-form">
        <label><span>Name</span><input defaultValue={status.machine.username} disabled /></label>
        <label><span>Login email</span><input disabled placeholder="email sign-in planned" type="email" /></label>
        <label><span>Login password</span><input disabled placeholder="password management planned" type="password" /></label>
        <label><span>Alternative notification email</span><input disabled placeholder="notifications email planned" type="email" /></label>
        <label><span>Language</span><select disabled defaultValue="en"><option value="en">English</option></select></label>
        <label><span>Theme</span><select disabled defaultValue="system"><option value="system">System</option><option value="light">Light</option><option value="dark">Dark</option></select></label>
      </form>
    </section>
  );
}

function NotificationsSurface(): ReactElement {
  return (
    <section className="settings-surface">
      <div className="planned-card">
        <h2>Notifications</h2>
        <p>Release updates, workflow failures, security notices, and hosted account messages will appear here.</p>
      </div>
      <ul className="notification-list">
        <li><strong>Readiness</strong><span>Local status and restart notices.</span></li>
        <li><strong>Workflow</strong><span>PR, release, and routine activity.</span></li>
        <li><strong>Security</strong><span>Vault and credentials posture reminders.</span></li>
      </ul>
    </section>
  );
}

function AdminSurface(): ReactElement {
  return (
    <section className="settings-surface">
      <div className="planned-card">
        <h2>Admin</h2>
        <p>Hosted administration, user access, billing, audit, and deployment controls are placeholders until authenticated server routes land.</p>
      </div>
    </section>
  );
}
