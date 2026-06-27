import { describe, expect, test } from "bun:test";
import { appearanceStorageKeys, clampSidebarWidth, loadingBrandGlyph, loadingSkeletonPanelLabels, readStoredAppearancePreferences } from "../src/App";
import { hueFromInputValue } from "../src/AppNavigation";
import { commandPaletteMatches, commandPaletteShortcutEntries, commandPaletteShortcutQuery, orderCommandItemsByRecency, rememberCommandPaletteItemId } from "../src/CommandPalette";
import { DEFAULT_ACCENT_HUE, DEFAULT_FONT, DEFAULT_FONT_SIZE, surfaceRecordCounts } from "../src/app-model";
import { renderDashboardHtml } from "../src/dashboard";
import { fetchStatus, mockedStatus } from "../src/status-client";

describe("dashboard shell", () => {
  test("renders setup/status placeholders", () => {
    const html = renderDashboardHtml(mockedStatus());

    expect(html).toContain("aidevops app interface");
    expect(html).toContain("Made for creators");
    expect(html).toContain("AI-assisted development workflows, code quality, and deployment automation");
    expect(html).toContain("DevOps");
    expect(html).toContain("Comms");
    expect(html).toContain("Operations");
    expect(html).toContain("Management");
    expect(html).toContain("Documents");
    expect(html).toContain("Email Accounts");
    expect(html).toContain("Messaging Accounts");
    expect(html).toContain("Calendars");
    expect(html).toContain("Addressbooks");
    expect(html).toContain("Notebooks");
    expect(html).toContain("Identities");
    expect(html).toContain("Sites");
    expect(html).toContain("Websites");
    expect(html).toContain("Forums");
    expect(html).toContain("Social Media");
    expect(html).toContain("Marketplaces");
    expect(html).toContain("Local Repos");
    expect(html).toContain("Remote Repos");
    expect(html).toContain("Secrets");
    expect(html).toContain("AI Providers");
    expect(html).toContain("Vault");
    expect(html).toContain("Encrypted by aidevops Vault; contents visible only when unlocked through app or authorised vault commands.");
    expect(html).toContain("AI Provider Pools");
    expect(html).toContain("AI Apps");
    expect(html).toContain("Installed aidevops targets");
    expect(html).toContain("VPNs &amp; Proxies");
    expect(html).toContain("Agents file explorer");
    expect(html).toContain("Local Setup");
    expect(html).toContain("Theme follows system preferences");
    expect(html).toContain("Appearance controls can be hidden or shown");
    expect(html).toContain("command palette");
    expect(html).toContain("AI Assistant panel");
    expect(html).toContain("profile menu");
    expect(html).toContain("Help");
    expect(html).toContain("Notifications");
    expect(html).toContain("Admin");
    expect(html).toContain("editable Hue");
    expect(html).toContain("Show borders toggle");
    expect(html).toContain("Show counts toggle");
    expect(html).toContain("desktop status bar");
    expect(html).toContain("Font size choices xs, s, m, lg, xl");
    expect(html).toContain("Menlo (default)");
    expect(html).toContain("IBM Plex Mono");
    expect(html).toContain("Playpen Sans");
    expect(html).toContain("Source Sans");
    expect(html).toContain("Source Serif");
    expect(html).toContain("Tilt Neon");
    expect(html).toContain("GUI app");
    expect(html).toContain("Installation");
    expect(html).toContain("Domains");
    expect(html).toContain("Servers");
    expect(html).toContain("Secret references");
  });

  test("derives sidebar record counts from status records", () => {
    const counts = surfaceRecordCounts(mockedStatus().data);

    expect(counts.security).toBe(1);
    expect(counts.localSetup).toBe(2);
    expect(counts.agents).toBe(3);
    expect(counts.vault).toBe(4);
    expect(counts.apps).toBe(2);
  });

  test("normalizes legacy status payloads from older local API processes", async () => {
    const legacyFetch = (async () => new Response(JSON.stringify({
      ok: true,
      operation_id: "setup.status.read",
      source: { surface: "setup", authority: "legacy", path_refs: [] },
      data: { aidevops_version: "legacy" },
      warnings: [],
      errors: [],
      redactions: [],
      observed_at: "2026-06-22T00:00:00.000Z",
    }))) as unknown as typeof fetch;
    const status = await fetchStatus(legacyFetch);

    expect(status.data.local_repos.repos).toEqual([]);
    expect(status.data.oauth_pool.providers.map((provider) => provider.provider)).toEqual(["anthropic", "openai", "cursor", "google"]);
    expect(status.data.vault.status).toBe("uninitialized");
    expect(status.data.vault.collections.flatMap((collection) => collection.surface_ids)).toContain("agents");
    expect(status.data.setup_targets[0].path_ref).toBe("~/.aidevops/agents/VERSION");
    expect(status.data.ai_apps.map((app) => app.name)).toContain("OpenCode");
    expect(status.data.machine.initials).toBe("LM");
  });

  test("loads saved appearance preferences before persistence effects run", () => {
    const preferences = readStoredAppearancePreferences(storageFrom({
      [appearanceStorageKeys.accentHue]: "210",
      [appearanceStorageKeys.font]: "Poppins",
      [appearanceStorageKeys.fontSize]: "xl",
      [appearanceStorageKeys.machineRail]: "false",
      [appearanceStorageKeys.showBorders]: "false",
      [appearanceStorageKeys.showNavCounts]: "false",
      [appearanceStorageKeys.theme]: "dark",
    }), true);

    expect(preferences.accentHue).toBe(210);
    expect(preferences.fontPreference).toBe("Poppins");
    expect(preferences.fontSizePreference).toBe("xl");
    expect(preferences.machineRailVisible).toBe(false);
    expect(preferences.showBorders).toBe(false);
    expect(preferences.showNavCounts).toBe(false);
    expect(preferences.themePreference).toBe("dark");
  });

  test("falls back safely for invalid saved appearance preferences", () => {
    const preferences = readStoredAppearancePreferences(storageFrom({
      [appearanceStorageKeys.accentHue]: "999",
      [appearanceStorageKeys.font]: "Papyrus",
      [appearanceStorageKeys.fontSize]: "huge",
      [appearanceStorageKeys.machineRail]: "false",
      [appearanceStorageKeys.showBorders]: "maybe",
      [appearanceStorageKeys.showNavCounts]: "maybe",
      [appearanceStorageKeys.theme]: "night",
    }), false);

    expect(preferences.accentHue).toBe(DEFAULT_ACCENT_HUE);
    expect(preferences.fontPreference).toBe(DEFAULT_FONT);
    expect(preferences.fontSizePreference).toBe(DEFAULT_FONT_SIZE);
    expect(preferences.machineRailVisible).toBe(true);
    expect(preferences.showBorders).toBe(true);
    expect(preferences.showNavCounts).toBe(true);
    expect(preferences.themePreference).toBe("system");
  });

  test("allows clearing the editable hue input without resetting to the default", () => {
    expect(hueFromInputValue("")).toBeNull();
    expect(hueFromInputValue("   ")).toBeNull();
    expect(hueFromInputValue("210")).toBe(210);
    expect(hueFromInputValue("999")).toBe(359);
    expect(hueFromInputValue("1e")).toBeNull();
  });

  test("clamps sidebar width to compact and wide bounds", () => {
    expect(clampSidebarWidth(120)).toBe(248);
    expect(clampSidebarWidth(360)).toBe(360);
    expect(clampSidebarWidth(800)).toBe(520);
  });

  test("keeps the loading skeleton aligned to the shell landmarks", () => {
    expect(loadingSkeletonPanelLabels).toEqual(["machine rail", "sidebar", "workspace", "status bar"]);
    expect(loadingBrandGlyph).toBe(">_");
  });

  test("maps command palette single-key shortcuts", () => {
    for (const [shortcut, query] of commandPaletteShortcutEntries) {
      expect(commandPaletteShortcutQuery(keyEvent(shortcut))).toBe(query);
    }
    expect(commandPaletteShortcutQuery({ ...keyEvent("/"), metaKey: true })).toBeUndefined();
  });

  test("scopes command palette symbol prefixes", () => {
    const items = [
      paletteItem("session-1", "_session", "AI session"),
      paletteItem("channel-1", "#devops", "Channel"),
      paletteItem("surface-agents", "Agents", "Agent"),
      paletteItem("surface-servers", "Servers", "Infrastructure"),
      paletteItem("surface-help", "Help", "Help"),
      paletteItem("terminal-new-command", "> command", "Terminal"),
      paletteItem("add-secret", "+secret", "Add"),
      paletteItem("remove-secret", "-secret", "Remove"),
      paletteItem("slash-add-secret", "/add-secret", "Command"),
      paletteItem("surface-comms", "Messaging", "Comms"),
      paletteItem("surface-settings", "Settings", "Settings"),
      paletteItem("surface-notifications", "Notifications", "Notifications"),
      paletteItem("surface-security", "Secrets", "Secret"),
      paletteItem("emoji-check", ":white_check_mark:", "Emoji"),
      paletteItem("copy-current-link", "^ copy link", "Link"),
    ];

    expect(commandPaletteMatches(items, "#", []).map((item) => item.tag)).toEqual(["Channel"]);
    expect(commandPaletteMatches(items, "_", []).map((item) => item.tag)).toEqual(["AI session"]);
    expect(commandPaletteMatches(items, "&", []).map((item) => item.tag)).toEqual(["Infrastructure"]);
    expect(commandPaletteMatches(items, "?", []).map((item) => item.tag)).toEqual(["Help"]);
    expect(commandPaletteMatches(items, ":", []).map((item) => item.tag)).toEqual(["Emoji"]);
    expect(commandPaletteMatches(items, "^", []).map((item) => item.tag)).toEqual(["Link"]);
  });

  test("filters scoped command palette queries after the shortcut symbol", () => {
    const items = [
      paletteItem("session-ui", "_UI command palette", "AI session"),
      paletteItem("session-pulse", "_Pulse diagnostics", "AI session"),
      paletteItem("channel-devops", "#devops", "Channel"),
      paletteItem("channel-comms", "#comms", "Channel"),
    ];

    expect(commandPaletteMatches(items, "_pulse", []).map((item) => item.id)).toEqual(["session-pulse"]);
    expect(commandPaletteMatches(items, "#comm", []).map((item) => item.id)).toEqual(["channel-comms"]);
  });

  test("orders command palette recent selections first", () => {
    const items = [{ id: "surface-vault" }, { id: "surface-git" }, { id: "slash-add-device" }];
    const recentIds = rememberCommandPaletteItemId("surface-git", ["slash-add-device"]);

    expect(recentIds).toEqual(["surface-git", "slash-add-device"]);
    expect(orderCommandItemsByRecency(items, recentIds).map((item) => item.id)).toEqual(["surface-git", "slash-add-device", "surface-vault"]);
  });
});

function keyEvent(key: string): Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey"> {
  return { altKey: false, ctrlKey: false, key, metaKey: false };
}

function paletteItem(id: string, label: string, tag: string) {
  return { description: label, icon: "grid" as const, id, label, searchText: label, surface: "overview" as const, tag };
}

function storageFrom(values: Record<string, string>): Pick<Storage, "getItem"> {
  return {
    getItem: (key: string) => values[key] ?? null,
  };
}
