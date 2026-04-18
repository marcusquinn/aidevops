# t2184: fix(observability): capture duration_ms + metadata in tool_calls INSERT

ref: GH#19648
origin: interactive (opencode, maintainer session)
parent: t2177 (PR #19635) / t2181 (PR #19644)

## What

Fix two observability gaps in `recordToolCall` at
`.agents/plugins/opencode-aidevops/observability.mjs:503-546`:

1. **`duration_ms` never captured.** The column exists in the `tool_calls`
   schema (line 204) and was added in the t1308 migration, but the INSERT
   statement at line 534-543 omits it. The plugin has no concept of
   tool-start time — `recordToolCall` fires from `tool.execute.after` with
   no paired `tool.execute.before` timestamp.
2. **`metadata` hard-coded to SQL `NULL`.** Line 542 emits literal
   `NULL` instead of using the `output.metadata` object that the caller
   already passes in. `output.metadata` contains useful per-tool context
   (`filePath` for Write/Edit, `task_id` for sub-agent `task` calls,
   sometimes `pattern_id` / `dispatch_kind` for observability helpers).

Evidence (verified against live DB `~/.aidevops/.agent-workspace/observability/llm-requests.db`,
538,212 rows over 56 days):

- `SELECT COUNT(*) FROM tool_calls WHERE duration_ms IS NOT NULL` → **0**
- `SELECT COUNT(*) FROM tool_calls WHERE metadata IS NOT NULL` → **0**

## Why

- `duration_ms` is the primary signal for `session-introspect-helper.sh`
  stuck-tool diagnosis and aggregate cost-per-tool analysis. Without it,
  the SQLite DB is a token-count log, not an observability DB.
- `metadata` is how a post-hoc audit ("which file did Write modify in
  session X at timestamp Y?") answers without replaying the transcript.
- Both were declared in the schema specifically to be populated, and
  neither ever has been. This is not a new feature — it's a shipped
  regression since t1308 (2026-02-22).

Self-caught during t2177 follow-up: `session-introspect-helper.sh`
depends on `duration_ms` to surface "last tool still running >60s".
Helper works in unit tests against synthetic rows; returns nothing
useful in live sessions because every row's `duration_ms IS NULL`.

## How

### 1. NEW `timing-tracing.mjs` (mirror `intent-tracing.mjs`)

Per-callID `Map<string, number>` storing start timestamps. Two exports:

- `recordToolStart(callID)` — stores `Date.now()` keyed by callID.
  Called from `handleToolBefore`.
- `consumeToolDuration(callID)` — returns `Date.now() - stored` or
  `null` if the callID is unknown or empty. Deletes the entry. Called
  from `handleToolAfter`.

Same LRU pattern as `intent-tracing.mjs`: prune to 2500 entries when
size exceeds 5000.

### 2. EDIT `quality-hooks.mjs`

- Line 11: add `import { recordToolStart, consumeToolDuration } from "./timing-tracing.mjs";`
- In `handleToolBefore` (after the intent block, line 159-163):
  `if (callID) recordToolStart(callID);`
- In `handleToolAfter` (line 211-212):
  - Add: `const durationMs = consumeToolDuration(input.callID || "");`
  - Change: `recordToolCall(input, output, intent, durationMs);`

### 3. EDIT `observability.mjs::recordToolCall`

- Change signature to `recordToolCall(input, output, intent, durationMs)`
- Extract pure SQL builder `buildToolCallInsertSql(sessionID, callID, toolName, intent, isSuccess, durationMs, metadata)` for testability (no sqlite dependency).
- Fix the INSERT:
  - Add `duration_ms` to the column list between `success` and `metadata`.
  - Use `${durationMs !== null && durationMs !== undefined ? durationMs : "NULL"}` pattern (mirrors the existing llm_requests INSERT at line 431).
  - Replace hard-coded `NULL` for metadata with `${sqlEscape(output.metadata ? JSON.stringify(output.metadata) : null)}`.
  - `sqlEscape(null)` already returns the literal string `"NULL"` (see `observability-sqlite.mjs:151`), so passing null through the escape is safe.

### 4. Tests

- NEW `tests/test-timing-tracing.mjs` — `node:test` suite. Covers:
  1. Record then consume returns a non-negative integer.
  2. Consume twice for the same callID: second call returns null.
  3. Consume for unknown callID returns null.
  4. Empty callID returns null (guard).
  5. LRU prune triggers when size exceeds 5000 and keeps the newer 2500.

- NEW `tests/test-observability-tool-calls.mjs` — `node:test` suite on
  the pure `buildToolCallInsertSql` builder. Covers:
  1. With durationMs and metadata → SQL contains both columns populated.
  2. With durationMs=null → SQL contains literal `NULL` (unquoted) for the duration column.
  3. With undefined metadata → SQL contains literal `NULL` for metadata.
  4. With metadata object → SQL contains JSON-stringified, SQL-escaped string.
  5. SQL shape: column list has 7 names matching 7 value slots (schema alignment regression guard).

### Files

- NEW: `.agents/plugins/opencode-aidevops/timing-tracing.mjs`
- NEW: `.agents/plugins/opencode-aidevops/tests/test-timing-tracing.mjs`
- NEW: `.agents/plugins/opencode-aidevops/tests/test-observability-tool-calls.mjs`
- EDIT: `.agents/plugins/opencode-aidevops/quality-hooks.mjs` (3 lines)
- EDIT: `.agents/plugins/opencode-aidevops/observability.mjs` (extract builder + expand INSERT)

## Acceptance

1. All new test assertions pass under `node --test .agents/plugins/opencode-aidevops/tests/`.
2. After deploy + one tool call, `SELECT duration_ms, metadata FROM tool_calls ORDER BY id DESC LIMIT 1` returns non-null values.
3. Existing `test-otel-enrichment.mjs` suite remains green (20 assertions).
4. `test-session-introspect.sh` remains green.

## Verification

```bash
node --test .agents/plugins/opencode-aidevops/tests/
.agents/scripts/tests/test-session-introspect.sh
```

Post-merge + deploy verification (Phase C):

```bash
sqlite3 -header -column ~/.aidevops/.agent-workspace/observability/llm-requests.db \
  "SELECT timestamp, tool_name, duration_ms, length(metadata) AS meta_len \
   FROM tool_calls ORDER BY id DESC LIMIT 10"
```

## Risk

Low. The edit adds a new module that is pure data-flow, wires it into two
existing hook call sites, and changes one SQL statement. No existing
behavior regresses: `durationMs=null` renders as SQL `NULL` (same as
today's every-row behavior for that column); `metadata` currently stores
SQL `NULL` for every row — any non-null value is a strict improvement.

Worst-case failure of the timing Map (e.g., a callID is never consumed):
one Map entry leaks per orphan until the 5000-entry LRU trim, which is
bounded and identical to the existing `intent-tracing.mjs` behavior.

## Tier: simple

Tier checklist:

- [x] **2 or fewer files modified?** 2 edits (observability.mjs, quality-hooks.mjs) + 3 new files (timing-tracing.mjs, 2 tests). New files don't count against the edit budget.
- [x] **Every target file under 500 lines?** observability.mjs is 562 — at the borderline, but all edits are local to one function and one insert statement, with verbatim old/new blocks provided.
- [x] **Exact oldString/newString?** Yes, all inline above.
- [x] **No judgment or design decisions?** The pattern is "mirror intent-tracing.mjs"; no API design.
- [x] **No error handling to design?** `sqlEscape` already handles null/undefined.
- [x] **No cross-package changes?** One plugin package.
- [x] **Estimate ≤1h?** ~45m (writing + tests + verify).
- [x] **≤4 acceptance criteria?** 4.

All checked → `tier:simple`.

**Selected tier:** `tier:simple`

**Tier rationale:** Small, additive, copy-paste pattern from intent-tracing.mjs.
One file slightly over 500 lines but the edit is a self-contained function body
with verbatim replacement blocks. No novel logic.
