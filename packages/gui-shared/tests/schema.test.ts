import { describe, expect, test } from "bun:test";
import {
  STATUS_ROUTE_MANIFEST,
  createEnvelope,
  isReadOnlyManifest,
  statusFixture,
} from "../src";

describe("GUI shared schema contracts", () => {
  test("status route is declared as a read-only operation", () => {
    expect(isReadOnlyManifest(STATUS_ROUTE_MANIFEST)).toBe(true);
    expect(STATUS_ROUTE_MANIFEST.command_pattern).toEqual(["aidevops", "status"]);
  });

  test("status envelope preserves source and redaction metadata", () => {
    const envelope = createEnvelope({
      operation_id: "setup.status.read",
      source: {
        surface: "setup",
        authority: "aidevops helpers",
        path_refs: ["~/.config/aidevops/settings.json"],
      },
      data: statusFixture,
      observed_at: "2026-06-21T00:00:00.000Z",
    });

    expect(envelope.ok).toBe(true);
    expect(envelope.operation_id).toBe("setup.status.read");
    expect(envelope.redactions).toContain("secret_values");
    expect(envelope.data.runtime.read_only).toBe(true);
    expect(envelope.data.update.restart_required).toBe(false);
  });
});
