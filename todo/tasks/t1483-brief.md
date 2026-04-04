---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1483: Fix model ID handling — revert Codex removal and enforce latest-alias convention

## Origin

- **Created:** 2026-03-14
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human)
- **Conversation context:** User reviewed PR#4641 (which replaced `openai/gpt-5.3-codex` with `openai/gpt-4o` in `DEFAULT_HEADLESS_MODELS`) and flagged that the premise was wrong — Codex *is* available via OpenAI OAuth subscription. The dispatch failure was misdiagnosed as a missing model when the real issue is likely auth/provider config. User also flagged PR#4647 (which pinned `claude-haiku-4-5` to dated snapshot `claude-haiku-4-5-20251001`) as wrong — the convention is to use the latest unversioned alias. PR#4647 closed, GH#3337 closed.

## What

1. Revert the model change from PR#4641 — restore `openai/gpt-5.3-codex` in `DEFAULT_HEADLESS_MODELS` (line 18 and help text line 817).
2. Add auth-availability pre-check to `choose_model()` — before selecting a model, verify the provider has auth configured (not just that it's not backed off). This way Codex stays in the default list but is only selected when OpenAI auth is actually available. Users without OpenAI OAuth simply skip it silently — no failed dispatch, no backoff churn.
3. Investigate and fix the actual root cause of the `ProviderModelNotFoundError` — likely the headless runtime's OpenAI auth path doesn't support OAuth-based access (it only checks `OPENAI_API_KEY` env var at line 161-163). Consider also supporting OpenCode Zen gateway model IDs (e.g., `opencode/gpt-5.3-codex`) as an alternative provider path.
4. Update the provider config in `model-routing-table.json` to include OpenAI as a provider if needed.
5. Update tests in `tests/test-headless-runtime-helper.sh` to match restored model ID and test the auth-availability pre-check (no-auth-configured → skip silently).
6. Audit all model ID references for dated snapshots and enforce the convention: use latest unversioned aliases (e.g., `claude-haiku-4-5` not `claude-haiku-4-5-20251001`). PR#4647/GH#3337 was an example of going the wrong direction.

## Why

PR#4641 was a false fix — it treated a symptom (dispatch failure) by removing a valid model instead of fixing the auth/config issue. Codex is a capable coding model available via OpenAI OAuth subscription, and having it in the headless rotation provides provider diversity (reduces single-provider risk) and access to a strong coding-specific model. Replacing it with `gpt-4o` loses the coding specialisation and doesn't address why the model wasn't reachable.

However, the default model list must work for all users — not just those with OpenAI OAuth configured. The current backoff system handles this reactively (fail → backoff → skip), but this wastes a dispatch attempt and creates noise. The right fix is a proactive auth-availability check: if a provider has no auth configured, skip its models silently during selection. This keeps Codex in the defaults for users who have it, while being invisible to users who don't.

## How (Approach)

1. **Revert the model ID** in `.agents/scripts/headless-runtime-helper.sh`:
   - Line 18: restore `openai/gpt-5.3-codex` in `DEFAULT_HEADLESS_MODELS`
   - Line 817: restore in help text

2. **Add `provider_auth_available()` check** to `choose_model()` (line 510 loop):
   - New function that checks whether a provider has auth configured (env var set, or OAuth token present, or OpenCode Zen gateway available)
   - Called alongside `provider_backoff_active()` in the model selection loop — if no auth, skip silently (no error, no backoff record)
   - Can leverage `model-availability-helper.sh check <provider>` (exit code 3 = API key missing) or do a lightweight inline check
   - For OpenAI: check `OPENAI_API_KEY` env var OR OpenCode OAuth status for OpenAI provider
   - For Anthropic: check `ANTHROPIC_API_KEY` env var OR OpenCode auth status (existing logic)

3. **Fix OpenAI auth signature**: Update `compute_auth_signature()` (line 161) to handle OAuth token auth, not just `OPENAI_API_KEY`.

4. **Consider OpenCode Zen gateway IDs**: For users routing through OpenCode's gateway (e.g., `opencode/gpt-5.3-codex`), the headless runtime currently rejects `opencode/*` models (line 473). Evaluate whether this rejection should be relaxed for non-headless-specific gateway models, or whether the `DEFAULT_HEADLESS_MODELS` should include both direct (`openai/`) and gateway (`opencode/`) variants with the auth check selecting the right one.

5. **Fix provider config**: Add OpenAI provider entry to `model-routing-table.json`.

6. **Update tests**: Restore `openai/gpt-5.3-codex` references and add tests for:
   - No OpenAI auth → Codex skipped silently, Anthropic selected
   - OpenAI auth present → Codex selected on alternate rotation
   - Both providers backed off → returns exit 75

7. **Audit model IDs**: Scan for dated snapshots, enforce latest-alias convention.

Key files:
- `.agents/scripts/headless-runtime-helper.sh:18` — DEFAULT_HEADLESS_MODELS constant
- `.agents/scripts/headless-runtime-helper.sh:113` — auth signature for openai
- `.agents/scripts/headless-runtime-helper.sh:161-163` — OpenAI auth material computation
- `.agents/configs/model-routing-table.json` — provider definitions
- `tests/test-headless-runtime-helper.sh:86-124` — OpenAI rotation tests

## Acceptance Criteria

- [ ] `DEFAULT_HEADLESS_MODELS` contains `openai/gpt-5.3-codex` (not `gpt-4o`)
  ```yaml
  verify:
    method: codebase
    pattern: "openai/gpt-5.3-codex"
    path: ".agents/scripts/headless-runtime-helper.sh"
  ```
- [ ] `gpt-4o` is NOT in `DEFAULT_HEADLESS_MODELS` (it was the wrong replacement)
  ```yaml
  verify:
    method: codebase
    pattern: "DEFAULT_HEADLESS_MODELS.*gpt-4o"
    path: ".agents/scripts/headless-runtime-helper.sh"
    expect: absent
  ```
- [ ] Auth-availability pre-check exists: `choose_model()` skips providers with no auth configured (no error, no backoff — silent skip)
  ```yaml
  verify:
    method: codebase
    pattern: "provider_auth_available"
    path: ".agents/scripts/headless-runtime-helper.sh"
  ```
- [ ] No-auth fallback works: when OpenAI auth is not configured, `select` returns Anthropic model without errors
  ```yaml
  verify:
    method: bash
    run: "unset OPENAI_API_KEY && bash tests/test-headless-runtime-helper.sh"
  ```
- [ ] OpenAI provider auth supports OAuth-based access (not just `OPENAI_API_KEY`)
  ```yaml
  verify:
    method: subagent
    prompt: "Review compute_auth_signature() and provider_auth_available() in headless-runtime-helper.sh and confirm they handle OpenAI OAuth token auth in addition to API key auth"
    files: ".agents/scripts/headless-runtime-helper.sh"
  ```
- [ ] Tests pass: `bash tests/test-headless-runtime-helper.sh`
  ```yaml
  verify:
    method: bash
    run: "bash tests/test-headless-runtime-helper.sh"
  ```
- [ ] Lint clean: `shellcheck .agents/scripts/headless-runtime-helper.sh`
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/headless-runtime-helper.sh"
  ```

## Context & Decisions

- PR#4641 was auto-generated by a pulse worker that observed `ProviderModelNotFoundError` during dispatch and assumed the model ID was invalid.
- The user confirmed Codex is available via OpenAI OAuth subscription — the model exists, the auth path was the problem.
- The `compute_auth_signature()` function (line 161) only checks `OPENAI_API_KEY` env var. If the OpenAI OAuth flow uses a different env var or token mechanism, the helper would see no auth material and the provider would fail.
- `model-routing-table.json` currently has no OpenAI provider entry — only `local` and `anthropic`. This may also contribute to the failure.
- GH#4628 should be reopened or this new issue should reference it as the correct fix.
- PR#4647 tried to pin `claude-haiku-4-5` to `claude-haiku-4-5-20251001` in `model-availability-helper.sh`. This was wrong — the unversioned alias is the convention and is already correct. PR closed, GH#3337 closed.
- Convention: always use latest unversioned model aliases. Dated snapshots are only for normalization/parsing compatibility paths, never for active routing defaults.
- The default model list must work for all users. Not everyone has OpenAI OAuth configured. The existing backoff system handles failures reactively (fail → backoff → skip on retry), but this wastes a dispatch attempt. A proactive `provider_auth_available()` check in `choose_model()` is the right pattern — skip providers with no auth silently, no error, no backoff noise.
- `model-availability-helper.sh` already has provider probing with exit code 3 for missing API keys. The headless runtime could call this or implement a lightweight inline equivalent.
- OpenCode Zen gateway models (`opencode/*`) are currently rejected for headless runs (line 473). This may need revisiting if users route through the gateway for providers they don't have direct API keys for.

## Relevant Files

- `.agents/scripts/headless-runtime-helper.sh:18` — DEFAULT_HEADLESS_MODELS constant to revert
- `.agents/scripts/headless-runtime-helper.sh:113` — auth signature env var mapping
- `.agents/scripts/headless-runtime-helper.sh:161-163` — OpenAI auth material computation
- `.agents/scripts/headless-runtime-helper.sh:817` — help text to revert
- `.agents/configs/model-routing-table.json` — needs OpenAI provider entry
- `tests/test-headless-runtime-helper.sh:86-124` — tests to update
- `.agents/scripts/model-availability-helper.sh:115-131` — model tier definitions (verify no dated snapshots)
- `.agents/scripts/model-availability-helper.sh:1-38` — provider probing with exit code 3 for missing keys (reusable pattern)

## Dependencies

- **Blocked by:** none
- **Blocks:** reliable multi-provider headless dispatch
- **External:** none (the fix must work with OR without OpenAI OAuth configured)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Understand OAuth auth flow, OpenCode Zen gateway model IDs |
| Implementation | 1.5h | Revert model ID, add auth pre-check, fix auth path, update provider config |
| Testing | 30m | Run tests, verify both auth-present and no-auth scenarios |
| **Total** | **~2.5h** | |
