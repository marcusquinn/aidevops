import { describe, expect, test } from "bun:test";
import { app } from "../src/app";

describe("GUI API smoke", () => {
  test("read-only local API app boots and handles status", async () => {
    const response = await app.request("/api/status");
    expect(response.status).toBe(200);
  });
});
