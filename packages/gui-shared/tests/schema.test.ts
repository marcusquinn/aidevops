import { describe, expect, test } from "bun:test";
import {
  createEnvelope,
  FILE_EXPLORER_ROUTE_MANIFEST,
  GUI_FILE_ROOTS,
  isReadOnlyManifest,
  STATUS_ROUTE_MANIFEST,
  statusFixture,
  VAULT_STATUS_ROUTE_MANIFEST,
} from "../src";

describe("GUI shared schema contracts", () => {
  test("status route is declared as a read-only operation", () => {
    expect(isReadOnlyManifest(STATUS_ROUTE_MANIFEST)).toBe(true);
    expect(STATUS_ROUTE_MANIFEST.command_pattern).toEqual(["aidevops", "status"]);
  });

  test("file explorer route is read-only and root allowlisted", () => {
    expect(isReadOnlyManifest(FILE_EXPLORER_ROUTE_MANIFEST)).toBe(true);
    expect(FILE_EXPLORER_ROUTE_MANIFEST.operation_id).toBe("filesystem.read");
    expect(GUI_FILE_ROOTS.map((root) => root.id)).toEqual(["agents", "config", "localSetup", "git"]);
  });

  test("vault route is metadata-only and read-only", () => {
    expect(isReadOnlyManifest(VAULT_STATUS_ROUTE_MANIFEST)).toBe(true);
    expect(VAULT_STATUS_ROUTE_MANIFEST.operation_id).toBe("vault.status.read");
    expect(VAULT_STATUS_ROUTE_MANIFEST.redactions).toContain("vault_passphrases");
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
    expect(envelope.data.machine.initials).toBe("LM");
    expect(envelope.data.update.restart_required).toBe(false);
    expect(envelope.data.navigation.map((item) => item.label)).toContain("Config");
    expect(envelope.data.settings.value_policy).toBe("keys_only_no_values");
    expect(envelope.data.local_repos.path_ref).toBe("~/Git");
    expect(envelope.data.oauth_pool.value_policy).toBe("metadata_only_no_tokens");
    expect(envelope.data.vault.value_policy).toBe("metadata_only_no_secret_material");
    expect(envelope.data.vault.collections.map((collection) => collection.surface_ids).flat()).toContain("agents");
    expect(envelope.data.setup_targets[0].path_ref).toBe("~/.aidevops/agents/VERSION");
    expect(envelope.data.ai_apps.map((app) => app.name)).toContain("OpenCode");
    expect(envelope.data.capabilities[0].status).toBe("available");
  });
});
