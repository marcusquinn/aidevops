// ---------------------------------------------------------------------------
// Timing Tracing (t2184)
// Mirror of intent-tracing.mjs — records tool-call start timestamps in
// tool.execute.before and produces a duration (ms) on tool.execute.after.
// ---------------------------------------------------------------------------
// Companion to intent-tracing.mjs. Same per-callID Map pattern, same LRU
// bound (5000 entries, pruned to 2500). Separate module so the timing data
// path is independently testable and cannot collide with intent consumption
// ordering.
//
// The SQLite `tool_calls.duration_ms` column has existed in the schema since
// t1308 but was never populated — the INSERT statement in observability.mjs
// omitted the column. t2184 closes that gap by measuring start→after here
// and threading the value into the INSERT.

/**
 * Per-callID start-timestamp store. Bridges tool.execute.before →
 * tool.execute.after. Maps callID → ms-since-epoch when the tool started.
 * @type {Map<string, number>}
 */
const startTsByCallId = new Map();

/**
 * Record the start timestamp for a tool call.
 * Called from toolExecuteBefore. Stores Date.now() keyed by callID.
 *
 * No-op when callID is empty — without an ID the post-hook cannot look
 * up the entry, so storing it would just leak memory until the LRU trim.
 *
 * @param {string} callID - Unique tool call identifier
 * @returns {void}
 */
export function recordToolStart(callID) {
  if (!callID) return;

  startTsByCallId.set(callID, Date.now());

  // Prune old entries to prevent unbounded memory growth.
  // Same threshold and trim size as intent-tracing.mjs.
  if (startTsByCallId.size > 5000) {
    const keys = Array.from(startTsByCallId.keys());
    for (const k of keys.slice(0, 2500)) {
      startTsByCallId.delete(k);
    }
  }
}

/**
 * Retrieve and remove the stored start timestamp, returning elapsed ms.
 * Called from toolExecuteAfter.
 *
 * @param {string} callID
 * @returns {number | null} Elapsed milliseconds, or null if callID is
 *   empty, unknown, or already consumed.
 */
export function consumeToolDuration(callID) {
  if (!callID) return null;

  const start = startTsByCallId.get(callID);
  if (start === undefined) return null;

  startTsByCallId.delete(callID);
  const elapsed = Date.now() - start;
  return elapsed >= 0 ? elapsed : 0;
}

/**
 * Test-only: inspect current tracking size. Not exported to consumers.
 * @returns {number}
 * @internal
 */
export function _size() {
  return startTsByCallId.size;
}

/**
 * Test-only: clear all tracked entries. Used by test suites to isolate runs.
 * @returns {void}
 * @internal
 */
export function _clear() {
  startTsByCallId.clear();
}
