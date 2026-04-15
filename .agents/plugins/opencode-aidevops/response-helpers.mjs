/**
 * Response construction helpers for cross-realm safety.
 *
 * OpenCode's Bun plugin loader may rebind the `Response` constructor to a
 * realm-local `_Response` class that Bun.serve rejects with "Expected a
 * Response object, but received '_Response'".
 *
 * `Response.json()` (Fetch API static method, Bun ≥1.0) constructs the
 * response through Bun's native internal path, bypassing the mismatch.
 * Falls back to `new Response()` for runtimes without `Response.json()`.
 */

/**
 * Create a JSON HTTP response.
 * @param {any} data - The data to serialize as JSON
 * @param {object} init - Response init options (status, headers, etc.)
 * @returns {Response}
 */
export function jsonResponse(data, init = {}) {
  if (typeof Response.json === "function") {
    return Response.json(data, init);
  }
  return new Response(JSON.stringify(data), {
    ...init,
    headers: { "Content-Type": "application/json", ...init.headers },
  });
}

/**
 * Create a plain-text HTTP response.
 * @param {string} body - The response body
 * @param {object} init - Response init options (status, headers, etc.)
 * @returns {Response}
 */
export function textResponse(body, init = {}) {
  return new Response(body, init);
}
