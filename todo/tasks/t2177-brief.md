<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2177: OTEL span enrichment and session-introspect helper for self-diagnosis

## Origin

- **Created:** 2026-04-18
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** opencode dev tweeted about recent OTEL instrumentation work landing in v1.4.7+ (tool-span tracing, AI-SDK span export, Effect context threading) with traces shipped to a local TUI (kit's motel) exposing an agent-readable query endpoint. Discussion surfaced two actionable gaps in aidevops: (1) stuck-worker forensics today relies on text log spelunking even though our plugin already captures per-tool-call data in SQLite, and (2) opencode's active spans could carry aidevops-specific attributes (intent, task-id, session origin, runtime) essentially for free, making span trees self-labelling for anyone viewing them in motel/Jaeger/etc. Motel's query API is not yet public (tweet said "video soon"), so we skip the agent-query-endpoint piece until it's documented.

## What

Three small, independent deliverables:

1. **Session-introspect helper** — `session-introspect-helper.sh` — reads the existing observability SQLite DB (`~/.aidevops/.agent-workspace/observability/llm-requests.db`) and surfaces anti-patterns for the current session: recent tool calls with intents, per-tool frequency, file-reread loops (same file read >3 times), error clustering, token burn rate. Runs offline — no OTEL required.

2. **OTEL span enrichment** — opencode-aidevops plugin attaches aidevops-specific attributes to opencode's active tool span in `tool.execute.before`: `aidevops.intent` (the `agent__intent` field), `aidevops.tool_name`, `aidevops.task_id` (inferred from cwd or env), `aidevops.session_origin`, `aidevops.runtime`. No-op when `@opentelemetry/api` is unavailable or OTEL is not enabled — dynamic import with graceful fallback.

3. **OTEL env passthrough** — shell-env hook propagates `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, and `OTEL_SERVICE_NAME` to subprocesses spawned by opencode, so headless workers and helper scripts running under an instrumented session inherit the tracing config.

4. **Documentation** — `reference/observability.md` explains the three-layer model (SQLite plugin obs → OTEL emission → TUI sink) and how to point opencode at a local OTLP collector. `prompts/build.txt` gets a one-line stuck-detection hint pointing at the introspect helper.

## Why

- **Stuck-worker debugging is expensive today.** When a pulse worker burns tokens on a file-reread loop, the existing remedy is the external watchdog kill + post-hoc log reading. The SQLite DB already holds every tool call — we just haven't exposed it as an agent-callable self-diagnostic. One sql query + text output closes a real pain gap.
- **opencode's OTEL work is a one-way ratchet.** Upstream added tool-span tracing, AI-SDK span export, and context-manager registration in v1.4.7-v1.4.11 (commits 685d79e95, f73ff781e, 9640d889b, 6bed7d469, 23a2d0128). Plugin hooks already run inside opencode's active span via AsyncLocalStorage — adding attributes costs a one-line span call. The alternative (not enriching) leaves every aidevops span indistinguishable from a generic opencode span in whatever OTEL viewer the user runs.
- **Plugin SQLite and OTEL are complementary, not competing.** SQLite holds token/cost and aidevops intent — OTEL doesn't. OTEL holds parent/child span trees and AI-SDK internals — SQLite doesn't. Both layers win if we wire intent/task-id into OTEL attributes so they correlate.

## Tier

### Tier checklist

- [ ] 2 or fewer files to modify — NO (6-8 files touched)
- [x] Every target file under 500 lines
- [ ] Exact oldString/newString for every edit — partial (NEW files are exact; EDIT files are described)
- [x] No judgment or design decisions — mostly (attribute naming choices made in brief)
- [x] No error handling or fallback logic to design (graceful OTEL import failure is specified)
- [x] No cross-package changes
- [x] Estimate 1h or less — NO (~2h with tests)
- [x] 4 or fewer acceptance criteria — 6 below

**Selected tier:** `tier:standard`

**Tier rationale:** Multiple files across the plugin, helper scripts, and docs. No exotic design — all patterns exist (dynamic import, SQLite helper, shell script). Does not qualify for tier:simple due to file count and exploration required for the plugin hook point.

## PR Conventions

Leaf task — use `Resolves #NNN` in PR body.

## How (Approach)

### Files to Modify

- `NEW: .agents/plugins/opencode-aidevops/otel-enrichment.mjs` — dynamic-import wrapper around `@opentelemetry/api`; exports `enrichActiveSpan(attrs)` that is a no-op when the API is unavailable.
- `EDIT: .agents/plugins/opencode-aidevops/quality-hooks.mjs` — in `handleToolBefore`, after intent extraction, call `enrichActiveSpan(...)` with aidevops attributes.
- `EDIT: .agents/plugins/opencode-aidevops/shell-env.mjs` — add `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_SERVICE_NAME` passthrough.
- `NEW: .agents/scripts/session-introspect-helper.sh` — subcommands: `recent [N]`, `patterns`, `errors`, `sessions`, `help`. Model on `.agents/scripts/observability-helper.sh` structure (shared-constants sourcing, `cmd_*` functions, case dispatch).
- `NEW: .agents/scripts/tests/test-session-introspect.sh` — seeds a temp SQLite DB, runs each subcommand, asserts expected output.
- `NEW: .agents/reference/observability.md` — setup doc for OTEL sink + introspect helper.
- `EDIT: .agents/prompts/build.txt` — one-line hint in stuck-detection area.
- `EDIT: .agents/AGENTS.md` — reference observability.md once, near existing Capabilities/reference list.

### Implementation Steps

1. **`otel-enrichment.mjs`** — module with `enrichActiveSpan(attrs)`. Caches dynamic import result; if import fails, all calls become no-ops. Also exposes `otelEnabled()` for callers that want to skip building attribute payloads when disabled.

2. **`quality-hooks.mjs` edit** — in `handleToolBefore`, after `extractAndStoreIntent` returns an intent, call `enrichActiveSpan({ 'aidevops.intent': intent, 'aidevops.tool_name': input.tool, 'aidevops.task_id': detectTaskId(), 'aidevops.session_origin': process.env.OPENCODE_HEADLESS ? 'worker' : 'interactive', 'aidevops.runtime': 'opencode' })`. `detectTaskId()` reads `AIDEVOPS_TASK_ID` env var (set by full-loop-helper when dispatched) or parses the current worktree path (`~/Git/<repo>-<branch>` where branch contains a `tNNN` or `GH#NNN`).

3. **`shell-env.mjs` edit** — after existing env assignments, copy `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_SERVICE_NAME` from `process.env` into `output.env` when set.

4. **`session-introspect-helper.sh`** — bash 3.2-compatible. Sources `shared-constants.sh`. Subcommands:
   - `recent [N]` — last N tool calls for current session (most recent session_id in DB), columns: timestamp, tool_name, intent, duration_ms, success.
   - `patterns` — for current session: total calls, calls/min rate, per-tool count, file-reread detection (groups Read/Edit calls by `args.filePath` from `metadata`, flags >3), error rate.
   - `errors` — failed tool calls in current session with intent + error snippet.
   - `sessions [N]` — list recent N sessions with request count + cost + last-seen.
   - `help` — usage.
   Default `N` values: 20 for `recent`, 10 for `sessions`. Current-session detection: `SELECT session_id FROM tool_calls ORDER BY timestamp DESC LIMIT 1`. Override with `--session <id>` flag.

5. **Test** — creates temp DB at `$TMPDIR/introspect-test-$$`, inserts 25 fake tool_calls rows (mix of tools, 4 reads of the same file, 2 errors), runs each subcommand with `AIDEVOPS_INTROSPECT_DB` env var override, greps output for expected strings.

6. **Docs** — `reference/observability.md` ~80 lines: three-layer model, env var setup, introspect examples, OTLP sink options (kit motel when available; Jaeger all-in-one in Docker as an interim).

### Verification

```bash
# 1. Shellcheck the new helper and test
shellcheck .agents/scripts/session-introspect-helper.sh .agents/scripts/tests/test-session-introspect.sh

# 2. Run the test harness
.agents/scripts/tests/test-session-introspect.sh

# 3. Lint markdown
markdownlint-cli2 .agents/reference/observability.md todo/tasks/t2177-brief.md

# 4. Syntax-check the plugin changes
node --check .agents/plugins/opencode-aidevops/otel-enrichment.mjs
node --check .agents/plugins/opencode-aidevops/quality-hooks.mjs
node --check .agents/plugins/opencode-aidevops/shell-env.mjs

# 5. Live smoke test — introspect against current session
.agents/scripts/session-introspect-helper.sh recent 5
.agents/scripts/session-introspect-helper.sh patterns
```

## Acceptance Criteria

- [ ] `session-introspect-helper.sh recent|patterns|errors|sessions` all produce expected output against live SQLite
- [ ] OTEL enrichment is a no-op when `@opentelemetry/api` is not installed (plugin still loads, no errors in stderr)
- [ ] Shell-env passthrough verified: `env | grep OTEL` in a new bash spawned from opencode shows the parent env
- [ ] All shellcheck + markdownlint + node --check pass
- [ ] Test harness exits 0
- [ ] Documentation cross-references resolve (build.txt mention → reference/observability.md → introspect helper path)
