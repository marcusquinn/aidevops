/* jshint esversion: 11 */
import { type ReactElement, type ReactNode, useEffect, useState } from "react";
import { FiAlertTriangle, FiBell, FiCheckCircle, FiChevronLeft, FiChevronRight, FiCommand, FiGlobe, FiHash, FiHelpCircle, FiInfo, FiLogOut, FiMessageSquare, FiSearch, FiSettings, FiShield, FiTerminal, FiTool, FiUser } from "react-icons/fi";
import type { GuiFileRootId, GuiNotificationSummary, GuiStatusData } from "../../gui-shared/src";
import { SurfaceGlyph } from "./AppNavigation";
import type { ConversationMode, ShellMode, SurfaceId, SurfaceNavItem } from "./app-model";
import { inventorySurfaceConfigs, surfaceIds, text } from "./app-model";
import { CommandPalette, type CommandPaletteSelection, commandPaletteShortcutQuery } from "./CommandPalette";
import { FileExplorerSurface } from "./FileExplorerSurface";
import { AppsSurface, EditableInventorySurface, InstallationSurface } from "./InventorySurfaces";
import { AiProvidersSurface, LocalReposSurface, LockedVaultGate, OverviewSurface, PlannedSurface, ProjectsSurface, SecuritySurface, VaultSurface } from "./StatusSurfaces";
import { isVaultSurfaceLocked, vaultCollectionForSurface } from "./VaultBadges";

const communityLinks = {
  github: "https://github.com/marcusquinn/aidevops",
  x: "https://x.com/marcuswquinn",
} as const;

export function Workspace({ activeItem, activeSectionLabel, activeSurface, canGoBack, canGoForward, conversationMode, fileRoot, goBack, goForward, selectedLocalRepoIndex, selectedSessionId, setActiveSurface, setConversationMode, setSelectedLocalRepoIndex, setSelectedSessionId, setShellMode, shellMode, status }: {
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
  selectedSessionId: string | undefined;
  setActiveSurface: (surface: SurfaceId) => void;
  setConversationMode: (mode: ConversationMode) => void;
  setSelectedLocalRepoIndex: (index: number) => void;
  setSelectedSessionId: (id: string | undefined) => void;
  setShellMode: (mode: ShellMode) => void;
  shellMode: ShellMode;
  status: GuiStatusData;
}) {
  return (
    <section className="app-inset" aria-label={text.workspaceLabel}>
      <WorkspaceHeader activeItem={activeItem} activeSectionLabel={activeSectionLabel} activeSurface={activeSurface} canGoBack={canGoBack} canGoForward={canGoForward} goBack={goBack} goForward={goForward} setActiveSurface={setActiveSurface} setConversationMode={setConversationMode} setSelectedLocalRepoIndex={setSelectedLocalRepoIndex} setSelectedSessionId={setSelectedSessionId} setShellMode={setShellMode} status={status} />
      <div className="workspace-scroll">
        {shellMode === "sessions"
          ? <ConversationWorkspace conversationMode={conversationMode} selectedLocalRepoIndex={selectedLocalRepoIndex} selectedSessionId={selectedSessionId} status={status} />
          : <SurfaceContent activeItem={activeItem} activeSurface={activeSurface} fileRoot={fileRoot} openSurface={setActiveSurface} status={status} />}
      </div>
    </section>
  );
}

function WorkspaceHeader({ activeItem, activeSectionLabel, activeSurface, canGoBack, canGoForward, goBack, goForward, setActiveSurface, setConversationMode, setSelectedLocalRepoIndex, setSelectedSessionId, setShellMode, status }: {
  activeItem: SurfaceNavItem;
  activeSectionLabel: string;
  activeSurface: SurfaceId;
  canGoBack: boolean;
  canGoForward: boolean;
  goBack: () => void;
  goForward: () => void;
  setActiveSurface: (surface: SurfaceId) => void;
  setConversationMode: (mode: ConversationMode) => void;
  setSelectedLocalRepoIndex: (index: number) => void;
  setSelectedSessionId: (id: string | undefined) => void;
  setShellMode: (mode: ShellMode) => void;
  status: GuiStatusData;
}): ReactElement {
  const [assistantOpen, setAssistantOpen] = useState(false);
  const [commandInitialQuery, setCommandInitialQuery] = useState("");
  const [commandOpen, setCommandOpen] = useState(false);
  const [notificationsOpen, setNotificationsOpen] = useState(false);
  const [profileOpen, setProfileOpen] = useState(false);
  const userInitials = status.machine.initials || "AI";
  const userName = status.machine.username || "Local user";
  const activeNotifications = status.notifications.filter((notification) => notification.status === "active");

  useEffect(() => {
    const openCommandPalette = (event: KeyboardEvent) => {
      handleWorkspaceShortcut(event, {
        goBack,
        goForward,
        openCommand: (query) => {
          setCommandInitialQuery(query);
          setCommandOpen(true);
        },
      });
    };

    window.addEventListener("keydown", openCommandPalette);
    return () => window.removeEventListener("keydown", openCommandPalette);
  }, [goBack, goForward]);

  const closeMenus = () => {
    setNotificationsOpen(false);
    setProfileOpen(false);
  };

  const openItem = ({ conversationMode, repoPathRef, sessionId, shellMode, surface }: CommandPaletteSelection) => {
    const repoIndex = status.local_repos.repos.findIndex((repo) => repo.path_ref === repoPathRef);
    setShellMode(shellMode ?? "devices");
    if (repoIndex >= 0) {
      setSelectedLocalRepoIndex(repoIndex);
    }
    setSelectedSessionId(sessionId);
    if (conversationMode) {
      setConversationMode(conversationMode);
    }
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
          <button aria-label="Open signposts and help" className="header-icon-button" onClick={() => openItem({ surface: "help" })} title="Signposts and help (?)" type="button">
            <FiHelpCircle aria-hidden="true" />
          </button>
          <button aria-expanded={notificationsOpen} aria-label="Open notifications" className="header-icon-button" onClick={() => { setNotificationsOpen((current) => !current); setProfileOpen(false); }} type="button">
            <FiBell aria-hidden="true" />
            {activeNotifications.length > 0 ? <span className="notification-dot" aria-hidden="true" /> : null}
          </button>
          {notificationsOpen ? <NotificationsMenu notifications={status.notifications} openSurface={(surface) => openItem({ surface })} /> : null}
        </div>
        <button aria-pressed={assistantOpen} aria-label="Toggle AI Assistant" className={assistantOpen ? "header-icon-button active" : "header-icon-button"} onClick={() => setAssistantOpen((current) => !current)} title="AI sessions (_)" type="button">
          <FiTerminal aria-hidden="true" />
        </button>
        <div className="header-action-menu">
          <button aria-expanded={profileOpen} aria-label={`Open profile menu for ${userName}`} className="profile-avatar-button" onClick={() => { setProfileOpen((current) => !current); setNotificationsOpen(false); }} title={userName} type="button">
            <span>{userInitials}</span>
          </button>
          {profileOpen ? <ProfileMenu openSurface={(surface) => openItem({ surface })} userName={userName} /> : null}
        </div>
      </div>
      {assistantOpen ? <AssistantPanel activeSurface={activeSurface} userName={userName} /> : null}
      {commandOpen ? <CommandPalette activeSurface={activeSurface} close={() => setCommandOpen(false)} initialQuery={commandInitialQuery} openItem={openItem} status={status} /> : null}
    </header>
  );
}

function handleWorkspaceShortcut(event: KeyboardEvent, actions: { goBack: () => void; goForward: () => void; openCommand: (query: string) => void }): void {
  const shortcutQuery = commandPaletteShortcutQuery(event);
  const isEditableTarget = isEditableShortcutTarget(event.target);
  const commandQuery = (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k" ? "" : shortcutQuery;

  if (commandQuery !== undefined && !isEditableTarget) {
    event.preventDefault();
    actions.openCommand(commandQuery);
  } else if (event.key === "Backspace" && !isEditableTarget) {
    event.preventDefault();
    (event.shiftKey ? actions.goForward : actions.goBack)();
  }
}

function isEditableShortcutTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) {
    return false;
  }

  return target.isContentEditable || ["INPUT", "SELECT", "TEXTAREA"].includes(target.tagName);
}

function NotificationsMenu({ notifications, openSurface }: { notifications: GuiNotificationSummary[]; openSurface: (surface: SurfaceId) => void }): ReactElement {
  const active = notifications.filter((notification) => notification.status === "active");
  const preview = notifications.slice(0, 4);

  return (
    <div className="popover-menu notifications-menu" role="menu">
      <div className="notifications-menu-heading">
        <strong>Notifications</strong>
        <span>{active.length} active</span>
      </div>
      {preview.length === 0 ? <p>No current aidevops notifications.</p> : null}
      {preview.map((notification) => <NotificationPreview key={notification.id} notification={notification} />)}
      <button onClick={() => openSurface("notifications")} role="menuitem" type="button">Open notifications</button>
    </div>
  );
}

function NotificationPreview({ notification }: { notification: GuiNotificationSummary }): ReactElement {
  return (
    <article className={`notification-preview ${notification.severity}`}>
      <span aria-hidden="true"><NotificationIcon notification={notification} /></span>
      <div>
        <strong>{notification.title}</strong>
        <small>{notification.category} · {notification.status}</small>
      </div>
    </article>
  );
}

function ConversationWorkspace({ conversationMode, selectedLocalRepoIndex, selectedSessionId, status }: {
  conversationMode: ConversationMode;
  selectedLocalRepoIndex: number;
  selectedSessionId: string | undefined;
  status: GuiStatusData;
}) {
  const selectedRepo = status.local_repos.repos[selectedLocalRepoIndex] ?? status.local_repos.repos[0];
  const selectedSession = selectedRepo === undefined
    ? undefined
    : status.opencode_sessions.sessions.find((session) => session.id_ref === selectedSessionId && session.repo_path_ref === selectedRepo.path_ref) ?? status.opencode_sessions.sessions.find((session) => session.repo_path_ref === selectedRepo.path_ref);
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

function SurfaceContent({ activeItem, activeSurface, fileRoot, openSurface, status }: {
  activeItem: SurfaceNavItem;
  activeSurface: SurfaceId;
  fileRoot: GuiFileRootId | undefined;
  openSurface: (surface: SurfaceId) => void;
  status: GuiStatusData;
}) {
  const inventoryConfig = inventorySurfaceConfigs[activeSurface];
  const vaultCollection = vaultCollectionForSurface(status.vault, activeSurface);
  const staticSurfaces: Partial<Record<SurfaceId, ReactNode>> = {
    overview: <OverviewSurface status={status} />,
    help: <HelpSurface />,
    settings: <SettingsSurface status={status} />,
    notifications: <NotificationsSurface openSurface={openSurface} status={status} />,
    admin: <AdminSurface />,
    vault: <VaultSurface status={status} />,
    aiSessions: <PlannedSurface label={text.aiSessions} detail={text.aiSessionsIntro} />,
    channels: <PlannedSurface label={text.channels} detail={text.channelsIntro} />,
    directMessages: <PlannedSurface label={text.directMessages} detail={text.directMessagesIntro} />,
    workers: <PlannedSurface label={text.workers} detail={text.workersIntro} />,
    repos: <PlannedSurface label={text.repos} detail={text.reposIntro} />,
    deployments: <PlannedSurface label={text.deployments} detail={text.deploymentsIntro} />,
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
    apps: <AppsSurface status={status} />,
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

function HelpSurface(): ReactElement {
  const shortcuts = [
    ["#", "Channels"],
    ["_", "AI sessions"],
    ["&", "Infrastructure"],
    ["?", "Help"],
    [">", "New terminal command"],
    ["+", "Add commands"],
    ["-", "Remove commands"],
    ["/", "Slash commands"],
    ["=", "Comms"],
    ["~", "Settings and config"],
    ["!", "Notifications"],
    [".", "Agents"],
    ["*", "Secrets and passwords"],
    [":", "Emoji picker"],
    ["^", "Copy current page link"],
  ];

  return (
    <section className="settings-surface help-surface">
      <div className="planned-card">
        <h2>Help</h2>
        <p>Use the command palette shortcuts from anywhere outside text inputs. Recent selections appear first until you keep typing to filter.</p>
      </div>
      <ul className="shortcut-list">
        {shortcuts.map(([shortcut, label]) => <li key={shortcut}><kbd>{shortcut}</kbd><span>{label}</span></li>)}
        <li><kbd>Backspace</kbd><span>Previous page</span></li>
        <li><kbd>Shift Backspace</kbd><span>Next page</span></li>
      </ul>
    </section>
  );
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

function NotificationsSurface({ openSurface, status }: { openSurface: (surface: SurfaceId) => void; status: GuiStatusData }): ReactElement {
  const active = status.notifications.filter((notification) => notification.status === "active");
  const resolved = status.notifications.filter((notification) => notification.status === "resolved");

  return (
    <section className="settings-surface notifications-surface">
      <div className="planned-card notifications-hero">
        <h2>Notifications</h2>
        <p>OpenCode startup toasts and the GUI notification centre read the same aidevops status cache and local readiness data, so resolved items disappear or downgrade everywhere after the underlying status changes.</p>
        <section aria-label="Notification summary" className="notification-summary-strip">
          <span><strong>{active.length}</strong> active</span>
          <span><strong>{resolved.length}</strong> resolved</span>
          <span><strong>{status.notifications.length}</strong> total</span>
        </section>
      </div>
      <ul aria-label="aidevops notifications" className="github-notification-list">
        {status.notifications.length === 0 ? <p className="empty-state">No aidevops notifications are currently reported.</p> : null}
        {status.notifications.map((notification) => <NotificationCard key={notification.id} notification={notification} openSurface={openSurface} />)}
      </ul>
    </section>
  );
}

function NotificationCard({ notification, openSurface }: { notification: GuiNotificationSummary; openSurface: (surface: SurfaceId) => void }): ReactElement {
  return (
    <li className={`github-notification-card ${notification.severity} ${notification.status}`}>
      <div className="notification-state-icon" aria-hidden="true"><NotificationIcon notification={notification} /></div>
      <div className="notification-card-body">
        <header>
          <div>
            <p className="eyebrow">{notification.category} · {notification.source}</p>
            <h3>{notification.title}</h3>
          </div>
          <span className="notification-status-pill">{notification.status}</span>
        </header>
        <p>{notification.message}</p>
        <small>{notification.source_ref}</small>
        <div className="notification-actions">
          {notification.actions.map((action) => {
            if (action.kind === "surface" && isSurfaceId(action.surface_id)) {
              const surfaceId = action.surface_id;
              return <button className="secondary-action" disabled={!action.enabled} key={action.id} onClick={() => openSurface(surfaceId)} type="button">{action.label}</button>;
            }

            return <button className="secondary-action" disabled key={action.id} title={action.command_preview} type="button">{action.label}</button>;
          })}
        </div>
      </div>
    </li>
  );
}

function NotificationIcon({ notification }: { notification: GuiNotificationSummary }): ReactElement {
  if (notification.severity === "error") return <FiAlertTriangle />;
  if (notification.severity === "warning") return <FiTool />;
  if (notification.severity === "success") return <FiCheckCircle />;
  return <FiInfo />;
}

function isSurfaceId(value: string | undefined): value is SurfaceId {
  return surfaceIds.includes(value as SurfaceId);
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
