# t2187: investigate(otel): opencode v1.4.11 `run` mode does not emit per-tool-call Tool.execute/Bash spans

## Session origin

Empirical observation from the t2184/t2186 session (2026-04-18). While verifying the `headless-runtime-helper.sh run` OTEL passthrough fix against Jaeger, we confirmed opencode v1.4.11 emits 200+ outer orchestration spans per session — but never emits per-tool-call `Tool.execute` / `Bash` spans in `run` mode.

## What

Document — and decide how to close — the gap between what the aidevops opencode plugin's OTEL enrichment expects (an active `Tool.execute` span to attach `aidevops.intent`, `aidevops.task_id`, `aidevops.session_origin`, `aidevops.runtime` to) and what opencode v1.4.11 actually emits in `run` mode.

## Why

The plugin's `enrichActiveSpan` helper does a dynamic import of `@opentelemetry/api` and calls `trace.getActiveSpan()` inside `tool.execute.before` / `tool.execute.after`. When opencode doesn't register a span for the tool call, `getActiveSpan()` returns `undefined` and the plugin silently no-ops.

Consequence: the framework's primary audit-trail join key — `aidevops.task_id` → TODO.md — is invisible on every tool call in headless `run` mode, even with the t2186 OTEL passthrough fix in place. The plugin records the call in its own SQLite (`~/.aidevops/plugin-data/opencode-aidevops.db`, `tool_calls` table), but OTEL-side observability is effectively empty of per-tool context.

Distribution:
- Outer orchestration spans (`Config.*`, `FileSystem.*`, `Session.*`, `ToolRegistry.*`, `Auth.*`, `SessionPrompt.*`, `Git.*`, etc.) — **emitted correctly** in `run` mode. Verified 2026-04-18: 108 unique operations over 18 traces, 471 spans.
- Per-tool-call `Tool.execute` / `Bash` / `Read` / `Edit` / `Write` / `Grep` spans — **NOT emitted** in `run` mode. String search on the darwin-arm64 binary confirms the names exist in the compiled code, so this is code-path specific (`run` vs TUI vs server), not missing instrumentation entirely.

## How (research — files TBD)

This is a research-phase task. The implementation files cannot be pinned down until step 1 below resolves. Three possible outcomes, each with different file surface:

1. **Survey opencode v1.4.11 source** (`~/.opencode/sdk/*` or fetch from opencode repo) to locate the `Tool.execute` instrumentation call site. Determine whether the gap is:
   - (a) Deliberate: `run` mode intentionally skips per-tool spans (e.g., for log noise reduction). Action: document as known limitation, add a `reference/opencode-otel-limitations.md` note, close.
   - (b) A bug: `run` mode misses a `tracer.startActiveSpan` wrapper that TUI/server have. Action: contribute upstream PR to opencode; pin our plugin compatibility to versions post-fix.
   - (c) Conditional on an env var / config flag. Action: set the flag in `headless-runtime-lib.sh`'s passthrough block and verify.

2. **If (a) or (b)**: consider whether aidevops plugin should self-create spans when opencode hasn't (i.e., the plugin wraps its own tracer around the hook callback instead of relying on opencode's active span). Trade-off: plugin-owned spans would not nest inside opencode's outer Session/Config trace tree — they'd appear as orphan traces under service `opencode-aidevops`. Decide whether the loss of hierarchy is acceptable vs the benefit of universal enrichment.

3. **Contingency**: if opencode has server mode (`opencode serve`), verify whether `Tool.execute` spans DO appear there. If yes, document the `run` vs `serve` trade-off.

## Acceptance criteria

- [ ] Root cause identified and documented: is this (a) deliberate, (b) bug, or (c) config-gated?
- [ ] `reference/observability.md` updated with a "known limitations in run mode" section
- [ ] If (b) — upstream issue / PR filed against opencode with repro
- [ ] Decision recorded on plugin-owned spans vs status quo

## Context

- Predecessor: t2186 (PR #19659, merged) — OTEL sandbox passthrough fix
- Related: t2177 (PR #19635) — plugin OTEL enrichment module that this limitation renders partially ineffective
- Evidence captured in memory: `mem_20260418065018_f479789e` (high confidence)

## Tier

**`tier:standard`** — research + decision task. Not Haiku (no surgical edit known in advance; judgement call on which of the three outcomes to pursue). Not `tier:thinking` (the architectural pattern is well-known — wrap/don't-wrap, file-upstream/document — no novel reasoning required). Do NOT `#auto-dispatch` until step 1 resolves into an actionable file set.

## PR conventions

This is a leaf task, not a parent. When implementation PR(s) open, body uses `Resolves #<this-issue-number>`.
