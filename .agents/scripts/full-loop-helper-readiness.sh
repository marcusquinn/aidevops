#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Readiness -- exact-head remote evidence and pre-merge gates
# =============================================================================
# Sub-library for full-loop-helper-commit.sh. Function bodies retain caller-owned
# state, transition locks, API backpressure, check classification and authority.
#
# Usage: source "${_FULL_LOOP_COMMIT_DIR}/full-loop-helper-readiness.sh"
#
# Dependencies:
#   - full-loop-helper-commit.sh constants and sibling includes
#   - shared-constants.sh logging and exact-check helpers
#   - full-loop state/merge helpers supplied by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_READINESS_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_READINESS_LIB_LOADED=1

# Preserve a custom caller SCRIPT_DIR; authority diagnostics use the source path.
if [[ -z "${_FULL_LOOP_COMMIT_DIR:-}" ]]; then
	_FULL_LOOP_COMMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	SCRIPT_DIR="$_FULL_LOOP_COMMIT_DIR"
fi

# --- Pre-Merge Gate ---

# Pre-merge gate (GH#17541) — deterministic enforcement of review-bot-gate
# before any PR merge. Workers MUST call this before `gh pr merge`.
# Models the pulse-wrapper.sh pattern (line 8243-8262) for the worker merge path.
#
# Usage: full-loop-helper.sh pre-merge-gate <PR_NUMBER> [REPO]
# Exit codes: 0 = safe to merge, 1 = gate failed (do NOT merge)
_full_loop_persist_pr_check_evidence() {
	local status="$1"
	local head_sha="$2"
	local evidence="${3:-}"
	command -v load_state >/dev/null 2>&1 || return 0
	command -v save_state >/dev/null 2>&1 || return 0
	[[ -f "${STATE_FILE:-}" ]] || return 0
	command -v _full_loop_acquire_transition_lock >/dev/null 2>&1 || return 1
	_full_loop_acquire_transition_lock || return 1
	load_state || {
		_full_loop_release_transition_lock
		return 1
	}
	PR_CHECK_STATUS="$status"
	PR_CHECK_HEAD="$head_sha"
	PR_CHECK_EVIDENCE="$evidence"
	if ! save_state "${CURRENT_PHASE:-pr-review}" "$SAVED_PROMPT" "${PR_NUMBER:-}" "$STARTED_AT"; then
		_full_loop_release_transition_lock
		return 1
	fi
	_full_loop_release_transition_lock
	return 0
}

_full_loop_local_admission_evidence() {
	local diagnostics="$1" line=""
	while IFS= read -r line; do
		case "$line" in
		'gh_pr_checks_exact_json: [gh-transport] '*)
			# The exact-check wrapper adds only this bounded trusted prefix. Strip
			# it before parsing the transport evidence so the deadline survives
			# without accepting arbitrary text containing a transport marker.
			line="${line#gh_pr_checks_exact_json: }"
			;;
		esac
		case "$line" in
		'[gh-transport] error_kind=github-api-read-deferred attempted=false deferred_by=local_admission '*)
			FULL_LOOP_PRE_MERGE_BLOCKER_KIND="${line#*error_kind=}"
			FULL_LOOP_PRE_MERGE_BLOCKER_KIND="${FULL_LOOP_PRE_MERGE_BLOCKER_KIND%% *}"
			FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL="retry-when-capacity-returns"
			[[ ! "$line" =~ retry_at=([0-9]+([.][0-9]+)?) ]] || FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL="${BASH_REMATCH[1]}"
			FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="$FULL_LOOP_PRE_MERGE_BLOCKER_KIND"
			FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="$line"
			return 0
			;;
		esac
	done <<<"$diagnostics"
	return 1
}

_full_loop_query_required_checks() {
	local pr_number="$1"
	local repo="$2"
	local pr_head_ref="$3"
	local required_contexts=""
	local required_contexts_rc=0
	local required_checks=""
	local required_rc=0
	local required_checks_stderr=""
	local required_checks_stderr_file=""
	local minimum_check_count=1
	local expected_no_required_checks="no required checks reported on the '${pr_head_ref}' branch"

	FULL_LOOP_REQUIRED_CHECKS_JSON=""
	FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="unavailable"
	FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="required-context resolution failed"
	FULL_LOOP_REQUIRED_CHECKS_SUCCESS_EVIDENCE="required-checks-pass"
	FULL_LOOP_REQUIRED_CHECKS_SUCCESS_SUMMARY="required checks are terminal-success"
	FULL_LOOP_PRE_MERGE_BLOCKER_KIND=""
	FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=""

	required_checks_stderr_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-full-loop-required-checks.XXXXXX") || {
		FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="stderr-capture-unavailable"
		FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="cannot capture gh stderr"
		return 1
	}
	required_contexts=$(_required_contexts_for_default_branch "$repo" 2>"$required_checks_stderr_file") || required_contexts_rc=$?
	if [[ "$required_contexts_rc" -ne 0 ]] && _full_loop_local_admission_evidence "$(<"$required_checks_stderr_file")"; then
		rm -f "$required_checks_stderr_file"
		return 1
	fi
	if [[ "$required_contexts_rc" -eq 0 && -z "$required_contexts" ]]; then
		rm -f "$required_checks_stderr_file"
		FULL_LOOP_REQUIRED_CHECKS_JSON="[]"
		FULL_LOOP_REQUIRED_CHECKS_SUCCESS_EVIDENCE="no-required-checks"
		FULL_LOOP_REQUIRED_CHECKS_SUCCESS_SUMMARY="no required checks are configured"
		return 0
	fi

	required_checks=$(gh_pr_checks_exact_json "$repo" "$pr_number" required \
		2>"$required_checks_stderr_file") || required_rc=$?
	required_checks_stderr=$(<"$required_checks_stderr_file")
	rm -f "$required_checks_stderr_file"
	FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="exact check read exit ${required_rc}"
	if [[ "$required_rc" -ne 0 ]] && _full_loop_local_admission_evidence "$required_checks_stderr"; then
		return 1
	fi
	if [[ "$required_checks_stderr" == *"error_kind=github-api-cooldown"* ]]; then
		FULL_LOOP_PRE_MERGE_BLOCKER_KIND="$_FULL_LOOP_ERROR_COOLDOWN"
		FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL="unknown"
		if [[ "$required_checks_stderr" =~ expires_at=([0-9]+) ]]; then
			FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL="${BASH_REMATCH[1]}"
		fi
		FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="$_FULL_LOOP_ERROR_COOLDOWN"
		if [[ "$FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL" =~ ^[0-9]+$ ]]; then
			FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="GitHub API cooldown is active until epoch ${FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL}"
		else
			FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="GitHub API cooldown is active"
		fi
	elif [[ "$required_checks_stderr" == *"error_kind=github-api-read-deferred"* ]]; then
		FULL_LOOP_PRE_MERGE_BLOCKER_KIND="$_FULL_LOOP_ERROR_READ_DEFERRED"
		FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL="retry-when-capacity-returns"
		FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="$_FULL_LOOP_ERROR_READ_DEFERRED"
		FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="GitHub API read capacity is deferred; preserve the PR and retry when capacity returns"
	fi

	if [[ "$required_rc" -eq 1 && -z "$required_checks" && -n "$pr_head_ref" && "$required_checks_stderr" == "$expected_no_required_checks" ]]; then
		required_checks="[]"
		minimum_check_count=0
		FULL_LOOP_REQUIRED_CHECKS_SUCCESS_EVIDENCE="no-required-checks"
		FULL_LOOP_REQUIRED_CHECKS_SUCCESS_SUMMARY="no required checks are configured"
	elif [[ -n "$required_checks_stderr" || ("$required_rc" -ne 0 && "$required_rc" -ne 1 && "$required_rc" -ne 8) ]]; then
		return 1
	fi
	if [[ -z "$required_checks" ]] || ! printf '%s' "$required_checks" | jq -e --argjson minimum "$minimum_check_count" \
		'type == "array" and length >= $minimum' >/dev/null 2>&1; then
		return 1
	fi
	FULL_LOOP_REQUIRED_CHECKS_JSON="$required_checks"
	return 0
}

_full_loop_review_bot_gate_helper_path() {
	local helper_path="${SCRIPT_DIR}/review-bot-gate-helper.sh"

	if [[ ! -f "$helper_path" ]]; then
		helper_path="${HOME}/.aidevops/agents/scripts/review-bot-gate-helper.sh"
	fi
	[[ -f "$helper_path" ]] || return 1
	printf '%s\n' "$helper_path"
	return 0
}

#######################################
# Fetch the fixed full-loop PR readiness snapshot with response-owned cost.
# Native `gh pr view` does not expose its GraphQL operation cost, so concurrent
# activity can otherwise leave the benchmark attempt unattributed.
# Args: $1=pr_number, $2=repo_slug
# Output: gh-pr-view-compatible readiness JSON
# Returns: 0=complete exact-cost snapshot, otherwise transport/validation failure
#######################################
_full_loop_pr_readiness_json_graphql() {
	local pr_number="$1"
	local repo_slug="$2"
	local owner="${repo_slug%%/*}"
	local name="${repo_slug#*/}"
	local response="" pr_json=""
	local jq_string_type="string"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$owner" && -n "$name" && "$repo_slug" == */* ]] || return 1
	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub.
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="full-loop-readiness-exact-cost" \
		gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr_number" -f query='
		query($owner: String!, $name: String!, $pr: Int!) {
			repository(owner: $owner, name: $name) {
				pullRequest(number: $pr) {
					state
					isDraft
					reviewDecision
					headRefOid
					headRefName
				}
			}
			rateLimit { cost }
		}') || return $?

	pr_json=$(printf '%s' "$response" | jq -ce --arg string_type "$jq_string_type" '
		select(((.errors // []) | type) == "array")
		| select(((.errors // []) | length) == 0)
		| select((.data.rateLimit.cost | type) == "number")
		| select(.data.rateLimit.cost > 0 and (.data.rateLimit.cost | floor) == .data.rateLimit.cost)
		| .data.repository.pullRequest
		| select(type == "object")
		| select((.state | type) == $string_type)
		| select((.isDraft | type) == "boolean")
		| select((.headRefOid | type) == $string_type)
		| select((.headRefName | type) == $string_type)
		| {state, isDraft, reviewDecision, headRefOid, headRefName}
	' 2>/dev/null) || return 1
	printf '%s\n' "$pr_json"
	return 0
}

# Capture at the caller boundary: command substitution cannot propagate blocker
# globals. Keep transport evidence distinct without replaying a readiness read.
_full_loop_read_pr_readiness() {
	local pr_number="$1" repo="$2"
	local error_file="" diagnostics="" read_rc=0
	FULL_LOOP_PR_READINESS_JSON=""
	FULL_LOOP_PRE_MERGE_BLOCKER_KIND=""
	FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=""
	error_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-pr-readiness.XXXXXX") || return 1
	FULL_LOOP_PR_READINESS_JSON=$(_full_loop_pr_readiness_json_graphql "$pr_number" "$repo" 2>"$error_file") || read_rc=$?
	diagnostics=$(<"$error_file")
	rm -f "$error_file"
	[[ "$read_rc" -ne 0 ]] || return 0
	FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="readiness-unavailable"
	FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="PR readiness read failed (exit ${read_rc})"
	if _full_loop_local_admission_evidence "$diagnostics"; then
		: # Existing typed local-admission evidence owns the reason and deadline.
	elif [[ "$diagnostics" == *'error_kind=github-api-cooldown'* ||
		"$diagnostics" == *'[gh-cooldown] secondary-rate-limit active=true'* ||
		"$diagnostics" == *'[gh-cooldown] primary-'*' active=true'* ]]; then
		FULL_LOOP_PRE_MERGE_BLOCKER_KIND="$_FULL_LOOP_ERROR_COOLDOWN"
		FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="$FULL_LOOP_PRE_MERGE_BLOCKER_KIND"
		FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="GitHub API cooldown is active"
		if [[ "$diagnostics" =~ expires_at=([0-9]+) ]]; then
			FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL="${BASH_REMATCH[1]}"
			FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL+=" until epoch ${BASH_REMATCH[1]}"
		fi
	elif [[ "$diagnostics" == *'[gh-cooldown] read-ramp active=true'* ||
		"$diagnostics" == *'error_kind=github-api-read-deferred'* ]]; then
		FULL_LOOP_PRE_MERGE_BLOCKER_KIND="$_FULL_LOOP_ERROR_READ_DEFERRED"
		FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="$FULL_LOOP_PRE_MERGE_BLOCKER_KIND"
		FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="GitHub API read capacity is deferred (recovery/admission)"
	elif [[ "$read_rc" -eq 124 ]]; then
		FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="readiness-timeout"
		FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="PR readiness read timed out; evidence remains unknown"
	fi
	_full_loop_record_check_read_failure "$pr_number" ""
	return 1
}

_full_loop_reconcile_stale_coderabbit_review() {
	local pr_number="$1"
	local repo="$2"
	local expected_head="$3"
	local rbg_helper=""
	local refreshed_json=""

	FULL_LOOP_RECONCILED_PR_JSON=""
	rbg_helper=$(_full_loop_review_bot_gate_helper_path) || {
		print_error "review-bot-gate-helper.sh not found — cannot reconcile stale CodeRabbit review state"
		return 1
	}
	print_info "Checking whether CodeRabbit's blocking review is superseded at exact head ${expected_head}..."
	if ! bash "$rbg_helper" reconcile-stale-coderabbit "$pr_number" "$repo" "$expected_head"; then
		print_error "PR #${pr_number} retains changes-requested review state; automatic reconciliation was not authorized"
		return 1
	fi
	_full_loop_read_pr_readiness "$pr_number" "$repo" || {
		print_error "Cannot refresh PR #${pr_number} after CodeRabbit reconciliation"
		return 1
	}
	refreshed_json="$FULL_LOOP_PR_READINESS_JSON"
	if [[ "$(printf '%s' "$refreshed_json" | jq -r '.headRefOid // empty')" != "$expected_head" ]]; then
		print_error "PR #${pr_number} head changed during CodeRabbit reconciliation"
		return 1
	fi
	FULL_LOOP_RECONCILED_PR_JSON="$refreshed_json"
	return 0
}

# Keep transport backpressure distinct from CI or malformed-evidence failures.
_full_loop_record_check_read_failure() {
	local pr_number="$1"
	local verified_head="$2"
	FULL_LOOP_PR_CHECK_STATUS="$_FULL_LOOP_CHECK_INDETERMINATE"
	case "$FULL_LOOP_PRE_MERGE_BLOCKER_KIND" in
	github-api-cooldown | github-api-read-deferred) FULL_LOOP_PR_CHECK_STATUS="$_FULL_LOOP_CHECK_DEFERRED" ;;
	esac
	export FULL_LOOP_PR_CHECK_STATUS
	_full_loop_persist_pr_check_evidence "$FULL_LOOP_PR_CHECK_STATUS" "$verified_head" "$FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE" || true
	if [[ "$FULL_LOOP_PR_CHECK_STATUS" == "$_FULL_LOOP_CHECK_DEFERRED" ]]; then
		print_info "PR #${pr_number} verification deferred (${FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL}); no CI failure, repair or duplicate implementation is established"
	else
		print_error "PR #${pr_number} required-check evidence is indeterminate (${FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL})"
	fi
	return 0
}

_full_loop_verify_pr_readiness() {
	local pr_number="$1"
	local repo="$2"
	local pr_json=""
	local verified_head=""
	local review_decision=""
	local readiness_failures=""

	_full_loop_read_pr_readiness "$pr_number" "$repo" || return 1
	pr_json="$FULL_LOOP_PR_READINESS_JSON"
	verified_head=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty')
	review_decision=$(printf '%s' "$pr_json" | jq -r '(.reviewDecision // "") | ascii_upcase')
	if [[ "$review_decision" == "CHANGES_REQUESTED" && -n "$verified_head" ]]; then
		_full_loop_reconcile_stale_coderabbit_review "$pr_number" "$repo" "$verified_head" || return 1
		pr_json="$FULL_LOOP_RECONCILED_PR_JSON"
	fi

	readiness_failures=$(printf '%s' "$pr_json" | jq -r --arg pr "$pr_number" --arg repo "$repo" '
		def up(v): (v // "" | ascii_upcase);
		[
			if .state != "OPEN" then "PR #\($pr) is not open" else empty end,
			if .isDraft == true then "PR #\($pr) is a draft; mark it ready with: gh pr ready \($pr) --repo \($repo)" else empty end,
			if up(.reviewDecision) == "CHANGES_REQUESTED" then "PR #\($pr) has changes requested" else empty end,
			if (.headRefOid // "") == "" then "PR #\($pr) has no stable head" else empty end
		][]') || return 1
	if [[ -n "$readiness_failures" ]]; then
		while IFS= read -r readiness_failure; do
			print_error "$readiness_failure"
		done <<<"$readiness_failures"
		return 1
	fi
	verified_head=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty')
	local pr_head_ref=""
	pr_head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // empty')

	local required_checks=""
	_full_loop_query_required_checks "$pr_number" "$repo" "$pr_head_ref" || {
		_full_loop_record_check_read_failure "$pr_number" "$verified_head"
		return 1
	}
	required_checks="$FULL_LOOP_REQUIRED_CHECKS_JSON"
	local post_checks_head=""
	post_checks_head=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh pr view "$pr_number" --repo "$repo" \
		--json headRefOid --jq '.headRefOid // empty' 2>/dev/null) || true
	if [[ -z "$post_checks_head" || "$post_checks_head" != "$verified_head" ]]; then
		FULL_LOOP_PR_CHECK_STATUS="$_FULL_LOOP_CHECK_INDETERMINATE"
		export FULL_LOOP_PR_CHECK_STATUS
		_full_loop_persist_pr_check_evidence "$FULL_LOOP_PR_CHECK_STATUS" "$post_checks_head" "head-drift-during-check-query" || true
		print_error "PR #${pr_number} head changed while required checks were queried; refresh exact-head evidence"
		return 1
	fi
	local non_passing=""
	# GitHub accepts completed SKIPPED checks for non-applicable required gates.
	# Do not admit other skipping states or infer completion from the bucket alone.
	non_passing=$(printf '%s' "$required_checks" | jq -c '[.[] | select(((.bucket == "pass") or (.bucket == "skipping" and .state == "SKIPPED")) | not)]')
	if [[ "$(printf '%s' "$non_passing" | jq 'length')" -gt 0 ]]; then
		if printf '%s' "$non_passing" | jq -e --arg pending "$_FULL_LOOP_CHECK_PENDING" 'all(.[]; (.bucket // "") == $pending)' >/dev/null 2>&1; then
			FULL_LOOP_PR_CHECK_STATUS="$_FULL_LOOP_CHECK_PENDING"
			export FULL_LOOP_PR_CHECK_STATUS
			_full_loop_persist_pr_check_evidence "$FULL_LOOP_PR_CHECK_STATUS" "$verified_head" "required-checks-pending" || true
			print_info "PR #${pr_number} required checks are pending at the current head; no repair action is eligible"
		else
			FULL_LOOP_PR_CHECK_STATUS="terminal-failure"
			FULL_LOOP_PR_FAILURE_EVIDENCE=$(printf '%s' "$non_passing" | jq -c --arg pending "$_FULL_LOOP_CHECK_PENDING" '[.[] | select((.bucket // "") != $pending) | {name,state,bucket}]')
			export FULL_LOOP_PR_CHECK_STATUS FULL_LOOP_PR_FAILURE_EVIDENCE
			local failure_names=""
			failure_names=$(printf '%s' "$FULL_LOOP_PR_FAILURE_EVIDENCE" | jq -r 'map(.name) | join(",")')
			_full_loop_persist_pr_check_evidence "$FULL_LOOP_PR_CHECK_STATUS" "$verified_head" "$failure_names" || true
			print_error "PR #${pr_number} has terminal required-check failures at the current head"
		fi
		return 1
	fi
	FULL_LOOP_PR_CHECK_STATUS="terminal-success"
	export FULL_LOOP_PR_CHECK_STATUS
	local local_branch=""
	local_branch=$(git branch --show-current 2>/dev/null || true)
	if [[ -n "$local_branch" && "$local_branch" == "$pr_head_ref" ]]; then
		local local_head=""
		local_head=$(git rev-parse HEAD 2>/dev/null || true)
		if [[ -z "$local_head" || "$local_head" != "$verified_head" ]]; then
			local repo_root=""
			repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
			if [[ -n "$repo_root" ]] && planning_verify_publication_receipt \
				"$repo_root" origin "$pr_head_ref" "$verified_head"; then
				print_info "Verified checkout-free planning publication receipt at PR head ${verified_head}; local Git state remains untouched"
			else
				print_error "PR #${pr_number} head drifted from the current worktree without a valid checkout-free planning publication receipt; push or refresh review evidence before merge"
				return 1
			fi
		fi
	fi
	_full_loop_persist_pr_check_evidence "$FULL_LOOP_PR_CHECK_STATUS" "$verified_head" "$FULL_LOOP_REQUIRED_CHECKS_SUCCESS_EVIDENCE" || true

	FULL_LOOP_VERIFIED_PR_HEAD_SHA="$verified_head"
	export FULL_LOOP_VERIFIED_PR_HEAD_SHA
	print_success "Remote PR evidence verified at head ${verified_head}; ${FULL_LOOP_REQUIRED_CHECKS_SUCCESS_SUMMARY}"
	return 0
}

cmd_pre_merge_gate() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	FULL_LOOP_PRE_MERGE_BLOCKER_KIND=""
	FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=""

	if [[ -z "$pr_number" ]]; then
		print_error "Usage: full-loop-helper.sh pre-merge-gate <PR_NUMBER> [REPO]"
		return 1
	fi

	# Auto-detect repo from git remote if not provided
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
		if [[ -z "$repo" ]]; then
			print_error "Cannot detect repo. Pass REPO as second argument."
			return 1
		fi
	fi

	_full_loop_verify_pr_readiness "$pr_number" "$repo" || return 1

	local rbg_helper=""
	if ! rbg_helper=$(_full_loop_review_bot_gate_helper_path); then
		FULL_LOOP_PRE_MERGE_BLOCKER_KIND="review-bot"
		print_error "review-bot-gate-helper.sh not found — refusing an unreviewed merge"
		return 1
	fi

	print_info "Running review bot gate for PR #${pr_number} in ${repo}..."

	# Check once. Pending review is persisted by the lifecycle caller and resumed
	# by the next provider/check event; this avoids a fixed-duration polling loop.
	local rbg_result=""
	rbg_result=$(bash "$rbg_helper" check "$pr_number" "$repo" 2>&1) || true

	local rbg_status=""
	rbg_status=$(printf '%s' "$rbg_result" | grep -oE '(PASS_RATE_LIMITED|PASS_ADVISORY|PASS|SKIP|WAITING)' | tail -1)

	case "$rbg_status" in
	PASS | PASS_ADVISORY | SKIP | PASS_RATE_LIMITED)
		print_success "Review bot gate: ${rbg_status} — safe to merge PR #${pr_number}"
		;;
	*)
		FULL_LOOP_PRE_MERGE_BLOCKER_KIND="review-bot"
		print_error "Review bot gate: ${rbg_status:-FAILED} — do NOT merge PR #${pr_number}"
		printf '%s\n' "$rbg_result" | tail -5
		return 1
		;;
	esac

	#aidevops:trust-boundary GH#17671/GH#28622 -- resolve every authority target
	# from the final live PR snapshot. This diagnostic never grants authority; the
	# merge transport repeats the same evaluation immediately before its write.
	#aidevops:trust-boundary -- advisory only; never grants merge authority.
	local verifier_dir="" active_dir="" verifier_bundle="" active_bundle=""
	verifier_dir=$(cd -P "$_FULL_LOOP_COMMIT_DIR" 2>/dev/null && pwd) || verifier_dir=""
	if [[ "$verifier_dir" == */runtime-bundles/*/agents/scripts ]]; then
		active_dir=$(cd -P "$HOME/.aidevops/agents/scripts" 2>/dev/null && pwd) || active_dir=""
		if [[ "$active_dir" == */runtime-bundles/*/agents/scripts && "$active_dir" != "$verifier_dir" ]]; then
			verifier_bundle=${verifier_dir%/agents/scripts}
			active_bundle=${active_dir%/agents/scripts}
			printf 'APPROVAL_NOTE: verifier bundle %s is older than active bundle %s; re-run with ~/.aidevops/agents/scripts/approval-helper.sh before re-signing\n' "${verifier_bundle##*/}" "${active_bundle##*/}" >&2
		fi
	fi
	declare -p FULL_LOOP_EXTERNAL_AUTHORITY_APPROVAL_TARGETS >/dev/null 2>&1 ||
		FULL_LOOP_EXTERNAL_AUTHORITY_APPROVAL_TARGETS=()
	if ! _merge_collect_external_authority_gaps "$pr_number" "$repo"; then
		FULL_LOOP_PRE_MERGE_BLOCKER_KIND="external-authority"
		FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL="unable to verify external/fork authority"
		return 1
	fi
	if [[ "${#FULL_LOOP_EXTERNAL_AUTHORITY_TARGETS[@]}" -gt 0 ]]; then
		local approval_targets=""
		approval_targets="${FULL_LOOP_EXTERNAL_AUTHORITY_TARGETS[*]}"
		FULL_LOOP_PRE_MERGE_BLOCKER_KIND="external-authority"
		FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL="${approval_targets}"
		print_error "External/fork PR #${pr_number} has missing cryptographic development authority"
		print_info "After finalizing all approval-bound PR metadata, run this one command:"
		printf 'sudo aidevops approve batch %s %s\n' "$approval_targets" "$repo"
		return 1
	fi

	#aidevops:trust-boundary -- distinguish absent authority targets from verified
	# targets without changing the fail-closed authority evaluation above.
	if [[ "${#FULL_LOOP_EXTERNAL_AUTHORITY_APPROVAL_TARGETS[@]}" -gt 0 ]]; then
		print_success "External/fork authority preflight: verified for ${FULL_LOOP_EXTERNAL_AUTHORITY_APPROVAL_TARGETS[*]} on PR #${pr_number}"
	else
		print_success "External/fork authority preflight: no external authority targets for PR #${pr_number}"
	fi
	return 0
}
