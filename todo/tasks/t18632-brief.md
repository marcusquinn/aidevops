<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18632: GH#34125 Phase 3: block tool-level egress from local-only bound sessions

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `create child issue sub-issue parent-task claim-task-id brief worker-ready` → 0 hits — no relevant lessons
- [x] Discovery pass: 1 merged PR (#34142, Phase 1) touches target files in last 48h; 0 open PRs; open-issue search for `local-only` returns only parent #34125
- [x] File refs verified: 20 refs checked, all present at HEAD `32a63021a8`
- [x] Tier: `tier:thinking` — the Bash network-egress mechanism (command policy vs OS sandbox) is an unresolved trust-boundary decision
- [x] Seeded draft PR decision recorded: skipped — mechanism choice is open

## Origin

- **Created:** 2026-10-09
- **Session:** opencode:ses_edf9d373bffeXmpJHw5hBor7vr
- **Created by:** ai-interactive (maintainer requested filing after Phase 1 merged)
- **Parent task:** #34125 — Phase 1 is t18630 / #34140 / PR #34142 (merged `d899a9ffe6`)
- **Blocked by:** t18631 / #34146, Phase 2 (native `blockedBy` edge; `blocked-by:t18631`). Both phases edit `quality-hooks.mjs`, so they run in sequence.
- **Conversation context:** Phase 1 keeps the bound session's own model traffic on the device. Its documented gaps (`.agents/reference/vault-local-only-binding.md` "Trust assumptions and gaps") are tools that send data off the device without going through `chat.params`.

## What

In a session bound with `AIDEVOPS_RUNTIME_POLICY=local-only`, every aidevops-controlled tool path that can send session content off the device fails closed with a content-free `VAULT_POLICY_DENIED`. Loopback destinations stay allowed. The paths covered:

1. **Remote MCP servers.** Tool calls to MCP entries with `type: "remote"` (`mcp-registry.mjs`: context7 `:228`, sentry `:332`, socket `:345`, posthog `:357`, cloudflare `:375`) and to any user-configured remote MCP. Activating them through `mcp-activation-tool.mjs` is also refused.
2. **Host web tools.** `webfetch` / `websearch` (URLs and queries can carry content).
3. **Plugin tools that call provider APIs directly** and bypass `chat.params`. `gpt_image_generate` (`gpt-image-request.mjs`) is one; Phase 1 already covered `ai-research`.
4. **Framework helpers that send content to provider APIs.** Each calls the shared `vault_runtime_policy_check` (`.agents/scripts/vault-data-policy-helper.sh:97`) before its first request, as `ai-research-helper.sh:347,411` does. Verified candidates: `memory-embeddings-helper-engine.sh`, `transcription-helper.sh`, `email-signature-parser-helper.sh`, `email_md_summary.py`, `eeat-score-helper.sh`, `video-gen-helper.sh`. OAuth/health/registry helpers send no session content; record that classification rather than gating them.
5. **Model-initiated Bash and bounded-operation network egress** (`curl`, `wget`, `ssh`, `git push`, `gh`, `nc`, interpreters opening sockets), and child commands run with the binding variable cleared.
6. **OTEL export** to a non-loopback `OTEL_EXPORTER_OTLP_ENDPOINT` (forwarded by `shell-env.mjs:157-159`; span attributes include the model-written intent, `quality-hooks.mjs:306-312`).
7. **Task delegation evidence.** Prove with a test that a subagent with an explicit remote model is denied at `chat.params`. Phase 1 should already cover this; this phase adds proof, not new code, unless the test fails.

## Why

Parent #34125 required correction 5: cover search, shell/subprocess, bounded operations, MCP outputs, delegation, logging and observability before content leaves. Without this phase, a bound session's local model can still send private data to a remote service through a tool, which defeats the binding.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Bash egress has no complete deterministic answer. A command denylist is bypassable, while an OS network sandbox (macOS `sandbox-exec`, Linux network namespaces) changes the execution path and portability. This choice changes a trust boundary and needs independent security review.

## PR Conventions

Parent #34125 is a `parent-task`: the PR body uses `For #34125`. This phase covers the last listed gaps. Close the parent only if the maintainer confirms that nothing remains; otherwise leave it open with a remaining-scope comment.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/reference/vault-local-only-binding.md` (Phase 1 contract and gaps) and `.agents/plugins/opencode-aidevops/local-only-policy.mjs` (`activeLocalOnlyPolicy()`, `isLoopbackDestination()`, `assertLocalOnlyEgress()`). Reuse them; never re-read `process.env` for the binding.
- **Read first:** `.agents/plugins/opencode-aidevops/quality-hooks.mjs:218-249` (`enforceBashToolSafety`, `enforceBoundedOperationSafety`) and `.agents/plugins/opencode-aidevops/quality-hooks-command-policy.mjs:76-88`. This is where commands are inspected today, including the `ownedListenerRoots` loopback allowance.
- **Read first:** `.agents/scripts/ai-research-helper.sh:340-350` — the pattern for a helper calling `vault_runtime_policy_check` before a provider request.
- **Load only if** Phase 2 has merged: its `private-processing-policy.mjs` gate shape, so both phases share one denial helper.
- **Stop when** the Bash mechanism decision, the remote-MCP identification rule, and the helper list are fixed.

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/local-only-policy.mjs` — a shared tool-egress denial helper.
- `EDIT: .agents/plugins/opencode-aidevops/quality-hooks.mjs` — deny remote-MCP, web-tool and direct-provider tool calls before execution while bound, plus the Bash/bounded-operation decision.
- `EDIT: .agents/plugins/opencode-aidevops/quality-hooks-command-policy.mjs` — if the command-policy route is chosen.
- `EDIT: .agents/plugins/opencode-aidevops/mcp-activation-tool.mjs` — refuse to connect a remote MCP while bound.
- `EDIT: .agents/plugins/opencode-aidevops/gpt-image-tool.mjs` — deny while bound.
- `EDIT: .agents/plugins/opencode-aidevops/shell-env.mjs` and `.agents/plugins/opencode-aidevops/otel-enrichment.mjs` — no non-loopback OTEL export while bound.
- `EDIT:` the helper scripts listed in What item 4 — call `vault_runtime_policy_check` before the first provider request.
- `EDIT: .agents/reference/vault-local-only-binding.md` — move the covered items out of "gaps" and state the residual trust assumptions.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-local-only-policy.mjs` — sentinel tests for each surface.

### Complete Write Surface

- **Callers/readers:** V1 `index.mjs:723-730` and V2 `v2.mjs:398-405` both call `toolExecuteBefore`. MCP tools arrive there with server-prefixed names; the remote/local type comes from the merged MCP config (`mcp-registry.mjs:187-188` documents the `type`/`url` fields). Helper scripts inherit `AIDEVOPS_RUNTIME_POLICY` from the bound process.
- **Writers/mutation paths:** N/A because denials only throw; optional receipts reuse the Phase 2 writer (`worker-blocker-log.mjs`).
- **Existing verification/tests:** `tests/test-local-only-policy.mjs`, `tests/test-mcp-activation.mjs`, `tests/test-gpt-image-tool.mjs`, `tests/test-shell-env-origin.mjs`, `tests/test-otel-enrichment.mjs`, `tests/test-git-safety-gate.mjs` (command policy), `.agents/scripts/tests/test-vault-data-policy-routing.sh`, `.agents/scripts/tests/test-ai-research-helper-oauth-pool.sh`.
- **Schemas/config:** `.agents/configs/local-ai-providers.conf` is unchanged. Use no new config unless the Bash decision requires an allowlist.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/`; there are no generated files.
- **Migrations/backfills:** N/A because these are stateless pre-execution gates against the frozen `local-only-policy.mjs` binding.
- **Cleanup/rollback paths:** revert the PR (gates live in `quality-hooks.mjs` and the listed helpers). N/A for data cleanup because nothing is persisted.

### Implementation Steps

1. Decide the Bash/bounded-operation mechanism and record it with residual risk in the PR body. A command policy blocks known network tools, but interpreters and custom binaries escape it. An OS sandbox without network (loopback allowed) is stronger but changes portability. Neither may block loopback listeners the session owns (`ownedListenerRoots`).
2. Decide how to identify a remote MCP tool reliably from the tool name plus the merged MCP config, without trusting tool arguments.
3. Implement the gates, using one shared denial helper and the content-free message format from Phase 1.
4. Get an independent security review (the parent issue requires one).

### Hazards and Compatibility

- **Concurrency/atomicity:** stateless checks against the frozen policy; no shared mutable state.
- **Migration/rollback:** reverting restores the Phase 1/2 behaviour; nothing is persisted.
- **Mixed-version/backward compatibility:** **unbound sessions must behave exactly as today on every surface**. That is the regression guarantee. Helpers run outside OpenCode (headless, cron) are unbound unless the variable is set.
- **Idempotency/retry:** a denial is deterministic and must not trigger retry loops. Return a terminal content-free error the session-continuation guard treats as a blocker, not a transient failure.
- **Partial failure/recovery:** if remote/local classification fails (unknown MCP type, unresolvable URL), deny while bound (fail closed).

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-local-only-policy.mjs .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs .agents/plugins/opencode-aidevops/tests/test-gpt-image-tool.mjs .agents/plugins/opencode-aidevops/tests/test-shell-env-origin.mjs .agents/plugins/opencode-aidevops/tests/test-otel-enrichment.mjs .agents/plugins/opencode-aidevops/tests/test-git-safety-gate.mjs
bash .agents/scripts/tests/test-vault-data-policy-routing.sh
bash .agents/scripts/tests/test-ai-research-helper-oauth-pool.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the node suite proves the plugin surfaces (MCP, web, gpt-image, OTEL, command policy) for bound denial and unbound regression. The shell suites prove the headless gate and the helper-gate pattern. Lint covers the changed shell, Python and markdown files.
- **Broad verification trigger:** not required unless the Bash sandbox route changes the shared command execution path. In that case, run `.agents/scripts/tests/test-opencode-launcher-helper.sh` too.

### Safety-Stop Recovery

- **Original objective:** a bound session cannot send content off the device through aidevops-controlled tools.
- **Unsafe route not to repeat:** no live network or provider tests with real data; use synthetic sentinels and a fake external endpoint.
- **Next safe route:** if a surface cannot be gated deterministically, document it in `vault-local-only-binding.md` "Trust assumptions and gaps" and land the rest. Never claim coverage without a denial test.

### Scope Boundaries

**Hard boundaries:** Phase 1 egress and Phase 2 read/notify semantics are unchanged. Unbound behaviour is unchanged. Third-party OpenCode plugins remain a documented trust assumption. There is no network test with real data.

**AI brief owner:** maintainer interactive session for #34125.

**Recovery:** preserve the PR and use the runtime request intake in `reference/worker-discipline.md`.

### Files Scope

- `.agents/plugins/opencode-aidevops/local-only-policy.mjs`
- `.agents/plugins/opencode-aidevops/quality-hooks.mjs`
- `.agents/plugins/opencode-aidevops/quality-hooks-command-policy.mjs`
- `.agents/plugins/opencode-aidevops/mcp-activation-tool.mjs`
- `.agents/plugins/opencode-aidevops/gpt-image-tool.mjs`
- `.agents/plugins/opencode-aidevops/shell-env.mjs`
- `.agents/plugins/opencode-aidevops/otel-enrichment.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-local-only-policy.mjs`
- `.agents/scripts/memory-embeddings-helper-engine.sh`
- `.agents/scripts/transcription-helper.sh`
- `.agents/scripts/email-signature-parser-helper.sh`
- `.agents/scripts/email_md_summary.py`
- `.agents/scripts/eeat-score-helper.sh`
- `.agents/scripts/video-gen-helper.sh`
- `.agents/reference/vault-local-only-binding.md`

## Acceptance Criteria

- [ ] While bound: a remote MCP tool call, `webfetch`, `gpt_image_generate`, and a Bash `curl https://…` with a synthetic sentinel are each denied before execution; a fake external endpoint receives nothing.
- [ ] While bound: loopback calls still work (a local MCP, `curl http://127.0.0.1:<owned port>`, an Ollama helper call).
- [ ] While bound: each listed content-sending helper exits non-zero with `VAULT_POLICY_DENIED` before any network request; OTEL export to a non-loopback endpoint is disabled.
- [ ] A subagent configured with a remote model is denied at `chat.params` (test evidence).
- [ ] Regression: unbound sessions and unbound helper runs behave exactly as before; all suites listed under Verification pass.
- [ ] The Bash mechanism decision, residual risks and the independent security review are recorded in the PR body, and `vault-local-only-binding.md` gaps are updated.

## Context & Decisions

- Loopback stays allowed. A local proxy that forwards to a remote host remains a documented trust assumption (Phase 1).
- Helpers that send no session content (OAuth pool, model registry/availability, health checks) are out of scope; record the classification so later reviewers can see it was considered.
- Never trust tool arguments or model output to declare a destination local.

## Dependencies

- **Blocked by:** t18631 / #34146 (shares `quality-hooks.mjs` and the denial/receipt helper)
- **Blocks:** final closure of parent #34125
