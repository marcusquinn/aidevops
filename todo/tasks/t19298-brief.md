## What

`provider_static_auth_available` (`.agents/scripts/headless-runtime-provider.sh`) treats only `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` environment variables as static auth. An API-type credential stored in OpenCode's `auth.json` (`{"type":"api", ...}`) is not counted. So when that provider also has a non-empty OAuth pool whose accounts are all exhausted, `provider_oauth_pool_available` returns 1 and the provider is skipped, although the stored API key could serve the request.

## Why

Found by CodeRabbit on PR #39943 (GH#39936). The same shared rule gates tier selection (`.agents/scripts/headless-runtime-model.sh` `_first_healthy_configured_model`) and, after PR #39943, explicit pins (`_choose_model_explicit`). The gap predates that PR on the tier path. It only matters for runners that hold an API-type `auth.json` credential and a configured OAuth pool for the same provider.

## How

- `.agents/scripts/headless-runtime-provider.sh` `provider_static_auth_available`: also return 0 when the provider's `auth.json` entry has `type == "api"` and a non-empty key. Do NOT reuse `opencode_auth_has_provider` unchanged, because it also matches OAuth entries (`access`/`refresh`). Keep rejecting env keys marked `AIDEVOPS_*_API_KEY_SOURCE=oauth-pool`.
- `get_auth_signature` (same file, the GH#39936 block near the `pool=` fingerprint) calls `provider_static_auth_available` to decide whether to add the pool account-set fingerprint. A provider that becomes static-authenticated drops the pool component, so its provider backoff key changes once. Confirm that this one-time reset is acceptable, or keep the fingerprint decision independent.

### Files Scope

- `.agents/scripts/headless-runtime-provider.sh`
- `.agents/scripts/tests/test-headless-runtime-oauth-pool-gate.sh`

## Acceptance

- With an API-type `auth.json` credential, no env key, and an exhausted pool, `provider_oauth_pool_available` returns 0, and `headless-runtime-helper.sh select --model <provider>/<model>` succeeds.
- An OAuth-type `auth.json` entry with an exhausted pool still returns 1.
- An env key with `AIDEVOPS_*_API_KEY_SOURCE=oauth-pool` is still not static.

## Verification

- `shellcheck .agents/scripts/headless-runtime-provider.sh`
- `bash .agents/scripts/tests/test-headless-runtime-oauth-pool-gate.sh`

Ref #39936
