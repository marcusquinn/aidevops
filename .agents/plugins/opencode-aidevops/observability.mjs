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

import {
  mkdirSync, readFileSync, writeFileSync, existsSync, rmdirSync, unlinkSync, statSync,
} from "fs";
import { join, dirname } from "path";
import { homedir } from "os";
import { execSync } from "child_process";
import { fileURLToPath } from "url";
import {
  setDbPath, sqliteExec, sqliteExecSync, shutdownSqlite as _shutdownSqlite, sqlEscape,
} from "./observability-sqlite.mjs";

const HOME = homedir();
const DEFAULT_OBS_DIR = join(HOME, ".aidevops", ".agent-workspace", "observability");
// AIDEVOPS_OBS_DB_OVERRIDE lets tests redirect to a temp DB without touching
// the prod observability DB. Module-load semantics — set the env var BEFORE
// importing this module. See tests/test-observability-concurrent-init.sh (t2900).
const DB_PATH = process.env.AIDEVOPS_OBS_DB_OVERRIDE || join(DEFAULT_OBS_DIR, "llm-requests.db");
const OBS_DIR = dirname(DB_PATH);

// ---------------------------------------------------------------------------
// Pricing table — loaded from shared JSON (single source of truth).
// File: .agents/configs/model-pricing.json (also consumed by shared-constants.sh)
// Falls back to hardcoded defaults if the JSON file is missing/unreadable.
// ---------------------------------------------------------------------------

/** Hardcoded fallback — used only when model-pricing.json is unreadable */
const FALLBACK_PRICING = {
  "opus-4":    { input: 15.0,  output: 75.0,  cacheRead: 1.50,   cacheWrite: 18.75 },
  "sonnet-4":  { input: 3.0,   output: 15.0,  cacheRead: 0.30,   cacheWrite: 3.75  },
  "haiku-4":   { input: 0.80,  output: 4.0,   cacheRead: 0.08,   cacheWrite: 1.0   },
  "haiku-3":   { input: 0.80,  output: 4.0,   cacheRead: 0.08,   cacheWrite: 1.0   },
};
const FALLBACK_DEFAULT = { input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75 };

/**
 * Load pricing from the shared JSON file.
 * The JSON uses snake_case keys (cache_read, cache_write) for cross-language
 * compatibility; we convert to camelCase for JS consumption.
 * @returns {{ models: Record<string, {input,output,cacheRead,cacheWrite}>, default: {input,output,cacheRead,cacheWrite} }}
 */
function loadPricingFromJSON() {
  // Resolve relative to this file's location (works in both dev repo and deployed ~/.aidevops/)
  const thisDir = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    join(thisDir, "..", "..", "configs", "model-pricing.json"),          // repo: .agents/plugins/../../configs/
    join(HOME, ".aidevops", "agents", "configs", "model-pricing.json"), // deployed
  ];

  for (const candidate of candidates) {
    try {
      const raw = JSON.parse(readFileSync(candidate, "utf-8"));
      const models = {};
      for (const [key, p] of Object.entries(raw.models || {})) {
        models[key] = {
          input: p.input,
          output: p.output,
          cacheRead: p.cache_read,
          cacheWrite: p.cache_write,
        };
      }
      const def = raw.default || {};
      const defaultPricing = {
        input: def.input ?? 3.0,
        output: def.output ?? 15.0,
        cacheRead: def.cache_read ?? 0.30,
        cacheWrite: def.cache_write ?? 3.75,
      };
      return { models, default: defaultPricing };
    } catch {
      // Try next candidate
    }
  }

  // All candidates failed — use hardcoded fallback
  console.error("[aidevops] Observability: model-pricing.json not found, using hardcoded fallback");
  return { models: FALLBACK_PRICING, default: FALLBACK_DEFAULT };
}

const _pricing = loadPricingFromJSON();
const MODEL_PRICING = _pricing.models;
const DEFAULT_PRICING = _pricing.default;

/**
 * Look up pricing for a model ID. Matches against the pricing table keys
 * as substrings of the model ID (e.g., "claude-sonnet-4-20250514" matches "sonnet-4").
 * @param {string} modelID
 * @returns {{ input: number, output: number, cacheRead: number, cacheWrite: number }}
 */
function getPricing(modelID) {
  if (!modelID) return DEFAULT_PRICING;
  const lower = modelID.toLowerCase();
  for (const [key, pricing] of Object.entries(MODEL_PRICING)) {
    if (lower.includes(key)) return pricing;
  }
  return DEFAULT_PRICING;
}

/**
 * Calculate cost from token counts and model pricing.
 * OpenCode does not provide cost in message events — we must compute it.
 * @param {object} tokens - { input, output, reasoning, cache: { read, write } }
 * @param {string} modelID
 * @returns {number} Total cost in USD
 */
function calculateCost(tokens, modelID) {
  if (!tokens) return 0.0;
  const pricing = getPricing(modelID);
  const inputTokens = tokens.input || 0;
  const outputTokens = tokens.output || 0;
  const reasoningTokens = tokens.reasoning || 0;
  const cacheRead = tokens.cache?.read || 0;
  const cacheWrite = tokens.cache?.write || 0;

  // Reasoning tokens are billed at output rate
  const cost =
    (inputTokens / 1e6) * pricing.input +
    ((outputTokens + reasoningTokens) / 1e6) * pricing.output +
    (cacheRead / 1e6) * pricing.cacheRead +
    (cacheWrite / 1e6) * pricing.cacheWrite;

  return Math.round(cost * 1e8) / 1e8; // 8 decimal places
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

  // Set the DB path for the SQLite process manager
  setDbPath(DB_PATH);

  // FAST PATH (t2900): the schema includes `PRAGMA journal_mode=WAL` and
  // `CREATE TABLE/INDEX IF NOT EXISTS`. Even though the CREATEs are
  // idempotent, all of them require the writer lock. With 24 concurrent
  // workers (see `MAX_WORKERS` in pulse-wrapper.sh), the writer queue grew
  // beyond the 5s `.timeout` and produced `database is locked (5)` on
  // 100% of worker startups. Read-only check first — no lock contention,
  // skips the slow path entirely once the DB is ready.
  if (existsSync(DB_PATH) && _isSchemaInitialized()) {
    return _runDataMigrations();
  }

  // SLOW PATH (t2900): serialise schema creation across concurrent workers
  // via mkdir-based advisory lock. mkdir is POSIX-atomic on every fs we
  // care about, so we don't need flock (which has FD-inheritance footguns).
  // Pattern follows oauth-pool-storage::withPoolLock.
  return _withInitLock(() => {
    // DOUBLE-CHECKED LOCKING: another worker may have completed init while
    // we waited. If schema is now ready, skip the writer-lock-heavy path.
    if (existsSync(DB_PATH) && _isSchemaInitialized()) {
      return _runDataMigrations();
    }
    if (!_createSchema()) return false;
    return _runDataMigrations();
  });
}

/**
 * Read-only check: are all expected tables present and is the t1309 `intent`
 * column on `tool_calls`? Uses `sqlite3 -readonly` so it never contends on
 * the writer lock — safe to call from N concurrent workers without race.
 *
 * Returns false on any error (DB doesn't exist, sqlite3 fails, schema is
 * incomplete) so the caller falls through to the slow path.
 *
 * @returns {boolean}
 */
function _isSchemaInitialized() {
  try {
    const result = execSync(
      "sqlite3 -readonly -separator '|' \"$TARGET_DB\" " +
      "\"SELECT " +
      "(SELECT COUNT(*) FROM sqlite_master WHERE type='table' " +
      "AND name IN ('llm_requests','tool_calls','session_summaries')) AS tbls, " +
      "(SELECT COUNT(*) FROM pragma_table_info('tool_calls') WHERE name='intent') AS intent_col;\"",
      {
        encoding: "utf-8",
        timeout: 2000,
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env, TARGET_DB: DB_PATH },
      },
    ).trim();
    if (!result) return false;
    const [tbls, intentCol] = result.split("|");
    return tbls === "3" && intentCol === "1";
  } catch {
    return false;
  }
}

/**
 * Run the heavy schema CREATE block (the writer-lock contention point).
 * Caller is responsible for serialising this via `_withInitLock`.
 *
 * @returns {boolean} true on success
 */
function _createSchema() {
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
  intent TEXT,
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

  const result = sqliteExecSync(schema, 10000);
  if (result === null) {
    console.error("[aidevops] Observability: schema creation failed");
    return false;
  }
  return true;
}

/**
 * Idempotent data migrations that run on every plugin init.
 *
 * Both migrations are no-ops on the second+ run (they check state first /
 * have `WHERE cost=0` filters), so calling this on the fast path is cheap.
 * It still touches the writer lock briefly when the SELECT promotes to a
 * BEGIN IMMEDIATE — but the per-call write is a microsecond, not a 459MB
 * journal flush, so writer-queue contention is no longer the bottleneck.
 *
 * @returns {boolean} true on success (best-effort — never returns false)
 */
function _runDataMigrations() {
  // Migration: add intent column to tool_calls if it doesn't exist (t1309).
  // Check first to avoid noisy "duplicate column" errors in logs.
  // Fresh DBs already have the column from the CREATE TABLE above.
  const hasIntentCol = sqliteExecSync(
    "SELECT COUNT(*) FROM pragma_table_info('tool_calls') WHERE name='intent';",
    5000,
  );
  if (hasIntentCol === "0") {
    sqliteExecSync("ALTER TABLE tool_calls ADD COLUMN intent TEXT;", 5000);
  }

  // Migration: backfill cost for rows where cost=0 but tokens exist.
  // OpenCode never provided msg.cost — all historical rows have cost=0.
  // This runs once (subsequent runs find 0 rows to update) and takes ~1s.
  backfillCosts();

  return true;
}

/**
 * mkdir-based advisory lock for schema initialisation (t2900).
 *
 * Pattern matches `oauth-pool-storage::withPoolLock`. mkdirSync is
 * POSIX-atomic — only one of N concurrent callers wins. Stale locks (dead
 * PID or older than `STALE_MS`) are reclaimed automatically.
 *
 * Lock is per-DB-path so the test suite (which sets `AIDEVOPS_OBS_DB_OVERRIDE`)
 * doesn't fight production workers for the same lockdir.
 *
 * On lock-acquisition timeout, falls back to running `fn()` without the
 * lock — the SQLite `.timeout 5000` busy_timeout is still in effect, and
 * a worst-case `database is locked` is preferable to dropping observability
 * for the rest of the session.
 *
 * @template T
 * @param {() => T} fn
 * @returns {T}
 */
function _withInitLock(fn) {
  const LOCK_DIR = `${DB_PATH}.init.lock.d`;
  const OWNER_FILE = `${LOCK_DIR}/owner`;
  const STALE_MS = 30000; // 30s — schema init has historically taken <2s
  const deadline = Date.now() + 30000;

  if (!_acquireInitLock(LOCK_DIR, OWNER_FILE, STALE_MS, deadline)) {
    console.error("[aidevops] Observability: init lock timeout — proceeding without lock");
    return fn();
  }

  try {
    return fn();
  } finally {
    _releaseInitLock(LOCK_DIR, OWNER_FILE);
  }
}

/**
 * Block until the init lock is acquired, the deadline is reached, or a
 * stale lock is reclaimed. Returns true on acquisition, false on timeout.
 *
 * Stale locks (dead PID or older than `staleMs`) are removed and the loop
 * retries. Concurrent callers race via mkdirSync POSIX-atomic semantics —
 * exactly one wins per attempt.
 *
 * @param {string} lockDir
 * @param {string} ownerFile
 * @param {number} staleMs
 * @param {number} deadline epoch-ms after which we give up
 * @returns {boolean}
 */
function _acquireInitLock(lockDir, ownerFile, staleMs, deadline) {
  const sleepBuf = new Int32Array(new SharedArrayBuffer(4));
  while (Date.now() < deadline) {
    try {
      mkdirSync(lockDir);
      writeFileSync(ownerFile, JSON.stringify({ pid: process.pid, ts: Date.now() }), { mode: 0o600 });
      return true;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      if (_isInitLockStale(ownerFile, staleMs)) {
        _removeStaleLockFiles(lockDir, ownerFile);
        continue;
      }
      Atomics.wait(sleepBuf, 0, 0, 100);
    }
  }
  return false;
}

/**
 * Best-effort removal of a stale init lock's owner file and dir. Any
 * ENOENT/EBUSY race against another reclaiming process is swallowed.
 *
 * @param {string} lockDir
 * @param {string} ownerFile
 */
function _removeStaleLockFiles(lockDir, ownerFile) {
  try { unlinkSync(ownerFile); } catch { /* race */ }
  try { rmdirSync(lockDir); } catch { /* race */ }
}

/**
 * Returns true if the init lock's owner PID is dead or older than `staleMs`.
 * Returns false on any read error (caller should keep waiting).
 *
 * @param {string} ownerFile
 * @param {number} staleMs
 * @returns {boolean}
 */
function _isInitLockStale(ownerFile, staleMs) {
  try {
    const { pid, ts } = JSON.parse(readFileSync(ownerFile, "utf-8"));
    const processGone = (() => {
      try {
        process.kill(pid, 0);
        return false;
      } catch (e) {
        // ESRCH = no such process (gone); EPERM = exists but owned by another user
        return e.code === "ESRCH";
      }
    })();
    return processGone || (Date.now() - ts > staleMs);
  } catch {
    // Owner file missing or corrupt (e.g. killed between mkdirSync and writeFileSync).
    // Fall back to the lock directory's mtime as a reliable staleness signal.
    try {
      const stats = statSync(dirname(ownerFile));
      return (Date.now() - stats.mtimeMs) > staleMs;
    } catch {
      return false;
    }
  }
}

/**
 * Release the init lock if and only if we still own it (PID match).
 * Prevents a finally-block from removing another process's lock after a
 * stale takeover.
 *
 * @param {string} lockDir
 * @param {string} ownerFile
 */
function _releaseInitLock(lockDir, ownerFile) {
  try {
    const { pid } = JSON.parse(readFileSync(ownerFile, "utf-8"));
    if (pid !== process.pid) return;
    try { unlinkSync(ownerFile); } catch { /* race */ }
    try { rmdirSync(lockDir); } catch { /* race */ }
  } catch { /* lock dir already gone */ }
}

/**
 * Backfill cost for historical rows where cost=0 but tokens exist.
 * Uses SQL CASE expressions matching the JS pricing table to avoid
 * round-tripping each row through JS. Runs in a single UPDATE statement.
 * Idempotent — only updates rows where cost=0 AND tokens_total>0.
 */
function backfillCosts() {
  // Build SQL CASE expression from the pricing table
  const cases = Object.entries(MODEL_PRICING).map(([key, p]) =>
    `WHEN lower(model_id) LIKE '%${key}%' THEN ` +
    `(tokens_input * ${p.input} + (tokens_output + tokens_reasoning) * ${p.output} ` +
    `+ tokens_cache_read * ${p.cacheRead} + tokens_cache_write * ${p.cacheWrite}) / 1000000.0`
  ).join("\n    ");

  const sql = `
UPDATE llm_requests
SET cost = CASE
    ${cases}
    ELSE (tokens_input * ${DEFAULT_PRICING.input} + (tokens_output + tokens_reasoning) * ${DEFAULT_PRICING.output}
      + tokens_cache_read * ${DEFAULT_PRICING.cacheRead} + tokens_cache_write * ${DEFAULT_PRICING.cacheWrite}) / 1000000.0
  END
WHERE cost = 0.0 AND tokens_total > 0;
`;

  // Combine UPDATE and SELECT changes() in a single sqliteExecSync call so
  // they run on the same sqlite3 connection — a separate call returns 0.
  const countRaw = sqliteExecSync(`${sql}\nSELECT changes();`, 30000);
  const count = countRaw?.split("\n").pop() ?? "0";
  if (parseInt(count, 10) > 0) {
    console.error(`[aidevops] Observability: backfilled cost for ${count} rows`);

    // Rebuild session_summaries from the corrected data.
    // Compute total_errors from actual error columns instead of hardcoding 0.
    sqliteExecSync(`
DELETE FROM session_summaries;
INSERT INTO session_summaries (session_id, first_seen, last_seen, request_count,
  total_tokens_input, total_tokens_output, total_cost, total_tool_calls, total_errors,
  project_path, models_used)
SELECT session_id, MIN(timestamp), MAX(timestamp), COUNT(*),
  SUM(tokens_input), SUM(tokens_output), SUM(cost), MAX(tool_call_count),
  SUM(CASE WHEN error_type IS NOT NULL OR error_message IS NOT NULL THEN 1 ELSE 0 END),
  MAX(project_path), GROUP_CONCAT(DISTINCT model_id)
FROM llm_requests
GROUP BY session_id;
`, 30000);
    console.error("[aidevops] Observability: rebuilt session_summaries with corrected costs");
  }
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
    // Shut down the persistent sqlite3 process on exit
    process.on("exit", _shutdownSqlite);
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

  // Calculate cost from tokens — OpenCode does not provide msg.cost
  const cost = calculateCost(msg.tokens, msg.modelID);

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
    ${cost},
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
  updateSessionSummary(msg, cost, toolCallCount);
}

/**
 * Update the session_summaries table with aggregated data.
 * Uses INSERT OR REPLACE with accumulated values.
 *
 * @param {object} msg - Assistant message
 * @param {number} cost - Pre-calculated cost for this request
 * @param {number} toolCallCount - Current tool call count for session
 */
function updateSessionSummary(msg, cost, toolCallCount) {
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
  ${cost},
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
  total_cost = total_cost + ${cost},
  total_tool_calls = ${toolCallCount},
  total_errors = total_errors + ${hasError},
  models_used = CASE
    WHEN instr(',' || models_used || ',', ',' || ${sqlEscape(msg.modelID || "")} || ',') = 0
    THEN models_used || ',' || ${sqlEscape(msg.modelID || "")}
    ELSE models_used
  END;
`;

  sqliteExec(sql);
}

/**
 * Build the INSERT SQL for a tool_calls row. Pure function — no DB access,
 * no global state — so it is exhaustively testable without sqlite3.
 *
 * Column order must stay aligned with the `tool_calls` CREATE TABLE in
 * initDatabase(). If you add or reorder columns there, update this
 * builder and its test suite (test-observability-tool-calls.mjs) in the
 * same commit.
 *
 * @param {object} args
 * @param {string} args.sessionID
 * @param {string} args.callID
 * @param {string} args.toolName
 * @param {string | null | undefined} args.intent
 * @param {0 | 1} args.isSuccess
 * @param {number | null | undefined} args.durationMs - Elapsed ms, or null/undefined to store SQL NULL
 * @param {object | null | undefined} args.metadata - Raw metadata object; JSON-stringified before escape
 * @returns {string} INSERT statement ready for sqliteExec
 */
export function buildToolCallInsertSql({ sessionID, callID, toolName, intent, isSuccess, durationMs, metadata }) {
  const durationSql = (durationMs !== null && durationMs !== undefined)
    ? String(durationMs)
    : "NULL";
  // sqlEscape(null) returns the literal string "NULL" — we exploit that
  // so the metadata column renders as SQL NULL when metadata is absent.
  const metadataValue = (metadata !== null && metadata !== undefined)
    ? JSON.stringify(metadata)
    : null;

  return `INSERT INTO tool_calls (
    session_id, call_id, tool_name, intent, success, duration_ms, metadata
  ) VALUES (
    ${sqlEscape(sessionID)},
    ${sqlEscape(callID)},
    ${sqlEscape(toolName)},
    ${sqlEscape(intent || null)},
    ${isSuccess},
    ${durationSql},
    ${sqlEscape(metadataValue)}
  );`;
}

/**
 * Record a tool call from the tool.execute.after hook.
 * Increments the in-memory counter and writes to the tool_calls table.
 *
 * @param {object} input - { tool, sessionID, callID, args }
 * @param {object} output - { title, output, metadata }
 * @param {string | undefined} intent - LLM-provided intent string (from agent__intent field)
 * @param {number | null | undefined} [durationMs] - Elapsed milliseconds from tool.execute.before (t2184)
 */
export function recordToolCall(input, output, intent, durationMs) {
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

  // Prune old sessions to prevent unbounded memory growth
  if (sessionToolCounts.size > 1000) {
    const keys = Array.from(sessionToolCounts.keys());
    for (const k of keys.slice(0, 500)) {
      sessionToolCounts.delete(k);
    }
  }

  // Determine success from output (heuristic: no error indicators)
  const outputText = output.output || "";
  const isSuccess = !outputText.includes("error") &&
    !outputText.includes("FAILED") &&
    !outputText.includes("Error:") ? 1 : 0;

  const sql = buildToolCallInsertSql({
    sessionID,
    callID,
    toolName,
    intent,
    isSuccess,
    durationMs,
    metadata: output?.metadata,
  });

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
