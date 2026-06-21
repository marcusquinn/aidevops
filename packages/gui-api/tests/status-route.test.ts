import { describe, expect, test } from "bun:test";
import { app } from "../src/app";

describe("status API route", () => {
  test("GET /api/status returns the shared response envelope", async () => {
    const response = await app.request("/api/status");
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.ok).toBe(true);
    expect(body.operation_id).toBe("setup.status.read");
    expect(body.redactions).toContain("secret_values");
  });

  test("unknown routes fail closed", async () => {
    const response = await app.request("/api/unknown");
    const body = await response.json();

    expect(response.status).toBe(404);
    expect(body.errors).toContain("unknown_route");
  });
});
