// ---------------------------------------------------------------------------
// Phase 4.5: Intent Tracing (t1309)
// Extracted from index.mjs (t1914) — intent extraction and storage.
// ---------------------------------------------------------------------------
// Inspired by oh-my-pi's agent__intent pattern. The LLM is instructed via
// system prompt to include an `agent__intent` field in every tool call,
// describing its intent in present participle form. The field is extracted
// from tool args in the `tool.execute.before` hook and stored in the
// observability DB alongside the tool call record.

/**
 * Field name for intent tracing — matches oh-my-pi convention.
 * @type {string}
 */
export const INTENT_FIELD = "agent__intent";

/**
 * Per-callID intent store. Bridges tool.execute.before → tool.execute.after.
 * Maps callID → intent string.
 * @type {Map<string, string>}
 */
const intentByCallId = new Map();

/**
 * Extract and store the intent field from tool call args.
 * Called from toolExecuteBefore — stores intent keyed by callID for
 * retrieval in toolExecuteAfter when the tool call is recorded to the DB.
 *
 * @param {string} callID - Unique tool call identifier
 * @param {object} args - Tool call arguments (may contain agent__intent)
 * @returns {string | undefined} Extracted intent string, or undefined
 */
export function extractAndStoreIntent(callID, args) {
  if (!args || typeof args !== "object") return undefined;

  const raw = args[INTENT_FIELD];
  if (typeof raw !== "string") return undefined;

  const intent = raw.trim();
  if (!intent) return undefined;

  intentByCallId.set(callID, intent);

  // Prune old entries to prevent unbounded memory growth
  if (intentByCallId.size > 5000) {
    const keys = Array.from(intentByCallId.keys());
    for (const k of keys.slice(0, 2500)) {
      intentByCallId.delete(k);
    }
  }

  return intent;
}

/**
 * Retrieve and remove the stored intent for a callID.
 * Called from toolExecuteAfter — consumes the intent stored by extractAndStoreIntent.
 *
 * @param {string} callID
 * @returns {string | undefined}
 */
export function consumeIntent(callID) {
  const intent = intentByCallId.get(callID);
  if (intent !== undefined) {
    intentByCallId.delete(callID);
  }
  return intent;
}
