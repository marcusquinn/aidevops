import { describe, expect, test } from "bun:test";
import { app } from "../src/app";

describe("status API route", () => {
  test("GET /api/health returns a lightweight readiness envelope", async () => {
    const response = await app.request("/api/health");
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.ok).toBe(true);
    expect(body.operation_id).toBe("capabilities.read");
    expect(body.data.status).toBe("ok");
  });

  test("GET /api/status returns the shared response envelope", async () => {
    const response = await app.request("/api/status");
    const body = await response.json();

    expect([200, 400]).toContain(response.status);
    expect(body.ok).toBe(true);
    expect(body.operation_id).toBe("setup.status.read");
    expect(body.redactions).toContain("secret_values");
    expect(body.data.managed_apps.map((app: { id: string }) => app.id)).toContain("aidevops");
  });

  test("app actions reject commands outside the allowlist", async () => {
    const response = await app.request("/api/apps/not-real/actions/install", { method: "POST" });
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.operation_id).toBe("apps.action.run");
    expect(body.errors).toContain("action_not_allowlisted");
  });

  test("Pulse and Workers actions reject commands outside the allowlist", async () => {
    const response = await app.request("/api/pulse-workers/actions/not-real", { method: "POST" });
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.operation_id).toBe("pulse_workers.action.run");
    expect(body.errors).toContain("action_not_allowlisted");
    expect(body.data.command_preview).toBe("not run");
  });

  test("Pulse and Workers job status fails closed for unknown jobs", async () => {
    const response = await app.request("/api/pulse-workers/jobs/not-real");
    const body = await response.json();

    expect(response.status).toBe(404);
    expect(body.operation_id).toBe("pulse_workers.action.status");
    expect(body.errors).toContain("unknown_job");
  });

  test("unknown routes fail closed", async () => {
    const response = await app.request("/api/unknown");
    const body = await response.json();

    expect(response.status).toBe(404);
    expect(body.errors).toContain("unknown_route");
  });

  test("GET /api/files/agents returns a read-only file explorer envelope", async () => {
    const response = await app.request("/api/files/agents");
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.operation_id).toBe("filesystem.read");
    expect(body.data.root.id).toBe("agents");
    expect(body.data.root.path_ref).toBe("~/.aidevops/agents");
  });

  test("GET /api/vault/status returns metadata without unlock material", async () => {
    const response = await app.request("/api/vault/status");
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.operation_id).toBe("vault.status.read");
    expect(body.data.value_policy).toBe("metadata_only_no_secret_material");
    expect(body.redactions).toContain("vault_passphrases");
  });
});
