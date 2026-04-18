<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Observability

Three complementary layers — cost tracking, execution forensics, and mid-session self-diagnosis. Each is independently useful; together they cover full agent activity.

## Layers

### 1. Plugin SQLite (always on)

The opencode-aidevops plugin captures every LLM request and tool call to
`~/.aidevops/.agent-workspace/observability/llm-requests.db`.

Tables:

- `llm_requests` — per-message tokens, cost, model, duration, finish reason
- `tool_calls` — per-tool call session_id, tool_name, intent (from the
  `agent__intent` field), duration_ms, success, metadata JSON
- `session_summaries` — aggregate totals keyed by session_id

Query with `.agents/scripts/observability-helper.sh` (cost dashboards,
rate-limit telemetry, cache health). No configuration required — the
plugin auto-creates the DB on first tool call.

### 2. OpenTelemetry spans (opt-in, opencode v1.4.7+)

opencode emits OTLP spans for AI SDK calls, tool execution, and server
routes. Activated by pointing the runtime at a local collector:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
# Optional auth for hosted sinks:
export OTEL_EXPORTER_OTLP_HEADERS="x-token=..."
```

The opencode-aidevops plugin shell-env hook forwards these variables to
every subprocess opencode spawns — headless workers and helper scripts
inherit the trace endpoint without per-script plumbing.

The plugin enriches each active tool span with aidevops attributes
via `@opentelemetry/api` (dynamic import, no-op when absent):

| Attribute                   | Value                                    |
|-----------------------------|------------------------------------------|
| `aidevops.intent`           | The `agent__intent` string for the call  |
| `aidevops.tool_name`        | Tool name (Read, Edit, Bash, …)          |
| `aidevops.task_id`          | `tNNN` / `GH#NNN` detected from cwd/env  |
| `aidevops.session_origin`   | `worker` or `interactive`                |
| `aidevops.runtime`          | `opencode`                               |

Namespace `aidevops.*` avoids collision with OpenTelemetry's standard
semantic conventions (which opencode already populates as `session.id`,
`message.id`, etc.).

### 3. Session introspect (offline self-diagnosis)

`session-introspect-helper.sh` reads the plugin SQLite directly — no OTEL
required — and surfaces stuck-worker anti-patterns for the current session.

## Running a local OTLP collector

Any OTLP HTTP sink works:

- **kit motel** — the dedicated opencode/aidevops OTel TUI, still maturing
  (tweeted preview 2026-04). Check the opencode repo for install docs when
  the video/release lands.
- **Jaeger all-in-one** — one-line Docker run, web UI at localhost:16686:

  ```bash
  docker run --rm --name jaeger \
    -p 4318:4318 -p 16686:16686 \
    jaegertracing/all-in-one:latest
  ```

- **OpenTelemetry Collector** — for forwarding to Grafana Tempo, Honeycomb,
  Datadog, or any OTLP-compatible destination.

Point opencode at whichever collector via the env var above and restart
the session. No further aidevops configuration is needed.

## Self-diagnosis

`session-introspect-helper.sh` diagnoses stuck workers offline — reads local
SQLite, no OTEL required:

```bash
# What have I been doing?
session-introspect-helper.sh recent 30

# Am I in a file-reread loop?
session-introspect-helper.sh patterns

# What errors have I hit?
session-introspect-helper.sh errors

# Recent sessions with cost summary
session-introspect-helper.sh sessions 5
```

The `patterns` subcommand flags files read/edited more than 3× in the
current session — a common stuck-worker signature when file comprehension
isn't landing. When this fires, break out of the loop: `git diff`,
`git status`, or step back to re-read the brief.

Stuck-worker thresholds (informational):

| Signal                  | Value         | Interpretation                      |
|-------------------------|---------------|-------------------------------------|
| Calls/minute            | > 30          | Excessive tool chatter              |
| Same file read          | > 3× / session| Re-read loop                         |
| Consecutive errors      | 3+ on same tool | Not learning from feedback        |

The helper exposes data for course-correction; it does not kill the session.

## Known limitation: `run` mode does not emit per-tool OTEL spans (t2187)

**Verified against:** opencode v1.4.11 (Bun-compiled), Jaeger all-in-one,
2026-04-18. 471 spans / 108 unique operations observed; zero `Tool.execute`
spans among them.

**What works in `run` mode:** outer orchestration spans — `Config.*`,
`FileSystem.*`, `Session.*`, `ToolRegistry.*`, `Auth.*`, `SessionPrompt.*`,
`Git.*`, `Npm.*`, `Bus.*`. These confirm the `@effect/opentelemetry` bridge
and `OTLPTraceExporter` are active.

**What is missing:** per-tool-call `Tool.execute` spans. The span IS
declared in opencode source at `packages/opencode/src/tool/tool.ts` —
every tool is wrapped via
`.pipe(Effect.orDie, Effect.withSpan("Tool.execute", { attributes: attrs }))`.
It simply does not appear in the OTEL export in `run` mode.

**What is NOT the cause** (falsified against `anomalyco/opencode` source on
2026-04-18 as part of t2212):

- NOT an `AsyncLocalStorageContextManager` gap. `packages/opencode/src/effect/observability.ts`
  explicitly installs one via `context.setGlobalContextManager(mgr)` with
  an in-source comment stating the intent is "so non-Effect code (like
  the AI SDK) that calls `tracer.startActiveSpan()` relies on
  `context.active()` to find the parent span" — opencode ships with
  the fix for the exact bridging mechanism earlier drafts of this doc
  blamed. (PR #19677 had already corrected the `Effect.promise` →
  `Effect.runPromise` terminology; t2212 retires the underlying
  attribution that `runPromise` was still somehow the culprit.)
- NOT a Promise-boundary issue. The tool invocation path in
  `packages/opencode/src/session/prompt.ts::resolveTools()` uses
  `run.promise(Effect.gen(...))` where `run` comes from
  `EffectBridge.make()` in `packages/opencode/src/effect/bridge.ts`.
  The bridge's `promise` calls `Effect.runPromise(wrap(effect))` with
  `wrap = attach(effect).pipe(Effect.provide(ctx))` — the outer Effect
  context (including the tracer layer) IS provided to the inner effect.
  Empirical counter-evidence observable in the local Jaeger: `Plugin.trigger`,
  `Plugin.list`, `Plugin.init`, and `Plugin.state` spans ALL appear and
  go through the same bridge as `Tool.execute`. If the bridge were the
  root cause, they would all be missing — they are not.

**What IS the cause:** not yet identified. Candidate hypotheses for
future investigation: (a) the `Effect.withSpan("Tool.execute")`
attach point interacts specifically with `Effect.orDie` and the AI
SDK's `tool({ execute })` Promise contract in a way plugin-trigger
spans do not; (b) the Tool.execute span lifetime ends before OTEL's
`BatchSpanProcessor` flushes because the AI SDK moves on without
awaiting span completion; (c) a tracer-layer lookup difference
between how `Effect.withSpan` resolves inside the tool-level Effect
vs the plugin-level Effect. These are specific enough to be testable
by someone reading opencode internals; they are not specific enough
to edit today.

**Classification:** architectural consequence (outcome (a) from the
t2187 brief). Not a config flag to toggle, not a simple bug — it is
a structural gap in how `run` mode integrates with the AI SDK's
tool interface.

**Impact on aidevops plugin:** the plugin's `enrichActiveSpan()` in
`otel-enrichment.mjs` calls `trace.getActiveSpan()` inside
`tool.execute.before` / `tool.execute.after` hooks. When opencode
does not create a `Tool.execute` span, `getActiveSpan()` returns
`undefined` and the enrichment silently no-ops. The `aidevops.*`
attributes (`intent`, `task_id`, `session_origin`, `runtime`) are
therefore invisible in OTEL traces for headless `run` mode sessions.
Plugin-side SQLite (`tool_calls` table) is unaffected — it records
independently of OTEL.

**Decision on plugin-owned fallback spans:** creating plugin-owned
spans when opencode does not provide one would produce orphan traces
under a separate service name (`opencode-aidevops`), disconnected
from the Session/Config trace tree. The cost of implementation is low
but the value is marginal — orphan spans without parent context are
hard to correlate in Jaeger/Tempo and do not meaningfully improve the
audit trail over what plugin SQLite already provides. **Status quo
accepted**: rely on plugin SQLite for per-tool observability in `run`
mode. Re-evaluate if opencode fixes the span gap upstream or if a
future version exposes a tracer handle to plugins.

**Upstream status:** the active opencode upstream is `anomalyco/opencode`
(not archived, default branch `dev`, Bun-compiled TypeScript, public
issue tracker active, verified 2026-04-18 via `gh api`). A separate,
legacy Go codebase exists at `opencode-ai/opencode` (archived, last
push 2025-09-18) — that is NOT the same project as the v1.4.x
Bun-compiled TypeScript binary users actually run. The span gap may
be resolved in a future `anomalyco/opencode` release if a contributor lands
an explicit span-export in the tool execution path or the AI SDK
switches to a span-preserving execution model. File OTEL-related
issues at `https://github.com/anomalyco/opencode/issues`; monitor release
notes there for changes.

## Verifying the OTEL integration

After pointing opencode at a collector and restarting:

1. Run any tool call in opencode (e.g. `ls`).
2. Check the collector received spans (look for `Config.*`,
   `Session.*`, `ToolRegistry.*` — these confirm the bridge works).
3. Expand a span's attributes — verify opencode-native keys
   (`session.id`, `message.id`) are present.
4. Check for `aidevops.*` attributes. **In TUI/server mode**, these
   should appear on `Tool.execute` spans. **In `run` mode**, they
   will be absent due to the known limitation above — verify via
   plugin SQLite instead (`session-introspect-helper.sh recent 10`).

If aidevops attributes are missing in a mode where they should work:

- Verify the plugin loaded: `AIDEVOPS_PLUGIN_DEBUG=1 opencode run ...`
  should emit `[aidevops]` startup lines.
- Verify `@opentelemetry/api` is resolvable from the plugin's load path
  (opencode bundles it as a transitive dependency).
- The enrichment path fails silent by design — a plugin error never
  breaks tool execution. Check opencode's stderr for SDK warnings.

## Relationship to other observability tooling

- `observability-helper.sh cache-health` — prompt cache hit rate per model
- `observability-helper.sh rate-limits` — provider quota telemetry
- `session-miner` routine — post-hoc mining of successful/failed sessions
  into the shared memory (SQLite FTS5). Different layer: session-miner
  extracts *lessons* across sessions; OTEL captures per-call *traces*
  within a session; session-introspect gives the *running* session a
  read-through to its own plugin SQLite data.
