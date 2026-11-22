// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createHash } from "node:crypto";

// GH#36698: process-scoped record of definite model-entitlement rejections,
// keyed by `provider/model` plus an opaque auth signature. A re-login or token
// change produces a new signature, so the old record no longer applies at once;
// otherwise the model is tried again after the TTL (a restored subscription
// becomes routable with no config change). Interactive re-probes cost one
// rejected request that same-tier failover absorbs, so this stays shorter than
// the headless 1h model backoff.
const DEFAULT_TTL_MS = 15 * 60 * 1000;
const MAX_RECORDS = 256;
const unavailable = new Map();

/**
 * Derive an opaque signature from an OpenAI OAuth access token. The token is
 * the single source both the request path and routing can read identically;
 * the ChatGPT account ID derives from it, so it adds no identity. Missing
 * credentials yield "", which never records or matches.
 */
export function openAIAuthSignature(access) {
  const token = String(access || "").replace(/^Bearer\s+/i, "").trim();
  return token ? createHash("sha256").update(`openai\n${token}`).digest("hex") : "";
}

/** Derive the auth signature for the credentials used by a request. */
export function authSignatureFromHeaders(headers) {
  const authorization = headers instanceof Headers
    ? headers.get("authorization")
    : headers?.authorization || headers?.Authorization;
  return openAIAuthSignature(authorization);
}

/** Remember a model rejection for one credential signature until its TTL expires. */
export function markModelUnavailable(model, authSignature, { ttlMs = DEFAULT_TTL_MS, now = Date.now() } = {}) {
  const candidate = String(model || "");
  const signature = String(authSignature || "");
  if (!candidate || !signature) return false;
  const key = `${candidate}\0${signature}`;
  unavailable.delete(key);
  unavailable.set(key, now + Math.max(0, Number(ttlMs) || DEFAULT_TTL_MS));
  while (unavailable.size > MAX_RECORDS) unavailable.delete(unavailable.keys().next().value);
  return true;
}

/** Check whether a model is unavailable for exactly this credential signature. */
export function isModelUnavailable(model, authSignature = "", now = Date.now()) {
  const candidate = String(model || "");
  const signature = String(authSignature || "");
  if (!candidate || !signature) return false;
  const key = `${candidate}\0${signature}`;
  const expiresAt = unavailable.get(key);
  if (!expiresAt) return false;
  if (expiresAt <= now) {
    unavailable.delete(key);
    return false;
  }
  return true;
}

/** Remove one model and credential pair from the unavailability store. */
export function clearModelUnavailable(model, authSignature = "") {
  const candidate = String(model || "");
  const signature = String(authSignature || "");
  return unavailable.delete(`${candidate}\0${signature}`);
}
