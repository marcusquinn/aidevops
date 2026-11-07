#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Merge Transport -- bounded GitHub reads/writes and merge recovery
# =============================================================================
# Extracted verbatim from full-loop-helper-merge.sh (GH#36968). Owns the
# bounded GitHub read/write adapters (_flm_gh_read, _flm_gh_write), the
# local-admission read retry (_merge_with_admission_retry), verified-head
# resolution, the REST merge fallback and transient/timed-out write
# reconciliation (_merge_run_bounded_write).
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-merge-transport.sh"
#        (sourced by full-loop-helper-merge.sh; do not execute directly)
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success,
#     print_warning, timeout_sec, _gh_with_timeout when available)
#   - full-loop-helper-merge-authority.sh (_merge_guard_admin_merge_maintainer_review)
#   - full-loop-helper-merge-prospective.sh (_merge_fetch_head_sha_rest)
#   - full-loop-helper-merge.sh (_merge_guard_prospective_todo)
#   - Globals: FULL_LOOP_EXPECTED_PR_HEAD_SHA, FULL_LOOP_VERIFIED_PR_HEAD_SHA,
#     FULL_LOOP_MERGE_READ_HEAD_SHA, FULL_LOOP_PRE_MERGE_BLOCKER_KIND/DETAIL,
#     _MERGE_WRITE_OUTPUT
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_MERGE_TRANSPORT_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_MERGE_TRANSPORT_LIB_LOADED=1

# --- Bounded GitHub Read/Write Adapters ---

_flm_gh_read() {
	_merge_with_admission_retry _flm_gh_read_once "$@"
	return $?
}

_flm_gh_read_once() {
	local rc=0
	local AIDEVOPS_GH_READ_TIMEOUT="${AIDEVOPS_GH_READ_TIMEOUT:-60}"
	# A fresh read keeps its transport timeout, even after a slow healthy gate.
	# The admission deadline bounds recovery waiting, not transport attempts.
	export AIDEVOPS_GH_READ_TIMEOUT
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

# One recovery owner per read/gate: the deadline starts at the first deferral;
# nested reads do not start their own retry loops. Only local-admission evidence is
# retryable; quota exhaustion, HTTP errors and review/CI failures fail closed.
_merge_with_admission_retry() {
	if [[ "${_FULL_LOOP_ADMISSION_ACTIVE:-0}" == 1 ]]; then
		"$@"
		return $?
	fi
	local budget="${AIDEVOPS_MERGE_ADMISSION_BUDGET_SECONDS:-60}"
	[[ "$budget" =~ ^[0-9]{1,4}$ && "$budget" -gt 0 ]] || budget=60
	[[ "$budget" -le 60 ]] || budget=60
	local _FULL_LOOP_ADMISSION_ACTIVE=1
	local _FULL_LOOP_ADMISSION_DEADLINE=0
	local attempts=0 rc=0 diagnostics="" retry_at="" now="" wait_seconds=0 round_up=0
	local err_file="" out_file=""
	err_file=$(mktemp "${TMPDIR:-/tmp}/merge-admission-error.XXXXXX") || return 1
	out_file=$(mktemp "${TMPDIR:-/tmp}/merge-admission-output.XXXXXX") || {
		rm -f "$err_file"
		return 1
	}
	while :; do
		rc=0
		"$@" >"$out_file" 2>"$err_file" || rc=$?
		diagnostics=$(<"$err_file")
		if [[ "$rc" -eq 0 ]]; then
			# Transport success is not read success if the captured response cannot
			# reach the caller. Preserve replay failures instead of returning an
			# empty successful read (GH#35181); never retry the transport for this.
			cat "$out_file" || rc=$?
			if [[ "$rc" -ne 0 ]]; then
				printf 'Could not replay captured GitHub read output (exit %s)\n' "$rc" >&2
			fi
			[[ -z "$diagnostics" ]] || printf '%s\n' "$diagnostics" >&2
			rm -f "$err_file" "$out_file"
			return "$rc"
		fi
		# Match the transport record, not unrelated text that mentions pacing.
		if [[ "$diagnostics" != *"error_kind=github-api-read-deferred attempted=false deferred_by=local_admission retry_at="* ]]; then
			break
		fi
		retry_at="${diagnostics##*deferred_by=local_admission retry_at=}"
		retry_at="${retry_at%%[[:space:]]*}"
		[[ "$retry_at" =~ ^[0-9]{1,10}([.][0-9]+)?$ ]] || break
		if [[ "$_FULL_LOOP_ADMISSION_DEADLINE" -eq 0 ]]; then
			_FULL_LOOP_ADMISSION_DEADLINE=$((SECONDS + budget))
		fi
		now=$(date +%s) || break
		round_up=0
		[[ ! "$retry_at" =~ [.][0-9]*[1-9] ]] || round_up=1
		wait_seconds=$((10#${retry_at%%.*} + round_up - now))
		[[ "$wait_seconds" -gt 0 ]] || wait_seconds=1
		[[ "$attempts" -lt 3 && "$wait_seconds" -le $((_FULL_LOOP_ADMISSION_DEADLINE - SECONDS)) ]] || break
		print_info "Local GitHub read admission: waiting ${wait_seconds}s (${budget}s recovery budget, retry $((attempts + 1))/3)" >&2
		sleep "$wait_seconds" || break
		[[ "$SECONDS" -lt "$_FULL_LOOP_ADMISSION_DEADLINE" ]] || break
		attempts=$((attempts + 1))
	done
	if [[ "$diagnostics" == *"error_kind=github-api-read-deferred attempted=false deferred_by=local_admission retry_at="* ]]; then
		FULL_LOOP_PRE_MERGE_BLOCKER_KIND=github-api-read-deferred
		FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL="$retry_at"
	fi
	# Preserve the final gate diagnostic as well as transport stderr on failure.
	cat "$out_file"
	[[ -z "$diagnostics" ]] || printf '%s\n' "$diagnostics" >&2
	rm -f "$err_file" "$out_file"
	return "$rc"
}

_flm_gh_write() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout write "$@" || rc=$?
	else
		timeout_sec "${AIDEVOPS_GH_WRITE_TIMEOUT:-45}" "$@" || rc=$?
	fi
	return "$rc"
}

# --- Merge Transport Fallback and Write Reconciliation ---

# _merge_rest_fallback — squash/merge/rebase a PR via the REST pull merge endpoint.
#
# This is a transport fallback only. It is called after review-bot-gate has
# passed and `gh pr merge` hit a GraphQL quota or transient server failure.
# The REST endpoint still enforces branch protection and mergeability;
# failures remain failures.
#
# Args: pr_number repo merge_method expected_head_sha [squash_subject] [merge_body_file]
# Returns: 0 = merged, 1 = REST merge failed
_merge_rest_fallback() {
	local pr_number="$1"
	local repo="$2"
	local merge_method="$3"
	local expected_head_sha="$4"
	local squash_subject="${5:-}"
	local merge_body_file="${6:-}"
	local rest_method="${merge_method#--}"
	local rest_out="" rest_rc=0

	# GH#36966: the previous transport may have committed before reporting an
	# error. Reconcile before revalidating authority on an auto-closed issue.
	_merge_report_already_merged_at_head "$pr_number" "$repo" "$expected_head_sha" && return 0

	if [[ -z "$expected_head_sha" ]]; then
		print_error "REST merge fallback unavailable: PR head SHA was not verified before merge"
		return 1
	fi

	case "$rest_method" in
	squash | merge | rebase) ;;
	*)
		print_error "Unsupported merge method for REST fallback: ${merge_method}"
		return 1
		;;
	esac

	#aidevops:trust-boundary -- GraphQL transport failure does not preserve a
	# mutable authority snapshot for the later REST mutation.
	_merge_revalidate_transport_authority "$pr_number" "$repo" "$expected_head_sha" || return 1

	print_info "GitHub transport failure blocked gh pr merge; retrying via REST pull merge endpoint with verified head SHA ${expected_head_sha}..."
	local rest_args=(-f "sha=${expected_head_sha}" -f "merge_method=${rest_method}")
	[[ -n "$squash_subject" ]] && rest_args+=(-f "commit_title=${squash_subject}")
	[[ -n "$merge_body_file" ]] && rest_args+=(-F "commit_message=@${merge_body_file}")
	if rest_out=$(gh api -X PUT "repos/${repo}/pulls/${pr_number}/merge" \
		${rest_args[@]+"${rest_args[@]}"} 2>&1); then
		rest_rc=0
	else
		rest_rc=$?
	fi

	printf '%s\n' "$rest_out"
	if [[ $rest_rc -eq 0 ]]; then
		print_success "PR #${pr_number} merged via REST fallback (${rest_method})"
		return 0
	fi

	_merge_report_already_merged_at_head "$pr_number" "$repo" "$expected_head_sha" && return 0
	print_error "REST merge fallback failed for PR #${pr_number}"
	return 1
}

# A server error after a mutation has an unknown outcome. Reconcile via REST
# before considering one retry; unreadable or changed state fails closed.
_merge_recover_transient_server_error() {
	local pr_number="$1" repo="$2" merge_method="$3" expected_head_sha="$4"
	local squash_subject="$5" merge_body_file="$6" pr_json=""
	pr_json=$(_flm_gh_read gh api "repos/${repo}/pulls/${pr_number}") || {
		print_error "Could not reconcile server-error merge for PR #${pr_number}; refusing retry"
		return 1
	}
	#aidevops:trust-boundary -- a failed transport is not proof the write failed,
	# and only the previously verified head can be accepted or retried.
	if jq -e --arg head "$expected_head_sha" '.merged == true and .head.sha == $head' <<<"$pr_json" >/dev/null 2>&1; then
		print_success "PR #${pr_number} already merged at verified head ${expected_head_sha}; no retry issued"
		return 0
	fi
	if ! jq -e --arg head "$expected_head_sha" '.merged == false and .state == "open" and .head.sha == $head' <<<"$pr_json" >/dev/null 2>&1; then
		print_error "PR #${pr_number} is not open at the verified head after server error; refusing retry"
		return 1
	fi
	# The fallback revalidates live review and transport authority before writing.
	_merge_rest_fallback "$pr_number" "$repo" "$merge_method" "$expected_head_sha" "$squash_subject" "$merge_body_file" || return 1
	return 0
}

# Final head-SHA read with bounded recovery from local admission deferral only.
# Sets FULL_LOOP_MERGE_READ_HEAD_SHA on success. On failure, when pacing caused
# it, FULL_LOOP_PRE_MERGE_BLOCKER_KIND/DETAIL carry the deferral kind + retry_at.
_merge_read_head_sha_with_admission_retry() {
	local pr_number="$1"
	local repo="$2"
	local err_file="" rc=0
	FULL_LOOP_MERGE_READ_HEAD_SHA=""
	FULL_LOOP_PRE_MERGE_BLOCKER_KIND=""
	FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL=""
	err_file=$(mktemp "${TMPDIR:-/tmp}/merge-head-retry.XXXXXX") || return 1
	FULL_LOOP_MERGE_READ_HEAD_SHA=$(_merge_with_admission_retry _merge_fetch_head_sha_rest "$pr_number" "$repo" 2>"$err_file") || rc=$?
	if [[ "$rc" -eq 0 && -n "$FULL_LOOP_MERGE_READ_HEAD_SHA" ]]; then
		cat "$err_file" >&2
		rm -f "$err_file"
		return 0
	fi
	FULL_LOOP_MERGE_READ_HEAD_SHA=""
	if declare -F _full_loop_local_admission_evidence >/dev/null 2>&1; then
		_full_loop_local_admission_evidence "$(<"$err_file")" || true
	fi
	cat "$err_file" >&2
	rm -f "$err_file"
	# Preserve failed read status; empty success still fails closed.
	[[ "$rc" -ne 0 ]] || rc=1
	return "$rc"
}

_merge_resolve_match_head() {
	local pr_number="$1"
	local repo="$2"
	local pre_merge_head_sha=""
	# Called directly (not in a subshell) so deferral evidence globals survive.
	_merge_read_head_sha_with_admission_retry "$pr_number" "$repo" || true
	pre_merge_head_sha="${FULL_LOOP_MERGE_READ_HEAD_SHA:-}"
	#aidevops:trust-boundary — constrain, never replace, the verified merge head.
	if [[ -n "${FULL_LOOP_EXPECTED_PR_HEAD_SHA:-}" && "$pre_merge_head_sha" != "$FULL_LOOP_EXPECTED_PR_HEAD_SHA" ]]; then
		print_error "PR #${pr_number} differs from the caller's approved head; refusing merge"
		return 1
	fi
	if [[ -n "${FULL_LOOP_VERIFIED_PR_HEAD_SHA:-}" ]]; then
		if [[ -z "$pre_merge_head_sha" ]]; then
			if [[ "${FULL_LOOP_PRE_MERGE_BLOCKER_KIND:-}" == github-api-read-deferred ]]; then
				print_error "PR #${pr_number} head SHA read deferred by local admission (retry_at=${FULL_LOOP_PRE_MERGE_BLOCKER_DETAIL:-unknown}); recovery budget exhausted, refusing merge"
			else
				print_error "Could not retrieve PR #${pr_number} head SHA for verification; refusing merge"
			fi
			return 1
		fi
		if [[ "$pre_merge_head_sha" != "$FULL_LOOP_VERIFIED_PR_HEAD_SHA" ]]; then
			print_error "PR #${pr_number} head changed after remote verification; refusing merge"
			return 1
		fi
	fi
	local match_head_sha="${FULL_LOOP_VERIFIED_PR_HEAD_SHA:-$pre_merge_head_sha}"
	[[ -n "$match_head_sha" ]] || return 1
	printf '%s\n' "$match_head_sha"
	return 0
}

_merge_review_state_still_clear() {
	local pr_number="$1"
	local repo="$2"
	local expected_head="$3"
	local review_json=""

	review_json=$(_flm_gh_read gh pr view "$pr_number" --repo "$repo" \
		--json state,isDraft,reviewDecision,headRefOid) || {
		print_error "Could not refresh PR #${pr_number} review state immediately before merge"
		return 1
	}
	# GH#33567: a merged PR is not a review/head change. Return 3 so the
	# primary merge path can verify an exact-head merge; other callers treat any
	# non-zero result as fail-closed and never issue a write.
	if printf '%s\n' "$review_json" | jq -e '(.state // "") == "MERGED"' >/dev/null 2>&1; then
		print_info "PR #${pr_number} is already MERGED; no merge write will be issued"
		return 3
	fi
	#aidevops:trust-boundary — admin and REST merge paths must not bypass a review added after readiness verification.
	if ! printf '%s\n' "$review_json" | jq -e --arg head "$expected_head" '
		.state == "OPEN"
		and .isDraft != true
		and (.headRefOid // "") == $head
		and ((.reviewDecision // "") | ascii_upcase) != "CHANGES_REQUESTED"
	' >/dev/null 2>&1; then
		print_error "PR #${pr_number} review or head state changed after readiness verification; refusing merge"
		return 1
	fi
	return 0
}

_merge_revalidate_transport_authority() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="$3"
	local review_rc=0

	# Propagates 3 (already MERGED) from the review-state check; 1 otherwise.
	_merge_review_state_still_clear "$pr_number" "$repo" "$expected_head_sha" || review_rc=$?
	[[ "$review_rc" -eq 0 || "$review_rc" -eq 3 ]] || return 1
	[[ "$review_rc" -eq 0 ]] || return 3
	_merge_guard_admin_merge_maintainer_review "$pr_number" "$repo" "$expected_head_sha" || return 1
	_merge_guard_prospective_todo "$pr_number" "$repo" || return 1
	return 0
}

# Read the PR once and succeed only when GitHub reports a completed merge of
# exactly the reviewed head. On success, prints the merge commit OID.
# Returns: 0 = merged at expected head, 1 = not proven (open, closed-unmerged,
# merged at a different head, or unreadable), 2 = PR state could not be read.
#aidevops:trust-boundary GH#33567 -- accepts only a merge that already happened
# at the verified head; never relaxes review/check gates for an open PR.
_merge_pr_merged_at_head() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="$3"
	local pr_json="" read_rc=0 merge_oid=""

	[[ -n "$expected_head_sha" ]] || return 1
	pr_json=$(_flm_gh_read gh pr view "$pr_number" --repo "$repo" \
		--json state,mergedAt,mergeCommit,headRefOid) || read_rc=$?
	merge_oid=$(printf '%s\n' "$pr_json" | jq -er --arg head "$expected_head_sha" '
		select(
			((.state // "") | ascii_downcase) == "merged"
			and (.mergedAt // null) != null
			and (.mergeCommit.oid // null) != null
			and (.headRefOid // null) == $head
		)
		| .mergeCommit.oid
	' 2>/dev/null) && {
		printf '%s\n' "$merge_oid"
		return 0
	}
	# GH#36966: the review read adapter can still show OPEN after GitHub has
	# merged and closed the linked issue. Use the REST merge record before
	# treating stale approval as a failed mutation; never accept another head.
	pr_json=$(_flm_gh_read gh api "repos/${repo}/pulls/${pr_number}" \
		-H 'Cache-Control: no-cache') || {
		[[ "$read_rc" -eq 0 ]] || return 2
		return 1
	}
	printf '%s\n' "$pr_json" | jq -er --arg head "$expected_head_sha" '
		select(.merged == true and .merged_at != null
			and .merge_commit_sha != null and .head.sha == $head)
		| .merge_commit_sha
	' 2>/dev/null || return 1
	return 0
}

# GH#33567: a PR can be merged at the verified head between readiness
# verification and the merge write (for example by GitHub auto-merge enabled
# on the protected release PR). Treat that as idempotent success; no write.
_merge_report_already_merged_at_head() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="$3"
	local merge_oid=""

	merge_oid=$(_merge_pr_merged_at_head "$pr_number" "$repo" "$expected_head_sha") || return 1
	print_success "PR #${pr_number} already merged at verified head ${expected_head_sha} (merge ${merge_oid}); no further write issued"
	return 0
}

# A timed-out merge write has an unknown outcome: GitHub may have accepted the
# mutation before the local process was killed. Re-read the exact PR/head once;
# accept only a completed merge of the reviewed head and never replay the write.
_merge_reconcile_timed_out_write() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="$3"
	local merged_rc=0

	print_warning "Merge write timed out for PR #${pr_number}; reconciling exact remote state without retrying the mutation"
	_merge_pr_merged_at_head "$pr_number" "$repo" "$expected_head_sha" >/dev/null || merged_rc=$?
	if [[ "$merged_rc" -eq 2 ]]; then
		print_error "Could not reconcile timed-out merge write for PR #${pr_number}; outcome remains unknown"
		return 1
	fi
	if [[ "$merged_rc" -eq 0 ]]; then
		print_success "PR #${pr_number} merge completed remotely before the local write timeout"
		return 0
	fi

	print_error "Timed-out merge write for PR #${pr_number} is not proven merged at the reviewed head; refusing blind retry"
	return 1
}

# Run one bounded merge write and reconcile errors against the verified head.
# Args: pr_number repo expected_head_sha command [command_args...]
# Sets _MERGE_WRITE_OUTPUT to the captured transport output, clearing it when
# timeout reconciliation fails. Returns 0 for a successful write or proven
# exact-head merge; otherwise returns the write status or 1 for an unproven timeout.
_merge_run_bounded_write() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="$3"
	local write_rc=0
	shift 3
	_MERGE_WRITE_OUTPUT=""
	if _MERGE_WRITE_OUTPUT=$(_flm_gh_write "$@" 2>&1); then
		return 0
	else
		write_rc=$?
	fi
	# A nonzero transport result is not proof that the mutation failed. Return
	# success to the normal post-merge lifecycle without replaying the write.
	_merge_report_already_merged_at_head "$pr_number" "$repo" "$expected_head_sha" && return 0
	[[ "$write_rc" -eq 124 ]] || return "$write_rc"
	_merge_reconcile_timed_out_write "$pr_number" "$repo" "$expected_head_sha" || {
		_MERGE_WRITE_OUTPUT=""
		return 1
	}
	return 0
}
