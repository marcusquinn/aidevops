---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t19183: fix(oauth-pool): share one runtime pool resolver and usability rule between model availability and headless auth

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `oauth pool resolver model-availability headless-runtime-provider V2 pool` → 0 hits — no relevant lessons
- [x] Discovery pass: PR #39097 (open, external, approved direction) adds both functions this task unifies; #39268/#39276 cover headless profile resolution separately; no other open PR touches the pool predicates
- [x] File refs verified: 9 refs checked at main `a4aa2d2d` and PR #39097 head `ed9cca98`
- [x] Tier: `tier:standard` — known pattern inside a decided boundary; neither target file is in `.agents/configs/self-hosting-files.conf`
- [x] Seeded draft PR decision recorded: skipped — the target functions only exist after PR #39097 merges

## Origin

- **Created:** 2026-11-19
- **Session:** opencode:interactive-2026-11-19 (review of PR #39097)
- **Created by:** ai-interactive
- **Parent task:** #35902 (OpenCode 2.x migration-readiness checks)
- **Blocked by:** #39095 — closes when PR #39097 merges; that PR introduces `_resolve_oauth_pool_available` and `opencode2_oauth_pool_auth_available`
- **Conversation context:** The maintainer review of PR #39097 accepted it as a strict improvement and deferred three review-bot findings (pool-file override, non-runnable statuses, V2 root) to this follow-up. The #39095 review and the #35902 audit comment name this as a prerequisite for switching the default OpenCode profile to V2.

## What

After PR #39097, two independent checks decide whether an OAuth pool account can authenticate a provider:

- `_resolve_oauth_pool_available` in `.agents/scripts/model-availability-helper.sh` (model availability probe, Source 5).
- `opencode2_oauth_pool_auth_available` in `.agents/scripts/headless-runtime-provider.sh` (headless worker model selection).

Each resolves its own pool file and applies its own status rule. This task makes both call one shared implementation, so that:

1. Both read the pool file the active runtime actually authenticates from.
2. Both apply the same allowlist of runnable account states.
3. Source 5 applies only when OpenCode `auth.json` is absent, matching the headless check.

## Why

The three CodeRabbit threads on PR #39097 (resolved as deferred to this task) identify cases where availability and runtime disagree:

- **Pool-file override:** `oauth-pool-helper.sh:37` and the V1 runtime honour `AIDEVOPS_OAUTH_POOL_FILE`; `_resolve_oauth_pool_available` reads only `MODEL_AVAILABILITY_OAUTH_POOL_FILE` or the default path.
- **Non-runnable statuses:** `provider-auth.mjs:286` writes `status: "billing-error"`. The availability predicate accepts it (it rejects only `auth-error` and cooling `rate-limited`), so the probe records healthy and skips HTTP. The runtime selects only `active`/`idle` accounts without an active cooldown (`provider-auth-pool.mjs:59-64`).
- **V2 root:** the generated V2 shim resolves the pool as `${AIDEVOPS_OPENCODE_V2_OAUTH_POOL_FILE:-${AIDEVOPS_OPENCODE_V2_ROOT:-$HOME/.aidevops/runtimes/opencode-v2}/auth/oauth-pool.json}` (`setup/modules/tool-install.sh:1061`, `:1074`). The headless check ignores `AIDEVOPS_OPENCODE_V2_ROOT`.

None of these regress V1 today, but switching the default profile to V2 (#35902) would expose the pool split to every user.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** Skeletons only; the worker writes the final jq/python bodies.
- [x] **Targets and reference pattern verified?**
- [x] **No semantic or design decision remains?** Resolution order, allowlist and gating are decided below.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?**
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?** Neither file is listed in `.agents/configs/self-hosting-files.conf`.

**Selected tier:** `tier:standard`

**Tier rationale:** Decided resolver order and allowlist, applied to two known functions plus one new small lib; the worker completes the function bodies from the verified patterns.

## PR Conventions

Leaf task: the PR body uses `Resolves` with this task's issue number. Reference the parent with `For #35902`.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/oauth-pool-usable-lib.sh` — two pure, read-only functions (below). Model the header, SPDX lines and guard on another small sourced lib such as `.agents/scripts/model-availability-probe-lib.sh`.
- `EDIT: .agents/scripts/model-availability-helper.sh` — source the lib next to the other `source "${SCRIPT_DIR}/..."` lines (`:502`, `:506`). Reimplement `_resolve_oauth_pool_available` on top of it, and gate Source 5 in `resolve_api_key` on `auth.json` being absent.
- `EDIT: .agents/scripts/headless-runtime-provider.sh` — source the lib, then reimplement `opencode2_oauth_pool_auth_available` on top of it. Keep its `[[ -f "$auth_file" ]] && return 1` gate.
- `EDIT: .agents/scripts/tests/test-model-availability-oauth-probe.sh` and `EDIT: .agents/scripts/tests/test-headless-runtime-oauth-pool-gate.sh` — only where existing cases pin the old resolution or status behaviour.

### Complete Write Surface

- **Callers/readers:** `resolve_api_key` (model-availability-helper.sh) and `provider_auth_available` (headless-runtime-provider.sh:133) are the only callers. `headless-runtime-provider.sh` is sourced by `headless-runtime-lib.sh:138` and `ai-research-helper.sh:30`; both set `SCRIPT_DIR` and load `shared-constants.sh`.
- **Writers/mutation paths:** none. Both functions are read-only; pool writers (`oauth-pool-helper.sh`, the plugin) are unchanged.
- **Existing verification/tests:** `test-model-availability-oauth-probe.sh`, `test-headless-runtime-oauth-pool-gate.sh`, `test-headless-provider-round-robin.sh`, `test-ai-research-helper-oauth-pool.sh`.
- **Schemas/config:** pool JSON schema `oauth-pool-storage.mjs:30` (`status` ∈ active|idle|rate-limited|auth-error; `billing-error` is written at `provider-auth.mjs:286` but is not in the typedef). No change.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`; the new lib deploys with them, no manifest change.
- **Migrations/backfills:** N/A because both functions are read-only and no stored state (`oauth-pool.json`, `auth.json`) changes shape.
- **Cleanup/rollback paths:** revert the PR; `_resolve_oauth_pool_available` and `opencode2_oauth_pool_auth_available` return to their post-#39097 bodies and `oauth-pool-usable-lib.sh` is removed.

### Implementation Steps

1. Create the lib with two functions:

```bash
# oauth_pool_runtime_file: echo the pool file the active OpenCode runtime
# authenticates from. Mirrors oauth-pool-helper.sh:37 (V1) and the generated
# V2 shim (setup/modules/tool-install.sh:1061,1074).
oauth_pool_runtime_file() {
	local profile="v1"
	if declare -F aidevops_opencode_profile_id >/dev/null 2>&1; then
		profile=$(aidevops_opencode_profile_id 2>/dev/null) || profile="v1"
	fi
	if [[ "$profile" == "v2" ]]; then
		local v2_root="${AIDEVOPS_OPENCODE_V2_ROOT:-${HOME}/.aidevops/runtimes/opencode-v2}"
		printf '%s\n' "${AIDEVOPS_OPENCODE_V2_OAUTH_POOL_FILE:-${v2_root}/auth/oauth-pool.json}"
	else
		printf '%s\n' "${AIDEVOPS_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}"
	fi
	return 0
}

# oauth_pool_has_usable_account PROVIDER POOL_FILE: exit 0 when the pool holds
# at least one runnable account. Allowlist (matches provider-auth-pool.mjs:59-64
# plus expired rate-limit normalisation): status missing/active/idle with no
# active cooldown, or rate-limited whose cooldown has expired. Everything else
# (auth-error, billing-error, unknown) is not runnable. Missing file, missing
# jq, malformed JSON or a non-array provider entry return 1. Never prints
# credential material.
oauth_pool_has_usable_account() {
	local provider="$1"
	local pool_file="$2"
	# jq body: map(select(status in allowlist and cooldownUntil <= now)) | length > 0
	return 1
}
```

   Use `aidevops_opencode_profile_id` (`shared-constants.sh:247`) as the profile resolver. Do not read `AIDEVOPS_OPENCODE_PROFILE` directly; #39276 is moving headless code onto the profile document.

2. `model-availability-helper.sh`: `_resolve_oauth_pool_available` computes `pool_file="${MODEL_AVAILABILITY_OAUTH_POOL_FILE:-$(oauth_pool_runtime_file)}"`; the availability override stays first because existing tests use it. Then return `oauth_pool_has_usable_account "$provider" "$pool_file"`. In `resolve_api_key`, run Source 5 only when `${HOME}/.local/share/opencode/auth.json` does not exist.
3. `headless-runtime-provider.sh`: in `opencode2_oauth_pool_auth_available`, keep the `auth.json` gate. Replace the inline pool path selection and the python predicate with the two lib calls.
4. Run `shellcheck -x` on all changed scripts, then the four suites listed under Verification.

### Hazards and Compatibility

- **Concurrency/atomicity:** read-only JSON reads. A concurrent plugin write can at worst yield a malformed read, which returns 1 (unavailable for one probe), the same as today.
- **Migration/rollback:** no state changes; revert is a clean code revert.
- **Mixed-version/backward compatibility:** keep `MODEL_AVAILABILITY_OAUTH_POOL_FILE` as the highest-priority override. V1 users with no override get the same path as before. V2 users without `AIDEVOPS_OPENCODE_V2_ROOT` get the same path as before.
- **Idempotency/retry:** pure functions; safe to call repeatedly.
- **Partial failure/recovery:** if python3 or the profile helper is missing, `aidevops_opencode_profile_id` falls back to `v1`; the lib must also default to `v1` when the function is undefined.

### Complexity Impact

- **Target function:** `opencode2_oauth_pool_auth_available` in `headless-runtime-provider.sh`
- **Current line count:** ~47 lines (post-#39097)
- **Estimated growth:** about −35 lines (inline python replaced by lib calls)
- **Projected post-change:** ~12 lines
- **Action required:** None.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/oauth-pool-usable-lib.sh .agents/scripts/model-availability-helper.sh .agents/scripts/headless-runtime-provider.sh
bash .agents/scripts/tests/test-model-availability-oauth-probe.sh
bash .agents/scripts/tests/test-headless-runtime-oauth-pool-gate.sh
bash .agents/scripts/tests/test-headless-provider-round-robin.sh
bash .agents/scripts/tests/test-ai-research-helper-oauth-pool.sh
# Production path, sandboxed HOME with no auth.json and one billing-error account:
#   model-availability-helper.sh probe anthropic --force  -> no key (not healthy)
```

- **Surface mapping:** shellcheck covers all three scripts. The probe suite covers Source 5 and the override order. The gate and round-robin suites cover the headless predicate. The ai-research suite covers the second sourcer of the provider lib.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** do not change pool writers, the plugin JS, or setup's shim generation. Do not change headless profile resolution beyond calling `aidevops_opencode_profile_id` (#39276 owns that).

**AI brief owner:** maintainer interactive session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/oauth-pool-usable-lib.sh`
- `.agents/scripts/model-availability-helper.sh`
- `.agents/scripts/headless-runtime-provider.sh`
- `.agents/scripts/tests/test-model-availability-oauth-probe.sh`
- `.agents/scripts/tests/test-headless-runtime-oauth-pool-gate.sh`

## Acceptance Criteria

- [ ] Both checks call `oauth_pool_has_usable_account` and `oauth_pool_runtime_file` from the new lib.

  ```yaml
  verify:
    method: bash
    run: "rg -q 'oauth_pool_has_usable_account' .agents/scripts/model-availability-helper.sh && rg -q 'oauth_pool_has_usable_account' .agents/scripts/headless-runtime-provider.sh"
  ```

- [ ] With `AIDEVOPS_OAUTH_POOL_FILE` pointing at a pool with one `active` anthropic account and no `auth.json`, the availability probe reports anthropic healthy. With `AIDEVOPS_OPENCODE_PROFILE=v2` and `AIDEVOPS_OPENCODE_V2_ROOT=<dir>`, the headless check reads `<dir>/auth/oauth-pool.json`.
- [ ] Negative regression: each check rejects a pool whose only anthropic account is `billing-error` (any cooldown), and Source 5 is never consulted when `auth.json` exists.

  ```yaml
  verify:
    method: codebase
    pattern: "!= \"auth-error\"\\)"
    path: ".agents/scripts/model-availability-helper.sh"
    expect: absent
  ```

- [ ] The four suites listed under Verification pass, and ShellCheck is clean on changed files.

## Context & Decisions

- Allowlist, not denylist: unknown future statuses must fail closed, as the runtime does.
- `MODEL_AVAILABILITY_OAUTH_POOL_FILE` keeps priority so existing tests and operator overrides are unchanged.
- Source 5 gating on `auth.json` absence was earlier review finding P2 on PR #39097. It keeps availability aligned with headless selection, which already applies the same gate.
- Ruled out: deriving pool eligibility from `opencode auth list` (OpenCode 2 store). That is a separate option from the #39095 issue and is not needed once both checks agree.

## Relevant Files

- `.agents/scripts/oauth-pool-helper.sh:37` — V1 pool path resolution to mirror.
- `.agents/scripts/setup/modules/tool-install.sh:1061-1075` — V2 shim pool path resolution to mirror.
- `.agents/plugins/opencode-aidevops/provider-auth-pool.mjs:59-64` — runtime account eligibility rule.
- `.agents/plugins/opencode-aidevops/provider-auth.mjs:286` — writer of `billing-error`.
- `.agents/scripts/shared-constants.sh:247` — `aidevops_opencode_profile_id`.
- `.agents/scripts/headless-runtime-provider.sh:133` — `provider_auth_available`, the caller of the headless check.

## Dependencies

- **Blocked by:** #39095 (PR #39097 merge introduces the target functions).
- **Blocks:** the V2 default-profile switch tracked on #35902.
- **External:** none.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | the two functions, the shim lines, the runtime eligibility rule |
| Implementation | 45m | new lib plus two call sites |
| Verification | 20m | four suites, shellcheck, sandboxed probe |
| **Total** | **1h20m** | |
