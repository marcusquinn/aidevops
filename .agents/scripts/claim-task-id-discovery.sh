#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Claim Task ID — Pre-Claim Discovery and Dispatch-Path Sub-Library
# =============================================================================
# Extracted from claim-task-id.sh (GH#20224 headroom split). Pure move.
#
# Usage: source "${SCRIPT_DIR}/claim-task-id-discovery.sh"
#
# Dependencies: shared-constants.sh, issue-sync-lib.sh and the global variables
# declared in claim-task-id.sh (REPO_PATH, REMOTE_NAME, TASK_*, ...).
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CLAIM_TASK_ID_DISCOVERY_LIB_LOADED:-}" ]] && return 0
_CLAIM_TASK_ID_DISCOVERY_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Pre-claim discovery pass (t2180) — decomposed into 5 helpers.
#
# Runs before atomic ID allocation to surface similar in-flight or
# recently-merged PRs. Prevents duplicate work (concrete evidence: PR #19494
# duplicated merged PR #19495, costing ~30 min of session time + 10 CI runs).
#
# Decomposition keeps every function ≤30 lines so the complexity-regression
# pre-push hook stays green. Prior attempt (PR #19658) bundled all logic in
# one ~170-line function that tripped the gate.
#
# Env vars:
#   AIDEVOPS_CLAIM_DEDUP_DAYS   recency window for merged PRs (default 14)
#
# Test hooks (for test-claim-task-id-discovery.sh only):
#   _AIDEVOPS_CLAIM_TEST_IS_TTY  "1" → force interactive path in non-TTY tests
#   _AIDEVOPS_CLAIM_TEST_ANSWER  "y"/"n" → override user prompt answer
# ---------------------------------------------------------------------------

# _pc_sanitize_keywords — extract keywords from task title.
# Emits up to 4 keywords on stdout, one per line, length-sorted descending
# (longer tokens are more discriminating in search).
# Stop-words and tokens <4 chars are dropped.
_pc_sanitize_keywords() {
	local title="$1"
	local stop=" feat fix chore add update remove delete get set the for to a an with from into via of at on in by and or is are was not use uses using new be do did does its it "
	local sanitized
	sanitized=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ')
	local -a raw_tokens=()
	IFS=' ' read -ra raw_tokens <<<"$sanitized"
	local -a kw=()
	local t
	for t in "${raw_tokens[@]}"; do
		[[ -z "$t" || ${#t} -lt 4 ]] && continue
		[[ "$stop" == *" ${t} "* ]] && continue
		kw+=("$t")
	done
	[[ ${#kw[@]} -eq 0 ]] && return 0
	local w
	for w in "${kw[@]}"; do
		printf '%s\t%s\n' "${#w}" "$w"
	done | sort -k1,1nr | sed -n '1,4p' | cut -f2-
	return 0
}

# _pc_search_related_prs — run gh_pr_list with OR query across keywords.
# Args: $1 repo_slug, $2 newline-separated keywords.
# Emits raw JSON array on stdout. Returns 0 on success, non-zero on gh error.
_pc_search_related_prs() {
	local repo_slug="$1"
	local keywords_nl="$2"
	local -a kws=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] && kws+=("$line")
	done <<<"$keywords_nl"
	[[ ${#kws[@]} -eq 0 ]] && return 1
	local query
	query=$(printf '%s OR ' "${kws[@]}")
	query="${query% OR }"
	gh_pr_list --repo "$repo_slug" --state all \
		--search "$query" --limit 5 \
		--json number,title,state,mergedAt,createdAt 2>/dev/null
	return $?
}

# _pc_search_related_issues — run gh_issue_list with OR query across keywords.
# Args: $1 repo_slug, $2 newline-separated keywords.
# Emits raw JSON array on stdout. Returns 0 on success, non-zero on gh error.
_pc_search_related_issues() {
	local repo_slug="$1"
	local keywords_nl="$2"
	local -a kws=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] && kws+=("$line")
	done <<<"$keywords_nl"
	[[ ${#kws[@]} -eq 0 ]] && return 1
	local query
	query=$(printf '%s OR ' "${kws[@]}")
	query="${query% OR }"
	gh_issue_list --repo "$repo_slug" --state open \
		--search "$query" --limit 20 \
		--json number,title,state,createdAt 2>/dev/null
	return $?
}

# _pc_filter_relevant_prs — apply recency + keyword-overlap filter.
# Args: $1 raw JSON, $2 newline keywords, $3 dedup_days.
# Emits formatted hit lines: "#NNN [STATE] title  (date)".
_pc_filter_relevant_prs() {
	local raw_json="$1"
	local keywords_nl="$2"
	local dedup_days="$3"
	local now_epoch cutoff_epoch
	now_epoch=$(date +%s 2>/dev/null || echo "0")
	cutoff_epoch=$((now_epoch - dedup_days * 86400))
	local pr_num pr_title pr_state pr_merged_at
	while IFS='|' read -r pr_num pr_title pr_state pr_merged_at; do
		[[ -z "$pr_num" || "$pr_state" == "CLOSED" ]] && continue
		if [[ "$pr_state" == "MERGED" && -n "$pr_merged_at" ]]; then
			local merged_epoch=0
			merged_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_merged_at" +%s 2>/dev/null) \
				|| merged_epoch=$(date --date="$pr_merged_at" +%s 2>/dev/null) \
				|| true
			[[ "$merged_epoch" -gt 0 && "$merged_epoch" -lt "$cutoff_epoch" ]] && continue
		fi
		local pr_lower overlap=0 kw
		pr_lower=$(printf '%s' "$pr_title" | tr '[:upper:]' '[:lower:]')
		while IFS= read -r kw; do
			[[ -z "$kw" ]] && continue
			[[ "$pr_lower" == *"$kw"* ]] && overlap=$((overlap + 1))
		done <<<"$keywords_nl"
		[[ $overlap -lt 2 ]] && continue
		printf '#%s [%s] %s  (%s)\n' "$pr_num" "$pr_state" "$pr_title" "${pr_merged_at:-open}"
	done < <(printf '%s' "$raw_json" | jq -r '.[] | "\(.number)|\(.title)|\(.state)|\(.mergedAt // "")"')
	return 0
}

# _pc_filter_relevant_issues — apply recency + keyword-overlap filter for open issues.
# Args: $1 raw JSON, $2 newline keywords, $3 dedup_days.
# Emits formatted hit lines: "#NNN [ISSUE] title  (date)".
_pc_filter_relevant_issues() {
	local raw_json="$1"
	local keywords_nl="$2"
	local dedup_days="$3"
	local now_epoch cutoff_epoch
	now_epoch=$(date +%s 2>/dev/null || echo "0")
	cutoff_epoch=$((now_epoch - dedup_days * 86400))
	local issue_num issue_title issue_created_at
	while IFS='|' read -r issue_num issue_title issue_created_at; do
		[[ -z "$issue_num" ]] && continue
		if [[ -n "$issue_created_at" ]]; then
			local created_epoch=0
			created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$issue_created_at" +%s 2>/dev/null) \
				|| created_epoch=$(date --date="$issue_created_at" +%s 2>/dev/null) \
				|| true
			[[ "$created_epoch" -gt 0 && "$created_epoch" -lt "$cutoff_epoch" ]] && continue
		fi
		local issue_lower overlap=0 kw
		issue_lower=$(printf '%s' "$issue_title" | tr '[:upper:]' '[:lower:]')
		while IFS= read -r kw; do
			[[ -z "$kw" ]] && continue
			[[ "$issue_lower" == *"$kw"* ]] && overlap=$((overlap + 1))
		done <<<"$keywords_nl"
		[[ $overlap -lt 2 ]] && continue
		printf '#%s [ISSUE] %s  (%s)\n' "$issue_num" "$issue_title" "${issue_created_at:-open}"
	done < <(printf '%s' "$raw_json" | jq -r '.[] | "\(.number)|\(.title)|\(.createdAt // "")"')
	return 0
}

# _pc_prompt_or_warn — interactive Y/N prompt or non-interactive stderr warns.
# Args: $1 newline-separated hit lines.
# Returns: 0 to proceed, 10 if interactive user declined.
_pc_prompt_or_warn() {
	local hits_nl="$1"
	[[ -z "$hits_nl" ]] && return 0
	local -a hits=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] && hits+=("$line")
	done <<<"$hits_nl"
	[[ ${#hits[@]} -eq 0 ]] && return 0
	local is_tty=false
	if [[ "${_AIDEVOPS_CLAIM_TEST_IS_TTY:-0}" == "1" ]]; then
		is_tty=true
	elif [[ -t 0 && -t 1 ]]; then
		is_tty=true
	fi
	local hit_count="${#hits[@]}" max_show=3 h
	if [[ "$is_tty" == true ]]; then
		printf '\n[claim-task-id] WARNING: Found %d similar open issue(s) or PR(s) — please check before claiming a new task ID:\n' "$hit_count" >&2
		for ((h = 0; h < hit_count && h < max_show; h++)); do
			printf '  \xe2\x80\xa2 %s\n' "${hits[$h]}" >&2
		done
		printf '\nContinue claiming a new ID? [y/N]: ' >&2
		local answer="${_AIDEVOPS_CLAIM_TEST_ANSWER:-}"
		[[ -z "$answer" ]] && { IFS= read -r answer </dev/tty 2>/dev/null || answer="n"; }
		local ans_lower
		ans_lower=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
		if [[ "$ans_lower" != "y" && "$ans_lower" != "yes" ]]; then
			printf '[claim-task-id] Claim aborted — verify the issues/PRs above before proceeding.\n' >&2
			return 10
		fi
	else
		for ((h = 0; h < hit_count && h < max_show; h++)); do
			printf '[claim-task-id] WARN: similar issue or PR found: %s\n' "${hits[$h]}" >&2
		done
	fi
	return 0
}

# _pre_claim_discovery_pass — orchestrator.
# Args: $1 title, $2 repo_slug.
# Returns: 0 (proceed) or 10 (user declined, interactive only).
# Fail-open: any missing dep (gh, jq, auth) short-circuits to 0.
# GH#21831: searches both PRs and open issues to catch cross-tNNN duplicates.
_pre_claim_discovery_pass() {
	local title="$1"
	local repo_slug="$2"
	local dedup_days="${AIDEVOPS_CLAIM_DEDUP_DAYS:-14}"
	[[ -z "$title" || -z "$repo_slug" ]] && return 0
	command -v gh >/dev/null 2>&1 || return 0
	command -v jq >/dev/null 2>&1 || return 0
	gh auth status >/dev/null 2>&1 || return 0
	local keywords
	keywords=$(_pc_sanitize_keywords "$title")
	[[ -z "$keywords" ]] && return 0
	local all_hits=""

	# Search related PRs (existing behaviour)
	local pr_json pr_hits
	pr_json=$(_pc_search_related_prs "$repo_slug" "$keywords") || true
	if [[ -n "$pr_json" && "$pr_json" != "[]" ]]; then
		pr_hits=$(_pc_filter_relevant_prs "$pr_json" "$keywords" "$dedup_days")
		[[ -n "$pr_hits" ]] && all_hits="${pr_hits}"
	fi

	# Search related open issues (GH#21831: catch cross-tNNN duplicates)
	local issue_json issue_hits
	issue_json=$(_pc_search_related_issues "$repo_slug" "$keywords") || true
	if [[ -n "$issue_json" && "$issue_json" != "[]" ]]; then
		issue_hits=$(_pc_filter_relevant_issues "$issue_json" "$keywords" "$dedup_days")
		if [[ -n "$issue_hits" ]]; then
			if [[ -n "$all_hits" ]]; then
				all_hits="${all_hits}"$'\n'"${issue_hits}"
			else
				all_hits="${issue_hits}"
			fi
		fi
	fi

	[[ -z "$all_hits" ]] && return 0
	_pc_prompt_or_warn "$all_hits"
	return $?
}

# ---------------------------------------------------------------------------
# Predecessor reference detection (GH#20834)
#
# Scans description text for prose references to predecessor tasks and
# emits a comma-separated list of IDs for automatic blocked-by tagging.
#
# Recognised patterns (case-insensitive):
#   1. "Follow-up from tNNN" / "Follow-up from GH#NNN"
#   2. "tracked in GH#NNN" / "tracked in #NNN"
#   3. "blocked-by: tNNN" / "blocked-by:GH#NNN"  (explicit pass-through)
#   4. "after tNNN ships/merges/lands"
#
# Outputs comma-separated IDs on stdout. Empty output means no refs found.
# Bare "#NNN" references in pattern 2 are normalised to "GH#NNN".
#
# The caller stores the result in the global _CLAIM_BLOCKED_BY_REFS.
# _ensure_todo_entry_written reads _CLAIM_BLOCKED_BY_REFS to append the
# blocked-by tag to the TODO.md line it writes.
# ---------------------------------------------------------------------------
_detect_predecessor_refs() {
	local text="$1"
	[[ -z "$text" ]] && return 0

	local -a all_refs=()
	local ref _tmpout

	# Normalise a single extracted ref to canonical form and print it.
	# t/T + digits → t<NNN>; gh#/GH#/Gh# + digits → GH#<NNN>; bare #NNN unchanged.
	_normalise_ref() {
		local r="$1"
		if [[ "$r" =~ ^[Tt]([0-9]+)$ ]]; then
			printf 't%s' "${BASH_REMATCH[1]}"
		elif [[ "$r" =~ ^[Gg][Hh]#([0-9]+)$ ]]; then
			printf 'GH#%s' "${BASH_REMATCH[1]}"
		else
			printf '%s' "$r"
		fi
		return 0
	}

	# Pattern 1: "Follow-up from tNNN" or "Follow-up from GH#NNN"
	_tmpout=$(printf '%s' "$text" \
		| grep -oiE 'follow-up from (t[0-9]+|GH#[0-9]+)' \
		| grep -oiE '(t[0-9]+|GH#[0-9]+)' 2>/dev/null || true)
	while IFS= read -r ref; do
		[[ -z "$ref" ]] && continue
		all_refs+=("$(_normalise_ref "$ref")")
	done <<<"$_tmpout"

	# Pattern 2: "tracked in GH#NNN" or "tracked in #NNN"
	_tmpout=$(printf '%s' "$text" \
		| grep -oiE 'tracked in (GH#[0-9]+|#[0-9]+)' \
		| grep -oiE '(GH#[0-9]+|#[0-9]+)' 2>/dev/null || true)
	while IFS= read -r ref; do
		[[ -z "$ref" ]] && continue
		# Normalise bare #NNN → GH#NNN first, then canonical-case normalise
		[[ "$ref" =~ ^#[0-9]+$ ]] && ref="GH${ref}"
		all_refs+=("$(_normalise_ref "$ref")")
	done <<<"$_tmpout"

	# Pattern 3: explicit "blocked-by:tNNN" or "blocked-by: GH#NNN" (pass-through)
	_tmpout=$(printf '%s' "$text" \
		| grep -oiE 'blocked-by:?[[:space:]]*(t[0-9]+|GH#[0-9]+)' \
		| grep -oiE '(t[0-9]+|GH#[0-9]+)' 2>/dev/null || true)
	while IFS= read -r ref; do
		[[ -z "$ref" ]] && continue
		all_refs+=("$(_normalise_ref "$ref")")
	done <<<"$_tmpout"

	# Pattern 4: "after tNNN ships/merges/lands"
	_tmpout=$(printf '%s' "$text" \
		| grep -oiE 'after t[0-9]+ (ships|merges|lands)' \
		| grep -oiE 't[0-9]+' 2>/dev/null || true)
	while IFS= read -r ref; do
		[[ -z "$ref" ]] && continue
		all_refs+=("$(_normalise_ref "$ref")")
	done <<<"$_tmpout"

	[[ ${#all_refs[@]} -eq 0 ]] && return 0

	# Deduplicate preserving insertion order.
	local -a deduped=()
	local seen=""
	for ref in "${all_refs[@]}"; do
		if [[ ",${seen}," != *",${ref},"* ]]; then
			deduped+=("$ref")
			seen="${seen:+${seen},}${ref}"
		fi
	done

	# Output comma-separated
	local csv=""
	for ref in "${deduped[@]}"; do
		csv="${csv:+${csv},}${ref}"
	done
	printf '%s' "$csv"
	return 0
}

# _apply_blocked_by_detection — populate _CLAIM_BLOCKED_BY_REFS from description.
# Skipped when NO_BLOCKED_BY=true, TASK_DESCRIPTION is empty, or dry-run.
# Emits advisory to stderr when predecessor refs are found.
_apply_blocked_by_detection() {
	_CLAIM_BLOCKED_BY_REFS=""
	[[ "$NO_BLOCKED_BY" == true ]] && return 0
	[[ -z "$TASK_DESCRIPTION" ]] && return 0
	[[ "$DRY_RUN" == true ]] && return 0

	local detected
	detected=$(_detect_predecessor_refs "$TASK_DESCRIPTION") || true
	[[ -z "$detected" ]] && return 0

	_CLAIM_BLOCKED_BY_REFS="$detected"
	log_warn "GH#20834: Detected predecessor reference(s) in description; auto-emitting blocked-by:${detected}. Override with --no-blocked-by."
	return 0
}

# ---------------------------------------------------------------------------
# Dispatch-path auto-dispatch advisory (t2821 / t2920)
#
# When a caller requests --labels auto-dispatch on a task whose title or
# description references dispatch-path scripts, emit a non-blocking stderr
# advisory noting that the t2819 pre-dispatch detector will auto-elevate the
# worker to tier:thinking. No recommendation to switch to no-auto-dispatch —
# auto-dispatch is the AI-first default; opus-4-7 + worker worktree isolation
# + CI gates + circuit breaker (t2690) cover the residual risk.
#
# The canonical pattern list is loaded from self-hosting-files.conf.
# Falls back to hardcoded defaults when the conf file is absent.
#
# Arguments: none (reads TASK_TITLE, TASK_DESCRIPTION, TASK_LABELS globals)
#
# Environment:
#   AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1 — disable entirely
# ---------------------------------------------------------------------------
_warn_dispatch_path_auto_dispatch() {
	[[ "${AIDEVOPS_SKIP_DISPATCH_PATH_CHECK:-}" == "1" ]] && return 0

	# Only fire when auto-dispatch (or auto_dispatch) is in the label set
	if [[ ",${TASK_LABELS}," != *",auto-dispatch,"* && \
		",${TASK_LABELS}," != *",auto_dispatch,"* ]]; then
		return 0
	fi

	# Load patterns from shared conf file
	local _conf_file="${AIDEVOPS_DISPATCH_PATH_FILES_CONF:-${SCRIPT_DIR}/../configs/self-hosting-files.conf}"
	local _patterns=()
	if [[ -f "$_conf_file" ]]; then
		while IFS= read -r _line; do
			[[ -z "$_line" || "$_line" == \#* ]] && continue
			_patterns+=("$_line")
		done <"$_conf_file"
	fi
	if [[ ${#_patterns[@]} -eq 0 ]]; then
		_patterns=(
			"pulse-wrapper.sh" "pulse-dispatch-" "pulse-cleanup.sh"
			"headless-runtime-helper.sh" "headless-runtime-lib.sh"
			"worker-lifecycle-common.sh" "worker-lifecycle-common-" "shared-dispatch-dedup.sh"
			"shared-claim-lifecycle.sh" "worker-activity-watchdog.sh"
		)
	fi

	# Scan title + description for any dispatch-path pattern
	local _combined="${TASK_TITLE} ${TASK_DESCRIPTION:-}"
	local _matched=""
	local _p
	for _p in "${_patterns[@]}"; do
		if grep -qF "$_p" <<<"$_combined"; then
			_matched="$_p"
			break
		fi
	done
	[[ -z "$_matched" ]] && return 0

	log_info "t2920: dispatch-path file detected ('${_matched}') with auto-dispatch label."
	log_info "  The pre-dispatch detector (t2819) will auto-elevate this worker to tier:thinking."
	log_info "  No action required — proceed with auto-dispatch as normal."
	log_info "  See: reference/auto-dispatch.md \"Dispatch-Path Default (t2821 / t2920)\""
	return 0
}

