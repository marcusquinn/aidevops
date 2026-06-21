import { describe, expect, test } from "bun:test";
import { STATUS_ADAPTER_COMMAND, readStatus } from "../src/status-adapter";

describe("status adapter", () => {
  test("uses an exact helper command pattern", () => {
    expect(STATUS_ADAPTER_COMMAND).toEqual(["aidevops", "status"]);
  });

  test("returns typed read-only status data", () => {
    const response = readStatus({ observedAt: "2026-06-21T00:00:00.000Z" });

    expect(response.ok).toBe(true);
    expect(response.operation_id).toBe("setup.status.read");
    expect(response.data.runtime).toEqual({ host: "local", api: "hono", read_only: true });
    expect(response.data.update.restart_required).toBeBoolean();
    expect(response.data.update.message).toContain("GUI app");
    expect(response.data.navigation.map((item) => item.id)).toContain("git");
    expect(response.data.settings.value_policy).toBe("keys_only_no_values");
    expect(response.data.repos.path_ref).toBe("~/.config/aidevops/repos.json");
    expect(response.data.capabilities.length).toBeGreaterThan(0);
    expect(response.data.secrets[0]).toEqual({ name: "GITHUB_TOKEN", status: "unchecked" });
  });
});
