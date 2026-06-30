import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readStatus, readVaultStatus, readVaultSummary, STATUS_ADAPTER_COMMAND } from "../src/status-adapter";
import { resolveBinary } from "../src/status-adapter-utils";
import { readPulseWorkersSummary } from "../src/status-pulse-workers";

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
    expect(response.data.managed_apps.map((app) => app.id)).toContain("pulse");
    expect(response.data.managed_apps.find((app) => app.id === "ollama")?.install_path_ref).not.toBe("not found");
    expect(response.data.ai_apps.map((app) => app.name)).toEqual(["OpenCode", "Claude Code", "Codex CLI", "Cursor"]);
    expect(JSON.stringify(response.data.ai_apps)).not.toContain("token");
    expect(response.data.notifications.every((notification) => notification.source_ref.length > 0)).toBe(true);
    expect(response.data.vault.value_policy).toBe("metadata_only_no_secret_material");
    expect(response.data.pulse_workers.value_policy).toBe("metadata_only_no_prompt_payloads_no_secrets");
    expect(response.source.path_refs).toContain("~/.aidevops/logs/headless-runtime-metrics.jsonl");
    expect(response.data.vault.readiness.remote_unlock_enabled).toBe(false);
    expect(JSON.stringify(response.data.vault)).not.toContain("SECRET_SENTINEL_DO_NOT_RENDER");
    expect(response.data.capabilities.length).toBeGreaterThan(0);
    expect(response.data.secrets[0]).toEqual({ name: "GITHUB_TOKEN", status: "unchecked" });
  });

  test("populates Pulse and Workers status from local telemetry files", () => {
    const root = mkdtempSync(join(tmpdir(), "aidevops-gui-pulse-workers-"));
    const metricsPath = join(root, "headless-runtime-metrics.jsonl");
    const pulseStatsPath = join(root, "pulse-stats.json");
    const resourcesPath = join(root, "resource-metrics.jsonl");
    const tokenReportsRoot = join(root, "token-reports");
    const reportDir = join(tokenReportsRoot, "20260630T094500Z");
    const oauthPoolPath = join(root, "oauth-pool.json");
    mkdirSync(reportDir, { recursive: true });
    writeFileSync(metricsPath, [
      JSON.stringify({ ts: 1782810000, result: "success", issue: 25914, pr: 25999, repo: "marcusquinn/aidevops", provider: "openai", model: "gpt-5.5", input_tokens: 1200, output_tokens: 300, cached_tokens: 100, estimated_cost_usd: 0.42, duration_ms: 60000, issue_origin: "origin_interactive", author_association: "MEMBER" }),
      JSON.stringify({ ts: 1782806400, result: "blocked", issue: 25910, repo: "marcusquinn/aidevops", provider: "anthropic", model: "sonnet", total_tokens: 900, issue_origin: "third_party", author_association: "CONTRIBUTOR" }),
      JSON.stringify({ ts: 1782806300, result: "failed", issue: 25911, repo: "marcusquinn/aidevops", provider: "anthropic", model: "sonnet", total_tokens: 700, estimated_cost_usd: 0.28, duration_ms: 1900000, issue_origin: "aidevops_created", author_association: "OWNER", failure_category: "review_gate" }),
      JSON.stringify({ ts: 1782720000, result: "success", issue: 25800, repo: "marcusquinn/aidevops", provider: "openai", model: "gpt-5.5", total_tokens: 300, estimated_cost_usd: 0.10, issue_origin: "self_created", author_association: "MEMBER", verification: "bun test passed" }),
    ].join("\n"));
    writeFileSync(pulseStatsPath, JSON.stringify({ counters: { pre_dispatch_aborts: [1782810000], retry_queue: [1782806400, 1000] } }));
    writeFileSync(resourcesPath, JSON.stringify({ ts: 1782810000, role: "worker", rss_kb: 900000, peak_rss_kb: 900000, result: "success" }));
    writeFileSync(join(reportDir, "report.json"), JSON.stringify({ provider: "openai", model: "gpt-5.5", input_tokens: 500, output_tokens: 150, total_tokens: 650, estimated_cost_ref: "$0.08 estimated" }));
    writeFileSync(oauthPoolPath, JSON.stringify({ providers: [{ provider: "openai", available: 2 }] }));

    const result = readPulseWorkersSummary({ metricsPath, pulseStatsPath, resourceMetricsPath: resourcesPath, tokenReportsRoot, oauthPoolPath, observedAt: "2026-06-30T09:45:00.000Z", nowMs: 1782812700000 });

    expect(result.summary.kpis.find((kpi) => kpi.id === "worker-outcomes-24h")?.sample_size).toBe(3);
    expect(result.summary.events[0].issue_ref).toBe("#25914");
    expect(result.summary.events[0].usage?.provider).toBe("openai");
    expect(result.summary.events[0].usage?.estimated_cost_ref).toBe("$0.42 estimated");
    expect(result.summary.events[0].resources[0].pressure).toBe("medium");
    expect(result.summary.insights.map((finding) => finding.kind)).toEqual(expect.arrayContaining(["third_party_waiting", "repeated_failure", "weak_verification", "resource_pressure", "cost_spike", "slow_bottleneck"]));
    expect(result.summary.insights.find((finding) => finding.kind === "cost_spike")?.comparison_label).toContain("previous equivalent period");
    expect(result.summary.insights.find((finding) => finding.kind === "weak_verification")?.recommendation).toContain("verification command");
    expect(result.summary.insights.find((finding) => finding.kind === "repeated_failure")?.evidence_refs).toContain("#25910");
    expect(result.summary.attention.map((item) => item.id)).toContain("pulse-counter-pre-dispatch-aborts");
    expect(result.summary.filters.providers.map((item) => item.label)).toContain("openai:gpt-5.5");
    expect(JSON.stringify(result.summary)).not.toContain(root);
  });

  test("returns safe Pulse and Workers warnings for missing or malformed telemetry", () => {
    const root = mkdtempSync(join(tmpdir(), "aidevops-gui-pulse-workers-missing-"));
    const invalidPulseStatsPath = join(root, "pulse-stats.json");
    writeFileSync(invalidPulseStatsPath, "not-json");

    const result = readPulseWorkersSummary({ metricsPath: join(root, "missing.jsonl"), pulseStatsPath: invalidPulseStatsPath, resourceMetricsPath: join(root, "missing-resources.jsonl"), tokenReportsRoot: join(root, "reports"), oauthPoolPath: join(root, "oauth-pool.json"), observedAt: "2026-06-30T09:45:00.000Z" });

    expect(result.summary.events).toEqual([]);
    expect(result.summary.kpis.find((kpi) => kpi.id === "worker-outcomes-24h")?.value).toBe("unknown");
    expect(result.summary.attention.some((item) => item.title === "Telemetry source invalid")).toBe(true);
    expect(result.summary.attention.some((item) => item.id === "provider-availability-unknown")).toBe(true);
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

  test("does not search relative home tool paths when HOME is unset", () => {
    const originalCwd = process.cwd();
    const originalHome = process.env.HOME;
    const originalPath = process.env.PATH;
    const repoRoot = mkdtempSync(join(tmpdir(), "aidevops-gui-relative-path-"));
    const fakeBinDir = join(repoRoot, ".bun", "bin");
    const fakeBinary = join(fakeBinDir, "aidevops-relative-path-sentinel");
    mkdirSync(fakeBinDir, { recursive: true });
    writeFileSync(fakeBinary, "#!/bin/sh\nexit 0\n");
    chmodSync(fakeBinary, 0o700);

    try {
      process.chdir(repoRoot);
      delete process.env.HOME;
      process.env.PATH = "";

      expect(resolveBinary("aidevops-relative-path-sentinel")).toBeNull();
    } finally {
      process.chdir(originalCwd);
      if (originalHome === undefined) {
        delete process.env.HOME;
      } else {
        process.env.HOME = originalHome;
      }
      if (originalPath === undefined) {
        delete process.env.PATH;
      } else {
        process.env.PATH = originalPath;
      }
    }
  });
});
