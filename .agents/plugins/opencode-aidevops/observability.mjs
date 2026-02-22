/**
 * LLM Observability Module (t1308)
 *
 * Captures LLM request metadata from OpenCode plugin hooks and writes
 * to a SQLite database for cost tracking, performance analysis, and
 * debugging. Each session appends incrementally — no full reparse needed.
 *
 * Data sources:
 *   - `event` hook: message.updated (assistant messages with cost/tokens)
 *   - `tool.execute.after` hook: tool call counts per session
 *
 * Schema is forward-compatible with t1307 (observability-helper.sh CLI).
 *
 * @module observability
 */

import { mkdirSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { execSync } from "child_process";

const HOME = homedir();
const OBS_DIR = join(HOME, ".aidevops", ".agent-workspace", "observability");
const DB_PATH = join(OBS_DIR, "llm-requests.db");

// ---------------------------------------------------------------------------
// SQLite helpers (uses sqlite3 CLI — no native dependency needed in ESM)
// ---------------------------------------------------------------------------

/**
 * Run a sqlite3 command. Returns stdout or empty string on failure.
 * @param {string} sql - SQL statement(s) to execute
 * @param {number} [timeout=5000]
 * @returns {string}
 */
function sqliteExec(sql, timeout = 5000) {
  try {
    return execSync(`sqlite3 "${DB_PATH}"`, {
      input: sql,
      encoding: "utf-8",
      timeout,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return "";
  }
}

/**
 * Escape a string for safe inclusion in a SQL literal.
 * Doubles single quotes per SQL standard.
 * @param {string} value
 * @returns {string}
 */
function sqlEscape(value) {
  if (value === null || value === undefined) return "NULL";
  return `'${String(value).replace(/'/g, "''")}'`;
}

/**
 * Initialise the observability database with WAL mode and schema.
 * Idempotent — safe to call on every plugin load.
 * @returns {boolean} true if initialisation succeeded
 */
function initDatabase() {
  try {
    mkdirSync(OBS_DIR, { recursive: true });
  } catch {
    console.error("[aidevops] Failed to create observability directory");
    return false;
  }

  // Check sqlite3 is available
  try {
    execSync("which sqlite3", { encoding: "utf-8", timeout: 2000, stdio: ["pipe", "pipe", "pipe"] });
  } catch {
    console.error("[aidevops] sqlite3 not found — observability disabled");
    return false;
  }

  const schema = `
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS llm_requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  session_id TEXT NOT NULL,
  message_id TEXT,
  provider_id TEXT,
  model_id TEXT,
  agent TEXT,
  tokens_input INTEGER DEFAULT 0,
  tokens_output INTEGER DEFAULT 0,
  tokens_reasoning INTEGER DEFAULT 0,
  tokens_cache_read INTEGER DEFAULT 0,
  tokens_cache_write INTEGER DEFAULT 0,
  tokens_total INTEGER DEFAULT 0,
  cost REAL DEFAULT 0.0,
  duration_ms INTEGER,
  finish_reason TEXT,
  error_type TEXT,
  error_message TEXT,
  tool_call_count INTEGER DEFAULT 0,
  project_path TEXT,
  variant TEXT
);

CREATE INDEX IF NOT EXISTS idx_llm_requests_session
  ON llm_requests(session_id);
CREATE INDEX IF NOT EXISTS idx_llm_requests_timestamp
  ON llm_requests(timestamp);
CREATE INDEX IF NOT EXISTS idx_llm_requests_model
  ON llm_requests(model_id);
CREATE INDEX IF NOT EXISTS idx_llm_requests_provider
  ON llm_requests(provider_id);

CREATE TABLE IF NOT EXISTS tool_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  session_id TEXT NOT NULL,
  message_id TEXT,
  call_id TEXT,
  tool_name TEXT NOT NULL,
  success INTEGER DEFAULT 1,
  duration_ms INTEGER,
  metadata TEXT
);

CREATE INDEX IF NOT EXISTS idx_tool_calls_session
  ON tool_calls(session_id);
CREATE INDEX IF NOT EXISTS idx_tool_calls_tool
  ON tool_calls(tool_name);

CREATE TABLE IF NOT EXISTS session_summaries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL UNIQUE,
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  request_count INTEGER DEFAULT 0,
  total_tokens_input INTEGER DEFAULT 0,
  total_tokens_output INTEGER DEFAULT 0,
  total_cost REAL DEFAULT 0.0,
  total_tool_calls INTEGER DEFAULT 0,
  total_errors INTEGER DEFAULT 0,
  project_path TEXT,
  models_used TEXT
);

CREATE INDEX IF NOT EXISTS idx_session_summaries_session
  ON session_summaries(session_id);
`;

  const result = sqliteExec(schema, 10000);
  if (result === "" || result.includes("wal")) {
    return true;
  }
  // Schema creation returns empty on success for CREATE TABLE IF NOT EXISTS
  return true;
}

// ---------------------------------------------------------------------------
// In-memory session state (avoids DB round-trips for counting)
// ---------------------------------------------------------------------------

/**
 * Per-session tool call counter.
 * Maps sessionID → { total: number, byTool: Map<string, number> }
 * @type {Map<string, { total: number, byTool: Map<string, number> }>}
 */
const sessionToolCounts = new Map();

/**
 * Track which message IDs we've already recorded to avoid duplicates.
 * The event hook may fire multiple times for the same message as it updates.
 * We only record once — when time.completed is set.
 * @type {Set<string>}
 */
const recordedMessages = new Set();

/**
 * Whether the database was successfully initialised.
 * @type {boolean}
 */
let dbReady = false;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Initialise the observability system.
 * Call once at plugin startup.
 * @returns {boolean} Whether initialisation succeeded
 */
export function initObservability() {
  dbReady = initDatabase();
  if (dbReady) {
    console.error("[aidevops] Observability: SQLite DB ready at " + DB_PATH);
  }
  return dbReady;
}

/**
 * Handle an OpenCode event for LLM observability.
 * Filters for assistant message completions and records metadata.
 *
 * @param {{ event: import("@opencode-ai/sdk").Event }} input
 */
export function handleEvent(input) {
  if (!dbReady) return;

  const event = input.event;
  if (!event || !event.type) return;

  if (event.type === "message.updated") {
    handleMessageUpdated(event);
  }
}

/**
 * Process a message.updated event.
 * Records LLM request data when an assistant message completes.
 *
 * @param {{ type: string, properties: { info: object } }} event
 */
function handleMessageUpdated(event) {
  const msg = event.properties?.info;
  if (!msg) return;

  // Only record assistant messages (LLM responses)
  if (msg.role !== "assistant") return;

  // Only record when the message is completed (has time.completed)
  if (!msg.time?.completed) return;

  // Deduplicate — event may fire multiple times for same message
  if (recordedMessages.has(msg.id)) return;
  recordedMessages.add(msg.id);

  // Prevent unbounded memory growth — prune old entries periodically
  if (recordedMessages.size > 10000) {
    const entries = Array.from(recordedMessages);
    const toRemove = entries.slice(0, 5000);
    for (const id of toRemove) {
      recordedMessages.delete(id);
    }
  }

  const durationMs = msg.time.completed && msg.time.created
    ? Math.round(msg.time.completed - msg.time.created)
    : null;

  const errorType = msg.error?.name || null;
  const errorMessage = msg.error?.data?.message || null;

  // Get tool call count for this session from our in-memory tracker
  const sessionState = sessionToolCounts.get(msg.sessionID);
  const toolCallCount = sessionState?.total || 0;

  const projectPath = msg.path?.root || msg.path?.cwd || null;

  const sql = `INSERT INTO llm_requests (
    session_id, message_id, provider_id, model_id, agent,
    tokens_input, tokens_output, tokens_reasoning,
    tokens_cache_read, tokens_cache_write, tokens_total,
    cost, duration_ms, finish_reason, error_type, error_message,
    tool_call_count, project_path, variant
  ) VALUES (
    ${sqlEscape(msg.sessionID)},
    ${sqlEscape(msg.id)},
    ${sqlEscape(msg.providerID)},
    ${sqlEscape(msg.modelID)},
    ${sqlEscape(msg.agent)},
    ${msg.tokens?.input || 0},
    ${msg.tokens?.output || 0},
    ${msg.tokens?.reasoning || 0},
    ${msg.tokens?.cache?.read || 0},
    ${msg.tokens?.cache?.write || 0},
    ${msg.tokens?.total || 0},
    ${msg.cost || 0.0},
    ${durationMs !== null ? durationMs : "NULL"},
    ${sqlEscape(msg.finish || null)},
    ${sqlEscape(errorType)},
    ${sqlEscape(errorMessage)},
    ${toolCallCount},
    ${sqlEscape(projectPath)},
    ${sqlEscape(msg.variant || null)}
  );`;

  sqliteExec(sql);

  // Update session summary (upsert)
  updateSessionSummary(msg, toolCallCount);
}

/**
 * Update the session_summaries table with aggregated data.
 * Uses INSERT OR REPLACE with accumulated values.
 *
 * @param {object} msg - Assistant message
 * @param {number} toolCallCount - Current tool call count for session
 */
function updateSessionSummary(msg, toolCallCount) {
  const now = new Date().toISOString();
  const projectPath = msg.path?.root || msg.path?.cwd || null;
  const hasError = msg.error ? 1 : 0;

  const sql = `
INSERT INTO session_summaries (
  session_id, first_seen, last_seen, request_count,
  total_tokens_input, total_tokens_output, total_cost,
  total_tool_calls, total_errors, project_path, models_used
) VALUES (
  ${sqlEscape(msg.sessionID)},
  ${sqlEscape(now)},
  ${sqlEscape(now)},
  1,
  ${msg.tokens?.input || 0},
  ${msg.tokens?.output || 0},
  ${msg.cost || 0.0},
  ${toolCallCount},
  ${hasError},
  ${sqlEscape(projectPath)},
  ${sqlEscape(msg.modelID || "")}
)
ON CONFLICT(session_id) DO UPDATE SET
  last_seen = ${sqlEscape(now)},
  request_count = request_count + 1,
  total_tokens_input = total_tokens_input + ${msg.tokens?.input || 0},
  total_tokens_output = total_tokens_output + ${msg.tokens?.output || 0},
  total_cost = total_cost + ${msg.cost || 0.0},
  total_tool_calls = ${toolCallCount},
  total_errors = total_errors + ${hasError},
  models_used = CASE
    WHEN models_used NOT LIKE '%' || ${sqlEscape(msg.modelID || "")} || '%'
    THEN models_used || ',' || ${sqlEscape(msg.modelID || "")}
    ELSE models_used
  END;
`;

  sqliteExec(sql);
}

/**
 * Record a tool call from the tool.execute.after hook.
 * Increments the in-memory counter and writes to the tool_calls table.
 *
 * @param {object} input - { tool, sessionID, callID, args }
 * @param {object} output - { title, output, metadata }
 */
export function recordToolCall(input, output) {
  if (!dbReady) return;

  const toolName = input.tool || "";
  const sessionID = input.sessionID || "";
  const callID = input.callID || "";

  if (!sessionID || !toolName) return;

  // Update in-memory counter
  if (!sessionToolCounts.has(sessionID)) {
    sessionToolCounts.set(sessionID, { total: 0, byTool: new Map() });
  }
  const state = sessionToolCounts.get(sessionID);
  state.total++;
  state.byTool.set(toolName, (state.byTool.get(toolName) || 0) + 1);

  // Determine success from output (heuristic: no error indicators)
  const outputText = output.output || "";
  const isSuccess = !outputText.includes("error") &&
    !outputText.includes("FAILED") &&
    !outputText.includes("Error:") ? 1 : 0;

  const sql = `INSERT INTO tool_calls (
    session_id, call_id, tool_name, success, metadata
  ) VALUES (
    ${sqlEscape(sessionID)},
    ${sqlEscape(callID)},
    ${sqlEscape(toolName)},
    ${isSuccess},
    NULL
  );`;

  sqliteExec(sql);
}

/**
 * Get the database path for external tools (e.g., observability-helper.sh).
 * @returns {string}
 */
export function getDbPath() {
  return DB_PATH;
}

/**
 * Get the observability directory path.
 * @returns {string}
 */
export function getObsDir() {
  return OBS_DIR;
}
