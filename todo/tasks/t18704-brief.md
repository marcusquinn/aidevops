---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18704: Guard V2 MCP adapter output against the OpenCode V2 Mcp config schema shape

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `opencode v2 mcp adapter timeout toV2McpConfig` → 0 hits — no relevant lessons
- [x] Discovery pass: 1 commit (`06246e3483`, PR #34789) / 1 merged PR (#34789) / 0 open PRs touch target files in last 48h
- [x] File refs verified: 4 refs checked, all present at HEAD (`v2-mcp-adapter.mjs`, `mcp-registry.mjs`, `tests/test-opencode-v2-adapter.mjs`, `tests/test-seo-utils-mcp-registry.mjs`)
- [x] Tier: `tier:standard` — disqualifier check clean (test-only change; worker chooses validator structure within a decided boundary)
- [x] Seeded draft PR decision recorded: skipped — the change is one test helper plus one call site; a seed adds no value

## Origin

- **Created:** 2026-10-16
- **Session:** opencode:unknown-2026-10-16
- **Created by:** ai-interactive
- **Parent task:** none (follow-up to GH#34785 / PR #34789)
- **Blocked by:** none
- **Conversation context:** GH#34785 showed that a scalar `timeout` emitted by the V2 MCP adapter failed OpenCode V2 native schema validation in `mcp.transform`, which disabled the whole aidevops plugin. PR #34789 fixed `timeout` only. The existing V2 adapter test uses a mock editor with no schema validation, so any other field type mismatch would also ship undetected.

## What

A test-level guard that validates every MCP server config the production V2 transform emits against a pinned copy of the OpenCode V2 `Mcp.LocalConfig` / `Mcp.RemoteConfig` field types. If any managed registry entry (current or future) emits a field whose type V2 rejects, `node --test .agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs` fails with the server name and field path.

## Why

On V2, one invalid MCP field disables the entire plugin — tools, agents, permission evaluation and provider OAuth hooks (GH#34785). The mock editor in `test-opencode-v2-adapter.mjs` accepts anything, which is why #34206 shipped a scalar timeout unnoticed for a week. A pinned shape check turns that class of regression into a CI failure at the cost of one small test helper.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** Skeleton only; the worker writes the validator body.
- [x] **Targets and reference pattern verified?** One test file; existing toggle test already drives the production registry → transform path.
- [x] **No semantic or design decision remains?** Field types are pinned below from the V2 binary.
- [x] **Bounded, reversible, low-consequence impact?** Test-only.
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?** Not in `.agents/configs/self-hosting-files.conf`.

**Selected tier:** `tier:standard`

**Tier rationale:** decided boundary and pinned schema, but the worker writes the validator body rather than copying a complete edit -> tier:standard.

## PR Conventions

Leaf task: use `Resolves #NNN` for this task's issue.

## How (Approach)

### Worker Quick-Start

```bash
# 1. The production path is already exercised here (createV2McpRuntime -> initialize -> transforms[0](editor)):
rg -n "V2 MCP toggles reuse one transform" .agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs

# 2. Pinned V2 shape, extracted from the installed OpenCode V2 2.0.3 binary (Effect Schema classes).
#    Unknown keys are not the concern; wrong types on known keys are.
#    Mcp.LocalConfig:  type:"local"; command:string[] (required); cwd?:string;
#                      environment?:Record<string,string>; disabled?:boolean;
#                      codemode?:boolean; timeout?:Mcp.TimeoutConfig
#    Mcp.RemoteConfig: type:"remote"; url:string (required); headers?:Record<string,string>;
#                      oauth?:Mcp.OAuthConfig | false; disabled?:boolean; codemode?:boolean;
#                      timeout?:Mcp.TimeoutConfig
#    Mcp.TimeoutConfig: startup?, catalog?, execution? — positive integer milliseconds
#    Mcp.OAuthConfig:  client_id?, client_secret?, scope?, redirect_uri?: string;
#                      callback_port?: integer 1..65535
# Re-extract if the V2 runtime changes:
rg -a -o --max-count 1 'class [a-z0-9]+ extends rt\("Mcp\.(Local|Remote|Timeout)Config"\)\(\{.{0,400}' \
  ~/.aidevops/runtimes/opencode-v2/runtime/node_modules/@opencode/cli-darwin-arm64/bin/opencode
```

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs` — add a module-level `assertV2McpConfigShape(name, server)` helper and call it for every value after the first `transforms[0](editor)` in the "V2 MCP toggles reuse one transform and apply the latest override" test. Replace the timeout-only loop added by PR #34789 (`// Every managed server must match the V2 Mcp.TimeoutConfig object shape.`) with the general helper; keep the explicit `seo-utils` `{ execution: 900_000 }` assertion.

### Complete Write Surface

- **Callers/readers:** only the test file above; `toV2McpConfig` (`v2-mcp-adapter.mjs:7`) and `buildMcpConfigEntry` (`mcp-registry.mjs:756`) are read, not changed.
- **Writers/mutation paths:** N/A — no production code changes. If the guard finds a real mismatch, fix it in `toV2McpConfig` (V2 boundary), never in the V1 registry shape, and record that in the PR.
- **Existing verification/tests:** `tests/test-opencode-v2-adapter.mjs` ("V1 MCP enablement maps to V2 disabled semantics", "V2 MCP toggles ..."), `tests/test-seo-utils-mcp-registry.mjs` (pins the V1 scalar timeout; must stay green).
- **Schemas/config:** the pinned V2 shape lives in the test helper with a comment naming the source (`Mcp.LocalConfig`/`Mcp.RemoteConfig`, OpenCode V2 2.0.3) and the re-extraction command above.
- **Generated/deployed mirrors:** N/A — tests are not deployed to `~/.aidevops/agents/` as runtime code.
- **Migrations/backfills:** N/A because the change is test-only; no stored config or user data is rewritten.
- **Cleanup/rollback paths:** revert the single commit touching `tests/test-opencode-v2-adapter.mjs`.

### Implementation Steps

1. Add the helper near the top of the test file (after imports):

```js
// Pinned from OpenCode V2 2.0.3 Mcp.LocalConfig / Mcp.RemoteConfig (GH#34785).
// A wrong type on any known field makes V2 disable the whole plugin.
function assertV2McpConfigShape(name, server) {
  const isStringRecord = (value) => value && typeof value === "object" && !Array.isArray(value)
    && Object.values(value).every((entry) => typeof entry === "string");
  const isPositiveInt = (value) => Number.isInteger(value) && value > 0;
  assert.ok(server.type === "local" || server.type === "remote", `${name}.type`);
  if (server.type === "local") {
    assert.ok(Array.isArray(server.command) && server.command.every((part) => typeof part === "string"), `${name}.command`);
    if (server.cwd !== undefined) assert.equal(typeof server.cwd, "string", `${name}.cwd`);
    if (server.environment !== undefined) assert.ok(isStringRecord(server.environment), `${name}.environment`);
  } else {
    assert.equal(typeof server.url, "string", `${name}.url`);
    if (server.headers !== undefined) assert.ok(isStringRecord(server.headers), `${name}.headers`);
    // oauth: object (Mcp.OAuthConfig) or literal false
  }
  for (const key of ["disabled", "codemode"]) {
    if (server[key] !== undefined) assert.equal(typeof server[key], "boolean", `${name}.${key}`);
  }
  if (server.timeout !== undefined) {
    // object with only startup/catalog/execution, each a positive integer
  }
  // Also assert V1-only keys never leak: `enabled`, `env`.
}
```

2. In the toggle test, after the first `transforms[0](editor);`, call `assertV2McpConfigShape(name, server)` for every entry in `values`, replacing the timeout-only loop.
3. Run the verification commands below. If the guard fails on a real server, fix `toV2McpConfig` at the V2 boundary in the same PR and say so in the PR body.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A — synchronous test assertions only.
- **Migration/rollback:** N/A — single test commit, trivial revert.
- **Mixed-version/backward compatibility:** the V1 registry shape is unchanged; `test-seo-utils-mcp-registry.mjs` must stay green to prove it.
- **Idempotency/retry:** N/A — pure assertions.
- **Partial failure/recovery:** N/A.

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs .agents/plugins/opencode-aidevops/tests/test-seo-utils-mcp-registry.mjs
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the first command proves the guard runs over the production registry → transform output and that V1 registry tests still pass; the second covers changed-file lint and secrets.
- **Negative proof (manual, not committed):** temporarily revert the `timeout` mapping in `toV2McpConfig` and confirm the guard fails naming `seo-utils.timeout`, then restore it.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** do not change the V1 registry entry shape in `mcp-registry.mjs`; do not add new test runners, harnesses or fixtures.

**AI brief owner:** marcusquinn (maintainer)

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs`
- `.agents/plugins/opencode-aidevops/v2-mcp-adapter.mjs`

## Acceptance Criteria

- [ ] Every server emitted by the production V2 transform in the toggle test is checked against the pinned `Mcp.LocalConfig`/`Mcp.RemoteConfig` field types, and the test passes on current main.

  ```yaml
  verify:
    method: bash
    run: "node --test .agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs"
  ```

- [ ] The helper exists and names its V2 source.

  ```yaml
  verify:
    method: codebase
    pattern: "function assertV2McpConfigShape"
    path: ".agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs"
  ```

- [ ] Regression guarantee: a scalar `timeout` (the GH#34785 shape) or a leaked V1 `enabled`/`env` key makes the guard fail with the server name; the V1 registry test `test-seo-utils-mcp-registry.mjs` still passes unchanged.

  ```yaml
  verify:
    method: bash
    run: "node --test .agents/plugins/opencode-aidevops/tests/test-seo-utils-mcp-registry.mjs"
  ```

- [ ] Changed-file lint is clean (`.agents/scripts/linters-local.sh --changed`).

## Context & Decisions

- Normalization belongs at the V2 adapter boundary (`toV2McpConfig`), not the registry: V1 `opencode.json` consumes the registry shape directly (decision recorded in PR #34789).
- Effect Schema structs ignore excess keys on decode, so the guard targets wrong types on known keys, plus leaked V1 keys (`enabled`, `env`) as a hygiene check.
- Ruled out: a live V2 host smoke harness. `opencode api --standalone` on the local 2.0.3 runtime did not load file plugins, and a new harness needs separate approval under `reference/ci-gate-policy.md`.

## Relevant Files

- `.agents/plugins/opencode-aidevops/v2-mcp-adapter.mjs:7` — `toV2McpConfig`, the V1→V2 translation boundary
- `.agents/plugins/opencode-aidevops/mcp-registry.mjs:756` — `buildMcpConfigEntry`, the V1 entry shapes (local, remote, managed workspace)
- `.agents/plugins/opencode-aidevops/tests/test-opencode-v2-adapter.mjs` — toggle test that drives the production transform
- `.agents/plugins/opencode-aidevops/tests/test-seo-utils-mcp-registry.mjs:48` — pins the V1 scalar timeout

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | toggle test, `toV2McpConfig`, `buildMcpConfigEntry` |
| Implementation | 20m | helper + call site |
| Verification | 10m | two node test files, changed-file lint, manual negative proof |
| **Total** | **40m** | |
