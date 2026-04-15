// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// aidevops opencode plugin — shared HTTP response helpers

/**
 * Cross-realm-safe HTTP response construction for plugin-hosted Bun.serve
 * endpoints.
 *
 * ## Background
 *
 * When OpenCode's Bun plugin loader imports a plugin module, the `Response`
 * class identity visible inside the plugin can diverge from the one Bun's
 * native `Bun.serve` dispatcher uses as its type guard. Returning the wrong
 * identity from a fetch handler produces:
 *
 *   "Expected a Response object, but received '_Response'"
 *
 * and the request dies with journal spam from the OpenCode service.
 *
 * Reported in PR #19174 (superdav42). The empirical fix is to construct JSON
 * responses via `Response.json()` — a Fetch API static method that Bun
 * implements natively and that returns an instance blessed by Bun's internal
 * path, bypassing the constructor mismatch.
 *
 * For streaming and plain-text responses, `new Response(...)` has not been
 * observed to fail in practice (the known-bad pattern is specifically
 * `new Response(JSON.stringify(x), {headers: {"Content-Type": "application/json"}})`
 * in the fork-loader realm). The `textResponse` helper is kept as a
 * consistency alias so all response construction in the plugin flows through
 * a single audited call site — if we ever see the same `_Response` error on a
 * streaming path, we can add the same workaround in one place.
 *
 * ## Why a shared module
 *
 * The plugin has at least five files that host `Bun.serve` endpoints or
 * return `Response` objects from fetch handlers:
 *
 *   - claude-proxy.mjs
 *   - google-proxy.mjs
 *   - cursor/proxy.js
 *   - cursor/proxy-stream.js
 *   - provider-auth-request.mjs
 *
 * Duplicating the helpers in each file is a maintenance trap — if Bun changes
 * the fix, we'd have to update it five times. This module is the single
 * source of truth.
 */

/**
 * Construct a JSON HTTP response using the cross-realm-safe path.
 *
 * Uses `Response.json()` when available (Bun ≥1.0, Node ≥18.0), which
 * invokes Bun's native Fetch API implementation and sidesteps the
 * `_Response` constructor mismatch. Falls back to `new Response(JSON.stringify(...))`
 * for older runtimes where the Response constructor is the only option;
 * the fallback preserves API parity and may itself trip the mismatch on
 * buggy hosts, but no such host is known at time of writing.
 *
 * @param {unknown} data - Any JSON-serialisable value.
 * @param {ResponseInit} [init] - Standard Response init (status, headers, statusText).
 * @returns {Response}
 */
export function jsonResponse(data, init = {}) {
  if (typeof Response.json === "function") {
    return Response.json(data, init);
  }
  return new Response(JSON.stringify(data), {
    ...init,
    headers: { "Content-Type": "application/json", ...(init.headers || {}) },
  });
}

/**
 * Construct a plain-text or stream HTTP response.
 *
 * This is currently a thin alias over `new Response(...)` — streaming paths
 * and short text bodies have not been observed to trip the `_Response`
 * mismatch in practice. The alias exists so that if a workaround is ever
 * needed, it can be added in one place instead of hunted through every
 * `Bun.serve` callsite in the plugin. Prefer this helper over direct
 * `new Response(...)` for new code.
 *
 * @param {BodyInit | null | undefined} body
 * @param {ResponseInit} [init]
 * @returns {Response}
 */
export function textResponse(body, init = {}) {
  return new Response(body, init);
}
