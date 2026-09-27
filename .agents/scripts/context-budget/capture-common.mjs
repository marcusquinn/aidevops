// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Shared request-body capture for context-budget-helper.sh probes. It is inert
// unless the helper sets AIDEVOPS_CONTEXT_BUDGET_OUT to an absolute directory,
// saves provider request bodies only (never headers), and self-disables after a
// capture count or deadline. It must never throw into the request path.
import { mkdirSync, writeFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";

const INSTALLED = Symbol.for("aidevops.context-budget.capture.v1");
const PROVIDER_REQUEST = /\/v1\/messages(?:\?|$)|\/responses(?:\?|$)|\/chat\/completions(?:\?|$)/;
const DEFAULT_MAX_CAPTURES = 4;
const DEFAULT_DEADLINE_MS = 300_000;

/** Resolve capture settings from the helper-provided environment, or null when inactive. */
export function captureSettings(env = process.env) {
  const outDir = env.AIDEVOPS_CONTEXT_BUDGET_OUT ?? "";
  if (!outDir || !isAbsolute(outDir)) return null;
  const tag = /^[a-z0-9-]{1,40}$/.test(env.AIDEVOPS_CONTEXT_BUDGET_TAG ?? "")
    ? env.AIDEVOPS_CONTEXT_BUDGET_TAG
    : "capture";
  const max = Number.parseInt(env.AIDEVOPS_CONTEXT_BUDGET_MAX ?? "", 10);
  return {
    outDir,
    tag,
    maxCaptures: Number.isInteger(max) && max > 0 && max <= 20 ? max : DEFAULT_MAX_CAPTURES,
    deadline: Date.now() + DEFAULT_DEADLINE_MS,
  };
}

/** True for provider inference endpoints whose bodies carry the prompt context. */
export function isProviderRequest(url) {
  return PROVIDER_REQUEST.test(String(url ?? ""));
}

/** Create a writer that stores up to maxCaptures bodies as <tag>-<pid>-<n>.json (0600). */
export function createCaptureWriter(settings) {
  let count = 0;
  mkdirSync(settings.outDir, { recursive: true, mode: 0o700 });
  return {
    get active() {
      return count < settings.maxCaptures && Date.now() < settings.deadline;
    },
    write(body) {
      if (!body || count >= settings.maxCaptures || Date.now() >= settings.deadline) return;
      count += 1;
      writeFileSync(join(settings.outDir, `${settings.tag}-${process.pid}-${count}.json`), body, { mode: 0o600 });
    },
  };
}

async function requestBodyText(input, init) {
  if (typeof init?.body === "string") return init.body;
  if (init?.body instanceof Uint8Array) return new TextDecoder().decode(init.body);
  if (typeof Request !== "undefined" && input instanceof Request) return input.clone().text();
  return null;
}

function requestUrl(input) {
  if (typeof input === "string") return input;
  if (input instanceof URL) return input.href;
  return input?.url ?? String(input);
}

/** Wrap globalThis.fetch once per process; restores the original once capture ends. */
export function installFetchCapture(settings = captureSettings()) {
  if (!settings || globalThis[INSTALLED]) return false;
  globalThis[INSTALLED] = true;
  const writer = createCaptureWriter(settings);
  const original = globalThis.fetch;
  globalThis.fetch = async function contextBudgetFetch(input, init) {
    try {
      if (writer.active && isProviderRequest(requestUrl(input))) writer.write(await requestBodyText(input, init));
    } catch {
      // Diagnostic only: never affect the provider request.
    }
    if (!writer.active) globalThis.fetch = original;
    return original.call(this, input, init);
  };
  return true;
}
