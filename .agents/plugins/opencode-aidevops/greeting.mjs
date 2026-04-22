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
// Toast grouping (single-pass, cheap):
//   - info    : version + env lines                         (8s)
//   - success : "Security: all protections active"          (5s)
//   - warning : pulse-stalled / external contribution lines (15s)
//   - error   : [SECURITY ADVISORY] lines                   (30s)
//
// If a category has no matching lines, no toast for it is emitted. A
// user with a clean environment sees one info toast and one success toast.
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
 * Uses a short timeout — we never want a hung greeting to block plugin init.
 *
 * @param {string} scriptsDir
 * @returns {string}
 */
function runUpdateCheck(scriptsDir) {
  const script = join(scriptsDir, "aidevops-update-check.sh");
  try {
    return execSync(`bash ${JSON.stringify(script)} --interactive`, {
      encoding: "utf-8",
      timeout: 5000,
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
 * Build toast bodies from classified lines, skipping empty categories.
 *
 * @param {{ info: string[], success: string[], warning: string[], error: string[] }} buckets
 * @returns {Array<{ title: string, message: string, variant: "info"|"success"|"warning"|"error", duration: number }>}
 */
function buildToasts(buckets) {
  const toasts = [];

  if (buckets.error.length > 0) {
    toasts.push({
      title: "aidevops — attention required",
      message: buckets.error.join("\n"),
      variant: "error",
      duration: 30000,
    });
  }

  if (buckets.warning.length > 0) {
    toasts.push({
      title: "aidevops",
      message: buckets.warning.join("\n"),
      variant: "warning",
      duration: 15000,
    });
  }

  if (buckets.info.length > 0) {
    toasts.push({
      title: "aidevops",
      message: buckets.info.join("\n"),
      variant: "info",
      duration: 8000,
    });
  }

  if (buckets.success.length > 0) {
    toasts.push({
      title: "aidevops",
      message: buckets.success.join("\n"),
      variant: "success",
      duration: 5000,
    });
  }

  return toasts;
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
  const toasts = buildToasts(buckets);

  if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
    console.error(`[aidevops] greeting: built ${toasts.length} toasts (info=${buckets.info.length}, success=${buckets.success.length}, warning=${buckets.warning.length}, error=${buckets.error.length})`);
  }

  // Emit sequentially so the ordering (error → warning → info → success)
  // is preserved in the TUI toast stack. Per-toast errors are swallowed
  // so one bad emit doesn't prevent later ones.
  for (const body of toasts) {
    await emitToast(client, body);
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
