#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-simplification.sh — Codebase simplification subsystem — shell+markdown complexity scanning, LLM-driven sweeps, simplification-state hash registry, duplicate-issue dedup, CI threshold proximity guards, weekly scan orchestrator.
#
# Extracted from pulse-wrapper.sh in Phase 6 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This was the LARGEST single extraction in the plan — 29 functions covering
# the entire codebase-simplification subsystem. The cluster is self-contained
# at the call-graph level (heavy intra-cluster calls, only 8 outbound edges
# to dispatch-core + orchestrator), so extracting as one module preserved
# locality.
#
# **t2020 / GH#18483**: the state-registry sub-cluster (7 functions handling
# .agents/configs/simplification-state.json) was moved out to
# `pulse-simplification-state.sh` to drop this file below the 2,000-line gate
# that was blocking #18420 (t1993). The extracted functions are still resolved
# at call time via Bash name resolution — both modules are sourced from
# pulse-wrapper.sh, so the cross-module call
# `_simplification_state_backfill_closed -> _complexity_scan_has_existing_issue`
# continues to work unchanged.
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / COMPLEXITY_* / SIMPLIFICATION_*
# configuration constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _complexity_scan_check_interval
#   - _coderabbit_review_check_interval
#   - run_daily_codebase_review
#   - _run_post_merge_review_scanner
#   - _complexity_scan_tree_hash
#   - _complexity_scan_tree_changed
#   - _complexity_llm_sweep_due
#   - _complexity_run_llm_sweep
#   - _complexity_scan_find_repo
#   - _complexity_scan_collect_violations
#   - _complexity_scan_should_open_md_issue
#   - _complexity_scan_collect_md_violations
#   - _complexity_scan_extract_md_topic_label
#   - _complexity_scan_has_existing_issue
#   - _complexity_scan_close_duplicate_issues_by_title
#   - _complexity_scan_build_md_issue_body
#   - _complexity_scan_check_open_cap
#   - _complexity_scan_md_file_status        (extracted from _complexity_scan_process_single_md_file, GH#18653)
#   - _complexity_scan_md_build_full_body    (extracted from _complexity_scan_process_single_md_file, GH#18653)
#   - _complexity_scan_process_single_md_file
#   - _complexity_scan_create_md_issues
#   - _complexity_scan_sh_build_issue_body_with_sig  (extracted from _complexity_scan_create_issues, GH#18653)
#   - _complexity_scan_sh_create_issue       (extracted from _complexity_scan_create_issues, GH#18653)
#   - _complexity_scan_create_issues
#   - run_simplification_dedup_cleanup
#   - _check_ci_nesting_read_threshold       (extracted from _check_ci_nesting_threshold_proximity, GH#18653)
#   - _check_ci_nesting_count_violations     (extracted from _check_ci_nesting_threshold_proximity, GH#18653)
#   - _check_ci_nesting_build_issue_body     (extracted from _check_ci_nesting_threshold_proximity, GH#18653)
#   - _check_ci_nesting_threshold_proximity
#   - run_weekly_complexity_scan
#
# Functions moved to pulse-simplification-state.sh (t2020, GH#18483):
#   - _simplification_state_check
#   - _simplification_state_record
#   - _simplification_state_refresh
#   - _simplification_state_prune
#   - _simplification_state_push
#   - _create_requeue_issue
#   - _simplification_state_backfill_closed
#
# This is a pure move from pulse-wrapper.sh. Function bodies are
# byte-identical to their pre-extraction form.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_SIMPLIFICATION_LOADED:-}" ]] && return 0
_PULSE_SIMPLIFICATION_LOADED=1

# Check if the complexity scan interval has elapsed.
# Arguments: $1 - now_epoch (current epoch seconds)
# Returns: 0 if scan is due, 1 if not yet due
_complexity_scan_check_interval() {
	local now_epoch="$1"
	if [[ ! -f "$COMPLEXITY_SCAN_LAST_RUN" ]]; then
		return 0
	fi
	local last_run
	last_run=$(cat "$COMPLEXITY_SCAN_LAST_RUN" 2>/dev/null || echo "0")
	[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
	local elapsed=$((now_epoch - last_run))
	if [[ "$elapsed" -lt "$COMPLEXITY_SCAN_INTERVAL" ]]; then
		local remaining=$(((COMPLEXITY_SCAN_INTERVAL - elapsed) / 3600))
		echo "[pulse-wrapper] Complexity scan not due yet (${remaining}h remaining)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

# Emit the list of pulse-enabled, non-local-only slugs from the given
# repos.json path, one per line. Extracted from _run_post_merge_review_scanner
# et al. so new scanner wrappers don't duplicate the jq filter (t2442).
# Arguments: $1 - repos_json path
# Outputs: newline-separated slugs on stdout
_pulse_enabled_repo_slugs() {
	local repos_json="$1"
	[[ -f "$repos_json" ]] || return 0
	jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null || true
	return 0
}

# Check if the daily CodeRabbit codebase review interval has elapsed.
# Models on _complexity_scan_check_interval which has never regressed (GH#17640).
# Arguments: $1 - now_epoch (current epoch seconds)
# Returns: 0 if review is due, 1 if not yet due
_coderabbit_review_check_interval() {
	local now_epoch="$1"
	if [[ ! -f "$CODERABBIT_REVIEW_LAST_RUN" ]]; then
		return 0
	fi
	local last_run
	last_run=$(cat "$CODERABBIT_REVIEW_LAST_RUN" 2>/dev/null || echo "0")
	[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
	local elapsed=$((now_epoch - last_run))
	if [[ "$elapsed" -lt "$CODERABBIT_REVIEW_INTERVAL" ]]; then
		local remaining=$(((CODERABBIT_REVIEW_INTERVAL - elapsed) / 3600))
		echo "[pulse-wrapper] CodeRabbit codebase review not due yet (${remaining}h remaining)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Daily full codebase review via CodeRabbit (GH#17640).
#
# Posts "@coderabbitai Please run a full codebase review" on issue #2632
# once per 24h. Uses a simple timestamp file gate (same pattern as
# _complexity_scan_check_interval) to avoid duplicate posts.
#
# Previous implementations regressed because they checked complex quality
# gate status instead of a plain time-based interval. This version uses
# the same pattern as the complexity scan which has never regressed.
#
# Actionable findings from the review are routed through
# quality-feedback-helper.sh to create tracked issues.
#######################################
run_daily_codebase_review() {
	local aidevops_slug="marcusquinn/aidevops"

	# t2145: CodeRabbit review triggers issue-creating scanners — maintainer-only.
	local _cr_role
	_cr_role=$(get_repo_role_by_slug "$aidevops_slug")
	if [[ "$_cr_role" != "maintainer" ]]; then
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s)

	# Time gate: skip if last review was <24h ago
	_coderabbit_review_check_interval "$now_epoch" || return 0

	# Permission gate: only collaborators with write+ may trigger reviews
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null) || current_user=""
	if [[ -z "$current_user" ]]; then
		echo "[pulse-wrapper] CodeRabbit review: skipped — cannot determine current user" >>"$LOGFILE"
		return 0
	fi
	local perm_level
	perm_level=$(gh api "repos/${aidevops_slug}/collaborators/${current_user}/permission" \
		--jq '.permission' 2>/dev/null) || perm_level=""
	case "$perm_level" in
	admin | maintain | write) ;; # allowed
	*)
		echo "[pulse-wrapper] CodeRabbit review: skipped — user '$current_user' has '$perm_level' permission on $aidevops_slug (need write+)" >>"$LOGFILE"
		return 0
		;;
	esac

	echo "[pulse-wrapper] Posting daily CodeRabbit full codebase review request on #${CODERABBIT_REVIEW_ISSUE} (GH#17640)..." >>"$LOGFILE"

	# Post the review trigger comment
	if gh_issue_comment "$CODERABBIT_REVIEW_ISSUE" \
		--repo "$aidevops_slug" \
		--body "@coderabbitai Please run a full codebase review" 2>>"$LOGFILE"; then
		# Update timestamp only on successful post
		printf '%s\n' "$now_epoch" >"$CODERABBIT_REVIEW_LAST_RUN"
		echo "[pulse-wrapper] CodeRabbit review: posted successfully, next review in ~24h" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] CodeRabbit review: failed to post comment on #${CODERABBIT_REVIEW_ISSUE}" >>"$LOGFILE"
		return 1
	fi

	# Route actionable findings through quality-feedback-helper if available
	local qfh="${SCRIPT_DIR}/quality-feedback-helper.sh"
	if [[ -x "$qfh" ]]; then
		echo "[pulse-wrapper] CodeRabbit review: findings will be processed by quality-feedback-helper.sh on next cycle" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Daily post-merge review scanner (t1993).
#
# Scans recently merged PRs in pulse-enabled repos for actionable AI bot
# review comments (CodeRabbit, Gemini Code Assist, claude-review, gpt-review)
# and creates review-followup issues. Idempotent via existing dedup in
# post-merge-review-scanner.sh's issue_exists() guard.
#
# Time-gated to run at most once per POST_MERGE_SCANNER_INTERVAL (default 24h).
# Reference pattern: run_daily_codebase_review.
#######################################
_run_post_merge_review_scanner() {
	local now_epoch
	now_epoch=$(date +%s)

	# Time gate: skip if last run was within the interval
	if [[ -f "$POST_MERGE_SCANNER_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$POST_MERGE_SCANNER_LAST_RUN" 2>/dev/null || echo "0")
		[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
		local elapsed=$((now_epoch - last_run))
		if [[ "$elapsed" -lt "$POST_MERGE_SCANNER_INTERVAL" ]]; then
			return 0
		fi
	fi

	local scanner="${SCRIPT_DIR}/post-merge-review-scanner.sh"
	if [[ ! -x "$scanner" ]]; then
		echo "[pulse-wrapper] Post-merge scanner: helper not found or not executable: $scanner" >>"$LOGFILE"
		return 0
	fi

	# Iterate pulse-enabled repos; scan each. Scanner is idempotent —
	# existing review-followup issues are skipped via issue_exists().
	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local total_repos=0
	local skipped_contributor=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		# t2145: skip repos where the user is a contributor, not the maintainer.
		# Scanners that scrape repo data (PR bot comments) duplicate what the
		# maintainer's own pulse already sees, creating NMR noise.
		local repo_role
		repo_role=$(get_repo_role_by_slug "$slug")
		if [[ "$repo_role" != "maintainer" ]]; then
			skipped_contributor=$((skipped_contributor + 1))
			continue
		fi
		total_repos=$((total_repos + 1))
		echo "[pulse-wrapper] Post-merge scanner: scanning $slug" >>"$LOGFILE"
		SCANNER_DAYS="${SCANNER_DAYS:-7}" "$scanner" scan "$slug" >>"$LOGFILE" 2>&1 || true
	done < <(_pulse_enabled_repo_slugs "$repos_json")
	if [[ "$skipped_contributor" -gt 0 ]]; then
		echo "[pulse-wrapper] Post-merge scanner: skipped ${skipped_contributor} contributor-role repo(s) (t2145)" >>"$LOGFILE"
	fi

	printf '%s\n' "$now_epoch" >"$POST_MERGE_SCANNER_LAST_RUN"
	echo "[pulse-wrapper] Post-merge scanner: completed ${total_repos} repo(s), next run in ~$((POST_MERGE_SCANNER_INTERVAL / 3600))h" >>"$LOGFILE"
	return 0
}

#######################################
# Per-cycle auto-decomposer scanner (t2442, tightened t2573).
#
# Scans pulse-enabled (maintainer-role) repos for parent-task issues
# whose <!-- parent-needs-decomposition --> nudge has aged without
# a human response, and files worker-ready tier:thinking issues asking
# the dispatched worker to decompose the parent into child issues.
#
# Closes the pre-t2442 dispatch black hole: before this, a parent-task
# with no children could sit forever because the `parent-task` label
# blocks dispatch unconditionally, but the reconciler's nudge comment
# was advisory-only.
#
# Idempotent via auto-decomposer-scanner.sh's title + source:auto-decomposer
# label dedup — re-runs skip parents that already have a decompose issue
# in any state. Per-parent state file (AUTO_DECOMPOSER_PARENT_STATE)
# prevents re-filing the same parent within AUTO_DECOMPOSER_INTERVAL
# (default 7 days). t2573 removed the global 24h run gate to allow
# scanning every pulse cycle and clearing multiple parents per day.
# Reference pattern: _run_post_merge_review_scanner.
#######################################
_run_auto_decomposer_scanner() {
	local scanner="${SCRIPT_DIR}/auto-decomposer-scanner.sh"
	if [[ ! -x "$scanner" ]]; then
		echo "[pulse-wrapper] Auto-decomposer: helper not found or not executable: $scanner" >>"$LOGFILE"
		return 0
	fi

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local total_repos=0
	local skipped_contributor=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		# t2145 parity with post-merge-review-scanner: skip contributor-role
		# repos. The auto-decomposer creates issues directly; we only want
		# that in repos where the user is the maintainer.
		local repo_role
		repo_role=$(get_repo_role_by_slug "$slug")
		if [[ "$repo_role" != "maintainer" ]]; then
			skipped_contributor=$((skipped_contributor + 1))
			continue
		fi
		total_repos=$((total_repos + 1))
		echo "[pulse-wrapper] Auto-decomposer: scanning $slug" >>"$LOGFILE"
		"$scanner" scan "$slug" >>"$LOGFILE" 2>&1 || true
	done < <(_pulse_enabled_repo_slugs "$repos_json")
	if [[ "$skipped_contributor" -gt 0 ]]; then
		echo "[pulse-wrapper] Auto-decomposer: skipped ${skipped_contributor} contributor-role repo(s) (t2145)" >>"$LOGFILE"
	fi

	echo "[pulse-wrapper] Auto-decomposer: completed ${total_repos} repo(s) (per-parent re-file gate: $((AUTO_DECOMPOSER_INTERVAL / 86400))d)" >>"$LOGFILE"
	return 0
}

# Compute a deterministic tree hash for the files the complexity scan cares about.
# Uses git ls-tree to hash the current state of .agents/ *.sh and *.md files.
# This is O(1) — a single git command, not per-file iteration.
# Arguments: $1 - repo_path
# Outputs: tree hash string to stdout (empty on failure)
_complexity_scan_tree_hash() {
	local repo_path="$1"
	# Hash the tree of .agents/ tracked files — covers both .sh and .md targets.
	# git ls-tree -r HEAD outputs blob hashes + paths; piping through sha256sum
	# gives a single stable hash that changes iff any tracked file changes.
	# Capture output first: sha256sum always produces output (even for empty input),
	# so an empty-check on the pipeline result is unreliable (GH#18555).
	local tree_data
	tree_data=$(git -C "$repo_path" ls-tree -r HEAD -- .agents/ 2>/dev/null)
	if [[ -z "$tree_data" ]]; then
		return 0
	fi
	printf '%s\n' "$tree_data" | awk '{print $3, $4}' | sha256sum 2>/dev/null | awk '{print $1}' || true
	return 0
}

# Check whether the repo tree has changed since the last complexity scan.
# Compares current tree hash against the cached value in COMPLEXITY_SCAN_TREE_HASH_FILE.
# Arguments: $1 - repo_path
# Returns: 0 if changed (scan needed), 1 if unchanged (skip)
# Side effect: updates COMPLEXITY_SCAN_TREE_HASH_FILE when changed
_complexity_scan_tree_changed() {
	local repo_path="$1"
	local current_hash
	current_hash=$(_complexity_scan_tree_hash "$repo_path")
	if [[ -z "$current_hash" ]]; then
		# Cannot compute hash — proceed with scan to be safe
		return 0
	fi
	local cached_hash=""
	if [[ -f "$COMPLEXITY_SCAN_TREE_HASH_FILE" ]]; then
		cached_hash=$(cat "$COMPLEXITY_SCAN_TREE_HASH_FILE" 2>/dev/null || true)
	fi
	if [[ "$current_hash" == "$cached_hash" ]]; then
		echo "[pulse-wrapper] Complexity scan: tree unchanged since last scan — skipping file iteration" >>"$LOGFILE"
		return 1
	fi
	# Tree changed — update cache and signal scan needed
	printf '%s\n' "$current_hash" >"$COMPLEXITY_SCAN_TREE_HASH_FILE"
	return 0
}

# Check if the daily LLM sweep is due and debt is stalled.
# The LLM sweep fires when:
#   1. COMPLEXITY_LLM_SWEEP_INTERVAL has elapsed since last sweep, AND
#   2. The open function-complexity-debt count has not decreased since last check
# Arguments: $1 - now_epoch, $2 - aidevops_slug
# Returns: 0 if sweep is due, 1 if not due
_complexity_llm_sweep_due() {
	local now_epoch="$1"
	local aidevops_slug="$2"

	# Interval guard
	if [[ -f "$COMPLEXITY_LLM_SWEEP_LAST_RUN" ]]; then
		local last_sweep
		last_sweep=$(cat "$COMPLEXITY_LLM_SWEEP_LAST_RUN" 2>/dev/null || echo "0")
		[[ "$last_sweep" =~ ^[0-9]+$ ]] || last_sweep=0
		local elapsed=$((now_epoch - last_sweep))
		if [[ "$elapsed" -lt "$COMPLEXITY_LLM_SWEEP_INTERVAL" ]]; then
			return 1
		fi
	fi

	# Fetch current open debt count
	local current_count
	current_count=$(gh api graphql \
		-f query="query { repository(owner:\"${aidevops_slug%%/*}\", name:\"${aidevops_slug##*/}\") { issues(labels:[\"function-complexity-debt\"], states:OPEN) { totalCount } } }" \
		--jq '.data.repository.issues.totalCount' 2>/dev/null) || current_count=""
	[[ "$current_count" =~ ^[0-9]+$ ]] || return 1

	# Compare against last recorded count
	local prev_count=""
	if [[ -f "$COMPLEXITY_DEBT_COUNT_FILE" ]]; then
		prev_count=$(cat "$COMPLEXITY_DEBT_COUNT_FILE" 2>/dev/null || true)
	fi

	# Always update the count file
	printf '%s\n' "$current_count" >"$COMPLEXITY_DEBT_COUNT_FILE"

	# No sweep needed when debt is already zero — nothing to act on (GH#17422)
	if [[ "$current_count" -eq 0 ]]; then
		echo "[pulse-wrapper] Complexity LLM sweep: debt is zero, no sweep required" >>"$LOGFILE"
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
		return 1
	fi

	# Sweep is due if debt count has not decreased (stalled or growing)
	if [[ -n "$prev_count" && "$prev_count" =~ ^[0-9]+$ ]]; then
		if [[ "$current_count" -lt "$prev_count" ]]; then
			echo "[pulse-wrapper] Complexity LLM sweep: debt reduced (${prev_count} → ${current_count}) — sweep not needed" >>"$LOGFILE"
			printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
			return 1
		fi
	fi

	# GH#17536: Skip sweep when all remaining debt issues are already dispatched.
	# If every open function-complexity-debt issue (excluding sweep meta-issues) has
	# status:queued or status:in-progress, the pipeline is working — no sweep needed.
	local dispatched_count
	dispatched_count=$(gh issue list --repo "$aidevops_slug" \
		--label "function-complexity-debt" --state open \
		--json number,title,labels --jq '
		[.[] | select(.title | test("stalled|LLM sweep") | not)] |
		if length == 0 then 0
		else
			[.[] | select(.labels | map(.name) | (index("status:queued") or index("status:in-progress")))] | length
		end' 2>/dev/null) || dispatched_count=""
	local actionable_count
	actionable_count=$(gh issue list --repo "$aidevops_slug" \
		--label "function-complexity-debt" --state open \
		--json number,title --jq '[.[] | select(.title | test("stalled|LLM sweep") | not)] | length' 2>/dev/null) || actionable_count=""
	if [[ "$actionable_count" =~ ^[0-9]+$ && "$dispatched_count" =~ ^[0-9]+$ && "$actionable_count" -gt 0 && "$dispatched_count" -ge "$actionable_count" ]]; then
		echo "[pulse-wrapper] Complexity LLM sweep: all ${actionable_count} debt issues are dispatched — sweep not needed" >>"$LOGFILE"
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
		return 1
	fi

	echo "[pulse-wrapper] Complexity LLM sweep: debt stalled at ${current_count} (prev: ${prev_count:-unknown}, dispatched: ${dispatched_count:-?}/${actionable_count:-?}) — sweep due" >>"$LOGFILE"
	return 0
}

# Run the daily LLM sweep: create a GitHub issue asking the LLM to review
# why simplification debt is stalled and suggest approach adjustments.
# Arguments: $1 - aidevops_slug, $2 - now_epoch, $3 - maintainer
# Returns: 0 always (best-effort)
_complexity_run_llm_sweep() {
	local aidevops_slug="$1"
	local now_epoch="$2"
	local maintainer="$3"

	# Dedup: check if an open sweep issue already exists (t1855).
	# Both sweep code paths use different title patterns — check both.
	local sweep_exists
	sweep_exists=$(gh issue list --repo "$aidevops_slug" \
		--label "function-complexity-debt" --state open \
		--search "in:title \"simplification debt stalled\"" \
		--json number --jq 'length' 2>/dev/null) || sweep_exists="0"
	if [[ "${sweep_exists:-0}" -gt 0 ]]; then
		echo "[pulse-wrapper] Complexity LLM sweep: skipping — open stall issue already exists" >>"$LOGFILE"
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
		return 0
	fi

	local current_count=""
	if [[ -f "$COMPLEXITY_DEBT_COUNT_FILE" ]]; then
		current_count=$(cat "$COMPLEXITY_DEBT_COUNT_FILE" 2>/dev/null || true)
	fi

	local sweep_body
	sweep_body="## Simplification debt stall — LLM sweep (automated, GH#15285)

**Open function-complexity-debt issues:** ${current_count:-unknown}

The simplification debt count has not decreased in the last $((COMPLEXITY_LLM_SWEEP_INTERVAL / 3600))h. This issue is a prompt for the LLM to review the current state and suggest approach adjustments.

### Questions to investigate

1. Are the open function-complexity-debt issues actionable? Check for issues that are blocked, stale, or need maintainer review.
2. Are workers dispatching on function-complexity-debt issues? Check recent pulse logs for dispatch activity.
3. Is the open cap (500) being hit? If so, consider raising it or closing stale issues.
4. Are there systemic blockers (e.g., all remaining issues require architectural decisions)?

### Suggested actions

- Review the oldest 10 open function-complexity-debt issues and close any that are no longer relevant.
- Check if \`tier:simple\` and \`tier:standard\` issues are being dispatched — if not, verify the pulse is routing them correctly.
- If debt is growing, consider lowering \`COMPLEXITY_MD_MIN_LINES\` or \`COMPLEXITY_FILE_VIOLATION_THRESHOLD\` to catch more candidates.

### Confidence: low

This is an automated stall-detection sweep. The LLM should review the actual issue list before acting.

---
**To dismiss**, comment \`dismissed: <reason>\` on this issue."

	# Append signature footer
	local sig_footer="" _sweep_elapsed=""
	_sweep_elapsed=$((now_epoch - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$sweep_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_sweep_elapsed" --session-type routine 2>/dev/null || true)
	sweep_body="${sweep_body}${sig_footer}"

	# Skip needs-maintainer-review when user is maintainer (GH#16786)
	local sweep_review_label=""
	if [[ "${_COMPLEXITY_SCAN_SKIP_REVIEW_GATE:-false}" != "true" ]]; then
		sweep_review_label="--label needs-maintainer-review"
	fi
	# shellcheck disable=SC2086
	# t1955: Don't self-assign on issue creation — let dispatch_with_dedup handle
	# assignment. Self-assigning creates a phantom claim that triggers stale recovery
	# on other runners, producing audit trail gaps.
	if gh_create_issue --repo "$aidevops_slug" \
		--title "perf: simplification debt stalled — LLM sweep needed ($(date -u +%Y-%m-%d))" \
		--label "function-complexity-debt" $sweep_review_label --label "tier:thinking" \
		--body "$sweep_body" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Complexity LLM sweep: created stall-review issue" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Complexity LLM sweep: failed to create stall-review issue" >>"$LOGFILE"
	fi

	printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
	return 0
}

# Resolve the aidevops repo path and validate lint-file-discovery.sh exists.
# Arguments: $1 - repos_json path, $2 - aidevops_slug, $3 - now_epoch
# Outputs: aidevops_path via stdout (empty on failure)
# Returns: 0 on success, 1 on failure (also writes last-run timestamp on failure)
_complexity_scan_find_repo() {
	local repos_json="$1"
	local aidevops_slug="$2"
	local now_epoch="$3"
	local aidevops_path=""
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		aidevops_path=$(jq -r --arg slug "$aidevops_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .path' \
			"$repos_json" 2>/dev/null | head -n 1)
	fi
	if [[ -z "$aidevops_path" || "$aidevops_path" == "null" || ! -d "$aidevops_path" ]]; then
		echo "[pulse-wrapper] Complexity scan: aidevops repo path not found — skipping" >>"$LOGFILE"
		echo "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 1
	fi
	local lint_discovery="${aidevops_path}/.agents/scripts/lint-file-discovery.sh"
	if [[ ! -f "$lint_discovery" ]]; then
		echo "[pulse-wrapper] Complexity scan: lint-file-discovery.sh not found — skipping" >>"$LOGFILE"
		echo "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 1
	fi
	echo "$aidevops_path"
	return 0
}

# Collect per-file violation counts from shell files in the repo.
# Arguments: $1 - aidevops_path, $2 - now_epoch
# Outputs: scan_results (pipe-delimited lines: file_path|count) via stdout
# Side effect: logs total violation count; writes last-run on no files found
_complexity_scan_collect_violations() {
	local aidevops_path="$1"
	local now_epoch="$2"
	local shell_files
	shell_files=$(git -C "$aidevops_path" ls-files '*.sh' | grep -Ev '_archive/' || true)
	if [[ -z "$shell_files" ]]; then
		echo "[pulse-wrapper] Complexity scan: no shell files found — skipping" >>"$LOGFILE"
		echo "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 1
	fi
	local scan_results=""
	local total_violations=0
	local files_with_violations=0
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local full_path="${aidevops_path}/${file}"
		[[ -f "$full_path" ]] || continue
		local result
		# Use -v to pass the threshold safely — interpolating shell variables into
		# awk scripts is a security risk and breaks if the value contains quotes (GH#18555).
		result=$(awk -v threshold="$COMPLEXITY_FUNC_LINE_THRESHOLD" '
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { fname=$1; sub(/\(\)/, "", fname); start=NR; next }
			fname && /^\}$/ { lines=NR-start; if(lines+0>threshold+0) printf "%s() %d lines\n", fname, lines; fname="" }
		' "$full_path")
		if [[ -n "$result" ]]; then
			local count
			count=$(echo "$result" | wc -l | tr -d ' ')
			total_violations=$((total_violations + count))
			files_with_violations=$((files_with_violations + 1))
			if [[ "$count" -ge "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" ]]; then
				# Use repo-relative path as dedup key (not basename — avoids collisions
				# between files with the same name in different directories, GH#5630)
				scan_results="${scan_results}${file}|${count}"$'\n'
			fi
		fi
	done <<<"$shell_files"
	echo "[pulse-wrapper] Complexity scan: ${total_violations} violations across ${files_with_violations} files" >>"$LOGFILE"
	printf '%s' "$scan_results"
	return 0
}

# Determine whether an agent doc qualifies for a simplification issue.
# Not every .agents/*.md file is actionable — very short files, empty stubs,
# and YAML-only frontmatter files are not candidates. This gate prevents
# flooding the issue tracker with non-actionable entries (CodeRabbit GH#6879).
# Arguments: $1 - full_path, $2 - line_count
# Returns: 0 if the file should get an issue, 1 if it should be skipped
_complexity_scan_should_open_md_issue() {
	local full_path="$1"
	local line_count="$2"

	# Skip files below the minimum actionable size
	if [[ "$line_count" -lt "$COMPLEXITY_MD_MIN_LINES" ]]; then
		return 1
	fi

	# Skip files that are mostly YAML frontmatter (e.g., stub agent definitions).
	# If >60% of lines are inside the frontmatter block, there's no prose to simplify.
	local frontmatter_end=0
	if head -1 "$full_path" 2>/dev/null | grep -q '^---$'; then
		frontmatter_end=$(awk 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { print NR; exit }' "$full_path" 2>/dev/null)
		frontmatter_end=${frontmatter_end:-0}
	fi
	if [[ "$frontmatter_end" -gt 0 ]]; then
		local content_lines=$((line_count - frontmatter_end))
		# If content after frontmatter is less than 40% of total, skip
		local threshold=$(((line_count * 40) / 100))
		if [[ "$content_lines" -lt "$threshold" ]]; then
			return 1
		fi
	fi

	return 0
}

# Collect agent docs (.md files in .agents/) for simplification analysis.
# No hard file size gate — classification (instruction doc vs reference corpus)
# determines the action, not line count (t1679, code-simplifier.md).
# Files must pass _complexity_scan_should_open_md_issue to be included —
# this filters out stubs, short files, and frontmatter-only definitions.
# Protected files (build.txt, AGENTS.md, pulse.md, pulse-sweep.md) are excluded — these are
# core infrastructure that must be simplified manually with a maintainer present.
# Results are sorted longest-first so biggest wins come early.
# Arguments: $1 - aidevops_path
# Outputs: scan_results (pipe-delimited lines: file_path|line_count) via stdout
_complexity_scan_collect_md_violations() {
	local aidevops_path="$1"

	# Protected files and directories — excluded from automated simplification.
	# - build.txt, AGENTS.md, pulse.md, pulse-sweep.md: core infrastructure (code-simplifier.md)
	# - templates/: template files meant to be copied, not compressed
	# - README.md: navigation/index docs, not instruction docs
	# - todo/: planning files, not code
	local protected_pattern='prompts/build\.txt|^\.agents/AGENTS\.md|^AGENTS\.md|scripts/commands/pulse\.md|scripts/commands/pulse-sweep\.md'
	local excluded_dirs='_archive/|/templates/|/todo/'
	local excluded_files='/README\.md$'

	local md_files
	md_files=$(git -C "$aidevops_path" ls-files '*.md' | grep -E '^\.agents/' | grep -Ev "$excluded_dirs" | grep -Ev "$excluded_files" | grep -Ev "$protected_pattern" || true)
	if [[ -z "$md_files" ]]; then
		echo "[pulse-wrapper] Complexity scan (.md): no agent doc files found" >>"$LOGFILE"
		return 1
	fi

	local scan_results=""
	local file_count=0
	local skipped_count=0
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local full_path="${aidevops_path}/${file}"
		[[ -f "$full_path" ]] || continue
		local lc
		lc=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ')
		if _complexity_scan_should_open_md_issue "$full_path" "$lc"; then
			scan_results="${scan_results}${file}|${lc}"$'\n'
			file_count=$((file_count + 1))
		else
			skipped_count=$((skipped_count + 1))
		fi
	done <<<"$md_files"

	# Sort longest-first (descending by line count after the pipe)
	scan_results=$(printf '%s' "$scan_results" | sort -t'|' -k2 -rn)

	echo "[pulse-wrapper] Complexity scan (.md): ${file_count} agent docs qualified, ${skipped_count} skipped (below ${COMPLEXITY_MD_MIN_LINES}-line threshold or stub)" >>"$LOGFILE"
	printf '%s' "$scan_results"
	return 0
}

# Extract a concise, meaningful topic label from a markdown file's H1 heading.
# For chapter-style headings such as "# Chapter 13: Heatmap Analysis", returns
# "Heatmap Analysis" so issue titles stay semantic instead of numeric-only.
# Arguments: $1 - aidevops_path, $2 - file_path (repo-relative)
# Outputs: topic label via stdout
_complexity_scan_extract_md_topic_label() {
	local aidevops_path="$1"
	local file_path="$2"
	local full_path="${aidevops_path}/${file_path}"

	if [[ ! -f "$full_path" ]]; then
		return 1
	fi

	local heading
	heading=$(awk '/^# / { print; exit }' "$full_path" 2>/dev/null)
	if [[ -z "$heading" ]]; then
		return 1
	fi

	local topic
	topic=$(printf '%s' "$heading" | sed -E 's/^#[[:space:]]*//; s/^[Cc][Hh][Aa][Pp][Tt][Ee][Rr][[:space:]]*[0-9]+[[:space:]]*[:.-]?[[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]]+$//')
	if [[ -z "$topic" ]]; then
		return 1
	fi

	# Keep issue titles concise and stable
	topic=$(printf '%s' "$topic" | cut -c1-80)
	printf '%s' "$topic"
	return 0
}

# Check if an open function-complexity-debt issue already exists for a given file.
#
# Uses GitHub search API via `gh issue list --search` to query server-side,
# avoiding the --limit 200 cap that caused duplicate issues (GH#10783).
# Previous approach fetched 200 issues locally and checked with jq, but with
# 3000+ open function-complexity-debt issues, most were invisible to the dedup check.
#
# Arguments:
#   $1 - repo_slug (owner/repo for gh commands)
#   $2 - issue_key (repo-relative file path used as dedup key)
# Exit codes:
#   0 - existing issue found (skip creation)
#   1 - no existing issue (safe to create)
_complexity_scan_has_existing_issue() {
	local repo_slug="$1"
	local issue_key="$2"

	# Server-side search by file path in title — accurate across all issues,
	# not limited by --limit pagination. The file path is always in the title.
	local match_count
	match_count=$(gh issue list --repo "$repo_slug" \
		--label "function-complexity-debt" --state open \
		--search "in:title \"$issue_key\"" \
		--json number --jq 'length' 2>/dev/null) || match_count="0"
	if [[ "${match_count:-0}" -gt 0 ]]; then
		return 0
	fi

	# Fallback: search in issue body for the structured **File:** field.
	# This catches issues where the title format differs (e.g., Qlty issues).
	match_count=$(gh issue list --repo "$repo_slug" \
		--label "function-complexity-debt" --state open \
		--search "\"$issue_key\" in:body" \
		--json number --jq 'length' 2>/dev/null) || match_count="0"

	if [[ "$match_count" -gt 0 ]]; then
		return 0
	fi

	return 1
}

# Close open duplicate function-complexity-debt issues for an exact title.
#
# This is a post-create race repair for cross-machine TOCTOU collisions:
# two runners can both pass pre-create dedup checks, then both create the
# same issue title seconds apart. This helper converges to a single open
# issue by keeping the newest and closing older duplicates immediately.
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - issue_title (exact title match)
# Returns:
#   0 always (best-effort)
_complexity_scan_close_duplicate_issues_by_title() {
	local repo_slug="$1"
	local issue_title="$2"

	local issue_numbers=""
	if ! issue_numbers=$(T="$issue_title" gh issue list --repo "$repo_slug" \
		--label "function-complexity-debt" --state open \
		--search "in:title \"${issue_title}\"" \
		--limit 100 --json number,title \
		--jq 'map(select(.title == env.T) | .number) | sort | .[]'); then
		echo "[pulse-wrapper] Complexity scan: failed to query duplicates for title: ${issue_title}" >>"$LOGFILE"
		return 0
	fi

	[[ -z "$issue_numbers" ]] && return 0

	local issue_count=0
	local keep_number=""
	local issue_number
	while IFS= read -r issue_number; do
		[[ -n "$issue_number" ]] || continue
		issue_count=$((issue_count + 1))
		# Keep the newest issue (largest number) for consistency with
		# run_simplification_dedup_cleanup.
		keep_number="$issue_number"
	done <<<"$issue_numbers"

	if [[ "$issue_count" -le 1 || -z "$keep_number" ]]; then
		return 0
	fi

	local closed_count=0
	while IFS= read -r issue_number; do
		[[ -n "$issue_number" ]] || continue
		[[ "$issue_number" == "$keep_number" ]] && continue
		if gh issue close "$issue_number" --repo "$repo_slug" --reason "not planned" \
			--comment "Auto-closing duplicate from concurrent simplification scan run. Keeping newest issue #${keep_number}." \
			>/dev/null 2>&1; then
			closed_count=$((closed_count + 1))
		fi
	done <<<"$issue_numbers"

	if [[ "$closed_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Complexity scan: closed ${closed_count} duplicate function-complexity-debt issue(s) for title: ${issue_title}" >>"$LOGFILE"
	fi

	return 0
}

# Build the GitHub issue body for an agent doc flagged for simplification review.
# Arguments:
#   $1 - file_path (repo-relative)
#   $2 - line_count
#   $3 - topic_label (may be empty)
# Output: issue body text to stdout
_complexity_scan_build_md_issue_body() {
	local file_path="$1"
	local line_count="$2"
	local topic_label="$3"

	cat <<ISSUE_BODY_EOF
<!-- aidevops:generator=function-complexity-gate cited_file=${file_path} threshold=${COMPLEXITY_MD_LINE_THRESHOLD:-500} -->

## Agent doc simplification (automated scan)

**File:** \`${file_path}\`
**Detected topic:** ${topic_label:-Unknown}
**Current size:** ${line_count} lines

### Classify before acting

**First, determine the file type** — the correct action depends on whether this is an instruction doc or a reference corpus:

- **Instruction doc** (agent rules, workflows, decision trees, operational procedures): Tighten prose, reorder by importance, split if multiple concerns. Follow guidance below.
- **Reference corpus** (SKILL.md, domain knowledge base, textbook-style content with self-contained sections): Do NOT compress content. Instead, split into chapter files with a slim index. See \`tools/code-review/code-simplifier.md\` "Reference corpora" classification (GH#6432).

### For instruction docs — proposed action

Tighten and restructure this agent doc. Follow \`tools/build-agent/build-agent.md\` guidance. Key principles:

1. **Preserve all institutional knowledge** — every verbose rule exists because something broke without it. Do not remove task IDs, incident references, error statistics, or decision rationale. Compress prose, not knowledge.
2. **Order by importance** — most critical instructions first (primacy effect: LLMs weight earlier context more heavily). Security rules, core workflow, then edge cases.
3. **Split if needed** — if the file covers multiple distinct concerns, extract sub-docs with a parent index. Use progressive disclosure (pointers, not inline content).
4. **Use search patterns, not line numbers** — any \`file:line_number\` references to other files go stale on every edit. Use \`rg "pattern"\` or section heading references instead.

### For reference corpora — proposed action

1. **Extract each major section** into its own file (e.g., \`01-introduction.md\`, \`02-fundamentals.md\`)
2. **Replace the original with a slim index** (~100-200 lines) — table of contents with one-line descriptions and file pointers
3. **Zero content loss** — every line moves to a chapter file, nothing is deleted or compressed
4. **Reconcile existing chapter files** — if partial splits already exist, deduplicate and keep the most complete version

### Worker guidance

**Reference pattern:** \`.agents/reference/large-file-split.md\` (playbook for splits — covers orchestrator pattern, identity-key preservation, and PR body template).

**Precedent in this repo:** \`issue-sync-helper.sh\` + \`issue-sync-lib.sh\` (simple split) and \`headless-runtime-lib.sh\` + sub-libraries (complex split). For agent docs, see existing chapter-file splits in \`.agents/reference/\`.

**Expected CI gate overrides:** If this PR triggers a complexity regression from restructured files, apply the \`complexity-bump-ok\` label AND include a \`## Complexity Bump Justification\` section in the PR body citing scanner evidence. See the playbook section 4 (Known CI False-Positive Classes).

### Verification

- Content preservation: all code blocks, URLs, task ID references (\`tNNN\`, \`GH#NNN\`), and command examples must be present before and after
- No broken internal links or references
- Agent behaviour unchanged (test with a representative query if possible)
- Qlty smells resolved for the target file: \`~/.qlty/bin/qlty smells --all 2>&1 | grep '${file_path}' | grep -c . | grep -q '^0$'\` (report \`SKIP\` if Qlty is unavailable, not \`FAIL\`)
- For reference corpora: \`wc -l\` total of chapter files >= original line count minus index overhead

### Confidence: medium

Automated scan flagged this file for maintainer review. The best simplification strategy requires human judgment — some files are appropriately structured already. Reference corpora (SKILL.md, domain knowledge bases) need restructuring into chapters, not content reduction.

---
**To approve or decline**, comment on this issue:
- \`approved\` — removes the review gate and queues for automated dispatch
- \`declined: <reason>\` — closes this issue (include your reason after the colon)
ISSUE_BODY_EOF
	return 0
}

# Check if the open function-complexity-debt issue backlog exceeds the cap.
# Arguments: $1 - aidevops_slug, $2 - cap (default 100), $3 - log_prefix
# Exit codes: 0 = under cap (safe to create), 1 = at/over cap (skip)
_complexity_scan_check_open_cap() {
	local aidevops_slug="$1"
	local cap="${2:-200}"
	local log_prefix="${3:-Complexity scan}"

	local total_open
	total_open=$(gh api graphql -f query="query { repository(owner:\"${aidevops_slug%%/*}\", name:\"${aidevops_slug##*/}\") { issues(labels:[\"function-complexity-debt\"], states:OPEN) { totalCount } } }" \
		--jq '.data.repository.issues.totalCount' 2>/dev/null) || total_open="0"
	if [[ "${total_open:-0}" -ge "$cap" ]]; then
		echo "[pulse-wrapper] ${log_prefix}: skipping — ${total_open} open function-complexity-debt issues (cap: ${cap})" >>"$LOGFILE"
		return 1
	fi
	return 0
}

# Determine early-exit status for a single agent doc file.
# Checks simplification state (unchanged/converged) and open-issue dedup.
# Arguments: $1 - aidevops_slug, $2 - file_path, $3 - state_file, $4 - aidevops_path
# Output: "unchanged"|"converged"|"existing"|"new"|"recheck" via stdout
# Returns: 0 always
_complexity_scan_md_file_status() {
	local aidevops_slug="$1"
	local file_path="$2"
	local state_file="$3"
	local aidevops_path="$4"

	local file_status="new"
	if [[ -n "$state_file" && -n "$aidevops_path" ]]; then
		file_status=$(_simplification_state_check "$aidevops_path" "$file_path" "$state_file")
		if [[ "$file_status" == "unchanged" || "$file_status" == "converged" ]]; then
			printf '%s' "$file_status"
			return 0
		fi
		# "recheck" falls through — gets a new issue with recheck label
	fi

	if _complexity_scan_has_existing_issue "$aidevops_slug" "$file_path"; then
		printf '%s' "existing"
		return 0
	fi

	printf '%s' "$file_status"
	return 0
}

# Build the full issue body for an agent doc: base body + optional recheck note + sig footer.
# Arguments: $1 - file_path, $2 - line_count, $3 - topic_label,
#            $4 - needs_recheck (true/false), $5 - state_file
# Output: full issue body to stdout
# Returns: 0 always
_complexity_scan_md_build_full_body() {
	local file_path="$1"
	local line_count="$2"
	local topic_label="$3"
	local needs_recheck="$4"
	local state_file="$5"

	local issue_body
	issue_body=$(_complexity_scan_build_md_issue_body "$file_path" "$line_count" "$topic_label")

	if [[ "$needs_recheck" == true ]]; then
		local prev_pr
		prev_pr=$(jq -r --arg fp "$file_path" '.files[$fp].pr // 0' "$state_file" 2>/dev/null) || prev_pr="0"
		issue_body="${issue_body}

### Recheck note

This file was previously simplified (PR #${prev_pr}) but has since been modified. The content hash no longer matches the post-simplification state. Please re-evaluate."
	fi

	# Append signature footer. The pulse-wrapper runs as standalone bash via
	# launchd (not inside OpenCode), so --no-session skips session DB lookups.
	# Pass elapsed time and 0 tokens to show honest stats (GH#13099).
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	printf '%s%s' "$issue_body" "$sig_footer"
	return 0
}

# Process a single agent doc file for simplification issue creation (GH#5627).
# Checks simplification state, dedup, changed-since-simplification status,
# builds title/body, and creates issue.
#
# Arguments:
#   $1 - file_path (repo-relative)
#   $2 - line_count
#   $3 - aidevops_slug
#   $4 - aidevops_path
#   $5 - state_file (may be empty)
#   $6 - maintainer
# Output: single line to stdout — "created", "skipped", or "failed"
_complexity_scan_process_single_md_file() {
	local file_path="$1"
	local line_count="$2"
	local aidevops_slug="$3"
	local aidevops_path="$4"
	local state_file="$5"
	local maintainer="$6"

	local file_status
	file_status=$(_complexity_scan_md_file_status "$aidevops_slug" "$file_path" "$state_file" "$aidevops_path")
	case "$file_status" in
	unchanged)
		echo "[pulse-wrapper] Complexity scan (.md): skipping ${file_path} — already simplified (hash unchanged)" >>"$LOGFILE"
		echo "skipped"
		return 0
		;;
	converged)
		echo "[pulse-wrapper] Complexity scan (.md): skipping ${file_path} — converged after ${SIMPLIFICATION_MAX_PASSES:-3} passes (t1754)" >>"$LOGFILE"
		echo "skipped"
		return 0
		;;
	existing)
		echo "[pulse-wrapper] Complexity scan (.md): skipping ${file_path} — existing open issue" >>"$LOGFILE"
		echo "skipped"
		return 0
		;;
	esac
	# file_status is "new" or "recheck" at this point

	local topic_label=""
	if [[ -n "$aidevops_path" ]]; then
		topic_label=$(_complexity_scan_extract_md_topic_label "$aidevops_path" "$file_path" 2>/dev/null || true)
	fi

	local needs_recheck=false
	[[ "$file_status" == "recheck" ]] && needs_recheck=true

	local issue_title="simplification: tighten agent doc ${file_path} (${line_count} lines)"
	if [[ -n "$topic_label" ]]; then
		issue_title="simplification: tighten agent doc ${topic_label} (${file_path}, ${line_count} lines)"
	fi
	[[ "$needs_recheck" == true ]] && issue_title="recheck: ${issue_title}"

	local issue_body
	issue_body=$(_complexity_scan_md_build_full_body "$file_path" "$line_count" "$topic_label" "$needs_recheck" "$state_file")

	# Build label list — skip needs-maintainer-review when user is maintainer (GH#16786)
	local review_label=""
	if [[ "${_COMPLEXITY_SCAN_SKIP_REVIEW_GATE:-false}" != "true" ]]; then
		review_label="--label needs-maintainer-review"
	fi

	local create_ok=false
	# t1955: Don't self-assign on issue creation — let dispatch_with_dedup handle
	# assignment. Self-assigning creates a phantom claim that triggers stale recovery.
	if [[ "$needs_recheck" == true ]]; then
		# shellcheck disable=SC2086
		gh_create_issue --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "function-complexity-debt" $review_label --label "tier:standard" --label "recheck-simplicity" \
			--body "$issue_body" >/dev/null 2>&1 && create_ok=true
	else
		# shellcheck disable=SC2086
		gh_create_issue --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "function-complexity-debt" $review_label --label "tier:standard" \
			--body "$issue_body" >/dev/null 2>&1 && create_ok=true
	fi

	if [[ "$create_ok" == true ]]; then
		_complexity_scan_close_duplicate_issues_by_title "$aidevops_slug" "$issue_title"
		local log_suffix=""
		[[ "$needs_recheck" == true ]] && log_suffix=" [RECHECK]"
		echo "[pulse-wrapper] Complexity scan (.md): created issue for ${file_path} (${line_count} lines)${log_suffix}" >>"$LOGFILE"
		echo "created"
	else
		echo "[pulse-wrapper] Complexity scan (.md): failed to create issue for ${file_path}" >>"$LOGFILE"
		echo "failed"
	fi
	return 0
}

# Create GitHub issues for agent docs flagged for simplification review.
# Default to tier:standard — simplification requires reading the file, understanding
# its structure, deciding what to extract vs compress, and preserving institutional
# knowledge. Haiku-tier models lack the judgment for this; they over-compress,
# lose task IDs, or restructure without understanding the reasoning behind the
# original layout. Maintainers can raise to tier:thinking for architectural docs.
# Arguments: $1 - scan_results (pipe-delimited: file_path|line_count), $2 - repos_json, $3 - aidevops_slug
_complexity_scan_create_md_issues() {
	local scan_results="$1"
	local repos_json="$2"
	local aidevops_slug="$3"
	local max_issues_per_run=5
	local issues_created=0
	local issues_skipped=0

	# Total-open cap: stop creating when backlog is already large
	_complexity_scan_check_open_cap "$aidevops_slug" 500 "Complexity scan (.md)" || return 0

	local maintainer
	maintainer=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null)
	if [[ -z "$maintainer" ]]; then
		maintainer=$(echo "$aidevops_slug" | cut -d/ -f1)
	fi

	local aidevops_path
	aidevops_path=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .path' \
		"$repos_json" 2>/dev/null | head -n 1)

	# Simplification state file — tracks already-simplified files by git blob hash
	local state_file=""
	if [[ -n "$aidevops_path" ]]; then
		state_file="${aidevops_path}/.agents/configs/simplification-state.json"
	fi

	while IFS='|' read -r file_path line_count; do
		[[ -n "$file_path" ]] || continue
		[[ "$issues_created" -ge "$max_issues_per_run" ]] && break

		local result
		result=$(_complexity_scan_process_single_md_file "$file_path" "$line_count" \
			"$aidevops_slug" "$aidevops_path" "$state_file" "$maintainer")

		case "$result" in
		created) issues_created=$((issues_created + 1)) ;;
		skipped) issues_skipped=$((issues_skipped + 1)) ;;
		*) ;; # failed — logged by helper, no counter change
		esac
	done <<<"$scan_results"
	echo "[pulse-wrapper] Complexity scan (.md) complete: ${issues_created} issues created, ${issues_skipped} skipped (existing/simplified)" >>"$LOGFILE"
	return 0
}

# Build issue body for a shell file complexity finding, with signature footer appended.
# Arguments: $1 - file_path, $2 - violation_count, $3 - details (function-detail text)
# Output: full body to stdout
# Returns: 0 always
_complexity_scan_sh_build_issue_body_with_sig() {
	local file_path="$1"
	local violation_count="$2"
	local details="$3"

	local issue_body
	issue_body="<!-- aidevops:generator=function-complexity-gate cited_file=${file_path} threshold=${COMPLEXITY_FUNC_LINE_THRESHOLD} -->

## Complexity scan finding (automated, GH#5628)

**File:** \`${file_path}\`
**Violations:** ${violation_count} functions exceed ${COMPLEXITY_FUNC_LINE_THRESHOLD} lines

### Functions exceeding threshold

\`\`\`
${details}
\`\`\`

### Proposed action

Break down the listed functions into smaller, focused helper functions. Each function should ideally be under ${COMPLEXITY_FUNC_LINE_THRESHOLD} lines.

**Reference pattern:** \`.agents/reference/large-file-split.md\` (playbook for shell-lib splits — covers orchestrator pattern, identity-key preservation, and PR body template).

**Precedent in this repo:** \`issue-sync-helper.sh\` + \`issue-sync-lib.sh\` (simple split) and \`headless-runtime-lib.sh\` + sub-libraries (complex split). Copy the include-guard and SCRIPT_DIR-fallback pattern from the simple precedent.

**Expected CI gate overrides:** This PR may trigger a complexity regression from function extraction. Apply the \`complexity-bump-ok\` label AND include a \`## Complexity Bump Justification\` section in the PR body citing scanner evidence. See the playbook section 4 (Known CI False-Positive Classes).

### Verification

- \`bash -n <file>\` (syntax check)
- \`shellcheck <file>\` (lint)
- Run existing tests if present
- Confirm no functionality is lost

### Confidence: medium

This is an automated scan. The function lengths are factual, but the best decomposition strategy requires human judgment.

---
**To approve or decline**, comment on this issue:
- \`approved\` — removes the review gate and queues for automated dispatch
- \`declined: <reason>\` — closes this issue (include your reason after the colon)"

	# Append signature footer (--no-session + elapsed time, GH#13099)
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	printf '%s%s' "$issue_body" "$sig_footer"
	return 0
}

# Create a GitHub issue for a single shell file with function-complexity violations.
# Assumes nesting-only and dedup checks have already passed (caller's responsibility).
# Arguments: $1 - file_path, $2 - violation_count, $3 - repos_json, $4 - aidevops_slug
# Returns: 0 if issue created, 1 if failed
_complexity_scan_sh_create_issue() {
	local file_path="$1"
	local violation_count="$2"
	local repos_json="$3"
	local aidevops_slug="$4"

	# Compute function details (not in scan_results to avoid breaking IFS='|', GH#5630)
	local aidevops_path
	aidevops_path=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .path' \
		"$repos_json" 2>/dev/null | head -n 1)
	local details=""
	if [[ -n "$aidevops_path" && -f "${aidevops_path}/${file_path}" ]]; then
		# Use -v to pass the threshold safely — interpolating shell variables into
		# awk scripts is a security risk and breaks if the value contains quotes (GH#18555).
		details=$(awk -v threshold="$COMPLEXITY_FUNC_LINE_THRESHOLD" '
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { fname=$1; sub(/\(\)/, "", fname); start=NR; next }
			fname && /^\}$/ { lines=NR-start; if(lines+0>threshold+0) printf "%s() %d lines\n", fname, lines; fname="" }
		' "${aidevops_path}/${file_path}" | head -10)
	fi

	local issue_body
	issue_body=$(_complexity_scan_sh_build_issue_body_with_sig "$file_path" "$violation_count" "$details")

	local issue_title="simplification: reduce function complexity in ${file_path} (${violation_count} functions >${COMPLEXITY_FUNC_LINE_THRESHOLD} lines)"
	# Skip needs-maintainer-review when user is maintainer (GH#16786)
	local review_label_sh=""
	if [[ "${_COMPLEXITY_SCAN_SKIP_REVIEW_GATE:-false}" != "true" ]]; then
		review_label_sh="--label needs-maintainer-review"
	fi
	# t1955: Don't self-assign — let dispatch_with_dedup handle assignment.
	# shellcheck disable=SC2086
	if gh_create_issue --repo "$aidevops_slug" \
		--title "$issue_title" \
		--label "function-complexity-debt" $review_label_sh \
		--body "$issue_body" >/dev/null 2>&1; then
		_complexity_scan_close_duplicate_issues_by_title "$aidevops_slug" "$issue_title"
		echo "[pulse-wrapper] Complexity scan: created issue for ${file_path} (${violation_count} violations)" >>"$LOGFILE"
		return 0
	fi
	echo "[pulse-wrapper] Complexity scan: failed to create issue for ${file_path}" >>"$LOGFILE"
	return 1
}

# Create GitHub issues for qualifying files (dedup via server-side title search).
# Arguments: $1 - scan_results (pipe-delimited: file_path|count), $2 - repos_json, $3 - aidevops_slug
# Returns: 0 always
_complexity_scan_create_issues() {
	local scan_results="$1"
	local repos_json="$2"
	local aidevops_slug="$3"
	local max_issues_per_run=5
	local issues_created=0
	local issues_skipped=0

	# Total-open cap: stop creating when backlog is already large
	_complexity_scan_check_open_cap "$aidevops_slug" 500 "Complexity scan" || return 0

	local maintainer
	maintainer=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null)
	if [[ -z "$maintainer" ]]; then
		maintainer=$(echo "$aidevops_slug" | cut -d/ -f1)
	fi

	while IFS='|' read -r file_path violation_count; do
		[[ -n "$file_path" ]] || continue
		[[ "$issues_created" -ge "$max_issues_per_run" ]] && break

		# Skip nesting-only violations (GH#17632): files flagged solely for max_nesting
		# exceeding the threshold have violation_count=0 (no long functions). The current
		# issue template is function-length-specific; creating a "0 functions >100 lines"
		# issue is misleading and produces false-positive dispatch work.
		if [[ "${violation_count:-0}" -eq 0 ]]; then
			echo "[pulse-wrapper] Complexity scan: skipping ${file_path} — nesting-only violation (0 long functions)" >>"$LOGFILE"
			issues_skipped=$((issues_skipped + 1))
			continue
		fi

		# Dedup via server-side title search — accurate across all issues (GH#5630)
		if _complexity_scan_has_existing_issue "$aidevops_slug" "$file_path"; then
			echo "[pulse-wrapper] Complexity scan: skipping ${file_path} — existing open issue" >>"$LOGFILE"
			issues_skipped=$((issues_skipped + 1))
			continue
		fi

		if _complexity_scan_sh_create_issue "$file_path" "$violation_count" "$repos_json" "$aidevops_slug"; then
			issues_created=$((issues_created + 1))
		fi
	done <<<"$scan_results"
	echo "[pulse-wrapper] Complexity scan complete: ${issues_created} issues created, ${issues_skipped} skipped (existing)" >>"$LOGFILE"
	return 0
}

#######################################
# Close duplicate function-complexity-debt issues across pulse-enabled repos.
#
# For each repo, fetches open function-complexity-debt issues and groups by
# file path extracted from the title. When multiple issues exist for the
# same file, keeps the newest and closes the rest as "not planned".
#
# Rate-limited: closes at most DEDUP_CLEANUP_BATCH_SIZE issues per run
# and runs at most once per DEDUP_CLEANUP_INTERVAL (default: daily).
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
run_simplification_dedup_cleanup() {
	local now_epoch
	now_epoch=$(date +%s)

	# Interval guard
	if [[ -f "$DEDUP_CLEANUP_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$DEDUP_CLEANUP_LAST_RUN" 2>/dev/null || echo "0")
		[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
		local elapsed=$((now_epoch - last_run))
		if [[ "$elapsed" -lt "$DEDUP_CLEANUP_INTERVAL" ]]; then
			return 0
		fi
	fi

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local repo_slugs
	repo_slugs=$(_pulse_enabled_repo_slugs "$repos_json") || repo_slugs=""
	[[ -z "$repo_slugs" ]] && return 0

	local total_closed=0
	local batch_limit="$DEDUP_CLEANUP_BATCH_SIZE"

	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		[[ "$total_closed" -ge "$batch_limit" ]] && break
		# t2145: skip repos where the user is a contributor — simplification
		# dedup cleanup is a maintainer-only operation.
		local _dedup_role
		_dedup_role=$(get_repo_role_by_slug "$slug")
		[[ "$_dedup_role" != "maintainer" ]] && continue

		# Use jq to extract file paths from titles and find duplicates server-side.
		# Strategy: fetch issues sorted by number ascending (oldest first), extract
		# file path from title via jq regex, group by path, and collect all but the
		# last (newest) issue number from each group as duplicates to close.
		local dupe_numbers
		dupe_numbers=$(gh issue list --repo "$slug" \
			--label "function-complexity-debt" --state open \
			--limit 500 --json number,title \
			--jq '
				sort_by(.number) |
				[.[] | {
					number,
					file: (
						(.title | capture("\\((?<p>[^,)]+\\.(sh|md|py|ts|js))[,)]") // null | .p) //
						(.title | capture("in (?<p>[^ ]+\\.(sh|md|py|ts|js))") // null | .p) //
						null
					)
				}] |
				[.[] | select(.file != null)] |
				group_by(.file) |
				[.[] | select(length > 1) | .[:-1][].number] |
				.[]
			' 2>/dev/null) || dupe_numbers=""

		[[ -z "$dupe_numbers" ]] && continue

		while IFS= read -r dupe_num; do
			[[ -z "$dupe_num" ]] && continue
			[[ "$total_closed" -ge "$batch_limit" ]] && break
			if gh issue close "$dupe_num" --repo "$slug" --reason "not planned" \
				--comment "Auto-closing duplicate: another function-complexity-debt issue exists for this file. Keeping the newest." \
				>/dev/null 2>&1; then
				total_closed=$((total_closed + 1))
			fi
		done <<<"$dupe_numbers"
	done <<<"$repo_slugs"

	echo "$now_epoch" >"$DEDUP_CLEANUP_LAST_RUN"
	if [[ "$total_closed" -gt 0 ]]; then
		echo "[pulse-wrapper] Dedup cleanup: closed ${total_closed} duplicate function-complexity-debt issue(s)" >>"$LOGFILE"
	fi
	return 0
}

# Read the nesting depth CI threshold from the config file.
# Arguments: $1 - aidevops_path
# Output: threshold integer to stdout (defaults to 260 if config unreadable)
# Returns: 0 always
_check_ci_nesting_read_threshold() {
	local aidevops_path="$1"
	local threshold=260
	local conf_file="${aidevops_path}/.agents/configs/complexity-thresholds.conf"
	if [[ -f "$conf_file" ]]; then
		local val
		val=$(grep '^NESTING_DEPTH_THRESHOLD=' "$conf_file" | cut -d= -f2 || true)
		if [[ -n "$val" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
			threshold="$val"
		fi
	fi
	printf '%s' "$threshold"
	return 0
}

# Count shell files with nesting depth > 8 (CI metric, global counter, no function resets).
# Arguments: $1 - aidevops_path
# Output: violation count to stdout
# Returns: 0 always (returns 0 and outputs 0 when no shell files found)
_check_ci_nesting_count_violations() {
	local aidevops_path="$1"
	local violations=0
	local lint_files
	lint_files=$(git -C "$aidevops_path" ls-files '*.sh' 2>/dev/null |
		grep -v 'node_modules\|vendor\|\.git' |
		sed "s|^|${aidevops_path}/|" || true)
	if [[ -z "$lint_files" ]]; then
		printf '0'
		return 0
	fi
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		[[ -f "$file" ]] || continue
		local max_depth
		max_depth=$(awk '
			BEGIN { depth=0; max_depth=0 }
			/^[[:space:]]*#/ { next }
			/[[:space:]]*(if|for|while|until|case)[[:space:]]/ { depth++; if(depth>max_depth) max_depth=depth }
			/[[:space:]]*(fi|done|esac)[[:space:]]*$/ || /^[[:space:]]*(fi|done|esac)$/ { if(depth>0) depth-- }
			END { print max_depth }
		' "$file" 2>/dev/null) || max_depth=0
		if [[ "$max_depth" -gt 8 ]]; then
			violations=$((violations + 1))
		fi
	done <<<"$lint_files"
	printf '%s' "$violations"
	return 0
}

# Build the CI nesting threshold proximity warning issue body with signature footer.
# Arguments: $1 - violations, $2 - threshold, $3 - headroom, $4 - buffer
# Output: full body to stdout
# Returns: 0 always
_check_ci_nesting_build_issue_body() {
	local violations="$1"
	local threshold="$2"
	local headroom="$3"
	local buffer="$4"

	local issue_body
	issue_body="## CI Nesting Threshold Proximity Warning

The shell nesting depth violation count is within **${buffer}** of the CI threshold.

- **Current violations**: ${violations}
- **CI threshold**: ${threshold} (from \`.agents/configs/complexity-thresholds.conf\`)
- **Headroom remaining**: ${headroom}

### Why this matters

The \`Complexity Analysis\` CI check fails when nesting depth violations exceed the threshold. When PRs add new scripts with deep nesting, they push the count over the threshold and block all open PRs. This happened 6 times in a short window (GH#17808).

### Recommended actions

1. Reduce nesting depth in the highest-depth scripts (run \`complexity-scan-helper.sh scan\` to identify them)
2. Or bump the threshold in \`.agents/configs/complexity-thresholds.conf\` with a documented rationale

### Files to check

Run locally to see current violators:
\`\`\`bash
git ls-files '*.sh' | while read -r f; do
  d=\$(awk 'BEGIN{d=0;m=0} /^[[:space:]]*#/{next} /[[:space:]]*(if|for|while|until|case)[[:space:]]/{d++;if(d>m)m=d} /[[:space:]]*(fi|done|esac)[[:space:]]*\$||/^[[:space:]]*(fi|done|esac)\$/{if(d>0)d--} END{print m}' \"\$f\")
  [ \"\$d\" -gt 8 ] && echo \"\$d \$f\"
done | sort -rn | head -20
\`\`\`"

	# Append signature footer
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	printf '%s%s' "$issue_body" "$sig_footer"
	return 0
}

#######################################
# Check if nesting depth violation count is approaching the CI threshold.
# Creates a warning issue when within the buffer to prevent CI regressions
# before they happen (GH#17808 — regression guard for Complexity Analysis CI).
#
# The CI check uses a global awk counter (not per-function) that counts all
# if/for/while/until/case across the entire file without resetting at function
# boundaries. This function replicates that logic to detect proximity.
#
# Arguments:
#   $1 - aidevops_path (repo root)
#   $2 - aidevops_slug (owner/repo)
#   $3 - maintainer (GitHub login)
# Returns: 0 always (best-effort)
#######################################
_check_ci_nesting_threshold_proximity() {
	# t2171 / GH#19585: retired. The proximity scanner was filing duplicate
	# "CI nesting threshold proximity: N/M violations" issues every ~45min
	# (observed: GH#19526-19582, 11 iterations in 7h) because the ratchet-down
	# + CI-bump loop kept oscillating the threshold just inside the buffer.
	#
	# Replacement: the nesting-depth step in code-quality.yml now calls
	# complexity-regression-helper.sh with --metric nesting-depth, blocking
	# only on NEW violations (set difference) and treating the total count
	# as a non-blocking warning. No threshold to tune, no treadmill to ratchet.
	#
	# Helper functions (_check_ci_nesting_read_threshold, _count_violations,
	# _build_issue_body) are preserved so the characterization test at
	# tests/test-pulse-wrapper-characterization.sh:208 still finds them.
	local _unused_aidevops_path="${1:-}"
	local _unused_aidevops_slug="${2:-}"
	local _unused_maintainer="${3:-}"
	if [[ -n "${LOGFILE:-}" ]]; then
		echo "[pulse-wrapper] _check_ci_nesting_threshold_proximity: retired (t2171/GH#19585) — CI regression gate replaces this" >>"$LOGFILE"
	fi
	return 0
}

# _complexity_scan_permission_gate — check current user has admin access (t2001)
# Sets global _COMPLEXITY_SCAN_SKIP_REVIEW_GATE.
# Returns 1 (call-site should return 0) if scan should be skipped.
_complexity_scan_permission_gate() {
	local aidevops_slug="$1"

	# Permission gate: only admin users may create simplification issues.
	# write/maintain collaborators are excluded — they could otherwise use
	# bot-created function-complexity-debt issues to bypass the maintainer assignee
	# gate (GH#16786, GH#18197). On personal repos, admin = repo owner only.
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null) || current_user=""
	if [[ -n "$current_user" ]]; then
		local perm_level
		perm_level=$(gh api "repos/${aidevops_slug}/collaborators/${current_user}/permission" \
			--jq '.permission' 2>/dev/null) || perm_level=""
		case "$perm_level" in
		admin) ;; # allowed — repo owner/admin only
		*)
			echo "[pulse-wrapper] Complexity scan: skipped — user '$current_user' has '$perm_level' permission on $aidevops_slug (need admin)" >>"$LOGFILE"
			return 1
			;;
		esac
	fi

	# When the authenticated user IS the repo maintainer, skip the
	# needs-maintainer-review label — the standard auto-dispatch + PR
	# review flow provides sufficient gating (GH#16786).
	local maintainer_from_config
	maintainer_from_config=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$REPOS_JSON" 2>/dev/null)
	[[ -z "$maintainer_from_config" ]] && maintainer_from_config=$(printf '%s' "$aidevops_slug" | cut -d/ -f1)
	_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=false
	if [[ "$current_user" == "$maintainer_from_config" ]]; then
		_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=true
	fi
	return 0
}

# _complexity_scan_pull_latest — pull aidevops repo before scanning (GH#17848, t2001)
# Fail-closed: returns 1 (skip cycle) if pull fails to avoid stale-state warnings.
_complexity_scan_pull_latest() {
	local aidevops_path="$1"

	# GH#17848: Pull latest state before scanning to avoid false-positive
	# proximity warnings from stale local checkouts. The proximity guard and
	# tree-change check both read working-tree files, so a stale checkout
	# (e.g., local repo hasn't pulled a threshold-bump PR yet) produces
	# incorrect violation counts and may create spurious warning issues.
	# Fail-closed: if pull fails, skip this scan cycle rather than proceeding
	# with stale data (which would reintroduce the exact problem we're fixing).
	# Do NOT update COMPLEXITY_SCAN_LAST_RUN on skip — the next cycle retries.
	# GIT_TERMINAL_PROMPT=0 prevents credential prompts from hanging the pulse.
	# GH#18644: timeout_sec 30 prevents network hangs from blocking the pulse
	# cycle. Previously used bare `timeout` which is Linux-only — on macOS it
	# exits immediately with "command not found" and the pull runs without any
	# timeout protection (or, if set -e is active, aborts the stage). The
	# portable timeout_sec helper from shared-constants.sh tries `timeout`,
	# `gtimeout`, and a bash-native PGID-kill fallback.
	if git -C "$aidevops_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		if ! GIT_TERMINAL_PROMPT=0 timeout_sec 30 \
			git -C "$aidevops_path" pull --ff-only --no-rebase >>"$LOGFILE" 2>&1; then
			echo "[pulse-wrapper] Complexity scan: git pull failed for ${aidevops_path} — skipping this cycle to avoid stale-state warnings" >>"$LOGFILE"
			return 1
		fi
	fi
	return 0
}

# _complexity_scan_state_refresh — prune/refresh/backfill simplification state (t1754, t1855, t2001)
# Updates state file and pushes to main if any entries changed.
_complexity_scan_state_refresh() {
	local aidevops_path="$1"
	local state_file="$2"
	local aidevops_slug="$3"

	# Phase 1: Refresh simplification state hashes against current main (t1754).
	# Replaces the previous timeline-API-based backfill which was fragile and
	# frequently missed state updates, causing infinite recheck loops.
	# Now simply recomputes git hash-object for every file in state and updates
	# any that differ. This catches all modifications (simplification PRs,
	# feature work, refactors) without depending on GitHub API link resolution.
	local state_updated=false

	# Prune stale entries (files moved/renamed/deleted since last scan)
	local pruned_count
	pruned_count=$(_simplification_state_prune "$aidevops_path" "$state_file")
	if [[ "$pruned_count" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: pruned $pruned_count stale entries (files no longer exist)" >>"$LOGFILE"
		state_updated=true
	fi

	# Refresh all hashes — O(n) git hash-object calls, no API requests (t1754)
	local refreshed_count
	refreshed_count=$(_simplification_state_refresh "$aidevops_path" "$state_file")
	if [[ "$refreshed_count" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: refreshed $refreshed_count hashes (files changed since last scan)" >>"$LOGFILE"
		state_updated=true
	fi

	# Backfill state for recently closed issues (t1855).
	# _simplification_state_record() was defined but never called — workers
	# complete simplification and close issues, but the state file was never
	# updated. This backfill detects closed issues and records their file hashes
	# so the scanner knows they're done and doesn't create duplicate issues.
	local backfilled_count
	backfilled_count=$(_simplification_state_backfill_closed "$aidevops_path" "$state_file" "$aidevops_slug")
	if [[ "${backfilled_count:-0}" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: backfilled $backfilled_count entries from recently closed issues (t1855)" >>"$LOGFILE"
		state_updated=true
	fi

	# Defensive auto-close sweep for spurious "0 smells remaining" re-queue
	# issues (GH#18795). Closes any stragglers from the pre-PR-#18848 bug
	# and self-heals any future regression of the same class. Verifies the
	# file is genuinely clean via Qlty before closing — never closes a
	# legitimate finding even if its title coincidentally matches the
	# spurious pattern. No-op when Qlty is not installed.
	local spurious_closed
	spurious_closed=$(_simplification_close_spurious_requeue_issues "$aidevops_path" "$aidevops_slug")
	if [[ "${spurious_closed:-0}" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: closed $spurious_closed spurious zero-smell re-queue issues (GH#18795)" >>"$LOGFILE"
	fi

	# Push state file if updated (planning data — direct to main)
	if [[ "$state_updated" == true ]]; then
		_simplification_state_push "$aidevops_path"
	fi
	return 0
}

# _complexity_scan_lang_shell — shell-file complexity scan via helper (Phase 2, t2001)
# Converts helper output to issue-creation format and calls _complexity_scan_create_issues.
_complexity_scan_lang_shell() {
	local scan_helper="$1"
	local aidevops_path="$2"
	local state_file="$3"
	local repos_json="$4"
	local aidevops_slug="$5"

	# Shell files — convert helper output to existing issue creation format
	# Helper outputs: status|file_path|line_count|func_count|long_func_count|max_nesting|file_type
	# Issue creation expects: file_path|violation_count
	local sh_scan_output
	sh_scan_output=$("$scan_helper" scan "$aidevops_path" --type sh --state-file "$state_file" 2>>"$LOGFILE") || true
	if [[ -n "$sh_scan_output" ]]; then
		local sh_results=""
		while IFS='|' read -r _status file_path _lines _funcs long_funcs _nesting _type; do
			[[ -n "$file_path" ]] || continue
			sh_results="${sh_results}${file_path}|${long_funcs}"$'\n'
		done <<<"$sh_scan_output"
		if [[ -n "$sh_results" ]]; then
			sh_results=$(printf '%s' "$sh_results" | sort -t'|' -k2 -rn)
			_complexity_scan_create_issues "$sh_results" "$repos_json" "$aidevops_slug"
		fi
	fi
	return 0
}

# _complexity_scan_lang_md — markdown-file complexity scan via helper (Phase 3, t2001)
# Converts helper output to issue-creation format and calls _complexity_scan_create_md_issues.
_complexity_scan_lang_md() {
	local scan_helper="$1"
	local aidevops_path="$2"
	local state_file="$3"
	local repos_json="$4"
	local aidevops_slug="$5"

	# Markdown files — convert helper output to existing issue creation format
	# Helper outputs: status|file_path|line_count|func_count|long_func_count|max_nesting|file_type
	# Issue creation expects: file_path|line_count
	local md_scan_output
	md_scan_output=$("$scan_helper" scan "$aidevops_path" --type md --state-file "$state_file" 2>>"$LOGFILE") || true
	if [[ -n "$md_scan_output" ]]; then
		local md_results=""
		while IFS='|' read -r _status file_path lines _funcs _long_funcs _nesting _type; do
			[[ -n "$file_path" ]] || continue
			md_results="${md_results}${file_path}|${lines}"$'\n'
		done <<<"$md_scan_output"
		if [[ -n "$md_results" ]]; then
			md_results=$(printf '%s' "$md_results" | sort -t'|' -k2 -rn)
			_complexity_scan_create_md_issues "$md_results" "$repos_json" "$aidevops_slug"
		fi
	fi
	return 0
}

# _complexity_scan_sweep_check — LLM sweep check and issue creation (Phase 4, t2001)
# If simplification debt stalled, creates a sweep issue for LLM review (GH#15285).
_complexity_scan_sweep_check() {
	local scan_helper="$1"
	local aidevops_slug="$2"

	# Phase 4: Daily LLM sweep check (GH#15285)
	# If simplification debt hasn't decreased in 6h, flag for LLM review.
	# The sweep itself runs as a separate worker dispatch, not inline.
	local sweep_result
	sweep_result=$("$scan_helper" sweep-check "$aidevops_slug" 2>>"$LOGFILE") || sweep_result=""
	if [[ "$sweep_result" == needed* ]]; then
		echo "[pulse-wrapper] LLM sweep triggered: ${sweep_result}" >>"$LOGFILE"
		# Create a one-off issue for the LLM sweep if none exists (t1855: check both title patterns)
		local sweep_issue_exists
		sweep_issue_exists=$(gh issue list --repo "$aidevops_slug" \
			--label "function-complexity-debt" --state open \
			--search "in:title \"simplification debt stalled\" OR in:title \"LLM complexity sweep\"" \
			--json number --jq 'length' 2>/dev/null) || sweep_issue_exists="0"
		if [[ "${sweep_issue_exists:-0}" -eq 0 ]]; then
			local sweep_reason
			sweep_reason=$(echo "$sweep_result" | cut -d'|' -f2)
			gh_create_issue --repo "$aidevops_slug" \
				--title "LLM complexity sweep: review stalled function-complexity debt" \
				--label "function-complexity-debt" --label "auto-dispatch" --label "tier:thinking" \
				--body "## Daily LLM sweep (automated, GH#15285)

**Trigger:** ${sweep_reason}

The deterministic complexity scan detected that function-complexity debt has not decreased in the configured stall window. An LLM-powered deep review is needed to:

1. Identify why existing function-complexity-debt issues are not being resolved
2. Re-prioritize the backlog based on actual impact
3. Close issues that are no longer relevant (files deleted, already simplified)
4. Suggest new decomposition strategies for stuck files

### Scope

Review all open \`function-complexity-debt\` issues and the current \`simplification-state.json\`. Focus on the top 10 largest files first." >/dev/null 2>&1 || true
			"$scan_helper" sweep-done 2>>"$LOGFILE" || true
		fi
	fi
	return 0
}

# _complexity_scan_ratchet_check — retired in t2171 (GH#19585).
#
# Historical purpose (Phase 5, t1913): file a chore issue to ratchet-down
# complexity thresholds when violations dropped >=5 below the current value.
# In practice, the ratchet-check + CI-bump-up cycle formed a treadmill: each
# cleanup PR triggered a ratchet-down PR, each CI near-miss triggered a
# threshold bump, and the two oscillated forever (observed: BASH32 threshold
# bouncing 74↔78, NESTING threshold cycling 285→290→285).
#
# Replacement: code-quality.yml now runs complexity-regression-helper.sh with
# per-metric regression gates (function-complexity, nesting-depth, file-size,
# bash32-compat). PRs fail only for NEW violations; totals are non-blocking
# warnings. Thresholds in complexity-thresholds.conf remain as targets for
# the simplification routine but are no longer part of the CI gate contract.
_complexity_scan_ratchet_check() {
	local _unused_scan_helper="${1:-}"
	local _unused_aidevops_path="${2:-}"
	local _unused_aidevops_slug="${3:-}"
	if [[ -n "${LOGFILE:-}" ]]; then
		echo "[pulse-wrapper] _complexity_scan_ratchet_check: retired (t2171/GH#19585) — per-metric regression gates replace the threshold treadmill" >>"$LOGFILE"
	fi
	return 0
}

# run_weekly_complexity_scan — orchestrator: interval check → auth gate → scan phases (t2001)
# Refactored in Phase 12 (t2001): extracted per-language and per-phase helpers to reduce
# this function from 287 lines to a clean orchestrator. New helpers:
#   _complexity_scan_permission_gate, _complexity_scan_pull_latest,
#   _complexity_scan_state_refresh, _complexity_scan_lang_shell,
#   _complexity_scan_lang_md, _complexity_scan_sweep_check,
#   _complexity_scan_ratchet_check
run_weekly_complexity_scan() {
	local repos_json="$REPOS_JSON"
	local aidevops_slug="marcusquinn/aidevops"

	# t2145: complexity scan creates function-complexity-debt issues — maintainer-only.
	local _cs_role
	_cs_role=$(get_repo_role_by_slug "$aidevops_slug")
	if [[ "$_cs_role" != "maintainer" ]]; then
		echo "[pulse-wrapper] Complexity scan skipped: role=$_cs_role for $aidevops_slug (t2145)" >>"$LOGFILE"
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s)

	_complexity_scan_check_interval "$now_epoch" || return 0

	_complexity_scan_permission_gate "$aidevops_slug" || return 0

	local aidevops_path
	aidevops_path=$(_complexity_scan_find_repo "$repos_json" "$aidevops_slug" "$now_epoch") || return 0

	_complexity_scan_pull_latest "$aidevops_path" || return 0

	# GH#15285: O(1) tree hash check — skip file iteration if no tracked files changed.
	local tree_changed=true
	if ! _complexity_scan_tree_changed "$aidevops_path"; then
		tree_changed=false
	fi

	local maintainer
	maintainer=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null)
	[[ -z "$maintainer" ]] && maintainer=$(printf '%s' "$aidevops_slug" | cut -d/ -f1)

	# LLM sweep + CI proximity guard run independently of tree change (GH#15285, GH#17808).
	if _complexity_llm_sweep_due "$now_epoch" "$aidevops_slug"; then
		_complexity_run_llm_sweep "$aidevops_slug" "$now_epoch" "$maintainer"
	fi
	_check_ci_nesting_threshold_proximity "$aidevops_path" "$aidevops_slug" "$maintainer" || true

	if [[ "$tree_changed" == false ]]; then
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 0
	fi

	echo "[pulse-wrapper] Running deterministic complexity scan (GH#5628, GH#15285)..." >>"$LOGFILE"

	# Ensure recheck label exists (used when a simplified file changes)
	gh label create "recheck-simplicity" --repo "$aidevops_slug" --color "D4C5F9" \
		--description "File changed since last simplification and needs recheck" --force 2>/dev/null || true

	local state_file="${aidevops_path}/.agents/configs/simplification-state.json"
	_complexity_scan_state_refresh "$aidevops_path" "$state_file" "$aidevops_slug"

	local scan_helper="${SCRIPT_DIR}/complexity-scan-helper.sh"
	if [[ -x "$scan_helper" ]]; then
		_complexity_scan_lang_shell "$scan_helper" "$aidevops_path" "$state_file" "$repos_json" "$aidevops_slug"
		_complexity_scan_lang_md "$scan_helper" "$aidevops_path" "$state_file" "$repos_json" "$aidevops_slug"
		_complexity_scan_sweep_check "$scan_helper" "$aidevops_slug"
		_complexity_scan_ratchet_check "$scan_helper" "$aidevops_path" "$aidevops_slug"
	else
		# Fallback to inline scan if helper not available
		echo "[pulse-wrapper] complexity-scan-helper.sh not found, using inline scan" >>"$LOGFILE"
		local sh_results
		sh_results=$(_complexity_scan_collect_violations "$aidevops_path" "$now_epoch") || true
		if [[ -n "$sh_results" ]]; then
			sh_results=$(printf '%s' "$sh_results" | sort -t'|' -k2 -rn)
			_complexity_scan_create_issues "$sh_results" "$repos_json" "$aidevops_slug"
		fi
		local md_results
		md_results=$(_complexity_scan_collect_md_violations "$aidevops_path") || true
		if [[ -n "$md_results" ]]; then
			_complexity_scan_create_md_issues "$md_results" "$repos_json" "$aidevops_slug"
		fi
	fi

	printf '%s\n' "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
	return 0
}
