# t2188: fix(observability): restore `agent__intent` capture by declaring it on every tool's input_schema

ref: GH#19649
origin: interactive (opencode, maintainer session)
parent: GH#19649 (three prior headless dispatches failed to produce a PR)

## What

Restore end-to-end capture of the `agent__intent` field in the `tool_calls`
observability table. The system-prompt instruction telling the LLM to
include `agent__intent` on every tool call has been in place since t1901,
but since direct Anthropic API transit landed (`provider-auth.mjs`,
`bc0802741`, 2026-03-20) the field has been silently stripped before
reaching the plugin's `tool.execute.before` hook. Daily intent coverage
collapsed from thousands of rows/day on OpenAI traffic (`call_*` IDs) to
**zero** on recent Anthropic traffic (`toolu_*` IDs).

The fix: inject `agent__intent` as an optional property on every tool's
`input_schema` at request-transform time in `provider-auth-request.mjs`.
The Anthropic Messages API validates tool arguments against each tool's
declared schema and strips unknown properties — including `agent__intent`
when undeclared. Declaring the property preserves the LLM's intent field
through to the plugin hook that records it.

## Why

`agent__intent` is the primary observability signal distinguishing
"why was this tool called" from "what tool was called". Without it:

- `session-introspect-helper.sh patterns` cannot cluster tool calls by
  intent (e.g. "20 Reads looking for auth code" vs "20 Reads on the
  same file in a loop").
- Post-hoc audits of stuck workers have no narrative — only tool names
  and arguments, no "what the LLM thought it was doing".
- The entire observability value proposition degrades to a token-count
  log, the same failure mode t2184 just fixed for `duration_ms` / `metadata`.

Evidence (live DB `~/.aidevops/.agent-workspace/observability/llm-requests.db`):

- March 12, all calls `call_*`: 6,037 rows, 6,017 with intent (99.7%).
- March 17, all calls `toolu_*`: 4,475 rows, **0** with intent.
- Recent sessions: 2,600+ calls/day, **0** with intent.
- Root cause confirmed by inspecting raw `part` rows in
  `~/.local/share/opencode/opencode-archive.db`: OpenAI arg JSON
  contains sibling `agent__intent`; Anthropic arg JSON does not.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify — `provider-auth-request.mjs` and a new test file.
- [x] Every target file under 500 lines — `provider-auth-request.mjs` is 320 lines.
- [x] Exact change blocks provided — yes (see How).
- [x] No judgment / design decisions — the fix is a single additive transform; no alternative designs considered.
- [x] No error handling to design — the transform is pure-additive with no failure modes (skips non-object schemas and pre-existing intent properties).
- [x] No cross-package changes — scoped to `.agents/plugins/opencode-aidevops/`.
- [x] Estimate under 1h — implementation < 30 min, tests + brief included.
- [x] 4 or fewer acceptance criteria — 4 (see below).

**Selected tier:** `tier:simple`
**Tier rationale:** Single additive function in one file + one new test file. All checklist items pass.

## PR Conventions

Leaf issue (#19649 is not `parent-task`) — PR body uses `Resolves #19649`.

## How

### Files to Modify

- **EDIT:** `.agents/plugins/opencode-aidevops/provider-auth-request.mjs` (add `injectIntentParameter` function; wire it into `applyBodyTransforms` after `prefixToolNames`).
- **NEW:** `.agents/plugins/opencode-aidevops/tests/test-intent-schema-injection.mjs` (mirror the pattern at `tests/test-observability-tool-calls.mjs`).

### Implementation Steps

1. Define `INTENT_PARAM_NAME` and `INTENT_PARAM_SCHEMA` module constants in `provider-auth-request.mjs`, just after `prefixToolNames`.
2. Define `injectIntentParameter(tools)` returning a new array: for each tool, inject `agent__intent` into `tool.input_schema.properties` if and only if the schema is an object-typed JSON-Schema and does not already declare the property. Never touch `required` (the field is optional — the LLM must be free to omit it when it has no intent to report).
3. Export the function for targeted testing; the existing codebase precedent is `buildToolCallInsertSql` in `observability.mjs`.
4. Wire it into `applyBodyTransforms`: call `injectIntentParameter` on `parsed.tools` immediately after the existing `prefixToolNames` call.
5. Write `tests/test-intent-schema-injection.mjs` covering: happy path (intent gets added), skip conditions (no schema, null schema, non-object schema, pre-existing intent), purity (no input mutation), mixed-batch correctness.

### Verification

- `node --check .agents/plugins/opencode-aidevops/provider-auth-request.mjs` — syntax passes.
- `node --test .agents/plugins/opencode-aidevops/tests/test-intent-schema-injection.mjs` — all 12 assertions pass.
- `node --test .agents/plugins/opencode-aidevops/tests/*.mjs` — 53 total assertions pass (12 new + 41 regression).
- Post-merge smoke test: spin up a fresh opencode session, make a few tool calls, run `sqlite3 ~/.aidevops/.agent-workspace/observability/llm-requests.db "SELECT COUNT(*), SUM(intent IS NOT NULL) FROM tool_calls WHERE session_id = '<session>'"` — expect non-zero intent count for `toolu_*` call IDs.

## Acceptance Criteria

1. `agent__intent` appears as an optional property on every object-typed tool schema in the transformed `/v1/messages` body.
2. Live Anthropic sessions produce `tool_calls` rows with non-null `intent` values (currently 0%; target ≥80% to match historical OpenAI coverage, subject to LLM compliance).
3. Test suite passes: `node --test .agents/plugins/opencode-aidevops/tests/*.mjs`.
4. No pre-existing tools with a legitimately-declared `agent__intent` property are mutated.

## Context

- Related, recently-landed: t2184 (`duration_ms` + `metadata` capture) + t2187 (run-mode OTEL span gap). Both addressed the same class of "shipped-but-empty" observability columns — this task is the third.
- Root cause traced via:
  - Per-day `callID`-prefix breakdown of `tool_calls` showing the OpenAI vs Anthropic split.
  - Raw `part` rows in opencode-archive.db confirming Anthropic strips vs OpenAI preserves.
  - git blame on `provider-auth-request.mjs` identifying the transform pipeline.
  - Reading the opencode plugin TypeScript definitions at `~/.opencode/node_modules/@opencode-ai/plugin/dist/index.d.ts` to confirm the `tool.execute.before` hook's `output.args` contract.
- Session notes: three headless workers were dispatched on #19649 on 2026-04-18 (PIDs 59144, 25951, 58597). All exited within ~2 minutes with `CLAIM_RELEASED reason=process_exit`, no commits, no logs in `~/.aidevops/logs/workers/`. Root cause of the headless failures is NOT addressed by this PR — recommend a separate follow-up issue once this fix lands and the observability picture clears up.
