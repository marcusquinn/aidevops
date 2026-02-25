---
mode: subagent
---
# t1306: OpenCode upstream — proof-of-concept PR for stream hooks

## Origin

- **Created:** 2026-02-22
- **Session:** claude-code (interactive)
- **Created by:** ai-supervisor (auto-dispatch from p030 harness plan)
- **Parent task:** t1302 (Harness engineering: oh-my-pi learnings)
- **Conversation context:** Analysis of oh-my-pi's TTSR (Time-To-Stream Rules) pattern revealed OpenCode lacks plugin hooks for real-time stream observation. t1305 opened the upstream issue; this task implements the proof-of-concept PR.

## What

Fork anomalyco/opencode and submit a PR implementing two new plugin hooks:

1. **`stream.delta`** — fires on `text-delta`, `reasoning-delta`, and `tool-input-delta` events during streaming. Plugins can set `output.abort = true` to cancel the stream.
2. **`stream.aborted`** — fires after abort. Plugins can set `output.retry = true` with optional `injectMessage` to retry with corrective context.

The PR must include type definitions in the plugin package, implementation in `processor.ts`, and tests.

## Why

Full TTSR (real-time stream policy enforcement) is blocked without stream-level plugin hooks. The existing `experimental.text.complete` hook only fires after generation completes — too late for real-time content filtering, pattern detection, or cost control. This is the highest-leverage upstream contribution from the p030 harness plan.

## How (Approach)

1. Fork from latest `anomalyco/opencode` dev branch (not stale clone — v1.2.7+ migrated from Bun.file() to Filesystem module)
2. Add `Plugin.trigger("stream.delta", ...)` calls in the three delta cases in `packages/opencode/src/session/processor.ts`
3. Add `StreamAbortedError` class for clean abort signaling
4. Add catch-block handling with retry logic (max 3 attempts) and optional message injection
5. Add type definitions to `packages/plugin/src/index.ts` (Hooks interface)
6. Add tests in `packages/opencode/test/session/stream-hooks.test.ts`

Key files:
- `packages/opencode/src/session/processor.ts` — streaming loop (two locations: reasoning and text delta handlers)
- `packages/plugin/src/index.ts:231` — Hooks interface extension
- `packages/opencode/test/session/stream-hooks.test.ts` — new test file

## Acceptance Criteria

- [x] `stream.delta` hook fires on text-delta, reasoning-delta, and tool-input-delta

  ```yaml
  verify:
    method: manual
    prompt: "Check upstream PR anomalyco/opencode#14741 diff for Plugin.trigger calls in all three delta cases"
  ```

- [x] `stream.aborted` hook fires after abort with retry capability

  ```yaml
  verify:
    method: manual
    prompt: "Check upstream PR anomalyco/opencode#14741 diff for StreamAbortedError catch block with retry logic"
  ```

- [x] Plugin type definitions added to Hooks interface

  ```yaml
  verify:
    method: manual
    prompt: "Check packages/plugin/src/index.ts diff for stream.delta and stream.aborted type definitions"
  ```

- [x] Tests pass (11 tests covering StreamAbortedError, hook shapes, retry loop)

  ```yaml
  verify:
    method: manual
    prompt: "Check upstream CI — all 9/9 checks pass including unit (linux) with stream-hooks tests"
  ```

- [x] All upstream CI checks pass

  ```yaml
  verify:
    method: manual
    prompt: "gh pr checks 14741 --repo anomalyco/opencode — all 9 checks SUCCESS"
  ```

- [x] PR references upstream issue from t1305

## Context & Decisions

- **v2 branch**: First attempt (`feature/stream-hooks`, PR #14701/#14727) was closed due to stale base. Rebased onto latest dev as `feature/stream-hooks-v2` (PR #14741).
- **AbortController vs custom error**: Chose `StreamAbortedError` custom error class over AbortController exposure — simpler, doesn't require plumbing AbortController through the plugin API.
- **Max retries = 3**: Hardcoded constant `STREAM_ABORT_MAX_RETRIES = 3` to prevent infinite retry loops.
- **Type assertions for tool-input-delta**: Used `(value as any).id` and `(value as any).delta` because the upstream SDK types don't expose these fields on tool-input-delta events yet.
- **Accumulated text tracking**: Added `toolInputAccumulated` record to track accumulated tool input per tool call ID, matching the pattern used for text and reasoning deltas.

## Relevant Files

- `packages/opencode/src/session/processor.ts` — main implementation (stream hooks + abort handling)
- `packages/plugin/src/index.ts` — type definitions for new hooks
- `packages/opencode/test/session/stream-hooks.test.ts` — 11 tests (new file)

## Dependencies

- **Blocked by:** t1305 (upstream issue — completed, anomalyco/opencode#14740)
- **Blocks:** Full TTSR implementation (real-time stream policy enforcement in aidevops OpenCode plugin)
- **External:** Upstream maintainer review and merge of anomalyco/opencode#14741

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Study processor.ts streaming architecture, v1.2.7 migration |
| Implementation | 2h | Hook calls, error class, retry logic, type definitions |
| Testing | 30m | 11 unit tests + CI verification |
| PR iteration | 30m | Rebase onto latest dev, address CI flakiness |
| **Total** | **4h** | |

## Completion Evidence

- **Upstream PR:** [anomalyco/opencode#14741](https://github.com/anomalyco/opencode/pull/14741) — OPEN, MERGEABLE, 9/9 CI checks pass
- **Upstream issue:** [anomalyco/opencode#14740](https://github.com/anomalyco/opencode/issues/14740) — OPEN
- **Changes:** 267 additions, 2 deletions across 3 files
- **Tests:** 11 new tests in `stream-hooks.test.ts` + all 120 existing session tests pass
