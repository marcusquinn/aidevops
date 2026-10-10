// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import test from "node:test";

import {
  createProviderErrorHandler,
  normalizeProviderError,
  localFailureCheck,
} from "../provider-error-diagnostics.mjs";

function apiError(overrides = {}) {
  return {
    name: "APIError",
    data: {
      message: "Forbidden",
      statusCode: 403,
      isRetryable: false,
      responseBody: "<!doctype html><title>Forbidden</title>",
      responseHeaders: {
        authorization: "Bearer secret-value",
        cookie: "private-cookie",
        "x-request-id": "req-safe-123",
      },
      metadata: { url: "https://api.example.test/v1/responses?secret=value" },
      ...overrides,
    },
  };
}

test("normalizes HTML 403 without retaining raw response data", () => {
  const diagnostic = normalizeProviderError(apiError());
  assert.deepEqual(diagnostic, {
    classification: "gateway_denied",
    status_code: 403,
    response_body_kind: "html",
    is_retryable: false,
    endpoint_origin: "https://api.example.test",
    request_id: "req-safe-123",
    request_id_source: "x-request-id",
  });
  assert.doesNotMatch(JSON.stringify(diagnostic), /secret-value|private-cookie|doctype/);
});

test("keeps JSON, text, and empty 403 responses distinguishable", () => {
  assert.equal(normalizeProviderError(apiError({ responseBody: '{"error":"denied"}' })).response_body_kind, "json");
  assert.equal(normalizeProviderError(apiError({ responseBody: "denied" })).response_body_kind, "text");
  assert.equal(normalizeProviderError(apiError({ responseBody: "  " })).response_body_kind, "empty");
  assert.equal(normalizeProviderError(apiError({ responseBody: undefined })).response_body_kind, "unavailable");
  assert.equal(normalizeProviderError(apiError({ responseBody: "denied" })).classification, "access_denied");
});

test("ignores non-API SDK errors", () => {
  for (const name of ["ProviderAuthError", "UnknownError", "MessageAbortedError"]) {
    assert.equal(normalizeProviderError({ name, data: { message: "Aborted" } }), null);
  }
});

test("explains gateway denial once per session without claiming lost permission", async () => {
  const toasts = [];
  let timestamp = 100000;
  const handler = createProviderErrorHandler({
    client: { tui: { showToast: async (toast) => toasts.push(toast) } },
    isHeadless: () => false,
    resolveSessionModel: () => "openai/gpt-test",
    now: () => timestamp,
  });
  const event = { event: { type: "session.error", properties: { sessionID: "session-1", error: apiError() } } };
  await handler(event);
  await handler(event);
  timestamp += 30001;
  await handler(event);
  assert.equal(toasts.length, 2);
  assert.match(toasts[0].body.message, /edge\/proxy denial, not proof/);
  assert.doesNotMatch(toasts[0].body.message, /secret-value|private-cookie/);
});

test("does not emit interactive diagnostics in headless mode", async () => {
  const toasts = [];
  const handler = createProviderErrorHandler({
    client: { tui: { showToast: async (toast) => toasts.push(toast) } },
    isHeadless: () => true,
    resolveSessionModel: () => "openai/gpt-test",
  });
  await handler({ event: { type: "session.error", properties: { sessionID: "session-1", error: apiError() } } });
  assert.equal(toasts.length, 0);
});

test("clears deduplication for SDK-shaped deletion events", async () => {
  const toasts = [];
  let timestamp = 100000;
  const handler = createProviderErrorHandler({
    client: { tui: { showToast: async (toast) => toasts.push(toast) } },
    isHeadless: () => false,
    resolveSessionModel: () => "openai/gpt-test",
    now: () => timestamp,
  });
  const denied = { event: { type: "session.error", properties: { sessionID: "session-1", error: apiError() } } };
  await handler(denied);
  await handler({ event: { type: "session.deleted", properties: { info: { id: "session-1" } } } });
  timestamp += 1;
  await handler(denied);
  assert.equal(toasts.length, 2);
});

test("reserves concurrent delivery and retries after a failed toast", async () => {
  const toasts = [];
  let fail = false;
  const handler = createProviderErrorHandler({
    client: { tui: { showToast: async (toast) => {
      if (fail) throw new Error("toast unavailable");
      toasts.push(toast);
    } } },
    isHeadless: () => false,
    resolveSessionModel: () => "openai/gpt-test",
    now: () => 100000,
  });
  const denied = { event: { type: "session.error", properties: { sessionID: "session-1", error: apiError() } } };
  await Promise.all([handler(denied), handler(denied)]);
  assert.equal(toasts.length, 1);

  const retryHandler = createProviderErrorHandler({
    client: { tui: { showToast: async (toast) => {
      if (fail) throw new Error("toast unavailable");
      toasts.push(toast);
    } } },
    isHeadless: () => false,
    resolveSessionModel: () => "openai/gpt-test",
    now: () => 200000,
  });
  fail = true;
  await assert.rejects(retryHandler(denied), /toast unavailable/);
  fail = false;
  await retryHandler(denied);
  assert.equal(toasts.length, 2);
});

test("bound failures emit one content-free toast and receipt per window for V1 and V2", async () => {
  for (const error of [apiError({ statusCode: 404, message: "sentinel-private-body" }),
    { name: "UnknownError", data: { message: "ECONNREFUSED sentinel-private-body" } },
    { code: "VAULT_POLICY_DENIED" }, { message: "model identity mismatch" }, { code: "ETIMEDOUT" }]) {
    const toasts = [];
    const receipts = [];
    let time = 0;
    const handler = createProviderErrorHandler({ policy: { bound: true }, now: () => time,
      isHeadless: () => false, client: { tui: { showToast: async (toast) => toasts.push(toast) } },
      append: (event) => { receipts.push(event); return true; } });
    const event = { event: { type: "session.error", data: { sessionID: "ses_test", error } } };
    await Promise.all([handler(event), handler(event)]);
    assert.equal(toasts.length, 1);
    assert.equal(receipts.length, 1);
    assert.equal(receipts[0].reason, localFailureCheck(error));
    assert.doesNotMatch(JSON.stringify({ toasts, receipts }), /sentinel-private-body/);
    time += 30001;
    await handler(event);
    assert.equal(receipts.length, 2);
  }
});

test("headless and unavailable TUI retain receipt; receipt failures remain content-free", async () => {
  for (const headless of [true, false]) {
    let receipts = 0;
    const handler = createProviderErrorHandler({ policy: { bound: true },
      isHeadless: () => headless, client: { tui: { showToast: async () => { throw new Error("no TUI"); } } },
      append: () => { receipts++; return true; } });
    const event = { type: "session.error", properties: { sessionID: "ses_test", error: apiError({ statusCode: 404 }) } };
    await handler(event);
    await handler(event);
    assert.equal(receipts, 1);
  }
});
