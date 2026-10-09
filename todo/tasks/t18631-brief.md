<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18631: GH#34125 Phase 2: stop-and-notify on local backend failure and deny protected reads outside a local-only binding

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `create child issue sub-issue parent-task claim-task-id brief worker-ready` → 0 hits — no relevant lessons
- [x] Discovery pass: 1 merged PR (#34142, Phase 1) touches target files in last 48h; 0 open PRs; open-issue search for `local-only` returns only parent #34125
- [x] File refs verified: 14 refs checked, all present at HEAD `32a63021a8`
- [x] Tier: `tier:thinking` — protected-data classification source and readiness semantics are unresolved trust/privacy decisions
- [x] Seeded draft PR decision recorded: skipped — classification source is a design decision; a seed would anchor the worker

## Origin

- **Created:** 2026-10-09
- **Session:** opencode:ses_edf9d373bffeXmpJHw5hBor7vr
- **Created by:** ai-interactive (maintainer requested filing after Phase 1 merged)
- **Parent task:** #34125 — Phase 1 is t18630 / #34140 / PR #34142 (merged `d899a9ffe6`)
- **Blocked by:** none (Phase 1 merged)
- **Conversation context:** Phase 1 binds an interactive OpenCode session to local-only processing at launch and blocks remote model egress. The parent incident also needs immediate, content-free notification when the local backend fails, and denial of protected-data reads in sessions that are not bound.

## What

1. **Stop and notify.** When a session bound with `AIDEVOPS_RUNTIME_POLICY=local-only` gets a local-backend failure (HTTP 404, connection refused, timeout, model-identity mismatch) or a `VAULT_POLICY_DENIED`, the operator immediately sees a foreground, content-free toast naming the failed check and the blocked operation. A bounded, durable, content-free blocker receipt is written. Nothing falls back to another provider (Phase 1 already blocks that path; this phase makes the stop visible).
2. **Protected-read denial.** A session that is **not** bound refuses to read data classified `local-only` / `local-LLM-only` (Read/Grep/Glob/list tools and bounded-operation/Bash reads of the same paths). The denial is content-free and tells the operator to relaunch with `AIDEVOPS_RUNTIME_POLICY=local-only aidevops opencode`. A bound session can read the same path.

## Why

Parent #34125 incident: a cloud session processed private data after a local-model request returned HTTP 404, and the operator was not notified. Phase 1 stops a bound session from sending to a remote provider, but (a) a local failure still surfaces only as a generic session error, and (b) an unbound cloud session can still read protected data. Parent required corrections 2, 3 and 8.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** where protected-data classification comes from (without creating a parallel authorization store) and what counts as readiness evidence are unresolved trust/privacy decisions. The change also alters a trust boundary (`#aidevops:trust-boundary`) and needs independent security review.

## PR Conventions

Parent #34125 is a `parent-task`: the PR body uses `For #34125` and a closing keyword only for this leaf issue.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/reference/vault-local-only-binding.md` (64 lines). This is the Phase 1 contract and its known gaps.
- **Read first:** `.agents/plugins/opencode-aidevops/local-only-policy.mjs`. This is the frozen binding (`activeLocalOnlyPolicy()`, `VAULT_POLICY_DENIED`, `LocalOnlyPolicyError`). Reuse it; never re-read `process.env`.
- **Read first:** `.agents/plugins/opencode-aidevops/provider-error-diagnostics.mjs:106-142`. This is the reference for turning `session.error` into a content-free, rate-limited `client.tui.showToast`.
- **Read first:** `.agents/plugins/opencode-aidevops/quality-hooks-secret-read.mjs:97-136`. This is the reference for a pre-read path classifier plus a throwing gate wired from `quality-hooks.mjs` `enforceReadAndFileQuality` (lines 251-275).
- **Load only if** classification needs Vault state: `.agents/reference/vault.md` §3 (lines 98-131: labels and `data_classification` / `runtime_policy` task metadata), the "Phase 2.5" section (lines 383-391: `vault-storage-lib.sh` gate) and `AIDEVOPS_VAULT_MANAGED_HISTORY_ROOT` (line 88).
- **Stop when** the classification source, the readiness decision, and the hook placement for V1 (`index.mjs` `tool.execute.before` → `quality-hooks.mjs`) and V2 (`v2.mjs:398` `ctx.tool.hook("execute.before")`, which calls the same `toolExecuteBefore`) are all clear.

### Files to Modify

- `NEW: .agents/plugins/opencode-aidevops/private-processing-policy.mjs` — protected-path classification and the unbound-session read gate (the module name was proposed in the parent issue). Model it on `quality-hooks-secret-read.mjs`.
- `EDIT: .agents/plugins/opencode-aidevops/quality-hooks.mjs:251-275` — call the new gate from `enforceReadAndFileQuality` next to `checkSecretReadWithApproval`; cover Bash/bounded-operation reads alongside `enforceBashToolSafety` (`:218-238`) and `enforceBoundedOperationSafety` (`:242-249`).
- `EDIT: .agents/plugins/opencode-aidevops/provider-error-diagnostics.mjs` (or a sibling module wired into the same `event` fan-out in `index.mjs:755-776`) — classify local-backend failures and `VAULT_POLICY_DENIED` in bound sessions, then toast and write the receipt.
- `EDIT: .agents/plugins/opencode-aidevops/local-only-policy.mjs` — export any shared classification or receipt helper; keep the binding frozen.
- `EDIT: .agents/plugins/opencode-aidevops/index.mjs` and `.agents/plugins/opencode-aidevops/v2.mjs` — wiring only.
- `EDIT: .agents/reference/vault-local-only-binding.md`, `.agents/private-local-ai.md` — document the behaviour and remove the covered gaps.
- `NEW: .agents/plugins/opencode-aidevops/tests/test-private-processing-policy.mjs`; `EDIT: tests/test-provider-error-diagnostics.mjs`, `tests/test-local-only-policy.mjs`.

### Complete Write Surface

- **Callers/readers:** `index.mjs:723-730` (V1 `tool.execute.before` → `toolExecuteBefore`); `v2.mjs:398-405` (V2 `execute.before` → same function); `index.mjs:755-776` (`event` fan-out including `providerErrorHandler`); `permission-broker.mjs` captures permission requests, and read permission must not imply transfer permission (parent issue).
- **Writers/mutation paths:** the new blocker receipt only. Reuse `appendWorkerBlockerEvent` from `.agents/scripts/worker-blocker-log.mjs`, following the de-duplicated call in `permission-broker.mjs:125-146` (`recordPermissionBlocker`), or write a sibling append-only log under `~/.aidevops/.agent-workspace/`. Content-free fields only: timestamp, session ID, check name, blocked tool name; no path or prompt text.
- **Existing verification/tests:** `tests/test-local-only-policy.mjs` (Phase 1 sentinel pattern: drive the real `AidevopsPlugin` factory), `tests/test-provider-error-diagnostics.mjs` (toast fixture), `tests/test-source-access-guidance.mjs` (read-gate fixture shape), `tests/test-permission-broker.mjs`.
- **Schemas/config:** possibly a protected-path list. If one is needed, reuse the shared-config pattern of `.agents/configs/local-ai-providers.conf` (missing file = fail closed for bound sessions, no-op for unbound). This is not yet knowable until the classification decision below.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/` to `~/.aidevops/agents/`; there are no generated files.
- **Migrations/backfills:** N/A because the gate is new and Phase 1 stores no policy state (`local-only-policy.mjs` freezes the binding in memory only).
- **Cleanup/rollback paths:** revert the PR. The receipt log written through `worker-blocker-log.mjs` is append-only and bounded, so no data cleanup is needed.

### Implementation Steps

1. **Decide the classification source** and record it in the PR body. Constraints: no new authorization store (parent requirement); labels come from trusted operator configuration, never from model output, file contents or tool arguments. Candidates, in preference order:
   - (a) The Vault managed paths and collections already resolved by `vault-storage-lib.sh`.
   - (b) An operator-owned protected-root list in `~/.config/aidevops/` (outside the repo, `600`).
   - (c) Both.
   Reject anything a model can write.
2. **Decide readiness semantics.** In a bound session, the parent model turn itself runs on the local backend, so a successful turn is evidence that the route works. Decide whether to add a probe before the first protected read (for example, the loopback endpoint answers and the session model ID is installed, as with `ollama-helper.sh health`, `/api/tags`). The parent issue says self-description alone is not attestation, so record the decision and the residual risk either way.
3. Implement the unbound read gate (throw a content-free `VAULT_POLICY_DENIED`-style error before the tool runs) and the bound stop-and-notify (toast plus receipt, de-duplicated per session the same way as `provider-error-diagnostics.mjs:120-123`).
4. Get an independent security review of the trust-boundary change (the parent issue requires one). Phase 1 used two `specialist-advisor` rounds.

### Hazards and Compatibility

- **Concurrency/atomicity:** the receipt is append-only JSONL, one line per event; concurrent sessions append independently (same as the permission-broker blocker log).
- **Migration/rollback:** no persisted policy state; reverting restores Phase 1 behaviour exactly.
- **Mixed-version/backward compatibility:** unbound sessions that read **unclassified** paths must behave exactly as today. That is the regression guarantee. V1 and V2 share `toolExecuteBefore`, so both hosts get the read gate from one change.
- **Idempotency/retry:** toasts are rate-limited per session; repeated denials append receipt lines but never re-prompt in a loop.
- **Partial failure/recovery:** if the toast fails (headless, or no TUI), the receipt and the thrown denial still apply. A notification failure must never turn into allowing the operation.

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-private-processing-policy.mjs .agents/plugins/opencode-aidevops/tests/test-local-only-policy.mjs .agents/plugins/opencode-aidevops/tests/test-provider-error-diagnostics.mjs .agents/plugins/opencode-aidevops/tests/test-permission-broker.mjs .agents/plugins/opencode-aidevops/tests/test-source-access-guidance.mjs
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the first command proves the read gate (unbound denied, bound allowed, unclassified unchanged), stop-and-notify (toast plus receipt, content-free), and that the existing read and permission gates still pass. The second covers changed-file lint and the markdown docs.
- **Broad verification trigger:** not required. The change is confined to the plugin package and two docs.

### Safety-Stop Recovery

- **Original objective:** deny protected reads outside a local-only binding, and notify immediately on a local backend failure.
- **Unsafe route not to repeat:** never test with real private data, credentials or live provider calls; use synthetic sentinels only (parent safety section).
- **Next safe route:** if a live OpenCode host run is impossible from a worktree (see t18633 / #34148 for the ToolRegistry crash), drive the real plugin factory in a Node child, as Phase 1 did.

### Scope Boundaries

**Hard boundaries:** no changes to Phase 1 egress semantics. No MCP, OTEL, webfetch, Bash network egress, or Task delegation gating (those belong to Phase 3). No new authorization store. No access to real private data.

**AI brief owner:** maintainer interactive session for #34125.

**Recovery:** preserve the PR and use the runtime request intake in `reference/worker-discipline.md`.

### Files Scope

- `.agents/plugins/opencode-aidevops/private-processing-policy.mjs`
- `.agents/plugins/opencode-aidevops/local-only-policy.mjs`
- `.agents/plugins/opencode-aidevops/quality-hooks.mjs`
- `.agents/plugins/opencode-aidevops/provider-error-diagnostics.mjs`
- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/v2.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-private-processing-policy.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-local-only-policy.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-provider-error-diagnostics.mjs`
- `.agents/reference/vault-local-only-binding.md`
- `.agents/private-local-ai.md`

## Acceptance Criteria

- [ ] An unbound session that reads a synthetic protected path (Read, Grep, and a Bash `cat`) is denied before the tool runs; the denial contains neither the sentinel nor the path contents.
- [ ] A bound session reading the same path is allowed.
- [ ] A bound session that gets a synthetic local 404 or connection-refused `session.error` produces exactly one content-free toast (per rate window) and one receipt line naming the failed check; no request reaches a fake external provider.
- [ ] Regression: an unbound session that reads unclassified repository files behaves exactly as before, and all existing read-gate and permission-broker tests pass.
- [ ] The classification source and readiness decision are recorded in the PR body, and the independent security review result is linked.

## Context & Decisions

- Phase 1 (`local-only-policy.mjs`) is the only trusted binding source; it is frozen at plugin init and child processes inherit it.
- Model output, tool arguments, file contents and "continue" prompts can never set classification or binding (parent requirement 1).
- Post-hoc output scrubbing is not sufficient; denial must happen before content reaches the model (parent requirement 5).

## Dependencies

- **Blocked by:** none (Phase 1 merged)
- **Blocks:** t18632 / #34147, Phase 3 (bound-session tool egress). It shares `quality-hooks.mjs`, so it is sequenced after this phase to avoid conflicts.
