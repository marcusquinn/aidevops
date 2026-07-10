// ---------------------------------------------------------------------------
// greeting.mjs — session-start framework status as TUI toasts (t2724)
//
// Routes the output of `aidevops-update-check.sh --interactive` through
// OpenCode's `client.tui.showToast()` so the session banner renders as
// ephemeral toasts instead of (or alongside) a message-context block.
//
// Phase 1: additive — the model still renders the greeting as the first
// message. Phase 2 (separate commit) trims the redundant text from
// generate-opencode-agents.sh once we've visually confirmed the toast.
//
// Trigger semantics (fail-open):
//   - Primary: fires once per plugin init on the first session.created event.
//   - Fallback: if session.created is missed (plugin loaded mid-session),
//     fires on the first session.updated event within 30s of plugin init.
//
// Caching: raw update-check output is written to
//   ~/.aidevops/cache/session-greeting.txt
// so non-Bash agents can read it without re-running the script (t2724 phase 2
// template change points agents at this file).
//
// Toast model (t2727 consolidation):
//   OpenCode's TUI renders one toast at a time — each client.tui.showToast()
//   call replaces the previous before the user can read it. So we classify
//   lines into severity buckets (error, warning, info, success) but emit a
//   SINGLE consolidated toast whose variant follows the highest severity
//   present and whose message preserves severity ordering:
//     error   (30s) : [SECURITY ADVISORY] / [ERROR] lines
//     warning (15s) : pulse-stalled / external contribution / [WARN] lines
//     info     (8s) : version + env lines
//     success  (5s) : "Security: all protections active"
//   A user with a clean environment sees one info/success-tinted toast with
//   the version+env+security-active lines. With any advisory or warning, the
//   variant escalates (error overrides warning, warning overrides info) and
//   all lines remain visible in the body.
//
// Toast filters: UPDATE_AVAILABLE|<...> and AUTO_UPDATE_ENABLED are the
// only lines suppressed — those are machine-readable sentinels. The
// runtime-identity line (`You are running in <app>. Global config: ...`)
// WAS suppressed from the toast by t2728 but restored by t2731 after
// user feedback that seeing the config path at session start is valuable.
// See also t2730 for the parallel AGENTS.md prose (model-only surface).
//
// Async model (t2729):
//   The update-check script spawns background children (provenance notify,
//   deploy drift check) that inherit stdout. With execSync, Node waits for
//   all inherited FDs to close — 5-8s wallclock on typical macOS hardware.
//   The fix: fire execAsync and return from the handler immediately; emit
//   the toast inside the promise's .then() callback whenever the subprocess
//   finishes. The session.created handler resolves in <1ms; the toast appears
//   5-15s later (same content, same variant, just deferred).
//   With AIDEVOPS_PLUGIN_DEBUG=1, the trace log shows handler-completed
//   BEFORE emitToast-* — the reversed ordering confirms async delivery.
//
// Diagnostics: set AIDEVOPS_PLUGIN_DEBUG=1 to trace every handler invocation
// and each toast emission (including failures). Without DEBUG the handler
// is silent on success — only actual errors reach stderr.
// ---------------------------------------------------------------------------

import { exec } from "child_process";
import { promisify } from "util";
import {
  closeSync,
  fstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "fs";
import { join, dirname } from "path";
import { homedir } from "os";

const execAsync = promisify(exec);

const CACHE_DIR = join(homedir(), ".aidevops", "cache");
const CACHE_BASENAME = "session-greeting.txt";
const LOCK_BASENAME = "session-greeting-refresh.lock";
const LOCK_OWNER_BASENAME = "owner";
// Comprehensive checks run at most once per 15-minute window. The subprocess
// times out after 15 seconds, so a lock older than 30 seconds is safe to reap
// after an abrupt plugin-process exit.
const REFRESH_TTL_MS = 15 * 60 * 1000;
const LOCK_STALE_MS = 30 * 1000;
const WARNING_LINE_PREFIXES = ["Pulse stalled", "[OPENCODE MAINTENANCE]", "[WARNING]", "[WARN]"];

// Fallback window: accept the first session.updated as a trigger if no
// session.created arrived within this many ms of plugin init. Keeps the
// handler from firing on every subsequent session.updated event.
const FALLBACK_WINDOW_MS = 30000;

/**
 * Run the update-check script asynchronously and deliver results via callback.
 *
 * t2729: replaced execSync with execAsync so the caller returns immediately
 * and the toast is emitted inside the promise's .then() callback whenever the
 * subprocess finishes. Node no longer waits for background children
 * (provenance notify, deploy drift check) to close their inherited stdout FDs.
 *
 * Timeout 15s (t2725) is preserved as a fallback governing the fire-and-forget
 * tail rather than the handler return time.
 *
 * The caller owns a cross-process lock and this promise chain always releases
 * it, including empty-output and failure paths.
 *
 * @param {{ scriptsDir: string, client: any, cacheFile: string, lockDir: string,
 *   execGreeting: Function, maintenanceNoticeFn: Function }} options
 */
function runGreetingAsync({ scriptsDir, client, cacheFile, lockDir, lockToken, execGreeting, maintenanceNoticeFn }) {
  const script = join(scriptsDir, "aidevops-update-check.sh");
  Promise.resolve()
    .then(() => execGreeting(`bash ${JSON.stringify(script)} --interactive`, {
      timeout: 15000,
    }))
    .then(async ({ stdout }) => {
      const output = stdout ? stdout.trim() : "";
      if (!output) {
        if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
          console.error("[aidevops] greeting: update-check returned empty, skipping toasts");
        }
        return;
      }

      const maintenanceNotice = await maintenanceNoticeFn(scriptsDir);
      const combinedOutput = [output, maintenanceNotice].filter(Boolean).join("\n");

      cacheGreeting(cacheFile, combinedOutput);
      const toast = greetingToast(combinedOutput);

      if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
        const buckets = classifyLines(combinedOutput);
        const bucketCounts = `info=${buckets.info.length}, success=${buckets.success.length}, warning=${buckets.warning.length}, error=${buckets.error.length}`;
        if (toast) {
          console.error(`[aidevops] greeting: built 1 toast (variant=${toast.variant}, ${bucketCounts})`);
        } else {
          console.error(`[aidevops] greeting: no lines to show (${bucketCounts})`);
        }
      }

      if (toast) {
        emitToast(client, toast);
      }
    })
    .catch((err) => {
      if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
        console.error(`[aidevops] greeting: update-check failed: ${err.message}`);
      }
    })
    .finally(() => {
      releaseRefreshLock(lockDir, lockToken);
    });
  // Returns here — handler can resolve before the subprocess finishes.
}

/**
 * Return an optional one-line OpenCode DB maintenance notice.
 *
 * The helper owns all DB/scheduler logic; the plugin only appends any emitted
 * notice to the existing consolidated greeting toast. Failures are ignored so
 * session startup never depends on maintenance diagnostics.
 *
 * @param {string} scriptsDir
 * @returns {Promise<string>}
 */
async function getOpenCodeMaintenanceNotice(scriptsDir) {
  const script = join(scriptsDir, "opencode-db-maintenance-helper.sh");
  try {
    const { stdout } = await execAsync(`bash ${JSON.stringify(script)} notice`, {
      timeout: 2500,
    });
    return stdout ? stdout.trim() : "";
  } catch (err) {
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: opencode maintenance notice failed: ${err.message}`);
    }
    return "";
  }
}

/**
 * Write raw update-check output to ~/.aidevops/cache/session-greeting.txt
 * so non-Bash agents can consult it without re-running the script.
 * Failures are non-fatal — the toast path continues regardless.
 *
 * @param {string} output
 */
function cacheGreeting(cacheFile, output) {
  const tempFile = join(dirname(cacheFile), `.${CACHE_BASENAME}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`);
  try {
    mkdirSync(dirname(cacheFile), { recursive: true });
    writeFileSync(tempFile, output + "\n", { encoding: "utf-8", mode: 0o600 });
    renameSync(tempFile, cacheFile);
  } catch (err) {
    rmSync(tempFile, { force: true });
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: cache write failed: ${err.message}`);
    }
  }
}

function readGreetingCache(cacheFile) {
  let fd;
  try {
    fd = openSync(cacheFile, "r");
    const output = readFileSync(fd, "utf-8").trim();
    if (!output) return null;
    return { output, mtimeMs: fstatSync(fd).mtimeMs };
  } catch {
    return null;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function greetingToast(output) {
  return buildToast(classifyLines(output));
}

function emitCachedGreeting(client, cached) {
  if (!cached) return;
  const toast = greetingToast(cached.output);
  if (toast) emitToast(client, toast);
}

function createOwnedLock(lockDir, lockToken) {
  try {
    mkdirSync(lockDir);
    writeFileSync(join(lockDir, LOCK_OWNER_BASENAME), lockToken, { encoding: "utf-8", mode: 0o600 });
    return lockToken;
  } catch (err) {
    if (err.code !== "EEXIST") {
      rmSync(lockDir, { recursive: true, force: true });
    }
    return null;
  }
}

function acquireRefreshLock(lockDir, staleMs, nowMs) {
  const lockToken = `${process.pid}-${Math.random().toString(16).slice(2)}`;
  try {
    mkdirSync(dirname(lockDir), { recursive: true });
    const acquired = createOwnedLock(lockDir, lockToken);
    if (acquired) return acquired;
  } catch (err) {
    if (err.code !== "EEXIST") return null;
  }

  const staleDir = `${lockDir}.stale.${lockToken}`;
  try {
    if (nowMs - statSync(lockDir).mtimeMs <= staleMs) return null;
    // Rename atomically before reaping: only one contender can claim a stale
    // lock, and no contender can delete a replacement lock by path.
    renameSync(lockDir, staleDir);
    return createOwnedLock(lockDir, lockToken);
  } catch {
    // Another process either recovered or acquired the lock first.
    return null;
  } finally {
    rmSync(staleDir, { recursive: true, force: true });
  }
}

function releaseRefreshLock(lockDir, lockToken) {
  try {
    const owner = readFileSync(join(lockDir, LOCK_OWNER_BASENAME), "utf-8");
    if (owner !== lockToken) return;
    rmSync(lockDir, { recursive: true, force: true });
  } catch (err) {
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: lock release failed: ${err.message}`);
    }
  }
}

function observeSharedRefresh({ cacheFile, lockDir, lockStaleMs, client, now }) {
  const deadline = now() + lockStaleMs;
  const poll = () => {
    const cached = readGreetingCache(cacheFile);
    if (cached) {
      emitCachedGreeting(client, cached);
      return;
    }

    try {
      if (now() >= deadline || now() - statSync(lockDir).mtimeMs > lockStaleMs) return;
    } catch {
      // The owner may publish the cache and remove its lock between our cache
      // read and lock stat. Re-check once so that handoff still emits it.
      const finalCached = readGreetingCache(cacheFile);
      if (finalCached) {
        emitCachedGreeting(client, finalCached);
        return;
      }
      // A stale-lock contender may have renamed the old lock but not created
      // its replacement yet. Keep polling within the original safety bound.
      if (now() >= deadline) return;
    }

    const timer = setTimeout(poll, 25);
    timer.unref?.();
  };
  poll();
}

/**
 * Classify each line of update-check output into toast variants.
 *
 * @param {string} output
 * @returns {{ info: string[], success: string[], warning: string[], error: string[] }}
 */
export function classifyLines(output) {
  const info = [];
  const success = [];
  const warning = [];
  const error = [];

  for (const rawLine of output.split("\n")) {
    const line = rawLine.trim();
    if (!line) continue;

    // Skip UPDATE_AVAILABLE| sentinel lines — those are machine-readable
    // markers consumed by the model greeting, not human banner text.
    if (line.startsWith("UPDATE_AVAILABLE|") || line === "AUTO_UPDATE_ENABLED") {
      continue;
    }

    // Order matters: errors first (most specific), then warnings, then
    // success, then info (catch-all for version/env lines).
    if (line.startsWith("[SECURITY ADVISORY]") || line.startsWith("[ERROR]")) {
      error.push(line);
    } else if (isWarningLine(line)) {
      warning.push(line);
    } else if (line.startsWith("Security: all protections active")) {
      success.push(line);
    } else {
      info.push(line);
    }
  }

  return { info, success, warning, error };
}

function isWarningLine(line) {
  return WARNING_LINE_PREFIXES.some((prefix) => line.startsWith(prefix)) || /contribution\(s\) need/i.test(line);
}

/**
 * Consolidate classified lines into a single toast body.
 *
 * OpenCode's TUI renders one toast at a time — each new client.tui.showToast()
 * call replaces the previous one before the user can read it (t2727, observed
 * after PR #20424 deployed: end user saw only the final "success" toast of the
 * original four-emit sequence). So we collapse the four-category Phase 1
 * design into a single emit that preserves severity ordering in the message
 * body.
 *
 * Variant follows the highest severity present (error > warning > info >
 * success); duration follows the variant's existing mapping (30s/15s/8s/5s).
 * Returns null when all buckets are empty so the caller can skip the emit.
 *
 * @param {{ info: string[], success: string[], warning: string[], error: string[] }} buckets
 * @returns {{ title: string, message: string, variant: "info"|"success"|"warning"|"error", duration: number } | null}
 */
export function buildToast(buckets) {
  const lines = [
    ...buckets.error,
    ...buckets.warning,
    ...buckets.info,
    ...buckets.success,
  ];

  if (lines.length === 0) return null;

  let variant, duration;
  if (buckets.error.length > 0) {
    variant = "error";
    duration = 30000;
  } else if (buckets.warning.length > 0) {
    variant = "warning";
    duration = 15000;
  } else if (buckets.info.length > 0) {
    variant = "info";
    duration = 8000;
  } else {
    variant = "success";
    duration = 5000;
  }

  return {
    title: "aidevops",
    message: lines.join("\n"),
    variant,
    duration,
  };
}

/**
 * Emit one toast via client.tui.showToast(). Logs failures when DEBUG is on.
 *
 * @param {any} client
 * @param {{ title: string, message: string, variant: string, duration: number }} body
 */
async function emitToast(client, body) {
  try {
    await client.tui.showToast({ body });
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: toast emitted (variant=${body.variant}, ${body.message.length} chars)`);
    }
  } catch (err) {
    // Log on DEBUG; otherwise swallow (failures here are non-fatal —
    // the user still has the message-context greeting in Phase 1).
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: toast failed: ${err.message}`);
    }
  }
}

// runGreeting is superseded by runGreetingAsync (t2729). The async variant
// fires the update-check subprocess and returns immediately; all downstream
// work (cache write, classify, toast emit) runs inside the promise chain.
// The caller MUST NOT await runGreetingAsync — doing so would restore the
// blocking behaviour this change is meant to fix.

/**
 * Create a handler that fires the greeting once per plugin init. The
 * returned function matches the plugin `event` hook contract so it can be
 * composed alongside other event consumers.
 *
 * Trigger rules:
 *   1. Fires on the first `session.created` event received.
 *   2. Falls back to the first `session.updated` event if >0ms but <30s
 *      since plugin init has elapsed without a session.created arriving
 *      (handles the case where the plugin loads after a session is already
 *      active — e.g., hot-deploy during an existing session).
 *   3. Ignores all other event types.
 *
 * @param {{ scriptsDir: string, client: any }} opts
 * @returns {(input: { event: { type: string } }) => Promise<void>}
 */
export function createGreetingHandler({
  scriptsDir,
  client,
  cacheDir = CACHE_DIR,
  refreshTtlMs = REFRESH_TTL_MS,
  lockStaleMs = LOCK_STALE_MS,
  execGreeting = execAsync,
  maintenanceNoticeFn = getOpenCodeMaintenanceNotice,
  now = Date.now,
}) {
  let fired = false;
  const initTime = now();
  const cacheFile = join(cacheDir, CACHE_BASENAME);
  const lockDir = join(cacheDir, LOCK_BASENAME);

  return async ({ event }) => {
    if (fired) return;
    if (!event || !event.type) return;

    const isPrimary = event.type === "session.created";
    const isFallback =
      event.type === "session.updated" &&
      now() - initTime < FALLBACK_WINDOW_MS;

    if (!isPrimary && !isFallback) return;

    fired = true;

    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      const mode = isPrimary ? "primary" : "fallback";
      console.error(`[aidevops] greeting: triggered (mode=${mode}, type=${event.type})`);
    }

    // Serve the last complete cache synchronously. This keeps the event hook
    // independent of refresh latency even when this process becomes lock owner.
    const cached = readGreetingCache(cacheFile);
    emitCachedGreeting(client, cached);

    if (!cached || now() - cached.mtimeMs > refreshTtlMs) {
      const lockToken = acquireRefreshLock(lockDir, lockStaleMs, now());
      if (lockToken) {
        // t2729: fire-and-forget — do NOT await. The handler resolves immediately;
        // the toast arrives whenever the subprocess finishes.
        runGreetingAsync({
          scriptsDir,
          client,
          cacheFile,
          lockDir,
          lockToken,
          execGreeting,
          maintenanceNoticeFn,
        });
      } else {
        if (!cached) {
          // A cold-cache follower still gets the owner's completed greeting;
          // polling is bounded by the same crashed-lock recovery interval.
          observeSharedRefresh({ cacheFile, lockDir, lockStaleMs, client, now });
        }
        if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
          console.error("[aidevops] greeting: refresh already running in another process");
        }
      }
    }

    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error("[aidevops] greeting: handler-completed");
    }
  };
}
