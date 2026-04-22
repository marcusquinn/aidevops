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
// Diagnostics: set AIDEVOPS_PLUGIN_DEBUG=1 to trace every handler invocation
// and each toast emission (including failures). Without DEBUG the handler
// is silent on success — only actual errors reach stderr.
// ---------------------------------------------------------------------------

import { execSync } from "child_process";
import { mkdirSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { homedir } from "os";

const CACHE_DIR = join(homedir(), ".aidevops", "cache");
const CACHE_FILE = join(CACHE_DIR, "session-greeting.txt");

// Fallback window: accept the first session.updated as a trigger if no
// session.created arrived within this many ms of plugin init. Keeps the
// handler from firing on every subsequent session.updated event.
const FALLBACK_WINDOW_MS = 30000;

/**
 * Run the update-check script and return its stdout (trimmed), or "" on failure.
 *
 * Timeout 15s (t2725): the script itself produces output in ~1-2s, but forks
 * background children (provenance notify, deploy drift check) that inherit
 * stdout. Node's execSync waits for all inherited FDs to close, so total
 * observed wallclock is 5-8s on a typical macOS system. 15s gives headroom
 * for slower hardware; a timeout just means no toasts this session — the
 * handler is async, so nothing else blocks.
 *
 * @param {string} scriptsDir
 * @returns {string}
 */
function runUpdateCheck(scriptsDir) {
  const script = join(scriptsDir, "aidevops-update-check.sh");
  try {
    return execSync(`bash ${JSON.stringify(script)} --interactive`, {
      encoding: "utf-8",
      timeout: 15000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (err) {
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: update-check failed: ${err.message}`);
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
function cacheGreeting(output) {
  try {
    mkdirSync(dirname(CACHE_FILE), { recursive: true });
    writeFileSync(CACHE_FILE, output + "\n", "utf-8");
  } catch (err) {
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: cache write failed: ${err.message}`);
    }
  }
}

/**
 * Classify each line of update-check output into toast variants.
 *
 * @param {string} output
 * @returns {{ info: string[], success: string[], warning: string[], error: string[] }}
 */
function classifyLines(output) {
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
    } else if (
      line.startsWith("Pulse stalled") ||
      /contribution\(s\) need/i.test(line) ||
      line.startsWith("[WARNING]") ||
      line.startsWith("[WARN]")
    ) {
      warning.push(line);
    } else if (line.startsWith("Security: all protections active")) {
      success.push(line);
    } else {
      info.push(line);
    }
  }

  return { info, success, warning, error };
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
function buildToast(buckets) {
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

/**
 * Run the full greeting flow: update-check → cache → classify → toasts.
 *
 * @param {string} scriptsDir
 * @param {any} client
 */
async function runGreeting(scriptsDir, client) {
  const output = runUpdateCheck(scriptsDir);
  if (!output) {
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error("[aidevops] greeting: update-check returned empty, skipping toasts");
    }
    return;
  }

  cacheGreeting(output);

  const buckets = classifyLines(output);
  const toast = buildToast(buckets);

  if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
    const bucketCounts = `info=${buckets.info.length}, success=${buckets.success.length}, warning=${buckets.warning.length}, error=${buckets.error.length}`;
    if (toast) {
      console.error(`[aidevops] greeting: built 1 toast (variant=${toast.variant}, ${bucketCounts})`);
    } else {
      console.error(`[aidevops] greeting: no lines to show (${bucketCounts})`);
    }
  }

  // t2727: single emit. OpenCode's TUI replaces any existing toast on each
  // showToast() call, so multiple emits race and only the last one is seen.
  if (toast) {
    await emitToast(client, toast);
  }
}

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
export function createGreetingHandler({ scriptsDir, client }) {
  let fired = false;
  const initTime = Date.now();

  return async ({ event }) => {
    if (fired) return;
    if (!event || !event.type) return;

    const isPrimary = event.type === "session.created";
    const isFallback =
      event.type === "session.updated" &&
      Date.now() - initTime < FALLBACK_WINDOW_MS;

    if (!isPrimary && !isFallback) return;

    fired = true;

    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      const mode = isPrimary ? "primary" : "fallback";
      console.error(`[aidevops] greeting: triggered (mode=${mode}, type=${event.type})`);
    }

    await runGreeting(scriptsDir, client);
  };
}
