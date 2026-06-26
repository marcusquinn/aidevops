import { describe, expect, test } from "bun:test";
import { readStatus, readVaultStatus, STATUS_ADAPTER_COMMAND } from "../src/status-adapter";

describe("status adapter", () => {
  test("uses an exact helper command pattern", () => {
    expect(STATUS_ADAPTER_COMMAND).toEqual(["aidevops", "status"]);
  });

  test("returns typed read-only status data", () => {
    const response = readStatus({ observedAt: "2026-06-21T00:00:00.000Z" });

    expect(response.ok).toBe(true);
    expect(response.operation_id).toBe("setup.status.read");
    expect(response.data.runtime).toEqual({ host: "local", api: "hono", read_only: true });
    expect(response.data.machine.initials.length).toBeGreaterThanOrEqual(1);
    expect(response.data.machine.local_ips.length).toBeGreaterThanOrEqual(1);
    expect(response.data.update.restart_required).toBeBoolean();
    expect(response.data.update.message).toContain("GUI app");
    expect(response.data.navigation.map((item) => item.id)).toContain("git");
    expect(response.data.settings.value_policy).toBe("keys_only_no_values");
    expect(response.data.repos.path_ref).toBe("~/.config/aidevops/repos.json");
    expect(response.data.local_repos.excluded_worktrees).toBeGreaterThanOrEqual(0);
    expect(response.data.oauth_pool.value_policy).toBe("metadata_only_no_tokens");
    expect(response.data.oauth_pool.providers.map((provider) => provider.provider)).toEqual(["anthropic", "openai", "cursor", "google"]);
    expect(JSON.stringify(response.data.oauth_pool)).not.toContain("\"access\"");
    expect(JSON.stringify(response.data.oauth_pool)).not.toContain("\"refresh\"");
    expect(response.data.setup_targets.map((target) => target.path_ref)).toContain("~/.aidevops/agents/VERSION");
    expect(response.data.setup_targets.every((target) => typeof target.needs_update === "boolean")).toBe(true);
    expect(response.data.ai_apps.map((app) => app.name)).toEqual(["OpenCode", "Claude Code", "Codex CLI", "Cursor"]);
    expect(JSON.stringify(response.data.ai_apps)).not.toContain("token");
    expect(response.data.vault.value_policy).toBe("metadata_only_no_secret_material");
    expect(response.data.vault.readiness.remote_unlock_enabled).toBe(false);
    expect(JSON.stringify(response.data.vault)).not.toContain("SECRET_SENTINEL_DO_NOT_RENDER");
    expect(response.data.capabilities.length).toBeGreaterThan(0);
    expect(response.data.secrets[0]).toEqual({ name: "GITHUB_TOKEN", status: "unchecked" });
  });

  test("returns a metadata-only Vault envelope", () => {
    const response = readVaultStatus({ observedAt: "2026-06-21T00:00:00.000Z" });

    expect(response.ok).toBe(true);
    expect(response.operation_id).toBe("vault.status.read");
    expect(response.data.value_policy).toBe("metadata_only_no_secret_material");
    expect(response.data.collections.map((collection) => collection.surface_ids).flat()).toContain("agents");
    expect(response.redactions).toContain("recovery_material");
  });
});
