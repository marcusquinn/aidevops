<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2186: include `OTEL_*` env vars in headless sandbox passthrough

## Session origin

Interactive (OWNER). Direct follow-up from the t2184 (Phase C) observability
investigation: Jaeger was running and reachable on `:4318`, the opencode plugin
deployed and verified writing `duration_ms` / `metadata` to the local SQLite,
yet the `opencode` service never registered in Jaeger when the session was
spawned via `headless-runtime-helper.sh run` with OTEL env vars exported in
the parent shell. Root cause isolated to a missing allow-list entry.

## What

Extend the sandbox passthrough allow-list in
`.agents/scripts/headless-runtime-lib.sh` → `build_sandbox_passthrough_csv()`
so that env var names matching `OTEL_*` are forwarded to the sandboxed child
process spawned by `sandbox-exec-helper.sh run --passthrough ...`.

Add a regression test at
`.agents/scripts/tests/test-sandbox-passthrough-otel.sh` that invokes the
public `passthrough-csv` subcommand with a controlled env (via `env -i` to
neutralise caller state) and asserts:

1. `OTEL_EXPORTER_OTLP_ENDPOINT` is present in the CSV when set.
2. `OTEL_SERVICE_NAME` is present in the CSV when set.
3. `OTEL_TRACES_SAMPLER` is present in the CSV when set.
4. An unrelated var (`UNRELATED_FOO`) is NOT present (allow-list integrity).
5. A previously-covered prefix (`AIDEVOPS_*`) is still present (no regression).

## Why

Empirical evidence captured during Phase C of t2184:

- Direct `opencode run` with `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`
  exported, no sandbox involved: service `opencode` registered in Jaeger within
  seconds, trace + 200-span payloads arrived. Proven working.
- Same env, same Jaeger, but invoked via `headless-runtime-helper.sh run`
  (which uses `sandbox-exec-helper.sh run --passthrough "$passthrough_csv"`):
  zero traces. Service never registered. `jaeger-all-in-one` was the only
  entry in `/api/services`.

Inspection of `build_sandbox_passthrough_csv()` (line 767) showed the
allow-list covered `AIDEVOPS_*`, `PULSE_*`, `GH_*`, `GITHUB_*`, `OPENAI_*`,
`ANTHROPIC_*`, `GOOGLE_*`, `OPENCODE_*`, `CLAUDE_*`, `XDG_*`, `REAL_HOME`,
`TMPDIR`, `TMP`, `TEMP`, `RTK_*`, `VERIFY_*` — but **not `OTEL_*`**. Inside
the sandbox, opencode saw no OTEL env, never initialised its OTLP exporter
(the opencode binary ships the full `@opentelemetry` stack and activates on
env var presence; confirmed by `strings` inspection of the v1.4.11 binary),
and the plugin's `enrichActiveSpan` silently no-op'd because there was no
active tracer to attach to.

This fix closes the last remaining gap in the observability chain documented
by `reference/observability.md`: plugin SQLite (t2184) + OTEL propagation
for headless workers (t2186) = end-to-end visibility whether the worker
runs sandboxed or bare.

## How

- **EDIT**: `.agents/scripts/headless-runtime-lib.sh` — single-token add to
  the `case` pattern at line 767. Add `OTEL_*` between `XDG_*` and
  `REAL_HOME`. Add a short comment block explaining the rationale so future
  maintainers don't strip it "because it's not clearly related to the
  existing prefixes".
- **NEW**: `.agents/scripts/tests/test-sandbox-passthrough-otel.sh` — new
  test. Model on `.agents/scripts/tests/test-auto-dispatch-no-assign.sh`
  (sandbox/trap/pass-fail pattern). Uses `env -i PATH=$PATH HOME=$HOME` to
  start each invocation with a clean environment so assertions don't depend
  on ambient state.
- **Verification**:
  - `shellcheck .agents/scripts/headless-runtime-lib.sh`
  - `shellcheck .agents/scripts/tests/test-sandbox-passthrough-otel.sh`
  - `bash .agents/scripts/tests/test-sandbox-passthrough-otel.sh` → 5/5 pass
  - Regression proof: `git stash` the edit, re-run the test, confirm 3/5
    fail (OTEL assertions fail, allow-list + regression guards still pass).
    Restored the edit before commit.

## Acceptance criteria

- [x] `OTEL_*` added to allow-list in `build_sandbox_passthrough_csv()`.
- [x] Regression test added at
  `.agents/scripts/tests/test-sandbox-passthrough-otel.sh` (5 assertions).
- [x] Test passes (5/5) with the fix applied.
- [x] Test fails (3/5) without the fix — proves it guards the change.
- [x] ShellCheck clean on both touched files.
- [x] Allow-list integrity: an unrelated env var (`UNRELATED_FOO`) is still
      excluded from the CSV.
- [ ] Post-deploy verification: after `setup.sh --non-interactive`, invoke
      `headless-runtime-helper.sh run` with OTEL env set and confirm
      Jaeger receives traces from the sandboxed worker.

## Context

- **Direct predecessor**: t2184 (GH#19648, PR #19651 merged) — fixed
  `duration_ms` + `metadata` capture in the local SQLite.
- **Parent work**: t2177 (OTEL enrichment module, PR #19635 merged), t2181
  (regex fix, PR #19644 merged).
- **Upstream evidence**: opencode v1.4.11 binary strings show complete
  OpenTelemetry stack (`NodeTracerProvider`, `BatchSpanProcessor`,
  `OTLPTraceExporter`, `AsyncLocalStorageContextManager`) with default URL
  `http://localhost:4318/v1/traces` — activates on `OTEL_EXPORTER_OTLP_ENDPOINT`
  env var presence (confirmed via `strings` on `opencode-darwin-arm64/bin/opencode`).
- **Related upstream finding (separate issue)**: even with OTEL working,
  opencode v1.4.11 `run` mode does not appear to emit per-tool-call spans
  (`Tool.execute`, `Bash`). Binary contains the strings but the registered
  operations list from Jaeger shows only `Session.*`, `ToolRegistry.*`,
  `SessionPrompt.*`, filesystem, config — no tool execution spans. This is
  an upstream/documentation question about `opencode run` vs TUI/server
  mode and is out of scope for t2186. To be filed as a separate issue.

## Tier checklist

- [x] Brief has verbatim `oldString`/`newString` replacements? **Yes** — a
      single `case` pattern line.
- [x] Target file(s) under 500 lines without verbatim blocks? `headless-runtime-lib.sh`
      is ~2100 lines but the edit is exact-match.
- [x] Only 2 files touched? **Yes** — edit + new test.
- [x] Acceptance criteria count ≤ 4 actionable items before deployment? **Yes**.
- [x] No architecture/novel-design judgment calls? **Correct** — mechanical
      allow-list extension with matching test.

**Tier**: `tier:simple`. Haiku-eligible under the brief template rules, but
since this is an interactive session with OWNER author, the maintainer gate
auto-passes on `origin:interactive`.

## PR conventions

- Title: `t2186: fix(headless): include OTEL_* in sandbox passthrough for worker trace export`
- Body: `Resolves #<issue-number>` (leaf task, not parent).
- Origin label: `origin:interactive` (applied automatically by `gh_create_pr`
  wrapper; OWNER author auto-passes maintainer gate).
