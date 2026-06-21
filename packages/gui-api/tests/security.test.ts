import { describe, expect, test } from "bun:test";
import { BANNED_ROUTE_PATTERNS, containsSecretSentinel } from "../../gui-shared/src";
import { app } from "../src/app";

describe("API trust boundary", () => {
  test("banned arbitrary command routes reject POST requests", async () => {
    for (const route of BANNED_ROUTE_PATTERNS) {
      const response = await app.request(route, { method: "POST", body: "ignored" });
      expect(response.status).toBe(405);
    }
  });

  test("status route does not serialize secret sentinels", async () => {
    const response = await app.request("/api/status");
    const body = await response.json();

    expect(containsSecretSentinel(body)).toBe(false);
  });

  test("file explorer rejects path traversal outside allowlisted roots", async () => {
    const response = await app.request("/api/files/agents?path=../../.ssh");
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.errors).toContain("path_outside_root");
    expect(containsSecretSentinel(body)).toBe(false);
  });
});
