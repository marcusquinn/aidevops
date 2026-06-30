import { describe, expect, test } from "bun:test";
import { BANNED_ROUTE_PATTERNS, containsSecretSentinel } from "../../gui-shared/src";
import { app, createOutputLineRedactor } from "../src/app";

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
  }, 10_000);

  test("vault status route does not serialize secret sentinels", async () => {
    const response = await app.request("/api/vault/status");
    const body = await response.json();

    expect(containsSecretSentinel(body)).toBe(false);
  });

  test("Tambo provider route exposes metadata without browser secrets", async () => {
    const response = await app.request("/api/tambo/session?tenant_ref=local&workspace_ref=aidevops&session_ref=channel-general");
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.data.secret_policy).toBe("server_only_no_browser_tokens");
    expect(body.data).not.toHaveProperty("api_key");
    expect(body.data).not.toHaveProperty("authorization");
    expect(containsSecretSentinel(body)).toBe(false);
  });

  test("Tambo provider route strips scope delimiters from thread key scope refs", async () => {
    const response = await app.request("/api/tambo/session?tenant_ref=team:alpha&workspace_ref=ops:prod&session_ref=conversation:local");
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.data.thread_key_ref).toBe("teamalpha:opsprod:conversation:local");
  });

  test("file explorer rejects path traversal outside allowlisted roots", async () => {
    const response = await app.request("/api/files/agents?path=../../.ssh");
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.errors).toContain("path_outside_root");
    expect(containsSecretSentinel(body)).toBe(false);
  });

  test("pulse worker action route rejects inherited object property names", async () => {
    const response = await app.request("/api/pulse-workers/actions/toString", { method: "POST" });
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.errors).toContain("action_not_allowlisted");
  });

  test("background output redactor redacts multiline private key blocks", () => {
    const redactLine = createOutputLineRedactor();
    const privateKeyBegin = "-----BEGIN OPENSSH " + "PRIVATE KEY-----";
    const privateKeyEnd = "-----END OPENSSH " + "PRIVATE KEY-----";
    const output = [
      "before",
      privateKeyBegin,
      "synthetic-private-key-fixture-body",
      privateKeyEnd,
      "after token=secret-value",
    ].map((line) => redactLine(line));

    expect(output).toEqual([
      "before",
      "[redacted private key]",
      "[redacted private key]",
      "[redacted private key]",
      "after token=[redacted]",
    ]);
  });
});
