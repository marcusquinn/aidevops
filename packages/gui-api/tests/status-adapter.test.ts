import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readStatus, readVaultStatus, readVaultSummary, STATUS_ADAPTER_COMMAND } from "../src/status-adapter";

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
    expect(response.data.opencode_sessions.path_ref).toBe("~/.local/share/opencode/opencode.db");
    expect(response.data.opencode_sessions.value_policy).toBe("metadata_only_no_message_payloads");
    expect(JSON.stringify(response.data.opencode_sessions)).not.toContain("content");
    expect(JSON.stringify(response.data.opencode_sessions)).not.toContain("parts");
    expect(response.data.oauth_pool.value_policy).toBe("metadata_only_no_tokens");
    expect(response.data.oauth_pool.providers.map((provider) => provider.provider)).toEqual(["anthropic", "openai", "cursor", "google"]);
    expect(JSON.stringify(response.data.oauth_pool)).not.toContain("\"access\"");
    expect(JSON.stringify(response.data.oauth_pool)).not.toContain("\"refresh\"");
    expect(response.data.setup_targets.map((target) => target.path_ref)).toContain("~/.aidevops/agents/VERSION");
    expect(response.data.setup_targets.every((target) => typeof target.needs_update === "boolean")).toBe(true);
    expect(response.data.ai_apps.map((app) => app.name)).toEqual(["OpenCode", "Claude Code", "Codex CLI", "Cursor"]);
    expect(JSON.stringify(response.data.ai_apps)).not.toContain("token");
    expect(response.data.notifications.every((notification) => notification.source_ref.length > 0)).toBe(true);
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
    expect(response.data.collections.flatMap((collection) => collection.surface_ids)).toContain("agents");
    expect(response.redactions).toContain("recovery_material");
  });

  test("reads Vault helper output through sh without requiring an executable bit", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "aidevops-gui-vault-helper-"));
    const scriptsDir = join(repoRoot, ".agents", "scripts");
    const helperPath = join(scriptsDir, "vault-helper.sh");
    mkdirSync(scriptsDir, { recursive: true });
    writeFileSync(
      helperPath,
      [
        "case \"$1\" in",
        "  status) printf '%s\\n' unlocked ;;",
        "  setup-state) printf '%s\\n' migration-ready ;;",
        "  *) exit 2 ;;",
        "esac",
      ].join("\n"),
    );
    chmodSync(helperPath, 0o600);

    const vault = readVaultSummary(repoRoot);

    expect(vault.helper_status).toBe("available");
    expect(vault.status).toBe("unlocked");
    expect(vault.setup_state).toBe("migration-ready");
    expect(vault.readiness.migration_allowed).toBe(true);
  });
});
