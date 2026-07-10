import {
  createEnvelope,
  fileExplorerFixture,
  GUI_FILE_ROOTS,
  type GuiFileExplorerData,
  type GuiFileRootId,
  type GuiResponseEnvelope,
  type GuiStatusData,
  type GuiVaultStatusData,
  statusFixture,
} from "../../gui-shared/src";

export async function fetchStatus(
  fetcher: typeof fetch = fetch,
): Promise<GuiResponseEnvelope<GuiStatusData>> {
  const response = await fetcher("/api/status");
  if (!response.ok) {
    throw new Error(`Status request failed with ${response.status}`);
  }

  return normalizeStatusEnvelope((await response.json()) as GuiResponseEnvelope<Partial<GuiStatusData>>);
}

export function mockedStatus(): GuiResponseEnvelope<GuiStatusData> {
  return createEnvelope({
    operation_id: "setup.status.read",
    source: {
      surface: "setup",
      authority: "aidevops helpers",
      path_refs: ["~/.aidevops/agents", "~/.config/aidevops/settings.json"],
    },
    data: { ...statusFixture, secrets: [] },
  });
}

export function unavailableStatus(): GuiResponseEnvelope<GuiStatusData> {
  const envelope = mockedStatus();
  return { ...envelope, data: { ...envelope.data, vault: unavailableVault("error") } };
}

export async function fetchFileExplorer(
  rootId: GuiFileRootId,
  relativePath = "",
  fetcher: typeof fetch = fetch,
): Promise<GuiResponseEnvelope<GuiFileExplorerData>> {
  const query = relativePath.length > 0 ? `?path=${encodeURIComponent(relativePath)}` : "";
  const response = await fetcher(`/api/files/${rootId}${query}`);
  if (!response.ok) {
    throw new Error(`File explorer request failed with ${response.status}`);
  }

  return (await response.json()) as GuiResponseEnvelope<GuiFileExplorerData>;
}

export function mockedFileExplorer(rootId: GuiFileRootId): GuiResponseEnvelope<GuiFileExplorerData> {
  const root = GUI_FILE_ROOTS.find((entry) => entry.id === rootId) ?? GUI_FILE_ROOTS[0];

  return createEnvelope({
    operation_id: "filesystem.read",
    source: {
      surface: "filesystem",
      authority: "local read-only allowlist",
      path_refs: [root.path_ref],
    },
    data: {
      ...fileExplorerFixture,
      root,
      current_path_ref: root.path_ref,
      selected_preview: root.id === "agents" ? fileExplorerFixture.selected_preview : null,
    },
  });
}

function normalizeStatusEnvelope(envelope: GuiResponseEnvelope<Partial<GuiStatusData>>): GuiResponseEnvelope<GuiStatusData> {
  const data = envelope.data ?? {};

  const vault = normalizeVault(data.vault);
  return {
    ...envelope,
    data: {
      ...statusFixture,
      ...data,
      update: { ...statusFixture.update, ...data.update },
      runtime: { ...statusFixture.runtime, ...data.runtime },
      machine: { ...statusFixture.machine, ...data.machine },
      paths: data.paths ?? statusFixture.paths,
      helper_availability: data.helper_availability ?? statusFixture.helper_availability,
      navigation: data.navigation ?? statusFixture.navigation,
      settings: { ...statusFixture.settings, ...data.settings },
      repos: { ...statusFixture.repos, ...data.repos, repos: data.repos?.repos ?? statusFixture.repos.repos },
      local_repos: { ...statusFixture.local_repos, ...data.local_repos, repos: data.local_repos?.repos ?? statusFixture.local_repos.repos },
      opencode_sessions: { ...statusFixture.opencode_sessions, ...data.opencode_sessions, sessions: data.opencode_sessions?.sessions ?? statusFixture.opencode_sessions.sessions },
      oauth_pool: { ...statusFixture.oauth_pool, ...data.oauth_pool, providers: data.oauth_pool?.providers ?? statusFixture.oauth_pool.providers },
      setup_targets: data.setup_targets ?? statusFixture.setup_targets,
      ai_apps: data.ai_apps ?? statusFixture.ai_apps,
      managed_apps: data.managed_apps ?? statusFixture.managed_apps,
      notifications: data.notifications ?? statusFixture.notifications,
      vault,
      pulse_workers: {
        ...statusFixture.pulse_workers,
        ...data.pulse_workers,
        kpis: data.pulse_workers?.kpis ?? statusFixture.pulse_workers.kpis,
        attention: data.pulse_workers?.attention ?? statusFixture.pulse_workers.attention,
        insights: data.pulse_workers?.insights ?? statusFixture.pulse_workers.insights,
        filters: { ...statusFixture.pulse_workers.filters, ...data.pulse_workers?.filters },
        charts: data.pulse_workers?.charts ?? statusFixture.pulse_workers.charts,
        events: data.pulse_workers?.events ?? statusFixture.pulse_workers.events,
        actions: data.pulse_workers?.actions ?? statusFixture.pulse_workers.actions,
      },
      capabilities: data.capabilities ?? statusFixture.capabilities,
      secrets: vault.status === "unlocked" && vault.unlocked ? data.secrets ?? [] : [],
      placeholders: data.placeholders ?? statusFixture.placeholders,
    },
  };
}

function normalizeVault(vault: GuiStatusData["vault"] | undefined): GuiVaultStatusData {
  if (vault === undefined || vault.status === undefined || vault.setup_state === undefined) {
    return unavailableVault("unchecked");
  }
  return {
    ...statusFixture.vault,
    ...vault,
    readiness: { ...statusFixture.vault.readiness, ...vault.readiness },
    collections: vault.collections ?? statusFixture.vault.collections,
    devices: vault.devices ?? statusFixture.vault.devices,
    sync: { ...statusFixture.vault.sync, ...vault.sync },
    secure_messages: { ...statusFixture.vault.secure_messages, ...vault.secure_messages },
    backups: { ...statusFixture.vault.backups, ...vault.backups },
    audit: { ...statusFixture.vault.audit, ...vault.audit },
  };
}

function unavailableVault(helperStatus: GuiVaultStatusData["helper_status"]): GuiVaultStatusData {
  return {
    ...statusFixture.vault,
    status: "unknown",
    setup_state: "unknown",
    initialized: false,
    locked: true,
    unlocked: false,
    available: false,
    helper_status: helperStatus,
    readiness: {
      ...statusFixture.vault.readiness,
      migration_allowed: false,
      setup_required: false,
      restart_test_required: false,
      locked_content_hidden: true,
    },
    collections: statusFixture.vault.collections.map((collection) => ({ ...collection, state: collection.state === "planned" ? "planned" : "unknown" })),
  };
}
