import { createEnvelope, statusFixture, type GuiResponseEnvelope, type GuiStatusData } from "../../gui-shared/src";

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
