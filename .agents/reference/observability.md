<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Observability

aidevops observes the opencode runtime through three complementary layers.
Each is independently useful; together they cover cost tracking, execution
forensics, and mid-session self-diagnosis.

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

The plugin also enriches each active tool span with aidevops attributes
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

See "Self-diagnosis" below.

## Running a local OTLP collector

Any OTLP HTTP sink works. Interim options:

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

When a worker appears stuck (token burn, repeated tool calls, silent hang),
the running session can inspect its own activity with
`session-introspect-helper.sh`. Works offline, reads local SQLite only.

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

The helper does not kill the session — it exposes the data the running
session (or a watching operator) can use to course-correct.

## Verifying the OTEL integration

After pointing opencode at a collector and restarting:

1. Run any tool call in opencode (e.g. `ls`).
2. Check the collector received an `opencode.tool.*` span.
3. Expand the span's attributes — you should see both opencode-native
   keys (`session.id`, `message.id`) and aidevops-specific keys
   (`aidevops.intent`, `aidevops.task_id`, …).

If aidevops attributes are missing:

- Verify the plugin loaded: `AIDEVOPS_PLUGIN_DEBUG=1 opencode run ...`
  should emit `[aidevops]` startup lines.
- Verify `@opentelemetry/api` is resolvable from the plugin's load path
  (opencode bundles it as a transitive dependency).
- The enrichment path fails silent by design — a plugin error never
  breaks tool execution — so check opencode's stderr for SDK warnings
  if attributes aren't appearing despite the plugin being active.

## Relationship to other observability tooling

- `observability-helper.sh cache-health` — prompt cache hit rate per model
- `observability-helper.sh rate-limits` — provider quota telemetry
- `session-miner` routine — post-hoc mining of successful/failed sessions
  into the shared memory (SQLite FTS5). Different layer: session-miner
  extracts *lessons* across sessions; OTEL captures per-call *traces*
  within a session; session-introspect gives the *running* session a
  read-through to its own plugin SQLite data.
