import {
  createEnvelope,
  fileExplorerFixture,
  GUI_FILE_ROOTS,
  statusFixture,
  type GuiFileExplorerData,
  type GuiFileRootId,
  type GuiResponseEnvelope,
  type GuiStatusData,
} from "../../gui-shared/src";

export async function fetchStatus(
  fetcher: typeof fetch = fetch,
): Promise<GuiResponseEnvelope<GuiStatusData>> {
  const response = await fetcher("/api/status");
  if (!response.ok) {
    throw new Error(`Status request failed with ${response.status}`);
  }

  return (await response.json()) as GuiResponseEnvelope<GuiStatusData>;
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
