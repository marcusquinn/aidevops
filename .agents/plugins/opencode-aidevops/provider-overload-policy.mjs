// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// t19362 / GH#40283: pure policy for provider-overload-retry.mjs: settings,
// error classification, continuation text and content-free identifiers.

import { createHash } from "node:crypto";

const DEFAULT_DELAY_SECONDS = 60;
const DEFAULT_MAX_ATTEMPTS = 5;
const MAX_DELAY_SECONDS = 3600;
const MAX_ATTEMPTS_LIMIT = 50;
const OVERLOAD_STATUS = 529;
const RATE_LIMIT_STATUS = 429;
const OVERLOAD_TEXT = /overloaded/i;
const OVERLOAD_ERROR_NAMES = new Set(["APIError", "UnknownError"]);
const DISABLED_VALUES = new Set(["0", "false", "off", "no"]);

function boundedInt(value, fallback, max) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isSafeInteger(parsed) || parsed < 1) return fallback;
  return Math.min(parsed, max);
}

/** Resolve the retry settings from the environment on every use. */
export function overloadRetrySettings(env = process.env) {
  const flag = String(env?.AIDEVOPS_OVERLOAD_RETRY ?? "").trim().toLowerCase();
  return {
    enabled: !DISABLED_VALUES.has(flag),
    delayMs: boundedInt(env?.AIDEVOPS_OVERLOAD_RETRY_DELAY_SECONDS, DEFAULT_DELAY_SECONDS, MAX_DELAY_SECONDS) * 1000,
    maxAttempts: boundedInt(env?.AIDEVOPS_OVERLOAD_RETRY_MAX_ATTEMPTS, DEFAULT_MAX_ATTEMPTS, MAX_ATTEMPTS_LIMIT),
  };
}

/** True when this runtime will retry a terminal overload error itself. */
export function overloadRetryEnabled(env = process.env) {
  return overloadRetrySettings(env).enabled;
}

// A 4xx other than 429 is a request problem; its body may echo request text.
function overloadStatusAllowed(status) {
  return !Number.isInteger(status) || status === RATE_LIMIT_STATUS || status >= 500;
}

/**
 * Classify a terminal OpenCode session error as a transient provider
 * overload: HTTP 529, or "overloaded" in the text of a 5xx, 429 or
 * status-less stream error.
 */
export function isProviderOverloadError(error) {
  if (!OVERLOAD_ERROR_NAMES.has(String(error?.name || ""))) return false;
  const data = error.data && typeof error.data === "object" ? error.data : {};
  const status = data.statusCode === undefined ? null : Number(data.statusCode);
  if (status === OVERLOAD_STATUS) return true;
  return overloadStatusAllowed(status)
    && [data.message, data.responseBody].some((text) => typeof text === "string" && OVERLOAD_TEXT.test(text));
}

export function continuationText(attempt, maxAttempts) {
  return [
    `AIDEVOPS PROVIDER OVERLOAD RETRY (${attempt}/${maxAttempts}).`,
    "The previous assistant turn stopped because the model provider returned an overloaded error after its built-in retries.",
    "Continue the task from where it stopped.",
    "Do not repeat side effects that already completed, such as writes, commits, pushes, deployments or external requests; check current state first if unsure.",
  ].join("\n");
}

/** Content-free session identifier for logs. */
export function sessionHash(sessionID) {
  return `sha256:${createHash("sha256").update(String(sessionID)).digest("hex").slice(0, 12)}`;
}

function optionalString(value) {
  return typeof value === "string" && value ? value : undefined;
}

/** Agent, model and variant of a user message, or null without a model. */
export function requestIdentity(info) {
  const model = info?.model || {};
  if (!model.providerID || !model.modelID) return null;
  return {
    agent: optionalString(info.agent),
    providerID: String(model.providerID),
    modelID: String(model.modelID),
    // OpenCode 1 user messages carry `variant`; some builds nest it in `model`.
    variant: optionalString(info.variant ?? model.variant),
  };
}
