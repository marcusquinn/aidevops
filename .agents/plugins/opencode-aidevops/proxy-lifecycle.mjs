// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Shared proxy lifecycle: probe-existing + EADDRINUSE-adopt + bounded retry.
 *
 * Every aidevops local proxy (Claude CLI, Cursor gRPC, Google auth-translating)
 * binds a deterministic loopback port via `Bun.serve` and needs the same
 * three race-resilience behaviours when N OpenCode sessions start at once:
 *
 *   1. Probe before bind — if a sibling instance already owns the port,
 *      adopt the URL instead of double-binding.
 *   2. EADDRINUSE adoption — if our `Bun.serve` raises EADDRINUSE because
 *      a sibling won the bind race during the gap between probe and bind,
 *      retry the probe (the sibling's fetch listener may not be up yet).
 *   3. Idempotent re-entry — repeat calls during a single startup are
 *      cheap (gated by an in-flight flag) and once started, return the
 *      cached port without re-binding.
 *
 * This module factors that pattern out of `claude-proxy.mjs` (where it
 * landed in PR #21951 / GH#21944) so `cursor-proxy.mjs` and
 * `google-proxy.mjs` can share it instead of growing copies that drift.
 *
 * Each proxy file calls `createProxyLifecycle({ … })` once at module scope
 * and owns the resulting `{ ensureStarted, getPort, providerID }` object.
 * `ensureStarted({ credentialsAvailable, launch })` is the single entry
 * point — caller supplies the credential check and the bind action; this
 * helper supplies the race-resilience.
 *
 * See GH#21944 (lazy-start + EADDRINUSE adopt for claude-proxy) and
 * GH#21948 (this consolidation).
 */

// ---------------------------------------------------------------------------
// Headless detection (shared)
// ---------------------------------------------------------------------------

/**
 * Detect headless OpenCode/CI sessions. Headless workers (pulse-spawned,
 * GitHub Actions, full-loop) only ever target anthropic/* via the OAuth
 * pool — they never request claudecli/* / cursor/* / google/*, so starting
 * a local proxy listener for them is pure waste and contributes to
 * multi-instance EADDRINUSE races. Canonical env-var set per AGENTS.md
 * "Main-branch planning exception" rule (t1990). See GH#21944.
 *
 * Used by `index.mjs` to gate the `experimental.chat.system.transform`
 * hook's lazy-start dispatch table — headless workers skip the bind path
 * entirely.
 *
 * @returns {boolean}
 */
export function isHeadless() {
  return Boolean(
    process.env.FULL_LOOP_HEADLESS ||
    process.env.AIDEVOPS_HEADLESS ||
    process.env.OPENCODE_HEADLESS ||
    process.env.GITHUB_ACTIONS,
  );
}

// ---------------------------------------------------------------------------
// EADDRINUSE detection (shared)
// ---------------------------------------------------------------------------

/**
 * Heuristic: is this error a port-already-bound failure rather than a
 * deeper Bun.serve config problem? Bun raises EADDRINUSE; some shims raise
 * `listen EADDRINUSE`. We check both `code` and `message` so we don't miss
 * either form.
 *
 * @param {unknown} err
 * @returns {boolean}
 */
export function isPortInUseError(err) {
  if (!err) return false;
  // err may be any thrown value (Error, string, plain object). Narrow safely.
  const code = /** @type {{code?: string}} */ (err).code;
  if (code === "EADDRINUSE") return true;
  const message = /** @type {{message?: unknown}} */ (err).message;
  const msg = typeof message === "string" ? message : "";
  return /EADDRINUSE|address already in use/i.test(msg);
}

// ---------------------------------------------------------------------------
// Standalone probe helpers (also used by the factory below)
// ---------------------------------------------------------------------------

/**
 * Resolve the port from an env-var override or fall back to the default.
 * Centralised so every proxy uses the same parsing rules (radix 10, no
 * silent NaN). Caller validates the result.
 *
 * @param {string} envVar - Name of the env var to consult
 * @param {number} defaultPort - Numeric default if env var is unset/empty
 * @returns {number}
 */
export function resolveProxyPort(envVar, defaultPort) {
  const raw = process.env[envVar];
  if (!raw) return defaultPort;
  const parsed = parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : defaultPort;
}

/**
 * Probe whether a proxy server is already listening on `port` by
 * fetching `http://127.0.0.1:${port}${path}` with an AbortController-
 * backed timeout.
 *
 * Returns the port on success (so callers can fluently assign it),
 * `null` on any failure (timeout, connection refused, non-2xx).
 *
 * @param {number} port
 * @param {string} path
 * @param {number} timeoutMs
 * @returns {Promise<number|null>}
 */
export async function probeProxy(port, path, timeoutMs) {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    const res = await fetch(`http://127.0.0.1:${port}${path}`, {
      signal: controller.signal,
    });
    clearTimeout(timer);
    if (res.ok) return port;
  } catch {
    // not running, not reachable, or timed out
  }
  return null;
}

/**
 * Probe with bounded retries — used by the EADDRINUSE adoption path.
 *
 * When a sibling plugin is mid-startup, the port may already be `bind()`ed
 * by Bun but the fetch listener not yet reachable, so a single probe
 * returns null even though the owner will be ready in <1s.
 *
 * Retries `attempts` times with `intervalMs` spacing. Returns the port
 * on first success, `null` if every attempt fails (port likely poisoned
 * by an unrelated process — caller should report failure).
 *
 * @param {number} port
 * @param {string} path
 * @param {number} timeoutMs
 * @param {number} attempts
 * @param {number} intervalMs
 * @returns {Promise<number|null>}
 */
export async function probeProxyWithRetry(port, path, timeoutMs, attempts, intervalMs) {
  for (let attempt = 0; attempt < attempts; attempt++) {
    const found = await probeProxy(port, path, timeoutMs);
    if (found) return found;
    if (attempt < attempts - 1) {
      await new Promise((resolve) => setTimeout(resolve, intervalMs));
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Lifecycle factory
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} ProxyLifecycleOptions
 * @property {string} name
 *   Human-readable proxy name for log prefixes (e.g. "Claude", "Cursor",
 *   "Google"). Used as `[aidevops] ${name} proxy: …`.
 * @property {number} defaultPort
 *   Canonical loopback port the proxy binds. Each proxy claims a fixed
 *   port so opencode.json `api: http://127.0.0.1:<port>/v1` survives
 *   restart and multi-instance races converge on adoption.
 * @property {string} envPortVar
 *   Env-var name that overrides `defaultPort` for users who hit a port
 *   collision (e.g. `CLAUDE_PROXY_PORT`, `CURSOR_PROXY_PORT`,
 *   `GOOGLE_PROXY_PORT`).
 * @property {string} providerID
 *   OpenCode provider ID (e.g. `claudecli`, `cursor`, `google`). The
 *   composed `experimental.chat.system.transform` hook in index.mjs
 *   dispatches lazy-start by matching `input.model.providerID` against
 *   this string.
 * @property {string} [probePath]
 *   HTTP GET path that returns 2xx from a healthy proxy (default
 *   `/v1/models`). Google's proxy uses `/health`.
 * @property {number} [probeTimeoutMs]
 *   Per-probe timeout in ms (default 1500). The historical 1s default
 *   was too short when the existing proxy was mid-SSE-stream. See
 *   GH#21944.
 * @property {number} [probeRetryAttempts]
 *   EADDRINUSE-adoption retry count (default 5). If 5 probes fail to
 *   find a server, the port is genuinely poisoned by something else.
 * @property {number} [probeRetryIntervalMs]
 *   Spacing between retry probes in ms (default 1000).
 */

/**
 * @typedef {Object} EnsureStartedOptions
 * @property {() => boolean} credentialsAvailable
 *   Returns true if the proxy can actually serve traffic (e.g. accounts
 *   exist in the OAuth pool, or the upstream CLI is on PATH). Returning
 *   false short-circuits to a clean `null` return without binding.
 * @property {() => Promise<{port: number}>} launch
 *   Performs the actual `Bun.serve` bind and any post-bind side effects
 *   (auth registration, opencode.json persistence, model discovery).
 *   Throws on any bind failure — the lifecycle helper catches and
 *   classifies (EADDRINUSE → adopt-with-retry, else → log + return null).
 *   Must return `{ port }` on success.
 */

/**
 * @typedef {Object} EnsureStartedResult
 * @property {number} port - Final port (either freshly bound or adopted).
 * @property {boolean} adopted - True if we adopted a sibling's listener,
 *   false if we did the bind ourselves. Callers may use this to skip
 *   redundant side effects (e.g. don't re-persist opencode.json — the
 *   sibling already did).
 */

// ---------------------------------------------------------------------------
// Module-level lifecycle helpers
// ---------------------------------------------------------------------------
//
// These are hoisted out of `createProxyLifecycle`'s closure (where they lived
// in the first cut of GH#21948) and take the lifecycle state object as their
// first argument. The motivation is purely a quality-gate concern: when these
// helpers were nested, qlty's `function-complexity` and `return-statements`
// counters rolled their inner returns up into `createProxyLifecycle`'s totals,
// pushing the factory over the threshold (cc=20, returns=14). Hoisting drops
// the factory's effective metrics to ~2/2 without changing observable
// behaviour or the public API. State is still encapsulated — the lifecycle
// object is closed over only by the small accessor lambdas the factory
// returns.

/**
 * @typedef {Object} LifecycleState
 * @property {string} name
 * @property {string} providerID
 * @property {string} probePath
 * @property {number} probeTimeoutMs
 * @property {number} probeRetryAttempts
 * @property {number} probeRetryIntervalMs
 * @property {number} targetPort
 * @property {number | null} port
 * @property {boolean} starting
 */

/**
 * Probe once at the lifecycle's target port and adopt if found.
 *
 * @param {LifecycleState} lifecycle
 * @returns {Promise<EnsureStartedResult | null>}
 */
async function tryAdoptExisting(lifecycle) {
  const existing = await probeProxy(
    lifecycle.targetPort,
    lifecycle.probePath,
    lifecycle.probeTimeoutMs,
  );
  if (!existing) return null;
  lifecycle.port = existing;
  console.error(
    `[aidevops] ${lifecycle.name} proxy: adopted existing server on port ${lifecycle.port}`,
  );
  return { port: lifecycle.port, adopted: true };
}

/**
 * Try to adopt a sibling listener after our own bind raised EADDRINUSE.
 * Splits the post-EADDRINUSE branch out of `tryLaunch` so the main
 * function stays under the framework's function-complexity gate.
 *
 * @param {LifecycleState} lifecycle
 * @returns {Promise<EnsureStartedResult | null>}
 */
async function attemptEaddrinuseAdoption(lifecycle) {
  const adoptedPort = await probeProxyWithRetry(
    lifecycle.targetPort,
    lifecycle.probePath,
    lifecycle.probeTimeoutMs,
    lifecycle.probeRetryAttempts,
    lifecycle.probeRetryIntervalMs,
  );
  if (adoptedPort) {
    lifecycle.port = adoptedPort;
    console.error(
      `[aidevops] ${lifecycle.name} proxy: adopted sibling server on port ${lifecycle.port} after EADDRINUSE`,
    );
    return { port: lifecycle.port, adopted: true };
  }
  console.error(
    `[aidevops] ${lifecycle.name} proxy: port ${lifecycle.targetPort} in use but no responsive proxy found after ${lifecycle.probeRetryAttempts} probes — port may be poisoned by another process`,
  );
  return null;
}

/**
 * Try to launch the proxy via the caller-supplied `launch` callback,
 * with EADDRINUSE → adopt-with-retry recovery. Caller has already
 * verified credentials and we are not adopting an existing listener.
 *
 * @param {LifecycleState} lifecycle
 * @param {() => Promise<{port: number}>} launch
 * @returns {Promise<EnsureStartedResult | null>}
 */
async function tryLaunch(lifecycle, launch) {
  lifecycle.starting = true;
  try {
    const result = await launch();
    lifecycle.port = result.port;
    return { port: lifecycle.port, adopted: false };
  } catch (err) {
    if (isPortInUseError(err)) {
      // EADDRINUSE between probe and bind = sibling plugin won the
      // race. Sibling's fetch handler may not be ready yet, so retry-
      // probe before declaring failure. Collapses the historical
      // "scary error + fallback succeeds" log pair into either a
      // clean adoption or a single genuine failure. See GH#21944.
      return attemptEaddrinuseAdoption(lifecycle);
    }
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[aidevops] ${lifecycle.name} proxy: failed to start: ${message}`);
    return null;
  } finally {
    lifecycle.starting = false;
  }
}

/**
 * Apply launch preconditions (Bun present, credentials available) and
 * delegate to `tryLaunch`. Splitting this out of `ensureStarted` keeps
 * the main entry point's return count under the qlty threshold.
 *
 * @param {LifecycleState} lifecycle
 * @param {EnsureStartedOptions} opts
 * @returns {Promise<EnsureStartedResult | null>}
 */
async function tryLaunchIfPossible(lifecycle, opts) {
  if (typeof globalThis.Bun === "undefined") {
    console.error(
      `[aidevops] ${lifecycle.name} proxy: skipped (not running under Bun and no existing proxy found)`,
    );
    return null;
  }
  // Caller-defined precondition failed (no accounts / CLI missing).
  // Silent return; the caller logs context if useful.
  if (!opts.credentialsAvailable()) return null;
  return tryLaunch(lifecycle, opts.launch);
}

/**
 * Bring the proxy up if it isn't already, with full race-resilience.
 *
 * Order of operations:
 *   1. If we're mid-startup (`starting`), bail — second concurrent
 *      caller returns null rather than racing.
 *   2. If we already have a cached port, return it (adopted=false
 *      because we don't know — the cached value covers both fresh
 *      bind and prior adoption transparently).
 *   3. Probe-first: if a sibling already serves the port, adopt it.
 *   4. Verify Bun is available (we can't bind without it) and the
 *      caller's credential check passes; then call `launch()`. On
 *      EADDRINUSE, retry-probe to adopt the sibling that won the race.
 *
 * @param {LifecycleState} lifecycle
 * @param {EnsureStartedOptions} opts
 * @returns {Promise<EnsureStartedResult | null>}
 */
async function ensureStartedImpl(lifecycle, opts) {
  if (lifecycle.starting) return null;
  if (lifecycle.port !== null) return { port: lifecycle.port, adopted: false };

  // Probe first — handles plugin hot-reload (module scope reset, but
  // the previous Bun.serve instance lives on) and adopts any sibling
  // that's already serving requests.
  const adopted = await tryAdoptExisting(lifecycle);
  if (adopted) return adopted;

  return tryLaunchIfPossible(lifecycle, opts);
}

/**
 * Create a per-proxy lifecycle controller. Call once at module scope in
 * each proxy file; the returned object owns the proxy's port + in-flight
 * state in closure (via the `lifecycle` object).
 *
 * The controller is internally idempotent: parallel `ensureStarted` calls
 * during initial startup short-circuit (the second sees `starting=true`
 * and returns null), and post-startup calls return the cached port
 * without re-binding.
 *
 * @param {ProxyLifecycleOptions} options
 * @returns {{
 *   providerID: string,
 *   getPort: () => number | null,
 *   ensureStarted: (opts: EnsureStartedOptions) => Promise<EnsureStartedResult | null>,
 * }}
 */
export function createProxyLifecycle(options) {
  /** @type {LifecycleState} */
  const lifecycle = {
    name: options.name,
    providerID: options.providerID,
    probePath: options.probePath ?? "/v1/models",
    probeTimeoutMs: options.probeTimeoutMs ?? 1500,
    probeRetryAttempts: options.probeRetryAttempts ?? 5,
    probeRetryIntervalMs: options.probeRetryIntervalMs ?? 1000,
    targetPort: resolveProxyPort(options.envPortVar, options.defaultPort),
    port: null,
    starting: false,
  };
  return {
    providerID: lifecycle.providerID,
    getPort: () => lifecycle.port,
    ensureStarted: (opts) => ensureStartedImpl(lifecycle, opts),
  };
}
