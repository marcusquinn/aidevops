/* jshint esversion: 11 */
import { type ReactElement, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { FiSearch } from "react-icons/fi";
import { SurfaceGlyph } from "./AppNavigation";
import type { ConversationMode, ShellMode, SurfaceId, SurfaceIconName, SurfaceNavItem } from "./app-model";
import { navGroups, orderedNavItems, utilityNavItems } from "./app-model";
import type { GuiStatusData } from "../../gui-shared/src";

interface CommandPaletteItem {
  action?: "copy-current-link";
  description: string;
  conversationMode?: ConversationMode;
  icon: SurfaceIconName;
  iconGlyph?: string;
  id: string;
  label: string;
  repoPathRef?: string;
  searchText: string;
  sessionId?: string;
  shellMode?: ShellMode;
  surface: SurfaceId;
  tag: string;
}

const commandPaletteRecentStorageKey = "aidevops-gui-command-palette-recents";
const commandPaletteRecentLimit = 5;

const slashCommandItems: CommandPaletteItem[] = [
  { id: "slash-add-device", label: "/add-device", description: "Start device pairing setup", icon: "device", searchText: "/add-device add device pair machine", surface: "devices", tag: "Command" },
  { id: "slash-add-local-repo", label: "/add-local-repo", description: "Add a local repository path", icon: "folder", searchText: "/add-local-repo add local repo git", surface: "git", tag: "Command" },
  { id: "slash-add-remote-repo", label: "/add-remote-repo", description: "Register a remote repository", icon: "git", searchText: "/add-remote-repo add remote repo", surface: "projects", tag: "Command" },
  { id: "slash-add-secret", label: "/add-secret", description: "Add a protected secret reference", icon: "shield", searchText: "/add-secret add secret vault", surface: "security", tag: "Command" },
  { id: "slash-add-ai-provider", label: "/add-ai-provider", description: "Connect an AI provider account", icon: "users", searchText: "/add-ai-provider add ai provider oauth", surface: "aiProviders", tag: "Command" },
];

const addCommandItems: CommandPaletteItem[] = slashCommandItems.map((item) => {
  const label = item.label.replace("/", "+");

  return { ...item, id: item.id.replace("slash-", "plus-"), label, searchText: `${label} ${item.searchText}`, tag: "Add" };
});

const removeCommandItems: CommandPaletteItem[] = [
  { id: "remove-device", label: "-device", description: "Remove a paired device placeholder", icon: "device", searchText: "-device remove device unpair machine", surface: "devices", tag: "Remove" },
  { id: "remove-local-repo", label: "-local-repo", description: "Remove a local repository reference placeholder", icon: "folder", searchText: "-local-repo remove local repo git", surface: "git", tag: "Remove" },
  { id: "remove-secret", label: "-secret", description: "Remove a protected secret reference placeholder", icon: "shield", searchText: "-secret remove secret vault password", surface: "security", tag: "Remove" },
];

const terminalCommandItems: CommandPaletteItem[] = [
  { id: "terminal-new-command", label: "> new terminal command", description: "Send a command to a new terminal session", icon: "terminal", searchText: "> terminal command new session shell", surface: "localSetup", tag: "Terminal" },
];

const emojiItems: CommandPaletteItem[] = [
  { id: "emoji-thumbs-up", label: ":thumbsup:", description: "Copy or insert 👍", icon: "message", iconGlyph: "👍", searchText: ":thumbsup thumbs up approve emoji", surface: "messagingAccounts", tag: "Emoji" },
  { id: "emoji-check", label: ":white_check_mark:", description: "Copy or insert ✅", icon: "message", iconGlyph: "✅", searchText: ":white_check_mark check done emoji", surface: "messagingAccounts", tag: "Emoji" },
  { id: "emoji-eyes", label: ":eyes:", description: "Copy or insert 👀", icon: "message", iconGlyph: "👀", searchText: ":eyes review look emoji", surface: "messagingAccounts", tag: "Emoji" },
];

const plannedChannelItems: CommandPaletteItem[] = [
  { id: "channel-devops", label: "#devops", description: "Chat channel for aidevops operations", icon: "hash", searchText: "#devops devops channel chat", surface: "messagingAccounts", shellMode: "sessions", conversationMode: "people", tag: "Channel" },
  { id: "channel-comms", label: "#comms", description: "Chat channel for communications", icon: "hash", searchText: "#comms comms channel chat", surface: "messagingAccounts", shellMode: "sessions", conversationMode: "people", tag: "Channel" },
];

export interface CommandPaletteSelection {
  conversationMode?: ConversationMode;
  repoPathRef?: string;
  sessionId?: string;
  shellMode?: ShellMode;
  surface: SurfaceId;
}

export function CommandPalette({ activeSurface, close, initialQuery, openItem, status }: { activeSurface: SurfaceId; close: () => void; initialQuery: string; openItem: (selection: CommandPaletteSelection) => void; status: GuiStatusData }): ReactElement {
  const allItems = useMemo(() => commandPaletteItems(status, activeSurface), [activeSurface, status]);
  const [query, setQuery] = useState(initialQuery);
  const [activeIndex, setActiveIndex] = useState(0);
  const [recentIds, setRecentIds] = useState<string[]>(() => readCommandPaletteRecentIds());
  const inputRef = useRef<HTMLInputElement>(null);
  const matches = useMemo(() => commandPaletteMatches(allItems, query, recentIds), [allItems, query, recentIds]);

  const selectItem = useCallback((item: CommandPaletteItem | undefined) => {
    if (item) {
      const nextRecentIds = rememberCommandPaletteItemId(item.id, recentIds);
      setRecentIds(nextRecentIds);
      if (item.action === "copy-current-link") {
        void copyCurrentSurfaceLink(item.surface);
      }
      openItem({ conversationMode: item.conversationMode, repoPathRef: item.repoPathRef, sessionId: item.sessionId, shellMode: item.shellMode, surface: item.surface });
    }
  }, [openItem, recentIds]);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  useEffect(() => {
    setActiveIndex((current) => Math.min(current, Math.max(0, matches.length - 1)));
  }, [matches.length]);

  useEffect(() => {
    const handlePaletteKeys = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        close();
      } else if (event.key === "ArrowDown") {
        event.preventDefault();
        setActiveIndex((current) => Math.min(matches.length - 1, current + 1));
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        setActiveIndex((current) => Math.max(0, current - 1));
      } else if (event.key === "Enter") {
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
          <input aria-activedescendant={matches[activeIndex]?.id} aria-controls="command-palette-results" aria-expanded="true" aria-autocomplete="list" ref={inputRef} onChange={(event) => { setQuery(event.currentTarget.value); setActiveIndex(0); }} placeholder="Search /commands, #channels, _sessions, &infra, ?help, .agents" role="combobox" value={query} />
        </label>
        <ul id="command-palette-results">
          {matches.map((item, index) => (
            <li key={item.id}>
              <button className={index === activeIndex ? "active" : undefined} id={item.id} onClick={() => selectItem(item)} type="button">
                <span className="surface-icon" aria-hidden="true">{item.iconGlyph ?? <SurfaceGlyph icon={item.icon} />}</span>
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

export function commandPaletteShortcutQuery(event: Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey">): string | undefined {
  if (event.metaKey || event.ctrlKey || event.altKey) {
    return undefined;
  }

  return new Map(commandPaletteShortcutEntries).get(event.key);
}

export const commandPaletteShortcutEntries = ["#", "_", "&", "?", ">", "+", "-", "/", "=", "~", "!", ".", "*", ":", "^"].map((shortcut) => [shortcut, shortcut] as const);

export function orderCommandItemsByRecency<T extends { id: string }>(items: T[], recentIds: string[]): T[] {
  const recentItems = recentIds
    .map((id) => items.find((item) => item.id === id))
    .filter((item): item is T => item !== undefined);
  const recentItemIds = new Set(recentItems.map((item) => item.id));

  return [...recentItems, ...items.filter((item) => !recentItemIds.has(item.id))];
}

export function rememberCommandPaletteItemId(itemId: string, currentIds: string[]): string[] {
  const nextIds = [itemId, ...currentIds.filter((id) => id !== itemId)].slice(0, commandPaletteRecentLimit);
  writeCommandPaletteRecentIds(nextIds);
  return nextIds;
}

export function commandPaletteMatches(items: CommandPaletteItem[], query: string, recentIds: string[]): CommandPaletteItem[] {
  const normalizedQuery = query.trim().toLowerCase();
  const prefix = normalizedQuery.charAt(0);
  const scopedItems = itemsForCommandPrefix(items, prefix);
  const filterQuery = commandPaletteShortcutEntries.some(([shortcut]) => shortcut === prefix) ? normalizedQuery.slice(1).trim() : normalizedQuery;

  if (normalizedQuery.length === 0 || commandPaletteShortcutEntries.some(([shortcut]) => shortcut === normalizedQuery)) {
    return orderCommandItemsByRecency(scopedItems, recentIds).slice(0, 8);
  }

  return scopedItems
    .filter((item) => item.searchText.toLowerCase().includes(filterQuery))
    .slice(0, 8);
}

function commandPaletteItems(status: GuiStatusData, activeSurface: SurfaceId): CommandPaletteItem[] {
  const surfaceItems: CommandPaletteItem[] = orderedNavItems.map((item) => ({
    description: item.description,
    icon: item.icon,
    id: `surface-${item.id}`,
    label: item.label,
    searchText: `${item.label} ${item.description}`,
    surface: item.id,
    tag: surfaceTagForItem(item),
  }));
  const helpItems: CommandPaletteItem[] = [
    { id: "help-shortcuts", label: "? shortcuts", description: "Open command palette and keyboard shortcut help", icon: "help", searchText: "? shortcuts help command palette keyboard", surface: "help", tag: "Help" },
  ];
  const currentLinkItems: CommandPaletteItem[] = [
    { action: "copy-current-link", id: "copy-current-link", label: `^ copy ${activeSurface} link`, description: "Copy a link that can reopen this page in the web or local app", icon: "link", searchText: `^ link copy current page url ${activeSurface} aidevops://surface/${activeSurface}`, surface: activeSurface, tag: "Link" },
  ];
  const sessionItems: CommandPaletteItem[] = status.opencode_sessions.sessions.map((session) => ({
    description: `AI session in ${session.repo_path_ref}`,
    icon: "terminal",
    iconGlyph: "_",
    id: `session-${session.id_ref}`,
    label: `_${session.title}`,
    repoPathRef: session.repo_path_ref,
    searchText: `_${session.title} ${session.title} ${session.repo_path_ref} ${session.agent} ${session.model}`,
    sessionId: session.id_ref,
    surface: "git",
    shellMode: "sessions",
    conversationMode: "ai",
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

  return [...surfaceItems, ...helpItems, ...sessionItems, ...plannedChannelItems, ...directMessageItems, ...slashCommandItems, ...addCommandItems, ...removeCommandItems, ...terminalCommandItems, ...emojiItems, ...currentLinkItems];
}

function itemsForCommandPrefix(items: CommandPaletteItem[], prefix: string): CommandPaletteItem[] {
  const tagsByPrefix = new Map<string, string[]>([
    ["/", ["Command"]],
    ["@", ["Direct message"]],
    ["#", ["Channel"]],
    ["_", ["AI session"]],
    ["&", ["Infrastructure"]],
    ["?", ["Help"]],
    [">", ["Terminal"]],
    ["+", ["Add"]],
    ["-", ["Remove"]],
    ["=", ["Comms"]],
    ["~", ["Settings"]],
    ["!", ["Notifications"]],
    [".", ["Agent"]],
    ["*", ["Secret"]],
    [":", ["Emoji"]],
    ["^", ["Link"]],
  ]);
  const allowedTags = tagsByPrefix.get(prefix) ?? ["Surface"];

  return items.filter((item) => allowedTags.includes(item.tag));
}

function surfaceTagForItem(item: SurfaceNavItem): string {
  const explicitTags: Partial<Record<SurfaceId, string>> = {
    agents: "Agent",
    config: "Settings",
    help: "Help",
    notifications: "Notifications",
    projectConfig: "Settings",
    security: "Secret",
    settings: "Settings",
    vault: "Secret",
  };
  const infrastructureIds = navGroups.find((group) => group.label === "Infrastructure")?.items.map((groupItem) => groupItem.id) ?? [];
  const commsIds = navGroups.filter((group) => group.mode === "comms").flatMap((group) => group.items.map((groupItem) => groupItem.id));
  const utilityFallback = utilityNavItems.some((utilityItem) => utilityItem.id === item.id) ? "Surface" : undefined;

  return explicitTags[item.id] ?? (infrastructureIds.includes(item.id) ? "Infrastructure" : undefined) ?? (commsIds.includes(item.id) ? "Comms" : undefined) ?? utilityFallback ?? "Surface";
}

async function copyCurrentSurfaceLink(surface: SurfaceId): Promise<void> {
  const browserUrl = typeof window === "undefined" ? "" : window.location.href.split("#")[0];
  const link = browserUrl.length > 0 ? `${browserUrl}#surface=${surface}` : `aidevops://surface/${surface}`;

  if (typeof navigator !== "undefined" && navigator.clipboard) {
    await navigator.clipboard.writeText(link);
  }
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
