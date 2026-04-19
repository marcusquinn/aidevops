---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2249: Restore headless OAuth rotation via XDG_DATA_HOME-aware auth path

## Origin

- **Created:** 2026-04-18
- **Session:** Claude-code:interactive-2026-04-18
- **Created by:** marcusquinn (human, operator during live dispatch outage diagnosis)
- **Parent task:** none
- **Conversation context:** Pulse worker cascade failure investigated 2026-04-18 22:00-22:15 UTC. Root cause traced to interaction of two April 1st PRs: PR #15114 added per-worker XDG_DATA_HOME auth isolation; PR #15099 disabled headless OAuth rotation entirely to protect interactive sessions from shared `auth.json` mutation. The rotation skip was never revisited after auth isolation shipped. Result: when the active pool account hits rate_limit (anthropic-side window longer than the 60s DB backoff), every subsequent headless worker inherits the same rate-limited auth, sees "backed off" → exits 75 → wastes a full dispatch cycle. Pool has 3 accounts, 2 available, but headless can't reach them.

## What

Make `oauth-pool-helper.sh` `XDG_DATA_HOME`-aware so OAuth rotation targets whichever `auth.json` the current shell is pointing at — the shared `~/.local/share/opencode/auth.json` for interactive sessions, the isolated `$XDG_DATA_HOME/opencode/auth.json` for headless workers. With that in place, restore pool rotation for headless workers at the moments it matters:

1. **Pre-dispatch** (new): before the worker spawns, if the account that was copied into its isolated auth is currently in cooldown per the shared pool, rotate the **isolated** file to a healthy account. This is the change that actually prevents wasted dispatches.
2. **In-flight** (restore): when a worker detects rate_limit mid-run, continue calling `mark-failure` (already safe), and update comments to reflect that `rotate` is also now safe — but keep the mid-run rotation skipped because opencode caches tokens in memory and won't re-read the auth file for the current session.

Interactive behaviour must remain byte-for-byte identical (no `XDG_DATA_HOME` export → same hardcoded path → same rotation semantics).

## Why

The current design has a silent failure mode: single-provider OAuth pools with multiple accounts cascade-fail on rate_limit because headless workers can't rotate to healthy accounts. Observed impact during the 2026-04-18 22:00-22:15 UTC outage:

- 6+ issues dispatched, 6 workers died in 140-byte logs with "is currently backed off"
- Fast-fail counters climbed to 600s backoff per issue → 10 min × 6 issues = 1h of dispatch capacity wasted
- Pool was healthy the whole time (2 of 3 accounts available) but inaccessible to headless

The rotation capability existed before PR #15099 (2026-04-01) and was removed as a defensive workaround for the shared-file collision that PR #15114 (same day) fixed properly. This task closes the loop.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — 3 files (oauth-pool-helper.sh, headless-runtime-helper.sh, headless-runtime-lib.sh) plus 3 new test files. Over the limit.
- [x] **Every target file under 500 lines?** — `oauth-pool-helper.sh` is 2101 lines, `headless-runtime-helper.sh` is 1329 lines, `headless-runtime-lib.sh` is 2107 lines. All over 500.
- [x] **Exact `oldString`/`newString` for every edit?** — Provided below for the one-line change; the rest require judgment.
- [x] **No judgment or design decisions?** — Pre-dispatch cooldown check has design decisions (exactly when to rotate, how to detect "current account", concurrency safety).
- [x] **No error handling or fallback logic to design?** — Needs fallback when rotate fails, when pool read fails, when jq is missing. Graceful degradation.
- [x] **No cross-package or cross-module changes?** — Touches 3 related scripts.
- [x] **Estimate 1h or less?** — 2-3h interactive implementation + testing.
- [x] **4 or fewer acceptance criteria?** — 7 criteria below.

**Selected tier:** `tier:thinking`

**Tier rationale:** Safety-critical OAuth auth-file handling across 3 large scripts. The pre-dispatch rotation logic requires designing a cooldown-detection mechanism, choosing the right concurrency primitive, and avoiding regressions in interactive token rotation. Failure modes (killing interactive session, race conditions between concurrent workers) are severe. Worth opus-tier reasoning even though each individual change is small.

## PR Conventions

Leaf task, non-parent. PR body will use `Resolves #NNN`.

## How (Approach)

### Worker Quick-Start

```bash
# 1. The keystone one-liner:
grep -n "^OPENCODE_AUTH_FILE=" .agents/scripts/oauth-pool-helper.sh
# Current: OPENCODE_AUTH_FILE="${HOME}/.local/share/opencode/auth.json"
# Target:  OPENCODE_AUTH_FILE="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/auth.json"

# 2. The pool structure (email -> cooldownUntil is what we check):
jq '.anthropic[] | {email, status, cooldownUntil}' ~/.aidevops/oauth-pool.json

# 3. Existing isolation site to hook into:
grep -n "aidevops-worker-auth" .agents/scripts/headless-runtime-helper.sh
# Line 321 creates isolated_data_dir, 325 copies shared->isolated, 333 exports XDG_DATA_HOME
```

### Files to Modify

- `EDIT: .agents/scripts/oauth-pool-helper.sh:31` — one-line XDG-aware path
- `EDIT: .agents/scripts/headless-runtime-helper.sh:320-335` — after copy, before export: pre-dispatch rotate-if-cooldown check
- `EDIT: .agents/scripts/headless-runtime-lib.sh:305-356` — update `attempt_pool_recovery` comment block to reflect isolation-safe reality; keep mid-run rotation skipped (opencode caches tokens)
- `NEW: .agents/scripts/tests/test-oauth-xdg-aware-path.sh` — verify `XDG_DATA_HOME=/tmp/x oauth-pool-helper.sh` targets `/tmp/x/opencode/auth.json`
- `NEW: .agents/scripts/tests/test-oauth-pre-dispatch-rotation.sh` — verify pre-dispatch rotate swaps account when current is in cooldown
- `NEW: .agents/scripts/tests/test-oauth-interactive-unaffected.sh` — verify shared auth.json byte-identical after a headless worker rotates its isolated copy

### Implementation Steps

**Step 1: Make `oauth-pool-helper.sh` XDG-aware (the keystone)**

```diff
--- a/.agents/scripts/oauth-pool-helper.sh
+++ b/.agents/scripts/oauth-pool-helper.sh
@@ -28,7 +28,11 @@
 POOL_FILE="${AIDEVOPS_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}"
-OPENCODE_AUTH_FILE="${HOME}/.local/share/opencode/auth.json"
+# XDG-aware auth path (t2249): resolves to the isolated per-worker auth.json
+# when called from a headless worker context (XDG_DATA_HOME set by
+# invoke_opencode), and to the shared interactive file otherwise.
+# This is what makes rotate safe for concurrent interactive + headless usage.
+OPENCODE_AUTH_FILE="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/auth.json"
```

**Step 2: Add pre-dispatch rotation in `headless-runtime-helper.sh`**

In `invoke_opencode`, after the copy at line 325 and after `export XDG_DATA_HOME="$isolated_data_dir"` at line 333, before the opencode child spawns:

```bash
# Pre-dispatch pool check (t2249): if the account in the isolated auth
# is currently in cooldown per pool metadata, rotate the isolated file
# to a healthy account. Prevents wasted dispatches on known-dead accounts.
# Safe because OPENCODE_AUTH_FILE now resolves via XDG_DATA_HOME — rotate
# writes to the ISOLATED file, not the shared interactive auth.json.
if [[ -x "$OAUTH_POOL_HELPER" && -f "${isolated_data_dir}/opencode/auth.json" ]]; then
    _maybe_rotate_isolated_auth "${isolated_data_dir}/opencode/auth.json" "anthropic"
fi
```

Where `_maybe_rotate_isolated_auth` is a new helper (same file) that:

1. Reads `.anthropic.email` from the isolated auth.json via `jq`
2. Reads `cooldownUntil` for that email from the shared pool file via `jq`
3. If `cooldownUntil > now_ms`, invokes `XDG_DATA_HOME="$isolated_dir" "$OAUTH_POOL_HELPER" rotate anthropic` (the env export is already active but explicit is clearer in logs)
4. Logs the rotation decision (`[lifecycle] pre_dispatch_rotate: ... -> ...`)
5. Exits 0 always — best-effort, failure shouldn't block dispatch

**Step 3: Update `attempt_pool_recovery` comments in `headless-runtime-lib.sh`**

Replace the "DANGEROUS" comment block (lines 305-320 of the OLD `headless-runtime-helper.sh` before split, now `headless-runtime-lib.sh` around line 320-355) with a current-state explanation:

```diff
-	# DANGEROUS: rotate rewrites the shared auth.json -- SKIP for headless workers.
-	# Only record backoff so the pre-dispatch check routes to the other provider.
-	# Interactive sessions handle rotation explicitly via `oauth-pool-helper.sh rotate`.
-	print_warning "${provider} ${reason} detected; recorded backoff (rotation skipped -- interactive-only)"
+	# t2249: `oauth-pool-helper.sh` is now XDG_DATA_HOME-aware, so rotation
+	# from a headless worker targets the worker's ISOLATED auth.json, not
+	# the shared interactive file. Mid-run rotation is still skipped here
+	# because opencode caches auth tokens in memory for the active session —
+	# rewriting auth.json mid-run doesn't affect the already-running model
+	# call. The pool `mark-failure` above IS the useful signal: it updates
+	# shared pool metadata so the pre-dispatch check in invoke_opencode will
+	# rotate the NEXT worker to a healthy account.
+	print_warning "${provider} ${reason} detected; recorded backoff (in-flight rotation no-op — opencode token cache)"
```

**Step 4: Regression tests**

`test-oauth-xdg-aware-path.sh`: source `oauth-pool-helper.sh` with and without `XDG_DATA_HOME` set, assert `OPENCODE_AUTH_FILE` resolves correctly.

`test-oauth-pre-dispatch-rotation.sh`: seed a fake pool with one account in cooldown + one available. Create isolated dir, copy fake auth. Invoke `_maybe_rotate_isolated_auth`. Assert isolated auth.json email changes. Assert shared auth.json unchanged.

`test-oauth-interactive-unaffected.sh`: record shared auth.json hash. Run `XDG_DATA_HOME=/tmp/xxx oauth-pool-helper.sh rotate anthropic` (against a test pool). Assert hash of `~/.local/share/opencode/auth.json` is unchanged.

### Verification

```bash
# One-shot verification covering all 3 tests:
for t in .agents/scripts/tests/test-oauth-xdg-aware-path.sh \
         .agents/scripts/tests/test-oauth-pre-dispatch-rotation.sh \
         .agents/scripts/tests/test-oauth-interactive-unaffected.sh; do
    bash "$t" || { echo "FAIL: $t"; exit 1; }
done

# ShellCheck all touched scripts:
shellcheck .agents/scripts/oauth-pool-helper.sh \
           .agents/scripts/headless-runtime-helper.sh \
           .agents/scripts/headless-runtime-lib.sh

# Live smoke (optional, requires real pool): dispatch a worker, tail its log,
# confirm the [lifecycle] pre_dispatch_rotate line appears when appropriate
# and no "rotation skipped -- interactive-only" messages are emitted.
```

## Acceptance Criteria

- [ ] `OPENCODE_AUTH_FILE` in `oauth-pool-helper.sh` respects `XDG_DATA_HOME` when set.
- [ ] `invoke_opencode` calls a pre-dispatch rotation check that uses the shared pool metadata to decide whether to rotate the isolated auth.
- [ ] Pre-dispatch rotation writes ONLY to the isolated `$XDG_DATA_HOME/opencode/auth.json`, never to `~/.local/share/opencode/auth.json`.
- [ ] Interactive session behaviour (no `XDG_DATA_HOME` set, shared auth.json) is byte-for-byte identical — verified by test-oauth-interactive-unaffected.sh.
- [ ] Comment in `headless-runtime-lib.sh` accurately reflects the new reality (no stale "DANGEROUS" warning).
- [ ] All 3 new regression tests pass.
- [ ] ShellCheck clean on all 3 modified scripts.

## Context & Decisions

- **Why XDG_DATA_HOME over a custom env var:** opencode already uses `$XDG_DATA_HOME/opencode/auth.json` as its canonical auth path (confirmed in `headless-runtime-helper.sh:307`). Reusing the same variable keeps the pool helper aligned with opencode's own filesystem conventions — no new coupling.
- **Why NOT in-flight rotation:** opencode's internal OAuth client caches access tokens in memory for the active session. Rewriting `auth.json` mid-run doesn't invalidate those cached tokens. The useful signal is `mark-failure` (which we keep), because the NEXT dispatch's pre-dispatch check will read the updated pool metadata and route around the rate-limited account.
- **Why NOT always-rotate pre-dispatch:** `oauth-pool-helper.sh rotate` always picks a DIFFERENT account from the current one. Unconditional rotation would cycle through the pool on every dispatch, fragmenting rate-limit quotas and ignoring account priorities. Conditional rotation (only when cooldown) preserves sticky routing when it's healthy.
- **Concurrency:** `_rotate_execute` already holds an advisory lock (`POOL_FILE_PATH` + `AUTH_FILE_PATH` env vars drive an atomic pool+auth update under `flock`). Two concurrent workers hitting `rotate` at the same time will serialize correctly.
- **Alternatives considered and rejected:**
  1. _Split env vars (e.g., `AIDEVOPS_POOL_AUTH_FILE`)_ — cleaner in isolation but introduces a new coupling point; XDG_DATA_HOME is the existing standard.
  2. _Pass `--target-file` flag to rotate_ — explicit but requires wiring through `pool_ops.py` + all callers; env var inheritance is simpler.
  3. _Always rotate on every dispatch_ — disrespects priority, fragments quotas. See "Why NOT" above.

## Relevant Files

- `.agents/scripts/oauth-pool-helper.sh:31` — the keystone line to change
- `.agents/scripts/oauth-pool-helper.sh:1207-1213` — `_rotate_execute` that passes `AUTH_FILE_PATH` env to `pool_ops.py` (already parameterised correctly)
- `.agents/scripts/oauth-pool-helper.sh:1263-1311` — `cmd_rotate` entry point, uses `$OPENCODE_AUTH_FILE` (which becomes XDG-aware)
- `.agents/scripts/headless-runtime-helper.sh:305-335` — auth isolation site; PRE-dispatch rotation hook goes here
- `.agents/scripts/headless-runtime-lib.sh:305-356` — `attempt_pool_recovery`; comment block to update
- `.agents/scripts/oauth-pool-lib/pool_ops.py` — Python rotation/refresh/mark-failure implementations; no changes needed (already reads `AUTH_FILE_PATH` env)
- PR #15099 (MERGED 2026-04-01) — introduced the "interactive-only" skip this task reverses
- PR #15114 (MERGED 2026-04-01) — introduced the XDG_DATA_HOME auth isolation this task completes

## Dependencies

- **Blocked by:** none
- **Blocks:** reliable cascade dispatch under rate_limit cascades; any future multi-provider pool coordination work
- **External:** none — purely code change, no secrets or services

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | oauth-pool-helper.sh:1200-1350, headless-runtime-helper.sh:300-340, pool_ops.py internals |
| Implementation | 90m | 1-line path change + pre-dispatch helper (~30 lines) + comment updates |
| Testing | 45m | Three new test harnesses with stubbed pool fixtures |
| **Total** | **~2h15m** | Safety-critical code path — worth thorough testing |
