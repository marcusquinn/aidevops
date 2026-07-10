import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { appearanceStorageKeys, clampSidebarWidth, loadingBrandGlyph, loadingSkeletonPanelLabels, readStoredAppearancePreferences, shouldPromptVaultSetup } from "../src/App";
import { hueFromInputValue } from "../src/AppNavigation";
import { wrappedOptionIndex } from "../src/AppearanceControls";
import { Workspace } from "../src/AppWorkspace";
import { commandPaletteMatches, commandPaletteShortcutEntries, commandPaletteShortcutQuery, orderCommandItemsByRecency, rememberCommandPaletteItemId } from "../src/CommandPalette";
import { CommsConversationSurface } from "../src/CommsConversationSurface";
import { AppsSurface, nextRecommendedFilterValue } from "../src/InventorySurfaces";
import { PulseWorkersSurface } from "../src/PulseWorkersSurface";
import { recommendedApps } from "../src/RecommendedAppsSurface";
import { AiProvidersSurface } from "../src/StatusSurfaces";
import { VaultAccessModal } from "../src/VaultAccessModal";
import { vaultDialogIntentForStatus } from "../src/VaultBadges";
import { DEFAULT_ACCENT_HUE, DEFAULT_CONTRAST, DEFAULT_FONT, DEFAULT_FONT_SIZE, chatPrimitiveStackDecision, fontOptions, navGroups, surfaceRecordCounts, type SurfaceNavItem } from "../src/app-model";
import { renderDashboardHtml } from "../src/dashboard";
import { fetchStatus, mockedStatus } from "../src/status-client";
import { workspaceTourRegistry } from "../src/WorkspaceTour";
import type { GuiConversationThread, GuiManagedAppSummary, GuiStatusData } from "../../gui-shared/src";

const guiWebRoot = `${import.meta.dir}/..`;

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
    expect(html).toContain("Repos");
    expect(html).toContain("AI Sessions");
    expect(html).toContain("Channels");
    expect(html).toContain("Direct Messages");
    expect(html).toContain("Pulse &amp; Workers");
    expect(html).toContain("Deployments");
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
    expect(html).toContain("reserved signposts/help slot immediately left of notifications");
    expect(html).toContain("AI Assistant panel");
    expect(html).toContain("profile menu");
    expect(html).toContain("Help");
    expect(html).toContain("Notifications");
    expect(html).toContain("Admin");
    expect(html).toContain("editable Hue");
    expect(html).toContain("Contrast");
    expect(html).toContain("Show borders toggle");
    expect(html).toContain("Show counts toggle");
    expect(html).toContain("desktop status bar");
    expect(html).toContain("Font size choices xs, s, m, lg, xl");
    expect(html).toContain("Inter (default)");
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
    expect(counts.vault).toBe(9);
    expect(counts.apps).toBe(2);
    expect(counts.aiSessions).toBe(mockedStatus().data.opencode_sessions.sessions.length);
    expect(counts.repos).toBe(mockedStatus().data.local_repos.total + mockedStatus().data.repos.total);
  });

  test("prompts for vault setup only once per loaded session", () => {
    const setupVault = { ...mockedStatus().data.vault, helper_status: "available" as const };
    expect(shouldPromptVaultSetup(false, setupVault, false)).toBe(true);
    expect(shouldPromptVaultSetup(false, setupVault, true)).toBe(false);
    expect(shouldPromptVaultSetup(true, setupVault, false)).toBe(false);
    expect(shouldPromptVaultSetup(false, { ...setupVault, status: "unknown", readiness: { ...setupVault.readiness, setup_required: false } }, false)).toBe(false);
  });

  test("maps Vault states to explicit setup, unlock, recovery, and unavailable intents", () => {
    const fixture = mockedStatus().data.vault;
    expect(vaultDialogIntentForStatus({ ...fixture, helper_status: "available" })).toBe("setup");
    expect(vaultDialogIntentForStatus({ ...fixture, helper_status: "available", initialized: true, status: "locked", setup_state: "migration-ready", readiness: { ...fixture.readiness, setup_required: false } })).toBe("unlock");
    expect(vaultDialogIntentForStatus({ ...fixture, helper_status: "available", initialized: true, status: "corrupted", setup_state: "unknown", readiness: { ...fixture.readiness, setup_required: false } })).toBe("recover");
    expect(vaultDialogIntentForStatus({ ...fixture, helper_status: "error", status: "unknown", setup_state: "unknown", readiness: { ...fixture.readiness, setup_required: false } })).toBe("unavailable");
    expect(vaultDialogIntentForStatus({ ...fixture, helper_status: "available", status: "unlocked", initialized: true, locked: false, unlocked: true })).toBe("lock");
  });

  test("keeps passphrases out of the Vault access dialog", () => {
    const vault = { ...mockedStatus().data.vault, helper_status: "available" as const, initialized: true, status: "locked" as const, setup_state: "migration-ready" as const, readiness: { ...mockedStatus().data.vault.readiness, setup_required: false } };
    const html = renderToStaticMarkup(createElement(VaultAccessModal, { intent: "unlock", onClose: noop, onRefresh: noop, vault }));

    expect(html).toContain("Unlock existing Vault");
    expect(html).toContain("aidevops vault unlock");
    expect(html).not.toContain("type=\"password\"");
    expect(html).not.toContain("New passphrase");
    expect(html).not.toContain("current-password");
  });

  test("renders AI session controls with audited-route placeholders", () => {
    const status = mockedStatus().data;
    const html = renderToStaticMarkup(createElement(Workspace, {
      activeItem: aiSessionsItem,
      activeSectionLabel: "Development",
      activeSurface: "aiSessions",
      canGoBack: false,
      canGoForward: false,
      conversationMode: "ai",
      fileRoot: undefined,
      goBack: noop,
      goForward: noop,
      selectedLocalRepoIndex: 0,
      selectedSessionId: status.opencode_sessions.sessions[0]?.id_ref,
      setActiveSurface: noop,
      setConversationMode: noop,
      setSelectedLocalRepoIndex: noop,
      setSelectedSessionId: noop,
      setShellMode: noop,
      shellMode: "sessions",
      status,
    }));

    expect(html).toContain("AI Sessions");
    expect(html).toContain("data-tour=\"ai-sessions-surface\"");
    expect(html).toContain("Model/provider");
    expect(html).toContain("Create worker task");
    expect(html).toContain("Context attachment");
    expect(html).toContain("Tool status");
    expect(html).toContain("data-genui-component=\"RepoHealthCard\"");
    expect(html).toContain("ready for Tambo cards");
    expect(html).toContain("MessageScroller-compatible transcript");
    expect(html).toContain("New, rename, pin, archive, delete, share, and export");
  });

  test("renders signposts button immediately before notifications with page tours", () => {
    const html = renderWorkspaceSurface(aiSessionsItem, "aiSessions");
    const signpostsIndex = html.indexOf("Start AI Sessions tour");
    const notificationsIndex = html.indexOf("Open notifications");

    expect(signpostsIndex).toBeGreaterThanOrEqual(0);
    expect(notificationsIndex).toBeGreaterThan(signpostsIndex);
    expect(html).toContain("data-tour=\"ai-sessions-surface\"");
    expect(workspaceTourRegistry.aiSessions?.map((step) => step.target)).toContain('[data-tour="ai-session-transcript"]');
  });

  test("registers route-specific tours for workspace destinations", () => {
    expect(Object.keys(workspaceTourRegistry).sort()).toEqual(["aiSessions", "channels", "deployments", "directMessages", "repos", "settings", "workers"]);
    expect(workspaceTourRegistry.channels?.[0]?.target).toBe('[data-tour="comms-conversations"]');
    expect(workspaceTourRegistry.directMessages?.[0]?.target).toBe('[data-tour="comms-conversations"]');
    expect(workspaceTourRegistry.workers?.[0]?.target).toBe('[data-tour="workers-surface"]');
    expect(workspaceTourRegistry.repos?.[0]?.target).toBe('[data-tour="repos-surface"]');
    expect(workspaceTourRegistry.deployments?.[0]?.target).toBe('[data-tour="deployments-surface"]');
    expect(workspaceTourRegistry.settings?.[0]?.target).toBe('[data-tour="settings-surface"]');
  });

  test("records the audited chat primitive stack decision", () => {
    expect(chatPrimitiveStackDecision.owner).toBe("local_vite_shell");
    expect(chatPrimitiveStackDecision.foundation).toContain("Turbostarter AI patterns");
    expect(chatPrimitiveStackDecision.adopt).toEqual(["MessageScroller", "Message", "Bubble", "Attachment", "Marker"]);
    expect(chatPrimitiveStackDecision.defer).toContain("Tambo ordinary chat persistence");
    expect(chatPrimitiveStackDecision.defer).toContain("Next.js route ownership");
  });

  test("renders Pulse and Workers data-driven dashboard with filters and drilldown", () => {
    const html = renderWorkspaceSurface(workersItem, "workers");
    const workersNavItem = navGroups.flatMap((group) => group.items).find((item) => item.id === "workers");

    expect(html).toContain("Pulse &amp; Workers");
    expect(workersNavItem).toMatchObject({ label: "Pulse & Workers" });
    expect(workersNavItem?.badge).toBeUndefined();
    expect(html).toContain("Data-driven observability");
    expect(html).toContain("Repo scope");
    expect(html).toContain("Issue origin");
    expect(html).toContain("Provider/model scope");
    expect(html).toContain("Needs attention");
    expect(html).toContain("Grouped systemic findings");
    expect(html).toContain("Third-party issues waiting");
    expect(html).toContain("No-verification outcomes");
    expect(html).toContain("Likely cause");
    expect(html).toContain("Operational trends");
    expect(html).toContain("Key indicators");
    expect(html).toContain("single-column chart stack");
    expect(html).toContain("Trends · compact bars · day/week/month/year");
    expect(html).toContain("Latest");
    expect(html).toContain("Δ period");
    expect(html).toContain("Filter controls");
    expect(html).toContain("Status");
    expect(html).toContain("Severity");
    expect(html).toContain("Provider / model");
    expect(html).toContain("Cost range");
    expect(html).toContain("Duration range");
    expect(html).toContain("Expensive runs");
    expect(html).toContain("Community bug report");
    expect(html).toContain("third-party · CONTRIBUTOR");
    expect(html).toContain("OpenAI · gpt-5.5");
    expect(html).toContain("114,000 tokens");
    expect(html).toContain("Mobile activity cards");
    expect(html).toContain("Detail drawer becomes a full-screen sheet on small screens");
    expect(html).toContain("Drilldown drawer");
    expect(html).toContain("Suggested systemic fix");
    expect(html).toContain("Related systemic findings");
    expect(html).toContain("Usage and cost");
    expect(html).toContain("Allowlisted controls");
    expect(html).toContain("Safe actions with terminal output");
    expect(html).toContain("Diagnose");
    expect(html).toContain("Run Pulse now");
    expect(html).toContain("Open logs/transcript");
    expect(html).toContain("Create systemic fix task");
    expect(html).toContain("confirmation required");
    expect(html).toContain("terminal panel becomes a full-screen panel/sheet");
    expect(html).toContain("Destructive controls such as stopping workers");
  });

  test("includes OpenPanel in recommended apps for analytics dashboards", () => {
    const openPanel = recommendedApps.find((app) => app.name === "OpenPanel");

    expect(openPanel).toMatchObject({
      websiteUrl: "https://openpanel.dev/",
      repoUrl: "https://github.com/Openpanel-dev/openpanel",
      platforms: ["webapp", "saas", "api"],
    });
    expect(openPanel?.description).toContain("privacy-first dashboards");
  });

  test("renders Pulse and Workers detail drawer when drilldown sections are absent", () => {
    const status = mockedStatus().data;
    const [firstEvent, ...remainingEvents] = status.pulse_workers.events;
    const eventWithoutDrilldownSections = { ...firstEvent, drilldown_sections: undefined } as unknown as typeof firstEvent;
    const html = renderToStaticMarkup(createElement(PulseWorkersSurface, {
      status: {
        ...status,
        pulse_workers: {
          ...status.pulse_workers,
          events: [eventWithoutDrilldownSections, ...remainingEvents],
        },
      } satisfies GuiStatusData,
    }));

    expect(html).toContain("No failure analysis recorded.");
    expect(html).toContain("No grouped finding attached to this event.");
  });

  test("renders channel and DM conversation surfaces from the unified model", () => {
    const channelHtml = renderWorkspaceSurface(channelsItem, "channels");
    const dmHtml = renderWorkspaceSurface(directMessagesItem, "directMessages");

    expect(channelHtml).toContain("Unified conversation model");
    expect(channelHtml).toContain("general");
    expect(channelHtml).toContain("worker-feed");
    expect(channelHtml).toContain("data-sender-kind=\"system\"");
    expect(channelHtml).toContain("data-genui-component=\"TaskCard\"");
    expect(channelHtml).toContain("Integrate Tambo GenUI cards");
    expect(channelHtml).toContain("ack");
    expect(channelHtml).toContain("3 members");
    expect(dmHtml).toContain("Direct Messages");
    expect(dmHtml).toContain("AI DevOps");
    expect(dmHtml).toContain("Direct support threads share the same message parts");
    expect(dmHtml).toContain("data-genui-component=\"ApprovalPromptCard\"");
    expect(dmHtml).toContain("Approval execution is deferred until audited approval tooling exists.");
    expect(dmHtml).toContain("Search channels, DMs, mentions");
  });

  test("rejects unsafe Tambo component payloads during conversation rendering", () => {
    const html = renderToStaticMarkup(createElement(CommsConversationSurface, {
      mode: "channels",
      threads: [{
        conversation: { id: "channel-unsafe", type: "channel", title: "unsafe", scope: { tenant_ref: "local", workspace_ref: "aidevops", repo_ref: null }, source_ref: "test", status: "read_only", created_at: "2026-06-27T00:00:00Z", updated_at: "2026-06-27T00:00:00Z" },
        participants: [{ id: "participant-ai", conversation_id: "channel-unsafe", kind: "ai_assistant", display_name: "AI DevOps", identity_ref: null, agent_ref: "aidevops", worker_ref: null, membership_state: "active", joined_at: "2026-06-27T00:00:00Z" }],
        messages: [{ id: "message-unsafe", conversation_id: "channel-unsafe", sender_participant_id: "participant-ai", sender_kind: "ai_assistant", sequence: 1, status: "delivered", usage: null, created_at: "2026-06-27T00:00:00Z", edited_at: null }],
        parts: [{ id: "part-unsafe", message_id: "message-unsafe", kind: "tambo_component", ordinal: 1, text: null, payload_json: { component: "TaskCard", tenant_ref: "other", session_ref: "channel-unsafe", read_only: true, props: { title: "Unsafe", status: "blocked", href: "not allowed" } }, file_ref: null, source_ref: "test" }],
        reactions: [],
        read_states: [],
      } satisfies GuiConversationThread],
    }));

    expect(html).toContain("Unsupported DevOps card");
    expect(html).toContain("tenant_scope_mismatch");
  });

  test("renders conversation threads when optional collections are absent", () => {
    const html = renderToStaticMarkup(createElement(CommsConversationSurface, {
      mode: "channels",
      threads: [{
        conversation: { id: "channel-partial", type: "channel", title: "partial", scope: { tenant_ref: "local", workspace_ref: "aidevops", repo_ref: null }, source_ref: "test", status: "read_only", created_at: "2026-06-27T00:00:00Z", updated_at: "2026-06-27T00:00:00Z" },
      } as GuiConversationThread],
    }));

    expect(html).toContain("partial");
    expect(html).toContain("0 members");
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
    expect(status.data.oauth_pool.providers.map((provider) => provider.provider)).toEqual(["anthropic", "openai", "cursor", "google", "zai"]);
    expect(status.data.vault.status).toBe("unknown");
    expect(status.data.vault.readiness.setup_required).toBe(false);
    expect(status.data.vault.collections.flatMap((collection) => collection.surface_ids)).toContain("agents");
    expect(status.data.pulse_workers.value_policy).toBe("metadata_only_no_prompt_payloads_no_secrets");
    expect(status.data.pulse_workers.events.map((event) => event.issue_origin)).toContain("third_party");
    expect(status.data.setup_targets[0].path_ref).toBe("~/.aidevops/agents/VERSION");
    expect(status.data.ai_apps.map((app) => app.name)).toContain("OpenCode");
    expect(status.data.machine.initials).toBe("LM");
  });

  test("renders AI provider recommendations, OpenCode prefixes, and multi-account copy", () => {
    const baseStatus = mockedStatus().data;
    const status: GuiStatusData = {
      ...baseStatus,
      oauth_pool: {
        ...baseStatus.oauth_pool,
        providers: baseStatus.oauth_pool.providers.map((provider) => provider.provider === "openai"
          ? {
              ...provider,
              configured: true,
              total: 2,
              available: 1,
              active_or_idle: 1,
              accounts: [
                { email_ref: "account-one@example.test", status: "active", priority: 10, last_used: "2026-07-06T00:00:00.000Z", expires_at: "2026-07-07T00:00:00.000Z", cooldown_until: null },
                { email_ref: "account-two@example.test", status: "rate-limited", priority: 0, last_used: "2026-07-05T00:00:00.000Z", expires_at: "2026-07-07T00:00:00.000Z", cooldown_until: "2026-07-06T01:00:00.000Z" },
              ],
            }
          : provider),
      },
    };
    const html = renderToStaticMarkup(createElement(AiProvidersSurface, { status }));

    expect(html).toContain("Recommended OAuth pools");
    expect(html).toContain("Z.ai");
    expect(html).toContain("Recommended");
    expect(html).toContain("openai-pool");
    expect(html).toContain("Add another account");
    expect(html).toContain("metadata-only pool entries");
  });

  test("renders AI provider metadata while Vault is locked", () => {
    const html = renderWorkspaceSurface(aiProvidersItem, "aiProviders");

    expect(html).toContain("AI Providers");
    expect(html).toContain("Recommended OAuth pools");
    expect(html).toContain("Z.ai");
    expect(html).not.toContain("AI Providers is locked");
  });

  test("renders a metadata-only Secrets workspace across locked and unlocked states", () => {
    const base = mockedStatus().data;
    const lockedStatus: GuiStatusData = {
      ...base,
      vault: { ...base.vault, helper_status: "available", initialized: true, status: "locked", setup_state: "migration-ready", readiness: { ...base.vault.readiness, setup_required: false }, collections: base.vault.collections.map((collection) => ({ ...collection, state: collection.state === "planned" ? "planned" : "locked" })) },
    };
    const unlockedStatus: GuiStatusData = {
      ...lockedStatus,
      vault: { ...lockedStatus.vault, status: "unlocked", locked: false, unlocked: true, collections: lockedStatus.vault.collections.map((collection) => ({ ...collection, state: collection.state === "planned" ? "planned" : "unlocked" })) },
    };

    const lockedHtml = renderWorkspaceSurface(securityItem, "security", lockedStatus);
    const unlockedHtml = renderWorkspaceSurface(securityItem, "security", unlockedStatus);

    expect(lockedHtml).toContain("What unlock enables");
    expect(lockedHtml).toContain("Unlock Vault");
    expect(lockedHtml).not.toContain("GITHUB_TOKEN");
    expect(unlockedHtml).toContain("Reference inventory");
    expect(unlockedHtml).toContain("GITHUB_TOKEN");
    expect(unlockedHtml).toContain("Never displayed");
    expect(unlockedHtml).not.toContain("type=\"password\"");
  });

  test("renders updated Apps copy, casing, filter order, and compact managed metadata", () => {
    const html = renderToStaticMarkup(createElement(AppsSurface, { status: { ...mockedStatus().data, managed_apps: [managedAppFixture] } }));
    const source = [
      readFileSync(`${guiWebRoot}/src/AppActionTerminal.tsx`, "utf8"),
      readFileSync(`${guiWebRoot}/src/InventorySurfaces.tsx`, "utf8"),
      readFileSync(`${guiWebRoot}/src/ManagedAppPanel.tsx`, "utf8"),
      readFileSync(`${guiWebRoot}/src/RecommendedAppsSurface.tsx`, "utf8"),
      readFileSync(`${guiWebRoot}/src/external-links.ts`, "utf8"),
    ].join("\n");

    expect(html).toContain("AIDevOps");
    expect(html).toContain("These are the apps we use and recommend from our tried &amp; tested toolkit — enabling all the things we can do with AI");
    expect(html).not.toContain("App and CLI inventory for tools installed or updated by aidevops");
    expect(source.indexOf("Recommended app operating system filters")).toBeLessThan(source.indexOf("Recommended app platform filters"));
    expect(html).toContain("app-meta managed-app-path");
    expect(html).toContain("data-tooltip=\"Installed: 3.29.11\"");
    expect(html).toContain("data-tooltip=\"Latest: 3.29.11\"");
    expect(sectionBetween(html, "managed-app-details", "app-meta managed-app-path")).not.toContain("Installed");
    expect(sectionBetween(html, "managed-app-details", "app-meta managed-app-path")).not.toContain("Latest");
    expect(source).toContain("data-tooltip={href}");
    expect(source).toContain("externalLink");
    expect(source).toContain("recommended-app-title-link");
    expect(source).toContain("app-global-tooltip");
    expect(source).toContain("tooltip.align");
    expect(source).not.toContain("title={href}");
    expect(source).not.toContain("title={`Filter by $" + "{label}`}");
    expect(source).toContain("terminalStatusLabel(job)");
    expect(source).toContain("if (!response.ok)");
    expect(source).toContain("envelope === null");
    expect(source).toContain("Network error running");
    expect(source).toContain("https://apps.apple.com/us/app/telegram-messenger/id686449807");
    expect(source).toContain("https://play.google.com/store/apps/details?id=org.telegram.messenger");
  });

  test("returns recommended filters to all when the active non-all option is selected again", () => {
    expect(nextRecommendedFilterValue("macos", "macos", "all")).toBe("all");
    expect(nextRecommendedFilterValue("macos", "linux", "all")).toBe("linux");
    expect(nextRecommendedFilterValue("all", "all", "all")).toBe("all");
  });

  test("loads saved appearance preferences before persistence effects run", () => {
    const preferences = readStoredAppearancePreferences(storageFrom({
      [appearanceStorageKeys.accentHue]: "210",
      [appearanceStorageKeys.contrast]: "high",
      [appearanceStorageKeys.font]: "Poppins",
      [appearanceStorageKeys.fontSize]: "xl",
      [appearanceStorageKeys.machineRail]: "false",
      [appearanceStorageKeys.showBorders]: "false",
      [appearanceStorageKeys.showNavCounts]: "false",
      [appearanceStorageKeys.theme]: "dark",
    }), true);

    expect(preferences.accentHue).toBe(210);
    expect(preferences.contrastPreference).toBe("high");
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
      [appearanceStorageKeys.contrast]: "extreme",
      [appearanceStorageKeys.font]: "Papyrus",
      [appearanceStorageKeys.fontSize]: "huge",
      [appearanceStorageKeys.machineRail]: "false",
      [appearanceStorageKeys.showBorders]: "maybe",
      [appearanceStorageKeys.showNavCounts]: "maybe",
      [appearanceStorageKeys.theme]: "night",
    }), false);

    expect(preferences.accentHue).toBe(DEFAULT_ACCENT_HUE);
    expect(preferences.contrastPreference).toBe(DEFAULT_CONTRAST);
    expect(preferences.fontPreference).toBe(DEFAULT_FONT);
    expect(preferences.fontSizePreference).toBe(DEFAULT_FONT_SIZE);
    expect(preferences.machineRailVisible).toBe(true);
    expect(preferences.showBorders).toBe(true);
    expect(preferences.showNavCounts).toBe(true);
    expect(preferences.themePreference).toBe("system");
  });

  test("uses the updated default appearance without Cal Sans", () => {
    expect(DEFAULT_ACCENT_HUE).toBe(191);
    expect(fontOptions.map((option) => option.value)).not.toContain("Cal Sans");
  });

  test("allows clearing the editable hue input without resetting to the default", () => {
    expect(hueFromInputValue("")).toBeNull();
    expect(hueFromInputValue("   ")).toBeNull();
    expect(hueFromInputValue("210")).toBe(210);
    expect(hueFromInputValue("999")).toBe(359);
    expect(hueFromInputValue("1e")).toBeNull();
  });

  test("wraps dropdown stepper buttons at option boundaries", () => {
    expect(wrappedOptionIndex(0, 3, -1)).toBe(2);
    expect(wrappedOptionIndex(2, 3, 1)).toBe(0);
    expect(wrappedOptionIndex(1, 3, 1)).toBe(2);
    expect(wrappedOptionIndex(0, 0, 1)).toBe(0);
  });

  test("keeps appearance borders and sizing behind shared tokens", () => {
    const css = readFileSync(`${guiWebRoot}/src/styles.css`, "utf8");

    expect(css).toContain(':root[data-borders="hidden"]');
    expect(css).toContain("--border-accent: transparent");
    expect(css).toContain("--glass-panel-shadow: none");
    expect(css).toContain(':root[data-borders="hidden"] :where(');
    expect(css).toContain("border-color: transparent !important");
    expect(css).toContain("box-shadow: none !important");
    expect(css).toContain("outline-color: transparent !important");
    expect(css).toContain(":root[data-borders=\"hidden\"] *,\n:root[data-borders=\"hidden\"] *::before,\n:root[data-borders=\"hidden\"] *::after");
    expect(css).toContain(":root[data-borders=\"hidden\"] [data-tooltip]::after");
    expect(css).toContain(":root[data-borders=\"hidden\"] .desktop-status-bar span:not(.status-dot)::before");
    expect(css).toContain("[class*=\"tooltip\"]");
    expect(css).toContain("[class*=\"loading\"]");
    expect(css).toContain(".appearance-segmented-control");
    expect(css).toContain(".appearance-panel {\n  background: transparent");
    expect(css).toContain("font-size: 0.86em");
    expect(css).toContain("border-left: 4px solid var(--border-accent)");
    expect(css).toContain("border-left: 5px solid var(--border-accent)");
    expect(css).not.toContain("border-color: var(--accent)");
    expect(css).not.toContain("border-color: #ef4444");
    expect(css).not.toContain("border-color: color-mix(in srgb, var(--accent) 52%, transparent)");
  });

  test("keeps workspace surface grids content-sized instead of vertically stretched", () => {
    const css = readFileSync(`${guiWebRoot}/src/styles.css`, "utf8");

    expect(css).toMatch(/\.workspace-scroll\s*\{[^}]*align-content:\s*start;[^}]*align-items:\s*start;/s);
    expect(css).toMatch(/\.surface-page\s*\{[^}]*align-content:\s*start;/s);
    expect(css).toMatch(/\.settings-surface,\n\.settings-form\s*\{[^}]*align-content:\s*start;/s);
    expect(css).toMatch(/\.settings-form\s*\{[^}]*align-items:\s*start;[^}]*grid-template-columns:\s*repeat\(auto-fit, minmax\(240px, 1fr\)\);/s);
    expect(css).toMatch(/\.settings-form label\s*\{[^}]*align-content:\s*start;[^}]*min-height:\s*0;/s);
    expect(css).toMatch(/\.settings-form input,\n\.settings-form select\s*\{[^}]*min-height:\s*44px;[^}]*width:\s*100%;/s);
  });

  test("clamps sidebar width to compact and wide bounds", () => {
    expect(clampSidebarWidth(120)).toBe(300);
    expect(clampSidebarWidth(360)).toBe(360);
    expect(clampSidebarWidth(800)).toBe(520);
  });

  test("keeps the loading skeleton aligned to the shell landmarks", () => {
    expect(loadingSkeletonPanelLabels).toEqual(["machine rail", "sidebar", "workspace", "status bar"]);
    expect(loadingBrandGlyph).toBe("compact prompt status");
  });

  test("renders the hydrated app immediately with status refresh in progress", () => {
    const appSource = readFileSync(`${guiWebRoot}/src/App.tsx`, "utf8");

    expect(appSource).not.toContain("if (statusLoading)");
    expect(appSource).toContain("aria-busy={statusLoading}");
  });

  test("wires desktop screenshot capture controls to native save notifications", () => {
    const appSource = readFileSync(`${guiWebRoot}/src/App.tsx`, "utf8");
    const screenshotSource = readFileSync(`${guiWebRoot}/src/ScreenshotCaptureNotification.tsx`, "utf8");
    const css = readFileSync(`${guiWebRoot}/src/styles.css`, "utf8");
    const desktopInstaller = readFileSync(`${guiWebRoot}/../gui-desktop/scripts/install-macos-app.sh`, "utf8");

    expect(appSource).toContain("ScreenshotCaptureNotificationHost");
    expect(screenshotSource).toContain("aidevops:screenshot-captured");
    expect(screenshotSource).toContain("screenshotNotifications.map");
    expect(screenshotSource).toContain("screenshot-capture-notification");
    expect(screenshotSource).toContain("screenshot-info-icon");
    expect(screenshotSource).toContain("Saved to:");
    expect(screenshotSource).toContain("File path copied to clipboard.");
    expect(screenshotSource).toContain("screenshot-path-button");
    expect(screenshotSource).toContain("screenshot-dismiss-button");
    expect(css).toContain(".screenshot-capture-notification-stack");
    expect(css).toContain(".screenshot-capture-notification .screenshot-info-icon");
    expect(css).toContain(".screenshot-capture-notification");
    expect(desktopInstaller).toContain("Screenshot App");
    expect(desktopInstaller).toContain("Screenshot Page");
    expect(desktopInstaller).toContain("cameraButton.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -9)");
    expect(desktopInstaller).toContain("cameraButton.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: 5.5)");
    expect(desktopInstaller).toContain("savePageScreenshotAfterRestoringScroll");
    expect(desktopInstaller).toContain("homeDirectoryForCurrentUser.appendingPathComponent(\"Screenshots\"");
    expect(desktopInstaller).toContain("aidevops-app-screenshot-\\(screenshotTimestamp())-\\(sanitizeFilenameComponent(nameComponent)).png");
    expect(desktopInstaller).toContain("NSPasteboard.general.setString(fileURL.path");
  });

  test("limits native Vault terminal handoff to allowlisted action identifiers", () => {
    const bridgeSource = readFileSync(`${guiWebRoot}/src/vault-command-bridge.ts`, "utf8");
    const desktopInstaller = readFileSync(`${guiWebRoot}/../gui-desktop/scripts/install-macos-app.sh`, "utf8");

    expect(bridgeSource).toContain('postMessage(action)');
    expect(bridgeSource).not.toContain("postMessage(vaultCommandText");
    expect(desktopInstaller).toContain('case "vaultCommand"');
    expect(desktopInstaller).toContain("#aidevops:trust-boundary");
    expect(desktopInstaller).toContain('case "unlock": command = "aidevops vault unlock"');
    expect(desktopInstaller).toContain('default: return');
    expect(desktopInstaller).not.toContain("do script \\\"\\(body)\\\"");
  });

  test("ships critical loading styles before React hydrates", () => {
    const html = readFileSync(`${guiWebRoot}/index.html`, "utf8");
    const css = readFileSync(`${guiWebRoot}/src/styles.css`, "utf8");

    expect(html).toContain("loading-brand-overlay");
    expect(html).toContain("loading-brand-chevron");
    expect(html).toContain("Preparing local GUI");
    expect(html).toContain("loading-cursor-blink");
    expect(html).toContain("aidevops-gui-theme");
    expect(html).toContain("app-loading-shell");
    expect(html).not.toContain("loading-brand-word");
    expect(html).not.toContain("loading-brand-icon");
    expect(css).not.toContain(".loading-brand-word");
    expect(css).toMatch(/font-family:\s*var\(--font-family-app\);/);
  });

  test("desktop wrapper defers to the web loading shell and refreshes app icon metadata", () => {
    const desktopInstaller = readFileSync(`${guiWebRoot}/../gui-desktop/scripts/install-macos-app.sh`, "utf8");

    expect(desktopInstaller).not.toContain('loadStatusHTML(title: "Starting aidevops"');
    expect(desktopInstaller).toContain('viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc"');
    expect(desktopInstaller).toContain('rm -f "${resources_dir}/aidevops.icns" "${resources_dir}/aidevops.svg"');
    expect(desktopInstaller).toContain('touch "${resources_dir}/aidevops.icns" "${contents_dir}/Info.plist" "$app_path"');
    expect(desktopInstaller).toContain("qlmanage -r cache");
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

const aiSessionsItem: SurfaceNavItem = {
  description: "AI session workspace",
  icon: "terminal",
  id: "aiSessions",
  label: "AI Sessions",
};

const aiProvidersItem: SurfaceNavItem = {
  description: "OAuth pool account metadata by provider",
  icon: "users",
  id: "aiProviders",
  label: "AI Providers",
};

const securityItem: SurfaceNavItem = {
  description: "Secret references and trust boundary",
  icon: "shield",
  id: "security",
  label: "Secrets",
};

const channelsItem: SurfaceNavItem = {
  description: "Team channels",
  icon: "hash",
  id: "channels",
  label: "Channels",
};

const directMessagesItem: SurfaceNavItem = {
  description: "Direct messages",
  icon: "message",
  id: "directMessages",
  label: "Direct Messages",
};

const workersItem: SurfaceNavItem = {
  description: "Pulse, worker sessions, outcomes, and resources",
  icon: "activity",
  id: "workers",
  label: "Pulse & Workers",
};

const managedAppFixture: GuiManagedAppSummary = {
  actions: [{ command_preview: "aidevops app update aidevops", confirmation: "recommended", enabled: true, id: "update", label: "Update" }],
  aidevops_install: true,
  aidevops_update: true,
  category: "core",
  description: "Framework CLI, agents, workflows, scripts, and local GUI assets.",
  id: "aidevops",
  install_path_ref: "/usr/local/bin/aidevops",
  installed_version: "3.29.11",
  latest_version: "3.29.11",
  name: "aidevops",
  origin_repo_url: "",
  origin_website_url: "",
  status: "found",
};

function renderWorkspaceSurface(activeItem: SurfaceNavItem, activeSurface: SurfaceNavItem["id"], status: GuiStatusData = mockedStatus().data): string {
  return renderToStaticMarkup(createElement(Workspace, {
    activeItem,
    activeSectionLabel: "Management",
    activeSurface,
    canGoBack: false,
    canGoForward: false,
    conversationMode: "people",
    fileRoot: undefined,
    goBack: noop,
    goForward: noop,
    selectedLocalRepoIndex: 0,
    selectedSessionId: undefined,
    setActiveSurface: noop,
    setConversationMode: noop,
    setSelectedLocalRepoIndex: noop,
    setSelectedSessionId: noop,
    setShellMode: noop,
    shellMode: "devices",
    status,
  }));
}

function noop(): void {
  // test callback placeholder
}

function sectionBetween(text: string, startNeedle: string, endNeedle: string): string {
  const start = text.indexOf(startNeedle);
  const end = text.indexOf(endNeedle, start);

  expect(start).toBeGreaterThanOrEqual(0);
  expect(end).toBeGreaterThanOrEqual(start);

  return text.slice(start, end);
}

function storageFrom(values: Record<string, string>): Pick<Storage, "getItem"> {
  return {
    getItem: (key: string) => values[key] ?? null,
  };
}
