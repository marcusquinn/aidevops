// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

const DEFAULT_TTL_MS = 15 * 60 * 1000;
const unavailable = new Map();
const activeAuthSignatures = new Map();

function hash(value) {
  let result = 2166136261;
  for (const char of String(value || "")) {
    result ^= char.codePointAt(0);
    result = Math.imul(result, 16777619);
  }
  return (result >>> 0).toString(16);
}

function providerOf(model) {
  const value = String(model || "");
  const separator = value.indexOf("/");
  return separator > 0 ? value.slice(0, separator) : "";
}

export function authSignatureFromHeaders(headers) {
  const value = headers instanceof Headers
    ? `${headers.get("authorization") || ""}\n${headers.get("chatgpt-account-id") || ""}`
    : `${headers?.authorization || headers?.Authorization || ""}\n${headers?.["chatgpt-account-id"] || ""}`;
  return hash(value);
}

export function markModelUnavailable(model, authSignature, { ttlMs = DEFAULT_TTL_MS, now = Date.now() } = {}) {
  const candidate = String(model || "");
  const signature = String(authSignature || "");
  if (!candidate || !signature) return false;
  const provider = providerOf(candidate);
  if (provider) activeAuthSignatures.set(provider, signature);
  unavailable.set(`${candidate}\0${signature}`, now + Math.max(0, Number(ttlMs) || DEFAULT_TTL_MS));
  return true;
}

export function isModelUnavailable(model, authSignature = "", now = Date.now()) {
  const candidate = String(model || "");
  const signature = String(authSignature || "") || activeAuthSignatures.get(providerOf(candidate)) || "";
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

export function clearModelUnavailable(model, authSignature = "") {
  const candidate = String(model || "");
  const signature = String(authSignature || "") || activeAuthSignatures.get(providerOf(candidate)) || "";
  return unavailable.delete(`${candidate}\0${signature}`);
}
