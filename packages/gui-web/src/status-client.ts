import {
  createEnvelope,
  fileExplorerFixture,
  GUI_FILE_ROOTS,
  type GuiFileExplorerData,
  type GuiFileRootId,
  type GuiResponseEnvelope,
  type GuiStatusData,
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
    data: statusFixture,
  });
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
      oauth_pool: { ...statusFixture.oauth_pool, ...data.oauth_pool, providers: data.oauth_pool?.providers ?? statusFixture.oauth_pool.providers },
      setup_targets: data.setup_targets ?? statusFixture.setup_targets,
      ai_apps: data.ai_apps ?? statusFixture.ai_apps,
      capabilities: data.capabilities ?? statusFixture.capabilities,
      secrets: data.secrets ?? statusFixture.secrets,
      placeholders: data.placeholders ?? statusFixture.placeholders,
    },
  };
}
