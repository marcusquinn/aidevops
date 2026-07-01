/**
 * OpenAI OAuth refresh recovery.
 *
 * OpenCode refreshes built-in OpenAI OAuth credentials via auth.openai.com
 * before its model request reaches api.openai.com/v1/*. A 401/403 there would
 * otherwise surface as `Token refresh failed: 401` and stop the session before
 * the normal OpenAI API fetch rotation path can run.
 */

import { getAccounts, markAuthRefreshFailure, rotateOpenAIPoolToken } from "./oauth-pool.mjs";
import { OPENAI_TOKEN_ENDPOINT } from "./oauth-pool-constants.mjs";

const TOKEN_REFRESH_FAILURE_STATUSES = new Set([401, 403]);

function requestUrl(input) {
  if (typeof input === "string") return input;
  if (input instanceof URL) return input.toString();
  return input?.url || "";
}

export function isOpenAITokenRefreshRequest(input) {
  try {
    const url = new URL(requestUrl(input));
    const endpoint = new URL(OPENAI_TOKEN_ENDPOINT);
    return url.origin === endpoint.origin && url.pathname === endpoint.pathname;
  } catch { return false; }
}

export async function readOpenAITokenRefreshBody(input, init) {
  let bodyText = "";
  try {
    if (typeof init?.body === "string") bodyText = init.body;
    else if (init?.body instanceof URLSearchParams) bodyText = init.body.toString();
    else if (typeof Request !== "undefined" && input instanceof Request) bodyText = await input.clone().text();
  } catch {
    // Best-effort: request body may be a non-cloneable stream.
  }
  return bodyText;
}

function extractOpenAIRefreshToken(bodyText) {
  let refreshToken = "";
  try {
    const params = new URLSearchParams(bodyText);
    if (params.get("grant_type") === "refresh_token") refreshToken = params.get("refresh_token") || "";
  } catch { /* malformed form body: no matching pool account */ }
  return refreshToken;
}

function resolveOpenAIRefreshAccount(bodyText) {
  const refreshToken = extractOpenAIRefreshToken(bodyText);
  return getAccounts("openai").find((account) => account.refresh === refreshToken) || null;
}

function buildOpenAITokenRefreshResponse(account) {
  const expiresAt = Number(account.expires) || Date.now() + 3600_000;
  const expiresIn = Math.max(1, Math.floor((expiresAt - Date.now()) / 1000));
  return new Response(JSON.stringify({
    access_token: account.access,
    refresh_token: account.refresh,
    expires_in: expiresIn,
    token_type: "Bearer",
  }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

export async function handleOpenAITokenRefreshFailure(ctx) {
  const { client, response, bodyText } = ctx;
  if (!TOKEN_REFRESH_FAILURE_STATUSES.has(response.status)) return response;
  const current = resolveOpenAIRefreshAccount(bodyText);
  const currentEmail = current?.email || "unknown";
  if (current) markAuthRefreshFailure("openai", current);
  console.error(`[aidevops] OpenAI provider: token refresh failed (${response.status}) for ${currentEmail} — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  return rotated?.access ? buildOpenAITokenRefreshResponse(rotated) : response;
}
