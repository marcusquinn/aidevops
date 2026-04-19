# t2392 brief

## Session origin

Interactive session (2026-04-19) — user reported pulse backlog drought: 34 open issues, 16+ clearly dispatchable, but `issues_dispatched: 0` in pulse health. Live diagnosis traced the failure to the `model-availability-helper.sh` probe misrouting OpenCode OAuth tokens as static API keys.

## What

Fix `model-availability-helper.sh` so OpenCode OAuth-typed entries in `~/.local/share/opencode/auth.json` (primary worker auth path — opencode CLI with Anthropic provider) are treated as healthy **without HTTP probing**, regardless of access-token expiry. Also add a defensive prefix check in the probe builder for the case where a raw OAuth token (prefix `sk-ant-oat01-`) has been set as `ANTHROPIC_API_KEY` env var.

The claude CLI is an out-of-scope fallback path — not wired into the OAuth pool yet, untested, and deferred.

## Why

Today, `resolve_api_key` at line 437-444 returns the **raw** OAuth access token when it's not expired:

```bash
if [[ "$expires_at" -gt "$now_ms" ]] 2>/dev/null; then
    echo "$access_token"   # <— bug: raw OAuth token returned
    return 0
fi
```

That token (108 chars, `sk-ant-oat01-...`) flows into `_probe_build_request` (line 767):

```bash
curl_args="$curl_args -H 'x-api-key: ${api_key}' -H 'anthropic-version: 2023-06-01'"
```

The Anthropic `/v1/models` endpoint rejects OAuth tokens on the `x-api-key` header — they need `Authorization: Bearer`. Result: HTTP 401 `bad-key`, provider marked unhealthy, `resolve_tier opus/sonnet` returns "No available model for tier: opus/sonnet", and `dispatch_deterministic_fill_floor` can enumerate candidates but never dispatches workers.

Observed today: 25 candidates enumerated by DFF, 5 attempted dispatch, all 5 failed at model resolution. Pulse health: `workers_active: 3 (stale), issues_dispatched: 0`. The drought persisted ~2h until diagnosis.

**Scope**: this affects every aidevops user who runs opencode without a paid static Anthropic API key — the default recommended configuration. Reported by the repo maintainer in an interactive session; likely hitting other users silently.

PR #17793 (t1927) introduced the `oauth-refresh-available` synthetic-marker pattern for **expired** OAuth tokens. The fix here extends that pattern to all OAuth-typed entries (not just expired ones), matching the existing `probe_provider` → `_probe_resolve_and_validate_key` → `_record_health healthy` flow.

## How

**Primary fix — `model-availability-helper.sh` lines 437-456**:

EDIT `.agents/scripts/model-availability-helper.sh:437`. Replace the "access_token non-empty" branch so that when the auth.json entry for this provider has `type == "oauth"`, always return `oauth-refresh-available` — regardless of `expires_at`. The probe will then record healthy and skip HTTP. Workers still authenticate via their own opencode/claude-cli runtime auth path (unchanged).

Pattern reference: the existing expired-token branch at lines 448-456 already returns `oauth-refresh-available` and is consumed correctly at line 903 (`_probe_resolve_and_validate_key`) + line 905 (`_record_health healthy`). This is mentoring the fix.

**Defensive fix — `model-availability-helper.sh` lines 765-768**:

EDIT the `anthropic)` case in `_probe_build_request`. Before adding the `x-api-key` header, check if `$api_key` starts with `sk-ant-oat01-` (OAuth access token prefix). If so, return with an error marker so the caller short-circuits to healthy — belt-and-braces in case a user exports an OAuth token directly to `ANTHROPIC_API_KEY` env var.

**Regression test — NEW `.agents/scripts/tests/test-model-availability-oauth-token.sh`**:

Model on `.agents/scripts/tests/test-pulse-wrapper-worker-detection.sh` (simple test-runner pattern). Three assertions:

1. Given an auth.json with `anthropic.type = "oauth"` and a **future** `expires` timestamp, `resolve_api_key anthropic` returns `oauth-refresh-available`.
2. Given an auth.json with `anthropic.type = "oauth"` and a **past** `expires` timestamp + refresh token, `resolve_api_key anthropic` returns `oauth-refresh-available` (unchanged pre-existing behaviour).
3. Given `ANTHROPIC_API_KEY=sk-ant-oat01-dummy` env var set, `probe_provider anthropic` records healthy without making the HTTP probe.

## Acceptance criteria

- [ ] `resolve_api_key anthropic` returns `oauth-refresh-available` whenever auth.json has `anthropic.type == "oauth"` (valid or expired)
- [ ] `_probe_build_request` does not send OAuth tokens (prefix `sk-ant-oat01-`) via `x-api-key` header
- [ ] Regression test passes: 3/3 assertions
- [ ] `shellcheck` passes on `model-availability-helper.sh` and the new test file
- [ ] After deploy, `model-availability-helper.sh probe anthropic --force` returns `healthy` on a machine with only opencode OAuth (no static key)
- [ ] After deploy, the pulse DFF dispatches workers — observable in `pulse.log`: `Deterministic fill floor: dispatched N` with N > 0

## Context

- Evidence: `~/.aidevops/logs/pulse.log` (2026-04-19 ~18:30Z) shows `No available model for tier: opus` followed by `dispatch_triage_reviews: model resolution failed (opus and sonnet unavailable)` despite 25 DFF candidates enumerated
- `oauth-pool-helper.sh check anthropic` reports all 3 OAuth accounts `Validity: OK`
- `model-availability-helper.sh status` reports `anthropic: bad-key (HTTP 401)`
- The probe/pool discrepancy IS the bug: probe uses static-key semantics against OAuth tokens
- Prior related work: PR #17793 (t1927), PR #17855 (probe_provider refactor)
- Memory reference: `mem_20260419184307_55b54c8c`
