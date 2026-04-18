// ---------------------------------------------------------------------------
// OTEL span enrichment (t2177)
//
// opencode v1.4.7+ wraps every tool execution in an OTel span and threads
// the AsyncLocalStorage context manager so nested code (our plugin hooks
// included) observes the active span via @opentelemetry/api's `trace.getActiveSpan()`.
//
// This module offers a dynamic, fail-soft path to enrich that span with
// aidevops-specific attributes (intent, task_id, session_origin, runtime)
// WITHOUT adding @opentelemetry/api as a hard dependency. If the module
// is unavailable (older opencode, missing install, OTEL disabled), all
// calls become no-ops.
//
// Attribute naming follows the domain-first convention used by opencode's
// own span attributes (session.id, message.id) — our namespace is
// `aidevops.*` to avoid collision with standard OTel conventions.
//
// @module otel-enrichment
// ---------------------------------------------------------------------------

/**
 * Cached tracer API handle. `undefined` until first load attempt;
 * `null` when the load failed (becomes permanent no-op).
 * @type {{ getActiveSpan: () => any } | null | undefined}
 */
let _traceApi;

/**
 * One-shot dynamic import of `@opentelemetry/api`. Cached on success;
 * cached as `null` on failure so we don't pay the import cost per tool call.
 *
 * @returns {Promise<{ getActiveSpan: () => any } | null>}
 */
async function loadTraceApi() {
  if (_traceApi !== undefined) return _traceApi;
  try {
    const mod = await import("@opentelemetry/api");
    _traceApi = mod.trace || null;
  } catch {
    _traceApi = null;
  }
  return _traceApi;
}

/**
 * Filter out undefined/null/empty-string values so we don't leak
 * empty keys through to the trace sink.
 *
 * @param {Record<string, any>} attrs
 * @returns {Record<string, string | number | boolean>}
 */
function cleanAttributes(attrs) {
  const cleaned = {};
  for (const [k, v] of Object.entries(attrs)) {
    if (v !== undefined && v !== null && v !== "") cleaned[k] = v;
  }
  return cleaned;
}

/**
 * Enrich the currently-active OTEL span with aidevops attributes.
 *
 * Safe to call from every tool hook — when OTEL is not active, the span
 * lookup returns undefined and this is a no-op. Exceptions from the OTEL
 * SDK are swallowed so the enrichment never affects the host tool's
 * success/failure.
 *
 * @param {Record<string, string | number | boolean>} attrs
 * @returns {Promise<boolean>} true when an attribute was applied
 */
export async function enrichActiveSpan(attrs) {
  try {
    if (!attrs || typeof attrs !== "object") return false;
    const api = await loadTraceApi();
    const span = api?.getActiveSpan?.();
    if (!span || typeof span.setAttributes !== "function") return false;
    const cleaned = cleanAttributes(attrs);
    if (Object.keys(cleaned).length === 0) return false;
    span.setAttributes(cleaned);
    return true;
  } catch {
    return false;
  }
}

/**
 * Best-effort synchronous status check.
 *
 * Returns true when `@opentelemetry/api` was loaded AND an active span
 * is visible from the current async context. Callers may use this to
 * skip building large attribute payloads when OTEL is disabled, though
 * `enrichActiveSpan` itself is already cheap when there is no span.
 *
 * @returns {boolean}
 */
export function otelEnabled() {
  if (_traceApi === null) return false;
  if (!_traceApi) return false;
  try {
    return !!_traceApi.getActiveSpan?.();
  } catch {
    return false;
  }
}

/**
 * Detect the current aidevops task ID from the environment.
 *
 * Resolution order:
 *   1. AIDEVOPS_TASK_ID env var (set by full-loop-helper when dispatched)
 *   2. Worktree branch name parsed from cwd — patterns:
 *        feature/t1234-...   → t1234
 *        feature/gh-19634-...→ GH#19634
 *      Otherwise returns empty string.
 *
 * @param {string} [cwd] - Process working directory (default: process.cwd())
 * @returns {string} Task ID like "t1234" or "GH#19634", or "" when unknown
 */
export function detectTaskId(cwd) {
  const envId = process.env.AIDEVOPS_TASK_ID;
  if (envId && /^(t\d+|GH#\d+)$/.test(envId)) return envId;

  const dir = cwd || process.cwd();
  // Worktree naming: ~/Git/<repo>.<type>-<name> or ~/Git/<repo>-<type>-<name>
  // Branch pattern: <type>/t1234-desc or <type>/gh-19634-desc
  const tMatch = dir.match(/\/[a-z]+[-/]t(\d+)(?:-|$|\/)/i);
  if (tMatch) return `t${tMatch[1]}`;
  const ghMatch = dir.match(/\/[a-z]+[-/]gh-(\d+)(?:-|$|\/)/i);
  if (ghMatch) return `GH#${ghMatch[1]}`;
  return "";
}

/**
 * Env vars that, when any is non-empty, indicate a headless worker
 * session. Mirrors the convention used by the pre-edit check.
 */
const HEADLESS_ENV_VARS = [
  "FULL_LOOP_HEADLESS",
  "AIDEVOPS_HEADLESS",
  "OPENCODE_HEADLESS",
  "CLAUDE_HEADLESS",
  "GITHUB_ACTIONS",
];

/**
 * Detect whether the current session is running headless (worker) or
 * interactive.
 *
 * @returns {"worker" | "interactive"}
 */
export function detectSessionOrigin() {
  const headless = HEADLESS_ENV_VARS.some((v) => process.env[v]);
  return headless ? "worker" : "interactive";
}
