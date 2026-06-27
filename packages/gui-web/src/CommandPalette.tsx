/* jshint esversion: 11 */
import { type ReactElement, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { FiSearch } from "react-icons/fi";
import { SurfaceGlyph } from "./AppNavigation";
import type { SurfaceId, SurfaceNavItem } from "./app-model";
import { orderedNavItems } from "./app-model";
import type { GuiStatusData } from "../../gui-shared/src";

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

export function CommandPalette({ close, initialQuery, openSurface, status }: { close: () => void; initialQuery: string; openSurface: (surface: SurfaceId) => void; status: GuiStatusData }): ReactElement {
  const allItems = useMemo(() => commandPaletteItems(status), [status]);
  const [query, setQuery] = useState(initialQuery);
  const [activeIndex, setActiveIndex] = useState(0);
  const [recentIds, setRecentIds] = useState<string[]>(() => readCommandPaletteRecentIds());
  const inputRef = useRef<HTMLInputElement>(null);
  const matches = useMemo(() => commandPaletteMatches(allItems, query, recentIds), [allItems, query, recentIds]);

  const selectItem = useCallback((item: CommandPaletteItem | undefined) => {
    if (item) {
      const nextRecentIds = rememberCommandPaletteItemId(item.id, recentIds);
      setRecentIds(nextRecentIds);
      openSurface(item.surface);
    }
  }, [openSurface, recentIds]);

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
          <input aria-activedescendant={matches[activeIndex]?.id} aria-controls="command-palette-results" aria-expanded="true" aria-autocomplete="list" ref={inputRef} onChange={(event) => { setQuery(event.currentTarget.value); setActiveIndex(0); }} placeholder="Search commands, #sessions, #channels, @people, or /actions" role="combobox" value={query} />
        </label>
        <ul id="command-palette-results">
          {matches.map((item, index) => (
            <li key={item.id}>
              <button className={index === activeIndex ? "active" : undefined} id={item.id} onClick={() => selectItem(item)} type="button">
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

export function commandPaletteShortcutQuery(event: Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey">): string | undefined {
  if (event.metaKey || event.ctrlKey || event.altKey) {
    return undefined;
  }

  return new Map([["/", "/"], ["@", "@"], ["#", "#"], [".", ""]]).get(event.key);
}

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

function commandPaletteMatches(items: CommandPaletteItem[], query: string, recentIds: string[]): CommandPaletteItem[] {
  const normalizedQuery = query.trim().toLowerCase();
  const prefix = normalizedQuery.charAt(0);
  const scopedItems = itemsForCommandPrefix(items, prefix);

  if (normalizedQuery.length === 0 || ["/", "@", "#"].includes(normalizedQuery)) {
    return orderCommandItemsByRecency(scopedItems, recentIds).slice(0, 8);
  }

  return scopedItems
    .filter((item) => item.searchText.toLowerCase().includes(normalizedQuery))
    .slice(0, 8);
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
  const tagsByPrefix = new Map<string, string[]>([
    ["/", ["Command"]],
    ["@", ["Direct message"]],
    ["#", ["AI session", "Channel"]],
  ]);
  const allowedTags = tagsByPrefix.get(prefix) ?? ["Surface"];

  return items.filter((item) => allowedTags.includes(item.tag));
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
