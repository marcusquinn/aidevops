// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createHash } from "node:crypto";

const DEFAULT_TTL_MS = 15 * 60 * 1000;
const unavailable = new Map();

function hash(value) {
  return createHash("sha256").update(String(value || "")).digest("hex");
}

/** Derive an opaque signature for the credentials used by a request. */
export function authSignatureFromHeaders(headers) {
  const value = headers instanceof Headers
    ? `${headers.get("authorization") || ""}\n${headers.get("chatgpt-account-id") || ""}`
    : `${headers?.authorization || headers?.Authorization || ""}\n${headers?.["chatgpt-account-id"] || ""}`;
  return hash(value);
}

/** Remember a model rejection for one credential signature until its TTL expires. */
export function markModelUnavailable(model, authSignature, { ttlMs = DEFAULT_TTL_MS, now = Date.now() } = {}) {
  const candidate = String(model || "");
  const signature = String(authSignature || "");
  if (!candidate || !signature) return false;
  unavailable.set(`${candidate}\0${signature}`, now + Math.max(0, Number(ttlMs) || DEFAULT_TTL_MS));
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
