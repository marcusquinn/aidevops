<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2097: Fail-loud on GraphQL rate limit exhaustion in pulse prefetch

## Origin

- **Created:** 2026-04-14
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none — spun off from GH#18976 investigation
- **Conversation context:** Review of GH#18976 identified that the proposed REST API fallback for GraphQL exhaustion has multiple risks (PR/issue filter, field mapping, dispatch-dedup label drift, cache schema consistency). The bug's actual symptom — pulse cycles no-op silently while holding the instance lock — is fixable in isolation with ~40 lines by making the existing error handlers detect rate-limit errors, log them loudly, and abort the cycle cleanly. The broader question of whether to add a REST fallback, reduce consumption, or both, is deferred to GH#18976 as an investigation. This task ships the minimum viable fix for observability and lock-release discipline.

## What

The pulse prefetch cluster has five `gh` call sites that currently swallow all errors — on failure they log a single line to `$LOGFILE` and replace the result with `"[]"`. When the failure mode is GraphQL rate-limit exhaustion, the pulse proceeds to dispatch decisions with empty data, does nothing useful, and releases the instance lock only at the end of the cycle. The cycle appears successful in logs (no fatal error) and the exhaustion is visible only as "Open PRs (0)" / "Open Issues (0)" next to a stale `gh api rate_limit` reading.

After this change:

1. A shared helper `_pulse_gh_err_is_rate_limit` classifies stderr text to detect GraphQL/REST rate-limit errors.
2. Every prefetch call site that currently has a silent-fallback handler additionally calls the classifier. On rate-limit detection it logs a loud, greppable `RATE_LIMIT_EXHAUSTED` line and touches a flag file `$PULSE_RATE_LIMIT_FLAG`.
3. `_preflight_prefetch_and_scope` (in `pulse-dispatch-engine.sh`) checks the flag after `prefetch_state` returns. If set, it logs a summary, increments `_PULSE_HEALTH_PREFETCH_ERRORS`, removes the flag file, and returns 1 — which the existing call chain (`_run_preflight_stages` → `run()`) already handles by aborting the cycle cleanly and releasing the instance lock.
4. The existing `"[]"` fallback behaviour is preserved for non-rate-limit errors (network blips, transient 5xx) so the change is not a general destabilization — only rate-limit exhaustion triggers the abort.

Observable outcome after a forced or natural exhaustion:

- Log line `[pulse-wrapper] GraphQL RATE_LIMIT_EXHAUSTED during <function>` appears at WARN level.
- `_preflight_prefetch_and_scope` logs a summary: `[pulse-wrapper] Prefetch aborted due to GraphQL rate-limit exhaustion — skipping cycle`.
- Instance lock is released within seconds of the prefetch phase starting (currently ~3 min because the prefetch runs to completion with empty data and the rest of the cycle then runs on stale state).
- `_PULSE_HEALTH_PREFETCH_ERRORS` counter increments, which surfaces in the health snapshot.
- No worker dispatch happens (the cycle returns early).

## Why

Observed on 2026-04-08 and 2026-04-14: the pulse's GraphQL budget (5000/hr) was fully exhausted, causing `_prefetch_repo_prs` / `_prefetch_repo_issues` to return empty arrays silently. The pulse held the instance lock for its full cycle duration (3+ min observed) while doing zero useful work, preventing subsequent cycles from running the deterministic merge pass, dep graph, routine evaluation, and health snapshot. This is a reliability bug: the pulse appears to be "running" but accomplishes nothing, and the symptom (empty data) is indistinguishable from a genuinely quiet repo in the log.

The root cause of the exhaustion itself (is the pulse consuming the budget, or is it a shared-consumer problem?) and the question of whether to add a REST API fallback for continued operation during exhaustion are deferred to GH#18976 for investigation. This task fixes only the silent-failure symptom so that (a) exhaustion events are visible in the log, (b) the instance lock releases immediately, and (c) the next cycle can run once GraphQL recovers.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — 2 files: `pulse-prefetch.sh`, `pulse-dispatch-engine.sh`
- [x] **Complete code blocks for every edit?** — yes, below
- [x] **No judgment or design decisions?** — the error patterns are well-known; integration point already exists
- [ ] **No error handling or fallback logic to design?** — NO: this task IS error-handling logic. That's an automatic `tier:standard`.
- [x] **Estimate 1h or less?**
- [x] **4 or fewer acceptance criteria?**

**Selected tier:** `tier:standard`

**Tier rationale:** Fails one disqualifier (error-handling design), so not `tier:simple`. Two files, narrow scope, existing integration point — well within `tier:standard`. Interactive implementation, so tier is informational only (no dispatch).

## PR Conventions

Leaf task. PR body will use `Resolves #<new-issue>` and `For #18976` to link both sides.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-prefetch.sh` — add classifier helper near top of file (after the header block, before the first function). Wire it into 5 existing error handlers at lines 607-612, 654-658, 788-793, 1768-1773, 1875-1880.
- `EDIT: .agents/scripts/pulse-dispatch-engine.sh:1175-1192` — check the rate-limit flag after `prefetch_state` returns, abort the cycle if set.

### Implementation Steps

1. **Add the flag-file constant** in `pulse-wrapper.sh` config block (around line 294 where `PULSE_PREFETCH_CACHE_FILE` is defined):

    ```bash
    PULSE_RATE_LIMIT_FLAG="${PULSE_RATE_LIMIT_FLAG:-${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}" # GH#<NEW>: set by prefetch on detected GraphQL rate-limit exhaustion; checked by _preflight_prefetch_and_scope to abort cycle cleanly
    ```

2. **Add the classifier helper** at the top of `pulse-prefetch.sh` (after the module guard and header comments, before the first function):

    ```bash
    #######################################
    # Classify a gh CLI stderr blob as a rate-limit exhaustion error.
    #
    # gh surfaces GraphQL budget exhaustion in several forms depending on
    # which endpoint triggered it. This helper matches the common phrases
    # case-insensitively. REST core exhaustion is also matched in case a
    # future prefetch site uses gh api directly.
    #
    # Arguments:
    #   $1 - path to stderr file (or "-" to read stdin)
    # Returns:
    #   0 if stderr indicates rate-limit exhaustion
    #   1 otherwise
    #######################################
    _pulse_gh_err_is_rate_limit() {
    	local err_file="$1"
    	[[ -n "$err_file" && -s "$err_file" ]] || return 1
    	# Match patterns observed from gh CLI when GraphQL/REST budget is spent.
    	# Keep this list narrow — false positives would turn network blips into
    	# cycle aborts. Case-insensitive via grep -i.
    	grep -qiE 'API rate limit exceeded|rate limit exceeded for|was submitted too quickly|secondary rate limit|GraphQL: API rate limit' "$err_file"
    }

    #######################################
    # Mark the current cycle as rate-limited.
    #
    # Writes a timestamp + context line to the flag file. Idempotent — if the
    # flag already exists from an earlier prefetch site in the same cycle,
    # append the new context so postmortem logs show all affected sites.
    #
    # Arguments:
    #   $1 - context string (function name + repo slug)
    #######################################
    _pulse_mark_rate_limited() {
    	local context="$1"
    	local ts
    	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    	mkdir -p "$(dirname "$PULSE_RATE_LIMIT_FLAG")" 2>/dev/null || true
    	printf '%s %s\n' "$ts" "$context" >>"$PULSE_RATE_LIMIT_FLAG"
    	echo "[pulse-wrapper] GraphQL RATE_LIMIT_EXHAUSTED during ${context}" >>"$LOGFILE"
    }
    ```

3. **Wire into `_prefetch_repo_prs`** at the existing error handler (current lines 607-612):

    ```bash
    		if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
    			local err_msg
    			err_msg=$(cat "$pr_err" 2>/dev/null || echo "unknown error")
    			if _pulse_gh_err_is_rate_limit "$pr_err"; then
    				_pulse_mark_rate_limited "_prefetch_repo_prs:${slug}"
    			fi
    			echo "[pulse-wrapper] _prefetch_repo_prs: gh pr list FAILED for ${slug}: ${err_msg}" >>"$LOGFILE"
    			pr_json="[]"
    		fi
    ```

4. **Wire into `_prefetch_repo_daily_cap`** at existing error handler (current lines 654-658):

    ```bash
    	if [[ -z "$daily_cap_json" || "$daily_cap_json" == "null" ]]; then
    		local _daily_cap_err_msg
    		_daily_cap_err_msg=$(cat "$daily_cap_err" 2>/dev/null || echo "unknown error")
    		if _pulse_gh_err_is_rate_limit "$daily_cap_err"; then
    			_pulse_mark_rate_limited "_prefetch_repo_daily_cap:${slug}"
    		fi
    		echo "[pulse-wrapper] _prefetch_repo_daily_cap: gh pr list FAILED for ${slug}: ${_daily_cap_err_msg}" >>"$LOGFILE"
    		daily_cap_json="[]"
    	fi
    ```

5. **Wire into `_prefetch_repo_issues`** at existing error handler (current lines 788-793):

    ```bash
    		if [[ -z "$issue_json" || "$issue_json" == "null" ]]; then
    			local issue_err_msg
    			issue_err_msg=$(cat "$issue_err" 2>/dev/null || echo "unknown error")
    			if _pulse_gh_err_is_rate_limit "$issue_err"; then
    				_pulse_mark_rate_limited "_prefetch_repo_issues:${slug}"
    			fi
    			echo "[pulse-wrapper] _prefetch_repo_issues: gh issue list FAILED for ${slug}: ${issue_err_msg}" >>"$LOGFILE"
    			issue_json="[]"
    		fi
    ```

6. **Wire into `prefetch_triage_review_status`** (NMR scan, current lines 1768-1773):

    ```bash
    		if [[ -z "$nmr_json" || "$nmr_json" == "null" ]]; then
    			local _nmr_err_msg
    			_nmr_err_msg=$(cat "$nmr_err" 2>/dev/null || echo "unknown error")
    			if _pulse_gh_err_is_rate_limit "$nmr_err"; then
    				_pulse_mark_rate_limited "prefetch_triage_review_status:${slug}"
    			fi
    			echo "[pulse-wrapper] prefetch_triage_review_status: gh issue list FAILED for ${slug}: ${_nmr_err_msg}" >>"$LOGFILE"
    			nmr_json="[]"
    		fi
    ```

7. **Wire into `prefetch_needs_info_replies`** (current lines 1875-1880):

    ```bash
    		if [[ -z "$ni_json" || "$ni_json" == "null" ]]; then
    			local _ni_err_msg
    			_ni_err_msg=$(cat "$ni_err" 2>/dev/null || echo "unknown error")
    			if _pulse_gh_err_is_rate_limit "$ni_err"; then
    				_pulse_mark_rate_limited "prefetch_needs_info_replies:${slug}"
    			fi
    			echo "[pulse-wrapper] prefetch_needs_info_replies: gh issue list FAILED for ${slug}: ${_ni_err_msg}" >>"$LOGFILE"
    			ni_json="[]"
    		fi
    ```

8. **Check the flag in `_preflight_prefetch_and_scope`** (`pulse-dispatch-engine.sh:1175-1192`):

    ```bash
    _preflight_prefetch_and_scope() {
    	# Clear any stale flag from a previous cycle — only the current
    	# cycle's prefetch should set it.
    	rm -f "$PULSE_RATE_LIMIT_FLAG" 2>/dev/null || true

    	if ! run_stage_with_timeout "prefetch_state" "$PRE_RUN_STAGE_TIMEOUT" prefetch_state; then
    		echo "[pulse-wrapper] prefetch_state did not complete successfully — aborting this cycle to avoid stale dispatch decisions" >>"$LOGFILE"
    		_PULSE_HEALTH_PREFETCH_ERRORS=$((_PULSE_HEALTH_PREFETCH_ERRORS + 1))
    		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
    		return 1
    	fi

    	# GH#<NEW>: if any prefetch site detected GraphQL rate-limit exhaustion,
    	# abort the cycle cleanly. Empty prefetch data is indistinguishable from
    	# a genuinely quiet backlog; proceeding would run the deterministic pipeline
    	# on stale state. The flag is cleared at the top of the next cycle.
    	if [[ -f "$PULSE_RATE_LIMIT_FLAG" ]]; then
    		local affected_sites
    		affected_sites=$(wc -l <"$PULSE_RATE_LIMIT_FLAG" 2>/dev/null | tr -d ' ' || echo "?")
    		echo "[pulse-wrapper] Prefetch aborted due to GraphQL rate-limit exhaustion (${affected_sites} site(s) affected) — skipping cycle" >>"$LOGFILE"
    		_PULSE_HEALTH_PREFETCH_ERRORS=$((_PULSE_HEALTH_PREFETCH_ERRORS + 1))
    		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
    		return 1
    	fi

    	if [[ -f "$SCOPE_FILE" ]]; then
    		local persisted_scope
    		persisted_scope=$(cat "$SCOPE_FILE" 2>/dev/null || echo "")
    		if [[ -n "$persisted_scope" ]]; then
    			export PULSE_SCOPE_REPOS="$persisted_scope"
    			echo "[pulse-wrapper] Restored PULSE_SCOPE_REPOS from ${SCOPE_FILE}" >>"$LOGFILE"
    		fi
    	fi
    	return 0
    }
    ```

9. **Shellcheck both files** — no new warnings:

    ```bash
    shellcheck .agents/scripts/pulse-prefetch.sh .agents/scripts/pulse-dispatch-engine.sh
    ```

10. **Unit test the classifier** — create a minimal test harness that verifies the classifier matches known rate-limit strings and rejects unrelated errors (network timeout, auth failure). New file `.agents/scripts/tests/test-pulse-rate-limit-classifier.sh`.

### Verification

```bash
# 1. Shellcheck clean (no new warnings)
shellcheck .agents/scripts/pulse-prefetch.sh \
           .agents/scripts/pulse-dispatch-engine.sh \
           .agents/scripts/pulse-wrapper.sh

# 2. Classifier unit test
bash .agents/scripts/tests/test-pulse-rate-limit-classifier.sh

# 3. Dry-run smoke test (existing characterization harness)
.agents/scripts/pulse-wrapper.sh --self-check

# 4. Manual simulation: seed the flag file and observe abort
touch "${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag"
echo "2026-04-14T00:00:00Z test" > "${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag"
bash -c 'source .agents/scripts/pulse-wrapper.sh; _preflight_prefetch_and_scope' 2>&1 | tail -5
# Expected: "Prefetch aborted due to GraphQL rate-limit exhaustion" appears in LOGFILE
#           Return code 1
rm -f "${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag"
```

## Acceptance Criteria

- [ ] Classifier helper `_pulse_gh_err_is_rate_limit` added to `pulse-prefetch.sh` and matches observed rate-limit error strings case-insensitively.
- [ ] All 5 existing prefetch error handlers call the classifier and touch the flag file on rate-limit detection, without disturbing the existing `"[]"` fallback for other errors.
- [ ] `_preflight_prefetch_and_scope` checks the flag after prefetch and returns 1 when set, logging a summary and incrementing `_PULSE_HEALTH_PREFETCH_ERRORS`.
- [ ] Flag file is cleared at the top of each prefetch cycle so stale entries from a previous cycle don't cause false aborts.
- [ ] Shellcheck runs clean on all three touched files.
- [ ] Classifier unit test covers: positive matches (rate limit exceeded, secondary rate limit, GraphQL: API rate limit) and negative matches (network timeout, auth failure, 404).
- [ ] PR body links both sides: `Resolves #<new>` and `For #18976`.

## Context / Reference

- **Issue under investigation:** GH#18976 — proposes REST API fallback for GraphQL exhaustion. This task ships the narrow fail-loud fix; the broader solution is deferred to that issue.
- **Precedent for REST fallback** (for GH#18976, not this task): PR #4363 added REST fallback to `review-bot-gate-helper.sh`.
- **Cycle control path:** `run()` → `_run_preflight_stages` (dispatch-engine.sh:1199) → `_preflight_prefetch_and_scope` (dispatch-engine.sh:1175) → `prefetch_state` (prefetch.sh). A non-zero return from `_preflight_prefetch_and_scope` already aborts the cycle cleanly and releases the instance lock via the normal `run()` exit path.
- **Delta prefetch interaction:** Delta fetches at lines 222-231, 464, 513, 722 call `gh` too, but they fall back to full fetch on any error — the full fetch is what hits the rate-limit site. No direct wiring needed at delta sites; the downstream full fetch catches it.
- **Why `"[]"` fallback stays for non-rate-limit errors:** the pulse must tolerate transient network blips without aborting every cycle. Only rate-limit exhaustion — which is the specific failure mode where empty data is indistinguishable from quiet — triggers the cycle abort.
