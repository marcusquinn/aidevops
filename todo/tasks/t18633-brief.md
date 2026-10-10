<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18633: fix(opencode): tool-schema fallback lacks `object` and yields host-incompatible schemas when `@opencode-ai/plugin` is unresolvable

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `create child issue sub-issue parent-task claim-task-id brief worker-ready` → 0 hits; a lesson was stored this session for the same symptom (live run from an undeployed worktree crashes in ToolRegistry)
- [x] Discovery pass: last changes to `tool-schema.mjs` are `e795202a85`, `2f0a1083eb`, `f402f502d3` (2026-09-15); 0 open PRs; no open issue matches `schema.object` / `tool-schema fallback`
- [x] File refs verified: 6 refs checked, all present at HEAD `32a63021a8`
- [x] Tier: `tier:standard` — known module, one decided boundary (never hand an invalid schema to a host); the worker picks the local implementation
- [x] Seeded draft PR decision recorded: skipped — small change; the worker needs to confirm the host crash link first

## Origin

- **Created:** 2026-10-09
- **Session:** opencode:ses_edf9d373bffeXmpJHw5hBor7vr
- **Created by:** ai-interactive (maintainer asked to capture this during GH#34125 Phase 1)
- **Parent task:** none
- **Conversation context:** While verifying t18630 (PR #34142), `test-opencode-v2-adapter.mjs` failed one case locally ("V1 tool definitions adapt to structured V2 registrations": `schema.object is not a function`), but passed in CI. A live `opencode run` that loaded the plugin from the same worktree crashed in OpenCode `ToolRegistry` with `TypeError: undefined is not an object (evaluating 'g.type')`, both with and without the local-only binding.

## What

When `@opencode-ai/plugin` cannot be resolved, the plugin must never hand a host or adapter an incomplete stub schema:

1. The V2 adapter test passes in a checkout without `node_modules`, or skips with an explicit, logged reason. It must not throw `schema.object is not a function`.
2. When the plugin is loaded by a real OpenCode host and the schema package is unresolvable, it either resolves the host's copy or does not register custom tools and records a plugin-health diagnostic. It must not register stub schemas that crash the host's `ToolRegistry`.

## Why

Evidence (verified at HEAD `32a63021a8`):

- `.agents/plugins/opencode-aidevops/tool-schema.mjs:4-25`: when both `@opencode-ai/plugin/v1` and `@opencode-ai/plugin` fail to import, `loadV1ToolHelper` returns a fallback whose `schema` has only `array`, `enum`, `string`, `number` and `union`. Each returns the stub `{ _zod: {}, optional(), describe() }`. There is no `object` and no real Zod definition.
- `.agents/plugins/opencode-aidevops/v2-tool-adapter.mjs:39` calls `schema.object(definition.args || {})`, which throws with the fallback. The test reaches it through `tests/test-opencode-v2-adapter.mjs:369-390` (`tool` imported from `../tools.mjs`, which re-exports `tool-schema.mjs`).
- Linked worktrees have no `.agents/plugins/opencode-aidevops/node_modules`; the deployed `~/.aidevops/agents/plugins/opencode-aidevops/node_modules/@opencode-ai/` exists. CI installs locked dependencies (`npm run test`), so CI passes.
- **Hypothesis to confirm first:** the `g.type` crash is OpenCode's tool registry reading the type of a stub node with an empty `_zod`. It reproduced identically with and without the binding, which fits a schema cause rather than a policy cause.

Impact: local verification from worktrees is unreliable (one false failure; the live host check is impossible). Any deployment where the package fails to resolve would crash the host instead of degrading.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** single module plus test, with a decided boundary (never give a host an invalid schema). The worker chooses between a complete fallback, resolving the host's package, or skipping registration, after confirming the crash link.

## PR Conventions

Leaf issue: use a closing keyword for this issue in the PR body.

## How (Approach)

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/tool-schema.mjs:4-47` — fallback behaviour.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs:369-390` — make the case deterministic without installed dependencies (skip with reason or use the fixed fallback).
- `EDIT: .agents/plugins/opencode-aidevops/plugin-health.mjs` — only if the chosen fix records a "custom tools not registered" diagnostic.

### Complete Write Surface

- **Callers/readers:** `tools.mjs:12,16` (`const z = tool.schema`), `objective-receipt-tool.mjs:5`, `oauth-pool-tool.mjs:19`, `on-demand-tools.mjs:89`, `v2.mjs:392` (`addV1ToolsToV2Editor(editor, baseTools, tool.schema, …)`), `v2-tool-adapter.mjs:39`.
- **Writers/mutation paths:** N/A because resolution happens once at module load in `tool-schema.mjs` and writes nothing.
- **Existing verification/tests:** `tests/test-opencode-v2-adapter.mjs` (including `:556`, `helper.schema = {}`), `tests/test-on-demand-tools.mjs:168` (custom fallback fixture), `tests/test-tool-args-schema.mjs`, `tests/test-memory-tool-schema.mjs`, `tests/test-plugin-health.mjs`.
- **Schemas/config:** `.agents/plugins/opencode-aidevops/package.json` pins `@opencode-ai/plugin`; no change is expected.
- **Generated/deployed mirrors:** `setup.sh` deploys the plugin plus `node_modules`; there is no generated output.
- **Migrations/backfills:** N/A because only load-time behaviour in `tool-schema.mjs` changes; there is no stored state.
- **Cleanup/rollback paths:** revert the PR touching `tool-schema.mjs`. N/A for data cleanup because nothing is persisted.

### Implementation Steps

1. Confirm the crash link. From a worktree without `node_modules`, load the real plugin factory and call each registered tool's args through the host's conversion path, or reproduce with `opencode run` using the plugin from the worktree. Record whether the `g.type` crash comes from the stub schema.
2. Fix in `tool-schema.mjs` so callers never receive an incomplete schema. Keep `requirePinnedRuntime` (`:29-45`), which already throws for pinned remote runtimes.
3. Make the V2 adapter test deterministic with and without installed dependencies.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A. Top-level `await` resolution happens once per module load.
- **Migration/rollback:** none; revert restores the current fallback.
- **Mixed-version/backward compatibility:** the deployed plugin (dependencies installed) must resolve the real package and behave exactly as today. That is the regression guarantee. V1 and V2 hosts both consume `tool.schema`.
- **Idempotency/retry:** N/A. Stateless.
- **Partial failure/recovery:** if only `/v1` fails and the root export succeeds, the existing order (`tool-schema.mjs:32`) is preserved.

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs .agents/plugins/opencode-aidevops/tests/test-on-demand-tools.mjs .agents/plugins/opencode-aidevops/tests/test-tool-args-schema.mjs .agents/plugins/opencode-aidevops/tests/test-memory-tool-schema.mjs .agents/plugins/opencode-aidevops/tests/test-plugin-health.mjs
npm --prefix .agents/plugins/opencode-aidevops ci && npm --prefix .agents/plugins/opencode-aidevops run test
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** run the first command in a fresh worktree without `node_modules`; it proves the no-dependency path. The second proves the installed-dependency path that CI and deployment use. Lint covers the changed files.
- **Broad verification trigger:** not required.

### Scope Boundaries

**Hard boundaries:** no dependency version changes; no change to tool argument definitions.

**AI brief owner:** maintainer interactive session.

**Recovery:** preserve the PR and use the runtime request intake in `reference/worker-discipline.md`.

### Files Scope

- `.agents/plugins/opencode-aidevops/tool-schema.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs`
- `.agents/plugins/opencode-aidevops/plugin-health.mjs`

## Acceptance Criteria

- [ ] In a worktree without `node_modules`, `node --test .agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs` reports no failures (pass or explicit skip with reason).
- [ ] With dependencies installed, `npm run test` in `.agents/plugins/opencode-aidevops` passes, and `tool.schema` is the real package helper (not the fallback).
- [ ] Regression: no code path hands a host a schema object lacking a real definition. The PR records whether the `g.type` host crash is resolved, or why it is unrelated.

## Context & Decisions

- This is not caused by GH#34125 work: the failure reproduces on `main` and with the local-only binding unset.
- Do not "fix" it by committing `node_modules` or changing CI.

## Dependencies

- **Blocked by:** none
- **Blocks:** reliable live-host verification from worktrees (useful for GH#34125 Phases 2-3)
